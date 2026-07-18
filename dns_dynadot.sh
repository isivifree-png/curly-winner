#!/bin/sh
# ~/.acme.sh/dnsapi/dns_dynadot.sh
# Управление TXT-записями через Dynadot API v2
#
# Требуемые переменные окружения:
# export DYNADOT_API_KEY="ваш_api_key"
# export DYNADOT_API_SECRET="ваш_secret_key"

# ========== ДОБАВЛЕНИЕ TXT-записи ==========
dns_dynadot_add() {
    local fulldomain="$1"
    local txtvalue="$2"

    _debug "fulldomain: $fulldomain"
    _debug "txtvalue: $txtvalue"

    if ! _get_root "$fulldomain"; then
        _err "Cannot find root domain for $fulldomain"
        return 1
    fi
    _debug "domain: $_domain, subdomain: $_sub_domain"

    local domain_enc txt_enc sub_enc data
    domain_enc=$(_url_encode "$_domain")
    txt_enc=$(_url_encode "$txtvalue")

    # Используем add_dns для добавления одной записи
    data="domain=${domain_enc}&record_type=TXT&record=${txt_enc}"

    if [ -n "$_sub_domain" ]; then
        sub_enc=$(_url_encode "$_sub_domain")
        data="${data}&subdomain=${sub_enc}"
    fi

    if ! _dynadot_rest "add_dns" "$data"; then
        return 1
    fi

    _info "TXT record for $fulldomain added successfully."
    _sleep 30  # Даём время на распространение записи
    return 0
}

# ========== УДАЛЕНИЕ TXT-записи ==========
dns_dynadot_rm() {
    local fulldomain="$1"
    local txtvalue="$2"

    _debug "fulldomain: $fulldomain"
    _debug "txtvalue: $txtvalue"

    if ! _get_root "$fulldomain"; then
        _err "Cannot find root domain for $fulldomain"
        return 1
    fi
    _debug "domain: $_domain, subdomain: $_sub_domain"

    # 1. Найти record_id для записи (с учётом поддомена)
    local record_id
    if ! record_id=$(_dynadot_find_record_id "$_domain" "$_sub_domain" "$txtvalue"); then
        _err "Failed to find TXT record for $fulldomain"
        return 1
    fi
    _debug "Found record_id: $record_id"

    # 2. Удалить запись по ID
    if ! _dynadot_remove_by_id "$_domain" "$record_id"; then
        return 1
    fi

    _info "TXT record for $fulldomain removed successfully."
    return 0
}

# ========== Вспомогательная функция вызова API ==========
_dynadot_rest() {
    local command="$1"
    local data="$2"
    response=""   # глобальная переменная для возврата ответа

    if [ -z "$DYNADOT_API_KEY" ] || [ -z "$DYNADOT_API_SECRET" ]; then
        _err "DYNADOT_API_KEY and DYNADOT_API_SECRET environment variables are required."
        return 1
    fi

    # Кодируем ключи для безопасной вставки в тело запроса
    local enc_key enc_secret
    enc_key=$(_url_encode "$DYNADOT_API_KEY")
    enc_secret=$(_url_encode "$DYNADOT_API_SECRET")

    data="${data}&key=${enc_key}&secret=${enc_secret}"

    local url="https://api.dynadot.com/api/v2/${command}"

    _debug "Calling Dynadot API: ${command} (domain: ${_domain:-unknown})"
    _debug "Data length: $(printf '%s' "$data" | wc -c)"

    # Отключаем DEBUG, чтобы данные (включая ключи) не попали в лог curl/wget
    local _save_debug=""
    local _save_debug_was_set=false
    if [ "${DEBUG+x}" ]; then
        _save_debug_was_set=true
        _save_debug="$DEBUG"
    fi
    DEBUG=''

    response=$(_post "$data" "$url" "" "POST" "application/x-www-form-urlencoded")
    local ret=$?

    # Восстанавливаем DEBUG
    if [ "$_save_debug_was_set" = true ]; then
        DEBUG="$_save_debug"
    else
        unset DEBUG
    fi

    # Проверяем код возврата HTTP-запроса
    if [ $ret -ne 0 ]; then
        _err "HTTP request failed (curl/wget error)"
        return 1
    fi

    if [ -z "$response" ]; then
        _err "Empty response from Dynadot API"
        return 1
    fi

    _debug "Response: $response"

    # Проверка статуса ответа API
    local api_status
    api_status=$(_json_get "$response" "status")
    if [ "$api_status" = "error" ]; then
        _err "Dynadot API returned an error: $response"
        return 1
    fi

    # Если статус не "success" и не "error" – тоже считаем ошибкой
    if [ "$api_status" != "success" ]; then
        _err "Unexpected API status: $api_status"
        return 1
    fi

    return 0
}

# ========== Поиск record_id для TXT-записи ==========
_dynadot_find_record_id() {
    local domain="$1"
    local subdomain="$2"
    local txtvalue="$3"

    local data="domain=$(_url_encode "$domain")"
    if [ -n "$subdomain" ]; then
        data="${data}&subdomain=$(_url_encode "$subdomain")"
    fi

    if ! _dynadot_rest "list_dns" "$data"; then
        _err "Failed to list DNS records"
        return 1
    fi

    # Декодируем массив dns_list в переменные вида dns_list_0_record_id, dns_list_count и т.д.
    if ! _json_decode "$response" "dns_list"; then
        _err "Failed to decode DNS list response"
        return 1
    fi

    # Безопасно извлекаем количество записей
    eval "count=\"\$dns_list_count\""
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
        _debug "No DNS records found."
        return 1
    fi

    local i=0
    while [ $i -lt "$count" ]; do
        # Безопасное извлечение полей записи
        eval "record_id=\"\$dns_list_${i}_record_id\""
        eval "record_type=\"\$dns_list_${i}_record_type\""
        eval "record_value=\"\$dns_list_${i}_record_value\""
        eval "rec_sub=\"\$dns_list_${i}_subdomain\""

        # Добавлена проверка поддомена, чтобы не задеть чужие записи
        if [ -n "$record_id" ] && [ "$record_type" = "TXT" ] && [ "$record_value" = "$txtvalue" ] && [ "$rec_sub" = "$subdomain" ]; then
            echo "$record_id"
            return 0
        fi
        i=$((i + 1))
    done

    _debug "TXT record with value '$txtvalue' not found (subdomain: '$subdomain')."
    return 1
}

# ========== Удаление записи по ID ==========
_dynadot_remove_by_id() {
    local domain="$1"
    local record_id="$2"

    local data="domain=$(_url_encode "$domain")&record_id0=$record_id"
    _dynadot_rest "remove_dns" "$data"
}
#!/usr/bin/env sh
# ~/.acme.sh/dnsapi/dns_dynadot.sh
# Управление TXT-записями через Dynadot API v2
#
# Требуемые переменные окружения (или будут сохранены в account.conf):
# export DYNADOT_API_KEY="ваш_api_key"
# export DYNADOT_API_SECRET="ваш_secret_key"

########  Public functions #####################

#Usage: add  _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_dynadot_add() {
  fulldomain="$1"
  txtvalue="$2"

  # Загружаем или запрашиваем ключи
  DYNADOT_API_KEY="${DYNADOT_API_KEY:-$(_readaccountconf_mutable DYNADOT_API_KEY)}"
  DYNADOT_API_SECRET="${DYNADOT_API_SECRET:-$(_readaccountconf_mutable DYNADOT_API_SECRET)}"

  if [ -z "$DYNADOT_API_KEY" ] || [ -z "$DYNADOT_API_SECRET" ]; then
    DYNADOT_API_KEY=""
    DYNADOT_API_SECRET=""
    _err "You didn't specify Dynadot API key and secret yet."
    _err "Please set DYNADOT_API_KEY and DYNADOT_API_SECRET and try again."
    return 1
  fi

  # Сохраняем ключи в конфиг аккаунта
  _saveaccountconf_mutable DYNADOT_API_KEY "$DYNADOT_API_KEY"
  _saveaccountconf_mutable DYNADOT_API_SECRET "$DYNADOT_API_SECRET"

  _debug "First detect the root zone"
  if ! _get_root "$fulldomain"; then
    _err "Cannot find root domain for $fulldomain"
    return 1
  fi
  _debug "domain: $_domain"
  _debug "sub_domain: $_sub_domain"

  # Кодируем параметры для API
  domain_enc=$(_url_encode "$_domain")
  txt_enc=$(_url_encode "$txtvalue")

  data="domain=${domain_enc}&record_type=TXT&record=${txt_enc}"
  if [ -n "$_sub_domain" ]; then
    sub_enc=$(_url_encode "$_sub_domain")
    data="${data}&subdomain=${sub_enc}"
  fi

  _info "Adding TXT record"
  if _dynadot_rest "add_dns" "$data"; then
    _info "Added, OK"
    _sleep 30
    return 0
  else
    _err "Add TXT record error."
    return 1
  fi
}

#Usage: rm  _acme-challenge.www.domain.com   "XKrxpRBosdIKFzxW_CT3KLZNf6q0HG9i01zxXp5CPBs"
dns_dynadot_rm() {
  fulldomain="$1"
  txtvalue="$2"

  DYNADOT_API_KEY="${DYNADOT_API_KEY:-$(_readaccountconf_mutable DYNADOT_API_KEY)}"
  DYNADOT_API_SECRET="${DYNADOT_API_SECRET:-$(_readaccountconf_mutable DYNADOT_API_SECRET)}"

  if [ -z "$DYNADOT_API_KEY" ] || [ -z "$DYNADOT_API_SECRET" ]; then
    DYNADOT_API_KEY=""
    DYNADOT_API_SECRET=""
    _err "You didn't specify Dynadot API key and secret yet."
    _err "Please set DYNADOT_API_KEY and DYNADOT_API_SECRET and try again."
    return 1
  fi

  _saveaccountconf_mutable DYNADOT_API_KEY "$DYNADOT_API_KEY"
  _saveaccountconf_mutable DYNADOT_API_SECRET "$DYNADOT_API_SECRET"

  if ! _get_root "$fulldomain"; then
    _err "Cannot find root domain for $fulldomain"
    return 1
  fi

  # Ищем record_id существующей записи
  if ! record_id=$(_dynadot_find_record_id "$_domain" "$_sub_domain" "$txtvalue"); then
    _err "Failed to find TXT record"
    return 1
  fi
  _debug "Found record_id: $record_id"

  # Удаляем запись
  if _dynadot_remove_by_id "$_domain" "$record_id"; then
    _info "Removed, OK"
    return 0
  else
    _err "Remove TXT record error."
    return 1
  fi
}

####################  Private functions below ##################################
# _acme-challenge.www.domain.com
# returns
#  _sub_domain=_acme-challenge.www
#  _domain=domain.com
_get_root() {
  domain="$1"
  i=1
  p=1

  while true; do
    h=$(printf "%s" "$domain" | cut -d . -f "$i"-100)
    _debug "trying root: $h"
    if [ -z "$h" ]; then
      # not valid
      return 1
    fi

    # Пытаемся получить информацию о домене через API
    # В случае успеха _dynadot_rest возвращает 0
    if _dynadot_rest "get_domain_info" "domain=$(_url_encode "$h")" 2>/dev/null; then
      # Проверим, что ответ содержит статус success (на случай ложных срабатываний)
      if _json_contains "$response" "success" "status"; then
        _domain="$h"
        if [ "$h" = "$domain" ]; then
          _sub_domain=""
        else
          _cutlength=$((${#domain} - ${#h} - 1))
          _sub_domain=$(printf "%s" "$domain" | cut -c "1-$_cutlength")
        fi
        return 0
      fi
    fi
    p=$i
    i=$(_math "$i" + 1)
  done
  return 1
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

  _debug "Calling Dynadot API: ${command}"
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
    eval "record_id=\"\$dns_list_${i}_record_id\""
    eval "record_type=\"\$dns_list_${i}_record_type\""
    eval "record_value=\"\$dns_list_${i}_record_value\""
    eval "rec_sub=\"\$dns_list_${i}_subdomain\""

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

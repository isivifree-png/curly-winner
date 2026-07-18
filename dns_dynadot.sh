#!/usr/bin/env sh
# ~/.acme.sh/dnsapi/dns_dynadot.sh
# Управление TXT-записями через Dynadot API v2
#
# Требуемые переменные окружения (будут сохранены в account.conf после первого использования):
# export DYNADOT_API_KEY="ваш_api_key"
# export DYNADOT_API_SECRET="ваш_secret_key"

########  Public functions #####################

dns_dynadot_add() {
  fulldomain="$1"
  txtvalue="$2"

  DYNADOT_API_KEY="${DYNADOT_API_KEY:-$(_readaccountconf_mutable DYNADOT_API_KEY)}"
  DYNADOT_API_SECRET="${DYNADOT_API_SECRET:-$(_readaccountconf_mutable DYNADOT_API_SECRET)}"

  if [ -z "$DYNADOT_API_KEY" ] || [ -z "$DYNADOT_API_SECRET" ]; then
    DYNADOT_API_KEY=""
    DYNADOT_API_SECRET=""
    _err "You didn't specify Dynadot API key and secret yet."
    return 1
  fi

  _saveaccountconf_mutable DYNADOT_API_KEY "$DYNADOT_API_KEY"
  _saveaccountconf_mutable DYNADOT_API_SECRET "$DYNADOT_API_SECRET"

  _debug "First detect the root zone"
  if ! _get_root "$fulldomain"; then
    _err "Cannot find root domain for $fulldomain"
    return 1
  fi
  _debug "domain: $_domain"
  _debug "sub_domain: $_sub_domain"

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

dns_dynadot_rm() {
  fulldomain="$1"
  txtvalue="$2"

  DYNADOT_API_KEY="${DYNADOT_API_KEY:-$(_readaccountconf_mutable DYNADOT_API_KEY)}"
  DYNADOT_API_SECRET="${DYNADOT_API_SECRET:-$(_readaccountconf_mutable DYNADOT_API_SECRET)}"

  if [ -z "$DYNADOT_API_KEY" ] || [ -z "$DYNADOT_API_SECRET" ]; then
    _err "API credentials missing"
    return 1
  fi

  _saveaccountconf_mutable DYNADOT_API_KEY "$DYNADOT_API_KEY"
  _saveaccountconf_mutable DYNADOT_API_SECRET "$DYNADOT_API_SECRET"

  if ! _get_root "$fulldomain"; then
    _err "Cannot find root domain for $fulldomain"
    return 1
  fi

  if ! record_id=$(_dynadot_find_record_id "$_domain" "$_sub_domain" "$txtvalue"); then
    _err "Failed to find TXT record"
    return 1
  fi
  _debug "Found record_id: $record_id"

  if _dynadot_remove_by_id "$_domain" "$record_id"; then
    _info "Removed, OK"
    return 0
  else
    _err "Remove TXT record error."
    return 1
  fi
}

####################  Private functions ##################################

_get_root() {
  domain="$1"
  local search="$domain"
  if echo "$search" | grep -q '^_acme-challenge\.'; then
    search=$(echo "$search" | sed 's/^_acme-challenge\.//')
  fi

  local parts=$(echo "$search" | tr '.' '\n' | grep -c .)
  _debug "domain parts count: $parts"
  if [ "$parts" -le 2 ]; then
    _domain="$search"
  else
    _domain=$(echo "$search" | awk -F. '{print $(NF-1)"."$NF}')
  fi

  if [ "$_domain" = "$domain" ]; then
    _sub_domain=""
  else
    local cutlength=$((${#domain} - ${#_domain} - 1))
    _sub_domain=$(printf "%s" "$domain" | cut -c "1-$cutlength")
  fi
  _debug "determined root: $_domain, subdomain: $_sub_domain"
  return 0
}

# ---------- HTTP-клиент с гарантированными таймаутами через _post ----------
_dynadot_rest() {
  local command="$1"
  local data="$2"
  response=""

  if [ -z "$DYNADOT_API_KEY" ] || [ -z "$DYNADOT_API_SECRET" ]; then
    _err "API credentials missing"
    return 1
  fi

  local enc_key enc_secret
  enc_key=$(_url_encode "$DYNADOT_API_KEY")
  enc_secret=$(_url_encode "$DYNADOT_API_SECRET")
  data="${data}&key=${enc_key}&secret=${enc_secret}"

  local url="https://api.dynadot.com/api/v2/${command}"

  # Покажем выполняемую команду для диагностики
  _debug "EXECUTING: _post \"$data\" \"$url\" \"\" \"POST\" \"application/x-www-form-urlencoded\""

  # Убедимся, что заданы таймауты через _CURL_OPTS
  export _CURL_OPTS="${_CURL_OPTS:---connect-timeout 10 --max-time 60}"

  # Используем встроенную функцию acme.sh, которая автоматически применит таймауты
  response=$(_post "$data" "$url" "" "POST" "application/x-www-form-urlencoded")
  local ret=$?

  if [ $ret -ne 0 ]; then
    _err "HTTP request failed with return code $ret"
    return 1
  fi

  if [ -z "$response" ]; then
    _err "Empty response from Dynadot API"
    return 1
  fi

  _debug "Response: $response"

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

  if ! _json_decode "$response" "dns_list"; then
    _err "Failed to decode DNS list response"
    return 1
  fi

  eval "count=\"\${dns_list_count}\""
  if [ -z "$count" ] || [ "$count" -eq 0 ]; then
    _debug "No DNS records found."
    return 1
  fi

  local i=0
  while [ $i -lt "$count" ]; do
    eval "record_id=\"\${dns_list_${i}_record_id}\""
    eval "record_type=\"\${dns_list_${i}_record_type}\""
    eval "record_value=\"\${dns_list_${i}_record_value}\""
    eval "rec_sub=\"\${dns_list_${i}_subdomain}\""

    if [ -n "$record_id" ] && [ "$record_type" = "TXT" ] && [ "$record_value" = "$txtvalue" ] && [ "$rec_sub" = "$subdomain" ]; then
      echo "$record_id"
      return 0
    fi
    i=$((i + 1))
  done

  _debug "TXT record with value '$txtvalue' not found (subdomain: '$subdomain')."
  return 1
}

_dynadot_remove_by_id() {
  local domain="$1"
  local record_id="$2"

  local data="domain=$(_url_encode "$domain")&record_id0=$(_url_encode "$record_id")"
  _dynadot_rest "remove_dns" "$data"
}

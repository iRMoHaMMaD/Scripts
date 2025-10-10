#!/usr/bin/env bash
set -Eeuo pipefail
COUNT="${COUNT:-13}"
WARMUP="${WARMUP:-3}"
DELAY="${DELAY:-1s}"
THRESHOLD_MS="${THRESHOLD_MS:-2}"
CF_API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"

ENV_FILE="/etc/cf-orchestrator/config.env"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

FQDN="${1:-${CF_FQDN:-}}"
IP_FILE="${2:-${IPLIST_FILE:-}}"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "ERROR: CLOUDFLARE_API_TOKEN is not set."
  exit 1
fi
if [[ -z "$FQDN" || -z "$IP_FILE" || ! -f "$IP_FILE" ]]; then
  echo "Usage: $0 <fqdn> <ip_list_file>"
  exit 1
fi

cf_api() {
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sS -X "$method" -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" --data "$data" "${CF_API_BASE}${path}"
  else
    curl -sS -X "$method" -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" "${CF_API_BASE}${path}"
  fi
}

get_zone_id_for_fqdn() {
  local fqdn="$1" page=1 per_page=50 best_zone="" best_id=""
  while :; do
    local resp success count
    resp="$(cf_api GET "/zones?per_page=${per_page}&page=${page}")"
    success="$(jq -r '.success' <<<"$resp")"
    [[ "$success" == "true" ]] || { echo "ERROR: Unable to list zones" >&2; return 1; }
    count="$(jq -r '.result | length' <<<"$resp")"
    (( count == 0 )) && break
    for i in $(seq 0 $((count-1))); do
      local zname zid
      zname="$(jq -r ".result[$i].name" <<<"$resp")"
      zid="$(jq -r ".result[$i].id" <<<"$resp")"
      if [[ "$fqdn" == "$zname" || "$fqdn" == *".${zname}" ]]; then
        if [[ ${#zname} -gt ${#best_zone} ]]; then best_zone="$zname"; best_id="$zid"; fi
      fi
    done
    local tpages; tpages="$(jq -r '.result_info.total_pages' <<<"$resp")"
    (( page >= tpages )) && break
    page=$((page+1))
  done
  [[ -n "$best_id" ]] || { echo "ERROR: No matching zone for $fqdn" >&2; return 1; }
  echo "$best_zone|$best_id"
}

get_dns_record() { cf_api GET "/zones/$1/dns_records?type=A&name=$2"; }
create_dns_record() {
  cf_api POST "/zones/$1/dns_records" "$(jq -n --arg type A --arg name "$2" --arg content "$3" \
    --argjson ttl 1 --argjson proxied true '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')"
}
update_dns_record() {
  local ttl="$6"; [[ "$ttl" == "auto" ]] && ttl=1
  cf_api PUT "/zones/$1/dns_records/$2" "$(jq -n --arg type A --arg name "$3" --arg content "$4" \
    --argjson ttl "$ttl" --argjson proxied "$5" '{type:$type,name:$name,content:$content,ttl:$ttl,proxied:$proxied}')"
}

measure_ip_udp() {
  local ip="$1" warm="${WARMUP:-3}" total="${COUNT:-13}" delay="${DELAY:-1s}"
  (( total <= warm )) && total=$((warm+1))
  local main_count=$(( total - warm ))
  nping --udp -c "$warm" --delay "$delay" "$ip" >/dev/null 2>&1 || true
  local out; out="$(nping --udp -c "$main_count" --delay "$delay" "$ip" 2>&1 || true)"
  local rcvd; rcvd="$(grep -Eo 'Rcvd: *[0-9]+' <<<"$out" | awk '{print $2}' | tail -n1)"
  [[ -z "$rcvd" || "$rcvd" -eq 0 ]] && { echo "inf"; return 0; }
  local avg; avg="$(grep -Eo 'Avg rtt: *[0-9]+(\.[0-9]+)?ms' <<<"$out" | tail -n1 | sed -E 's/.*Avg rtt:\s*([0-9.]+)ms/\1/')"
  [[ -n "$avg" ]] && printf "%.3f\n" "$avg" || echo "inf"
}

best_ip=""; best_avg="inf"; declare -A ip_avg
echo "== Measuring candidate IPs..."
while IFS= read -r ip; do
  ip="${ip%%[[:space:]]*}"; [[ -z "$ip" ]] && continue
  echo "   -> $ip"
  avg="$(measure_ip_udp "$ip")"
  ip_avg["$ip"]="$avg"
  echo "      avg(ms) = $avg"
  if [[ "$avg" != "inf" ]]; then
    if [[ "$best_avg" == "inf" ]] || awk "BEGIN{exit !($avg < $best_avg)}"; then
      best_avg="$avg"; best_ip="$ip"
    fi
  fi
done < "$IP_FILE"

[[ -z "$best_ip" || "$best_avg" == "inf" ]] && { echo "ERROR: No reachable IPs."; exit 1; }
echo "== Best candidate: $best_ip (avg ${best_avg}ms)"

echo "== Resolving Cloudflare zone and record..."
zone_pair="$(get_zone_id_for_fqdn "$FQDN")"
zone_id="${zone_pair##*|}"
rec_json="$(get_dns_record "$zone_id" "$FQDN")"
[[ "$(jq -r '.success' <<<"$rec_json")" == "true" ]] || { echo "ERROR: DNS query failed"; exit 1; }

rec_count="$(jq -r '.result | length' <<<"$rec_json")"
if (( rec_count == 0 )); then
  echo "== No A record; creating $FQDN -> $best_ip ..."
  create_resp="$(create_dns_record "$zone_id" "$FQDN" "$best_ip")"
  [[ "$(jq -r '.success' <<<"$create_resp")" == "true" ]] && { echo "Created A $FQDN -> $best_ip"; exit 0; } \
    || { echo "ERROR: create failed: $(jq -r '.errors|tostring' <<<"$create_resp")"; exit 1; }
fi

record_id="$(jq -r '.result[] | select(.type=="A" and .name=="'"$FQDN"'") | .id' <<<"$rec_json" | head -n1)"
current_ip="$(jq -r '.result[] | select(.type=="A" and .name=="'"$FQDN"'") | .content' <<<"$rec_json" | head -n1)"
proxied="$(jq -r '.result[] | select(.type=="A" and .name=="'"$FQDN"'") | .proxied' <<<"$rec_json" | head -n1)"
ttl="$(jq -r '.result[] | select(.type=="A" and .name=="'"$FQDN"'") | .ttl' <<<"$rec_json" | head -n1)"

[[ -z "$record_id" || -z "$current_ip" ]] && { echo "ERROR: record id/ip missing"; exit 1; }
echo "== Current DNS: $FQDN -> $current_ip (proxied=$proxied ttl=$ttl)"

if ! grep -qx "$current_ip" "$IP_FILE"; then
  echo "== Current IP not in list. Updating to $best_ip ..."
  upd="$(update_dns_record "$zone_id" "$record_id" "$FQDN" "$best_ip" "$proxied" "$ttl")"
  [[ "$(jq -r '.success' <<<"$upd")" == "true" ]] && { echo "Updated A $FQDN -> $best_ip"; exit 0; } \
    || { echo "ERROR: update failed: $(jq -r '.errors|tostring' <<<"$upd")"; exit 1; }
fi

curr_avg="${ip_avg[$current_ip]:-}"
if [[ -z "$curr_avg" ]]; then
  echo "== Measuring current IP..."
  curr_avg="$(measure_ip_udp "$current_ip")"
fi
echo "== Current avg: ${curr_avg}ms ; Best avg: ${best_avg}ms ; Threshold: ${THRESHOLD_MS}ms"

should_update="no"
if [[ "$curr_avg" == "inf" ]]; then
  should_update="yes"
else
  cmp="$(awk -v c="$curr_avg" -v b="$best_avg" -v t="$THRESHOLD_MS" 'BEGIN{diff=c-b; print (diff>=t)?"yes":"no"}')"
  [[ "$cmp" == "yes" ]] && should_update="yes"
fi

if [[ "$should_update" == "yes" ]]; then
  echo "== Updating to better IP: $best_ip"
  upd="$(update_dns_record "$zone_id" "$record_id" "$FQDN" "$best_ip" "$proxied" "$ttl")"
  [[ "$(jq -r '.success' <<<"$upd")" == "true" ]] && echo "Updated A $FQDN -> $best_ip" \
    || { echo "ERROR: update failed: $(jq -r '.errors|tostring' <<<"$upd")"; exit 1; }
else
  echo "== No update needed (improvement < ${THRESHOLD_MS}ms)."
fi

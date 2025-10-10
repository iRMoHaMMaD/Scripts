#!/usr/bin/env bash
set -euo pipefail

# نیازمندی‌ها: ip, iptables, (اختیاری: wg)
command -v ip >/dev/null || { echo "ip not found"; exit 1; }
command -v iptables >/dev/null || { echo "iptables not found"; exit 1; }

# پیدا کردن اینترفیس خروجی اصلی (Interface پشت Default Route)
get_main_if() {
  # تلاش اول: default route
  local dev
  dev=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [[ -n "${dev:-}" ]]; then
    echo "$dev"; return
  fi
  # تلاش دوم: یک مقصد عمومی
  dev=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [[ -n "${dev:-}" ]]; then
    echo "$dev"; return
  fi
  echo "نتوانستم اینترفیس اصلی را پیدا کنم." >&2
  exit 1
}

MAIN_IF=$(get_main_if)
echo "Main interface: $MAIN_IF"

# جمع‌آوری نام اینترفیس‌های WireGuard
WG_IFS=""

# 1) اگر ابزار wg هست و اینترفیس فعالی وجود دارد:
if command -v wg >/dev/null 2>&1; then
  active_wg=$(wg show interfaces 2>/dev/null | tr ' ' '\n' | grep -E '^wg[0-9]+' || true)
  if [[ -n "${active_wg:-}" ]]; then
    WG_IFS="$WG_IFS $active_wg"
  fi
fi

# 2) از روی فایل‌های کانفیگ هم اضافه کن (در صورت نبود/تکمیل)
if [[ -d /etc/wireguard ]]; then
  config_wg=$(ls -1 /etc/wireguard/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//' || true)
  if [[ -n "${config_wg:-}" ]]; then
    WG_IFS="$WG_IFS $config_wg"
  fi
fi

# تمیز کردن لیست و یکتا کردن
WG_IFS=$(printf "%s\n" $WG_IFS | awk 'NF' | sort -u)

if [[ -z "${WG_IFS:-}" ]]; then
  echo "هیچ اینترفیس وایرگاردی پیدا نشد." >&2
  exit 1
fi

echo "WireGuard interfaces: $WG_IFS"

# helper: افزودن قانون اگر وجود ندارد
ipt_add_once() {
  local table=""
  if [[ $1 == "-t" ]]; then
    table="-t $2"
    shift 2
  fi
  local chain=$1; shift
  # بررسی وجود قانون
  if iptables $table -C "$chain" "$@" 2>/dev/null; then
    return 0
  fi
  iptables $table -A "$chain" "$@"
}

# روشن کردن IP forwarding (درجا)
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# قانون NAT (یک‌بار برای اینترفیس اصلی)
# iptables -t nat -A POSTROUTING -o ens3 -j MASQUERADE
ipt_add_once -t nat POSTROUTING -o "$MAIN_IF" -j MASQUERADE

# قوانین FORWARD برای هر wgX:
for WG in $WG_IFS; do
  # iptables -A FORWARD -i wg1 -o ens3 -j ACCEPT
  ipt_add_once FORWARD -i "$WG" -o "$MAIN_IF" -j ACCEPT

  # iptables -A FORWARD -i ens3 -o wg1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ipt_add_once FORWARD -i "$MAIN_IF" -o "$WG" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
done

echo "تمام شد."
echo "Main IF: $MAIN_IF"
echo "WG IFs : $WG_IFS"

# نکته‌های اختیاری:
# - برای پایدار کردن قوانین پس از ریبوت:
#   sudo apt-get update && sudo apt-get install -y iptables-persistent
#   sudo netfilter-persistent save
# - اگر IPv6 هم لازم داری، معادل ip6tables را اضافه کن و net.ipv6.conf.all.forwarding=1 را فعال کن.

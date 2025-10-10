#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ENV_FILE="/etc/cf-orchestrator/config.env"
# مقادیر حساس و تنظیمات را از ENV بخوان
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# مسیرهای بکاپ
SRC_DIR="/root/WGDashboard/src/db"
WG_DIR="/etc/wireguard"

# متغیرهای ضروری
: "${BOT_TOKEN:?BOT_TOKEN must be set in $ENV_FILE}"
: "${CHAT_ID:?CHAT_ID must be set in $ENV_FILE}"

CAPTION_LABEL="${CAPTION_LABEL:-GE1}"
CAPTION="📌 بکاپ جدید ایجاد شد ${CAPTION_LABEL} ✅"
BACKUP_FILE="/tmp/backup_$(date +'%Y%m%d_%H%M%S').zip"

# گزینه‌های curl (Timeout/Retry و …)
CURL_OPTS=(
  --silent --show-error --fail
  --max-time 120
  --retry 3
  --retry-delay 2
  --retry-connrefused
)

# اگر پروکسی HTTP با احراز هویت دارید، از آن استفاده کن
# مثال PROXY_URL: http://user:pass@HOST:3128
if [[ -n "${PROXY_URL:-}" ]]; then
  CURL_OPTS+=( --proxy "$PROXY_URL" )
fi

# ساخت بکاپ (بی‌صدا و سریع). دقت: /etc/wireguard شامل کلیدهای خصوصی است.
# اگر نمی‌خواهید کلیدها ارسال شوند، WG_DIR را حذف کنید یا zip را رمزگذاری کنید.
zip -rq "$BACKUP_FILE" "$SRC_DIR" "$WG_DIR"

# ارسال بکاپ به تلگرام
SEND_RESULT="$(
  curl "${CURL_OPTS[@]}" -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
    -F "chat_id=${CHAT_ID}" \
    -F "document=@${BACKUP_FILE}" \
    -F "caption=${CAPTION}"
)"

# بررسی نتیجه
if [[ "$SEND_RESULT" == *'"ok":true'* ]]; then
  echo "Backup sent."
  rm -f "${BACKUP_FILE}"
else
  echo "Backup send failed:"
  echo "$SEND_RESULT"
  exit 1
fi

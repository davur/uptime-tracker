#!/bin/sh
# report_uptime.sh
# Reads boot session intervals from sessions.log and sends each as a
# separate report with "from" and "to" epoch timestamps.
# Retries unsent sessions on subsequent runs (handles offline days).
#
# Cron entry: 30 6 * * * /opt/iot/report_uptime.sh
#
# Dependencies: curl, awk, sort, date

LOG_DIR="/var/lib/iot-uptime"
SESSIONS_LOG="$LOG_DIR/sessions.log"
SENT_LOG="$LOG_DIR/sent.log"    # boot epochs already successfully reported
PENDING_DIR="$LOG_DIR/pending"  # one JSON file per pending session

SERVER_URL="${IOT_SERVER_URL:-https://your-api-id.execute-api.us-east-1.amazonaws.com/prod/report}"
DEVICE_ID="${IOT_DEVICE_ID:-$(cat /etc/machine-id 2>/dev/null || hostname)}"
API_KEY="${IOT_API_KEY:-}"

mkdir -p "$PENDING_DIR"
touch "$SENT_LOG"

# ---------------------------------------------------------------------------
# Step 1: Create a pending JSON file for each unsent session
# ---------------------------------------------------------------------------
if [ -f "$SESSIONS_LOG" ]; then
    while read -r boot_epoch to_epoch; do
        [ -z "$boot_epoch" ] && continue

        # Skip if already sent
        if grep -qx "$boot_epoch" "$SENT_LOG"; then
            continue
        fi

        PENDING_FILE="$PENDING_DIR/${boot_epoch}.json"
        if [ ! -f "$PENDING_FILE" ]; then
            printf '{"device_id":"%s","from":%s,"to":%s}' \
                "$DEVICE_ID" "$boot_epoch" "$to_epoch" > "$PENDING_FILE"
        else
            # Update the "to" time in case this is the current active session
            # and we are retrying with a more recent snapshot
            awk -v to="$to_epoch" '{
                sub(/"to":[0-9]+/, "\"to\":"to)
                print
            }' "$PENDING_FILE" > "$PENDING_FILE.tmp"
            mv "$PENDING_FILE.tmp" "$PENDING_FILE"
        fi
    done < "$SESSIONS_LOG"
fi

# ---------------------------------------------------------------------------
# Step 2: Send all pending reports
# ---------------------------------------------------------------------------
for PENDING_FILE in "$PENDING_DIR"/*.json; do
    [ -f "$PENDING_FILE" ] || continue

    BOOT_EPOCH=$(basename "$PENDING_FILE" .json)
    PAYLOAD=$(cat "$PENDING_FILE")

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 15 \
        -X POST "$SERVER_URL" \
        -H "Content-Type: application/json" \
        ${API_KEY:+-H "x-api-key: $API_KEY"} \
        -d "$PAYLOAD" 2>/dev/null)

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
        echo "$BOOT_EPOCH" >> "$SENT_LOG"
        rm -f "$PENDING_FILE"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) sent session $BOOT_EPOCH (HTTP $HTTP_CODE)"
    else
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) failed session $BOOT_EPOCH (HTTP $HTTP_CODE) - will retry"
        if [ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "422" ]; then
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) dropping session $BOOT_EPOCH due to client error"
            rm -f "$PENDING_FILE"
        fi
    fi
done

# ---------------------------------------------------------------------------
# Step 3: Prune sessions.log — remove sent sessions older than 30 days
# ---------------------------------------------------------------------------
CUTOFF_EPOCH=$(( $(date -u +%s) - 2592000 ))  # 30 days in seconds

if [ -f "$SESSIONS_LOG" ]; then
    awk -v cutoff="$CUTOFF_EPOCH" '$1 >= cutoff' "$SESSIONS_LOG" > "$SESSIONS_LOG.tmp"
    mv "$SESSIONS_LOG.tmp" "$SESSIONS_LOG"
fi

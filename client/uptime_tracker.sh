#!/bin/sh
# uptime_tracker.sh
# Tracks uptime as epoch-based intervals (boot_time -> now).
# Run hourly via cron to keep the "to" timestamp current.
# On each run it upserts the current boot session's interval in sessions.log.
#
# Cron entry: 0 * * * * /opt/iot/uptime_tracker.sh
#
# Log format: <boot_epoch> <current_epoch>
# One line per boot session, updated in-place each hour.

LOG_DIR="/var/lib/iot-uptime"
SESSIONS_LOG="$LOG_DIR/sessions.log"

mkdir -p "$LOG_DIR"

NOW_EPOCH=$(date -u +%s)
UPTIME_SECS=$(awk '{print int($1)}' /proc/uptime)

# Derive the epoch when this boot started
BOOT_EPOCH=$(( NOW_EPOCH - UPTIME_SECS ))

# Upsert this boot session: if a line starting with BOOT_EPOCH exists, update
# the "to" timestamp; otherwise append a new line.
if [ -f "$SESSIONS_LOG" ] && grep -q "^$BOOT_EPOCH " "$SESSIONS_LOG"; then
    # Update existing session's end time in-place using awk
    awk -v boot="$BOOT_EPOCH" -v now="$NOW_EPOCH" \
        '$1 == boot { $2 = now } { print }' \
        "$SESSIONS_LOG" > "$SESSIONS_LOG.tmp"
    mv "$SESSIONS_LOG.tmp" "$SESSIONS_LOG"
else
    echo "$BOOT_EPOCH $NOW_EPOCH" >> "$SESSIONS_LOG"
fi

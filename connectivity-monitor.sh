#!/usr/bin/env bash
# =============================================================================
# Connectivity Monitor
# Test elke 5 seconden de netwerkverbinding en log de status.
# =============================================================================

LOG_FILE="/var/log/tempdog/connectivity.log"
PING_TARGET="${1:-$(ip route | grep default | awk '{print $3}')}"
INTERVAL=5

mkdir -p "$(dirname "$LOG_FILE")"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Connectivity monitor gestart (target: $PING_TARGET)" | tee -a "$LOG_FILE"

last_status="unknown"
last_success=""
fail_count=0

while true; do
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if ping -c 1 -W 2 "$PING_TARGET" > /dev/null 2>&1; then
        last_success="$timestamp"

        if [[ "$last_status" != "up" ]]; then
            echo "$timestamp - ONLINE (was offline for $fail_count checks)" | tee -a "$LOG_FILE"
            fail_count=0
        fi
        last_status="up"
    else
        ((fail_count++))

        if [[ "$last_status" != "down" ]]; then
            echo "$timestamp - OFFLINE (last success: $last_success)" | tee -a "$LOG_FILE"
        elif (( fail_count % 12 == 0 )); then
            # Log elke minuut als nog steeds offline
            echo "$timestamp - STILL OFFLINE ($fail_count checks, ~$((fail_count * INTERVAL))s)" | tee -a "$LOG_FILE"
        fi
        last_status="down"
    fi

    sleep "$INTERVAL"
done

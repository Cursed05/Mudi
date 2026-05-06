#!/bin/sh
#
# wg-rotation.sh - ПРОСТА РОТАЦІЯ (Версія 9.0)
#

STATE_FILE="/tmp/wg_rotation_state.json"
LOG_FILE="/var/log/wg_rotation.log"
POLL_INTERVAL=1

. /lib/functions/gl_util.sh 2>/dev/null

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

show_on_screen() {
    local text="$1"
    if type mcu_send_message >/dev/null 2>&1; then
        mcu_send_message "WG: $text"
    else
        echo "{\"display_mask\": \"1f\", \"custom_en\": \"1\", \"content\": \"WG: $text\"}" > /tmp/mcu_message 2>/dev/null
        killall -17 e750-mcu 2>/dev/null || true
    fi
}

get_ui_profiles() {
    uci show wireguard | grep "\.peer_.*\.name=" | cut -d'=' -f2 | tr -d "'" | awk '!seen[$0]++' | xargs echo
}

switch_to_profile() {
    local target_name="$1"
    target_name=$(echo "$target_name" | tr -d '\r\n')
    log ">>> РОТАЦІЯ: $target_name"
    show_on_screen "Connecting..."

    local p_id=$(uci show wireguard | grep "\.peer_.*\.name='$target_name'" | head -n 1 | cut -d'.' -f2)
    if [ -z "$p_id" ]; then return 1; fi

    local g_id=$(uci -q get wireguard.$p_id.group_id)

    # Проста класична заміна через UCI
    uci set wireguard.global.group_id="$g_id"
    uci set wireguard.global.peer_id="$p_id"
    uci set wireguard.global.name="$target_name"
    uci set wireguard.global.enable='1'
    uci set network.wgclient.config="$p_id"
    uci set network.wgclient.disabled='0'
    uci commit wireguard
    uci commit network

    log "✓ Встановлено (через UCI): $target_name"
    show_on_screen "$target_name"
    return 0
}

read_state() {
    [ ! -f "$STATE_FILE" ] && echo "last='' visited=''" && return
    local last=$(grep -o '"last":"[^"]*"' "$STATE_FILE" | cut -d'"' -f4)
    local visited=$(grep -o '"visited":\[[^]]*\]' "$STATE_FILE" | sed 's/.*\[\(.*\)\].*/\1/' | tr -d '"')
    echo "last='$last' visited='$visited'"
}

write_state() {
    local last="$1"; local visited="$2"; local visited_json=""
    IFS=','
    for v in $visited; do
        [ -n "$visited_json" ] && visited_json="$visited_json,"
        visited_json="$visited_json\"$v\""
    done
    unset IFS
    echo "{\"last\":\"$last\",\"visited\":[$visited_json],\"time\":\"$(date -Iseconds)\"}" > "$STATE_FILE"
}

check_trigger() {
    if [ -f "/tmp/switch_tunnel" ]; then
        rm -f /tmp/switch_tunnel
        return 0
    fi
    return 1
}

contains() {
    local list="$1"; local item="$2"
    for x in $list; do [ "$x" = "$item" ] && return 0; done
    return 1
}

main() {
    log "========== СТАРТ  =========="
    echo "1" > /tmp/switch_tunnel

    while true; do
        if check_trigger; then
            profiles=$(get_ui_profiles)
            [ -z "$profiles" ] && sleep 5 && continue

            eval $(read_state)
            next=""
            for p in $profiles; do
                if ! contains "$visited" "$p"; then next="$p"; break; fi
            done

            if [ -z "$next" ]; then
                log "Коло завершено."
                show_on_screen "Loop Done! Going again!"
                sleep 2
                visited=""
                next=$(echo "$profiles" | awk '{print $1}')
            fi

            if switch_to_profile "$next"; then
                [ -z "$visited" ] && visited="$next" || visited="$visited $next"
                write_state "$next" "$visited"
            fi
        fi
        sleep "$POLL_INTERVAL"
    done
}

main "$@"

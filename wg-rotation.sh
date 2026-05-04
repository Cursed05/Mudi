#!/bin/sh
#
# wg-rotation.sh - KERNEL HOT-SWAP (Версія 8.0)
#

STATE_FILE="/tmp/wg_rotation_state.json"
LOG_FILE="/var/log/wg_rotation.log"
ACCEL_THRESHOLD=50
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

    local p_id=$(uci show wireguard | grep "\.peer_.*\.name='$target_name'" | head -n 1 | cut -d'.' -f2)
    if [ -z "$p_id" ]; then return 1; fi

    local g_id=$(uci -q get wireguard.$p_id.group_id)
    local address=$(uci -q get wireguard.$p_id.address_v4)
    [ -z "$address" ] && address=$(uci -q get wireguard.$p_id.address)
    local priv_key=$(uci -q get wireguard.$p_id.private_key)
    local pub_key=$(uci -q get wireguard.$p_id.public_key)
    local endpoint=$(uci -q get wireguard.$p_id.end_point)
    local allowed_ips=$(uci -q get wireguard.$p_id.allowed_ips)
    [ -z "$allowed_ips" ] && allowed_ips="0.0.0.0/0, ::/0"

    # 1. Перевірка статусу
    local is_up=$(ifstatus wgclient 2>/dev/null | grep '"up": true')
    local net_disabled=$(uci -q get network.wgclient.disabled)

    if [ -z "$is_up" ] || [ "$net_disabled" = "1" ]; then
        log "VPN вимкнений. Повний запуск..."
        show_on_screen "Waking VPN..."
        uci set wireguard.global.group_id="$g_id"
        uci set wireguard.global.peer_id="$p_id"
        uci set wireguard.global.name="$target_name"
        uci set wireguard.global.enable='1'
        uci set network.wgclient.config="$p_id"
        uci set network.wgclient.disabled='0'
        uci commit wireguard
        uci commit network
        /etc/init.d/wireguard restart >/dev/null 2>&1
        sleep 5
        /sbin/ifup wgclient >/dev/null 2>&1
        
        local wait=0
        while ! (ifstatus wgclient 2>/dev/null | grep -q '"up": true') && [ $wait -lt 30 ]; do
            sleep 1; wait=$((wait + 1))
        done
        [ $wait -ge 30 ] && log "VPN FAIL TO WAKE" && return 1
    fi

    # 2. ШВИДКА РОТАЦІЯ (HOT-SWAP)
    local REAL_IFACE="wgclient"
    log "Hot-swap на $target_name (IP: $address)..."
    
    echo "$priv_key" > /tmp/wg_priv
    # Видаляємо старого піра і додаємо нового
    wg set "$REAL_IFACE" private-key /tmp/wg_priv peer "$pub_key" endpoint "$endpoint" allowed-ips "$allowed_ips"
    rm -f /tmp/wg_priv

    # КРИТИЧНО ПРАВИЛЬНИЙ IP: Міняємо внутрішню адресу інтерфейсу на ту, яку хоче новий сервер
    # Це робиться без перезавантаження заліза, тому Ethernet не повинен падати.
    if [ -n "$address" ]; then
        ip addr flush dev "$REAL_IFACE" 2>/dev/null
        ip addr add "$address" dev "$REAL_IFACE"
    fi

    # Синхронізація UCI
    uci set wireguard.global.peer_id="$p_id"
    uci set wireguard.global.name="$target_name"
    uci set network.wgclient.config="$p_id"
    uci commit wireguard
    uci commit network
    
    log "✓ Встановлено: $target_name"
    show_on_screen "$target_name"
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
    local accel_path="/dev/iio:device0/in_accel_x_raw"
    if [ -f "$accel_path" ]; then
        local cur=$(cat "$accel_path" 2>/dev/null || echo 0)
        local last=$(cat /tmp/last_accel 2>/dev/null || echo 0)
        local diff=$((cur - last)); [ $diff -lt 0 ] && diff=$((-diff))
        if [ "$diff" -gt "$ACCEL_THRESHOLD" ]; then
            echo "$cur" > /tmp/last_accel
            return 0
        fi
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

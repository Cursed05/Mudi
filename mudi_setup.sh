#!/bin/sh

# ==============================================================================
# GL.iNet Mudi (GL-E750 / GL-E750V2) Initial Setup Script - v2
# Description: Automated setup for 4G Modem, Wireless, and OLED Screen.
# ==============================================================================

echo "======================================================="
echo "   GL.iNet Mudi - Automated Configuration Script"
echo "======================================================="
echo ""
echo "=> STEP 1: INITIAL DATA GATHERING"
echo "Please answer the following questions before we apply any changes."
echo "--------------------------------------------------------"

# 1. Gather Wi-Fi info
ROUTER_SSID="Alibabay"
echo -n "[Wi-Fi] Enter Router Name / SSID (default: $ROUTER_SSID): "
read input_ssid
ROUTER_SSID=${input_ssid:-$ROUTER_SSID}

WIFI_PASS="Aloha123"
echo -n "[Wi-Fi] Enter new Wi-Fi password (default: $WIFI_PASS): "
read input_pass
WIFI_PASS=${input_pass:-$WIFI_PASS}

echo -n "[Wi-Fi] Do you need the 5GHz network enabled? (y/N): "
read enable_5g

# 2. Gather Modem info
echo ""
echo "[Modem] Often Auto-APN fails for certain SIM cards (e.g. in Ukraine)."
echo "If your SIM card didn't connect previously, enter your operator's APN."
APN_DEFAULT="internet"
echo -n "[Modem] Enter APN (default: $APN_DEFAULT, leave blank for auto): "
read input_apn
if [ -z "$input_apn" ]; then
    input_apn=$APN_DEFAULT
fi

# 2. Gather Screen info
echo -n "[OLED] Enter the screen timeout in seconds (default 10): "
read screen_timeout
screen_timeout=${screen_timeout:-10}

echo "[OLED] Do you want to hide the Wi-Fi password from the OLED screen for security?"
echo -n "Hide Password? (Y/n): "
read hide_pwd
hide_pwd=${hide_pwd:-Y}

# 3. Gather Time/Timezone info
echo ""
echo "[System] Time synchronization (NTP) will be configured."
TZ_DEFAULT="Europe/Kyiv"
echo -n "[System] Enter Timezone (default: $TZ_DEFAULT): "
read input_tz
TZ_INPUT=${input_tz:-$TZ_DEFAULT}

# Map common timezones to their exact POSIX strings for OpenWrt
if [ "$TZ_INPUT" = "Europe/Kyiv" ]; then
    POSIX_TZ='EET-2EEST,M3.5.0/3,M10.5.0/4'
elif [ "$TZ_INPUT" = "Europe/Warsaw" ]; then
    POSIX_TZ='CET-1CEST,M3.5.0,M10.5.0/3'
else
    # Fallback generic (user might have to refine manually if not Kyiv/Warsaw)
    POSIX_TZ='EET-2EEST,M3.5.0/3,M10.5.0/4' 
fi

# 4. Reboot request
echo ""
echo "[System] To ensure GL.iNet applies all Modem and OLED settings smoothly,"
echo "it is required to reboot the router after configuration."
echo -n "Reboot router automatically at the end? (Y/n): "
read do_reboot
do_reboot=${do_reboot:-Y}

# 5. Blue-merle installation
echo ""
echo "[Add-on] The 'blue-merle' package enhances privacy with IMEI/MAC randomization."
echo "Note: The router will need to connect to the internet during setup to download it."
echo -n "Install blue-merle automatically before reboot? (y/N): "
read install_merle
install_merle=${install_merle:-N}

echo ""
echo "======================================================="
echo "=> STEP 2: APPLYING CONFIGURATION"
echo "======================================================="

# --- MODEM ---
echo "[1/4] Configuring Modem (AutoSetup SIM Card, APN & Roaming)..."

# Derive the bus ID from interface naming convention
# modem_1_1_2 -> bus 1-1.2, modem_1_1 -> bus 1-1
# We check the ifname reference from the IPv6 interface (modem_1_1_2_6 -> @modem_1_1_2)
BASE_IF=$(uci show network | grep "ifname='@modem" | sed "s/.*@//" | sed "s/'//" | head -n 1)
if [ -z "$BASE_IF" ]; then
    # Fallback: find any modem interface directly
    BASE_IF=$(uci show network | grep "=interface" | grep "modem" | grep -v "_6=" | cut -d. -f2 | cut -d= -f1 | head -n 1)
fi
if [ -z "$BASE_IF" ]; then
    # Last fallback: strip _6 suffix from IPv6 interface
    IPV6_IF=$(uci show network | grep "=interface" | grep "modem" | cut -d. -f2 | cut -d= -f1 | head -n 1)
    BASE_IF=$(echo "$IPV6_IF" | sed 's/_6$//')
fi

echo "Base modem interface: $BASE_IF"

# Convert interface name to USB bus ID: modem_1_1_2 -> 1-1.2
BUS_ID=$(echo "$BASE_IF" | sed 's/^modem_//' | sed 's/_/-/' | sed 's/_/./g')
echo "Derived USB bus ID: $BUS_ID"

# Create the primary modem interface if it doesn't exist
if ! uci -q get network.${BASE_IF} >/dev/null 2>&1; then
    echo "Creating missing primary modem interface: $BASE_IF"
    uci set network.${BASE_IF}=interface
    uci set network.${BASE_IF}.proto='qmi'
    uci set network.${BASE_IF}.device='/dev/cdc-wdm0'
    uci set network.${BASE_IF}.pdptype='ipv4v6'
    uci set network.${BASE_IF}.disabled='0'
fi

# Configure APN
uci -q set network.${BASE_IF}.disabled='0'
if [ "$input_apn" = "auto" ] || [ "$input_apn" = "AUTO" ]; then
    uci -q set network.${BASE_IF}.apn_auto='1'
else
    uci -q set network.${BASE_IF}.apn_auto='0'
    uci -q set network.${BASE_IF}.apn="${input_apn}"
fi

# Also enable the IPv6 interface if it exists
IPV6_IF="${BASE_IF}_6"
if uci -q get network.${IPV6_IF} >/dev/null 2>&1; then
    uci -q set network.${IPV6_IF}.disabled='0'
fi

uci commit network

# Run gl_modem connect-auto (simulates the "Auto Setup" button)
echo "Running gl_modem connect-auto on bus $BUS_ID..."
gl_modem -B "$BUS_ID" connect-auto 2>/dev/null &
MODEM_PID=$!
sleep 5
echo "gl_modem triggered (PID: $MODEM_PID). Modem will finish connecting after reboot."
uci commit network 2>/dev/null

# --- WIRELESS ---
echo "[2/3] Configuring Wireless 2.4GHz / 5GHz..."
for radio in $(uci show wireless | grep -E "=wifi-device" | cut -d. -f2 | cut -d= -f1); do
    band=$(uci -q get wireless.${radio}.band)
    
    # Minimize TX Power
    uci -q set wireless.${radio}.txpower='1'

    # Find ALL interfaces (wifi-iface) that belong to this radio
    ifaces=$(uci show wireless | grep "device='${radio}'" | cut -d. -f2)
    
    for iface in $ifaces; do
        # Set SSID, Password and AES encryption for every interface on this radio
        uci -q set wireless.${iface}.ssid="${ROUTER_SSID}"
        uci -q set wireless.${iface}.encryption='psk2+ccmp'
        uci -q set wireless.${iface}.key="${WIFI_PASS}"
        
        # Aggressively enable or disable 5GHz on the interface level
        if echo "$band" | grep -iqE "5g|a|ac|ax"; then
            if [ "$enable_5g" = "y" ] || [ "$enable_5g" = "Y" ]; then
                uci -q set wireless.${iface}.disabled='0'
            else
                uci -q set wireless.${iface}.disabled='1'
            fi
        else
            # Ensure 2.4GHz is always enabled
            uci -q set wireless.${iface}.disabled='0'
        fi
    done
    
    # Also disable the radio device itself just in case
    if echo "$band" | grep -iqE "5g|a|ac|ax"; then
        if [ "$enable_5g" = "y" ] || [ "$enable_5g" = "Y" ]; then
            uci -q set wireless.${radio}.disabled='0'
        else
            uci -q set wireless.${radio}.disabled='1'
        fi
    else
        uci -q set wireless.${radio}.disabled='0'
    fi
done
uci commit wireless

# --- OLED ---
echo "[3/3] Configuring OLED Screen Settings..."
uci -q set glconfig.mcu.display_time="${screen_timeout}"

if [ "$hide_pwd" = "y" ] || [ "$hide_pwd" = "Y" ]; then
    uci -q set glconfig.mcu.show_pwd='0'
else
    uci -q set glconfig.mcu.show_pwd='1'
fi
uci commit glconfig

# --- TIME & SYSTEM ---
echo "[4/4] Configuring Time Synchronization ($TZ_INPUT)..."
uci -q set system.@system[0].zonename="${TZ_INPUT}"
uci -q set system.@system[0].timezone="${POSIX_TZ}"

# Ensure NTP client is enabled and uses standard pools
uci -q set system.ntp.enable_server='0'
uci -q delete system.ntp.server
uci -q add_list system.ntp.server='0.openwrt.pool.ntp.org'
uci -q add_list system.ntp.server='1.openwrt.pool.ntp.org'
uci -q add_list system.ntp.server='2.openwrt.pool.ntp.org'
uci commit system

echo ""
echo "======================================================="
echo "                 Setup Finished!                       "
echo "======================================================="

# --- BLUE-MERLE ---
if [ "$install_merle" = "Y" ] || [ "$install_merle" = "y" ]; then
    echo "======================================================="
    echo "          Installing blue-merle privacy addon           "
    echo "======================================================="
    echo "Waiting for internet connection (up to 60 seconds)..."
    
    internet_ok=false
    for i in $(seq 1 30); do
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
            internet_ok=true
            break
        fi
        sleep 2
    done
    
    if [ "$internet_ok" = "true" ]; then
        echo "Internet connection established! Downloading latest release..."
        # Query Github API for latest IPK url
        LATEST_URL=$(curl -s https://api.github.com/repos/srlabs/blue-merle/releases/latest | grep "browser_download_url" | grep "\\.ipk" | cut -d '"' -f 4 | head -n 1)
        
        if [ -n "$LATEST_URL" ]; then
            echo "URL found: $LATEST_URL"
            curl -sL -o /tmp/blue-merle.ipk "$LATEST_URL"
            if [ -f /tmp/blue-merle.ipk ]; then
                echo "Installing package via opkg..."
                opkg update
                opkg install /tmp/blue-merle.ipk
                rm -f /tmp/blue-merle.ipk
                echo "blue-merle installed successfully!"
            else
                echo "Error: Failed to download blue-merle.ipk"
            fi
        else
            echo "Error: Could not retrieve download URL from GitHub API."
        fi
    else
        echo "Timeout: No internet connection detected. Skipping blue-merle."
    fi
    echo ""
fi

if [ "$do_reboot" = "Y" ] || [ "$do_reboot" = "y" ]; then
    echo "Rebooting in 3 seconds... Your SSH connection will close."
    sleep 3
    reboot
else
    # Only reload services manually if not rebooting, otherwise we risk SSH drop
    echo "Applying services manually (You might lose connection temporarily)..."
    /etc/init.d/network restart 2>/dev/null
    wifi reload 2>/dev/null
    /etc/init.d/e750_mcu restart 2>/dev/null || /etc/init.d/mcu restart 2>/dev/null
    echo "Done! Please reboot manually if anything seems odd."
fi

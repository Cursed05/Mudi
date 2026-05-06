uci set mcu.global.main_enabled='1'
uci set mcu.global.wifi_2g_enabled='1'
uci set mcu.global.wifi_5g_enabled='0'
uci set mcu.global.wifi_password_enabled='0'
uci set mcu.global.lan_enabled='0'
uci set mcu.global.vpn_enabled='1'
uci set mcu.global.custom_enabled='0'

uci commit mcu

# Застосувати зміни (перезапустити службу екрану)
/etc/init.d/e750_mcu restart 2>/dev/null || /etc/init.d/mcu restart 2>/dev/null

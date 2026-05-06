uci set vpnpolicy.global.kill_switch='1'
uci commit vpnpolicy
/etc/init.d/vpnpolicy restart
/etc/init.d/firewall restart
#!/bin/sh
# flint-diag: read-only snapshot of a Flint 4 (4.11.0 beta1) for SFP wired-Mesh debugging.
# Changes nothing. Passwords, keys and onboarding codes are redacted.
#
# Usage: sh flint-diag.sh [--capture]
#   --capture  also sniff IEEE 1905 and STP frames for 20 s (needs tcpdump)
# Writes /tmp/flint-diag-<host>-<time>.txt and prints its path.

OUT=/tmp/flint-diag-$(cat /proc/sys/kernel/hostname)-$(date +%Y%m%d-%H%M%S).txt

section() { printf '\n===== %s\n' "$1"; }
run() { printf '$ %s\n' "$*"; sh -c "$*" 2>&1; }
redact() { sed -E "s/((key|password|passwd|psk|sae_password|secret|onbd_code|code|token)[a-z_]*=)'?[^' ]*'?/\1<redacted>/Ig"; }

{
	section "identity"
	run "cat /etc/glversion; cat /etc/openwrt_release | grep -E 'RELEASE|REVISION'"
	run "uptime; cat /tmp/sysinfo/board_name"

	section "mesh config and status"
	run "uci show gl-mesh" | redact
	run "ubus call gl-mesh status"
	run "uci -q get glconfig.general.mode"
	run "ps w | grep -E 'gl-mesh|i1905d|beerocks|wld|amxrt' | grep -v grep"

	section "network config"
	run "uci show network" | redact
	run "cat /etc/flint-sfp-uplink.state 2>/dev/null || echo 'flint-sfp-uplink: not installed/applied'"

	section "switch and SFP"
	run "swconfig dev switch0 show | grep -E '^(VLAN|Port)|vlan:|ports:|link:|pvid:'"
	run "swconfig dev switch0 port 4 show | grep -vE 'Pkts|Octets|Bytes|Frame|Err|Drop|Collision|Pause|Undersize|Oversize|Fragment|Jabber|Filtered'"
	run "dmesg | grep -iE 'sfp|yt92|serdes|eth1' | tail -40"

	section "links and bridge"
	run "ip -br link"
	run "ip -br addr"
	run "for d in eth1 eth1.1 eth1.2 eth2; do [ -e /sys/class/net/\$d ] && echo \"\$d carrier=\$(cat /sys/class/net/\$d/carrier 2>/dev/null) oper=\$(cat /sys/class/net/\$d/operstate)\"; done"
	run "echo stp_state=\$(cat /sys/class/net/br-lan/bridge/stp_state) root=\$(cat /sys/class/net/br-lan/bridge/root_id) self=\$(cat /sys/class/net/br-lan/bridge/bridge_id)"
	run "for p in /sys/class/net/br-lan/brif/*; do echo \"\$(basename \$p) state=\$(cat \$p/state) designated_bridge=\$(cat \$p/designated_bridge) designated_root=\$(cat \$p/designated_root)\"; done"

	section "mesh logs"
	run "tail -n 150 /var/log/gl-mesh 2>/dev/null"
	run "tail -n 80 /var/log/i1905d.log 2>/dev/null"
	run "logread | grep -iE 'mesh|1905|beerocks|dynbh|backhaul|flint-sfp' | tail -60"

	if [ "$1" = "--capture" ]; then
		# 'any' can't filter on Ethernet addresses, so capture per wired device.
		# eth1.1 = LAN switch VLAN (SFP when set to LAN), eth1.2 = SFP as secondwan/uplink, eth2 = copper WAN.
		if command -v tcpdump >/dev/null; then
			for dev in eth1.1 eth1.2 eth2; do
				[ -e "/sys/class/net/$dev" ] || continue
				section "10 s capture on $dev: IEEE 1905 (0x893a), STP BPDUs, LLDP"
				run "timeout 10 tcpdump -n -e -i $dev 'ether proto 0x893a or ether dst 01:80:c2:00:00:00 or ether dst 01:80:c2:00:00:0e' -c 40 2>&1 | grep -E '^[0-9]'"
			done
		else
			echo "tcpdump not installed (apk add tcpdump)"
		fi
	fi
} > "$OUT" 2>&1

echo "$OUT"

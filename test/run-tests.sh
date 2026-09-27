#!/usr/bin/env bash
# Host tests for flint-sfp-uplink.sh against an anonymised Flint 4 network config.
# Runs on a PC, never on a router: router tools (ubus, tcpdump, ip, bridge) are stubbed.
# Needs a host build of OpenWrt uci: HOST_UCI=/path/to/uci (with its libs on LD_LIBRARY_PATH).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../flint-sfp-uplink.sh"
HOST_UCI=${HOST_UCI:?set HOST_UCI to a host uci binary}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/config" "$T/save" "$T/bin"
cp "$HERE/fixtures/network" "$T/config/network"
cp "$HERE/fixtures/gl-mesh" "$T/config/gl-mesh"
cp "$HERE/fixtures/board_special" "$T/config/board_special"

# Stubs: record calls instead of touching the host.
cat > "$T/bin/logger" <<'EOF'
#!/bin/sh
echo "logger $*" >> "$CALLS"
EOF
cat > "$T/ubus" <<'EOF'
#!/bin/sh
echo "ubus $*" >> "$CALLS"
if [ "$*" = "call gl-mesh status" ] && [ -n "$CNTR_MAC" ]; then
	printf '{\n\t"agent_state": "OPERATIONAL",\n\t"cntr_mac": "%s"\n}\n' "$CNTR_MAC"
fi
EOF
cat > "$T/tcpdump" <<'EOF'
#!/bin/sh
echo "tcpdump $*" >> "$CALLS"
[ -n "$TCPDUMP_OUT" ] && cat "$TCPDUMP_OUT"
exit 0
EOF
cat > "$T/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >> "$CALLS"
case "$*" in
	*" master br-lan") mkdir -p "$SYS_NET/br-lan/brif"; touch "$SYS_NET/br-lan/brif/$3" ;;
	*nomaster) rm -rf "$SYS_NET/br-lan/brif/$3" ;;
	*" down") mkdir -p "$SYS_NET/$3"; echo 0x1002 > "$SYS_NET/$3/flags" ;;
	*" up") mkdir -p "$SYS_NET/$3"; echo 0x1003 > "$SYS_NET/$3/flags" ;;
esac
EOF
cat > "$T/bridge" <<'EOF'
#!/bin/sh
[ -n "$BRIDGE_OUT" ] && cat "$BRIDGE_OUT"
exit 0
EOF
chmod +x "$T/ip" "$T/bridge"
chmod +x "$T/tcpdump"
mkdir -p "$T/sys/eth1.2"
cat > "$T/gl-mesh" <<'EOF'
#!/bin/sh
case "$1" in
	running) [ "${GL_MESH_RUNNING:-1}" = 1 ] ;;
	*) echo "gl-mesh $1" >> "$CALLS" ;;
esac
EOF
chmod +x "$T/bin/logger" "$T/ubus" "$T/gl-mesh"

export CALLS="$T/calls.log" PATH="$T/bin:$PATH" NO_LOCK=1
export UCI="$HOST_UCI -c $T/config -t $T/save"
export UBUS="$T/ubus" GL_MESH_INIT="$T/gl-mesh" STATE="$T/state"
export PROC_SECONDWAN="$T/nonexistent" BOARD_JSON="$T/nonexistent"
export TCPDUMP="$T/tcpdump" SYS_NET="$T/sys" STP_WAIT=2
export CONF="$T/conf"
export IP="$T/ip" BRIDGE="$T/bridge" WSTATE="$T/wstate" COPPER_WAIT=2
echo glinet,gl-be14000 > "$T/board_name"; echo 4.11.0 > "$T/glversion"
export BOARD_NAME_FILE="$T/board_name" GLVERSION_FILE="$T/glversion" GSTATE="$T/gstate" GUARD_RECHECK=1

u() { $UCI -q get "$1"; }
us() { $UCI set "$1=$2"; $UCI commit "${1%%.*}"; }
ud() { $UCI -q delete "$1"; $UCI commit "${1%%.*}"; }
run() { : > "$CALLS"; sh "$SCRIPT" "$@" > "$T/out" 2>&1; }

PASS=0 FAIL=0
check() {
	local desc=$1; shift
	if "$@"; then PASS=$((PASS + 1)); echo "ok   $desc"
	else FAIL=$((FAIL + 1)); echo "FAIL $desc"; sed 's/^/     | /' "$T/out"; fi
}
eq() { [ "$1" = "$2" ] || { echo "     expected '$2', got '$1'"; return 1; }; }
called() { grep -q "$1" "$CALLS"; }
not_called() { ! grep -q "$1" "$CALLS"; }

echo "# 1. Router mode (Mesh off): nothing changes"
run sync
check "wan stays on eth2" eq "$(u network.wan.device)" eth2
check "secondwan stays enabled" eq "$(u network.secondwan.disabled)" ""
check "no state written" test ! -f "$STATE"
check "no network reload" not_called "network reload"

echo "# 2. Node mode, plan only"
us gl-mesh.@base[0].enabled 1
us gl-mesh.@base[0].mode agent
run plan
check "plan lists wan change" grep -q "network.wan.device='eth1.2'" "$T/out"
check "plan lists secondwan disable" grep -q "network.secondwan.disabled='1'" "$T/out"
check "plan writes nothing" eq "$(u network.wan.device)" eth2
check "plan saves no state" test ! -f "$STATE"

echo "# 3. Node mode, sync"
run sync
check "wan moved to SFP (eth1.2)" eq "$(u network.wan.device)" eth1.2
check "secondwan disabled" eq "$(u network.secondwan.disabled)" 1
check "switch VLAN for SFP untouched" eq "$(u network.vlan_secondwan.ports)" "4 5t"
check "original wan saved" grep -q "orig_wan_device='eth2'" "$STATE"
check "network reloaded" called "ubus call network reload"
check "gl-mesh restarted" called "gl-mesh restart"

echo "# 4. Sync again is a no-op"
run sync
check "no reload when nothing changed" not_called "network reload"
check "no gl-mesh restart" not_called "gl-mesh restart"

echo "# 5. GL role-switch reset (ports back to factory), then hotplug sync"
us network.wan.device eth2
ud network.secondwan.disabled
run sync
check "re-applied wan on SFP" eq "$(u network.wan.device)" eth1.2
check "re-disabled secondwan" eq "$(u network.secondwan.disabled)" 1
check "state still records factory wan" grep -q "orig_wan_device='eth2'" "$STATE"

echo "# 6. At boot gl-mesh is not running yet: no restart"
us network.wan.device eth2
GL_MESH_RUNNING=0 run sync
check "applied" eq "$(u network.wan.device)" eth1.2
check "gl-mesh not restarted" not_called "gl-mesh restart"

echo "# 7. Back to Router mode: revert"
us gl-mesh.@base[0].mode controller
run sync
check "wan restored to eth2" eq "$(u network.wan.device)" eth2
check "secondwan re-enabled" eq "$(u network.secondwan.disabled)" ""
check "state removed" test ! -f "$STATE"

echo "# 8. Revert leaves values changed by someone else alone"
us gl-mesh.@base[0].mode agent
run sync
us network.wan.device eth9
us gl-mesh.@base[0].enabled 0
run sync
check "user's wan device kept" eq "$(u network.wan.device)" eth9
check "secondwan still restored" eq "$(u network.secondwan.disabled)" ""
us network.wan.device eth2

echo "# 9. Mesh disabled while in node mode also reverts"
us gl-mesh.@base[0].enabled 1
run sync
us gl-mesh.@base[0].enabled 0
run sync
check "wan restored" eq "$(u network.wan.device)" eth2

echo "# 10. install / uninstall into a staging root"
PREFIX="$T/root" run install --force
check "script installed" test -x "$T/root/usr/sbin/flint-sfp-uplink"
check "init hook START=14" grep -q "^START=14" "$T/root/etc/init.d/flint-sfp-uplink"
check "hotplug hook installed" test -f "$T/root/etc/hotplug.d/iface/98-flint-sfp-uplink"
PREFIX="$T/root" run uninstall
check "hooks removed" test ! -e "$T/root/etc/init.d/flint-sfp-uplink" -a ! -e "$T/root/etc/hotplug.d/iface/98-flint-sfp-uplink"

echo "# 11. Hotplug hook filters events"
PREFIX="$T/root" run install --force
hook="$T/root/etc/hotplug.d/iface/98-flint-sfp-uplink"
check "ignores lan ifup" sh -c "ACTION=ifup INTERFACE=lan sh '$hook'; [ \$? = 0 ]"
check "hook targets wan/secondwan only" grep -q 'wan|secondwan' "$hook"

echo "# 12. STP safety check before install"
# BPDU lines as captured on a node's SFP (eth1.2), with MAC addresses anonymised.
DIRECT='02:49:45.018917 02:00:00:00:00:01 > 01:80:c2:00:00:00, 802.3, length 38: LLC, dsap STP (0x42) Individual, ssap STP (0x42) Command, ctrl 0x03: STP 802.1d, Config, Flags [none], bridge-id 0000.02:00:00:00:00:01.8001, length 35
	message-age 0.00s, max-age 8.00s, hello-time 1.00s, forwarding-delay 2.00s
	root-id 0000.02:00:00:00:00:01, root-pathcost 0'
SWITCH_STP='02:24:16.068939 02:00:00:00:00:a6 > 01:80:c2:00:00:00, 802.3, length 39: LLC, dsap STP (0x42) Individual, ssap STP (0x42) Command, ctrl 0x03: STP 802.1w, Rapid STP, Flags [Proposal, Learn, Forward], bridge-id 8000.02:00:00:00:00:a4.8003, length 36
	message-age 1.00s, max-age 20.00s, hello-time 2.00s, forwarding-delay 15.00s
	root-id 0000.02:00:00:00:00:01, root-pathcost 2000'
SWITCH_ROOT='00:00:01.000000 02:00:00:00:00:a6 > 01:80:c2:00:00:00, 802.3, length 39: LLC, dsap STP (0x42) Individual, ssap STP (0x42) Command, ctrl 0x03: STP 802.1w, Rapid STP, Flags [Proposal, Learn, Forward], bridge-id 8000.02:00:00:00:00:a4.8003, length 36
	root-id 8000.02:00:00:00:00:a4, root-pathcost 0'
cap() { printf '%s\n' "$1" > "$T/cap"; export TCPDUMP_OUT="$T/cap"; }
us gl-mesh.@base[0].mode agent; us gl-mesh.@base[0].enabled 1
rm -f "$STATE"; us network.wan.device eth2; ud network.secondwan.disabled

cap "$DIRECT"; export CNTR_MAC=02:00:00:00:00:01
run check
check "direct link / transparent switch: check passes" grep -q "OK - STP messages come straight from the main router" "$T/out"

cap "$SWITCH_STP"
run check
check "switch running STP: check fails" grep -q "FAILED" "$T/out"
check "... and names the switch problem" grep -q "switch running its own STP" "$T/out"
PREFIX="$T/root2" run install
check "install refused" test ! -e "$T/root2/usr/sbin/flint-sfp-uplink"
check "config untouched when refused" eq "$(u network.wan.device)" eth2

export TCPDUMP_OUT=
run check
check "no STP at all: check fails" grep -q "no STP messages" "$T/out"
check "... and warns about loops" grep -q "network loop" "$T/out"

cap "$DIRECT"; export CNTR_MAC=
run check
check "not joined yet, direct link: passes on priority-0 root" grep -q "OK - STP messages come straight from a Mesh controller" "$T/out"
cap "$SWITCH_ROOT"
run check
check "not joined, switch is its own root: fails" grep -q "FAILED" "$T/out"

cap "$DIRECT"; export CNTR_MAC=02:00:00:00:00:01
TCPDUMP=/nonexistent/tcpdump run check
check "no tcpdump: fails safe" grep -q "tcpdump is not available" "$T/out"
SYS_NET="$T/nosys" run check
check "missing SFP interface: fails" grep -q "does not exist yet" "$T/out"

PREFIX="$T/root3" run install
check "install proceeds when check passes" test -x "$T/root3/usr/sbin/flint-sfp-uplink"
cap "$SWITCH_STP"
PREFIX="$T/root4" run install --force
check "--force skips the check" test -x "$T/root4/usr/sbin/flint-sfp-uplink"

echo "# 13. Optional 10G WAN port as a link-checked LAN port on the node"
member() { test -e "$T/sys/br-lan/brif/eth2"; }
carrier() { mkdir -p "$T/sys/eth2"; echo "$1" > "$T/sys/eth2/carrier"; }
ports() { $UCI -q get network.@device[0].ports; }
PC='10:00:00.000001 3c:ec:ef:11:22:33 > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 60: Request who-has 192.168.8.1 tell 192.168.8.50, length 46'
LOOP_NO_STP='10:00:00.000001 02:00:00:00:00:01 > 01:80:c2:00:00:13, ethertype IEEE1905.1 (0x893a), length 851:
10:00:00.100000 02:00:00:00:00:01 > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 60: Request who-has 192.168.8.119 tell 192.168.8.1, length 46'
LOOP_STP='10:00:00.000001 02:00:00:00:00:01 > 01:80:c2:00:00:13, ethertype IEEE1905.1 (0x893a), length 851:
10:00:00.200000 02:00:00:00:00:01 > 01:80:c2:00:00:00, 802.3, length 38: LLC, dsap STP (0x42) Individual, ssap STP (0x42) Command, ctrl 0x03: STP 802.1d, Config, Flags [none], bridge-id 0000.02:00:00:00:00:01.8001, length 35'
KNOWN_MAC='10:00:00.000001 02:00:00:00:00:c1 > ff:ff:ff:ff:ff:ff, ethertype ARP (0x0806), length 60: Request who-has 192.168.8.1 tell 192.168.8.114, length 46'
printf '%s\n' "02:00:00:00:00:c1 dev eth1.2 master br-lan" "3c:ec:ef:aa:bb:cc dev eth1.1 master br-lan" > "$T/fdb"; export BRIDGE_OUT="$T/fdb"
export CNTR_MAC=02:00:00:00:00:01
rm -f "$STATE" "$CONF" "$T/wstate"; us network.wan.device eth2; ud network.secondwan.disabled
us gl-mesh.@base[0].mode agent; us gl-mesh.@base[0].enabled 1

# earlier versions put eth2 into the br-lan config; that must be cleaned up
run sync
$UCI add_list network.@device[0].ports=eth2; $UCI commit network; echo "added_copper='1'" >> "$STATE"
run sync
check "legacy config entry for eth2 removed" sh -c "! echo '$(ports)' | grep -qw eth2"
check "... and flag cleared" grep -q "added_copper='0'" "$STATE"

run wan-lan on
rm -f "$T/sys/eth2/carrier"; run copper-watch-once
check "port admin-down (no carrier file): brought up for link detection" called "ip link set eth2 up"
check "... but not bridged" sh -c '! test -e "$0/sys/br-lan/brif/eth2"' "$T"
carrier 0; run copper-watch-once
check "no cable: port stays out" sh -c '! test -e "$0/sys/br-lan/brif/eth2"' "$T"
check "... state is down" eq "$(cat "$T/wstate")" down

cap "$PC"; carrier 1; run copper-watch-once
check "PC plugged in: bridged" member
check "... judged safe" eq "$(cat "$T/wstate")" safe
rm -f "$T/sys/br-lan/brif/eth2"; run copper-watch-once
check "re-added after br-lan rebuild" member
check "... without re-checking" not_called "tcpdump"

carrier 0; run copper-watch-once
check "unplugged: removed from bridge" sh -c '! test -e "$0/sys/br-lan/brif/eth2"' "$T"

cap "$LOOP_NO_STP"; carrier 1; run copper-watch-once
check "cable back to main network, no STP: kept out" sh -c '! test -e "$0/sys/br-lan/brif/eth2"' "$T"
check "... logged as loop risk" grep -q "loop risk" "$T/out"
cap "$PC"; run copper-watch-once
check "stays out until unplugged" sh -c '! test -e "$0/sys/br-lan/brif/eth2"' "$T"

carrier 0; run copper-watch-once; cap "$LOOP_STP"; carrier 1; run copper-watch-once
check "cable back to main network with STP: bridged" member
check "... STP will block the extra path" grep -q "STP present" "$T/out"

carrier 0; run copper-watch-once; cap "$KNOWN_MAC"; carrier 1; run copper-watch-once
check "MAC already reached over the SFP, no STP: kept out" sh -c '! test -e "$0/sys/br-lan/brif/eth2"' "$T"

carrier 0; run copper-watch-once; cap "$PC"; carrier 1; run copper-watch-once
check "PC again: bridged" member
run wan-lan off
check "wan-lan off: removed" sh -c '! test -e "$0/sys/br-lan/brif/eth2"' "$T"
check "... and port set back down" called "ip link set eth2 down"

run wan-lan on; run copper-watch-once
check "on again: bridged" member
us gl-mesh.@base[0].mode controller; run copper-watch-once
check "router mode: removed" sh -c '! test -e "$0/sys/br-lan/brif/eth2"' "$T"
us gl-mesh.@base[0].mode agent

rm -f "$T/wstate"; export CNTR_MAC=; carrier 1; cap "$PC"; run copper-watch-once
check "main router unknown: kept out" sh -c '! test -e "$0/sys/br-lan/brif/eth2"' "$T"
export CNTR_MAC=02:00:00:00:00:01

PREFIX="$T/root5" run install --force
check "init script is procd with watcher" grep -q "procd_set_param command /usr/sbin/flint-sfp-uplink watch" "$T/root5/etc/init.d/flint-sfp-uplink"
check "... watcher always runs (guard needs it)" sh -c "! grep -q 'COPPER_LAN' '$T/root5/etc/init.d/flint-sfp-uplink'"
run wan-lan bogus
check "wan-lan rejects bad argument" grep -q "usage" "$T/out"

run copper-lan on
check "old copper-lan alias still works" grep -q "COPPER_LAN=1" "$CONF"
run wan-lan off
echo "# 14. Runtime SFP guard"
guard_brif() { mkdir -p "$T/sys/br-lan/brif/eth1.2"; echo "$1" > "$T/sys/br-lan/brif/eth1.2/designated_bridge"; }
sfp_member() { test -e "$T/sys/br-lan/brif/eth1.2"; }
sfp_flags() { cat "$T/sys/eth1.2/flags" 2>/dev/null; }
mkdir -p "$T/sys/eth1"; echo 0x1003 > "$T/sys/eth1.2/flags"
rm -f "$T/gstate"; us gl-mesh.@base[0].mode agent; us gl-mesh.@base[0].enabled 1
run sync; export CNTR_MAC=02:00:00:00:00:01
guard_brif 0000.020000000001
run guard-once; run guard-once; run guard-once
check "main router is designated bridge: SFP stays" sfp_member
check "... no bad samples" eq "$(cut -d' ' -f1-2 "$T/gstate")" "0 0"
guard_brif 7fff.020000000002
run guard-once; run guard-once
check "two bad samples: still in (tolerates STP settling)" sfp_member
guard_brif 0000.020000000001; run guard-once
check "... good sample resets the count" eq "$(cut -d' ' -f1 "$T/gstate")" 0
guard_brif 8000.0200000000a4; : > "$T/calls.log"
run guard-once; run guard-once; run guard-once
check "switch became designated (STP not passing): SFP out of bridge" sh -c '! test -e "$0/sys/br-lan/brif/eth1.2"' "$T"
check "... and taken down so GL falls back" eq "$(sfp_flags)" 0x1002
check "... logged" grep -q "SFP guard: no STP from the main router" "$T/out"
check "... marked out" eq "$(cut -d' ' -f2 "$T/gstate")" 1
echo 0x1003 > "$T/sys/eth1.2/flags"; cap "$SWITCH_STP"; : > "$T/calls.log"; run guard-once
check "something brought it up while out: forced down again" eq "$(sfp_flags)" 0x1002
check "STP recheck listens on parent eth1" called "tcpdump -n -vv -Q in -i eth1 "
check "... filtered to VLAN 2" called "vlan 2 and ether dst 01:80:c2:00:00:00"
check "STP still wrong: stays down" eq "$(sfp_flags)" 0x1002
cap "$DIRECT"; run guard-once
check "main router's STP back: SFP up again" eq "$(sfp_flags)" 0x1003
check "... and back in br-lan" sfp_member
check "... logged" grep -q "STP is back" "$T/out"
guard_brif 7fff.020000000002; run guard-once; run guard-once; run guard-once
run revert
check "revert brings a guarded-down SFP back up" eq "$(sfp_flags)" 0x1003
check "... and clears guard state" test ! -f "$T/gstate"
run sync; rm -rf "$T/sys/br-lan/brif/eth1.2"
us gl-mesh.@base[0].mode controller; guard_brif 7fff.020000000002; : > "$T/calls.log"
run guard-once; run guard-once; run guard-once
check "not a node: guard does nothing" not_called "nomaster"
us gl-mesh.@base[0].mode agent; export CNTR_MAC=
run guard-once; run guard-once; run guard-once
check "main router unknown: guard does nothing" not_called "nomaster"
export CNTR_MAC=02:00:00:00:00:01; rm -rf "$T/sys/br-lan/brif/eth1.2"

echo "# 15. Model / firmware check"
echo glinet,gl-mt6000 > "$T/board_name"; cap "$DIRECT"
PREFIX="$T/root6" run install
check "other model: install refused" test ! -e "$T/root6/usr/sbin/flint-sfp-uplink"
check "... says why" grep -q "not a Flint 4" "$T/out"
echo glinet,gl-be14000 > "$T/board_name"; echo 4.12.0 > "$T/glversion"
PREFIX="$T/root6" run install
check "other firmware: install refused" test ! -e "$T/root6/usr/sbin/flint-sfp-uplink"
check "... says why" grep -q "not 4.11.x" "$T/out"
PREFIX="$T/root6" run install --force
check "--force overrides" test -x "$T/root6/usr/sbin/flint-sfp-uplink"
echo 4.11.0 > "$T/glversion"
check "Flint 4 on 4.11.0 passes" sh "$SCRIPT" model-check

echo "# 16. Watcher never touches a 10G WAN port it didn't add"
rm -f "$T/wstate"; echo "COPPER_LAN=0" > "$CONF"; export COPPER_LAN=0
mkdir -p "$T/sys/br-lan/brif"; touch "$T/sys/br-lan/brif/eth2"
us gl-mesh.@base[0].mode controller
run copper-watch-once
check "router mode, GL uses WAN as LAN: left alone" member
us gl-mesh.@base[0].mode agent
run copper-watch-once
check "node mode, wan-lan off, not ours: left alone" member
rm -f "$T/sys/br-lan/brif/eth2"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]

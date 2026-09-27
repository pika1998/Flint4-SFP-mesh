#!/bin/sh
# flint-sfp-uplink: let GL.iNet Mesh (Flint 4, 4.11.0 beta1) use the SFP+ port as a node's
# wired backhaul.
#
# Why: on a Mesh node GL only treats `network.wan.device` as a wired uplink (features.lua
# WIRED_BACKHAUL_ANY_PORT=false, dynbh.lua get_wan_device), and switching a unit to node mode
# resets its ports to factory, which puts the SFP back on `secondwan` (eth1.2, switch VLAN 2).
# So in node mode we point `wan` at the SFP device and disable `secondwan`. GL's own dynbh then
# bridges the SFP into br-lan and runs its normal wired-backhaul logic on it.
# Outside node mode we restore exactly what we changed.
# Details: README.md
#
# Usage: flint-sfp-uplink {status|check|plan|sync|apply|revert|install [--force] [--wan-lan]|
#                          wan-lan on|off|uninstall}
#   check      verify the main router's STP messages reach this node's SFP (safety check)
#   plan       show what sync would change, change nothing
#   sync       apply in node mode, revert otherwise (what the boot/hotplug hooks run)
#   install    run `check`, then copy this script to /usr/sbin, add the boot + hotplug hooks
#              and sync. --force skips the check.
#   wan-lan    optional: in node mode also make the 10G WAN port (WAN/LAN1) a normal LAN port
#              (on a node it is otherwise unused, since the SFP takes over the uplink role).
#              (copper-lan is accepted as an old alias.) A watcher checks each cable plugged into it before bridging it: if the port leads
#              back into the main network (Mesh frames or MACs the node already reaches over the
#              SFP) but no STP arrives, it is kept out of the bridge to avoid a hidden loop.
#   uninstall  revert and remove the hooks
#
# Once installed, a background watcher (procd) also:
#   - guards the SFP: if the main router's STP stops arriving on the bridged SFP (switch config
#     changed, fibre pulled), it takes the SFP out of the bridge so GL falls back to Wi-Fi on a
#     single path, and puts it back once STP returns;
#   - runs the 10G WAN port plug-in check when wan-lan is on.
# install also refuses on anything other than a Flint 4 (GL-BE14000) on firmware 4.11.x unless
# --force is given.
#
# Why the check: GL keeps the node's 5 GHz backhaul associated as a standby and relies on STP
# to stop the wired + wireless paths forming a loop. It also only accepts the wired parent if
# the STP designated bridge on the port is the main router (dynbh.lua handle_topology_discovery).
# So the main router's BPDUs must reach the SFP unchanged. A direct fibre/DAC link or a switch
# that passes BPDUs through is fine. A managed switch running its own STP, or one that drops
# BPDUs (e.g. a MikroTik CRS3xx with a hardware-offloaded bridge), is not.

NAME=flint-sfp-uplink

# Overridable for host tests.
UCI=${UCI:-uci}
UBUS=${UBUS:-ubus}
STATE=${STATE:-/etc/$NAME.state}
CONF=${CONF:-/etc/$NAME.conf}
LOCKFILE=${LOCKFILE:-/var/lock/$NAME.lock}
GL_MESH_INIT=${GL_MESH_INIT:-/etc/init.d/gl-mesh}
PROC_SECONDWAN=${PROC_SECONDWAN:-/proc/gl-hw-info/secondwan}
BOARD_JSON=${BOARD_JSON:-/etc/board.json}
SYS_NET=${SYS_NET:-/sys/class/net}
STP_WAIT=${STP_WAIT:-6}
TCPDUMP=${TCPDUMP:-tcpdump}
IP=${IP:-ip}
BRIDGE=${BRIDGE:-bridge}
WSTATE=${WSTATE:-/var/run/$NAME.copper}
COPPER_WAIT=${COPPER_WAIT:-10}
WATCH_INTERVAL=${WATCH_INTERVAL:-2}
GSTATE=${GSTATE:-/var/run/$NAME.guard}
GUARD_LIMIT=${GUARD_LIMIT:-3}          # consecutive bad samples before taking the SFP out
GUARD_EVERY=${GUARD_EVERY:-3}          # guard runs every Nth watcher pass (~6 s)
GUARD_RECHECK=${GUARD_RECHECK:-10}     # while out, re-test STP every Nth guard pass (~60 s)
BOARD_NAME_FILE=${BOARD_NAME_FILE:-/tmp/sysinfo/board_name}
GLVERSION_FILE=${GLVERSION_FILE:-/etc/glversion}
PREFIX=${PREFIX:-}

DRY_RUN=0
CHANGED=0

COPPER_LAN=0
[ -f "$CONF" ] && . "$CONF"

log() {
	echo "$NAME: $*"
	[ "$DRY_RUN" = 1 ] || logger -t "$NAME" "$*" 2>/dev/null
}

uget() { $UCI -q get "$1"; }

uset() {
	if [ "$DRY_RUN" = 1 ]; then echo "  uci set $1='$2'"; else $UCI set "$1=$2"; fi
	CHANGED=1
}

udel() {
	if [ "$DRY_RUN" = 1 ]; then echo "  uci delete $1"; else $UCI -q delete "$1"; fi
	CHANGED=1
}

uadd_list() {
	if [ "$DRY_RUN" = 1 ]; then echo "  uci add_list $1='$2'"; else $UCI add_list "$1=$2"; fi
	CHANGED=1
}

udel_list() {
	if [ "$DRY_RUN" = 1 ]; then echo "  uci del_list $1='$2'"; else $UCI -q del_list "$1=$2"; fi
	CHANGED=1
}

# The br-lan device section (anonymous, e.g. @device[0]).
brlan_section() {
	$UCI -q show network | sed -n "s/^network\.\([^.]*\)\.name='br-lan'$/\1/p" | head -n 1
}

brlan_has() {
	local sec
	sec=$(brlan_section)
	[ -n "$sec" ] && $UCI -q get "network.$sec.ports" | tr ' ' '\n' | grep -qx "$1"
}

set_state() {
	[ "$DRY_RUN" = 1 ] && return
	[ -f "$STATE" ] || return
	if grep -q "^$1=" "$STATE"; then
		sed -i "s/^$1=.*/$1='$2'/" "$STATE"
	else
		echo "$1='$2'" >> "$STATE"
	fi
}

# GL records the SFP VLAN device in several places; prefer the live network config.
sfp_device() {
	local dev
	dev=$(uget network.secondwan_dev.name)
	[ -n "$dev" ] || dev=$(cat "$PROC_SECONDWAN" 2>/dev/null)
	[ -n "$dev" ] || dev=$(uget board_special.hardware.secondwan)
	echo "${dev:-eth1.2}"
}

# The factory WAN device, used when there is no saved state to restore from.
factory_wan_device() {
	local dev
	dev=$(jsonfilter -i "$BOARD_JSON" -e '@.network.wan.device' 2>/dev/null)
	echo "${dev:-eth2}"
}

is_node() {
	[ "$(uget gl-mesh.@base[0].enabled)" = 1 ] && [ "$(uget gl-mesh.@base[0].mode)" = agent ]
}

save_state() {
	[ "$DRY_RUN" = 1 ] && return
	local wan_dev=$1
	[ "$wan_dev" = "$(sfp_device)" ] && wan_dev=$(factory_wan_device)
	{
		echo "orig_wan_device='$wan_dev'"
		echo "orig_secondwan_disabled='$(uget network.secondwan.disabled)'"
		echo "sfp_device='$(sfp_device)'"
	} > "$STATE"
}

finish() {
	[ "$DRY_RUN" = 1 ] && return 0
	[ "$CHANGED" = 1 ] || return 0
	$UCI commit network
	$UBUS call network reload >/dev/null 2>&1
	# At boot (START=14) gl-mesh has not started yet and will read the new config itself.
	if [ -x "$GL_MESH_INIT" ] && "$GL_MESH_INIT" running >/dev/null 2>&1; then
		log "restarting gl-mesh so it picks up the SFP uplink"
		"$GL_MESH_INIT" restart >/dev/null 2>&1
	fi
}

apply() {
	local sfp cur
	sfp=$(sfp_device)
	cur=$(uget network.wan.device)
	[ -f "$STATE" ] || save_state "$cur"

	if [ "$cur" != "$sfp" ]; then
		log "node mode: wan device $cur -> $sfp (SFP)"
		uset network.wan.device "$sfp"
	fi
	# secondwan also claims the SFP device; it must not run DHCP on a bridged port.
	if [ -n "$(uget network.secondwan)" ] && [ "$(uget network.secondwan.disabled)" != 1 ]; then
		log "node mode: disabling secondwan (shares $sfp)"
		uset network.secondwan.disabled 1
	fi
	copper_lan_sync
	finish
}

# Earlier versions put the 10G WAN port into br-lan in the config. It is now bridged at runtime,
# only after the link check, so remove any config entry an earlier version added.
copper_lan_sync() {
	local sec copper added_copper orig_wan_device
	[ -f "$STATE" ] && . "$STATE"
	[ "$added_copper" = 1 ] || return 0
	copper=${orig_wan_device:-$(factory_wan_device)}
	sec=$(brlan_section)
	if [ -n "$sec" ] && brlan_has "$copper"; then
		log "removing $copper from br-lan config (now bridged at runtime after a link check)"
		udel_list "network.$sec.ports" "$copper"
	fi
	set_state added_copper 0
}

copper_device() {
	local orig_wan_device
	[ -f "$STATE" ] && . "$STATE"
	echo "${orig_wan_device:-$(factory_wan_device)}"
}

copper_is_member() { [ -e "$SYS_NET/br-lan/brif/$1" ]; }

copper_attach() {
	copper_is_member "$1" && return 0
	log "10G WAN port as LAN: adding $1 to br-lan"
	$IP link set "$1" master br-lan
}

copper_detach() {
	copper_is_member "$1" || return 0
	log "10G WAN port as LAN: removing $1 from br-lan"
	$IP link set "$1" nomaster
}

# Listen on the copper port before bridging it. Unsafe only if it leads back into the main
# network (Mesh/1905 frames, or source MACs the node already learned over the SFP) while no STP
# arrives, i.e. a second path that STP could not see.
copper_check() {
	local dev=$1 ctrl sfp out srcs known mac leads=0 bpdus mesh
	ctrl=$(controller_mac)
	[ -n "$ctrl" ] || { log "10G WAN port check: main router not known yet, keeping $dev out"; return 1; }
	sfp=$(sfp_device)
	out=$(timeout "$COPPER_WAIT" "$TCPDUMP" -n -e -Q in -i "$dev" -c 300 2>/dev/null)
	bpdus=$(echo "$out" | grep -c ' > 01:80:c2:00:00:00')
	mesh=$(echo "$out" | grep -ciE 'IEEE1905|0x893a')
	srcs=$(echo "$out" | sed -n 's/^[0-9:.]* \([0-9a-f:]\{17\}\) > .*/\1/p' | sort -u)
	known=$({ $BRIDGE fdb show br br-lan 2>/dev/null | grep " dev $sfp " | awk '{print $1}'; echo "$ctrl"; } |
		tr 'A-F' 'a-f' | sort -u)
	[ "$mesh" -gt 0 ] && leads=1
	for mac in $srcs; do
		echo "$known" | grep -qx "$mac" && leads=1
	done
	if [ "$leads" = 1 ] && [ "$bpdus" = 0 ]; then
		log "10G WAN port check: $dev leads back into the main network but no STP arrives; keeping it out of br-lan (loop risk)"
		return 1
	fi
	if [ "$leads" = 1 ]; then
		log "10G WAN port check: $dev leads back into the main network with STP present; bridging (STP will block the extra path)"
	else
		log "10G WAN port check: $dev has an edge device; bridging"
	fi
	return 0
}

# One pass of the 10G WAN port watcher. Remembers per link-up whether the port was judged safe.
copper_watch_once() {
	local dev carrier prev
	dev=$(copper_device)
	# Only undo what this watcher did; never touch the port otherwise (GL may use it as WAN or LAN).
	if ! is_node || [ "$COPPER_LAN" != 1 ]; then
		[ -f "$WSTATE" ] && { copper_detach "$dev"; rm -f "$WSTATE"; }
		return 0
	fi
	# On a node nothing uses this port, so it may be administratively down, which hides the
	# link state (reading carrier fails). Bring it up for link detection only; it is not bridged yet.
	if ! carrier=$(cat "$SYS_NET/$dev/carrier" 2>/dev/null); then
		$IP link set "$dev" up
		carrier=0
	fi
	if [ "$carrier" != 1 ]; then
		copper_detach "$dev"; echo down > "$WSTATE"; return 0
	fi
	prev=$(cat "$WSTATE" 2>/dev/null)
	case "$prev" in
		safe) copper_attach "$dev" ;;   # re-add if a network reload rebuilt br-lan
		unsafe) : ;;                    # stay out until the cable is unplugged
		*)
			copper_detach "$dev"
			if copper_check "$dev"; then
				echo safe > "$WSTATE"; copper_attach "$dev"
			else
				echo unsafe > "$WSTATE"
			fi ;;
	esac
}

# SFP guard. On a bridge port, sysfs designated_bridge is "<prio>.<mac without colons>". While the
# main router's BPDUs arrive it is the main router; if they stop, the node becomes designated
# itself within max-age (GL uses 8 s). Then the SFP is taken out AND set administratively down:
# just unbridging it is not enough, because GL keeps exchanging its 1905 control messages over
# the raw interface, stays on "Ethernet" and never falls back (seen in live testing). With the
# interface down, GL sees the SFP as unplugged and falls back to Wi-Fi on its own. While it is
# down, STP is watched on the parent interface (e.g. eth1, VLAN 2), which still sees the frames.
sfp_is_up() { [ $(( $(cat "$SYS_NET/$1/flags" 2>/dev/null || echo 1) & 1 )) = 1 ]; }

guard_take_out() {
	log "SFP guard: no STP from the main router on $1 (designated bridge $2); taking it down so GL falls back to Wi-Fi without a loop"
	$IP link set "$1" nomaster
	$IP link set "$1" down
}

guard_restore() {
	log "SFP guard: main router's STP is back on $1, bringing it up and returning it to br-lan"
	$IP link set "$1" up
	$IP link set "$1" master br-lan
}

guard_once() {
	local dev ctrl brif d bad=0 out=0 pass=0 parent vid
	is_node || return 0
	[ -f "$STATE" ] || return 0
	ctrl=$(controller_mac)
	[ -n "$ctrl" ] || return 0
	dev=$(sfp_device)
	[ -f "$GSTATE" ] && read -r bad out pass < "$GSTATE"
	pass=$((pass + 1))

	if [ "$out" = 1 ]; then
		sfp_is_up "$dev" && { $IP link set "$dev" nomaster; $IP link set "$dev" down; }
		if [ $((pass % GUARD_RECHECK)) = 0 ]; then
			case "$dev" in
				*.*) parent=${dev%.*}; vid=${dev##*.} ;;
				*) parent=$dev; vid= ;;
			esac
			if CAP_IF=$parent CAP_FILTER="${vid:+vlan $vid and }ether dst 01:80:c2:00:00:00" stp_check >/dev/null 2>&1; then
				guard_restore "$dev"
				bad=0; out=0
			fi
		fi
		echo "$bad $out $pass" > "$GSTATE"
		return 0
	fi

	brif="$SYS_NET/br-lan/brif/$dev"
	if [ ! -e "$brif" ]; then
		echo "0 0 $pass" > "$GSTATE"
		return 0
	fi
	d=$(cat "$brif/designated_bridge" 2>/dev/null | sed 's/^[0-9a-f]*\.//')
	if [ "$d" = "$(echo "$ctrl" | tr -d ':')" ]; then
		bad=0
	else
		bad=$((bad + 1))
		if [ "$bad" -ge "$GUARD_LIMIT" ]; then
			guard_take_out "$dev" "$d"
			out=1
		fi
	fi
	echo "$bad $out $pass" > "$GSTATE"
}

# The background watcher: SFP guard, plus the 10G WAN port check when wan-lan is on.
watch() {
	local n=0
	while :; do
		COPPER_LAN=0
		[ -f "$CONF" ] && . "$CONF"
		copper_watch_once
		n=$((n + 1))
		[ $((n % GUARD_EVERY)) = 0 ] && guard_once
		sleep "$WATCH_INTERVAL"
	done
}

# Only a Flint 4 on 4.11.x has been tested; other models and firmware lay things out differently.
model_check() {
	local board ver
	board=$(cat "$BOARD_NAME_FILE" 2>/dev/null)
	ver=$(cat "$GLVERSION_FILE" 2>/dev/null)
	case "$board" in
		glinet,gl-be14000|gl-be14000) ;;
		*) echo "model check: this is '${board:-unknown}', not a Flint 4 (GL-BE14000)"; return 1 ;;
	esac
	case "$ver" in
		4.11|4.11.*) ;;
		*) echo "model check: firmware '${ver:-unknown}' is not 4.11.x; GL may have changed things (or added SFP support)"; return 1 ;;
	esac
	return 0
}

revert() {
	[ -f "$STATE" ] || { [ "$1" = quiet ] || log "nothing to revert"; return 0; }
	local orig_wan_device orig_secondwan_disabled sfp_device added_copper sec
	. "$STATE"

	[ "$DRY_RUN" = 1 ] || copper_detach "${orig_wan_device:-$(factory_wan_device)}"
	if [ "$DRY_RUN" != 1 ] && [ -f "$GSTATE" ] && [ "$(cut -d' ' -f2 "$GSTATE")" = 1 ]; then
		log "bringing $sfp_device back up (was taken down by the SFP guard)"
		$IP link set "$sfp_device" up
	fi
	[ "$DRY_RUN" = 1 ] || rm -f "$GSTATE"

	sec=$(brlan_section)
	if [ "$added_copper" = 1 ] && [ -n "$sec" ] && brlan_has "$orig_wan_device"; then
		log "removing 10G WAN port $orig_wan_device from br-lan"
		udel_list "network.$sec.ports" "$orig_wan_device"
	fi

	# Only undo values that are still ours, so later user or GL changes are left alone.
	if [ "$(uget network.wan.device)" = "$sfp_device" ]; then
		log "restoring wan device $sfp_device -> $orig_wan_device"
		uset network.wan.device "$orig_wan_device"
	fi
	if [ "$(uget network.secondwan.disabled)" = 1 ] && [ "$orig_secondwan_disabled" != 1 ]; then
		log "re-enabling secondwan"
		if [ -n "$orig_secondwan_disabled" ]; then
			uset network.secondwan.disabled "$orig_secondwan_disabled"
		else
			udel network.secondwan.disabled
		fi
	fi
	[ "$DRY_RUN" = 1 ] || rm -f "$STATE"
	finish
}

sync() {
	if is_node; then
		apply
	else
		revert quiet
	fi
}

status() {
	local sfp dev
	sfp=$(sfp_device)
	echo "mesh:            enabled=$(uget gl-mesh.@base[0].enabled) mode=$(uget gl-mesh.@base[0].mode)"
	echo "sfp device:      $sfp"
	echo "wan device:      $(uget network.wan.device)  proto=$(uget network.wan.proto) disabled=$(uget network.wan.disabled)"
	echo "secondwan:       device=$(uget network.secondwan.device) disabled=$(uget network.secondwan.disabled)"
	echo "10G WAN as LAN:  $([ "$COPPER_LAN" = 1 ] && echo on || echo off) (port $(copper_device): $(cat "$WSTATE" 2>/dev/null || echo -))"
	echo "SFP guard:       $([ -f "$GSTATE" ] && awk '{print ($2==1 ? "SFP taken down (no STP from main router), rechecking" : "ok, bad samples " $1)}' "$GSTATE" || echo -)"
	echo "saved state:     $([ -f "$STATE" ] && tr '\n' ' ' < "$STATE" || echo none)"
	command -v swconfig >/dev/null && echo "sfp link:        $(swconfig dev switch0 port 4 get link 2>/dev/null)"
	if [ -d /sys/class/net/br-lan/brif ]; then
		echo "br-lan STP:      $(cat /sys/class/net/br-lan/bridge/stp_state 2>/dev/null)"
		for dev in /sys/class/net/br-lan/brif/*; do
			echo "  $(basename "$dev") state=$(cat "$dev/state") designated=$(cat "$dev/designated_bridge")"
		done
	fi
}

# The main router's AL MAC, once this unit has joined Mesh (empty before that).
controller_mac() {
	$UBUS call gl-mesh status 2>/dev/null |
		sed -n 's/.*"cntr_mac"[^"]*"\([0-9a-fA-F:]*\)".*/\1/p' | head -n 1 | tr 'A-F' 'a-f'
}

# Listen for BPDUs on the SFP and check they come straight from the main router.
# BPDU fields (tcpdump -vv): bridge-id = sender, root-id = root; both are "<prio>.<mac>[.<port>]".
stp_check() {
	local dev ctrl out senders roots mac prio capif filt
	dev=$(sfp_device)
	ctrl=$(controller_mac)
	capif=${CAP_IF:-$dev}
	filt=${CAP_FILTER:-ether dst 01:80:c2:00:00:00}

	if ! command -v "$TCPDUMP" >/dev/null 2>&1; then
		echo "check: tcpdump is not available, so the STP check can't run (use --force to skip)"
		return 1
	fi
	if [ ! -e "$SYS_NET/$capif" ]; then
		echo "check: SFP interface $dev does not exist yet; is the SFP set up as a port on this unit?"
		return 1
	fi

	echo "check: listening ${STP_WAIT}s for STP messages on $capif (SFP)..."
	out=$(timeout "$STP_WAIT" "$TCPDUMP" -n -vv -Q in -i "$capif" -c 4 "$filt" 2>/dev/null)
	senders=$(echo "$out" | sed -n 's/.*bridge-id [0-9a-f]*\.\([0-9a-f:]\{17\}\).*/\1/p' | sort -u)
	roots=$(echo "$out" | sed -n 's/.*root-id \([0-9a-f]*\)\.\([0-9a-f:]\{17\}\).*/\1 \2/p' | sort -u)

	if [ -z "$senders" ]; then
		echo "check: FAILED - no STP messages from the main router arrived on the SFP."
		echo "  Is Mesh enabled on the main router (it turns STP on), is its SFP set to LAN and the"
		echo "  link up? If a managed switch sits in between, it is probably dropping STP (BPDUs):"
		echo "  disable STP on it and make sure it forwards 01:80:C2:00:00:00 between the router ports."
		echo "  Without this, the SFP and the standby Wi-Fi backhaul could form a network loop."
		return 1
	fi

	if [ -n "$ctrl" ]; then
		for mac in $senders; do
			[ "$mac" = "$ctrl" ] && { echo "check: OK - STP messages come straight from the main router ($ctrl)"; return 0; }
		done
		echo "check: FAILED - STP messages on the SFP come from $(echo $senders), not the main router ($ctrl)."
		echo "$roots" | grep -q " $ctrl$" &&
			echo "  They carry the main router as root, so a switch running its own STP sits in between."
		echo "  Disable STP on that switch and have it forward 01:80:C2:00:00:00 between the router"
		echo "  ports, otherwise GL will not accept the wired parent."
		return 1
	fi

	# Not joined yet: GL gives the Mesh controller bridge priority 0, so expect a priority-0 root
	# that is also the sender (nothing in between re-originating BPDUs).
	for mac in $senders; do
		echo "$roots" | while read -r prio rmac; do
			[ "$prio" = 0000 ] && [ "$rmac" = "$mac" ] && echo ok
		done | grep -q ok && { echo "check: OK - STP messages come straight from a Mesh controller ($mac)"; return 0; }
	done
	echo "check: FAILED - STP messages come from $(echo $senders), which does not look like a GL Mesh"
	echo "  main router sending directly (expected bridge priority 0). If a managed switch sits in"
	echo "  between, disable its STP and forward 01:80:C2:00:00:00 between the router ports."
	return 1
}

install() {
	local self arg force=0
	for arg in "$@"; do
		case "$arg" in
			--force) force=1 ;;
			--wan-lan|--copper-lan) [ -n "$PREFIX" ] || echo "COPPER_LAN=1" > "$CONF"; COPPER_LAN=1 ;;
		esac
	done
	if [ "$force" != 1 ] && ! model_check; then
		echo "$NAME: not installed. Use --force only if you know this firmware behaves the same."
		return 1
	fi
	if [ "$force" != 1 ] && ! stp_check; then
		echo "$NAME: not installed. Fix the above, or re-run with --force if you understand the loop risk."
		return 1
	fi
	self=$(readlink -f "$0")
	mkdir -p "$PREFIX/usr/sbin" "$PREFIX/etc/init.d" "$PREFIX/etc/hotplug.d/iface"
	[ "$self" = "$(readlink -f "$PREFIX/usr/sbin/$NAME" 2>/dev/null)" ] || cp "$self" "$PREFIX/usr/sbin/$NAME"
	chmod 755 "$PREFIX/usr/sbin/$NAME"

	# Before gl-mesh (START=15) and netifd (START=20), so both read the adjusted config.
	cat > "$PREFIX/etc/init.d/$NAME" <<-'EOF'
	#!/bin/sh /etc/rc.common
	START=14
	USE_PROCD=1
	boot() { /usr/sbin/flint-sfp-uplink sync; start; }
	start_service() {
		procd_open_instance
		procd_set_param command /usr/sbin/flint-sfp-uplink watch
		procd_set_param respawn
		procd_close_instance
	}
	EOF
	chmod 755 "$PREFIX/etc/init.d/$NAME"

	# A Mesh role switch resets ports and re-enables secondwan; catch its ifup and re-apply.
	cat > "$PREFIX/etc/hotplug.d/iface/98-$NAME" <<-'EOF'
	#!/bin/sh
	case "$ACTION" in ifup|ifupdate) ;; *) exit 0 ;; esac
	case "$INTERFACE" in wan|secondwan) ;; *) exit 0 ;; esac
	/usr/sbin/flint-sfp-uplink sync >/dev/null 2>&1 &
	EOF

	[ -n "$PREFIX" ] || "/etc/init.d/$NAME" enable
	log "installed"
	[ -n "$PREFIX" ] || { sync; "/etc/init.d/$NAME" restart; }
}

uninstall() {
	revert
	[ -n "$PREFIX" ] || { "/etc/init.d/$NAME" stop 2>/dev/null; "/etc/init.d/$NAME" disable 2>/dev/null; }
	rm -f "$PREFIX/etc/init.d/$NAME" "$PREFIX/etc/hotplug.d/iface/98-$NAME" "$PREFIX/usr/sbin/$NAME"
	[ -n "$PREFIX" ] || rm -f "$CONF"
	log "uninstalled"
}

locked() {
	if command -v lock >/dev/null 2>&1 && [ -z "$NO_LOCK" ]; then
		lock "$LOCKFILE"
		"$@"
		lock -u "$LOCKFILE"
	else
		"$@"
	fi
}

case "$1" in
	status) status ;;
	check) stp_check ;;
	plan) DRY_RUN=1; echo "planned changes (nothing is written):"; sync; [ "$CHANGED" = 1 ] || echo "  none" ;;
	sync) locked sync ;;
	apply) locked apply ;;
	revert) locked revert ;;
	install) shift; install "$@" ;;
	wan-lan|copper-lan)
		case "$2" in
			on) echo "COPPER_LAN=1" > "$CONF"; COPPER_LAN=1 ;;
			off) echo "COPPER_LAN=0" > "$CONF"; COPPER_LAN=0 ;;
			*) echo "usage: $NAME wan-lan on|off" >&2; exit 2 ;;
		esac
		locked sync
		[ "$COPPER_LAN" = 1 ] || { copper_detach "$(copper_device)"; is_node && $IP link set "$(copper_device)" down; }
		[ -z "$PREFIX" ] && [ -x "/etc/init.d/$NAME" ] && "/etc/init.d/$NAME" restart ;;
	watch|copper-watch) watch ;;
	guard-once) guard_once ;;
	model-check) model_check ;;
	copper-watch-once) copper_watch_once ;;
	copper-check) copper_check "$(copper_device)" ;;
	uninstall) locked uninstall ;;
	*) echo "usage: $NAME {status|check|plan|sync|apply|revert|install [--force] [--wan-lan]|wan-lan on|off|uninstall}" >&2; exit 2 ;;
esac

# Flint 4 wired Mesh over SFP+ (4.11.0 beta1)

GL's 4.11.0 beta1 finally brought Mesh support to the Flint 4 (GL-BE14000), which I'd been waiting for. The only problem was that wired backhaul used the node's WAN port and ignored SFP+. That wasn't much use for my setup, because pretty much my whole network runs over fibre.

After spending a few hours figuring it out, I managed to get my second Flint using SFP+ for wired Mesh, with a MikroTik switch between the two routers. This is the script and setup I used. It's been running stable for me so far.

## Choose your setup

It's one script, with an optional setting to use the node's spare 10G WAN port as LAN.

| Setup | Install command | What it does |
|---|---|---|
| **SFP+ as the Mesh uplink** | `sh flint-sfp-uplink.sh install` | Uses SFP+ for wired Mesh. The node's 10G WAN port stays unused. |
| **SFP+ uplink and 10G WAN as LAN** | `sh flint-sfp-uplink.sh install --wan-lan` | Uses SFP+ for wired Mesh and makes the 10G WAN port available for a PC, NAS or another checked LAN connection. |

You can change the WAN-as-LAN setting later without reinstalling:

```sh
flint-sfp-uplink wan-lan on
flint-sfp-uplink wan-lan off
```

Both options only change the **Mesh node**. The main router's SFP+ port needs to be set to LAN separately.

Before starting, make sure both Flints are on **4.11.0 beta1** and you've decided which one will be the main router and which will be the node. The script can be installed before or after the node joins Mesh.

If you're connecting the Flints directly with fibre or a DAC, you probably won't need any extra setup in between. A basic unmanaged switch may also work as it is. If you have a managed switch, such as a MikroTik, UniFi or TP-Link Omada, you may need to configure it to pass the STP messages between the routers. See [the switch setup below](#2-the-switch-in-between-if-you-have-one).

The script checks whether those messages are getting through before installing and refuses to continue if the check fails.

## My setup

- Two Flint 4s running 4.11.0 beta1: one main router (Mesh controller) and one node
- ONT → main Flint's 10G WAN port
- Main Flint SFP+ → MikroTik CRS305-1G-4S+ → node Flint SFP+
- My PC connected to the same CRS305
- 10G SR multimode optics with LC-LC OM3/OM4 fibre

## What was causing the problem

There were two separate issues to sort out.

### The node only checks its WAN port for wired Mesh

In this firmware, GL's Mesh code expects the wired uplink to be on the WAN interface. The node could receive messages from the main router over the fibre, but Mesh didn't recognise the SFP+ interface. The log kept showing:

```text
received 1905 message on unknown iface eth1.2
```

`eth1.2` is the SFP+ interface.

On top of that, joining Mesh as a node resets the port configuration to its defaults, which turns SFP+ back into a second WAN. So manually changing the port beforehand wasn't enough, because joining Mesh could undo it again.

### The MikroTik wasn't passing the STP messages through

The two Flints use spanning tree (STP) messages to check the wired path and avoid network loops. This matters because the node keeps its 5 GHz wireless backhaul connected as a standby, even when it's using Ethernet.

My CRS305 was running its own STP, so the Flints weren't seeing each other's messages directly. I initially thought turning STP off on the switch would sort it, but the CRS3xx switch chip was still catching the BPDU frames instead of forwarding them.

I had to add two switch rules to pass those frames between the ports connected to the Flints. Once that was sorted, the routers could see each other's STP messages over the fibre.

## What the script does

`flint-sfp-uplink.sh` runs on the **Mesh node**. It:

- Points `wan` at the SFP+ interface, `eth1.2`, and disables the conflicting second-WAN configuration.
- Reapplies the changes after a reboot or when GL resets the ports during Mesh joining.
- Restores the normal configuration if the unit stops being a Mesh node.
- Checks that the main router's STP messages reach the SFP+ interface before installing. If they don't, it refuses to install because bridging the SFP+ path could cause a network loop.
- Keeps checking the path with a small background watcher and disables it if the main router's STP messages stop arriving. The node can then fall back to Wi-Fi. When STP returns, it enables the SFP+ path again.
- Checks that it's running on a Flint 4 with 4.11.x firmware, because other models or versions may handle things differently.

I tested the watcher by disabling the STP forwarding rule on my MikroTik. The node fell back to Wi-Fi within about **40 seconds**. After I enabled the rule again, it returned to fibre automatically.

GL's own Mesh system handles the backhaul switching. The script gets the SFP+ interface into the configuration Mesh expects, and GL then bridges it, switches to Ethernet and keeps Wi-Fi as the standby.

## Optional: use the node's 10G WAN port as LAN

Once SFP+ is the uplink, the node's **10G WAN/LAN1 port** is no longer being used. You can enable it as an extra LAN port during installation with `--wan-lan`, or afterwards:

```sh
flint-sfp-uplink wan-lan on     # or: install --wan-lan
flint-sfp-uplink wan-lan off
```

This is useful if you've got a PC or NAS near the node, since the other LAN ports are only 2.5G and 1G.

The script checks the connection for a few seconds each time a cable is plugged in before deciding whether to add the port to LAN:

| Connection detected | What happens |
|---|---|
| A normal device, such as a PC or NAS | The port is added to LAN. |
| Another connection to the main network, with STP getting through | The port is added to LAN, with STP handling the extra path to prevent a loop. |
| Another connection to the main network, without STP getting through | The port stays out of LAN and a warning is logged, because the extra path could create a loop. |

Unplugging the cable removes the port from LAN again, so the next connection gets checked from scratch.

Traffic from this port passes through the node's CPU before reaching the fibre, so a 10G link doesn't guarantee 10 Gbps throughput.

## How to use it

### 1. Main router

On the **main Flint**, go to **Network → Ports** and set the **SFP+ port to LAN**. This setting stays in place in router mode. Mine was already configured that way.

### 2. The switch in between (if you have one)

#### Direct connection or unmanaged switch

If you're using fibre or a DAC directly between the Flints, you can skip the switch configuration. A basic unmanaged switch may not need any changes either. The script's check will tell you if STP isn't reaching the node.

#### MikroTik CRS3xx

This is what I used on my CRS305:

```text
/interface bridge set [find name=bridge] protocol-mode=none
/interface ethernet switch rule add switch=switch1 ports=sfp-sfpplus1 dst-mac-address=01:80:C2:00:00:00/FF:FF:FF:FF:FF:FF new-dst-ports=sfp-sfpplus2 comment="flint-mesh: STP main->node"
/interface ethernet switch rule add switch=switch1 ports=sfp-sfpplus2 dst-mac-address=01:80:C2:00:00:00/FF:FF:FF:FF:FF:FF new-dst-ports=sfp-sfpplus1 comment="flint-mesh: STP node->main"
```

In my setup, `sfp-sfpplus1` connects to the main Flint and `sfp-sfpplus2` connects to the node. Change the port names to match your setup, and make sure `bridge` is the correct bridge name.

The forwarding rules target STP frames. Normal traffic, including my PC on the same switch, continued working as expected.

#### Other managed switches

The aim is to let the two Flints receive each other's STP frames (`01:80:C2:00:00:00`). You may need to disable the switch's STP participation on the path between them and configure BPDU forwarding. The exact settings depend on the switch; disabling STP alone wasn't enough on my CRS305.

### 3. Install on the node

Copy the script to the node using `scp -O` for the Flint's Dropbear setup:

```sh
scp -O flint-sfp-uplink.sh root@<node-ip>:/tmp/
```

SSH into the **node**, then check the connection and review the planned changes:

```sh
sh /tmp/flint-sfp-uplink.sh check      # is STP getting through?
sh /tmp/flint-sfp-uplink.sh plan       # shows what it'll change, changes nothing
```

When you're ready, install it:

```sh
sh /tmp/flint-sfp-uplink.sh install    # runs the check again, then installs
```

Use `install --wan-lan` if you also want to enable the node's 10G WAN port as LAN. You can install the script before or after joining Mesh; it doesn't apply the uplink changes while the Flint is in router mode.

**The first time the changes are applied, the node's network restarts.** Devices connected to it will briefly disconnect, including your SSH session, and the node may get a new DHCP address. If you're installing over SSH, use this detached command in place of the normal install command:

```sh
sh -c 'trap "" HUP; sh /tmp/flint-sfp-uplink.sh install' > /tmp/flint-sfp-uplink.log 2>&1 < /dev/null &
```

This keeps the install running if the SSH connection drops. The Flint doesn't have `nohup`, which is why the command uses a HUP trap instead.

To update the script later, copy over the newer version and run `install` again. If no configuration changes are needed, it doesn't restart the network.

### 4. Check it worked

Run these on the node:

```sh
ubus call gl-mesh status        # connection type should say "Ethernet", ifname "eth1.2"
flint-sfp-uplink status
```

The Mesh connection type should be `Ethernet`, with `eth1.2` as the interface. The script's status should also show `SFP guard: ok`.

Mine shows an Ethernet link at **10000 Mb/s**. Nearly all the Mesh traffic now goes over the fibre, with the 5 GHz wireless backhaul kept as a standby.

## Performance

An `iperf3` test between the two Flints over fibre gave me about **5 Gbps in each direction**.

That test ran on the routers themselves, with their CPUs handling the test traffic. It isn't a measurement of throughput between devices behind the routers, so I'd test that separately for your setup.

## Uninstall

On the node, run:

```sh
flint-sfp-uplink uninstall
```

This restores the WAN and second-WAN settings and removes the hooks added by the script.

If you also added the MikroTik rules, remove them separately:

```text
/interface ethernet switch rule remove [find comment~"flint-mesh"]
```

You can then set the bridge's `protocol-mode` back to `rstp` if that's what it used before.

## Things to know

- This is unofficial and has only been tested on **my two Flint 4s running 4.11.0 beta1**. The install check accepts 4.11.x, but that doesn't mean every version has been tested.
- After a firmware update, you'll need to install the script again.
- The node's 10G WAN port stays unused unless you enable `wan-lan`. Uninstalling returns it to GL's normal configuration.
- If GL adds official SFP+ wired backhaul support, I'd remove this and use that instead.

### If the fibre disconnects

The node falls back to Wi-Fi automatically, but it takes around **30–40 seconds**. The SFP+ port sits behind the Flint's internal switch, so Linux doesn't directly see the physical link go down. The watcher detects the missing STP messages and disables the SFP+ path, allowing Mesh to fall back to Wi-Fi.

When the fibre is reconnected and STP messages start arriving again, the node returns to the wired connection automatically.

### Diagnostics and tests

`flint-diag.sh` is the read-only diagnostics script I used while working this out. It collects Mesh status, port configuration, SFP information, STP details and logs, which should help if something isn't working.

`test/run-tests.sh` contains the **100 tests** I ran against a copy of my actual configuration before trying the script on the router.

### Using `--force`

`--force` skips the model and STP checks. Only use it if you understand why those checks failed, because bypassing them could leave you with a network loop.

Use at your own risk. It's been stable in my setup, and `flint-sfp-uplink uninstall` restores the node settings if you need to remove it.

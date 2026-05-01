# vlan-wizard

Interactive VLAN setup script for the GL.iNet Flint 2 (MT6000) running stock GL.iNet firmware (4.8.x / OpenWrt 21.02-SNAPSHOT) with DSA networking.

Based on [ryan-pope.com/posts/flint2-vlans](https://ryan-pope.com/posts/flint2-vlans/).

## Why does every change require a reboot?

GL.iNet's firmware crashes if you try to activate `vlan_filtering` on a running `br-lan` bridge via `network reload`. A clean reboot lets the MTK hardware acceleration (flow offloading, packet steering) initialize in the correct order after the bridge-VLAN config is written — the same thing LuCI's "Save & Apply" does internally.

**Expect ~1-2 minutes of downtime after every VLAN operation.**

## VLAN strategy

- **VLAN 1** — your existing LAN. All current `br-lan` ports are kept as untagged with PVID 1. Nothing changes for your main network.
- **New VLANs** — created as wifi-only by default (no physical ports). A physical trunk port can be added later with the `port` command.

Each new VLAN gets its own:
- Network interface (`br-lan.<id>`)
- Static gateway IP (`192.168.X.1`)
- DHCP pool (`192.168.X.100–249`)
- Isolated firewall zone (internet via WAN, blocked from LAN)
- Firewall rules for DHCP and DNS
- Wi-Fi interface(s) on 2.4GHz and/or 5GHz

## Installation

Copy the script to your router and make it executable:

```sh
scp vlan-wizard.sh root@192.168.8.1:/root/
ssh root@192.168.8.1 "chmod +x /root/vlan-wizard.sh"
```

## Commands

### `add` — add a new VLAN

```sh
./vlan-wizard.sh add
```

Walks you through an interactive wizard:

| Prompt | Example |
|---|---|
| VLAN ID (2–4094) | `20` |
| Interface name (a-z, 0-9, _) | `iot` |
| Subnet octet X for 192.168.X.0/24 | `20` |
| Enable 2.4GHz wifi? | `Y` |
| Enable 5GHz wifi? | `Y` |
| SSID(s) | `MyIoT` |
| Wifi password (min 8 chars) | `supersecret` |
| Client isolation? | `n` |

Shows a preview before applying. Requires confirmation before rebooting.

A backup of `network`, `wireless`, `firewall`, and `dhcp` is saved to `/root/vlan_wizard_backup` before the first change. Subsequent `add` calls reuse the same backup.

---

### `list` — list all VLANs

```sh
./vlan-wizard.sh list
```

Displays a table of all configured `br-lan` VLANs with their interface name, subnet, and associated SSIDs.

---

### `remove` — remove a VLAN

```sh
./vlan-wizard.sh remove <VLAN-ID>
```

Removes the bridge-vlan entry, network interface, DHCP config, firewall zone, firewall rules, forwardings, and all associated Wi-Fi interfaces. Saves a timestamped backup before removing, then reboots.

VLAN 1 cannot be removed.

---

### `port add` — add a physical port to a VLAN

```sh
./vlan-wizard.sh port add <VLAN-ID> <lanX> [tagged|untagged]
```

Attaches a physical LAN port to an existing VLAN. Useful for trunking a switch or connecting a wired device to an isolated network.

- `tagged` (default) — the port carries 802.1Q tags; use for trunk links to another switch
- `untagged` — the port sends/receives untagged traffic; use for a single end device

**Note:** Making a port untagged in a new VLAN changes its PVID away from VLAN 1. Update the VLAN 1 bridge entry in LuCI afterwards if needed.

```sh
# Example: add lan2 as a tagged trunk port to VLAN 20
./vlan-wizard.sh port add 20 lan2 tagged

# Example: add lan3 as an untagged access port to VLAN 30
./vlan-wizard.sh port add 30 lan3 untagged
```

---

### `status` — show current state

```sh
./vlan-wizard.sh status
```

Displays:
- Raw UCI `bridge-vlan` config
- Kernel bridge VLAN table (`bridge vlan show`) — only populated after reboot with `vlan_filtering` on
- All network interfaces with IP and device
- All Wi-Fi interfaces with SSID, network, and ifname

---

### `rollback` — restore backup and reboot

```sh
./vlan-wizard.sh rollback
```

Imports the original `network`, `wireless`, `firewall`, and `dhcp` config from `/root/vlan_wizard_backup` and reboots immediately. Use this if you lose access to the router after a VLAN change.

If no backup exists, the script tells you to run a factory reset (hold the reset button for 10 seconds).

## Backup location

```
/root/vlan_wizard_backup/
  network          ← original config (used by rollback)
  wireless
  firewall
  dhcp
  <timestamp>_before_remove_vlan<id>_network   ← per-remove snapshots
  <timestamp>_before_remove_vlan<id>_wireless
  ...
```

## Firewall behaviour

Every VLAN is placed in an isolated firewall zone:

| Direction | Policy |
|---|---|
| Input (→ router) | REJECT |
| Forward (→ LAN) | REJECT |
| Output (router →) | ACCEPT |
| DHCP (UDP 67-68) | ACCEPT |
| DNS (TCP/UDP 53) | ACCEPT |
| Forward to WAN | ACCEPT (internet works) |

Clients on a VLAN can reach the internet but cannot reach your main LAN or other VLANs.

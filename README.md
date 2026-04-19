# LuCI VLAN Clients Dashboard

> **Disclaimer:** This script was developed with the assistance of AI. It has been tested on the hardware listed below, but use it at your own risk. **Always take a backup before making any changes to your router.**

A modern JavaScript LuCI view for **GL.iNet Flint 2 (MT6000)** that shows all connected clients grouped by VLAN interface.

Tested on firmware **4.8.x** (OpenWrt 21.02-SNAPSHOT).

---

## Features

- Groups clients by VLAN with collapsible sections
- Shows friendly VLAN names (e.g. `iot` instead of `br-lan.20`)
- Filter pills to show/hide individual VLANs
- Search by hostname, IP, MAC, or custom label
- Per-device custom labels stored in `/etc/vlan-client-labels`
- Sortable columns (IP, MAC, hostname)
- Collapse state persisted across page loads

---

## Installation

Copy `install-vlan-clients.sh` to the router and run it:

```sh
scp install-vlan-clients.sh root@192.168.8.1:/root/
ssh root@192.168.8.1 "sh /root/install-vlan-clients.sh"
```

Then open LuCI → **Network → VLAN Clients**.

> Log out and back in if the menu item does not appear.

---

## Files installed

| Path | Description |
|------|-------------|
| `/www/luci-static/resources/view/vlan-clients.js` | The view |
| `/usr/share/luci/menu.d/luci-app-vlan-clients.json` | Menu entry |
| `/usr/share/rpcd/acl.d/luci-app-vlan-clients.json` | RPC permissions |
| `/etc/vlan-client-labels` | Custom device labels |

---

## Backup

By default, LuCI backups only include UCI config files. Run this once on the router to add the dashboard files to the backup list — after that they are automatically included every time you create a backup:

```sh
cat >> /etc/sysupgrade.conf << 'EOF'
/etc/vlan-client-labels
/www/luci-static/resources/view/vlan-clients.js
/usr/share/luci/menu.d/luci-app-vlan-clients.json
/usr/share/rpcd/acl.d/luci-app-vlan-clients.json
EOF
```

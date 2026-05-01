# GL.iNet Flint 2 — VLAN Tools

A collection of shell scripts for setting up and managing VLANs on the **GL.iNet Flint 2 (MT6000)** running stock GL.iNet firmware (4.8.x / OpenWrt 21.02-SNAPSHOT) with DSA networking.

> **Disclaimer:** These scripts were developed with the assistance of AI. They have been tested on the hardware listed above, but use them at your own risk. **Always take a backup before making any changes to your router.**

---

## Tools

### [vlan-wizard](vlan-wizard/README.md)
An interactive command-line wizard for creating, listing, and removing VLANs. Handles everything automatically — bridge config, network interfaces, DHCP, firewall zones, and Wi-Fi SSIDs. Backs up your config before every change and includes a one-command rollback.

### [vlan-dashboard](vlan-dashboard/README.md)
A LuCI view that shows all connected clients grouped by VLAN. Installed directly into the GL.iNet web interface under **Network → VLAN Clients**. Supports filtering, search, sortable columns, and custom device labels.

---

## Compatibility

| Hardware | GL.iNet Flint 2 (MT6000) |
|---|---|
| Firmware | GL.iNet 4.8.x |
| OpenWrt base | 21.02-SNAPSHOT |
| Networking | DSA (Distributed Switch Architecture) |

---

## Recommended workflow

1. Use **vlan-wizard** to create your VLANs and assign SSIDs
2. Install **vlan-dashboard** to monitor which clients are on which VLAN

Both tools are independent — you can use either one on its own.

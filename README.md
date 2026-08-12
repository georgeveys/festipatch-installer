# festiPatch Installer

Automated setup script for the festiPatch server. Configures a fresh Ubuntu Server 24.04 LTS installation with everything needed to run the festiPatch application.

---

## What it installs

- **Network** — nmtui for wired and WiFi configuration
- **MySQL 8** — database, user, and credentials auto-generated
- **Node.js** — latest LTS via NodeSource
- **PM2** — process manager with boot persistence
- **UFW** — firewall with MySQL access scoped to local LAN interfaces
- **avahi-daemon** — mDNS so the device is reachable as `festipatch.local`
- **Automated backups** — hourly MySQL dumps, 7-day retention
- **Network fallback** *(optional)* — falls back to a static IP if this machine ever fails to get a DHCP lease
- **Custom MOTD** — shows hostname, IP, uptime, MySQL and app status on login

---

## Requirements

- Fresh Ubuntu Server 24.04 LTS installation (standard, not minimized)
- A `festipatch` user account created during OS install
- Internet connectivity (the script will help you configure this via nmtui at the start)

---

## Before you run

You will need a **Tailscale reusable auth key** ready to paste during setup:

1. Go to [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)
2. Click **Generate auth key**
3. Tick **Reusable**, leave **Ephemeral** off
4. Set expiry to suit (or no expiry for a permanent install key)
5. Copy the key — it starts with `tskey-auth-...`

---

## How to run

On the fresh machine, log in as the `festipatch` user and run:

```bash
curl -fsSL https://raw.githubusercontent.com/georgeveys/festipatch-installer/main/festipatch-setup.sh -o setup.sh
chmod +x setup.sh
bash setup.sh
```

> Do not pipe directly to bash (`curl ... | bash`) — the script requires keyboard input at several points and will fail if stdin is a pipe.

---

## What happens during setup

The script runs through the following steps in order:

| Step | What it does |
|------|-------------|
| 0 | Opens nmtui — configure wired and WiFi connections, then quit |
| 1 | Prompts for a machine name (e.g. `Glastonbury FOH`) displayed on login |
| 2 | Installs sudo and adds the festipatch user to sudoers |
| 3 | Updates system packages |
| 4 | Installs core dependencies |
| 5 | Configures mDNS (`festipatch-XX.local`) |
| 6 | Installs Node.js LTS |
| 7 | Installs PM2 |
| 8 | Installs and configures MySQL |
| 9 | Creates the festipatch database and user with a generated password |
| 10 | Configures UFW firewall |
| 10 | Installs Tailscale and connects to your account using the auth key |
| 11 | Generates an SSH key and pauses for you to add it to GitHub |
| 12 | Clones the festiPatch repository |
| 13 | Installs Node dependencies |
| 14 | Generates the `.env` file with database credentials and JWT secret |
| 15 | Starts the app via PM2 and configures boot persistence |
| 16 | Sets up hourly MySQL backups |
| 18 | *(optional, if you opted in)* Installs network fallback support |
| 19 | Installs custom MOTD and login banner |

---

## GitHub SSH key

During setup the script will generate an SSH key and pause with instructions. You will need to:

1. Copy the public key displayed on screen
2. Go to [github.com/settings/keys](https://github.com/settings/keys)
3. Click **New SSH key**
4. Paste the key and title it (e.g. `festipatch-21`)
5. Press Enter in the terminal to continue

This key is required to clone the private festiPatch repository.

---

## After setup

The script displays all generated credentials at the end. Save these somewhere secure — the MySQL password and JWT secret are not recoverable after the terminal session closes (though they are written to the `.env` file on disk).

```
MySQL Password:  <generated>
JWT Secret:      <generated>
App .env:        /var/www/festipatch/server/.env
Backups:         /var/backups/festipatch/
App URL:         http://festipatch.local
```

Verify the app is running:

```bash
pm2 list
```

---

## Network Fallback

If you answer yes to the "Enable network fallback support?" prompt, the setup script installs `festipatch-network-fallback.sh` to `/usr/local/bin/` and a cron job (`/etc/cron.d/festipatch-network-fallback`) that runs it as root every 5 minutes — same pattern as the hourly MySQL backup.

This installs the *mechanism* only. It has nothing to fall back to until you set an actual fallback IP, prefix, and gateway from the app itself — **Admin → Settings → General → Network Fallback** (only visible there because `NETWORK_FALLBACK_ENABLED=true` was added to `.env` when you opted in). Saving in the app writes `server/network-fallback-config.json`; the cron script reads that file and maintains a low-priority NetworkManager connection profile (`festipatch-fallback-static`) for it.

It's deliberately non-destructive:
- It never touches the machine's normal DHCP connection or rewrites any existing network config — it only ever adds one *additional*, lower-priority connection profile.
- NetworkManager itself decides when to use it — it only activates the fallback profile if the DHCP connection genuinely fails to get a lease.
- Undoing it completely is one command: `sudo nmcli connection delete festipatch-fallback-static` (or just clear the 3 fields in the app and save — the cron script removes the profile on its next run).

Test it by hand before trusting the cron job:

```bash
sudo /usr/local/bin/festipatch-network-fallback.sh --dry-run
```

This logs what it *would* do (creating/updating/removing the profile) without actually running any `nmcli` commands. Real output and errors are logged to `/var/log/festipatch-network-fallback.log` either way.

> **Test on spare hardware first.** This changes real network behaviour on a machine you may only have local access to — verify it actually fails over the way you expect before relying on it for a live event.

---

## Rerunning the script

The script is idempotent for most steps — it checks before installing and skips steps that are already complete. If you need to reconfigure networking, run `sudo nmtui` directly.

---

## Repo structure

```
festipatch-installer/
├── README.md
├── festipatch-setup.sh
└── festipatch-network-fallback.sh
```

---

## License

MIT — George Veys 2026

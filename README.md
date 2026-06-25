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
- **Custom MOTD** — shows hostname, IP, uptime, MySQL and app status on login

---

## Requirements

- Fresh Ubuntu Server 24.04 LTS installation (standard, not minimized)
- A `festipatch` user account created during OS install
- Internet connectivity (the script will help you configure this via nmtui at the start)

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
| 5 | Configures mDNS (`festipatch.local`) |
| 6 | Installs Node.js LTS |
| 7 | Installs PM2 |
| 8 | Installs and configures MySQL |
| 9 | Creates the festipatch database and user with a generated password |
| 10 | Configures UFW firewall |
| 11 | Generates an SSH key and pauses for you to add it to GitHub |
| 12 | Clones the festiPatch repository |
| 13 | Installs Node dependencies |
| 14 | Generates the `.env` file with database credentials and JWT secret |
| 15 | Starts the app via PM2 and configures boot persistence |
| 16 | Sets up hourly MySQL backups |
| 17 | Installs custom MOTD and login banner |

---

## GitHub SSH key

During setup the script will generate an SSH key and pause with instructions. You will need to:

1. Copy the public key displayed on screen
2. Go to [github.com/settings/keys](https://github.com/settings/keys)
3. Click **New SSH key**
4. Paste the key and title it (e.g. `festipatch-glastonbury`)
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
App URL:         http://festipatch.local:3001
```

Verify the app is running:

```bash
pm2 list
```

---

## Rerunning the script

The script is idempotent for most steps — it checks before installing and skips steps that are already complete. If you need to reconfigure networking, run `sudo nmtui` directly.

---

## Repo structure

```
festipatch-installer/
├── README.md
└── festipatch-setup.sh
```

---

## License

MIT — George Veys 2026

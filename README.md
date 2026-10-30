# Sirena HR server on Windows

Runs the whole of Sirena HR on one Windows machine: the database, the API and the website.
Phones and browsers reach it at `https://hr.sirenatech.com` through Cloudflare.
You manage the database from your laptop at `db.sirenatech.com`, from allowlisted IPs only.
You or Claude administer the machine over SSH. Tailscale is a second way in for when your IP changes.

```
Phones / browsers ─HTTPS─► Cloudflare ─► :443 Caddy ─┬─► C:\sirena\www (website)
                                                     └─► 127.0.0.1:3000 API ─► PostgreSQL 17
pgAdmin / DBeaver ─TLS, allowlisted IPs─► :5432 ──────────────────────────────►┘
You / Claude ─SSH key, allowlisted IPs or Tailscale─► :22    Remote Desktop ─Tailscale only─► :3389
```

> **Want an AI assistant to guide you through it?** Open [AI_SETUP_PROMPT.md](AI_SETUP_PROMPT.md) and paste its prompt into Claude Code or Cursor on the server.

**What's on the internet:**
- Port 443, which only accepts traffic from Cloudflare.
- Ports 5432 and 22, which only accept the IPs you allowlist.

Everything else is closed.

---

## Part 1: Before you go to the server (on your laptop, about 20 minutes)

### 1.1 About this repo
This repo is only the setup kit. The app code stays in `hilokeshrm/sirena-hr`. `setup.ps1` clones that repo onto the server with a read-only deploy key. After setup, the server runs these same scripts from its clone (`C:\sirena\repo\ops\windows`), so updates to the scripts go into `sirena-hr`.

### 1.2 Make an SSH key for this laptop
```powershell
ssh-keygen -t ed25519 -f $HOME\.ssh\sirena_server -C "laptop"
Get-Content $HOME\.ssh\sirena_server.pub     # copy this line; you'll paste it on the server
```

### 1.3 Find your laptop's public IP
```powershell
(Invoke-RestMethod https://ifconfig.me/ip).Trim()
```

### 1.4 Cloudflare (dash.cloudflare.com > sirenatech.com)

**DNS > Records**
| Type | Name | Content | Proxy |
|---|---|---|---|
| A | `hr` | server's static IP | **Proxied** (orange cloud) |
| A | `db` | server's static IP | **DNS only** (grey cloud): Cloudflare can't carry Postgres traffic |

**SSL/TLS > Overview**
- Set the encryption mode to **Full (strict)**.

**SSL/TLS > Edge Certificates**
- Turn on **Always Use HTTPS**.

**SSL/TLS > Origin Server > Create Certificate**
1. Choose RSA (2048).
2. Hostnames: `hr.sirenatech.com`.
3. Validity: 15 years.
4. Leave the page open. Setup asks you to paste the **Origin Certificate** and the **Private Key**, and Cloudflare shows the key only once.

### 1.5 Router at the server's site
- Give the server a fixed LAN address (DHCP reservation).
- Forward these TCP ports to that address:
  - **443**: the website and API
  - **5432**: Postgres
  - **22**: SSH
- Do **not** forward 3389. Remote Desktop goes over Tailscale only.

---

## Part 2: At the server (about 45 minutes, most of it waiting for installs)

The machine needs **Windows 10/11 Pro** or Server. Home edition can't accept Remote Desktop connections, though everything else works.

### 2.1 Get the scripts
Download https://github.com/hilokeshrm/sirena-hr-server/archive/refs/heads/main.zip (no sign-in needed). Extract it, for example to `C:\Users\<you>\Downloads\sirena-hr-server-main`.

Then, in PowerShell:
```powershell
cd C:\Users\<you>\Downloads\sirena-hr-server-main
Get-ChildItem -Recurse | Unblock-File
Copy-Item config.example.psd1 config.psd1
notepad config.psd1          # check Domain, DbHost, RepoSsh, Branch; save
```

### 2.2 Run setup
Open PowerShell **as Administrator** (right-click > Run as administrator), in the same folder:
```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -AllowIp <your laptop IP> -AllowLabel laptop
```
It stops for you four times:
1. **Tailscale sign-in:** a browser opens. Sign in with the account you'll use on your laptop and phone.
2. **Deploy key:** it prints a line starting `ssh-ed25519`. On GitHub, go to repo > Settings > Deploy keys > Add deploy key, paste it, and leave *Allow write access* **off**. Then press Enter.
3. **Origin certificate:** Notepad opens twice. Paste the Cloudflare **Origin Certificate**, save and close. Then paste the **Private Key**, save and close.
4. **First data:**
   - `1` for an empty company with one super admin (real use). It asks for your email and name.
   - `2` for the demo company with 9 people (trying it out).

It ends by printing a status report. Every line should be clean. *API (public)* may fail for a few minutes while DNS updates.

### 2.3 Let your laptop in over SSH
Still in the Administrator PowerShell:
```powershell
.\add-ssh-key.ps1 -Key "<the line from step 1.2>"
```

### 2.4 Take these to your laptop
Use a password manager for the passwords, and a USB stick or similar for the certificate file:

| What | Where on the server |
|---|---|
| Admin database password | `C:\sirena\secrets\db-admin.txt` |
| Read-only database password | `C:\sirena\secrets\db-ro.txt` |
| Super admin password (option 1) | `C:\sirena\secrets\first-admin-password.txt` |
| Demo login password (option 2) | `C:\sirena\secrets\seed-password.txt` |
| Database CA certificate | `C:\sirena\sirena-db-ca.crt` |

Don't take `pg-superuser.txt`, `jwt.txt` or `deploy_key`. They never need to leave the machine.

### 2.5 Two settings only you can change
- **BIOS:** set *Restore on AC power loss* to **Power On**, so the server comes back after a power cut.
- **Windows sign-in:** keep the account password. SSH uses keys, but Windows still needs a password on the account.

---

## Part 3: Back on your laptop

### 3.1 SSH shortcuts
Add this to `C:\Users\<you>\.ssh\config`:
```
Host sirena
    HostName <server static IP>
    User <Windows user name on the server>
    IdentityFile ~/.ssh/sirena_server

Host sirena-ts
    HostName <server Tailscale IP, shown in the status report>
    User <Windows user name on the server>
    IdentityFile ~/.ssh/sirena_server
```
Install Tailscale on the laptop and sign in with the same account. Then test:
```powershell
ssh sirena "C:\sirena\repo\ops\windows\status.ps1"
```

### 3.2 pgAdmin (or DBeaver)
| Field | Value |
|---|---|
| Host | `db.sirenatech.com` |
| Port | `5432` |
| Database | `sirena_hr` |
| User | `sirena_admin` (read-write) or `sirena_ro` (read-only) |
| SSL mode | `verify-full` |
| Root certificate | the `sirena-db-ca.crt` you copied |

For psql: `psql "host=db.sirenatech.com dbname=sirena_hr user=sirena_admin sslmode=verify-full sslrootcert=C:/path/sirena-db-ca.crt"`

### 3.3 The app
- **Website:** https://hr.sirenatech.com. Sign in and change the first password from the profile page.
- **Android:** build the APK against the public API.
  ```powershell
  cd sirena-hr\app
  flutter build apk --release --dart-define=API_BASE=https://hr.sirenatech.com/api
  ```

### 3.4 Alerts (free, 10 minutes)
- **[UptimeRobot](https://uptimerobot.com):** add an HTTP monitor on `https://hr.sirenatech.com/api/health`, and turn on alerts to your phone or email.
- **[Healthchecks.io](https://healthchecks.io):** create a check with period 1 day and grace 2 hours, then copy its ping URL. On the server, put the URL in `BackupPingUrl` in `C:\sirena\config.psd1`. If a night's backup doesn't arrive, you get an email.
- **Off-machine backup copy:** set `OffsiteDir` (a second disk or a NAS) or `RcloneRemote` (Backblaze B2, Google Drive and others) in the same file. Do this early. A backup that lives only on the server's own disk doesn't survive that disk dying.

---

## Day to day

Everything below runs on the server. Either open `ssh sirena` and type the command, or run it in one go: `ssh sirena "C:\sirena\repo\ops\windows\<script> ..."`.
Or ask Claude, for example "check the Sirena server", "deploy main", or "allow 203.0.113.9 for Meena". It runs the same commands over SSH.

| Task | Command (in `C:\sirena\repo\ops\windows`) |
|---|---|
| Health report | `.\status.ps1` |
| Deploy latest code | `.\deploy.ps1` |
| Deploy / roll back to a commit | `.\deploy.ps1 -Ref <commit>` |
| Let an IP reach the database + SSH | `.\allow-ip.ps1 -Ip 203.0.113.9 -Label "meena home"` |
| Database only / SSH only | add `-DbOnly` / `-SshOnly` |
| List allowed IPs | `.\allow-ip.ps1 -List` |
| Remove one | `.\revoke-ip.ps1 -Label "meena home"` |
| Read-only query | `.\sql.ps1 'SELECT code, "fullName", role FROM "Employee"'` |
| Write query (careful) | `.\sql.ps1 -Write '...'` |
| Back up now | `.\backup.ps1 -Kind manual` |
| Restore latest backup | `.\restore.ps1 -Latest` (takes a safety backup first) |
| Restore a specific file | `.\restore.ps1 -File C:\sirena\backups\daily\<file>.dump` |
| Re-apply setup (after Windows or tool updates) | `.\setup.ps1` (safe to re-run) |

**When your IP changes and you're locked out:** connect with Tailscale (`ssh sirena-ts`), run `allow-ip.ps1` with the new IP, then `revoke-ip.ps1` the old one.

### What runs automatically
| When | What |
|---|---|
| Always | Services `sirena-postgres`, `SirenaApi` and `SirenaCaddy` start on boot and restart if they crash |
| Daily 02:00 | `backup.ps1`: database dump plus uploaded files. Keeps 14 daily and 8 weekly backups, plus the last 10 pre-deploy backups |
| Sunday 04:00 | `restore-test.ps1`: loads the latest backup into a scratch database to prove it restores |
| Monday 05:00 | `refresh-cloudflare.ps1`: keeps the port-443 allowlist in step with Cloudflare's IP ranges |
| Windows Update | Restarts only between 23:00 and 06:00 |

### Where things are
| Path | What |
|---|---|
| `C:\sirena\config.psd1` | Settings (edit, then re-run `setup.ps1` for firewall or service changes) |
| `C:\sirena\secrets\` | Generated passwords and the deploy key (Administrators only) |
| `C:\sirena\repo\` | The code; `backend\.env` holds the API settings |
| `C:\sirena\www\` | The built website |
| `C:\sirena\pgdata\` | PostgreSQL data; logs in `pgdata\log\` |
| `C:\sirena\files\` | Files uploaded to projects |
| `C:\sirena\backups\` | `daily`, `weekly`, `predeploy`, `prerestore`, `files` |
| `C:\sirena\logs\` | `api.log`, `caddy.log`, `caddy-access.log`, `backup.log`, `deploy-*.log` |
| `C:\sirena\certs\` | Cloudflare origin certificate and the database certificate authority |

### Troubleshooting
- **API (local) failing:** read the end of `C:\sirena\logs\api.log`, then `Restart-Service SirenaApi`.
- **API (public) failing but local is fine:** check `caddy.log`, check that port 443 is still forwarded on the router, and that Cloudflare is in Full (strict) mode with `hr` proxied.
- **Can't connect from pgAdmin:** is your current IP on `allow-ip.ps1 -List`? Is port 5432 forwarded? Is `db` set to DNS only (grey cloud)?
- **Deploy failed:** the script rolls back automatically and says so. Its full log is `C:\sirena\logs\deploy-<time>.log`.
- **Database certificate expiring** (the status report warns 30 days ahead): re-run `setup.ps1` to renew it. The CA stays the same, so clients need no change.

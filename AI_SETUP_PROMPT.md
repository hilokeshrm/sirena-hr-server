# Prompt for Claude Code or Cursor on the server

Use this to have an AI coding assistant walk you through the setup on the server machine.

1. Install [Claude Code](https://claude.com/claude-code) or [Cursor](https://cursor.com) on the server.
2. Download and extract https://github.com/hilokeshrm/sirena-hr-server/archive/refs/heads/main.zip (for example to `Downloads\sirena-hr-server-main`).
3. Start the assistant **as Administrator**, opened on that folder:
   - Claude Code: open PowerShell with Run as administrator, `cd` to the folder, run `claude`.
   - Cursor: right-click Cursor > Run as administrator, then File > Open Folder.
4. Paste everything inside the box below into its chat (Cursor: use Agent mode).

Have these ready:
- the server's static public IP
- your laptop's public IP and its SSH public key line (`ssh-ed25519 ...`)
- the Cloudflare origin certificate page open in a browser on the server

---

````text
You are setting up the Sirena HR production server on THIS Windows machine, using the
setup kit in the current folder. Read README.md fully first; it is the source of truth.
Then work through the phases below in order. Be brief, and tell me what you're doing at each step.

GROUND RULES
- Never print, paste or summarise the contents of C:\sirena\secrets\*, private keys, or
  the Cloudflare origin private key. When I need a secret, tell me the file path.
- Don't open firewall ports, disable the firewall, turn on SSH password login, or change
  pg_hba.conf by hand. Allowlist changes go through allow-ip.ps1 / revoke-ip.ps1 only.
- setup.ps1 is interactive (browser sign-in, Enter prompts, Notepad windows), and your
  shell cannot answer prompts. Do NOT run setup.ps1 yourself; I run it in my own
  Administrator PowerShell window. You prepare, check, and fix.
- Ask me before anything destructive: restore.ps1, dropping data, deleting C:\sirena,
  uninstalling software, or rebooting.
- Don't push to any git repository or change anything on GitHub except the deploy-key
  step I do myself.
- If a step fails, read the error and the logs in C:\sirena\logs, explain the cause in one
  or two sentences, fix it, and tell me exactly what to re-run.

PHASE 1: CHECKS (you run these)
1. Confirm the shell is elevated (Administrator). If not, stop and tell me how to restart you as admin.
2. Report: Windows edition and version (Remote Desktop needs Pro or Server; Home is fine
   otherwise), free space on C: (need 30 GB+), whether winget works, and whether these
   ports are already in use locally: 443, 5432, 3000, 22.
3. Ask me for: the server's static public IP, my laptop's public IP, the Windows user
   name I'll SSH in as, and whether this is the REAL company or the DEMO data.
4. Check DNS: hr.sirenatech.com should resolve to Cloudflare addresses (proxied), and
   db.sirenatech.com should resolve to the static IP (DNS only). If they don't, tell me
   the exact Cloudflare DNS records to fix (README Part 1.4) and wait.
5. From README Part 1.4 and 1.5, list the Cloudflare and router settings that must already
   be done. Ask me to confirm each one (you can't see them).

PHASE 2: CONFIG (you do this)
6. Copy config.example.psd1 to config.psd1, show me its values, and change any I correct.
   Defaults: Domain hr.sirenatech.com, DbHost db.sirenatech.com,
   RepoSsh git@github.com:hilokeshrm/sirena-hr.git, Branch main.
7. Run: Get-ChildItem -Recurse | Unblock-File

PHASE 3: SETUP (I run this)
8. Give me the exact command to paste into my Administrator PowerShell, in this folder:
   powershell -ExecutionPolicy Bypass -File .\setup.ps1 -AllowIp <my laptop IP> -AllowLabel laptop
   Before I run it, explain the four places it will stop for me:
   Tailscale browser sign-in; GitHub deploy key (repo hilokeshrm/sirena-hr > Settings >
   Deploy keys, write access OFF); Notepad twice for the Cloudflare origin certificate then
   the private key; the first-data choice (1 = real company with one super admin,
   2 = demo company).
9. Wait for me to say it finished or paste an error. On an error, diagnose it, fix the
   cause, and tell me to re-run the same command (setup is safe to re-run).

PHASE 4: AFTER SETUP (you run these)
10. Ask me for my laptop's SSH public key line, then run:
    .\add-ssh-key.ps1 -Key "<that line>"
11. Run C:\sirena\repo\ops\windows\status.ps1 and go through every line marked "!".
    "API (public)" may fail for a few minutes after a DNS change; recheck before digging in.
12. Check from this machine:
    - https://hr.sirenatech.com loads the sign-in page
    - https://hr.sirenatech.com/api/health returns ok
    - Get-NetFirewallRule -Name 'Sirena-*' lists rules for HTTPS, Postgres, SSH (and RDP if enabled)
13. Tell me what to copy to my laptop, BY PATH ONLY (don't show the contents):
    C:\sirena\secrets\db-admin.txt, C:\sirena\secrets\db-ro.txt,
    C:\sirena\secrets\first-admin-password.txt or seed-password.txt,
    and C:\sirena\sirena-db-ca.crt
14. Run "& 'C:\Program Files\Tailscale\tailscale.exe' ip -4" and give me:
    the static IP, the Tailscale IP, and the Windows user name, ready to paste into my
    laptop's ~/.ssh/config (README Part 3.1).
15. Remind me of the steps only I can do: BIOS "Restore on AC power loss = Power On",
    UptimeRobot on /api/health, Healthchecks.io ping URL in C:\sirena\config.psd1
    (BackupPingUrl), and an off-machine backup location (OffsiteDir or RcloneRemote).
16. Finish with a short summary: what's running, what's left for me, and anything you
    weren't able to verify.
````

# Personal Backup Toolkit (rsync over SSH)

This repository provides a simple incremental backup setup:

- One Ubuntu server acts as the backup target.
- Each client device pushes selected folders via `rsync` over SSH.
- Only changed file blocks are transferred.

It is built for your setup:

- Backup server reachable by SSH at `100.68.188.2`
- Clients: Windows 11, Android (Termux), Pop!_OS

## Repository Layout

- `server/setup_ubuntu_backup_server.sh`: installs/primes backup user and directories.
- `server/add_client_key.sh`: adds a client SSH public key and creates its device folder.
- `client/unix/run_backup.sh`: client for Pop!_OS and Android Termux.
- `client/unix/client.conf.example`: Unix client config example.
- `client/android/client.termux.conf.example`: Android Termux config example.
- `client/windows/Run-Backup.ps1`: Windows 11 client script.
- `client/windows/client.windows.json.example`: Windows client config example.

## 1) Set Up the Ubuntu Backup Server

Copy this repo to the server, then run:

```bash
sudo bash server/setup_ubuntu_backup_server.sh \
  --backup-user backup \
  --backup-root /srv/backups
```

What this does:

- Installs `openssh-server` and `rsync`
- Creates user `backup` (key-based login)
- Creates backup root `/srv/backups`
- Adds a restrictive SSH match block for user `backup`

## 2) Create SSH Keys Per Client

Use one key per device.

Pop!_OS / Android (Termux):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/pcloud_backup_ed25519 -C "popos-backup"
```

Windows PowerShell:

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\pcloud_backup_ed25519" -C "win11-backup"
```

## 3) Register Each Client Key on Server

For each client key, copy the `.pub` file onto the server, then run:

```bash
sudo bash server/add_client_key.sh \
  --key-file /tmp/client.pub \
  --device-name popos-laptop \
  --backup-user backup \
  --backup-root /srv/backups
```

Repeat for `win11-main`, `android-phone`, etc.

## 4) Configure and Run Clients

### Pop!_OS (and other Linux)

```bash
mkdir -p ~/.config/pcloud-backup
cp client/unix/client.conf.example ~/.config/pcloud-backup/client.conf
```

Edit `~/.config/pcloud-backup/client.conf` (device name, folders, key path), then run:

```bash
bash client/unix/run_backup.sh --dry-run
bash client/unix/run_backup.sh
```

### Android (Termux)

Install requirements:

```bash
pkg update
pkg install rsync openssh
termux-setup-storage
```

Create config from example:

```bash
mkdir -p ~/.config/pcloud-backup
cp client/android/client.termux.conf.example ~/.config/pcloud-backup/client.conf
```

Run:

```bash
bash client/unix/run_backup.sh --dry-run
bash client/unix/run_backup.sh
```

### Windows 11

Install MSYS2 + rsync:

```powershell
winget install -e --id MSYS2.MSYS2
```

Then open an MSYS2 shell once and run:

```bash
pacman -S --noconfirm rsync openssh
```

You can either:
- add `C:\msys64\usr\bin` to PATH, or
- keep explicit `rsyncCommand` / `sshCommand` in the JSON config (recommended).

Optional JSON keys for explicit binaries:

```json
"rsyncCommand": "C:/msys64/usr/bin/rsync.exe",
"sshCommand": "C:/Windows/System32/OpenSSH/ssh.exe"
```

Optional JSON key for SSH connect timeout (seconds, default 15):

```json
"sshConnectTimeoutSeconds": 15
```

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.config\pcloud-backup" | Out-Null
Copy-Item .\client\windows\client.windows.json.example "$env:USERPROFILE\.config\pcloud-backup\client.windows.json"
```

Edit `client.windows.json`, then run:

```powershell
powershell -ExecutionPolicy Bypass -File .\client\windows\Run-Backup.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File .\client\windows\Run-Backup.ps1
```

If Windows reports `connection unexpectedly closed`, run these checks:

```powershell
ssh -i "$env:USERPROFILE\.ssh\pcloud_backup_ed25519" backup@100.68.188.2 "echo ssh-ok && command -v rsync"
ssh -i "$env:USERPROFILE\.ssh\pcloud_backup_ed25519" backup@100.68.188.2 "mkdir -p /srv/backups/win11-main/test && ls -ld /srv/backups/win11-main"
```

Both commands must succeed before `Run-Backup.ps1` will work.

If SSH says `This account is currently not available`, the backup user shell is likely `nologin`.
On Ubuntu server, run:

```bash
sudo usermod -s /bin/bash backup
sudo bash server/setup_ubuntu_backup_server.sh --backup-user backup --backup-root /srv/backups
```

## 5) Scheduling

Pop!_OS cron example (every 6 hours):

```cron
0 */6 * * * /usr/bin/bash /path/to/personal_cloud/client/unix/run_backup.sh >> /var/log/pcloud-backup.log 2>&1
```

Windows Task Scheduler action:

- Program/script: `powershell.exe`
- Arguments: `-ExecutionPolicy Bypass -File C:\path\to\personal_cloud\client\windows\Run-Backup.ps1`

Android: use Termux:Tasker or `termux-job-scheduler` to run `client/unix/run_backup.sh` periodically.

## Restore Example

Restore Pop!_OS Documents to a local folder:

```bash
rsync -av backup@100.68.188.2:/srv/backups/popos-laptop/documents/ ~/restore/documents/
```

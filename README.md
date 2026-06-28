# Cerebro: State-Monitoring Differential Backup Engine

> **Version:** v3.4  
> **Core Philosophy:** "Verify First, Commit Later."

## 1. Overview

Cerebro is a state-monitoring backup engine for Linux environments. Unlike simple file replication scripts or standard `tar` cron jobs, Cerebro operates on a verification pipeline: it stages files, inspects content changes against the latest valid archive across multiple destinations, and only commits a new backup if actual content changes are detected.

### Key Architectural Characteristics:
* **Zero External Dependencies (Offline-First):** Cerebro operates entirely offline. It does not require an internet connection, Git authentication, cloud APIs, or third-party webhooks to track state changes, compute text diffs, maintain metadata, or create backups.
* **Portable & Self-Contained:** Because the engine runs entirely out of its own directory, it does not modify the global user environment, install system libraries, or rely on shared global state. 
* **Multi-Instance Isolation:** You can run multiple instances of Cerebro in parallel by placing them in separate directories (e.g., configuring `/opt/cerebro-configs/` and `/opt/cerebro-db/` independently). By simply copying the folder structure and naming the script files uniquely, non-technical users can maintain isolated, specialized backup profiles without managing complex environment variables or shared system locks.
* **Scalable Monitoring Overhead:** The engine scales dynamically based on configuration. It can run as a zero-overhead, completely hands-off local backup cron job, or scale up to a high-frequency, multi-destination configuration auditor with pre- and post-run service execution hooks.
* **Target Scenarios:** Designed for environments (such as self-hosted containers, databases, and configuration directories) where you need to distinguish between critical configuration changes and routine runtime file updates.

---

## 2. Key Features

Cerebro addresses standard backup limitations through three primary mechanisms:

### A. Content-Aware Filtering (Smart Change Detection)
Instead of relying solely on modification timestamps—which often trigger redundant backups for unchanged files (e.g. rotated log files or database touches)—Cerebro parses content. By combining `[NOLOG]` and `[TARDISCARD]` directives, Cerebro can detect that only temporary files or logs have changed, record the event in the log, and discard the redundant archive, reducing backup storage footprints.

### B. Inline Diff Logging
Cerebro can log text changes directly to its execution log. By configuring `[LOGDIFF]` rules for text files (such as scripts, `.env` files, or configurations), Cerebro computes unified diffs between the previous backup and the active environment, writing the specific line modifications into `cerebro.log`. This provides a continuous audit history of configurations without requiring manual extraction of archives.

### C. Multi-Destination Sync
Cerebro supports writing backups to multiple storage locations (`[DESTINATIONS]`). Before a backup run, it scans all configured destinations to locate the most recent valid backup. After creating a new backup, it replicates the archive to all active destinations, maintaining target parity.

---

## 3. Core Architecture

Cerebro follows a strict execution pipeline to ensure data integrity:

1.  **Startup Configuration Guard:** Validates configuration rules and verifies that all absolute paths defined in `[CRUCIAL]` are covered by a path in `[INCLUDE]`. If any crucial path is uncovered, aborts immediately.
2.  **Staging:** Creates a temporary, isolated environment in `/tmp` for comparison work.
3.  **Latest Backup Discovery:** Scans ALL `[DESTINATIONS]` to find the most recent valid backup (by timestamp), verifying backup integrity using `timeout tar -tzf` and automatically deleting corrupted archives.
4.  **Comparison:** Extracts the previous backup and performs a file-by-file diff against live data.
5.  **Decision Matrix:**
    - _Crucial Deletion:_ If a file in the previous backup matches a pattern in `[CRUCIAL]` and is missing in the new backup, abort execution immediately with code 1, deleting the new tarball (post-backup hooks are executed).
    - _No Change:_ Abort, delete staged tar, log "No changes detected."
    - _Meaningful Change (RETAIN):_ If changes are detected in files not covered by `[NOLOG]`, or matching `[LOGDIFF]` (where unified text diffs are written to `cerebro.log`), the backup is tagged as `RETAIN`.
    - _Routine Change (DISCARD):_ If changes match ONLY `[NOLOG]` patterns, the backup is tagged as `DISCARD:LATEST`.
6.  **Tagging & Metadata:** Create entry in `.tar_meta_data.txt` with the backup tag (`RETAIN` or `DISCARD:LATEST`).
7.  **Creation:** Build the final `tar.gz` archive with all excludes applied.
8.  **Verification:** Run `tar -tzf` to ensure the archive is not corrupted.
9.  **Distribution:** Use `rsync` with timeout to copy the valid archive to all reachable `[DESTINATIONS]`, falling back to direct copying via `cp -ru` if all rsync retry attempts fail.
10. **Cleanup:** If `[TARDISCARD] DISCARD=1`, prune old `DISCARD` archives from the destinations. Prune log file if `[LOGPRUNE]` enabled.
11. **Self-Maintenance:** Update cron job, remove temp files, release lock.

---

## 4. Configuration Guide

Cerebro is controlled entirely via `cerebro.cfg`. This file defines the "Intelligence" of the system.

### `[INCLUDE]` & `[EXCLUDE]`

Standard path definitions. Supports wildcards (`*`).

**How it works:**

- `[INCLUDE]`: Absolute paths to files or directories you want backed up.
- `[EXCLUDE]`: Patterns or paths to skip (logs, temp files, cache directories).

**Built-in Protection:**

- **Automatic Backup Directory Exclusion**: Cerebro automatically excludes its own `backups/` folder to prevent recursive backup loops. You do NOT need to manually add `/path/to/cerebro/backups` to `[EXCLUDE]` - the script handles this internally regardless of where you install it.

**Example:**

```ini
[INCLUDE]
/home/pi/Docker
/home/pi/.config/important-app
/etc/nginx/nginx.conf

[EXCLUDE]
*.log
*.tmp
/home/pi/Docker/container-logs
```

---

### `[LOGDIFF]` (The Inspector)

**Files matching these patterns get their CONTENT read and diffed.**

- **Use Case:** Configuration files, scripts, docker-compose files - anything where you need to see WHAT changed.
- **Behavior:** When a file matching this pattern changes, Cerebro extracts the previous version, runs `diff`, and writes the added/removed lines directly into `cerebro.log`.
- **Benefit:** Your log becomes a version control system. You can see exactly when `docker-compose.yml` changed and what lines were modified without extracting any tar files.

**What gets logged:**

```
FILE: /home/pi/Docker/docker-compose.yml
DIFFERENCE: Content changed between old and new backup
< OLD LINE:   image: nginx:1.20
> NEW LINE:   image: nginx:1.21
< OLD LINE:   - "8080:80"
> NEW LINE:   - "8081:80"
```

**Patterns:**

```ini
[LOGDIFF]
*.yml
*.sh
*.conf
*.env
*.py
*.json
```

---

### `[NOLOG]` (The Silencer)

**Files here trigger backups but DON'T log content differences.**

- **Use Case:** Binary files, databases, frequently changing data where the diff output would be useless noise.
- **Behavior:** Cerebro detects the file changed (via hash/size comparison) and triggers a backup, but it does NOT write the diff to the log file. Instead it just notes: "File X changed."
- **Why?** A 500MB `.db` file changing would create a 500MB diff in your log. This keeps logs readable while still capturing state changes.

**Common Use Cases:**

- SQLite databases (`*.db`)
- Application state files
- Binary configuration blobs
- Docker volume data that changes frequently but you don't need content-level visibility

**Example:**

```ini
[NOLOG]
/home/pi/Docker/pi-hole/data/*
/home/pi/Apps/app-state.db
*.sqlite
```

---

### `[TARDISCARD]` (Storage Retention Optimization)

**Prunes archives containing only noise-level changes (triggered by `[NOLOG]` updates).**

- **`DISCARD=0`**: Disabled. Retains all generated backup archives.
- **`DISCARD=1`**: Enabled. Activates retention optimization logic.

#### Execution Logic:
1. **Meaningful Changes (RETAIN):** If a backup contains modifications that do not match `[NOLOG]` patterns, or matches `[LOGDIFF]` patterns (unified diffs captured), it is preserved and tagged as `RETAIN`.
2. **Routine Changes Only (DISCARD):** If a backup contains modifications matching only `[NOLOG]` rules, it is tagged as `DISCARD:LATEST`.
3. **Pruning Cycle:** Upon a successful subsequent run, historical `DISCARD` archives are pruned, leaving only the single most recent archive tagged as `DISCARD:LATEST` alongside the preserved `RETAIN` archives. This ensures that long-term backup history is preserved for code and configuration changes while preventing database updates from consuming excessive storage.

---

### `[DESTINATIONS]`

**Define multiple backup storage locations.**

Cerebro treats this as an array of equals - no "primary" or "secondary". Before every run, it scans ALL destinations to find the latest backup across all of them.

**Features:**

- **Automatic hostname appending**: If you define `/mnt/nas/backup/cerebro`, Cerebro will actually write to `/mnt/nas/backup/cerebro/hostname` - this allows multiple machines to use the same NAS share without conflicts.
- **Resilience**: If one destination is offline (unmounted NAS), Cerebro continues with the available ones, using a non-blocking double-forked background monitor to check connection responsiveness.
- **Sync logic**: After creating a new backup, Cerebro attempts to copy it to ALL reachable destinations using `rsync` with timeout protection, falling back to direct copying via `cp -ru` if rsync fails.

**Example:**

```ini
[DESTINATIONS]
/media/G-Drive/backup/cerebro
/mnt/nas/backup/cerebro
/mnt/cloud-mount/backups
```

**What happens:**

- Machine hostname is `raspberrypi`
- Cerebro will write to:
  - `/media/G-Drive/backup/cerebro/raspberrypi/backup_20240215_040000-1.tar.gz`
  - `/mnt/nas/backup/cerebro/raspberrypi/backup_20240215_040000-1.tar.gz`
  - `/mnt/cloud-mount/backups/raspberrypi/backup_20240215_040000-1.tar.gz`

---

### `[SCHEDULE]` (Cron Automation)

**Control when Cerebro runs automatically.**

```ini
[SCHEDULE]
cron=1
schedule=00 04 * * 1
```

- **`cron=0`**: Disable automatic scheduling. Run manually only.
- **`cron=1`**: Enable automatic scheduling.
- **`schedule=`**: Standard cron syntax. Use https://crontab.guru/ to generate.

**Common schedules:**

- `00 04 * * *` - Daily at 4:00 AM
- `00 04 * * 1` - Weekly on Monday at 4:00 AM
- `00 */6 * * *` - Every 6 hours
- `*/30 * * * *` - Every 30 minutes (aggressive monitoring)

**Important:** Cron uses the system's local timezone. If your system timezone is UTC but you want backups at 4 AM local time, you need to convert:

```bash
# Check your timezone
timedatectl
# Or
date +%Z
```

**How it works:**
When you run `./cerebro.sh` for the first time (or any time config changes), it automatically installs/updates the cron job. You never need to manually edit crontab.

**Cron vs Manual backups:**

- **Cron backups** are named with time-based suffixes: `backup_20240215_040000-1.tar.gz` (1 = 00:00-05:59, 2 = 06:00-11:59, etc.)
- **Manual backups** are named with letter suffixes: `backup_20240215_153000-a.tar.gz`, `backup_20240215_154500-b.tar.gz` (cycling a-z)

---

### `[TRANSFER]` (Transfer Retries Settings)

**Configure copy/rsync retry attempts to destinations.**

```ini
[TRANSFER]
RETRIES=1
TIMEOUT=300
RSYNC_TIMEOUT=30
```

- **`RETRIES`**: Sets the number of `rsync` attempts to each backup destination (defaults to `3` attempts if omitted). If all attempts fail, Cerebro automatically falls back to copying files directly using `cp -ru`.
- **`TIMEOUT`**: Sets the shell-level execution limit (in seconds) for each transfer command before it is force-killed. If omitted, defaults to `300` seconds (5 minutes).
- **`RSYNC_TIMEOUT`**: Sets the connection/data inactivity timeout (in seconds) for the internal `rsync` command. If omitted, defaults to `30` seconds.

---

### `[LOGTYPE]` (Verbosity Control)

**Control what gets written to `cerebro.log`.**

```ini
[LOGTYPE]
DEBUG=0
INFO=1
NOFIRSTRUN=0
```

- **`DEBUG=1`**: Ultra-verbose. Logs every file being processed, timing info, decision trees. Use for troubleshooting.
- **`DEBUG=0`**: Production mode. Only logs significant events.
- **`INFO=1`**: Log normal operational messages (backup created, files transferred, etc.)
- **`INFO=0`**: Silent mode. Only log errors and file differences.
- **`NOFIRSTRUN=1`**: Suppress the "First run, no previous backup to compare" message. Useful if you're running Cerebro on a new system and don't want log noise.

**Recommended settings:**

- Development/Testing: `DEBUG=1, INFO=1`
- Production: `DEBUG=0, INFO=1`
- High-frequency monitoring: `DEBUG=0, INFO=0` (only log real changes)

---

### `[LOGPRUNE]` (Log File Management)

**Automatically clean old entries from `cerebro.log` without losing configuration audit history.**

```ini
[LOGPRUNE]
ENABLED=1
DISCARD_MAX_AGE_DAYS=1
```

- **`ENABLED=1`**: Active. Cerebro will prune log entries.
- **`DISCARD_MAX_AGE_DAYS=1`**: Defines the age threshold (in days) for pruning routine logs.

**Smart Retention Logic:**
Unlike standard log rotation tools that truncate the entire file or delete all historical records, Cerebro uses an intelligent parser:
- **Pruned:** Only standard run blocks, runs with no changes, and runs containing ONLY `DISCARD`-tagged changes (such as routine database or volume updates) are pruned once they exceed the maximum age.
- **Preserved:** All run blocks containing unified text diffs and configuration changes (tagged as `RETAIN`) are **preserved forever**. This ensures that your system config audit history is never lost while still keeping disk usage under control.

**Why this exists:**
If you run Cerebro frequently with verbose settings, the log file will grow rapidly. This feature prunes the routine change noise while maintaining a permanent version history of configurations.

**Recommendation:**

- High-frequency backups (< 1 hour): `DISCARD_MAX_AGE_DAYS=1`
- Daily backups: `DISCARD_MAX_AGE_DAYS=30`
- Weekly backups: `DISCARD_MAX_AGE_DAYS=365`

### `[HOOKS]` (Command Hooks)

**Execute custom scripts or commands before and after the backup process.**

This section allows you to orchestrate system state changes around your backup execution. It is particularly powerful for ensuring **application consistency** (e.g. freezing databases or stopping containers) before archiving files.

```ini
[HOOKS]
# Command to run before backup creation
PRE_BACKUP_CMD=docker-compose -f /home/pi/Docker/docker-compose.yml down

# Command to run after backup completes (or on script termination)
POST_BACKUP_CMD=docker-compose -f /home/pi/Docker/docker-compose.yml up -d
```

#### How it works:

*   **`PRE_BACKUP_CMD` (Pre-Backup Hook):**
    *   Runs immediately before the backup creation starts.
    *   **Fail-Fast Design:** If the command fails (returns a non-zero exit status), Cerebro logs the failure and **aborts immediately** without modifying your existing backups or staging files.
*   **`POST_BACKUP_CMD` (Post-Backup Hook):**
    *   Runs when the script exits.
    *   **Guaranteed Execution:** This command is bound to the script's `EXIT` trap. Even if the backup fails, the connection check times out, or the script is terminated, the post-backup hook is **guaranteed to run**. This ensures services (like Docker stacks or databases) are never left stopped or frozen.

#### Common Use Cases:

*   **Database Consistent Backups:** Lock database tables or dump a transaction log before archiving, then unlock/resume the database.
*   **Docker Container Backups:** Stop active containers (`docker stop` or `docker-compose down`) to release file locks on volumes, then restart them (`docker start` or `docker-compose up -d`).
*   **Notifications:** Send a web-hook or email alert on backup completion.

### `[CRUCIAL]` (State Protection Guard)

**Define files and folders that are absolutely essential and must never be lost.**

This section acts as a fail-fast safety check to protect your backup timeline from being corrupted if critical system or application configurations are accidentally deleted on the live system.

```ini
[CRUCIAL]
# Exact files that must not be deleted
/home/user/.ssh/id_rsa
/etc/nginx/nginx.conf
/home/user/.config/app/config.ini

# Directory contents (ensures the directory is not empty)
/home/user/projects/critical-app/*
```

#### How it works:

1. **Startup Configuration Guard:** 
   Before running the backup, Cerebro verifies that every path defined under `[CRUCIAL]` is covered by a path in `[INCLUDE]`. If a crucial path is not included in the backup, the run halts immediately with a config error.
2. **Deletion Abort Check:**
   During the comparison phase (`compare_tars`), Cerebro compares the previous backup with the newly created backup. If any file present in the previous backup matches a pattern in `[CRUCIAL]` but is missing in the new backup, the run is aborted:
   - The newly created, incomplete backup tarball is deleted.
   - The backup run exits with code `1`.
   - The global `EXIT` trap executes the `POST_BACKUP_CMD` hook to ensure your system services are restarted.
3. **Intentional Deletions:**
   If you intentionally delete a crucial file, the backup will fail until you remove its pattern or path from the `[CRUCIAL]` section in `cerebro.cfg`.

---

## 5. The Metadata System (Understanding .tar_meta_data.txt)

Cerebro maintains a hidden metadata file at `$SCRIPT_DIR/assets/.tar_meta_data.txt`. This file tracks every backup and its classification.

**Format:**

```
backup_20260215_040000-1.tar.gz:RETAIN:FIRST
backup_20260215_100000-2.tar.gz:RETAIN
backup_20260215_160000-3.tar.gz:DISCARD
backup_20260215_220000-4.tar.gz:DISCARD:LATEST
```

**Tags:**

- **`RETAIN`**: This backup contains meaningful changes (e.g. file content differences matching `[LOGDIFF]`, new files, or non-excluded deleted files). **Always kept.**
- **`RETAIN:FIRST`**: The first backup created on a system (which has no previous backup to compare against). **Always kept.**
- **`DISCARD`**: This backup contains ONLY changes that matched `[NOLOG]` patterns. **Eligible for deletion.**
- **`DISCARD:LATEST`**: The most recent DISCARD backup. **Protected until a newer backup is created.**

**TARDISCARD Logic:**

```
Current state:
  backup_001.tar.gz:RETAIN
  backup_002.tar.gz:DISCARD
  backup_003.tar.gz:DISCARD
  backup_004.tar.gz:DISCARD:LATEST

New backup created (backup_005.tar.gz):
  - If it's RETAIN  → Keep it, convert current DISCARD:LATEST to DISCARD, and clean up older DISCARD backups.
  - If it's DISCARD → Promote backup_005 to DISCARD:LATEST, and delete backup_002 and backup_003.

Result (if backup_005 is DISCARD):
  backup_001.tar.gz:RETAIN
  backup_004.tar.gz:DISCARD
  backup_005.tar.gz:DISCARD:LATEST
```

This ensures you always have:

1. All meaningful configuration and code history (RETAIN files)
2. The two most recent backup states (current + previous)

---

## 6. Usage Scenarios

### Scenario A: The "Set and Forget" Homelab

**Setup:**

```ini
[INCLUDE]
/home/pi/Docker

[EXCLUDE]
*.log
*.tmp

[LOGDIFF]
*.yml
*.sh
*.conf

[NOLOG]
/home/pi/Docker/*/data/*

[SCHEDULE]
cron=1
schedule=00 04 * * *

[TARDISCARD]
DISCARD=1
```

**Result:**
- If no changes are detected, the backup is skipped.
- If a configuration file changes, a backup is created, tagged as `RETAIN`, textual differences are logged, and the archive is synced to the NAS.
- If only database files or volume data change, a backup is created but tagged as `DISCARD:LATEST`, which will be cleaned up on the subsequent run to minimize storage usage.

---

### Scenario B: The Developer/Scripter

**Setup:**

```ini
[INCLUDE]
/home/user/scripts
/home/user/projects

[LOGDIFF]
*.sh
*.py
*.js
*.json
*.md

[SCHEDULE]
cron=1
schedule=*/30 * * * *

[TARDISCARD]
DISCARD=0
```

**Result:**
Cerebro runs every 30 minutes. 
- Creates a backup only when changes are detected in scripts or codebase.
- Writes unified code differences directly to `cerebro.log`.
- Retains all historical backups for granular version tracking.

---

### Scenario C: Critical Infrastructure

**Setup:**

```ini
[INCLUDE]
/etc
/var/www
/opt/production-app

[LOGDIFF]
*.conf
*.ini
*.yml

[DESTINATIONS]
/mnt/local-raid/backup
/mnt/nas/backup
/mnt/cloud-sync/backup

[SCHEDULE]
cron=1
schedule=00 */4 * * *

[TARDISCARD]
DISCARD=1

[LOGPRUNE]
ENABLED=1
DISCARD_MAX_AGE_DAYS=7
```

**Result:**
Cerebro runs every 4 hours.
- Replicates backup archives across all configured locations (RAID, NAS, Cloud).
- If one destination goes offline, Cerebro copies to the remaining active ones.
- Log pruning automatically trims `cerebro.log` to keep its size managed.

---

### Scenario D: Paranoid Monitoring

**Setup:**

```ini
[INCLUDE]
/home/pi/.ssh
/etc/passwd
/etc/shadow
/etc/sudoers
/var/log/auth.log

[LOGDIFF]
*

[SCHEDULE]
cron=1
schedule=*/5 * * * *

[LOGTYPE]
DEBUG=1
INFO=1

[TARDISCARD]
DISCARD=0
```

**Result:**
Cerebro runs every 5 minutes.
- Monitors critical system configuration directories.
- Logs immediate warnings and line-level diffs on configuration changes.
- Retains all archives to maintain a complete history of system changes.

---

## 7. What the Log File Actually Shows

**Example cerebro.log output after a run where docker-compose.yml changed:**

```
2026-02-15 04:00:01 - [INFO] ========== BACKUP RUN STARTED ==========
2026-02-15 04:00:01 - [INFO] Run Type: cron
2026-02-15 04:00:01 - [INFO] Version: v3.2
2026-02-15 04:00:01 - [INFO] Backup Name: backup_20260215_040001-1.tar.gz
2026-02-15 04:00:01 - [Sync Destinations] Synced backups from /media/G-Drive/backup/cerebro/raspberrypi to all destinations.
2026-02-15 04:00:02 - [Backup Creation] Starting backup creation...
2026-02-15 04:00:05 - [Backup Creation] Tar file created: /home/pi/Apps/cerebro/backups/backup_20260215_040001-1.tar.gz
2026-02-15 04:00:10 - [Comparison] [MOD] /home/pi/Docker/docker-compose.yml
2026-02-15 04:00:10 - [Comparison] [-] 'image: nginx:1.20'
2026-02-15 04:00:10 - [Comparison] [+] 'image: nginx:1.21'
2026-02-15 04:00:10 - [Comparison] [-] '- "8080:80"'
2026-02-15 04:00:10 - [Comparison] [+] '- "8081:80"'
2026-02-15 04:00:11 - [Comparison] [META] Backup tagged as: RETAIN
2026-02-15 04:00:11 - [Comparison] [META] Changes detected between:
2026-02-15 04:00:11 - [Comparison] [META] New: /home/pi/Apps/cerebro/backups/backup_20260215_040001-1.tar.gz
2026-02-15 04:00:11 - [Comparison] [META] Previous: /mnt/nas/backup/cerebro/raspberrypi/backup_20260214_040000-1.tar.gz
2026-02-15 04:00:12 - [Verification] Tar file verified successfully.
2026-02-15 04:00:12 - [Verification] Backup created: /home/pi/Apps/cerebro/backups/backup_20260215_040001-1.tar.gz
2026-02-15 04:00:15 - [Transfer] Backup copied to /media/G-Drive/backup/cerebro/raspberrypi/backup_20260215_040001-1.tar.gz via rsync.
2026-02-15 04:00:20 - [Transfer] Backup copied to /mnt/nas/backup/cerebro/raspberrypi/backup_20260215_040001-1.tar.gz via rsync.
2026-02-15 04:00:21 - [Cleanup] Backup removed from /home/pi/Apps/cerebro/backups/backup_20260215_040001-1.tar.gz
2026-02-15 04:00:21 - [Tar Removal] Removed backup_20260214_100000-2.tar.gz from /media/G-Drive/backup/cerebro/raspberrypi.
2026-02-15 04:00:21 - [Tar Removal] Removed backup_20260214_100000-2.tar.gz from /mnt/nas/backup/cerebro/raspberrypi.
2026-02-15 04:00:21 - [INFO] ========== BACKUP RUN ENDED ==========
```

**Key takeaways:**

- You can see EXACTLY what changed (nginx version and port mapping)
- You know which backup contains the change
- You can see the transfer was successful to both destinations
- You can see old DISCARD backups were cleaned up

---

## 8. How to Restore from Backup

Cerebro creates standard `.tar.gz` files. Restoring is straightforward:

### Full Restore

```bash
# Find the backup you want
ls /mnt/nas/backup/cerebro/raspberrypi/

# Extract everything
cd /
sudo tar -xzf /mnt/nas/backup/cerebro/raspberrypi/backup_20240215_040000-1.tar.gz

# This restores all files to their original locations
```

### Selective Restore (Single File)

```bash
# List contents
tar -tzf backup_20240215_040000-1.tar.gz | grep docker-compose

# Extract specific file
tar -xzf backup_20240215_040000-1.tar.gz home/pi/Docker/docker-compose.yml

# File is now in ./home/pi/Docker/docker-compose.yml (relative path)
# Copy it to the actual location
sudo cp home/pi/Docker/docker-compose.yml /home/pi/Docker/docker-compose.yml
```

### Restore to a Different Location (Inspection)

```bash
# Extract to a temp directory
mkdir /tmp/restore-check
tar -xzf backup_20240215_040000-1.tar.gz -C /tmp/restore-check

# Now you can browse /tmp/restore-check to see the backed up state
# without overwriting live data
```

### Find Which Backup Contains a Specific State

**Use the log file:**

```bash
# Search for when a specific file changed
grep "docker-compose.yml" cerebro.log

# Look for the backup name associated with that change
# Then extract that specific backup
```

---

## 9. Recall — Restore Utility

> **Recall is a companion recovery utility for Cerebro.** All recovery operations in Section 8 can be performed manually. Recall automates search, path construction, and extraction.

### Functional Overview

`recall.sh` is a CLI extraction utility that reads `cerebro.cfg` to search and extract target files or directories from the latest backup across all configured destinations.

**Key Features:**

- **Automatic Configuration Reading:** Resolves backup destinations and targets the latest valid archive automatically.
- **Fuzzy Search with Disambiguation:** Searches for files using partial names. If multiple matches exist, it presents an interactive selector.
- **Safe Extraction:** To prevent accidental overwrites of active files, extracted files are placed at `.bak` paths (e.g., `smb.conf.bak`).
- **Directory Extraction:** Appending a trailing slash to the search term extracts the entire directory tree (renamed with a `_bak` suffix).
- **Multi-term Queries:** Restores multiple files or folders in a single command execution.
- **Multi-Destination Scanning:** Scans all active `[DESTINATIONS]` to locate the most recent valid backup.
- **Targeted Restores:** Bypasses auto-discovery when the `-b` / `--backup` option is specified, extracting files from a targeted archive.

### Installation

`recall.sh` lives alongside `cerebro.sh` in the same directory. No additional dependencies beyond what Cerebro already requires.

```bash
chmod +x recall.sh
```

### Usage

```bash
./recall.sh [OPTIONS] <search_term_1> [search_term_2] ...
```

**Options:**
* `-h, --help`      Show help message and exit
* `-b, --backup`    Specify a custom backup tarball archive as the source

### Examples

**Restore a single config file:**

```bash
./recall.sh smb.conf
# Output: [SUCCESS] Saved to -> /etc/samba/smb.conf.bak
# Review it, then: sudo mv /etc/samba/smb.conf.bak /etc/samba/smb.conf
```

**Restore your rclone auth:**

```bash
./recall.sh rclone.conf
# Output: [SUCCESS] Saved to -> /home/pi/.config/rclone/rclone.conf.bak
```

**Restore multiple files in one call:**

```bash
./recall.sh smb.conf rclone.conf
# Both extracted and placed as .bak files simultaneously
```

**Restore from a specific backup archive:**

```bash
./recall.sh -b /mnt/nas/backup/cerebro/raspberrypi/backup_20240215_040000-1.tar.gz etc/samba/smb.conf
```

**Restore an entire folder:**

```bash
./recall.sh Apps/tutor/
# Output: [SUCCESS] Saved to -> /home/pi/Apps/tutor_bak/
```

**Ambiguous search — interactive picker:**

```bash
./recall.sh compose
# Found 4 matching files for 'compose':
# 1) home/pi/Docker/stack-a/docker-compose.yml
# 2) home/pi/Docker/stack-b/docker-compose.yml
# ...
# Select the file to extract for 'compose' (or Cancel):
```

### Recommended Recovery Workflow

Because extracted files are saved with a `.bak` suffix, you can inspect differences before applying the restored version:

```bash
# Extract
./recall.sh smb.conf

# Review what you are getting back
diff /etc/samba/smb.conf /etc/samba/smb.conf.bak

# If satisfied, apply it
sudo mv /etc/samba/smb.conf.bak /etc/samba/smb.conf
sudo systemctl restart smbd
```

### Logging

Recall writes its own log to `recall.log` in the same directory as `cerebro.sh`. Each session is delimited with `RECALL SESSION STARTED / ENDED` markers.

---

## 10. Directory Structure & File Locations

When installed, Cerebro creates the following structure:

```
/opt/cerebro/                        # Installation directory (example)
├── cerebro.sh                       # Main script
├── cerebro.cfg                      # Configuration file
├── cerebro.log                      # Log file (all events)
├── backups/                         # Temporary staging area
│   └── (empty - backups are moved to destinations immediately)
└── assets/                          # Metadata directory
    ├── .tar_meta_data.txt           # Backup classification tracking
    └── .manual_backup_counter       # Cycles through a-z for manual backups
```

**Destination directories** (configured in `[DESTINATIONS]`):

```
/mnt/nas/backup/cerebro/
└── hostname/                        # Auto-appended based on system hostname
    ├── backup_20240215_040000-1.tar.gz
    ├── backup_20240215_100000-2.tar.gz
    └── backup_20240216_040000-1.tar.gz
```

**Key points:**

- The `backups/` directory is **always empty** after successful runs (files are moved to destinations)
- If all destinations fail, backups remain in `backups/` until the next successful run
- The `assets/` directory is **critical** - losing it breaks TARDISCARD logic (but doesn't affect backup data)
- Each machine backing up to the same NAS gets a separate subdirectory based on hostname

---

## 11. Installation & First Run

### Requirements

- Linux environment (Bash 4.0+)
- Standard GNU tools (Cerebro self-checks and can install if missing):
  - `tar` - Archive creation
  - `rsync` - File transfer
  - `diff` - Content comparison
  - `gawk` (GNU Awk) - **CRITICAL:** Required for log pruning. Standard `awk` implementations won't work.
  - `grep`, `sed` - Text processing
  - `find`, `wc` - File operations
  - `timeout` - Process management

### Quick Installation (Automated)

You can install Cerebro using `curl` or `wget`. The installer will automatically detect your environment, download the script and a template configuration, and set up the directory structure in `~/cerebro`.

**Option A: Using curl**

```bash
mkdir -p ~/cerebro && curl -sL https://raw.githubusercontent.com/Arelius-D/Cerebro/main/install.sh | bash
```

**Option B: Using wget**

```bash
mkdir -p ~/cerebro && wget -qO - https://raw.githubusercontent.com/Arelius-D/Cerebro/main/install.sh | bash
```

### Manual Setup Steps

1. **Place the script:**

```bash
mkdir -p /opt/cerebro
cd /opt/cerebro
# Copy cerebro.sh and cerebro.cfg here
chmod +x cerebro.sh
```

2. **Edit the config:**

```bash
nano cerebro.cfg
# Set your [INCLUDE] paths
# Set your [DESTINATIONS]
# Configure [SCHEDULE]
```

3. **First run (manual):**

```bash
./cerebro.sh
```

> [!IMPORTANT]
> **Must be Run Manually First:** The first run of Cerebro on a new system must be executed manually from a terminal without any flags (specifically **no** `--update` flag). This manual execution is required because:
> 1. It performs the interactive dependency check and offers to install missing tools (under headless/cron runs, this interactive prompting fails).
> 2. It initializes the local folder structure (`assets/` and `backups/`).
> 3. It generates the initial `RETAIN:FIRST` backup reference to start tracking file states.
> 4. It installs the automated cron job on the system.

**What happens on first run:**

- Cerebro checks for required tools, offers to install if missing
- Reads `cerebro.cfg`
- Creates the `backups/` directory
- Creates the `assets/` directory for metadata
- Since there's no previous backup, it creates the first one and tags it as `RETAIN:FIRST`
- Installs the cron job (if `cron=1` in config)
- Logs to `cerebro.log`

**Suppressing "first run" messages:**
Set `NOFIRSTRUN=1` in `[LOGTYPE]` if you don't want the "No previous backup found" message in the log.

4. **Understanding Manual vs. Cron Execution:**

When you run Cerebro, it operates in one of two modes:

**Manual Mode (default):**

```bash
./cerebro.sh
```

- Uses **letter suffixes** (a-z, cycling): `backup_20240215_153022-a.tar.gz`
- Each manual run increments the letter (a→b→c...→z, then wraps back to a)
- Useful for ad-hoc backups before making risky changes

**Cron Mode (--update flag):**

```bash
./cerebro.sh --update
```

- Uses **number suffixes** (1-4, based on time of day):
  - 1 = 00:00-05:59
  - 2 = 06:00-11:59
  - 3 = 12:00-17:59
  - 4 = 18:00-23:59
- Prevents creating dozens of backups per day if cron runs frequently
- The cron job automatically uses this flag (it's appended in the crontab entry)

**Example:**
If your cron runs every hour, you'll get at most 4 backups per day (one per time window), not 24.

5. **Verify cron installation:**

```bash
crontab -l | grep cerebro
```

You should see your schedule.

6. **Test a cron run manually:**

```bash
./cerebro.sh --update
```

This simulates a cron-triggered run.

---

## 12. Performance & Storage Considerations

### CPU Usage

- **Compression:** `tar -czf` uses gzip. On modern systems, negligible impact.
- **Diffing:** Only happens when changes are detected. Text files are fast, large binaries in `[NOLOG]` are skipped.
- **Typical homelab load:** < 5% CPU for 30 seconds during backup creation.

### Memory Usage

- **Staging:** Uses `/tmp` for extraction and comparison. Ensure `/tmp` has space for 2x your largest backup.
- **Typical usage:** Extracts old tar, compares with live data, creates new tar. Peak memory = size of largest single file being processed.

### Storage Requirements

- **Local staging:** `$SCRIPT_DIR/backups/` is temporary. Backups are moved to `[DESTINATIONS]` immediately after creation.
- **Destination storage:** Depends on your data size and retention policy.
  - **With TARDISCARD:** Expect 10-20% of "all backups ever created" due to smart pruning.
  - **Without TARDISCARD:** All backups are kept. Plan accordingly.

**Example:**

- 10GB of Docker data
- Daily backups
- 1 real config change per week
- 6 log file changes per day (NOLOG events)

**Without TARDISCARD:** 7 backups/week × 10GB = 70GB/week = 3.6TB/year  
**With TARDISCARD:** 1 RETAIN backup/week × 10GB + 1 DISCARD:LATEST backup = 20GB/week = 1TB/year

### Network Considerations

- **rsync with timeout and failover cp:** Cerebro uses `rsync` with a timeout limit. If the rsync transfer fails or hangs, it terminates the transfer and automatically falls back to copying files directly via `cp -ru`.
- **Compression:** Backups are gzipped, reducing network transfer size.
- **Cloud storage and Mount checks:** To prevent execution blocks or hangs on slow or unresponsive cloud/FUSE mounts (like rclone), Cerebro runs a connection check using a double-forked background process before performing read or write operations.

---

## 13. Troubleshooting & FAQ

### Q: Cerebro says "No changes detected" but I know files changed.

**A:** Check your `[EXCLUDE]` patterns. You might be excluding the files that changed. Enable `DEBUG=1` to see which files are being processed.

### Q: Backups are huge and filling up my storage.

**A:**

1. Enable `TARDISCARD DISCARD=1`
2. Move frequently-changing data (logs, temp files, cache) to `[NOLOG]`
3. Add patterns to `[EXCLUDE]` for unnecessary data

### Q: The log file is massive.

**A:** Enable `[LOGPRUNE]` and set `DISCARD_MAX_AGE_DAYS=1` (or your preferred retention).

### Q: Cerebro isn't running automatically.

**A:**

```bash
# Check if cron job exists
crontab -l | grep cerebro

# Check cron service
systemctl status cron

# Check permissions
ls -la /path/to/cerebro.sh

# Check the log file for errors
tail -f cerebro.log
```

### Q: How do I migrate Cerebro to a new system?

**A:**

1. Copy the entire Cerebro directory (script, config, assets folder)
2. Update paths in `cerebro.cfg` to match the new system
3. Run `./cerebro.sh` once to install the cron job
4. Your existing backups in `[DESTINATIONS]` will be discovered automatically

### Q: What if all my destinations fail?

**A:** Cerebro will keep the backup in `$SCRIPT_DIR/backups/` and log an error. The backup is not lost, just not transferred. On the next successful run, it will be synced.

### Q: Can I run Cerebro on multiple machines backing up to the same NAS?

**A:** Yes. Cerebro automatically appends the hostname to the destination path, so each machine gets its own subdirectory:

```
/mnt/nas/backup/cerebro/
  ├── machine1/
  ├── machine2/
  └── machine3/
```

### Q: How do I disable Cerebro temporarily without losing my config?

**A:** Set `cron=0` in `[SCHEDULE]`, run `./cerebro.sh` once to remove the cron job. Cerebro is now dormant but all settings are preserved.

### Q: The comparison is taking forever.

**A:** If you have large binary files in `[INCLUDE]`, move them to `[NOLOG]`. Cerebro will still back them up but won't try to diff them.

### Q: I accidentally deleted my metadata file (.tar_meta_data.txt). What happens?

**A:** Cerebro will rebuild it on the next run. You'll lose the RETAIN/DISCARD tags, so TARDISCARD won't work correctly until new backups are created. Your actual backup data is unaffected.

### Q: I see "tar: file changed as we read it" warnings.

**A:** This is a **warning**, not an error. It happens when a file is being written to while tar is reading it (common with active log files or databases).

- **Solution 1:** Add actively-written files to `[EXCLUDE]` if they're not important
- **Solution 2:** Run Cerebro during low-activity periods
- **Solution 3:** Use pre-backup scripts to stop services temporarily (see Advanced Use Cases)
- The backup will still be created; only the actively-written file may be incomplete

### Q: Can I backup files from a remote server?

**A:** Not directly. Cerebro operates on local filesystems. However:

- **Option 1:** Mount the remote filesystem (NFS, SMBFS, SSHFS) and add it to `[INCLUDE]`
- **Option 2:** Use rsync to sync remote data locally first, then backup the local copy
- **Option 3:** Run Cerebro on the remote server and use shared storage for `[DESTINATIONS]`

### Q: How do I know if a backup actually completed successfully?

**A:** Check three things:

1. Exit code: `./cerebro.sh; echo $?` (0 = success)
2. Log file: `tail cerebro.log` (should end with "BACKUP RUN ENDED")
3. Destination: `ls -lh /path/to/destination/hostname/` (newest file should match timestamp)

### Q: What happens if I run Cerebro while another instance is running?

**A:** The second instance will detect the lock file (`/tmp/$SCRIPT_NAME.lock`) and exit immediately to prevent data corruption. 

Cerebro handles this with two robust mechanisms:
1. **Self-Healing Stale Lock Recovery:** If a crash or reboot occurs, the lock file remains but the PID inside it will be inactive. Cerebro automatically checks this at startup using `ps -p "$pid"`. If the PID is dead, it logs a warning, cleans up the stale lock file, and runs the backup.
2. **Multi-Instance Isolation via Renaming:** The lock file name is derived dynamically from the script file name (`/tmp/$SCRIPT_NAME.lock`). To run multiple instances in parallel on the same system, simply rename the main script file to match its task (e.g. rename it to `cerebro-docker.sh` in one directory and `cerebro-dev.sh` in another). Their lock files will be isolated automatically to `/tmp/cerebro-docker.lock` and `/tmp/cerebro-dev.lock` without any code modifications.

### Q: How do I move Cerebro to a different directory on the same system?

**A:**

1. Stop any running cron jobs: `crontab -e` and comment out the Cerebro line
2. Move the entire directory: `mv /old/path/cerebro /new/path/cerebro`
3. `cd /new/path/cerebro`
4. Run `./cerebro.sh` once - this updates the cron job with the new path
5. Verify: `crontab -l | grep cerebro` should show the new path

Your backups in `[DESTINATIONS]` are unaffected; Cerebro will find them automatically.

---

## 14. Advanced Use Cases

### Email Alerts on Changes

Pipe Cerebro's output to a mail command in your cron job:

```bash
00 04 * * * /opt/cerebro/cerebro.sh --update 2>&1 | mail -s "Cerebro Backup Report" admin@example.com
```

### Integration with Monitoring Systems

Parse `cerebro.log` for the string `"Backup tagged as: RETAIN"` to trigger alerts:

```bash
if grep -q "Backup tagged as: RETAIN" cerebro.log; then
    curl -X POST https://monitoring.example.com/webhook -d "Critical config changed"
fi
```

### Pre-backup Hooks

Add a script that runs before Cerebro:

```bash
#!/bin/bash
# pre-cerebro.sh
docker-compose -f /home/pi/Docker/docker-compose.yml down
/opt/cerebro/cerebro.sh --update
docker-compose -f /home/pi/Docker/docker-compose.yml up -d
```

This ensures you're backing up a consistent state.

### Offsite Encryption

Encrypt backups before sending to cloud:

```bash
# In your cron job
/opt/cerebro/cerebro.sh --update
gpg --encrypt --recipient admin@example.com /mnt/nas/backup/cerebro/hostname/*.tar.gz
rclone sync /mnt/nas/backup/cerebro/hostname/ remote:encrypted-backup/
```

---

## 15. Security Considerations

### File Permissions

- `cerebro.sh`: Should be `700` (only owner can read/write/execute)
- `cerebro.cfg`: Should be `600` (contains paths, might contain sensitive info)
- Backups: Inherit permissions from the destination directory

### Sensitive Data

- If backing up `/etc/shadow`, `/home/user/.ssh`, or other sensitive files, ensure:
  1. Destination directories are encrypted or access-controlled
  2. Backups are not world-readable
  3. Log file (`cerebro.log`) doesn't expose sensitive content (use `[NOLOG]` for these files)

### Root Privileges

- Cerebro can run as a regular user if it has read access to all `[INCLUDE]` paths
- If backing up system files (`/etc`, `/var`), run as root or use sudo
- Cron jobs inherit the user context - ensure the user running Cerebro has appropriate permissions

---

## 16. Comparison with Other Backup Tools

| Feature                | Cerebro          | rsync              | Duplicity      | Borg           | tar+cron      |
| ---------------------- | ---------------- | ------------------ | -------------- | -------------- | ------------- |
| Smart Change Detection | ✅ Content-aware | ❌ Timestamp-based | ✅ Block-level | ✅ Block-level | ❌ Time-based |
| Diff Logging           | ✅ Built-in      | ❌ Manual          | ❌ No          | ❌ No          | ❌ Manual     |
| Multi-Destination Sync | ✅ Automatic     | ❌ Manual          | ❌ Single      | ❌ Single      | ❌ Manual     |
| Noise Filtering        | ✅ TARDISCARD    | ❌ No              | ❌ No          | ❌ No          | ❌ No         |
| Configuration Format   | ✅ Simple INI    | ❌ CLI args        | ❌ Complex     | ❌ Complex     | ❌ Scripts    |
| Human-Readable Backups | ✅ tar.gz        | ✅ Files           | ❌ Encrypted   | ❌ Repo format | ✅ tar.gz     |
| Setup Complexity       | ✅ Simple        | ✅ Simple          | ❌ Moderate    | ❌ Moderate    | ✅ Simple     |
| Incremental            | ❌ No            | ✅ Yes             | ✅ Yes         | ✅ Yes         | ❌ No         |
| Deduplication          | ❌ No            | ❌ No              | ✅ Yes         | ✅ Yes         | ❌ No         |

**When to use Cerebro:**

- You need visibility into WHAT changed, not just THAT something changed
- You want simple, readable backups (tar.gz) you can extract with standard tools
- You need multi-destination redundancy without complex scripts
- You want to filter out noise (log rotations, temp files) from your backup history

**When NOT to use Cerebro:**

- You need incremental/differential backups (use Borg or Duplicity)
- You have terabytes of data with minor changes (use rsync or Borg)
- You need encryption at rest (use Duplicity or add GPG to Cerebro workflow)
- You need deduplication (use Borg)

---

> **Final Note:** Cerebro is built on the premise that **data is useless without context**. By providing deep visibility into _what_ changed and _why_ a backup occurred, it transforms backups from a "storage chore" into a "system administration asset."

> **Philosophy:** A backup system should answer three questions:
>
> 1. **What do I have?** (Latest state)
> 2. **What changed?** (Diffs and logs)
> 3. **When did it change?** (Timestamped history)
>
> Cerebro answers all three without requiring you to extract archives or maintain external version control.

---

**Questions? Issues? Contributions?** [https://github.com/Arelius-D/Cerebro](https://github.com/Arelius-D/Cerebro)

**License:** MIT License

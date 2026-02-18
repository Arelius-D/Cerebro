# Cerebro: Intelligent Differential Backup & State Monitoring

> **Version:** v2.1  
> **Core Philosophy:** "Read, Understand, Verify."

## 1. What is Cerebro?

Cerebro is not a simple "copy-paste" backup script. It is an **intelligent state-monitor** wrapped in a backup utility. 

Unlike standard tools (like `rsync` or simple `tar` cron jobs) that blindly copy data on a schedule, Cerebro operates on a **"Verify First"** architecture. It stages data, compares it against the last known valid state across multiple storage destinations, and *only* commits a new backup if meaningful changes are detected.

It is designed for complex environments (Self-hosted stacks, Docker containers, System configurations) where you need to distinguish between **critical configuration changes** and **meaningless noise**.

---

## 2. Why Use Cerebro? (The Logic)

Cerebro solves three critical problems inherent in standard backup solutions:

### A. The "Noise" Filter (Smart Change Detection)
Most backup tools trigger a new archive if a file's timestamp changes. Cerebro inspects the **content**.
* **The Problem:** A Docker container rotates a log file. A standard backup tool sees a "change" and creates a 2GB duplicate archive.
* **The Cerebro Solution:** Through the `[NOLOG]` and `[TARDISCARD]` protocols, Cerebro detects that *only* a log file changed. It can record the event in the system log but **discard the heavy archive**, saving gigabytes of storage over time while keeping your backup timeline clean.

### B. High-Visibility Logging (The "Black Box" Fix)
Standard backups are opaque; you don't know what changed until you restore.
* **The Cerebro Solution:** The `[LOGDIFF]` feature allows you to define text files (scripts, configs, `.env` files). When these change, Cerebro **diffs the content** and writes the specific added/removed lines directly into `cerebro.log`.
* **Result:** You can read your log file like a commit history, seeing exactly when and how a configuration was altered without ever touching a `.tar.gz` file.

### C. Multi-Destination Sync (Active Redundancy)
Cerebro does not assume a single storage location is available.
* **The Cerebro Solution:** It supports an array of `[DESTINATIONS]`. Before every run, it scans *all* defined locations (NAS, USB Drives, Cloud Mounts) to find the true "Latest" backup. After a run, it synchronizes the new backup to all healthy destinations, ensuring your off-site and on-site copies are identical.

---

## 3. Core Architecture

Cerebro follows a strict execution pipeline to ensure data integrity:

1.  **Staging:** Creates a temporary, isolated environment in `/tmp` for comparison work.
2.  **Latest Backup Discovery:** Scans ALL `[DESTINATIONS]` to find the most recent valid backup (by timestamp).
3.  **Comparison:** Extracts the previous backup and performs a file-by-file diff against live data.
4.  **Decision Matrix:**
    * *No Change:* Abort, delete staged tar, log "No changes detected."
    * *LOGDIFF Change:* Extract and log the actual text differences, tag backup as `LOGDIFF`.
    * *NOLOG Change:* Note the change but don't log content, tag backup as `NOLOG` or `DISCARD` based on rules.
5.  **Tagging & Metadata:** Create entry in `.tar_meta_data.txt` with backup type (LOGDIFF/NOLOG/DISCARD).
6.  **Creation:** Build the final `tar.gz` archive with all excludes applied.
7.  **Verification:** Run `tar -tzf` to ensure the archive is not corrupted.
8.  **Distribution:** Use `rsync` with timeout to copy the valid archive to all reachable `[DESTINATIONS]`.
9.  **Cleanup:** If `[TARDISCARD] DISCARD=1`, remove old DISCARD-tagged backups. Prune log file if `[LOGPRUNE]` enabled.
10. **Self-Maintenance:** Update cron job, remove temp files, release lock.

---

## 4. Configuration Guide

Cerebro is controlled entirely via `cerebro.cfg`. This file defines the "Intelligence" of the system.

### `[INCLUDE]` & `[EXCLUDE]`
Standard path definitions. Supports wildcards (`*`).

**How it works:**
* `[INCLUDE]`: Absolute paths to files or directories you want backed up.
* `[EXCLUDE]`: Patterns or paths to skip (logs, temp files, cache directories).

**Built-in Protection:**
* **Automatic Backup Directory Exclusion**: Cerebro automatically excludes its own `backups/` folder to prevent recursive backup loops. You do NOT need to manually add `/path/to/cerebro/backups` to `[EXCLUDE]` - the script handles this internally regardless of where you install it.

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

* **Use Case:** Configuration files, scripts, docker-compose files - anything where you need to see WHAT changed.
* **Behavior:** When a file matching this pattern changes, Cerebro extracts the previous version, runs `diff`, and writes the added/removed lines directly into `cerebro.log`.
* **Benefit:** Your log becomes a version control system. You can see exactly when `docker-compose.yml` changed and what lines were modified without extracting any tar files.

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

* **Use Case:** Binary files, databases, frequently changing data where the diff output would be useless noise.
* **Behavior:** Cerebro detects the file changed (via hash/size comparison) and triggers a backup, but it does NOT write the diff to the log file. Instead it just notes: "File X changed."
* **Why?** A 500MB `.db` file changing would create a 500MB diff in your log. This keeps logs readable while still capturing state changes.

**Common Use Cases:**
* SQLite databases (`*.db`)
* Application state files
* Binary configuration blobs
* Docker volume data that changes frequently but you don't need content-level visibility

**Example:**
```ini
[NOLOG]
/home/pi/Docker/pi-hole/data/*
/home/pi/Apps/app-state.db
*.sqlite
```

---

### `[TARDISCARD]` (The Storage Saver)
**Intelligently prunes backups that only contain noise-level changes.**

* **`DISCARD=0`**: Disabled. All backups are kept.
* **`DISCARD=1`**: Enabled. "Smart Prune" logic activates.

**How it works:**
When a backup run completes, Cerebro checks the metadata to see WHAT triggered the backup:
1. **If the backup contains LOGDIFF changes** → Keep it (tagged as `LOGDIFF`).
2. **If the backup contains ONLY NOLOG changes** → Tag it as `DISCARD`.
3. **On the NEXT run**, if a new backup is created, Cerebro deletes all old `DISCARD`-tagged backups, keeping only the most recent `DISCARD` backup.

**Why this matters:**
* You have a Docker container that writes to a log file every 5 minutes.
* Without TARDISCARD: You'd have 288 backups per day (one every 5 minutes), all containing the same data except for log rotation.
* With TARDISCARD: You have 1 backup representing the "last known NOLOG state" and all your meaningful backups (when actual configs changed).

**Storage saved:** In a typical homelab, this can save 80-90% of backup storage over a year.

---

### `[DESTINATIONS]`
**Define multiple backup storage locations.**

Cerebro treats this as an array of equals - no "primary" or "secondary". Before every run, it scans ALL destinations to find the latest backup across all of them.

**Features:**
* **Automatic hostname appending**: If you define `/mnt/nas/backup/cerebro`, Cerebro will actually write to `/mnt/nas/backup/cerebro/hostname` - this allows multiple machines to use the same NAS share without conflicts.
* **Resilience**: If one destination is offline (unmounted NAS), Cerebro continues with the available ones.
* **Sync logic**: After creating a new backup, Cerebro attempts to copy it to ALL reachable destinations using `rsync` with timeout protection.

**Example:**
```ini
[DESTINATIONS]
/media/G-Drive/backup/cerebro
/mnt/nas/backup/cerebro
/mnt/cloud-mount/backups
```

**What happens:**
* Machine hostname is `raspberrypi`
* Cerebro will write to:
  * `/media/G-Drive/backup/cerebro/raspberrypi/backup_20240215_040000-1.tar.gz`
  * `/mnt/nas/backup/cerebro/raspberrypi/backup_20240215_040000-1.tar.gz`
  * `/mnt/cloud-mount/backups/raspberrypi/backup_20240215_040000-1.tar.gz`

---

### `[SCHEDULE]` (Cron Automation)
**Control when Cerebro runs automatically.**

```ini
[SCHEDULE]
cron=1
schedule=00 04 * * 1
```

* **`cron=0`**: Disable automatic scheduling. Run manually only.
* **`cron=1`**: Enable automatic scheduling.
* **`schedule=`**: Standard cron syntax. Use https://crontab.guru/ to generate.

**Common schedules:**
* `00 04 * * *` - Daily at 4:00 AM
* `00 04 * * 1` - Weekly on Monday at 4:00 AM
* `00 */6 * * *` - Every 6 hours
* `*/30 * * * *` - Every 30 minutes (aggressive monitoring)

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
* **Cron backups** are named with time-based suffixes: `backup_20240215_040000-1.tar.gz` (1 = 00:00-05:59, 2 = 06:00-11:59, etc.)
* **Manual backups** are named with letter suffixes: `backup_20240215_153000-a.tar.gz`, `backup_20240215_154500-b.tar.gz` (cycling a-z)

---

### `[LOGTYPE]` (Verbosity Control)
**Control what gets written to `cerebro.log`.**

```ini
[LOGTYPE]
DEBUG=0
INFO=1
NOFIRSTRUN=0
```

* **`DEBUG=1`**: Ultra-verbose. Logs every file being processed, timing info, decision trees. Use for troubleshooting.
* **`DEBUG=0`**: Production mode. Only logs significant events.
* **`INFO=1`**: Log normal operational messages (backup created, files transferred, etc.)
* **`INFO=0`**: Silent mode. Only log errors and file differences.
* **`NOFIRSTRUN=1`**: Suppress the "First run, no previous backup to compare" message. Useful if you're running Cerebro on a new system and don't want log noise.

**Recommended settings:**
* Development/Testing: `DEBUG=1, INFO=1`
* Production: `DEBUG=0, INFO=1`
* High-frequency monitoring: `DEBUG=0, INFO=0` (only log real changes)

---

### `[LOGPRUNE]` (Log File Management)
**Automatically clean old entries from `cerebro.log`.**

```ini
[LOGPRUNE]
ENABLED=1
DISCARD_MAX_AGE_DAYS=1
```

* **`ENABLED=1`**: Active. Cerebro will delete log entries older than the specified age.
* **`DISCARD_MAX_AGE_DAYS=1`**: Keep only the last 1 day of logs.

**Why this exists:**
If you run Cerebro every 5 minutes with `DEBUG=1`, your log file will grow to gigabytes in a week. This feature keeps the log manageable while retaining recent history.

**What gets deleted:**
Only the timestamped log entries. The current run's log header is always kept.

**Recommendation:**
* High-frequency backups (< 1 hour): `DISCARD_MAX_AGE_DAYS=1`
* Daily backups: `DISCARD_MAX_AGE_DAYS=30`
* Weekly backups: `DISCARD_MAX_AGE_DAYS=365`

---

## 5. The Metadata System (Understanding .tar_meta_data.txt)

Cerebro maintains a hidden metadata file at `$SCRIPT_DIR/assets/.tar_meta_data.txt`. This file tracks every backup and its classification.

**Format:**
```
backup_20240215_040000-1.tar.gz:LOGDIFF
backup_20240215_100000-2.tar.gz:NOLOG
backup_20240215_160000-3.tar.gz:DISCARD
backup_20240215_220000-4.tar.gz:DISCARD:LATEST
```

**Tags:**
* **`LOGDIFF`**: This backup contains changes to files in `[LOGDIFF]`. **Always kept.**
* **`NOLOG`**: This backup contains changes to files in `[NOLOG]` AND `[LOGDIFF]`. **Always kept.**
* **`DISCARD`**: This backup contains ONLY `[NOLOG]` changes. **Eligible for deletion.**
* **`DISCARD:LATEST`**: The most recent DISCARD backup. **Protected until a newer backup is created.**

**TARDISCARD Logic:**
```
Current state: 
  backup_001.tar.gz:LOGDIFF
  backup_002.tar.gz:DISCARD
  backup_003.tar.gz:DISCARD
  backup_004.tar.gz:DISCARD:LATEST

New backup created (backup_005.tar.gz):
  - If it's LOGDIFF → Delete all DISCARD except LATEST
  - If it's DISCARD → Promote backup_005 to DISCARD:LATEST, delete backup_002 and backup_003

Result:
  backup_001.tar.gz:LOGDIFF
  backup_004.tar.gz:DISCARD
  backup_005.tar.gz:DISCARD:LATEST
```

This ensures you always have:
1. All meaningful configuration changes (LOGDIFF/NOLOG)
2. The two most recent states (current + previous)

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
You sleep. Cerebro wakes up daily at 4 AM, checks your containers. If nothing changed, it goes back to sleep (no backup created). If an app auto-updated and changed a config, Cerebro snapshots it, logs the version change in `cerebro.log`, syncs it to your NAS, and you can review it in the morning. If just a database file changed, it creates a backup but marks it as DISCARD to save space.

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
Every 30 minutes, Cerebro checks your work. Every time you edit a script, it creates a versioned backup. The `cerebro.log` effectively becomes a "git commit history" showing exactly what code you tweaked, when, and what the diff was. You can trace bugs back to specific edits without needing to remember to commit.

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
High frequency backups (every 4 hours). Multiple redundant destinations (local RAID + NAS + cloud). If your local drive dies, the NAS copy is up to date. If you accidentally break a config file, you can review `cerebro.log` to see exactly what changed in the last backup, or restore from the previous tar. Log pruning keeps the log file under control.

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
Every 5 minutes, Cerebro checks critical system files. If someone adds an SSH key, modifies sudoers, or changes user passwords, you'll have a timestamped backup and a full diff of exactly what changed. This is forensics-level monitoring - if your system is compromised, you'll know exactly when and what was altered.

---

## 7. What the Log File Actually Shows

**Example cerebro.log output after a run where docker-compose.yml changed:**

```
========== BACKUP RUN STARTED ==========
  2024-02-15 04:00:01 - Run Type: cron
  2024-02-15 04:00:01 - Timestamp: 2024-02-15 04:00:01
  2024-02-15 04:00:01 - Backup Name: backup_20240215_040001-1.tar.gz

    [Backup Creation]
        2024-02-15 04:00:02 - Starting backup creation...
        2024-02-15 04:00:05 - Backup tar created successfully.

    [Comparison]
        2024-02-15 04:00:06 - Comparing with latest backup: backup_20240214_040000-1.tar.gz
        2024-02-15 04:00:10 - FILE: /home/pi/Docker/docker-compose.yml
        2024-02-15 04:00:10 - DIFFERENCE: Content changed between old and new backup
< OLD:     image: nginx:1.20
> NEW:     image: nginx:1.21
< OLD:       - "8080:80"
> NEW:       - "8081:80"

        2024-02-15 04:00:11 - INFO: Backup tagged as: LOGDIFF
        2024-02-15 04:00:11 - Changes detected between:
        2024-02-15 04:00:11 -   New: /path/to/backup_20240215_040001-1.tar.gz
        2024-02-15 04:00:11 -   Previous: backup_20240214_040000-1.tar.gz

    [Transfer]
        2024-02-15 04:00:15 - INFO: Backup copied to /media/G-Drive/backup/cerebro/raspberrypi/backup_20240215_040001-1.tar.gz via rsync.
        2024-02-15 04:00:20 - INFO: Backup copied to /mnt/nas/backup/cerebro/raspberrypi/backup_20240215_040001-1.tar.gz via rsync.

    [Cleanup]
        2024-02-15 04:00:21 - INFO: Backup removed from /path/to/cerebro/backups/backup_20240215_040001-1.tar.gz

    [Tar Removal]
        2024-02-15 04:00:21 - Removed backup_20240214_100000-2.tar.gz from /media/G-Drive/backup/cerebro/raspberrypi.
        2024-02-15 04:00:21 - Removed backup_20240214_100000-2.tar.gz from /mnt/nas/backup/cerebro/raspberrypi.

========== BACKUP RUN ENDED ==========
```

**Key takeaways:**
* You can see EXACTLY what changed (nginx version and port mapping)
* You know which backup contains the change
* You can see the transfer was successful to both destinations
* You can see old DISCARD backups were cleaned up

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

## 9. Directory Structure & File Locations

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
* The `backups/` directory is **always empty** after successful runs (files are moved to destinations)
* If all destinations fail, backups remain in `backups/` until the next successful run
* The `assets/` directory is **critical** - losing it breaks TARDISCARD logic (but doesn't affect backup data)
* Each machine backing up to the same NAS gets a separate subdirectory based on hostname

---

## 10. Installation & First Run

### Requirements
* Linux environment (Bash 4.0+)
* Standard GNU tools (Cerebro self-checks and can install if missing):
  * `tar` - Archive creation
  * `rsync` - File transfer
  * `diff` - Content comparison
  * `gawk` (GNU Awk) - **CRITICAL:** Required for log pruning. Standard `awk` implementations won't work.
  * `grep`, `sed` - Text processing
  * `find`, `wc` - File operations
  * `timeout` - Process management

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

**What happens on first run:**
* Cerebro checks for required tools, offers to install if missing
* Reads `cerebro.cfg`
* Creates the `backups/` directory
* Creates the `assets/` directory for metadata
* Since there's no previous backup, it creates the first one and tags it as `LOGDIFF`
* Installs the cron job (if `cron=1` in config)
* Logs to `cerebro.log`

**Suppressing "first run" messages:**
Set `NOFIRSTRUN=1` in `[LOGTYPE]` if you don't want the "No previous backup found" message in the log.

4. **Understanding Manual vs. Cron Execution:**

When you run Cerebro, it operates in one of two modes:

**Manual Mode (default):**
```bash
./cerebro.sh
```
* Uses **letter suffixes** (a-z, cycling): `backup_20240215_153022-a.tar.gz`
* Each manual run increments the letter (a→b→c...→z, then wraps back to a)
* Useful for ad-hoc backups before making risky changes

**Cron Mode (--update flag):**
```bash
./cerebro.sh --update
```
* Uses **number suffixes** (1-4, based on time of day):
  * 1 = 00:00-05:59
  * 2 = 06:00-11:59
  * 3 = 12:00-17:59
  * 4 = 18:00-23:59
* Prevents creating dozens of backups per day if cron runs frequently
* The cron job automatically uses this flag (it's appended in the crontab entry)

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

## 10. Performance & Storage Considerations

### CPU Usage
* **Compression:** `tar -czf` uses gzip. On modern systems, negligible impact.
* **Diffing:** Only happens when changes are detected. Text files are fast, large binaries in `[NOLOG]` are skipped.
* **Typical homelab load:** < 5% CPU for 30 seconds during backup creation.

### Memory Usage
* **Staging:** Uses `/tmp` for extraction and comparison. Ensure `/tmp` has space for 2x your largest backup.
* **Typical usage:** Extracts old tar, compares with live data, creates new tar. Peak memory = size of largest single file being processed.

### Storage Requirements
* **Local staging:** `$SCRIPT_DIR/backups/` is temporary. Backups are moved to `[DESTINATIONS]` immediately after creation.
* **Destination storage:** Depends on your data size and retention policy.
  * **With TARDISCARD:** Expect 10-20% of "all backups ever created" due to smart pruning.
  * **Without TARDISCARD:** All backups are kept. Plan accordingly.

**Example:**
* 10GB of Docker data
* Daily backups
* 1 real config change per week
* 6 log file changes per day (NOLOG events)

**Without TARDISCARD:** 7 backups/week × 10GB = 70GB/week = 3.6TB/year  
**With TARDISCARD:** 1 LOGDIFF backup/week × 10GB + 1 DISCARD backup = 20GB/week = 1TB/year

### Network Considerations
* **rsync with timeout:** Cerebro uses `rsync` with a 300-second timeout. If a transfer hangs (NAS offline, network issue), it will abort and try the next destination.
* **Compression:** Backups are gzipped, reducing network transfer size.
* **Cloud storage:** If using cloud mounts (rclone, etc.), ensure stable connectivity. Cerebro will skip unreachable destinations.

---

## 11. Troubleshooting & FAQ

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
**A:** Cerebro will rebuild it on the next run. You'll lose the LOGDIFF/NOLOG/DISCARD tags, so TARDISCARD won't work correctly until new backups are created. Your actual backup data is unaffected.

### Q: I see "tar: file changed as we read it" warnings.
**A:** This is a **warning**, not an error. It happens when a file is being written to while tar is reading it (common with active log files or databases).
* **Solution 1:** Add actively-written files to `[EXCLUDE]` if they're not important
* **Solution 2:** Run Cerebro during low-activity periods
* **Solution 3:** Use pre-backup scripts to stop services temporarily (see Advanced Use Cases)
* The backup will still be created; only the actively-written file may be incomplete

### Q: Can I backup files from a remote server?
**A:** Not directly. Cerebro operates on local filesystems. However:
* **Option 1:** Mount the remote filesystem (NFS, SMBFS, SSHFS) and add it to `[INCLUDE]`
* **Option 2:** Use rsync to sync remote data locally first, then backup the local copy
* **Option 3:** Run Cerebro on the remote server and use shared storage for `[DESTINATIONS]`

### Q: How do I know if a backup actually completed successfully?
**A:** Check three things:
1. Exit code: `./cerebro.sh; echo $?` (0 = success)
2. Log file: `tail cerebro.log` (should end with "BACKUP RUN ENDED")
3. Destination: `ls -lh /path/to/destination/hostname/` (newest file should match timestamp)

### Q: What happens if I run Cerebro while another instance is running?
**A:** The second instance will detect the lock file (`/tmp/cerebro.lock`) and exit immediately with an error message. This prevents corruption from concurrent backups.

### Q: How do I move Cerebro to a different directory on the same system?
**A:**
1. Stop any running cron jobs: `crontab -e` and comment out the Cerebro line
2. Move the entire directory: `mv /old/path/cerebro /new/path/cerebro`
3. `cd /new/path/cerebro`
4. Run `./cerebro.sh` once - this updates the cron job with the new path
5. Verify: `crontab -l | grep cerebro` should show the new path

Your backups in `[DESTINATIONS]` are unaffected; Cerebro will find them automatically.

---

## 12. Advanced Use Cases

### Email Alerts on Changes
Pipe Cerebro's output to a mail command in your cron job:
```bash
00 04 * * * /opt/cerebro/cerebro.sh --update 2>&1 | mail -s "Cerebro Backup Report" admin@example.com
```

### Integration with Monitoring Systems
Parse `cerebro.log` for the string `"Backup tagged as: LOGDIFF"` to trigger alerts:
```bash
if grep -q "Backup tagged as: LOGDIFF" cerebro.log; then
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

## 13. Security Considerations

### File Permissions
* `cerebro.sh`: Should be `700` (only owner can read/write/execute)
* `cerebro.cfg`: Should be `600` (contains paths, might contain sensitive info)
* Backups: Inherit permissions from the destination directory

### Sensitive Data
* If backing up `/etc/shadow`, `/home/user/.ssh`, or other sensitive files, ensure:
  1. Destination directories are encrypted or access-controlled
  2. Backups are not world-readable
  3. Log file (`cerebro.log`) doesn't expose sensitive content (use `[NOLOG]` for these files)

### Root Privileges
* Cerebro can run as a regular user if it has read access to all `[INCLUDE]` paths
* If backing up system files (`/etc`, `/var`), run as root or use sudo
* Cron jobs inherit the user context - ensure the user running Cerebro has appropriate permissions

---

## 14. Comparison with Other Backup Tools

| Feature | Cerebro | rsync | Duplicity | Borg | tar+cron |
|---------|---------|-------|-----------|------|----------|
| Smart Change Detection | ✅ Content-aware | ❌ Timestamp-based | ✅ Block-level | ✅ Block-level | ❌ Time-based |
| Diff Logging | ✅ Built-in | ❌ Manual | ❌ No | ❌ No | ❌ Manual |
| Multi-Destination Sync | ✅ Automatic | ❌ Manual | ❌ Single | ❌ Single | ❌ Manual |
| Noise Filtering | ✅ TARDISCARD | ❌ No | ❌ No | ❌ No | ❌ No |
| Configuration Format | ✅ Simple INI | ❌ CLI args | ❌ Complex | ❌ Complex | ❌ Scripts |
| Human-Readable Backups | ✅ tar.gz | ✅ Files | ❌ Encrypted | ❌ Repo format | ✅ tar.gz |
| Setup Complexity | ✅ Simple | ✅ Simple | ❌ Moderate | ❌ Moderate | ✅ Simple |
| Incremental | ❌ No | ✅ Yes | ✅ Yes | ✅ Yes | ❌ No |
| Deduplication | ❌ No | ❌ No | ✅ Yes | ✅ Yes | ❌ No |

**When to use Cerebro:**
* You need visibility into WHAT changed, not just THAT something changed
* You want simple, readable backups (tar.gz) you can extract with standard tools
* You need multi-destination redundancy without complex scripts
* You want to filter out noise (log rotations, temp files) from your backup history

**When NOT to use Cerebro:**
* You need incremental/differential backups (use Borg or Duplicity)
* You have terabytes of data with minor changes (use rsync or Borg)
* You need encryption at rest (use Duplicity or add GPG to Cerebro workflow)
* You need deduplication (use Borg)

---

## 15. Roadmap & Future Features

**Planned for v2.1:**
* Web dashboard for log visualization
* Slack/Discord webhook notifications
* Pre/post-backup hook scripts
* Config validation with warnings
* Backup integrity testing on schedule

**Under consideration:**
* Incremental backup mode
* Built-in encryption
* Database dump integration (MySQL, PostgreSQL)
* Windows Subsystem for Linux (WSL) support

---

> **Final Note:** Cerebro is built on the premise that **data is useless without context**. By providing deep visibility into *what* changed and *why* a backup occurred, it transforms backups from a "storage chore" into a "system administration asset." 

> **Philosophy:** A backup system should answer three questions:
> 1. **What do I have?** (Latest state)
> 2. **What changed?** (Diffs and logs)
> 3. **When did it change?** (Timestamped history)
>
> Cerebro answers all three without requiring you to extract archives or maintain external version control.

---

**Questions? Issues? Contributions?** [https://github.com/Arelius-D/Cerebro](https://github.com/Arelius-D/Cerebro)

**License:** MIT License
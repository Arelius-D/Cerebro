#!/bin/bash
# Cerebro v2.0 - Custom Backup Solution
# Copyright (c) 2026 Arelius-D | MIT License
set -euo pipefail

SCRIPT_NAME=$(basename "$0" .sh)
SCRIPT_TITLE="Custom Backup Solution for Files and Folders"
CODE_VERSION="v2.0"
SCRIPT_DIR="${SCRIPT_DIR:-$(dirname "$(realpath "$0")")}"
SCRIPT_FILE_NAME="$SCRIPT_NAME.sh"
ASSETS_DIR="$SCRIPT_DIR/assets"
LOG_FILE="$SCRIPT_DIR/$SCRIPT_NAME.log"
CONFIG="$SCRIPT_DIR/$SCRIPT_NAME.cfg"
BACKUP_DIR="$SCRIPT_DIR/backups"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
HOSTNAME=$(hostname)
declare -A nolog_changes

log_message() {
    local message="$1"
    local prefix="${message%%:*}"

    if [[ "$prefix" == "DEBUG" && ${DEBUG_ENABLED:-0} -eq 0 ]]; then
        return
    elif [[ "$prefix" != "DEBUG" && ${INFO_ENABLED:-1} -eq 0 && ! "$message" =~ ^(ERROR|FILE|DIFFERENCE|\[backup_|SOURCE:) ]]; then
        return
    elif [[ "$message" == "=========="* ]]; then
        echo "$message" >> "$LOG_FILE"
        return
    elif [[ "$message" == "" ]]; then
        echo "" >> "$LOG_FILE"
        return
    elif [[ "$message" =~ ^\[[A-Za-z]+\]$ ]]; then
        echo "    $message" >> "$LOG_FILE"
        return
    fi

    if [[ "$message" =~ ^(Run Type|Timestamp|Backup Name): ]]; then
        echo "  $(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
    else
        echo "        $(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
    fi
}

BACKUP_TYPE="manual"
BACKUP_SUFFIX="a"
if [ "${1:-}" = "--update" ]; then
    BACKUP_TYPE="cron"
    HOUR=$(date +%H | sed 's/^0//')
    BACKUP_SUFFIX=$(( (HOUR / 6) + 1 ))
fi
BACKUP_NAME="backup_${TIMESTAMP}-${BACKUP_SUFFIX}.tar.gz"

manual_counter_file="$ASSETS_DIR/.manual_backup_counter"
if [ "$BACKUP_TYPE" = "manual" ]; then
    mkdir -p "$ASSETS_DIR"
    if [ -f "$manual_counter_file" ]; then
        read -r counter < "$manual_counter_file"
        counter=${counter:-a}
        if [ "$counter" = "z" ]; then
            counter="a"
        else
            counter=$(echo "$counter" | tr 'a-y' 'b-z')
        fi
    else
        counter="a"
    fi
    log_message "DEBUG: Setting manual backup suffix to $counter"
    echo "$counter" > "$manual_counter_file"
    BACKUP_SUFFIX="$counter"
    BACKUP_NAME="backup_${TIMESTAMP}-${BACKUP_SUFFIX}.tar.gz"
fi

check_requirements() {
    local missing=0
    for cmd in gawk tar diff rsync cp find grep wc sed timeout; do
        if ! command -v "$cmd" >/dev/null; then
            echo "[ERROR] $cmd is required but not installed."
            missing=1
        fi
    done
    if [ $missing -eq 1 ]; then
        echo "[INFO] Install missing tools? (y/n): "
        read -r install
        if [[ "$install" =~ ^[yY] ]]; then
            if ! sudo -n true 2>/dev/null; then
                echo "[INFO] sudo password required to install tools."
            fi
            sudo apt update && sudo apt install tar diffutils rsync coreutils findutils grep sed -y || {
                echo "[ERROR] Failed to install required tools."
                exit 1
            }
        else
            echo "[ERROR] Please install required tools manually: sudo apt install tar diffutils rsync coreutils findutils grep sed -y"
            exit 1
        fi
    fi
}

parse_rules() {
    local section=""
    items=()
    files=()
    folders=()
    ignores=()
    logdiffs=()
    nologs=()
    destinations=()
    cron_enabled=0
    cron_schedule=""
    logprune_enabled=0
    logprune_discard_max_age_days=1

    if [ ! -f "$CONFIG" ]; then
        echo "[ERROR] $CONFIG not found."
        exit 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        case "$section" in
            INCLUDE)
                [[ -n "$line" ]] && items+=("$line")
                ;;
            EXCLUDE)
                [[ -n "$line" ]] && ignores+=("$line")
                ;;
            LOGDIFF)
                [[ -n "$line" ]] && logdiffs+=("$line")
                ;;
            NOLOG)
                [[ -n "$line" ]] && nologs+=("$line")
                ;;
            DESTINATIONS)
                [[ -n "$line" ]] && destinations+=("${line%/}/$HOSTNAME")
                ;;
            SCHEDULE)
                if [[ "$line" =~ ^cron=([0-1])$ ]]; then
                    cron_enabled="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^schedule=(.*)$ ]]; then
                    cron_schedule="${BASH_REMATCH[1]}"
                fi
                ;;
            LOGTYPE)
                if [[ "$line" =~ ^DEBUG=([0-1])$ ]]; then
                    DEBUG_ENABLED="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^INFO=([0-1])$ ]]; then
                    INFO_ENABLED="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^NOFIRSTRUN=([0-1])$ ]]; then
                    NOFIRSTRUN="${BASH_REMATCH[1]}"
                fi
                ;;
            TARDISCARD)
                if [[ "$line" =~ ^DISCARD=([0-1])$ ]]; then
                    DISCARD_ENABLED="${BASH_REMATCH[1]}"
                fi
                ;;
            LOGPRUNE)
                if [[ "$line" =~ ^ENABLED=([0-1])$ ]]; then
                    logprune_enabled="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^DISCARD_MAX_AGE_DAYS=([0-9]+)$ ]]; then
                    logprune_discard_max_age_days="${BASH_REMATCH[1]}"
                fi
                ;;
        esac
    done < "$CONFIG"

    for item in "${items[@]}"; do
        if [ -f "$item" ]; then
            files+=("$item")
        elif [ -d "$item" ]; then
            folders+=("$item")
        fi
    done

    if [ -z "$cron_schedule" ]; then
        echo "[ERROR] Missing 'schedule=' in [SCHEDULE] section of $CONFIG."
        log_message "ERROR: Missing 'schedule=' in [SCHEDULE] section."
        exit 1
    elif ! echo "$cron_schedule" | grep -Eq '^[[:space:]]*([0-9*/,-]+[[:space:]]+){4}[0-9*/,-]+[[:space:]]*$'; then
        echo "[ERROR] Invalid cron schedule in $CONFIG: $cron_schedule"
        log_message "ERROR: Invalid cron schedule: $cron_schedule"
        exit 1
    fi
}

matches_pattern() {
    local string="$1"
    local pattern="$2"
    if [[ "$pattern" == *'*' ]]; then
        local base_path="${pattern%\*}"
        if [[ "$string" == "$base_path"* ]]; then
            return 0
        fi
    fi
    case "$string" in
        $pattern)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

build_exclude_patterns() {
    exclude_patterns=()
    if [ -n "$BACKUP_DIR" ]; then
        exclude_patterns+=("--exclude=$BACKUP_DIR")
        log_message "DEBUG: System Auto-exclude applied: $BACKUP_DIR"
    fi
    for pattern in "${ignores[@]}"; do
        exclude_patterns+=("--exclude=$pattern")
    done
}

should_log_diff() {
    local file="$1"
    for pattern in "${nologs[@]}"; do
        if matches_pattern "$file" "$pattern"; then
            log_message "DEBUG: $file matches NOLOG pattern $pattern"
            return 1
        fi
    done
    for pattern in "${logdiffs[@]}"; do
        if matches_pattern "$file" "$pattern"; then
            log_message "DEBUG: $file matches LOGDIFF pattern $pattern"
            return 0
        fi
    done
    return 1
}

create_tar() {
    local tar_file="$1"
    local tar_cmd=(tar -czf "$tar_file" "${exclude_patterns[@]}")
    local items=()

    log_message "Starting backup creation..."

    for file in "${files[@]}"; do
        if [ -e "$file" ]; then
            items+=("$file")
            log_message "DEBUG: Including file $file"
        else
            log_message "WARNING: File $file does not exist, skipping."
        fi
    done

    for folder in "${folders[@]}"; do
        if [ -d "$folder" ]; then
            items+=("$folder")
            log_message "DEBUG: Including folder $folder"
        else
            log_message "WARNING: Folder $folder does not exist, skipping."
        fi
    done

    if [ ${#items[@]} -eq 0 ]; then
        log_message "ERROR: No valid files or folders to back up."
        return 1
    fi

    tar_cmd+=("${items[@]}")
    log_message "DEBUG: Running tar command: ${tar_cmd[*]}"

    local tar_errors
    tar_errors=$("${tar_cmd[@]}" 2>&1) || {
        log_message "ERROR: Failed to create tar file $tar_file: $tar_errors"
        return 1
    }

    if [ -f "$tar_file" ]; then
        log_message "Tar file created: $tar_file"
        sync
        return 0
    else
        log_message "ERROR: Tar file $tar_file not created."
        return 1
    fi
}

verify_tar() {
    local tar_file="$1"
    log_message "[Verification]"
    if tar -tzf "$tar_file" >/dev/null 2>>"$LOG_FILE"; then
        log_message "Tar file verified successfully."
        return 0
    else
        log_message "ERROR: Tar file $tar_file is corrupt or invalid."
        rm -f "$tar_file"
        return 1
    fi
}

cleanup_log() {
    if [ ! -f "$LOG_FILE" ]; then
        return
    fi
    local temp_log=""
    local retries=3
    local attempt=1
    while [ $attempt -le $retries ]; do
        temp_log=$(mktemp 2>>"$LOG_FILE") && break
        log_message "WARNING: mktemp failed on attempt $attempt, retrying..."
        sleep 1
        ((attempt++))
    done
    if [ -z "$temp_log" ]; then
        log_message "ERROR: Failed to create temporary log file after $retries attempts."
        echo "[ERROR] Failed to create temporary log file after $retries attempts."
        return 1
    fi
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local processed_patterns=()
    while IFS= read -r line; do
        if [[ "$line" == *[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\ -\ Changes\ detected\ in\ * ]]; then
            local file_path="${line#* Changes detected in }"
            file_path="${file_path%% [REDACTED]*}"
            local is_nolog=0
            for pattern in "${nologs[@]}"; do
                if [[ "$pattern" == *'*' && "$file_path" == "$pattern"* && ! " ${processed_patterns[*]} " =~ " $pattern " ]]; then
                    local match_count=$(grep -cE "Changes detected in $pattern( \[REDACTED\])?" "$LOG_FILE")
                    echo "        $timestamp - Changes detected in $pattern [REDACTED]" >> "$temp_log"
                    if [ $match_count -gt 1 ]; then
                        echo "        $timestamp - [NOLOG]: Multiple changes detected but not logged (see [NOLOG] in $SCRIPT_NAME.cfg)" >> "$temp_log"
                    else
                        echo "        $timestamp - [NOLOG]: Change detected but not logged (see [NOLOG] in $SCRIPT_NAME.cfg)" >> "$temp_log"
                    fi
                    processed_patterns+=("$pattern")
                    is_nolog=1
                    break
                elif [[ "$file_path" == "$pattern" ]]; then
                    echo "        $timestamp - Changes detected in $pattern" >> "$temp_log"
                    echo "        $timestamp - [NOLOG]: Change detected but not logged (see [NOLOG] in $SCRIPT_NAME.cfg)" >> "$temp_log"
                    is_nolog=1
                    break
                fi
            done
            [ $is_nolog -eq 0 ] && echo "$line" >> "$temp_log"
        else
            echo "$line" >> "$temp_log"
        fi
    done < "$LOG_FILE"
    if [ -s "$temp_log" ]; then
        mv "$temp_log" "$LOG_FILE" || {
            log_message "ERROR: Failed to move $temp_log to $LOG_FILE."
            echo "[ERROR] Failed to move $temp_log to $LOG_FILE."
            rm -f "$temp_log"
            return 1
        }
        sync
    else
        rm -f "$temp_log"
        log_message "ERROR: Log cleanup failed, temp log is empty."
        return 1
    fi
}

prune_log_file() {
    if [ "${logprune_enabled:-0}" -eq 0 ]; then
        log_message "DEBUG: Log pruning is disabled, skipping."
        return 0
    fi
    if [ ! -s "$LOG_FILE" ]; then
        return 0
    fi

    local delimiter="========== BACKUP RUN STARTED =========="

    local awk_script='
    BEGIN {
        RS = delimiter
        first_block = 1
    }

    {
        if (first_block) {
            printf "%s", $0
            first_block = 0
            next
        }

        full_block = delimiter $0

        if (full_block ~ /INFO: Backup tagged as: RETAIN/) {
            printf "%s", full_block
            next
        }

        if (full_block ~ /INFO: Backup tagged as: DISCARD/) {
            if (match(full_block, /Timestamp: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})/, arr)) {
                run_date_str = arr[1]
                gsub(/[-:]/, " ", run_date_str)
                run_timestamp = mktime(run_date_str)

                if (run_timestamp >= cutoff) {
                    printf "%s", full_block
                }
            } else {
                printf "%s", full_block
            }
            next
        }

        if (match(full_block, /Timestamp: ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})/, arr)) {
            run_date_str = arr[1]
            gsub(/[-:]/, " ", run_date_str)
            run_timestamp = mktime(run_date_str)
            if (run_timestamp >= cutoff) {
                printf "%s", full_block
            }
        } else {
            printf "%s", full_block
        }
    }'

    log_message "[Log Pruning]"

    local cutoff_timestamp
    cutoff_timestamp=$(date -d "$logprune_discard_max_age_days days ago" +%s)

    local temp_log
    temp_log=$(mktemp) || {
        log_message "ERROR: Failed to create temporary file for log pruning."
        return 1
    }

    gawk -v cutoff="$cutoff_timestamp" -v delimiter="$delimiter" "$awk_script" "$LOG_FILE" > "$temp_log"

    if [ -s "$temp_log" ]; then
        local lines_before
        lines_before=$(wc -l < "$LOG_FILE")
        local lines_after
        lines_after=$(wc -l < "$temp_log")
        local lines_pruned=$((lines_before - lines_after))
        if [ "$lines_pruned" -gt 0 ]; then
            log_message "INFO: Pruned $lines_pruned lines from the log file."
        fi
        mv "$temp_log" "$LOG_FILE"
    else
        log_message "WARNING: Log pruning resulted in an empty file. Keeping original log."
        rm -f "$temp_log"
    fi
}

run_rsync() {
    local src="$1"
    local dest="$2"
    local retries=3
    local timeout=300
    local attempt=1
    local rsync_output
    while [ $attempt -le $retries ]; do
        log_message "DEBUG: Attempt $attempt of rsync from $src to $dest"
        rsync_output=$(timeout $timeout rsync -av --timeout=30 "$src" "$dest" 2>&1)
        if [ $? -eq 0 ]; then
            log_message "DEBUG: rsync succeeded on attempt $attempt"
            echo "$rsync_output"
            return 0
        else
            log_message "WARNING: rsync attempt $attempt failed: $rsync_output"
            sleep 10
            ((attempt++))
        fi
    done
    log_message "ERROR: rsync failed after $retries attempts"
    echo "$rsync_output"
    return 1
}

sync_destinations() {
    log_message "[Sync Destinations]"
    if [ ${#destinations[@]} -lt 2 ]; then
        log_message "Only one destination, no sync needed."
        return 0
    fi
    local primary_dest=""
    local max_files=0
    local metadata_file="$ASSETS_DIR/.tar_meta_data.txt"
    for dest in "${destinations[@]}"; do
        mkdir -p "$dest"
        local file_count=$(ls "$dest"/*.tar.gz 2>/dev/null | wc -l)
        if [ $file_count -gt $max_files ]; then
            primary_dest="$dest"
            max_files=$file_count
            log_message "DEBUG: Selected $primary_dest as primary ($file_count files)"
        fi
    done

    if [ -z "$primary_dest" ] && [ -f "$metadata_file" ]; then
        local latest_file=$(tail -n 1 "$metadata_file" | cut -d: -f1)
        for dest in "${destinations[@]}"; do
            mkdir -p "$dest"
            if [ -f "$dest/$latest_file" ]; then
                primary_dest="$dest"
                log_message "DEBUG: Selected $primary_dest as primary (has latest file $latest_file from metadata)"
                break
            fi
        done
    fi
    if [ -z "$primary_dest" ]; then
        log_message "No backups found in any destination, skipping sync."
        return 0
    fi
    echo "$primary_dest" > "$ASSETS_DIR/.primary_dest"
    for dest in "${destinations[@]}"; do
        if [ "$dest" != "$primary_dest" ]; then
            mkdir -p "$dest"
            local start_time=$(date +%s)
            rsync_output=$(run_rsync "$primary_dest/" "$dest/")
            if [ $? -eq 0 ]; then
                log_message "Synced backups from $primary_dest to $dest via rsync."
                sync
            else
                log_message "WARNING: Failed to sync backups to $dest: $rsync_output"
            fi
            [ ${DEBUG_ENABLED:-0} -eq 1 ] && log_message "DEBUG: Sync to $dest took: $(( $(date +%s) - start_time )) seconds"
        fi
    done
    return 0
}

compare_tars() {
    local new_tar="$1"
    local latest_backup=""
    local prev_discard_latest=""
    local metadata_file="$ASSETS_DIR/.tar_meta_data.txt"

    log_message "DEBUG: Entering compare_tars for $new_tar"

    for dest in "${destinations[@]}"; do
        mkdir -p "$dest"
        local file_count=$(ls "$dest"/*.tar.gz 2>/dev/null | wc -l)
        if [ $file_count -gt 0 ]; then
            latest_backup=$(ls -t "$dest"/*.tar.gz 2>/dev/null | head -n 1)
            if [ -n "$latest_backup" ]; then
                break
            fi
        fi
    done

    if [ -z "$latest_backup" ] && [ -f "$metadata_file" ]; then
        local latest_file=$(tail -n 1 "$metadata_file" | cut -d: -f1)
        for dest in "${destinations[@]}"; do
            mkdir -p "$dest"
            if [ -f "$dest/$latest_file" ]; then
                latest_backup="$dest/$latest_file"
                break
            fi
        done
    fi

    log_message "[Comparison]"

    if [ -z "$latest_backup" ]; then
        log_message "No previous backup found. Treating as first backup."
        if [ ${NOFIRSTRUN:-0} -eq 1 ]; then
            tar -tf "$new_tar" | while read -r rel_path; do
                if [ -f "/$rel_path" ]; then
                    log_message "First backup: /$rel_path marked as changed."
                fi
            done
        fi
        mkdir -p "$ASSETS_DIR"
        echo "${new_tar##*/}:RETAIN:FIRST" > "$metadata_file"
        log_message "DEBUG: Exiting compare_tars (no previous backup)"
        return 0
    fi

    local new_temp_dir=$(mktemp -d)
    local old_temp_dir=$(mktemp -d)

    local original_trap
    original_trap=$(trap -p EXIT | sed "s/trap -- '\(.*\)' EXIT/\1/" || true)
    trap 'rm -rf "${new_temp_dir:-}" "${old_temp_dir:-}"' EXIT

    if ! tar -xzf "$new_tar" -C "$new_temp_dir" 2>>"$LOG_FILE"; then
        log_message "ERROR: Failed to extract $new_tar."
        rm -rf "$new_temp_dir" "$old_temp_dir"
        if [ -n "$original_trap" ]; then
            trap "$original_trap" EXIT
        else
            trap - EXIT
        fi
        log_message "DEBUG: Exiting compare_tars (extraction error new_tar)"
        return 1
    fi
    if ! tar -xzf "$latest_backup" -C "$old_temp_dir" 2>>"$LOG_FILE"; then
        log_message "ERROR: Failed to extract $latest_backup."
        rm -rf "$new_temp_dir" "$old_temp_dir"
        if [ -n "$original_trap" ]; then
            trap "$original_trap" EXIT
        else
            trap - EXIT
        fi
        log_message "DEBUG: Exiting compare_tars (extraction error latest_backup)"
        return 1
    fi

    local has_changes=0
    local retain_changes=0
    nolog_changes=()

    while IFS= read -r -d '' new_file; do
        local rel_path="${new_file#$new_temp_dir/}"
        local old_file="$old_temp_dir/$rel_path"
        local source_path="/$rel_path"

        log_message "DEBUG: Comparing $source_path"
        if [ ! -f "$old_file" ]; then
            has_changes=1
            nolog_matched=0
            for pattern in "${nologs[@]}"; do
                if matches_pattern "$source_path" "$pattern"; then
                    if [[ "$pattern" == *'*' ]]; then
                        base_path="$pattern"
                        nolog_changes["$base_path"]+="$source_path\n"
                    else
                        nolog_changes["$source_path"]="single"
                    fi
                    nolog_matched=1
                    break
                fi
            done
            if [ $nolog_matched -eq 0 ]; then
                log_message "New file detected: $source_path"
                retain_changes=1
            fi
        elif ! cmp -s "$new_file" "$old_file" 2>>"$LOG_FILE"; then
            has_changes=1
            nolog_matched=0
            for pattern in "${nologs[@]}"; do
                if matches_pattern "$source_path" "$pattern"; then
                    if [[ "$pattern" == *'*' ]]; then
                        base_path="$pattern"
                        nolog_changes["$base_path"]+="$source_path\n"
                    else
                        nolog_changes["$source_path"]="single"
                    fi
                    nolog_matched=1
                    break
                fi
            done
            if [ $nolog_matched -eq 0 ]; then
                if should_log_diff "$source_path"; then
                    log_message "Changes detected in FILE: $source_path"
                    retain_changes=1
                    diff_output=$(diff -u "$old_file" "$new_file" 2>>"$LOG_FILE" || true)
                    if [ -n "$diff_output" ]; then
                        while IFS= read -r line; do
                            if [[ "$line" == -* && "$line" != ---* ]]; then
                                log_message "Removed from the FILE: '${line#-}'"
                            elif [[ "$line" == +* && "$line" != +++* ]]; then
                                log_message "Added to the FILE: '${line#+}'"
                            fi
                        done <<< "$diff_output"
                        log_message ""
                    else
                        log_message "Modified, FILE:"
                        log_message "'$(cat "$new_file" 2>>"$LOG_FILE" | head -n 1)'"
                        log_message ""
                    fi
                else
                    log_message "Changes detected in $source_path"
                    retain_changes=1
                fi
            fi
        else
            log_message "DEBUG: No changes in $source_path"
        fi
    done < <(find "$new_temp_dir" -type f -print0 2>>"$LOG_FILE" || {
        log_message "ERROR: Failed to find files in $new_temp_dir"
        rm -rf "$new_temp_dir" "$old_temp_dir"
        if [ -n "$original_trap" ]; then
            trap "$original_trap" EXIT
        else
            trap - EXIT
        fi
        log_message "DEBUG: Exiting compare_tars (find error new_temp_dir)"
        return 1
    })

    while IFS= read -r -d '' old_file; do
        local rel_path="${old_file#$old_temp_dir/}"
        local new_file="$new_temp_dir/$rel_path"
        local source_path="/$rel_path"

        if [ ! -f "$new_file" ]; then
            has_changes=1
            nolog_matched=0
            for pattern in "${nologs[@]}"; do
                if matches_pattern "$source_path" "$pattern"; then
                    if [[ "$pattern" == *'*' ]]; then
                        base_path="$pattern"
                        nolog_changes["$base_path"]+="$source_path\n"
                    else
                        nolog_changes["$source_path"]="single"
                    fi
                    nolog_matched=1
                    break
                fi
            done
            if [ $nolog_matched -eq 0 ]; then
                log_message "File deleted: $source_path"
                retain_changes=1
            fi
        fi
    done < <(find "$old_temp_dir" -type f -print0 2>>"$LOG_FILE" || {
        log_message "ERROR: Failed to find files in $old_temp_dir"
        rm -rf "$new_temp_dir" "$old_temp_dir"
        if [ -n "$original_trap" ]; then
            trap "$original_trap" EXIT
        else
            trap - EXIT
        fi
        log_message "DEBUG: Exiting compare_tars (find error old_temp_dir)"
        return 1
    })

    for path in "${!nolog_changes[@]}"; do
        if [[ "${nolog_changes[$path]}" == "single" ]]; then
            log_message "Changes detected in $path"
            log_message "[NOLOG]: Change detected but not logged (see [NOLOG] in $SCRIPT_NAME.cfg)"
        else
            changes=($(echo -e "${nolog_changes[$path]}" | tr '\n' ' '))
            if [ ${#changes[@]} -gt 1 ]; then
                log_message "Changes detected in $path [REDACTED]"
                log_message "[NOLOG]: Multiple changes detected but not logged (see [NOLOG] in $SCRIPT_NAME.cfg)"
            else
                log_message "Changes detected in ${changes[0]}"
                log_message "[NOLOG]: Change detected but not logged (see [NOLOG] in $SCRIPT_NAME.cfg)"
            fi
        fi
    done

    rm -rf "$new_temp_dir" "$old_temp_dir"

    if [ -n "$original_trap" ]; then
        trap "$original_trap" EXIT
    else
        trap - EXIT
    fi

    if [ $has_changes -eq 0 ]; then
        log_message "INFO: Backup Skipped: No Changes Detected"
        rm -f "$new_tar"
        echo "[INFO] No changes detected. Backup creation skipped."
        log_message "DEBUG: Exiting compare_tars (no changes)"
        return 1
    else
        local metadata_file="$ASSETS_DIR/.tar_meta_data.txt"
        local tag="DISCARD"
        local subtag=":LATEST"
        if [ $retain_changes -eq 1 ]; then
            tag="RETAIN"
            subtag=""
        fi
        mkdir -p "$ASSETS_DIR"
        local prev_discard_latest=""
        if [ -f "$metadata_file" ]; then
            local temp_metadata=$(mktemp)
            while IFS=: read -r tar_file old_tag old_subtag; do
                if [[ "$old_tag" == "DISCARD" && "$old_subtag" == "LATEST" ]]; then
                    prev_discard_latest="$tar_file"
                    echo "$tar_file:DISCARD" >> "$temp_metadata"
                else
                    echo "$tar_file:$old_tag${old_subtag:+:$old_subtag}" >> "$temp_metadata"
                fi
            done < "$metadata_file"
            mv "$temp_metadata" "$metadata_file"
        fi
        echo "${new_tar##*/}:$tag$subtag" >> "$metadata_file"
        log_message "INFO: Backup tagged as: $tag$subtag"
        log_message "Changes detected between:"
        log_message "  New: $new_tar"
        log_message "  Previous: $latest_backup"
        echo "$prev_discard_latest"
        log_message "DEBUG: Exiting compare_tars (changes detected)"
        return 0
    fi
}

create_backup() {
    mkdir -p "$BACKUP_DIR"
    local new_tar="$BACKUP_DIR/$BACKUP_NAME"
    log_message "[Backup Creation]"
    if ! create_tar "$new_tar"; then
        log_message "ERROR: Failed to create backup tar."
        exit 1
    fi
    if ! compare_tars "$new_tar"; then
        rm -f "$new_tar"
        return 1
    fi
    if ! verify_tar "$new_tar"; then
        log_message "ERROR: Tar file $new_tar is corrupt or invalid."
        rm -f "$new_tar"
        return 1
    fi
    log_message "INFO: Backup created: $new_tar"
    echo "INFO: Backup created: $new_tar"
    move_backup
    old_tar_removal
    return 0
}

move_backup() {
    local at_least_one_success=0
    log_message "[Transfer]"
    for dest in "${destinations[@]}"; do
        mkdir -p "$dest"
        local start_time=$(date +%s)
        rsync_output=$(run_rsync "$BACKUP_DIR/$BACKUP_NAME" "$dest/")
        if [ $? -eq 0 ]; then
            log_message "INFO: Backup copied to $dest/$BACKUP_NAME via rsync."
            echo "INFO: Backup copied to $dest/$BACKUP_NAME"
            sync
            at_least_one_success=1
        else
            log_message "WARNING: Failed to copy backup to $dest via rsync: $rsync_output"
            echo "WARNING: Failed to copy backup to $dest"
        fi
        [ ${DEBUG_ENABLED:-0} -eq 1 ] && log_message "DEBUG: Transfer to $dest took: $(( $(date +%s) - start_time )) seconds"
    done
    log_message "[Cleanup]"
    if [ $at_least_one_success -eq 1 ]; then
        rm -f "$BACKUP_DIR/$BACKUP_NAME"
        log_message "INFO: Backup removed from $BACKUP_DIR/$BACKUP_NAME"
        echo "INFO: Local backup removed: $BACKUP_DIR/$BACKUP_NAME"
    else
        log_message "ERROR: No backups copied successfully, retaining $BACKUP_DIR/$BACKUP_NAME"
        echo "ERROR: No backups copied successfully, retaining $BACKUP_DIR/$BACKUP_NAME"
    fi
    sync_destinations
}

setup_cron_job() {
    local script_path="$SCRIPT_DIR/$SCRIPT_FILE_NAME"
    local cron_command="/bin/bash \"$script_path\" --update >> \"$LOG_FILE\" 2>&1"
    local cron_entry="$cron_schedule $cron_command"

    touch "$LOG_FILE"

    if [ "$cron_enabled" -eq 0 ]; then
        if crontab -l 2>/dev/null | grep -F "$cron_command" >/dev/null; then
            crontab -l 2>/dev/null | grep -vF "$cron_command" | crontab -
            echo "[INFO] Cron job for $SCRIPT_FILE_NAME --update removed."
            log_message "INFO: Cron job for $SCRIPT_FILE_NAME --update removed."
        else
            log_message "Cron job setup skipped (disabled in $SCRIPT_NAME.cfg)."
        fi
        return
    fi

    if crontab -l 2>/dev/null | grep -F "$cron_entry" >/dev/null; then
        echo "[INFO] Cron job for $SCRIPT_FILE_NAME --update already exists with schedule '$cron_schedule'."
        log_message "INFO: Cron job for $SCRIPT_FILE_NAME --update already exists with schedule '$cron_schedule'."
    else
        if crontab -l 2>/dev/null | grep -F "$cron_command" >/dev/null; then
            crontab -l 2>/dev/null | grep -vF "$cron_command" | crontab -
            log_message "INFO: Removed outdated cron job for $SCRIPT_FILE_NAME --update."
        fi
        (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
        echo "[SUCCESS] Cron job added: $SCRIPT_FILE_NAME --update with schedule '$cron_schedule'."
        log_message "SUCCESS: Cron job added: $SCRIPT_FILE_NAME --update with schedule '$cron_schedule'."
    fi
}

old_tar_removal() {
    if [ "${DISCARD_ENABLED:-0}" -eq 0 ]; then
        log_message "INFO: Tar removal disabled in [TARDISCARD] section."
        return 0
    fi

    log_message "[Tar Removal]"
    local metadata_file="$ASSETS_DIR/.tar_meta_data.txt"
    if [ ! -f "$metadata_file" ]; then
        log_message "INFO: No metadata file found, skipping tar removal."
        return 0
    fi

    local temp_metadata=$(mktemp)
    local latest_discard=""
    while IFS=: read -r tar_file tag subtag; do
        if [[ "$tag" == "DISCARD" && "$subtag" == "LATEST" ]]; then
            latest_discard="$tar_file"
        elif [[ "$tag" == "DISCARD" ]]; then
            for dest in "${destinations[@]}"; do
                if [ -f "$dest/$tar_file" ]; then
                    rm -f "$dest/$tar_file" && log_message "Removed $tar_file from $dest."
                fi
            done
        fi
        echo "$tar_file:$tag${subtag:+:$subtag}" >> "$temp_metadata"
    done < "$metadata_file"

    if [ -s "$temp_metadata" ]; then
        mv "$temp_metadata" "$metadata_file"
    else
        rm -f "$temp_metadata"
        log_message "ERROR: Temporary metadata file empty, keeping original."
    fi
    return 0
}

wait_for_background() {
    log_message "DEBUG: Waiting for background processes to complete"
    while pgrep -P $$ > /dev/null 2>&1; do
        sleep 1
    done
    log_message "DEBUG: All background processes completed"
    return 0
}

main() {
    LOCK_FILE="/tmp/$SCRIPT_NAME.lock"
    TEMP_LOG="/tmp/$SCRIPT_NAME-temp.log"
    if [ -f "$LOCK_FILE" ]; then
        pid=$(cat "$LOCK_FILE" 2>>"$TEMP_LOG") || {
            echo "ERROR: Failed to read lock file $LOCK_FILE" >>"$TEMP_LOG"
            echo "[ERROR] Failed to read lock file $LOCK_FILE"
            exit 1
        }
        if ! ps -p "$pid" > /dev/null 2>&1; then
            log_message "WARNING: Stale lock file found for PID $pid, removing."
            rm -f "$LOCK_FILE" || {
                echo "ERROR: Failed to remove stale lock file $LOCK_FILE" >>"$TEMP_LOG"
                echo "[ERROR] Failed to remove stale lock file $LOCK_FILE"
                exit 1
            }
        else
            log_message "ERROR: Another instance of $SCRIPT_NAME is running (PID $pid)."
            echo "ERROR: Another instance of $SCRIPT_NAME is running (PID $pid)."
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE" || {
        echo "ERROR: Failed to create lock file $LOCK_FILE" >>"$TEMP_LOG"
        echo "[ERROR] Failed to create lock file $LOCK_FILE"
        exit 1
    }
    trap 'wait_for_background || true; rm -f "$LOCK_FILE" || true; log_message "DEBUG: Executing main EXIT trap"; log_message "========== BACKUP RUN ENDED ==========" || true; sync || true; rm -f "$TEMP_LOG" || true' EXIT
    echo "$SCRIPT_TITLE $SCRIPT_FILE_NAME $CODE_VERSION"
    if ! parse_rules; then
        log_message "ERROR: parse_rules failed."
        exit 1
    fi
    if ! build_exclude_patterns; then
        log_message "ERROR: build_exclude_patterns failed."
        exit 1
    fi
    prune_log_file
    log_message "========== BACKUP RUN STARTED =========="
    log_message "Run Type: $BACKUP_TYPE"
    log_message "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    log_message "Backup Name: $BACKUP_NAME"
    if ! touch "$LOG_FILE"; then
        echo "ERROR: Failed to create or touch $LOG_FILE" >>"$TEMP_LOG"
        echo "[ERROR] Failed to create or touch $LOG_FILE"
        exit 1
    fi
    if ! check_requirements; then
        log_message "ERROR: check_requirements failed."
        exit 1
    fi
    sync_destinations
    if ! create_backup; then
        log_message "INFO: Backup process completed with no new backup created."
    fi
    setup_cron_job
}

main "$@"
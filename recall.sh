#!/bin/bash
# Cerebro Recall Utility v1.0
# Copyright (c) 2026 Arelius-D | MIT License
# Extraction and Restoration Tool for the Cerebro Suite
set -euo pipefail

SCRIPT_NAME=$(basename "$0" .sh)
SCRIPT_TITLE="Cerebro Recall Utility"
CODE_VERSION="v1.0"
SCRIPT_DIR="${SCRIPT_DIR:-$(dirname "$(realpath "$0")")}"
CONFIG="$SCRIPT_DIR/cerebro.cfg"
ASSETS_DIR="$SCRIPT_DIR/assets"
LOG_FILE="$SCRIPT_DIR/$SCRIPT_NAME.log"
HOSTNAME=$(hostname)

log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ "$message" == "=========="* || -z "$message" ]]; then
        echo "$message"
    elif [[ "$message" =~ ^\[(SUCCESS|INFO|WARNING|ERROR)\] ]]; then
        echo -e "$message"
    else
        echo "  $message"
    fi

    if [[ "$message" == "=========="* || -z "$message" ]]; then
        echo "$message" >> "$LOG_FILE"
    else
        echo "[$timestamp] $message" >> "$LOG_FILE"
    fi
}

show_help() {
    echo "================================================================"
    echo "  $SCRIPT_TITLE $CODE_VERSION"
    echo "================================================================"
    echo "Usage: ./$SCRIPT_NAME.sh [OPTIONS] <search_term_1> [search_term_2] ..."
    echo ""
    echo "Options:"
    echo "  -h, --help    Show this help message and exit"
    echo ""
    echo "Examples:"
    echo "  1. Extract a single file:"
    echo "     ./$SCRIPT_NAME.sh ddns-fix.sh"
    echo ""
    echo "  2. Extract multiple specific files:"
    echo "     ./$SCRIPT_NAME.sh ddns-fix.sh cerebro.cfg"
    echo ""
    echo "  3. Extract an entire folder (use trailing slash for clarity):"
    echo "     ./$SCRIPT_NAME.sh Apps/tutor/"
    echo ""
    echo "  4. Combination of files and folders:"
    echo "     ./$SCRIPT_NAME.sh Apps/tutor/ docker-compose.yml"
    echo ""
    echo "Details:"
    echo "  - The script automatically locates the latest valid Cerebro backup."
    echo "  - It uses a fuzzy search. If multiple files match a term, you will be prompted to select the correct one."
    echo "  - Extracted files are safely placed in their original absolute paths with a '.bak' extension to prevent accidental overwrites."
    echo "================================================================"
}

if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_help
            exit 0
            ;;
    esac
done

search_terms=("$@")

touch "$LOG_FILE"
log_message "========== RECALL SESSION STARTED =========="
log_message "[INFO] Search terms: ${search_terms[*]}"

destinations=()
if [ -f "$CONFIG" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        if [ "$section" = "DESTINATIONS" ]; then
            destinations+=("${line%/}/$HOSTNAME")
        fi
    done < "$CONFIG"
else
    log_message "[ERROR] $CONFIG not found."
    exit 1
fi

latest_backup=""
metadata_file="$ASSETS_DIR/.tar_meta_data.txt"

find_args=()
for dest in "${destinations[@]}"; do
    if [ -d "$dest" ]; then
        find_args+=("$dest")
    fi
done

if [ ${#find_args[@]} -gt 0 ]; then
    latest_backup=$(find "${find_args[@]}" -maxdepth 1 -name "*.tar.gz" -printf "%T@ %p\n" 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-)
fi

if [ -z "$latest_backup" ] && [ -f "$metadata_file" ]; then
    latest_file=$(tail -n 1 "$metadata_file" | cut -d: -f1)
    for dest in "${destinations[@]}"; do
        if [ -f "$dest/$latest_file" ]; then
            latest_backup="$dest/$latest_file"
            break
        fi
    done
fi

if [ -z "$latest_backup" ]; then
    log_message "[ERROR] Could not find any backups in destinations."
    log_message "========== RECALL SESSION ENDED =========="
    exit 1
fi

log_message "[INFO] Target Backup: $(basename "$latest_backup")"
log_message "[INFO] Located at: $(dirname "$latest_backup")"

log_message "[INFO] Indexing archive contents..."
archive_contents=$(tar -tzf "$latest_backup" 2>/dev/null || true)

if [ -z "$archive_contents" ]; then
    log_message "[ERROR] Failed to read archive or archive is empty."
    exit 1
fi

extract_item() {
    local target_path="$1"
    local temp_dir="$2"

    local target_absolute_file="$target_path"
    if [[ "$target_path" != /* ]]; then
        target_absolute_file="/$target_path"
    fi
    if [[ "$target_absolute_file" == /./* ]]; then
        target_absolute_file="${target_absolute_file/\/.\//\/}"
    fi

    local target_dir backup_dest
    if [[ "$target_path" == */ ]]; then
        target_dir="${target_absolute_file%/}"
        backup_dest="${target_dir}_bak"
    else
        target_dir=$(dirname "$target_absolute_file")
        backup_dest="${target_absolute_file}.bak"
    fi

    local parent_dir=$(dirname "$backup_dest")
    if [ ! -d "$parent_dir" ]; then
        log_message "[INFO] Local path $parent_dir does not exist, creating it."
        sudo mkdir -p "$parent_dir"
    fi

    log_message "[INFO] Extracting '$target_path' to temp..."
    if ! tar -xzf "$latest_backup" -C "$temp_dir" "$target_path" 2>/dev/null; then
        log_message "[ERROR] Failed to extract from archive: $target_path"
        return 1
    fi

    local extracted_path="$temp_dir/$target_path"

    if cp -r "$extracted_path" "$backup_dest" 2>/dev/null; then
        log_message "[SUCCESS] Saved to -> $backup_dest"
    else
        if sudo cp -r "$extracted_path" "$backup_dest"; then
            user_owner=$(stat -c '%U' "$parent_dir" 2>/dev/null || echo "$USER")
            group_owner=$(stat -c '%G' "$parent_dir" 2>/dev/null || echo "$USER")
            sudo chown -R "$user_owner:$group_owner" "$backup_dest"
            log_message "[SUCCESS] Saved to -> $backup_dest (sudo)"
        else
            log_message "[ERROR] Failed to copy to destination: $backup_dest"
            return 1
        fi
    fi
}

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

for term in "${search_terms[@]}"; do
    log_message ""
    log_message "[INFO] Processing search term: '$term'"

    if [[ "$term" == */ ]]; then
        matching_dirs=$(echo "$archive_contents" | grep -i "${term}" | grep "/$" || true)

        if [ -z "$matching_dirs" ]; then
            log_message "[WARNING] No folder found matching '$term'."
            continue
        fi

        mapfile -t dir_array <<< "$matching_dirs"
        dir_count=${#dir_array[@]}

        if [ "$dir_count" -eq 1 ]; then
            exact_dir="${dir_array[0]}"
            extract_item "$exact_dir" "$temp_dir"
        else
            echo "Found $dir_count matching folders for '$term':"
            if [ "$dir_count" -gt 20 ]; then
                echo "Showing first 20 matches. Please refine your search term if your folder is not listed."
                dir_array=("${dir_array[@]:0:20}")
            fi

            PS3="Select the folder to extract for '$term' (or Cancel): "
            select sel in "${dir_array[@]}" "Cancel"; do
                if [ "$sel" = "Cancel" ]; then
                    log_message "[INFO] Skipped '$term'."
                    break
                elif [ -n "$sel" ]; then
                    extract_item "$sel" "$temp_dir"
                    break
                else
                    echo "Invalid selection."
                fi
            done
        fi
    else
        matching_files=$(echo "$archive_contents" | grep -i "$term" | grep -v "/$" || true)

        if [ -z "$matching_files" ]; then
            log_message "[WARNING] No files found matching '$term'."
            continue
        fi

        mapfile -t files_array <<< "$matching_files"
        file_count=${#files_array[@]}

        if [ "$file_count" -eq 1 ]; then
            exact_file="${files_array[0]}"
            extract_item "$exact_file" "$temp_dir"
        else
            echo "Found $file_count matching files for '$term':"
            if [ "$file_count" -gt 20 ]; then
                echo "Showing first 20 matches. Please refine your search term if your file is not listed."
                files_array=("${files_array[@]:0:20}")
            fi

            PS3="Select the file to extract for '$term' (or Cancel): "
            select sel in "${files_array[@]}" "Cancel"; do
                if [ "$sel" = "Cancel" ]; then
                    log_message "[INFO] Skipped '$term'."
                    break
                elif [ -n "$sel" ]; then
                    extract_item "$sel" "$temp_dir"
                    break
                else
                    echo "Invalid selection."
                fi
            done
        fi
    fi
done

log_message ""
log_message "========== RECALL SESSION ENDED =========="
sync
exit 0

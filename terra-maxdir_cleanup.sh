#!/bin/bash
#
# maxdir_cleanup.sh by TeRRaDude 01/01/2026
#
# (Based on OLD sig-directory_limit.sh by signor that,
#  Only could move stuff from sections to 1 Archive directory).
#
# Description:
#   Enforces maximum directory limits per glftpd section.
#   Oldest directories are cleaned (deleted or moved to per-section archive).
#
# Compatible:
#   Debian 12 and above
#
# Note:
#  Please take note that these scripts come without instructions on how to set
#  them up, it is sole responsibility of the end user to understand the scripts
#  function before executing them. If you do not know how to execute them, then
#  please don't use them. They come with no warranty should any damage happen due
#  to the improper settings and execution of these scripts (missing data, etc).
#
# ------------------------------------------------------------
# CHANGELOG
# ------------------------------------------------------------
# v1.0  Initial version
# v1.1  Added sandbox (dry-run) mode
# v1.2  Added multi-section support
# v1.3  Added move-to-archive option
# v1.4  Added glftpd compatible logging
# v1.5  Added path exclusion logic
# v1.6  Fixed false exclusions under /glftpd/site/*
# v1.7  Added hard safety rules (no root/site cleanup)
# v1.8  Added additional sanity checks & logging
# v1.9  Lockfile support
# v2.0  Per-section archive directories
# v2.1  Safety check for move to prevent overwrite
# v2.2  Added setup explanations for DELETE/MOVE
# v2.3  Lockfile chmod 644 and directory chmod 755
# ------------------------------------------------------------

############################################
# GLOBAL SETTINGS
############################################

# -------------------------------
# SANDBOX MODE
# -------------------------------
# true  = dry-run, only log what would be done
# false = live execution
SANDBOX=true

# -------------------------------
# CLEANUP ACTION
# -------------------------------
# "delete" = remove directories permanently (archive_dir is ignored)
# "move"   = move directories to per-section archive (archive_dir must be set per section)
CLEANUP_ACTION="move"

# -------------------------------
# LOGGING
# -------------------------------
LOG_DIR="/glftpd/ftp-data/logs"
LOG_FILE="maxdirectory.log"
gllog="$LOG_DIR/$LOG_FILE"

# -------------------------------
# LOCKFILE (prevents multiple instances)
# -------------------------------
LOCKFILE="/glftpd/tmp/maxdir_cleanup.lock"

# Ensure log directory exists
mkdir -p "$LOG_DIR"
touch "$gllog"
chmod 666 "$gllog"

############################################
# EXCLUDED PATHS (ABSOLUTE - NEVER TOUCH)
############################################

EXCLUDED_PATHS=(
    "/glftpd"
    "/_ARCHiVE"
    "/ARCHiVE"
    "/PRE"
    "/_PRE"
)

############################################
# SECTIONS CONFIGURATION
# -------------------------------
# Format per section:
#   For DELETE:
#       "SectionName|DirectoryPath|MaxDirectories"
#       - Archive directory is ignored
#   For MOVE:
#       "SectionName|DirectoryPath|MaxDirectories|ArchiveDirectory"
#       - ArchiveDirectory = target path where excess dirs are moved
# Example:
#   DELETE: "TV-Flemish|/glftpd/site/TV-Flemish|50"
#   MOVE:   "X265|/glftpd/site/X265|80|/glftpd/site/_ARCHiVE/X265-2160P"
#
############################################

SECTIONS=(
    "X265|/glftpd/sites/X265|5|/glftpd/sites/_ARCHiVE/X265-2160P"
    "TV-NL|/glftpd/sites/TV-NL|10|/glftpd/sites/_ARCHiVE/TV-X264NL"
)

############################################
####### END OF CONFiG ######################
############################################



############################################
# LOCKFILE CHECK
############################################

# Ensure lockfile directory exists with safe permissions
mkdir -p "$(dirname "$LOCKFILE")"
chmod 755 "$(dirname "$LOCKFILE")"

if [ -e "$LOCKFILE" ]; then
    echo "Lockfile exists, another instance may be running. Exiting." >> "$gllog"
    exit 1
fi

# Create lockfile with chmod 644
echo $$ > "$LOCKFILE"
chmod 644 "$LOCKFILE"

# Ensure lockfile removed on exit
trap 'rm -f "$LOCKFILE"' EXIT INT TERM

############################################
# FUNCTIONS
############################################

log_msg() {
    echo "$(date "+%a %b %e %T %Y") MAXDIRLOG: $1" >> "$gllog"
}

log_done() {
    echo "$(date "+%a %b %e %T %Y") MAXDIRLOGDONE: \"Cleanup Done $1\"" >> "$gllog"
}

is_excluded_path() {
    local path="$1"
    for excluded in "${EXCLUDED_PATHS[@]}"; do
        [[ "$path" == "$excluded" ]] && return 0
    done
    case "$path" in
        "/"|"/glftpd"|"/glftpd/site")
            return 0
            ;;
    esac
    return 1
}

############################################
# MAIN LOOP
############################################

for section_entry in "${SECTIONS[@]}"; do

    IFS="|" read -r section directory maxdirs archive_dir <<< "$section_entry"

    # Directory must exist
    if [[ ! -d "$directory" ]]; then
        log_msg "\"$section\" \"$directory\" Directory does not exist"
        continue
    fi

    # Safety checks
    if is_excluded_path "$directory"; then
        log_msg "\"$section\" \"$directory\" Path is excluded - skipped"
        continue
    fi

    if [[ "$(basename "$directory")" == "_ARCHiVE" ]]; then
        log_msg "\"$section\" \"$directory\" Archive directory skipped"
        continue
    fi

    # Collect first-level directories, oldest first
    mapfile -t dir_list < <(
        find "$directory" -mindepth 1 -maxdepth 1 -type d -printf "%T@ %p\n" | sort -n
    )

    total_dirs=${#dir_list[@]}
    (( total_dirs <= maxdirs )) && continue

    cleanup_count=$(( total_dirs - maxdirs ))
    cleaned=0

    log_msg "\"$section\" \"$directory\" Exceeds limit ($total_dirs/$maxdirs)"

    for (( i=0; i<cleanup_count; i++ )); do
        dir_to_clean=$(echo "${dir_list[$i]}" | cut -d' ' -f2-)

        if is_excluded_path "$dir_to_clean"; then
            log_msg "\"$section\" \"$dir_to_clean\" Excluded directory skipped"
            continue
        fi

        # Determine action label for logging
        if [[ "$CLEANUP_ACTION" == "delete" ]]; then
            ACTION_LABEL="clean"
        else
            ACTION_LABEL="archive"
        fi

        # For MOVE, calculate target_dir even in SANDBOX
        if [[ "$CLEANUP_ACTION" == "move" ]]; then
            mkdir -p "$archive_dir"
            target_dir="$archive_dir/$(basename "$dir_to_clean")"
            if [[ -e "$target_dir" ]]; then
                timestamp=$(date "+%Y%m%d-%H%M%S")
                target_dir="${target_dir}_$timestamp"
            fi
        fi

        if [[ "$SANDBOX" == "true" ]]; then
            if [[ "$CLEANUP_ACTION" == "delete" ]]; then
                log_msg "\"$section\" SANDBOX: Would clean \"$dir_to_clean\""
            else
                log_msg "\"$section\" SANDBOX: Would archive \"$dir_to_clean\" -> \"$target_dir\""
            fi
        else
            if [[ "$CLEANUP_ACTION" == "delete" ]]; then
                rm -rf -- "$dir_to_clean"
                log_msg "\"$section\" Cleaned \"$dir_to_clean\""
            else
                mv -- "$dir_to_clean" "$target_dir"
                log_msg "\"$section\" Archived \"$dir_to_clean\" -> \"$target_dir\""
            fi
        fi

        ((cleaned++))
    done

    log_done "$cleaned"

done

exit 0

#!/usr/bin/env bash
#
# Safe Swap Manager + Basic System Setup
# - Auto-calculates recommended swap size based on RAM
# - Modes: auto (default), set, increase, decrease
# - Dry-run support (--dry-run)
# - Memory safety checks before disabling old swap
# - Safe swap migration: create new -> enable -> disable old -> remove old
# - Optional system setup: timezone + apt update + nano + vnstat
#
# Usage examples:
#   ./safe-swap-manager.sh                    # auto mode (recommended)
#   ./safe-swap-manager.sh --mode auto        # same as above
#   ./safe-swap-manager.sh --mode set --size-mb 2048
#   ./safe-swap-manager.sh --mode increase --delta-mb 512
#   ./safe-swap-manager.sh --mode decrease --delta-mb 512
#   ./safe-swap-manager.sh --dry-run          # show what would happen
#   ./safe-swap-manager.sh --setup-system     # also set timezone + install tools
#
# Recommended for Debian/Ubuntu-based VPS.

set -euo pipefail

#######################################
# Default configuration
#######################################

SWAPFILE="/swapfile"
MIN_SAFE_FREE_RAM_MB=200      # Minimum free RAM required before disabling old swap
DEFAULT_TIMEZONE="Asia/Shanghai"

DRY_RUN=0
MODE="auto"                   # auto | set | increase | decrease
SIZE_MB=""                    # target size for 'set'
DELTA_MB=""                   # +/- size for increase/decrease
RUN_SETUP_SYSTEM=0
TIMEZONE="$DEFAULT_TIMEZONE"

#######################################
# Helper functions
#######################################

usage() {
  cat <<EOF
Safe Swap Manager

Options:
  --mode auto|set|increase|decrease
      auto      : (default) choose swap size based on total RAM
      set       : set swap to an exact size (requires --size-mb)
      increase  : increase current swap by delta (requires --delta-mb)
      decrease  : decrease current swap by delta (requires --delta-mb)

  --size-mb N       : target swap size in MB (for --mode set)
  --delta-mb N      : amount to increase/decrease swap in MB
  --dry-run         : show what would be done, without making changes
  --setup-system    : also set timezone, apt update, install nano & vnstat
  --timezone ZONE   : timezone to set with --setup-system (default: $DEFAULT_TIMEZONE)
  -h, --help        : show this help

Examples:
  $0
  $0 --mode auto
  $0 --mode set --size-mb 2048
  $0 --mode increase --delta-mb 512
  $0 --dry-run --mode auto
  $0 --setup-system
EOF
}

log() {
  echo -e "$*"
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    # shellcheck disable=SC2145
    echo "[RUN] $*"
    "$@"
  fi
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run as root (or with sudo)." >&2
    exit 1
  fi
}

#######################################
# Parse arguments
#######################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"; shift
      ;;
    --size-mb)
      SIZE_MB="${2:-}"; shift
      ;;
    --delta-mb)
      DELTA_MB="${2:-}"; shift
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --setup-system)
      RUN_SETUP_SYSTEM=1
      ;;
    --timezone)
      TIMEZONE="${2:-}"; shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

#######################################
# Validate arguments
#######################################

case "$MODE" in
  auto|set|increase|decrease) ;;
  *)
    echo "ERROR: Invalid --mode '$MODE'. Use auto|set|increase|decrease." >&2
    exit 1
    ;;
esac

if [[ "$MODE" == "set" && -z "$SIZE_MB" ]]; then
  echo "ERROR: --mode set requires --size-mb N" >&2
  exit 1
fi

if [[ ("$MODE" == "increase" || "$MODE" == "decrease") && -z "$DELTA_MB" ]]; then
  echo "ERROR: --mode $MODE requires --delta-mb N" >&2
  exit 1
fi

#######################################
# System info helpers
#######################################

get_ram_mb() {
  local mem_kb
  mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  echo $(( (mem_kb + 512) / 1024 ))
}

get_free_ram_mb() {
  free -m | awk '/Mem:/ {print $4}'
}

get_swap_total_mb() {
  free -m | awk '/Swap:/ {print $2}'
}

get_swap_free_mb() {
  free -m | awk '/Swap:/ {print $4}'
}

get_swap_used_mb() {
  local total free
  total=$(get_swap_total_mb)
  free=$(get_swap_free_mb)
  echo $(( total - free ))
}

recommended_swap_mb() {
  local ram_mb
  ram_mb=$(get_ram_mb)

  if   [[ "$ram_mb" -le 1024 ]]; then
    echo 2048         # <= 1GB RAM → 2GB swap
  elif [[ "$ram_mb" -le 2048 ]]; then
    echo 2048         # <= 2GB RAM → 2GB swap
  elif [[ "$ram_mb" -le 4096 ]]; then
    echo 1024         # <= 4GB RAM → 1GB swap
  else
    echo 0            # > 4GB RAM → no auto swap recommendation
  fi
}

get_existing_swap_files() {
  # Only return swap *files* (ignore partitions)
  swapon --show=NAME --noheadings 2>/dev/null | while read -r dev; do
    if [[ -f "$dev" ]]; then
      echo "$dev"
    fi
  done
}

#######################################
# Memory safety check
#######################################

memory_safety_check() {
  local free_ram_mb swap_used_mb
  free_ram_mb=$(get_free_ram_mb)
  swap_used_mb=$(get_swap_used_mb)

  log "Current free RAM: ${free_ram_mb}MB"
  log "Current swap used: ${swap_used_mb}MB"

  # We are using safe migration (new swap before old off) so this is conservative.
  if [[ "$free_ram_mb" -lt "$MIN_SAFE_FREE_RAM_MB" && "$swap_used_mb" -gt 0 ]]; then
    echo "ERROR: Memory too full to safely adjust swap right now." >&2
    echo "       Free RAM: ${free_ram_mb}MB (min required: ${MIN_SAFE_FREE_RAM_MB}MB)" >&2
    echo "       Swap in use: ${swap_used_mb}MB" >&2
    echo "       Try again later when the system is less loaded." >&2
    exit 1
  fi
}

#######################################
# Swap operations
#######################################

create_new_swapfile() {
  local target_mb="$1"
  local new_swap="${SWAPFILE}.new"

  log "Creating new swapfile at ${new_swap} (${target_mb}MB)..."

  if [[ -e "$new_swap" && "$DRY_RUN" -eq 0 ]]; then
    echo "ERROR: Temporary swapfile ${new_swap} already exists. Remove it first." >&2
    exit 1
  fi

  # Use fallocate if available, fallback to dd
  if command -v fallocate >/dev/null 2>&1; then
    run fallocate -l "${target_mb}M" "$new_swap"
  else
    run dd if=/dev/zero of="$new_swap" bs=1M count="$target_mb" status=progress
  fi

  run chmod 600 "$new_swap"
  run mkswap "$new_swap"

  echo "$new_swap"
}

activate_swapfile() {
  local file="$1"
  log "Activating new swap: $file"
  run swapon "$file"
}

disable_and_remove_old_swapfile() {
  local old="$1"

  if [[ -z "$old" ]]; then
    log "No existing swapfile to disable."
    return
  fi

  if [[ ! -e "$old" ]]; then
    log "Existing swapfile $old not found on disk; skipping removal."
    return
  fi

  log "Disabling old swapfile: $old"
  run swapoff "$old"

  if [[ -f "$old" ]]; then
    log "Removing old swapfile: $old"
    run rm -f "$old"
  else
    log "Note: $old is not a regular file, skipping rm."
  fi
}

finalize_new_swapfile() {
  local new="$1"

  log "Renaming $new to $SWAPFILE"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] mv $new $SWAPFILE"
  else
    mv "$new" "$SWAPFILE"
  fi

  log "Updating /etc/fstab entry for $SWAPFILE"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] sed -i '/swapfile/d' /etc/fstab"
    echo "[DRY-RUN] echo '$SWAPFILE none swap sw 0 0' >> /etc/fstab"
  else
    sed -i '/swapfile/d' /etc/fstab || true
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
  fi
}

#######################################
# Optional system setup
#######################################

setup_system() {
  log ""
  log "===== SYSTEM SETUP (timezone + apt + nano + vnstat) ====="
  log "Setting timezone: $TIMEZONE"

  run timedatectl set-timezone "$TIMEZONE"

  log "Running apt update..."
  run apt update -y

  log "Installing nano and vnstat..."
  run apt install -y nano vnstat

  log ""
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] System setup summary would be shown here."
  else
    echo "===== SYSTEM SETUP COMPLETE ====="
    echo "Timezone: $(timedatectl show -p Timezone --value)"
    echo "Nano: $(nano --version | head -n1)"
    echo "vnStat: $(vnstat --version | head -n1)"
    echo "================================="
  fi
}

#######################################
# Main logic
#######################################

main() {
  require_root

  local ram_mb current_swap_mb target_swap_mb new_swapfile old_swapfile
  ram_mb=$(get_ram_mb)
  current_swap_mb=$(get_swap_total_mb)

  log "=== Safe Swap Manager ==="
  log "Detected RAM: ${ram_mb}MB"
  log "Current total swap: ${current_swap_mb}MB"
  log "Mode: $MODE"
  [[ "$DRY_RUN" -eq 1 ]] && log "DRY-RUN: no changes will be made."

  # Determine target swap size
  case "$MODE" in
    auto)
      target_swap_mb=$(recommended_swap_mb)
      if [[ "$target_swap_mb" -eq 0 ]]; then
        log "RAM > 4GB and auto mode selected: no swap recommended. Nothing to do."
        target_swap_mb=0
      fi
      ;;
    set)
      target_swap_mb="$SIZE_MB"
      ;;
    increase)
      if [[ "$current_swap_mb" -eq 0 ]]; then
        log "No existing swap; 'increase' will act like 'set' to ${DELTA_MB}MB."
        target_swap_mb="$DELTA_MB"
      else
        target_swap_mb=$(( current_swap_mb + DELTA_MB ))
      fi
      ;;
    decrease)
      if [[ "$current_swap_mb" -eq 0 ]]; then
        echo "ERROR: No existing swap to decrease." >&2
        exit 1
      fi
      if (( current_swap_mb <= DELTA_MB )); then
        echo "ERROR: Cannot decrease swap below 0MB." >&2
        exit 1
      fi
      target_swap_mb=$(( current_swap_mb - DELTA_MB ))
      ;;
  esac

  if [[ "$target_swap_mb" -le 0 ]]; then
    log "Target swap size is 0MB. No swap changes will be applied."
  else
    log "Target swap size: ${target_swap_mb}MB"

    # Determine existing swapfile (first regular file, if any)
    old_swapfile=""
    mapfile -t existing_files < <(get_existing_swap_files)
    if [[ "${#existing_files[@]}" -gt 0 ]]; then
      old_swapfile="${existing_files[0]}"
      log "Existing swapfile detected: $old_swapfile"
    else
      log "No existing swapfile detected. A new one will be created."
    fi

    # Safety check before touching swap
    memory_safety_check

    # Create new swapfile, enable, disable old, finalize
    new_swapfile=$(create_new_swapfile "$target_swap_mb")
    activate_swapfile "$new_swapfile"
    disable_and_remove_old_swapfile "$old_swapfile"
    finalize_new_swapfile "$new_swapfile"

    log ""
    log "Final swap status:"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] free -h"
      echo "[DRY-RUN] swapon --show"
    else
      free -h
      swapon --show
    fi
  fi

  if [[ "$RUN_SETUP_SYSTEM" -eq 1 ]]; then
    setup_system
  fi

  log "=== Done. ==="
}

main "$@"

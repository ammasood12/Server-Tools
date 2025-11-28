#!/usr/bin/env bash
#
# Server Setup Essentials
# - Interactive menu
# - Safe swap management (auto / set / increase / decrease)
# - Timezone configuration (menu + custom)
# - Software installation (multi-select via comma-separated choices)
# - Proxy tools menu (includes V2bX installer - wyx2685)
# - Default setup: auto swap + base software + timezone (with confirmation)
#
# Recommended for fresh Debian/Ubuntu servers.

set -euo pipefail

#######################################
# Colors
#######################################
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

#######################################
# Global config
#######################################
SWAPFILE="/swapfile"
MIN_SAFE_FREE_RAM_MB=200
DEFAULT_TIMEZONE="Asia/Shanghai"

#######################################
# Helpers
#######################################
require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}ERROR:${RESET} Please run as root (or with sudo)." >&2
    exit 1
  fi
}

log_info()  { echo -e "${CYAN}[INFO]${RESET} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${RESET}   $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*"; }

pause() {
  echo
  read -rp "Press Enter to continue..." _
}

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
    echo 2048      # <=1GB RAM -> 2GB swap
  elif [[ "$ram_mb" -le 2048 ]]; then
    echo 2048      # <=2GB RAM -> 2GB swap
  elif [[ "$ram_mb" -le 4096 ]]; then
    echo 1024      # <=4GB RAM -> 1GB swap
  else
    echo 0         # >4GB RAM -> usually no swap needed
  fi
}

get_existing_swap_files() {
  swapon --show=NAME --noheadings 2>/dev/null | while read -r dev; do
    [[ -f "$dev" ]] && echo "$dev"
  done
}

#######################################
# Memory safety check
#######################################
memory_safety_check() {
  local free_ram_mb swap_used_mb
  free_ram_mb=$(get_free_ram_mb)
  swap_used_mb=$(get_swap_used_mb)

  log_info "Current free RAM: ${free_ram_mb}MB"
  log_info "Current swap used: ${swap_used_mb}MB"

  if [[ "$free_ram_mb" -lt "$MIN_SAFE_FREE_RAM_MB" && "$swap_used_mb" -gt 0 ]]; then
    log_error "Memory too full to safely adjust swap right now."
    echo "  Free RAM: ${free_ram_mb}MB (min required: ${MIN_SAFE_FREE_RAM_MB}MB)"
    echo "  Swap in use: ${swap_used_mb}MB"
    echo "Try again later when the system is less loaded."
    return 1
  fi
  return 0
}

#######################################
# Swap operations
#######################################
create_new_swapfile() {
  local target_mb="$1"
  local new_swap="${SWAPFILE}.new"

  log_info "Creating new swapfile at ${new_swap} (${target_mb}MB)..."

  if [[ -e "$new_swap" ]]; then
    log_error "Temporary swapfile ${new_swap} already exists. Remove it first."
    return 1
  fi

  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${target_mb}M" "$new_swap"
  else
    dd if=/dev/zero of="$new_swap" bs=1M count="$target_mb" status=progress
  fi

  chmod 600 "$new_swap"
  mkswap "$new_swap" >/dev/null
  echo "$new_swap"
}

activate_swapfile() {
  local file="$1"
  log_info "Activating new swap: $file"
  swapon "$file"
}

disable_and_remove_old_swapfile() {
  local old="$1"

  if [[ -z "$old" ]]; then
    log_info "No existing swapfile to disable."
    return 0
  fi

  if [[ ! -e "$old" ]]; then
    log_warn "Existing swapfile $old not found on disk; skipping removal."
    return 0
  fi

  log_info "Disabling old swapfile: $old"
  swapoff "$old"

  if [[ -f "$old" ]]; then
    log_info "Removing old swapfile: $old"
    rm -f "$old"
  else
    log_warn "$old is not a regular file, skipping rm."
  fi
}

finalize_new_swapfile() {
  local new="$1"

  log_info "Renaming $new to $SWAPFILE"
  mv "$new" "$SWAPFILE"

  log_info "Updating /etc/fstab entry for $SWAPFILE"
  sed -i '/swapfile/d' /etc/fstab || true
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
}

apply_swap_change() {
  local target_mb="$1"

  local current_swap_mb
  current_swap_mb=$(get_swap_total_mb)

  if [[ "$target_mb" -eq "$current_swap_mb" ]]; then
    log_info "Current swap (${current_swap_mb}MB) already matches target. Nothing to do."
    return 0
  fi

  echo
  echo -e "${BOLD}${CYAN}Swap Change Plan:${RESET}"
  echo "  Current swap: ${current_swap_mb}MB"
  echo "  Target swap : ${target_mb}MB"
  echo

  read -rp "Apply this swap change? (y/N): " ans
  case "$ans" in
    y|Y) ;;
    *) log_warn "Swap change cancelled."; return 1 ;;
  esac

  if ! memory_safety_check; then
    return 1
  fi

  local new_swapfile old_swapfile
  new_swapfile=$(create_new_swapfile "$target_mb") || return 1

  activate_swapfile "$new_swapfile"

  mapfile -t existing_files < <(get_existing_swap_files)
  old_swapfile=""
  if [[ "${#existing_files[@]}" -gt 0 ]]; then
    # new swap also appears here, we want to disable old one(s)
    for f in "${existing_files[@]}"; do
      if [[ "$f" != "$new_swapfile" ]]; then
        old_swapfile="$f"
        break
      fi
    done
  fi

  disable_and_remove_old_swapfile "$old_swapfile"
  finalize_new_swapfile "$new_swapfile"

  log_ok "Swap updated successfully."
  echo
  free -h
  echo
  swapon --show
}

#######################################
# Swap management menu
#######################################
swap_management_menu() {
  while true; do
    clear
    echo -e "${BOLD}${MAGENTA}=== Swap Management ===${RESET}"
    echo
    local ram_mb swap_mb
    ram_mb=$(get_ram_mb)
    swap_mb=$(get_swap_total_mb)
    echo -e "Detected RAM  : ${CYAN}${ram_mb}MB${RESET}"
    echo -e "Current Swap  : ${CYAN}${swap_mb}MB${RESET}"
    echo
    echo "1) Auto configure swap (recommended)"
    echo "2) Set exact swap size (MB)"
    echo "3) Increase swap by MB"
    echo "4) Decrease swap by MB"
    echo "5) Show memory & swap status"
    echo "6) Back to main menu"
    echo
    read -rp "Choose an option [1-6]: " choice

    case "$choice" in
      1)
        local target
        target=$(recommended_swap_mb)
        if [[ "$target" -le 0 ]]; then
          log_warn "RAM > 4GB. Auto mode does not recommend swap by default."
          pause
        else
          apply_swap_change "$target" || true
          pause
        fi
        ;;
      2)
        read -rp "Enter desired swap size in MB (e.g., 2048): " size_mb
        if [[ -n "${size_mb//[0-9]/}" || -z "$size_mb" ]]; then
          log_error "Invalid size."
        else
          apply_swap_change "$size_mb" || true
        fi
        pause
        ;;
      3)
        local inc current target
        current=$(get_swap_total_mb)
        read -rp "Increase swap by how many MB? (e.g., 512): " inc
        if [[ -n "${inc//[0-9]/}" || -z "$inc" ]]; then
          log_error "Invalid value."
        else
          target=$(( current + inc ))
          apply_swap_change "$target" || true
        fi
        pause
        ;;
      4)
        local dec current target
        current=$(get_swap_total_mb)
        if [[ "$current" -eq 0 ]]; then
          log_warn "No swap configured currently."
          pause
        else
          read -rp "Decrease swap by how many MB? (e.g., 512): " dec
          if [[ -n "${dec//[0-9]/}" || -z "$dec" ]]; then
            log_error "Invalid value."
          elif (( dec >= current )); then
            log_error "Cannot decrease swap below 0."
          else
            target=$(( current - dec ))
            apply_swap_change "$target" || true
          fi
          pause
        fi
        ;;
      5)
        echo
        free -h
        echo
        swapon --show || true
        pause
        ;;
      6)
        return
        ;;
      *)
        log_warn "Invalid choice."
        pause
        ;;
    esac
  done
}

#######################################
# Timezone configuration
#######################################
choose_timezone() {
  clear
  echo -e "${BOLD}${MAGENTA}=== Timezone Configuration ===${RESET}"
  echo
  echo "Select a timezone:"
  echo "1) Asia/Shanghai"
  echo "2) Asia/Tokyo"
  echo "3) Asia/Hong_Kong"
  echo "4) Asia/Singapore"
  echo "5) UTC"
  echo "6) Custom (manual input)"
  echo "7) Cancel"
  echo
  read -rp "Choose an option [1-7]: " tz_choice

  local tz=""
  case "$tz_choice" in
    1) tz="Asia/Shanghai" ;;
    2) tz="Asia/Tokyo" ;;
    3) tz="Asia/Hong_Kong" ;;
    4) tz="Asia/Singapore" ;;
    5) tz="UTC" ;;
    6)
      read -rp "Enter full timezone string (e.g., Asia/Shanghai): " tz
      ;;
    7)
      log_warn "Timezone change cancelled."
      pause
      return
      ;;
    *)
      log_warn "Invalid choice."
      pause
      return
      ;;
  esac

  if [[ -z "$tz" ]]; then
    log_warn "No timezone selected."
    pause
    return
  fi

  echo
  echo "You selected timezone: $tz"
  read -rp "Apply this timezone? (y/N): " ans
  case "$ans" in
    y|Y)
      if timedatectl set-timezone "$tz"; then
        log_ok "Timezone set to $(timedatectl show -p Timezone --value)"
      else
        log_error "Failed to set timezone. Make sure it's valid."
      fi
      ;;
    *)
      log_warn "Timezone change cancelled."
      ;;
  esac
  pause
}

#######################################
# Software installation
#######################################
apt_install_packages() {
  local pkgs=("$@")
  if [[ "${#pkgs[@]}" -eq 0 ]]; then
    log_warn "No packages to install."
    return
  fi

  log_info "Running apt update..."
  apt update -y

  log_info "Installing: ${pkgs[*]}"
  apt install -y "${pkgs[@]}"

  log_ok "Package installation complete."
}

install_softwares_menu() {
  while true; do
    clear
    echo -e "${BOLD}${MAGENTA}=== Install Common Software ===${RESET}"
    echo
    echo "Select software to install (comma separated):"
    echo " 1) nano"
    echo " 2) vnstat"
    echo " 3) curl"
    echo " 4) wget"
    echo " 5) htop"
    echo " 6) git"
    echo " 7) unzip"
    echo " 8) screen"
    echo " 9) none / back"
    echo
    read -rp "Your choice (e.g., 1,2,5): " selection

    if [[ -z "$selection" || "$selection" == "9" ]]; then
      log_warn "No software selected."
      pause
      return
    fi

    IFS=',' read -ra choices <<< "$selection"
    declare -a pkgs=()

    for c in "${choices[@]}"; do
      c="${c//[[:space:]]/}" # trim spaces
      case "$c" in
        1) pkgs+=("nano") ;;
        2) pkgs+=("vnstat") ;;
        3) pkgs+=("curl") ;;
        4) pkgs+=("wget") ;;
        5) pkgs+=("htop") ;;
        6) pkgs+=("git") ;;
        7) pkgs+=("unzip") ;;
        8) pkgs+=("screen") ;;
        9) ;; # none/back
        *) log_warn "Unknown option: $c" ;;
      esac
    done

    # Remove duplicates
    if [[ "${#pkgs[@]}" -eq 0 ]]; then
      log_warn "No valid packages selected."
      pause
      return
    fi

    echo
    echo -e "${BOLD}Packages to install:${RESET} ${pkgs[*]}"
    read -rp "Proceed with installation? (y/N): " ans
    case "$ans" in
      y|Y)
        apt_install_packages "${pkgs[@]}"
        ;;
      *)
        log_warn "Installation cancelled."
        ;;
    esac
    pause
    return
  done
}

#######################################
# Proxy tools menu (V2bX etc.)
#######################################
install_v2bx() {
  echo
  log_info "This will install V2bX (wyx2685 script)."
  echo "Command used:"
  echo "  wget -N https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh && bash install.sh"
  echo
  read -rp "Proceed with V2bX installation? (y/N): " ans
  case "$ans" in
    y|Y)
      wget -N https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh
      bash install.sh
      log_ok "V2bX installation script executed."
      ;;
    *)
      log_warn "V2bX installation cancelled."
      ;;
  esac
  pause
}

proxy_tools_menu() {
  while true; do
    clear
    echo -e "${BOLD}${MAGENTA}=== Proxy Tools ===${RESET}"
    echo
    echo "1) Install V2bX (wyx2685)"
    echo "2) Back to main menu"
    echo
    read -rp "Choose an option [1-2]: " choice

    case "$choice" in
      1) install_v2bx ;;
      2) return ;;
      *) log_warn "Invalid choice."; pause ;;
    esac
  done
}

#######################################
# Default setup: auto swap + base software + timezone
#######################################
default_setup() {
  clear
  echo -e "${BOLD}${MAGENTA}=== Default Setup ===${RESET}"
  echo
  local ram_mb rec_swap
  ram_mb=$(get_ram_mb)
  rec_swap=$(recommended_swap_mb)

  if [[ "$rec_swap" -le 0 ]]; then
    rec_swap=0
  fi

  # Base software list
  local base_pkgs=("nano" "vnstat" "curl" "wget" "htop")

  echo -e "${BOLD}Plan:${RESET}"
  echo -e "  RAM detected       : ${CYAN}${ram_mb}MB${RESET}"
  echo -e "  Swap configuration : ${CYAN}$([[ "$rec_swap" -gt 0 ]] && echo \"Auto -> ${rec_swap}MB\" || echo \"No change (RAM > 4GB)\")${RESET}"
  echo -e "  Timezone           : will ask you to choose (default suggestion: ${DEFAULT_TIMEZONE})"
  echo -e "  Base software      : ${CYAN}${base_pkgs[*]}${RESET}"
  echo
  read -rp "Apply this default setup? (y/N): " ans
  case "$ans" in
    y|Y) ;;
    *) log_warn "Default setup cancelled."; pause; return ;;
  esac

  # Swap
  if [[ "$rec_swap" -gt 0 ]]; then
    if ! memory_safety_check; then
      log_warn "Skipping swap change due to safety check failure."
    else
      apply_swap_change "$rec_swap" || log_warn "Swap change failed or cancelled."
    fi
  else
    log_info "Skipping swap configuration (RAM > 4GB)."
  fi

  # Timezone
  choose_timezone

  # Software
  apt_install_packages "${base_pkgs[@]}"

  log_ok "Default setup completed."
  pause
}

#######################################
# Main menu
#######################################
main_menu() {
  while true; do
    clear
    echo -e "${BOLD}${BLUE}=====================================${RESET}"
    echo -e "${BOLD}${BLUE}       Server Setup Essentials       ${RESET}"
    echo -e "${BOLD}${BLUE}=====================================${RESET}"
    echo
    echo "1) Swap Management"
    echo "2) Install Common Software"
    echo "3) Configure Timezone"
    echo "4) Install Proxy Tools (V2bX etc.)"
    echo "5) Default Setup (auto swap + base tools + timezone)"
    echo "6) Exit"
    echo
    read -rp "Choose an option [1-6]: " choice

    case "$choice" in
      1) swap_management_menu ;;
      2) install_softwares_menu ;;
      3) choose_timezone ;;
      4) proxy_tools_menu ;;
      5) default_setup ;;
      6)
        echo
        log_ok "Goodbye."
        exit 0
        ;;
      *)
        log_warn "Invalid choice."
        pause
        ;;
    esac
  done
}

#######################################
# Entry point
#######################################
require_root
main_menu

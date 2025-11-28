#!/usr/bin/env bash
#
# Server Setup Essentials
# - Interactive menu
# - Safe swap management with auto temporary swap safety mode
# - Timezone configuration (menu + default Asia/Shanghai in Default Setup)
# - Software installation (multi-select)
# - Proxy tools menu (V2bX installer)
# - Default Setup: auto swap + base tools + timezone (no prompts)

VERSION="v2.1.0"
set -euo pipefail

#######################################
# Colors and Styles
#######################################
readonly RED="\e[31m"
readonly GREEN="\e[32m"
readonly YELLOW="\e[33m"
readonly BLUE="\e[34m"
readonly MAGENTA="\e[35m"
readonly CYAN="\e[36m"
readonly BOLD="\e[1m"
readonly DIM="\e[2m"
readonly RESET="\e[0m"

#######################################
# Global Configuration
#######################################
readonly SWAPFILE="/swapfile"
readonly MIN_SAFE_FREE_RAM_MB=200
readonly DEFAULT_TIMEZONE="Asia/Shanghai"
readonly TEMP_SWAP_PATH="/tmp/server_setup_essentials_temp_swap"
readonly BASE_PACKAGES=("nano" "vnstat" "curl" "wget" "htop" "git" "unzip" "screen")

TEMP_SWAP_ACTIVE=0

#######################################
# Helper Functions
#######################################
require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}╭─────────────────────────────────────────╮${RESET}"
        echo -e "${RED}│            ${BOLD}PERMISSION ERROR${RESET}${RED}             │${RESET}"
        echo -e "${RED}╰─────────────────────────────────────────╯${RESET}"
        echo -e "${RED}Please run this script as root or with sudo.${RESET}"
        echo
        exit 1
    fi
}

log_info()  { echo -e "${CYAN}${BOLD}[ℹ]${RESET} ${CYAN}$*${RESET}"; }
log_ok()    { echo -e "${GREEN}${BOLD}[✓]${RESET} ${GREEN}$*${RESET}"; }
log_warn()  { echo -e "${YELLOW}${BOLD}[!]${RESET} ${YELLOW}$*${RESET}"; }
log_error() { echo -e "${RED}${BOLD}[✗]${RESET} ${RED}$*${RESET}"; }

pause() {
    echo
    read -rp "$(echo -e "${DIM}Press ${BOLD}Enter${RESET}${DIM} to continue...${RESET}")" _
    echo
}

print_separator() {
    echo -e "${DIM}─────────────────────────────────────────────────────${RESET}"
}

banner() {
    clear
    echo -e "${BOLD}${BLUE}╔═════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${BLUE}║    🚀 Server Setup Essentials ${VERSION}    ║${RESET}"
    echo -e "${BOLD}${BLUE}╚═════════════════════════════════════════════════╝${RESET}"
    echo
}

section_title() {
    echo
    echo -e "${BOLD}${MAGENTA}🛠  $*${RESET}"
    print_separator
}

#######################################
# System Information Functions
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

    if [[ "$ram_mb" -le 1024 ]]; then
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

display_system_info() {
    local ram_mb swap_mb free_ram_mb
    ram_mb=$(get_ram_mb)
    swap_mb=$(get_swap_total_mb)
    free_ram_mb=$(get_free_ram_mb)
    
    echo -e "${BOLD}${CYAN}📊 System Overview:${RESET}"
    echo -e "  ${DIM}•${RESET} RAM Total    : ${CYAN}${ram_mb} MB${RESET}"
    echo -e "  ${DIM}•${RESET} RAM Free     : ${CYAN}${free_ram_mb} MB${RESET}"
    echo -e "  ${DIM}•${RESET} Swap Total   : ${CYAN}${swap_mb} MB${RESET}"
    echo -e "  ${DIM}•${RESET} Timezone    : ${CYAN}$(timedatectl show -p Timezone --value 2>/dev/null || echo "Unknown")${RESET}"
    print_separator
}

#######################################
# Memory Safety & Temporary Swap
#######################################
memory_safety_check() {
    local free_ram_mb swap_used_mb
    free_ram_mb=$(get_free_ram_mb)
    swap_used_mb=$(get_swap_used_mb)

    log_info "Current free RAM: ${free_ram_mb}MB"
    log_info "Current swap used: ${swap_used_mb}MB"

    if [[ "$free_ram_mb" -lt "$MIN_SAFE_FREE_RAM_MB" && "$swap_used_mb" -gt 0 ]]; then
        return 1
    fi
    return 0
}

enable_temp_swap() {
    if [[ "$TEMP_SWAP_ACTIVE" -eq 1 ]]; then
        return 0
    fi

    log_warn "Free RAM is low. Enabling temporary safety swap (${CYAN}1024MB${RESET})..."
    
    if [[ -e "$TEMP_SWAP_PATH" ]]; then
        log_warn "Temporary swap file already exists, trying to use it."
    else
        if command -v fallocate >/dev/null 2>&1; then
            if ! fallocate -l 1024M "$TEMP_SWAP_PATH"; then
                log_error "Failed to create temporary swap file using fallocate."
                return 1
            fi
        else
            if ! dd if=/dev/zero of="$TEMP_SWAP_PATH" bs=1M count=1024 status=none; then
                log_error "Failed to create temporary swap file using dd."
                return 1
            fi
        fi
        
        chmod 600 "$TEMP_SWAP_PATH" || true
        
        if ! mkswap "$TEMP_SWAP_PATH" >/dev/null; then
            log_error "Failed to format temporary swap."
            rm -f "$TEMP_SWAP_PATH" || true
            return 1
        fi
    fi

    if swapon "$TEMP_SWAP_PATH" 2>/dev/null; then
        TEMP_SWAP_ACTIVE=1
        log_ok "Temporary swap enabled at $TEMP_SWAP_PATH."
        return 0
    else
        log_error "Failed to enable temporary swap."
        return 1
    fi
}

disable_temp_swap() {
    if [[ "$TEMP_SWAP_ACTIVE" -eq 1 ]]; then
        log_info "Disabling temporary safety swap..."
        swapoff "$TEMP_SWAP_PATH" 2>/dev/null || true
        rm -f "$TEMP_SWAP_PATH" 2>/dev/null || true
        TEMP_SWAP_ACTIVE=0
        log_ok "Temporary safety swap removed."
    fi
}

#######################################
# Swap Operations (Corrected & Safe)
#######################################
create_new_swapfile() {
    local target_mb="$1"
    local new_swap="${SWAPFILE}.new"

    log_info "Creating new swapfile: ${new_swap} (${target_mb}MB)"
    
    # Remove any previous file
    rm -f "$new_swap" 2>/dev/null || true

    # Create file
    if command -v fallocate >/dev/null 2>&1; then
        if ! fallocate -l "${target_mb}M" "$new_swap"; then
            log_error "Failed to allocate swapfile using fallocate."
            return 1
        fi
    else
        if ! dd if=/dev/zero of="$new_swap" bs=1M count="$target_mb" status=none; then
            log_error "Failed to create swapfile using dd."
            return 1
        fi
    fi

    chmod 600 "$new_swap" || return 1

    if ! mkswap "$new_swap" >/dev/null 2>&1; then
        log_error "mkswap failed for the new swapfile."
        return 1
    fi

    echo "$new_swap"
}

activate_swapfile() {
    local newswap="$1"

    if [[ ! -f "$newswap" ]]; then
        log_error "New swapfile missing: $newswap"
        return 1
    fi

    log_info "Activating new swap: $newswap"
    if ! swapon "$newswap" 2>/dev/null; then
        log_error "swapon failed for $newswap"
        return 1
    fi

    return 0
}

disable_and_remove_old_swapfile() {
    local old="$1"

    if [[ -z "$old" ]]; then
        log_info "No old swapfile to disable."
        return 0
    fi

    log_info "Disabling old swapfile: $old"
    swapoff "$old" 2>/dev/null || log_warn "swapoff failed (may not be active)."

    if [[ -f "$old" ]]; then
        log_info "Removing old swapfile"
        rm -f "$old" 2>/dev/null || log_warn "Failed to remove old swapfile."
    fi

    return 0
}

finalize_new_swapfile() {
    local newswap="$1"

    log_info "Finalizing new swapfile configuration"
    mv "$newswap" "$SWAPFILE"

    log_info "Updating /etc/fstab"
    sed -i '/swapfile/d' /etc/fstab || true
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab

    return 0
}

apply_swap_change() {
    local target_mb="$1"
    local current_swap_mb
    current_swap_mb=$(get_swap_total_mb)

    [[ "$target_mb" -eq "$current_swap_mb" ]] && {
        log_info "Swap already ${current_swap_mb}MB → No change needed"
        return 0
    }

    section_title "Swap Change Plan"
    echo -e "  ${DIM}•${RESET} Current swap : ${CYAN}${current_swap_mb}MB${RESET}"
    echo -e "  ${DIM}•${RESET} Target swap  : ${CYAN}${target_mb}MB${RESET}"
    echo

    # If not in auto mode, ask for confirmation
    if [[ "${2:-}" != "AUTO" ]]; then
        read -rp "$(echo -e "${YELLOW}Apply this swap change? ${BOLD}(y/N):${RESET} ")" ans
        if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
            log_warn "Swap change cancelled."
            return 0
        fi
    fi

    # Safety check
    if ! memory_safety_check; then
        log_warn "Memory low → enabling temporary safety swap..."
        if ! enable_temp_swap; then
            log_error "Failed to enable temporary swap → aborting swap change"
            return 1
        fi
    fi

    # Create new swapfile
    local new_swapfile
    new_swapfile=$(create_new_swapfile "$target_mb")
    if [[ -z "$new_swapfile" || ! -f "$new_swapfile" ]]; then
        log_error "Swapfile creation failed."
        disable_temp_swap
        return 1
    fi

    # Activate new swapfile
    if ! activate_swapfile "$new_swapfile"; then
        log_error "Failed to activate new swap."
        rm -f "$new_swapfile" || true
        disable_temp_swap
        return 1
    fi

    # Find old swapfile (excluding new + temp)
    local old_swapfile=""
    mapfile -t existing_files < <(get_existing_swap_files)
    for f in "${existing_files[@]}"; do
        if [[ "$f" != "$new_swapfile" && "$f" != "$TEMP_SWAP_PATH" ]]; then
            old_swapfile="$f"
            break
        fi
    done

    # Disable & remove old swapfile
    disable_and_remove_old_swapfile "$old_swapfile"

    # Finalize new swap
    finalize_new_swapfile "$new_swapfile"

    # Remove temporary safety swap if active
    disable_temp_swap

    log_ok "Swap update completed successfully."
    echo
    echo -e "${BOLD}${GREEN}📈 Final Memory Status:${RESET}"
    free -h
    echo
    swapon --show || true
}

#######################################
# Swap Management Menu
#######################################
swap_management_menu() {
    while true; do
        banner
        section_title "Swap Management"
        
        display_system_info

        echo -e "${BOLD}${CYAN}🔧 Swap Operations:${RESET}"
        echo "1) Auto configure swap (recommended)"
        echo "2) Set exact swap size (MB)"
        echo "3) Increase swap by MB"
        echo "4) Decrease swap by MB"
        echo "5) Show memory & swap status"
        echo "6) Back to main menu"
        echo
        read -rp "$(echo -e "${BOLD}Choose an option [1-6]: ${RESET}")" choice

        case "$choice" in
            1)
                local rec
                rec=$(recommended_swap_mb)
                if [[ "$rec" -le 0 ]]; then
                    log_warn "RAM > 4GB. Auto mode does not recommend swap by default."
                else
                    apply_swap_change "$rec"
                fi
                pause
                ;;
            2)
                read -rp "$(echo -e "${BOLD}Enter desired swap size in MB (e.g., 2048): ${RESET}")" size_mb
                if [[ -n "${size_mb//[0-9]/}" || -z "$size_mb" ]]; then
                    log_error "Invalid size. Please enter a positive number."
                else
                    apply_swap_change "$size_mb"
                fi
                pause
                ;;
            3)
                local current inc target
                current=$(get_swap_total_mb)
                read -rp "$(echo -e "${BOLD}Increase swap by how many MB? (e.g., 512): ${RESET}")" inc
                if [[ -n "${inc//[0-9]/}" || -z "$inc" ]]; then
                    log_error "Invalid value. Please enter a positive number."
                else
                    target=$(( current + inc ))
                    apply_swap_change "$target"
                fi
                pause
                ;;
            4)
                local current dec target
                current=$(get_swap_total_mb)
                if [[ "$current" -eq 0 ]]; then
                    log_warn "No swap configured currently."
                    pause
                else
                    read -rp "$(echo -e "${BOLD}Decrease swap by how many MB? (e.g., 512): ${RESET}")" dec
                    if [[ -n "${dec//[0-9]/}" || -z "$dec" ]]; then
                        log_error "Invalid value. Please enter a positive number."
                    elif (( dec >= current )); then
                        log_error "Cannot decrease swap below 0."
                    else
                        target=$(( current - dec ))
                        apply_swap_change "$target"
                    fi
                    pause
                fi
                ;;
            5)
                echo
                echo -e "${BOLD}${GREEN}📊 Current Memory Status:${RESET}"
                free -h
                echo
                echo -e "${BOLD}${GREEN}💾 Active Swap Files:${RESET}"
                swapon --show || echo "No active swap files"
                pause
                ;;
            6)
                return
                ;;
            *)
                log_warn "Invalid choice. Please select 1-6."
                pause
                ;;
        esac
    done
}

#######################################
# Timezone Configuration Menu
#######################################
choose_timezone() {
    while true; do
        banner
        section_title "Timezone Configuration"

        echo -e "Current timezone: ${CYAN}$(timedatectl show -p Timezone --value)${RESET}"
        echo
        echo -e "${BOLD}Select a timezone:${RESET}"
        echo "1) Asia/Shanghai"
        echo "2) Asia/Tokyo"
        echo "3) Asia/Hong_Kong"
        echo "4) Asia/Singapore"
        echo "5) UTC"
        echo "6) Custom (manual input)"
        echo "7) Back"
        echo
        read -rp "$(echo -e "${BOLD}Choose an option [1-7]: ${RESET}")" tz_choice

        local tz=""
        case "$tz_choice" in
            1) tz="Asia/Shanghai" ;;
            2) tz="Asia/Tokyo" ;;
            3) tz="Asia/Hong_Kong" ;;
            4) tz="Asia/Singapore" ;;
            5) tz="UTC" ;;
            6)
                read -rp "$(echo -e "${BOLD}Enter full timezone string (e.g., Asia/Shanghai): ${RESET}")" tz
                ;;
            7)
                log_warn "Timezone change cancelled."
                pause
                return
                ;;
            *)
                log_warn "Invalid choice. Please select 1-7."
                pause
                continue
                ;;
        esac

        if [[ -z "$tz" ]]; then
            log_warn "No timezone selected."
            pause
            continue
        fi

        echo
        echo -e "You selected timezone: ${CYAN}${tz}${RESET}"
        read -rp "$(echo -e "${YELLOW}Apply this timezone? ${BOLD}(y/N):${RESET} ")" ans
        case "$ans" in
            y|Y)
                if timedatectl set-timezone "$tz"; then
                    log_ok "Timezone successfully set to: $(timedatectl show -p Timezone --value)"
                else
                    log_error "Failed to set timezone. Please make sure '$tz' is a valid timezone."
                fi
                ;;
            *)
                log_warn "Timezone change cancelled."
                ;;
        esac
        pause
        return
    done
}

#######################################
# Software Installation
#######################################
apt_install_packages() {
    local pkgs=("$@")
    if [[ "${#pkgs[@]}" -eq 0 ]]; then
        log_warn "No packages to install."
        return
    fi

    log_info "Updating package lists..."
    if ! apt update -y; then
        log_error "Failed to update package lists."
        return 1
    fi

    log_info "Installing: ${pkgs[*]}"
    if ! apt install -y "${pkgs[@]}"; then
        log_error "Failed to install some packages."
        return 1
    fi

    log_ok "Package installation completed successfully."
}

install_softwares_menu() {
    while true; do
        banner
        section_title "Install Common Software"

        echo -e "${BOLD}Select software to install (comma separated):${RESET}"
        echo " 1) nano        (Text editor)"
        echo " 2) vnstat      (Network traffic monitor)"
        echo " 3) curl        (HTTP transfer tool)"
        echo " 4) wget        (Web downloader)"
        echo " 5) htop        (Process viewer)"
        echo " 6) git         (Version control)"
        echo " 7) unzip       (Archive extractor)"
        echo " 8) screen      (Terminal multiplexer)"
        echo " 9) Back to main menu"
        echo
        read -rp "$(echo -e "${BOLD}Your choice (e.g., 1,2,5): ${RESET}")" selection

        if [[ -z "$selection" || "$selection" == "9" ]]; then
            log_warn "No software selected."
            pause
            return
        fi

        IFS=',' read -ra choices <<< "$selection"
        declare -a pkgs=()

        for c in "${choices[@]}"; do
            c="${c//[[:space:]]/}"
            case "$c" in
                1) pkgs+=("nano") ;;
                2) pkgs+=("vnstat") ;;
                3) pkgs+=("curl") ;;
                4) pkgs+=("wget") ;;
                5) pkgs+=("htop") ;;
                6) pkgs+=("git") ;;
                7) pkgs+=("unzip") ;;
                8) pkgs+=("screen") ;;
                9) ;;
                *) log_warn "Unknown option: $c" ;;
            esac
        done

        if [[ "${#pkgs[@]}" -eq 0 ]]; then
            log_warn "No valid packages selected."
            pause
            return
        fi

        echo
        echo -e "${BOLD}Packages to install:${RESET} ${GREEN}${pkgs[*]}${RESET}"
        read -rp "$(echo -e "${YELLOW}Proceed with installation? ${BOLD}(y/N):${RESET} ")" ans
        case "$ans" in
            y|Y)
                if apt_install_packages "${pkgs[@]}"; then
                    log_ok "All packages installed successfully."
                else
                    log_error "Some packages failed to install."
                fi
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
# Proxy Tools Menu (V2bX etc.)
#######################################
install_v2bx() {
    banner
    section_title "Install V2bX (wyx2685)"

    echo -e "${BOLD}This will run:${RESET}"
    echo "  wget -N https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh"
    echo "  bash install.sh"
    echo
    read -rp "$(echo -e "${YELLOW}Proceed with V2bX installation? ${BOLD}(y/N):${RESET} ")" ans
    case "$ans" in
        y|Y)
            log_info "Downloading V2bX installation script..."
            if wget -N https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh; then
                log_info "Running V2bX installation script..."
                bash install.sh
                log_ok "V2bX installation script executed."
            else
                log_error "Failed to download V2bX installation script."
            fi
            ;;
        *)
            log_warn "V2bX installation cancelled."
            ;;
    esac
    pause
}

proxy_tools_menu() {
    while true; do
        banner
        section_title "Proxy Tools"

        echo "1) Install V2bX (wyx2685)"
        echo "2) Back to main menu"
        echo
        read -rp "$(echo -e "${BOLD}Choose an option [1-2]: ${RESET}")" choice

        case "$choice" in
            1) install_v2bx ;;
            2) return ;;
            *) log_warn "Invalid choice. Please select 1 or 2."; pause ;;
        esac
    done
}

#######################################
# Default Setup: Auto Configuration
#######################################
default_setup() {
    banner
    section_title "Default Setup (Automatic Configuration)"

    local ram_mb rec_swap
    ram_mb=$(get_ram_mb)
    rec_swap=$(recommended_swap_mb)

    local base_pkgs=("nano" "vnstat" "curl" "wget" "htop")

    echo -e "${BOLD}${GREEN}🚀 Automatic Setup Plan:${RESET}"
    echo -e "  ${DIM}•${RESET} RAM detected       : ${CYAN}${ram_mb} MB${RESET}"
    if [[ "$rec_swap" -gt 0 ]]; then
        echo -e "  ${DIM}•${RESET} Swap configuration : ${CYAN}Auto → ${rec_swap} MB${RESET}"
    else
        echo -e "  ${DIM}•${RESET} Swap configuration : ${CYAN}No change (RAM > 4GB)${RESET}"
    fi
    echo -e "  ${DIM}•${RESET} Timezone           : ${CYAN}${DEFAULT_TIMEZONE}${RESET}"
    echo -e "  ${DIM}•${RESET} Base software      : ${CYAN}${base_pkgs[*]}${RESET}"
    echo
    log_info "Running Default Setup without further prompts..."

    # Swap configuration
    if [[ "$rec_swap" -gt 0 ]]; then
        log_info "Configuring swap to ${rec_swap}MB..."
        apply_swap_change "$rec_swap" "AUTO"
    else
        log_info "Skipping swap configuration (RAM > 4GB)."
    fi

    # Timezone configuration
    log_info "Setting timezone to ${DEFAULT_TIMEZONE}..."
    if timedatectl set-timezone "$DEFAULT_TIMEZONE"; then
        log_ok "Timezone set to: $(timedatectl show -p Timezone --value)"
    else
        log_error "Failed to set timezone to ${DEFAULT_TIMEZONE}."
    fi

    # Base software installation
    log_info "Installing base software packages..."
    if apt_install_packages "${base_pkgs[@]}"; then
        log_ok "Base software installation completed."
    else
        log_error "Some packages failed to install."
    fi

    log_ok "Default setup completed successfully."
    pause
}

#######################################
# Main Menu
#######################################
main_menu() {
    while true; do
        banner
        echo -e "${BOLD}${BLUE}📋 Main Menu${RESET}"
        print_separator
        display_system_info
        
        echo -e "${BOLD}${CYAN}🎯 Available Operations:${RESET}"
        echo "1) Swap Management"
        echo "2) Install Common Software"
        echo "3) Configure Timezone"
        echo "4) Install Proxy Tools (V2bX etc.)"
        echo "5) Default Setup (auto swap + base tools + timezone)"
        echo "6) Exit"
        echo
        read -rp "$(echo -e "${BOLD}Choose an option [1-6]: ${RESET}")" choice

        case "$choice" in
            1) swap_management_menu ;;
            2) install_softwares_menu ;;
            3) choose_timezone ;;
            4) proxy_tools_menu ;;
            5) default_setup ;;
            6)
                echo
                log_ok "Thank you for using Server Setup Essentials. Goodbye! 👋"
                echo
                exit 0
                ;;
            *)
                log_warn "Invalid choice. Please select 1-6."
                pause
                ;;
        esac
    done
}

#######################################
# Entry Point
#######################################
main() {
    require_root
    trap disable_temp_swap EXIT
    main_menu
}

main "$@"
exit 0

#!/usr/bin/env bash
#
# Server Setup Essentials
# - Interactive menu
# - Safe swap management with auto temporary swap safety mode
# - Timezone configuration (menu + default Asia/Shanghai in Default Setup)
# - Software installation (multi-select)
# - Proxy tools menu (V2bX installer)
# - Default Setup: auto swap + base tools + timezone (no prompts)
#!/usr/bin/env bash
#
# Server Setup Essentials - Fixed Version
#

VERSION="v2.1.1"
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
        log_info "Creating temporary swap file..."
        
        # Try different methods to create swap file
        if command -v fallocate >/dev/null 2>&1; then
            log_info "Using fallocate to create swap file..."
            if ! fallocate -l 1024M "$TEMP_SWAP_PATH" 2>/dev/null; then
                log_warn "fallocate failed, trying dd method..."
                if ! dd if=/dev/zero of="$TEMP_SWAP_PATH" bs=1M count=1024 status=none 2>/dev/null; then
                    log_error "Both fallocate and dd failed to create temporary swap file."
                    return 1
                fi
            fi
        else
            log_info "Using dd to create swap file..."
            if ! dd if=/dev/zero of="$TEMP_SWAP_PATH" bs=1M count=1024 status=none 2>/dev/null; then
                log_error "dd failed to create temporary swap file."
                return 1
            fi
        fi
        
        # Set proper permissions
        if ! chmod 600 "$TEMP_SWAP_PATH"; then
            log_error "Failed to set permissions on temporary swap file."
            rm -f "$TEMP_SWAP_PATH" 2>/dev/null || true
            return 1
        fi
        
        # Format as swap
        log_info "Formatting temporary swap file..."
        if ! mkswap "$TEMP_SWAP_PATH" >/dev/null 2>&1; then
            log_error "Failed to format temporary swap file."
            rm -f "$TEMP_SWAP_PATH" 2>/dev/null || true
            return 1
        fi
    fi

    # Enable the swap
    log_info "Enabling temporary swap..."
    if swapon "$TEMP_SWAP_PATH" 2>/dev/null; then
        TEMP_SWAP_ACTIVE=1
        log_ok "Temporary swap enabled at $TEMP_SWAP_PATH (1024MB)."
        return 0
    else
        log_error "Failed to enable temporary swap."
        rm -f "$TEMP_SWAP_PATH" 2>/dev/null || true
        return 1
    fi
}

disable_temp_swap() {
    if [[ "$TEMP_SWAP_ACTIVE" -eq 1 ]]; then
        log_info "Disabling temporary safety swap..."
        if swapoff "$TEMP_SWAP_PATH" 2>/dev/null; then
            log_ok "Temporary swap disabled."
        else
            log_warn "Failed to disable temporary swap (may not be active)."
        fi
        if rm -f "$TEMP_SWAP_PATH" 2>/dev/null; then
            log_ok "Temporary swap file removed."
        else
            log_warn "Failed to remove temporary swap file."
        fi
        TEMP_SWAP_ACTIVE=0
    fi
}

#######################################
# Swap Operations (Fixed Version)
#######################################
create_new_swapfile() {
    local target_mb="$1"
    local new_swap="${SWAPFILE}.new"

    log_info "Creating new swapfile: ${new_swap} (${target_mb}MB)"
    
    # Remove any previous file
    if [[ -f "$new_swap" ]]; then
        log_info "Removing existing swap file: $new_swap"
        rm -f "$new_swap" 2>/dev/null || {
            log_error "Failed to remove existing swap file."
            return 1
        }
    fi

    # Check available disk space
    local available_mb
    available_mb=$(df -m "$(dirname "$new_swap")" | awk 'NR==2 {print $4}')
    if [[ "$available_mb" -lt "$target_mb" ]]; then
        log_error "Insufficient disk space. Available: ${available_mb}MB, Required: ${target_mb}MB"
        return 1
    fi

    log_info "Available disk space: ${available_mb}MB"

    # Create swap file with better error handling
    log_info "Creating swap file using dd (this may take a while for large sizes)..."
    
    if ! dd if=/dev/zero of="$new_swap" bs=1M count="$target_mb" status=progress 2>&1; then
        log_error "Failed to create swap file using dd."
        rm -f "$new_swap" 2>/dev/null || true
        return 1
    fi

    # Verify file was created with correct size
    local actual_size
    actual_size=$(stat -c%s "$new_swap" 2>/dev/null || stat -f%z "$new_swap" 2>/dev/null)
    local expected_size=$(( target_mb * 1024 * 1024 ))
    
    if [[ "$actual_size" -ne "$expected_size" ]]; then
        log_error "Swap file size incorrect. Expected: ${expected_size}, Got: ${actual_size}"
        rm -f "$new_swap" 2>/dev/null || true
        return 1
    fi

    # Set permissions
    if ! chmod 600 "$new_swap"; then
        log_error "Failed to set permissions on swap file."
        rm -f "$new_swap" 2>/dev/null || true
        return 1
    fi

    # Format as swap
    log_info "Formatting swap file..."
    if ! mkswap "$new_swap" >/dev/null 2>&1; then
        log_error "mkswap failed for the new swap file."
        rm -f "$new_swap" 2>/dev/null || true
        return 1
    fi

    log_ok "Swap file created successfully: $new_swap (${target_mb}MB)"
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

    log_ok "New swap activated successfully."
    return 0
}

disable_and_remove_old_swapfile() {
    local old="$1"

    if [[ -z "$old" ]]; then
        log_info "No old swapfile to disable."
        return 0
    fi

    log_info "Disabling old swapfile: $old"
    if swapoff "$old" 2>/dev/null; then
        log_ok "Old swapfile disabled."
    else
        log_warn "swapoff failed for $old (may not be active or already disabled)"
    fi

    if [[ -f "$old" ]]; then
        log_info "Removing old swapfile: $old"
        if rm -f "$old" 2>/dev/null; then
            log_ok "Old swapfile removed."
        else
            log_warn "Failed to remove old swapfile: $old"
        fi
    fi

    return 0
}

finalize_new_swapfile() {
    local newswap="$1"

    log_info "Finalizing new swapfile configuration..."
    
    # Backup existing swapfile if it exists
    if [[ -f "$SWAPFILE" ]]; then
        local backup_file="${SWAPFILE}.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Backing up existing swapfile to: $backup_file"
        mv "$SWAPFILE" "$backup_file" 2>/dev/null || true
    fi

    # Move new swapfile to final location
    if mv "$newswap" "$SWAPFILE"; then
        log_ok "New swapfile moved to final location: $SWAPFILE"
    else
        log_error "Failed to move new swapfile to final location."
        return 1
    fi

    # Update fstab
    log_info "Updating /etc/fstab..."
    if ! sed -i '/swapfile/d' /etc/fstab 2>/dev/null; then
        log_warn "Failed to remove old swap entries from fstab, continuing..."
    fi
    
    if echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab; then
        log_ok "Swap entry added to /etc/fstab"
    else
        log_error "Failed to update /etc/fstab"
        return 1
    fi

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

    # Safety check and enable temporary swap if needed
    if ! memory_safety_check; then
        log_warn "Memory low → enabling temporary safety swap..."
        if ! enable_temp_swap; then
            log_error "Failed to enable temporary swap → aborting swap change"
            return 1
        fi
    fi

    # Create new swapfile
    log_info "Starting swapfile creation process..."
    local new_swapfile
    new_swapfile=$(create_new_swapfile "$target_mb")
    if [[ -z "$new_swapfile" || ! -f "$new_swapfile" ]]; then
        log_error "Swapfile creation failed. Please check disk space and permissions."
        disable_temp_swap
        return 1
    fi

    # Activate new swapfile
    if ! activate_swapfile "$new_swapfile"; then
        log_error "Failed to activate new swap."
        rm -f "$new_swapfile" 2>/dev/null || true
        disable_temp_swap
        return 1
    fi

    # Find old swapfile (excluding new + temp)
    local old_swapfile=""
    mapfile -t existing_files < <(get_existing_swap_files)
    for f in "${existing_files[@]}"; do
        if [[ "$f" != "$new_swapfile" && "$f" != "$TEMP_SWAP_PATH" && "$f" != "$SWAPFILE" ]]; then
            old_swapfile="$f"
            break
        fi
    done

    # Disable & remove old swapfile
    disable_and_remove_old_swapfile "$old_swapfile"

    # Finalize new swap
    if ! finalize_new_swapfile "$new_swapfile"; then
        log_error "Failed to finalize new swap configuration."
        disable_temp_swap
        return 1
    fi

    # Remove temporary safety swap if active
    disable_temp_swap

    log_ok "Swap update completed successfully."
    echo
    echo -e "${BOLD}${GREEN}📈 Final Memory Status:${RESET}"
    free -h
    echo
    echo -e "${BOLD}${GREEN}💾 Active Swap Files:${RESET}"
    swapon --show || echo "No active swap files"
}

# ... (rest of the functions remain the same as in the previous improved version)
# [The rest of the functions - swap_management_menu, choose_timezone, apt_install_packages, 
# install_softwares_menu, install_v2bx, proxy_tools_menu, default_setup, main_menu - 
# remain exactly the same as in the previous improved version]

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

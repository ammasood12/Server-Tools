# !/usr/bin/env bash
#
# Server Setup Essentials - Clean Slate Version
# - Interactive menu
# - Safe swap management with auto temporary swap safety mode
# - Timezone configuration (menu + default Asia/Shanghai in Default Setup)
# - Software installation (multi-select)
# - Proxy tools menu (V2bX installer)
# - Default Setup: auto swap + base tools + timezone (no prompts)

VERSION="v2.2.1"
set -euo pipefail

#######################################
# Colors and Styles
#######################################
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

#######################################
# Configuration
#######################################
readonly SWAPFILE="/swapfile"
readonly MIN_SAFE_RAM_MB=100
readonly DEFAULT_TIMEZONE="Asia/Shanghai"
readonly BASE_PACKAGES=("curl" "wget" "nano" "htop" "vnstat" "git" "unzip" "screen")

#######################################
# Logging Functions
#######################################
log_info()  { echo -e "${CYAN}${BOLD}[INFO]${RESET} ${CYAN}$*${RESET}"; }
log_ok()    { echo -e "${GREEN}${BOLD}[OK]${RESET} ${GREEN}$*${RESET}"; }
log_warn()  { echo -e "${YELLOW}${BOLD}[WARN]${RESET} ${YELLOW}$*${RESET}"; }
log_error() { echo -e "${RED}${BOLD}[ERROR]${RESET} ${RED}$*${RESET}"; }

#######################################
# Utility Functions
#######################################
require_root() {
    [[ $EUID -eq 0 ]] || {
        log_error "This script must be run as root"
        exit 1
    }
}

pause() {
    echo
    read -rp "Press Enter to continue..." _
}

print_separator() {
    echo -e "${BLUE}─────────────────────────────────────────────────────${RESET}"
}

banner() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "╔═════════════════════════════════════════════════╗"
    echo "            🚀 Server Setup Essentials            "
    echo "                    ${VERSION}                     "
    echo "╚═════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

section_title() {
    echo
    echo -e "${BOLD}${MAGENTA}🔧 $*${RESET}"
    print_separator
}

#######################################
# System Information
#######################################
get_ram_mb() {
    grep MemTotal /proc/meminfo | awk '{printf "%.0f", $2/1024}'
}

get_swap_total_mb() {
    free -m | awk '/Swap:/ {print $2}'
}

get_swap_used_mb() {
    free -m | awk '/Swap:/ {print $3}'
}

get_free_ram_mb() {
    free -m | awk '/Mem:/ {print $4}'
}

get_disk_available_mb() {
    df -m / | awk 'NR==2 {print $4}'
}

get_active_swap_files() {
    swapon --show=NAME --noheadings 2>/dev/null | tr -d '[:space:]' || true
}

recommended_swap_mb() {
    local ram_mb=$(get_ram_mb)
    
    if [[ $ram_mb -le 1024 ]]; then
        echo 2048
    elif [[ $ram_mb -le 2048 ]]; then
        echo 2048
    elif [[ $ram_mb -le 4096 ]]; then
        echo 1024
    else
        echo 0
    fi
}

display_system_status() {
    echo -e "${BOLD}System Status:${RESET}"
    echo -e "  💻 RAM: ${CYAN}$(get_ram_mb)MB${RESET} (Free: $(get_free_ram_mb)MB)"
    echo -e "  💾 Swap: ${CYAN}$(get_swap_total_mb)MB${RESET} (Used: $(get_swap_used_mb)MB)"
    echo -e "  💿 Disk Available: ${CYAN}$(get_disk_available_mb)MB${RESET}"
    
    # Disk type detection
    local disk_type=$(lsblk -d -o ROTA 2>/dev/null | awk 'NR==2')
    if [[ "$disk_type" == "0" ]]; then
        echo -e "  🚀 Disk Type: ${CYAN}SSD${RESET}"
    elif [[ "$disk_type" == "1" ]]; then
        echo -e "  💾 Disk Type: ${CYAN}HDD${RESET}"
    else
        echo -e "  💿 Disk Type: ${CYAN}Unknown${RESET}"
    fi
    
    # CPU information
    local cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//')
    local cpu_cores=$(grep -c "^processor" /proc/cpuinfo)
    echo -e "  🔧 CPU: ${CYAN}${cpu_model}${RESET}"
    echo -e "  🎯 Cores: ${CYAN}${cpu_cores}${RESET}"
    
    # OS information
    local os_name=$(source /etc/os-release && echo "$PRETTY_NAME")
    local kernel_version=$(uname -r)
    echo -e "  🐧 OS: ${CYAN}${os_name}${RESET}"
    echo -e "  ⚙️  Kernel: ${CYAN}${kernel_version}${RESET}"
    
    # BBR information
    local bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [[ "$bbr_status" == "bbr" ]]; then
        echo -e "  🚀 BBR: ${GREEN}Enabled${RESET}"
    else
        echo -e "  🚀 BBR: ${YELLOW}Disabled${RESET}"
    fi
    
    local active_swap=$(get_active_swap_files)
    if [[ -n "$active_swap" ]]; then
        echo -e "  📋 Active Swap Files: ${CYAN}$active_swap${RESET}"
    fi
    echo
}

#######################################
# Swap Management Core
#######################################
cleanup_existing_swap() {
    log_info "Cleaning up existing swap configuration..."
    
    # Get all active swap files
    local active_swaps
    active_swaps=$(swapon --show=NAME --noheadings 2>/dev/null || true)
    
    if [[ -n "$active_swaps" ]]; then
        log_info "Disabling active swap files..."
        swapoff -a 2>/dev/null || {
            log_warn "Some swap files could not be disabled (may be in use)"
        }
    fi
    
    # Remove swap files
    local swap_files=("/swapfile" "/swapfile.new" "/swapfile2" "/tmp/temp_swap_"*)
    for file in "${swap_files[@]}"; do
        if [[ -f "$file" ]]; then
            log_info "Removing: $file"
            rm -f "$file" 2>/dev/null || log_warn "Could not remove: $file"
        fi
    done
    
    # Clean fstab
    if grep -q "swapfile" /etc/fstab 2>/dev/null; then
        log_info "Cleaning /etc/fstab..."
        sed -i '/swapfile/d' /etc/fstab 2>/dev/null || true
    fi
    
    log_ok "Cleanup completed"
}

create_swap_file() {
    local file_path="$1"
    local size_mb="$2"
    
    log_info "Creating swap file: ${file_path} (${size_mb}MB)"
    
    # Check disk space
    local available_mb=$(get_disk_available_mb)
    if [[ $available_mb -lt $size_mb ]]; then
        log_error "Insufficient disk space. Available: ${available_mb}MB, Required: ${size_mb}MB"
        return 1
    fi
    
    # Create file
    if command -v fallocate >/dev/null 2>&1; then
        if ! fallocate -l "${size_mb}M" "$file_path"; then
            log_warn "fallocate failed, using dd..."
            if ! dd if=/dev/zero of="$file_path" bs=1M count="$size_mb" status=none; then
                log_error "Failed to create swap file"
                return 1
            fi
        fi
    else
        if ! dd if=/dev/zero of="$file_path" bs=1M count="$size_mb" status=none; then
            log_error "Failed to create swap file"
            return 1
        fi
    fi
    
    # Set permissions and format
    chmod 600 "$file_path" || {
        log_error "Failed to set permissions"
        return 1
    }
    
    if ! mkswap "$file_path" >/dev/null 2>&1; then
        log_error "Failed to format swap file"
        rm -f "$file_path" 2>/dev/null || true
        return 1
    fi
    
    if ! swapon "$file_path"; then
        log_error "Failed to enable swap file"
        rm -f "$file_path" 2>/dev/null || true
        return 1
    fi
    
    log_ok "Swap file created and enabled successfully"
    return 0
}

setup_swap() {
    local target_mb="$1"
    local current_swap=$(get_swap_total_mb)
    
    [[ $target_mb -eq $current_swap ]] && {
        log_info "Swap already at ${current_mb}MB - no changes needed"
        return 0
    }
    
    section_title "Configuring Swap: ${current_swap}MB → ${target_mb}MB"
    
    # Clean up first
    cleanup_existing_swap
    
    # Create new swap file
    if create_swap_file "$SWAPFILE" "$target_mb"; then
        # Update fstab
        echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
        log_ok "Swap configuration completed successfully"
        
        # Show final status
        echo
        free -h
        echo
        swapon --show
    else
        log_error "Failed to configure swap"
        return 1
    fi
}

#######################################
# Swap Management Menu
#######################################
swap_management_menu() {
    while true; do
        banner
        section_title "Swap Management"
        
        display_system_status
        
        echo -e "${BOLD}Available Actions:${RESET}"
        echo "1) Auto-configure swap (recommended)"
        echo "2) Set custom swap size"
        echo "3) Clean up all swap files and start fresh"
        echo "4) Show detailed status"
        echo "5) Back to main menu"
        echo
        
        read -rp "Choose option [1-5]: " choice
        
        case $choice in
            1)
                local recommended=$(recommended_swap_mb)
                if [[ $recommended -gt 0 ]]; then
                    setup_swap $recommended
                else
                    log_info "System has sufficient RAM - no swap recommended"
                fi
                pause
                ;;
            2)
                read -rp "Enter swap size in MB: " custom_size
                if [[ $custom_size =~ ^[0-9]+$ ]] && [[ $custom_size -gt 0 ]]; then
                    setup_swap $custom_size
                else
                    log_error "Invalid size entered"
                fi
                pause
                ;;
            3)
                log_info "Starting fresh swap configuration..."
                cleanup_existing_swap
                log_ok "System is now clean. Use option 1 or 2 to configure new swap."
                pause
                ;;
            4)
                echo
                free -h
                echo
                swapon --show 2>/dev/null || log_info "No swap files active"
                pause
                ;;
            5)
                return
                ;;
            *)
                log_warn "Invalid choice"
                pause
                ;;
        esac
    done
}

#######################################
# Timezone Configuration
#######################################
configure_timezone() {
    section_title "Timezone Configuration"
    
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Unknown")
    echo -e "Current timezone: ${CYAN}${current_tz}${RESET}"
    echo
    
    echo "Available timezones:"
    echo "1) Asia/Shanghai"
    echo "2) Asia/Tokyo" 
    echo "3) Asia/Singapore"
    echo "4) UTC"
    echo "5) Custom input"
    echo "6) Cancel"
    echo
    
    read -rp "Choose option [1-6]: " tz_choice
    
    case $tz_choice in
        1) local new_tz="Asia/Shanghai" ;;
        2) local new_tz="Asia/Tokyo" ;;
        3) local new_tz="Asia/Singapore" ;;
        4) local new_tz="UTC" ;;
        5)
            read -rp "Enter timezone: " new_tz
            [[ -z "$new_tz" ]] && {
                log_warn "No timezone entered"
                return
            }
            ;;
        6)
            log_warn "Timezone change cancelled"
            return
            ;;
        *)
            log_warn "Invalid choice"
            return
            ;;
    esac
    
    if timedatectl set-timezone "$new_tz" 2>/dev/null; then
        log_ok "Timezone set to: $(timedatectl show --property=Timezone --value)"
    else
        log_error "Failed to set timezone: $new_tz"
    fi
    pause
}

#######################################
# Package Management
#######################################
install_packages() {
    section_title "Package Installation"
    
    echo "Select packages to install:"
    echo "1) Essential tools (curl, wget, nano, htop, vnstat)"
    echo "2) Development tools (git, unzip, screen)"
    echo "3) All recommended packages"
    echo "4) Custom selection"
    echo "5) Cancel"
    echo
    
    read -rp "Choose option [1-5]: " pkg_choice
    
    case $pkg_choice in
        1)
            local packages=("curl" "wget" "nano" "htop" "vnstat")
            ;;
        2)
            local packages=("git" "unzip" "screen")
            ;;
        3)
            local packages=("${BASE_PACKAGES[@]}")
            ;;
        4)
            echo "Enter package names separated by spaces:"
            read -r -a packages
            ;;
        5)
            log_warn "Package installation cancelled"
            return
            ;;
        *)
            log_warn "Invalid choice"
            return
            ;;
    esac
    
    [[ ${#packages[@]} -eq 0 ]] && {
        log_warn "No packages selected"
        return
    }
    
    echo
    echo -e "Packages to install: ${CYAN}${packages[*]}${RESET}"
    read -rp "Proceed with installation? (y/N): " confirm
    
    [[ $confirm =~ ^[Yy]$ ]] || {
        log_warn "Installation cancelled"
        return
    }
    
    log_info "Updating package lists..."
    if ! apt update -y; then
        log_error "Failed to update package lists"
        return
    fi
    
    log_info "Installing packages..."
    if apt install -y "${packages[@]}"; then
        log_ok "Packages installed successfully"
    else
        log_error "Some packages failed to install"
    fi
    pause
}

#######################################
# Quick Setup
#######################################
quick_setup() {
    section_title "Quick Server Setup"
    
    echo -e "${BOLD}This will perform:${RESET}"
    echo "  • Clean up existing swap files"
    echo "  • Auto-configure optimal swap"
    echo "  • Set timezone to Asia/Shanghai" 
    echo "  • Install essential packages"
    echo
    
    read -rp "Proceed with quick setup? (y/N): " confirm
    [[ $confirm =~ ^[Yy]$ ]] || {
        log_warn "Quick setup cancelled"
        return
    }
    
    # Clean up existing swap
    log_info "Step 1: Cleaning up existing swap..."
    cleanup_existing_swap
    
    # Configure swap
    log_info "Step 2: Configuring swap..."
    local recommended=$(recommended_swap_mb)
    if [[ $recommended -gt 0 ]]; then
        setup_swap $recommended
    else
        log_info "No swap configuration needed"
    fi
    
    # Set timezone
    log_info "Step 3: Setting timezone..."
    if timedatectl set-timezone "$DEFAULT_TIMEZONE" 2>/dev/null; then
        log_ok "Timezone set to: $(timedatectl show --property=Timezone --value)"
    else
        log_warn "Failed to set timezone"
    fi
    
    # Install packages
    log_info "Step 4: Installing packages..."
    if apt update -y && apt install -y "${BASE_PACKAGES[@]}"; then
        log_ok "Packages installed successfully"
    else
        log_warn "Some packages failed to install"
    fi
    
    log_ok "Quick setup completed!"
    pause
}

#######################################
# Main Menu
#######################################
main_menu() {
    while true; do
        banner
        
        echo -e "${BOLD}${BLUE}🏠 Main Menu${RESET}"
        print_separator
        
        display_system_status
        
        echo -e "${BOLD}Available Actions:${RESET}"
        echo "1) Swap Management"
        echo "2) Configure Timezone" 
        echo "3) Install Packages"
        echo "4) Quick Setup (recommended for new servers)"
        echo "5) Exit"
        echo
        
        read -rp "Choose option [1-5]: " choice
        
        case $choice in
            1) swap_management_menu ;;
            2) configure_timezone ;;
            3) install_packages ;;
            4) quick_setup ;;
            5)
                echo
                log_ok "Thank you for using Server Setup Essentials! 👋"
                exit 0
                ;;
            *)
                log_warn "Invalid choice"
                pause
                ;;
        esac
    done
}

#######################################
# Main Execution
#######################################
main() {
    require_root
    trap 'echo; log_error "Script interrupted"; exit 1' INT TERM
    
    # Check system
    if ! [[ -f /etc/debian_version ]]; then
        log_warn "This script is optimized for Debian-based systems"
        read -rp "Continue anyway? (y/N): " proceed
        [[ $proceed =~ ^[Yy]$ ]] || exit 1
    fi
    
    main_menu
}

# Run main function
main "$@"

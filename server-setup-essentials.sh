#!/usr/bin/env bash
#
# Server Setup Essentials - Enhanced Version
# - Interactive menu with beautiful dashboard
# - Network diagnostics and optimization tools
# - Safe swap management with intelligent detection
# - Timezone configuration
# - Software installation (multi-select)
# - Comprehensive network optimization

VERSION="v2.4.0"
set -euo pipefail

###### Colors and Styles ######
#######################################

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly ORANGE='\033[0;33m'
readonly PURPLE='\033[0;35m'
readonly BOLD='\033[1m'
readonly UNDERLINE='\033[4m'
readonly RESET='\033[0m'

###### Configuration ######
#######################################

readonly SWAPFILE="/swapfile"
readonly MIN_SAFE_RAM_MB=100
readonly DEFAULT_TIMEZONE="Asia/Shanghai"
readonly BASE_PACKAGES=("curl" "wget" "nano" "htop" "vnstat" "git" "unzip" "screen" "speedtest-cli" "traceroute" "ethtool")
readonly NETWORK_PACKAGES=("speedtest-cli" "traceroute" "ethtool" "net-tools" "dnsutils" "iptables-persistent")
LOG_DIR="/root/server-setup-logs/"
mkdir -p "$LOG_DIR" 
readonly LOG_FILE="/root/server-setup-logs/server-setup-$(date +%Y%m%d-%H%M%S).log"

###### Logging Functions ######
#######################################

log_info()  { echo -e "${CYAN}${BOLD}[INFO]${RESET} ${CYAN}$*${RESET}" | tee -a "$LOG_FILE"; }
log_ok()    { echo -e "${GREEN}${BOLD}[OK]${RESET} ${GREEN}$*${RESET}" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}${BOLD}[WARN]${RESET} ${YELLOW}$*${RESET}" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}${BOLD}[ERROR]${RESET} ${RED}$*${RESET}" | tee -a "$LOG_FILE"; }

###### Utility Functions ######
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
    echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║              SERVER SETUP ESSENTIALS ${VERSION}                    ║${RESET}"
    echo -e "${BOLD}${CYAN}╠════════════════════════════════════════════════════════════════╣${RESET}"
}

section_title() {
    banner
    display_system_status
    echo
    echo -e "${BOLD}${MAGENTA}🎯 $*${RESET}"
}

sub_section() {
    echo
    echo -e "${BOLD}${CYAN}🔹 $*${RESET}"
}

###### System Information Functions ######
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

get_swap_file_size_mb() {
    local swap_file="$1"
    if [[ -f "$swap_file" ]]; then
        local size_bytes=$(stat -c%s "$swap_file" 2>/dev/null || echo 0)
        echo $((size_bytes / 1024 / 1024))
    else
        echo 0
    fi
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

detect_ifaces() {
    ip -br link show | awk '{print $1}' | grep -E '^e|^en|^eth|^wlan' | paste -sd, -
}

fmt_uptime() {
    local up=$(uptime -p | sed 's/^up //')
    up=$(echo "$up" | sed -E 's/weeks?/w/g; s/days?/d/g; s/hours?/h/g; s/minutes?/m/g; s/seconds?/s/g; s/,//g')
    
    if echo "$up" | grep -qE '[wd]'; then
        up=$(echo "$up" | sed -E 's/[0-9]+m//g; s/[0-9]+s//g')
    fi
    
    echo "$up" | tr -s ' ' | sed 's/ *$//'
}

get_load_status() {
    local load_value=$1 cores=$2
    if (( $(echo "$load_value > $cores * 2" | bc -l 2>/dev/null) )); then
        echo -e "$RED❌ High Load$RESET"
    elif (( $(echo "$load_value > $cores" | bc -l 2>/dev/null) )); then
        echo -e "$YELLOW⚠️ Medium Load$RESET"
    else
        echo -e "$GREEN✅ Optimal Load$RESET"
    fi
}

get_mem_status() {
    local percent=$1 free_mb=$2
    local status_icon="✅" color=$RESET
    
    [[ $percent -gt 80 ]] && { status_icon="🚨"; color=$RED; }
    [[ $percent -gt 60 ]] && { status_icon="⚠"; color=$YELLOW; }
    
    echo -e "$color$status_icon ${free_mb}MB Available$RESET"
}

get_disk_status() {
    local percent=$1
    local color=$RESET
    [[ "${percent%\%}" -gt 80 ]] && color=$RED
    [[ "${percent%\%}" -gt 60 ]] && color=$YELLOW
    echo "$color"
}

get_disk_type() {
    local disk_type_value=$(lsblk -d -o ROTA 2>/dev/null | awk 'NR==2 {print $1}')
    case "$disk_type_value" in
        "0") echo -e "$GREEN🚀 SSD$RESET" ;;
        "1") echo -e "$BLUE💾 HDD$RESET" ;;
        *) echo -e "$YELLOW💿 Unknown$RESET" ;;
    esac
}

get_swap_status() {
    local total=$1 used=$2 percent=$3 recommended=$4
    if [[ $total -eq 0 ]]; then
        echo "$RED❌ Not configured$RESET"
    else
        local color=$RESET status="✅ Optimal usage"
        [[ $percent -gt 80 ]] && { color=$RED; status="🚨 High usage"; }
        [[ $percent -gt 60 ]] && [[ $percent -le 80 ]] && { color=$YELLOW; status="⚠ Medium usage"; }
        [[ $total -lt $recommended ]] && { color=$YELLOW; status="⚠ Small usage"; }
        echo -e "$color$status$RESET"
    fi
}

###### Display System Status ######
###############################################

display_system_status() {
    # Header information
    printf "${MAGENTA}%-14s${RESET} %-17s ${MAGENTA}%-10s${RESET} %-20s\n" \
        "  Boot:" "$(who -b | awk '{print $3, $4}')" "Uptime:" "$(fmt_uptime)"
    
    printf "${MAGENTA}%-14s${RESET} %-17s ${MAGENTA}%-10s${RESET} %-20s\n" \
        "  Current:" "$(date '+%Y-%m-%d %H:%M')" "Timezone:" "$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Unknown")"
    
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════╣${RESET}"
    
    # Bandwidth and Traffic Information
    display_bandwidth_info
    display_traffic_info
    
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════╣${RESET}"
    
    # System Information
    display_system_info
    display_resource_usage
    display_network_info
    
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${RESET}"
}

display_bandwidth_info() {
    local INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -2 | tr '\n' ',' | sed 's/,$//')
    
    if command -v vnstat >/dev/null 2>&1; then
        local VNSTAT_VERSION=$(vnstat --version 2>/dev/null | awk '{print $2}')
        local vnstat_output=$(vnstat --oneline 2>/dev/null)
        
        if [[ -n "$vnstat_output" ]]; then
            local vnstat_month=$(echo "$vnstat_output" | awk -F';' '{print $8}')
            local vnstat_rx=$(echo "$vnstat_output" | awk -F';' '{print $9}')
            local vnstat_tx=$(echo "$vnstat_output" | awk -F';' '{print $10}')
            local vnstat_total=$(echo "$vnstat_output" | awk -F';' '{print $11}')
            
            printf "${YELLOW}%-14s${RESET} %-9s %-9s ${GREEN}%-10s${RESET} ${CYAN}%-10s${RESET} ${MAGENTA}%-10s${RESET}\n" \
                "" "iface" "Duration" "RX/UL" "TX/DL" "Total"
            printf "${YELLOW}%-14s${RESET} %-9s %-9s %-10s %-10s %-10s\n" \
                "  vnStat $VNSTAT_VERSION" "$INTERFACES" "$vnstat_month" "$vnstat_rx" "$vnstat_tx" "$vnstat_total"
        else
            printf "${YELLOW}%-14s${RESET} ${RED}%-46s${RESET}\n" \
                "  Bandwidth:" "Collecting data..."
        fi
    else
        printf "${YELLOW}%-14s${RESET} ${RED}%-46s${RESET}\n" \
            "  Bandwidth:" "vnStat not installed"
    fi
}

display_traffic_info() {
    local BOOT_DAYS=$(echo $(($(date +%s) - $(date -d "$(who -b | awk '{print $3, $4}')" +%s))) | awk '{printf "%d days\n", $1/86400}')
    
    ip -s link | awk -v boot_days="$BOOT_DAYS" '
    function human(x){
        split("B KB MB GB TB",u);
        i=1;
        while(x>=1024&&i<5){
            x/=1024;
            i++
        }
        return sprintf("%.2f %s",x,u[i])
    } 
    /^[0-9]+:/{
        iface=$2;
        gsub(":","",iface)
    } 
    /RX:/{
        getline;
        rx=$1
    } 
    /TX:/{
        getline;
        tx=$1;
        if(iface != "lo") {
            total=rx+tx;
            printf "  %-12s %-9s %-9s %-10s %-10s %-10s\n", "Server", iface, boot_days, human(rx), human(tx), human(total)
        }
    }' | head -3
}

display_system_info() {
    local HOSTNAME=$(hostname -f 2>/dev/null || hostname)
    local OS=$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
    local KERNEL=$(uname -r)
    local CPU=$(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | sed 's/\<Processor\>//g' | xargs)
    local CORES=$(nproc)
    
    printf "${YELLOW}%-14s${RESET} %-46s\n" "  Hostname:" "$HOSTNAME"
    printf "${YELLOW}%-14s${RESET} %-46s\n" "  OS:" "$OS"
    printf "${YELLOW}%-14s${RESET} %-46s\n" "  Kernel:" "$KERNEL"
    printf "${YELLOW}%-14s${RESET} %-46s\n" "  CPU:" "$CPU ($CORES cores)"
}

display_resource_usage() {
    local MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    local MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    local MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))
    local DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
    local DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
    local DISK_PERCENT=$(df -h / | awk 'NR==2 {print $5}')
    local LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    local load1=$(echo "$LOAD" | awk -F', ' '{print $1}' | sed 's/,//g')
    local CORES=$(nproc)
    	
    # Disk
    local disk_color=$(get_disk_status "$DISK_PERCENT")
    printf "${YELLOW}%-14s${RESET} ${disk_color}%-20s${RESET} %s\n" "  Disk:" \
        "${DISK_USED} / ${DISK_TOTAL} (${DISK_PERCENT})" "$(get_disk_type)"
		
    # Load Average
    printf "${YELLOW}%-14s${RESET} %-20s %s\n" "  Load Avg:" "$LOAD" "$(get_load_status "$load1" "$CORES")"
    
    # Memory
    printf "${YELLOW}%-14s${RESET} %-20s %s\n" "  Memory:" "${MEM_USED}MB / ${MEM_TOTAL}MB (${MEM_PERCENT}%)" \
        "$(get_mem_status "$MEM_PERCENT" "$(get_free_ram_mb)")"    
    
    # Swap
    local swap_total=$(get_swap_total_mb)
    local swap_used=$(get_swap_used_mb)
    local swap_percent=0
    [[ $swap_total -gt 0 ]] && swap_percent=$((swap_used * 100 / swap_total))
    local recommended_swap=$(recommended_swap_mb)
    
    if [[ $swap_total -eq 0 ]]; then
        printf "${YELLOW}%-14s${RESET} ${RED}%-20s${RESET} ${RED}%s${RESET}\n" "  Swap:" "Not configured" "❌"
    else
        local swap_color=$RESET
        [[ $swap_percent -gt 80 ]] && swap_color=$RED
        [[ $swap_percent -gt 60 ]] && swap_color=$YELLOW
        printf "${YELLOW}%-14s${RESET} ${swap_color}%-20s${RESET} %s\n" "  Swap:" \
            "${swap_used}MB / ${swap_total}MB (${swap_percent}%)" "$(get_swap_status "$swap_total" "$swap_used" "$swap_percent" "$recommended_swap")"
    fi
}

display_network_info() {
    local IPV4=$(hostname -I | awk '{print $1}')
    local IPV6=$(ip -6 addr show scope global 2>/dev/null | grep inet6 | head -1 | awk '{print $2}' | cut -d'/' -f1)
    local bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    local q_status=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')
    
    local ipv6_status=$([ -n "$IPV6" ] && echo -e "${GREEN}IPv6 ✓${RESET}" || echo -e "${RED}IPv6 ✗${RESET}")
    local bbr_display=$([ "$bbr_status" == "bbr" ] || [ "$bbr_status" == "bbr2" ] && echo -e "${GREEN}${bbr_status^^} ✓${RESET}" || echo -e "${RED}${bbr_status} ✗${RESET}")
    local qdisc_display=$([ "$q_status" == "fq_codel" ] && echo -e "${GREEN}${q_status^^} ✓${RESET}" || echo -e "${RED}${q_status} ✗${RESET}")
        
    printf "${YELLOW}%-14s${RESET} %-20s ${YELLOW}%-14s${RESET} %s\n" "  BBR+QDisc:" "$bbr_display + $qdisc_display"
	printf "${YELLOW}%-14s${RESET} %-20s ${YELLOW}%-10s${RESET} %s\n" "  IPv4:" "$IPV4 ($ipv6_status)"
}

###### Swap Management Core ######
#######################################

swap_management_menu() {
    while true; do
		section_title "Swap Management"
		echo
        echo "   1) Auto-configure swap (intelligent detection)"
        echo "   2) Set custom swap size"
        echo "   3) Clean up all swap files and start fresh"
        echo "   4) Show Current Swap Details"
        echo "   0) Back to Main Menu"
        echo
        
        read -rp "   Choose option [0-4]: " choice
        case $choice in
            1)
                local recommended=$(recommended_swap_mb)
                [[ $recommended -gt 0 ]] && setup_swap $recommended || log_ok "System has sufficient RAM - no swap recommended"
                pause
                ;;
            2)
                read -rp "Enter swap size in MB: " custom_size
                [[ $custom_size =~ ^[0-9]+$ ]] && [[ $custom_size -gt 0 ]] && setup_swap $custom_size || log_error "Invalid size entered"
                pause
                ;;
            3)
                log_info "Starting fresh swap configuration..."
                cleanup_existing_swap
                log_ok "System is now clean. Use option 1 or 2 to configure new swap."
                pause
                ;;
            4)
                echo -e "${BOLD}Swap Details:${RESET}"
                free -h; echo; swapon --show 2>/dev/null || log_info "No swap files active"; echo
                pause
                ;;
            0) return ;;
            *) log_warn "Invalid choice"; pause ;;
        esac
    done
}

cleanup_existing_swap() {
    log_info "Cleaning up existing swap configuration..."
    
    local active_swaps=$(swapon --show=NAME --noheadings 2>/dev/null || true)
    if [[ -n "$active_swaps" ]]; then
        log_info "Disabling active swap files..."
        swapoff -a 2>/dev/null || log_warn "Some swap files could not be disabled (may be in use)"
    fi
    
    local swap_files=("/swapfile" "/swapfile.new" "/swapfile2" "/tmp/temp_swap_"*)
    for file in "${swap_files[@]}"; do
        [[ -f "$file" ]] && { log_info "Removing: $file"; rm -f "$file" 2>/dev/null || log_warn "Could not remove: $file"; }
    done
    
    grep -q "swapfile" /etc/fstab 2>/dev/null && {
        log_info "Cleaning /etc/fstab..."
        sed -i '/swapfile/d' /etc/fstab 2>/dev/null || true
    }
    
    log_ok "Cleanup completed"
}

create_swap_file() {
    local file_path="$1" size_mb="$2"
    local available_mb=$(get_disk_available_mb)
    
    [[ $available_mb -lt $size_mb ]] && {
        log_error "Insufficient disk space. Available: ${available_mb}MB, Required: ${size_mb}MB"
        return 1
    }
    
    log_info "Creating swap file: ${file_path} (${size_mb}MB)"
    
    if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${size_mb}M" "$file_path" || {
            log_warn "fallocate failed, using dd..."
            dd if=/dev/zero of="$file_path" bs=1M count="$size_mb" status=none || {
                log_error "Failed to create swap file"; return 1; }
        }
    else
        dd if=/dev/zero of="$file_path" bs=1M count="$size_mb" status=none || {
            log_error "Failed to create swap file"; return 1; }
    fi
    
    chmod 600 "$file_path" || { log_error "Failed to set permissions"; return 1; }
    mkswap "$file_path" >/dev/null 2>&1 || { log_error "Failed to format swap file"; rm -f "$file_path"; return 1; }
    swapon "$file_path" || { log_error "Failed to enable swap file"; rm -f "$file_path"; return 1; }
    
    log_ok "Swap file created and enabled successfully"
    return 0
}

setup_swap() {
    local target_mb="$1"
    local current_swap=$(get_swap_total_mb)
    local current_swap_file_size=$(get_swap_file_size_mb "$SWAPFILE")
    
    if [[ -f "$SWAPFILE" ]] && [[ $current_swap_file_size -eq $target_mb ]] && [[ $current_swap -eq $target_mb ]]; then
        log_ok "Swap already configured with recommended size: ${target_mb}MB - no changes needed"
        return 0
    fi
    
    section_title "Configuring Swap: ${current_swap}MB → ${target_mb}MB"
    cleanup_existing_swap
    
    if create_swap_file "$SWAPFILE" "$target_mb"; then
        echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
        log_ok "Swap configuration completed successfully"
        echo; free -h; echo; swapon --show
    else
        log_error "Failed to configure swap"
        return 1
    fi
}

###### Network Tools and Optimization ######
#######################################

network_tools_menu() {
    while true; do        
        section_title "Network Tools & Optimization"
        # echo -e "${BOLD}${CYAN}Available Network Actions:${RESET}"
		echo "   (Modify sysctl.conf)"
		echo
        echo "   1) Run Network Diagnostics"
        echo "   2) Apply Network Optimization (BBR/BBR2)"
        echo "   3) Restore Network Settings"
        echo "   4) Install Network Tools"
        echo "   0) Back to Main Menu"
        echo
        
        read -rp "   Choose option [0-4]: " choice
        case $choice in
            1) network_diagnostics; pause ;;
            2) apply_network_optimization; pause ;;
            3) restore_network_settings; pause ;;
            4) install_network_tools; pause ;;
            0) return ;;
            *) log_warn "Invalid choice"; pause ;;
        esac
    done
}

install_network_tools() {
    sub_section "Installing Network Tools"
    log_info "Updating package lists..."
    apt update -y >/dev/null 2>&1
    
    log_info "Installing network diagnostic tools..."
    if apt install -y "${NETWORK_PACKAGES[@]}" >/dev/null 2>&1; then
        log_ok "Network tools installed successfully"
    else
        log_error "Failed to install some network tools"
        return 1
    fi
}

network_diagnostics() {
    section_title "Network Diagnostics"
    install_network_tools
    
    echo -e "${BOLD}${GREEN}🌐 Running Network Tests...${RESET}"
    echo
    
    # Ping tests
    sub_section "Ping Tests"
    declare -A ping_hosts=([Google]="8.8.8.8" [Cloudflare]="1.1.1.1" [AliDNS]="223.5.5.5" [Quad9]="9.9.9.9")
    for name in "${!ping_hosts[@]}"; do
        echo -e "${CYAN}Pinging ${name} (${ping_hosts[$name]})...${RESET}"
        ping -c 4 -W 3 "${ping_hosts[$name]}" 2>/dev/null | tail -n2 || echo -e "${RED}Failed to ping ${ping_hosts[$name]}${RESET}\n"
    done
    
    # Traceroute
    sub_section "Network Route Analysis"
    echo -e "${CYAN}Traceroute to 8.8.8.8 (first 10 hops):${RESET}"
    traceroute -m 10 8.8.8.8 2>/dev/null | head -n 15 || log_warn "Traceroute not available"
    
    # Interface information
    sub_section "Network Interface Status"
    for i in $(ls /sys/class/net | grep -v lo); do
        local IP=$(ip -4 addr show $i | grep inet | awk '{print $2}' | head -n1)
        echo -e "${CYAN}Interface ${i}:${RESET} ${IP:-${RED}No IP${RESET}}"
    done
    
    log_ok "Network diagnostics completed"
}

apply_network_optimization() {
    section_title "Applying Network Optimization"
    
    log_info "Checking BBR availability..."
    local bbr_mode="bbr"
    if modprobe tcp_bbr2 2>/dev/null; then
        echo -e "${GREEN}BBR2 is available${RESET}"
        read -rp "Use BBR2 instead of BBR? [Y/n]: " use_bbr2
        [[ "$use_bbr2" =~ ^[Yy]$|^$ ]] && bbr_mode="bbr2"
    else
        log_warn "BBR2 not available, using BBR"
    fi
    
    local backup_file="/etc/sysctl.conf.bak-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating backup: $backup_file"
    cp /etc/sysctl.conf "$backup_file" && log_ok "Backup created successfully"
    
    log_info "Applying network optimization settings..."
    cat <<EOF > /etc/sysctl.conf
# ============================================================
# 🌐 Network Optimization - Server Setup Essentials
# BBR/BBR2 + fq_codel + UDP/QUIC optimization
# version: v03 (based on sysctl-General-v03.conf file)
#
# Universal sysctl.conf for VPS (Generalized, Safe Everywhere)
# Works on: DigitalOcean, Vultr, Linode, AWS, Hetzner, OVH,
# Tencent, Alibaba, Oracle, RackNerd, Mikrotik CHR, etc.
# ============================================================

######## Core Network Optimization ########
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr

######## Connection Stability ########
######## TCP Stability & Handshake ########
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

######## MTU & RTT Optimization ########
######## MTU Auto-Adjustment ########
######## (Best for global routing) ########
# changed from 1 to 2
net.ipv4.tcp_mtu_probing = 2

######## TCP Buffers ########
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608

######## UDP / QUIC Optimization ########
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_mem = 3145728 4194304 8388608
net.ipv4.udp_rmem_min = 32768
net.ipv4.udp_wmem_min = 32768

######## NIC / Packet Processing ########
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 5000

######## Performance & Stability ########
######## Queue / Backlog ########
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192

######## Port Range ########
net.ipv4.ip_local_port_range = 10240 65535

######## Security ########
net.ipv4.tcp_syncookies = 1

######## Routing ########
net.ipv4.ip_forward = 1
######## Anti-Route Conflicts ########
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

######## File Handles ########
fs.file-max = 1000000

# ============================================================
# END - Universal sysctl.conf
# ============================================================
EOF

    if sysctl -p >/dev/null 2>&1; then
        log_ok "Network optimization applied successfully with ${bbr_mode}"
        sub_section "Verification"
        echo -e "${GREEN}✓ Congestion Control:${RESET} $(sysctl -n net.ipv4.tcp_congestion_control)"
        echo -e "${GREEN}✓ Default Qdisc:${RESET} $(sysctl -n net.core.default_qdisc)"
        echo -e "${GREEN}✓ IPv4 Forwarding:${RESET} $(sysctl -n net.ipv4.ip_forward)"
    else
        log_error "Failed to apply network optimization"
        return 1
    fi
}

restore_network_settings() {
    section_title "Restore Network Settings"
    local last_backup=$(ls -t /etc/sysctl.conf.bak-* 2>/dev/null | head -n1)
    
    if [[ -z "$last_backup" ]]; then
        log_error "No backup found to restore"
        return 1
    fi
    
    echo -e "Last backup: ${CYAN}${last_backup}${RESET}"
    read -rp "Restore this backup? [y/N]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Restoring network settings from backup..."
        if cp "$last_backup" /etc/sysctl.conf && sysctl -p >/dev/null 2>&1; then
            log_ok "Network settings restored successfully"
        else
            log_error "Failed to restore network settings"
        fi
    else
        log_warn "Restore cancelled"
    fi
}


###### System Logs Optimization ######
###############################################

logs_optimization_menu() {
    section_title "System Logs Optimization"
	echo "   (Modify journald.conf)"
	echo
    echo "   1) Basic Journal Optimization (Recommended)"
    echo "   2) Custom Journal Limits"
    echo "   3) Vacuum Logs Only"
    echo "   4) View Current Log Usage"
    echo "   5) Remove All Optimization"
    echo "   0) Back to Main Menu"
    echo
    
    read -rp "   Choose option [0-5]: " choice
    
    case $choice in
        1) optimize_system_logs ;;
        2) set_custom_journal_limits ;;
        3) vacuum_logs_only ;;
        4) view_log_usage ;;
        5) remove_log_optimization ;;
        0) return ;;
        *) log_warn "Invalid choice" ;;
    esac
    pause
}

optimize_system_logs() {
    section_title "System Logs Optimization"
    
    echo -e "${BOLD}${GREEN}This will optimize system journal logs and rotation:${RESET}"
    echo "  ✅ Configure journald limits (SystemMaxUse=100M, RuntimeMaxUse=50M)"
    # echo "  ✅ Set up log rotation and cleanup cron jobs"
    echo "  ✅ Vacuum existing journal logs"
    echo "  ✅ Restart journald service"
    echo
    
    read -rp "Proceed with system logs optimization? (y/N): " confirm
    [[ $confirm =~ ^[Yy]$ ]] || {
        log_warn "Logs optimization cancelled"
        return
    }
    
    # Install required packages
    sub_section "Step 1: Installing Required Packages"
    log_info "Installing log optimization tools..."
    if apt update -y && apt install -y "${LOG_OPTIMIZATION_PACKAGES[@]}"; then
        log_ok "Log optimization tools installed successfully"
    else
        log_error "Failed to install some packages"
        return 1
    fi
    
    # Configure journald
    sub_section "Step 2: Configuring Journald Limits"
    log_info "Configuring journald system limits..."
    
    local journald_conf="/etc/systemd/journald.conf"
    local journald_backup="${journald_conf}.bak-$(date +%Y%m%d-%H%M%S)"
    
    # Create backup
    cp "$journald_conf" "$journald_backup" && log_ok "Backup created: $journald_backup"
    
    # Configure journald limits
    cat <<EOF > "$journald_conf"
# ======================================================================
# systemd-journald Configuration (Optimized for VPS 1–4 GB RAM)
# Clean, safe, annotated — all default options remain commented.
# version: optimize-Journal v02.conf
# ======================================================================
[Journal]
#############################################
# STORAGE & COMPRESSION
#############################################
# Storage type:
#   auto       → use persistent if /var/log/journal exists, otherwise volatile
#   persistent → keep logs on disk
#   volatile   → keep logs only in RAM (lost at reboot)
Storage=persistent
# Compress journal files to reduce disk usage
Compress=yes
# Cryptographically seal journal files against tampering
Seal=yes

#############################################
# RATE LIMITING 
# (Prevents log spam from services like V2bX)
#############################################
# Allow at most 5000 messages every 30 seconds
RateLimitIntervalSec=30s
RateLimitBurst=5000

#############################################
# DISK USAGE LIMITS (Most important for small VPS)
#############################################
# Maximum total disk usage for journald logs (default: unlimited)
# Recommended: 100–200M for small servers
SystemMaxUse=150M
# Always keep at least 50M disk space free
SystemKeepFree=50M
# Maximum size of a single journal file
SystemMaxFileSize=10M
# Maximum number of journal files allowed (default is 100)
#SystemMaxFiles=100

#############################################
# RUNTIME (RAM) LOG STORAGE LIMITS
#############################################
# Maximum RAM usage for volatile logs (/run/log/journal)
RuntimeMaxUse=30M
RuntimeMaxFileSize=5M
# Minimum free RAM to keep (uncommon; keep commented)
#RuntimeKeepFree=
# Maximum number of RAM journal files
#RuntimeMaxFiles=100

#############################################
# RETENTION / ROTATION
#############################################
# Maximum total retention time for logs
MaxRetentionSec=1month
# Maximum retention per log file
MaxFileSec=1week

#############################################
# LOG FORWARDING (Disabled for performance)
#############################################
# Don’t forward logs to syslog, kmsg, console, or wall messages
# Saves CPU/RAM and avoids duplicate logs
ForwardToSyslog=no
ForwardToKMsg=no
ForwardToConsole=no
ForwardToWall=no
# Path for forwarding to console (unused when ForwardToConsole=no)
#TTYPath=/dev/console

#############################################
# LOG LEVEL LIMITS (Store only important logs)
#############################################
# Store logs up to "warning"
MaxLevelStore=warning
# Forward logs (if enabled) only up to warning
MaxLevelSyslog=warning
# Kernel message logging
MaxLevelKMsg=notice
# Console logging level (disabled anyway)
MaxLevelConsole=notice
# Emergency broadcast level
MaxLevelWall=emerg

#############################################
# MISC OPTIONS (Keep defaults unless needed)
#############################################
#SyncIntervalSec=5m
#SplitMode=uid
#LineMax=48K
#ReadKMsg=yes
#Audit=yes

#############################################
# END OF CONFIGURATION
#############################################
EOF

    log_ok "Journald configuration applied successfully"
    
    # Restart journald service
    sub_section "Step 3: Restarting Journald Service"
    log_info "Restarting systemd-journald service..."
    if systemctl restart systemd-journald; then
        log_ok "Journald service restarted successfully"
    else
        log_warn "Failed to restart journald service"
    fi
    
    # Clean up existing journals
    sub_section "Step 4: Cleaning Up Existing Journals"
    log_info "Vacuuming journal logs..."
    
    # Vacuum by size
    if journalctl --vacuum-size=50M 2>/dev/null; then
        log_ok "Journal logs vacuumed to 50MB limit"
    else
        log_warn "Failed to vacuum journal by size"
    fi
    
    # Vacuum by time (keep only last 7 days)
    if journalctl --vacuum-time=7days 2>/dev/null; then
        log_ok "Journal logs older than 7 days removed"
    else
        log_warn "Failed to vacuum journal by time"
    fi
    
    # # Set up cron job for regular cleanup
    # sub_section "Step 5: Setting Up Automatic Cleanup"
    # log_info "Configuring automatic log cleanup cron job..."
    
    # local cron_job="0 2 * * * /usr/bin/journalctl --vacuum-size=100M --vacuum-time=7days >/dev/null 2>&1"
    
    # # Remove existing similar cron jobs
    # (crontab -l 2>/dev/null | grep -v "journalctl --vacuum" | crontab -) 2>/dev/null
    
    # # Add new cron job
    # (crontab -l 2>/dev/null; echo "$cron_job") | crontab - 2>/dev/null
    
    # if crontab -l 2>/dev/null | grep -q "journalctl --vacuum"; then
        # log_ok "Automatic log cleanup cron job configured"
    # else
        # log_warn "Failed to configure cron job"
    # fi
    
    # Optimize specific service logs if they exist
    sub_section "Step 6: Optimizing Service Logs"
    local services=("nginx" "apache2" "mysql" "mariadb" "V2bX" "xray" "v2ray")
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log_info "Optimizing logs for service: $service"
            
            # Vacuum service-specific logs
            journalctl --unit="$service" --vacuum-time=1d 2>/dev/null && \
            log_ok "Cleaned logs for $service" || \
            log_warn "No logs found for $service"
            
            # Restart service to apply new log settings
            systemctl restart "$service" 2>/dev/null && \
            log_ok "Restarted $service" || \
            log_warn "Could not restart $service"
        fi
    done
    
    # Show final status
    sub_section "Step 7: Verification"
    log_info "Current journal usage:"
    journalctl --disk-usage
    
    # echo
    # log_info "Current cron jobs for log cleanup:"
    # crontab -l 2>/dev/null | grep -E "journal|vacuum|log" || echo "No log cleanup cron jobs found"
    
    echo
    log_ok "🎉 System logs optimization completed successfully!"
    echo -e "${GREEN}Journal logs are now optimized with proper limits and cleanup.${RESET}"
}

set_custom_journal_limits() {
    section_title "Custom Journal Limits"
    
    echo -e "${YELLOW}Enter custom journal limits (leave empty for default):${RESET}"
    read -rp "SystemMaxUse (default: 150M): " system_max
    read -rp "RuntimeMaxUse (default: 30M): " runtime_max
    read -rp "SystemMaxFileSize (default: 5M): " file_size
    read -rp "MaxRetentionSec (default: 1month): " retention
    
    system_max=${system_max:-"150M"}
    runtime_max=${runtime_max:-"30M"}
    file_size=${file_size:-"5M"}
    retention=${retention:-"1month"}
    
    log_info "Applying custom journal limits..."
    
    local journald_conf="/etc/systemd/journald.conf"
    local backup="${journald_conf}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$journald_conf" "$backup"
    
    # Preserve existing config and update only specific values
    grep -v -E "^(SystemMaxUse|RuntimeMaxUse|SystemMaxFileSize|MaxRetentionSec)=" "$journald_conf" > "${journald_conf}.tmp"
    
    cat <<EOF >> "${journald_conf}.tmp"
SystemMaxUse=${system_max}
RuntimeMaxUse=${runtime_max}
SystemMaxFileSize=${file_size}
MaxRetentionSec=${retention}
EOF

    mv "${journald_conf}.tmp" "$journald_conf"
    systemctl restart systemd-journald
    
    log_ok "Custom journal limits applied successfully"
}

vacuum_logs_only() {
    section_title "Vacuum System Logs"
    
    # Show current disk usage before vacuum
    echo -e "${GREEN}Current Journal Disk Usage:${RESET}"
    local before_usage=$(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]\+[A-Z]' | head -1)
    local before_size=$(du -sh /var/log/journal 2>/dev/null | awk '{print $1}')
    
    printf "  ${CYAN}%-25s${RESET} ${YELLOW}%8s${RESET}\n" "Journal files:" "$before_usage"
    printf "  ${CYAN}%-25s${RESET} ${YELLOW}%8s${RESET}\n" "Disk usage:" "$before_size"
    echo
    
    echo -e "${YELLOW}Select vacuum option:${RESET}"
    echo "1) Vacuum to 50M size limit"
    echo "2) Vacuum logs older than 7 days"
    echo "3) Vacuum both size and time"
    echo "4) Custom vacuum parameters"
    echo "0) Cancel"
    echo
    
    read -rp "Choose option [1-5]: " vacuum_choice
    
    case $vacuum_choice in
        1)
            echo -e "\n${CYAN}Vacuuming logs to 50MB size limit...${RESET}"
            if journalctl --vacuum-size=50M 2>/dev/null; then
                show_vacuum_results "$before_usage" "$before_size"
                log_ok "Logs vacuumed to 50MB limit"
            else
                log_error "Failed to vacuum logs"
            fi
            ;;
        2)
            echo -e "\n${CYAN}Vacuuming logs older than 7 days...${RESET}"
            if journalctl --vacuum-time=7days 2>/dev/null; then
                show_vacuum_results "$before_usage" "$before_size"
                log_ok "Logs older than 7 days removed"
            else
                log_error "Failed to vacuum logs"
            fi
            ;;
        3)
            echo -e "\n${CYAN}Vacuuming logs by size and time...${RESET}"
            if journalctl --vacuum-size=50M --vacuum-time=7days 2>/dev/null; then
                show_vacuum_results "$before_usage" "$before_size"
                log_ok "Logs vacuumed by both size and time"
            else
                log_error "Failed to vacuum logs"
            fi
            ;;
        4)
            custom_vacuum_parameters "$before_usage" "$before_size"
            ;;
        0)
            log_warn "Vacuum operation cancelled"
            ;;
        *)
            log_warn "Invalid choice"
            ;;
    esac
}

show_vacuum_results() {
    local before_usage="$1"
    local before_size="$2"
    
    echo
    echo -e "${GREEN}Vacuum Results:${RESET}"
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${RESET}"
    
    # Get after usage
    local after_usage=$(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]\+[A-Z]' | head -1)
    local after_size=$(du -sh /var/log/journal 2>/dev/null | awk '{print $1}')
    
    # Calculate savings
    local usage_saved=$(calculate_savings "$before_usage" "$after_usage")
    local size_saved=$(calculate_savings "$before_size" "$after_size")
    
    printf "${CYAN}║${RESET} ${YELLOW}%-20s${RESET} ${GREEN}%8s${RESET} ${CYAN}→${RESET} ${GREEN}%8s${RESET} ${CYAN}(${GREEN}%s saved${RESET}${CYAN})${RESET} %15s ${CYAN}║${RESET}\n" \
        "Journal files:" "$before_usage" "$after_usage" "$usage_saved" ""
    
    printf "${CYAN}║${RESET} ${YELLOW}%-20s${RESET} ${GREEN}%8s${RESET} ${CYAN}→${RESET} ${GREEN}%8s${RESET} ${CYAN}(${GREEN}%s saved${RESET}${CYAN})${RESET} %15s ${CYAN}║${RESET}\n" \
        "Disk usage:" "$before_size" "$after_size" "$size_saved" ""
    
    # Show detailed breakdown
    local journal_files=$(find /var/log/journal -name "*.journal" 2>/dev/null | wc -l)
    local largest_file=$(find /var/log/journal -name "*.journal" -exec du -h {} \; 2>/dev/null | sort -hr | head -1 | awk '{print $1}')
    
    printf "${CYAN}║${RESET} ${YELLOW}%-20s${RESET} ${GREEN}%8d files${RESET} %30s ${CYAN}║${RESET}\n" \
        "Journal files count:" "$journal_files" ""
    
    if [[ -n "$largest_file" ]]; then
        printf "${CYAN}║${RESET} ${YELLOW}%-20s${RESET} ${GREEN}%8s${RESET} %30s ${CYAN}║${RESET}\n" \
            "Largest file:" "$largest_file" ""
    fi
    
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${RESET}"
    echo
}

calculate_savings() {
    local before="$1"
    local after="$2"
    
    # Extract numeric value and unit
    local before_num=$(echo "$before" | grep -o '^[0-9.]\+')
    local before_unit=$(echo "$before" | grep -o '[A-Z]\+$')
    local after_num=$(echo "$after" | grep -o '^[0-9.]\+')
    local after_unit=$(echo "$after" | grep -o '[A-Z]\+$')
    
    # Convert to same unit (simplified conversion)
    if [[ "$before_unit" == "G" ]] && [[ "$after_unit" == "M" ]]; then
        before_num=$(echo "$before_num * 1024" | bc -l 2>/dev/null || echo "$before_num")
        before_unit="M"
    elif [[ "$before_unit" == "M" ]] && [[ "$after_unit" == "G" ]]; then
        after_num=$(echo "$after_num * 1024" | bc -l 2>/dev/null || echo "$after_num")
        after_unit="M"
    fi
    
    # Calculate savings
    if [[ "$before_unit" == "$after_unit" ]] && command -v bc >/dev/null 2>&1; then
        local saved=$(echo "$before_num - $after_num" | bc -l 2>/dev/null)
        if (( $(echo "$saved > 0" | bc -l) )); then
            printf "%.1f%s" "$saved" "$before_unit"
        else
            echo "0$before_unit"
        fi
    else
        echo "N/A"
    fi
}

custom_vacuum_parameters() {
    local before_usage="$1"
    local before_size="$2"
    
    echo -e "\n${YELLOW}Custom Vacuum Parameters:${RESET}"
    read -rp "Size limit (e.g., 100M, 1G): " custom_size
    read -rp "Time limit (e.g., 7days, 1month, 2weeks): " custom_time
    
    [[ -z "$custom_size" && -z "$custom_time" ]] && {
        log_warn "No parameters specified"
        return
    }
    
    local vacuum_cmd="journalctl"
    [[ -n "$custom_size" ]] && vacuum_cmd="$vacuum_cmd --vacuum-size=$custom_size"
    [[ -n "$custom_time" ]] && vacuum_cmd="$vacuum_cmd --vacuum-time=$custom_time"
    
    echo -e "\n${CYAN}Executing: $vacuum_cmd${RESET}"
    
    if eval "$vacuum_cmd" 2>/dev/null; then
        show_vacuum_results "$before_usage" "$before_size"
        log_ok "Custom vacuum completed successfully"
    else
        log_error "Failed to execute custom vacuum"
    fi
}

view_log_usage() {
    section_title "Current Log Usage"
    
    echo -e "${GREEN}Journal Disk Usage:${RESET}"
    journalctl --disk-usage
    
    # echo -e "\n${GREEN}Largest Journal Files:${RESET}"
    # find /var/log/journal -name "*.journal" -exec du -h {} \; 2>/dev/null | sort -hr | head -10
    
    echo -e "\n${GREEN}Current Journal Configuration:${RESET}"
    grep -E "^(SystemMaxUse|RuntimeMaxUse|SystemMaxFileSize|MaxRetentionSec)=" /etc/systemd/journald.conf 2>/dev/null || echo "Using default settings"
    
    # echo -e "\n${GREEN}Log Cleanup Cron Jobs:${RESET}"
    # crontab -l 2>/dev/null | grep -E "journal|vacuum|log" || echo "No log cleanup cron jobs configured"
}

remove_log_optimization() {
    section_title "Remove Log Optimization"
    
    read -rp "Remove all log optimization settings? (y/N): " confirm
    [[ $confirm =~ ^[Yy]$ ]] || {
        log_warn "Operation cancelled"
        return
    }
    
    # # Remove cron jobs
    # (crontab -l 2>/dev/null | grep -v -E "journal|vacuum|log" | crontab -) 2>/dev/null
    # log_ok "Log cleanup cron jobs removed"
    
    # Restore default journald config
    local journald_conf="/etc/systemd/journald.conf"
    if [[ -f "${journald_conf}.original" ]]; then
        cp "${journald_conf}.original" "$journald_conf"
        log_ok "Original journald configuration restored"
    else
        log_warn "No original backup found, keeping current configuration"
    fi
    
    systemctl restart systemd-journald
    log_ok "Journald service restarted with default settings"
}

###### Timezone Configuration ######
#######################################

configure_timezone() {
    section_title "Timezone Configuration"
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Unknown")
    echo -e "Current timezone: ${CYAN}${current_tz}${RESET}"
    echo -e "${BOLD}Available timezones:${RESET}"
    
    local timezones=(
        "Asia/Shanghai" "Asia/Tokyo" "Asia/Singapore" 
        "UTC" "Europe/London" "America/New_York" "Custom input"
    )
    
    for i in "${!timezones[@]}"; do
        echo "   $((i+1))) ${timezones[$i]}"
    done
    echo "   0) Cancel"
    echo
    
    read -rp "   Choose option [0-7]: " tz_choice
    case $tz_choice in
        [1-6]) local new_tz="${timezones[$((tz_choice-1))]}" ;;
        7) read -rp "Enter timezone: " new_tz; [[ -z "$new_tz" ]] && { log_warn "No timezone entered"; return; } ;;
        0) log_warn "Timezone change cancelled"; return ;;
        *) log_warn "Invalid choice"; return ;;
    esac
    
    timedatectl set-timezone "$new_tz" 2>/dev/null && \
        log_ok "Timezone set to: $(timedatectl show --property=Timezone --value)" || \
        log_error "Failed to set timezone: $new_tz"
    pause
}

###### Package Management ######
#######################################

install_packages() {
    section_title "Package Installation"
	echo
    # echo -e "${BOLD}Select packages to install:${RESET}"
    echo "   1) Essential tools (curl, wget, nano, htop, vnstat)"
    echo "   2) Development tools (git, unzip, screen)"
    echo "   3) Network tools (speedtest-cli, traceroute, ethtool, net-tools)"
    echo "   4) All recommended packages"
    echo "   5) Custom selection"
    echo "   0) Cancel"
    echo
    
    read -rp "   Choose option [0-5]: " pkg_choice
    case $pkg_choice in
        1) local packages=("curl" "wget" "nano" "htop" "vnstat") ;;
        2) local packages=("git" "unzip" "screen") ;;
        3) local packages=("${NETWORK_PACKAGES[@]}") ;;
        4) local packages=("${BASE_PACKAGES[@]}") ;;
        5) echo "Enter package names separated by spaces:"; read -r -a packages ;;
        0) log_warn "Package installation cancelled"; return ;;
        *) log_warn "Invalid choice"; return ;;
    esac
    
    [[ ${#packages[@]} -eq 0 ]] && { log_warn "No packages selected"; return; }
    
    echo -e "Packages to install: ${CYAN}${packages[*]}${RESET}"
    read -rp "Proceed with installation? (y/N): " confirm
    [[ $confirm =~ ^[Yy]$ ]] || { log_warn "Installation cancelled"; return; }
    
    log_info "Updating package lists..."
    apt update -y || { log_error "Failed to update package lists"; return; }
    
    log_info "Installing packages..."
    apt install -y "${packages[@]}" && log_ok "Packages installed successfully" || log_error "Some packages failed to install"
    pause
}

###### Quick Setup ######
#######################################

quick_setup() {
    section_title "Quick Server Setup"
    echo -e "${BOLD}${GREEN}This will perform the following actions:${RESET}"
    echo "  ✅ Clean up existing swap files/partitions"
    echo "  ✅ Auto-configure optimal swap (if needed)"
    echo "  ✅ Set timezone to Asia/Shanghai" 
    echo "  ✅ Install essential packages"
    echo "  ✅ Apply network optimization (BBR/BBR2)"
    echo -e "${YELLOW}Note: This is recommended for new servers${RESET}"
    echo
    
    read -rp "Proceed with quick setup? (y/N): " confirm
    [[ $confirm =~ ^[Yy]$ ]] || { log_warn "Quick setup cancelled"; return; }
    
    # Swap configuration
    sub_section "Step 1: Swap Configuration"
    cleanup_existing_swap
    local recommended=$(recommended_swap_mb)
    [[ $recommended -gt 0 ]] && setup_swap $recommended || log_ok "No swap configuration needed"
    
    # Timezone
    sub_section "Step 2: Timezone Configuration"
    timedatectl set-timezone "$DEFAULT_TIMEZONE" 2>/dev/null && \
        log_ok "Timezone set to: $(timedatectl show --property=Timezone --value)" || \
        log_warn "Failed to set timezone"
    
    # Packages
    sub_section "Step 3: Package Installation"
    apt update -y && apt install -y "${BASE_PACKAGES[@]}" && \
        log_ok "Packages installed successfully" || \
        log_warn "Some packages failed to install"
    
    # Network Optimization
    sub_section "Step 4: Network Optimization"
    apply_network_optimization
	
	# Step 5: System Logs Optimization
    sub_section "Step 5: System Logs Optimization"
    optimize_system_logs
    
    log_ok "🎉 Quick setup completed successfully!"
    echo -e "${GREEN}Your server is now optimized and ready for use.${RESET}"
    pause
}

###### Main Menu ######
#######################################

main_menu() {
    while true; do
        banner
		display_system_status
		echo
		echo -e "${BOLD}${MAGENTA}🏠 MAIN MENU${RESET}"
		echo
        echo -e "   1) ${ORANGE}Quick Setup${RESET} (Recommended for new servers)"
        echo -e "   2) ${GREEN}Timezone Configuration${RESET}" 
        echo -e "   3) ${YELLOW}Install Essential Software${RESET}"
        echo -e "   4) ${CYAN}System Swap Management${RESET}"
        echo -e "   5) ${BLUE}Network Optimization${RESET}"
		echo -e "   6) ${PURPLE}Logs Optimization${RESET}"
        echo -e "   0) ${RED}Exit${RESET}"
        echo
        
        read -rp "   Choose option [1-6]: " choice
        case $choice in
            1) quick_setup ;;
            2) configure_timezone ;;
            3) install_packages ;;
            4) swap_management_menu ;;
            5) network_tools_menu ;;
			6) logs_optimization_menu ;;
            0)
                echo
                log_ok "   Thank you for using Server Setup Essentials! 👋"
                echo -e "${GREEN}Log file: ${LOG_FILE}${RESET}"
                exit 0
                ;;
            *) log_warn "Invalid choice"; pause ;;
        esac
    done
}

###### Main Execution ######
#######################################

main() {
    require_root
    trap 'echo; log_error "Script interrupted"; exit 1' INT TERM
    
    echo "=== Server Setup Essentials $VERSION - $(date) ===" > "$LOG_FILE"
    
    if ! [[ -f /etc/debian_version ]]; then
        log_warn "This script is optimized for Debian-based systems"
        read -rp "Continue anyway? (y/N): " proceed
        [[ $proceed =~ ^[Yy]$ ]] || exit 1
    fi
    
    main_menu
}

main "$@"

#!/usr/bin/env bash
#
# Server Setup Essentials - Enhanced Version
# - Interactive menu with beautiful dashboard
# - Network diagnostics and optimization tools
# - Safe swap management with intelligent detection
# - Timezone configuration
# - Software installation (multi-select)
# - Comprehensive network optimization

VERSION="v2.3.6"
set -euo pipefail

###### Colors and Styles ######
###############################################

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
###############################################

readonly SWAPFILE="/swapfile"
readonly MIN_SAFE_RAM_MB=100
readonly DEFAULT_TIMEZONE="Asia/Shanghai"
readonly BASE_PACKAGES=("curl" "wget" "nano" "htop" "vnstat" "git" "unzip" "screen" "speedtest-cli" "traceroute" "ethtool")
readonly NETWORK_PACKAGES=("speedtest-cli" "traceroute" "ethtool" "net-tools" "dnsutils" "iptables-persistent")
readonly LOG_FILE="/root/server-setup-$(date +%Y%m%d-%H%M%S).log"
readonly LOG_OPTIMIZATION_PACKAGES=("cron" "logrotate")

###### Logging Functions ######
###############################################

log_info()  { echo -e "${CYAN}${BOLD}[INFO]${RESET} ${CYAN}$*${RESET}" | tee -a "$LOG_FILE"; }
log_ok()    { echo -e "${GREEN}${BOLD}[OK]${RESET} ${GREEN}$*${RESET}" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}${BOLD}[WARN]${RESET} ${YELLOW}$*${RESET}" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}${BOLD}[ERROR]${RESET} ${RED}$*${RESET}" | tee -a "$LOG_FILE"; }

###### Utility Functions ######
###############################################

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
###############################################

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
            
            printf "${YELLOW}%-14s${RESET} %-9s %-9s ${GREEN}%-9s${RESET} ${CYAN}%-9s${RESET} ${MAGENTA}%-9s${RESET}\n" \
                "" "iface" "Duration" "RX/UL" "TX/DL" "Total"
            printf "${YELLOW}%-14s${RESET} %-9s %-9s %-9s %-9s %-9s\n" \
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
            printf "  %-12s %-9s %-9s %-9s %-9s %-9s\n", "Server", iface, boot_days, human(rx), human(tx), human(total)
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
###############################################

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
###############################################

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

network_system_info() {
    banner
    section_title "System & Network Overview"
    display_system_status
    pause
}

network_tools_menu() {
    while true; do        
        section_title "Network Tools & Optimization"
        # echo -e "${BOLD}${CYAN}Available Network Actions:${RESET}"
		echo
        echo "   1) Run Network Diagnostics"
        echo "   2) Apply Network Optimization (BBR/BBR2)"
        echo "   3) Restore Network Settings"
        echo "   4) Install Network Tools"
        echo "   5) Show detailed system & network info"
        echo "   0) Back to Main Menu"
        echo
        
        read -rp "   Choose option [1-6]: " choice
        case $choice in
            1) network_diagnostics; pause ;;
            2) apply_network_optimization; pause ;;
            3) restore_network_settings; pause ;;
            4) install_network_tools; pause ;;
            5) network_system_info; pause ;;
            0) return ;;
            *) log_warn "Invalid choice"; pause ;;
        esac
    done
}

###### Optimize System Logs ######
###############################################

optimize_system_logs() {
    section_title "System Logs Optimization"
    
    echo -e "${BOLD}${GREEN}This will optimize system journal logs and rotation:${RESET}"
    echo "  ✅ Configure journald limits (optimize-Journal v02.conf)"
    echo "  ✅ Set up log rotation and cleanup cron jobs"
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
    
    # Set up cron job for regular cleanup
    sub_section "Step 5: Setting Up Automatic Cleanup"
    if setup_log_cleanup_cron; then
        log_ok "Automatic log cleanup scheduling completed"
    else
        log_warn "Cron job setup failed - please configure manually"
        echo -e "${YELLOW}Manual command to add to crontab (crontab -e):${RESET}"
        echo -e "${CYAN}0 2 * * * /usr/bin/journalctl --vacuum-size=100M --vacuum-time=7days >/dev/null 2>&1${RESET}"
    fi
    
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
    
    echo
    log_info "Current cron jobs for log cleanup:"
    crontab -l 2>/dev/null | grep -E "journal|vacuum|log" || echo "No log cleanup cron jobs found"
    
    echo
    log_ok "🎉 System logs optimization completed successfully!"
    echo -e "${GREEN}Journal logs are now optimized with proper limits and automatic cleanup.${RESET}"
}

###### Advanced System Logs Optimization ######
#######################################
advanced_logs_optimization() {
    while true; do
        section_title "Advanced System Logs Optimization"
        
        # echo -e "${BOLD}${CYAN}Log Optimization Categories:${RESET}"
		echo
        echo "   1) Journal Configuration & Limits"
        echo "   2) Immediate Log Cleanup"
        echo "   3) Automated Cleanup Scheduling"
        echo "   4) System Status & Information"
        echo "   5) Reset & Removal"
        echo "   0) ↩️  Back to Main Menu"
        echo
        
        read -rp "   Choose category [1-6]: " category_choice
        
        case $category_choice in
            1)	journal_configuration_menu ;;
            2)	immediate_cleanup_menu ;;
            3)  automated_scheduling_menu ;;
            4)  system_status_menu ;;
            5)  reset_removal_menu ;;
            0)  return ;;
            *)  log_warn "Invalid choice"
                pause ;;
        esac
    done
}

###### Journal Configuration Sub-Menu ######
#######################################
journal_configuration_menu() {
    while true; do
        section_title "Logs Optimization > Journal Configuration & Limits"        
        # echo -e "${BOLD}${CYAN}Journal Configuration Options:${RESET}"
		echo
        echo "   1) Apply Basic Journal Optimization (Recommended)"
        echo "   2) Set Custom Journal Limits"
        echo "   3) View Current Journal Settings"
        echo "   0) Back to Log Optimization Menu"
        echo
        
        read -rp "   Choose option [1-4]: " choice
        
        case $choice in
            1)  optimize_system_logs ;;
            2)  set_custom_journal_limits ;;
            3)  echo -e "\n${GREEN}Current Journal Configuration:${RESET}"
                grep -E "^(SystemMaxUse|RuntimeMaxUse|SystemMaxFileSize|MaxRetentionSec)=" /etc/systemd/journald.conf 2>/dev/null || echo "Using default settings"
                pause ;;
            0) return ;;
            *)  log_warn "Invalid choice" ;;
        esac
    done
}

###### Immediate Cleanup Sub-Menu ######
#######################################
immediate_cleanup_menu() {
    while true; do
        section_title "Logs Optimization > Immediate Log Cleanup"        
        # echo -e "${BOLD}${CYAN}Immediate Cleanup Options:${RESET}"
		echo
        echo "   1) Vacuum to 50M Size Limit"
        echo "   2) Vacuum Logs Older Than 7 Days"
        echo "   3) Vacuum Both Size and Time"
        echo "   4) Custom Vacuum Parameters"
        echo "   5) View Current Log Usage"
        echo "   0) Back to Log Optimization Menu"
        echo
        
        read -rp "   Choose option [1-6]: " choice
        
        case $choice in
            1)  vacuum_logs_only ;;
            2)  echo -e "\n${CYAN}Vacuuming logs older than 7 days...${RESET}"
                journalctl --vacuum-time=7days 2>/dev/null && log_ok "Logs older than 7 days removed" || log_error "Failed to vacuum logs"
                pause ;;
            3)  echo -e "\n${CYAN}Vacuuming logs by size and time...${RESET}"
                journalctl --vacuum-size=50M --vacuum-time=7days 2>/dev/null && log_ok "Logs vacuumed successfully" || log_error "Failed to vacuum logs"
                pause ;;
            4)  custom_vacuum_parameters ;;
            5)  view_log_usage ;;
            0)  return ;;
            *)  log_warn "Invalid choice" ;;
        esac
    done
}

###### Automated Scheduling Sub-Menu ######
#######################################
automated_scheduling_menu() {
    while true; do
        # section_title "Logs Optimization > Automated Cleanup Scheduling"
        echo
        echo -e "${BOLD}${CYAN}Cron Job Management Options:${RESET}"
        echo "   1) Add/Update Default Log Cleanup Cron Job"
        echo "   2) Add Custom Log Cleanup Cron Job"
        echo "   3) View Current Cron Jobs"
        echo "   4) Test Cron Job Execution"
        echo "   5) Remove All Log Cleanup Cron Jobs"
        echo "   0) Back to Log Optimization Menu"
        echo
        
        read -rp "   Choose option [1-6]: " choice
        
        case $choice in
            1)  add_default_log_cron ;;
            2)  add_custom_log_cron ;;
            3)  show_current_cron_jobs detailed
                pause ;;
            4)  test_cron_execution ;;
            5)  remove_log_cron_jobs ;;
            0)  return ;;
            *)  log_warn "Invalid choice" ;;
        esac
    done
}

###### System Status Sub-Menu ######
#######################################
system_status_menu() {
    section_title "Logs Optimization > System Status & Information"
    
    echo -e "${GREEN}Journal Disk Usage:${RESET}"
    journalctl --disk-usage
    
    echo -e "\n${GREEN}Current Journal Configuration:${RESET}"
    grep -E "^(SystemMaxUse|RuntimeMaxUse|SystemMaxFileSize|MaxRetentionSec)=" /etc/systemd/journald.conf 2>/dev/null || echo "Using default settings"
    
    echo -e "\n${GREEN}Largest Journal Files:${RESET}"
    find /var/log/journal -name "*.journal" -exec du -h {} \; 2>/dev/null | sort -hr | head -5
    
    echo -e "\n${GREEN}Log Cleanup Cron Jobs:${RESET}"
    crontab -l 2>/dev/null | grep -E "journal|vacuum|log" || echo "No log cleanup cron jobs configured"
    
    echo -e "\n${GREEN}System Log Files Size:${RESET}"
    ls -lah /var/log/*.log 2>/dev/null | head -10 | awk '{print $5, $9}'
    
    pause
}

###### Reset & Removal Sub-Menu ######
#######################################
reset_removal_menu() {
    while true; do
        section_title "Logs Optimization > Reset & Removal Options"        
        # echo -e "${BOLD}${CYAN}Reset & Removal Options:${RESET}"
		echo	
        echo "   1) Remove All Log Optimization Settings"
        echo "   2) Remove Only Cron Jobs (Keep Journal Settings)"
        echo "   3) Reset Journal to Default Settings"
        echo "   4) View What Will Be Removed"
        echo "   0) Back to Log Optimization Menu"
        echo
        
        read -rp "   Choose option [1-5]: " choice
        
        case $choice in
            1)	remove_log_optimization ;;
            2)	remove_log_cron_jobs ;;
            3)	reset_journal_settings ;;
            4)	show_removal_preview ;;
            0)	return;;
            *)	log_warn "Invalid choice" ;;
        esac
    done
}

###### Additional Helper Functions ######
#######################################
reset_journal_settings() {
    section_title "Reset Journal to Default Settings"
    
    read -rp "Reset journald to default settings? This will remove all custom limits. (y/N): " confirm
    [[ $confirm =~ ^[Yy]$ ]] || {
        log_warn "Operation cancelled"
        return
    }
    
    local journald_conf="/etc/systemd/journald.conf"
    
    # Create a minimal default config
    cat <<EOF > "$journald_conf"
[Journal]
# Default settings - minimal configuration
Storage=auto
Compress=yes
EOF
    
    systemctl restart systemd-journald
    log_ok "Journald settings reset to defaults"
}

show_removal_preview() {
    section_title "Removal Preview"
    
    echo -e "${YELLOW}The following items would be removed:${RESET}"
    echo
    
    # Check journal settings
    local custom_settings=$(grep -E "^(SystemMaxUse|RuntimeMaxUse|SystemMaxFileSize|MaxRetentionSec)=" /etc/systemd/journald.conf 2>/dev/null)
    if [[ -n "$custom_settings" ]]; then
        echo -e "${RED}• Custom Journal Settings:${RESET}"
        echo "$custom_settings"
    else
        echo -e "${GREEN}• No custom journal settings found${RESET}"
    fi
    
    # Check cron jobs
    local cron_jobs=$(crontab -l 2>/dev/null | grep -E "journal|vacuum|log")
    if [[ -n "$cron_jobs" ]]; then
        echo -e "\n${RED}• Log Cleanup Cron Jobs:${RESET}"
        echo "$cron_jobs"
    else
        echo -e "\n${GREEN}• No log cleanup cron jobs found${RESET}"
    fi
    
    echo
    echo -e "${YELLOW}Use options 1-3 in the previous menu to remove specific items.${RESET}"
    pause
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
        1)  echo -e "\n${CYAN}Vacuuming logs to 50MB size limit...${RESET}"
            if journalctl --vacuum-size=50M 2>/dev/null; then
                show_vacuum_results "$before_usage" "$before_size"
                log_ok "Logs vacuumed to 50MB limit"
            else
                log_error "Failed to vacuum logs"
            fi
            ;;
        2)  echo -e "\n${CYAN}Vacuuming logs older than 7 days...${RESET}"
            if journalctl --vacuum-time=7days 2>/dev/null; then
                show_vacuum_results "$before_usage" "$before_size"
                log_ok "Logs older than 7 days removed"
            else
                log_error "Failed to vacuum logs"
            fi
            ;;
        3)  echo -e "\n${CYAN}Vacuuming logs by size and time...${RESET}"
            if journalctl --vacuum-size=50M --vacuum-time=7days 2>/dev/null; then
                show_vacuum_results "$before_usage" "$before_size"
                log_ok "Logs vacuumed by both size and time"
            else
                log_error "Failed to vacuum logs"
            fi
            ;;
        4)  custom_vacuum_parameters "$before_usage" "$before_size"
            ;;
        0)  log_warn "Vacuum operation cancelled"
            ;;
        *)  log_warn "Invalid choice"
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
    
    echo -e "\n${GREEN}Largest Journal Files:${RESET}"
    find /var/log/journal -name "*.journal" -exec du -h {} \; 2>/dev/null | sort -hr | head -10
    
    echo -e "\n${GREEN}Current Journal Configuration:${RESET}"
    grep -E "^(SystemMaxUse|RuntimeMaxUse|SystemMaxFileSize|MaxRetentionSec)=" /etc/systemd/journald.conf 2>/dev/null || echo "Using default settings"
    
    echo -e "\n${GREEN}Log Cleanup Cron Jobs:${RESET}"
    crontab -l 2>/dev/null | grep -E "journal|vacuum|log" || echo "No log cleanup cron jobs configured"
}

remove_log_optimization() {
    section_title "Remove Log Optimization"
    
    read -rp "Remove all log optimization settings? (y/N): " confirm
    [[ $confirm =~ ^[Yy]$ ]] || {
        log_warn "Operation cancelled"
        return
    }
    
    # Remove cron jobs
    (crontab -l 2>/dev/null | grep -v -E "journal|vacuum|log" | crontab -) 2>/dev/null
    log_ok "Log cleanup cron jobs removed"
    
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


###### Complete Fixed Cron Job Management ######
###############################################

# Safe crontab management
safe_crontab() {
    local action="$1"
    local content="$2"
    
    case "$action" in
        "get")
            crontab -l 2>/dev/null || echo ""
            ;;
        "set")
            echo "$content" | crontab - 2>/dev/null
            return $?
            ;;
        "add")
            local current=$(crontab -l 2>/dev/null || echo "")
            printf "%s\n%s" "$current" "$content" | crontab - 2>/dev/null
            return $?
            ;;
    esac
}

# Add cron job with duplicate prevention
add_cron_job() {
    local new_job="$1"
    local description="$2"
    
    log_info "Adding cron job: $description"
    
    # Check if job already exists
    if safe_crontab "get" | grep -F "$new_job" >/dev/null; then
        log_ok "Cron job already exists"
        return 0
    fi
    
    # Add the new job
    if safe_crontab "add" "$new_job"; then
        # Verify it was added
        if safe_crontab "get" | grep -F "$new_job" >/dev/null; then
            log_ok "Cron job added successfully: $description"
            return 0
        else
            log_error "Failed to verify cron job addition"
            return 1
        fi
    else
        log_error "Failed to add cron job"
        return 1
    fi
}

# Remove cron jobs by pattern
remove_cron_jobs() {
    local pattern="$1"
    local description="$2"
    
    log_info "Removing cron jobs: $description"
    
    local current_crontab=$(safe_crontab "get")
    local new_crontab=$(echo "$current_crontab" | grep -v "$pattern" || true)
    
    if [[ "$current_crontab" != "$new_crontab" ]]; then
        if safe_crontab "set" "$new_crontab"; then
            log_ok "Cron jobs removed successfully: $description"
            return 0
        else
            log_error "Failed to remove cron jobs"
            return 1
        fi
    else
        log_ok "No matching cron jobs found to remove"
        return 0
    fi
}

# Test if cron system is working
test_cron_system() {
    log_info "Testing cron system..."
    
    # Test basic cron functionality
    if ! command -v crontab >/dev/null 2>&1; then
        log_error "crontab command not found. Install cron package first."
        return 1
    fi
    
    # Test if we can read/write crontab
    local test_job="# TEST $(date +%s)"
    if safe_crontab "add" "$test_job" 2>/dev/null; then
        # Clean up test job
        remove_cron_jobs "$test_job" "test job"
        log_ok "Cron system is working properly"
        return 0
    else
        log_error "Cron system is not accessible. Check permissions."
        return 1
    fi
}

# Show current cron jobs - FIXED VERSION
show_current_cron_jobs() {
    local detail_level="${1:-simple}"  # Default to simple if no parameter
    
    local cron_jobs=$(safe_crontab "get" | grep -E "journal|vacuum|log")
    
    if [[ -z "$cron_jobs" ]]; then
        echo -e "  ${YELLOW}No log cleanup cron jobs configured${RESET}"
        return
    fi
    
    if [[ "$detail_level" == "detailed" ]]; then
        echo -e "${GREEN}Detailed Cron Job Information:${RESET}"
        echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${RESET}"
        safe_crontab "get" | grep -E "journal|vacuum|log" | while IFS= read -r job; do
            printf "${CYAN}║${RESET} ${YELLOW}%-60s${RESET} ${CYAN}║${RESET}\n" "  $job"
        done
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${RESET}"
    else
        echo -e "${CYAN}Current cron jobs:${RESET}"
        echo "$cron_jobs" | while IFS= read -r job; do
            echo -e "  ${GREEN}•${RESET} $job"
        done
    fi
    echo
}

# Setup log cleanup cron
setup_log_cleanup_cron() {
    sub_section "Setting Up Automatic Log Cleanup"
    
    # Test cron system first
    if ! test_cron_system; then
        log_warn "Please install cron package: apt update && apt install -y cron"
        return 1
    fi
    
    local cron_job="0 2 * * * /usr/bin/journalctl --vacuum-size=100M --vacuum-time=7days >/dev/null 2>&1"
    local description="Daily log cleanup at 2 AM"
    
    # Remove any existing log cleanup jobs first
    remove_cron_jobs "journalctl --vacuum" "existing log cleanup jobs"
    
    # Add the new job
    if add_cron_job "$cron_job" "$description"; then
        echo -e "${GREEN}✓ Schedule:${RESET} Daily at 2:00 AM"
        echo -e "${GREEN}✓ Action:${RESET} Vacuum logs to 100MB, keep 7 days"
        echo -e "${GREEN}✓ Command:${RESET} journalctl --vacuum-size=100M --vacuum-time=7days"
        return 0
    else
        log_error "Failed to setup log cleanup cron job"
        return 1
    fi
}

# Default log cron
add_default_log_cron() {
    section_title "Add Default Log Cleanup Cron Job"
    
    echo -e "${YELLOW}Default cron job will run daily at 2:00 AM and vacuum logs to 100MB, keeping 7 days${RESET}"
    echo -e "${CYAN}Command: journalctl --vacuum-size=100M --vacuum-time=7days${RESET}"
    echo
    
    read -rp "Proceed with adding default cron job? (y/N): " confirm
    [[ $confirm =~ ^[Yy]$ ]] || {
        log_warn "Operation cancelled"
        return
    }
    
    if setup_log_cleanup_cron; then
        log_ok "Default log cleanup cron job configured successfully"
    else
        log_error "Failed to configure default cron job"
    fi
}

# Custom log cron
add_custom_log_cron() {
    section_title "Add Custom Log Cleanup Cron Job"
    
    echo -e "${YELLOW}Customize your log cleanup cron job:${RESET}"
    echo
    
    # Schedule selection
    echo -e "${CYAN}Schedule Frequency:${RESET}"
    echo "1) Daily at 2:00 AM (Recommended)"
    echo "2) Daily at custom time"
    echo "3) Weekly (Sunday 2:00 AM)"
    echo "4) Monthly (1st day 2:00 AM)"
    echo "5) Custom cron schedule"
    echo
    
    read -rp "Choose schedule [1-5]: " schedule_choice
    
    local cron_schedule=""
    case $schedule_choice in
        1) cron_schedule="0 2 * * *" ;;
        2)  
            read -rp "Enter hour (0-23): " custom_hour
            [[ $custom_hour =~ ^[0-9]+$ ]] && [[ $custom_hour -ge 0 ]] && [[ $custom_hour -le 23 ]] || {
                log_error "Invalid hour, using default 2 AM"
                custom_hour="2"
            }
            cron_schedule="0 $custom_hour * * *"
            ;;
        3) cron_schedule="0 2 * * 0" ;;
        4) cron_schedule="0 2 1 * *" ;;
        5)  
            echo -e "${YELLOW}Enter custom cron schedule (min hour day month weekday):${RESET}"
            echo -e "${CYAN}Examples:${RESET}"
            echo "  '0 2 * * *'    - Daily at 2:00 AM"
            echo "  '0 0 * * 0'    - Weekly on Sunday"
            echo "  '0 0 1 * *'    - Monthly on 1st day"
            echo "  '*/30 * * * *' - Every 30 minutes"
            echo
            read -rp "Cron schedule: " cron_schedule
            ;;
        *)  
            log_warn "Invalid choice, using default schedule"
            cron_schedule="0 2 * * *"
            ;;
    esac
    
    # Vacuum parameters
    echo
    echo -e "${CYAN}Vacuum Parameters:${RESET}"
    read -rp "Size limit (e.g., 100M, 1G) [default: 100M]: " vacuum_size
    read -rp "Time limit (e.g., 7days, 1month) [default: 7days]: " vacuum_time
    
    vacuum_size=${vacuum_size:-"100M"}
    vacuum_time=${vacuum_time:-"7days"}
    
    # Build cron command
    local cron_command="/usr/bin/journalctl --vacuum-size=$vacuum_size --vacuum-time=$vacuum_time >/dev/null 2>&1"
    local full_cron_job="$cron_schedule $cron_command"
    
    # Show summary and confirm
    echo
    echo -e "${GREEN}Cron Job Summary:${RESET}"
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${RESET}"
    printf "${CYAN}║${RESET} ${YELLOW}%-15s${RESET} ${GREEN}%s${RESET} %30s ${CYAN}║${RESET}\n" "Schedule:" "$cron_schedule" ""
    printf "${CYAN}║${RESET} ${YELLOW}%-15s${RESET} ${GREEN}%s${RESET} %30s ${CYAN}║${RESET}\n" "Size limit:" "$vacuum_size" ""
    printf "${CYAN}║${RESET} ${YELLOW}%-15s${RESET} ${GREEN}%s${RESET} %30s ${CYAN}║${RESET}\n" "Time limit:" "$vacuum_time" ""
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════╣${RESET}"
    printf "${CYAN}║${RESET} ${MAGENTA}%-60s${RESET} ${CYAN}║${RESET}\n" "Command: $cron_command"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${RESET}"
    echo
    
    read -rp "Add this cron job? (y/N): " confirm
    [[ $confirm =~ ^[Yy]$ ]] || {
        log_warn "Operation cancelled"
        return
    }
    
    # Remove existing similar cron jobs
    remove_cron_jobs "journalctl --vacuum" "existing log cleanup jobs"
    
    # Add new cron job
    if add_cron_job "$full_cron_job" "custom log cleanup"; then
        log_ok "Custom log cleanup cron job added successfully"
    else
        log_error "Failed to add custom cron job"
    fi
}

# Remove all log cron jobs
remove_all_log_cron_jobs() {
    section_title "Remove All Log Cleanup Cron Jobs"
    
    read -rp "Remove all log cleanup cron jobs? (y/N): " confirm
    [[ $confirm =~ ^[Yy]$ ]] || {
        log_warn "Operation cancelled"
        return
    }
    
    if remove_cron_jobs "journal|vacuum|log" "all log cleanup jobs"; then
        log_ok "All log cleanup cron jobs removed successfully"
    else
        log_error "Failed to remove cron jobs"
    fi
}

# Test cron execution
test_cron_execution() {
    section_title "Test Cron Job Execution"
    
    echo -e "${YELLOW}This will execute the log cleanup command now to test it:${RESET}"
    echo
    
    local cron_jobs=$(safe_crontab "get" | grep -E "journal|vacuum|log" | head -1)
    
    if [[ -z "$cron_jobs" ]]; then
        log_error "No log cleanup cron jobs found to test"
        return
    fi
    
    # Extract the command part (remove schedule)
    local test_command=$(echo "$cron_jobs" | sed 's/^[^ ]* [^ ]* [^ ]* [^ ]* [^ ]* //')
    
    echo -e "${CYAN}Found cron job:${RESET}"
    echo -e "  ${GREEN}Schedule:${RESET} $(echo "$cron_jobs" | awk '{print $1, $2, $3, $4, $5}')"
    echo -e "  ${GREEN}Command:${RESET} $test_command"
    echo
    
    read -rp "Execute this command now? (y/N): " confirm
    [[ $confirm =~ ^[Yy]$ ]] || {
        log_warn "Test cancelled"
        return
    }
    
    echo -e "\n${CYAN}Executing test command...${RESET}"
    
    # Show before state
    local before_usage=$(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]\+[A-Z]' | head -1)
    echo -e "${GREEN}Before:${RESET} $before_usage"
    
    # Execute the command
    if eval "$test_command" 2>/dev/null; then
        # Show after state
        local after_usage=$(journalctl --disk-usage 2>/dev/null | grep -o '[0-9.]\+[A-Z]' | head -1)
        echo -e "${GREEN}After:${RESET} $after_usage"
        
        if [[ "$before_usage" != "$after_usage" ]]; then
            local saved=$(calculate_savings "$before_usage" "$after_usage")
            echo -e "${GREEN}Space saved:${RESET} $saved"
        fi
        
        log_ok "Cron job test executed successfully"
    else
        log_error "Cron job test failed"
    fi
}

###### Updated Automated Scheduling Sub-Menu ######
###################################################

automated_scheduling_menu() {
    while true; do
        section_title "Automated Cleanup Scheduling"        
        # echo -e "${BOLD}${CYAN}Cron Job Management Options:${RESET}"
		echo
        echo "   1) Add/Update Default Log Cleanup Cron Job"
        echo "   2) Add Custom Log Cleanup Cron Job"
        echo "   3) View Current Cron Jobs"
        echo "   4) Test Cron Job Execution"
        echo "   5) Remove All Log Cleanup Cron Jobs"
        echo "   0) Back to Log Optimization Menu"
        echo
        
        read -rp "   Choose option [1-6]: " choice
        
        case $choice in
            1)  add_default_log_cron 
                pause ;;
            2)  add_custom_log_cron 
                pause ;;
            3)  show_current_cron_jobs "detailed"
                pause ;;
            4)  test_cron_execution 
                pause ;;
            5)  remove_all_log_cron_jobs 
                pause ;;
            0)  return ;;
            *)  log_warn "Invalid choice" 
                pause ;;
        esac
    done
}

###### Swap Management Menu ######
###############################################

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
        
        read -rp "   Choose option [1-5]: " choice
        case $choice in
            1)      local recommended=$(recommended_swap_mb)      [[ $recommended -gt 0 ]] && setup_swap $recommended || log_ok "System has sufficient RAM - no swap recommended"
                pause
                ;;
            2)      read -rp "Enter swap size in MB: " custom_size
                [[ $custom_size =~ ^[0-9]+$ ]] && [[ $custom_size -gt 0 ]] && setup_swap $custom_size || log_error "Invalid size entered"
                pause
                ;;
            3)      log_info "Starting fresh swap configuration..."
                cleanup_existing_swap
                log_ok "System is now clean. Use option 1 or 2 to configure new swap."
                pause
                ;;
            4)      echo -e "${BOLD}Swap Details:${RESET}"
                free -h; echo; swapon --show 2>/dev/null || log_info "No swap files active"; echo
                pause
                ;;
            0) return ;;
            *) log_warn "Invalid choice"; pause ;;
        esac
    done
}

###### Timezone Configuration ######
###############################################

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
    
    read -rp "   Choose option [1-8]: " tz_choice
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
    
    read -rp "   Choose option [1-6]: " pkg_choice
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
    
    read -rp "   Proceed with quick setup? (y/N): " confirm
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
        echo -e "   1) ${CYAN}System Swap Management${RESET}"
        echo -e "   2) ${GREEN}Timezone Configuration${RESET}" 
        echo -e "   3) ${YELLOW}Install Essential Software${RESET}"
        echo -e "   4) ${BLUE}Network Diagnostics & Optimization${RESET}"
        echo -e "   5) ${ORANGE}Quick Setup${RESET} (Recommended for new servers)"
		echo -e "   6) ${PURPLE}System Logs Optimization${RESET}"
        echo -e "   0) ${RED}Exit${RESET}"
        echo
        
        read -rp "   Choose option [1-6]: " choice
        case $choice in
            1) swap_management_menu ;;
            2) configure_timezone ;;
            3) install_packages ;;
            4) network_tools_menu ;;
            5) quick_setup ;;
			6) advanced_logs_optimization ;;
            0)
                echo
                log_ok "Thank you for using Server Setup Essentials! 👋"
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

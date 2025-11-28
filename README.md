# Server Setup Essentials

An interactive Bash toolkit to quickly prepare a fresh Linux server (Debian/Ubuntu), with:

- ✅ Safe **swap management** (auto / set / increase / decrease)
- ✅ Interactive **timezone selection**
- ✅ **Software installer** (multi-select via comma-separated choices)
- ✅ **Proxy tools** menu (includes V2bX installer - wyx2685)
- ✅ One-click **Default Setup** (auto swap + base tools + timezone)

Perfect for new VPS / nodes running things like sing-box, XrayR, V2bX, etc.

---

## Features

### 🧠 Smart & Safe Swap Management

- Detects RAM and suggests recommended swap:
  - ≤ 1 GB RAM → 2 GB swap
  - ≤ 2 GB RAM → 2 GB swap
  - ≤ 4 GB RAM → 1 GB swap
- Modes:
  - Auto configure
  - Set exact size (MB)
  - Increase / decrease by MB
  - Show memory & swap status
- Uses a **safe swap migration strategy**:
  1. Create new swapfile
  2. Enable it
  3. Disable & remove old swapfile
  4. Update `/etc/fstab`
- Includes a **memory safety check** before changing swap.

---

### 🌏 Timezone Configuration

Interactive menu:

- Asia/Shanghai  
- Asia/Tokyo  
- Asia/Hong_Kong  
- Asia/Singapore  
- UTC  
- Custom (manual input)

Uses `timedatectl set-timezone` under the hood.

---

### 📦 Software Installer (multi-select)

From the menu you can install:

- nano  
- vnstat  
- curl  
- wget  
- htop  
- git  
- unzip  
- screen  

Selection is via **comma-separated** options, e.g.:

`1,2,5`

The script will:

- Run `apt update`
- Install all chosen packages

---

### 🚀 Proxy Tools Menu

Currently includes:

- **Install V2bX (wyx2685)**  
  Uses:

  ```bash
  wget -N https://raw.githubusercontent.com/wyx2685/V2bX-script/master/install.sh && bash install.sh

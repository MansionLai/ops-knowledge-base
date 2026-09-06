# Linux Guest 診斷 SOP

在 KubeVirt 環境中，維運團隊無法直接登入使用者 VM，當 user 回報異常時，請依下列 SOP 引導使用者執行診斷腳本，收集後回傳分析。

---

## 腳本說明

| 腳本 | 用途 | 使用時機 |
| :--- | :--- | :--- |
| `linux-diag.sh` | 全面收集系統狀態（dmesg、OOM Killer、行程、網路、磁碟、安全性等） | 任何異常，或 user 當下仍有問題時 |

腳本輸出結構：
```
vm_diag_<hostname>_<timestamp>.tar.gz
├── SUMMARY_FOR_AI.txt   # 一鍵餵給 AI 的精簡重點摘要（含 Prompt 範本）
├── 01_system/           # 系統資訊、核心版本、硬體規格、QEMU-GA 狀態
├── 02_logs/             # dmesg、journalctl、OOM Killer 記錄、失敗服務
├── 03_processes/        # 行程清單 (Top CPU/MEM)、行程樹 (pstree)、排程任務
├── 04_network/          # 網路介面、連線狀態 (ss/netstat)、路由表、防火牆
├── 05_storage/          # 磁碟空間 (df)、Block 設備 (lsblk)、I/O 統計
├── 06_security/         # 登入使用者 (w/who)、近期登入歷史 (last)、sudo 權限
└── 07_sampling/         # 動態採樣 (vmstat、連續行程快照)
```

---

## 使用者執行步驟

### Step 1：建立腳本
請在 Linux VM 中以終端機建立 `linux-diag.sh`（放於 `/tmp` 或使用者家目錄均可）：

```bash
cat << 'EOF' > linux-diag.sh
#!/usr/bin/env bash
# ==============================================================================
# linux-diag.sh
# General-purpose Linux Guest Diagnostic Collector
# Collects: System Info, Logs & OOM, Processes, Network, Storage, Security, Sampling
# Output: <OutputDir>/vm_diag_<Hostname>_<Timestamp>.tar.gz
# Usage: sudo bash linux-diag.sh
#        sudo bash linux-diag.sh --duration 60 --interval 5
#        sudo bash linux-diag.sh --since "2026-09-04 09:00:00" --until "2026-09-04 13:00:00"
#        sudo bash linux-diag.sh --output-dir /var/tmp
# ==============================================================================

set -u

SCRIPT_VERSION="1.0.0"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
HOSTNAME_VAL=$(hostname 2>/dev/null || echo "unknown-host")
OUTPUT_DIR="/tmp"
DURATION=30
INTERVAL=5
SINCE=""
UNTIL=""

# ------------------------------------------------------------------------------
# 0. ARGUMENT PARSING
# ------------------------------------------------------------------------------
print_help() {
    cat <<EOF
Linux Guest Diagnostic Collector v${SCRIPT_VERSION}

用法:
  sudo bash linux-diag.sh [選項]

選項:
  -d, --duration <sec>       動態採樣總時長（秒，預設: 30）
  -i, --interval <sec>       動態採樣間隔（秒，預設: 5）
  -o, --output-dir <path>    輸出目標目錄（預設: /tmp）
      --since <datetime>     日誌收集起始時間 (例如 "2026-09-04 09:00:00")
      --until <datetime>     日誌收集結束時間 (例如 "2026-09-04 13:00:00")
  -h, --help                 顯示此說明畫面

範例:
  sudo bash linux-diag.sh
  sudo bash linux-diag.sh --duration 60 --interval 5
  sudo bash linux-diag.sh --since "2026-09-04 09:00:00" --until "2026-09-04 13:00:00"
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--duration)
            DURATION="$2"
            shift 2
            ;;
        -i|--interval)
            INTERVAL="$2"
            shift 2
            ;;
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --since)
            SINCE="$2"
            shift 2
            ;;
        --until)
            UNTIL="$2"
            shift 2
            ;;
        -h|--help)
            print_help
            ;;
        *)
            echo "[WARN] 未知參數: $1"
            shift
            ;;
    esac
done

# Check root privilege
IS_ADMIN=false
if [ "$EUID" -eq 0 ]; then
    IS_ADMIN=true
fi

DIAG_ROOT="vm_diag_${HOSTNAME_VAL}_${TIMESTAMP}"
DIAG_PATH="${OUTPUT_DIR}/${DIAG_ROOT}"
ARCHIVE_PATH="${OUTPUT_DIR}/${DIAG_ROOT}.tar.gz"

echo ""
echo "========================================================"
echo "  Linux Guest Diagnostic Collector v${SCRIPT_VERSION}"
echo "========================================================"
echo "  Hostname   : ${HOSTNAME_VAL}"
echo "  Timestamp  : $(date +'%Y-%m-%d %H:%M:%S %Z')"
echo "  OutputDir  : ${OUTPUT_DIR}"
echo "  Sampling   : ${DURATION}s (interval: ${INTERVAL}s)"
[ -n "${SINCE}" ] && echo "  Since      : ${SINCE}"
[ -n "${UNTIL}" ] && echo "  Until      : ${UNTIL}"
echo "  RunAsRoot  : ${IS_ADMIN}"
if [ "${IS_ADMIN}" != "true" ]; then
    echo "  [WARNING] 未以 root/sudo 執行，部分日誌 (dmesg, journalctl, secure) 可能不完整。"
fi
echo "========================================================"
echo ""

# Create directory tree
SECTIONS=(
    "01_system"
    "02_logs"
    "03_processes"
    "04_network"
    "05_storage"
    "06_security"
    "07_sampling"
)

mkdir -p "${DIAG_PATH}"
for s in "${SECTIONS[@]}"; do
    mkdir -p "${DIAG_PATH}/${s}"
done

# Helper: Banner
write_header() {
    local file="$1"
    local title="$2"
    local desc="$3"
    local tip="${4:-}"
    cat <<EOF > "${file}"
================================================================================
  ${title}
================================================================================
  Description : ${desc}
  Analysis Tip: ${tip}
  Collected At: $(date +'%Y-%m-%d %H:%M:%S %Z')
  Hostname    : ${HOSTNAME_VAL}
================================================================================

EOF
}

# ==============================================================================
# SECTION 1/7 -- SYSTEM
# ==============================================================================
echo "[1/7] 收集系統基本資訊與規格..."

# 1.1 Overview
OVERVIEW_FILE="${DIAG_PATH}/01_system/system_overview.txt"
write_header "${OVERVIEW_FILE}" "System Overview" "Basic OS, Kernel, Architecture, and Uptime" "對齊時區與 Prometheus 告警時間"
{
    echo "=== Hostname ==="
    hostname 2>&1
    echo ""
    echo "=== Current Time ==="
    date -u +"UTC  : %Y-%m-%d %H:%M:%S"
    date +"Local: %Y-%m-%d %H:%M:%S %Z"
    echo ""
    echo "=== Kernel Info ==="
    uname -a 2>&1
    echo ""
    echo "=== OS Release ==="
    if [ -f /etc/os-release ]; then
        cat /etc/os-release 2>&1
    elif [ -f /etc/redhat-release ]; then
        cat /etc/redhat-release 2>&1
    fi
    echo ""
    echo "=== Uptime & Load Average ==="
    uptime 2>&1
    echo ""
    echo "=== System Architecture ==="
    arch 2>/dev/null || uname -m 2>&1
} >> "${OVERVIEW_FILE}" 2>&1

# 1.2 CPU Info
CPU_FILE="${DIAG_PATH}/01_system/cpu_info.txt"
write_header "${CPU_FILE}" "CPU Hardware Information" "Processor specifications, cores, and topology" "確認 vCPU 配置與超線程狀態"
{
    if command -v lscpu >/dev/null 2>&1; then
        lscpu 2>&1
    else
        grep -E "model name|cpu cores|processor|cpu MHz|flags" /proc/cpuinfo 2>/dev/null | head -n 40
    fi
} >> "${CPU_FILE}" 2>&1

# 1.3 Memory Info
MEM_FILE="${DIAG_PATH}/01_system/memory_info.txt"
write_header "${MEM_FILE}" "Memory Distribution" "RAM and Swap statistics, buffers/cached" "檢視 MemAvailable 與 Swap 使用率"
{
    echo "=== free -h ==="
    free -h 2>/dev/null || free -m 2>&1
    echo ""
    echo "=== /proc/meminfo ==="
    cat /proc/meminfo 2>/dev/null || true
    echo ""
    echo "=== /proc/vmstat (Paging & OOM) ==="
    grep -E "oom|pgpgin|pgpgout|pswpin|pswpout|allocstall" /proc/vmstat 2>/dev/null || true
} >> "${MEM_FILE}" 2>&1

# 1.4 QEMU Guest Agent
QEMU_FILE="${DIAG_PATH}/01_system/qemu_guest_agent.txt"
write_header "${QEMU_FILE}" "QEMU Guest Agent Status" "Agent service state, version, and running status" "若未運行，KubeVirt/Prometheus 無法取得真實記憶體指標"
{
    if command -v systemctl >/dev/null 2>&1; then
        systemctl status qemu-guest-agent --no-pager 2>&1 || true
    fi
    echo ""
    echo "=== Process Search ==="
    ps aux | grep -i '[q]emu-ga' || echo "qemu-ga not found in process table"
    echo ""
    echo "=== Package Version ==="
    if command -v rpm >/dev/null 2>&1; then
        rpm -qa | grep qemu-guest-agent 2>&1 || true
    elif command -v dpkg >/dev/null 2>&1; then
        dpkg -l | grep qemu-guest-agent 2>&1 || true
    fi
} >> "${QEMU_FILE}" 2>&1

# 1.5 Kernel Modules
write_header "${DIAG_PATH}/01_system/kernel_modules.txt" "Loaded Kernel Modules" "List of loaded kernel drivers and modules"
lsmod 2>&1 >> "${DIAG_PATH}/01_system/kernel_modules.txt"

# 1.6 Sysctl Tuning
write_header "${DIAG_PATH}/01_system/sysctl_params.txt" "Kernel Runtime Parameters" "Memory, network, and VM tuning parameters" "檢查 vm.panic_on_oom 與 vm.overcommit_memory"
{
    sysctl -a 2>/dev/null | grep -E "^(vm\.|net\.core\.|net\.ipv4\.tcp_|fs\.file-max)" || true
} >> "${DIAG_PATH}/01_system/sysctl_params.txt"

# ==============================================================================
# SECTION 2/7 -- LOGS & OOM
# ==============================================================================
echo "[2/7] 收集系統日誌、核心報錯與 OOM 事件..."

# 2.1 OOM & Kernel Alerts
OOM_FILE="${DIAG_PATH}/02_logs/oom_and_kernel_alerts.txt"
write_header "${OOM_FILE}" "OOM Killer & Critical Kernel Alerts" "Extracted out-of-memory events, segfaults, soft lockups" "此檔為排查非預期重啟與程式死因的首要關鍵"
{
    echo "=== OOM Killer Events (dmesg) ==="
    dmesg -T 2>/dev/null | grep -iE 'oom|out of memory|killed process|oom-killer|invoked oom-killer' | tail -n 100 || true
    echo ""
    echo "=== CPU Lockups & Panics ==="
    dmesg -T 2>/dev/null | grep -iE 'soft lockup|hard lockup|kernel panic|call trace|mce|machine check' | tail -n 100 || true
    echo ""
    echo "=== Disk & Filesystem IO Errors ==="
    dmesg -T 2>/dev/null | grep -iE 'ext4-fs error|xfs: metadata i/o error|i/o error|buffer i/o error|blk_update_request' | tail -n 100 || true
    echo ""
    echo "=== Segfaults & Process Crashes ==="
    dmesg -T 2>/dev/null | grep -iE 'segfault|general protection' | tail -n 100 || true
} >> "${OOM_FILE}" 2>&1

# 2.2 Full dmesg
write_header "${DIAG_PATH}/02_logs/dmesg_full.txt" "Full Kernel Ring Buffer" "Complete dmesg buffer with timestamps"
dmesg -T >> "${DIAG_PATH}/02_logs/dmesg_full.txt" 2>&1 || true

# 2.3 Journalctl Errors
JOURNAL_FILE="${DIAG_PATH}/02_logs/journal_errors.txt"
write_header "${JOURNAL_FILE}" "Systemd Journal Errors" "Priority err, crit, alert, emerg from systemd journal" "檢查各系統服務報錯"
{
    if command -v journalctl >/dev/null 2>&1; then
        local_args=("-p" "3" "--no-pager" "-n" "500")
        [ -n "${SINCE}" ] && local_args+=("--since" "${SINCE}")
        [ -n "${UNTIL}" ] && local_args+=("--until" "${UNTIL}")
        journalctl "${local_args[@]}" 2>&1 || true
    else
        echo "journalctl not available, reading /var/log/messages or syslog:"
        grep -iE "error|critical|fatal" /var/log/messages /var/log/syslog 2>/dev/null | tail -n 300 || true
    fi
} >> "${JOURNAL_FILE}" 2>&1

# 2.4 Failed Services
FAILED_SRV="${DIAG_PATH}/02_logs/failed_services.txt"
write_header "${FAILED_SRV}" "Failed System Services" "List of systemd units in failed state" "確認事發前後崩潰重啟的 Daemon"
{
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --failed --no-pager 2>&1 || true
    else
        echo "systemctl not available"
    fi
} >> "${FAILED_SRV}" 2>&1

# ==============================================================================
# SECTION 3/7 -- PROCESSES
# ==============================================================================
echo "[3/7] 收集行程快照、資源消耗前名與行程樹..."

# 3.1 Top Processes Snapshot
PROC_SNAP="${DIAG_PATH}/03_processes/process_snapshot.txt"
write_header "${PROC_SNAP}" "Process Snapshot" "Top 35 processes by CPU and Memory" "確認當下吃滿資源的行程與 PID"
{
    echo "=== Top 35 Processes by CPU% ==="
    ps aux --sort=-%cpu 2>/dev/null | head -n 36 || ps -ef 2>/dev/null | head -n 36
    echo ""
    echo "=== Top 35 Processes by Memory (RSS) ==="
    ps aux --sort=-%mem 2>/dev/null | head -n 36 || ps -ef 2>/dev/null | head -n 36
} >> "${PROC_SNAP}" 2>&1

# 3.2 Process Tree
PROC_TREE="${DIAG_PATH}/03_processes/process_tree.txt"
write_header "${PROC_TREE}" "Process Hierarchy Tree" "Tree structure showing parent-child process relationships" "找出背後是哪個父行程或 Worker 派生的"
{
    if command -v pstree >/dev/null 2>&1; then
        pstree -apnh 2>&1 || pstree -ap 2>&1
    else
        ps -ejH 2>&1 || ps aux 2>&1
    fi
} >> "${PROC_TREE}" 2>&1

# 3.3 Full Process List
write_header "${DIAG_PATH}/03_processes/all_processes.txt" "Complete Process List" "Full ps aux output with threads and user info"
ps aux 2>&1 >> "${DIAG_PATH}/03_processes/all_processes.txt"

# 3.4 Scheduled Tasks
CRON_FILE="${DIAG_PATH}/03_processes/cron_and_timers.txt"
write_header "${CRON_FILE}" "Scheduled Tasks & Timers" "Crontab jobs and systemd timer units" "確認事發時間是否有定時備份、更新或掃毒任務"
{
    echo "=== User Crontab (Current User) ==="
    crontab -l 2>&1 || true
    echo ""
    echo "=== System-wide Crontabs (/etc/crontab & /etc/cron.*) ==="
    [ -f /etc/crontab ] && cat /etc/crontab
    ls -la /etc/cron.* 2>/dev/null || true
    echo ""
    echo "=== Systemd Active Timers ==="
    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-timers --no-pager --all 2>&1 || true
    fi
} >> "${CRON_FILE}" 2>&1

# ==============================================================================
# SECTION 4/7 -- NETWORK
# ==============================================================================
echo "[4/7] 收集網路設定、連線與監聽狀態..."

# 4.1 IP Config & Interfaces
write_header "${DIAG_PATH}/04_network/ip_config.txt" "Network Interfaces and Addresses" "IP address configurations and interface status"
{
    if command -v ip >/dev/null 2>&1; then
        ip -d addr show 2>&1
    else
        ifconfig -a 2>&1
    fi
} >> "${DIAG_PATH}/04_network/ip_config.txt"

# 4.2 Routing
write_header "${DIAG_PATH}/04_network/routes.txt" "Routing Table" "Kernel routing table and default gateway"
{
    if command -v ip >/dev/null 2>&1; then
        ip route show 2>&1
    else
        netstat -rn 2>&1
    fi
} >> "${DIAG_PATH}/04_network/routes.txt"

# 4.3 Listening Ports & Sockets
SOCKET_FILE="${DIAG_PATH}/04_network/listening_ports.txt"
write_header "${SOCKET_FILE}" "Listening Ports and Sockets" "All TCP/UDP ports listening for inbound traffic" "確認應用程式監聽埠位與 PID"
{
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>&1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>&1
    fi
} >> "${SOCKET_FILE}" 2>&1

# 4.4 Connection States Summary
CONN_FILE="${DIAG_PATH}/04_network/connection_summary.txt"
write_header "${CONN_FILE}" "TCP Connection States Summary" "Count of sockets by TCP state (TIME_WAIT, ESTABLISHED, etc.)" "確認連線爆滿或 SYN Flood 現象"
{
    if command -v ss >/dev/null 2>&1; then
        echo "=== ss summary ==="
        ss -s 2>&1
        echo ""
        echo "=== Active TCP States Count ==="
        ss -tan 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ant 2>/dev/null | awk '{print $6}' | sort | uniq -c | sort -rn
    fi
} >> "${CONN_FILE}" 2>&1

# 4.5 DNS Config
write_header "${DIAG_PATH}/04_network/dns_config.txt" "DNS Configuration" "Resolv.conf and DNS status"
{
    echo "=== /etc/resolv.conf ==="
    cat /etc/resolv.conf 2>/dev/null || true
    echo ""
    echo "=== /etc/hosts ==="
    cat /etc/hosts 2>/dev/null || true
} >> "${DIAG_PATH}/04_network/dns_config.txt"

# 4.6 Firewall Rules
write_header "${DIAG_PATH}/04_network/firewall_rules.txt" "Firewall and Packet Filtering Rules" "iptables / nftables configuration"
{
    if command -v iptables >/dev/null 2>&1; then
        echo "=== iptables-save ==="
        iptables-save 2>&1 || iptables -L -n -v 2>&1
    fi
    if command -v nft >/dev/null 2>&1; then
        echo ""
        echo "=== nft list ruleset ==="
        nft list ruleset 2>&1 || true
    fi
    if command -v ufw >/dev/null 2>&1; then
        echo ""
        echo "=== ufw status ==="
        ufw status verbose 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        echo ""
        echo "=== firewalld zones ==="
        firewall-cmd --list-all 2>&1 || true
    fi
} >> "${DIAG_PATH}/04_network/firewall_rules.txt"

# ==============================================================================
# SECTION 5/7 -- STORAGE
# ==============================================================================
echo "[5/7] 收集儲存、磁碟使用率與 Block 設備..."

# 5.1 Disk Usage
STORAGE_FILE="${DIAG_PATH}/05_storage/disk_usage.txt"
write_header "${STORAGE_FILE}" "Filesystem Disk Space & Inodes" "df -h and df -i output" "確認根目錄或 /var 是否爆滿 (100% full)"
{
    echo "=== Filesystem Usage (df -hT) ==="
    df -hT 2>&1
    echo ""
    echo "=== Inode Usage (df -i) ==="
    df -i 2>&1
} >> "${STORAGE_FILE}" 2>&1

# 5.2 Block Devices
write_header "${DIAG_PATH}/05_storage/block_devices.txt" "Block Devices & Mounts" "lsblk, fstab and current mount points"
{
    echo "=== lsblk ==="
    command -v lsblk >/dev/null 2>&1 && lsblk -f 2>&1 || true
    echo ""
    echo "=== /etc/fstab ==="
    cat /etc/fstab 2>/dev/null || true
    echo ""
    echo "=== /proc/mounts (Read-only check) ==="
    grep -E " (ro|rw) " /proc/mounts 2>/dev/null | grep -v "/proc" || true
} >> "${DIAG_PATH}/05_storage/block_devices.txt"

# 5.3 Disk Stats
write_header "${DIAG_PATH}/05_storage/disk_io_stats.txt" "Kernel Disk I/O Statistics" "/proc/diskstats and iostat"
{
    echo "=== /proc/diskstats ==="
    cat /proc/diskstats 2>/dev/null || true
    if command -v iostat >/dev/null 2>&1; then
        echo ""
        echo "=== iostat -xz 1 2 ==="
        iostat -xz 1 2 2>&1 || true
    fi
} >> "${DIAG_PATH}/05_storage/disk_io_stats.txt"

# ==============================================================================
# SECTION 6/7 -- SECURITY
# ==============================================================================
echo "[6/7] 收集安全性、登入歷史與使用者帳號..."

# 6.1 Logged in users & Last
SEC_FILE="${DIAG_PATH}/06_security/login_sessions.txt"
write_header "${SEC_FILE}" "Active Users and Login History" "w, who, and last login entries" "確認事發時間有誰登入、是否有暴力破解"
{
    echo "=== Current Logged-in Users (w) ==="
    w 2>&1 || who -a 2>&1
    echo ""
    echo "=== Last 40 Logins (last) ==="
    last -n 40 2>&1 || true
    echo ""
    echo "=== Last Bad/Failed Logins (lastb) ==="
    lastb -n 30 2>&1 || echo "lastb not available or requires root"
} >> "${SEC_FILE}" 2>&1

# 6.2 User accounts list
write_header "${DIAG_PATH}/06_security/user_accounts.txt" "Local User Accounts" "List of users with login shells"
{
    echo "=== Users with Login Shells (/etc/passwd) ==="
    grep -vE '(/sbin/nologin|/bin/false)' /etc/passwd 2>/dev/null || true
    echo ""
    echo "=== Sudoers Group Members ==="
    grep -E '^(sudo|wheel|admin):' /etc/group 2>/dev/null || true
} >> "${DIAG_PATH}/06_security/user_accounts.txt"

# ==============================================================================
# SECTION 7/7 -- SAMPLING
# ==============================================================================
echo "[7/7] 執行 ${DURATION} 秒動態採樣 (每 ${INTERVAL} 秒記錄一次)..."

SAMPLES=$(( DURATION / INTERVAL ))
[ "$SAMPLES" -lt 1 ] && SAMPLES=1

SAMPLE_FILE="${DIAG_PATH}/07_sampling/sampling_${DURATION}s.txt"
write_header "${SAMPLE_FILE}" "Continuous System Sampling" "vmstat and top resource processes over ${DURATION} seconds" "觀察 CPU/Memory 瞬時飆高軌跡"
{
    echo "=== Sampling Config ==="
    echo "Duration: ${DURATION} seconds"
    echo "Interval: ${INTERVAL} seconds"
    echo "Samples : ${SAMPLES}"
    echo "Started : $(date +'%Y-%m-%d %H:%M:%S')"
    echo ""

    if command -v vmstat >/dev/null 2>&1; then
        echo "--- vmstat ${INTERVAL} ${SAMPLES} ---"
        vmstat "${INTERVAL}" "${SAMPLES}" 2>&1
        echo ""
    fi

    echo "--- Periodic Process Snapshot ---"
    for i in $(seq 1 "${SAMPLES}"); do
        echo "--- [Sample ${i}/${SAMPLES}] at $(date +'%H:%M:%S') ---"
        echo "Top 5 CPU:"
        ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -n 6 || ps -ef | head -n 6
        echo "Top 5 Memory:"
        ps -eo pid,user,%cpu,%mem,rss,comm --sort=-%mem 2>/dev/null | head -n 6 || ps -ef | head -n 6
        echo ""
        [ "${i}" -lt "${SAMPLES}" ] && sleep "${INTERVAL}"
    done
} >> "${SAMPLE_FILE}" 2>&1

# ==============================================================================
# GENERATE SUMMARY_FOR_AI.txt
# ==============================================================================
echo ""
echo "正在產生 SUMMARY_FOR_AI.txt 精簡診斷摘要..."
AI_FILE="${DIAG_PATH}/SUMMARY_FOR_AI.txt"

# Extract system stats for summary
DISTRO_NAME="Unknown Linux"
if [ -f /etc/os-release ]; then
    DISTRO_NAME=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
fi
KERNEL_VER=$(uname -r)
UPTIME_STR=$(uptime -p 2>/dev/null || uptime | sed 's/.*up \([^,]*\), .*/\1/')
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^[ \t]*//' || echo "Unknown CPU")
CPU_COUNT=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")

# Memory calculation
MEM_TOTAL_KB=$(grep -m1 "MemTotal:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
MEM_AVAIL_KB=$(grep -m1 "MemAvailable:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
if [ "$MEM_TOTAL_KB" -gt 0 ]; then
    MEM_TOTAL_GB=$(awk -v t="$MEM_TOTAL_KB" 'BEGIN {printf "%.1f", t/1048576}')
    MEM_AVAIL_GB=$(awk -v a="$MEM_AVAIL_KB" 'BEGIN {printf "%.1f", a/1048576}')
    MEM_USED_PCT=$(awk -v t="$MEM_TOTAL_KB" -v a="$MEM_AVAIL_KB" 'BEGIN {printf "%.1f", ((t-a)/t)*100}')
else
    MEM_TOTAL_GB="N/A"
    MEM_AVAIL_GB="N/A"
    MEM_USED_PCT="N/A"
fi

cat <<EOF > "${AI_FILE}"
================================================================================
  LINUX GUEST DIAGNOSTIC SUMMARY — FOR AI-ASSISTED ANALYSIS
================================================================================
  Hostname    : ${HOSTNAME_VAL}
  OS          : ${DISTRO_NAME}
  Kernel      : ${KERNEL_VER}
  Collected   : $(date +'%Y-%m-%d %H:%M:%S %Z')
  Uptime      : ${UPTIME_STR}
  Run As Root : ${IS_ADMIN}
================================================================================

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  HOW TO USE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. Share this file with an AI assistant (ChatGPT, Claude, Gemini, etc.)
  2. Use the prompt template in the next section
  3. If the AI needs more detail, share the specific .txt file from the archive

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PROMPT TEMPLATE (copy and paste to AI, then attach this file)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

You are an expert Linux systems administrator and performance engineer.
The attached file is a diagnostic summary from a Linux VM (running in a
KubeVirt / Kubernetes virtualization environment). Please analyze and provide:
  1. Overall system health assessment
  2. Root cause of reported issues (e.g. OOM, CPU spike, disk pressure, hung tasks)
  3. Security or stability concerns
  4. Recommended next steps and remediation

Incident context: [USER: describe symptoms here, e.g. 'high CPU/Memory around 14:00, service unresponsive']

If you need more detail on any area, ask me to share the specific log file
from the diagnostic tarball (e.g. '02_logs/oom_and_kernel_alerts.txt' or '03_processes/process_snapshot.txt').

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [1] SYSTEM IDENTITY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Hostname    : ${HOSTNAME_VAL}
  OS          : ${DISTRO_NAME}
  Kernel      : ${KERNEL_VER}
  Uptime      : ${UPTIME_STR}
  CPU         : ${CPU_MODEL} | Cores: ${CPU_COUNT}
  RAM Total   : ${MEM_TOTAL_GB} GB | Available: ${MEM_AVAIL_GB} GB | Used: ${MEM_USED_PCT}%
  Time Zone   : $(date +'%Z (UTC%:z)')

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [2] ⚠️  AUTO-DETECTED ALERTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

# Detect Alerts
ALERT_COUNT=0

# 1. OOM Killer Check
OOM_COUNT=$(dmesg 2>/dev/null | grep -icE "killed process|oom-killer|out of memory" || echo "0")
if [ "${OOM_COUNT}" -gt 0 ]; then
    echo "  [CRITICAL] OOM Killer triggered! Found ${OOM_COUNT} OOM event(s) in dmesg." >> "${AI_FILE}"
    ALERT_COUNT=$((ALERT_COUNT + 1))
fi

# 2. Disk Space Check (>85%)
while read -r fs size used avail pct mount; do
    pct_num=$(echo "${pct}" | tr -d '%')
    if [ "${pct_num}" -ge 90 ] 2>/dev/null; then
        echo "  [DISK CRITICAL] Mount point '${mount}' is ${pct} full! (Available: ${avail})" >> "${AI_FILE}"
        ALERT_COUNT=$((ALERT_COUNT + 1))
    elif [ "${pct_num}" -ge 80 ] 2>/dev/null; then
        echo "  [DISK WARNING]  Mount point '${mount}' is ${pct} full. (Available: ${avail})" >> "${AI_FILE}"
        ALERT_COUNT=$((ALERT_COUNT + 1))
    fi
done < <(df -hP 2>/dev/null | grep -E '^/dev/' || true)

# 3. Memory pressure alert (>85%)
if [ "${MEM_USED_PCT%.*}" -ge 90 ] 2>/dev/null; then
    echo "  [RAM CRITICAL]  Physical memory usage is ${MEM_USED_PCT}%" >> "${AI_FILE}"
    ALERT_COUNT=$((ALERT_COUNT + 1))
elif [ "${MEM_USED_PCT%.*}" -ge 80 ] 2>/dev/null; then
    echo "  [RAM WARNING]   Physical memory usage is ${MEM_USED_PCT}%" >> "${AI_FILE}"
    ALERT_COUNT=$((ALERT_COUNT + 1))
fi

# 4. Failed Services Alert
if command -v systemctl >/dev/null 2>&1; then
    FAILED_UNITS=$(systemctl --failed --no-legend 2>/dev/null | wc -l || echo "0")
    if [ "${FAILED_UNITS}" -gt 0 ]; then
        echo "  [SERVICE ALERT] ${FAILED_UNITS} systemd unit(s) in failed state!" >> "${AI_FILE}"
        ALERT_COUNT=$((ALERT_COUNT + 1))
    fi
fi

# 5. QEMU Guest Agent Check
if ! ps aux | grep -i '[q]emu-ga' >/dev/null 2>&1; then
    echo "  [QEMU-GA WARN]  qemu-guest-agent process NOT running. KubeVirt/Prometheus metrics may be inaccurate." >> "${AI_FILE}"
    ALERT_COUNT=$((ALERT_COUNT + 1))
fi

# 6. Kernel Soft Lockup / Panic
LOCKUP_COUNT=$(dmesg 2>/dev/null | grep -icE "soft lockup|kernel panic" || echo "0")
if [ "${LOCKUP_COUNT}" -gt 0 ]; then
    echo "  [KERNEL ALERT]  Found ${LOCKUP_COUNT} soft lockup / panic message(s) in dmesg." >> "${AI_FILE}"
    ALERT_COUNT=$((ALERT_COUNT + 1))
fi

if [ "$ALERT_COUNT" -eq 0 ]; then
    echo "  No critical issues auto-detected." >> "${AI_FILE}"
fi

cat <<EOF >> "${AI_FILE}"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [3] TOP RESOURCE CONSUMERS (Current Snapshot)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--- Top 5 CPU Processes ---
$(ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -n 6 || ps -ef | head -n 6)

--- Top 5 Memory Processes (RSS) ---
$(ps -eo pid,user,%cpu,%mem,rss,comm --sort=-%mem 2>/dev/null | head -n 6 || ps -ef | head -n 6)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [4] RECENT CRITICAL LOG EVENTS (Last 10 OOM / Kernel Alerts)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$(dmesg -T 2>/dev/null | grep -iE 'oom|killed process|soft lockup|panic|ext4-fs error|xfs:' | tail -n 10 || echo "  None found in dmesg.")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [5] STORAGE & MOUNTS SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$(df -hT 2>/dev/null | grep -E '^(Filesystem|/dev/)' || df -h 2>/dev/null | head -n 10)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [6] NETWORK & SOCKET SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$(if command -v ss >/dev/null 2>&1; then
    ss -s 2>/dev/null
    echo "Listening TCP Ports: $(ss -tln 2>/dev/null | grep -c LISTEN || echo 'N/A')"
else
    echo "Active Connections: $(netstat -ant 2>/dev/null | wc -l || echo 'N/A')"
fi)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  END OF SUMMARY — See individual files in tarball for full details
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

echo "  -> SUMMARY_FOR_AI.txt 已生成。"

# ==============================================================================
# COMPRESS OUTPUT
# ==============================================================================
echo ""
echo "正在將診斷資料打包成 .tar.gz..."
tar -czf "${ARCHIVE_PATH}" -C "${OUTPUT_DIR}" "${DIAG_ROOT}"
rm -rf "${DIAG_PATH}"

FILE_SIZE=$(ls -lh "${ARCHIVE_PATH}" | awk '{print $5}')

echo ""
echo "========================================================"
echo "  Collection Summary"
echo "========================================================"
echo "  Hostname   : ${HOSTNAME_VAL}"
echo "  Output     : ${ARCHIVE_PATH} (${FILE_SIZE})"
echo "  RunAsRoot  : ${IS_ADMIN}"
echo ""
echo "  Sections collected:"
echo "    [1/7] 01_system    - Hostname, kernel, cpu, memory, qemu-ga, sysctl"
echo "    [2/7] 02_logs      - dmesg, oom alerts, journalctl, failed services"
echo "    [3/7] 03_processes - Top CPU/MEM, pstree, crontab, systemd timers"
echo "    [4/7] 04_network   - IP addresses, routes, ss/netstat, dns, iptables"
echo "    [5/7] 05_storage   - df, lsblk, fstab, diskstats, iostat"
echo "    [6/7] 06_security  - Logged in users, last logins, sudoers"
echo "    [7/7] 07_sampling  - Continuous vmstat and process sampling (${DURATION}s)"
echo ""
echo "Done. 請將 ${ARCHIVE_PATH} 傳回維運團隊。"
echo "========================================================"

EOF
chmod +x linux-diag.sh
```

> [!TIP]
> 亦可直接複製下方 **「腳本原始碼」** 區段的完整內容，使用 `vim linux-diag.sh` 或 `nano linux-diag.sh` 貼上儲存。

---

### Step 2：以 root / sudo 身分執行

```bash
# 預設收集（包含 30 秒動態採樣）
sudo bash linux-diag.sh
```

**若知道事發時間，指定時間段（推薦）：**
```bash
sudo bash linux-diag.sh --since "2026-09-04 09:00:00" --until "2026-09-04 13:00:00"
```

**若需自訂動態採樣時間（例如觀察 60 秒，每 5 秒記錄一次）：**
```bash
sudo bash linux-diag.sh -d 60 -i 5
```

---

### Step 3：回傳壓縮檔
腳本完成後會顯示輸出路徑，請使用者將 `.tar.gz` 傳回維運團隊：
```
/tmp/vm_diag_<hostname>_<timestamp>.tar.gz
```

---

## 關鍵異常指標速查

| 關鍵字 / 徵兆 | 來源日誌 | 意義與嚴重度 |
| :--- | :--- | :--- |
| **Out of memory: Killed process** | dmesg / journalctl | 虛擬機記憶體耗盡，核心 OOM Killer 強制殺死行程 🔴 |
| **invoked oom-killer** | dmesg | 觸發 OOM 機制，核心印出當時各行程記憶體佔用 🔴 |
| **kernel: BUG: soft lockup** | dmesg | CPU 核心卡死在內核態超過 20 秒 (CPU 飢餓/搶佔問題) 🔴 |
| **kernel: Call Trace: / Kernel panic** | dmesg | Linux 核心崩潰或嚴重例外 (Kernel Panic) 🔴 |
| **segfault at ...** | dmesg / syslog | 應用程式記憶體段錯誤，程式異常崩潰 (Crash) 🟠 |
| **task ... blocked for more than 120 seconds** | dmesg | 行程進入不可中斷的 D 狀態（儲存 I/O 卡死或死鎖） 🟠 |
| **EXT4-fs error / XFS: metadata I/O error** | dmesg | 底層磁碟 I/O 錯誤或檔案系統損毀 🔴 |
| **Unit entered failed state** | systemctl | 關鍵守護行程崩潰或啟動失敗 🟠 |
| **Failed password for ...** | auth.log / secure | SSH 登入失敗記錄（確認是否有暴力密碼攻擊） 🟡 |

> [!IMPORTANT]
> **QEMU Guest Agent 狀態**：請在 `01_system/qemu_guest_agent.txt` 確認 `qemu-guest-agent` 服務是否為 `active (running)`。
> 若未運行，KubeVirt 與 Prometheus 上的 `memory_available` 指標不可信，容易產生假性記憶體告警。

---

## 腳本原始碼

> 複製以下完整內容，存成 `linux-diag.sh` 後執行。

```bash
#!/usr/bin/env bash
# ==============================================================================
# linux-diag.sh
# General-purpose Linux Guest Diagnostic Collector
# Collects: System Info, Logs & OOM, Processes, Network, Storage, Security, Sampling
# Output: <OutputDir>/vm_diag_<Hostname>_<Timestamp>.tar.gz
# Usage: sudo bash linux-diag.sh
#        sudo bash linux-diag.sh --duration 60 --interval 5
#        sudo bash linux-diag.sh --since "2026-09-04 09:00:00" --until "2026-09-04 13:00:00"
#        sudo bash linux-diag.sh --output-dir /var/tmp
# ==============================================================================

set -u

SCRIPT_VERSION="1.0.0"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
HOSTNAME_VAL=$(hostname 2>/dev/null || echo "unknown-host")
OUTPUT_DIR="/tmp"
DURATION=30
INTERVAL=5
SINCE=""
UNTIL=""

# ------------------------------------------------------------------------------
# 0. ARGUMENT PARSING
# ------------------------------------------------------------------------------
print_help() {
    cat <<EOF
Linux Guest Diagnostic Collector v${SCRIPT_VERSION}

用法:
  sudo bash linux-diag.sh [選項]

選項:
  -d, --duration <sec>       動態採樣總時長（秒，預設: 30）
  -i, --interval <sec>       動態採樣間隔（秒，預設: 5）
  -o, --output-dir <path>    輸出目標目錄（預設: /tmp）
      --since <datetime>     日誌收集起始時間 (例如 "2026-09-04 09:00:00")
      --until <datetime>     日誌收集結束時間 (例如 "2026-09-04 13:00:00")
  -h, --help                 顯示此說明畫面

範例:
  sudo bash linux-diag.sh
  sudo bash linux-diag.sh --duration 60 --interval 5
  sudo bash linux-diag.sh --since "2026-09-04 09:00:00" --until "2026-09-04 13:00:00"
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--duration)
            DURATION="$2"
            shift 2
            ;;
        -i|--interval)
            INTERVAL="$2"
            shift 2
            ;;
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --since)
            SINCE="$2"
            shift 2
            ;;
        --until)
            UNTIL="$2"
            shift 2
            ;;
        -h|--help)
            print_help
            ;;
        *)
            echo "[WARN] 未知參數: $1"
            shift
            ;;
    esac
done

# Check root privilege
IS_ADMIN=false
if [ "$EUID" -eq 0 ]; then
    IS_ADMIN=true
fi

DIAG_ROOT="vm_diag_${HOSTNAME_VAL}_${TIMESTAMP}"
DIAG_PATH="${OUTPUT_DIR}/${DIAG_ROOT}"
ARCHIVE_PATH="${OUTPUT_DIR}/${DIAG_ROOT}.tar.gz"

echo ""
echo "========================================================"
echo "  Linux Guest Diagnostic Collector v${SCRIPT_VERSION}"
echo "========================================================"
echo "  Hostname   : ${HOSTNAME_VAL}"
echo "  Timestamp  : $(date +'%Y-%m-%d %H:%M:%S %Z')"
echo "  OutputDir  : ${OUTPUT_DIR}"
echo "  Sampling   : ${DURATION}s (interval: ${INTERVAL}s)"
[ -n "${SINCE}" ] && echo "  Since      : ${SINCE}"
[ -n "${UNTIL}" ] && echo "  Until      : ${UNTIL}"
echo "  RunAsRoot  : ${IS_ADMIN}"
if [ "${IS_ADMIN}" != "true" ]; then
    echo "  [WARNING] 未以 root/sudo 執行，部分日誌 (dmesg, journalctl, secure) 可能不完整。"
fi
echo "========================================================"
echo ""

# Create directory tree
SECTIONS=(
    "01_system"
    "02_logs"
    "03_processes"
    "04_network"
    "05_storage"
    "06_security"
    "07_sampling"
)

mkdir -p "${DIAG_PATH}"
for s in "${SECTIONS[@]}"; do
    mkdir -p "${DIAG_PATH}/${s}"
done

# Helper: Banner
write_header() {
    local file="$1"
    local title="$2"
    local desc="$3"
    local tip="${4:-}"
    cat <<EOF > "${file}"
================================================================================
  ${title}
================================================================================
  Description : ${desc}
  Analysis Tip: ${tip}
  Collected At: $(date +'%Y-%m-%d %H:%M:%S %Z')
  Hostname    : ${HOSTNAME_VAL}
================================================================================

EOF
}

# ==============================================================================
# SECTION 1/7 -- SYSTEM
# ==============================================================================
echo "[1/7] 收集系統基本資訊與規格..."

# 1.1 Overview
OVERVIEW_FILE="${DIAG_PATH}/01_system/system_overview.txt"
write_header "${OVERVIEW_FILE}" "System Overview" "Basic OS, Kernel, Architecture, and Uptime" "對齊時區與 Prometheus 告警時間"
{
    echo "=== Hostname ==="
    hostname 2>&1
    echo ""
    echo "=== Current Time ==="
    date -u +"UTC  : %Y-%m-%d %H:%M:%S"
    date +"Local: %Y-%m-%d %H:%M:%S %Z"
    echo ""
    echo "=== Kernel Info ==="
    uname -a 2>&1
    echo ""
    echo "=== OS Release ==="
    if [ -f /etc/os-release ]; then
        cat /etc/os-release 2>&1
    elif [ -f /etc/redhat-release ]; then
        cat /etc/redhat-release 2>&1
    fi
    echo ""
    echo "=== Uptime & Load Average ==="
    uptime 2>&1
    echo ""
    echo "=== System Architecture ==="
    arch 2>/dev/null || uname -m 2>&1
} >> "${OVERVIEW_FILE}" 2>&1

# 1.2 CPU Info
CPU_FILE="${DIAG_PATH}/01_system/cpu_info.txt"
write_header "${CPU_FILE}" "CPU Hardware Information" "Processor specifications, cores, and topology" "確認 vCPU 配置與超線程狀態"
{
    if command -v lscpu >/dev/null 2>&1; then
        lscpu 2>&1
    else
        grep -E "model name|cpu cores|processor|cpu MHz|flags" /proc/cpuinfo 2>/dev/null | head -n 40
    fi
} >> "${CPU_FILE}" 2>&1

# 1.3 Memory Info
MEM_FILE="${DIAG_PATH}/01_system/memory_info.txt"
write_header "${MEM_FILE}" "Memory Distribution" "RAM and Swap statistics, buffers/cached" "檢視 MemAvailable 與 Swap 使用率"
{
    echo "=== free -h ==="
    free -h 2>/dev/null || free -m 2>&1
    echo ""
    echo "=== /proc/meminfo ==="
    cat /proc/meminfo 2>/dev/null || true
    echo ""
    echo "=== /proc/vmstat (Paging & OOM) ==="
    grep -E "oom|pgpgin|pgpgout|pswpin|pswpout|allocstall" /proc/vmstat 2>/dev/null || true
} >> "${MEM_FILE}" 2>&1

# 1.4 QEMU Guest Agent
QEMU_FILE="${DIAG_PATH}/01_system/qemu_guest_agent.txt"
write_header "${QEMU_FILE}" "QEMU Guest Agent Status" "Agent service state, version, and running status" "若未運行，KubeVirt/Prometheus 無法取得真實記憶體指標"
{
    if command -v systemctl >/dev/null 2>&1; then
        systemctl status qemu-guest-agent --no-pager 2>&1 || true
    fi
    echo ""
    echo "=== Process Search ==="
    ps aux | grep -i '[q]emu-ga' || echo "qemu-ga not found in process table"
    echo ""
    echo "=== Package Version ==="
    if command -v rpm >/dev/null 2>&1; then
        rpm -qa | grep qemu-guest-agent 2>&1 || true
    elif command -v dpkg >/dev/null 2>&1; then
        dpkg -l | grep qemu-guest-agent 2>&1 || true
    fi
} >> "${QEMU_FILE}" 2>&1

# 1.5 Kernel Modules
write_header "${DIAG_PATH}/01_system/kernel_modules.txt" "Loaded Kernel Modules" "List of loaded kernel drivers and modules"
lsmod 2>&1 >> "${DIAG_PATH}/01_system/kernel_modules.txt"

# 1.6 Sysctl Tuning
write_header "${DIAG_PATH}/01_system/sysctl_params.txt" "Kernel Runtime Parameters" "Memory, network, and VM tuning parameters" "檢查 vm.panic_on_oom 與 vm.overcommit_memory"
{
    sysctl -a 2>/dev/null | grep -E "^(vm\.|net\.core\.|net\.ipv4\.tcp_|fs\.file-max)" || true
} >> "${DIAG_PATH}/01_system/sysctl_params.txt"

# ==============================================================================
# SECTION 2/7 -- LOGS & OOM
# ==============================================================================
echo "[2/7] 收集系統日誌、核心報錯與 OOM 事件..."

# 2.1 OOM & Kernel Alerts
OOM_FILE="${DIAG_PATH}/02_logs/oom_and_kernel_alerts.txt"
write_header "${OOM_FILE}" "OOM Killer & Critical Kernel Alerts" "Extracted out-of-memory events, segfaults, soft lockups" "此檔為排查非預期重啟與程式死因的首要關鍵"
{
    echo "=== OOM Killer Events (dmesg) ==="
    dmesg -T 2>/dev/null | grep -iE 'oom|out of memory|killed process|oom-killer|invoked oom-killer' | tail -n 100 || true
    echo ""
    echo "=== CPU Lockups & Panics ==="
    dmesg -T 2>/dev/null | grep -iE 'soft lockup|hard lockup|kernel panic|call trace|mce|machine check' | tail -n 100 || true
    echo ""
    echo "=== Disk & Filesystem IO Errors ==="
    dmesg -T 2>/dev/null | grep -iE 'ext4-fs error|xfs: metadata i/o error|i/o error|buffer i/o error|blk_update_request' | tail -n 100 || true
    echo ""
    echo "=== Segfaults & Process Crashes ==="
    dmesg -T 2>/dev/null | grep -iE 'segfault|general protection' | tail -n 100 || true
} >> "${OOM_FILE}" 2>&1

# 2.2 Full dmesg
write_header "${DIAG_PATH}/02_logs/dmesg_full.txt" "Full Kernel Ring Buffer" "Complete dmesg buffer with timestamps"
dmesg -T >> "${DIAG_PATH}/02_logs/dmesg_full.txt" 2>&1 || true

# 2.3 Journalctl Errors
JOURNAL_FILE="${DIAG_PATH}/02_logs/journal_errors.txt"
write_header "${JOURNAL_FILE}" "Systemd Journal Errors" "Priority err, crit, alert, emerg from systemd journal" "檢查各系統服務報錯"
{
    if command -v journalctl >/dev/null 2>&1; then
        local_args=("-p" "3" "--no-pager" "-n" "500")
        [ -n "${SINCE}" ] && local_args+=("--since" "${SINCE}")
        [ -n "${UNTIL}" ] && local_args+=("--until" "${UNTIL}")
        journalctl "${local_args[@]}" 2>&1 || true
    else
        echo "journalctl not available, reading /var/log/messages or syslog:"
        grep -iE "error|critical|fatal" /var/log/messages /var/log/syslog 2>/dev/null | tail -n 300 || true
    fi
} >> "${JOURNAL_FILE}" 2>&1

# 2.4 Failed Services
FAILED_SRV="${DIAG_PATH}/02_logs/failed_services.txt"
write_header "${FAILED_SRV}" "Failed System Services" "List of systemd units in failed state" "確認事發前後崩潰重啟的 Daemon"
{
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --failed --no-pager 2>&1 || true
    else
        echo "systemctl not available"
    fi
} >> "${FAILED_SRV}" 2>&1

# ==============================================================================
# SECTION 3/7 -- PROCESSES
# ==============================================================================
echo "[3/7] 收集行程快照、資源消耗前名與行程樹..."

# 3.1 Top Processes Snapshot
PROC_SNAP="${DIAG_PATH}/03_processes/process_snapshot.txt"
write_header "${PROC_SNAP}" "Process Snapshot" "Top 35 processes by CPU and Memory" "確認當下吃滿資源的行程與 PID"
{
    echo "=== Top 35 Processes by CPU% ==="
    ps aux --sort=-%cpu 2>/dev/null | head -n 36 || ps -ef 2>/dev/null | head -n 36
    echo ""
    echo "=== Top 35 Processes by Memory (RSS) ==="
    ps aux --sort=-%mem 2>/dev/null | head -n 36 || ps -ef 2>/dev/null | head -n 36
} >> "${PROC_SNAP}" 2>&1

# 3.2 Process Tree
PROC_TREE="${DIAG_PATH}/03_processes/process_tree.txt"
write_header "${PROC_TREE}" "Process Hierarchy Tree" "Tree structure showing parent-child process relationships" "找出背後是哪個父行程或 Worker 派生的"
{
    if command -v pstree >/dev/null 2>&1; then
        pstree -apnh 2>&1 || pstree -ap 2>&1
    else
        ps -ejH 2>&1 || ps aux 2>&1
    fi
} >> "${PROC_TREE}" 2>&1

# 3.3 Full Process List
write_header "${DIAG_PATH}/03_processes/all_processes.txt" "Complete Process List" "Full ps aux output with threads and user info"
ps aux 2>&1 >> "${DIAG_PATH}/03_processes/all_processes.txt"

# 3.4 Scheduled Tasks
CRON_FILE="${DIAG_PATH}/03_processes/cron_and_timers.txt"
write_header "${CRON_FILE}" "Scheduled Tasks & Timers" "Crontab jobs and systemd timer units" "確認事發時間是否有定時備份、更新或掃毒任務"
{
    echo "=== User Crontab (Current User) ==="
    crontab -l 2>&1 || true
    echo ""
    echo "=== System-wide Crontabs (/etc/crontab & /etc/cron.*) ==="
    [ -f /etc/crontab ] && cat /etc/crontab
    ls -la /etc/cron.* 2>/dev/null || true
    echo ""
    echo "=== Systemd Active Timers ==="
    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-timers --no-pager --all 2>&1 || true
    fi
} >> "${CRON_FILE}" 2>&1

# ==============================================================================
# SECTION 4/7 -- NETWORK
# ==============================================================================
echo "[4/7] 收集網路設定、連線與監聽狀態..."

# 4.1 IP Config & Interfaces
write_header "${DIAG_PATH}/04_network/ip_config.txt" "Network Interfaces and Addresses" "IP address configurations and interface status"
{
    if command -v ip >/dev/null 2>&1; then
        ip -d addr show 2>&1
    else
        ifconfig -a 2>&1
    fi
} >> "${DIAG_PATH}/04_network/ip_config.txt"

# 4.2 Routing
write_header "${DIAG_PATH}/04_network/routes.txt" "Routing Table" "Kernel routing table and default gateway"
{
    if command -v ip >/dev/null 2>&1; then
        ip route show 2>&1
    else
        netstat -rn 2>&1
    fi
} >> "${DIAG_PATH}/04_network/routes.txt"

# 4.3 Listening Ports & Sockets
SOCKET_FILE="${DIAG_PATH}/04_network/listening_ports.txt"
write_header "${SOCKET_FILE}" "Listening Ports and Sockets" "All TCP/UDP ports listening for inbound traffic" "確認應用程式監聽埠位與 PID"
{
    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>&1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>&1
    fi
} >> "${SOCKET_FILE}" 2>&1

# 4.4 Connection States Summary
CONN_FILE="${DIAG_PATH}/04_network/connection_summary.txt"
write_header "${CONN_FILE}" "TCP Connection States Summary" "Count of sockets by TCP state (TIME_WAIT, ESTABLISHED, etc.)" "確認連線爆滿或 SYN Flood 現象"
{
    if command -v ss >/dev/null 2>&1; then
        echo "=== ss summary ==="
        ss -s 2>&1
        echo ""
        echo "=== Active TCP States Count ==="
        ss -tan 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ant 2>/dev/null | awk '{print $6}' | sort | uniq -c | sort -rn
    fi
} >> "${CONN_FILE}" 2>&1

# 4.5 DNS Config
write_header "${DIAG_PATH}/04_network/dns_config.txt" "DNS Configuration" "Resolv.conf and DNS status"
{
    echo "=== /etc/resolv.conf ==="
    cat /etc/resolv.conf 2>/dev/null || true
    echo ""
    echo "=== /etc/hosts ==="
    cat /etc/hosts 2>/dev/null || true
} >> "${DIAG_PATH}/04_network/dns_config.txt"

# 4.6 Firewall Rules
write_header "${DIAG_PATH}/04_network/firewall_rules.txt" "Firewall and Packet Filtering Rules" "iptables / nftables configuration"
{
    if command -v iptables >/dev/null 2>&1; then
        echo "=== iptables-save ==="
        iptables-save 2>&1 || iptables -L -n -v 2>&1
    fi
    if command -v nft >/dev/null 2>&1; then
        echo ""
        echo "=== nft list ruleset ==="
        nft list ruleset 2>&1 || true
    fi
    if command -v ufw >/dev/null 2>&1; then
        echo ""
        echo "=== ufw status ==="
        ufw status verbose 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        echo ""
        echo "=== firewalld zones ==="
        firewall-cmd --list-all 2>&1 || true
    fi
} >> "${DIAG_PATH}/04_network/firewall_rules.txt"

# ==============================================================================
# SECTION 5/7 -- STORAGE
# ==============================================================================
echo "[5/7] 收集儲存、磁碟使用率與 Block 設備..."

# 5.1 Disk Usage
STORAGE_FILE="${DIAG_PATH}/05_storage/disk_usage.txt"
write_header "${STORAGE_FILE}" "Filesystem Disk Space & Inodes" "df -h and df -i output" "確認根目錄或 /var 是否爆滿 (100% full)"
{
    echo "=== Filesystem Usage (df -hT) ==="
    df -hT 2>&1
    echo ""
    echo "=== Inode Usage (df -i) ==="
    df -i 2>&1
} >> "${STORAGE_FILE}" 2>&1

# 5.2 Block Devices
write_header "${DIAG_PATH}/05_storage/block_devices.txt" "Block Devices & Mounts" "lsblk, fstab and current mount points"
{
    echo "=== lsblk ==="
    command -v lsblk >/dev/null 2>&1 && lsblk -f 2>&1 || true
    echo ""
    echo "=== /etc/fstab ==="
    cat /etc/fstab 2>/dev/null || true
    echo ""
    echo "=== /proc/mounts (Read-only check) ==="
    grep -E " (ro|rw) " /proc/mounts 2>/dev/null | grep -v "/proc" || true
} >> "${DIAG_PATH}/05_storage/block_devices.txt"

# 5.3 Disk Stats
write_header "${DIAG_PATH}/05_storage/disk_io_stats.txt" "Kernel Disk I/O Statistics" "/proc/diskstats and iostat"
{
    echo "=== /proc/diskstats ==="
    cat /proc/diskstats 2>/dev/null || true
    if command -v iostat >/dev/null 2>&1; then
        echo ""
        echo "=== iostat -xz 1 2 ==="
        iostat -xz 1 2 2>&1 || true
    fi
} >> "${DIAG_PATH}/05_storage/disk_io_stats.txt"

# ==============================================================================
# SECTION 6/7 -- SECURITY
# ==============================================================================
echo "[6/7] 收集安全性、登入歷史與使用者帳號..."

# 6.1 Logged in users & Last
SEC_FILE="${DIAG_PATH}/06_security/login_sessions.txt"
write_header "${SEC_FILE}" "Active Users and Login History" "w, who, and last login entries" "確認事發時間有誰登入、是否有暴力破解"
{
    echo "=== Current Logged-in Users (w) ==="
    w 2>&1 || who -a 2>&1
    echo ""
    echo "=== Last 40 Logins (last) ==="
    last -n 40 2>&1 || true
    echo ""
    echo "=== Last Bad/Failed Logins (lastb) ==="
    lastb -n 30 2>&1 || echo "lastb not available or requires root"
} >> "${SEC_FILE}" 2>&1

# 6.2 User accounts list
write_header "${DIAG_PATH}/06_security/user_accounts.txt" "Local User Accounts" "List of users with login shells"
{
    echo "=== Users with Login Shells (/etc/passwd) ==="
    grep -vE '(/sbin/nologin|/bin/false)' /etc/passwd 2>/dev/null || true
    echo ""
    echo "=== Sudoers Group Members ==="
    grep -E '^(sudo|wheel|admin):' /etc/group 2>/dev/null || true
} >> "${DIAG_PATH}/06_security/user_accounts.txt"

# ==============================================================================
# SECTION 7/7 -- SAMPLING
# ==============================================================================
echo "[7/7] 執行 ${DURATION} 秒動態採樣 (每 ${INTERVAL} 秒記錄一次)..."

SAMPLES=$(( DURATION / INTERVAL ))
[ "$SAMPLES" -lt 1 ] && SAMPLES=1

SAMPLE_FILE="${DIAG_PATH}/07_sampling/sampling_${DURATION}s.txt"
write_header "${SAMPLE_FILE}" "Continuous System Sampling" "vmstat and top resource processes over ${DURATION} seconds" "觀察 CPU/Memory 瞬時飆高軌跡"
{
    echo "=== Sampling Config ==="
    echo "Duration: ${DURATION} seconds"
    echo "Interval: ${INTERVAL} seconds"
    echo "Samples : ${SAMPLES}"
    echo "Started : $(date +'%Y-%m-%d %H:%M:%S')"
    echo ""

    if command -v vmstat >/dev/null 2>&1; then
        echo "--- vmstat ${INTERVAL} ${SAMPLES} ---"
        vmstat "${INTERVAL}" "${SAMPLES}" 2>&1
        echo ""
    fi

    echo "--- Periodic Process Snapshot ---"
    for i in $(seq 1 "${SAMPLES}"); do
        echo "--- [Sample ${i}/${SAMPLES}] at $(date +'%H:%M:%S') ---"
        echo "Top 5 CPU:"
        ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -n 6 || ps -ef | head -n 6
        echo "Top 5 Memory:"
        ps -eo pid,user,%cpu,%mem,rss,comm --sort=-%mem 2>/dev/null | head -n 6 || ps -ef | head -n 6
        echo ""
        [ "${i}" -lt "${SAMPLES}" ] && sleep "${INTERVAL}"
    done
} >> "${SAMPLE_FILE}" 2>&1

# ==============================================================================
# GENERATE SUMMARY_FOR_AI.txt
# ==============================================================================
echo ""
echo "正在產生 SUMMARY_FOR_AI.txt 精簡診斷摘要..."
AI_FILE="${DIAG_PATH}/SUMMARY_FOR_AI.txt"

# Extract system stats for summary
DISTRO_NAME="Unknown Linux"
if [ -f /etc/os-release ]; then
    DISTRO_NAME=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')
fi
KERNEL_VER=$(uname -r)
UPTIME_STR=$(uptime -p 2>/dev/null || uptime | sed 's/.*up \([^,]*\), .*/\1/')
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^[ \t]*//' || echo "Unknown CPU")
CPU_COUNT=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")

# Memory calculation
MEM_TOTAL_KB=$(grep -m1 "MemTotal:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
MEM_AVAIL_KB=$(grep -m1 "MemAvailable:" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
if [ "$MEM_TOTAL_KB" -gt 0 ]; then
    MEM_TOTAL_GB=$(awk -v t="$MEM_TOTAL_KB" 'BEGIN {printf "%.1f", t/1048576}')
    MEM_AVAIL_GB=$(awk -v a="$MEM_AVAIL_KB" 'BEGIN {printf "%.1f", a/1048576}')
    MEM_USED_PCT=$(awk -v t="$MEM_TOTAL_KB" -v a="$MEM_AVAIL_KB" 'BEGIN {printf "%.1f", ((t-a)/t)*100}')
else
    MEM_TOTAL_GB="N/A"
    MEM_AVAIL_GB="N/A"
    MEM_USED_PCT="N/A"
fi

cat <<EOF > "${AI_FILE}"
================================================================================
  LINUX GUEST DIAGNOSTIC SUMMARY — FOR AI-ASSISTED ANALYSIS
================================================================================
  Hostname    : ${HOSTNAME_VAL}
  OS          : ${DISTRO_NAME}
  Kernel      : ${KERNEL_VER}
  Collected   : $(date +'%Y-%m-%d %H:%M:%S %Z')
  Uptime      : ${UPTIME_STR}
  Run As Root : ${IS_ADMIN}
================================================================================

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  HOW TO USE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. Share this file with an AI assistant (ChatGPT, Claude, Gemini, etc.)
  2. Use the prompt template in the next section
  3. If the AI needs more detail, share the specific .txt file from the archive

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PROMPT TEMPLATE (copy and paste to AI, then attach this file)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

You are an expert Linux systems administrator and performance engineer.
The attached file is a diagnostic summary from a Linux VM (running in a
KubeVirt / Kubernetes virtualization environment). Please analyze and provide:
  1. Overall system health assessment
  2. Root cause of reported issues (e.g. OOM, CPU spike, disk pressure, hung tasks)
  3. Security or stability concerns
  4. Recommended next steps and remediation

Incident context: [USER: describe symptoms here, e.g. 'high CPU/Memory around 14:00, service unresponsive']

If you need more detail on any area, ask me to share the specific log file
from the diagnostic tarball (e.g. '02_logs/oom_and_kernel_alerts.txt' or '03_processes/process_snapshot.txt').

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [1] SYSTEM IDENTITY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Hostname    : ${HOSTNAME_VAL}
  OS          : ${DISTRO_NAME}
  Kernel      : ${KERNEL_VER}
  Uptime      : ${UPTIME_STR}
  CPU         : ${CPU_MODEL} | Cores: ${CPU_COUNT}
  RAM Total   : ${MEM_TOTAL_GB} GB | Available: ${MEM_AVAIL_GB} GB | Used: ${MEM_USED_PCT}%
  Time Zone   : $(date +'%Z (UTC%:z)')

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [2] ⚠️  AUTO-DETECTED ALERTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

# Detect Alerts
ALERT_COUNT=0

# 1. OOM Killer Check
OOM_COUNT=$(dmesg 2>/dev/null | grep -icE "killed process|oom-killer|out of memory" || echo "0")
if [ "${OOM_COUNT}" -gt 0 ]; then
    echo "  [CRITICAL] OOM Killer triggered! Found ${OOM_COUNT} OOM event(s) in dmesg." >> "${AI_FILE}"
    ALERT_COUNT=$((ALERT_COUNT + 1))
fi

# 2. Disk Space Check (>85%)
while read -r fs size used avail pct mount; do
    pct_num=$(echo "${pct}" | tr -d '%')
    if [ "${pct_num}" -ge 90 ] 2>/dev/null; then
        echo "  [DISK CRITICAL] Mount point '${mount}' is ${pct} full! (Available: ${avail})" >> "${AI_FILE}"
        ALERT_COUNT=$((ALERT_COUNT + 1))
    elif [ "${pct_num}" -ge 80 ] 2>/dev/null; then
        echo "  [DISK WARNING]  Mount point '${mount}' is ${pct} full. (Available: ${avail})" >> "${AI_FILE}"
        ALERT_COUNT=$((ALERT_COUNT + 1))
    fi
done < <(df -hP 2>/dev/null | grep -E '^/dev/' || true)

# 3. Memory pressure alert (>85%)
if [ "${MEM_USED_PCT%.*}" -ge 90 ] 2>/dev/null; then
    echo "  [RAM CRITICAL]  Physical memory usage is ${MEM_USED_PCT}%" >> "${AI_FILE}"
    ALERT_COUNT=$((ALERT_COUNT + 1))
elif [ "${MEM_USED_PCT%.*}" -ge 80 ] 2>/dev/null; then
    echo "  [RAM WARNING]   Physical memory usage is ${MEM_USED_PCT}%" >> "${AI_FILE}"
    ALERT_COUNT=$((ALERT_COUNT + 1))
fi

# 4. Failed Services Alert
if command -v systemctl >/dev/null 2>&1; then
    FAILED_UNITS=$(systemctl --failed --no-legend 2>/dev/null | wc -l || echo "0")
    if [ "${FAILED_UNITS}" -gt 0 ]; then
        echo "  [SERVICE ALERT] ${FAILED_UNITS} systemd unit(s) in failed state!" >> "${AI_FILE}"
        ALERT_COUNT=$((ALERT_COUNT + 1))
    fi
fi

# 5. QEMU Guest Agent Check
if ! ps aux | grep -i '[q]emu-ga' >/dev/null 2>&1; then
    echo "  [QEMU-GA WARN]  qemu-guest-agent process NOT running. KubeVirt/Prometheus metrics may be inaccurate." >> "${AI_FILE}"
    ALERT_COUNT=$((ALERT_COUNT + 1))
fi

# 6. Kernel Soft Lockup / Panic
LOCKUP_COUNT=$(dmesg 2>/dev/null | grep -icE "soft lockup|kernel panic" || echo "0")
if [ "${LOCKUP_COUNT}" -gt 0 ]; then
    echo "  [KERNEL ALERT]  Found ${LOCKUP_COUNT} soft lockup / panic message(s) in dmesg." >> "${AI_FILE}"
    ALERT_COUNT=$((ALERT_COUNT + 1))
fi

if [ "$ALERT_COUNT" -eq 0 ]; then
    echo "  No critical issues auto-detected." >> "${AI_FILE}"
fi

cat <<EOF >> "${AI_FILE}"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [3] TOP RESOURCE CONSUMERS (Current Snapshot)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--- Top 5 CPU Processes ---
$(ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -n 6 || ps -ef | head -n 6)

--- Top 5 Memory Processes (RSS) ---
$(ps -eo pid,user,%cpu,%mem,rss,comm --sort=-%mem 2>/dev/null | head -n 6 || ps -ef | head -n 6)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [4] RECENT CRITICAL LOG EVENTS (Last 10 OOM / Kernel Alerts)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$(dmesg -T 2>/dev/null | grep -iE 'oom|killed process|soft lockup|panic|ext4-fs error|xfs:' | tail -n 10 || echo "  None found in dmesg.")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [5] STORAGE & MOUNTS SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$(df -hT 2>/dev/null | grep -E '^(Filesystem|/dev/)' || df -h 2>/dev/null | head -n 10)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [6] NETWORK & SOCKET SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$(if command -v ss >/dev/null 2>&1; then
    ss -s 2>/dev/null
    echo "Listening TCP Ports: $(ss -tln 2>/dev/null | grep -c LISTEN || echo 'N/A')"
else
    echo "Active Connections: $(netstat -ant 2>/dev/null | wc -l || echo 'N/A')"
fi)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  END OF SUMMARY — See individual files in tarball for full details
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

echo "  -> SUMMARY_FOR_AI.txt 已生成。"

# ==============================================================================
# COMPRESS OUTPUT
# ==============================================================================
echo ""
echo "正在將診斷資料打包成 .tar.gz..."
tar -czf "${ARCHIVE_PATH}" -C "${OUTPUT_DIR}" "${DIAG_ROOT}"
rm -rf "${DIAG_PATH}"

FILE_SIZE=$(ls -lh "${ARCHIVE_PATH}" | awk '{print $5}')

echo ""
echo "========================================================"
echo "  Collection Summary"
echo "========================================================"
echo "  Hostname   : ${HOSTNAME_VAL}"
echo "  Output     : ${ARCHIVE_PATH} (${FILE_SIZE})"
echo "  RunAsRoot  : ${IS_ADMIN}"
echo ""
echo "  Sections collected:"
echo "    [1/7] 01_system    - Hostname, kernel, cpu, memory, qemu-ga, sysctl"
echo "    [2/7] 02_logs      - dmesg, oom alerts, journalctl, failed services"
echo "    [3/7] 03_processes - Top CPU/MEM, pstree, crontab, systemd timers"
echo "    [4/7] 04_network   - IP addresses, routes, ss/netstat, dns, iptables"
echo "    [5/7] 05_storage   - df, lsblk, fstab, diskstats, iostat"
echo "    [6/7] 06_security  - Logged in users, last logins, sudoers"
echo "    [7/7] 07_sampling  - Continuous vmstat and process sampling (${DURATION}s)"
echo ""
echo "Done. 請將 ${ARCHIVE_PATH} 傳回維運團隊。"
echo "========================================================"

```

---

## 維運分析重點

收到 `.tar.gz` 壓縮包後，建議依以下順序進行分析：

1. **`SUMMARY_FOR_AI.txt`** — **首選捷徑**！直接檢視自動偵測之告警項目（OOM 事件、磁碟爆滿、服務失敗），亦可直接整份餵給 AI 助理（ChatGPT / Claude / Gemini）進行即時根因推斷。
2. **`01_system/system_overview.txt`** — 確認時區與核心版本，對齊 Prometheus / Grafana 告警時間。
3. **`02_logs/oom_and_kernel_alerts.txt`** — 搜尋 OOM Killer、Soft Lockup、Segfault 與磁碟 I/O 錯誤，定位行程無預警消失或卡頓的根本原因。
4. **`02_logs/failed_services.txt`** — 檢查是否有系統服務崩潰或未正常拉起。
5. **`03_processes/process_snapshot.txt`** — 檢視事發當下吃最多 CPU 與記憶體的 Top 行程。
6. **`05_storage/disk_usage.txt`** — 確認根目錄 `/`、`/var` 是否 100% 寫滿或 Inode 耗盡。
7. **`07_sampling/sampling_*.txt`** — 檢視動態採樣中的 vmstat（run queue `r`、swap in/out `si/so`、I/O wait `wa`）波動趨勢。

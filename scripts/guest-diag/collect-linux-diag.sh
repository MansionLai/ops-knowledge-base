#!/usr/bin/env bash
# ==============================================================================
# Script: collect-linux-diag.sh
# Description: Collects Linux guest system diagnostic data during CPU/Memory peaks
# Output: /tmp/vm_diag_<hostname>_<timestamp>.tar.gz
# Usage: sudo bash collect-linux-diag.sh [sampling_duration_seconds]
# ==============================================================================

set -u

# Ensure root privileges if possible for full dmesg/system logs access
if [ "$EUID" -ne 0 ]; then
    echo "[WARN] 建議以 root / sudo 權限執行，以收集完整的內核與系統日誌 (dmesg, journalctl)。"
    echo "[INFO] 目前以非 root 身份執行，將盡可能收集所有可讀取的資料..."
fi

# Configurable parameters
DURATION=${1:-30} # Default sampling duration: 30 seconds
INTERVAL=5
SAMPLES=$(( DURATION / INTERVAL ))
[ "$SAMPLES" -lt 1 ] && SAMPLES=1

HOSTNAME_VAL=$(hostname 2>/dev/null || echo "unknown-host")
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
WORK_DIR="/tmp/vm_diag_${HOSTNAME_VAL}_${TIMESTAMP}"
ARCHIVE_PATH="/tmp/vm_diag_${HOSTNAME_VAL}_${TIMESTAMP}.tar.gz"

mkdir -p "${WORK_DIR}"
echo "================================================================="
echo " [KubeVirt Guest Diagnostics] 開始收集系統日誌..."
echo " 臨時目錄: ${WORK_DIR}"
echo " 動態採樣時間: ${DURATION} 秒 (每 ${INTERVAL} 秒採樣一次)"
echo "================================================================="

# 1. 系統基本資訊
echo "[1/7] 收集基本系統資訊..."
{
    echo "=== Hostname & Date ==="
    hostname
    date -u +"UTC: %Y-%m-%d %H:%M:%S"
    date +"Local: %Y-%m-%d %H:%M:%S %Z"
    echo ""
    echo "=== Kernel & OS Release ==="
    uname -a
    [ -f /etc/os-release ] && cat /etc/os-release
    echo ""
    echo "=== CPU Info Summary ==="
    if command -v lscpu >/dev/null 2>&1; then
        lscpu
    else
        grep -E "model name|cpu cores|processor" /proc/cpuinfo || true
    fi
    echo ""
    echo "=== Uptime & Load Average ==="
    uptime
    echo ""
    echo "=== QEMU Guest Agent Status ==="
    if command -v systemctl >/dev/null 2>&1; then
        systemctl status qemu-guest-agent --no-pager 2>&1 || true
    else
        ps aux | grep -i '[q]emu-ga' || echo "qemu-ga not found in process list"
    fi
} > "${WORK_DIR}/system_info.txt" 2>&1

# 2. 記憶體詳細狀態
echo "[2/7] 收集記憶體狀態與分佈..."
{
    echo "=== free -h ==="
    free -h 2>/dev/null || free -m
    echo ""
    echo "=== /proc/meminfo ==="
    cat /proc/meminfo
    echo ""
    echo "=== /proc/vmstat (Partial) ==="
    grep -E "oom|pgpgin|pgpgout|pswpin|pswpout|allocstall" /proc/vmstat 2>/dev/null || true
} > "${WORK_DIR}/memory_details.txt" 2>&1

# 3. 行程快照 (CPU & Memory Top)
echo "[3/7] 擷取當前資源消耗最高的行程快照..."
{
    echo "=== Top 35 Processes by CPU% ==="
    ps aux --sort=-%cpu 2>/dev/null | head -n 36 || ps -ef | head -n 36
    echo ""
    echo "=== Top 35 Processes by Memory% (RSS) ==="
    ps aux --sort=-%mem 2>/dev/null | head -n 36 || ps -ef | head -n 36
} > "${WORK_DIR}/process_snapshot.txt" 2>&1

# 4. 行程樹結構 (Process Tree)
echo "[4/7] 擷取行程樹 (Process Tree)..."
{
    if command -v pstree >/dev/null 2>&1; then
        pstree -ap 2>&1 || true
    else
        ps -ejH 2>&1 || ps -ef 2>&1
    fi
} > "${WORK_DIR}/process_tree.txt" 2>&1

# 5. 儲存與 I/O 狀態
echo "[5/7] 收集磁碟與 I/O 狀態..."
{
    echo "=== Filesystem Usage (df -h) ==="
    df -h
    echo ""
    echo "=== Block Devices (lsblk) ==="
    command -v lsblk >/dev/null 2>&1 && lsblk || true
    echo ""
    echo "=== /proc/diskstats ==="
    cat /proc/diskstats 2>/dev/null || true
} > "${WORK_DIR}/disk_io.txt" 2>&1

# 6. 核心日誌與 OOM Killer 檢查
echo "[6/7] 檢查 OOM Killer 與內核告警 (dmesg / journalctl)..."
{
    echo "=== OOM Killer & Memory Pressure Search ==="
    dmesg -T 2>/dev/null | grep -iE 'oom|out of memory|killed process|page fault|throttle|mce|segfault' | tail -n 100 || true
    echo ""
    echo "=== System Warnings & Errors (journalctl last 300 entries) ==="
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -p 4 -n 300 --no-pager 2>&1 || true
    elif [ -f /var/log/messages ]; then
        tail -n 300 /var/log/messages
    elif [ -f /var/log/syslog ]; then
        tail -n 300 /var/log/syslog
    fi
} > "${WORK_DIR}/oom_and_kernel_alerts.txt" 2>&1

# 匯出完整 dmesg 以備深入查閱
dmesg -T > "${WORK_DIR}/dmesg_full.txt" 2>/dev/null || true

# 7. 動態時間窗口採樣
echo "[7/7] 開始進行 ${DURATION} 秒動態採樣 (每 ${INTERVAL} 秒記錄一次)..."
{
    echo "=== Continuous Sampling (Duration: ${DURATION}s, Interval: ${INTERVAL}s) ==="
    date
    echo ""
    if command -v vmstat >/dev/null 2>&1; then
        echo "--- vmstat ${INTERVAL} ${SAMPLES} ---"
        vmstat "${INTERVAL}" "${SAMPLES}"
        echo ""
    fi

    echo "--- Periodic Process Samples ---"
    for i in $(seq 1 "${SAMPLES}"); do
        echo "--- Sample ${i}/${SAMPLES} at $(date +'%H:%M:%S') ---"
        echo "Top 5 CPU:"
        ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu | head -n 6
        echo "Top 5 Memory:"
        ps -eo pid,user,%cpu,%mem,rss,comm --sort=-%mem | head -n 6
        echo ""
        [ "${i}" -lt "${SAMPLES}" ] && sleep "${INTERVAL}"
    done
} > "${WORK_DIR}/sampling_${DURATION}s.txt" 2>&1

# 打包壓縮
echo "正在壓縮打包診斷日誌..."
tar -czf "${ARCHIVE_PATH}" -C /tmp "vm_diag_${HOSTNAME_VAL}_${TIMESTAMP}"
rm -rf "${WORK_DIR}"

echo ""
echo "================================================================="
echo " [完成] 診斷資料已成功打包！"
echo " 輸出檔案: ${ARCHIVE_PATH}"
echo " 檔案大小: $(ls -lh "${ARCHIVE_PATH}" | awk '{print $5}')"
echo " 請將此壓縮檔傳回給維運團隊進行分析。"
echo "================================================================="

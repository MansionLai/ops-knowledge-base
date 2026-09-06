<#
.SYNOPSIS
    KubeVirt Windows Guest System Diagnostics Collector
.DESCRIPTION
    Collects system metrics, high CPU/Memory processes, event logs, and dynamic samples
    during resource peak incidents, packaging them into a single zip archive.
.PARAMETER SampleDurationSeconds
    Duration to perform continuous sampling (default: 30 seconds).
.PARAMETER SampleIntervalSeconds
    Interval between dynamic samples (default: 5 seconds).
.EXAMPLE
    .\collect-windows-diag.ps1
    .\collect-windows-diag.ps1 -SampleDurationSeconds 60
#>

[CmdletBinding()]
param(
    [int]$SampleDurationSeconds = 30,
    [int]$SampleIntervalSeconds = 5
)

$ErrorActionPreference = "Continue"

# Check Admin Privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "建議以「系統管理員身分執行」(Run as Administrator) PowerShell，以利讀取完整的系統事件日誌與行程詳細資訊。"
}

$computerName = $env:COMPUTERNAME
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$workDir = Join-Path $env:TEMP "vm_diag_${computerName}_${timestamp}"
$archivePath = Join-Path $env:TEMP "vm_diag_${computerName}_${timestamp}.zip"

New-Item -ItemType Directory -Path $workDir -Force | Out-Null

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " [KubeVirt Guest Diagnostics - Windows] 開始收集診斷資訊..." -ForegroundColor Cyan
Write-Host " 暫存目錄: $workDir"
Write-Host " 動態採樣時間: $SampleDurationSeconds 秒 (每 $SampleIntervalSeconds 秒採樣一次)"
Write-Host "================================================================="

# 1. 系統基本資訊
Write-Host "[1/6] 收集系統基本資訊與硬體規格..."
$sysInfoFile = Join-Path $workDir "system_info.txt"
& {
    Write-Output "=== 基本資訊與時間 ==="
    Write-Output "電腦名稱: $computerName"
    Write-Output "UTC 時間: $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Output "本地時間: $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
    Write-Output ""

    Write-Output "=== 作業系統與開機時間 ==="
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Output "OS: $($os.Caption) ($($os.Version) Build $($os.BuildNumber))"
    Write-Output "架構: $($os.OSArchitecture)"
    Write-Output "最後開機時間: $($os.LastBootUpTime)"
    $uptime = (Get-Date) - $os.LastBootUpTime
    Write-Output "已運行時間: $($uptime.Days) 天 $($uptime.Hours) 小時 $($uptime.Minutes) 分鐘"
    Write-Output ""

    Write-Output "=== 處理器 (CPU) 規格 ==="
    $cpus = Get-CimInstance Win32_Processor
    foreach ($cpu in $cpus) {
        Write-Output "名稱: $($cpu.Name)"
        Write-Output "核心數: $($cpu.NumberOfCores), 邏輯處理器數: $($cpu.NumberOfLogicalProcessors), 當前負載: $($cpu.LoadPercentage)%"
    }
    Write-Output ""

    Write-Output "=== 記憶體 (RAM) 總覽 ==="
    $totalRamMB = [math]::Round($os.TotalVisibleMemorySize / 1KB, 2)
    $freeRamMB = [math]::Round($os.FreePhysicalMemory / 1KB, 2)
    $usedRamMB = [math]::Round($totalRamMB - $freeRamMB, 2)
    $ramUsagePercent = [math]::Round(($usedRamMB / $totalRamMB) * 100, 2)
    Write-Output "實體記憶體總量: $totalRamMB MB"
    Write-Output "已使用記憶體: $usedRamMB MB ($ramUsagePercent%)"
    Write-Output "可用實體記憶體: $freeRamMB MB"
    Write-Output ""

    Write-Output "=== 分頁檔 (Pagefile) 狀態 ==="
    Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage | Format-Table -AutoSize | Out-String
    Write-Output ""

    Write-Output "=== QEMU Guest Agent 狀態 ==="
    $qemuService = Get-Service -Name "QEMU-GA", "qemu-ga" -ErrorAction SilentlyContinue
    if ($qemuService) {
        $qemuService | Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize | Out-String
    } else {
        Write-Output "警告: 未偵測到 QEMU-GA (QEMU Guest Agent) 服務！若未安裝，Hypervisor 將無法取得精準 Guest 記憶體指標。"
    }
} | Out-File -FilePath $sysInfoFile -Encoding utf8

# 2. 行程快照 (CPU & Memory Top 30)
Write-Host "[2/6] 擷取當前最高 CPU 與記憶體行程快照..."
$procSnapshotFile = Join-Path $workDir "process_snapshot.txt"
& {
    Write-Output "=== Top 30 Processes by CPU Time ==="
    Get-Process | Sort-Object CPU -Descending | Select-Object -First 30 Id, ProcessName, `
        @{Name="CPU_Time(s)";Expression={[math]::Round($_.CPU,2)}}, `
        @{Name="WorkingSet_MB";Expression={[math]::Round($_.WorkingSet64/1MB,2)}}, `
        @{Name="PrivateMem_MB";Expression={[math]::Round($_.PrivateMemorySize64/1MB,2)}}, `
        Handles, Path | Format-Table -AutoSize | Out-String

    Write-Output ""
    Write-Output "=== Top 30 Processes by Memory (Working Set) ==="
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 30 Id, ProcessName, `
        @{Name="WorkingSet_MB";Expression={[math]::Round($_.WorkingSet64/1MB,2)}}, `
        @{Name="PrivateMem_MB";Expression={[math]::Round($_.PrivateMemorySize64/1MB,2)}}, `
        @{Name="CPU_Time(s)";Expression={[math]::Round($_.CPU,2)}}, `
        Handles, Path | Format-Table -AutoSize | Out-String
} | Out-File -FilePath $procSnapshotFile -Encoding utf8

# 3. 完整行程清單
Write-Host "[3/6] 匯出所有執行中行程清單..."
$allProcFile = Join-Path $workDir "process_list_all.csv"
Get-Process | Select-Object Id, ProcessName, CPU, WorkingSet64, PrivateMemorySize64, Handles, Path | `
    Export-Csv -Path $allProcFile -NoTypeInformation -Encoding utf8

# 4. 磁碟空間
Write-Host "[4/6] 收集磁碟使用量..."
$diskFile = Join-Path $workDir "disk_info.txt"
Get-CimInstance Win32_LogicalDisk | Select-Object DeviceID, VolumeName, FileSystem, `
    @{Name="Size(GB)";Expression={[math]::Round($_.Size/1GB,2)}}, `
    @{Name="FreeSpace(GB)";Expression={[math]::Round($_.FreeSpace/1GB,2)}}, `
    @{Name="Free(%)";Expression={[math]::Round(($_.FreeSpace/$_.Size)*100,2)}} | `
    Format-Table -AutoSize | Out-File -FilePath $diskFile -Encoding utf8

# 5. 事件日誌檢查 (System & Application - 最近 24 小時的 Warning / Error)
Write-Host "[5/6] 收集 Windows 事件日誌 (最近 24 小時 Warning / Error / OOM)..."
$eventLogFile = Join-Path $workDir "event_logs.txt"
& {
    $sinceTime = (Get-Date).AddHours(-24)
    Write-Output "=== 搜尋 Resource-Exhaustion-Detector (低記憶體事件 ID 2004) ==="
    try {
        $memEvents = Get-WinEvent -FilterHashtable @{LogName='System'; Id=2004; StartTime=$sinceTime} -ErrorAction SilentlyContinue
        if ($memEvents) {
            foreach ($e in $memEvents) {
                Write-Output "[$($e.TimeCreated)] ID: $($e.Id) - $($e.Message)"
                Write-Output "------------------------------------------------------------------"
            }
        } else {
            Write-Output "過去 24 小時內未發現 Event ID 2004 (系統未觸發嚴重低虛擬記憶體警告)。"
        }
    } catch {
        Write-Output "無法查詢 Event 2004: $_"
    }

    Write-Output ""
    Write-Output "=== 系統事件 (System Logs - 最近 100 筆 Warning / Error / Critical) ==="
    try {
        Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2,3; StartTime=$sinceTime} -MaxEvents 100 -ErrorAction SilentlyContinue | `
            Select-Object TimeCreated, LevelDisplayName, ProviderName, Id, Message | `
            Format-List | Out-String
    } catch {
        Write-Output "無符合條件之 System 事件或權限不足。"
    }

    Write-Output ""
    Write-Output "=== 應用程式事件 (Application Logs - 最近 100 筆 Error / Critical) ==="
    try {
        Get-WinEvent -FilterHashtable @{LogName='Application'; Level=1,2; StartTime=$sinceTime} -MaxEvents 100 -ErrorAction SilentlyContinue | `
            Select-Object TimeCreated, LevelDisplayName, ProviderName, Id, Message | `
            Format-List | Out-String
    } catch {
        Write-Output "無符合條件之 Application 事件或權限不足。"
    }
} | Out-File -FilePath $eventLogFile -Encoding utf8

# 6. 動態連續採樣 (Sampling Loop)
Write-Host "[6/6] 進行 $SampleDurationSeconds 秒動態採樣 (每 $SampleIntervalSeconds 秒採樣一次)..."
$samplingFile = Join-Path $workDir "sampling_${SampleDurationSeconds}s.txt"
$samplesCount = [math]::Max(1, [math]::Floor($SampleDurationSeconds / $SampleIntervalSeconds))

& {
    Write-Output "=== 動態資源負載採樣 (總時間: ${SampleDurationSeconds}s, 間隔: ${SampleIntervalSeconds}s) ==="
    for ($i = 1; $i -le $samplesCount; $i++) {
        $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $cpuPct = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $memFree = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB

        Write-Output "--- Sample [$i/$samplesCount] at $now | CPU 總負載: $cpuPct% | 剩餘記憶體: $([math]::Round($memFree, 1)) MB ---"
        Write-Output "Top 5 CPU Processes:"
        Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 Id, ProcessName, @{Name="CPU(s)";Expression={[math]::Round($_.CPU,2)}}, @{Name="WS(MB)";Expression={[math]::Round($_.WorkingSet64/1MB,1)}} | Format-Table -AutoSize | Out-String
        Write-Output "Top 5 Memory (Working Set) Processes:"
        Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 Id, ProcessName, @{Name="WS(MB)";Expression={[math]::Round($_.WorkingSet64/1MB,1)}}, @{Name="Private(MB)";Expression={[math]::Round($_.PrivateMemorySize64/1MB,1)}} | Format-Table -AutoSize | Out-String

        if ($i -lt $samplesCount) {
            Start-Sleep -Seconds $SampleIntervalSeconds
        }
    }
} | Out-File -FilePath $samplingFile -Encoding utf8

# 壓縮打包
Write-Host "正在壓縮打包診斷日誌..."
if (Test-Path $archivePath) { Remove-Item $archivePath -Force }
Compress-Archive -Path "$workDir\*" -DestinationPath $archivePath -Force
Remove-Item -Path $workDir -Recurse -Force

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host " [完成] Windows 診斷日誌已成功打包！" -ForegroundColor Green
Write-Host " 輸出檔案: $archivePath" -ForegroundColor Green
Write-Host " 請將此 ZIP 壓縮檔傳回給維運團隊進行分析。" -ForegroundColor Yellow
Write-Host "=================================================================" -ForegroundColor Green

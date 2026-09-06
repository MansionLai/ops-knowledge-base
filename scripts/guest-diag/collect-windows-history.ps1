<#
.SYNOPSIS
    KubeVirt Windows Guest - Historical Incident Log Collector
.DESCRIPTION
    Retroactively collects Windows Event Logs, Reliability Monitor data,
    Scheduled Task history, and WER crash reports for a specified time window.
    Use this when the user reports an incident that occurred days ago.
.PARAMETER StartTime
    Start of the incident window. Format: "yyyy-MM-dd HH:mm" (local time)
    Default: 3 days ago at 00:00
.PARAMETER EndTime
    End of the incident window. Format: "yyyy-MM-dd HH:mm" (local time)
    Default: now
.EXAMPLE
    # Collect logs for a specific 4-hour incident window
    .\collect-windows-history.ps1 -StartTime "2026-09-04 09:00" -EndTime "2026-09-04 13:00"
    # Collect logs for past 3 days (default)
    .\collect-windows-history.ps1
#>

[CmdletBinding()]
param(
    [string]$StartTime = "",
    [string]$EndTime   = ""
)

$ErrorActionPreference = "Continue"

# Resolve time range
if ([string]::IsNullOrEmpty($StartTime)) {
    $startDt = (Get-Date).AddDays(-3).Date
} else {
    $startDt = [datetime]::ParseExact($StartTime, "yyyy-MM-dd HH:mm", $null)
}
if ([string]::IsNullOrEmpty($EndTime)) {
    $endDt = Get-Date
} else {
    $endDt = [datetime]::ParseExact($EndTime, "yyyy-MM-dd HH:mm", $null)
}

# Check Admin Privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "建議以「系統管理員身分執行」PowerShell，部分 Event Log 和 WER 資料需要管理員權限。"
}

$computerName = $env:COMPUTERNAME
$timestamp    = Get-Date -Format "yyyyMMdd_HHmmss"
$workDir      = Join-Path $env:TEMP "vm_history_${computerName}_${timestamp}"
$archivePath  = Join-Path $env:TEMP "vm_history_${computerName}_${timestamp}.zip"

New-Item -ItemType Directory -Path $workDir -Force | Out-Null

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " [Windows Historical Incident Collector]" -ForegroundColor Cyan
Write-Host " 電腦名稱 : $computerName"
Write-Host " 查詢起始 : $($startDt.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host " 查詢結束 : $($endDt.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host " 暫存目錄 : $workDir"
Write-Host "================================================================="

# ===========================================================================
# [1] 系統基本資訊（時區確認用）
# ===========================================================================
Write-Host "[1/5] 收集系統基本資訊..."
$sysInfoFile = Join-Path $workDir "system_info.txt"
& {
    Write-Output "=== 時區與時間（請確認與報案時間是否一致）==="
    [System.TimeZoneInfo]::Local | Select-Object Id, DisplayName, BaseUtcOffset | Format-List
    Write-Output "目前本地時間: $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss zzz'))"
    Write-Output "目前 UTC 時間: $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Output ""
    Write-Output "=== OS 版本 ==="
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Output "$($os.Caption) $($os.Version) Build $($os.BuildNumber) [$($os.OSArchitecture)]"
    Write-Output "最後開機時間: $($os.LastBootUpTime)"
} | Out-File $sysInfoFile -Encoding utf8

# ===========================================================================
# [2] 關鍵 Event ID 歷史查詢（記憶體 / 崩潰 / 異常關機 / Hang）
# ===========================================================================
Write-Host "[2/5] 查詢關鍵 Event ID 歷史記錄..."
$eventFile = Join-Path $workDir "critical_events.txt"
& {
    $filter = @{ StartTime = $startDt; EndTime = $endDt }

    # ── Memory Pressure ──────────────────────────────────────────────────
    Write-Output "========================================================"
    Write-Output "  EVENT ID 2004 - Resource Exhaustion Detector"
    Write-Output "  (虛擬記憶體嚴重不足，Windows 自動記錄當時前 3 名元兇)"
    Write-Output "========================================================"
    try {
        $evts = Get-WinEvent -FilterHashtable (@{ LogName='System'; Id=2004 } + $filter) -EA SilentlyContinue
        if ($evts) {
            foreach ($e in $evts) {
                Write-Output ""
                Write-Output ">>> 時間: $($e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))"
                Write-Output $e.Message
                Write-Output "---"
            }
        } else { Write-Output "查詢區間內無此事件。" }
    } catch { Write-Output "查詢失敗: $_" }

    # ── Unexpected Shutdown / Reboot ──────────────────────────────────────
    Write-Output ""
    Write-Output "========================================================"
    Write-Output "  EVENT ID 41 - Kernel-Power（非預期關機/重啟，可能由 OOM 導致）"
    Write-Output "  EVENT ID 6008 - Unexpected Shutdown（異常關機紀錄）"
    Write-Output "========================================================"
    foreach ($eid in @(41, 6008)) {
        try {
            $evts = Get-WinEvent -FilterHashtable (@{ LogName='System'; Id=$eid } + $filter) -EA SilentlyContinue
            if ($evts) {
                foreach ($e in $evts) {
                    Write-Output ""
                    Write-Output ">>> [ID $eid] 時間: $($e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))"
                    Write-Output $e.Message
                    Write-Output "---"
                }
            } else { Write-Output "[ID $eid] 查詢區間內無此事件。" }
        } catch { Write-Output "[ID $eid] 查詢失敗: $_" }
    }

    # ── BSOD ──────────────────────────────────────────────────────────────
    Write-Output ""
    Write-Output "========================================================"
    Write-Output "  EVENT ID 1001 - BugCheck（藍屏/BSOD）"
    Write-Output "========================================================"
    try {
        $evts = Get-WinEvent -FilterHashtable (@{ LogName='Application'; Id=1001; ProviderName='Windows Error Reporting' } + $filter) -EA SilentlyContinue
        if ($evts) {
            foreach ($e in $evts) {
                Write-Output ""
                Write-Output ">>> 時間: $($e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))"
                Write-Output $e.Message
                Write-Output "---"
            }
        } else { Write-Output "查詢區間內無 BSOD 事件。" }
    } catch { Write-Output "查詢失敗: $_" }

    # ── Application Hang ─────────────────────────────────────────────────
    Write-Output ""
    Write-Output "========================================================"
    Write-Output "  EVENT ID 1002 - Application Hang（程式無回應，可能因 CPU/Memory 資源耗盡）"
    Write-Output "========================================================"
    try {
        $evts = Get-WinEvent -FilterHashtable (@{ LogName='Application'; Id=1002 } + $filter) -EA SilentlyContinue
        if ($evts) {
            foreach ($e in $evts) {
                Write-Output ""
                Write-Output ">>> 時間: $($e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))"
                Write-Output $e.Message
                Write-Output "---"
            }
        } else { Write-Output "查詢區間內無 Application Hang 事件。" }
    } catch { Write-Output "查詢失敗: $_" }

    # ── Application Crash ─────────────────────────────────────────────────
    Write-Output ""
    Write-Output "========================================================"
    Write-Output "  EVENT ID 1000 - Application Error（程式崩潰）"
    Write-Output "========================================================"
    try {
        $evts = Get-WinEvent -FilterHashtable (@{ LogName='Application'; Id=1000 } + $filter) -EA SilentlyContinue
        if ($evts) {
            foreach ($e in $evts) {
                Write-Output ""
                Write-Output ">>> 時間: $($e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))"
                Write-Output $e.Message
                Write-Output "---"
            }
        } else { Write-Output "查詢區間內無應用程式崩潰事件。" }
    } catch { Write-Output "查詢失敗: $_" }

    # ── Service Crash ──────────────────────────────────────────────────────
    Write-Output ""
    Write-Output "========================================================"
    Write-Output "  EVENT ID 7034 - Service Control Manager（服務意外終止）"
    Write-Output "========================================================"
    try {
        $evts = Get-WinEvent -FilterHashtable (@{ LogName='System'; Id=7034 } + $filter) -EA SilentlyContinue
        if ($evts) {
            foreach ($e in $evts) {
                Write-Output ""
                Write-Output ">>> 時間: $($e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))"
                Write-Output $e.Message
                Write-Output "---"
            }
        } else { Write-Output "查詢區間內無服務意外終止事件。" }
    } catch { Write-Output "查詢失敗: $_" }

    # ── Planned Shutdown / Restart ─────────────────────────────────────────
    Write-Output ""
    Write-Output "========================================================"
    Write-Output "  EVENT ID 1074 - 主動重啟/關機紀錄"
    Write-Output "========================================================"
    try {
        $evts = Get-WinEvent -FilterHashtable (@{ LogName='System'; Id=1074 } + $filter) -EA SilentlyContinue
        if ($evts) {
            foreach ($e in $evts) {
                Write-Output ""
                Write-Output ">>> 時間: $($e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))"
                Write-Output $e.Message
                Write-Output "---"
            }
        } else { Write-Output "查詢區間內無主動關機紀錄。" }
    } catch { Write-Output "查詢失敗: $_" }

} | Out-File $eventFile -Encoding utf8

# ===========================================================================
# [3] Reliability Monitor 歷史紀錄（28 天）
# ===========================================================================
Write-Host "[3/5] 匯出 Reliability Monitor 歷史（28 天）..."
$relFile = Join-Path $workDir "reliability_history.txt"
& {
    Write-Output "=== Reliability Monitor - 過去 28 天事件清單 ==="
    Write-Output "（可與報案時間交叉比對：是否有 Application Failure / Windows Failure）"
    Write-Output ""
    try {
        $relEvents = Get-WinEvent -LogName "Microsoft-Windows-Reliability-Analysis-WMI/Operational" -EA SilentlyContinue
        if (-not $relEvents) {
            # Fallback: use COM object for ReliabilityHistory
            $ra = New-Object -ComObject "Microsoft.Windows.ReliabilityAnalysis"
            Write-Output "COM object 方式不支援直接輸出，請手動開啟：開始 > 搜尋「可靠性記錄」(perfmon /rel)"
        } else {
            $relEvents | Where-Object { $_.TimeCreated -ge $startDt -and $_.TimeCreated -le $endDt } |
                Select-Object TimeCreated, LevelDisplayName, Message |
                Format-List | Out-String
        }
    } catch {
        Write-Output "備用方式：透過 Get-WinEvent 查詢 Application/System 事件代替 Reliability Monitor。"
        Write-Output "(若需圖形化介面，請執行: perfmon /rel)"
    }

    Write-Output ""
    Write-Output "=== 區間內所有 System + Application Warning/Error/Critical 彙整 ==="
    Write-Output "（此為完整告警時間軸，可用來重建事件序列）"
    Write-Output ""
    try {
        $allEvts = @()
        $allEvts += Get-WinEvent -FilterHashtable (@{ LogName='System'; Level=1,2,3 } + @{ StartTime=$startDt; EndTime=$endDt }) -EA SilentlyContinue
        $allEvts += Get-WinEvent -FilterHashtable (@{ LogName='Application'; Level=1,2,3 } + @{ StartTime=$startDt; EndTime=$endDt }) -EA SilentlyContinue
        $allEvts | Sort-Object TimeCreated |
            Select-Object TimeCreated, LogName, LevelDisplayName, ProviderName, Id,
                @{Name="Summary"; Expression={ ($_.Message -split "`n")[0] }} |
            Format-Table -AutoSize | Out-String
    } catch { Write-Output "查詢失敗: $_" }
} | Out-File $relFile -Encoding utf8

# ===========================================================================
# [4] Scheduled Task 執行歷史（排程任務是否在異常時間點觸發）
# ===========================================================================
Write-Host "[4/5] 查詢排程任務執行歷史..."
$taskFile = Join-Path $workDir "scheduled_tasks_history.txt"
& {
    Write-Output "=== 排程任務（Scheduled Tasks）執行歷史 ==="
    Write-Output "查詢區間: $($startDt.ToString('yyyy-MM-dd HH:mm')) ~ $($endDt.ToString('yyyy-MM-dd HH:mm'))"
    Write-Output "(排程任務突然執行可能是 CPU / Disk spike 的根因，例如備份、掃毒、更新)"
    Write-Output ""
    try {
        $taskEvts = Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" `
            -FilterXPath "*[System[TimeCreated[@SystemTime>='$($startDt.ToUniversalTime().ToString("o"))' and @SystemTime<='$($endDt.ToUniversalTime().ToString("o"))']]]" `
            -EA SilentlyContinue |
            Where-Object { $_.Id -in @(100, 102, 103, 200, 201, 202) }
        # ID 100=Task started, 102=Task completed, 200=Action started, 201=Action completed
        if ($taskEvts) {
            $taskEvts | Sort-Object TimeCreated |
                Select-Object TimeCreated, Id,
                    @{Name="TaskName"; Expression={ $_.Properties[0].Value }},
                    @{Name="Info"; Expression={ ($_.Message -split "`n")[0] }} |
                Format-Table -AutoSize | Out-String
        } else {
            Write-Output "查詢區間內無排程任務執行紀錄（或 Task Scheduler 歷史記錄未啟用）。"
            Write-Output "提示：若要啟用，請在工作排程器中開啟「啟用所有工作歷程記錄」。"
        }
    } catch { Write-Output "查詢失敗（可能需要管理員權限）: $_" }
} | Out-File $taskFile -Encoding utf8

# ===========================================================================
# [5] Windows Error Reporting (WER) Crash Dump 清單
# ===========================================================================
Write-Host "[5/5] 查詢 WER Crash Report 清單..."
$werFile = Join-Path $workDir "wer_crash_reports.txt"
& {
    Write-Output "=== Windows Error Reporting (WER) 崩潰報告 ==="
    Write-Output "查詢區間: $($startDt.ToString('yyyy-MM-dd HH:mm')) ~ $($endDt.ToString('yyyy-MM-dd HH:mm'))"
    Write-Output ""

    $werPaths = @(
        "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive",
        "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue",
        "C:\ProgramData\Microsoft\Windows\WER\ReportArchive",
        "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"
    )

    $found = $false
    foreach ($path in $werPaths) {
        if (Test-Path $path) {
            $reports = Get-ChildItem -Path $path -Directory -EA SilentlyContinue |
                Where-Object { $_.CreationTime -ge $startDt -and $_.CreationTime -le $endDt }
            if ($reports) {
                $found = $true
                Write-Output "路徑: $path"
                foreach ($r in $reports) {
                    Write-Output ""
                    Write-Output "  崩潰報告目錄: $($r.Name)  (建立時間: $($r.CreationTime))"
                    $reportFiles = Get-ChildItem $r.FullName -EA SilentlyContinue
                    foreach ($f in $reportFiles) {
                        Write-Output "    $($f.Name)  [$([math]::Round($f.Length/1KB,1)) KB]"
                    }
                    # 嘗試讀取 Report.wer 摘要
                    $werReport = Join-Path $r.FullName "Report.wer"
                    if (Test-Path $werReport) {
                        Write-Output "  --- Report.wer 摘要 ---"
                        Get-Content $werReport -EA SilentlyContinue | Select-String "AppName|AppVersion|AppPath|FaultModule|ExceptionCode" | Select-Object -First 10 | Out-String
                    }
                }
            }
        }
    }
    if (-not $found) {
        Write-Output "查詢區間內無 WER 崩潰報告（或無管理員權限存取 ProgramData 目錄）。"
    }

    Write-Output ""
    Write-Output "=== 提示：若需要完整的 Memory Dump 分析 ==="
    Write-Output "Mini dump 路徑: C:\Windows\Minidump\"
    Get-ChildItem "C:\Windows\Minidump\" -EA SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $startDt -and $_.LastWriteTime -le $endDt } |
        Select-Object Name, LastWriteTime, @{Name="Size(KB)";Expression={[math]::Round($_.Length/1KB,1)}} |
        Format-Table -AutoSize | Out-String
} | Out-File $werFile -Encoding utf8

# ===========================================================================
# 打包壓縮
# ===========================================================================
Write-Host ""
Write-Host "正在壓縮打包歷史診斷日誌..."
if (Test-Path $archivePath) { Remove-Item $archivePath -Force }
Compress-Archive -Path "$workDir\*" -DestinationPath $archivePath -Force
Remove-Item -Path $workDir -Recurse -Force

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host " [完成] Windows 歷史診斷日誌已成功打包！" -ForegroundColor Green
Write-Host " 輸出檔案: $archivePath" -ForegroundColor Green
Write-Host " 請將此 ZIP 壓縮檔傳回給維運團隊進行分析。" -ForegroundColor Yellow
Write-Host "=================================================================" -ForegroundColor Green

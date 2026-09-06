# windows-diag.ps1
# General-purpose Windows Guest Diagnostic Collector
# Collects: System Info, Event Logs, Processes, Network, Storage, Security, Software, Crash Reports
# Output: <OutputPath>\vm_diag_<ComputerName>_<timestamp>.zip
# Usage: powershell -ExecutionPolicy Bypass -File windows-diag.ps1
#        powershell -ExecutionPolicy Bypass -File windows-diag.ps1 -StartTime "2026-09-04 09:00" -EndTime "2026-09-04 13:00"
#        powershell -ExecutionPolicy Bypass -File windows-diag.ps1 -StartTime "2026-09-04 09:00" -EndTime "2026-09-04 13:00" -OutputPath "C:\Diag"
#
# Notes:
#   - Run as Administrator for full data collection (script warns but continues if not admin)
#   - No external dependencies: pure PowerShell built-in cmdlets only
#   - ErrorAction SilentlyContinue is used throughout to avoid stopping on permission errors
#   - Event logs are filtered by StartTime/EndTime parameters

param(
    [string]$StartTime  = "",   # "yyyy-MM-dd HH:mm", default: 7 days ago
    [string]$EndTime    = "",   # "yyyy-MM-dd HH:mm", default: now
    [string]$OutputPath = ""    # Output base directory, default: $env:TEMP
)

Set-StrictMode -Off
$ErrorActionPreference = "SilentlyContinue"

# Detect OS type for compatibility branching
$OSInfo       = Get-CimInstance Win32_OperatingSystem
$OSCaption    = $OSInfo.Caption
$OSBuild      = [int]$OSInfo.BuildNumber
$IsServerOS   = $OSCaption -match "Server"
$IsWin11      = (-not $IsServerOS) -and $OSBuild -ge 22000
$IsWin2019    = $OSCaption -match "2019"
$IsWin2022    = $OSCaption -match "2022"
$IsWin2025    = $OSCaption -match "2025"

# ---------------------------------------------------------------------------
# 0. INITIALIZATION
# ---------------------------------------------------------------------------

$ScriptVersion  = "1.0.0"
$Timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$ComputerName   = $env:COMPUTERNAME
$DiagRoot       = "vm_diag_${ComputerName}_${Timestamp}"
$PermissionErrors = [System.Collections.Generic.List[string]]::new()

# Resolve output path: default to same directory as the script
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = $PSScriptRoot }
$DiagPath = Join-Path $OutputPath $DiagRoot

# Parse time range
$Now = Get-Date
if ([string]::IsNullOrWhiteSpace($StartTime)) {
    $dtStart = $Now.AddDays(-7)
} else {
    $dtStart = [datetime]::ParseExact($StartTime, "yyyy-MM-dd HH:mm", $null)
}
if ([string]::IsNullOrWhiteSpace($EndTime)) {
    $dtEnd = $Now
} else {
    $dtEnd = [datetime]::ParseExact($EndTime, "yyyy-MM-dd HH:mm", $null)
}

# Admin check
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Windows Guest Diagnostic Collector v$ScriptVersion" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Computer  : $ComputerName"
Write-Host "  StartTime : $($dtStart.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "  EndTime   : $($dtEnd.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "  OutputPath: $OutputPath"
Write-Host "  Admin     : $IsAdmin"
if (-not $IsAdmin) {
    Write-Host "  [WARNING] Not running as Administrator. Some data may be incomplete." -ForegroundColor Yellow
}
Write-Host ""

# Create directory tree
$Sections = @(
    "01_system", "02_event_logs", "03_processes",
    "04_network", "05_storage",   "06_security",
    "07_software","08_crash_reports"
)
foreach ($s in $Sections) {
    New-Item -ItemType Directory -Path (Join-Path $DiagPath $s) -Force | Out-Null
}

# Helper: write a file header banner
function Write-FileHeader {
    param([string]$FilePath, [string]$Title, [string]$Description, [string]$AnalysisTip = "")
    $banner = @"
================================================================================
  $Title
================================================================================
  Description : $Description
  Analysis Tip: $AnalysisTip
  Collected At: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Computer    : $ComputerName
================================================================================

"@
    Set-Content -Path $FilePath -Value $banner -Encoding UTF8
}

# Helper: append output or an error note
function Invoke-CollectBlock {
    param([string]$FilePath, [scriptblock]$Block)
    try {
        $result = & $Block 2>&1
        Add-Content -Path $FilePath -Value $result -Encoding UTF8
    } catch {
        $msg = "[COLLECTION ERROR] $($_.Exception.Message)"
        Add-Content -Path $FilePath -Value $msg -Encoding UTF8
        $PermissionErrors.Add("$FilePath : $($_.Exception.Message)")
    }
}

# Helper: collect a named event log
function Get-FilteredWinEvent {
    param([string]$LogName, [string]$FilePath, [int[]]$EventIds = @())
    try {
        $filter = @{ LogName = $LogName; StartTime = $dtStart; EndTime = $dtEnd }
        if ($EventIds.Count -gt 0) { $filter["Id"] = $EventIds }
        $events = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop |
            Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message
        if ($events) {
            foreach ($e in $events) {
                $line = "[{0}] [{1}] [{2}] [{3}] {4}" -f `
                    $e.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss"), $e.Id,
                    $e.LevelDisplayName, $e.ProviderName,
                    ($e.Message -replace "`r`n|`n", " " | ForEach-Object { $_.Substring(0, [Math]::Min($_.Length,300)) })
                Add-Content -Path $FilePath -Value $line -Encoding UTF8
            }
            Add-Content -Path $FilePath -Value "`n[Total events: $($events.Count)]" -Encoding UTF8
        } else {
            Add-Content -Path $FilePath -Value "[No events found in the specified time range]" -Encoding UTF8
        }
    } catch {
        $msg = "[LOG ERROR] LogName='$LogName' : $($_.Exception.Message)"
        Add-Content -Path $FilePath -Value $msg -Encoding UTF8
        $PermissionErrors.Add("$FilePath ($LogName): $($_.Exception.Message)")
    }
}

# ===========================================================================
# SECTION 1/8 -- SYSTEM
# ===========================================================================
Write-Host "[1/8] Collecting system information..." -ForegroundColor Green

# 1a. system_overview.txt
$f = Join-Path $DiagPath "01_system\system_overview.txt"
Write-FileHeader $f "System Overview" `
    "OS version, timezone, uptime, boot time, basic system identifiers." `
    "Check OS version for patch baseline, boot time to confirm recent reboots."
Invoke-CollectBlock $f {
    "--- systeminfo ---"
    systeminfo 2>&1
    ""
    "--- OS Details (CIM) ---"
    Get-CimInstance Win32_OperatingSystem | Format-List Caption, Version, BuildNumber,
        OSArchitecture, InstallDate, LastBootUpTime, LocalDateTime, SystemDirectory,
        TotalVisibleMemorySize, FreePhysicalMemory, TotalVirtualMemorySize, FreeVirtualMemory
    ""
    "--- Uptime ---"
    $os = Get-CimInstance Win32_OperatingSystem
    $uptime = $os.LocalDateTime - $os.LastBootUpTime
    "Boot Time  : $($os.LastBootUpTime)"
    "Uptime     : $($uptime.Days)d $($uptime.Hours)h $($uptime.Minutes)m $($uptime.Seconds)s"
    ""
    "--- Timezone ---"
    Get-TimeZone | Format-List
    [System.TimeZoneInfo]::Local
}

# 1b. hardware.txt
$f = Join-Path $DiagPath "01_system\hardware.txt"
Write-FileHeader $f "Hardware Information" `
    "CPU, RAM DIMMs, BIOS, baseboard/motherboard details." `
    "Verify CPU core count vs. expected VM spec. Check BIOS version for known firmware CVEs."
Invoke-CollectBlock $f {
    "--- CPU ---"
    Get-CimInstance Win32_Processor | Format-List Name, Manufacturer, MaxClockSpeed,
        NumberOfCores, NumberOfLogicalProcessors, L2CacheSize, L3CacheSize, SocketDesignation, Status
    ""
    "--- Physical Memory (DIMMs) ---"
    Get-CimInstance Win32_PhysicalMemory | Format-List BankLabel, DeviceLocator, Capacity,
        Speed, MemoryType, Manufacturer, PartNumber
    ""
    "--- BIOS ---"
    Get-CimInstance Win32_BIOS | Format-List Manufacturer, Name, Version, SMBIOSBIOSVersion,
        ReleaseDate, SerialNumber
    ""
    "--- Baseboard / Motherboard ---"
    Get-CimInstance Win32_BaseBoard | Format-List Manufacturer, Product, SerialNumber, Version
    ""
    "--- System Enclosure ---"
    Get-CimInstance Win32_SystemEnclosure | Format-List Manufacturer, SerialNumber, SMBIOSAssetTag, ChassisTypes
    ""
    "--- Computer System ---"
    Get-CimInstance Win32_ComputerSystem | Format-List Manufacturer, Model, SystemType,
        TotalPhysicalMemory, NumberOfProcessors, NumberOfLogicalProcessors, DomainRole, Domain, Workgroup
}

# 1c. hotfixes.txt
$f = Join-Path $DiagPath "01_system\hotfixes.txt"
Write-FileHeader $f "Installed Hotfixes / Windows Updates" `
    "All installed Windows updates, patches, and hotfixes." `
    "Look for missing critical patches. Sort by InstalledOn to find recent changes."
Invoke-CollectBlock $f {
    Get-HotFix | Sort-Object InstalledOn -Descending | Format-Table HotFixID, Description, InstalledBy, InstalledOn -AutoSize
}

# 1d. environment_vars.txt
$f = Join-Path $DiagPath "01_system\environment_vars.txt"
Write-FileHeader $f "Environment Variables" `
    "System-level and current-user environment variables." `
    "Check PATH for unexpected entries. Look for credentials accidentally stored in env vars."
Invoke-CollectBlock $f {
    "--- System Environment Variables ---"
    [System.Environment]::GetEnvironmentVariables("Machine").GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name) = $($_.Value)" }
    ""
    "--- User Environment Variables ---"
    [System.Environment]::GetEnvironmentVariables("User").GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name) = $($_.Value)" }
    ""
    "--- Process Environment Variables (current session) ---"
    Get-ChildItem Env: | Sort-Object Name | Format-Table Name, Value -AutoSize
}

# 1e. boot_config.txt
$f = Join-Path $DiagPath "01_system\boot_config.txt"
Write-FileHeader $f "Boot Configuration (BCD)" `
    "Boot Configuration Data entries via bcdedit." `
    "Check boot order, safe mode flags, kernel debugger settings, or unexpected boot entries."
Invoke-CollectBlock $f {
    bcdedit /enum ALL 2>&1
}

# ===========================================================================
# SECTION 2/8 -- EVENT LOGS
# ===========================================================================
Write-Host "[2/8] Collecting event logs (range: $($dtStart.ToString('yyyy-MM-dd HH:mm')) to $($dtEnd.ToString('yyyy-MM-dd HH:mm')))..." -ForegroundColor Green

# 2a. system_events.txt
$f = Join-Path $DiagPath "02_event_logs\system_events.txt"
Write-FileHeader $f "System Event Log" `
    "System log: all severity levels, filtered to the specified time range." `
    "Filter for Level=Error/Critical first. Look for disk errors (Disk/NTFS), service crashes (SCM), BSODs (BugCheck)."
Get-FilteredWinEvent -LogName "System" -FilePath $f

# 2b. application_events.txt
$f = Join-Path $DiagPath "02_event_logs\application_events.txt"
Write-FileHeader $f "Application Event Log" `
    "Application log: all severity levels, filtered to the specified time range." `
    "Look for application crashes (.NET runtime errors, faulting module paths), hang events."
Get-FilteredWinEvent -LogName "Application" -FilePath $f

# 2c. security_events.txt
$f = Join-Path $DiagPath "02_event_logs\security_events.txt"
Write-FileHeader $f "Security Event Log (Key IDs)" `
    "Security log filtered to incident-relevant event IDs only (4624=Logon, 4625=FailedLogon, 4648=ExplicitCreds, 4672=PrivilegeUse, 4720=UserCreated, 4726=UserDeleted, 1102=AuditLogCleared)." `
    "4625 failures in bursts = brute force. 4720/4726 = account manipulation. 1102 = log tampering."
Get-FilteredWinEvent -LogName "Security" -FilePath $f -EventIds @(4624,4625,4648,4672,4720,4726,1102)

# 2d. defender_events.txt
$f = Join-Path $DiagPath "02_event_logs\defender_events.txt"
Write-FileHeader $f "Windows Defender Operational Log" `
    "Defender detections, scan results, real-time protection events." `
    "IDs 1116/1117 = malware detected/blocked. ID 5001 = real-time protection disabled (high severity)."
Get-FilteredWinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -FilePath $f

# 2e. powershell_events.txt
$f = Join-Path $DiagPath "02_event_logs\powershell_events.txt"
Write-FileHeader $f "PowerShell Logging (Script Block & Operational)" `
    "PowerShell script block execution logs and operational events." `
    "ID 4104 = script block executed (look for encoded/obfuscated commands). ID 400/800 = pipeline execution."
Get-FilteredWinEvent -LogName "Microsoft-Windows-PowerShell/Operational" -FilePath $f
Add-Content -Path $f -Value "`n--- PowerShell Admin Log ---`n" -Encoding UTF8
Get-FilteredWinEvent -LogName "Microsoft-Windows-PowerShell/Admin" -FilePath $f

# 2f. task_scheduler_events.txt
$f = Join-Path $DiagPath "02_event_logs\task_scheduler_events.txt"
Write-FileHeader $f "Task Scheduler Operational Log" `
    "Scheduled task execution start/stop/failure events." `
    "ID 106 = task registered. ID 201 = task completed. ID 101/103 = task failed to start. Watch for unknown tasks."
Get-FilteredWinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" -FilePath $f

# 2g. windows_update_events.txt
$f = Join-Path $DiagPath "02_event_logs\windows_update_events.txt"
Write-FileHeader $f "Windows Update Client Log" `
    "Windows Update installation, download, and failure events." `
    "ID 19 = update installed successfully. ID 20 = install failed (check error code). Look for recent patch activity."
Get-FilteredWinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -FilePath $f

# ===========================================================================
# SECTION 3/8 -- PROCESSES
# ===========================================================================
Write-Host "[3/8] Collecting process and service information..." -ForegroundColor Green

# 3a. running_processes.txt
$f = Join-Path $DiagPath "03_processes\running_processes.txt"
Write-FileHeader $f "Running Processes" `
    "All running processes with PID, parent PID, owner, command line, path, and memory." `
    "Check for processes with unusual paths (Temp, AppData), unsigned binaries, or high memory/CPU consumers."
Invoke-CollectBlock $f {
    $procs = Get-CimInstance Win32_Process | Sort-Object ProcessId
    foreach ($p in $procs) {
        $ownerInfo = $p.GetOwner()
        $owner = $ownerInfo.User
        $domain = $ownerInfo.Domain
        [PSCustomObject]@{
            PID         = $p.ProcessId
            PPID        = $p.ParentProcessId
            Name        = $p.Name
            Owner       = if ($owner) { "$domain\$owner" } else { "N/A" }
            "WS(MB)"    = [math]::Round($p.WorkingSetSize / 1MB, 1)
            CommandLine = $p.CommandLine
            Path        = $p.ExecutablePath
        } | Format-List
    }
}

# 3b. process_tree.txt
$f = Join-Path $DiagPath "03_processes\process_tree.txt"
Write-FileHeader $f "Process Tree (Parent-Child)" `
    "Parent-child process relationships showing process hierarchy." `
    "Suspicious: cmd.exe or powershell.exe spawned by Office apps, browsers, or services indicates potential exploitation."
Invoke-CollectBlock $f {
    $all = Get-CimInstance Win32_Process | Sort-Object ProcessId
    $lookup = @{}
    foreach ($p in $all) { $lookup[$p.ProcessId] = $p }

    function Show-Tree {
        param($pid, $indent = "")
        $p = $lookup[$pid]
        if (-not $p) { return }
        $ownerInfo = $p.GetOwner()
        $owner = $ownerInfo.User
        "{0}{1} (PID:{2} Owner:{3})" -f $indent, $p.Name, $p.ProcessId, $owner
        foreach ($child in ($all | Where-Object { $_.ParentProcessId -eq $pid -and $_.ProcessId -ne $pid })) {
            Show-Tree -pid $child.ProcessId -indent ("  " + $indent)
        }
    }

    $roots = $all | Where-Object { -not $lookup.ContainsKey($_.ParentProcessId) -or $_.ParentProcessId -eq 0 }
    foreach ($r in $roots) { Show-Tree -pid $r.ProcessId }
}

# 3c. services.txt
$f = Join-Path $DiagPath "03_processes\services.txt"
Write-FileHeader $f "Windows Services" `
    "All services with status, start type, binary path, and service account." `
    "Look for services running from Temp/AppData, non-standard accounts, or unexpected Auto-start services."
Invoke-CollectBlock $f {
    Get-CimInstance Win32_Service | Sort-Object State, Name |
        Select-Object Name, DisplayName, State, StartMode, PathName, StartName, Description |
        Format-List
}

# 3d. scheduled_tasks.txt
$f = Join-Path $DiagPath "03_processes\scheduled_tasks.txt"
Write-FileHeader $f "Scheduled Tasks" `
    "All scheduled tasks with state, triggers, actions, last/next run time, and author." `
    "Flag tasks not created by Microsoft, tasks running from unusual paths, or recently modified tasks."
Invoke-CollectBlock $f {
    Get-ScheduledTask | ForEach-Object {
        $info = Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            TaskPath    = $_.TaskPath + $_.TaskName
            State       = $_.State
            Author      = $_.Principal.UserId
            RunAs       = $_.Principal.RunLevel
            LastRunTime = $info.LastRunTime
            LastResult  = $info.LastTaskResult
            NextRunTime = $info.NextRunTime
            Actions     = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join " | "
            Triggers    = ($_.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ", "
        } | Format-List
    }
}

# 3e. startup_items.txt
$f = Join-Path $DiagPath "03_processes\startup_items.txt"
Write-FileHeader $f "Startup Items" `
    "Registry Run keys and Startup folder entries for all users." `
    "Compare against known-good baseline. Malware commonly persists via HKCU\Run or Startup folders."
Invoke-CollectBlock $f {
    $runKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    )
    foreach ($key in $runKeys) {
        "--- $key ---"
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($props) {
            $props.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } |
                ForEach-Object { "  $($_.Name) = $($_.Value)" }
        } else { "  (empty or not found)" }
        ""
    }
    ""
    "--- Startup Folders ---"
    $startupPaths = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    )
    foreach ($sp in $startupPaths) {
        "  Path: $sp"
        if (Test-Path $sp) {
            Get-ChildItem $sp -ErrorAction SilentlyContinue | Format-Table Name, LastWriteTime, Length -AutoSize
        } else { "  (not found)" }
    }
}

# ===========================================================================
# SECTION 4/8 -- NETWORK
# ===========================================================================
Write-Host "[4/8] Collecting network information..." -ForegroundColor Green

# 4a. network_config.txt
$f = Join-Path $DiagPath "04_network\network_config.txt"
Write-FileHeader $f "Network Configuration" `
    "All network adapters: IP, MAC, DNS, DHCP, gateway settings (equivalent to ipconfig /all)." `
    "Verify IPs match expected allocation. Check for unexpected adapters or manual DNS servers."
Invoke-CollectBlock $f {
    "--- ipconfig /all ---"
    ipconfig /all 2>&1
    ""
    "--- Network Adapters (CIM) ---"
    Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled } |
        Format-List Description, MACAddress, IPAddress, IPSubnet, DefaultIPGateway,
            DNSServerSearchOrder, DHCPEnabled, DHCPServer, DHCPLeaseObtained, DHCPLeaseExpires
    ""
    "--- All Network Adapters ---"
    Get-NetAdapter | Format-Table Name, Status, MacAddress, LinkSpeed, MediaType, InterfaceDescription -AutoSize
}

# 4b. active_connections.txt
$f = Join-Path $DiagPath "04_network\active_connections.txt"
Write-FileHeader $f "Active Network Connections" `
    "All TCP/UDP connections with local/remote address, state, PID, and process name." `
    "Look for ESTABLISHED connections to unknown external IPs, listeners on unexpected ports, or processes making unusual connections."
Invoke-CollectBlock $f {
    "--- TCP Connections ---"
    $procMap = @{}
    Get-Process | ForEach-Object { $procMap[$_.Id] = $_.Name }
    Get-NetTCPConnection | Sort-Object State, LocalPort |
        Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State,
            @{N="PID";E={$_.OwningProcess}},
            @{N="Process";E={$procMap[$_.OwningProcess]}} |
        Format-Table -AutoSize
    ""
    "--- UDP Endpoints ---"
    Get-NetUDPEndpoint | Sort-Object LocalPort |
        Select-Object LocalAddress, LocalPort,
            @{N="PID";E={$_.OwningProcess}},
            @{N="Process";E={$procMap[$_.OwningProcess]}} |
        Format-Table -AutoSize
    ""
    "--- Raw netstat output ---"
    netstat -ano 2>&1
}

# 4c. arp_table.txt
$f = Join-Path $DiagPath "04_network\arp_table.txt"
Write-FileHeader $f "ARP Cache" `
    "Current ARP table mapping IP addresses to MAC addresses." `
    "Look for duplicate MACs (ARP poisoning) or unexpected entries on the local subnet."
Invoke-CollectBlock $f {
    "--- arp -a ---"
    arp -a 2>&1
    ""
    "--- Get-NetNeighbor ---"
    Get-NetNeighbor | Format-Table InterfaceAlias, IPAddress, LinkLayerAddress, State -AutoSize
}

# 4d. routing_table.txt
$f = Join-Path $DiagPath "04_network\routing_table.txt"
Write-FileHeader $f "Routing Table" `
    "IP routing table showing all routes (equivalent to route print)." `
    "Verify default gateway. Check for unexpected static routes that may redirect traffic."
Invoke-CollectBlock $f {
    "--- route print ---"
    route print 2>&1
    ""
    "--- Get-NetRoute ---"
    Get-NetRoute | Sort-Object RouteMetric | Format-Table DestinationPrefix, NextHop, RouteMetric, InterfaceAlias -AutoSize
}

# 4e. dns_cache.txt
$f = Join-Path $DiagPath "04_network\dns_cache.txt"
Write-FileHeader $f "DNS Cache" `
    "Local DNS resolver cache (equivalent to ipconfig /displaydns)." `
    "Unusual or malicious domain lookups may appear here after an incident even if connections are closed."
Invoke-CollectBlock $f {
    "--- ipconfig /displaydns ---"
    ipconfig /displaydns 2>&1
    ""
    "--- Get-DnsClientCache ---"
    Get-DnsClientCache | Format-Table Entry, RecordName, RecordType, TimeToLive, Data -AutoSize
}

# 4f. firewall_status.txt
$f = Join-Path $DiagPath "04_network\firewall_status.txt"
Write-FileHeader $f "Windows Firewall Status and Rules" `
    "Firewall profile settings and all inbound/outbound rules." `
    "Check if firewall is disabled (major risk). Look for rules allowing broad inbound access from Any."
Invoke-CollectBlock $f {
    "--- Firewall Profile Status ---"
    Get-NetFirewallProfile | Format-Table Name, Enabled, DefaultInboundAction, DefaultOutboundAction, LogFileName -AutoSize
    ""
    "--- Enabled Firewall Rules ---"
    Get-NetFirewallRule | Where-Object { $_.Enabled -eq "True" } |
        Sort-Object Direction, Action |
        Select-Object DisplayName, Direction, Action, Profile,
            @{N="LocalPort"; E={ ($_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort }},
            @{N="RemoteAddress"; E={ ($_ | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue).RemoteAddress }} |
        Format-Table -AutoSize
    ""
    "--- All Firewall Rules (summary) ---"
    Get-NetFirewallRule | Format-Table DisplayName, Direction, Action, Enabled, Profile -AutoSize
}

# 4g. hosts_file.txt
$f = Join-Path $DiagPath "04_network\hosts_file.txt"
Write-FileHeader $f "Hosts File" `
    "Contents of C:\Windows\System32\drivers\etc\hosts." `
    "Malware commonly hijacks hosts file to redirect domains (e.g., AV update URLs, banking sites)."
Invoke-CollectBlock $f {
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    "Path: $hostsPath"
    ""
    Get-Content $hostsPath -ErrorAction SilentlyContinue
}

# ===========================================================================
# SECTION 5/8 -- STORAGE
# ===========================================================================
Write-Host "[5/8] Collecting storage information..." -ForegroundColor Green

# 5a. disk_usage.txt
$f = Join-Path $DiagPath "05_storage\disk_usage.txt"
Write-FileHeader $f "Disk / Volume Usage" `
    "All logical drives and volumes with size, free space, and filesystem type." `
    "Flag volumes below 10% free (may cause performance issues or log truncation)."
Invoke-CollectBlock $f {
    "--- Logical Disks ---"
    Get-CimInstance Win32_LogicalDisk | Format-Table DeviceID, DriveType, FileSystem,
        @{N="Size(GB)";E={[math]::Round($_.Size/1GB,2)}},
        @{N="FreeGB";E={[math]::Round($_.FreeSpace/1GB,2)}},
        @{N="Free%";E={if($_.Size -gt 0){[math]::Round(($_.FreeSpace/$_.Size)*100,1)}else{0}}},
        VolumeName -AutoSize
    ""
    "--- Volumes (Get-Volume) ---"
    Get-Volume | Format-Table DriveLetter, FriendlyName, FileSystem, HealthStatus, OperationalStatus,
        @{N="Size(GB)";E={[math]::Round($_.Size/1GB,2)}},
        @{N="Free(GB)";E={[math]::Round($_.SizeRemaining/1GB,2)}} -AutoSize
    ""
    "--- Disk Partitions ---"
    Get-Partition | Format-Table DiskNumber, PartitionNumber, DriveLetter,
        @{N="Size(GB)";E={[math]::Round($_.Size/1GB,2)}}, Type, IsActive, IsSystem -AutoSize
}

# 5b. disk_health.txt
$f = Join-Path $DiagPath "05_storage\disk_health.txt"
Write-FileHeader $f "Physical Disk Health" `
    "Physical disk SMART status, reliability data, and disk model/serial information." `
    "HealthStatus 'Unhealthy' or 'Warning' requires immediate attention. Check PredictFailure."
Invoke-CollectBlock $f {
    "--- Physical Disks ---"
    Get-PhysicalDisk | Format-List FriendlyName, MediaType, OperationalStatus, HealthStatus,
        @{N="Size(GB)";E={[math]::Round($_.Size/1GB,2)}}, BusType, FirmwareVersion, SerialNumber, UniqueId
    ""
    "--- Disk Reliability ---"
    Get-Disk | ForEach-Object {
        $disk = $_
        "Disk $($disk.Number): $($disk.FriendlyName)"
        "  OperationalStatus: $($disk.OperationalStatus)  HealthStatus: $($disk.HealthStatus)"
        $rel = $disk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        if ($rel) {
            "  ReadErrorsTotal : $($rel.ReadErrorsTotal)"
            "  WriteErrorsTotal: $($rel.WriteErrorsTotal)"
            "  Temperature (C) : $($rel.Temperature)"
            "  Wear (%)        : $($rel.Wear)"
        } else {
            "  (StorageReliabilityCounter not available for this disk)"
        }
        ""
    }
    "--- Win32_DiskDrive ---"
    Get-CimInstance Win32_DiskDrive | Format-List Name, Model, Size, MediaType, SerialNumber,
        Status, PredictFailure, Partitions, BytesPerSector
}

# 5c. volume_shadows.txt
$f = Join-Path $DiagPath "05_storage\volume_shadows.txt"
Write-FileHeader $f "Volume Shadow Copies (VSS)" `
    "List of all VSS shadow copies with creation time and volume." `
    "Ransomware commonly deletes shadow copies. Absence of shadows on critical volumes is a red flag."
Invoke-CollectBlock $f {
    "--- vssadmin list shadows ---"
    vssadmin list shadows 2>&1
    ""
    "--- Win32_ShadowCopy ---"
    Get-CimInstance Win32_ShadowCopy | Sort-Object InstallDate -Descending |
        Format-Table ID, VolumeName, InstallDate, SetID -AutoSize
}

# 5d. pagefile.txt
$f = Join-Path $DiagPath "05_storage\pagefile.txt"
Write-FileHeader $f "Pagefile Configuration" `
    "Pagefile (virtual memory) location, configured size, and current usage." `
    "Pagefile at 100% usage indicates memory pressure. System-managed vs. manual size config."
Invoke-CollectBlock $f {
    "--- Pagefile Configuration ---"
    Get-CimInstance Win32_PageFileSetting | Format-List Name, InitialSize, MaximumSize
    ""
    "--- Pagefile Current Usage ---"
    Get-CimInstance Win32_PageFileUsage | Format-List Name, CurrentUsage, PeakUsage, AllocatedBaseSize
    ""
    "--- Virtual Memory Summary ---"
    $os = Get-CimInstance Win32_OperatingSystem
    "TotalVirtualMemorySize : $([math]::Round($os.TotalVirtualMemorySize / 1MB, 2)) GB"
    "FreeVirtualMemory      : $([math]::Round($os.FreeVirtualMemory / 1MB, 2)) GB"
    "TotalVisibleMemorySize : $([math]::Round($os.TotalVisibleMemorySize / 1MB, 2)) GB"
    "FreePhysicalMemory     : $([math]::Round($os.FreePhysicalMemory / 1MB, 2)) GB"
}

# ===========================================================================
# SECTION 6/8 -- SECURITY
# ===========================================================================
Write-Host "[6/8] Collecting security information..." -ForegroundColor Green

# 6a. local_users.txt
$f = Join-Path $DiagPath "06_security\local_users.txt"
Write-FileHeader $f "Local User Accounts" `
    "All local user accounts with enabled status, last logon, and password info." `
    "Look for unexpected accounts, accounts with 'PasswordNeverExpires', or recently created accounts."
Invoke-CollectBlock $f {
    "--- Get-LocalUser ---"
    Get-LocalUser | Sort-Object Name | Format-List Name, Enabled, FullName, Description,
        LastLogon, PasswordLastSet, PasswordExpires, PasswordNeverExpires,
        UserMayChangePassword, AccountExpires, SID
    ""
    "--- net user (extended detail) ---"
    $users = Get-LocalUser | Select-Object -ExpandProperty Name
    foreach ($u in $users) {
        "--- net user $u ---"
        net user $u 2>&1
        ""
    }
}

# 6b. local_groups.txt
$f = Join-Path $DiagPath "06_security\local_groups.txt"
Write-FileHeader $f "Local Groups and Members" `
    "All local groups and their members." `
    "Administrators group is critical. Verify all members are expected. Look for unexpected accounts in privileged groups."
Invoke-CollectBlock $f {
    $groups = Get-LocalGroup | Sort-Object Name
    foreach ($g in $groups) {
        "=== $($g.Name) ==="
        $g | Format-List Name, Description, SID
        "Members:"
        Get-LocalGroupMember -Group $g.Name -ErrorAction SilentlyContinue |
            Format-Table Name, ObjectClass, PrincipalSource -AutoSize
        ""
    }
}

# 6c. current_sessions.txt
$f = Join-Path $DiagPath "06_security\current_sessions.txt"
Write-FileHeader $f "Current Logon Sessions" `
    "Currently logged-on users and active logon sessions." `
    "Check for unexpected interactive sessions or elevated sessions that should not be active."
Invoke-CollectBlock $f {
    "--- quser (active sessions) ---"
    quser 2>&1
    ""
    "--- Win32_LogonSession ---"
    Get-CimInstance Win32_LogonSession | Sort-Object StartTime -Descending |
        Format-Table LogonId, LogonType, StartTime, AuthenticationPackage -AutoSize
    ""
    "--- Win32_ComputerSystem (logged on users) ---"
    Get-CimInstance Win32_ComputerSystem | Select-Object UserName, Domain | Format-List
    ""
    "--- whoami /all ---"
    whoami /all 2>&1
}

# 6d. audit_policy.txt
$f = Join-Path $DiagPath "06_security\audit_policy.txt"
Write-FileHeader $f "Audit Policy" `
    "Current audit policy settings for all categories (via auditpol)." `
    "Verify Account Logon, Logon/Logoff, and Privilege Use audit both Success and Failure."
Invoke-CollectBlock $f {
    "--- auditpol /get /category:* ---"
    auditpol /get /category:* 2>&1
}

# 6e. antivirus_status.txt
$f = Join-Path $DiagPath "06_security\antivirus_status.txt"
Write-FileHeader $f "Antivirus / Security Product Status" `
    "Installed AV and security products via WMI SecurityCenter2." `
    "productState encodes enabled/disabled and up-to-date status. Multiple conflicting AVs can cause coverage gaps."
Invoke-CollectBlock $f {
    "--- AntiVirusProduct / FirewallProduct (SecurityCenter2) ---"
    if ($IsServerOS) {
        "SecurityCenter2 WMI namespace is not available on Windows Server editions."
        "Use Windows Defender status below instead."
    } else {
        $avProducts = Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
        if ($avProducts) {
            $avProducts | ForEach-Object {
                $state = $_.productState
                $rtEnabled   = ($state -band 0x1000) -ne 0
                $defUpToDate = ($state -band 0x0010) -eq 0
                [PSCustomObject]@{
                    DisplayName         = $_.displayName
                    ProductState        = "0x{0:X6}" -f $state
                    RealtimeEnabled     = $rtEnabled
                    DefinitionsUpToDate = $defUpToDate
                    PathToExe           = $_.pathToSignedProductExe
                    Timestamp           = $_.timestamp
                } | Format-List
            }
        } else {
            "No AntiVirus products found via SecurityCenter2."
        }
        ""
        "--- FirewallProduct (SecurityCenter2) ---"
        Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName FirewallProduct -ErrorAction SilentlyContinue |
            Format-List displayName, productState, pathToSignedProductExe
    }
    ""
    "--- Windows Defender Status (Get-MpComputerStatus) ---"
    $mpStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mpStatus) {
        $mpStatus | Format-List AMRunningMode, AMServiceEnabled, AntivirusEnabled,
            AntispywareEnabled, RealTimeProtectionEnabled, NISEnabled,
            AntivirusSignatureLastUpdated, AntispywareSignatureLastUpdated,
            QuickScanAge, FullScanAge, LastFullScanSource, TamperProtectionSource
    } else { "Windows Defender status not available." }
    ""
    "--- Windows Defender Recent Threat Detections ---"
    Get-MpThreatDetection -ErrorAction SilentlyContinue | Sort-Object InitialDetectionTime -Descending |
        Select-Object -First 50 | Format-Table InitialDetectionTime, ThreatName, ActionSuccess, Resources -AutoSize
}

# ===========================================================================
# SECTION 7/8 -- SOFTWARE
# ===========================================================================
Write-Host "[7/8] Collecting software information..." -ForegroundColor Green

# 7a. installed_apps.txt
$f = Join-Path $DiagPath "07_software\installed_apps.txt"
Write-FileHeader $f "Installed Applications" `
    "All installed software from both 64-bit and 32-bit registry hives." `
    "Sort by InstallDate for recently installed software. Look for unexpected or unsigned software."
Invoke-CollectBlock $f {
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $apps = foreach ($path in $uninstallPaths) {
        Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate,
                InstallLocation, UninstallString,
                @{N="Hive";E={ if ($path -like "*WOW*") {"32-bit"} elseif ($path -like "*HKCU*") {"User"} else {"64-bit"} }}
    }
    "--- Summary Table ---"
    $apps | Sort-Object DisplayName | Format-Table DisplayName, DisplayVersion, Publisher, InstallDate, Hive -AutoSize
    ""
    "--- Full Details (sorted by InstallDate desc) ---"
    $apps | Sort-Object InstallDate -Descending | Format-List
}

# 7b. running_browsers.txt
$f = Join-Path $DiagPath "07_software\running_browsers.txt"
Write-FileHeader $f "Browser Processes" `
    "Detected browser processes and their versions." `
    "Outdated browsers are common attack vectors. Browsers running unexpected child processes may indicate exploitation."
Invoke-CollectBlock $f {
    $browserNames = @("chrome","msedge","firefox","iexplore","opera","brave","vivaldi","safari")
    $found = $false
    foreach ($name in $browserNames) {
        $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($procs) {
            $found = $true
            foreach ($p in $procs) {
                [PSCustomObject]@{
                    Browser   = $p.Name
                    PID       = $p.Id
                    Path      = $p.Path
                    Version   = if ($p.Path) { (Get-Item $p.Path -ErrorAction SilentlyContinue).VersionInfo.ProductVersion } else { "N/A" }
                    "CPU(s)"  = [math]::Round($p.TotalProcessorTime.TotalSeconds, 2)
                    "Mem(MB)" = [math]::Round($p.WorkingSet64 / 1MB, 1)
                } | Format-List
            }
        }
    }
    if (-not $found) { "No browser processes currently running." }
}

# 7c. qemu_guest_agent.txt
$f = Join-Path $DiagPath "07_software\qemu_guest_agent.txt"
Write-FileHeader $f "QEMU Guest Agent (KubeVirt)" `
    "Status and configuration of the QEMU Guest Agent service (qemu-ga), relevant for KubeVirt VMs." `
    "Agent must be running for KubeVirt VM lifecycle operations (shutdown, snapshot quiesce) to work correctly."
Invoke-CollectBlock $f {
    "--- QEMU-GA Service Status ---"
    $svc = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
    if ($svc) {
        $svc | Format-List Name, DisplayName, Status, StartType
    } else {
        "QEMU-GA service not found. This may not be a KubeVirt/QEMU VM, or the agent is not installed."
    }
    ""
    "--- QEMU-GA Process ---"
    Get-Process -Name "qemu-ga" -ErrorAction SilentlyContinue | Format-List Name, Id, Path, CPU, WorkingSet
    ""
    "--- QEMU-GA via WMI (any qemu service) ---"
    Get-CimInstance Win32_Service | Where-Object { $_.Name -like "*qemu*" -or $_.DisplayName -like "*qemu*" } |
        Format-List Name, DisplayName, State, PathName, StartName
    ""
    "--- VirtIO Drivers ---"
    Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -like "*VirtIO*" -or $_.Manufacturer -like "*Red Hat*" } |
        Format-Table Name, Status, Manufacturer, DeviceID -AutoSize
}

# ===========================================================================
# SECTION 8/8 -- CRASH REPORTS
# ===========================================================================
Write-Host "[8/8] Collecting crash reports and WER data..." -ForegroundColor Green

# 8a. wer_reports.txt
$f = Join-Path $DiagPath "08_crash_reports\wer_reports.txt"
Write-FileHeader $f "Windows Error Reporting (WER) Reports" `
    "WER report directories and Report.wer summaries for application crashes." `
    "Each report contains crash details including faulting module and exception code. Critical for diagnosing app crashes."
Invoke-CollectBlock $f {
    $werPaths = @(
        "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
        "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue",
        "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive"
    )
    foreach ($werPath in $werPaths) {
        "=== $werPath ==="
        if (Test-Path $werPath) {
            $reports = Get-ChildItem $werPath -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
            if ($reports) {
                "Found $($reports.Count) report(s):"
                foreach ($report in $reports) {
                    "  [$($report.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))] $($report.Name)"
                    $werFile = Join-Path $report.FullName "Report.wer"
                    if (Test-Path $werFile) {
                        "  --- Report.wer ---"
                        Get-Content $werFile -ErrorAction SilentlyContinue | ForEach-Object { "    $_" }
                    }
                    ""
                }
            } else { "  (no reports found)" }
        } else { "  (path not found)" }
        ""
    }
}

# 8b. minidumps.txt
$f = Join-Path $DiagPath "08_crash_reports\minidumps.txt"
Write-FileHeader $f "Minidump Files" `
    "List of BSOD/kernel minidump files in C:\Windows\Minidump with timestamps." `
    "Each .dmp file corresponds to a Blue Screen of Death. Use WinDbg or !analyze to read them. Recent dumps indicate instability."
Invoke-CollectBlock $f {
    "--- C:\Windows\Minidump ---"
    $dumpPath = "$env:SystemRoot\Minidump"
    if (Test-Path $dumpPath) {
        $dumps = Get-ChildItem $dumpPath -Filter "*.dmp" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if ($dumps) {
            "Found $($dumps.Count) minidump file(s):"
            $dumps | Format-Table Name, LastWriteTime, @{N="Size(KB)";E={[math]::Round($_.Length/1KB,1)}} -AutoSize
        } else { "No .dmp files found in $dumpPath" }
    } else { "Minidump directory not found: $dumpPath" }
    ""
    "--- Memory.dmp (full kernel dump) ---"
    $fullDump = "$env:SystemRoot\Memory.dmp"
    if (Test-Path $fullDump) {
        $d = Get-Item $fullDump
        "Found: $($d.FullName) | Size: $([math]::Round($d.Length/1GB,2)) GB | Modified: $($d.LastWriteTime)"
    } else { "No Memory.dmp found at $env:SystemRoot\Memory.dmp" }
    ""
    "--- Crash Dump Settings (registry) ---"
    $crashKey = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"
    Get-ItemProperty -Path $crashKey -ErrorAction SilentlyContinue |
        Select-Object CrashDumpEnabled, DumpFile, MiniDumpDir, AutoReboot | Format-List
}

# ===========================================================================
# SUMMARY_FOR_AI.txt  -- Condensed report optimized for AI-assisted analysis
# ===========================================================================
Write-Host "" 
Write-Host "Generating SUMMARY_FOR_AI.txt..." -ForegroundColor Cyan
$aiFile = Join-Path $DiagPath "SUMMARY_FOR_AI.txt"

$aiLines = [System.Collections.Generic.List[string]]::new()
function AI { param([string]$line = "") $aiLines.Add($line) }

AI "================================================================================"
AI "  WINDOWS GUEST DIAGNOSTIC SUMMARY -- FOR AI-ASSISTED ANALYSIS"
AI "================================================================================"
AI "  Computer    : $ComputerName"
AI "  OS          : $OSCaption"
AI "  Build       : $OSBuild  |  Type: $(if($IsServerOS){'Server'}else{'Desktop'})"
AI "  Collected   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [Timezone: $(([System.TimeZoneInfo]::Local).DisplayName)]"
AI "  Time Range  : $($dtStart.ToString('yyyy-MM-dd HH:mm')) -> $($dtEnd.ToString('yyyy-MM-dd HH:mm'))"
AI "  Run As Admin: $IsAdmin"
AI "================================================================================"
AI ""
AI "------------------------------------------------------------------------------"
AI "  HOW TO USE"
AI "------------------------------------------------------------------------------"
AI "  1. Share this file with an AI assistant (ChatGPT, Claude, Gemini, etc.)"
AI "  2. Use the prompt template in the next section"
AI "  3. If the AI needs more detail, share the specific .txt file from the ZIP"
AI ""
AI "------------------------------------------------------------------------------"
AI "  PROMPT TEMPLATE (copy and paste to AI, then attach this file)"
AI "------------------------------------------------------------------------------"
AI ""
AI "You are an expert Windows systems administrator performing incident analysis."
AI "The attached file is a diagnostic summary from a Windows VM (running in a"
AI "KubeVirt virtualization environment). Please analyze and provide:"
AI "  1. Overall system health assessment"
AI "  2. Root cause of reported issues (if any)"
AI "  3. Security concerns"
AI "  4. Recommended next steps"
AI ""
AI "Incident context: [USER: describe the symptoms here, e.g. 'high CPU around 09:30']"
AI ""
AI "If you need more detail on any area, ask me to share the specific log file"
AI "from the diagnostic ZIP package (e.g. '02_event_logs/system_events.txt')."
AI ""
AI "------------------------------------------------------------------------------"
AI "  [1] SYSTEM IDENTITY"
AI "------------------------------------------------------------------------------"
try {
    $osObj  = Get-CimInstance Win32_OperatingSystem
    $uptime = $osObj.LocalDateTime - $osObj.LastBootUpTime
    $cs     = Get-CimInstance Win32_ComputerSystem
    $cpu    = Get-CimInstance Win32_Processor | Select-Object -First 1
    $totalRAM = [math]::Round($osObj.TotalVisibleMemorySize / 1MB, 1)
    $freeRAM  = [math]::Round($osObj.FreePhysicalMemory  / 1MB, 1)
    $usedRAMpct = [math]::Round((($osObj.TotalVisibleMemorySize - $osObj.FreePhysicalMemory) / $osObj.TotalVisibleMemorySize) * 100, 1)
    AI "  Hostname    : $ComputerName"
    AI "  OS          : $($osObj.Caption) Build $($osObj.BuildNumber)"
    AI "  Last Boot   : $($osObj.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    AI "  Uptime      : $($uptime.Days)d $($uptime.Hours)h $($uptime.Minutes)m"
    AI "  CPU         : $($cpu.Name) | Cores: $($cpu.NumberOfCores) | Logical: $($cpu.NumberOfLogicalProcessors)"
    AI "  RAM Total   : $totalRAM GB  |  Free: $freeRAM GB  |  Used: $usedRAMpct%"
    AI "  Domain      : $($cs.Domain)  |  Model: $($cs.Model)"
    $tz = [System.TimeZoneInfo]::Local
    AI "  TimeZone    : $($tz.DisplayName)  (UTC$($tz.BaseUtcOffset.Hours.ToString('+0;-#')))"
} catch { AI "  [ERROR collecting system identity: $_]" }
AI ""

AI "------------------------------------------------------------------------------"
AI "  [2] [!]  AUTO-DETECTED ALERTS"
AI "------------------------------------------------------------------------------"
$alertCount = 0

# Disk space alerts
try {
    Get-CimInstance Win32_LogicalDisk | Where-Object { $_.Size -gt 0 -and $_.DriveType -eq 3 } | ForEach-Object {
        $freePct = [math]::Round(($_.FreeSpace / $_.Size) * 100, 1)
        $freeGB  = [math]::Round($_.FreeSpace / 1GB, 1)
        if ($freePct -lt 10) {
            AI "  [DISK CRITICAL] $($_.DeviceID) is $([math]::Round(100-$freePct,1))% full -- only $freeGB GB remaining!"
            $alertCount++
        } elseif ($freePct -lt 20) {
            AI "  [DISK WARNING]  $($_.DeviceID) is $([math]::Round(100-$freePct,1))% full -- $freeGB GB remaining"
            $alertCount++
        }
    }
} catch {}

# RAM usage alert
try {
    $osObj2 = Get-CimInstance Win32_OperatingSystem
    $ramUsed = [math]::Round((($osObj2.TotalVisibleMemorySize - $osObj2.FreePhysicalMemory) / $osObj2.TotalVisibleMemorySize) * 100, 1)
    if ($ramUsed -gt 90) { AI "  [RAM CRITICAL]  Physical memory usage is $ramUsed%"; $alertCount++ }
    elseif ($ramUsed -gt 80) { AI "  [RAM WARNING]   Physical memory usage is $ramUsed%"; $alertCount++ }
} catch {}

# Pagefile usage
try {
    $pf = Get-CimInstance Win32_PageFileUsage | Select-Object -First 1
    if ($pf -and $pf.AllocatedBaseSize -gt 0) {
        $pfPct = [math]::Round(($pf.CurrentUsage / $pf.AllocatedBaseSize) * 100, 1)
        if ($pfPct -gt 80) { AI "  [PAGEFILE WARN] Pagefile usage is $pfPct% ($($pf.CurrentUsage) MB / $($pf.AllocatedBaseSize) MB)"; $alertCount++ }
    }
} catch {}

# QEMU-GA status
try {
    $qemuSvc = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
    if (-not $qemuSvc) {
        AI "  [QEMU-GA MISSING]  QEMU Guest Agent is NOT installed -- KubeVirt memory metrics UNRELIABLE"
        $alertCount++
    } elseif ($qemuSvc.Status -ne "Running") {
        AI "  [QEMU-GA STOPPED]  QEMU Guest Agent is installed but NOT running (Status: $($qemuSvc.Status))"
        $alertCount++
    }
} catch {}

# Auto-start services that are stopped
try {
    $stoppedSvcs = Get-CimInstance Win32_Service | Where-Object {
        $_.StartMode -eq "Auto" -and $_.State -ne "Running" -and
        $_.Name -notin @("MapsBroker","NetTcpPortSharing","RemoteRegistry","shpamsvc","tzautoupdate","XblAuthManager","XblGameSave","XboxGipSvc","XboxNetApiSvc")
    }
    foreach ($svc in $stoppedSvcs) {
        AI "  [SVC STOPPED]   Auto-start service not running: '$($svc.Name)' ($($svc.DisplayName))"
        $alertCount++
    }
} catch {}

# WER crash reports in range
try {
    $werDirs = @(
        "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
        "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue",
        "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive"
    )
    $crashCount = 0
    foreach ($dir in $werDirs) {
        if (Test-Path $dir) {
            $crashCount += (Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Where-Object {
                $_.CreationTime -ge $dtStart -and $_.CreationTime -le $dtEnd }).Count
        }
    }
    if ($crashCount -gt 0) { AI "  [CRASH REPORTS] $crashCount WER crash report(s) found in the specified time range"; $alertCount++ }
} catch {}

# Minidumps in range
try {
    $dumpPath = "$env:SystemRoot\Minidump"
    if (Test-Path $dumpPath) {
        $recentDumps = (Get-ChildItem $dumpPath -Filter "*.dmp" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $dtStart -and $_.LastWriteTime -le $dtEnd }).Count
        if ($recentDumps -gt 0) { AI "  [BSOD DETECTED] $recentDumps minidump file(s) in time range -- system experienced BSOD(s)"; $alertCount++ }
    }
} catch {}

# Defender real-time protection
try {
    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mp -and -not $mp.RealTimeProtectionEnabled) { AI "  [SECURITY] Windows Defender real-time protection is DISABLED"; $alertCount++ }
    if ($mp -and $mp.AntivirusSignatureAge -gt 7) { AI "  [SECURITY] Defender signatures are $($mp.AntivirusSignatureAge) days old (>7 days)"; $alertCount++ }
} catch {}

if ($alertCount -eq 0) { AI "  No critical alerts auto-detected." }
AI ""

AI "------------------------------------------------------------------------------"
AI "  [3] CRITICAL EVENTS IN TIME RANGE (Level >= Warning)"
AI "  Range: $($dtStart.ToString('yyyy-MM-dd HH:mm')) -> $($dtEnd.ToString('yyyy-MM-dd HH:mm'))"
AI "------------------------------------------------------------------------------"
try {
    # Priority Event IDs (OOM, BSOD, Crash, Hang, Kernel)
    $priorityIds = @(41, 6008, 2004, 1001, 1002, 1000, 7034, 7031, 7036, 1074)
    $priorityEvts = @()
    foreach ($log in @("System","Application")) {
        $evts = Get-WinEvent -FilterHashtable @{LogName=$log; StartTime=$dtStart; EndTime=$dtEnd; Level=1,2,3} -ErrorAction SilentlyContinue
        if ($evts) { $priorityEvts += $evts }
    }
    # Include priority IDs even if they're not Error/Critical
    foreach ($log in @("System","Application")) {
        $evts = Get-WinEvent -FilterHashtable @{LogName=$log; StartTime=$dtStart; EndTime=$dtEnd; Id=$priorityIds} -ErrorAction SilentlyContinue
        if ($evts) { $priorityEvts += $evts }
    }
    $priorityEvts = $priorityEvts | Sort-Object TimeCreated -Descending | Select-Object -Unique TimeCreated, Id, LevelDisplayName, LogName, ProviderName, Message
    if ($priorityEvts) {
        AI "  Total: $($priorityEvts.Count) event(s)"
        AI ""
        foreach ($e in ($priorityEvts | Select-Object -First 50)) {
            $shortMsg = ($e.Message -replace "`r`n|`n", " ").Substring(0, [Math]::Min(($e.Message -replace "`r`n|`n", " ").Length, 250))
            AI "  [$($e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] [ID:$($e.Id)] [$($e.LevelDisplayName)] [$($e.LogName)] $shortMsg"
        }
        if ($priorityEvts.Count -gt 50) { AI "  ... ($(($priorityEvts.Count - 50)) more events -- see 02_event_logs/ for full list)" }
    } else {
        AI "  No Warning/Error/Critical events found in the specified time range."
    }
} catch { AI "  [ERROR collecting events: $_]" }
AI ""

AI "------------------------------------------------------------------------------"
AI "  [4] TOP 15 PROCESSES BY MEMORY (Working Set)"
AI "------------------------------------------------------------------------------"
try {
    $procs = Get-CimInstance Win32_Process | Sort-Object WorkingSetSize -Descending | Select-Object -First 15
    AI "  {'Rank',-4} {'PID',-7} {'Name',-30} {'WS(MB)',-10} {'CPU(s)',-10} Owner"
    AI "  $('-'*80)"
    $rank = 1
    foreach ($p in $procs) {
        $owner = $p.GetOwner()
        $ownerStr = if ($owner.User) { "$($owner.Domain)\$($owner.User)" } else { "N/A" }
        $cpuSec = try { [math]::Round($p.UserModeTime / 1e7 + $p.KernelModeTime / 1e7, 1) } catch { "N/A" }
        $wsMB = [math]::Round($p.WorkingSetSize / 1MB, 1)
        AI "  $('{0,-4}' -f $rank) $('{0,-7}' -f $p.ProcessId) $('{0,-30}' -f $p.Name) $('{0,-10}' -f $wsMB) $('{0,-10}' -f $cpuSec) $ownerStr"
        $rank++
    }
} catch { AI "  [ERROR: $_]" }
AI ""

AI "------------------------------------------------------------------------------"
AI "  [5] TOP 15 PROCESSES BY CPU TIME"
AI "------------------------------------------------------------------------------"
try {
    $cpuProcs = Get-CimInstance Win32_Process |
        Select-Object ProcessId, Name, WorkingSetSize,
            @{N="TotalCPUsec";E={[math]::Round(($_.UserModeTime + $_.KernelModeTime)/1e7,1)}} |
        Sort-Object TotalCPUsec -Descending | Select-Object -First 15
    AI "  {'Rank',-4} {'PID',-7} {'Name',-30} {'CPU(s)',-12} WS(MB)"
    AI "  $('-'*70)"
    $rank = 1
    foreach ($p in $cpuProcs) {
        AI "  $('{0,-4}' -f $rank) $('{0,-7}' -f $p.ProcessId) $('{0,-30}' -f $p.Name) $('{0,-12}' -f $p.TotalCPUsec) $([math]::Round($p.WorkingSetSize/1MB,1))"
        $rank++
    }
} catch { AI "  [ERROR: $_]" }
AI ""

AI "------------------------------------------------------------------------------"
AI "  [6] STORAGE STATUS"
AI "------------------------------------------------------------------------------"
try {
    Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } | ForEach-Object {
        $freePct = if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { 0 }
        $freeGB  = [math]::Round($_.FreeSpace / 1GB, 1)
        $totalGB = [math]::Round($_.Size / 1GB, 1)
        $flag = if ($freePct -lt 10) { " <-- CRITICAL" } elseif ($freePct -lt 20) { " <-- WARNING" } else { "" }
        AI "  $($_.DeviceID)  Total: $totalGB GB  Free: $freeGB GB ($freePct%)$flag"
    }
} catch { AI "  [ERROR: $_]" }
try {
    $pfUsage = Get-CimInstance Win32_PageFileUsage | Select-Object -First 1
    if ($pfUsage) {
        AI "  Pagefile: $($pfUsage.CurrentUsage) MB used / $($pfUsage.AllocatedBaseSize) MB allocated (Peak: $($pfUsage.PeakUsage) MB)"
    }
} catch {}
AI ""

AI "------------------------------------------------------------------------------"
AI "  [7] SERVICES -- Auto-start but STOPPED"
AI "------------------------------------------------------------------------------"
try {
    $knownOk = @("MapsBroker","NetTcpPortSharing","RemoteRegistry","shpamsvc","tzautoupdate",
                 "XblAuthManager","XblGameSave","XboxGipSvc","XboxNetApiSvc","wisvc",
                 "WbioSrvc","PimIndexMaintenanceSvc","OneSyncSvc")
    $stopped = Get-CimInstance Win32_Service | Where-Object {
        $_.StartMode -eq "Auto" -and $_.State -ne "Running" -and $_.Name -notin $knownOk
    }
    if ($stopped) {
        foreach ($s in $stopped) {
            AI "  [STOPPED] $($s.Name.PadRight(35)) $($s.DisplayName)"
        }
    } else { AI "  All expected auto-start services are running." }
} catch { AI "  [ERROR: $_]" }
AI ""

AI "------------------------------------------------------------------------------"
AI "  [8] WER CRASH REPORTS (in time range)"
AI "------------------------------------------------------------------------------"
try {
    $werDirs = @(
        "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
        "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue",
        "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive"
    )
    $allCrashes = @()
    foreach ($dir in $werDirs) {
        if (Test-Path $dir) {
            $allCrashes += Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.CreationTime -ge $dtStart -and $_.CreationTime -le $dtEnd }
        }
    }
    if ($allCrashes) {
        foreach ($r in ($allCrashes | Sort-Object CreationTime -Descending | Select-Object -First 20)) {
            $werFile = Join-Path $r.FullName "Report.wer"
            $appName = if (Test-Path $werFile) {
                (Get-Content $werFile -ErrorAction SilentlyContinue | Select-String "AppName") -replace ".*AppName.*?=\s*",""
            } else { "(no Report.wer)" }
            AI "  [$($r.CreationTime.ToString('yyyy-MM-dd HH:mm:ss'))] $($r.Name)  App: $appName"
        }
    } else { AI "  No crash reports in the specified time range." }
} catch { AI "  [ERROR: $_]" }
AI ""

AI "------------------------------------------------------------------------------"
AI "  [9] STARTUP ITEMS (non-Microsoft / non-Windows)"
AI "------------------------------------------------------------------------------"
try {
    $runKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    )
    $startupFound = $false
    foreach ($key in $runKeys) {
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($props) {
            $props.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object {
                $val = $_.Value
                $isMicrosoft = $val -match "Microsoft|Windows\\System32|Windows\\SysWOW64"
                if (-not $isMicrosoft) {
                    AI "  [$key]"
                    AI "    Name : $($_.Name)"
                    AI "    Value: $val"
                    AI ""
                    $startupFound = $true
                }
            }
        }
    }
    if (-not $startupFound) { AI "  No non-Microsoft startup items found in registry Run keys." }
} catch { AI "  [ERROR: $_]" }
AI ""

AI "------------------------------------------------------------------------------"
AI "  [10] ACTIVE CONNECTIONS (ESTABLISHED, non-loopback)"
AI "------------------------------------------------------------------------------"
try {
    $procMap2 = @{}
    Get-Process | ForEach-Object { $procMap2[$_.Id] = $_.Name }
    $conns = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.RemoteAddress -ne "127.0.0.1" -and $_.RemoteAddress -ne "::1" } |
        Sort-Object RemoteAddress
    if ($conns) {
        AI "  {'LocalAddr:Port',-25} {'RemoteAddr:Port',-25} {'PID',-7} Process"
        AI "  $('-'*75)"
        foreach ($c in ($conns | Select-Object -First 40)) {
            $local  = "$($c.LocalAddress):$($c.LocalPort)"
            $remote = "$($c.RemoteAddress):$($c.RemotePort)"
            $pname  = $procMap2[$c.OwningProcess]
            AI "  $('{0,-25}' -f $local) $('{0,-25}' -f $remote) $('{0,-7}' -f $c.OwningProcess) $pname"
        }
        if ($conns.Count -gt 40) { AI "  ... ($($conns.Count - 40) more -- see 04_network/active_connections.txt)" }
    } else { AI "  No established non-loopback TCP connections." }
} catch { AI "  [ERROR: $_]" }
AI ""

AI "------------------------------------------------------------------------------"
AI "  [11] SECURITY SUMMARY (Event Counts in Time Range)"
AI "------------------------------------------------------------------------------"
try {
    $secIds = @(
        @{Id=4625; Label="Failed Logons (brute force indicator if >10)"},
        @{Id=4720; Label="User Accounts Created"},
        @{Id=4726; Label="User Accounts Deleted"},
        @{Id=4672; Label="Special Privilege Logons (admin-level)"},
        @{Id=1102; Label="Audit Log Cleared (tampering indicator)"}
    )
    foreach ($item in $secIds) {
        try {
            $cnt = (Get-WinEvent -FilterHashtable @{LogName="Security"; Id=$item.Id; StartTime=$dtStart; EndTime=$dtEnd} -ErrorAction Stop).Count
            $flag = ""
            if ($item.Id -eq 4625 -and $cnt -gt 10) { $flag = " <-- SUSPICIOUS" }
            if ($item.Id -eq 1102 -and $cnt -gt 0)  { $flag = " <-- ALERT: LOG TAMPERING" }
            if ($item.Id -eq 4720 -and $cnt -gt 0)  { $flag = " <-- REVIEW REQUIRED" }
            AI "  ID $($item.Id): $cnt event(s)  -- $($item.Label)$flag"
        } catch {
            AI "  ID $($item.Id): (access denied or log unavailable) -- $($item.Label)"
        }
    }
} catch { AI "  [ERROR collecting security summary: $_]" }
AI ""

AI "------------------------------------------------------------------------------"
AI "  [12] INSTALLED SOFTWARE (Last 30 Days)"
AI "------------------------------------------------------------------------------"
try {
    $cutoff = (Get-Date).AddDays(-30).ToString("yyyyMMdd")
    $recentApps = @()
    foreach ($path in @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*")) {
        $recentApps += Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.InstallDate -ge $cutoff } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
    }
    if ($recentApps) {
        $recentApps | Sort-Object InstallDate -Descending | ForEach-Object {
            AI "  [$($_.InstallDate)] $($_.DisplayName) $($_.DisplayVersion)  by $($_.Publisher)"
        }
    } else { AI "  No software installed in the past 30 days." }
} catch { AI "  [ERROR: $_]" }
AI ""

AI "------------------------------------------------------------------------------"
AI "  END OF SUMMARY -- See individual files in ZIP for full details"
AI "------------------------------------------------------------------------------"

$aiLines | Set-Content -Path $aiFile -Encoding UTF8
Write-Host "  -> SUMMARY_FOR_AI.txt written ($($aiLines.Count) lines)" -ForegroundColor Green

# ===========================================================================
# COMPRESS OUTPUT
# ===========================================================================
Write-Host ""
Write-Host "Compressing output to ZIP..." -ForegroundColor Cyan
$zipPath = Join-Path $OutputPath "${DiagRoot}.zip"

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($DiagPath, $zipPath)
    $zipSizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
    Write-Host "ZIP created: $zipPath ($zipSizeMB MB)" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] Failed to create ZIP: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Raw output directory is still available at: $DiagPath" -ForegroundColor Yellow
    $zipPath = "(ZIP creation failed -- see raw folder: $DiagPath)"
}

# ===========================================================================
# SUMMARY
# ===========================================================================
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Collection Summary" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  Computer   : $ComputerName"
Write-Host "  Time Range : $($dtStart.ToString('yyyy-MM-dd HH:mm')) -> $($dtEnd.ToString('yyyy-MM-dd HH:mm'))"
Write-Host "  Output ZIP : $zipPath"
Write-Host "  Raw Folder : $DiagPath"
Write-Host ""

$fileCount = (Get-ChildItem $DiagPath -Recurse -File -ErrorAction SilentlyContinue).Count
Write-Host "  Files collected: $fileCount"
Write-Host ""

if ($PermissionErrors.Count -gt 0) {
    Write-Host "  Permission / Collection Errors ($($PermissionErrors.Count)):" -ForegroundColor Yellow
    foreach ($err in $PermissionErrors) {
        Write-Host "    - $err" -ForegroundColor Yellow
    }
} else {
    Write-Host "  No permission errors encountered." -ForegroundColor Green
}

Write-Host ""
Write-Host "  Sections collected:" -ForegroundColor Cyan
Write-Host "    [1/8] 01_system          - systeminfo, hardware, hotfixes, env vars, BCD"
Write-Host "    [2/8] 02_event_logs      - System, Application, Security, Defender, PS, TaskSched, WU"
Write-Host "    [3/8] 03_processes       - Processes, tree, services, scheduled tasks, startup items"
Write-Host "    [4/8] 04_network         - IP config, connections, ARP, routes, DNS, firewall, hosts"
Write-Host "    [5/8] 05_storage         - Disk usage, health, shadow copies, pagefile"
Write-Host "    [6/8] 06_security        - Users, groups, sessions, audit policy, AV status"
Write-Host "    [7/8] 07_software        - Installed apps, browsers, QEMU Guest Agent"
Write-Host "    [8/8] 08_crash_reports   - WER reports, minidumps"
Write-Host ""
Write-Host "Done." -ForegroundColor Green

#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Nerdy Neighbor - Slow Disk Optimizer
.DESCRIPTION
    Detects whether Windows is running from eMMC or a mechanical hard drive and
    applies the tweaks that actually help on that kind of storage. Every change
    is recorded so it can be reverted.
.NOTES
    Run:  irm slowdisk.nerdyneighbor.net | iex        (elevated Windows PowerShell)
    Log:  C:\ProgramData\NerdyNeighbor\slowdisk.log
    State (used by revert): C:\ProgramData\NerdyNeighbor\slowdisk-state.json
    Options (set BEFORE the irm line, since iex can't take parameters):
      $env:NN_SLOWDISK = 'auto'     # default - detect the boot drive type
      $env:NN_SLOWDISK = 'hdd'      # force the hard-drive profile
      $env:NN_SLOWDISK = 'emmc'     # force the eMMC profile
      $env:NN_SLOWDISK = 'report'   # show what would change, change nothing
      $env:NN_SLOWDISK = 'revert'   # undo everything this script changed
      $env:NN_SLOWDISK_COMPACT = 'no'   # eMMC: skip CompactOS (it can take 20+ min)
      $env:NN_SLOWDISK_VISUAL  = 'no'   # skip "best performance" visual effects
      $env:NN_SLOWDISK_SEARCH  = 'off'|'keep'   # override the search indexer decision
      $env:NN_SLOWDISK_SYSMAIN = 'off'  # disable SysMain anyway (not recommended)
#>

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# When run via `irm ... | iex` the #Requires line is NOT enforced (that only
# works for a real .ps1 file), so check for elevation ourselves.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  This needs an ELEVATED PowerShell (Run as Administrator)." -ForegroundColor Red
    Write-Host "  Close this window, reopen PowerShell as Administrator, and run again." -ForegroundColor Yellow
    Write-Host ""
    return
}

# --- Logging -----------------------------------------------------------------
$LogDir    = Join-Path $env:ProgramData 'NerdyNeighbor'
$LogFile   = Join-Path $LogDir 'slowdisk.log'
$StateFile = Join-Path $LogDir 'slowdisk-state.json'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0}  [{1}]  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    switch ($Level) {
        'ERROR' { Write-Host "  $Message" -ForegroundColor Red }
        'WARN'  { Write-Host "  $Message" -ForegroundColor Yellow }
        'OK'    { Write-Host "  $Message" -ForegroundColor Green }
        'HEAD'  { Write-Host ""; Write-Host "  $Message" -ForegroundColor Cyan }
        default { Write-Host "  $Message" -ForegroundColor Gray }
    }
}

# Run a console tool without letting its stderr become a terminating error
# (Windows PowerShell 5.1 + ErrorActionPreference=Stop turns `2>&1` output
# into exceptions). Returns the output lines; $LASTEXITCODE is set as usual.
function Invoke-Native {
    param([string]$Exe, [Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgList)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Exe @ArgList 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $old }
}

# Each tweak runs on its own, so one failure never stops the rest.
function Invoke-Step([string]$Name, [scriptblock]$Block) {
    try { & $Block }
    catch { Write-Log "$Name - skipped: $($_.Exception.Message)" 'WARN'; $script:Skipped++ }
}

# --- Options -----------------------------------------------------------------
$Mode = "$env:NN_SLOWDISK".Trim().ToLower()
if (-not $Mode) { $Mode = 'auto' }
if ($Mode -notin 'auto', 'hdd', 'emmc', 'report', 'revert') {
    Write-Host "  Unknown NN_SLOWDISK value '$Mode'. Use auto, hdd, emmc, report or revert." -ForegroundColor Red
    return
}
$DryRun      = ($Mode -eq 'report')
$OptCompact  = "$env:NN_SLOWDISK_COMPACT".Trim().ToLower() -ne 'no'
$OptVisual   = "$env:NN_SLOWDISK_VISUAL".Trim().ToLower() -ne 'no'
$OptSearch   = "$env:NN_SLOWDISK_SEARCH".Trim().ToLower()
$OptSysMain  = "$env:NN_SLOWDISK_SYSMAIN".Trim().ToLower()

$script:Changed = 0
$script:Skipped = 0

# --- State (what we changed, so revert can undo it) --------------------------
$script:State = New-Object System.Collections.ArrayList
if (Test-Path $StateFile) {
    try {
        $loaded = Get-Content -Raw -Path $StateFile | ConvertFrom-Json
        foreach ($c in @($loaded.Changes)) { if ($c) { [void]$script:State.Add($c) } }
    } catch {
        Write-Log "Could not read $StateFile ($($_.Exception.Message)) - starting a fresh record." 'WARN'
    }
}
function Save-State {
    $obj = [pscustomobject]@{ Version = 1; Changes = @($script:State) }
    ConvertTo-Json -InputObject $obj -Depth 6 | Set-Content -Path $StateFile -Encoding UTF8
}
function Test-Recorded([string]$Id) {
    foreach ($c in $script:State) { if ($c.Id -eq $Id) { return $true } }
    return $false
}
function Add-Record([hashtable]$Record) {
    if (Test-Recorded $Record.Id) { return }   # keep the ORIGINAL value from the first run
    [void]$script:State.Add([pscustomobject]$Record)
    Save-State
}
function Note-Change([string]$What) {
    $script:Changed++
    if ($DryRun) { Write-Log "WOULD: $What" 'WARN' } else { Write-Log $What 'OK' }
}
function Note-Same([string]$What) { Write-Log "$What (already set)" }

# --- Registry helper ---------------------------------------------------------
# $Path is a full provider path, e.g. 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\...'
function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type, [string]$Label,
          [string]$HiveSid = $null, [string]$HiveFile = $null)
    $exists = $false; $cur = $null; $curKind = $null
    if (Test-Path $Path) {
        $key = Get-Item -Path $Path
        try {
            if ($key.GetValueNames() -contains $Name) {
                $exists  = $true
                $cur     = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
                $curKind = $key.GetValueKind($Name).ToString()
            }
        } finally { $key.Close() }
    }
    if ($exists) {
        if ($Type -eq 'Binary') { $same = ((@($cur) -join ',') -eq (@($Value) -join ',')) }
        else                    { $same = ("$cur" -eq "$Value") }
        if ($same) { if ($Label) { Note-Same $Label }; return }
    }
    if ($Label) { Note-Change $Label } else { $script:Changed++ }
    if ($DryRun) { return }

    $old = $null
    if ($exists) {
        if ($curKind -eq 'Binary') { $old = [Convert]::ToBase64String([byte[]]$cur) } else { $old = $cur }
    }
    Add-Record @{ Id = "reg|$Path|$Name"; Kind = 'reg'; Path = $Path; Name = $Name;
                  Existed = $exists; OldKind = $curKind; OldValue = $old;
                  HiveSid = $HiveSid; HiveFile = $HiveFile }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# --- Service helper ----------------------------------------------------------
function Get-SvcMode([string]$Name) {
    $p = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path $p)) { return $null }
    $v = Get-ItemProperty -Path $p
    switch ([int]$v.Start) {
        2 { if ($v.DelayedAutostart -eq 1) { 'delayed-auto' } else { 'auto' } }
        3 { 'demand' }
        4 { 'disabled' }
        default { "start$($v.Start)" }
    }
}
function Set-Svc([string]$Name, [string]$Mode, [string]$Label) {
    $cur = Get-SvcMode $Name
    if (-not $cur) { Write-Log "$Label - service $Name not present, skipping."; return }
    if ($cur -eq $Mode) { Note-Same $Label; return }
    Note-Change "$Label ($cur -> $Mode)"
    if ($DryRun) { return }
    Add-Record @{ Id = "svc|$Name"; Kind = 'svc'; Name = $Name; OldValue = $cur }
    Invoke-Native sc.exe config $Name start= $Mode | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log "sc.exe config $Name failed (exit $LASTEXITCODE)" 'WARN'; return }
    if ($Mode -eq 'disabled') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    elseif ($Mode -like '*auto') { Start-Service -Name $Name -ErrorAction SilentlyContinue }
}

# --- Per-user hives (visual effects must go into every profile) --------------
function Invoke-ForEachUserHive([scriptblock]$Action) {
    $list = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $targets = @()
    foreach ($k in Get-ChildItem $list) {
        $sid = $k.PSChildName
        if ($sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { continue }
        $dir = (Get-ItemProperty $k.PSPath).ProfileImagePath
        $targets += [pscustomobject]@{ Sid = $sid; File = (Join-Path $dir 'NTUSER.DAT'); Name = (Split-Path $dir -Leaf) }
    }
    $defDir = (Get-ItemProperty $list).Default
    if ($defDir) { $targets += [pscustomobject]@{ Sid = 'NN_DefaultUser'; File = (Join-Path $defDir 'NTUSER.DAT'); Name = 'Default (new users)' } }

    foreach ($t in $targets) {
        $root = "Registry::HKEY_USERS\$($t.Sid)"
        $weLoaded = $false
        if (-not (Test-Path $root)) {
            if (-not (Test-Path $t.File)) { continue }
            Invoke-Native reg.exe load "HKU\$($t.Sid)" "$($t.File)" | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Log "Could not load profile $($t.Name) - skipped." 'WARN'; continue }
            $weLoaded = $true
        }
        try { & $Action $root $t }
        catch { Write-Log "Profile $($t.Name): $($_.Exception.Message)" 'WARN' }
        finally {
            if ($weLoaded) {
                [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                Invoke-Native reg.exe unload "HKU\$($t.Sid)" | Out-Null
            }
        }
    }
}

# --- Drive detection ---------------------------------------------------------
function Get-BootDriveInfo {
    $letter = $env:SystemDrive.TrimEnd(':')
    $part   = Get-Partition -DriveLetter $letter
    $disk   = Get-Disk -Number $part.DiskNumber
    $pd     = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq "$($disk.Number)" } | Select-Object -First 1
    $msft   = Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_PhysicalDisk |
              Where-Object { $_.DeviceId -eq "$($disk.Number)" } | Select-Object -First 1
    $w32    = Get-CimInstance Win32_DiskDrive | Where-Object { $_.Index -eq $disk.Number } | Select-Object -First 1

    $bus    = "$($disk.BusType)"
    $media  = if ($pd) { "$($pd.MediaType)" } else { 'Unspecified' }
    $spin   = if ($msft) { [uint32]$msft.SpindleSpeed } else { 0 }
    $name   = "$($disk.FriendlyName)"
    $pnp    = if ($w32) { "$($w32.PNPDeviceID)" } else { '' }
    $model  = "$((Get-CimInstance Win32_ComputerSystem).Model)"

    $kind = 'unknown'; $why = ''
    if ($bus -in 'SD', 'MMC' -or $pnp -match '^(SD|MMC)\\' -or $name -match '\beMMC\b|\bMMC\b') {
        $kind = 'emmc'; $why = "bus type $bus"
    } elseif ($bus -in 'NVMe', 'UFS', 'SCM') {
        $kind = 'ssd';  $why = "bus type $bus"
    } elseif ($media -eq 'HDD') {
        $kind = 'hdd';  $why = 'Windows reports a rotational drive (seek penalty)'
    } elseif ($media -eq 'SSD') {
        $kind = 'ssd';  $why = 'Windows reports no seek penalty'
    } elseif ($spin -gt 0 -and $spin -lt 100000) {
        $kind = 'hdd';  $why = "spindle speed $spin RPM"
    } elseif ($name -match 'SSD|NVMe|Solid') {
        $kind = 'ssd';  $why = 'model name'
    }
    if ($model -match 'Virtual|VMware|KVM|QEMU' -and $kind -eq 'unknown') { $why = 'virtual machine' }

    $vol = Get-Volume -DriveLetter $letter
    [pscustomobject]@{
        Kind = $kind; Why = $why; Bus = $bus; Media = $media; Name = $name
        SizeGB = [math]::Round($disk.Size / 1GB, 0)
        FreeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
        FreePct = if ($vol.Size) { [math]::Round(100 * $vol.SizeRemaining / $vol.Size, 0) } else { 0 }
        Letter = $letter
    }
}

# =============================================================================
#  REVERT
# =============================================================================
function Invoke-Revert {
    Write-Log "Reverting changes recorded in $StateFile" 'HEAD'
    if ($script:State.Count -eq 0) { Write-Log "Nothing recorded - nothing to revert." 'OK'; return }
    $items = @($script:State); [array]::Reverse($items)
    $failed = 0
    foreach ($c in $items) {
        try {
            switch ($c.Kind) {
                'reg' {
                    $weLoaded = $false
                    if ($c.HiveSid -and -not (Test-Path "Registry::HKEY_USERS\$($c.HiveSid)")) {
                        Invoke-Native reg.exe load "HKU\$($c.HiveSid)" "$($c.HiveFile)" | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw "could not load hive for $($c.HiveSid)" }
                        $weLoaded = $true
                    }
                    try {
                        if (-not $c.Existed) {
                            Remove-ItemProperty -Path $c.Path -Name $c.Name -ErrorAction SilentlyContinue
                        } else {
                            $v = $c.OldValue
                            switch ($c.OldKind) {
                                'Binary'      { $v = [Convert]::FromBase64String($v) }
                                'DWord'       { $v = [int]$v }
                                'QWord'       { $v = [long]$v }
                                'MultiString' { $v = [string[]]@($v) }
                            }
                            if (-not (Test-Path $c.Path)) { New-Item -Path $c.Path -Force | Out-Null }
                            New-ItemProperty -Path $c.Path -Name $c.Name -Value $v -PropertyType $c.OldKind -Force | Out-Null
                        }
                    } finally {
                        if ($weLoaded) { [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Invoke-Native reg.exe unload "HKU\$($c.HiveSid)" | Out-Null }
                    }
                    Write-Log "Restored $($c.Path -replace '^Registry::','')\$($c.Name)" 'OK'
                }
                'svc' {
                    Invoke-Native sc.exe config $c.Name start= $c.OldValue | Out-Null
                    if ($c.OldValue -like '*auto') { Start-Service $c.Name -ErrorAction SilentlyContinue }
                    Write-Log "Service $($c.Name) back to $($c.OldValue)" 'OK'
                }
                'task' {
                    if ($c.OldValue -eq 'Disabled') { Disable-ScheduledTask -TaskPath $c.TaskPath -TaskName $c.Name | Out-Null }
                    else { Enable-ScheduledTask -TaskPath $c.TaskPath -TaskName $c.Name | Out-Null }
                    Write-Log "Scheduled task $($c.Name) back to $($c.OldValue)" 'OK'
                }
                'lastaccess' {
                    Invoke-Native fsutil.exe behavior set disablelastaccess $c.OldValue | Out-Null
                    Write-Log "NTFS last-access setting back to $($c.OldValue)" 'OK'
                }
                'mmagent' {
                    $p = @{ $c.Name = $true }
                    if ($c.OldValue) { Enable-MMAgent @p } else { Disable-MMAgent @p }
                    Write-Log "Memory manager $($c.Name) back to $($c.OldValue)" 'OK'
                }
                'mp' {
                    $v = $c.OldValue
                    if ($c.Name -eq 'ScanAvgCPULoadFactor') { $v = [byte]$v } else { $v = [bool]$v }
                    $p = @{ $c.Name = $v }; Set-MpPreference @p
                    Write-Log "Defender $($c.Name) back to $($c.OldValue)" 'OK'
                }
                'hiber' {
                    if (-not $c.OldEnabled) { Invoke-Native powercfg.exe /hibernate off | Out-Null }
                    else {
                        Invoke-Native powercfg.exe /hibernate on | Out-Null
                        if ($c.OldType) { Invoke-Native powercfg.exe /hibernate /type $c.OldType | Out-Null }
                        if ($c.OldSize) { Invoke-Native powercfg.exe /hibernate /size $c.OldSize | Out-Null }
                    }
                    Write-Log "Hibernation back to $(if ($c.OldEnabled) { "on ($($c.OldType))" } else { 'off' })" 'OK'
                }
                'compactos' {
                    Write-Log "Decompressing Windows (CompactOS off) - this can take 20+ minutes..." 'WARN'
                    Invoke-Native compact.exe /compactos:never | Out-Null
                    Write-Log "CompactOS turned off" 'OK'
                }
                'pagefile' {
                    $cs = Get-CimInstance Win32_ComputerSystem
                    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = [bool]$c.OldValue }
                    Write-Log "Automatic page file back to $($c.OldValue)" 'OK'
                }
            }
        } catch {
            $failed++
            Write-Log "Could not revert $($c.Id): $($_.Exception.Message)" 'WARN'
        }
    }
    if ($failed -eq 0) {
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        Write-Log "Everything reverted. Reboot to finish." 'OK'
    } else {
        Write-Log "$failed item(s) could not be reverted - see above. State file kept." 'WARN'
    }
}

# =============================================================================
#  MAIN
# =============================================================================
try {
    Write-Host ""
    Write-Host "  Nerdy Neighbor - Slow Disk Optimizer" -ForegroundColor Cyan
    Write-Host ""
    Write-Log "=== Run started on $env:COMPUTERNAME (user: $env:USERNAME, mode: $Mode) ==="

    if ($Mode -eq 'revert') { Invoke-Revert; Write-Host ""; return }

    $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    if ($build -lt 10240) { Write-Log "This is for Windows 10/11 only (build $build)." 'ERROR'; return }

    # ---- Detect --------------------------------------------------------------
    Write-Log "Checking the boot drive" 'HEAD'
    $drive = Get-BootDriveInfo
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    Write-Log ("Drive  : {0} ({1} GB, bus {2}, media {3})" -f $drive.Name, $drive.SizeGB, $drive.Bus, $drive.Media)
    Write-Log ("Free   : {0} GB ({1}%) on {2}:" -f $drive.FreeGB, $drive.FreePct, $drive.Letter)
    Write-Log ("RAM    : {0} GB" -f $ramGB)

    $diskProfile = $drive.Kind
    if ($Mode -in 'hdd', 'emmc') {
        Write-Log "Detected '$($drive.Kind)', but NN_SLOWDISK forces '$Mode'." 'WARN'
        $diskProfile = $Mode
    } else {
        Write-Log "Detected: $($drive.Kind.ToUpper()) ($($drive.Why))" 'OK'
    }

    if ($diskProfile -eq 'ssd') {
        Write-Log "This PC boots from an SSD - these tweaks aren't needed. Nothing changed." 'OK'
        Write-Log "To force it anyway: `$env:NN_SLOWDISK = 'hdd' (or 'emmc') before the irm line."
        Write-Host ""; return
    }
    if ($diskProfile -eq 'unknown') {
        $answer = $null
        if ([Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost') {
            Write-Log "Couldn't tell what kind of drive this is." 'WARN'
            $answer = (Read-Host "  Type hdd, emmc, or press Enter to cancel").Trim().ToLower()
        }
        if ($answer -in 'hdd', 'emmc') { $diskProfile = $answer }
        else {
            Write-Log "Drive type unknown - nothing changed. Set `$env:NN_SLOWDISK = 'hdd' or 'emmc' and run again." 'WARN'
            Write-Host ""; return
        }
    }
    $isHdd = ($diskProfile -eq 'hdd'); $isEmmc = ($diskProfile -eq 'emmc')
    if ($DryRun) { Write-Log "REPORT MODE - nothing will be changed." 'WARN' }
    Write-Log "Applying the $($diskProfile.ToUpper()) profile" 'HEAD'

    # ---- 1. NTFS last-access timestamps (a write on every file read) -----------
    Invoke-Step 'NTFS last-access timestamps' {
    $q = (Invoke-Native fsutil.exe behavior query disablelastaccess) -join ' '
    $curLA = if ($q -match '=\s*(\d)') { [int]$Matches[1] } else { -1 }
    if ($curLA -in 1, 3) { Note-Same "NTFS last-access updates off" }
    else {
        Note-Change "NTFS last-access updates off (was $curLA)"
        if (-not $DryRun) {
            Add-Record @{ Id = 'lastaccess'; Kind = 'lastaccess'; OldValue = $curLA }
            Invoke-Native fsutil.exe behavior set disablelastaccess 1 | Out-Null
        }
    }
    }

    # ---- 2. SysMain + memory compression --------------------------------------
    Invoke-Step 'SysMain + memory compression' {
    # SysMain does boot/app prefetch (ReadyBoot) - built for HDDs - and memory
    # compression, which keeps low-RAM machines from paging to the slow disk.
    if ($OptSysMain -eq 'off') {
        Set-Svc 'SysMain' 'disabled' 'SysMain disabled (forced by NN_SLOWDISK_SYSMAIN)'
    } else {
        if ((Get-SvcMode 'SysMain') -eq 'disabled') {
            Set-Svc 'SysMain' 'auto' 'SysMain re-enabled (prefetch + memory compression help slow disks)'
        } else { Note-Same 'SysMain enabled' }
        Set-Reg 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' `
            'EnablePrefetcher' 3 'DWord' 'Prefetcher on (boot + app launch)'
    }
    try {
        $mm = Get-MMAgent
        if ($ramGB -le 8 -and $OptSysMain -ne 'off') {
            if ($mm.MemoryCompression) { Note-Same 'Memory compression on' }
            else {
                Note-Change 'Memory compression on (less paging to disk)'
                if (-not $DryRun) { Add-Record @{ Id = 'mm|MemoryCompression'; Kind = 'mmagent'; Name = 'MemoryCompression'; OldValue = $false }; Enable-MMAgent -MemoryCompression }
            }
        }
        if (-not $mm.ApplicationPreLaunch) { Note-Same 'Store app pre-launch off' }
        else {
            Note-Change 'Store app pre-launch off'
            if (-not $DryRun) { Add-Record @{ Id = 'mm|ApplicationPreLaunch'; Kind = 'mmagent'; Name = 'ApplicationPreLaunch'; OldValue = $true }; Disable-MMAgent -ApplicationPreLaunch }
        }
    } catch { Write-Log "Memory manager settings skipped: $($_.Exception.Message)" 'WARN'; $script:Skipped++ }
    }

    # ---- 3. Windows Search indexer --------------------------------------------
    Invoke-Step 'Windows Search indexer' {
    $hasOutlook = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\OUTLOOK.EXE'
    $searchOff = $false
    if     ($OptSearch -eq 'off')  { $searchOff = $true }
    elseif ($OptSearch -eq 'keep') { $searchOff = $false }
    elseif ($isHdd -and -not $hasOutlook) { $searchOff = $true }
    if ($searchOff) {
        Set-Svc 'WSearch' 'disabled' 'Search indexer disabled (constant random reads on HDD)'
    } elseif ($hasOutlook -and $isHdd) {
        Write-Log "Search indexer kept - classic Outlook is installed and its search needs it." 'WARN'
    } else {
        Write-Log "Search indexer kept (eMMC handles it OK; Start menu/Settings search rely on it)."
    }
    }

    # ---- 4. Hibernation / Fast Startup ----------------------------------------
    Invoke-Step 'Hibernation / Fast Startup' {
    # Fast Startup needs the hiberfile. Reduced type = ~20% of RAM, no user hibernate.
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
    $pk = Get-ItemProperty $powerKey -ErrorAction SilentlyContinue
    if ($null -ne $pk.HibernateEnabled) { $hiberOn = ($pk.HibernateEnabled -eq 1) }
    else { $hiberOn = Test-Path (Join-Path $env:SystemDrive 'hiberfil.sys') }
    $hiberTyp = switch ($pk.HiberFileType) { 1 { 'reduced' } 2 { 'full' } default { $null } }
    $hiberNeedGB = [math]::Round($ramGB * 0.2 + 1, 1)
    $wantHiber = -not ($isEmmc -and ($drive.FreeGB - $hiberNeedGB) -lt 10)
    if ($wantHiber) {
        if ($hiberOn -and $hiberTyp -eq 'reduced') { Note-Same 'Fast Startup on (reduced hiberfile)' }
        else {
            Note-Change "Fast Startup on with a reduced hiberfile (~$hiberNeedGB GB) - faster cold boots"
            if (-not $DryRun) {
                Add-Record @{ Id = 'hiber'; Kind = 'hiber'; OldEnabled = $hiberOn; OldType = $hiberTyp; OldSize = $pk.HiberFileSizePercent }
                $o = Invoke-Native powercfg.exe /hibernate on
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Hibernation isn't available on this PC ($(($o -join ' ').Trim())) - Fast Startup skipped." 'WARN'; $script:Skipped++
                } else {
                    # A custom hiberfile size makes '/type reduced' fail with
                    # "The provided hiber file type is invalid" - clear it first.
                    Invoke-Native powercfg.exe /hibernate /size 0 | Out-Null
                    Remove-ItemProperty -Path $powerKey -Name 'HiberFileSizePercent' -ErrorAction SilentlyContinue
                    $o = Invoke-Native powercfg.exe /hibernate /type reduced
                    if ($LASTEXITCODE -ne 0) {
                        Write-Log "Reduced hiberfile not accepted ($(($o -join ' ').Trim())) - using the full size so Fast Startup still works." 'WARN'
                        Invoke-Native powercfg.exe /hibernate /type full | Out-Null
                    }
                }
            }
        }
        Set-Reg 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
            'HiberbootEnabled' 1 'DWord' 'Fast Startup enabled'
    } else {
        if (-not $hiberOn) { Note-Same 'Hibernation off (disk too full for a hiberfile)' }
        else {
            Note-Change 'Hibernation off (disk space is too tight on this eMMC)'
            if (-not $DryRun) {
                Add-Record @{ Id = 'hiber'; Kind = 'hiber'; OldEnabled = $hiberOn; OldType = $hiberTyp }
                Invoke-Native powercfg.exe /hibernate off | Out-Null
            }
        }
    }
    }

    # ---- 5. Defender: throttle scans, never disable ---------------------------
    Invoke-Step 'Defender: throttle scans, never disable' {
    try {
        $mp = Get-MpComputerStatus
        if (-not $mp.AntivirusEnabled -or ($mp.AMRunningMode -and $mp.AMRunningMode -ne 'Normal')) {
            Write-Log "Defender is in '$($mp.AMRunningMode)' mode (another AV is active) - skipped."
        } else {
            $pref = Get-MpPreference
            $want = @(
                @{ N = 'EnableLowCpuPriority';  Cur = [bool]$pref.EnableLowCpuPriority;  New = $true; L = 'Defender scans run at low priority' },
                @{ N = 'ScanOnlyIfIdleEnabled'; Cur = [bool]$pref.ScanOnlyIfIdleEnabled; New = $true; L = 'Defender scheduled scans only when idle' }
            )
            $load = [int]$pref.ScanAvgCPULoadFactor
            if ($load -eq 0 -or $load -gt 25) {
                $want += @{ N = 'ScanAvgCPULoadFactor'; Cur = $load; New = [byte]25; L = "Defender scan CPU cap 25% (was $load)" }
            } else { Note-Same "Defender scan CPU cap $load%" }
            foreach ($w in $want) {
                if ($w.Cur -eq $w.New) { Note-Same $w.L; continue }
                Note-Change $w.L
                if ($DryRun) { continue }
                Add-Record @{ Id = "mp|$($w.N)"; Kind = 'mp'; Name = $w.N; OldValue = $w.Cur }
                $p = @{ $w.N = $w.New }; Set-MpPreference @p
            }
        }
    } catch { Write-Log "Defender settings skipped: $($_.Exception.Message)" 'WARN'; $script:Skipped++ }
    }

    # ---- 6. Compatibility Appraiser (CompatTelRunner full-disk scans) ---------
    Invoke-Step 'Compatibility Appraiser' {
    $tasks = @()
    try {
        $tasks += Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -ErrorAction SilentlyContinue |
            Where-Object { $_.TaskName -like 'Microsoft Compatibility Appraiser*' -or $_.TaskName -eq 'ProgramDataUpdater' }
    } catch { }
    foreach ($t in $tasks) {
        if ($t.State -eq 'Disabled') { Note-Same "Task '$($t.TaskName)' off"; continue }
        Note-Change "Task '$($t.TaskName)' off (CompatTelRunner disk scans)"
        if ($DryRun) { continue }
        try {
            Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName | Out-Null
            Add-Record @{ Id = "task|$($t.TaskName)"; Kind = 'task'; TaskPath = $t.TaskPath; Name = $t.TaskName; OldValue = 'Ready' }
        } catch { Write-Log "Couldn't disable $($t.TaskName): $($_.Exception.Message)" 'WARN'; $script:Skipped++ }
    }
    }

    # ---- 7. Edge running in the background ------------------------------------
    Invoke-Step 'Edge running in the background' {
    $edgePol = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Edge'
    Set-Reg $edgePol 'StartupBoostEnabled'   0 'DWord' 'Edge Startup Boost off'
    Set-Reg $edgePol 'BackgroundModeEnabled' 0 'DWord' 'Edge background mode off'
    }

    # ---- 8. Page file safety net ----------------------------------------------
    Invoke-Step 'Page file safety net' {
    $cs = Get-CimInstance Win32_ComputerSystem
    $pfs = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)
    if (-not $cs.AutomaticManagedPagefile -and $pfs.Count -eq 0) {
        Note-Change 'Page file was DISABLED - set back to system managed'
        if (-not $DryRun) {
            Add-Record @{ Id = 'pagefile'; Kind = 'pagefile'; OldValue = $false }
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true }
        }
    } elseif ($cs.AutomaticManagedPagefile) { Note-Same 'Page file system managed' }
    else { Write-Log "Custom page file size in use - left alone." }
    }

    # ---- 9. Drive optimization (defrag for HDD, TRIM for eMMC) ----------------
    Invoke-Step 'Drive optimization' {
    try {
        $defrag = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop
        if ($defrag.State -ne 'Disabled') { Note-Same "Weekly drive optimization on" }
        else {
            Note-Change 'Weekly drive optimization re-enabled'
            if (-not $DryRun) {
                Add-Record @{ Id = 'task|ScheduledDefrag'; Kind = 'task'; TaskPath = '\Microsoft\Windows\Defrag\'; Name = 'ScheduledDefrag'; OldValue = 'Disabled' }
                Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' | Out-Null
            }
        }
    } catch { Write-Log "Drive optimization task not found - skipped." 'WARN' }
    if ($isEmmc -and -not $DryRun) {
        try { Optimize-Volume -DriveLetter $drive.Letter -ReTrim -ErrorAction Stop; Write-Log 'TRIM sent to the eMMC' 'OK' }
        catch { Write-Log "TRIM not supported by this eMMC controller - skipped." }
    }
    }

    # ---- 10. Visual effects (every profile + new users) -----------------------
    Invoke-Step 'Visual effects' {
    if ($OptVisual) {
        Write-Log "Visual effects -> best performance (keeps smooth fonts + thumbnails)"
        $script:before = $script:Changed
        Invoke-ForEachUserHive {
            param($root, $t)
            $before = $script:before; $sid = $t.Sid; $file = $t.File
            $set = {
                param($sub, $n, $v, $ty)
                Set-Reg "$root\$sub" $n $v $ty $null $sid $file
            }
            & $set 'Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary'
            & $set 'Control Panel\Desktop' 'DragFullWindows' '0' 'String'
            & $set 'Control Panel\Desktop' 'FontSmoothing' '2' 'String'
            & $set 'Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
            & $set 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3 'DWord'
            & $set 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0 'DWord'
            & $set 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 0 'DWord'
            & $set 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewShadow' 0 'DWord'
            & $set 'Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0 'DWord'
            & $set 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0 'DWord'
            $n = $script:Changed - $before
            if ($n -gt 0) { Write-Log "  - $($t.Name): $n setting(s)" $(if ($DryRun) { 'WARN' } else { 'OK' }) }
            else { Write-Log "  - $($t.Name): already set" }
            $script:before = $script:Changed
        }
    } else { Write-Log "Visual effects skipped (NN_SLOWDISK_VISUAL=no)" }
    }

    # ---- 11. CompactOS (eMMC only - fewer bytes to read, frees 2-4 GB) --------
    Invoke-Step 'CompactOS' {
    if ($isEmmc) {
        if (-not $OptCompact) { Write-Log "CompactOS skipped (NN_SLOWDISK_COMPACT=no)" }
        else {
            $cq = (Invoke-Native compact.exe /compactos:query) -join ' '
            if ($cq -match 'is in the Compact state') { Note-Same 'CompactOS on' }
            elseif ($cq -notmatch 'not in the Compact state') {
                Write-Log "Couldn't read CompactOS state (non-English Windows?) - skipped." 'WARN'; $script:Skipped++
            } else {
                Note-Change 'CompactOS on (compresses Windows files)'
                if (-not $DryRun) {
                    Add-Record @{ Id = 'compactos'; Kind = 'compactos'; OldValue = 'never' }
                    Write-Log "Compressing Windows - this can take 10-30 minutes on eMMC. Don't close this window." 'WARN'
                    Invoke-Native compact.exe /compactos:always | Out-Null
                    $after = Get-Volume -DriveLetter $drive.Letter
                    Write-Log ("CompactOS done - free space now {0} GB (was {1} GB)" -f [math]::Round($after.SizeRemaining / 1GB, 1), $drive.FreeGB) 'OK'
                }
            }
        }
    }
    }

    # ---- Report-only checks (security or user choices - tech decides) ---------
    Write-Log "Things to look at (not changed)" 'HEAD'
    $minFree = if ($isEmmc) { 20 } else { 15 }
    if ($drive.FreePct -lt $minFree) { Write-Log "Only $($drive.FreePct)% free - slow drives get much slower when nearly full. Clean up/move data." 'WARN' }
    else { Write-Log "Free space OK ($($drive.FreePct)%)" }
    if ($ramGB -lt 6) { Write-Log "Only $ramGB GB RAM - this machine will page to the slow disk a lot. Upgrade RAM if it isn't soldered." 'WARN' }
    try {
        $bl = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop |
              Where-Object { $_.DriveLetter -eq "$($drive.Letter):" }
        if ($bl -and $bl.ProtectionStatus -eq 1) { Write-Log "BitLocker/Device Encryption is ON for $($drive.Letter): - winutil 'BitLocker - Disable' if appropriate." 'WARN' }
        else { Write-Log "BitLocker off" }
    } catch { }
    try {
        $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
        if (@($dg.SecurityServicesRunning) -contains 2) { Write-Log "Memory Integrity (HVCI) is ON - costs speed on older/low-end CPUs. Security tradeoff: decide per client." 'WARN' }
        else { Write-Log "Memory Integrity off" }
    } catch { }
    if ($isHdd) { Write-Log "Best fix for this PC is still a SATA SSD swap (~`$25-40) - bigger than every tweak combined." 'WARN' }
    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique)
    if ($startup.Count) { Write-Log ("Startup apps ({0}): {1}" -f $startup.Count, ($startup -join ', ')) }

    # ---- Done ------------------------------------------------------------------
    Write-Host ""
    if ($DryRun) {
        Write-Log "Report finished - $script:Changed change(s) would be made. Run without NN_SLOWDISK=report to apply." 'OK'
    } else {
        Write-Log "Done - $($diskProfile.ToUpper()) profile applied ($script:Changed change(s), $script:Skipped skipped). REBOOT to finish." 'OK'
        Write-Log "Undo anytime:  `$env:NN_SLOWDISK='revert'; irm slowdisk.nerdyneighbor.net | iex"
    }
    Write-Host ""
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)" 'ERROR'
    Write-Host "  Log: $LogFile" -ForegroundColor Yellow
    Write-Host ""
}

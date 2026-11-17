<#
.SYNOPSIS
    RotorHazard developer helper for Windows: drives the Docker dev container in WSL2 and attaches USB timer nodes.
.DESCRIPTION
    rh-dev <command>            pass-through to docker/scripts/rh-dev.sh inside WSL2
                                (up [--mock N], down, restart, logs [-f], shell, test, lint, rebuild, reset-data, status)
    rh-dev setup                check/install WSL2 distro, systemd, Docker Engine and usbipd-win (asks for each step)
    rh-dev usb list             list USB devices, timer nodes highlighted
    rh-dev usb attach [busid]   bind (once) and attach a device to WSL2 with auto-attach
    rh-dev usb detach [busid]   stop auto-attach and detach
    rh-dev open                 open http://localhost:5000
    -DryRun                     print the wsl/usbipd command lines instead of running them
    Repo outside WSL (e.g. C:\...)? Set RH_WSL_DISTRO and RH_WSL_REPO (env vars or docker\scripts\rh-dev.local.ps1).
    Compatible with Windows PowerShell 5.1.
#>
param(
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CliArgs
)

$script:RhDefaultDistro = 'Ubuntu-26.04'
$script:RhTimerVids = @('1a86', '10c4', '0403', '0483', '2341')
$script:RhUrl = 'http://localhost:5000'
$script:RhDocs = 'doc/Docker Development.md'

function Resolve-RhWslTarget {
    param([string]$Path)
    $p = $Path
    if ($p -match '^Microsoft\.PowerShell\.Core\\FileSystem::(.*)$') { $p = $Matches[1] }
    if ($p -match '^\\\\wsl(?:\.localhost|\$)\\([^\\]+)(.*)$') {
        $distro = $Matches[1]
        $linux = $Matches[2] -replace '\\', '/'
        if ([string]::IsNullOrEmpty($linux)) { $linux = '/' }
        return [pscustomobject]@{ Distro = $distro; LinuxPath = $linux }
    }
    if ($env:RH_WSL_DISTRO -and $env:RH_WSL_REPO) {
        return [pscustomobject]@{ Distro = $env:RH_WSL_DISTRO; LinuxPath = $env:RH_WSL_REPO }
    }
    return $null
}

function ConvertFrom-UsbipdList {
    param([string[]]$Lines)
    $inConnected = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*Connected:') { $inConnected = $true; continue }
        if ($line -match '^\s*[A-Za-z][A-Za-z ]*:\s*$') { $inConnected = $false; continue }
        if (-not $inConnected) { continue }
        if ($line -match '^\s*(\d+-\d+(?:\.\d+)*)\s+([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\s+(.*?)\s*$') {
            $busId = $Matches[1]
            $vid = $Matches[2].ToLower()
            $prodId = $Matches[3].ToLower()
            $rest = $Matches[4]
            $device = $rest
            $state = ''
            if ($rest -match '^(.*?)\s+(Not shared|Shared|Attached)$') {
                $device = $Matches[1]
                $state = $Matches[2]
            }
            [pscustomobject]@{
                BusId   = $busId
                VidPid  = "${vid}:${prodId}"
                Device  = $device
                State   = $state
                IsTimer = ($script:RhTimerVids -contains $vid)
            }
        }
    }
}

function Get-RhWslInvocation {
    param($Target, [string[]]$Arguments)
    $r = @('wsl.exe', '-d', $Target.Distro, '--cd', $Target.LinuxPath, '--', 'docker/scripts/rh-dev.sh')
    if ($Arguments) { $r += $Arguments }
    return [string[]]$r
}

# ---- helpers (not unit tested) ---------------------------------------------------------------------------

function Format-RhCommand {
    param([string[]]$Parts)
    ($Parts | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
}

function Import-RhLocalConfig {
    $f = Join-Path $PSScriptRoot 'rh-dev.local.ps1'
    if (Test-Path $f) { . $f }
}

# wsl.exe emits UTF-16 for list output; read it as such and strip stray NULs
function Invoke-Wsl {
    param([string[]]$WslArgs)
    $old = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        $out = & wsl.exe @WslArgs 2>&1
    } finally {
        [Console]::OutputEncoding = $old
    }
    return @($out | ForEach-Object { ([string]$_) -replace "`0", '' })
}

function Get-RhDistros {
    $out = Invoke-Wsl @('-l', '-q')
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($out | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Confirm-Rh {
    param([string]$Question)
    if ($DryRun) { Write-Host "  [dry-run] would ask: $Question [y/N]"; return $true }
    $a = Read-Host "  $Question [y/N]"
    return ($a -match '^(y|yes|j|ja)$')
}

function Write-RhStep { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }

function Get-RhUsbipd {
    $c = Get-Command usbipd -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:ProgramFiles 'usbipd-win\usbipd.exe'
    if (Test-Path $p) { return $p }
    return $null
}

function Get-RhPidFile { param([string]$BusId) Join-Path $env:TEMP ("rh-dev-usb-{0}.pid" -f $BusId) }

function Get-RhSetupDistro {
    $t = Resolve-RhWslTarget (Get-Location).ProviderPath
    if (-not $t) { $t = Resolve-RhWslTarget $PSScriptRoot }
    if ($t) { return $t.Distro }
    return $script:RhDefaultDistro
}

# ---- commands --------------------------------------------------------------------------------------------

function Invoke-RhPassthrough {
    param([string[]]$Arguments)
    $target = Resolve-RhWslTarget $PSScriptRoot
    if (-not $target) {
        Write-Host "WARNING: this checkout is on a Windows drive ($PSScriptRoot)." -ForegroundColor Yellow
        Write-Host "Docker bind mounts from a Windows drive are slow, and no WSL repo location is configured." -ForegroundColor Yellow
        Write-Host "Either open the repo from WSL (\\wsl.localhost\<distro>\...) or set RH_WSL_DISTRO and RH_WSL_REPO" -ForegroundColor Yellow
        Write-Host "(env vars or docker\scripts\rh-dev.local.ps1), e.g. RH_WSL_REPO=/mnt/c/... See $script:RhDocs." -ForegroundColor Yellow
        return 1
    }
    $inv = Get-RhWslInvocation $target $Arguments
    if ($DryRun) { Write-Host (Format-RhCommand $inv); return 0 }
    $wslArgs = @($inv | Select-Object -Skip 1)
    & $inv[0] @wslArgs | Out-Host
    return $LASTEXITCODE
}

function Invoke-RhSetup {
    $distro = Get-RhSetupDistro
    Write-Host "RotorHazard dev setup (every change is asked first; finished steps are skipped)."
    if ($DryRun) { Write-Host "[dry-run] checks are skipped; showing the commands each step would run." }

    # 1. WSL + distro
    Write-RhStep 'Checking WSL2 and the distro'
    $haveDistro = $false
    if (-not $DryRun) {
        $distros = @(Get-RhDistros)
        if ($distros -contains $distro) { $haveDistro = $true }
        elseif ($distros.Count -gt 0) { $haveDistro = $true; $distro = $distros[0] }
    }
    if ($haveDistro) { Write-Host "  already done: distro '$distro' present" }
    else {
        Write-Host "  command: wsl --install -d $script:RhDefaultDistro"
        if (Confirm-Rh "Install WSL distro $($script:RhDefaultDistro)?") {
            if (-not $DryRun) {
                & wsl.exe --install -d $script:RhDefaultDistro | Out-Host
                Write-Host '  Finish the distro first-run user setup, then run setup again.'
                return 0
            }
        }
    }

    # 2. systemd
    Write-RhStep "Checking systemd in $distro"
    $hasSystemd = $false
    if (-not $DryRun) {
        $null = Invoke-Wsl @('-d', $distro, '-u', 'root', '--', 'grep', '-qs', '^systemd=true', '/etc/wsl.conf')
        $hasSystemd = ($LASTEXITCODE -eq 0)
    }
    if ($hasSystemd) { Write-Host '  already done: systemd enabled' }
    else {
        $cmd = "printf '[boot]\nsystemd=true\n' >> /etc/wsl.conf"
        Write-Host "  command: wsl -d $distro -u root -- bash -c `"$cmd`" ; wsl --shutdown"
        if (Confirm-Rh 'Enable systemd (restarts WSL)?') {
            if (-not $DryRun) {
                & wsl.exe -d $distro -u root -- bash -c $cmd | Out-Host
                & wsl.exe --shutdown | Out-Host
            }
        }
    }

    # 3. Docker Engine
    Write-RhStep "Checking Docker Engine in $distro"
    $hasDocker = $false
    if (-not $DryRun) {
        $null = Invoke-Wsl @('-d', $distro, '--', 'docker', 'compose', 'version')
        $hasDocker = ($LASTEXITCODE -eq 0)
    }
    if ($hasDocker) { Write-Host '  already done: docker + compose available' }
    else {
        $user = 'USER'
        if (-not $DryRun) { $user = ((Invoke-Wsl @('-d', $distro, '--', 'id', '-un')) | Select-Object -First 1).Trim() }
        $aptCmd = 'apt-get update && apt-get install -y docker.io docker-compose-v2 docker-buildx'
        Write-Host "  command: wsl -d $distro -u root -- bash -c `"$aptCmd`""
        Write-Host "  command: wsl -d $distro -u root -- usermod -aG docker $user"
        if (Confirm-Rh 'Install Docker Engine and add your user to the docker group?') {
            if (-not $DryRun) {
                & wsl.exe -d $distro -u root -- bash -c $aptCmd | Out-Host
                & wsl.exe -d $distro -u root -- usermod -aG docker $user | Out-Host
                Write-Host '  Run "wsl --shutdown" once so the new group membership applies.'
            }
        }
    }

    # 4. usbipd-win
    Write-RhStep 'Checking usbipd-win'
    if ((-not $DryRun) -and (Get-RhUsbipd)) { Write-Host '  already done: usbipd-win installed' }
    else {
        Write-Host '  command: winget install --exact dorssel.usbipd-win'
        if (Confirm-Rh 'Install usbipd-win with winget (needed for USB timer nodes)?') {
            if (-not $DryRun) { & winget.exe install --exact dorssel.usbipd-win | Out-Host }
        }
    }
    Write-Host 'Setup finished.'
    return 0
}

function Invoke-RhUsb {
    param([string[]]$Arguments)
    $sub = ''
    if ($Arguments -and $Arguments.Count -gt 0) { $sub = $Arguments[0] }
    $busId = ''
    if ($Arguments -and $Arguments.Count -gt 1) { $busId = $Arguments[1] }
    $usbipd = Get-RhUsbipd
    if (-not $usbipd) {
        if ($DryRun) { $usbipd = 'usbipd' }
        else { Write-Host 'usbipd-win not found. Run "rh-dev setup" first.' -ForegroundColor Red; return 1 }
    }
    $distro = Get-RhSetupDistro

    switch ($sub) {
        'list' {
            if ($DryRun) { Write-Host 'usbipd list'; return 0 }
            $devs = @(ConvertFrom-UsbipdList @(& $usbipd list))
            foreach ($d in $devs) {
                $mark = ' '
                if ($d.IsTimer) { $mark = '*' }
                $text = "{0} {1,-6} {2}  {3,-12} {4}" -f $mark, $d.BusId, $d.VidPid, $d.State, $d.Device
                if ($d.IsTimer) { Write-Host $text -ForegroundColor Green } else { Write-Host $text }
            }
            Write-Host '(* = likely timer node: CH340 1a86, CP210x 10c4, FTDI 0403, STM32 0483, Arduino 2341)'
            return 0
        }
        'attach' {
            if (-not $busId) {
                if ($DryRun) { Write-Host 'usb attach needs a bus id in dry-run mode'; return 2 }
                $timers = @(ConvertFrom-UsbipdList @(& $usbipd list) | Where-Object { $_.IsTimer })
                if ($timers.Count -eq 0) { Write-Host 'No likely timer devices found. Use "usb list" and pass a bus id.'; return 1 }
                for ($i = 0; $i -lt $timers.Count; $i++) {
                    Write-Host ("  [{0}] {1} {2} {3}" -f ($i + 1), $timers[$i].BusId, $timers[$i].VidPid, $timers[$i].Device)
                }
                $n = Read-Host 'Attach which device number'
                $idx = 0
                if (-not [int]::TryParse($n, [ref]$idx) -or $idx -lt 1 -or $idx -gt $timers.Count) { Write-Host 'Cancelled.'; return 1 }
                $busId = $timers[$idx - 1].BusId
            }
            $bindArgs = "bind --busid $busId"
            $attachArgs = "attach --wsl $distro --busid $busId --auto-attach"
            if ($DryRun) {
                Write-Host "[only if State is 'Not shared'; elevated via UAC] usbipd $bindArgs"
                Write-Host "usbipd $attachArgs   (hidden background process, PID in $(Get-RhPidFile $busId))"
                return 0
            }
            $needBind = $true
            $cur = @(ConvertFrom-UsbipdList @(& $usbipd list) | Where-Object { $_.BusId -eq $busId })
            if ($cur.Count -gt 0 -and $cur[0].State -ne 'Not shared') { $needBind = $false }
            if ($needBind) {
                Write-Host 'Binding device (UAC prompt)...'
                Start-Process -FilePath $usbipd -ArgumentList $bindArgs -Verb RunAs -Wait
            }
            $proc = Start-Process -FilePath $usbipd -ArgumentList $attachArgs -WindowStyle Hidden -PassThru
            Set-Content -Path (Get-RhPidFile $busId) -Value $proc.Id
            Write-Host "Attached $busId to $distro with auto-attach (PID $($proc.Id))."
            return 0
        }
        'detach' {
            if (-not $busId) { Write-Host 'Usage: rh-dev usb detach <busid>'; return 2 }
            $pidFile = Get-RhPidFile $busId
            if ($DryRun) {
                Write-Host "Stop-Process -Id <PID stored in $pidFile>"
                Write-Host "usbipd detach --busid $busId"
                return 0
            }
            if (Test-Path $pidFile) {
                $procId = [int](Get-Content $pidFile | Select-Object -First 1)
                Stop-Process -Id $procId -ErrorAction SilentlyContinue
                Remove-Item $pidFile -ErrorAction SilentlyContinue
            }
            & $usbipd detach --busid $busId | Out-Host
            return $LASTEXITCODE
        }
        default {
            Write-Host 'Usage: rh-dev usb list | attach [busid] | detach <busid>'
            return 2
        }
    }
}

function Invoke-RhMain {
    param([string[]]$Arguments)
    Import-RhLocalConfig
    $cmd = ''
    $rest = @()
    if ($Arguments -and $Arguments.Count -gt 0) {
        $cmd = $Arguments[0]
        $rest = @($Arguments | Select-Object -Skip 1)
    }
    switch ($cmd) {
        'setup' { return (Invoke-RhSetup) }
        'usb'   { return (Invoke-RhUsb $rest) }
        'open'  {
            if ($DryRun) { Write-Host "Start-Process $script:RhUrl"; return 0 }
            Start-Process $script:RhUrl
            return 0
        }
        default { return (Invoke-RhPassthrough $Arguments) }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $code = Invoke-RhMain $CliArgs
    exit ([int]($code | Select-Object -Last 1))
}

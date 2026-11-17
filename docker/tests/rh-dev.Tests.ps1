# Pester 3 tests for docker/scripts/rh-dev.ps1 (dot-sourced, so only the functions are loaded)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\scripts\rh-dev.ps1')

Describe 'Resolve-RhWslTarget' {
    BeforeEach {
        $script:oldDistro = $env:RH_WSL_DISTRO
        $script:oldRepo = $env:RH_WSL_REPO
        $env:RH_WSL_DISTRO = $null
        $env:RH_WSL_REPO = $null
    }
    AfterEach {
        $env:RH_WSL_DISTRO = $script:oldDistro
        $env:RH_WSL_REPO = $script:oldRepo
    }

    It 'parses a wsl.localhost UNC path' {
        $t = Resolve-RhWslTarget '\\wsl.localhost\Ubuntu-26.04\home\scordo\RotorHazard'
        $t.Distro | Should Be 'Ubuntu-26.04'
        $t.LinuxPath | Should Be '/home/scordo/RotorHazard'
    }
    It 'parses a wsl$ UNC path with spaces' {
        $t = Resolve-RhWslTarget '\\wsl$\Ubuntu\home\a b\RH'
        $t.Distro | Should Be 'Ubuntu'
        $t.LinuxPath | Should Be '/home/a b/RH'
    }
    It 'strips the PowerShell provider prefix' {
        $t = Resolve-RhWslTarget 'Microsoft.PowerShell.Core\FileSystem::\\wsl.localhost\Ubuntu\x'
        $t.Distro | Should Be 'Ubuntu'
        $t.LinuxPath | Should Be '/x'
    }
    It 'returns null for a drive path without env vars' {
        Resolve-RhWslTarget 'C:\P\RotorHazard' | Should BeNullOrEmpty
    }
    It 'falls back to the env vars for a drive path' {
        $env:RH_WSL_DISTRO = 'Ubuntu-26.04'
        $env:RH_WSL_REPO = '/home/scordo/RH'
        $t = Resolve-RhWslTarget 'C:\P\RotorHazard'
        $t.Distro | Should Be 'Ubuntu-26.04'
        $t.LinuxPath | Should Be '/home/scordo/RH'
    }
}

Describe 'ConvertFrom-UsbipdList' {
    $fixture = @(
        'Connected:',
        'BUSID  VID:PID    DEVICE                                                        STATE',
        '1-4    1a86:7523  USB-SERIAL CH340 (COM5)                                       Not shared',
        "2-1    046d:c52b  Logitech USB Input Device, USB-Eingabeger$([char]0xE4)t                   Not shared",
        '3-2    0483:5740  USB Serial Device (COM7)                                      Attached',
        '',
        'Persisted:',
        'GUID                                  DEVICE',
        '11111111-2222-3333-4444-555555555555  Some old device'
    )
    $devs = @(ConvertFrom-UsbipdList $fixture)

    It 'parses only the Connected section' {
        $devs.Count | Should Be 3
        $devs[0].BusId | Should Be '1-4'
        $devs[0].VidPid | Should Be '1a86:7523'
        $devs[0].Device | Should Be 'USB-SERIAL CH340 (COM5)'
    }
    It 'flags timer VIDs' {
        $devs[0].IsTimer | Should Be $true
        $devs[1].IsTimer | Should Be $false
        $devs[2].IsTimer | Should Be $true
    }
    It 'extracts the state' {
        $devs[0].State | Should Be 'Not shared'
        $devs[1].State | Should Be 'Not shared'
        $devs[2].State | Should Be 'Attached'
    }
}

Describe 'Get-RhWslInvocation' {
    It 'builds the wsl.exe argument list' {
        $t = [pscustomobject]@{ Distro = 'Ubuntu-26.04'; LinuxPath = '/home/scordo/RotorHazard' }
        $r = @(Get-RhWslInvocation $t @('up', '--mock', '2'))
        ($r -join '|') | Should Be 'wsl.exe|-d|Ubuntu-26.04|--cd|/home/scordo/RotorHazard|--|docker/scripts/rh-dev.sh|up|--mock|2'
    }
}

Describe 'Select-RhDistros' {
    It 'drops docker-desktop distros and blanks' {
        $r = @(Select-RhDistros @('docker-desktop', 'Ubuntu-26.04', '', 'docker-desktop-data', ' Debian '))
        ($r -join '|') | Should Be 'Ubuntu-26.04|Debian'
    }
}

Describe 'Test-RhDriveBackedPath' {
    It 'detects /mnt/<drive> paths' {
        Test-RhDriveBackedPath '/mnt/c/P/Remote/github/RotorHazard' | Should Be $true
        Test-RhDriveBackedPath '/mnt/d' | Should Be $true
    }
    It 'accepts WSL-native paths' {
        Test-RhDriveBackedPath '/home/scordo/RotorHazard' | Should Be $false
        Test-RhDriveBackedPath '/mnt/wsl/x' | Should Be $false
    }
}

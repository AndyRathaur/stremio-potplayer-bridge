<#
.SYNOPSIS
    Comprehensive PotPlayer bridge and interceptor for Stremio external playback.

.DESCRIPTION
    Stremio v5 launches external player 'VLC' through multiple possible mechanisms:
    1. Desktop Shell (stremio-shell-ng / WebView2): Intercepts vlc:// or playlist URLs,
       resolves VLC via HKEY_CLASSES_ROOT\Applications\vlc.exe\shell\open\command,
       App Paths\vlc.exe, and Program Files (x86)\VideoLAN\VLC\vlc.exe, then spawns:
       cmd.exe /C start "" "<vlc_path>" "C:\Users\<user>\AppData\Local\Temp\playlist.m3u"
    2. Streaming Server (server.js): Defines external players and spawns VLC directly
       via child_process.execFile("C:\Program Files (x86)\VideoLAN\VLC\vlc.exe", args)
    3. OS URL Scheme: ShellExecute("vlc://<stream-url>")

    This script sets up complete redirection across all mechanisms so selecting "VLC"
    in Stremio Settings -> Player -> "Play in external player" cleanly launches PotPlayer,
    translating POSIX flags, seeking parameters, and subtitles seamlessly.

.PARAMETER Action
    Register (default), Unregister, or Status.

.EXAMPLE
    .\setup-potplayer-stremio-bridge.ps1 -Action Register
    .\setup-potplayer-stremio-bridge.ps1 -Action Status
    .\setup-potplayer-stremio-bridge.ps1 -Action Unregister
#>

[CmdletBinding()]
param(
    [ValidateSet("Register", "Unregister", "Status")]
    [string]$Action = "Register"
)

# Enforce Administrator privileges for modifying system-wide registry and Program Files
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and $Action -ne "Status") {
    Write-Warning "Administrator rights are required to configure registry keys and system directories."
    Write-Warning "Relaunching PowerShell as Administrator..."
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action $Action"
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit
}

$baseDir = $PSScriptRoot
$csSource = Join-Path $baseDir "potplayer-stremio-bridge.cs"
$bridgeExe = Join-Path $baseDir "potplayer-stremio-bridge.exe"

$vlcDir86 = "C:\Program Files (x86)\VideoLAN\VLC"
$vlcDir64 = "C:\Program Files\VideoLAN\VLC"
$vlcExe86 = "$vlcDir86\vlc.exe"
$vlcBackup86 = "$vlcDir86\vlc-original.exe"
$vlcExe64 = "$vlcDir64\vlc.exe"
$vlcBackup64 = "$vlcDir64\vlc-original.exe"

function Compile-Bridge {
    if (-not (Test-Path $csSource)) {
        Write-Error "C# source not found: $csSource"
        return $false
    }
    
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) {
        $csc = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    }

    if (-not (Test-Path $csc)) {
        Write-Error ".NET Framework C# compiler (csc.exe) not found at standard Windows paths."
        return $false
    }

    Write-Host "Compiling bridge executable..." -ForegroundColor Cyan
    Write-Host "  Compiler: $csc" -ForegroundColor Gray
    Write-Host "  Source:   $csSource" -ForegroundColor Gray
    Write-Host "  Output:   $bridgeExe" -ForegroundColor Gray

    & $csc /target:winexe /out:"$bridgeExe" /optimize+ "$csSource" | Out-Null
    
    if (Test-Path $bridgeExe) {
        Write-Host "  [OK] Successfully compiled $bridgeExe" -ForegroundColor Green
        return $true
    } else {
        Write-Error "Compilation failed."
        return $false
    }
}

function Find-PotPlayer-Path {
    $candidates = @(
        "C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe",
        "C:\Program Files\DAUM\PotPlayer\PotPlayer64.exe",
        "C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini.exe",
        "C:\Program Files (x86)\DAUM\PotPlayer\PotPlayer.exe",
        "C:\Program Files\DAUM\PotPlayer\PotPlayerMini.exe",
        "$env:LOCALAPPDATA\DAUM\PotPlayer\PotPlayerMini64.exe",
        "$env:LOCALAPPDATA\DAUM\PotPlayer\PotPlayerMini.exe"
    )
    foreach ($cand in $candidates) {
        if (Test-Path $cand) { return $cand }
    }
    
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PotPlayerMini64.exe",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PotPlayer64.exe",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PotPlayerMini64.exe",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\PotPlayer64.exe"
    )
    foreach ($rp in $regPaths) {
        $val = (Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue).'(default)'
        if ($val -and (Test-Path ($val.Trim('"')))) {
            return ($val.Trim('"'))
        }
    }
    return $null
}

switch ($Action) {
    "Status" {
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "     Stremio -> PotPlayer Bridge Diagnostic Status        " -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan

        # 1. PotPlayer Detection
        $potPath = Find-PotPlayer-Path
        Write-Host "`n1. Target Media Player (PotPlayer):"
        if ($potPath) {
            Write-Host "  [OK] Detected at: $potPath" -ForegroundColor Green
        } else {
            Write-Host "  [WARNING] PotPlayer executable not found in standard paths!" -ForegroundColor Yellow
        }

        # 2. Bridge Executable
        Write-Host "`n2. Bridge Binary:"
        if (Test-Path $bridgeExe) {
            $info = Get-Item $bridgeExe
            Write-Host "  [OK] Found at: $bridgeExe ($($info.Length) bytes, built $($info.LastWriteTime))" -ForegroundColor Green
        } else {
            Write-Host "  [NOT COMPILED] $bridgeExe does not exist yet. Run with -Action Register." -ForegroundColor Red
        }

        # 3. Protocol Handler (vlc://)
        Write-Host "`n3. Protocol Scheme (vlc://):"
        $hkcuProto = (Get-ItemProperty "HKCU:\Software\Classes\vlc\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
        $hklmProto = (Get-ItemProperty "HKLM:\SOFTWARE\Classes\vlc\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
        Write-Host "  HKCU: $(if ($hkcuProto) { $hkcuProto } else { '[None]' })"
        Write-Host "  HKLM: $(if ($hklmProto) { $hklmProto } else { '[None]' })"

        # 4. Applications Registry
        Write-Host "`n4. Applications Registry (Applications\vlc.exe):"
        $hkcuApp = (Get-ItemProperty "HKCU:\SOFTWARE\Classes\Applications\vlc.exe\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
        $hklmApp = (Get-ItemProperty "HKLM:\SOFTWARE\Classes\Applications\vlc.exe\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
        Write-Host "  HKCU: $(if ($hkcuApp) { $hkcuApp } else { '[None]' })"
        Write-Host "  HKLM: $(if ($hklmApp) { $hklmApp } else { '[None]' })"

        # 5. App Paths Registry
        Write-Host "`n5. App Paths (Windows Execution Path):"
        $hkcuPath = (Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\vlc.exe" -ErrorAction SilentlyContinue).'(default)'
        $hklmPath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\vlc.exe" -ErrorAction SilentlyContinue).'(default)'
        Write-Host "  HKCU: $(if ($hkcuPath) { $hkcuPath } else { '[None]' })"
        Write-Host "  HKLM: $(if ($hklmPath) { $hklmPath } else { '[None]' })"

        # 6. VideoLAN Directory File Shims
        Write-Host "`n6. Filesystem Shims (VideoLAN Installation Dirs):"
        foreach ($item in @(@{ Dir = $vlcDir86; Exe = $vlcExe86; Backup = $vlcBackup86; Label = "32-bit (x86)" },
                            @{ Dir = $vlcDir64; Exe = $vlcExe64; Backup = $vlcBackup64; Label = "64-bit" })) {
            Write-Host "  [$($item.Label)] $($item.Dir):"
            if (Test-Path $item.Exe) {
                $len = (Get-Item $item.Exe).Length
                if (Test-Path $item.Backup) {
                    $bLen = (Get-Item $item.Backup).Length
                    Write-Host "    -> [SHIMMED] Active shim: $len bytes | Original backup: $bLen bytes" -ForegroundColor Green
                } else {
                    Write-Host "    -> [UNSHIMMED] Original executable present: $len bytes" -ForegroundColor Yellow
                }
            } else {
                Write-Host "    -> [NOT PRESENT] Directory or vlc.exe does not exist" -ForegroundColor Gray
            }
        }
        Write-Host ""
    }

    "Register" {
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "     Registering Stremio -> PotPlayer Interception        " -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan

        # 1. Compile bridge binary
        if (-not (Compile-Bridge)) {
            Write-Error "Failed to compile bridge executable. Aborting."
            return
        }

        # 2. Registry: Protocol Scheme (vlc://)
        Write-Host "`nConfiguring Protocol Handlers (vlc://)..." -ForegroundColor Cyan
        $protoKeys = @("HKCU:\Software\Classes\vlc", "HKLM:\SOFTWARE\Classes\vlc")
        foreach ($key in $protoKeys) {
            try {
                if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                Set-ItemProperty -Path $key -Name "(default)" -Value "URL:VLC Protocol (Bridged to PotPlayer)"
                Set-ItemProperty -Path $key -Name "URL Protocol" -Value ""
                $cmdKey = "$key\shell\open\command"
                if (-not (Test-Path $cmdKey)) { New-Item -Path $cmdKey -Force | Out-Null }
                Set-ItemProperty -Path $cmdKey -Name "(default)" -Value "`"$bridgeExe`" `"%1`""
                Write-Host "  [OK] Configured $key" -ForegroundColor Green
            } catch {
                Write-Warning "Failed setting $($key): $_"
            }
        }

        # 3. Registry: Applications\vlc.exe
        Write-Host "`nConfiguring Applications Registry..." -ForegroundColor Cyan
        $appKeys = @(
            "HKLM:\SOFTWARE\Classes\Applications\vlc.exe\shell\open\command",
            "HKCU:\SOFTWARE\Classes\Applications\vlc.exe\shell\open\command"
        )
        foreach ($key in $appKeys) {
            try {
                if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                Set-ItemProperty -Path $key -Name "(default)" -Value "`"$bridgeExe`" `"%1`""
                Write-Host "  [OK] Configured $key" -ForegroundColor Green
            } catch {
                Write-Warning "Failed setting $($key): $_"
            }
        }

        # 4. Registry: App Paths\vlc.exe
        Write-Host "`nConfiguring Windows App Paths..." -ForegroundColor Cyan
        $appPathKeys = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\vlc.exe",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\vlc.exe"
        )
        foreach ($key in $appPathKeys) {
            try {
                if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                Set-ItemProperty -Path $key -Name "(default)" -Value $bridgeExe
                Set-ItemProperty -Path $key -Name "Path" -Value $baseDir
                Write-Host "  [OK] Configured $key" -ForegroundColor Green
            } catch {
                Write-Warning "Failed setting $($key): $_"
            }
        }

        # 5. File Shim in VideoLAN directories
        Write-Host "`nConfiguring Filesystem Shims..." -ForegroundColor Cyan
        $targets = @(
            @{ Dir = $vlcDir86; Exe = $vlcExe86; Backup = $vlcBackup86; Label = "32-bit (x86)" },
            @{ Dir = $vlcDir64; Exe = $vlcExe64; Backup = $vlcBackup64; Label = "64-bit" }
        )

        # Stremio server.js hardcodes the x86 VideoLAN path. Ensure x86 exists even if VLC was never installed!
        if (-not (Test-Path $vlcDir86)) {
            Write-Host "  Creating $vlcDir86 directory for Stremio server.js compatibility..." -ForegroundColor Yellow
            New-Item -ItemType Directory -Path $vlcDir86 -Force | Out-Null
        }

        foreach ($target in $targets) {
            if (Test-Path $target.Dir) {
                if (Test-Path $target.Exe) {
                    $currentLen = (Get-Item $target.Exe).Length
                    $bridgeLen = (Get-Item $bridgeExe).Length
                    if ($currentLen -ne $bridgeLen) {
                        if (-not (Test-Path $target.Backup)) {
                            Copy-Item $target.Exe $target.Backup -Force
                            Write-Host "  Backed up original VLC to $($target.Backup)" -ForegroundColor Green
                        }
                        Copy-Item $bridgeExe $target.Exe -Force
                        Write-Host "  Installed bridge shim at $($target.Exe)" -ForegroundColor Green
                    } else {
                        Write-Host "  Shim already up to date at $($target.Exe)" -ForegroundColor Gray
                    }
                } else {
                    Copy-Item $bridgeExe $target.Exe -Force
                    Write-Host "  Installed bridge shim at $($target.Exe) (clean install)" -ForegroundColor Green
                }
            }
        }

        Write-Host "`n[SUCCESS] Stremio -> PotPlayer Bridge successfully registered across all layers!" -ForegroundColor Green
        Write-Host "Open Stremio -> Settings -> Player -> select 'Play in external player: VLC'." -ForegroundColor Cyan
    }

    "Unregister" {
        Write-Host "==========================================================" -ForegroundColor Yellow
        Write-Host "     Unregistering Stremio -> PotPlayer Bridge            " -ForegroundColor Yellow
        Write-Host "==========================================================" -ForegroundColor Yellow

        # 1. Clean Registry
        Write-Host "Restoring Registry..." -ForegroundColor Cyan
        $removeKeys = @(
            "HKCU:\Software\Classes\vlc",
            "HKCU:\SOFTWARE\Classes\Applications\vlc.exe",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\vlc.exe"
        )
        foreach ($rk in $removeKeys) {
            if (Test-Path $rk) {
                Remove-Item -Path $rk -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "  Removed $rk" -ForegroundColor Yellow
            }
        }

        # 2. Restore VLC Backups
        Write-Host "`nRestoring Original Binaries..." -ForegroundColor Cyan
        $targets = @(
            @{ Exe = $vlcExe86; Backup = $vlcBackup86 },
            @{ Exe = $vlcExe64; Backup = $vlcBackup64 }
        )

        foreach ($target in $targets) {
            if (Test-Path $target.Backup) {
                Copy-Item $target.Backup $target.Exe -Force
                Remove-Item $target.Backup -Force
                Write-Host "  Restored $($target.Exe) from backup" -ForegroundColor Green
                
                # Restore HKLM to original VLC executable
                Set-ItemProperty -Path "HKLM:\SOFTWARE\Classes\Applications\vlc.exe\shell\open\command" -Name "(default)" -Value "`"$($target.Exe)`" --started-from-file `"%1`"" -ErrorAction SilentlyContinue
                Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\vlc.exe" -Name "(default)" -Value $target.Exe -ErrorAction SilentlyContinue
            } elseif (Test-Path $target.Exe) {
                # Check if it was purely our bridge shim with no prior VLC installation
                $len = (Get-Item $target.Exe).Length
                if (Test-Path $bridgeExe -and $len -eq (Get-Item $bridgeExe).Length) {
                    Remove-Item $target.Exe -Force -ErrorAction SilentlyContinue
                    Write-Host "  Removed bridge shim from $($target.Exe)" -ForegroundColor Yellow
                }
            }
        }

        Write-Host "`n[DONE] Stremio -> PotPlayer bridge successfully unregistered." -ForegroundColor Green
    }
}

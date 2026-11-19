@echo off
setlocal enabledelayedexpansion

echo ==========================================================
echo        Building PotPlayer Stremio Bridge
echo ==========================================================

set "CSC=%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" (
    set "CSC=%SystemRoot%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)

if not exist "%CSC%" (
    echo [ERROR] Microsoft .NET Framework 4.x C# compiler csc.exe was not found.
    exit /b 1
)

echo Using compiler: %CSC%
echo Compiling potplayer-stremio-bridge.cs...

"%CSC%" /target:winexe /out:"%~dp0potplayer-stremio-bridge.exe" /optimize+ "%~dp0potplayer-stremio-bridge.cs"

if errorlevel 1 (
    echo [ERROR] Compilation failed!
    exit /b 1
)

echo [OK] potplayer-stremio-bridge.exe built successfully.

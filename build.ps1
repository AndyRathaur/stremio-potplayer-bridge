[CmdletBinding()]
param()

$baseDir = $PSScriptRoot
$source = Join-Path $baseDir "potplayer-stremio-bridge.cs"
$out = Join-Path $baseDir "potplayer-stremio-bridge.exe"

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) {
    $csc = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
}

if (-not (Test-Path $csc)) {
    Write-Error "Microsoft .NET Framework 4.x C# compiler (csc.exe) was not found."
    exit 1
}

Write-Host "Compiling $source -> $out..." -ForegroundColor Cyan
& $csc /target:winexe /out:"$out" /optimize+ "$source"

if ($LASTEXITCODE -eq 0 -and (Test-Path $out)) {
    $info = Get-Item $out
    Write-Host "[OK] Build successful! ($($info.Length) bytes)" -ForegroundColor Green
} else {
    Write-Error "Build failed with exit code $LASTEXITCODE"
    exit 1
}

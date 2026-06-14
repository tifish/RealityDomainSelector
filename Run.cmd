@echo off
setlocal
cd /d "%~dp0"

set "SCANNER=RealiTLScanner-windows-64.exe"
set "TRANCO=top-1m.csv"

if not exist "%SCANNER%" (
    echo [Run] %SCANNER% not found. Downloading...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-RealiTLScanner.ps1"
    if errorlevel 1 goto :fail
    for %%F in ("%~dp0RealiTLScanner-windows-64*.exe") do set "SCANNER=%%~nxF"
)

if not exist "Country.mmdb" (
    echo [Run] Country.mmdb not found. Downloading...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-CountryMmdb.ps1"
    if errorlevel 1 goto :fail
)

if not exist "%TRANCO%" (
    echo [Run] %TRANCO% not found. Downloading...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-TrancoTop1M.ps1"
    if errorlevel 1 goto :fail
)

echo [Run] Starting Select-RealityDomains...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Select-RealityDomains.ps1" -ScannerPath "%~dp0%SCANNER%" %*
if errorlevel 1 goto :fail

endlocal
exit /b 0

:fail
echo [Run] Failed with errorlevel %errorlevel%.
endlocal
exit /b 1

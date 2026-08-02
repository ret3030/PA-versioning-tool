@echo off
REM Dvojklik = interaktivni menu. Argumenty = davkovy rezim, napr.:
REM   ppv.cmd sync -Environment dev
REM   ppv.cmd env list
setlocal
set PPV_ARGS=%*

where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\ppv.ps1" %PPV_ARGS%
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\ppv.ps1" %PPV_ARGS%
)

set EXITCODE=%errorlevel%
if "%PPV_ARGS%"=="" (
    REM interaktivni rezim uz cekal na klavesu sam
) else (
    if not %EXITCODE%==0 pause
)
exit /b %EXITCODE%

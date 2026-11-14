@echo off
setlocal
chcp 936 >nul 2>&1
set "S=%~dp0scripts"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"

net session >nul 2>&1
if errorlevel 1 (
  echo [!] Not running as administrator - task creation and Program Files writes may fail.
  echo     Right-click this file and choose "Run as administrator" if a step fails.
  echo.
)

:menu
cls
echo ============================================================
echo   dsh-purge handoff failure - fix kit
echo ============================================================
echo   1. Diagnose (read only, safe)
echo   2. Patch plugin WMI quoting bug  (needs DSH restart to load)
echo   3. Schedule swap helper          (run BEFORE quitting DSH)
echo   4. Status                         (handoff phase / logs)
echo   5. Rollback                       (DSH must be fully quit)
echo   6. Open the folder
echo   0. Exit
echo ============================================================
set "C="
set /p "C=Choose: "
if "%C%"=="1" %PS% "%S%\1-diagnose.ps1" & echo. & pause & goto menu
if "%C%"=="2" %PS% "%S%\2-patch-plugin.ps1" & echo. & pause & goto menu
if "%C%"=="3" %PS% "%S%\3-schedule-swap.ps1" & echo. & pause & goto menu
if "%C%"=="4" %PS% "%S%\5-status.ps1" & echo. & pause & goto menu
if "%C%"=="5" %PS% "%S%\4-rollback.ps1" & echo. & pause & goto menu
if "%C%"=="6" explorer "%~dp0" & goto menu
if "%C%"=="0" exit /b 0
goto menu

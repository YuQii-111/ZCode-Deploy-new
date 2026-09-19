@echo off
chcp 65001 >nul
echo ============================================
echo   ZCode - verify
echo ============================================
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" diag
echo.
echo --- functional verify ---
echo.
where node >nul 2>&1
if %errorlevel%==0 (
  node "%~dp0verify-patch.cjs"
) else (
  if exist "D:\app\nodejs\node.exe" (
    "D:\app\nodejs\node.exe" "%~dp0verify-patch.cjs"
  ) else (
    echo node not found - functional verify skipped
  )
)
echo.
echo Closing in 15 seconds...
ping -n 16 127.0.0.1 >nul 2>&1
exit

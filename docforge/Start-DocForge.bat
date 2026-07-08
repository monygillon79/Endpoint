@echo off
title DocForge Server
color 0B

echo.
echo  ============================================
echo    DocForge - Starting server...
echo  ============================================
echo.

cd /d "%~dp0docforge-backend"

:: Check Node is installed
where node >nul 2>&1
if %errorlevel% neq 0 goto :no_node

:: Show Node version
for /f "tokens=*" %%v in ('node --version') do set NODE_VER=%%v
echo  [OK] Node.js %NODE_VER% found

:: Check dependencies are installed
if exist "node_modules" goto :deps_ready

echo  [INFO] Installing dependencies (first run only -- takes ~30 seconds)...
npm install
if %errorlevel% neq 0 goto :npm_fail

:deps_ready
echo  [OK] Dependencies ready
echo.
echo  ============================================
echo    DocForge is running at:
echo.
echo    http://localhost:3001
echo.
echo    1. Open the URL above in your browser
echo    2. Click Settings (gear icon)
echo    3. Enter your Anthropic API key
echo    4. Drop in your collection JSON
echo.
echo    Press Ctrl+C to stop the server
echo  ============================================
echo.

:: Open browser after 2 second delay (background)
start "" cmd /c "timeout /t 2 /nobreak >nul && start chrome http://localhost:3001 2>nul || start msedge http://localhost:3001 2>nul || start http://localhost:3001"

:: Start the server
node server.js
goto :eof

:no_node
echo  [ERROR] Node.js not found.
echo.
echo  Please install Node.js from https://nodejs.org
echo  Download the Windows Installer (.msi) and run it.
echo  Then close this window and double-click Start-DocForge.bat again.
echo.
start "" "https://nodejs.org/en/download"
pause
exit /b 1

:npm_fail
echo  [ERROR] npm install failed. Check your internet connection.
pause
exit /b 1

@echo off
rem Cyberpunk 2077 Co-op Campaign - installer. Runs Install-CyberpunkCoop.ps1 next to it.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-CyberpunkCoop.ps1"

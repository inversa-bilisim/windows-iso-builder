@echo off
echo ps2exe modulu kuruluyor ve EXE olusturuluyor...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "if (-not (Get-Module -ListAvailable ps2exe)) { Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber }; " ^
  "Import-Module ps2exe; " ^
  "Invoke-ps2exe -inputFile '%~dp0ProxmoxWinIso.ps1' -outputFile '%~dp0ProxmoxWinIso.exe' -noConsole -requireAdmin -title 'Proxmox Windows ISO Builder' -version '1.0.0.0' -iconFile '%~dp0ProxmoxWinIso.ico'"
if exist "%~dp0ProxmoxWinIso.exe" (echo OK: ProxmoxWinIso.exe hazir.) else (echo HATA: exe olusmadi.)
pause

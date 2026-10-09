@echo off
echo ps2exe modulu kuruluyor ve EXE olusturuluyor...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "if (-not (Get-Module -ListAvailable ps2exe)) { Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber }; " ^
  "Import-Module ps2exe; " ^
  "Invoke-ps2exe -inputFile '%~dp0WindowsIsoBuilder.ps1' -outputFile '%~dp0WindowsIsoBuilder.exe' -noConsole -requireAdmin -title 'Windows ISO Builder' -version '1.2.0.0' -iconFile '%~dp0WindowsIsoBuilder.ico'"
if exist "%~dp0WindowsIsoBuilder.exe" (echo OK: WindowsIsoBuilder.exe hazir.) else (echo HATA: exe olusmadi.)
pause

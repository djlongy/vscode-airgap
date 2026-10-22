@echo off
rem Runs vscode-airgap.ps1 from this folder with the same arguments.
rem Example: vscode-airgap.bat -Mode bundle -Version 1.143.0 -Extensions extensions.txt
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0vscode-airgap.ps1" %*
exit /b %ERRORLEVEL%

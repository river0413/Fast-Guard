@echo off
cd /d "%~dp0"
echo Starting FastGuard cloud auth backend on port 1444 ...
python app.py
pause

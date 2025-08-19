@echo off
echo [GARVIS] Starte komplette Stack...
start "GPU0"      cmd /c services\gpu0.bat
timeout /t 3 >nul
start "GPU1"      cmd /c services\gpu1.bat
timeout /t 3 >nul
start "CPU"       cmd /c services\cpu.bat
timeout /t 3 >nul
start "Router"    cmd /c services\router.bat
timeout /t 2 >nul
start "Evaluator" cmd /c services\evaluator.bat
echo [GARVIS] Alle Dienste gestartet.

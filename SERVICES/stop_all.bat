@echo off
echo [GARVIS] Beende alle Dienste...
taskkill /FI "WINDOWTITLE eq GARVIS GPU0*" /T /F
taskkill /FI "WINDOWTITLE eq GARVIS GPU1*" /T /F
taskkill /FI "WINDOWTITLE eq GARVIS CPU*" /T /F
taskkill /FI "WINDOWTITLE eq GARVIS Router*" /T /F
taskkill /FI "WINDOWTITLE eq GARVIS Evaluator*" /T /F

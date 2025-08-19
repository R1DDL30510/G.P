@echo off
title GARVIS GPU1 (gar-reason)
cd /d D:\GARVIS
ollama serve --port 11435 --model gar-reason:latest

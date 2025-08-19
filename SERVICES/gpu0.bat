@echo off
title GARVIS GPU0 (gar-chat)
cd /d D:\GARVIS
ollama serve --port 11434 --model gar-chat:latest

@echo off
title GARVIS CPU (gar-router)
cd /d D:\GARVIS
ollama serve --port 11436 --model gar-router:latest

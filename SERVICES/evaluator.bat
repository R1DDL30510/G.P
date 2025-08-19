@echo off
title GARVIS Evaluator-Proxy
cd /d D:\GARVIS\evaluator
uvicorn evaluator_proxy:app --host 127.0.0.1 --port 11437

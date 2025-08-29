# bootstrap_all_in_one.ps1
# Purpose: One-shot, minimal, idempotent GARVIS V1 stack on Windows (no model pull).
# Creates repo layout, venv, pinned deps, writes minimal apps, installs & starts services,
# and performs a health smoke (no inference required).

Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true
$ErrorActionPreference = 'Stop'

# ---------- Helpers ----------
function Assert-Admin {
  $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
  $wp = New-Object Security.Principal.WindowsPrincipal($wi)
  if (-not $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script in an elevated (Administrator) PowerShell."
  }
}
function Assert-Exe([string]$name){
  $cmd = Get-Command $name -ErrorAction SilentlyContinue
  if (-not $cmd) { throw "Required executable not found in PATH: $name" }
  return $cmd.Source
}
function Test-PortFree([int]$Port){
  try {
    $c = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    return -not ($c -and $c.State -contains 'Listen')
  } catch { return $true } # if cmd unavailable, don't block
}
function Require-PortFree([int[]]$Ports){
  foreach($p in $Ports){
    if (-not (Test-PortFree $p)) { throw "Port $p is already in use. Stop the conflicting process and rerun." }
  }
}
function StopDelete-ServiceIfExists([string]$Name){
  $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
  if ($svc) {
    try { sc.exe stop $Name | Out-Null } catch {}
    Start-Sleep -Milliseconds 600
    try { sc.exe delete $Name | Out-Null } catch {}
    Start-Sleep -Milliseconds 300
  }
}
function New-Dir([string]$Path){
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
}
function Write-File([string]$Path, [string]$Content){
  $dir = Split-Path -Parent $Path
  if ($dir) { New-Dir $dir }
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}
function Python-VenvPath {
  param([string]$Root)
  $p = Join-Path $Root "venv\Scripts\python.exe"
  if (-not (Test-Path $p)) { throw "Python venv not found at $p" }
  return $p
}
function Install-Service-PowerShell([string]$Name, [string]$ScriptPath, [string]$User="NT AUTHORITY\NetworkService"){
  $psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  if (-not (Test-Path $psExe)) { throw "powershell.exe not found at $psExe" }
  $binPath = "`"$psExe`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

  StopDelete-ServiceIfExists $Name
  # Note: sc.exe syntax requires spaces after '='
  sc.exe create $Name binPath= "$binPath" start= auto obj= "$User" type= own | Out-Null
  sc.exe description $Name "GARVIS minimal service ($([IO.Path]::GetFileName($ScriptPath)))" | Out-Null
}
function Start-And-Wait([string]$ServiceName){
  sc.exe start $ServiceName | Out-Null
  # Wait until RUNNING or timeout ~15s
  $sw = [Diagnostics.Stopwatch]::StartNew()
  do {
    Start-Sleep -Milliseconds 400
    $s = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq 'Running') { return }
  } while ($sw.ElapsedMilliseconds -lt 15000)
  throw "Service $ServiceName did not reach RUNNING within 15s."
}

# ---------- Preconditions ----------
Assert-Admin
$pythonExe = Assert-Exe "python"
$repoRoot  = (Resolve-Path ".").Path
$ollamaExe = "C:\Program Files\Ollama\ollama.exe"
if (-not (Test-Path $ollamaExe)) { throw "Ollama not found at '$ollamaExe'. Install Ollama for Windows and rerun." }

Require-PortFree @(11434,11435,11436,18080,28100,28101)

# ---------- Layout ----------
$folders = @("runner\Heavy","runner\Base","runner\CPU","orchestrator","router","evaluator","scripts","logs","models")
$folders | ForEach-Object { New-Dir (Join-Path $repoRoot $_) }

# ---------- .env & requirements ----------
$envContent = @"
# Runner hosts
OLLAMA_TALK_HOST=http://127.0.0.1:11434
OLLAMA_HEAVY_HOST=http://127.0.0.1:11435
OLLAMA_BASE_HOST=http://127.0.0.1:11436

# Orchestrator
ORCH_BIND=127.0.0.1
ORCH_PORT=18080

# Internal services
ROUTER_BIND=127.0.0.1
ROUTER_PORT=28100
EVAL_BIND=127.0.0.1
EVAL_PORT=28101

# Auth (Set your own)
AUTH_TOKEN=CHANGE_ME
"@
Write-File (Join-Path $repoRoot ".env") $envContent

$reqContent = @"
fastapi==0.116.1
uvicorn[standard]==0.35.0
httpx==0.28.1
python-dotenv==1.0.1
"@
Write-File (Join-Path $repoRoot "requirements.txt") $reqContent

# ---------- Python venv & deps ----------
& $pythonExe -m venv "$repoRoot\venv"
$venvPy = Python-VenvPath -Root $repoRoot
& $venvPy -m pip install --upgrade pip | Out-Null
& $venvPy -m pip install -r (Join-Path $repoRoot "requirements.txt")

# ---------- Runner start scripts ----------
$runnerCommon = @"
param()
`$ErrorActionPreference='Stop'
`$repoRoot = Split-Path -Parent (Split-Path -Parent `$PSScriptRoot) # runner/<Role> -> repo
`$env:OLLAMA_MODELS = Join-Path `$repoRoot 'models'
`$ollama = 'C:\Program Files\Ollama\ollama.exe'
if (-not (Test-Path `$ollama)) { throw 'Ollama not found at C:\Program Files\Ollama\ollama.exe' }
"@

# Heavy (GPU0)
$heavy = $runnerCommon + @"
`$env:OLLAMA_HOST='127.0.0.1:11435'
`$env:CUDA_VISIBLE_DEVICES='0'
& `$ollama serve
"
Write-File (Join-Path $repoRoot "runner\Heavy\start.ps1") $heavy

# Base (GPU1)
$base = $runnerCommon + @"
`$env:OLLAMA_HOST='127.0.0.1:11436'
`$env:CUDA_VISIBLE_DEVICES='1'
& `$ollama serve
"
Write-File (Join-Path $repoRoot "runner\Base\start.ps1") $base

# CPU
$cpu = $runnerCommon + @"
`$env:OLLAMA_HOST='127.0.0.1:11434'
`$env:OLLAMA_NUM_GPU='0'
& `$ollama serve
"
Write-File (Join-Path $repoRoot "runner\CPU\start.ps1") $cpu

# ---------- Minimal apps (orchestrator/router/evaluator) ----------
# router/app.py
$routerApp = @"
import os
from fastapi import FastAPI
from pydantic import BaseModel
from dotenv import load_dotenv
load_dotenv()

app = FastAPI()
CODE_HINTS = os.getenv("CODE_HINTS","python,java,js,sql").split(",")

class RouteIn(BaseModel):
    prompt: str

@app.get("/health")
def health(): return {"status":"ok","service":"router"}

@app.post("/route")
def route(r: RouteIn):
    p = r.prompt.lower()
    if any(k in p for k in CODE_HINTS): return {"target":"base"}
    if len(p) > 600: return {"target":"heavy"}
    return {"target":"talk"}
"@
Write-File (Join-Path $repoRoot "router\app.py") $routerApp

# evaluator/app.py
$evalApp = @"
import os, httpx
from fastapi import FastAPI
from dotenv import load_dotenv
load_dotenv()

TALK = os.getenv("OLLAMA_TALK_HOST","http://127.0.0.1:11434")
HEAVY = os.getenv("OLLAMA_HEAVY_HOST","http://127.0.0.1:11435")
BASE  = os.getenv("OLLAMA_BASE_HOST","http://127.0.0.1:11436")

app = FastAPI()

@app.get('/health')
def health():
    urls = [TALK, HEAVY, BASE]
    ok = True
    details = {}
    for u in urls:
        try:
            r = httpx.get(f"{u}/api/version", timeout=2.0)
            details[u] = r.status_code
            ok &= (r.status_code == 200)
        except Exception as e:
            ok = False
            details[u] = f"err:{type(e).__name__}"
    return {"status":"ok" if ok else "degraded", "runners":details}
"@
Write-File (Join-Path $repoRoot "evaluator\app.py") $evalApp

# orchestrator/app.py
$orchApp = @"
import os, httpx
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
from dotenv import load_dotenv
load_dotenv()

ORCH_BIND = os.getenv('ORCH_BIND','127.0.0.1')
ORCH_PORT = int(os.getenv('ORCH_PORT','18080'))
ROUTER    = f"http://{os.getenv('ROUTER_BIND','127.0.0.1')}:{os.getenv('ROUTER_PORT','28100')}"
EVAL      = f"http://{os.getenv('EVAL_BIND','127.0.0.1')}:{os.getenv('EVAL_PORT','28101')}"
TOKEN     = os.getenv('AUTH_TOKEN','CHANGE_ME')

app = FastAPI()

def _auth(h: str|None):
    if not h or not h.startswith('Bearer '): raise HTTPException(401, 'Missing Bearer token')
    if h.split(' ',1)[1] != TOKEN: raise HTTPException(403, 'Invalid token')

class ChatIn(BaseModel):
    prompt: str
    thread_id: str | None = None

@app.get('/health')
def health():
    status = {"router": None, "evaluator": None}
    try:
        r = httpx.get(f"{ROUTER}/health", timeout=2.0); status["router"]=r.status_code
        e = httpx.get(f"{EVAL}/health", timeout=2.0);   status["evaluator"]=e.json()
        ok = r.status_code==200 and e.status_code==200 and e.json().get("status") in ("ok","degraded")
    except Exception as ex:
        ok = False
    return {"status":"ok" if ok else "degraded", "services":status}

@app.post('/chat')
def chat(data: ChatIn, authorization: str | None = Header(default=None, convert_underscores=False)):
    _auth(authorization)
    # Minimal stub reply to validate end-to-end without models
    # (You can later call ROUTER->EVAL once models are pulled)
    return {"reply":"GARVIS stack is up. Pull models to enable generation."}
"@
Write-File (Join-Path $repoRoot "orchestrator\app.py") $orchApp

# ---------- Start scripts for apps ----------
$orchStart = @"
`$ErrorActionPreference='Stop'
`$repoRoot = Split-Path -Parent `$PSScriptRoot
`$py = Join-Path `$repoRoot 'venv\Scripts\python.exe'
Set-Location `$PSScriptRoot
& `"$py`" -m uvicorn app:app --host `$env:ORCH_BIND --port `$env:ORCH_PORT
"
Write-File (Join-Path $repoRoot "orchestrator\start_orchestrator.ps1") $orchStart

$routerStart = @"
`$ErrorActionPreference='Stop'
`$repoRoot = Split-Path -Parent `$PSScriptRoot
`$py = Join-Path `$repoRoot 'venv\Scripts\python.exe'
Set-Location `$PSScriptRoot
& `"$py`" -m uvicorn app:app --host `$env:ROUTER_BIND --port `$env:ROUTER_PORT
"
Write-File (Join-Path $repoRoot "router\start_router.ps1") $routerStart

$evalStart = @"
`$ErrorActionPreference='Stop'
`$repoRoot = Split-Path -Parent `$PSScriptRoot
`$py = Join-Path `$repoRoot 'venv\Scripts\python.exe'
Set-Location `$PSScriptRoot
& `"$py`" -m uvicorn app:app --host `$env:EVAL_BIND --port `$env:EVAL_PORT
"
Write-File (Join-Path $repoRoot "evaluator\start_evaluator.ps1") $evalStart

# ---------- Install services (PowerShell-hosted) ----------
Install-Service-PowerShell -Name "GARVIS_Heavy"       -ScriptPath (Join-Path $repoRoot "runner\Heavy\start.ps1")
Install-Service-PowerShell -Name "GARVIS_Base"        -ScriptPath (Join-Path $repoRoot "runner\Base\start.ps1")
Install-Service-PowerShell -Name "GARVIS_Talk"        -ScriptPath (Join-Path $repoRoot "runner\CPU\start.ps1")
Install-Service-PowerShell -Name "GARVIS_Router"      -ScriptPath (Join-Path $repoRoot "router\start_router.ps1")
Install-Service-PowerShell -Name "GARVIS_Evaluator"   -ScriptPath (Join-Path $repoRoot "evaluator\start_evaluator.ps1")
Install-Service-PowerShell -Name "GARVIS_Orchestrator"-ScriptPath (Join-Path $repoRoot "orchestrator\start_orchestrator.ps1")

# ---------- Start services ----------
Start-And-Wait "GARVIS_Heavy"
Start-And-Wait "GARVIS_Base"
Start-And-Wait "GARVIS_Talk"
Start-And-Wait "GARVIS_Router"
Start-And-Wait "GARVIS_Evaluator"
Start-And-Wait "GARVIS_Orchestrator"

# ---------- Smoke (no models required) ----------
# Health endpoint should be 'ok' or 'degraded' but reachable.
Start-Sleep -Seconds 2
$health = Invoke-RestMethod -Uri "http://127.0.0.1:18080/health" -TimeoutSec 4
if (-not $health) { throw "Health returned no payload." }
if ($health.status -ne 'ok' -and $health.status -ne 'degraded') {
  throw "Unexpected health.status: $($health.status)"
}

# Auth check on /chat (uses stub)
$token = (Get-Content (Join-Path $repoRoot ".env")) | Where-Object { $_ -like 'AUTH_TOKEN=*' } | ForEach-Object { ($_ -split '=',2)[1] }
if (-not $token) { throw "AUTH_TOKEN missing in .env" }
$headers = @{ Authorization = "Bearer $token" }
$payload = @{ prompt="ping"; thread_id="smoke" } | ConvertTo-Json
$resp = Invoke-RestMethod -Uri "http://127.0.0.1:18080/chat" -Method Post -Headers $headers -ContentType "application/json" -Body $payload -TimeoutSec 4
if (-not $resp.reply) { throw "/chat did not return a reply" }

Write-Host ""
Write-Host "==============================================="
Write-Host " GARVIS V1 minimal stack is UP (no models yet) "
Write-Host " Services: GARVIS_Heavy, GARVIS_Base, GARVIS_Talk,"
Write-Host "           GARVIS_Router, GARVIS_Evaluator, GARVIS_Orchestrator"
Write-Host " Health:   http://127.0.0.1:18080/health"
Write-Host " Next:     Pull models, then wire /chat -> Router/Evaluator"
Write-Host "==============================================="

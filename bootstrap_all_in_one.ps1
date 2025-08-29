<# =====================================================================
 GARVIS V1 – Bootstrap (Windows)
 One-shot, idempotent setup for Ollama + router/evaluator services.

 Features
 - Installs Ollama (winget machine-scope; choco fallback if available)
 - Finds actual ollama.exe (Program Files or per-user AppData)
 - Creates services:
     GARVIS_Ollama_GPU0  -> 127.0.0.1:11435 (CUDA_VISIBLE_DEVICES=0)
     GARVIS_Ollama_GPU1  -> 127.0.0.1:11436 (CUDA_VISIBLE_DEVICES=1)
     GARVIS_Ollama_CPU   -> 127.0.0.1:11434 (CPU only, OLLAMA_NO_GPU=1)
     GARVIS_Router       -> 127.0.0.1:28100 (gar_router.py)
     GARVIS_Evaluator    -> 127.0.0.1:11437 (evaluator_proxy.py)
 - Hardens with: loopback bind, delayed auto-start, failure actions (restart)
 - Validates ports + HTTP smoke tests

 Re-run safe: updates services/binpaths; restarts cleanly.

 Author: GARVIS
 ===================================================================== #>

[CmdletBinding()]
param(
  [string]$BaseDir = "D:\GARVIS",
  [int]$PortTalk  = 11434,  # CPU (Talk)
  [int]$PortHeavy = 11435,  # GPU0 (Heavy)
  [int]$PortBase  = 11436,  # GPU1 (Base)
  [int]$PortRouter = 28100, # Router service
  [int]$PortEval   = 11437, # Evaluator proxy
  [int]$StartTimeout = 90000, # ms to wait for RUNNING
  [string]$EnvFile,
  [switch]$SkipInstallOllama,  # if set, don't attempt install
  [switch]$SkipInstallPython   # if set, skip venv/packages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# -------------------------- Utility / Logging --------------------------
function Write-Info  { param([string]$m) Write-Host "[INFO ] $m" -ForegroundColor Cyan }
function Write-OK    { param([string]$m) Write-Host "[ OK  ] $m" -ForegroundColor Green }
function Write-Warn  { param([string]$m) Write-Host "[WARN ] $m" -ForegroundColor Yellow }
function Write-Err   { param([string]$m) Write-Host "[FAIL ] $m" -ForegroundColor Red }

function Assert-Admin {
  $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
  $wp = [Security.Principal.WindowsPrincipal]::new($wi)
  if (-not $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script in an elevated PowerShell (Admin)."
  }
}
Assert-Admin

function New-Dir {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Test-PortFree {
  param([int]$Port)
  try {
    $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $tcp.Start(); $tcp.Stop(); return $true
  } catch { return $false }
}

function Require-PortFree {
  param([int[]]$Ports)
  foreach ($p in $Ports) {
    if (-not (Test-PortFree -Port $p)) {
      throw "Port $p is already in use. Stop the conflicting process or change the parameter."
    }
  }
}

function Invoke-WithRetry {
  param(
    [scriptblock]$Action,
    [int]$Retries = 3,
    [int]$DelayMs = 1500
  )
  for ($i=1; $i -le $Retries; $i++) {
    try { return & $Action }
    catch {
      if ($i -eq $Retries) { throw }
      Start-Sleep -Milliseconds $DelayMs
    }
  }
}

# -------------------------- Env file parsing --------------------------
function Load-EnvFile {
  param([string]$Path)
  $vars = @{}
  if (Test-Path $Path) {
    Write-Info "Loading env file $Path"
    foreach ($line in Get-Content $Path) {
      if ($line.Trim().StartsWith('#') -or -not $line.Contains('=')) { continue }
      $pair = $line -split '=',2
      $vars[$pair[0].Trim()] = $pair[1].Trim()
    }
  }
  return $vars
}

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $EnvFile) { $EnvFile = Join-Path $ScriptRoot "config\env" }
$EnvVars = Load-EnvFile $EnvFile
foreach ($k in $EnvVars.Keys) { Set-Item -Force -Path env:$k -Value $EnvVars[$k] }

if ($EnvVars.GPU_PORT_BASE) {
  $base = [int]$EnvVars.GPU_PORT_BASE
  $PortTalk  = $base
  $PortHeavy = $base + 1
  $PortBase  = $base + 2
}
if ($EnvVars.ROUTER_PORT) { $PortRouter = [int]$EnvVars.ROUTER_PORT }
if ($EnvVars.EVAL_PORT)   { $PortEval   = [int]$EnvVars.EVAL_PORT }

# -------------------------- Python venv -------------------------------
function Ensure-PythonVenv {
  param([string]$VenvPath)
  if (-not (Test-Path $VenvPath)) {
    Write-Info "Creating Python venv at $VenvPath"
    $py = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command py.exe -ErrorAction SilentlyContinue }
    if (-not $py) { throw "Python not found. Install Python 3 and re-run." }
    & $py -m venv $VenvPath | Out-Null
  }
  $pip = Join-Path $VenvPath "Scripts\pip.exe"
  $packages = @('fastapi==0.111.0','uvicorn==0.29.0','pyyaml==6.0.1','requests==2.32.3')
  Write-Info "Ensuring Python packages: $($packages -join ', ')"
  & $pip install --disable-pip-version-check @packages | Out-Null
}

$PyDir = Join-Path $BaseDir "pyenv"
if (-not $SkipInstallPython) {
  Ensure-PythonVenv -VenvPath $PyDir
} else {
  Write-Warn "SkipInstallPython set — not creating Python venv."
}

# -------------------------- Ollama install/find ------------------------
function Get-OllamaExeCandidates {
  @(
    "C:\\Program Files\\Ollama\\ollama.exe",
    Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
  )
}
function Find-OllamaExe {
  foreach ($p in Get-OllamaExeCandidates) {
    if (Test-Path -LiteralPath $p) { return (Resolve-Path $p).Path }
  }
  return $null
}
function Install-Ollama {
  if (Find-OllamaExe) { Write-Info "Ollama already present."; return }

  $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
  $choco  = Get-Command choco.exe  -ErrorAction SilentlyContinue

  if ($winget) {
    Write-Info "Installing Ollama via winget (machine scope, silent)…"
    $args = @("install","-e","--id","Ollama.Ollama","--scope","machine",
              "--silent","--accept-source-agreements","--accept-package-agreements",
              "--disable-interactivity")
    & $winget @args | Out-Null
  } elseif ($choco) {
    Write-Info "winget not found. Trying Chocolatey: choco install ollama -y…"
    & $choco install ollama -y --no-progress | Out-Null
  } else {
    throw "Neither winget nor Chocolatey available to install Ollama. Install manually and re-run."
  }

  # post-check
  $exe = Find-OllamaExe
  if (-not $exe) { throw "Ollama installation did not yield a detectable ollama.exe. Check installer output." }
  Write-OK "Ollama found at: $exe"
}

if (-not $SkipInstallOllama) {
  Install-Ollama
} else {
  Write-Warn "SkipInstallOllama set — not attempting installation."
}

$OllamaExe = $EnvVars.OLLAMA_BIN
if (-not $OllamaExe) { $OllamaExe = Find-OllamaExe }
if (-not $OllamaExe) {
  throw "Ollama not found. Please install, then re-run. Searched: $(Get-OllamaExeCandidates -join ', ')"
}

# -------------------------- Layout / Paths -----------------------------
$OBase = Join-Path $BaseDir "ollama"
$SvcGPU0 = Join-Path $OBase "svc-gpu0"
$SvcGPU1 = Join-Path $OBase "svc-gpu1"
$SvcCPU  = Join-Path $OBase "svc-cpu"
$SvcRouter = Join-Path $BaseDir "svc-router"
$SvcEval   = Join-Path $BaseDir "svc-evaluator"
$Logs    = Join-Path $BaseDir "logs"

New-Dir $BaseDir
New-Dir $OBase
New-Dir $SvcGPU0
New-Dir $SvcGPU1
New-Dir $SvcCPU
New-Dir $SvcRouter
New-Dir $SvcEval
New-Dir $Logs

$RepoRoot = $ScriptRoot

# -------------------------- Ports & Sanity -----------------------------
Require-PortFree @($PortHeavy,$PortBase,$PortTalk,$PortRouter,$PortEval)

# -------------------------- Start scripts ------------------------------
function Write-StartScript {
  param(
    [string]$Dir,
    [string]$Name,          # gpu0 | gpu1 | cpu
    [int]$Port,
    [nullable[int]]$CudaIndex, # 0 or 1; $null for CPU
    [switch]$CpuOnly
  )
  $logFile = Join-Path (Join-Path $Logs $Name) "$Name.log"
  New-Dir (Split-Path $logFile -Parent)

  $content = @()
  $content += '$ErrorActionPreference = "Stop"'
  $content += '$PSNativeCommandUseErrorActionPreference = $true'
  $content += '$here = Split-Path -Parent $MyInvocation.MyCommand.Path'
  $content += '$env:OLLAMA_HOST = "127.0.0.1"'
  $content += '$env:OLLAMA_MODELS = Join-Path $here "..\models"'
  $content += 'if (-not (Test-Path $env:OLLAMA_MODELS)) { New-Item -ItemType Directory -Path $env:OLLAMA_MODELS | Out-Null }'
  if ($CpuOnly) {
    $content += '$env:OLLAMA_NO_GPU = "1"'
    $content += '$env:CUDA_VISIBLE_DEVICES = ""'
  } else {
    $content += '$env:OLLAMA_NO_GPU = ""'
    $content += ('$env:CUDA_VISIBLE_DEVICES = "{0}"' -f $CudaIndex)
  }
  foreach ($k in $EnvVars.Keys) {
    $val = $EnvVars[$k].Replace('"','`"')
    $content += ('$env:{0} = "{1}"' -f $k, $val)
  }
  $content += ('$ollama = "{0}"' -f $OllamaExe.Replace('"','`"'))
  $content += ('$log = "{0}"' -f $logFile.Replace('"','`"'))
  $content += 'New-Item -ItemType File -Path $log -Force | Out-Null'
  $content += 'function Start-Ollama {'
  $content += ('  $args = @("serve","--host","127.0.0.1","--port","{0}")' -f $Port)
  $content += '  & $ollama @args 2>&1 | Tee-Object -FilePath $log -Append'
  $content += '}'
  $content += 'Write-Host ("Starting ollama on http://127.0.0.1:{0} ({1}))" -f ' + $Port + ', "' + $Name + '"'
  $content += 'while ($true) {'
  $content += '  try { Start-Ollama } catch { Start-Sleep -Seconds 2 }'
  $content += '  Start-Sleep -Seconds 2'
  $content += '}'

  $path = Join-Path $Dir "start.ps1"
  Set-Content -LiteralPath $path -Value ($content -join [Environment]::NewLine) -Encoding UTF8
  Unblock-File -LiteralPath $path
  return $path
}

function Write-PyStartScript {
  param(
    [string]$Dir,
    [string]$Name,    # router | evaluator
    [string]$Target,  # router or eval
    [int]$Port
  )
  $logFile = Join-Path (Join-Path $Logs $Name) "$Name.log"
  New-Dir (Split-Path $logFile -Parent)

  $content = @()
  $content += '$ErrorActionPreference = "Stop"'
  $content += '$PSNativeCommandUseErrorActionPreference = $true'
  $content += ('$repo = "{0}"' -f $RepoRoot.Replace('"','`"'))
  $content += ('$venv = "{0}"' -f $PyDir.Replace('"','`"'))
  $content += '$py = Join-Path $venv "Scripts\python.exe"'
  foreach ($k in $EnvVars.Keys) {
    $val = $EnvVars[$k].Replace('"','`"')
    $content += ('$env:{0} = "{1}"' -f $k, $val)
  }
  $content += ('$env:PORT = "{0}"' -f $Port)
  $content += ('$log = "{0}"' -f $logFile.Replace('"','`"'))
  $content += 'New-Item -ItemType File -Path $log -Force | Out-Null'
  if ($Target -eq 'router') {
    $content += '$script = Join-Path $repo "router\gar_router.py"'
    $content += '$cfg = Join-Path $repo "router\router.yaml"'
    $content += 'function Start-App { & $py $script --config $cfg 2>&1 | Tee-Object -FilePath $log -Append }'
    $content += 'Write-Host ("Starting router on http://127.0.0.1:{0}" -f ' + $Port + ')'
  } else {
    $content += '$script = Join-Path $repo "evaluator\evaluator_proxy.py"'
    $content += 'function Start-App { & $py $script 2>&1 | Tee-Object -FilePath $log -Append }'
    $content += 'Write-Host ("Starting evaluator on http://127.0.0.1:{0}" -f ' + $Port + ')'
  }
  $content += 'while ($true) {'
  $content += '  try { Start-App } catch { Start-Sleep -Seconds 2 }'
  $content += '  Start-Sleep -Seconds 2'
  $content += '}'

  $path = Join-Path $Dir "start.ps1"
  Set-Content -LiteralPath $path -Value ($content -join [Environment]::NewLine) -Encoding UTF8
  Unblock-File -LiteralPath $path
  return $path
}

$StartGPU0 = Write-StartScript -Dir $SvcGPU0 -Name "gpu0" -Port $PortHeavy -CudaIndex 0
$StartGPU1 = Write-StartScript -Dir $SvcGPU1 -Name "gpu1" -Port $PortBase  -CudaIndex 1
$StartCPU  = Write-StartScript -Dir $SvcCPU  -Name "cpu"  -Port $PortTalk  -CpuOnly
$StartRouter = Write-PyStartScript -Dir $SvcRouter -Name "router" -Target "router" -Port $PortRouter
$StartEval   = Write-PyStartScript -Dir $SvcEval   -Name "evaluator" -Target "eval" -Port $PortEval

# -------------------------- Services ----------------------------------
$PSExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

function Ensure-Service {
  param(
    [string]$ServiceName,
    [string]$DisplayName,
    [string]$ScriptPath,
    [string]$Description
  )
  $bin = "$PSExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
  $existing = sc.exe query $ServiceName 2>$null | Out-String
  if ($LASTEXITCODE -eq 0 -and $existing -match "SERVICE_NAME") {
    Write-Info "Updating service $ServiceName…"
    sc.exe config $ServiceName binPath= "$bin" start= delayed-auto | Out-Null
    sc.exe description $ServiceName "$Description" | Out-Null
  } else {
    Write-Info "Creating service $ServiceName…"
    sc.exe create $ServiceName binPath= "$bin" start= delayed-auto obj= "LocalSystem" type= own | Out-Null
    sc.exe description $ServiceName "$Description" | Out-Null
  }
  # failure actions: restart x3 (5s)
  sc.exe failureflag $ServiceName 1 | Out-Null
  sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
}

Ensure-Service -ServiceName "GARVIS_Ollama_GPU0" -DisplayName "GARVIS Ollama GPU0" -ScriptPath $StartGPU0 `
  -Description "Ollama runner bound to GPU0 (CUDA_VISIBLE_DEVICES=0) on 127.0.0.1:$PortHeavy"

Ensure-Service -ServiceName "GARVIS_Ollama_GPU1" -DisplayName "GARVIS Ollama GPU1" -ScriptPath $StartGPU1 `
  -Description "Ollama runner bound to GPU1 (CUDA_VISIBLE_DEVICES=1) on 127.0.0.1:$PortBase"

Ensure-Service -ServiceName "GARVIS_Ollama_CPU" -DisplayName "GARVIS Ollama CPU" -ScriptPath $StartCPU `
  -Description "Ollama runner (CPU only) on 127.0.0.1:$PortTalk"

Ensure-Service -ServiceName "GARVIS_Router" -DisplayName "GARVIS Router" -ScriptPath $StartRouter `
  -Description "GARVIS routing service on 127.0.0.1:$PortRouter"

Ensure-Service -ServiceName "GARVIS_Evaluator" -DisplayName "GARVIS Evaluator" -ScriptPath $StartEval `
  -Description "GARVIS evaluator proxy on 127.0.0.1:$PortEval"

function Start-And-Wait {
  param([string]$Name)
  Write-Info "Starting $Name…"
  sc.exe start $Name | Out-Null
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $StartTimeout) {
    $state = (sc.exe query $Name | Select-String "STATE").ToString()
    if ($state -match "RUNNING") { Write-OK "$Name is RUNNING"; return }
    Start-Sleep -Milliseconds 600
  }
  throw "$Name did not reach RUNNING within $([math]::Round($StartTimeout/1000))s."
}

Start-And-Wait "GARVIS_Ollama_GPU0"
Start-And-Wait "GARVIS_Ollama_GPU1"
Start-And-Wait "GARVIS_Ollama_CPU"
Start-And-Wait "GARVIS_Router"
Start-And-Wait "GARVIS_Evaluator"

# -------------------------- Health / Smoke -----------------------------
function Wait-Port {
  param([int]$Port,[int]$TimeoutMs=20000)
  $sw=[Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
    if (Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -WarningAction SilentlyContinue).TcpTestSucceeded {
      return $true
    }
    Start-Sleep -Milliseconds 500
  }
  return $false
}
function Probe-Ollama {
  param([int]$Port)
  try {
    $url = "http://127.0.0.1:$Port/api/tags"
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $url -Method GET -TimeoutSec 5
    return ($resp.StatusCode -eq 200)
  } catch { return $false }
}
function Probe-Router {
  param([int]$Port)
  try {
    $url = "http://127.0.0.1:$Port/evaluate"
    $body = '{"prompt":"ping"}'
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $url -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 5
    return ($resp.StatusCode -eq 200)
  } catch { return $false }
}

foreach ($p in @($PortHeavy,$PortBase,$PortTalk,$PortRouter,$PortEval)) {
  if (-not (Wait-Port -Port $p -TimeoutMs 30000)) {
    throw "TCP port check failed for :$p (listener not detected)."
  }
}

foreach ($p in @($PortHeavy,$PortBase,$PortTalk)) {
  if (Probe-Ollama -Port $p) { Write-OK "HTTP OK on :$p (/api/tags)" }
  else { Write-Warn "HTTP probe failed on :$p. Service may still be initializing; check logs." }
}

if (Probe-Router -Port $PortRouter) { Write-OK "Router OK on :$PortRouter" }
else { Write-Warn "HTTP probe failed on :$PortRouter" }

if (Probe-Ollama -Port $PortEval) { Write-OK "Evaluator OK on :$PortEval" }
else { Write-Warn "HTTP probe failed on :$PortEval" }

# -------------------------- Summary -----------------------------------
Write-Host ""
Write-OK  "GARVIS stack is up."
Write-Host "Endpoints (loopback only):"
Write-Host ("  GPU0 (Heavy) : http://127.0.0.1:{0}" -f $PortHeavy)
Write-Host ("  GPU1 (Base)  : http://127.0.0.1:{0}" -f $PortBase)
Write-Host ("  CPU  (Talk)  : http://127.0.0.1:{0}" -f $PortTalk)
Write-Host ("  Router       : http://127.0.0.1:{0}" -f $PortRouter)
Write-Host ("  Evaluator    : http://127.0.0.1:{0}" -f $PortEval)
Write-Host ""
Write-Host "Services:"
Write-Host "  GARVIS_Ollama_GPU0, GARVIS_Ollama_GPU1, GARVIS_Ollama_CPU, GARVIS_Router, GARVIS_Evaluator"
Write-Host ""
Write-Host "Logs:"
Write-Host ("  {0}" -f $Logs)
Write-Host ""
Write-Host "Tip: Use 'ollama list --address 127.0.0.1:<port>' to verify connectivity."

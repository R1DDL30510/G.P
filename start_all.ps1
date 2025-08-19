# ======================================================================
# GARVIS Startup Script (patched version)
# - Disables any legacy Ollama Windows services
# - Kills any process already bound to the configured ports
# - Launches dedicated Ollama instances for GPU0, GPU1 and CPU using
#   separate model stores (via OLLAMA_MODELS)
# - Starts the GARVIS router and evaluator proxy
# - Performs a health check and prints a concise summary
# ======================================================================

param(
  [int]$Gpu0Port   = 11434,
  [int]$Gpu1Port   = 11435,
  [int]$CpuPort    = 11436,
  [int]$RouterPort = 28100,
  [int]$EvalPort   = 11437,

  # Paths to executables and scripts
  [string]$OllamaExe = "C:\OllamaService\ollama.exe",
  [string]$PythonExe = "C:\Users\WIN11HOST\AppData\Local\Programs\Python\Python312\python.exe",
  [string]$RouterPy  = "D:\GARVIS\router\gar_router.py",
  [string]$RouterCfg = "D:\GARVIS\router\router.yaml",
  [string]$EvalPy    = "D:\GARVIS\evaluator\evaluator_proxy.py"
)

function Start-PSChild {
  param([string]$Command, [string]$WorkingDir = $null)
  # Launch a PowerShell child process running the specified command.  The
  # process inherits the parent's environment and runs without creating
  # a new console window.
  $args = @('-NoLogo','-NoProfile','-Command',$Command)
  if ($WorkingDir -and (Test-Path $WorkingDir)) {
    Start-Process -NoNewWindow -FilePath 'powershell.exe' -ArgumentList $args -WorkingDirectory $WorkingDir | Out-Null
  } else {
    Start-Process -NoNewWindow -FilePath 'powershell.exe' -ArgumentList $args | Out-Null
  }
}

function Start-Exe {
  param([string]$Exe, [string[]]$ArgList, [string]$WorkingDir = $null)
  # Launch a native executable without opening a new console.  Useful for
  # starting Python scripts or compiled binaries.
  if ($WorkingDir -and (Test-Path $WorkingDir)) {
    Start-Process -NoNewWindow -FilePath $Exe -ArgumentList $ArgList -WorkingDirectory $WorkingDir | Out-Null
  } else {
    Start-Process -NoNewWindow -FilePath $Exe -ArgumentList $ArgList | Out-Null
  }
}

function Test-Http200 {
  param([string]$url, [string]$method="GET", $body=$null)
  # Attempt a simple HTTP request and return 200 on success, 0 otherwise.
  try {
    if ($method -eq 'POST') {
      Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 3 | Out-Null
      return 200
    } else {
      (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3).StatusCode
    }
  } catch { return 0 }
}

# ---- Setup logging and encoding ----
$logDir = "D:\GARVIS\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss') + "_start.log")
Start-Transcript -Path $logFile -Append
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

# ---- 1) disable legacy Windows services ----
Write-Host "=== Killing old Ollama services if present ==="
$legacy = 'OllamaCPU','OllamaGPU0','OllamaGPU1','Ollama2060','Ollama2080ti'
foreach ($svc in $legacy) {
  try {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s) {
      Stop-Service $svc -Force -ErrorAction SilentlyContinue
      Set-Service  $svc -StartupType Disabled -ErrorAction SilentlyContinue
      Write-Host "Disabled $svc"
    }
  } catch {}
}

# ---- 2) free any occupied ports ----
$ports = @($Gpu0Port,$Gpu1Port,$CpuPort,$RouterPort,$EvalPort)
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object { $ports -contains $_.LocalPort } |
  ForEach-Object {
    try { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue } catch {}
  }

# ---- 3) start stack ----
Write-Host "=== Starting GARVIS stack ==="
if (-not (Test-Path $OllamaExe)) { throw "OllamaExe not found: $OllamaExe" }
if (-not (Test-Path $PythonExe)) { throw "PythonExe not found: $PythonExe" }
if (-not (Test-Path $RouterPy))  { throw "RouterPy not found: $RouterPy" }
if (-not (Test-Path $RouterCfg)) { throw "RouterCfg not found: $RouterCfg" }
if (-not (Test-Path $EvalPy))    { throw "EvalPy not found: $EvalPy" }

# Determine working directories
$ollamaDir = Split-Path -Path $OllamaExe
$routerDir = Split-Path -Path $RouterPy
$evalDir   = Split-Path -Path $EvalPy

# GPU0 instance (dedicated model store)
$cmdGpu0 = @"
`$env:OLLAMA_HOST='127.0.0.1:$Gpu0Port';
`$env:CUDA_VISIBLE_DEVICES='0';
`$env:OLLAMA_MODELS='D:\GARVIS\OllamaGPU0';
& '$OllamaExe' serve
"@
Start-PSChild -Command $cmdGpu0 -WorkingDir $ollamaDir

# GPU1 instance
$cmdGpu1 = @"
`$env:OLLAMA_HOST='127.0.0.1:$Gpu1Port';
`$env:CUDA_VISIBLE_DEVICES='1';
`$env:OLLAMA_MODELS='D:\GARVIS\OllamaGPU1';
& '$OllamaExe' serve
"@
Start-PSChild -Command $cmdGpu1 -WorkingDir $ollamaDir

# CPU instance
$cmdCpu = @"
`$env:OLLAMA_HOST='127.0.0.1:$CpuPort';
`$env:OLLAMA_NO_GPU='1';
`$env:OLLAMA_MODELS='D:\GARVIS\OllamaCPU';
& '$OllamaExe' serve
"@
Start-PSChild -Command $cmdCpu -WorkingDir $ollamaDir

# Router (Python)
Start-Exe -Exe $PythonExe -ArgList @($RouterPy, '--config', $RouterCfg) -WorkingDir $routerDir

# Evaluator proxy (FastAPI)
$cmdEval = @"
`$env:PORT='$EvalPort';
& '$PythonExe' '$EvalPy'
"@
Start-PSChild -Command $cmdEval -WorkingDir $evalDir

# ---- 4) health check after startup ----
Start-Sleep -Seconds 6

$routerStatus = Test-Http200 "http://127.0.0.1:$RouterPort/evaluate" 'POST' (@{prompt='ping'} | ConvertTo-Json -Compress)

$summary = @()
$summary += [pscustomobject]@{ Name='gpu0';   Port=$Gpu0Port;   Status=(Test-Http200 "http://127.0.0.1:$Gpu0Port/api/tags") }
$summary += [pscustomobject]@{ Name='gpu1';   Port=$Gpu1Port;   Status=(Test-Http200 "http://127.0.0.1:$Gpu1Port/api/tags") }
$summary += [pscustomobject]@{ Name='cpu';    Port=$CpuPort;    Status=(Test-Http200 "http://127.0.0.1:$CpuPort/api/tags") }
$summary += [pscustomobject]@{ Name='router'; Port=$RouterPort; Status=$routerStatus }
$summary += [pscustomobject]@{ Name='evaluator'; Port=$EvalPort; Status=(Test-Http200 "http://127.0.0.1:$EvalPort/api/tags") }

Write-Host ""
Write-Host "=== GARVIS Startup Summary ===" ""
$summary | ForEach-Object {
  $ok = ($_.Status -eq 200)
  $statusText = if ($ok) { 'OK' } else { 'FAIL' }
  $color      = if ($ok) { 'Green' } else { 'Red' }
  Write-Host ("{0,-10} {1,-6} {2}" -f $_.Name, $_.Port, $statusText) -ForegroundColor $color
}

Stop-Transcript
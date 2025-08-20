# ======================================================================
# GARVIS Startup Script (patched version)
# - Disables any legacy Ollama Windows services
# - Kills any process already bound to the configured ports
# - Launches dedicated Ollama instances for each GPU and a CPU fallback using
#   separate model stores (via OLLAMA_MODELS)
# - Starts the GARVIS router and evaluator proxy
# - Performs a health check and prints a concise summary
# ======================================================================

param(
  [int]$GpuPortBase = 11434,
  [int]$RouterPort  = 28100,
  [int]$EvalPort    = 11437,

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

$baseDir = Split-Path -Path $logDir

# Detect GPUs and prepare directories
$gpuInfo = ""
try { $gpuInfo = & nvidia-smi --query-gpu=index --format=csv,noheader 2>$null } catch {}
$gpuIndices = @()
if ($gpuInfo) { $gpuIndices = $gpuInfo -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9]+$' } }

$gpuPorts = @{}
foreach ($idx in $gpuIndices) {
  $port = $GpuPortBase + [int]$idx
  $gpuPorts[$idx] = $port
  $dir = Join-Path $baseDir ("OllamaGPU" + $idx)
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
}

$CpuPort = $GpuPortBase + $gpuPorts.Count
$cpuDir = Join-Path $baseDir "OllamaCPU"
if (-not (Test-Path $cpuDir)) { New-Item -ItemType Directory -Path $cpuDir | Out-Null }

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
$ports = @($RouterPort,$EvalPort,$CpuPort) + $gpuPorts.Values
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

# GPU instances
foreach ($idx in $gpuPorts.Keys) {
  $port = $gpuPorts[$idx]
  $gpuDir = Join-Path $baseDir ("OllamaGPU" + $idx)
  $cmd = @"
`$env:OLLAMA_HOST='127.0.0.1:$port';
`$env:CUDA_VISIBLE_DEVICES='$idx';
`$env:OLLAMA_MODELS='$gpuDir';
& '$OllamaExe' serve
"@
  Start-PSChild -Command $cmd -WorkingDir $ollamaDir
}

# CPU instance
$cmdCpu = @"
`$env:OLLAMA_HOST='127.0.0.1:$CpuPort';
`$env:OLLAMA_NO_GPU='1';
`$env:OLLAMA_MODELS='$cpuDir';
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
foreach ($idx in $gpuPorts.Keys) {
  $port = $gpuPorts[$idx]
  $summary += [pscustomobject]@{ Name="gpu$idx"; Port=$port; Status=(Test-Http200 "http://127.0.0.1:$port/api/tags") }
}
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
# ======================================================================
# GARVIS Startup Script (PowerShell 5.1 compatible)
# - Disables old Ollama services
# - Starts dedicated Ollama instances on separate ports
# - Launches the router and evaluator proxy
# - Performs a health check and logs startup status
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
  $args = @("-NoLogo","-NoProfile","-Command",$Command)
  if ($WorkingDir -and (Test-Path $WorkingDir)) {
    Start-Process -NoNewWindow -FilePath "powershell.exe" -ArgumentList $args -WorkingDirectory $WorkingDir | Out-Null
  } else {
    Start-Process -NoNewWindow -FilePath "powershell.exe" -ArgumentList $args | Out-Null
  }
}

function Start-Exe {
  param([string]$Exe, [string[]]$ArgList, [string]$WorkingDir = $null)
  if ($WorkingDir -and (Test-Path $WorkingDir)) {
    Start-Process -NoNewWindow -FilePath $Exe -ArgumentList $ArgList -WorkingDirectory $WorkingDir | Out-Null
  } else {
    Start-Process -NoNewWindow -FilePath $Exe -ArgumentList $ArgList | Out-Null
  }
}

function Test-Http200 {
  param([string]$url, [string]$method="GET", $body=$null)
  try {
    if ($method -eq "POST") {
      Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 3 | Out-Null
      return 200
    } else {
      (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3).StatusCode
    }
  } catch { return 0 }
}

# ---- Setup transcript and output encoding ----
$logDir = "D:\GARVIS\logs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("{0:yyyy-MM-dd_HH-mm-ss}_start.log" -f (Get-Date))
Start-Transcript -Path $logFile -Append
[Console]::OutputEncoding = [Text.UTF8Encoding]::UTF8

# ---- 1) disable old services ----
Write-Host "=== Killing old Ollama services if present ==="
$old = "OllamaCPU","OllamaGPU0","OllamaGPU1","Ollama2060","Ollama2080ti"
foreach ($svc in $old) {
  try {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s) {
      Stop-Service $svc -Force -ErrorAction SilentlyContinue
      Set-Service  $svc -StartupType Disabled -ErrorAction SilentlyContinue
      Write-Host "Disabled $svc"
    }
  } catch {}
}

# ---- 2) free ports ----
$ports = @($Gpu0Port,$Gpu1Port,$CpuPort,$RouterPort,$EvalPort)
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object { $ports -contains $_.LocalPort } |
  ForEach-Object {
    try { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue } catch {}
  }

# ---- 3) start stack ----
Write-Host "=== Starting GARVIS stack ==="
$ollamaDir = Split-Path -Path $OllamaExe -ErrorAction SilentlyContinue
$routerDir = Split-Path -Path $RouterPy  -ErrorAction SilentlyContinue
$evalDir   = Split-Path -Path $EvalPy    -ErrorAction SilentlyContinue

# validate paths
if (-not (Test-Path $OllamaExe)) { throw "OllamaExe not found: $OllamaExe" }
if (-not (Test-Path $PythonExe)) { throw "PythonExe not found: $PythonExe" }
if (-not (Test-Path $RouterPy))  { throw "RouterPy not found: $RouterPy" }
if (-not (Test-Path $RouterCfg)) { throw "RouterCfg not found: $RouterCfg" }
if (-not (Test-Path $EvalPy))    { throw "EvalPy not found: $EvalPy" }

# GPU0
$cmdGpu0 = "`$env:OLLAMA_HOST='127.0.0.1:$Gpu0Port'; `$env:CUDA_VISIBLE_DEVICES='0'; & '$OllamaExe' serve"
Start-PSChild -Command $cmdGpu0 -WorkingDir $ollamaDir

# GPU1
$cmdGpu1 = "`$env:OLLAMA_HOST='127.0.0.1:$Gpu1Port'; `$env:CUDA_VISIBLE_DEVICES='1'; & '$OllamaExe' serve"
Start-PSChild -Command $cmdGpu1 -WorkingDir $ollamaDir

# CPU (no GPU)
$cmdCpu = "`$env:OLLAMA_HOST='127.0.0.1:$CpuPort'; `$env:OLLAMA_NO_GPU='1'; & '$OllamaExe' serve"
Start-PSChild -Command $cmdCpu -WorkingDir $ollamaDir

# Router with config
Start-Exe -Exe $PythonExe -ArgList @($RouterPy, "--config", $RouterCfg) -WorkingDir $routerDir

# Evaluator proxy
$cmdEval = "`$env:PORT='$EvalPort'; & '$PythonExe' '$EvalPy'"
Start-PSChild -Command $cmdEval -WorkingDir $evalDir

# ---- 4) health check ----
Start-Sleep -Seconds 6

$routerStatus = Test-Http200 "http://127.0.0.1:$RouterPort/evaluate" "POST" (@{prompt='ping'} | ConvertTo-Json -Compress)

$summary = @()
$summary += [pscustomobject]@{ Name="gpu0";      Port=$Gpu0Port;   Status=(Test-Http200 "http://127.0.0.1:$Gpu0Port/api/tags") }
$summary += [pscustomobject]@{ Name="gpu1";      Port=$Gpu1Port;   Status=(Test-Http200 "http://127.0.0.1:$Gpu1Port/api/tags") }
$summary += [pscustomobject]@{ Name="cpu";       Port=$CpuPort;    Status=(Test-Http200 "http://127.0.0.1:$CpuPort/api/tags") }
$summary += [pscustomobject]@{ Name="router";    Port=$RouterPort; Status=$routerStatus }
$summary += [pscustomobject]@{ Name="evaluator"; Port=$EvalPort;   Status=(Test-Http200 "http://127.0.0.1:$EvalPort/api/tags") }

Write-Host ""
Write-Host "=== GARVIS Startup Summary ===" ""
$summary | ForEach-Object {
  $ok = ($_.Status -eq 200)
  $statusText = if ($ok) { "OK" } else { "FAIL" }
  $color      = if ($ok) { "Green" } else { "Red" }
  Write-Host ("{0,-10} {1,-6} {2}" -f $_.Name, $_.Port, $statusText) -ForegroundColor $color
}

Stop-Transcript

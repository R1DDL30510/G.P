<# 
GARVIS · Ollama Benchmark & GPU Analysis (Windows PowerShell)

What it does:
1) Builds/loads models you pass in.
2) Runs a prompt sweep with different output lengths.
3) Captures Ollama timings from /api/generate (eval_count/duration).
4) Samples GPU telemetry (both GPUs) via nvidia-smi into CSV while tests run.

Usage examples:
  .\bench_ollama.ps1 -Endpoint 'http://127.0.0.1:11434' -Model 'garvis-helper-split' -OutDir '.\bench_out'
  .\bench_ollama.ps1 -Endpoint 'http://127.0.0.1:11434' -Model 'garvis-helper-gpu0-max' -OutDir '.\bench_out'

Prereq: NVIDIA drivers + nvidia-smi in PATH.
#>

param(
  [string]$Endpoint = "http://127.0.0.1:11434",
  [string]$Model,
  [string]$OutDir = ".\bench_out",
  [int]$GpuSampleMs = 1000,
  [int]$Samples = 3
)

if (-not $Model) { throw "Please provide -Model (Ollama model name)." }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# --- GPU monitor job ---
function Start-GpuMonitor {
  param([string]$CsvPath, [int]$IntervalMs = 1000)
  $script = @'
param($Csv,$Ms)
"ts,gpu,index,util,power_w,mem_used_mb,mem_total_mb" | Out-File -FilePath $Csv -Encoding ascii
while ($true) {
  $ts = (Get-Date).ToString("s")
  $out = & nvidia-smi --query-gpu=name,index,utilization.gpu,power.draw,memory.used,memory.total --format=csv,noheader,nounits 2>$null
  if ($LASTEXITCODE -ne 0) { Start-Sleep -Milliseconds $Ms; continue }
  foreach ($line in $out) {
    $parts = $line.Split(",").ForEach({ $_.Trim() })
    "$ts,$($parts[0]),$($parts[1]),$($parts[2]),$($parts[3]),$($parts[4]),$($parts[5])" | Add-Content -Path $Csv
  }
  Start-Sleep -Milliseconds $Ms
}
'@
  Start-Job -ScriptBlock ([ScriptBlock]::Create($script)) -ArgumentList $CsvPath, $IntervalMs
}

function Stop-GpuMonitor {
  Get-Job | Stop-Job -PassThru | Remove-Job -Force
}

# --- helper to POST /api/generate ---
function Invoke-OllamaGenerate {
  param([string]$Prompt,[int]$MaxTokens=256)
  $body = @{ model=$Model; prompt=$Prompt; stream=$false } | ConvertTo-Json -Depth 6
  $resp = Invoke-RestMethod -Method Post -Uri ($Endpoint.TrimEnd('/') + "/api/generate") -ContentType 'application/json' -Body $body
  return $resp
}

# --- Bench prompts ---
$prompts = @(
  @{ name="short";  text="Summarize in 2 sentences: The history of the FRITZ!Box and WireGuard integration."; max=128 },
  @{ name="code";   text="Write a PowerShell function that returns GPU utilization by parsing nvidia-smi CSV."; max=256 },
  @{ name="reason"; text="Solve: You have 3 boxes (apples, oranges, mixed)... classic two-draw puzzle. Explain briefly."; max=256 }
)

$gpuCsv = Join-Path $OutDir "gpu_telemetry.csv"
$job = Start-GpuMonitor -CsvPath $gpuCsv -IntervalMs $GpuSampleMs

$results = @()
try {
  for ($i=0; $i -lt $Samples; $i++) {
    foreach ($p in $prompts) {
      $name = $p.name
      $prompt = $p.text
      $max = $p.max
      $t0 = [DateTime]::UtcNow
      $resp = Invoke-OllamaGenerate -Prompt $prompt -MaxTokens $max
      $t1 = [DateTime]::UtcNow
      $dur_ms = [int]($t1 - $t0).TotalMilliseconds
      $eval_count = $resp.eval_count
      $eval_dur   = $resp.eval_duration
      $prompt_eval_count = $resp.prompt_eval_count
      $prompt_eval_dur   = $resp.prompt_eval_duration

      $tokens_s = if ($eval_dur -gt 0) { [math]::Round(($eval_count / ($eval_dur/1e9)),2) } else { 0 }
      $row = [PSCustomObject]@{
        ts = (Get-Date).ToString("s")
        model = $Model
        case  = $name
        latency_ms = $dur_ms
        prompt_tok  = $prompt_eval_count
        gen_tok     = $eval_count
        gen_time_ms = [int]($eval_dur/1e6)
        tokens_per_s = $tokens_s
      }
      $results += $row
      $row | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content -Path (Join-Path $OutDir "results.csv")
      Write-Host ("[{0}] {1}/{2}  {3}  {4} tok @ {5} tok/s  ({6} ms total)" -f (Get-Date -Format T), $i+1, $Samples, $name, $eval_count, $tokens_s, $dur_ms)
    }
  }
}
finally {
  Stop-GpuMonitor
}

"Saved: $(Join-Path $OutDir 'results.csv') and $gpuCsv"

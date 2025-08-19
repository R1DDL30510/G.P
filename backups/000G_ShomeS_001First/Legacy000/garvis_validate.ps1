
<# 
GARVIS v001 – Automated Validation (for LM agents)
File: garvis_validate.ps1

Usage examples:
  powershell -ExecutionPolicy Bypass -File .\garvis_validate.ps1
  powershell -ExecutionPolicy Bypass -File .\garvis_validate.ps1 -BaseDir "D:\GARVIS" -RouterYaml "D:\GARVIS\router\router.yaml"

Description:
  Runs non-destructive checks for dependencies, paths, config consistency,
  port conflicts, and endpoint health for the GARVIS v001 stack.
  Produces a console summary and a machine-readable JSON report.

Notes:
  - If ConvertFrom-Yaml is unavailable (PowerShell 7+), YAML checks will be downgraded to WARN with remediation hints.
  - No outbound internet requests are made; all checks are local to the host.
#>

[CmdletBinding()]
param(
  [string]$BaseDir = "D:\GARVIS",
  [string]$RouterYaml = "D:\GARVIS\router\router.yaml",
  [int[]]$ExpectedPorts = @(11434,11435,11436,11437,28100),
  [int]$HttpTimeoutSec = 4,
  [int]$CmdTimeoutSec = 10,
  [switch]$QuietJSON # only emit JSON report path on success
)

# --- helpers ---------------------------------------------------------------

function New-Check {
  param([string]$Id,[string]$Name,[string]$Status,[hashtable]$Data,[string]$Remediation)
  [ordered]@{ id=$Id; name=$Name; status=$Status; data=$Data; remediation=$Remediation }
}

function Add-Result {
  param($ArrRef, $Item)
  $ArrRef.Add([pscustomobject]$Item) | Out-Null
}

function Invoke-WithTimeout {
  param([scriptblock]$Script,[int]$TimeoutSec=10)
  $job = Start-Job -ScriptBlock $Script
  if (Wait-Job $job -Timeout $TimeoutSec) {
    $out = Receive-Job $job -Keep
    Remove-Job $job -Force
    return @{ ok=$true; output=$out }
  } else {
    Stop-Job $job -Force | Out-Null
    Remove-Job $job -Force
    return @{ ok=$false; timeout=$true; output=$null }
  }
}

function Test-Http {
  param([string]$Url,[int]$TimeoutSec=4)
  try {
    $c = New-Object System.Net.Http.HttpClient
    $c.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    $resp = $c.GetAsync($Url).GetAwaiter().GetResult()
    return @{ ok=$resp.IsSuccessStatusCode; code = [int]$resp.StatusCode }
  } catch {
    return @{ ok=$false; error = $_.Exception.Message }
  }
}

function Try-ConvertFromYaml {
  param([string]$YamlText)
  if (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) {
    try {
      return @{ ok=$true; obj = ($YamlText | ConvertFrom-Yaml) }
    } catch {
      return @{ ok=$false; error="ConvertFrom-Yaml failed: $($_.Exception.Message)" }
    }
  } else {
    return @{ ok=$false; error="ConvertFrom-Yaml not available (install PowerShell 7+ or powershell-yaml)" }
  }
}

# --- collect meta ----------------------------------------------------------
$results = New-Object System.Collections.ArrayList
$meta = [ordered]@{
  ts = (Get-Date).ToString("s")
  host = $env:COMPUTERNAME
  user = "$($env:USERNAME)"
  ps_version = $PSVersionTable.PSVersion.ToString()
  base_dir = $BaseDir
  router_yaml = $RouterYaml
}

# --- check: paths ----------------------------------------------------------
$paths = @(
  (Join-Path $BaseDir "router\logs"),
  (Join-Path $BaseDir "evaluator"),
  (Join-Path $BaseDir "services"),
  (Join-Path $BaseDir "start_all.ps1")
)
$missing = @()
foreach($p in $paths){
  if (-not (Test-Path $p)) { $missing += $p }
}
$status = "fail"
if ($missing.Count -eq 0) { $status = "pass" }
Add-Result -ArrRef $results -Item (New-Check -Id "paths.core" -Name "Core paths present" -Status $status -Data @{ checked=$paths; missing=$missing } -Remediation "Ensure GARVIS is staged at $BaseDir with expected subfolders.")

# --- check: ollama presence ------------------------------------------------
$ollamaPath = (Get-Command ollama -ErrorAction SilentlyContinue | Select-Object -First 1).Path
if ($null -eq $ollamaPath) {
  Add-Result -ArrRef $results -Item (New-Check -Id "dep.ollama" -Name "Ollama CLI in PATH" -Status "fail" -Data @{ path=$null } -Remediation "Install Ollama CLI and ensure it's in PATH.")
} else {
  $verRet = Invoke-WithTimeout -Script { & ollama --version } -TimeoutSec $CmdTimeoutSec
  if ($verRet.ok) {
    Add-Result -ArrRef $results -Item (New-Check -Id "dep.ollama" -Name "Ollama CLI in PATH" -Status "pass" -Data @{ path=$ollamaPath; version="$($verRet.output -join ' ')" } -Remediation "")
  } elseif ($verRet.timeout) {
    Add-Result -ArrRef $results -Item (New-Check -Id "dep.ollama" -Name "Ollama CLI in PATH" -Status "warn" -Data @{ path=$ollamaPath; note="version call timed out" } -Remediation "Investigate Ollama responsiveness; check service health.")
  } else {
    Add-Result -ArrRef $results -Item (New-Check -Id "dep.ollama" -Name "Ollama CLI in PATH" -Status "warn" -Data @{ path=$ollamaPath; err="unknown error running --version" } -Remediation "Run 'ollama --version' interactively to inspect error.")
  }
}

# --- check: ollama models list --------------------------------------------
if ($ollamaPath) {
  $lst = Invoke-WithTimeout -Script { & ollama list } -TimeoutSec $CmdTimeoutSec
  if ($lst.ok) {
    Add-Result -ArrRef $results -Item (New-Check -Id "ollama.list" -Name "Models are listed" -Status "pass" -Data @{ lines = ($lst.output | ForEach-Object { "$_" }) } -Remediation "")
  } elseif ($lst.timeout) {
    Add-Result -ArrRef $results -Item (New-Check -Id "ollama.list" -Name "Models are listed" -Status "warn" -Data @{ note="ollama list timed out" } -Remediation "Check OLLAMA_MODELS, Modelfile paths, and service availability.")
  } else {
    Add-Result -ArrRef $results -Item (New-Check -Id "ollama.list" -Name "Models are listed" -Status "fail" -Data @{ note="ollama list failed" } -Remediation "Verify models directory and permissions.")
  }
}

# --- check: ports listening ------------------------------------------------
$portData = @()
foreach($port in $ExpectedPorts){
  $tcp = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
  $ok = ($tcp -ne $null -and $tcp.Count -gt 0)
  $portData += [ordered]@{ port=$port; listening=$ok; procs=($tcp | Select-Object -ExpandProperty OwningProcess -Unique) }
}
$missingPorts = $portData | Where-Object { -not $_.listening } | Select-Object -ExpandProperty port
$portStatus = "fail"
if ($missingPorts.Count -eq 0) { $portStatus = "pass" }
Add-Result -ArrRef $results -Item (New-Check -Id "net.ports" -Name "Expected ports listening" -Status $portStatus -Data @{ details=$portData; missing=$missingPorts } -Remediation "Start services via start_all.ps1; check collisions with other apps.")

# --- check: HTTP health for endpoints -------------------------------------
$endpointsToCheck = @(
  @{ key="gpu0"; url="http://127.0.0.1:11434/api/tags" },
  @{ key="gpu1"; url="http://127.0.0.1:11435/api/tags" },
  @{ key="cpu";  url="http://127.0.0.1:11436/api/tags" },
  @{ key="eval"; url="http://127.0.0.1:11437/api/tags" }
)
$httpData = @()
foreach($ep in $endpointsToCheck){
  $res = Test-Http -Url $ep.url -TimeoutSec $HttpTimeoutSec
  $httpData += [ordered]@{ key=$ep.key; url=$ep.url; ok=$res.ok; code=$res.code; error=$res.error }
}
$httpBad = $httpData | Where-Object { -not $_.ok }
$httpStatus = "warn"
if ($httpBad.Count -eq 0) { $httpStatus = "pass" }
Add-Result -ArrRef $results -Item (New-Check -Id "http.endpoints" -Name "HTTP endpoints reachable" -Status $httpStatus -Data @{ details=$httpData } -Remediation "If some endpoints fail, inspect corresponding service logs.")

# --- check: YAML config consistency ---------------------------------------
$yamlExists = Test-Path $RouterYaml
if (-not $yamlExists) {
  Add-Result -ArrRef $results -Item (New-Check -Id "cfg.exists" -Name "router.yaml present" -Status "fail" -Data @{ path=$RouterYaml } -Remediation "Ensure router.yaml is deployed.")
} else {
  $yamlText = Get-Content $RouterYaml -Raw -ErrorAction SilentlyContinue
  $yamlParsed = Try-ConvertFromYaml -YamlText $yamlText
  if (-not $yamlParsed.ok) {
    Add-Result -ArrRef $results -Item (New-Check -Id "cfg.yaml" -Name "Parse router.yaml" -Status "warn" -Data @{ error=$yamlParsed.error } -Remediation "Use PowerShell 7+ or 'Install-Module powershell-yaml' to enable ConvertFrom-Yaml.")
  } else {
    $cfg = $yamlParsed.obj
    $issues = @()
    # endpoints vs inventory
    $eps = @()
    if ($cfg.endpoints) { $cfg.endpoints.PSObject.Properties | ForEach-Object { $eps += $_.Name } }
    $inv = @()
    if ($cfg.inventory) { $cfg.inventory.PSObject.Properties | ForEach-Object { $inv += $_.Name } }
    # verify each inventory item has endpoint that exists
    foreach($alias in $inv){
      $meta = $cfg.inventory.$alias.params
      $epKey = $cfg.inventory.$alias.endpoint
      if (-not $epKey) { $issues += "inventory '$alias' missing endpoint key" }
      elseif ($eps -notcontains $epKey) { $issues += "inventory '$alias' endpoint '$epKey' not in endpoints" }
      if (-not $meta.real_model) { $issues += "inventory '$alias' missing params.real_model" }
    }
    # model_map optional sanity
    if ($cfg.model_map) {
      $badMap = @()
      $cfg.model_map.PSObject.Properties | ForEach-Object {
        if ($eps -notcontains $_.Value) { $badMap += "$($_.Name)->$($_.Value)" }
      }
      if ($badMap.Count -gt 0) { $issues += "model_map references unknown endpoints: $($badMap -join ', ')" }
    }
    $statusCfg = "fail"
    if ($issues.Count -eq 0) { $statusCfg = "pass" }
    Add-Result -ArrRef $results -Item (New-Check -Id "cfg.consistency" -Name "router.yaml consistency" -Status $statusCfg -Data @{ issues=$issues; endpoints=$eps; inventory=$inv } -Remediation "Fix listed issues in router.yaml.")
  }
}

# --- summarize -------------------------------------------------------------
$pass = ($results | Where-Object { $_.status -eq "pass" }).Count
$warn = ($results | Where-Object { $_.status -eq "warn" }).Count
$fail = ($results | Where-Object { $_.status -eq "fail" }).Count
$summary = [ordered]@{ pass=$pass; warn=$warn; fail=$fail }

# --- persist JSON report ---------------------------------------------------
$reportDir = Join-Path $BaseDir "logs"
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$reportPath = Join-Path $reportDir ("validate_" + $stamp + ".json")

$payload = [ordered]@{
  meta = $meta
  results = $results
  summary = $summary
}
$payload | ConvertTo-Json -Depth 6 | Out-File -FilePath $reportPath -Encoding UTF8

# --- console output --------------------------------------------------------
if (-not $QuietJSON) {
  Write-Host ("GARVIS v001 – Validation Report ({0})`n" -f $meta.ts) -ForegroundColor Cyan
  foreach($r in $results){
    $color = "White"
    if ($r.status -eq "pass") { $color = "Green" }
    elseif ($r.status -eq "warn") { $color = "Yellow" }
    elseif ($r.status -eq "fail") { $color = "Red" }
    Write-Host ("[{0}] {1}" -f $r.status.ToUpper(), $r.name) -ForegroundColor $color
    if ($r.remediation) { Write-Host ("  ↳ Fix: {0}" -f $r.remediation) -ForegroundColor DarkGray }
  }
  Write-Host ""
  Write-Host ("Summary: PASS={0}  WARN={1}  FAIL={2}" -f $summary.pass,$summary.warn,$summary.fail) -ForegroundColor Cyan
  Write-Host ("JSON report: {0}" -f $reportPath) -ForegroundColor Gray
} else {
  Write-Output $reportPath
}

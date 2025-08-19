# === Loadtest.ps1 ===
# Belastet gar-chat (GPU0), gar-reason (GPU1), gar-router (CPU)
# Jeweils 10 Requests parallel -> Router entscheidet / verteilt
# Kompatibel mit Windows PowerShell 5.x

$uri = "http://127.0.0.1:18100/api/generate"

# Testprompts
$payloads = @{
    "gar-chat"   = '{ "model":"gar-chat", "prompt":"Erkläre kurz den Unterschied zwischen Hund und Katze.", "stream":false }'
    "gar-reason" = '{ "model":"gar-reason", "prompt":"Analysiere die Vor- und Nachteile von erneuerbaren Energien.", "stream":false }'
    "gar-router" = '{ "model":"gar-router", "prompt":"route: soll diese Anfrage eher coding oder reasoning sein?", "stream":false }'
}

# Funktion für eine einzelne Anfrage
function Invoke-Loadtest {
    param(
        [string]$Body,
        [string]$Model,
        [string]$Target  # cpu/gpu0/gpu1 oder "" für Standard
    )
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        if ($Target -ne "") {
            $res = Invoke-RestMethod -Uri "$uri?target=$Target" -Method POST -ContentType "application/json" -Body $Body
        } else {
            $res = Invoke-RestMethod -Uri $uri -Method POST -ContentType "application/json" -Body $Body
        }
        $sw.Stop()
        Write-Output ("[{0}] {1} -> {2} ms" -f $Model, $res.model, $sw.ElapsedMilliseconds)
    }
    catch {
        Write-Output ("[{0}] ERROR: {1}" -f $Model, $_.Exception.Message)
    }
}

# === Jobs starten (parallel) ===
$jobs = @()

foreach ($model in $payloads.Keys) {
    for ($i=1; $i -le 10; $i++) {
        $body = $payloads[$model]
        # gezieltes Target setzen
        $target = switch ($model) {
            "gar-chat"   { "gpu0" }
            "gar-reason" { "gpu1" }
            "gar-router" { "cpu" }
        }
        $jobs += Start-Job -ScriptBlock ${function:Invoke-Loadtest} -ArgumentList $body, $model, $target
    }
}

# === Warten & Ergebnisse sammeln ===
Wait-Job $jobs
$results = Receive-Job $jobs
Remove-Job $jobs

# Ausgabe sortieren
$results | Sort-Object
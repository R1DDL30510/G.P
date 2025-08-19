param(
  [switch]$ArchiveRoutineOlderThan14Days = $true
)

$ErrorActionPreference = "Stop"
$logDir     = "D:\GARVIS\logs"
$archiveDir = Join-Path $logDir "archive"
New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

# ---------- Hilfsfunktionen ----------
function Parse-LogTimeFromName([string]$name) {
  # erwartet: 2025-08-18_HH-mm-ss_start.log
  if ($name -match '^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})_start\.log$') {
    return Get-Date -Year $Matches[1] -Month $Matches[2] -Day $Matches[3] -Hour $Matches[4] -Minute $Matches[5] -Second $Matches[6]
  }
  return $null
}

function Get-PreviousCalendarWeekWindow {
  # Woche = Mo 00:00 bis Mo 00:00
  $now      = Get-Date
  $today    = Get-Date $now.Date
  $dow      = [int]$today.DayOfWeek  # So=0, Mo=1, ...
  $mondayThisWeek = $today.AddDays(1 - ($dow -eq 0 ? 7 : $dow))
  $mondayPrevWeek = $mondayThisWeek.AddDays(-7)
  # Fenster: [prevMon, thisMon)
  [PSCustomObject]@{
    Start = $mondayPrevWeek
    End   = $mondayThisWeek
  }
}

function Is-ImportantContent([string]$content) {
  return ($content -match 'FAIL' -or
          $content -match 'Exception' -or
          $content -match 'Traceback' -or
          $content -match 'ERROR' -or
          $content -match 'bind failed' -or
          $content -match 'port.*in use')
}

# ---------- Vorwoche bestimmen ----------
$win = Get-PreviousCalendarWeekWindow
$start = $win.Start
$end   = $win.End

# ---------- Logs einsammeln ----------
$allLogs = Get-ChildItem $logDir -Filter "*_start.log" -File
$withMeta = foreach ($f in $allLogs) {
  $t = Parse-LogTimeFromName $f.Name
  [PSCustomObject]@{ File=$f; When=$t }
} | Where-Object { $_.When -ne $null }

$logsPrevWeek = $withMeta | Where-Object { $_.When -ge $start -and $_.When -lt $end } | Sort-Object When

# ---------- Analyse der Vorwoche ----------
$summary = [PSCustomObject]@{
  Window         = "{0:yyyy-MM-dd} → {1:yyyy-MM-dd}" -f $start, $end
  TotalLogs      = 0
  ImportantLogs  = 0
  RoutineLogs    = 0
  FailLines      = 0
  EndpointsDown  = @()
}
$downCounts = @{}

foreach ($item in $logsPrevWeek) {
  $content = Get-Content $item.File.FullName -Raw
  $isImportant = Is-ImportantContent $content

  # Endpunkt-Fails aus Startup-Summary extrahieren
  foreach ($line in ($content -split "`r?`n")) {
    if ($line -match '^\s*(gpu0|gpu1|cpu|router|evaluator)\s+\d+\s+FAIL') {
      $k = $Matches[1]
      $downCounts[$k] = 1 + ($downCounts[$k] ?? 0)
      $summary.FailLines++
    }
    elseif ($line -match 'FAIL|Exception|Traceback|ERROR') {
      $summary.FailLines++
    }
  }

  if ($isImportant) { $summary.ImportantLogs++ } else { $summary.RoutineLogs++ }
  $summary.TotalLogs++
}

$summary.EndpointsDown = ($downCounts.Keys | ForEach-Object {
  "{0}:{1}" -f $_, $downCounts[$_]
})

# ---------- Summary-Datei schreiben ----------
$outFile = Join-Path $logDir ("weekly_summary_{0:yyyy-MM-dd}.txt" -f $end.AddDays(-1))
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine(("GARVIS Wochenreport: {0}" -f $summary.Window))
[void]$sb.AppendLine(("Logs gesamt: {0}" -f $summary.TotalLogs))
[void]$sb.AppendLine(("Wichtig (Fehler/Exceptions): {0}" -f $summary.ImportantLogs))
[void]$sb.AppendLine(("Routine: {0}" -f $summary.RoutineLogs))
[void]$sb.AppendLine(("Fehler-Zeilen: {0}" -f $summary.FailLines))
if ($summary.EndpointsDown.Count -gt 0) {
  [void]$sb.AppendLine(("Endpoints mit Ausfällen: {0}" -f ($summary.EndpointsDown -join ", ")))
} else {
  [void]$sb.AppendLine("Endpoints mit Ausfällen: keine")
}
Set-Content -Path $outFile -Value $sb.ToString() -Encoding UTF8

# ---------- Routine-Logs >14 Tage archivieren (nur wenn nicht wichtig) ----------
if ($ArchiveRoutineOlderThan14Days) {
  foreach ($item in $withMeta) {
    if ($item.When -lt (Get-Date).AddDays(-14)) {
      $content = Get-Content $item.File.FullName -Raw
      if (-not (Is-ImportantContent $content)) {
        $zip = Join-Path $archiveDir ($item.File.BaseName + ".zip")
        Compress-Archive -Path $item.File.FullName -DestinationPath $zip -Force
        Remove-Item $item.File.FullName -Force
      }
    }
  }
}

# ---------- (Optional) Toast anzeigen, falls BurntToast vorhanden ----------
if (Get-Module -ListAvailable -Name BurntToast) {
  Import-Module BurntToast
  $title = "GARVIS Wochenreport"
  $body  = "Zeitraum: $($summary.Window)`n" +
           "Logs: $($summary.TotalLogs), Wichtig: $($summary.ImportantLogs), Routine: $($summary.RoutineLogs)`n" +
           "Fehler-Zeilen: $($summary.FailLines)`n" +
           (($summary.EndpointsDown.Count -gt 0) ? ("Ausfälle: " + ($summary.EndpointsDown -join ", ")) : "Keine Ausfälle")
  New-BurntToastNotification -Text $title, $body
} else {
  # Fallback: Einzeiler in Konsole + Hinweis auf Datei
  Write-Host "[GARVIS] Weekly summary geschrieben: $outFile"
}

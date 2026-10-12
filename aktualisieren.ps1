# Rechnet die PV-Prognose für heute und die nächsten zwei Tage (daten.json)
# und ergänzt das Archiv der täglichen Erträge (archiv.json).
# Läuft stündlich als GitHub Action (pwsh), lokal auch mit Windows PowerShell 5.1.
#
# Anlage: anlage.json. Richtung als Kompass-Azimut (0° = Nord, 180° = Süd).
# Rechnung: kWp × Einstrahlung auf die geneigte Fläche / 1000, korrigiert um die
# Modultemperatur (NOCT ≈ 45 °C) und die Systemverluste, begrenzt auf die AC-Leistung
# des Wechselrichters, mal einem Korrekturfaktor je nach Bewölkung (anlage.json, aus dem
# Abgleich mit den Loxone-Messwerten). Die Archivwerte sind aus dem eingetretenen Wetter berechnet,
# keine Messwerte.

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$inv = [Globalization.CultureInfo]::InvariantCulture
$utf8 = New-Object Text.UTF8Encoding $false
$A = [IO.File]::ReadAllText("$PSScriptRoot/anlage.json", $utf8) | ConvertFrom-Json
$VORTAGE = 7   # so viele vergangene Tage werden bei jedem Lauf neu gerechnet
$KORR = if ($A.korrektur) { $A.korrektur } else { [pscustomobject]@{ klar = 1; bewoelkt = 1 } }

function Hole($basis, $f, $extra) {
  $az = $f.richtung - 180   # Open-Meteo: 0 = Süd, -90 = Ost, 90 = West
  $url = "${basis}?latitude=$($A.ort.lat)&longitude=$($A.ort.lon)&tilt=$($f.neigung)&azimuth=$az" +
    '&hourly=global_tilted_irradiance,temperature_2m,cloud_cover' +
    '&daily=weather_code,sunshine_duration,temperature_2m_max,temperature_2m_min,precipitation_sum' +
    "&timezone=Europe%2FZurich$extra"
  for ($i = 1; ; $i++) {
    try { return Invoke-RestMethod $url -TimeoutSec 90 }
    catch { if ($i -ge 3) { throw }; Start-Sleep 15 }
  }
}

# Leistung in kW pro Fläche und Stunde (Einstrahlung = Mittel der vorangehenden Stunde)
function Leistung($daten) {
  $n = $daten[0].hourly.time.Count
  $kw = @()
  for ($i = 0; $i -lt $A.flaechen.Count; $i++) {
    $f = $A.flaechen[$i]; $h = $daten[$i].hourly
    $kwp = $f.module * $f.wp / 1000
    $reihe = New-Object double[] $n
    for ($t = 0; $t -lt $n; $t++) {
      $g = [double]$h.global_tilted_irradiance[$t]
      if ($g -le 0) { continue }
      $tZelle = [double]$h.temperature_2m[$t] + $g / 800 * 25
      # Korrektur aus dem Abgleich mit den Messwerten, gewichtet nach der Bewölkung dieser Stunde
      $cc = [double]$h.cloud_cover[$t] / 100
      $faktor = $KORR.klar * (1 - $cc) + $KORR.bewoelkt * $cc
      $reihe[$t] = [math]::Max(0.0, $kwp * $g / 1000 * (1 + $A.tk / 100 * ($tZelle - 25)) * (1 - $A.verluste / 100) * $faktor)
    }
    $kw += , $reihe
  }
  if ($A.wrMax -gt 0) {
    for ($t = 0; $t -lt $n; $t++) {
      $s = 0; foreach ($r in $kw) { $s += $r[$t] }
      if ($s -gt $A.wrMax) { foreach ($r in $kw) { $r[$t] *= $A.wrMax / $s } }
    }
  }
  return , $kw
}

# kWh pro Tag und Fläche; der Stempel 00:00 gehört zur Stunde davor, also zum Vortag
function Tagessummen($zeiten, $kw) {
  $s = @{}
  for ($t = 0; $t -lt $zeiten.Count; $t++) {
    $tag = [datetime]::ParseExact($zeiten[$t], "yyyy-MM-dd'T'HH:mm", $inv).AddHours(-1).ToString('yyyy-MM-dd', $inv)
    if (-not $s.ContainsKey($tag)) { $s[$tag] = New-Object double[] $kw.Count }
    for ($i = 0; $i -lt $kw.Count; $i++) { $s[$tag][$i] += $kw[$i][$t] }
  }
  $s
}

function Eintrag($summen, $daily, $j, $alt) {
  $tag = $daily.time[$j]
  $e = [ordered]@{
    d     = @($summen[$tag] | ForEach-Object { [math]::Round($_, 2) })
    sonne = [math]::Round([double]$daily.sunshine_duration[$j] / 3600, 1)
    wc    = [int]$daily.weather_code[$j]
    tmin  = [math]::Round([double]$daily.temperature_2m_min[$j], 1)
    tmax  = [math]::Round([double]$daily.temperature_2m_max[$j], 1)
    regen = [math]::Round([double]$daily.precipitation_sum[$j], 1)
  }
  if ($alt -and $alt.Contains('prog')) { $e.prog = $alt.prog }
  $e
}

# ---------- Archiv laden ----------
$archivDatei = "$PSScriptRoot/archiv.json"
$archiv = @{}
if (Test-Path $archivDatei) {
  $json = [IO.File]::ReadAllText($archivDatei, $utf8) | ConvertFrom-Json
  foreach ($p in $json.PSObject.Properties) {
    $h = [ordered]@{}
    foreach ($q in $p.Value.PSObject.Properties) { $h[$q.Name] = $q.Value }
    $archiv[$p.Name] = $h
  }
}

# ---------- Prognose und letzte Tage ----------
$daten = @($A.flaechen | ForEach-Object { Hole 'https://api.open-meteo.com/v1/forecast' $_ "&past_days=$VORTAGE&forecast_days=3" })
$kw = Leistung $daten
$h0 = $daten[0].hourly; $d0 = $daten[0].daily
$summen = Tagessummen $h0.time $kw
$heute = $d0.time[$VORTAGE]

# vergangene Tage mit dem eingetretenen Wetter nachrechnen
for ($j = 0; $j -lt $VORTAGE; $j++) {
  $archiv[$d0.time[$j]] = Eintrag $summen $d0 $j $archiv[$d0.time[$j]]
}
# Prognose für heute einmal festhalten (erster Lauf des Tages), zum späteren Vergleich
if (-not $archiv.ContainsKey($heute)) { $archiv[$heute] = [ordered]@{} }
if (-not $archiv[$heute].Contains('prog')) {
  $archiv[$heute].prog = [math]::Round(($summen[$heute] | Measure-Object -Sum).Sum, 2)
}

# ---------- fehlende ältere Tage aus historischen Daten ergänzen ----------
$start = [datetime]::ParseExact($A.archivAb, 'yyyy-MM-dd', $inv)
$ende = [datetime]::ParseExact($d0.time[0], 'yyyy-MM-dd', $inv).AddDays(-1)
$fehlt = @()
for ($t = $start; $t -le $ende; $t = $t.AddDays(1)) {
  $k = $t.ToString('yyyy-MM-dd', $inv)
  if (-not ($archiv.ContainsKey($k) -and $archiv[$k].Contains('d'))) { $fehlt += $k }
}
if ($fehlt.Count) {
  Write-Host "Ergänze $($fehlt.Count) Tage ab $($fehlt[0])"
  $hist = @($A.flaechen | ForEach-Object {
    Hole 'https://historical-forecast-api.open-meteo.com/v1/forecast' $_ "&start_date=$($fehlt[0])&end_date=$($ende.ToString('yyyy-MM-dd', $inv))"
  })
  $hs = Tagessummen $hist[0].hourly.time (Leistung $hist)
  for ($j = 0; $j -lt $hist[0].daily.time.Count; $j++) {
    $k = $hist[0].daily.time[$j]
    if ($fehlt -contains $k -and $hs.ContainsKey($k)) { $archiv[$k] = Eintrag $hs $hist[0].daily $j $archiv[$k] }
  }
}

# ---------- schreiben ----------
$zeilen = $archiv.Keys | Sort-Object | ForEach-Object { '  "' + $_ + '": ' + ($archiv[$_] | ConvertTo-Json -Compress) }
[IO.File]::WriteAllText($archivDatei, "{`n" + ($zeilen -join ",`n") + "`n}`n", $utf8)

$von = $VORTAGE * 24; $bis = $h0.time.Count - 1
$prognose = [ordered]@{
  stand  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $inv)
  anlage = $A
  zeiten = $h0.time[$von..$bis]
  kw     = @($kw | ForEach-Object { , @($_[$von..$bis] | ForEach-Object { [math]::Round($_, 3) }) })
  wolken = $h0.cloud_cover[$von..$bis]
  tage   = [ordered]@{
    time               = $d0.time[$VORTAGE..($VORTAGE + 2)]
    weather_code       = $d0.weather_code[$VORTAGE..($VORTAGE + 2)]
    sunshine_duration  = $d0.sunshine_duration[$VORTAGE..($VORTAGE + 2)]
    temperature_2m_min = $d0.temperature_2m_min[$VORTAGE..($VORTAGE + 2)]
    temperature_2m_max = $d0.temperature_2m_max[$VORTAGE..($VORTAGE + 2)]
    precipitation_sum  = $d0.precipitation_sum[$VORTAGE..($VORTAGE + 2)]
  }
}
[IO.File]::WriteAllText("$PSScriptRoot/daten.json", ($prognose | ConvertTo-Json -Depth 6 -Compress), $utf8)

$heuteKwh = ($summen[$heute] | Measure-Object -Sum).Sum
Write-Host ("Prognose heute {0}: {1:0.0} kWh, Archiv {2} Tage" -f $heute, $heuteKwh, $archiv.Count)

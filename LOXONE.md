# Loxone-Schnittstelle

Die GitHub Action schreibt jede Stunde (ca. xx:23) zwei Dateien:

- **https://reneabenthung-web.github.io/pv-ertrag/loxone.txt** – eine Zeile pro Wert (`name=wert`), für den virtuellen HTTP-Eingang
- **https://reneabenthung-web.github.io/pv-ertrag/loxone.json** – dieselben Daten als JSON

Alle Werte sind **berechnet** (Wetterprognose × Anlage × Korrektur je Dach), keine Messwerte.
Zeiten in Ortszeit (Europe/Zurich). Fehlt ein Wert, steht `nan`.

## Werte in loxone.txt

| Name | Bedeutung | Einheit |
|---|---|---|
| `stand` | Zeitpunkt der Berechnung | Text |
| `stunde` | Stunde der Berechnung (0–23) | – |
| `jetzt_kw`, `jetzt_kw_d1`, `jetzt_kw_d2` | Leistung der laufenden Stunde, gesamt / Dach 1 / Dach 2 | kW |
| `wolken_jetzt` | Bewölkung der laufenden Stunde | % |
| `heute_rest_kwh` | erwarteter Ertrag ab jetzt bis Tagesende | kWh |
| `gestern_kwh` | Ertrag gestern (mit dem eingetretenen Wetter nachgerechnet) | kWh |
| `heute_kwh`, `heute_kwh_d1`, `heute_kwh_d2` | Tagesertrag heute, gesamt / je Dach | kWh |
| `heute_peak_kw`, `heute_peak_stunde` | höchste Stundenleistung heute und deren Beginn | kW / Stunde |
| `heute_sonne_h` | Sonnenstunden heute | h |
| `kw_h00` … `kw_h23` | Leistung heute je Stunde (`kw_h10` = 10:00–11:00) | kW |
| `morgen_…` | dieselben Tageswerte für morgen | |
| `kw_m00` … `kw_m23` | Leistung morgen je Stunde | kW |
| `uebermorgen_…` | Tageswerte für übermorgen (ohne Stundenwerte) | |

## Einrichtung in Loxone Config

1. **Virtueller HTTP-Eingang** anlegen
   - URL: `https://reneabenthung-web.github.io/pv-ertrag/loxone.txt`
   - Abfragezyklus: `900` s (die Datei ändert sich nur einmal pro Stunde)
2. Darunter je Wert einen **Virtuellen HTTP-Eingang Befehl** anlegen
   - Befehlserkennung: `heute_kwh=\v` (bzw. `morgen_kwh=\v`, `kw_h13=\v`, `jetzt_kw=\v` …)
   - Bei Bedarf „Signalverhalten: Analog“ und Einheit `<v.2> kWh` setzen
3. Die Werte z. B. für Verbraucher-Freigaben nutzen: Boiler, Wallbox oder Waschmaschine einschalten, wenn
   `heute_rest_kwh` hoch ist oder `kw_h12` … `kw_h15` über einem Schwellwert liegen.

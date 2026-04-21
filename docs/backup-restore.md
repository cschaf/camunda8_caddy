# Backup & Restore

Dieses Dokument beschreibt das Backup- und Restore-System für das Camunda 8 Self-Managed Docker Compose Projekt.

## Inhalt

- [Datenquellen](#datenquellen)
- [Backup-Szenarien](#backup-szenarien)
- [Restore-Szenarien](#restore-szenarien)
- [CLI-Referenz](#cli-referenz)
- [Troubleshooting](#troubleshooting)
- [Automatisierung](#automatisierung)

## Datenquellen

Das Backup-System sichert folgende Daten:

| Datenquelle | Methode | Bemerkung |
|-------------|---------|-----------|
| Zeebe State | Volume-Dump (`orchestration.tar.gz`) | Cold-Backup (Orchestration wird gestoppt) |
| Elasticsearch | Snapshot API | FS-Repository in `./backups/elasticsearch` |
| Keycloak DB | `pg_dump -Fc` | GZIP-komprimiert (`keycloak.sql.gz`) |
| Web Modeler DB | `pg_dump -Fc` | GZIP-komprimiert (`webmodeler.sql.gz`) |
| Konfigurationen | `tar.gz` | `.env`, `connector-secrets.txt`, `Caddyfile`, `application.yaml` |

**Nicht gesichert:** `keycloak-theme` Volume (wird von Identity automatisch initialisiert).

## Backup-Szenarien

### Tägliches Backup (empfohlen)

Führe das Backup-Skript regelmäßig aus, z.B. über einen Cronjob:

```bash
./scripts/backup.sh
```

Das Skript erzeugt einen Backup-Ordner unter `backups/YYYYMMDD_HHMMSS/` und erstellt automatisch ein JSON-Manifest mit Prüfsummen.

### Testlauf (Simulation)

Um den Backup-Ablauf zu testen, ohne Daten zu verändern:

```bash
./scripts/backup.sh --test
```

### Manuelles Backup

```bash
# Linux/macOS/WSL
./scripts/backup.sh

# Windows (PowerShell 7+)
.\scripts\backup.ps1
```

## Restore-Szenarien

### In-Place Restore (gleicher Cluster)

Stellt alle Daten auf dem gleichen Host wieder her, einschließlich der Konfigurationsdateien:

```bash
./scripts/restore.sh backups/20240115_120000
```

**Achtung:** Dies überschreibt alle aktuellen Daten! Das Skript fragt zur Sicherheit nach.

### Cross-Cluster Restore

Stellt Daten auf einem anderen Cluster wieder her. Konfigurationsdateien werden **nicht** überschrieben, sondern in `restored-configs/` extrahiert:

```bash
./scripts/restore.sh --cross-cluster backups/20240115_120000
```

Voraussetzungen:
- Elasticsearch-Version im Backup muss mit `.env` übereinstimmen
- Camunda-Version im Backup muss mit `.env` übereinstimmen

### Test-Restore (Integritätsprüfung)

Prüft die Backup-Integrität ohne Daten wiederherzustellen:

```bash
./scripts/restore.sh --test backups/20240115_120000
```

### Dry-Run

Zeigt alle Schritte an, die ausgeführt würden, ohne sie tatsächlich auszuführen:

```bash
./scripts/restore.sh --dry-run backups/20240115_120000
```

### Granulares Restore

Für ein granulares Restore (z.B. nur eine Datenbank) kannst du die Skripte als Vorlage verwenden und einzelne Schritte manuell ausführen:

```bash
# Nur Keycloak DB
zcat backups/20240115_120000/keycloak.sql.gz | docker exec -i postgres pg_restore -U bn_keycloak -d bitnami_keycloak

# Nur Elasticsearch
# Snapshot-Repo registrieren und restore (siehe restore.sh)
```

## CLI-Referenz

### backup.sh / backup.ps1

| Option | Beschreibung |
|--------|-------------|
| `--test` | Simuliert den Backup-Ablauf ohne Daten zu verändern |
| `-h, --help` | Zeigt die Hilfe an |

### restore.sh / restore.ps1

| Option | Beschreibung |
|--------|-------------|
| `--force` | Überspringt alle Sicherheitsabfragen |
| `--dry-run` | Zeigt an, was gemacht würde, ohne es auszuführen |
| `--cross-cluster` | Aktiviert Cross-Cluster-Restore (keine Config-Überschreibung) |
| `--test` | Prüft die Backup-Integrität ohne Restore |
| `-h, --help` | Zeigt die Hilfe an |

### Beispiele

```bash
# Backup erstellen
./scripts/backup.sh

# Backup testen
./scripts/backup.sh --test

# Restore auf gleichem Cluster
./scripts/restore.sh backups/20240115_120000

# Restore mit automatischer Bestätigung
./scripts/restore.sh --force backups/20240115_120000

# Cross-Cluster-Restore
./scripts/restore.sh --cross-cluster backups/20240115_120000

# Dry-Run eines Restores
./scripts/restore.sh --dry-run --force backups/20240115_120000
```

## Troubleshooting

### "Another backup/restore process is already running"

Ein Lock-File (`backups/.backup.lock`) verhindert parallele Ausführungen. Falls ein vorheriger Abbruch das Lock hinterlassen hat:

```bash
rm backups/.backup.lock
```

### Elasticsearch Snapshot fehlschlägt

- Prüfe, ob Elasticsearch läuft: `curl http://localhost:9200/_cluster/health`
- Prüfe, ob das Backup-Verzeichnis existiert und beschreibbar ist: `ls -la backups/elasticsearch/`
- Prüfe die Elasticsearch-Logs: `docker compose logs elasticsearch`

### pg_restore Warnungen

`pg_restore` gibt oft Warnungen wegen bereits existierender Objekte aus. Das ist normal und beeinträchtigt den Restore nicht, solange keine Fehler auftreten.

### Orchestration startet nicht nach Restore

- Prüfe, ob das Zeebe-State-Archiv korrekt ist: `tar tzf backups/.../orchestration.tar.gz`
- Prüfe die Berechtigungen im Volume nach dem Restore

### Version mismatch bei Cross-Cluster-Restore

Stelle sicher, dass die Versionen in `.env` mit dem Backup übereinstimmen:

```bash
# Version im Backup anzeigen
cat backups/20240115_120000/manifest.json | jq '.versions'
```

### Manifest verification failed

Das Manifest enthält SHA256-Prüfsummen aller Backup-Dateien. Bei einem Fehler:
- Prüfe, ob Dateien im Backup-Ordner fehlen oder beschädigt sind
- Prüfe den verfügbaren Speicherplatz

## Automatisierung

### Cronjob für tägliche Backups

Füge folgende Zeile zu deinem Crontab hinzu (`crontab -e`):

```cron
# Tägliches Camunda-Backup um 2:00 Uhr
0 2 * * * cd /pfad/zu/camunda8_caddy && ./scripts/backup.sh >> backups/cron.log 2>&1
```

### Windows Task Scheduler (PowerShell)

Erstelle eine Aufgabe, die täglich `scripts/backup.ps1` ausführt:

```powershell
$action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-File C:\pfad\zu\scripts\backup.ps1" -WorkingDirectory "C:\pfad\zu\camunda8_caddy"
$trigger = New-ScheduledTaskTrigger -Daily -At "02:00"
Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "CamundaBackup" -Description "Tägliches Camunda 8 Backup"
```

### Backup-Aufbewahrung

Standardmäßig werden Backups älter als 7 Tage automatisch gelöscht. Das lässt sich im Skript `scripts/lib/backup-common.sh` (bzw. `.ps1`) über den Parameter `cleanup_old_backups` anpassen.

### Exit-Codes

| Code | Bedeutung |
|------|-----------|
| 0 | Erfolg |
| 1 | Fehler |
| 2 | Bereits laufend (Lock-Konflikt) |

# Betriebs- und Übergabe-Handbuch

Dieses Dokument beschreibt den **Betrieb** der Camunda-8-Self-Managed-Installation
(Docker Compose) bei diesem Kunden. Es ist **eigenständig lesbar** und enthält
alles, was für den laufenden Betrieb der Installation nötig ist. Es hat zwei
Zielgruppen:

- **Teil A** richtet sich an den **Kunden und seine Infrastruktur-Admins** —
  was wurde installiert, wie greift man zu, was muss überwacht werden, was ist
  sicherheitsrelevant.
- **Teil B** richtet sich an den **Betreiber und seine Vertretung** — geführte
  Abläufe, Wartung und ein Incident-Playbook für den Störfall.

> **Lesehinweis:** Kunde/Infra-Admin liest **Teil 0 + Teil A**.
> Betreiber/Vertretung liest **alles**, Schwerpunkt **Teil B**.

> **Plattform:** Diese Installation läuft auf **Linux**. Alle Befehle in diesem
> Handbuch sind die `.sh`-Skripte bzw. Linux-Shell-Befehle.

> **⚠️ Wichtigste Betriebsregel:** Zum **Starten und Stoppen** des Stacks wird
> **ausschließlich `scripts/start.sh` bzw. `scripts/stop.sh`** verwendet —
> niemals `docker compose up/down` direkt. Begründung siehe [B2](#b2-standard-abläufe).

---

## Inhalt

- [Teil 0 — Einstieg (für alle)](#teil-0--einstieg-für-alle)
  - [0.1 Diese Installation](#01-diese-installation)
  - [0.2 Serverumgebungen (PROD / DEV / SANDBOX)](#02-serverumgebungen-prod--dev--sandbox)
  - [0.3 Rollen und Kontakte](#03-rollen-und-kontakte)
- [Teil A — Für den Kunden und seine Infrastruktur-Admins](#teil-a--für-den-kunden-und-seine-infrastruktur-admins)
  - [A1 Was wurde installiert?](#a1-was-wurde-installiert)
  - [A2 Wie greife ich zu?](#a2-wie-greife-ich-zu)
  - [A3 Was der Server braucht (Infrastruktur-Sicht)](#a3-was-der-server-braucht-infrastruktur-sicht)
  - [A4 Sicherheit und Datenschutz](#a4-sicherheit-und-datenschutz)
  - [A5 Was muss aktiv überwacht werden?](#a5-was-muss-aktiv-überwacht-werden)
  - [A6 Backup — was der Kunde wissen muss](#a6-backup--was-der-kunde-wissen-muss)
- [Teil B — Für den Betreiber und die Vertretung](#teil-b--für-den-betreiber-und-die-vertretung)
  - [B1 Betriebsroutine](#b1-betriebsroutine)
  - [B2 Standard-Abläufe](#b2-standard-abläufe)
  - [B3 Wartung](#b3-wartung)
  - [B4 Incident-Playbook](#b4-incident-playbook)
  - [B5 Notfall-Kontakte und Eskalation](#b5-notfall-kontakte-und-eskalation)
- [Anhang](#anhang)
  - [Glossar](#glossar)
  - [Befehls-Spickzettel](#befehls-spickzettel)

---

# Teil 0 — Einstieg (für alle)

## 0.1 Diese Installation

> Diese Tabelle ist bei der Übergabe auszufüllen. Sensible Werte (Passwörter,
> Secrets) gehören **nicht** in dieses Dokument — nur der **Ablageort** wird
> genannt. Die Secrets selbst liegen ausschließlich in `.env-credentials` auf
> dem Server.

| Feld | Wert |
|------|------|
| Kunde / Standort | `<KUNDE>` |
| Hostname (`HOST` in `.env`) | `<hostname.beispiel.local>` (klein geschrieben!) |
| Server (Hostname/IP) | `<SERVER>` |
| Betriebssystem + Version | `<Linux-Distribution + Version>` |
| Docker Engine / Compose Version | `<docker --version>` / `<docker compose version>` |
| Projektpfad auf dem Server | `<z. B. /opt/camunda>` |
| Stage (`STAGE` in `.env`) | `prod` / `dev` / `test` |
| Angezeigtes Label (`DISPLAY_STAGE`) | `<optional, sonst = STAGE>` |
| TLS | self-signed (Caddy) **oder** Zertifikat `<Aussteller>`, Ablauf `<Datum>` |
| Ablage `.env-credentials` | `<Pfad>` auf dem Server, Zugriff nur Betreiber |
| Backup-Verzeichnis | `<Pfad>` (Standard: `backups/` im Projekt) |
| Off-Site-Backup-Ziel | `<Ziel / Verantwortlicher>` |
| Monitoring-Anbindung | `<keine / Nagios / Zabbix / Checkmk / ...>` |
| Camunda-Lizenz | `<Self-Managed-Lizenz vorhanden? Ablauf?>` |
| Installiert am / durch | `<Datum>` / `<Person>` |

**Eingerichtete Automatisierung (Cron):**

| Job | Zeitplan | Cron |
|-----|----------|------|
| `scripts/monitor.sh` | alle 30 Minuten | `*/30 * * * *` |
| `scripts/backup.sh` | täglich um 02:00 Uhr | `0 2 * * *` |

## 0.2 Serverumgebungen (PROD / DEV / SANDBOX)

Es gibt drei getrennte Umgebungen. Servernamen und Verbindungsweg bei der
Übergabe ausfüllen.

| Umgebung | Zweck | Servername (FQDN / IP) | Stage (`STAGE`) | Hostname (`HOST`) |
|----------|-------|------------------------|-----------------|--------------------|
| **PROD** | Produktivbetrieb | `<prod.beispiel.local>` | `prod` | `<host>` |
| **DEV** | Entwicklung / Test vor PROD | `<dev.beispiel.local>` | `dev` | `<host>` |
| **SANDBOX** | Experimente / Schulung | `<sandbox.beispiel.local>` | `test` | `<host>` |

**Verbindung herstellen (anpassen):** Der Zugriff erfolgt per SSH, ggf. erst nach
VPN-Einwahl und/oder über einen Jump-Host. Voraussetzungen (VPN, hinterlegter
SSH-Key, Berechtigung) klärt der Kunde-Infra-Admin.

```bash
# 1. (falls nötig) VPN verbinden: <VPN-Profil / Anbieter>

# 2a. Direkte SSH-Verbindung
ssh <benutzer>@<servername>

# 2b. Verbindung über Jump-Host (falls der Zielserver nicht direkt erreichbar ist)
ssh -J <benutzer>@<jump-host> <benutzer>@<servername>

# 3. Ins Projektverzeichnis wechseln (siehe „Diese Installation" → Projektpfad)
cd <Projektpfad>
```

| Umgebung | SSH-Benutzer | Zugang (Direkt / Jump-Host / VPN) | Jump-Host | Besonderheiten |
|----------|--------------|------------------------------------|-----------|----------------|
| **PROD** | `<benutzer>` | `<...>` | `<jump-host>` | `<z. B. nur 4-Augen-Zugriff>` |
| **DEV** | `<benutzer>` | `<...>` | `<jump-host>` | `<...>` |
| **SANDBOX** | `<benutzer>` | `<...>` | `<jump-host>` | `<...>` |

> **Achtung — richtige Umgebung prüfen:** Vor jedem Eingriff sicherstellen, dass
> du auf dem **richtigen** Server bist (z. B. `hostname` prüfen und `STAGE` in
> `.env` ansehen), damit Wartungs-/Restore-Aktionen nicht versehentlich auf PROD
> laufen.

## 0.3 Rollen und Kontakte

| Rolle | Person / Team | Kontakt | Zuständig für |
|-------|---------------|---------|---------------|
| Betreiber (primär) | `<NAME>` | `<KONTAKT>` | Betrieb, Wartung, Updates, Disaster Recovery |
| Betreiber (Vertretung) | `<NAME>` | `<KONTAKT>` | Vertretung im Urlaubs-/Krankheitsfall |
| Kunde — Infrastruktur-Admin | `<NAME>` | `<KONTAKT>` | Server, Netz, DNS, Firewall, OS, Disk, Zeit-Sync |
| Kunde — Fachverantwortlich | `<NAME>` | `<KONTAKT>` | Prozesse, Benutzer, fachliche Fragen |
| Camunda Support / Lizenz | Camunda | `<Support-Portal / Account>` | Produktbugs, Lizenz, Enterprise-Registry |

**Eskalationspfad (Beispiel, anpassen):**
Anwender → Kunde-Infra-Admin → Betreiber (primär) → Betreiber (Vertretung) →
Camunda Support. Reaktionszeiten: `<SLA eintragen>`.

---

# Teil A — Für den Kunden und seine Infrastruktur-Admins

## A1 Was wurde installiert?

Auf dem Server läuft eine vollständige **Camunda 8 Self-Managed**-Plattform als
Satz von Docker-Containern, die per **Docker Compose** zusammen betrieben werden.
Vereinfacht erfüllen die Komponenten folgende Aufgaben:

| Komponente | Aufgabe in einfachen Worten |
|------------|------------------------------|
| **Orchestration (Zeebe + Operate + Tasklist)** | Das Herz: führt die Geschäftsprozesse (Workflows) aus. **Operate** zeigt laufende Prozesse und Fehler, **Tasklist** ist die Oberfläche für Benutzeraufgaben. |
| **Keycloak** | Zentrales Login (Single Sign-On). Alle Benutzer melden sich hier an. |
| **Identity** | Verwaltet Rollen/Berechtigungen und richtet die Keycloak-Clients ein. |
| **Optimize** | Auswertungen, Reports und Dashboards über die Prozesse (Analytics). |
| **Web Modeler** | Web-Oberfläche zum Erstellen und Bearbeiten von Prozessmodellen (BPMN/DMN). |
| **Connectors** | Anbindung an externe Systeme (REST, Mail, KI/Agentic-AI usw.). |
| **Console** | Übersichts-Oberfläche über die Plattform. |
| **Elasticsearch** | Speichert exportierte Prozessdaten und versorgt Optimize. |
| **PostgreSQL (3×)** | Datenbanken für Keycloak/Identity, Camunda-Kerndaten und Web Modeler. |
| **Reverse Proxy (Caddy)** | Stellt alle Oberflächen verschlüsselt (HTTPS) unter `https://*.<HOST>` bereit. |
| **Mailpit** | Lokaler E-Mail-Auffang für Web-Modeler-Mails (nur Test/Diagnose). |

Die Versionen aller Komponenten sind in `.env` festgelegt (z. B. `CAMUNDA_VERSION`,
`ELASTIC_VERSION`, `CAMUNDA_OPTIMIZE_VERSION`).

> **Lizenz:** Für den produktiven Einsatz ist ein Camunda-Self-Managed-Lizenz­schlüssel
> erforderlich. Er liegt in `.env-credentials` (`CAMUNDA_LICENSE_KEY`). Status siehe
> [Diese Installation](#01-diese-installation).

## A2 Wie greife ich zu?

Alle Oberflächen sind über den Reverse Proxy unter HTTPS erreichbar. `{HOST}`
steht für den Wert von `HOST` in `.env`.

| Dienst | URL |
|--------|-----|
| Dashboard (Startseite mit Links) | `https://{HOST}` |
| Operate / Tasklist | `https://orchestration.{HOST}` |
| Identity | `https://identity.{HOST}` |
| Console | `https://console.{HOST}` |
| Optimize | `https://optimize.{HOST}` |
| Web Modeler | `https://webmodeler.{HOST}` |
| Keycloak Admin | `https://keycloak.{HOST}/auth/` |
| Admin-UI | `https://orchestration.{HOST}/admin` |

> **Zertifikatswarnung:** Ohne eigenes Zertifikat erzeugt Caddy ein
> selbstsigniertes Zertifikat — der Browser warnt. Mit einem vertrauenswürdigen
> Zertifikat (Firmen-CA oder mkcert) verschwindet die Warnung.

**Benutzer anlegen:** Neue Benutzer werden mit dem Skript `add-camunda-user.sh`
angelegt. Wichtig: Camunda 8 hat **zwei** Berechtigungssysteme (Keycloak-Login
*und* Camundas internes Autorisierungssystem) — das Skript trägt den Benutzer in
**beide** ein, sonst landet er trotz erfolgreichem Login auf einer „Forbidden"-Seite.

```bash
bash scripts/add-camunda-user.sh --username jdoe --password "changeme" \
  --email "jdoe@example.com" --first-name John --last-name Doe --role NormalUser
```

Das Startpasswort wird standardmäßig als **temporär** gesetzt — der Benutzer muss
es beim ersten Login ändern. Für Service-Accounts o. Ä. lässt sich das mit
`--permanent-password` (bzw. `-PermanentPassword` im PowerShell-Skript) abschalten.

Rollen: **`NormalUser`** = lesend in Operate/Tasklist, kann Aufgaben abschließen.
**`Admin`** = Vollzugriff auf alle Komponenten.

## A3 Was der Server braucht (Infrastruktur-Sicht)

**Dimensionierung (Baseline `prod`):** Der Stack reserviert ca. 16 GB und
limitiert bei ca. 25–27 GB RAM. Der Host braucht **mindestens 32 GB RAM** und
ca. 16 vCPU für stabilen Betrieb. Kleinere Profile (`dev`, `test`) brauchen
weniger.

**Festplatte:** Frei wachsende Docker-Volumes; am stärksten wachsen `elastic`
(Elasticsearch) und `camunda-db` (Prozesshistorie — **keine automatische
Bereinigung**, wächst monoton). Planungsrichtwert: **20–30 GB frei** für die
Docker-Volumes auch bei niedrigem Volumen, plus Platz für Backups.

**Netzwerk / Ports:** Nach außen (LAN) sind **nur Port 80 und 443** (Caddy)
freigegeben. Alle anderen Ports sind bewusst an `127.0.0.1` (loopback) gebunden
und nur lokal für Diagnose/Skripte gedacht.

**DNS / Hosts:** Die Subdomains (`keycloak.{HOST}`, `orchestration.{HOST}`, …)
müssen auf den Server zeigen. Lokal werden sie per Hosts-Datei eingetragen
(`setup-host`-Skript); für Zugriff aus dem Netz braucht es passende DNS-Einträge
(z. B. Wildcard `*.{HOST}` → Server-IP).

**Zeit-Synchronisation:** Camunda-Timer sind uhrzeitgesteuert. NTP/Zeit-Sync
muss laufen — Drift > 1 Sekunde ist betrieblich sichtbar (Timer feuern zu spät
oder doppelt).

**Kernel-Einstellungen:** `vm.max_map_count ≥ 262144` (für Elasticsearch),
ausreichend File-Descriptoren für den Docker-Daemon (≥ 65536).

## A4 Sicherheit und Datenschutz

- **Angriffsfläche minimal:** Nur 80/443 sind extern erreichbar. Insbesondere
  **Elasticsearch (9200) niemals ins LAN exponieren** — davor steht nur das
  statische `elastic`-Passwort.
- **Secrets:** Alle Zugangsdaten liegen in `.env-credentials` (nie committen).
  Diese Datei wird mit eingeschränkten Rechten erzeugt (`chmod 600`).
  `.env` enthält **keine** Secrets.
- **TLS:** Standardmäßig selbstsigniert; für Produktion ein vertrauenswürdiges
  Zertifikat hinterlegen (`FULLCHAIN_PEM`/`PRIVATEKEY_PEM` in `.env`). Ablauf
  überwachen (siehe A5).
- **Keine internen Management-Endpunkte exponieren:** `/actuator/configprops`
  darf nicht freigegeben werden (enthält Secrets im Klartext).
- **Backups enthalten Secrets im Klartext** (Keycloak-Realm, OAuth-Secrets,
  DB-Passwörter, `.env-credentials`). Zugriff auf das Backup-Verzeichnis streng
  beschränken; Off-Site-Kopien verschlüsselt ablegen. Siehe A6.

## A5 Was muss aktiv überwacht werden?

Die wichtigsten fünf Signale:

| # | Signal | Schwelle (Warn / Kritisch) | Warum |
|---|--------|----------------------------|-------|
| 1 | **Freier Plattenplatz** (Docker-Datenverzeichnis) | < 25 % / < 15 % | Unter 15 % stoppt Elasticsearch neue Shards (Low Watermark 85 %); ab 95 % werden Indizes read-only und Camunda-Schreibvorgänge schlagen fehl. |
| 2 | **Container `unhealthy`** | > 5 min / > 15 min (Kernservices > 2 min) | Ein dauerhaft ungesunder Container bedeutet ausgefallene Funktion. |
| 3 | **Elasticsearch-Cluster-Status** | `yellow` > 30 min / `red` sofort | `red` = Datenverlust-Risiko, Optimize/Operate betroffen. |
| 4 | **OOM-Kill / Exit-Code 137** | sofort kritisch | Container hat sein Speicherlimit überschritten und verliert In-Flight-State. |
| 5 | **TLS-Zertifikat-Ablauf** (nur bei eigenem Cert) | < 30 Tage / < 7 Tage | Abgelaufenes Zertifikat = alle Oberflächen nicht mehr vertrauenswürdig erreichbar. |

**Eingerichtet:** `scripts/monitor.sh` läuft per Cronjob **alle 30 Minuten** und
prüft, ob alle Container laufen und gesund sind; bei Problemen wird der Stack
automatisch über das Start-Skript wieder hochgefahren und der Vorfall in
`monitor.log` protokolliert.

## A6 Backup — was der Kunde wissen muss

- **Was wird gesichert:** Zeebe-State, Camunda-Kern-DB, Keycloak-DB,
  Web-Modeler-DB, Elasticsearch-Snapshot (Optimize) und alle Konfigurationsdateien
  — in einem zeitgestempelten Ordner unter `backups/` mit Prüfsummen-Manifest.
- **Modell:** „Cold Backup" — die Anwendungsdienste werden kurz gestoppt
  (typisch ~5–10 min Downtime), die Datendienste laufen weiter.
- **Rhythmus (eingerichtet):** `scripts/backup.sh` läuft per Cronjob **täglich um
  02:00 Uhr**. Vor jeder risikobehafteten Änderung wird zusätzlich manuell ein
  frisches Backup gezogen.
- **Off-Site:** Backups müssen zusätzlich außerhalb des Servers liegen
  (verschlüsselt). Verantwortlicher und Ziel: siehe
  [Diese Installation](#01-diese-installation).
- **Aufbewahrung:** Standard 7 Tage lokal (konfigurierbar).
- **Wichtig:** Backups enthalten Secrets im Klartext — Zugriff streng beschränken.

Manueller Backup-Befehl: `bash scripts/backup.sh`. Integrität eines Backups prüfen
ohne Wiederherstellung: `bash scripts/restore.sh --verify backups/<TIMESTAMP>`.

---

# Teil B — Für den Betreiber und die Vertretung

## B1 Betriebsroutine

Ein Großteil läuft automatisch (siehe [Eingerichtete Automatisierung](#01-diese-installation)):
`monitor.sh` alle 30 min (Health + Auto-Recovery), `backup.sh` täglich um 02:00.
Die folgenden Punkte ergänzen die manuelle Sichtkontrolle.

**Täglich**

- [ ] Health-Überblick: `docker compose ... ps` (siehe Spickzettel) — alle
      Container `running`/`healthy`?
- [ ] Backup-Lauf der Nacht erfolgreich? (Log unter `backups/`, kein
      `*_FAILED`-Ordner)
- [ ] Freier Plattenplatz im grünen Bereich? (`docker system df -v`)
- [ ] `monitor.log` auf wiederholte Auto-Recoveries durchsehen.
- [ ] Auffälligkeiten in den Logs? (`... logs --since=24h | grep -E 'ERROR|Exception|OOMKilled'`)

**Wöchentlich**

- [ ] Backup-Integrität prüfen (`bash scripts/restore.sh --verify backups/<ts>`).
- [ ] Image-Updates verfügbar? (`bash scripts/registry-info.sh`)
- [ ] Zertifikatsablauf prüfen (falls eigenes Cert).

## B2 Standard-Abläufe

> **⚠️ Start/Stop nur über die Skripte.** Zum Hoch- und Herunterfahren des Stacks
> wird **ausschließlich `scripts/start.sh` bzw. `scripts/stop.sh`** verwendet —
> **niemals `docker compose up -d` / `down` direkt.** Die Skripte lesen `STAGE`
> aus `.env`, legen `stages/<stage>.yaml` über die Basis und übergeben **beide**
> Env-Dateien (`--env-file .env --env-file .env-credentials`). Ohne das fehlen
> Heap-Einstellungen und Secrets — Services werden OOM-gekillt (Exit 137).

**Stack starten / stoppen**

```bash
bash scripts/start.sh
bash scripts/stop.sh
```

> Der erste Start dauert 5–10 min (Bootstrap: Keycloak-Realm, OIDC-Clients,
> DB-Migrationen, ES-Index-Templates). Spätere Starts: 1–2 min. Ein erneut
> langsamer Start deutet auf einen gelöschten Volume hin (`docker volume ls`
> prüfen).

**Logs ansehen** (beide `--env-file`-Flags sind nötig, sonst scheitert die
Interpolation aus `.env-credentials`):

```bash
docker compose --env-file .env --env-file .env-credentials \
  -f docker-compose.yaml -f stages/<stage>.yaml logs -f <service>
```

**Nach Server-Reboot wiederherstellen:** `restart: unless-stopped` +
`autoheal`-Sidecar bringen die Container i. d. R. selbst hoch, und `monitor.sh`
(alle 30 min) fährt fehlende Dienste über das Start-Skript wieder hoch. Manuell
lassen sich fehlende/gestoppte Dienste mit `bash scripts/ensure-stack.sh`
nachstarten (startet nur die fehlenden Dienste).

**Benutzer anlegen:** siehe [A2](#a2-wie-greife-ich-zu).

**Hostname ändern:**

1. `HOST` in `.env` setzen (zwingend **klein** geschrieben).
2. `bash scripts/setup-host.sh` ausführen — aktualisiert Caddyfile und Hosts-Datei.
3. Stack mit `bash scripts/start.sh` neu starten.
4. Bei bereits bestehenden Keycloak-Daten und „Invalid redirect_uri"-Fehlern:
   Stack stoppen, Keycloak/Identity-Datenbank-Volumes entfernen, neu starten.

## B3 Wartung

> **Pflicht-Gate:** Vor **jeder** risikobehafteten Änderung (Image-Upgrade,
> Config-Änderung, Schema-Migration) ein frisches Backup ziehen
> (`bash scripts/backup.sh`).

| Aufgabe | Vorgehen |
|---------|----------|
| Minor-/Patch-Update | Neue Versionen in `.env` eintragen, `docker compose pull`, Backup, `bash scripts/start.sh`, anschließend Health verifizieren. |
| Major-Upgrade | Datei-für-Datei-Migration und Config-Diffs gemäß Camunda-Migrationsleitfaden; vorher Backup, danach Verifikation. |
| Optimize-Schema-Upgrade | Nach Optimize-Versionsbump nötig; läuft im Start-Skript automatisch, sonst manuell `bash scripts/optimize-upgrade.sh`. |
| Verfügbare Image-Versionen prüfen | `bash scripts/registry-info.sh` (fragt die Camunda-Registry ab). |

## B4 Incident-Playbook

Aufbau je Szenario: **Symptom → schnelle Diagnose → Maßnahme → wann eskalieren.**

### I1 — Eine Oberfläche lädt nicht / 502 / „kann nicht verbinden"

- **Diagnose:** Läuft Caddy? `docker ps` → `reverse-proxy` gesund?
  End-to-End: `curl -fskI "https://{HOST}/" | head -1`. Backend des betroffenen
  Dienstes gesund? (`docker inspect --format='{{.State.Health.Status}}' <service>`)
- **Maßnahme:** Ist nur **ein** Backend `unhealthy` → siehe I3. Ist **Caddy**
  betroffen → alle UIs offline, Caddy-Container neu starten; letzte
  Caddyfile-Änderung prüfen/rückgängig machen (`docker compose ... logs reverse-proxy`).
- **Eskalation:** Wenn Caddy nicht startet und Caddyfile/Cert korrekt sind →
  Betreiber/Camunda.

### I2 — Login schlägt fehl / „Invalid redirect_uri" / SSO kaputt

- **Diagnose:** OIDC-Discovery muss als JSON antworten:
  `curl -fsk "https://keycloak.{HOST}/auth/realms/camunda-platform/.well-known/openid-configuration" | head -c 200`.
  Liefert das nicht-200/nicht-JSON, ist **jedes** Login betroffen.
- **Maßnahme:** Keycloak-Container/Health prüfen. `Invalid redirect_uri` nach
  einer `HOST`-Änderung → `HOST` muss **klein** sein; ggf. Keycloak/Identity-Volumes
  entfernen und neu starten (siehe B2 „Hostname ändern").
- **Eskalation:** Wenn Keycloak gesund ist, aber Tokens abgelehnt werden →
  Betreiber (Client-/Issuer-Konfiguration).

### I3 — Container `unhealthy` oder Restart-Loop

- **Diagnose:**
  `docker inspect <c> --format '{{.Name}} restarts={{.RestartCount}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}'`
- **Exit-Code-Crib:** `0` sauberer Stop · `1` App-Crash (Logs lesen) ·
  **`137` SIGKILL → fast immer OOM** (`OOMKilled=true`) · `143` SIGTERM (geplant).
- **Maßnahme:** Bei `137`/OOM → Speicherlimit der Stage zu klein oder Last zu
  hoch; Logs und `docker stats` prüfen. Wiederholte autoheal-Restarts desselben
  Containers in Minuten → Ursache in dessen Logs suchen, nicht in autoheal.
- **Eskalation:** Wiederkehrende OOMs an Kernservices → Betreiber (Stage-Sizing).

### I4 — Platte voll / Elasticsearch read-only

- **Diagnose:** `docker system df -v`; ES-Status
  `curl -u "elastic:$ELASTIC_PASSWORD" http://127.0.0.1:9200/_cluster/health`.
- **Maßnahme:** Platz schaffen (alte Backups, ungenutzte Images:
  `docker image prune`). Watermarks: 85 % Low, 95 % Flood (read-only). Nach dem
  Aufräumen erholt sich ES; ggf. read-only-Block manuell aufheben. Retention-/
  ILM-Änderungen wirken **nur auf neue Indizes**.
- **Eskalation:** Wenn Platte strukturell zu klein → Kunde-Infra-Admin
  (Disk erweitern).

### I5 — Elasticsearch-Cluster `yellow`/`red`

- **Diagnose:** `_cluster/health`; bei nicht zugewiesenen Shards
  `_cluster/allocation/explain`.
- **Maßnahme:** Häufig Folge von Plattenmangel (→ I4) oder ES-Neustart. `yellow`
  ist bei Single-Node oft normal (keine Replikate). `red` = fehlende Primär-Shards
  → Logs prüfen, ggf. aus Backup restoren.
- **Eskalation:** `red` mit Datenverlust-Verdacht → Betreiber + Disaster Recovery
  (I7).

### I6 — Web Modeler langsam direkt nach Restore (~20–30 s)

- **Ursache:** `pg_restore` stellt keine Planner-Statistiken wieder her; bis
  Autovacuum `ANALYZE` ausführt, sind Queries langsam. **Kein Fehler.**
- **Maßnahme:** Die Restore-Skripte führen `ANALYZE` bereits automatisch aus;
  bei manuellem `pg_restore` `ANALYZE` nachziehen. Verschwindet nach ~30 s von
  selbst.

### I7 — Disaster Recovery (Totalausfall / Datenkorruption)

1. Aktuelles Backup wählen (oder das letzte vor dem Schaden).
2. Restore ausführen (destruktiv, legt vorher automatisch ein Rollback-Backup an):
   ```bash
   bash scripts/restore.sh backups/<TIMESTAMP>
   ```
3. Nach dem Restore Health prüfen; bei Bedarf Rollback mit dem im Log genannten
   `pre-restore`-Backup.
- **Eskalation:** Bei Unsicherheit über Datenkonsistenz **vor** dem destruktiven
  Restore Betreiber hinzuziehen.

## B5 Notfall-Kontakte und Eskalation

**Vor der Eskalation immer sammeln:**

- Betroffener Dienst + Symptom + Zeitpunkt
- `docker compose ... ps` (Health aller Container)
- Relevante Logs: `docker compose ... logs --since=30m <service>`
- Exit-/OOM-Status des betroffenen Containers (siehe I3)
- Bei ES-Problemen: `_cluster/health`-Ausgabe

**Wann eskalieren:**

- **Kunde-Infra-Admin:** Disk/Server/Netz/DNS/Zeit-Sync, Hardware.
- **Betreiber (Vertretung → primär):** Container-/Config-/Restore-Probleme,
  alles aus dem Playbook, das nicht in wenigen Minuten lösbar ist.
- **Camunda Support:** vermuteter Produktbug, Lizenzfragen, Registry-Zugang.

Kontakte: siehe [Rollen und Kontakte](#03-rollen-und-kontakte).

---

# Anhang

## Glossar

| Begriff | Bedeutung |
|---------|-----------|
| **Zeebe** | Die Workflow-Engine im Kern von Camunda 8 (führt BPMN-Prozesse aus). |
| **Operate** | Oberfläche zur Überwachung laufender Prozessinstanzen und Fehler (Incidents). |
| **Tasklist** | Oberfläche, in der Benutzer ihre Aufgaben (User Tasks) bearbeiten. |
| **Optimize** | Analytics/Reporting über Prozessdaten. |
| **Web Modeler** | Web-Editor für BPMN-/DMN-Modelle. |
| **Connectors** | Bausteine zur Anbindung externer Systeme (REST, Mail, KI …). |
| **Console** | Übersichts-Oberfläche der Plattform. |
| **Keycloak** | Zentrales Login-/Identity-System (Single Sign-On). |
| **Identity** | Camunda-Komponente, die Rollen und Keycloak-Clients verwaltet. |
| **OIDC** | OpenID Connect — das Login-Protokoll zwischen Diensten und Keycloak. |
| **Elasticsearch** | Such-/Analysedatenbank; speichert exportierte Prozessdaten für Optimize. |
| **Caddy / Reverse Proxy** | Stellt alle Dienste verschlüsselt unter `https://*.{HOST}` bereit. |
| **ILM / Retention** | Aufbewahrungsregeln in Elasticsearch (wirken nur auf neue Indizes). |
| **Stage** | Ressourcenprofil (`prod`/`dev`/`test`) aus `.env` → `stages/<stage>.yaml`. |
| **autoheal** | Sidecar, der ungesunde Container automatisch neu startet. |
| **Cold Backup** | Backup mit kurzem Stopp der Anwendungsdienste für konsistente Daten. |

## Befehls-Spickzettel

`<stage>` = Wert von `STAGE` in `.env`.

| Zweck | Befehl |
|-------|--------|
| **Stack starten** | `bash scripts/start.sh` |
| **Stack stoppen** | `bash scripts/stop.sh` |
| Status / Health | `docker compose --env-file .env --env-file .env-credentials -f docker-compose.yaml -f stages/<stage>.yaml ps` |
| Logs folgen | `docker compose --env-file .env --env-file .env-credentials -f docker-compose.yaml -f stages/<stage>.yaml logs -f <service>` |
| Ungesunde Container | `docker ps --filter health=unhealthy` |
| Restart-/OOM-Status | `docker inspect <c> --format '{{.RestartCount}} {{.State.ExitCode}} {{.State.OOMKilled}}'` |
| Plattennutzung | `docker system df -v` |
| Live-Ressourcen | `docker stats --no-stream` |
| Fehlende Dienste hochfahren | `bash scripts/ensure-stack.sh` |
| Backup (manuell) | `bash scripts/backup.sh` |
| Backup-Integrität prüfen | `bash scripts/restore.sh --verify backups/<ts>` |
| Restore (destruktiv) | `bash scripts/restore.sh backups/<ts>` |
| Benutzer anlegen | `bash scripts/add-camunda-user.sh ...` |
| Image-Versionen | `bash scripts/registry-info.sh` |
| ES-Cluster-Status | `curl -u "elastic:$ELASTIC_PASSWORD" http://127.0.0.1:9200/_cluster/health` |
| OIDC-Discovery | `curl -fsk "https://keycloak.{HOST}/auth/realms/camunda-platform/.well-known/openid-configuration"` |

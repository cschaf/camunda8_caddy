# IT-Infrastruktur-Anforderungen

**Camunda 8.9 Cluster & BBC Connectors (PoC)** · *TECHNISCHE DOKUMENTATION* · **best-blu consulting with energy GmbH**

| | |
|---|---|
| **Kunde** | Kundenunternehmen |
| **Version** | 1.1 |
| **Status** | Entwurf für Kunden-IT |
| **Datum** | projektbezogen |
| **Ansprechpartner** | Christian Schaf · <c.schaf@best-blu.de> |

---

## Inhaltsverzeichnis

1. [Zweck dieses Dokuments](#1-zweck-dieses-dokuments)
2. [Überblick: Was wird aufgebaut?](#2-überblick-was-wird-aufgebaut)
3. [Benötigte Infrastruktur](#3-benötigte-infrastruktur)
4. [Ressourcen-Dimensionierung](#4-ressourcen-dimensionierung)
5. [Netzwerk und Firewall-Freigaben](#5-netzwerk-und-firewall-freigaben)
6. [Zertifikate und Truststore](#6-zertifikate-und-truststore)
7. [Zugänge und Konten](#7-zugänge-und-konten)
8. [Betrieb und Monitoring](#8-betrieb-und-monitoring)
9. [Freigaben-Checkliste (Kunden-IT)](#9-freigaben-checkliste-kunden-it)
10. [Ablauf und Meilensteine (PoC)](#10-ablauf-und-meilensteine-poc)
11. [Ansprechpartner](#11-ansprechpartner)
12. [Offene Punkte und Annahmen](#12-offene-punkte-und-annahmen)
13. [Anhang A – Subdomains](#anhang-a--subdomains-des-camunda-clusters)
14. [Anhang B – Konfiguration](#anhang-b--konfiguration-bbc-connectors-beispielwerte)

---

## 1. Zweck dieses Dokuments

Dieses Dokument fasst für die IT des Kunden zusammen, welche **Hardware,
Netzwerk-Freigaben, Zugänge und Betriebsvoraussetzungen** benötigt werden, um
im Rahmen eines **Proof of Concept (PoC)** zu betreiben:

1. ein **Camunda 8.9 Self-Managed-Cluster** mit dem **PROD-Ressourcenprofil**
   (Abschnitte 3.1, 4, 5.1–5.2),
2. einen **Server/VM für die selbstimplementierten BBC Connectors** (Job Worker,
   Abschnitte 3.2, 5.3–5.5),
3. einen **Administrations-Laptop mit VPN** für Aufbau, Betrieb und Wartung
   (Abschnitt 3.3).

Wichtig zu verstehen:

- Es werden **zwei Server/VM** benötigt – **nicht nur einer**: ein
  **Cluster-Server** für die Camunda-Plattform und ein **Connector-Server** für
  die BBC Connectors. Zusätzlich wird ein **Arbeitsplatz-Laptop
  (Administrationsrechner) mit VPN-Zugang** benötigt.
- **Begriffsklärung:** Die **BBC Connectors** sind eine **eigene Entwicklung**
  (Spring Boot 3 / Java 21 / Zeebe Job Worker).
- **„PROD-Profil"** bedeutet hier: das produktionsnahe **Ressourcenprofil** der
  Container (CPU-/RAM-Limits). Es ist ein PoC – kein produktiver Dauerbetrieb
  mit SLA. Betriebsrelevant wird das Setup trotzdem betrieben (Monitoring,
  Backups), siehe Abschnitt 8.
- Beide Server laufen als **Docker-Hosts** (Docker Engine + Docker Compose,
  Single-Node-Setup); die Camunda-Plattform besteht aus einem Satz
  Container-Komponenten, jeder BBC Connector ist ein eigener Container.

---

## 2. Überblick: Was wird aufgebaut?

### 2.1 Infrastruktur im Überblick

| Komponente | Host | Zweck |
|------------|------|-------|
| **Cluster-Server** | 1× Linux-VM (16 vCPU / 32 GB / ≥ 100 GB SSD) | Camunda-8.9-Plattform (alle Cluster-Komponenten) |
| **Connector-Server** | 1× Linux-VM (8 vCPU / 16 GB / ≥ 50 GB SSD) | 5–10 BBC Connectors (Job Worker) als Docker-Container |
| **Administrations-Laptop** | 1× Windows 10/11 mit VPN | Administration beider Server + Browser-Zugriff auf alle Oberflächen |

### 2.2 Camunda-Cluster

Eine vollständige Camunda-8.9-Plattform als Container-Stack. Der Stack besteht
aus diesen Komponenten (Versionen aus `.env`):

| Komponente | Version | Aufgabe |
|-----------|---------|---------|
| Orchestration (Zeebe + Operate + Tasklist) | 8.9.6 | Prozess-Engine (Zeebe), Betriebs-UI (Operate), Aufgaben-UI (Tasklist) |
| Optimize | 8.9.6 | Reports & Dashboards (Analytics) |
| Identity | 8.9.4 | Rollen-/Rechteverwaltung, richtet OIDC-Clients ein |
| Keycloak | 26.3.2 | Zentrales Login (Single Sign-On, OIDC) |
| Elasticsearch | 8.19.11 | Datenbasis für Optimize |
| Web Modeler | 8.9.4 | Web-UI zum Modellieren von Prozessen (BPMN/DMN) |
| Console | 8.9.44 | Übersichts-/Management-UI |
| PostgreSQL (3×) | 15 | Datenbanken für Identity/Keycloak, Camunda-Kerndaten, Web Modeler |
| Reverse Proxy (Caddy) | 2.11.2 | HTTPS-Zugang zu allen UIs unter `https://*.<HOST>` |
| Mailpit | 1.21.8 | Lokaler E-Mail-Auffang (nur Test/Diagnose, keine Zustellung) |

Alle Oberflächen sind über HTTPS-Subdomains erreichbar, z. B.
`https://orchestration.camunda.kunde.local`,
`https://optimize.camunda.kunde.local`. Ein Dashboard unter
`https://camunda.kunde.local` verlinkt alle Dienste.

### 2.3 BBC Connectors

Die **BBC Connectors** sind eine Sammlung von Camunda-8-Konnektoren, die von
der BBC entwickelt wurden und stetig erweitert werden (Spring Boot 3 / Java 21 /
Zeebe Job Worker). Weitere Connectors können im Laufe des PoC hinzukommen; die
in diesem Dokument beschriebenen Anforderungen gelten dafür unverändert. Jeder
Connector ist ein eigener Docker-Container, der als **Job Worker** Aufgaben
(Service Tasks) aus Camunda-8-Prozessen ausführt und dabei externe Systeme
(Jira, SMTP, Webex, UiPath, Netzwerkfreigaben usw.) ansteuert.

Im PoC werden **5–10 dieser Connectors** parallel auf dem Connector-Server
betrieben.

> **Grundprinzip für die IT:** Die Connectors arbeiten im **Pull-Modell** – sie
> halten selbst eine **ausgehende** Verbindung zur Camunda-8-Plattform und
> warten auf Jobs. Mit Ausnahme von Webex- und UiPath-Connector (siehe 5.5)
> sind **keine eingehenden Verbindungen** zum Connector-Server nötig.

---

## 3. Benötigte Infrastruktur

### 3.1 Cluster-Server (Camunda 8.9)

| Anforderung | Wert | Begründung |
|-------------|------|------------|
| **Betriebssystem** | Linux (z. B. Ubuntu 22.04/24.04 LTS, RHEL 9/AlmaLinux 9) | Docker Engine + Docker Compose |
| **CPU** | **16 vCPU** (Empfehlung), mindestens 8 | Summe der Container-CPU-Limits ≈ 15,5 Kerne (Limits sind Deckel, nicht Dauerlast) |
| **Arbeitsspeicher** | **32 GB RAM** (Minimum) | Summe der Speicher-Limits ≈ 28 GB; ohne OS-Overhead drohen sonst OOM-Kills |
| **Festplatte** | **≥ 100 GB SSD**, empfohlen 200 GB (frei wachsend) | Image-Download (~10–15 GB) + Docker-Volumes (Daten, Logs, Backups) |
| **Docker** | Docker Engine ≥ 24 + Compose-Plugin | Laufzeitumgebung des gesamten Stacks |
| **Root-/sudo-Zugriff** | Benutzer mit `docker`-Gruppe oder sudo | Skripte, Backups, Wartung |
| **NTP / Zeitsync** | aktiviert, Drift < 1 s | Zeebe-Timer sind uhrzeitgesteuert |
| **Kernel-Parameter** | `vm.max_map_count ≥ 262144` | Pflicht für Elasticsearch |
| **SSH-Zugang** | Port 22 (idealerweise nur über VPN/Jump-Host) | Administration aus der Ferne |

**Hinweis zur Festplatte:** Es gibt **keine automatische Bereinigung** der
Prozesshistorie im PoC-Profil; das Datenvolumen wächst mit der Nutzung. Auch bei
niedrigem Prozessvolumen sollten **20–30 GB freier Platz** für die Docker-
Volumes eingeplant werden, **zusätzlich** zu einem separaten Backup-Ziel
(siehe 8.1).

**Netzwerk-Zugriff auf den Server:** Der Server muss für den
Administrationsrechner erreichbar sein – mindestens **HTTPS (443)** für die
Oberflächen und **SSH (22)** für die Administration, typischerweise **über VPN**.

### 3.2 Connector-Server (BBC Connectors)

| Anforderung | Wert | Begründung |
|-------------|------|------------|
| **CPU** | **8 vCPU** (Empfehlung), mindestens 4 | 1 Container = 1 JVM (Spring Boot + Zeebe SDK); ~0,5–1 vCPU je Connector |
| **Arbeitsspeicher** | **16 GB RAM** (Empfehlung), mindestens 8 | ~0,75–1 GB je Connector; zzgl. Docker-Overhead + nginx |
| **Festplatte** | **≥ 50 GB** (SSD empfohlen) | Images (~200–400 MB je Connector), Logs, Backups |
| **Netzwerk** | 100 Mbit/s oder besser, stabiler Uplink | Long-Polling-Verbindung zu Camunda + API-Aufrufe |
| **Betriebssystem** | Linux (z. B. Ubuntu 22.04/24.04 LTS, RHEL 9) | Docker Engine + Docker Compose |
| **Container-Runtime** | **Docker Engine 24+** mit **Compose v2** (`docker compose`-Plugin) | Laufzeitumgebung der Connectors |
| **Laufzeit im Container** | Alpine Linux + jlink-JRE (Java 21) – **kein Java auf dem Host nötig** | Images werden fertig gebaut geliefert |
| **Java auf dem Host** | Nur erforderlich, wenn JARs direkt per `java -jar` statt Docker gestartet werden (dann **JDK 21**) | Fallback-Betrieb |
| **Zeit-Synchronisation** | NTP erforderlich | JWT/OAuth-Token und Zeebe-Verbindung sind zeitkritisch |
| **SSH-Zugang** | Port 22 (idealerweise nur über VPN/Jump-Host) | Administration aus der Ferne |

**Skalierungsfaktor:** **~1 vCPU und 1 GB RAM je Connector** als Faustformel.
Bei 5 Connectors genügen **4 vCPU / 8 GB RAM**; die Tabelle gilt für
10 Connectors.

**Gelieferte Software / Artefakte:** Die Images werden **fertig gebaut**
geliefert und können als `.tar`-Archive offline auf den Server übertragen
werden (`docker-connector-manager.sh`):

| Artefakt | Beschreibung |
|----------|--------------|
| Docker-Images als `.tar` | `<registry>/<connector>:<version>` → `<connector>_latest.tar` (Registry-Adresse wird bei Auslieferung mitgeteilt) |
| `docker-compose.yaml` | Startet alle Connectors, je 1 Service + optional nginx |
| `.env` / `.env-credentials` | Konfiguration (siehe Anhang B) |
| `config/<connector>/application.yaml` | System-Konfiguration je Connector (Hosts, Zugangsdaten) |
| `config/<connector>/valid-jwt.txt` | Optionale JWT-Tokens für REST-Schnittstellen |
| `certs/` | Zertifikate für den Java-Truststore (Abschnitt 6) |
| `docker-connector-manager.sh` | Start/Stop/Refresh der Connectors |
| `monitoring.sh` | Selbstheilung / Neustart bei Ausfall (Cron, Abschnitt 8.2) |

### 3.3 Administrations-Laptop mit VPN

Für Aufbau, Betrieb und Wartung des Clusters **und** des Connector-Servers wird
**ein dedizierter Arbeitsplatz-Laptop** benötigt. Der Server allein genügt
nicht, weil:

- **SSH-Administration:** Start/Stop, Konfiguration, Backups, Restore und
  Monitoring laufen über Skripte, die vom Laptop per SSH auf den Servern
  ausgeführt werden (`scripts/start.sh`, `backup.sh`, `monitor.sh`,
  `generate-secrets.sh`, `add-camunda-user.sh`, `docker-connector-manager.sh` …).
- **Browser-Zugriff:** Alle Camunda-Oberflächen (Operate, Tasklist, Optimize,
  Web Modeler, Keycloak-Admin, Console) werden im Browser des Laptops bedient.
- **Hosts-/DNS-Auflösung:** Die Subdomains (`keycloak.<HOST>`,
  `orchestration.<HOST>`, …) müssen auf dem Laptop auf die Cluster-Server-IP
  zeigen – per DNS-Eintrag oder Hosts-Datei (Skript `scripts/setup-host.sh`).
- **Zertifikatsvertrauen:** Wird kein Firmen-Zertifikat genutzt, muss das
  selbstsignierte TLS-Zertifikat einmalig im Browser vertrauenswürdig gemacht
  werden (Ausnahme auf dem Laptop).
- **Diagnose:** Loopback-Ports des Cluster-Servers (z. B. Elasticsearch 9200)
  sind bewusst nur lokal gebunden und werden bei Bedarf per **SSH-Tunnel** vom
  Laptop aus genutzt.

| Anforderung | Wert | Begründung |
|-------------|------|------------|
| **Betriebssystem** | Windows 10/11 | Skripte existieren für Bash **und** PowerShell |
| **VPN-Zugang** | Zugriff auf Kundennetz / beide Server (443 + 22) | Voraussetzung für jede Administration |
| **Software** | SSH-Client (OpenSSH), Git (auf Windows: Git Bash), Browser (Chrome/Edge/Firefox), optional Docker CLI | Skripte, Tunneling, UI-Zugriff |
| **Lokale Admin-Rechte** | Schreibrechte auf die Hosts-Datei, Zertifikats-Trust | `setup-host` ändert die Hosts-Datei (auf Windows mit Admin-Rechten) |
| **Kein Docker nötig** | – | Docker läuft nur auf den Servern |

> **Empfehlung:** Der Laptop sollte von **einer Person** der betreuenden Seite
> (Betreiber/Implementierung) fest zugeordnet werden und nicht geteilt werden –
> er enthält SSH-Schlüssel und ggf. Zugangsdaten zum Cluster.

---

## 4. Ressourcen-Dimensionierung

### 4.1 Camunda-Cluster (PROD-Profil)

Container-Limits laut `stages/prod.yaml` (Summen: **~15,5 CPU-Kerne**,
**~28 GB RAM** als Limit-Deckel):

| Service | CPU-Limit | RAM-Limit | RAM-Reservierung | JVM-Heap |
|---------|-----------|-----------|------------------|----------|
| Orchestration (Zeebe/Operate/Tasklist) | 4,0 | 8192 MB | 4096 MB | 4500 MB |
| Elasticsearch | 2,0 | 8192 MB | 4096 MB | – (via ES_ENV) |
| Optimize | 1,5 | 3072 MB | 1536 MB | 2304 MB |
| Keycloak | 1,5 | 2048 MB | 512 MB | – |
| camunda-db (PostgreSQL) | 1,0 | 1536 MB | 768 MB | – |
| Identity | 1,0 | 1024 MB | 256 MB | 768 MB |
| Web Modeler REST-API | 1,0 | 1024 MB | 512 MB | 768 MB |
| postgres (Identity) | 1,0 | 1024 MB | 512 MB | – |
| Console | 0,5 | 1024 MB | 512 MB | – |
| web-modeler-db (PostgreSQL) | 0,5 | 512 MB | 256 MB | – |
| Web Modeler WebSockets | 0,5 | 256 MB | 64 MB | – |
| Reverse Proxy (Caddy) | 0,5 | 256 MB | 64 MB | – |
| Mailpit | 0,25 | 128 MB | 32 MB | – |
| camunda-data-init | 0,25 | 128 MB | 32 MB | – |

**Resultierende Host-Empfehlung (Cluster-Server):**

| | Minimum | Empfehlung |
|-|---------|------------|
| CPU | 8 vCPU | **16 vCPU** |
| RAM | 32 GB | 32–64 GB |
| SSD | 100 GB | **200 GB** |

### 4.2 Connector-Server (BBC Connectors)

| | Minimum | Empfehlung (10 Connectors) |
|-|---------|----------------------------|
| CPU | 4 vCPU | **8 vCPU** |
| RAM | 8 GB | **16 GB** |
| SSD | 50 GB | **50 GB+** |

Faustformel: **~1 vCPU und 1 GB RAM je Connector** plus Docker-Overhead und
nginx (nur bei Webex/UiPath).

---

## 5. Netzwerk und Firewall-Freigaben

### 5.1 Cluster-Server – eingehend

| Port | Protokoll | Zweck | Freigabe |
|------|-----------|-------|----------|
| 443 | TCP | HTTPS – alle Camunda-Oberflächen, Zeebe-Gateway (gRPC über TLS/h2c), Web Modeler WebSockets | **erforderlich** |
| 80 | TCP | HTTP-Redirect auf HTTPS (Caddy) | empfohlen |
| 22 | TCP | SSH-Administration (idealerweise nur via VPN) | **erforderlich** |
| 26500, 8088, 9200, 9600, … | – | Loopback-Diagnose-Ports – **nicht** nach außen freigeben | **nicht öffnen** |

> Alle Dienste außerhalb von Caddy sind an `127.0.0.1` gebunden und nur lokal
> auf dem Server nutzbar (Diagnose, Skripte). Insbesondere **Elasticsearch
> (9200) niemals ins Netzwerk exponieren** – davor steht nur ein statisches
> Passwort.

### 5.2 Cluster-Server – ausgehend

Für Image-Downloads beim ersten Start und bei Updates:

| Ziel | Port | Zweck |
|------|------|-------|
| `registry-1.docker.io` / `docker.io` | 443 (HTTPS) | Camunda-Plattform-, Keycloak-, Postgres-, Mailpit- und Caddy-Images |
| `docker.elastic.co` | 443 (HTTPS) | Elasticsearch-Image |
| `registry.camunda.cloud` | 443 (HTTPS) | Camunda-Enterprise-Images (Console, Web Modeler EE) + Registry-Abfrage per Skript |
| NTP-Server | 123 (UDP) | Zeitsynchronisation |

### 5.3 Connector-Server – Verbindung zur Camunda-Plattform (ausgehend, zwingend)

**Für alle BBC Connectors:**

| Zweck | Host / URL | Port | Protokoll |
|-------|-----------|------|-----------|
| Zeebe Job API (gRPC) | `https://zeebe.camunda.kunde.local` | **443** | HTTPS (gRPC über TLS) |
| Camunda REST API (Operate/Tasklist) | `https://orchestration.camunda.kunde.local` | **443** | HTTPS |
| OIDC Token-Endpunkt | `https://keycloak.camunda.kunde.local/auth/realms/camunda-platform/protocol/openid-connect/token` | **443** | HTTPS (POST) |

> `camunda.kunde.local` ist ein kundenspezifischer Platzhalter und kann vor der
> Einrichtung angepasst werden. Die Verbindung ist **ausschließlich ausgehend**
> vom Connector-Server zum Cluster-Server.

### 5.4 Connector-Server – externe Systeme (ausgehend, je Connector)

**Nur die tatsächlich im PoC eingesetzten Connectors benötigen eine Freigabe!**

| Connector | Externes System | Host / Endpunkte (ausgehend) | Port |
|-----------|-----------------|------------------------------|------|
| `jira-connector` | Atlassian Jira | `<jira-host>` (REST API `/rest/api/2`) | 443 |
| `confluence-connector` | Atlassian Confluence | `<confluence-host>` (REST API `/rest/api/`) | 443 |
| `smtp-connector` | SMTP-Mailserver | `<smtp-host>` | **25 / 465 / 587** |
| `webex-connector` | Cisco Webex | `webexapis.com` (+ eingehend, siehe 5.5) | 443 |
| `uipath-connector` | UiPath | `cloud.uipath.com` (+ eingehend, siehe 5.5) | 443 |
| `network-file-connector` | Netzlaufwerke (SMB) | `<smb-host>` (Netzfreigabe) | **445** (ggf. 139) |
| `camunda-utils-connector` | Camunda-Plattform | siehe 5.3 | 443 |

> **Empfehlung:** Für den PoC die Freigaben **erst für die geplanten
> Connectors** freischalten. `<...>`-Werte werden beim Onboarding des
> jeweiligen Systems ergänzt.
>
> **Accounts & Onboarding-Daten:** Werden diese Connectors im PoC eingesetzt,
> müssen zusätzlich zur Firewall-Freigabe auch die **Accounts und Daten** je
> System bereitgestellt werden – Details siehe Abschnitt 7.3.

### 5.5 Connector-Server – eingehend (nur Webex/UiPath)

Diese beiden Connectors besitzen einen REST-Controller für Callbacks/Webhooks;
ein **nginx** bündelt den Host-Port:

| Port (Host) | Connector | Richtung | Erforderlich von |
|-------------|-----------|----------|------------------|
| **1337** | `webex-connector` | eingehend | Webex-Cloud (Webhook-Callbacks, Adaptive Cards), Camunda REST |
| **1338** | `uipath-connector` | eingehend | UiPath-Cloud (Callbacks/Trigger), Camunda REST |

> Nur freigeben, wenn diese Connectors im PoC eingesetzt werden. Optional:
> Reverse-Proxy (FQDN) statt direkter IP + Port. Alle übrigen Connectors
> brauchen **keine** eingehende Freigabe.

### 5.6 DNS und Proxy

**Cluster-Subdomains** müssen auf die Cluster-Server-IP zeigen – **Wildcard
empfohlen**:

```
*.camunda.kunde.local → <Cluster-Server-IP>
```

Alternativ einzelne Einträge: `keycloak.`, `identity.`, `console.`, `optimize.`,
`orchestration.`, `webmodeler.`, `zeebe.` unter `<HOST>`.

- Für den PoC kann die Auflösung **lokal über die Hosts-Datei** erfolgen
  (Skript `setup-host`), dann funktioniert der Zugriff nur von diesem Rechner.
- Für mehrere Benutzer (z. B. Fachbereich) und für den Connector-Server ist ein
  **DNS-Eintrag** nötig – der Connector-Server muss alle Ziel-Hosts aus 5.3–5.5
  auflösen können (intern und öffentlich).
- **Wichtig:** Der endgültig gewählte `HOST` muss **kleingeschrieben** und
  **vor der Einrichtung festgelegt** werden. Eine spätere Änderung erfordert
  eine Neuaufsetzung der Identity-/Keycloak-Datenbanken.

**Corporate-Proxy (falls vorgeschaltet):**

| Thema | Anforderung |
|-------|-------------|
| HTTP(S)-Proxy | **CONNECT-Methode (Tunneling)** für alle Ziel-Hosts aus 5.2–5.5 freigeben. Proxy-Konfiguration über JVM-Optionen (`-Dhttps.proxyHost=...`) bzw. Umgebungsvariablen. |
| IPv4 | Empfehlung: `JAVA_TOOL_OPTIONS=-Djava.net.preferIPv4Stack=true` (im Compose-Setup bereits gesetzt) – vermeidet IPv6-Routingprobleme bei Docker-`host-gateway`. |
| Cluster-Auflösung vom Connector-Server | Bei lokalem Camunda-Cluster auf demselben Docker-Host wird der Cluster über `host-gateway` bzw. die reale IP erreicht (`CAMUNDA_HOST_GATEWAY`). |

### 5.7 Administrations-Laptop – ausgehend

| Ziel | Port | Zweck |
|------|------|-------|
| Cluster-Server | 443 (HTTPS) | Oberflächen |
| Cluster-Server | 22 (SSH) | Administration |
| Connector-Server | 22 (SSH), 443 (optional) | Administration, ggf. Oberflächen |
| VPN-Endpunkt | lt. VPN-Konfiguration | Netzzugang |

---

## 6. Zertifikate und Truststore

**Cluster-Server (TLS für Browser):**

| Fall | Anforderung |
|------|-------------|
| Standard | Caddy erzeugt ein **selbstsigniertes** Zertifikat – der Browser warnt. |
| Firmen-Zertifikat | `FULLCHAIN_PEM` / `PRIVATEKEY_PEM` in `.env` hinterlegen (z. B. Firmen-CA oder Wildcard). Ablauf überwachen. |

**Connector-Server (Java-Truststore):** Alle Connectors importieren beim Start
alle `.crt`- und `.pem`-Dateien aus dem Verzeichnis `certs/` in den
Java-Truststore (idempotent, Alias = Dateiname).

| Fall | Anforderung |
|------|-------------|
| Camunda-Cluster mit **interner/privater CA** oder Self-Signed-Zertifikat | **Root-CA als `.crt`/`.pem` in `certs/` ablegen**, sonst scheitert die gRPC-Verbindung zu Zeebe mit `SSLHandshakeException: PKIX path building failed` |
| Externe Systeme mit öffentlichen Zertifikaten | Kein Handlungsbedarf (Standard-Truststore) |
| Interne Systeme (Jira, Confluence, SMB, SMTP) mit interner CA | Zertifikat der internen CA ebenfalls in `certs/` bereitstellen |
| TLS-Mindeststandard | TLS 1.2+ an allen Endpunkten |

---

## 7. Zugänge und Konten

### 7.1 Camunda-Cluster – Zugänge

| # | Zugang | Beschaffung / Zuständigkeit | Wird benötigt für |
|---|--------|-----------------------------|-------------------|
| 1 | **SSH-Zugang zu beiden Servern** (Schlüssel/User) | Kunden-IT | Administration |
| 2 | **TLS-Zertifikat** (Firmen-CA oder Wildcard) | Kunden-IT – optional | Vertrauenswürdige HTTPS-Verbindung; ohne wird selbstsigniert genutzt |
| 3 | **Backup-Ziel** (z. B. NAS-Freigabe, S3-kompatibler Speicher, zweiter Datenträger) | Kunden-IT | Backup-/Restore-Skripte |
| 4 | **VPN-Profil** für den Administrations-Laptop | Kunden-IT | Remote-Zugriff auf Server |
| 5 | (optional) **SMTP-Konto** | Kunden-IT | E-Mail-Zustellung aus Prozessen |

### 7.2 Camunda-Plattform – OIDC-Service-Account für BBC Connectors (zwingend)

| Zugang | Beschreibung |
|--------|--------------|
| **OIDC Service-Account (Machine User)** | Client-ID + Client-Secret im Keycloak-Realm `camunda-platform`; Audience `orchestration-api` |
| Rechte | Darf **Jobs für Task-Typen `bbc_*` aktivieren/abschließen** und auf die Camunda-REST-API zugreifen |
| Tenant | Zuordnung zum relevanten Tenant (Standard: `<default>`) |

### 7.3 Externe Systeme – Accounts und Daten (je eingesetztem BBC-Connector)

Für **jeden** BBC-Connector, der im PoC eingesetzt werden soll, müssen von der
Kunden-IT neben der Firewall-Freigabe (Abschnitt 5.4) auch die **Accounts** und
**Onboarding-Daten** bereitgestellt werden. Ohne diese Angaben kann der
Connector weder konfiguriert noch gegen das Zielsystem getestet werden.

| Connector | Benötigter Account / Zugangsdaten | Benötigte Daten / Konfiguration |
|-----------|----------------------------------|---------------------------------|
| Jira | API-Token **oder** App-Passwort + Benutzer (Dedicated-Service-Konto) | Jira-Basis-URL (`<jira-host>`), Projekt-Key(s), Rechte zum Lesen/Anlegen/Bearbeiten von Issues in den relevanten Projekten |
| Confluence | API-Token **oder** App-Passwort + Benutzer | Confluence-Basis-URL (`<confluence-host>`), Space-Key(s), Rechte zum Lesen/Schreiben von Seiten |
| SMTP | Mailbox-Konto (Benutzer/Passwort) für den Versand, ggf. App-Passwort | SMTP-Server-Host + Port (**25 / 465 / 587**), Absenderadresse, TLS/STARTTLS-Einstellung, ggf. SMTP-Relay-Freigabe für den Connector-Server |
| Webex | **Bot-Token** (Bearer-Token, erstellt in `developer.webex.com`), ggf. Tenant-Admin-Freigabe für Webhooks | Raum-/Person-IDs für die Zieladressierung, öffentlich erreichbare Callback-/Webhook-URL (Port **1337** bzw. FQDN) |
| UiPath | **Orchestrator-API-Schlüssel** (Client-ID + User-Key bzw. Client-Secret, „App Credentials") | UiPath-Cloud-Tenant-Name und Organisation (`cloud.uipath.com`), Orchestrator-/Folder-Pfad, Roboter-/Prozessnamen, Callback-URL (Port **1338**) |
| Netzwerkfreigaben (SMB) | Domänen-/Dienstkonto mit **Lese-/Schreibrechten** auf die Ziel-Freigaben | UNC-Pfade der Freigaben (`\\<smb-host>\freigabe`), Domäne, Benutzername (UPN), Port-Freigabe **445** (ggf. 139) |
| Camunda-Utils | OIDC-Service-Account, siehe 7.2 | – |

> Für den PoC genügt je System ein **Dedicated-Service-Konto mit minimalen
> Rechten**. Die konkreten `<...>`-Werte (Hosts, IDs, Keys) werden beim
> Onboarding des jeweiligen Systems ergänzt und landen in
> `config/<connector>/application.yaml` bzw. `.env-credentials` des
> Connector-Servers.

### 7.4 Secrets-Handling

Alle Zugangsdaten (OIDC-Secrets, Datenbank-Passwörter, Elasticsearch-Passwort,
Keycloak-Admin, System-Zugänge der Connectors) liegen in **gitignored** Dateien
`.env-credentials` (Cluster **und** Connector-Server), die auf den Servern
erzeugt werden (`scripts/generate-secrets.sh`). Sie werden **niemals** committet
oder per E-Mail versendet; Übergabe erfolgt sicher (z. B.
Passwort-Manager/Vault).

---

## 8. Betrieb und Monitoring

### 8.1 Camunda-Cluster

- **Monitoring:** Das Skript `scripts/monitor.sh` prüft zyklisch Container-
  Status und schreibt ein Log (`monitor.log`). Kritische Signale: freier
  Plattenplatz (< 15 % = Elasticsearch-Problemzone), ungesunde Container,
  Elasticsearch-Clusterstatus (`yellow`/`red`).
- **Backups:** `scripts/backup.sh` sichert Docker-Volumes (Elasticsearch,
  Keycloak/Identity-DB, Camunda-DB, Web-Modeler-DB, Konfiguration). Restore
  über `scripts/restore.sh`. Backups enthalten **Secrets im Klartext** – das
  Backup-Ziel ist entsprechend zu schützen (Zugriffsrechte, Verschlüsselung).
- **Erster Start dauert 5–10 Minuten** (Bootstrap: Keycloak-Realm-Import,
  Identity-Provisionierung, DB-Migrationen, ES-Templates). Spätere Starts:
  1–2 Minuten.

### 8.2 Connector-Server

| Thema | Details |
|-------|---------|
| Autostart | `restart: unless-stopped` je Service (Docker) |
| Selbstheilung | `monitoring.sh check` per **Cron alle 5 Minuten** (`*/5 * * * * /opt/bbc-connectors/monitoring.sh check >> /var/log/bbc-connector-monitor.log 2>&1`, Beispiel-Pfad); erkennt fehlende Container, Replikat-Drift, Crash-Loops |
| Wartungsmodus | `docker-connector-manager.sh maintenance on "Grund"` vor geplanten Stopps |
| Logs | `docker compose logs -f <connector>`; Logrotation über `monitoring.sh` (Standard 1 MiB, 5 Generationen) |
| Rollout | Images als `.tar` übertragen → `docker-connector-manager.sh refresh` → `up` |

---

## 9. Freigaben-Checkliste (Kunden-IT)

| # | Freigabe | Verantwortlich | Erledigt? |
|---|----------|----------------|-----------|
| **Server / VM** | | | |
| 1 | **Cluster-Server** bereitgestellt: Linux, 16 vCPU / 32 GB / ≥ 100 GB SSD | Kunden-IT | ☐ |
| 2 | **Connector-Server** bereitgestellt: Linux, 8 vCPU / 16 GB / ≥ 50 GB SSD | Kunden-IT | ☐ |
| 3 | Docker Engine + Compose auf **beiden** Hosts installiert | Betreiber | ☐ |
| 4 | NTP/Zeitsync auf beiden Hosts; `vm.max_map_count` auf dem Cluster-Server | Kunden-IT | ☐ |
| **Netzwerk / Firewall** | | | |
| 5 | Inbound Cluster-Server: **443**, **80**, **22** (nur VPN) | Kunden-IT | ☐ |
| 6 | Outbound Cluster-Server: **docker.io**, **docker.elastic.co**, **registry.camunda.cloud**, NTP | Kunden-IT | ☐ |
| 7 | Outbound Connector-Server: **443** → `zeebe.<HOST>`, `orchestration.<HOST>`, `keycloak.<HOST>` (Camunda) | Kunden-IT | ☐ |
| 8 | Outbound Connector-Server: Ziel-Hosts der geplanten BBC-Connectors (SMB 445, SMTP 25/465/587) | Kunden-IT | ☐ |
| 9 | Inbound Connector-Server: **1337/1338** nur bei Webex-/UiPath-Connector | Kunden-IT | ☐ |
| 10 | Proxy: CONNECT-Tunneling für alle Ziel-Hosts (falls Corporate-Proxy) | Kunden-IT | ☐ |
| 11 | DNS: Wildcard `*.camunda.kunde.local` → Cluster-Server-IP; Auflösung aller Ziel-Hosts vom Connector-Server | Kunden-IT | ☐ |
| **Zugänge** | | | |
| 12 | TLS-Zertifikat (Firmen-CA) bereitgestellt oder Selbstsigniert-OK erklärt | Kunden-IT | ☐ |
| 13 | Interne/private Root-CAs als `.crt`/`.pem` in `certs/` des Connector-Servers | Kunden-IT | ☐ |
| 14 | VPN-Profil + Administrations-Laptop eingerichtet | Kunden-IT | ☐ |
| 15 | SSH-Zugang (Schlüssel) für Betreiber auf beiden Servern | Kunden-IT | ☐ |
| 16 | OIDC-Service-Account (Client-ID/Secret, Audience `orchestration-api`, Job-Rechte `bbc_*`) | Projektleitung / Kunden-IT | ☐ |
| 17 | System-Zugänge je eingesetztem BBC-Connector (Jira, SMTP, …) | Kunden-IT | ☐ |
| **Betrieb** | | | |
| 18 | Backup-Ziel (Freigabe/Storage) für das Cluster bereitgestellt | Kunden-IT | ☐ |
| 19 | Cron-Job `monitoring.sh check` auf dem Connector-Server eingerichtet | Betreiber | ☐ |

---

## 10. Ablauf und Meilensteine (PoC)

| Phase | Inhalt | Dauer (Richtwert) |
|-------|--------|-------------------|
| 0 | Freigaben-Checkliste abarbeiten (Abschnitt 9) | 1–2 Wochen (je nach IT-Prozessen) |
| 1 | Beide Server provisionieren, Docker installieren, Netzwerk/DNS verifizieren | 1–2 Tage |
| 2 | Cluster aufsetzen: Secrets generieren, `.env` konfigurieren, Cluster starten | 1 Tag |
| 3 | Connector-Server aufsetzen: Images (`.tar`), Compose, `certs/`, OIDC-Service-Account | 1 Tag |
| 4 | Benutzer anlegen, TLS-Zertifikat, Monitoring/Backup aktivieren | 1 Tag |
| 5 | PoC-Betrieb: Prozesse modellieren und ausführen, Demo mit Fachbereich | PoC-Zeitraum |
| 6 | PoC-Auswertung, Entscheidung Folgeauftrag (Ausbau/Produktion) | – |

---

## 11. Ansprechpartner

| Rolle | Name | E-Mail / Telefon |
|-------|------|------------------|
| Projektleitung / Camunda-Betreiber | `<Name>` | `<…>` |
| BBC-Connectors (Entwicklung/Betrieb) | `<Name>` | `<…>` |
| Kunden-IT (Server, Netzwerk, Freigaben) | `<Name>` | `<…>` |

---

## 12. Offene Punkte und Annahmen

1. **Welche BBC-Connectors** kommen im PoC konkret zum Einsatz? → Firewall-Matrix
   (5.4) entsprechend reduzieren.
2. **Camunda-Cluster:** Self-Managed (on-prem beim Kunden) – die Host-URLs
   (`zeebe.`/`orchestration.`/`keycloak.` unter `camunda.kunde.local`) und das
   Realm sind kundenspezifisch zu bestätigen.
3. **Netzwerksegment:** Der Connector-Server muss den Cluster-Server über
   **443 (ausgehend)** erreichen können – Firewall-Freigabe zwischen den
   Segmenten einplanen.
4. Falls Cluster und Connectors **auf demselben Docker-Host** laufen sollen:
   `CAMUNDA_HOST_GATEWAY` muss die reale Cluster-IP sein (`host-gateway` als
   Standard). Im Regelfall wird hier aber von zwei getrennten VMs ausgegangen.
5. **TLS-Zertifikate** der Camunda-Plattform müssen von den Connectors
   validierbar sein (Abschnitt 6).
6. **SMTP:** Für echte E-Mail-Zustellung aus Prozessen/Connectors ist eine
   SMTP-Freigabe nötig; ohne Freigabe bleibt es beim lokalen Mailpit (Cluster).

---

## Anhang A – Subdomains des Camunda-Clusters

| Dienst | URL |
|--------|-----|
| Dashboard | `https://camunda.kunde.local` |
| Operate / Tasklist | `https://orchestration.camunda.kunde.local` |
| Identity | `https://identity.camunda.kunde.local` |
| Console | `https://console.camunda.kunde.local` |
| Optimize | `https://optimize.camunda.kunde.local` |
| Web Modeler | `https://webmodeler.camunda.kunde.local` |
| Keycloak Admin | `https://keycloak.camunda.kunde.local/auth/` |
| Zeebe-Gateway (gRPC) | `https://zeebe.camunda.kunde.local` |
| Admin-UI | `https://orchestration.camunda.kunde.local/admin` |

*(`camunda.kunde.local` = Platzhalter für den tatsächlichen Wert von `HOST` aus
`.env` – im PoC typischerweise eine lokale, nicht öffentliche Domain.)*

---

## Anhang B – Konfiguration BBC Connectors (Beispielwerte)

| Parameter | Wert / Erläuterung |
|-----------|--------------------|
| **.env (Auszug)** | |
| `CAMUNDA_HOST` | `camunda.kunde.local` – Cluster-URL (`HOST` aus `.env` des Clusters) |
| `CAMUNDA_GRPC_ADDRESS` | `https://zeebe.camunda.kunde.local:443` |
| `CAMUNDA_REST_ADDRESS` | `https://orchestration.camunda.kunde.local` |
| `CAMUNDA_TOKEN_URL` | `https://keycloak.camunda.kunde.local/auth/realms/camunda-platform/protocol/openid-connect/token` |
| `CAMUNDA_AUDIENCE` | `orchestration-api` |
| `JIRA_REPLICAS` | `1` – Replikate je Connector (PoC: 1) |
| `WEBEX_PORT` | `1337` – nur bei Webex/UiPath |
| `UIPATH_PORT` | `1338` |
| **.env-credentials** | |
| `CAMUNDA_CLIENT_ID` | `<service-account-client-id>` |
| `CAMUNDA_CLIENT_SECRET` | `<service-account-secret>` |

**Start:** `docker compose up -d` (JARs zuvor via `mvn clean package -DskipTests`
bauen, sofern nicht als fertige Images/`.tar` geliefert).

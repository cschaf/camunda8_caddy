# ProcessOS Harness einrichten (Camunda 8.10)

Diese Anleitung beschreibt, wie ProcessOS Harness mit diesem Stack als
Governance-Cluster eingerichtet wird: zuerst die Cluster-Seite (einmalig pro
Umgebung), dann der Rechner des Builders unter Windows mit WSL.

Stand: 06.11.2026, ProcessOS Harness **1.0.0**. Alle Angaben stammen aus den
öffentlichen Quellen am Ende dieser Datei und aus Tests mit diesem Stack.

> **Lizenz:** Die ProcessOS-Archive stehen unter der Camunda License 1.0 und
> sind nicht öffentlich. Archive, die daraus installierten Dateien (z. B. die
> Skills unter `.claude/skills/`) und Beschreibungen ihres Inhalts gehören
> **nie** in dieses Repository. `c8 os install` immer in einem eigenen
> Projektordner mit eigenem, privatem Git-Repository ausführen.

Platzhalter in dieser Anleitung:

| Platzhalter | Bedeutung | Beispiel |
|---|---|---|
| `<HOST>` | Basis-Domain des Stacks | `camunda.firma.local` |
| `<windows-user>` | Windows-Benutzername (Pfad unter `C:\Users\`) | `mmuster` |
| `<stage>` | Stage-Datei des Stacks unter `stages/` | `dev` |
| `<projekt>` | Name des ProcessOS-Projekts | `rechnungseingang` |

## Inhalt

1. [Überblick](#1-überblick)
2. [Voraussetzungen](#2-voraussetzungen)
3. [Cluster vorbereiten (dieser Stack)](#3-cluster-vorbereiten-dieser-stack)
4. [Builder-Rechner unter Windows mit WSL](#4-builder-rechner-unter-windows-mit-wsl)
5. [ProcessOS-Projekt anlegen und starten](#5-processos-projekt-anlegen-und-starten)
6. [SMEs für die Reviews freischalten](#6-smes-für-die-reviews-freischalten)
7. [Fehlersuche](#7-fehlersuche)
8. [Quellen](#8-quellen)

## 1. Überblick

ProcessOS Harness läuft als Governance-Prozess auf Camunda und steuert einen
KI-Coding-Agenten (Claude Code CLI oder GitHub Copilot CLI) im Terminal des
Builders durch vier Phasen: **Scope → Discover → Transform → Implement**.
Zwischen den Phasen prüfen Fachexperten (SMEs) die Ergebnisse.

Aufteilung:

| Wo | Was |
|---|---|
| Builder-Rechner (WSL) | c8ctl mit ProcessOS-Plugin, KI-Agent, Projektordner mit Git, c8run für lokale Tests |
| Dieser Stack (Governance-Cluster) | Governance-Prozess, Projektstatus, Review-Formulare in der Tasklist |
| Privates Git-Repository | Alle Artefakte des Projekts |

Auf dem Server wird **nichts** von ProcessOS installiert. Der Builder
deployt den Governance-Prozess beim ersten Start selbst über c8ctl. Der
Cluster braucht dafür nur einen API-Client mit Rechten (Abschnitt 3).

Nicht Teil dieses Releases laut Camunda: Produktiv-Deployment und
Lifecycle-Management, Plattform-/CI-Setup, eigene UIs jenseits von Camunda
Forms, Process Mining, gemeinsames Gedächtnis über Projekte hinweg.

## 2. Voraussetzungen

### Zugang

- Berechtigt sind Camunda-Enterprise-Kunden und Partner mit Partnervertrag.
- Die Archive liegen im Camunda Download Center unter
  `https://downloads.camunda.cloud/enterprise-release/` (Enterprise-Zugangsdaten).
  Pro KI-Agent gibt es ein Archiv (`claudecode` oder `copilotcli`).
- Version **1.0.0** ist die stabile Version. `1.1.0-alpha.*` sind Vorschauen
  und nicht für Kundenprojekte gedacht.
- Kein Zugang: Customer Success Manager oder Partner Manager fragen.

### Organisatorisch

- Builder: Kurs "ProcessOS Harness overview" in der Camunda Academy abschließen.
- Das erste Projekt mit einem befähigten Partner oder einem Camunda Forward
  Deployed Engineer durchführen (über das Camunda-Account-Team).
- SMEs an den Review-Gates jeder Phase einplanen. Ohne Reviewer steht das
  Projekt still.
- Planung laut Camunda: 6 bis 8 Stunden pro Durchlauf. Tokenkosten etwa
  300 bis 600 USD (explorativ, kleiner Use Case), 800 bis 1.500+ USD
  (Lift-and-Shift, mittlerer Prozess), 1.000 bis 2.000+ USD
  (KI-Transformation, mittlerer bis großer Prozess).

### Builder-Rechner

| Komponente | Anforderung |
|---|---|
| Betriebssystem | Windows **über WSL**, macOS oder Unix. Unter Windows WSL verwenden, das ist die von Camunda getestete Variante. Für c8run: Ubuntu 22.04 oder neuer |
| Node.js | 22.18.0 oder neuer |
| c8ctl | 4.3.0 oder neuer (für ProcessOS 1.0.0) |
| Git und GitHub CLI | `git`, `gh` |
| Maven | nur für Java-Worker |
| c8run | lokaler Camunda-Cluster zum Validieren der erzeugten Lösung |
| Camunda Modeler | für BPMN/DMN-Reviews (unter Windows installieren) |
| KI-Agent | Claude Code oder GitHub Copilot CLI, Modell der Opus-Klasse empfohlen. Braucht Rechte zum Ausführen von Befehlen, ausgehenden Netzwerkzugriff und Schreibzugriff auf das Projekt-Repository |
| Root-CA-Zertifikat | Root-Zertifikat der CA, die das Server-Zertifikat des Stacks ausgestellt hat (Abschnitt 4.5) |

## 3. Cluster vorbereiten (dieser Stack)

Der Stack legt für c8ctl und andere Builder-Werkzeuge einen eigenen
M2M-Client **`c8ctl`** an. Er ist vom Plattform-Client `orchestration`
getrennt, damit sein Secret an Builder gegeben und unabhängig ausgetauscht
werden kann.

| Was | Wo |
|---|---|
| Keycloak-Client `c8ctl` (`read:*`/`write:*` auf `orchestration-api`) | `.identity/application.yaml` |
| Orchestration-Rolle `admin` | `.orchestration/application.yaml` (`defaultRoles`) |
| Secret `C8CTL_CLIENT_SECRET` | `.env-credentials` |

Die Rolle `admin` ist ein Startwert, bis feststeht, welche Rechte die
Werkzeuge genau brauchen. Danach einschränken.

### Neue Installation

Nichts zu tun. `scripts/generate-secrets.sh` erzeugt `C8CTL_CLIENT_SECRET`,
und der erste Start legt Client und Rolle an.

### Bestehende Installation (vor dem 03.11.2026 eingerichtet)

Auf dem Server im Projektordner:

```bash
# 1. Sicherung
for f in docker-compose.yaml .identity/application.yaml .orchestration/application.yaml; do
  cp "$f" "$f.bak-$(date +%Y%m%d)"
done

# 2. Secret einmalig anhängen
grep -q '^C8CTL_CLIENT_SECRET=' .env-credentials \
  || echo "C8CTL_CLIENT_SECRET=$(openssl rand -hex 24)" >> .env-credentials

# 3. Aktuelle Fassungen von docker-compose.yaml, .identity/application.yaml und
#    .orchestration/application.yaml aus dem Repository kopieren, dann prüfen:
docker compose --env-file .env --env-file .env-credentials \
  -f docker-compose.yaml -f stages/<stage>.yaml config -q && echo OK

# 4. Identity und Orchestration neu erstellen (Engine 1 bis 2 Minuten nicht erreichbar)
docker compose --env-file .env --env-file .env-credentials \
  -f docker-compose.yaml -f stages/<stage>.yaml up -d --force-recreate identity orchestration
```

`--force-recreate` ist nötig, weil Compose geänderte eingebundene Dateien
nicht erkennt. Ohne den Neustart von Orchestration greift die Rolle nicht.
Identity legt den neuen Client auch in einem bestehenden Realm an.

### Prüfen

Auf dem Server (gibt keine Secrets aus):

```bash
S=$(grep '^C8CTL_CLIENT_SECRET=' .env-credentials | cut -d= -f2-)
T=$(curl -sk -d grant_type=client_credentials -d client_id=c8ctl -d "client_secret=$S" \
  https://keycloak.<HOST>/auth/realms/camunda-platform/protocol/openid-connect/token \
  | sed -E 's/.*"access_token":"([^"]+)".*/\1/'); unset S
curl -sk -o /dev/null -w '%{http_code}\n' -X POST \
  -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{}' \
  https://orchestration.<HOST>/v2/process-definitions/search; unset T
```

| Ergebnis | Bedeutung |
|---|---|
| `200` | Client und Rolle sind eingerichtet |
| `403` | Rolle fehlt: `up -d --force-recreate orchestration` wiederholen |
| `401` | Token wird nicht akzeptiert: `docker logs orchestration --tail 50` prüfen |

### Secret an den Builder geben

Den Wert von `C8CTL_CLIENT_SECRET` nur über einen sicheren Kanal weitergeben
(Passwort-Tresor), nicht per Mail, Chat oder in einen KI-Agenten-Prompt. Er
gibt Admin-Zugriff auf den Cluster.

Ist das Secret doch einmal offengelegt worden:

1. Auf dem Server einen neuen Wert setzen und Identity neu erstellen:

   ```bash
   sed -i "s/^C8CTL_CLIENT_SECRET=.*/C8CTL_CLIENT_SECRET=$(openssl rand -hex 24)/" .env-credentials
   docker compose --env-file .env --env-file .env-credentials \
     -f docker-compose.yaml -f stages/<stage>.yaml up -d --force-recreate identity orchestration
   ```

2. Prüfen, dass Keycloak den neuen Wert übernommen hat: Die Prüfung aus
   "Prüfen" oben muss mit dem **neuen** Secret `200` liefern. Liefert sie
   `401`, hat Identity das Secret des bestehenden Clients nicht geändert
   (nicht getestet). Dann in der Keycloak-Admin-Konsole
   (`https://keycloak.<HOST>/auth/`, Realm `camunda-platform`) unter
   Clients → `c8ctl` → Credentials das Secret auf den Wert aus
   `.env-credentials` setzen bzw. dort neu erzeugen und in `.env-credentials`
   übernehmen.
3. Beim Builder das Profil neu anlegen (Abschnitt 4.7).

### Root-CA an den Builder geben

Zusammen mit dem Secret das **Root-Zertifikat der CA** bereitstellen, die das
Server-Zertifikat des Stacks ausgestellt hat (PEM, `CA:TRUE`). Builder
brauchen es in Abschnitt 4.5. Nicht das Server-Zertifikat selbst weitergeben,
damit funktioniert Node.js nicht.

## 4. Builder-Rechner unter Windows mit WSL

Alle Befehle in diesem Abschnitt laufen, wenn nicht anders angegeben, im
WSL-Terminal (Ubuntu).

### 4.1 WSL mit Ubuntu

In PowerShell **als Administrator** (entfällt, wenn Ubuntu unter WSL schon
installiert ist; prüfen mit `wsl -l -v`):

```powershell
wsl --install -d Ubuntu-24.04
```

Danach Ubuntu aus dem Startmenü öffnen und den Linux-Benutzer anlegen.

Projektdateien gehören ins Linux-Dateisystem (`~/…`), nicht nach `/mnt/c/…`.
Dort ist Git deutlich schneller und Dateirechte funktionieren wie erwartet.

### 4.2 Grundwerkzeuge

```bash
sudo apt update
sudo apt install -y git curl unzip ca-certificates openssl gh
git config --global user.name  "Vorname Nachname"
git config --global user.email "vorname.nachname@firma.de"
gh auth login        # nur nötig, wenn GitHub als Git-Host genutzt wird
```

Nur für Java-Worker:

```bash
sudo apt install -y openjdk-21-jdk maven
```

### 4.3 Node.js über nvm

nvm installiert Node.js im Benutzerverzeichnis. Globale npm-Pakete brauchen
dann kein `sudo`.

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.8/install.sh | bash
source ~/.bashrc
nvm install 22
node -v              # muss 22.18.0 oder neuer sein
```

### 4.4 Namensauflösung prüfen

Der Builder muss `orchestration.<HOST>` und `keycloak.<HOST>` auf Port 443
erreichen.

```bash
getent hosts orchestration.<HOST> keycloak.<HOST>
curl -skI https://orchestration.<HOST>/ | head -1
```

- Werden die Namen über das Firmen-DNS aufgelöst, übernimmt WSL das
  automatisch.
- Stehen sie nur in der Windows-Hosts-Datei
  (`C:\Windows\System32\drivers\etc\hosts`), kopiert WSL sie beim Start nach
  `/etc/hosts`. Nach einer Änderung unter Windows in PowerShell
  `wsl --shutdown` ausführen und WSL neu öffnen.

### 4.5 Root-Zertifikat vertrauen

Node.js nutzt nicht den Zertifikatsspeicher des Betriebssystems. Ohne diesen
Schritt bricht c8ctl ab, meist nur mit `fetch failed` (Details in
Abschnitt 7).

> **Häufigster Fehler:** Statt des Root-Zertifikats der CA wird das
> Server-Zertifikat (`*.<HOST>`) oder das Zertifikat eines anderen Servers
> eingebunden. curl akzeptiert ein Server-Zertifikat teilweise trotzdem,
> **Node.js und damit c8ctl nicht** (`UNABLE_TO_VERIFY_LEAF_SIGNATURE`).
> Gebraucht wird genau das Zertifikat, dessen Subject dem *Issuer* des
> Server-Zertifikats entspricht und das `CA:TRUE` enthält.

#### 1. Aussteller des Server-Zertifikats ermitteln

```bash
openssl s_client -connect orchestration.<HOST>:443 -servername orchestration.<HOST> </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```

Die Zeile `issuer=` nennt die gesuchte CA. Deren Root-Zertifikat im
PEM-Format besorgen (Text, beginnt mit `-----BEGIN CERTIFICATE-----`).

#### 2. Root-Zertifikat besorgen

Eine der folgenden Quellen nutzen:

- **Vom Betreiber des Stacks bzw. der IT** anfordern (Abschnitt 3,
  "Root-CA an den Builder geben").
- **Univention Corporate Server (UCS) als CA:** auf dem UCS-Primary, der das
  Zertifikat ausgestellt hat, unter `/etc/univention/ssl/ucsCA/CAcert.pem`,
  meist auch unter `http://<ucs-primary>/ucs-root-ca.crt`. Auf die ID im
  CA-Namen achten (`Root CA (ID=…)`): Gibt es mehrere UCS-Domänen, muss sie
  zum `issuer` aus Schritt 1 passen.
- **Aus dem Browser** unter Windows (wenn der Browser die Seite ohne Warnung
  öffnet):
  - Chrome/Edge: `https://orchestration.<HOST>` öffnen → Schloss →
    "Zertifikat anzeigen" → Reiter **Details** → unter
    **Zertifikathierarchie** den **obersten** Eintrag anklicken → erst dann
    **Exportieren** → "Base64-codiert ASCII, einzelnes Zertifikat".
  - Firefox: Schloss → "Verbindung sicher" → "Weitere Informationen" →
    "Zertifikat anzeigen" → Reiter der Root-CA wählen → "Herunterladen:
    PEM (Zertifikat)".

  Ohne Auswahl des obersten Eintrags exportiert der Browser das
  Server-Zertifikat (Dateiname dann typisch `_.<HOST>.crt`).
- **Windows-Zertifikatsspeicher:** `certmgr.msc` → "Vertrauenswürdige
  Stammzertifizierungsstellen" → Zertifikat exportieren als "Base-64-codiert
  X.509 (.CER)".
- **mkcert (nur Testumgebungen):** `rootCA.pem` aus dem Ordner, den
  `mkcert -CAROOT` auf dem Rechner anzeigt, der das Zertifikat erzeugt hat.

#### 3. Datei prüfen, bevor sie eingebunden wird

```bash
F=/mnt/c/Users/<windows-user>/Downloads/<root-ca-datei>.crt

openssl x509 -in "$F" -noout -subject -ext basicConstraints -enddate
#  subject     = muss dem issuer aus Schritt 1 entsprechen
#  CA:TRUE     = muss vorhanden sein (CA:FALSE heißt: Server-Zertifikat, falsche Datei)
#  notAfter    = Ablaufdatum notieren

NODE_EXTRA_CA_CERTS="$F" node -e \
  "fetch('https://orchestration.<HOST>/').then(r=>console.log('OK',r.status)).catch(e=>console.log((e.cause||e).code))"
#  muss "OK <statuscode>" ausgeben
```

Liegt die Datei im DER-Format vor (Binär, kein `-----BEGIN`), vorher
umwandeln: `openssl x509 -inform der -in "$F" -out root-ca.crt`.

#### 4. In WSL einbinden

```bash
sudo cp "$F" /usr/local/share/ca-certificates/firmen-root-ca.crt
sudo update-ca-certificates                     # für curl, git usw.

# NODE_EXTRA_CA_CERTS setzen bzw. einen alten Eintrag ersetzen (für Node.js / c8ctl)
sed -i '/^export NODE_EXTRA_CA_CERTS=/d' ~/.bashrc
echo 'export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/firmen-root-ca.crt' >> ~/.bashrc
source ~/.bashrc
```

`update-ca-certificates` erwartet die Endung `.crt`. Eine `.cer`-Datei im
Base-64-Format kann einfach umbenannt werden. Ein zuvor fälschlich
eingebundenes Zertifikat aus `/usr/local/share/ca-certificates/` löschen und
`sudo update-ca-certificates` erneut ausführen.

`NODE_EXTRA_CA_CERTS` gilt nur für Prozesse, die **nach** der Änderung
gestartet werden. Ein bereits laufender KI-Agent (z. B. `claude`) muss in
einem neuen Terminal neu gestartet werden.

#### 5. Prüfen, ohne `-k`

```bash
curl -sI https://orchestration.<HOST>/ | head -1
```

Läuft das Root-Zertifikat ab, muss die neue Fassung genauso eingebunden
werden. Das Ablaufdatum aus Schritt 3 im Kalender vormerken.

### 4.6 c8ctl und ProcessOS-Plugin

```bash
npm install -g @camunda8/cli@latest
c8ctl --version                                 # 4.3.0 oder neuer
c8 load plugin @camunda8/c8ctl-plugin-process-os
```

Falls ein anderes `c8` im `PATH` Vorrang hat, überall `c8ctl` statt `c8`
verwenden.

### 4.7 c8ctl-Profil für den Governance-Cluster

Das Secret wird mit `read -s` abgefragt, damit es nicht in der
Shell-Historie landet. c8ctl speichert es in seiner Profildatei
(`~/.config/c8ctl/profiles.json`).

```bash
read -rsp "C8CTL_CLIENT_SECRET: " C8CTL_SECRET; echo
c8ctl add profile governance \
  --baseUrl=https://orchestration.<HOST> \
  --oAuthUrl=https://keycloak.<HOST>/auth/realms/camunda-platform/protocol/openid-connect/token \
  --audience=orchestration-api \
  --clientId=c8ctl --clientSecret="$C8CTL_SECRET"
unset C8CTL_SECRET
chmod 600 ~/.config/c8ctl/profiles.json

c8ctl --json get topology --profile governance  # muss "brokers" bzw. "clusterSize" zeigen
```

Erwartete Ausgabe (gekürzt):

```json
{"brokers":[{"nodeId":0,"partitions":[{"partitionId":1,"role":"leader","health":"healthy"}],"version":"8.10.x"}],
 "clusterSize":1,"partitionsCount":1,"gatewayVersion":"8.10.x"}
```

Meldet c8ctl stattdessen `"error":"fetch failed"`, ist fast immer das
Zertifikat die Ursache, nicht das Profil. Der Hinweis
`Is the local cluster running?` in derselben Meldung ist dann irreführend.
Zurück zu Abschnitt 4.5, Schritt 3. Details zeigt
`c8ctl --json get topology --profile governance --verbose`.

Das Secret niemals in einen Chat oder Prompt des KI-Agenten kopieren. Der
Agent braucht es nicht: Er ruft c8ctl mit dem Profil auf, und c8ctl liest das
Secret selbst aus der Profildatei.

### 4.8 c8run für lokale Tests

Die erzeugte Lösung wird lokal auf c8run validiert, nicht auf dem
Governance-Cluster.

1. Die Linux-Version für die eigene Architektur (meist `linux-x86_64`) von
   `https://downloads.camunda.cloud/release/camunda/c8run/8.10/` laden.
2. Entpacken und starten (Dateiname des Downloads einsetzen):

   ```bash
   mkdir -p ~/c8run && tar -xzf /mnt/c/Users/<windows-user>/Downloads/<c8run-datei>.tgz -C ~/c8run
   ls ~/c8run                                      # entpackten Ordner ermitteln
   cd ~/c8run/<ordner> && ./start.sh               # alternativ: ./c8run start
   ```

3. Operate unter `http://localhost:8080/operate` aufrufen. WSL leitet
   `localhost` an Windows weiter, der Browser unter Windows funktioniert also.

c8run belegt lokal Port 8080 und weitere Ports. Nicht parallel zu einem
lokalen Docker-Stack auf denselben Ports betreiben.

### 4.9 KI-Agent

Claude Code in WSL installieren:

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude --version
```

Beim ersten Start (`claude`) anmelden oder den von der Firma vorgegebenen
Zugang einrichten (Anthropic, Amazon Bedrock oder Azure OpenAI, je nach
Vorgabe). Im Projekt ein Modell der Opus-Klasse wählen (`/model`).

Den Agenten erst starten, wenn Abschnitt 4.5 und 4.7 erfolgreich sind, damit
er `NODE_EXTRA_CA_CERTS` bereits übernimmt.

## 5. ProcessOS-Projekt anlegen und starten

1. Archiv für den Agenten aus dem Download Center laden (Version 1.0.0, für
   Claude Code das `claudecode`-Archiv). Es landet unter Windows in
   `Downloads`.

2. Projekt anlegen und installieren, **außerhalb** dieses Repositorys:

   ```bash
   mkdir -p ~/processos/<projekt> && cd ~/processos/<projekt>
   c8 os install claudecode --zip /mnt/c/Users/<windows-user>/Downloads/<archiv>.zip
   git init && git add . && git commit -m "chore(job) commit process-os-harness setup"
   ```

3. Privates Remote-Repository anlegen und verbinden, z. B. mit GitHub:

   ```bash
   gh repo create <org>/<projekt> --private --source . --push
   ```

4. Agent starten und die Journey beginnen:

   ```bash
   claude
   ```

   In Claude Code ein Opus-Modell wählen und `/process-os-governance-start`
   ausführen. Bei der Frage nach dem Cluster den in 4.7 angelegten
   Self-Managed-Cluster bzw. das Profil `governance` angeben.

Aktualisieren auf eine neue Version: `c8 os switch claudecode --zip <neues-archiv>.zip`.
Entfernen: `c8 os uninstall`.

## 6. SMEs für die Reviews freischalten

Die SMEs bearbeiten die Review-Formulare in der Tasklist unter
`https://orchestration.<HOST>/tasklist`. Weil in diesem Stack
Autorisierungen aktiv sind (`RESOURCE_AUTHORIZATIONS_ENABLED=true`), braucht
jeder SME:

1. einen Benutzer in Keycloak, z. B. mit
   `bash scripts/add-camunda-user.sh --username <name> --password "<initial>" --email <mail> --first-name <v> --last-name <n> --role NormalUser`;
2. in Admin (`https://orchestration.<HOST>/admin`) die Berechtigung, die User
   Tasks des Governance-Prozesses zu lesen und abzuschließen.

Die Prozess-ID des Governance-Prozesses steht nach dem ersten Start in
Operate. Am einfachsten eine Gruppe "ProcessOS Reviewer" anlegen, ihr die
Berechtigung geben und die SMEs der Gruppe zuordnen.

> Noch nicht mit diesem Stack getestet: welche Berechtigungen ein SME genau
> braucht und ob `--role NormalUser` dafür schon reicht. Beim ersten Projekt
> mit einem SME-Konto prüfen, ob die Review-Tasks in der Tasklist erscheinen
> und abgeschlossen werden können, und diesen Abschnitt dann ergänzen.

## 7. Fehlersuche

| Symptom | Ursache | Lösung |
|---|---|---|
| `getent hosts` liefert nichts | Name nicht auflösbar | DNS-Eintrag anfordern oder Windows-Hosts-Datei ergänzen, dann `wsl --shutdown` |
| c8ctl meldet `"error":"fetch failed"` mit Hinweis `Is the local cluster running?` | Meist TLS: Node vertraut dem Server nicht. Der Hinweis auf den lokalen Cluster ist irreführend | Mit `--verbose` wiederholen bzw. Node-Test aus 4.5, Schritt 3 ausführen; dann nach den folgenden Zeilen vorgehen |
| `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`, `self-signed certificate in certificate chain` | Node vertraut der CA nicht | Abschnitt 4.5, `echo $NODE_EXTRA_CA_CERTS` prüfen |
| `UNABLE_TO_VERIFY_LEAF_SIGNATURE` | In `NODE_EXTRA_CA_CERTS` steht ein Server-Zertifikat (`CA:FALSE`) statt des Root-Zertifikats, oder die Root-CA einer anderen CA | Mit `openssl x509 -in "$NODE_EXTRA_CA_CERTS" -noout -subject -ext basicConstraints` prüfen; richtige Root-CA nach 4.5 besorgen |
| curl ohne `-k`: `unable to get local issuer certificate` | Root-CA nicht im Systemspeicher | Abschnitt 4.5, Schritt 4 (`update-ca-certificates`) |
| curl mit `--cacert` geht, Node/c8ctl nicht | Server-Zertifikat statt Root-CA verwendet; curl akzeptiert das, Node nicht | Root-CA nach 4.5 besorgen |
| Ging bisher, plötzlich TLS-Fehler | Root- oder Server-Zertifikat abgelaufen | `openssl x509 -in "$NODE_EXTRA_CA_CERTS" -noout -enddate`; neue Fassung von der IT anfordern und nach 4.5 einbinden |
| TLS-Fehler nur im KI-Agenten, im Terminal nicht | Agent wurde vor dem Setzen von `NODE_EXTRA_CA_CERTS` gestartet | Agent beenden und in einem neuen Terminal starten |
| `401` / `invalid_client` | Secret falsch oder Client fehlt | Secret neu eingeben (`c8ctl remove profile governance`, dann 4.7); auf dem Server Abschnitt 3 prüfen |
| `403` / `FORBIDDEN` | Client hat keine Rolle | Auf dem Server `up -d --force-recreate orchestration`, dann Prüfung aus Abschnitt 3 |
| Secret wurde in Chat, Mail oder Prompt kopiert | Secret offengelegt | Secret auf dem Server neu setzen (Abschnitt 3), Profil neu anlegen (4.7) |
| `c8ctl` sehr langsam oder Git langsam | Projekt unter `/mnt/c/…` | Projekt nach `~/…` verschieben |
| SME sieht keine Tasks in der Tasklist | Fehlende Berechtigung | Abschnitt 6 |
| c8run startet nicht, Port belegt | Port 8080 wird schon genutzt | Andere lokale Dienste beenden |

## 8. Quellen

- [ProcessOS Harness: Overview](https://docs.camunda.io/docs/components/process-os-harness/overview/)
- [Installation](https://docs.camunda.io/docs/components/process-os-harness/installation/)
- [System requirements](https://docs.camunda.io/docs/components/process-os-harness/setup/system-requirements/)
- [Project setup](https://docs.camunda.io/docs/components/process-os-harness/setup/project-setup/)
- [Changelog](https://docs.camunda.io/docs/components/process-os-harness/changelog/)
- [c8run installieren und starten](https://docs.camunda.io/docs/self-managed/quickstart/developer-quickstart/c8run/install-start/)
- [c8ctl](https://github.com/camunda/c8ctl) und [Befehlsreferenz](https://github.com/camunda/c8ctl/blob/main/docs/command-reference.md)
- [npm: @camunda8/c8ctl-plugin-process-os](https://www.npmjs.com/package/@camunda8/c8ctl-plugin-process-os)
- [Node.js: NODE_EXTRA_CA_CERTS](https://nodejs.org/api/cli.html#node_extra_ca_certsfile)
- [Univention: Zertifikate (UCS-Handbuch)](https://docs.software-univention.de/manual/latest/de/domain-ldap/ssl.html)
- [WSL installieren](https://learn.microsoft.com/de-de/windows/wsl/install)
- [Claude Code einrichten](https://docs.claude.com/en/docs/claude-code/setup)
- [nvm](https://github.com/nvm-sh/nvm)

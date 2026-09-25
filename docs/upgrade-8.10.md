# Migration Camunda 8.9.19 → 8.10.x

Leitfaden für dieses Docker-Compose-Projekt. Er beschreibt den **im Branch `feature/camunda-8-10` umgesetzten Stand**, das Runbook für bestehende Umgebungen und alle Erkenntnisse aus den lokalen Tests.

| | |
|---|---|
| Stand | 25.09.2026 |
| Ausgangsversion | Camunda 8.9.19 (Connectors 8.9.10, Optimize 8.9.19, Web Modeler 8.9.8, Console 8.9.104, Identity 8.9.9) |
| Zielversion | Camunda 8.10.x. GA laut Camunda am **13.10.2026**. Der Branch nutzt bis dahin die Release Candidates `8.10.0-rc2` (Hub `8.10-rc1`). |
| Getestet | Lokal mit RC-Images: frischer Aufbau, Hub-DB-Migration, Optimize-Schema-Upgrade und Identity-Rollen-Provisionierung auf einem 8.9-Realm (Details in [Kapitel 8](#8-testergebnisse-lokal-rc-images)) |

> **Das Upgrade bestehender Umgebungen geht nur auf ein GA-Release.** Zeebe verweigert die State-Migration auf eine Pre-Release-Version (`Cannot upgrade to or from a pre-release version`). Empfehlung: nicht vor `8.10.1` produktiv gehen und das Upgrade vorher per Restore-Drill mit einem Prod-Backup proben.

---

## Inhalt

1. [Was ändert sich?](#1-was-ändert-sich)
2. [Voraussetzungen und Entscheidungen](#2-voraussetzungen-und-entscheidungen)
3. [Branch auf GA umstellen](#3-branch-auf-ga-umstellen-vor-dem-ersten-produktiv-upgrade)
4. [Runbook: bestehende Umgebung upgraden](#4-runbook-bestehende-umgebung-upgraden)
5. [Rollback](#5-rollback)
6. [Änderungen im Branch (Referenz)](#6-änderungen-im-branch-referenz)
7. [Verifikation nach dem Upgrade](#7-verifikation-nach-dem-upgrade)
8. [Testergebnisse lokal (RC-Images)](#8-testergebnisse-lokal-rc-images)
9. [Offene Punkte und TODOs](#9-offene-punkte-und-todos)
10. [Quellen](#10-quellen)

---

## 1. Was ändert sich?

| # | Änderung in 8.10 | Auswirkung auf dieses Projekt | Umsetzung im Branch |
|---|---|---|---|
| 1 | **Camunda Hub ersetzt Web Modeler und Console** (`camunda/hub`, `camunda/hub-websockets`) | Die Services `console`, `web-modeler-restapi` und `web-modeler-websockets` entfallen. Neu sind `hub` und `hub-websockets`. | ✅ |
| 2 | Hub migriert die **Web-Modeler-Datenbank** beim ersten Start per Flyway. Das ist **nicht rückwärtskompatibel**. | Vorher ist ein Backup Pflicht. Ein Rollback geht nur per Restore. Beim Umbau werden Dateien ohne Process Application in „`<Projekt> - General`“ verschoben. | ✅ (DB/Volume bleiben erhalten) |
| 3 | Die Console-Konfiguration entfällt. Cluster werden in Hub unter `camunda.hub.clusters` registriert. | `.console/application.yaml.template` wird ersetzt durch `.hub/application.yaml`. Das Rendern in den Start-Skripten entfällt. | ✅ |
| 4 | Neue Management-Identity-Rollen `Hub`, `Hub Admin`, `Analyst` und `DevOps` (Nachfolger von `Console`); neue Permissions `admin:clusters`, `admin:catalog` und `admin:bi` | Die Rollen werden automatisch angelegt, **aber Bestandsbenutzern nicht automatisch zugewiesen** (siehe 4.9). | ✅ + manueller Schritt |
| 5 | Zeebe: RocksDB-Speicherstrategie `PARTITION` → `FRACTION`; ES-Exporter-Replicas 0 → 1 | Wir pinnen `PARTITION`. Die Replicas stehen bereits explizit auf `0`. | ✅ |
| 6 | Zeebe blockiert Upgrades von und zu Pre-Release-Versionen | Nur GA-zu-GA-Upgrades sind möglich. | Hinweis |
| 7 | Optimize authentifiziert über die Camunda Security Library (CSL). Die `CAMUNDA_OPTIMIZE_IDENTITY_*`-Keys sind deprecated und entfallen in 8.11. | Die Legacy-Keys funktionieren in 8.10 weiter (werden intern übersetzt). `security.auth.cookie.same-site` entfällt ersatzlos. | ✅ / TODO vor 8.11 |
| 8 | Optimize zerlegt Objekt-Variablen standardmäßig nicht mehr in Einzelfelder. | Reports auf `obj.feld` würden brechen. | ✅ 8.9-Verhalten beibehalten (`includeObjectVariableValue: true`) |
| 9 | Connectors: Secret-Filter-Default `DISABLED` → `STRICT`; JWT-Webhooks verlangen `iss`/`aud`/`exp`; AWS SDK v2 | Aufgelöst werden nur noch Secrets, die im Connector-Template deklariert sind. | ✅ `STRICT` explizit gesetzt, Test nötig |
| 10 | Operate-/Tasklist-v1-API, Tasklist-V1-Mode, Zeebe Java Client und Zeebe Process Test **entfernt** | Externe Worker und Clients müssen den Camunda Java Client und die v2-API nutzen. | Außerhalb des Repos (siehe 2.2) |
| 11 | Hub: `camunda.modeler.*` → `camunda.hub.*`, `PLAY_ENABLED` → `TEST_MODE_ENABLED`, Komponententyp `orchestrationIdentity` → `admin`; `console`/`keycloak` sind als Typ ungültig | Wird in 8.10 noch übersetzt (Deprecation-Warnung). | ✅ neue Keys verwendet |
| 12 | Neu (optional): zentrale Secrets (`=camunda.secrets.NAME`), Physical Tenants, Business ID | Nur Opt-in. Die bestehende Konfiguration wird zum `default`-Tenant. | ✅ `./secrets` gemountet |
| 13 | Unterstützt: Elasticsearch 8.19+ / 9.4+, PostgreSQL ≥ 15 | ES 8.19.22 und PostgreSQL 15 sind in Ordnung. | ✅ |

Nicht betroffen: Helm v4, Bitnami-Keycloak (bereits `camunda/keycloak`), die Einzel-Images `camunda/zeebe`, `camunda/operate` und `camunda/tasklist` (wir nutzen `camunda/camunda`).

---

## 2. Voraussetzungen und Entscheidungen

### 2.1 Versionsstand

- Upgrades sind nur Minor für Minor möglich (8.9 → 8.10). **8.9.19 ist ein gültiger Ausgangspunkt.** Camunda empfiehlt den jeweils neuesten 8.9-Patch; upstream war am 25.09. bei 8.9.21. Einspielen kann man ihn vorher optional als eigenes Patch-Update.
- **Zeebe-Datenstand prüfen:** Der Stand im Volume kann älter sein als `.env` suggeriert. Lokal war er z. B. `8.9.6`. Das ist für 8.9 → 8.10 unkritisch.
- Das Ziel muss ein GA-Tag sein (siehe Hinweis oben).

### 2.2 Clients und Worker (außerhalb dieses Repos)

Diese Clients funktionieren gegen 8.10 **nicht mehr** und müssen **vor** dem Upgrade migriert werden. Das geht bereits gegen 8.9, weil 8.9 beide APIs anbietet.

- Aufrufe der Operate-API (`/v1/process-instances`, …) oder der Tasklist-API (`/v1/tasks`, …) → Orchestration Cluster API v2
- `io.camunda:zeebe-client-java` / `spring-zeebe` → `camunda-client-java` / `camunda-spring-boot-starter` (siehe `docs/zeebe-spring-boot-worker.md`)
- `zeebe-process-test` → Camunda Process Test
- Hinweis: Der Java-Client cached OAuth-Tokens jetzt standardmäßig nur im Speicher. Eine Datei-Ablage ist nur noch per `camunda.client.auth.credentials-cache-path` möglich.

Leitfäden: [Migrate to Camunda API](https://docs.camunda.io/docs/next/apis-tools/migration-manuals/migrate-to-camunda-api/), [Migrate to Camunda Java Client](https://docs.camunda.io/docs/next/apis-tools/migration-manuals/migrate-to-camunda-java-client/)

### 2.3 Fachliche Entscheidungen (im Branch vorbelegt)

| Thema | Vorbelegung | Wann ändern |
|---|---|---|
| Optimize-Objekt-Variablen | `zeebe.includeObjectVariableValue: true` (wie 8.9) | Auf `false` setzen, wenn kein Report Felder von Objekt-Variablen nutzt (spart Speicher). |
| Connectors-Secret-Filter | `STRICT` (neuer 8.10-Default) | Nur temporär `DISABLED`, falls Templates brechen; danach die Templates korrigieren. |
| RocksDB-Speicherstrategie | `PARTITION` (wie 8.9) | Bewusst auf `FRACTION` wechseln (Camunda-Sizing-Doku). |
| Hub-URL | `https://webmodeler.{HOST}`; `console.{HOST}` leitet per 302 um | Eine neue Subdomain `hub.{HOST}` erfordert Hosts, Caddy, `RESTAPI_SERVER_URL`, `CLIENT_PUSHER_HOST`, Identity `root-url` **und** Keycloak-Redirect-URIs. |
| Variablennamen | `WEBMODELER_*` bleiben (keine Umbenennung zu `HUB_*`) | Als späteres Refactoring. Die Werte müssen dabei 1:1 übernommen werden (DB-Passwort!). |

### 2.4 Ressourcen

- Hub ersetzt zwei Dienste. Die Limits im prod-Profil liegen jetzt bei 1,5 CPU / 2 GB (vorher Web Modeler 1 GB + Console 1 GB). Der Gesamtbedarf ist also ungefähr gleich.
- Das `prod`-Profil braucht allein für die festen JVM-Heaps über 11 GB RAM. Auf Rechnern mit kleiner Docker-VM (z. B. 8 GB) deshalb `stages/dev.yaml` verwenden (siehe 8.5).
- Plattenplatz für Backups einplanen. Lokal waren alle Volumes zusammen ~330 MB groß, gepackt ~31 MB.

---

## 3. Branch auf GA umstellen (vor dem ersten Produktiv-Upgrade)

Sobald 8.10 GA ist, im Branch:

1. **Tags ermitteln** mit `bash scripts/registry-info.sh` (Default-Modus listet `camunda`, `optimize`, `identity`, `connectors-bundle`, `hub`, `hub-websockets`, `keycloak`) oder über Docker Hub.
2. **`.env` und `.env.example`** anpassen:
   ```dotenv
   CAMUNDA_VERSION=8.10.x
   CAMUNDA_CONNECTORS_VERSION=8.10.x
   CAMUNDA_OPTIMIZE_VERSION=8.10.x
   CAMUNDA_HUB_VERSION=8.10.x          # Hub-Tag prüfen; RC-Tags hießen z. B. "8.10-rc1"
   CAMUNDA_IDENTITY_VERSION=8.9.9      # bzw. 8.10.x, falls Camunda ein verifiziertes Identity-8.10-Tag veröffentlicht
   ELASTIC_VERSION=8.19.22             # oder aktueller 8.19.x-Patch
   ```
3. **Secfix-/Hotfix-Images:** Mit `scripts/registry-info.sh --project hotfixes-ee` prüfen, ob es 8.10-Hotfix-Images gibt. Falls ja, `CAMUNDA_IMAGE`, `CAMUNDA_CONNECTORS_IMAGE`, `HUB_IMAGE` und `HUB_WEBSOCKETS_IMAGE` in `.env` setzen.
4. **Release Notes des GA-Patches** gegen Kapitel 1 und 9 abgleichen. Besonders prüfen: ob Hub die Legacy-OIDC-Keys noch übersetzt, ob sich Property-Namen geändert haben, und das Upstream-Compose `camunda-distributions/docker-compose/versions/camunda-8.10` auf neue Commits.
5. **Validieren:**
   ```bash
   for st in prod dev test; do
     docker compose --env-file .env --env-file .env-credentials \
       -f docker-compose.yaml -f stages/$st.yaml config --quiet && echo "$st OK"
   done
   ```
6. **Restore-Drill** mit einem aktuellen Prod-Backup gegen den Branch (`scripts/restore-drill.sh`). Das ist die einzige realistische Probe von Zeebe-, Hub- und Optimize-Migration an Echtdaten.
7. Merge nach `master`.

---

## 4. Runbook: bestehende Umgebung upgraden

Gilt pro Umgebung (Server oder lokal). Die Downtime beträgt erfahrungsgemäß 15–30 Minuten.

### 4.1 Downtime ankündigen und Clients prüfen

Alle Worker und Clients müssen bereits migriert sein (2.2).

### 4.2 Kalt-Backup und Verifikation

```bash
bash scripts/backup.sh
bash scripts/restore.sh --verify backups/<ordner>
```

Das Backup enthält die Dumps von Keycloak, Camunda-DB und **Web-Modeler-/Hub-DB** (`webmodeler.sql.gz`), den Zeebe-State, einen ES-Snapshot und die Configs. **Ohne dieses Backup gibt es kein Rollback.**

> **Achtung, Retention:** `backup.sh`/`backup.ps1` löschen standardmäßig Backups, die älter als **7 Tage** sind. Das 8.9-Backup vor dem Upgrade deshalb zusätzlich außerhalb von `backups/` sichern oder spätere Backups mit `--retention-days <n>` ausführen, damit der Rollback-Stand nicht automatisch verschwindet.

### 4.3 Stack stoppen

```bash
bash scripts/stop.sh
```

Während der Hub-Migration darf kein Web-Modeler-8.9-Container mehr laufen.

### 4.4 Code ausrollen

- Per CI (`gitlab-ci.txt`) oder `git pull` auf den gemergten Stand.
- **Achtung:** Das CI-rsync **überschreibt `.env`, `.env-credentials`, `Caddyfile`, `connector-secrets.txt` und `secrets/*` nicht**. Diese Dateien pflegt man auf dem Server per Hand (4.5–4.7).
- **Dateirechte (bei manuellem `git pull`):** Sicherstellen, dass `.hub/application.yaml` für den Hub-Containerprozess (UID 1001) lesbar ist: `chmod 0644 .hub/application.yaml` (im CI-Script `gitlab-ci.txt` bereits automatisiert).
- **Alte Console-Dateien bereinigen:** Das frühere Template `.console/application.yaml.template` wurde aus Git gelöscht. Auf dem Server verbliebene, gerenderte 8.9-Dateien im Verzeichnis `.console/` können gefahrlos entfernt werden: `rm -rf .console/`.

### 4.5 Server-`.env` anpassen (manuell!)

| Aktion | Variable |
|---|---|
| **Neu (Pflicht)** | `CAMUNDA_HUB_VERSION=<GA-Tag>`. Ohne diesen Wert bricht Compose mit `CAMUNDA_HUB_VERSION is required` ab. |
| Aktualisieren | `CAMUNDA_VERSION`, `CAMUNDA_CONNECTORS_VERSION`, `CAMUNDA_OPTIMIZE_VERSION`, `ELASTIC_VERSION` (ggf. `CAMUNDA_IDENTITY_VERSION`) |
| Entfernen | `CAMUNDA_WEB_MODELER_VERSION`, `CAMUNDA_CONSOLE_VERSION`, `CAMUNDA_OPERATE_VERSION`, `CAMUNDA_TASKLIST_VERSION` (werden nicht mehr genutzt) |
| Entfernen/ersetzen | 8.9-Secfix-Overrides `CAMUNDA_IMAGE`, `CAMUNDA_CONNECTORS_IMAGE`, `WEBMODELER_RESTAPI_IMAGE`, `WEBMODELER_WEBSOCKETS_IMAGE`. Hotfix-Overrides heißen jetzt `HUB_IMAGE` / `HUB_WEBSOCKETS_IMAGE`. |
| Unverändert | `WEBMODELER_MAIL_FROM_ADDRESS`, `STAGE`, `DISPLAY_STAGE` (wird zum Hub-Cluster-Tag), `HOST`, TLS-Pfade |

Am einfachsten ist ein Vergleich mit `diff .env.example .env`.

### 4.6 `.env-credentials`

- Es gibt **keine neuen Pflicht-Secrets**. `WEBMODELER_DB_*` und `WEBMODELER_PUSHER_*` bleiben unverändert, Hub nutzt dieselbe Datenbank.
- `CONSOLE_CLIENT_SECRET` wird nicht mehr verwendet und kann entfernt werden.
- **Nicht** `scripts/generate-secrets.sh` auf einer bestehenden Umgebung ausführen. Das Skript generiert neue Passwörter, die dann nicht mehr zu den bestehenden Datenbanken passen.

### 4.7 Caddyfile und Hosts neu erzeugen

```bash
sudo bash scripts/setup-host.sh          # Linux
pwsh -File scripts/setup-host.ps1         # Windows, als Administrator
```

Das rendert `Caddyfile` aus `Caddyfile.example`: Hub-Upstreams `hub:8081` bzw. `hub:8091` und `hub-websockets:8060`, dazu der Redirect `console.{HOST}` → `webmodeler.{HOST}`. Die Hosts-Einträge bleiben unverändert (`console.{HOST}` bleibt für den Redirect erhalten).

- **Wichtig:** `setup-host` legt die `Caddyfile` als **neue Datei** an. Ein laufender `reverse-proxy`-Container sieht über den Single-File-Bind-Mount weiter die alte Datei, und `caddy reload` lädt deshalb den alten Stand. Auch `start.sh` erzeugt den Container nicht neu, weil sich die Compose-Konfiguration nicht ändert. Deshalb nach `setup-host` bei laufendem Stack: `docker restart reverse-proxy`. Beim Upgrade-Ablauf (Stack gestoppt, dann `start.sh`) ist das automatisch erfüllt.
- `setup-host` markiert seine Hosts-Einträge jetzt mit `# camunda-compose-nvl` und ist idempotent. Einträge, die ältere Versionen **ohne** diese Markierung geschrieben haben (PowerShell-Variante), einmalig von Hand aus der Hosts-Datei entfernen. Der alte, kaputte Einzeilen-Block der Bash-Variante wird automatisch entfernt.

### 4.8 Validieren und starten

```bash
docker compose --env-file .env --env-file .env-credentials \
  -f docker-compose.yaml -f stages/<stage>.yaml config --quiet
bash scripts/start.sh
```

`start.sh` startet zuerst Elasticsearch, führt dann das **Optimize-Schema-Upgrade** aus (`Updating Optimize data structure version tag from 8.9 to 8.10.0 … Update finished successfully`) und startet danach den Rest.

Während des Starts die Logs beobachten:

| Container | Erwartung | Befehl |
|---|---|---|
| `orchestration` | `Starting processing N migration tasks` und kein `Cannot upgrade … pre-release`; Health `UP` | `docker logs -f orchestration`, `curl -s http://127.0.0.1:9600/actuator/health/status` |
| `hub` | `Successfully applied N migrations to schema "public"` und `Started ModelerSelfManagedApp`; kein `APPLICATION FAILED TO START` | `docker logs -f hub` |
| `optimize` | healthy | `docker logs optimize` |

Die Hub-Healthcheck-`start_period` beträgt 600 s. Autoheal startet Hub also während einer langen Migration nicht neu.

### 4.9 Identity/Keycloak nacharbeiten (manuell!)

Getestet auf einem echten 8.9-Realm (8.3):

- ✅ Identity legt die Rollen `Hub`, `Hub Admin`, `Analyst` und `DevOps` sowie die Permissions `admin:clusters`, `admin:catalog` und `admin:bi` automatisch an.
- ⚠️ **Bestandsbenutzer behalten nur ihre alten Rollen** (`Web Modeler`, `Web Modeler Admin`, `Console`). Die alte Rolle `Console` bekommt dabei **kein** `admin:clusters`.
- Die alten Keycloak-Clients `console` und `console-api` bleiben stehen.

Deshalb im Keycloak-Admin (`https://keycloak.{HOST}/auth/` → Realm `camunda-platform`) oder in Identity (`https://identity.{HOST}`):

| Bisherige Rolle | Zusätzlich zuweisen |
|---|---|
| `Web Modeler` | `Hub` |
| `Web Modeler Admin` | `Hub Admin` |
| `Console` | `DevOps` (Cluster-Verwaltung in Hub) |
| Fachanwender mit Optimize und Modellierung | ggf. `Analyst` |

Danach optional aufräumen, wenn alle Benutzer umgestellt sind: die Rollen `Console`, `Web Modeler` und `Web Modeler Admin` sowie die Clients `console` und `console-api`. Neue Benutzer über `scripts/add-camunda-user.*` bekommen bereits die neuen Rollen.

### 4.10 Verifikation und Abschluss

- Die Checkliste in [Kapitel 7](#7-verifikation-nach-dem-upgrade) abarbeiten.
- Danach ein neues Backup (`bash scripts/backup.sh`) als erster 8.10-Stand.
- Server-Bereinigung: Falls noch vorhanden, das alte Console-Konfigurationsverzeichnis vom Server löschen (`rm -rf .console/`).
- Anwender informieren: Web Modeler und Console heißen jetzt **Camunda Hub** unter `https://webmodeler.{HOST}`; Projekte sind neu strukturiert („`<Projekt> - General`“); „Play“ heißt jetzt „Test mode“.

---

## 5. Rollback

Ein Downgrade von 8.10 auf 8.9 ist von Camunda **nicht unterstützt**. Zeebe-State, Hub-DB und Optimize-Schema werden migriert. Deshalb geht ein Rollback nur so:

1. `bash scripts/stop.sh`
2. Repo auf den letzten 8.9-Stand zurücksetzen (`git checkout <8.9-commit>`), Server-`.env` und `Caddyfile` wieder auf 8.9 bringen (`setup-host` erneut ausführen).
3. `bash scripts/restore.sh backups/<8.9-backup>`, also vollständiger Restore von Keycloak, Camunda-DB, Hub-/Web-Modeler-DB, Zeebe und Elasticsearch.
4. `bash scripts/start.sh` und Verifikation.

Ein 8.9-Backup lässt sich umgekehrt jederzeit in eine 8.10-Umgebung einspielen. Hub und Optimize migrieren beim Start erneut.

---

## 6. Änderungen im Branch (Referenz)

### 6.1 Versionen und Credentials

| Datei | Änderung |
|---|---|
| `.env`, `.env.example` | 8.10-Versionen (derzeit RC), `CAMUNDA_HUB_VERSION` neu; `CAMUNDA_WEB_MODELER_VERSION`, `CAMUNDA_CONSOLE_VERSION`, `CAMUNDA_OPERATE_VERSION`, `CAMUNDA_TASKLIST_VERSION` und die 8.9-Secfix-Overrides entfernt; Hotfix-Beispiele `HUB_IMAGE` / `HUB_WEBSOCKETS_IMAGE` |
| `.env-credentials.example` | `CONSOLE_CLIENT_SECRET` entfernt; `WEBMODELER_*` als Hub-Werte kommentiert |

### 6.2 `docker-compose.yaml`

- **`console` entfernt** (Ports `8087` und `9100` werden frei).
- **`web-modeler-restapi` → `hub`** (`camunda/hub`, `${HUB_IMAGE}`-Override), Port `127.0.0.1:8070 → 8081`, Management/Health auf `8091`:
  - DB: `web-modeler-db` / `${WEBMODELER_DB_*}` unverändert. Die Datenbank wird in place migriert.
  - `RESTAPI_PUSHER_HOST: hub-websockets`
  - OIDC über die Legacy-Keys `RESTAPI_OAUTH2_TOKEN_ISSUER(_BACKEND_URL)`, `SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI` / `_JWK_SET_URI`, `OAUTH2_CLIENT_ID=web-modeler`, `OAUTH2_TOKEN_ISSUER`. Hub 8.10 übersetzt sie auf `camunda.security.authentication.oidc.*` (siehe 9.2).
  - **`SERVER_FORWARD_HEADERS_STRATEGY: framework`**: ohne dieses Flag leitet Hub auf `http://…/login` um (8.4).
  - `TEST_MODE_ENABLED: "true"` (ersetzt `PLAY_ENABLED`)
  - `CAMUNDA_MODELER_CLUSTERS_0_*` entfernt; stattdessen wird `.hub/application.yaml` read-only nach `/home/runner/config/application.yaml` gemountet.
  - Werte für die Cluster-Registrierung: `HOST`, `HUB_CLUSTER_TAG` (= `DISPLAY_STAGE`, sonst `STAGE`), `RESOURCE_AUTHORIZATIONS_ENABLED` sowie die Versionen von Camunda, Optimize, Connectors und Identity.
  - Ressourcen 1,5 CPU / 2 GB, `-Xmx1280m`; Healthcheck `start_period: 600s`.
- **`web-modeler-websockets` → `hub-websockets`** (`camunda/hub-websockets`, `${HUB_WEBSOCKETS_IMAGE}`-Override), sonst unverändert.
- **`init: true`** für `hub-websockets` und `optimize`: Beide Images haben einen Shell-Wrapper als PID 1, der SIGTERM nicht weiterreicht (siehe 6.7).
- **`identity`:** `VALUES_KEYCLOAK_INIT_CONSOLE_SECRET` entfernt.
- **`orchestration`:** `CAMUNDA_SECRETS_STORES_FILE_DEFAULT_PATH=/etc/camunda/secrets`, Mount `./secrets:/etc/camunda/secrets:ro` (zentrale Secrets, Opt-in).
- **Beibehalten:** Service/Volume `web-modeler-db` / `postgres-web`, Netzwerk `web-modeler`, Audience `web-modeler-api` in Orchestration. Bitte **nicht umbenennen**, sonst startet Hub mit leerer Datenbank.

### 6.3 Neue Datei `.hub/application.yaml`

Sie registriert zwei Cluster unter `camunda.hub.clusters`:

- `management`: Identity (`type: identity`, `webapp: https://identity.${HOST}`)
- `camunda-platform`: Orchestration (gRPC/REST intern), Operate, Tasklist, Admin (`type: admin`), Optimize, Connectors. Browser-URLs laufen über den Proxy.

Regeln:
- Die Cluster-`version` muss **vollständiges SemVer** sein (`${CAMUNDA_VERSION}`), sonst startet Hub nicht (8.4).
- Die Typen `console` und `keycloak` sind ungültig.
- Kein `configprops`-Endpoint (Gotcha 22).
- Die Datei ist statisch; Spring löst die Platzhalter aus dem Container-Environment auf.

### 6.4 Anwendungs-Konfigurationen

| Datei | Änderung |
|---|---|
| `.identity/application.yaml` | Console-Preset, Console-Client und Init-Secret entfernt. `webmodeler`-Preset in „Hub“ umbenannt; Client-ID `web-modeler` und Audiences bleiben. Neue Permissions `admin:clusters`, `admin:catalog` und `admin:bi`; neue Rollen `Hub`, `Hub Admin`, `Analyst` (auch im Optimize-Preset) und `DevOps`. Demo-User: `ManagementIdentity, Optimize, Analyst, Hub, Hub Admin, DevOps, Orchestration`. |
| `.orchestration/application.yaml` | `camunda.data.primary-storage.rocks-db.memory-allocation-strategy: PARTITION`; Kommentar zu `number-of-replicas: 0`; MCP-Kommentar |
| `.connectors/application.yaml` | `camunda.connector.secret-resolver.secret-filter.mode: STRICT` |
| `.optimize/environment-config.yaml.example` | `security.auth.cookie.same-site` entfernt; `zeebe.includeObjectVariableValue: true` |
| `.console/application.yaml.template` | gelöscht (inklusive `.gitignore`-Eintrag für die gerenderte Datei) |
| `secrets/.gitignore` | neu; der Verzeichnisinhalt wird nie committet |

### 6.5 Proxy und Dashboard

- `Caddyfile.example`: `console.{HOST}` → `redir https://webmodeler.{HOST}{uri} 302` (`/health` → Hub-Readiness). Der `webmodeler.{HOST}`-Block zeigt auf `hub:8081`, `/app/*` auf `hub-websockets:8060` und `/health` auf `hub:8091/health/readiness`.
- `dashboard/index.html`: Die Karten „Web Modeler“ und „Console“ sind zu „Camunda Hub“ zusammengeführt.

### 6.6 Skripte, Stages, CI

| Datei | Änderung |
|---|---|
| `scripts/start.sh` / `start.ps1` | Console-Rendering entfernt; `DISPLAY_STAGE` (Fallback `STAGE`) wird exportiert und landet als `HUB_CLUSTER_TAG` im Hub |
| `scripts/add-camunda-user.*` | `NormalUser` → `…, Hub`; `Admin` → `Hub, Hub Admin, DevOps, …` |
| `scripts/backup.*` | Config-Archiv enthält `.hub/application.yaml` statt `.console/application.yaml`; Hub-DB-Dump unverändert (`webmodeler.sql.gz`) |
| `scripts/restore.*`, `scripts/rehost-keycloak.sql` | `console_secret` und die Console-Client-Rehosts entfernt |
| `scripts/generate-secrets.*` | `CONSOLE_CLIENT_SECRET` entfernt |
| `scripts/logs.sh`, `scripts/registry-info.*`, `scripts/build_deployment_package.ps1` | Service- und Image-Namen `hub` / `hub-websockets`; Paket enthält `.hub/application.yaml` und `secrets/.gitignore` |
| `scripts/lib/drill-common.*`, `stages/drill.yaml` | Drill-Container/Ports für `hub` (`8070+offset → 8081`, `8071+offset → 8091`) und `hub-websockets`. Die Drill-Stage war auf `master` defekt (verwaister Service `web-modeler-webapp`). |
| `scripts/setup-host.test.ps1` | prüft den Redirect statt des Console-Font-Workarounds; `start-console-template.test.ps1` gelöscht |
| `stages/prod|dev|test.yaml` | `hub` ersetzt `web-modeler-restapi` + `console` (prod 1,5 CPU / 2 GB, dev 1 CPU / 1 GB `-Xmx640m`, test 1 CPU / 768 MB `-Xmx512m`); `hub-websockets` |
| `gitlab-ci.txt` | rsync schließt `secrets/*` aus (außer `.gitignore`); `chmod 0644` für `.hub/application.yaml` statt `.console/…` |

### 6.7 Skript-Prüfung (alle `.sh` und `.ps1`)

Alle Skripte wurden statisch geprüft (`bash -n`, PowerShell-Parser, alle `*.test.ps1` grün) und, wo gefahrlos möglich, gegen den laufenden 8.10-Stack ausgeführt. Dabei gefundene und behobene Fehler (größtenteils schon vor 8.10 vorhanden):

| Skript | Fehler | Fix |
|---|---|---|
| `optimize-upgrade.sh` / `.ps1` | Compose ohne Stage-Overlay: `up -d optimize` hat Optimize **und** Elasticsearch, Identity, Keycloak und Postgres mit Basis-Ressourcen neu erzeugt (lokal ES-OOM-Loop) | liest `STAGE`, nutzt `-f stages/<stage>.yaml` und `up -d --no-deps optimize` |
| `optimize-upgrade.sh` | Das globale `export MSYS_NO_PATHCONV=1` hat unter Git Bash die Host-Pfade kaputt gemacht (`couldn't find env file: C:\c\Users\...`); das Skript brach nach „Stopping …“ ab | Export entfernt; nur noch der `//optimize/...`-Doppelslash wie in `start.sh` |
| `ensure-stack.ps1` | kein `--env-file .env-credentials` → Interpolation schlug fehl, trotzdem „All expected services are running“ | beide Env-Dateien, Abbruch bei Config-Fehlern |
| `ensure-stack.sh` / `.ps1` | Einmal-Container `camunda-data-init` galt als „fehlend“ und wurde bei jedem Cron-Lauf neu gestartet | ausgeschlossen (wie in `monitor.*`); `DISPLAY_STAGE`-Fallback wie `start.*` |
| `lib/backup-common.sh` (`backup.sh`, `restore.sh`) | Health-Check parste `docker compose ps --format json` als Array; Compose v2 liefert NDJSON → Prüfung meldete **immer** „healthy“ | NDJSON und Array, `ps -a` (gestoppte Dienste fallen auf), `camunda-data-init` ausgenommen |
| `lib/backup-common.ps1` | `camunda-data-init` (Exit 0) als „not running“ gewarnt | ausgenommen |
| `lib/backup-common.ps1` | Aus Git Bash gestartet, fand PowerShell das GNU-`tar` von Git (`Cannot connect to C: resolve failed`) → Restore meldete Archive als unlesbar | `System32` (Windows-`tar`) im PATH vorangestellt |
| `backup.ps1` / `restore.ps1` | `--env-file` nicht als erstes Argument → Argumente verschmolzen zu einem String (PowerShell-Slice mit einem Element) → nur Hilfe ausgegeben | Slices mit `@()` |
| `restore.sh` | Dry-Run nannte `camunda-db` nicht und kannte den Zweig `--components camunda` nicht (die echte Ausführung war korrekt) | Meldungen angeglichen |
| `setup-host.sh` | Hosts-Block mit wörtlichem `\n` in **einer** Zeile geschrieben → unter Linux keine Namensauflösung der Subdomains | eine Zeile pro Eintrag, markiert, idempotent |
| `setup-host.ps1` | alte `127.0.0.1`-Zeilen wurden nie entfernt → Duplikate bei jedem Lauf | markierte Zeilen werden ersetzt |
| `Caddyfile.example` | `/health`-Routen lieferten 404/302 statt echter Readiness (lokale `Caddyfile` war abgewichen) | Keycloak `9000/auth/health/ready`, Optimize `/api/readyz`, Orchestration `9600/actuator/health/readiness`; Console-Redirect in `handle` gekapselt (sonst wurde auch `/health` umgeleitet) |
| `docker-compose.yaml` | `optimize` und `hub-websockets` ignorierten SIGTERM (Shell-Wrapper als PID 1) → jeder Stopp/jedes Backup wartete 180 s und endete mit SIGKILL | `init: true` → Stopp in ~1 s (Backup-Stoppphase 3:05 min → 8 s) |
| `preflight.sh` | Label „8.9“, Console-Ports `8087`/`9100` in der Port-Prüfung | aktualisiert |
| `build_deployment_package.ps1` | neuer Leitfaden fehlte im Paket | `docs/upgrade-8.10.md` aufgenommen |
| `restore-components.test.ps1` | erwartete Komponentenliste ohne `camunda` (Test veraltet, schlug schon auf `master` fehl) | an die Skripte angepasst |

**Funktional getestet** (lokal, `dev`-Profil): `start`/`stop` (sh + ps1), `monitor`, `ensure-stack` (inklusive gestopptem Dienst), `logs.sh`, `registry-info`, `setup-host` (Temp-Hosts-Datei), `add-camunda-user` (Admin + NormalUser, danach gelöscht), `build_deployment_package.ps1`, `optimize-upgrade` (sh + ps1), `backup` (sh + ps1, echt), `restore --verify`/`--dry-run` (sh + ps1) und **ein echter vollständiger Restore** (sh) des 8.10-Backups.

**Nicht funktional getestet:** `restore-drill.*` (braucht einen zweiten kompletten Stack, zu wenig RAM in der lokalen VM; Compose-Konfiguration der Drill-Stage ist validiert), `generate-secrets.*` (würde `.env-credentials` überschreiben; nur per Test abgedeckt), `preflight.sh` (nur Linux).

### 6.8 Dokumentation

README, `docs/update_guide.md`, `project_configuration.md`, `monitoring.md`, `stage_comparison.md`, `backup-restore.md`, `operations-handover-template.md`, `agentic-ai.md` und die Architekturdiagramme (`.mmd` + `.png`) sind auf Hub umgestellt.

**Nicht im Repo:** `CLAUDE.md` ist gitignored und gilt branch-übergreifend. Nach dem Merge dort anpassen: Service-, Netzwerk- und Port-Tabellen (console/web-modeler → hub), die Abschnitte „Display Stage Override“ und „Rendered configs“ (kein Console-Rendering mehr) sowie die Gotchas 3, 4, 11, 12, 23, 24 und 25 (Console/Web Modeler → Hub). Neu aufzunehmen: Hub braucht `SERVER_FORWARD_HEADERS_STRATEGY`, die Cluster-Version muss SemVer sein, und Zeebe blockiert Pre-Release-Upgrades.

---

## 7. Verifikation nach dem Upgrade

1. `docker compose ps`: alle Container `healthy`, keine Restart-Loops (`docker inspect -f '{{.RestartCount}}' <c>`).
2. `curl -s http://127.0.0.1:9600/actuator/health/status` → `{"status":"UP"}`.
3. Hub-Log: Flyway erfolgreich, kein `APPLICATION FAILED`, keine Fehler zu Komponententypen.
4. Proxy-Redirects (ohne Browser):
   ```bash
   H=<HOST>
   curl -sk -o /dev/null -w '%{http_code} %{redirect_url}\n' https://webmodeler.$H/   # 302 -> https://webmodeler.$H/login  (https!)
   curl -sk -o /dev/null -w '%{http_code} %{redirect_url}\n' https://console.$H/      # 302 -> https://webmodeler.$H/
   curl -sk -o /dev/null -w '%{http_code}\n' https://webmodeler.$H/health              # 200
   ```
5. Browser: Login in Hub ohne „login has expired“-Schleife (Gotcha 13). Bestehende Projekte sind vorhanden. Echtzeit-Updates (WebSocket) funktionieren.
6. Hub-Cluster-Übersicht: `camunda-platform` und `management` mit allen Komponenten grün, Links zeigen auf Proxy-URLs, Tag = `DISPLAY_STAGE`.
7. Aus Hub deployen und eine Instanz starten; Test-Mode funktioniert.
8. Operate, Tasklist und Admin: laufende Instanzen aus 8.9 sind sichtbar und laufen weiter.
9. Optimize: Login, bestehende Reports liefern Daten (insbesondere Objekt-Variablen).
10. Connectors: eine Instanz mit Secret-Nutzung (Outbound) und ein Inbound-/Webhook-Connector.
11. Rollen: Ein Benutzer mit `DevOps` sieht das Cluster-Management, ein Benutzer nur mit `Hub` nicht.
12. Externe Worker und Clients verbinden sich (gRPC über `zeebe.{HOST}`, REST v2).
13. `bash scripts/backup.sh` und `restore.sh --verify` auf dem neuen Stand.

---

## 8. Testergebnisse lokal (RC-Images)

Umgebung: Windows, Docker Desktop (Hyper-V, 8,3 GB VM-RAM), `stages/dev.yaml`, Images `8.10.0-rc2` / Hub `8.10-rc1`.

1. **Zeebe-Migration auf einen RC ist blockiert:** `IllegalStateException: Cannot upgrade to or from a pre-release version: UseOfPreReleaseVersion[from=8.9.6, to=8.10.0-rc2]`. Die Partition bleibt dann im Schritt `Migration` hängen. Nur für Tests lässt sich das mit `CAMUNDA_SYSTEM_UPGRADE_ENABLEVERSIONCHECK=false` umgehen; damit liefen 23 Migrationstasks sauber durch. **Diesen Schalter niemals in Prod oder im Repo setzen.**
2. **Die Hub-DB-Migration funktioniert:** `Successfully applied 42 migrations to schema "public", now at version v20260915` in unter 1 s (lokale Datenmenge).
3. **Das Optimize-Schema-Upgrade funktioniert:** 3 Schritte, `data structure version tag from 8.9 to 8.10.0`.
4. **Zwei Fehler gefunden und behoben:**
   - Die Cluster-Version `8.10-rc1` (Hub-Image-Tag) wird nicht als SemVer akzeptiert → `APPLICATION FAILED TO START … authorizations must not be set if 'version' is lower than 8.8`. Fix: `${CAMUNDA_VERSION}`.
   - Hub leitete auf `http://webmodeler.{HOST}/login` um. Fix: `SERVER_FORWARD_HEADERS_STRATEGY: framework`.
5. Das `prod`-Profil passt nicht in eine 8-GB-Docker-VM (JVM-Heaps über 11 GB).
   - Manueller Direktstart ohne Änderung der `.env`:
     ```bash
     DISPLAY_STAGE=<Label> docker compose --env-file .env --env-file .env-credentials \
       -f docker-compose.yaml -f stages/dev.yaml up -d
     ```
   - **Achtung bei Skripten (`start.sh` / `start.ps1`, `ensure-stack.*`, `optimize-upgrade.*`):** Die Skripte lesen `STAGE` direkt aus `.env` (Default `STAGE=PROD`) und binden `stages/prod.yaml` ein. Auf einer 8-GB-Docker-VM führt das sofort zum OOM-Kill (Exit Code 137) von Elasticsearch. Für lokale Entwicklungs- und Testläufe per Skript daher in der lokalen `.env` temporär **`STAGE=dev`** hinterlegen (mit optionalem `DISPLAY_STAGE=TEST`).
6. Frischer Aufbau from scratch: alle 14 Container sind healthy, Zeebe `UP`. Alle Proxy-URLs antworten; Orchestration nutzt den Callback `/sso-callback`, Optimize (CSL) weiterhin `/api/authentication/callback`. Es sind keine Keycloak-Änderungen nötig.
7. **Identity auf einem 8.9-Realm** (gesicherte 8.9-Keycloak-DB + Identity 8.9.9 mit neuer Konfiguration): Neue Rollen und Permissions werden angelegt, Bestandsbenutzer behalten nur ihre alten Rollen, `Console` erhält kein `admin:clusters`, und die Clients `console`/`console-api` bleiben stehen. Daraus ergibt sich Schritt 4.9.
8. Docker Desktop wurde unter Speicherdruck instabil (`error during connect … EOF` beim Anlegen von Containern). Ein `docker desktop restart` hat das behoben.
9. Die Skript-Prüfung (6.7) hat mehrere Fehler in Betriebs-Skripten gefunden und behoben, darunter `optimize-upgrade` (Stage-Overlay) und den wirkungslosen Health-Check in `backup.sh`/`restore.sh`.

---

## 9. Offene Punkte und TODOs

### 9.1 Vor dem Produktiv-Upgrade

| Punkt | Status |
|---|---|
| GA-Tags für `camunda`, `connectors-bundle`, `optimize`, `hub`, `hub-websockets` eintragen | Offen (GA am 13.10.2026) |
| Gibt es ein verifiziertes `camunda/identity:8.10.x`? | Offen; auf Docker Hub gab es nur `8.10.0-alpha*`, upstream bleibt bei `8.9.9` |
| 8.10-Hotfix-/Secfix-Images | Offen (`scripts/registry-info.sh`) |
| Restore-Drill mit Prod-Backup auf GA-Images (Zeebe + Hub + Optimize an Echtdaten, Laufzeit messen) | Offen |
| Browser-Login in Hub inklusive Gotcha 13 (Chrome-Iframe-Session-Check) | Offen, bisher nur per `curl` geprüft |
| Hub-Cluster-Übersicht und Deploy aus Hub im Browser prüfen | Offen |
| Worker/Clients auf v2-API und Camunda Java Client | Offen, außerhalb des Repos |
| Connector-Templates mit Secret-Filter `STRICT` testen | Offen |
| `camunda.data.primary-storage.snapshot-period` in `.orchestration/application.yaml` | Das 8.10-Konfigurationsmodell kennt nur `camunda.data.snapshot-period`. Der Key wird vermutlich ignoriert; der Default ist ebenfalls `5m`, also funktional egal. Beim nächsten Aufräumen korrigieren. |
| `CLAUDE.md` aktualisieren | Offen (siehe 6.8) |

### 9.2 Vor 8.11 (Deprecations aus 8.10)

- **Hub-OIDC** auf `CAMUNDA_SECURITY_AUTHENTICATION_OIDC_*` umstellen: `ISSUERURI`, `JWKSETURI` (intern), `CLIENTID=web-modeler`, `AUDIENCES=web-modeler-api,web-modeler-public-api`. Der Legacy-Key `user-id-claim` war nicht gesetzt, deshalb `USERNAMECLAIM` nur bewusst setzen, damit sich die User-Zuordnung in der Hub-DB nicht ändert.
- **Optimize-OIDC** umstellen: `CAMUNDA_OPTIMIZE_IDENTITY_ISSUER_URL/CLIENTID/CLIENTSECRET/AUDIENCE` → `CAMUNDA_SECURITY_AUTHENTICATION_OIDC_ISSUERURI/CLIENTID/CLIENTSECRET/AUDIENCES` plus `JWKSETURI`, `AUTHORIZATIONURI`, `TOKENURI` (Browser- und Backend-URLs getrennt wie bei Orchestration); `CAMUNDA_OPTIMIZE_IDENTITY_BASE_URL` bleibt. Aus dem Container ist nur `http://keycloak:18080` erreichbar, deshalb keine Discovery über den öffentlichen Issuer.
- Hub-Deprecation-Warnungen (`Deprecated Camunda Hub configuration keys detected`) im Log prüfen und die restlichen Keys auf `camunda.hub.*` bzw. `CAMUNDA_HUB_*` umstellen.
- Optional: `WEBMODELER_*` → `HUB_*` umbenennen (Werte 1:1 übernehmen).

---

## 10. Quellen

- Upstream Docker Compose 8.10: https://github.com/camunda/camunda-distributions/tree/main/docker-compose/versions/camunda-8.10. Relevante Commits: `8eca7c5` (Web Modeler → Hub), `452bbe0` (`admin:clusters`), `1c7b166` (zentrale Secrets), `0f526a0` (gemountete App-Config), `cc8c877` (Hub-Cluster-Config), `a0b3c0b` (Play → Test Mode)
- Release Notes 8.10: https://docs.camunda.io/docs/next/reference/announcements-release-notes/8100/8100-release-notes/
- Announcements 8.10: https://docs.camunda.io/docs/next/reference/announcements-release-notes/8100/8100-announcements/
- What's new in 8.10: https://docs.camunda.io/docs/next/reference/announcements-release-notes/8100/whats-new-in-810/
- Component changes 8.9 → 8.10: https://docs.camunda.io/docs/next/self-managed/upgrade/components/890-to-8100/
- Helm-Upgrade 8.9 → 8.10 (Hub-DB-Migration, Rollback): https://docs.camunda.io/docs/next/self-managed/upgrade/helm/890-to-8100/
- Hub-Properties: https://docs.camunda.io/docs/next/self-managed/components/hub/configuration/properties/
- Connectors Secret-Filter: https://github.com/camunda/connectors/pull/8501, https://github.com/camunda/connectors/pull/8600
- Eigene Image-Analyse der RCs (`camunda/hub:8.10-rc1`, `camunda/camunda:8.10.0-rc2`, `camunda/optimize:8.10.0-rc2`, `camunda/connectors-bundle:8.10.0-rc2`): `LegacyConfigPrefixEnvironmentPostProcessor`, `LegacyAuthConfigEnvironmentPostProcessor`, `OptimizeSecurityConfigCompatibilityPostProcessor`, Enum `ClusterAppType`, `config/defaults.yaml`

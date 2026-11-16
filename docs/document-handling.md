# Document Handling (Dokumente in Prozessen)

Dieses Dokument beschreibt, wie der Stack Dokumente (Excel, PDF, Word, …) speichert, die über
Formulare oder die Document-API nach Camunda gelangen, und was bei Installation und Betrieb zu
beachten ist.

## Was eingerichtet ist

| Baustein | Ort | Inhalt |
|---|---|---|
| Document Store | `.orchestration/application.yaml` → `camunda.document` | Store-ID `local`, Typ Local Storage, Pfad `/usr/local/camunda/documents` |
| Volume | `docker-compose.yaml` → Volume `documents` am Dienst `orchestration` | Persistente Ablage der Dateien |
| Upload-Limits | `.env` → `UPLOAD_MAX_FILE_SIZE`, `UPLOAD_MAX_REQUEST_SIZE` | Standard 25MB je Datei, 100MB je Request |
| Backup/Restore | `scripts/backup.*`, `scripts/restore.*` | Artefakt `documents.tar.gz`, Teil der Komponente `orchestration` |

Ohne den Block `camunda.document` nutzt Camunda einen In-Memory-Store: Dokumente wären nach jedem
Neustart von `orchestration` verloren.

Der Store wird nur am Dienst `orchestration` konfiguriert. Connectors und eigene Worker greifen
über die REST-API des Orchestration Clusters auf Dokumente zu und brauchen keinen eigenen Zugriff
auf das Volume.

## Einschränkungen von Local Storage

- Camunda stuft Local Storage als nicht produktionstauglich ein. Die Dateien liegen auf genau
  einem Docker-Host; fällt dessen Datenträger aus, hilft nur das Backup.
- Es gibt keine automatische Ablaufzeit (TTL). Dateien bleiben liegen, bis sie über die API
  gelöscht werden (`DELETE /v2/documents/{documentId}`). Das Volume wächst also dauerhaft und
  gehört in die Plattenplatz-Überwachung. Die 90-Tage-Retention der Prozessdaten räumt Dokumente
  nicht mit ab.
- Dokumente werden über Store-ID und Dokument-ID referenziert. Die Store-ID `local` darf nicht
  umbenannt werden, solange laufende Prozessinstanzen Referenzen darauf halten. Ein späterer
  Wechsel auf einen S3-kompatiblen Store (`camunda.document.aws.<id>` mit `endpoint`) ist
  möglich, bestehende Referenzen zeigen dann aber weiter auf `local`.

## Installation

### Neuinstallation aus diesem Branch

Es ist kein zusätzlicher Schritt nötig. `bash scripts/start.sh` (bzw. `pwsh -File scripts/start.ps1`)
legt das Volume `documents` beim ersten Start an.

Optional vor dem ersten Start in `.env` anpassen:

```
UPLOAD_MAX_FILE_SIZE=25MB
UPLOAD_MAX_REQUEST_SIZE=100MB
```

`UPLOAD_MAX_FILE_SIZE` begrenzt eine einzelne Datei, `UPLOAD_MAX_REQUEST_SIZE` einen ganzen
Request. Ein Formular mit mehreren Dateien wird als ein Request gesendet. Die Limits gelten für
die gesamte REST-API von `orchestration`, also auch für Deployments.

### Bestehende Installation aktualisieren

1. **Backup erstellen:** `bash scripts/backup.sh`.
2. **Branch-Stand einspielen** (`git pull` oder neues Deployment-Paket). Betroffene Dateien:
   `docker-compose.yaml`, `.orchestration/application.yaml`, `.env.example`, `scripts/backup.*`,
   `scripts/restore.*`, `scripts/cluster-wipe.*`.
3. **`.env` ergänzen (optional):** Wird die `.env` der Umgebung lokal gepflegt und nicht aus dem
   Branch übernommen, die beiden `UPLOAD_MAX_*`-Zeilen aus `.env.example` eintragen. Fehlen sie,
   gelten 25MB / 100MB. In `.env-credentials` ist nichts zu ändern.
4. **Stack neu starten:** `bash scripts/start.sh`. Compose erstellt wegen des neuen Volumes den
   Container `orchestration` neu; Operate, Tasklist und Zeebe sind dabei kurz nicht erreichbar.
5. **Prüfen** (siehe nächster Abschnitt).

Dokumente, die vor der Umstellung hochgeladen wurden, lagen im In-Memory-Store und sind nach dem
Neustart nicht mehr vorhanden. Laufende Prozessinstanzen mit solchen Referenzen müssen die Dateien
erneut erhalten.

## Prüfen nach dem Start

```bash
# Volume vorhanden
docker volume ls | grep documents

# Store wurde beim Start erkannt
docker logs orchestration 2>&1 | grep LocalStorageDocumentStore
# erwartet: Successfully accessed storage path '/usr/local/camunda/documents'

# Abgelegte Dateien (je Dokument eine Datei plus <id>-metadata)
docker exec orchestration ls -la /usr/local/camunda/documents
```

Fachlicher Test:

1. In Camunda Hub ein Formular mit einer **Filepicker**-Komponente an eine User Task hängen und
   den Prozess deployen.
2. In Tasklist eine Datei hochladen und die Task abschließen.
3. In Operate prüfen, dass die Variable eine Dokumentreferenz enthält (`storeId: local`).
4. `docker compose restart orchestration` ausführen und das Dokument erneut abrufen, z. B. über
   eine Folge-Task mit Dokumentvorschau.
5. `bash scripts/backup.sh` ausführen und prüfen, dass `documents.tar.gz` im Backup liegt.

### Berechtigungen

Der Stack läuft mit `camunda.security.authorizations.enabled: true`. Die Document-API verlangt
Rechte auf dem Ressourcentyp `DOCUMENT`:

| Recht | Wofür |
|---|---|
| `CREATE` | Hochladen (`POST /v2/documents`, Filepicker im Formular) |
| `READ` | Abrufen (`GET /v2/documents/{documentId}`, Dokumentvorschau) |
| `DELETE` | Löschen (`DELETE /v2/documents/{documentId}`) |

Der Benutzer `demo` und die Clients in der Rolle `admin` (`orchestration`, `c8ctl`) dürfen alles.
Für Fachanwender, den Client `connectors` und eigene Worker-Clients ist das nicht geprüft und
muss je Umgebung getestet werden.

#### Prüfen mit einem M2M-Client (z. B. Job Worker)

Auf dem Docker-Host, mit Client-ID und Secret des Workers (`HOST` wie in `.env`). Die Befehle
sind aus der API-Spezifikation abgeleitet und nicht gegen den vollständigen Stack gelaufen.

```bash
HOST=camunda.dev.local
CLIENT_ID=mein-worker
CLIENT_SECRET=...

# 1. Token holen
TOKEN=$(curl -sk "https://keycloak.$HOST/auth/realms/camunda-platform/protocol/openid-connect/token" \
  -d grant_type=client_credentials -d client_id=$CLIENT_ID -d client_secret=$CLIENT_SECRET \
  -d audience=orchestration-api | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

# 2. Hochladen (prüft CREATE)
echo test > test.txt
curl -s -w '\nHTTP %{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  -F "file=@test.txt" http://127.0.0.1:8088/v2/documents

# 3. Abrufen (prüft READ), documentId und contentHash aus der Antwort von Schritt 2
curl -s -w '\nHTTP %{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:8088/v2/documents/<documentId>?contentHash=<contentHash>"
```

| Antwort | Bedeutung |
|---|---|
| 201 / 200 | Recht vorhanden |
| 403 | Client ist bekannt, das Recht fehlt |
| 401 | Token wird nicht akzeptiert (Secret oder Audience falsch), kein Berechtigungsproblem |

Als Gegenprobe eignet sich der Client `c8ctl`, der über die Rolle `admin` alle Rechte hat.

#### Prüfen für Fachanwender

Mit einem normalen Anwender (nicht `demo`) in Tasklist anmelden und in einem Formular mit
Filepicker eine Datei hochladen. Schlägt der Upload fehl, fehlt `CREATE`. Zeigt die
Dokumentvorschau in einer Folge-Task nichts an, fehlt `READ`.

#### Nachsehen und vergeben

In der Admin-UI (`https://orchestration.{HOST}/admin`) im Bereich **Authorizations** den
Ressourcentyp **Document** wählen. Dort steht, welche Benutzer, Clients, Gruppen und Rollen
welche Rechte haben. Eine fehlende Autorisierung wird an derselben Stelle angelegt: Owner ist der
Client oder besser eine Rolle, Ressourcen-ID `*`, Rechte `READ` und bei Bedarf `CREATE` und
`DELETE`. Ein Client kann seine Rechte auch über eine Rolle erhalten.

## Dokumente im Prozess verwenden

Die Datei liegt immer im Document Store. Im Prozess wird nur mit der Referenz gearbeitet.

### Wo die Referenz gespeichert ist

Die Filepicker-Komponente schreibt unter ihrem Key (im Beispiel `kundenDokumente`) eine Liste von
Referenzen als normale Prozessvariable an die Prozessinstanz. Es ist immer eine Liste, auch bei
nur einer Datei:

```json
[{
  "camunda.document.type": "camunda",
  "storeId": "local",
  "documentId": "c756d65b-…",
  "contentHash": "109586ca…",
  "metadata": { "fileName": "angebot.pdf", "contentType": "application/pdf", "size": 48213 }
}]
```

Die Variable enthält alles, was zum Abrufen nötig ist. Sie ist die einzige Stelle, an der die
Zuordnung von Dokument zu Prozessinstanz verlässlich steht.

| Aspekt | Verhalten |
|---|---|
| Gültigkeitsbereich | Nach Abschluss der User Task liegt die Variable im Prozess-Scope und steht allen folgenden Tasks, Gateways und Connectors zur Verfügung. Sind an der Task Output-Mappings definiert, muss die Variable dort ausdrücklich übernommen werden, sonst bleibt sie lokal an der Task. |
| Sichtbarkeit | Operate zeigt die Referenz im Variablen-Tab der Instanz (Name, Typ, Größe) und bietet den Download an. |
| Weitergabe | Die Referenz lässt sich wie jede Variable an Call Activities, Subprozesse oder per Message an andere Prozesse übergeben. Der Empfänger ruft das Dokument damit genauso ab. |
| Lebensdauer der Variable | Sie lebt mit der Prozessinstanz und wird nach deren Ende mit der 90-Tage-Retention gelöscht. |
| Lebensdauer der Datei | Die Datei bleibt im Store, weil Local Storage keine Ablaufzeit hat. Nach Ablauf der Retention gibt es Dateien ohne Referenz. Wer sie länger braucht, legt die Referenz selbst ab (z. B. im Fachsystem); wer sie loswerden will, löscht sie per API. |
| Datei gelöscht | Die Variable bleibt am Prozess stehen, der Abruf schlägt fehl. |

### Zugriff per FEEL

Der Index beginnt bei 1.

| Ausdruck | Ergebnis |
|---|---|
| `kundenDokumente[1]` | erstes Dokument |
| `kundenDokumente[item.metadata.contentType = "application/pdf"]` | nur die PDFs |
| `kundenDokumente[1].metadata.fileName` | Dateiname, z. B. für ein Gateway |
| `count(kundenDokumente)` | Anzahl der Dokumente |

### Anzeigen und Herunterladen für Anwender

- **Tasklist:** In einem späteren Formular die Komponente *Document preview* einfügen und als
  Dokumentreferenz die Variable angeben (`=kundenDokumente`). PDFs und Bilder erscheinen als
  Vorschau, andere Typen (Excel, Word) mit Dateiname und Download.
- **Operate:** Variablen-Tab der Prozessinstanz, dort auch der Filter *Documents*.

### Connectors

Die Connectors aus dem Container `connectors` lösen Referenzen selbst auf. Im jeweiligen Feld
wird die Referenz übergeben:

- **E-Mail:** Anhänge `=kundenDokumente`
- **REST:** Dokument im Body, z. B. `={ "datei": kundenDokumente[1] }`; gesendet wird der
  Dateiinhalt
- **AI Agent / IDP:** Dokumente als Eingabe für Extraktion oder Analyse

Feldnamen und unterstützte Formate unterscheiden sich je Connector-Template und sind beim
Modellieren am Template zu prüfen.

### Eigene Job Worker

Der Worker erhält die Referenz als Variable und holt den Inhalt über die Document-API. Skizze
mit dem Camunda Java Client (Methodennamen gegen die eingesetzte Client-Version prüfen):

```java
@JobWorker(type = "dokument-verarbeiten")
public Map<String, Object> handle(@Variable List<DocumentReferenceResponse> kundenDokumente) {
    try (InputStream in = client.newDocumentContentGetRequest(kundenDokumente.get(0)).send().join()) {
        // Inhalt verarbeiten, z. B. Excel parsen
    }
    // neues Dokument erzeugen und als Variable zurückgeben
    var neu = client.newCreateDocumentCommand()
        .content(ergebnisBytes).fileName("auswertung.xlsx").send().join();
    return Map.of("auswertung", List.of(neu));
}
```

### REST-API

| Zweck | Aufruf |
|---|---|
| Hochladen | `POST /v2/documents` (multipart, Feld `file`), liefert die Referenz |
| Abrufen | `GET /v2/documents/{documentId}?contentHash={contentHash}` |
| Löschen | `DELETE /v2/documents/{documentId}` |

Basis-URL aus Containern: `http://orchestration:8080`, von außen: `https://orchestration.{HOST}`.
Nötig ist ein Bearer-Token aus Keycloak für einen M2M-Client mit Berechtigung auf den
Ressourcentyp `DOCUMENT`. Hochladen und Abrufen sind gegen den Local Store getestet (siehe
[Verifiziert](#verifiziert)).

### Nicht empfohlen

- **Direkter Zugriff auf das Volume:** Die Dateien liegen dort unter ihrer Dokument-ID ohne
  Dateiendung, und ohne die API entfällt die Berechtigungsprüfung.
- **Dateiinhalt als Prozessvariable (z. B. Base64):** Das bläht den Zeebe-Zustand auf. Immer die
  Referenz weiterreichen.

## Backup und Restore

- `backup.*` sichert das Volume als `documents.tar.gz`, im selben Stillstandsfenster wie den
  Zeebe-Zustand. Damit passen Referenzen und Dateien zusammen.
- `restore.*` spielt `documents.tar.gz` mit der Komponente `orchestration` (und bei `all`) zurück
  und ersetzt dabei das Volume vollständig.
- Enthält ein älteres Backup kein `documents.tar.gz`, bleibt das vorhandene Volume unverändert und
  das Skript protokolliert eine Warnung.
- `cluster-wipe.*` löscht das Volume zusammen mit den übrigen Datenvolumes.

Details: [`backup-restore.md`](backup-restore.md).

## Verifiziert

Lokal mit `camunda/camunda:8.10.7` als Einzelcontainer und derselben `camunda.document`- und
Multipart-Konfiguration geprüft (2026-11-16): Store wird erkannt, Upload einer 15-MB-Datei
funktioniert, eine 30-MB-Datei wird mit HTTP 413 abgelehnt, das Dokument ist nach einem
Container-Neustart abrufbar, und ein tar-Backup/-Restore des Volumes erhält die Besitzrechte
(`1001:0`). Der Ablauf über Tasklist-Formulare im vollständigen Stack ist damit nicht abgedeckt
und gehört zum fachlichen Test oben.

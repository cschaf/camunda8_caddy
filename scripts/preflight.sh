#!/usr/bin/env bash
#
# preflight.sh - Prüft alle per Skript prüfbaren Voraussetzungen für die
# Installation und den Betrieb der Camunda 8.9 DEV-Umgebung (Docker Compose)
# auf einem Ubuntu-Server.
#
# Aufruf:
#   bash scripts/preflight.sh [PROJEKTVERZEICHNIS]
#   bash scripts/preflight.sh --report [DATEI]
#   bash scripts/preflight.sh --report=DATEI
#
# Ohne Argument wird das Projektverzeichnis über die Skriptlage ermittelt
# (Verzeichnis über scripts/). Läuft das Skript auf einem frischen Server,
# auf dem das Repository noch nicht liegt, kann ein Zielverzeichnis übergeben
# werden (z. B. /opt/camunda) - dann entfallen die Projekt-Prüfungen.
#
# --report erzeugt am Ende eine Markdown-Datei (Standard: preflight-report.md)
# mit allen Prüfungen und dem Handlungsbedarf für die Infrastruktur.
#
# Exit-Code: 0 = keine Fehler, 1 = mindestens eine Prüfung fehlgeschlagen.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Verwendung: preflight.sh [OPTIONEN] [PROJEKTVERZEICHNIS]

Optionen:
  --report [DATEI]   Erzeugt einen Markdown-Bericht (Standard: preflight-report.md)
  --report=DATEI     Erzeugt den Bericht unter DATEI
  -h, --help         Zeigt diese Hilfe

Projektverzeichnis:
  Optionaler Pfad zum Repository. Ohne Angabe wird es über die Skriptlage
  ermittelt. Existiert dort keine .env, werden die Projekt-Prüfungen
  übersprungen (z. B. auf einem frischen Server unter /opt/camunda).
EOF
}

REPORT_FILE=""
PROJECT_DIR=""

while (($#)); do
  case "$1" in
    --report=*) REPORT_FILE="${1#*=}"; shift ;;
    --report)
      if [[ $# -ge 2 && "$2" != -* ]]; then
        REPORT_FILE="$2"
        shift
      else
        REPORT_FILE="preflight-report.md"
      fi
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ -z "$PROJECT_DIR" ]]; then
        PROJECT_DIR="$1"
      else
        echo "Fehler: Unbekanntes Argument '$1' (siehe --help)" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

PROJECT_DIR="${PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# --- Ausgabe-Hilfsfunktionen -------------------------------------------------

NO_COLOR="${NO_COLOR:-}"
if [[ -t 1 && -z "$NO_COLOR" ]]; then
  C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_GREEN=$'\033[32m'; C_BLUE=$'\033[36m'; C_BOLD=$'\033[1m'; C_NC=$'\033[0m'
else
  C_RED=""; C_YELLOW=""; C_GREEN=""; C_BLUE=""; C_BOLD=""; C_NC=""
fi

declare -i T_PASS=0 T_WARN=0 T_FAIL=0 T_INFO=0
declare -a RESULTS=()   # 'section|Name', 'level|msg' oder 'kv|Schlüssel|Wert'

report() {
  local level="$1"; shift
  case "$level" in
    PASS) printf '  %s[PASS]%s %s\n' "$C_GREEN" "$C_NC" "$*"; T_PASS+=1 ;;
    WARN) printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_NC" "$*"; T_WARN+=1 ;;
    FAIL) printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_NC" "$*"; T_FAIL+=1 ;;
    INFO) printf '  %s[INFO]%s %s\n' "$C_BLUE" "$C_NC" "$*"; T_INFO+=1 ;;
  esac
  RESULTS+=("$level|$*")
}

section() {
  printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_NC"
  RESULTS+=("section|$*")
}

# Faktische Ausgabe (kein PASS/WARN/FAIL), z. B. für Zahlenwerte.
kv() {
  printf '  %-28s %s\n' "$1" "$2"
  RESULTS+=("kv|$1|$2")
}

# --- kleine Helfer ------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Vergleich: a >= b (ganzzahlig)
ge() { [[ "$1" -ge "$2" ]]; }

# Liest einen Schlüssel aus einer .env-Datei (ohne Anführungszeichen).
env_get() {
  local file="$1" key="$2"
  local line
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | head -n1 || true)"
  [[ -z "$line" ]] && { printf ''; return; }
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

# --- Hauptprogramm ------------------------------------------------------------

printf '%sCamunda 8.9 - Voraussetzungsprüfung (Preflight)%s\n' "$C_BOLD" "$C_NC"
printf 'Prüfungstiefe: System + Werkzeuge + Netzwerk + Projekt (sofern vorhanden)\n'
printf 'Server: %s | Projektverzeichnis: %s\n' "$(hostname 2>/dev/null || echo '?')" "$PROJECT_DIR"

# ---------------------------------------------------------------------------
section '1. System'
# ---------------------------------------------------------------------------

# OS
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  os_label="${PRETTY_NAME:-$ID $VERSION_ID}"
else
  os_label="$(uname -s) $(uname -r)"
  ID="unknown"; VERSION_ID=""
fi
if [[ "$(uname -s)" != "Linux" ]]; then
  report FAIL "Kein Linux-Betriebssystem: $os_label"
elif [[ "$ID" == "ubuntu" && "$VERSION_ID" == "22.04" ]]; then
  report PASS "Ubuntu 22.04 erkannt ($os_label)"
elif [[ "$ID" == "ubuntu" ]]; then
  report WARN "Ubuntu $VERSION_ID erkannt - 22.04 ist die Referenzversion ($os_label)"
elif [[ "$ID" == "debian" ]]; then
  report WARN "Debian erkannt - getestet ist Ubuntu 22.04 ($os_label)"
else
  report WARN "Abweichende Distribution ($os_label) - Ubuntu 22.04 wird empfohlen"
fi

# Architektur
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) report PASS "Architektur $arch (unterstützt)" ;;
  aarch64|arm64) report WARN "Architektur $arch - nicht alle Camunda-Images verfügbar" ;;
  *) report FAIL "Nicht unterstützte Architektur: $arch" ;;
esac

# Bash-Version
if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
  report PASS "Bash ${BASH_VERSION%%-*} (>= 4)"
else
  report FAIL "Bash ${BASH_VERSION:-?} zu alt - Version 4+ erforderlich"
fi

# root / sudo
if [[ "$(id -u)" -eq 0 ]]; then
  report PASS "Skript läuft mit root-Rechten"
elif have sudo && sudo -n true 2>/dev/null; then
  report PASS "sudo-Passwortlos verfügbar"
elif have sudo; then
  report WARN "sudo vorhanden, aber Passwort erforderlich (nicht passwortlos)"
else
  report FAIL "Weder root noch sudo verfügbar"
fi

# CPU-Kerne
cores="$(nproc 2>/dev/null || echo 0)"
if ge "$cores" 8; then
  report PASS "CPU-Kerne: $cores (empfohlen: 8+)"
elif ge "$cores" 4; then
  report WARN "CPU-Kerne: $cores - empfohlen sind mindestens 8"
else
  report FAIL "CPU-Kerne: $cores - zu wenig für den Betrieb (empfohlen: 8+)"
fi

# Gesamter Arbeitsspeicher
mem_total_b="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_total_gb=$((mem_total_b / 1024 / 1024))
if ge "$mem_total_gb" 24; then
  report PASS "Arbeitsspeicher gesamt: ${mem_total_gb} GB"
elif ge "$mem_total_gb" 16; then
  report WARN "Arbeitsspeicher gesamt: ${mem_total_gb} GB - für DEV empfohlen werden 16-32 GB"
else
  report FAIL "Arbeitsspeicher gesamt: ${mem_total_gb} GB - zu wenig (DEV-Stufe benötigt ~16 GB freien RAM)"
fi

# Aktuell verfügbarer Arbeitsspeicher
mem_avail_b="$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_avail_gb=$((mem_avail_b / 1024 / 1024))
if ge "$mem_avail_gb" 8; then
  report PASS "Verfügbarer Arbeitsspeicher: ${mem_avail_gb} GB"
else
  report WARN "Verfügbarer Arbeitsspeicher: ${mem_avail_gb} GB - vor dem Start sollten ~16 GB frei sein"
fi

# Swap (Information)
swap_total_b="$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
swap_gb=$((swap_total_b / 1024 / 1024))
kv "Swap (Info)" "${swap_gb} GB"

# Festplattenplatz (Daten liegen in Docker-Volumes unter /var/lib/docker)
df_target="/var/lib/docker"
[[ -d "$df_target" ]] || df_target="/"
disk_total_k="$(df -Pk "$df_target" | awk 'NR==2 {print $2}')"
disk_free_k="$(df -Pk "$df_target" | awk 'NR==2 {print $4}')"
disk_total_gb=$((disk_total_k / 1024 / 1024))
disk_free_gb=$((disk_free_k / 1024 / 1024))
kv "Speicherort geprüft" "$df_target"
kv "Festplatte gesamt (Info)" "${disk_total_gb} GB"
if ge "$disk_free_gb" 60; then
  report PASS "Freier Speicherplatz: ${disk_free_gb} GB"
elif ge "$disk_free_gb" 25; then
  report WARN "Freier Speicherplatz: ${disk_free_gb} GB - für DEV mit Backups werden 60+ GB empfohlen"
else
  report FAIL "Freier Speicherplatz: ${disk_free_gb} GB - zu wenig (Images + Stack + Backups)"
fi

# Inodes (Schutz vor 'Disk full' trotz freiem Platz)
inode_free="$(df -Pi "$df_target" | awk 'NR==2 {print $4}')"
if ge "$inode_free" 100000; then
  report PASS "Freie Inodes: $inode_free"
else
  report WARN "Freie Inodes: $inode_free - sehr niedrig, Bereinigung prüfen"
fi

# ---------------------------------------------------------------------------
section '2. Werkzeuge'
# ---------------------------------------------------------------------------

# Docker Engine
if have docker; then
  docker_version="$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
  docker_major="${docker_version%%.*}"
  if ge "${docker_major:-0}" 24; then
    report PASS "Docker Engine ${docker_version:-?} (>= 24.0)"
  else
    report FAIL "Docker Engine ${docker_version:-?} zu alt - 24.0+ erforderlich"
  fi
else
  report FAIL "Docker Engine fehlt - Installation erforderlich"
fi

# Docker-Daemon + Socket-Berechtigung
if have docker; then
  if docker_output="$(docker info 2>&1)"; then
    report PASS "Docker-Daemon läuft und ist für den aktuellen Benutzer erreichbar"
  else
    if grep -qi 'permission denied' <<<"$docker_output"; then
      report FAIL "Docker-Socket ohne Berechtigung - Benutzer in Gruppe 'docker' aufnehmen oder mit sudo ausführen"
    else
      report FAIL "Docker-Daemon nicht erreichbar: $docker_output"
    fi
  fi
fi

# Docker Compose V2
if have docker && docker compose version >/dev/null 2>&1; then
  compose_ver="$(docker compose version 2>/dev/null)"
  report PASS "Docker Compose V2 ($compose_ver)"
elif have docker-compose; then
  report FAIL "Nur docker-compose V1 gefunden - Docker Compose V2-Plugin ('docker compose') erforderlich"
else
  report FAIL "Docker Compose V2 fehlt (Plugin 'docker compose')"
fi

# Git
if have git; then
  report PASS "Git $(git --version 2>/dev/null | sed 's/git version //')"
else
  report FAIL "Git fehlt"
fi

# openssl (für generate-secrets.sh)
if have openssl; then
  report PASS "openssl ($(openssl version 2>/dev/null | awk '{print $2}'))"
else
  report FAIL "openssl fehlt - für die Generierung sicherer Zugangsdaten erforderlich"
fi

# rsync (für GitLab-Deployment-Pipeline)
if have rsync; then
  report PASS "rsync vorhanden"
else
  report WARN "rsync fehlt - nur für die GitLab-Deployment-Pipeline erforderlich"
fi

# curl (für Healthchecks / Monitoring / Registry-Prüfung)
if have curl; then
  report PASS "curl vorhanden"
else
  report WARN "curl fehlt - für Diagnose und Monitoring empfohlen"
fi

# jq (nur für registry-info.sh)
if have jq; then
  report PASS "jq vorhanden"
else
  report INFO "jq fehlt - nur für das Hilfsskript registry-info.sh nötig"
fi

# ---------------------------------------------------------------------------
section '3. Netzwerk & Ports'
# ---------------------------------------------------------------------------

# Erreichbarkeit Container-Registry: realer Pull-Test mit einem Mini-Image.
# Nutzt die Docker-Daemon-Konfiguration (inkl. Mirror/Proxy aus /etc/docker/daemon.json)
# und prüft damit die tatsächliche Fähigkeit, Images zu laden.
TEST_IMAGE="busybox:1.36"
if have docker && docker info >/dev/null 2>&1; then
  pull_ok=false
  if docker image inspect "$TEST_IMAGE" >/dev/null 2>&1; then
    pull_ok=true
    report PASS "Test-Image '$TEST_IMAGE' ist lokal bereits vorhanden"
  else
    if have timeout; then
      timeout 90 docker pull "$TEST_IMAGE" >/dev/null 2>&1 && pull_ok=true
    else
      docker pull "$TEST_IMAGE" >/dev/null 2>&1 && pull_ok=true
    fi
    if [[ "$pull_ok" == true ]]; then
      report PASS "Test-Image '$TEST_IMAGE' erfolgreich geladen - Registry-Zugriff funktioniert"
      # Test-Image wieder entfernen, damit die Prüfung keine Rückstände hinterlässt
      docker rmi "$TEST_IMAGE" >/dev/null 2>&1 || true
    else
      report FAIL "Test-Image '$TEST_IMAGE' konnte nicht geladen werden - Registry-Zugriff/Netzwerk prüfen"
      report INFO "Hinweis: Falls ein Registry-Mirror/Proxy konfiguriert ist, /etc/docker/daemon.json prüfen"
    fi
  fi
elif have curl; then
  # Fallback ohne laufenden Docker-Daemon: nur HTTP-Erreichbarkeit
  if curl -fsS --max-time 8 -o /dev/null https://registry-1.docker.io/v2/ 2>/dev/null; then
    report PASS "Docker Hub (registry-1.docker.io) HTTP-erreichbar"
  else
    report WARN "Docker Hub nicht direkt erreichbar (curl) - Proxy/Mirror prüfen"
  fi
fi

# Erreichbarkeit Camunda-Registry (nur relevant, wenn Zugangsdaten konfiguriert sind)
if [[ -f "$PROJECT_DIR/.env" ]] && [[ -n "$(env_get "$PROJECT_DIR/.env" CAMUNDA_REGISTRY_URL)" ]]; then
  reg_url="$(env_get "$PROJECT_DIR/.env" CAMUNDA_REGISTRY_URL)"
  if have curl; then
    if curl -fsS --max-time 8 -o /dev/null "$reg_url" 2>/dev/null; then
      report PASS "Camunda-Registry ($reg_url) erreichbar"
    else
      report WARN "Camunda-Registry ($reg_url) nicht erreichbar - Firewall/Netz prüfen"
    fi
  fi
fi

# Port 443 (Reverse-Proxy/Caddy)
if ss -ltn 2>/dev/null | awk '$4 ~ /[:.]443$/ {print $4}' | grep -q .; then
  report WARN "Port 443 ist bereits belegt - Caddy kann sonst nicht binden (laufenden Dienst prüfen)"
else
  report PASS "Port 443 ist frei (für den verschlüsselten Zugriff)"
fi

# Lokale Diagnose-Ports (nur 127.0.0.1 gebunden); belegt => Stack läuft vermutlich
local_ports="26500 9600 8088 8086 8083 8084 9200 8070 8060 8087 9100 1025 8075"
occupied=()
for p in $local_ports; do
  if ss -ltn 2>/dev/null | awk -v port="$p" '$4 ~ "[:.]" port "$" {print $4}' | grep -q .; then
    occupied+=("$p")
  fi
done
if [[ ${#occupied[@]} -gt 0 ]]; then
  report INFO "Lokale Ports belegt (${occupied[*]}) - Camunda-Stack läuft vermutlich bereits"
else
  report PASS "Keine der lokalen Camunda-Diagnose-Ports ist belegt"
fi

# Läuft der Stack bereits?
if have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'orchestration'; then
  report INFO "Camunda-Stack ist bereits gestartet (Container 'orchestration' läuft)"
else
  report PASS "Camunda-Stack ist aktuell nicht gestartet"
fi

# ---------------------------------------------------------------------------
section '4. Projekt-Konfiguration (falls Repository vorhanden)'
# ---------------------------------------------------------------------------

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  report INFO "Kein .env im Verzeichnis $PROJECT_DIR - Projekt-Prüfungen übersprungen"
  report INFO "Entweder Repository klonen oder Projektverzeichnis als Argument übergeben"
else
  env_file="$PROJECT_DIR/.env"

  for req in .env .env-credentials connector-secrets.txt Caddyfile; do
    if [[ -f "$PROJECT_DIR/$req" ]]; then
      report PASS "Projektdatei $req vorhanden"
    else
      case "$req" in
        .env-credentials) report FAIL "Projektdatei $req fehlt - mit scripts/generate-secrets.sh erzeugen" ;;
        Caddyfile)        report WARN "Projektdatei $req fehlt - mit scripts/setup-host.sh erzeugen" ;;
        connector-secrets.txt) report WARN "Projektdatei $req fehlt - Kopie von connector-secrets.txt.example anlegen" ;;
        *)                report FAIL "Projektdatei $req fehlt" ;;
      esac
    fi
  done

  # HOST
  host_val="$(env_get "$env_file" HOST)"
  if [[ -z "$host_val" ]]; then
    report FAIL "HOST ist nicht in .env gesetzt"
  else
    if [[ "$host_val" == "${host_val,,}" ]]; then
      report PASS "HOST ist in Kleinbuchstaben gesetzt ($host_val)"
    else
      report FAIL "HOST enthält Großbuchstaben ($host_val) - muss komplett kleingeschrieben sein (OIDC-Redirect-Probleme)"
    fi
    if grep -qE "(^|[[:space:]])127\.0\.0\.1[[:space:]]+$host_val([[:space:]]|$)" /etc/hosts 2>/dev/null; then
      report PASS "Hosts-Eintrag für $host_val vorhanden"
    else
      report WARN "Kein Hosts-Eintrag für $host_val - mit scripts/setup-host.sh anlegen"
    fi
  fi

  # STAGE
  stage_val="$(env_get "$env_file" STAGE)"
  case "${stage_val,,}" in
    prod|dev|test) report PASS "STAGE='${stage_val}' (gültige Betriebsstufe)" ;;
    "")            report FAIL "STAGE ist nicht in .env gesetzt (erwartet: prod, dev oder test)" ;;
    *)             report FAIL "STAGE='$stage_val' ist ungültig (erwartet: prod, dev oder test)" ;;
  esac

  # TLS-Zertifikate (falls in .env konfiguriert)
  fullchain="$(env_get "$env_file" FULLCHAIN_PEM)"
  privkey="$(env_get "$env_file" PRIVATEKEY_PEM)"
  if [[ -n "$fullchain" && -n "$privkey" ]]; then
    cert_dir="$PROJECT_DIR/certs"
    if [[ -d "$cert_dir" ]] && ls "$cert_dir" | grep -q .; then
      report PASS "TLS-Zertifikate im Verzeichnis certs/ vorhanden (werden über den Reverse-Proxy verwendet)"
    else
      report WARN "TLS-Zertifikate in .env konfiguriert, aber certs/ ist leer - es wird ein selbstsigniertes Zertifikat verwendet"
    fi
  else
    report INFO "Keine eigenen TLS-Zertifikate konfiguriert - Reverse-Proxy nutzt selbstsignierte Zertifikate"
  fi

  # Versionswerte
  camunda_ver="$(env_get "$env_file" CAMUNDA_VERSION)"
  if [[ -n "$camunda_ver" ]]; then
    report PASS "CAMUNDA_VERSION=$camunda_ver"
  else
    report FAIL "CAMUNDA_VERSION ist nicht in .env gesetzt"
  fi
fi

# ---------------------------------------------------------------------------
section '5. GitLab-Deployment (nur wenn Zielverzeichnis /opt/camunda)'
# ---------------------------------------------------------------------------

if [[ -d /opt/camunda ]]; then
  report PASS "Deployment-Zielverzeichnis /opt/camunda existiert"
  if [[ -r /opt/camunda/.env ]]; then
    report PASS "/opt/camunda/.env vorhanden"
  else
    report WARN "/opt/camunda/.env fehlt - die GitLab-Pipeline bricht sonst ab"
  fi
  if [[ -r /opt/camunda/.env-credentials ]]; then
    report PASS "/opt/camunda/.env-credentials vorhanden"
  else
    report WARN "/opt/camunda/.env-credentials fehlt - die GitLab-Pipeline bricht sonst ab"
  fi
else
  report INFO "Kein /opt/camunda - GitLab-Pipeline-Deployment wird hier nicht geprüft"
fi

if id camunda-admin >/dev/null 2>&1; then
  report PASS "Betriebsbenutzer 'camunda-admin' existiert"
else
  report INFO "Betriebsbenutzer 'camunda-admin' fehlt - nur für die GitLab-Pipeline erforderlich"
fi

# ---------------------------------------------------------------------------
# Markdown-Bericht
# ---------------------------------------------------------------------------

md_status() {
  case "$1" in
    PASS) printf 'OK' ;;
    WARN) printf 'WARNUNG' ;;
    FAIL) printf 'FEHLER' ;;
    INFO) printf 'HINWEIS' ;;
  esac
}

md_icon() {
  case "$1" in
    PASS) printf ':white_check_mark:' ;;
    WARN) printf ':warning:' ;;
    FAIL) printf ':x:' ;;
    INFO) printf ':information_source:' ;;
  esac
}

generate_report() {
  local report_path="$1"
  local verdict=":green_circle: Alle geprüften Voraussetzungen sind erfüllt."
  if [[ "$T_FAIL" -gt 0 ]]; then
    verdict=":red_circle: Es wurden Fehler gefunden - vor der Installation zu beheben."
  elif [[ "$T_WARN" -gt 0 ]]; then
    verdict=":yellow_circle: Warnungen vorhanden - Installation möglich, aber Punkte vorab prüfen."
  fi

  {
    printf '# Camunda 8.9 - Voraussetzungs-Bericht (Preflight)\n\n'
    printf 'Automatisch erzeugt am **%s** auf Server **%s**.\n\n' "$(date '+%d.%m.%Y %H:%M')" "$(hostname 2>/dev/null || echo '?')"

    printf '## Zusammenfassung\n\n'
    printf '| Status | Anzahl |\n|---|---:|\n'
    printf '| Erfüllt (OK) | %d |\n' "$T_PASS"
    printf '| Warnungen | %d |\n' "$T_WARN"
    printf '| Fehler | %d |\n' "$T_FAIL"
    printf '| Hinweise | %d |\n' "$T_INFO"

    printf '\n**Gesamtergebnis:** %s\n' "$verdict"

    printf '\n## Detaillierte Prüfungen\n\n'

    local current_section=""
    local entry level msg key value
    for entry in "${RESULTS[@]}"; do
      level="${entry%%|*}"
      msg="${entry#*|}"
      case "$level" in
        section)
          current_section="$msg"
          [[ "$msg" == "Auswertung" ]] && continue
          printf '\n### %s\n\n' "$msg"
          printf '| Status | Prüfung |\n|---|---|\n'
          ;;
        kv)
          key="${msg%%|*}"
          value="${msg#*|}"
          printf '| | **%s** | %s |\n' "$key" "$value"
          ;;
        *)
          printf '| %s %s | %s |\n' "$(md_icon "$level")" "$(md_status "$level")" "$msg"
          ;;
      esac
    done

    # Handlungsbedarf für die Infrastruktur: alle WARN- und FAIL-Einträge
    local -i action_items=0
    printf '\n## Handlungsbedarf für die Infrastruktur\n\n'
    if [[ "$T_FAIL" -eq 0 && "$T_WARN" -eq 0 ]]; then
      printf 'Kein Handlungsbedarf - alle geprüften Voraussetzungen sind erfüllt.\n'
    else
      for entry in "${RESULTS[@]}"; do
        level="${entry%%|*}"
        msg="${entry#*|}"
        case "$level" in
          WARN|FAIL)
            printf '%s\n' "- [ ] **$(md_status "$level")** ($level): $msg"
            action_items+=1
            ;;
        esac
      done
      printf '\n_%d offene Punkte._\n' "$action_items"
    fi

    printf '\n## Empfohlene Grundinstallation (Ubuntu 22.04)\n\n'
    printf '```bash\n'
    printf 'sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 git openssl rsync curl\n'
    printf 'sudo usermod -aG docker $USER && newgrp docker\n'
    printf '```\n\n'
    printf '%s\n' '---' '_Erzeugt von `scripts/preflight.sh`._'
  } > "$report_path"
}

# ---------------------------------------------------------------------------
section 'Auswertung'
# ---------------------------------------------------------------------------

printf '  %sPASS%s: %d   %sWARN%s: %d   %sFAIL%s: %d   %sINFO%s: %d\n' \
  "$C_GREEN" "$C_NC" "$T_PASS" \
  "$C_YELLOW" "$C_NC" "$T_WARN" \
  "$C_RED" "$C_NC" "$T_FAIL" \
  "$C_BLUE" "$C_NC" "$T_INFO"

if [[ -n "$REPORT_FILE" ]]; then
  generate_report "$REPORT_FILE"
  printf '\n%sMarkdown-Bericht geschrieben: %s%s\n' "$C_BOLD" "$REPORT_FILE" "$C_NC"
fi

if [[ "$T_FAIL" -gt 0 ]]; then
  printf '\n%sErgebnis: Fehler gefunden - die markierten Voraussetzungen sind vor der Installation zu beheben.%s\n' "$C_RED" "$C_NC"
  printf 'Empfehlung für Ubuntu 22.04:\n'
  printf '  sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 git openssl rsync curl\n'
  printf '  sudo usermod -aG docker $USER && newgrp docker\n'
  exit 1
elif [[ "$T_WARN" -gt 0 ]]; then
  printf '\n%sErgebnis: Warnungen vorhanden - Installation möglich, aber Punkte vorab prüfen.%s\n' "$C_YELLOW" "$C_NC"
  exit 0
else
  printf '\n%sErgebnis: Alle geprüften Voraussetzungen sind erfüllt.%s\n' "$C_GREEN" "$C_NC"
  exit 0
fi
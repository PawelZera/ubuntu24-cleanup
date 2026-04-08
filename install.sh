#!/usr/bin/env bash
# Mini-installer: pobiera cleanup-ubuntu24.sh, weryfikuje SHA-256 i uruchamia.
# Zmienne sterujace mozna przekazac jako env, np.:
#   REBOOT_AT_END=1 PURGE_CLOUD_INIT=1 bash install.sh
#
# Uzycie:
#   curl -fsSL https://raw.githubusercontent.com/PawelZera/ubuntu24-cleanup/main/install.sh | sudo bash
#   lub ze zmiennymi:
#   curl -fsSL https://raw.githubusercontent.com/PawelZera/ubuntu24-cleanup/main/install.sh \
#     | sudo REBOOT_AT_END=1 bash

set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/PawelZera/ubuntu24-cleanup/main"
SCRIPT_NAME="cleanup-ubuntu24.sh"
SHA256_NAME="cleanup-ubuntu24.sh.sha256"

# --- kolory (jesli terminal je wspiera) ---
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ "${EUID}" -ne 0 ]]; then
  error "Uruchom jako root, np.: sudo bash $0"
  exit 1
fi

# Sprawdz zaleznosci
for cmd in curl sha256sum; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error "Brak wymaganego narzedzia: $cmd"
    exit 1
  fi
done

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "${TMPDIR_WORK}"' EXIT

info "Pobieranie ${SCRIPT_NAME} ..."
curl -fsSL "${BASE_URL}/${SCRIPT_NAME}" -o "${TMPDIR_WORK}/${SCRIPT_NAME}"

info "Pobieranie pliku SHA-256 ..."
if curl -fsSL "${BASE_URL}/${SHA256_NAME}" -o "${TMPDIR_WORK}/${SHA256_NAME}" 2>/dev/null; then
  # Plik sha256 zawiera: <hash>  <nazwa_pliku> lub <hash>  -
  # Normalizujemy do sciezki tymczasowej
  EXPECTED_HASH=$(awk '{print $1}' "${TMPDIR_WORK}/${SHA256_NAME}")
  ACTUAL_HASH=$(sha256sum "${TMPDIR_WORK}/${SCRIPT_NAME}" | awk '{print $1}')

  if [[ "${EXPECTED_HASH}" != "${ACTUAL_HASH}" ]]; then
    error "Weryfikacja SHA-256 NIEUDANA!"
    error "  Oczekiwany: ${EXPECTED_HASH}"
    error "  Aktualny:   ${ACTUAL_HASH}"
    error "Skrypt NIE zostal uruchomiony."
    exit 1
  fi
  info "SHA-256 OK: ${ACTUAL_HASH}"
else
  warn "Brak pliku .sha256 na serwerze - pomijam weryfikacje sumy kontrolnej."
  warn "Aby zapewnic integralnosc, opublikuj ${SHA256_NAME} obok skryptu."
fi

chmod +x "${TMPDIR_WORK}/${SCRIPT_NAME}"

info "Uruchamianie cleanup-ubuntu24.sh ..."
info "Zmienne: DISABLE_CLOUD_INIT=${DISABLE_CLOUD_INIT:-1} PURGE_CLOUD_INIT=${PURGE_CLOUD_INIT:-0} DISABLE_PRO_SERVICES=${DISABLE_PRO_SERVICES:-1} DETACH_UBUNTU_PRO=${DETACH_UBUNTU_PRO:-1} DISABLE_IPV6=${DISABLE_IPV6:-1} REBOOT_AT_END=${REBOOT_AT_END:-0}"
echo

export DISABLE_CLOUD_INIT="${DISABLE_CLOUD_INIT:-1}"
export PURGE_CLOUD_INIT="${PURGE_CLOUD_INIT:-0}"
export DISABLE_PRO_SERVICES="${DISABLE_PRO_SERVICES:-1}"
export DETACH_UBUNTU_PRO="${DETACH_UBUNTU_PRO:-1}"
export DISABLE_IPV6="${DISABLE_IPV6:-1}"
export REBOOT_AT_END="${REBOOT_AT_END:-0}"

bash "${TMPDIR_WORK}/${SCRIPT_NAME}"

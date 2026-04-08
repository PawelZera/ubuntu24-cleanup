#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Uruchom jako root, np.: sudo bash $0"
  exit 1
fi

log() {
  echo
  echo "==> $*"
}

DISABLE_CLOUD_INIT="${DISABLE_CLOUD_INIT:-1}"
PURGE_CLOUD_INIT="${PURGE_CLOUD_INIT:-0}"
DISABLE_PRO_SERVICES="${DISABLE_PRO_SERVICES:-1}"
DETACH_UBUNTU_PRO="${DETACH_UBUNTU_PRO:-1}"
DISABLE_IPV6="${DISABLE_IPV6:-1}"
REBOOT_AT_END="${REBOOT_AT_END:-0}"

BACKUP_DIR="/root/netplan-backup-$(date +%F-%H%M%S)"

detect_ifaces_from_netplan() {
  if ! command -v netplan >/dev/null 2>&1; then
    return 0
  fi

  netplan get network.ethernets 2>/dev/null \
    | awk -F: '
        /^[[:space:]]+[A-Za-z0-9_.:-]+:/ {
          key=$1
          gsub(/^[[:space:]]+/, "", key)
          gsub(/[[:space:]]+$/, "", key)
          if (key != "") print key
        }
      ' \
    | sort -u
}

detect_ifaces_from_system() {
  local ifaces=()

  while IFS= read -r i; do
    [[ "$i" == "lo" ]] && continue
    [[ -e "/sys/class/net/$i/device" ]] || continue
    ifaces+=("$i")
  done < <(find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)

  if [[ ${#ifaces[@]} -eq 0 ]]; then
    while IFS= read -r i; do
      [[ -n "$i" && "$i" != "lo" ]] && ifaces+=("$i")
    done < <(ip -o route show default | awk '{print $5}' | sort -u)
  fi

  printf '%s\n' "${ifaces[@]}" | awk 'NF' | sort -u
}

log "APT cleanup"
apt -y autoremove --purge
apt -y autoclean
apt -y clean

log "Usuwanie pozostalych wpisow rc"
mapfile -t RC_PKGS < <(dpkg -l | awk '/^rc/ {print $2}')
if ((${#RC_PKGS[@]})); then
  dpkg --purge "${RC_PKGS[@]}"
else
  echo "Brak pakietow w stanie rc"
fi

if [[ "${DISABLE_CLOUD_INIT}" == "1" ]]; then
  log "Wylaczanie cloud-init przez marker file"
  mkdir -p /etc/cloud
  touch /etc/cloud/cloud-init.disabled
fi

if [[ "${PURGE_CLOUD_INIT}" == "1" ]]; then
  log "Pelne usuwanie cloud-init"
  apt -y purge cloud-init || true
  rm -rf /etc/cloud /var/lib/cloud
fi

if command -v pro >/dev/null 2>&1; then
  if [[ "${DISABLE_PRO_SERVICES}" == "1" ]]; then
    log "Wylaczanie popularnych uslug Ubuntu Pro"
    for svc in esm-apps esm-infra livepatch cis usg; do
      pro disable "$svc" >/dev/null 2>&1 || true
    done
  fi

  if [[ "${DETACH_UBUNTU_PRO}" == "1" ]]; then
    log "Odpinanie subskrypcji Ubuntu Pro"
    yes | pro detach || true
  fi
else
  log "Polecenie 'pro' nie jest dostepne - pomijam Ubuntu Pro"
fi

if [[ "${DISABLE_IPV6}" == "1" ]]; then
  log "Wykrywanie interfejsow z netplan get"
  mapfile -t IFACES < <(detect_ifaces_from_netplan)

  if [[ ${#IFACES[@]} -eq 0 ]]; then
    log "Brak interfejsow w network.ethernets - fallback do wykrycia systemowego"
    mapfile -t IFACES < <(detect_ifaces_from_system)
  fi

  if [[ ${#IFACES[@]} -eq 0 ]]; then
    echo "Nie wykryto interfejsow do konfiguracji IPv6"
    exit 1
  fi

  printf 'Wykryte interfejsy: %s\n' "${IFACES[*]}"

  if [[ -d /etc/netplan ]]; then
    log "Backup /etc/netplan do ${BACKUP_DIR}"
    mkdir -p "${BACKUP_DIR}"
    cp -a /etc/netplan "${BACKUP_DIR}/"
  fi

  log "Tworzenie /etc/sysctl.d/99-disable-ipv6.conf"
  {
    echo "net.ipv6.conf.all.disable_ipv6 = 1"
    echo "net.ipv6.conf.default.disable_ipv6 = 1"
    echo "net.ipv6.conf.lo.disable_ipv6 = 1"
    for i in "${IFACES[@]}"; do
      echo "net.ipv6.conf.${i}.disable_ipv6 = 1"
    done
  } > /etc/sysctl.d/99-disable-ipv6.conf
  chmod 600 /etc/sysctl.d/99-disable-ipv6.conf

  log "Tworzenie overlay Netplan /etc/netplan/99-disable-ipv6.yaml"
  {
    echo "network:"
    echo "  version: 2"
    echo "  ethernets:"
    for i in "${IFACES[@]}"; do
      echo "    ${i}:"
      echo "      dhcp6: false"
      echo "      accept-ra: false"
      echo "      link-local: []"
    done
  } > /etc/netplan/99-disable-ipv6.yaml
  chmod 600 /etc/netplan/99-disable-ipv6.yaml

  log "Stosowanie sysctl"
  sysctl -p /etc/sysctl.d/99-disable-ipv6.conf

  if command -v netplan >/dev/null 2>&1; then
    log "netplan generate"
    netplan generate

    log "netplan apply"
    netplan apply
  else
    echo "Brak polecenia netplan - pomijam konfiguracje YAML"
  fi

  log "Weryfikacja"
  echo "all.disable_ipv6=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true)"
  for i in "${IFACES[@]}"; do
    echo "${i}.disable_ipv6=$(cat /proc/sys/net/ipv6/conf/${i}/disable_ipv6 2>/dev/null || true)"
  done
  ip -6 a || true
fi

log "Koniec"
if [[ "${REBOOT_AT_END}" == "1" ]]; then
  reboot
else
  echo "Zalecany reboot po zmianach."
fi

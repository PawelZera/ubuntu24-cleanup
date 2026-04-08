#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Uzycie:
#   sudo bash cleanup-ubuntu24.sh
#   sudo bash cleanup-ubuntu24.sh ntp1.example.com ntp2.example.com
#
# Dodatkowe serwery NTP podajemy jako argumenty pozycyjne.
# Zawsze dolaczane sa awaryjne: tempus1.gum.gov.pl i tempus2.gum.gov.pl
# ---------------------------------------------------------------------------

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
SET_TIMEZONE="${SET_TIMEZONE:-1}"
SET_NTP="${SET_NTP:-1}"
REBOOT_AT_END="${REBOOT_AT_END:-0}"

# Serwery NTP z argumentow + zawsze dodajemy 2 awaryjne GUM
NTP_FALLBACK=("tempus1.gum.gov.pl" "tempus2.gum.gov.pl")
NTP_SERVERS=()
for s in "$@" "${NTP_FALLBACK[@]}"; do
  NTP_SERVERS+=("$s")
done
# usuniecie duplikatow z zachowaniem kolejnosci
mapfile -t NTP_SERVERS < <(printf '%s\n' "${NTP_SERVERS[@]}" | awk '!seen[$0]++')

BACKUP_DIR="/root/netplan-backup-$(date +%F-%H%M%S)"

# Wyciaga TYLKO nazwy interfejsow sieciowych z "netplan get network.ethernets".
# Interfejsy to linie z pojedynczym tokenem pasujacym do typowych nazw kart
# (en*, eth*, ens*, enp*, eno*, bond*, itp.) na poziomie wcięcia 2 spacji.
# Klucze YAML jak dhcp6, accept-ra, addresses sa zaglebione glebiej lub
# nie pasuja do wzorca nazwy interfejsu.
detect_ifaces_from_netplan() {
  if ! command -v netplan >/dev/null 2>&1; then
    return 0
  fi

  netplan get network.ethernets 2>/dev/null \
    | awk '
        # Linia z dokladnie 2 spacjami wciecia + nazwa + dwukropek
        /^  [A-Za-z][A-Za-z0-9._-]+:/ {
          iface = $0
          gsub(/^[[:space:]]+/, "", iface)
          gsub(/:.*$/, "", iface)
          # Odrzuc typowe klucze YAML ktore nie sa nazwami interfejsow
          if (iface !~ /^(dhcp4|dhcp6|accept-ra|addresses|routes|nameservers|link-local|gateway4|gateway6|mtu|match|set-name|wakeonlan|optional|renderer|version|ethernets|wifis|bridges|bonds|vlans|tunnels|vrfs)$/) {
            print iface
          }
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

# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
if [[ "${SET_TIMEZONE}" == "1" ]]; then
  log "Ustawianie strefy czasowej na Europe/Warsaw"
  timedatectl set-timezone Europe/Warsaw
  echo "Strefa czasowa: $(timedatectl show -p Timezone --value)"

  log "Ustawianie formatu czasu 24h (locale)"
  if ! locale -a 2>/dev/null | grep -q 'pl_PL.utf8'; then
    apt -y install language-pack-pl >/dev/null 2>&1 || true
  fi
  update-locale LC_TIME=pl_PL.UTF-8

  if [[ -f /etc/default/locale ]]; then
    if ! grep -q 'LC_TIME' /etc/default/locale; then
      echo 'LC_TIME=pl_PL.UTF-8' >> /etc/default/locale
    else
      sed -i 's/^LC_TIME=.*/LC_TIME=pl_PL.UTF-8/' /etc/default/locale
    fi
  fi
fi

# ---------------------------------------------------------------------------
if [[ "${SET_NTP}" == "1" ]]; then
  log "Konfiguracja NTP (timesyncd)"
  printf 'Serwery NTP: %s\n' "${NTP_SERVERS[*]}"

  if ! command -v timedatectl >/dev/null 2>&1; then
    apt -y install systemd-timesyncd
  fi

  TIMESYNCD_CONF="/etc/systemd/timesyncd.conf.d/99-custom-ntp.conf"
  mkdir -p "$(dirname "${TIMESYNCD_CONF}")"

  PRIMARY_NTP=()
  FALLBACK_NTP=()
  for idx in "${!NTP_SERVERS[@]}"; do
    if [[ $idx -lt 2 ]]; then
      PRIMARY_NTP+=("${NTP_SERVERS[$idx]}")
    else
      FALLBACK_NTP+=("${NTP_SERVERS[$idx]}")
    fi
  done

  {
    echo "[Time]"
    echo "NTP=$(printf '%s ' "${PRIMARY_NTP[@]}" | sed 's/ $//')"
    if [[ ${#FALLBACK_NTP[@]} -gt 0 ]]; then
      echo "FallbackNTP=$(printf '%s ' "${FALLBACK_NTP[@]}" | sed 's/ $//')"
    fi
    echo "PollIntervalMinSec=32"
    echo "PollIntervalMaxSec=2048"
  } > "${TIMESYNCD_CONF}"
  chmod 644 "${TIMESYNCD_CONF}"

  cat "${TIMESYNCD_CONF}"

  log "Wlaczanie i restart systemd-timesyncd"
  systemctl enable --now systemd-timesyncd
  systemctl restart systemd-timesyncd

  for svc in ntp chrony chronyd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      log "Zatrzymywanie konkurencyjnej uslugi NTP: $svc"
      systemctl disable --now "$svc" || true
    fi
  done

  timedatectl set-ntp true

  log "Weryfikacja synchronizacji NTP (czekam maks. 30s)"
  SYNC_OK=0
  for attempt in {1..6}; do
    sleep 5
    STATUS=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "no")
    if [[ "${STATUS}" == "yes" ]]; then
      SYNC_OK=1
      break
    fi
    echo "  Proba ${attempt}/6 - NTPSynchronized=${STATUS}"
  done

  echo
  if [[ "${SYNC_OK}" == "1" ]]; then
    echo "[OK] NTP zsynchronizowany poprawnie."
  else
    echo "[WARN] NTP nie zsynchronizowal sie w ciagu 30s. Sprawdz polaczenie i serwery."
  fi

  log "Stan timesyncd"
  timedatectl status
  timedatectl show-timesync --all 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
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
  # || true - bledy dla nieistniejacych pseudointerfejsow nie przerywaja skryptu
  sysctl -p /etc/sysctl.d/99-disable-ipv6.conf || true

  if command -v netplan >/dev/null 2>&1; then
    log "netplan generate"
    netplan generate

    log "netplan apply"
    netplan apply
  else
    echo "Brak polecenia netplan - pomijam konfiguracje YAML"
  fi

  log "Weryfikacja IPv6"
  echo "all.disable_ipv6=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || true)"
  for i in "${IFACES[@]}"; do
    val=$(cat "/proc/sys/net/ipv6/conf/${i}/disable_ipv6" 2>/dev/null || echo "n/a")
    echo "${i}.disable_ipv6=${val}"
  done
  ip -6 a || true
fi

# ---------------------------------------------------------------------------
log "Koniec"
if [[ "${REBOOT_AT_END}" == "1" ]]; then
  reboot
else
  echo "Zalecany reboot po zmianach."
fi

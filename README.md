# ubuntu24-cleanup

Inteligentny skrypt czyszczący Ubuntu 24.04 LTS przeznaczony dla **serwerów produkcyjnych**:

- wyłącza **automatyczne aktualizacje** (unattended-upgrades, apt-daily, needrestart)
- wyłącza **cloud-init** (lub całkowicie go usuwa)
- odpina i wyłącza usługi **Ubuntu Pro**
- wyłącza **IPv6** przez sysctl + overlay Netplan (czyta interfejsy z `netplan get`)
- konfiguruje **strefę czasową** i **NTP** (z polskimi serwerami GUM jako fallback)
- czyści osierocone pakiety APT (`rc`)

## Szybki start (mini-installer)

```bash
curl -fsSL https://raw.githubusercontent.com/PawelZera/ubuntu24-cleanup/main/install.sh | sudo bash
```

### Z opcjami

```bash
curl -fsSL https://raw.githubusercontent.com/PawelZera/ubuntu24-cleanup/main/install.sh \
  | sudo REBOOT_AT_END=1 PURGE_CLOUD_INIT=1 bash
```

## Zmienne sterujące

| Zmienna | Domyślnie | Opis |
|---|---|---|
| `DISABLE_AUTO_UPGRADES` | `1` | Wyłącza automatyczne aktualizacje (unattended-upgrades, apt-daily timery, APT::Periodic, needrestart) |
| `DISABLE_CLOUD_INIT` | `1` | Tworzy `/etc/cloud/cloud-init.disabled` |
| `PURGE_CLOUD_INIT` | `0` | Całkowicie usuwa pakiet cloud-init |
| `DISABLE_PRO_SERVICES` | `1` | Wyłącza usługi Ubuntu Pro |
| `DETACH_UBUNTU_PRO` | `1` | Odłącza subskrypcję Ubuntu Pro |
| `DISABLE_IPV6` | `1` | Wyłącza IPv6 przez sysctl + netplan overlay |
| `SET_TIMEZONE` | `1` | Ustawia strefę czasową na `Europe/Warsaw` i locale `pl_PL.UTF-8` |
| `SET_NTP` | `1` | Konfiguruje timesyncd z serwerami NTP (argumenty + GUM fallback) |
| `REBOOT_AT_END` | `0` | Restartuje system po zakończeniu |

## Wyłączanie automatycznych aktualizacji

Na serwerach produkcyjnych automatyczne aktualizacje mogą nieoczekiwanie restartować usługi
(np. MySQL, Apache, Zabbix) w trakcie nocnego okna serwisowego `unattended-upgrades`.
Sekcja `DISABLE_AUTO_UPGRADES` blokuje ten mechanizm kompleksowo na czterech poziomach:

1. **systemd** — `disable --now` dla `unattended-upgrades.service`, `apt-daily.timer`, `apt-daily-upgrade.timer`
2. **mask** — `systemctl mask apt-daily.service apt-daily-upgrade.service` (blokada przed uruchomieniem przez zależności)
3. **APT::Periodic** — ustawia wszystkie wartości na `0` w `/etc/apt/apt.conf.d/20auto-upgrades`
4. **needrestart** — jeśli zainstalowany, przełącza tryb na `l` (tylko raport, bez automatycznych restartów usług po aktualizacji bibliotek)

> ⚠️ **Uwaga:** Po wyłączeniu autoaktualizacji serwer nie będzie sam instalował poprawek bezpieczeństwa.
> Pamiętaj o regularnym ręcznym patching'u w oknie serwisowym:
> ```bash
> sudo apt update && apt list --upgradable
> sudo apt full-upgrade
> ```

## Bezpieczne uruchomienie (z weryfikacją SHA-256)

```bash
curl -fsSLO https://raw.githubusercontent.com/PawelZera/ubuntu24-cleanup/main/cleanup-ubuntu24.sh
curl -fsSLO https://raw.githubusercontent.com/PawelZera/ubuntu24-cleanup/main/cleanup-ubuntu24.sh.sha256
sha256sum -c cleanup-ubuntu24.sh.sha256
sudo bash cleanup-ubuntu24.sh
```

> **Uwaga:** Plik `cleanup-ubuntu24.sh.sha256` musisz wygenerować po każdej zmianie skryptu:
> ```bash
> sha256sum cleanup-ubuntu24.sh > cleanup-ubuntu24.sh.sha256
> ```

## Serwery NTP

Dodatkowe serwery NTP można podać jako argumenty pozycyjne. Do podanych zawsze dołączane są dwa awaryjne serwery GUM:

```bash
sudo bash cleanup-ubuntu24.sh ntp1.example.com ntp2.example.com
```

Pierwsze dwa serwery z listy trafiają do dyrektywy `NTP=`, pozostałe do `FallbackNTP=` w konfiguracji `timesyncd`.

## Jak działa wykrywanie interfejsów

1. Najpierw odczytuje `netplan get network.ethernets` – nie rusza bridge, bondów, VLAN-ów
2. Jeśli brak wyników – fallback do `/sys/class/net/*/device`
3. Jeśli nadal brak – fallback do `ip route show default`

## Backup

Przed zmianami netplan skrypt tworzy backup do `/root/netplan-backup-YYYY-MM-DD-HHmmSS/`.

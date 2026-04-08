# ubuntu24-cleanup

Inteligentny skrypt czyszczący Ubuntu 24.04 LTS:
- wyłącza **cloud-init** (lub całkowicie go usuwa)
- odłącza i wyłącza usługi **Ubuntu Pro**
- wyłącza **IPv6** przez sysctl + overlay Netplan (czyta interfejsy z `netplan get`)
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
| `DISABLE_CLOUD_INIT` | `1` | Tworzy `/etc/cloud/cloud-init.disabled` |
| `PURGE_CLOUD_INIT` | `0` | Całkowicie usuwa pakiet cloud-init |
| `DISABLE_PRO_SERVICES` | `1` | Wyłącza usługi Ubuntu Pro |
| `DETACH_UBUNTU_PRO` | `1` | Odłącza subskrypcję Ubuntu Pro |
| `DISABLE_IPV6` | `1` | Wyłącza IPv6 przez sysctl + netplan overlay |
| `REBOOT_AT_END` | `0` | Restartuje system po zakończeniu |

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

## Jak działa wykrywanie interfejsów

1. Najpierw odczytuje `netplan get network.ethernets` – nie rusza bridge, bondów, VLAN-ów
2. Jeśli brak wyników – fallback do `/sys/class/net/*/device`
3. Jeśli nadal brak – fallback do `ip route show default`

## Backup

Przed zmianami netplan skrypt tworzy backup do `/root/netplan-backup-YYYY-MM-DD-HHmmSS/`.

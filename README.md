# xray-tproxy-install

> 🇬🇧 [English version of this README](README_en.md)

Интерактивный установщик **Xray + TPROXY** для OpenWrt (BusyBox `ash`, пакетные менеджеры `opkg` / `apk`). Ставит ядро Xray, конфигурацию прозрачного прокси через nftables TPROXY, опционально — `dnscrypt-proxy2` и `nfqws2`.

## Требования

- OpenWrt, доступ по SSH под `root`
- `curl` или `wget`, `jsonfilter`, `unzip` (недостающее скрипт доустановит сам)
- доступ к GitHub (иначе включается оффлайн-режим)

## Установка

```sh
chmod +x xray-tproxy-install.sh
./xray-tproxy-install.sh
```

Дальше скрипт задаёт несколько вопросов (везде можно нажать Enter — выбор по умолчанию):

1. **Установка** (п. 1) или **удаление** (п. 2).
2. Версия Xray: стабильная (`Stable`) или предварительная (`Pre-release`).
3. IPv4-адрес прокси-сервера в исключение роутинга (можно пропустить).
4. Установить `dnscrypt-proxy2` — рекомендуется.
5. Установить `nfqws2`.
6. Конфигурация Xray: папка `/etc/xray/confs` или один файл `/etc/xray/config.json`.

После установки отредактируйте параметры подключения в `/etc/xray/confs/04_outbounds.json` (там шаблон с `YOUR_UUID`, `YOUR_PBK`, `YOUR_SNI`, `YOUR_SID`, `YOUR_HOST`, `YOUR_HOST_IP`, `YOUR_SPX`) и запустите сервис:

```sh
/etc/init.d/xray-tproxy enable
/etc/init.d/xray-tproxy start
```

Логи: `/var/log/xray/access.log`, `/var/log/xray/error.log`.

## Что ставит скрипт

| Путь | Назначение |
|---|---|
| `/usr/bin/xray` | ядро Xray (качается с GitHub Releases под архитектуру роутера) |
| `/etc/init.d/xray-tproxy` | init-скрипт procd: проверка конфига, модули, policy routing, nft-правила, запуск Xray |
| `/etc/xray/tproxy.nft` | правила nftables: TPROXY TCP+UDP на порт `12345` для `br-lan` / `192.168.1.0/24`, исключения для приватных подсетей, обработка маркировки |
| `/etc/config/xray` | UCI-конфиг: `confdir` / `conffiles`, `datadir`, формат |
| `/etc/xray/confs/0{1..6}_*.json` | конфигурация Xray: логи, DNS (`127.0.0.53`), inbound `dokodemo-door` с TPROXY, outbound VLESS+REALITY+xHTTP, роутинг, policy |
| `/usr/share/xray/` | geo-файлы: `geoip_v2fly.dat`, `geosite_v2fly.dat`, `geoip_zkeenip.dat`, `geosite_zkeen.dat` |
| `/var/log/xray/` | логи доступа и ошибок |
| `/var/log/xray-geoupdate.log` | лог автообновления geo-файлов (задача cron) |
| `/etc/dnscrypt-proxy2/dnscrypt-proxy.toml` | конфиг dnscrypt-proxy2 (DoH: Google/Cloudflare, слушает `127.0.0.53:53`) |
| `/etc/config/dhcp` | дописывает `noresolv`, `server 127.0.0.53`, `cachesize 0` |

Роутинг в конфиге: реклама и аналитика → `block`, RU/YouTube и torrent → `direct`, всё остальное → `proxy`.

## Автообновление geo-файлов

При установке файлы geodat скачиваются из последних релизов на GitHub:

- `geoip_v2fly.dat` — [v2fly/geoip](https://github.com/v2fly/geoip)
- `geosite_v2fly.dat` — [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community)
- `geoip_zkeenip.dat` — [jameszeroX/zkeen-ip](https://github.com/jameszeroX/zkeen-ip)
- `geosite_zkeen.dat` — [jameszeroX/zkeen-domains](https://github.com/jameszeroX/zkeen-domains)

Скрипт автоматически создаёт задачу **cron**, которая каждый день в **04:00 по местному времени** проверяет релизы и обновляет все geo-файлы до последней версии, а затем перезапускает сервис `xray-tproxy`, чтобы новые базы вступили в силу. Задача записывается в `/etc/crontabs/root`:

```sh
0 4 * * * <путь к xray-tproxy-install.sh> --update-geodat >> /var/log/xray-geoupdate.log 2>&1
```

Обновить geo-файлы вручную можно в любой момент:

```sh
./xray-tproxy-install.sh --update-geodat
```

Для работы cron нужен установленный и запущенный пакет `cron` (`crond`) — скрипт попытается включить и запустить его самостоятельно при установке. Если скрипт запущен через `curl | sh` и путь к нему не удаётся определить, задача cron не создаётся — добавьте её в `/etc/crontabs/root` вручную по примеру выше.

При удалении (пункт 2 меню) задача cron удаляется автоматически.

## Удаление

Пункт 2 меню останавливает и отключает сервис, убирает nft-таблицу `xray_tproxy` и правила policy routing (fwmark `0x100`, таблица `100`), удаляет бинарник, init-скрипт, geo-файлы, логи и nft-конфиг. **Не трогает** `dnscrypt-proxy2`, `nfqws2` и ваши конфиги (`/etc/xray/confs`, `/etc/xray/config.json`) — их нужно очистить вручную:

```sh
rm -rf /etc/xray/confs /etc/xray/config.json
```

## Замечания

- Подсеть LAN и интерфейс в `/etc/xray/tproxy.nft` зашиты как `br-lan` / `192.168.1.0/24` — при другой схеме сети отредактируйте файл перед запуском.
- Порт TPROXY — `12345`, метка прокси-трафика — `0x100`, исходящие сокеты Xray маркируются `255`.

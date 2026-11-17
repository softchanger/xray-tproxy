# xray-tproxy-install

> 🇷🇺 [Русская версия этого README](README.md)

Interactive installer for **Xray + TPROXY** on OpenWrt (BusyBox `ash`, package managers `opkg` / `apk`). Installs the Xray core, a transparent proxy configuration via nftables TPROXY, and optionally `dnscrypt-proxy2` and `nfqws2`.

## Requirements

- OpenWrt, SSH access as `root`
- `curl` or `wget`, `jsonfilter`, `unzip` (the script installs anything missing)
- access to GitHub (otherwise offline mode kicks in)

## Installation

```sh
chmod +x xray-tproxy-install.sh
./xray-tproxy-install.sh
```

The script then asks a few questions (you can press Enter everywhere to accept the default):

1. **Install** (item 1) or **remove** (item 2).
2. Xray version: `Stable` or `Pre-release`.
3. IPv4 address of the proxy server to exclude from routing (can be skipped).
4. Install `dnscrypt-proxy2` — recommended.
5. Install `nfqws2`.
6. Xray configuration: folder `/etc/xray/confs` or a single file `/etc/xray/config.json`.

After installation, edit the connection parameters in `/etc/xray/confs/04_outbounds.json` (it contains a template with `YOUR_UUID`, `YOUR_PBK`, `YOUR_SNI`, `YOUR_SID`, `YOUR_HOST`, `YOUR_HOST_IP`, `YOUR_SPX`) and start the service:

```sh
/etc/init.d/xray-tproxy enable
/etc/init.d/xray-tproxy start
```

Logs: `/var/log/xray/access.log`, `/var/log/xray/error.log`.

## What the script installs

| Path | Purpose |
|---|---|
| `/usr/bin/xray` | Xray core (downloaded from GitHub Releases for the router's architecture) |
| `/etc/init.d/xray-tproxy` | procd init script: config check, modules, policy routing, nft rules, Xray start |
| `/etc/xray/tproxy.nft` | nftables rules: TPROXY TCP+UDP on port `12345` for `br-lan` / `192.168.1.0/24`, exclusions for private subnets, mark handling |
| `/etc/config/xray` | UCI config: `confdir` / `conffiles`, `datadir`, format |
| `/etc/xray/confs/0{1..6}_*.json` | Xray configuration: logs, DNS (`127.0.0.53`), `dokodemo-door` inbound with TPROXY, VLESS+REALITY+xHTTP outbound, routing, policy |
| `/usr/share/xray/` | geo files: `geoip_v2fly.dat`, `geosite_v2fly.dat`, `geoip_zkeenip.dat`, `geosite_zkeen.dat` |
| `/var/log/xray/` | access and error logs |
| `/var/log/xray-geoupdate.log` | log of automatic geo file updates (cron job) |
| `/etc/dnscrypt-proxy2/dnscrypt-proxy.toml` | dnscrypt-proxy2 config (DoH: Google/Cloudflare, listens on `127.0.0.53:53`) |
| `/etc/config/dhcp` | appends `noresolv`, `server 127.0.0.53`, `cachesize 0` |

Routing in the config: ads and analytics → `block`, RU/YouTube and torrent → `direct`, everything else → `proxy`.

## Automatic geodat file updates

On installation the geodat files are downloaded from the latest GitHub releases:

- `geoip_v2fly.dat` — [v2fly/geoip](https://github.com/v2fly/geoip)
- `geosite_v2fly.dat` — [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community)
- `geoip_zkeenip.dat` — [jameszeroX/zkeen-ip](https://github.com/jameszeroX/zkeen-ip)
- `geosite_zkeen.dat` — [jameszeroX/zkeen-domains](https://github.com/jameszeroX/zkeen-domains)

The script automatically creates a **cron** job that, every day at **04:00 local time**, checks the releases and updates all geo files to their latest versions, then restarts the `xray-tproxy` service so the new databases take effect. The job is written to `/etc/crontabs/root`:

```sh
0 4 * * * <path to xray-tproxy-install.sh> --update-geodat >> /var/log/xray-geoupdate.log 2>&1
```

You can also update the geo files manually at any time:

```sh
./xray-tproxy-install.sh --update-geodat
```

Cron requires the `cron` package (`crond`) installed and running — the script tries to enable and start it by itself during installation. If the script is run via `curl | sh` and its path cannot be determined, the cron job is not created — add it to `/etc/crontabs/root` manually using the example above.

On removal (menu item 2) the cron job is removed automatically.

## Removal

Menu item 2 stops and disables the service, removes the nftables table `xray_tproxy` and the policy routing rules (fwmark `0x100`, table `100`), and deletes the binary, init script, geo files, logs and nft config. It does **not** touch `dnscrypt-proxy2`, `nfqws2` or your configs (`/etc/xray/confs`, `/etc/xray/config.json`) — clean them up manually:

```sh
rm -rf /etc/xray/confs /etc/xray/config.json
```

## Notes

- The LAN subnet and interface are hardcoded in `/etc/xray/tproxy.nft` as `br-lan` / `192.168.1.0/24` — edit the file before running if your network layout differs.
- TPROXY port is `12345`, the proxy traffic mark is `0x100`, outgoing Xray sockets are marked `255`.

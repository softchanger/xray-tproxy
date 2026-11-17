#!/bin/sh

# ============================================================
# Xray TProxy installer for OpenWrt
# Compatible with BusyBox ash
# Encoding: UTF-8 (без поломки консоли под dropbear/openssh)
# ============================================================

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
umask 022

# --- Кодировка: гарантируем UTF-8, чтобы русские символы не ломали консоль ---
export LANG="${LANG:-C.UTF-8}"
export LC_CTYPE="${LC_CTYPE:-C.UTF-8}"

# -------------------- Цвета --------------------

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
light_blue='\033[0;94m'
reset='\033[0m'

# -------------------- Вывод --------------------

print_error() {
    printf "  ${red}Ошибка:${reset} %s\n" "$1" >&2
}

print_success() {
    printf "  ${green}%s${reset}\n" "$1"
}

print_warning() {
    printf "  ${yellow}%s${reset}\n" "$1"
}

print_info() {
    printf "  %s\n" "$1"
}

# -------------------- Проверка root --------------------

if [ "$(id -u)" != "0" ]; then
    print_error "Скрипт должен запускаться от имени root."
    exit 1
fi

# -------------------- Определение пакетного менеджера --------------------

if command -v opkg >/dev/null 2>&1; then
    pkg_manager="opkg"
elif command -v apk >/dev/null 2>&1; then
    pkg_manager="apk"
else
    print_error "Не найден пакетный менеджер opkg или apk."
    exit 1
fi

print_info "Пакетный менеджер: ${yellow}$pkg_manager${reset}"

# -------------------- Архитектура --------------------

arch="$(uname -m)"

case "$arch" in
    x86_64|amd64)
        xray_arch="64"
        ;;
    aarch64|arm64)
        xray_arch="arm64-v8a"
        ;;
    armv7l|armv7*)
        xray_arch="arm32-v7a"
        ;;
    armv6l)
        xray_arch="arm32-v6"
        ;;
    i386|i486|i586|i686)
        xray_arch="32"
        ;;
    mipsel*)
        xray_arch="mips32le"
        ;;
    mips*)
        xray_arch="mips32"
        ;;
    *)
        xray_arch=""
        ;;
esac

print_info "Архитектура: ${yellow}$arch${reset} (xray: ${yellow}$xray_arch${reset})"

# -------------------- Путь к скрипту (используется для задачи cron автообновления geo-файлов) --------------------

install_script_path="$0"
if command -v readlink >/dev/null 2>&1; then
    _script_resolved="$(readlink -f -- "$0" 2>/dev/null)"
    [ -n "$_script_resolved" ] && [ -f "$_script_resolved" ] && install_script_path="$_script_resolved"
elif command -v realpath >/dev/null 2>&1; then
    _script_resolved="$(realpath -- "$0" 2>/dev/null)"
    [ -n "$_script_resolved" ] && [ -f "$_script_resolved" ] && install_script_path="$_script_resolved"
fi
case "$install_script_path" in
    /*) : ;;
    *) install_script_path="$(pwd)/$install_script_path" ;;
esac
[ -f "$install_script_path" ] || install_script_path=""

# -------------------- Скачивание файла --------------------

download_file() {
    url="$1"
    output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 15 --max-time 300 \
            "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$output" "$url"
    else
        return 1
    fi
}

# -------------------- Получение URL ассета из последнего релиза GitHub --------------------

# get_github_latest_asset <owner/repo> <asset_name> <out_var>
get_github_latest_asset() {
    repo="$1"
    asset="$2"
    out_var="$3"

    api="https://api.github.com/repos/${repo}/releases/latest"
    rfile="/tmp/xray-gh-release.json"

    if ! download_file "$api" "$rfile"; then
        rm -f "$rfile"
        return 1
    fi

    i=0
    url=""
    name=""
    while [ "$i" -lt 100 ]; do
        name="$(jsonfilter -i "$rfile" -e "@.assets[${i}].name" 2>/dev/null)"
        [ -z "$name" ] && break
        if [ "$name" = "$asset" ]; then
            url="$(jsonfilter -i "$rfile" -e "@.assets[${i}].browser_download_url" 2>/dev/null)"
            break
        fi
        i=$((i + 1))
    done

    rm -f "$rfile"

    if [ -z "$url" ]; then
        return 1
    fi

    eval "${out_var}=\"\${url}\""
    return 0
}

# -------------------- Обновление geo-файлов --------------------

# Скачивает файлы geodat из последних релизов GitHub (как при установке,
# так и по задаче cron --update-geodat). Заменяет файлы атомарно (через .tmp),
# чтобы не оставить битый файл при обрыве связи.
update_geodat_files() {
    target_dir="$1"
    failed=0
    url=""

    mkdir -p "$target_dir"

    if ! command -v jsonfilter >/dev/null 2>&1; then
        print_error "jsonfilter не найден, невозможно определить URL geo-файлов."
        return 1
    fi

    printf "\n  Скачиваем geo-файлы в %s (последние релизы)...\n" "$target_dir"

    # geoip_v2fly.dat (v2fly/geoip -> geoip.dat)
    if get_github_latest_asset "v2fly/geoip" "geoip.dat" url; then
        if download_file "$url" "$target_dir/geoip_v2fly.dat.tmp" && mv "$target_dir/geoip_v2fly.dat.tmp" "$target_dir/geoip_v2fly.dat"; then
            print_success "geoip_v2fly.dat скачан."
        else
            rm -f "$target_dir/geoip_v2fly.dat.tmp"
            print_error "Не удалось скачать geoip_v2fly.dat."
            failed=1
        fi
    else
        print_error "Не найден ассет geoip.dat в v2fly/geoip."
        failed=1
    fi

    # geosite_v2fly.dat (v2fly/domain-list-community -> dlc.dat)
    if get_github_latest_asset "v2fly/domain-list-community" "dlc.dat" url; then
        if download_file "$url" "$target_dir/geosite_v2fly.dat.tmp" && mv "$target_dir/geosite_v2fly.dat.tmp" "$target_dir/geosite_v2fly.dat"; then
            print_success "geosite_v2fly.dat скачан."
        else
            rm -f "$target_dir/geosite_v2fly.dat.tmp"
            print_error "Не удалось скачать geosite_v2fly.dat."
            failed=1
        fi
    else
        print_error "Не найден ассет dlc.dat в v2fly/domain-list-community."
        failed=1
    fi

    # geoip_zkeenip.dat (jameszeroX/zkeen-ip -> zkeenip.dat)
    if get_github_latest_asset "jameszeroX/zkeen-ip" "zkeenip.dat" url; then
        if download_file "$url" "$target_dir/geoip_zkeenip.dat.tmp" && mv "$target_dir/geoip_zkeenip.dat.tmp" "$target_dir/geoip_zkeenip.dat"; then
            print_success "geoip_zkeenip.dat скачан."
        else
            rm -f "$target_dir/geoip_zkeenip.dat.tmp"
            print_error "Не удалось скачать geoip_zkeenip.dat."
            failed=1
        fi
    else
        print_error "Не найден ассет zkeenip.dat в jameszeroX/zkeen-ip."
        failed=1
    fi

    # geosite_zkeen.dat (jameszeroX/zkeen-domains -> zkeen.dat)
    if get_github_latest_asset "jameszeroX/zkeen-domains" "zkeen.dat" url; then
        if download_file "$url" "$target_dir/geosite_zkeen.dat.tmp" && mv "$target_dir/geosite_zkeen.dat.tmp" "$target_dir/geosite_zkeen.dat"; then
            print_success "geosite_zkeen.dat скачан."
        else
            rm -f "$target_dir/geosite_zkeen.dat.tmp"
            print_error "Не удалось скачать geosite_zkeen.dat."
            failed=1
        fi
    else
        print_error "Не найден ассет zkeen.dat в jameszeroX/zkeen-domains."
        failed=1
    fi

    return "$failed"
}

# -------------------- Задача cron автообновления geo-файлов --------------------

# Добавляет в /etc/crontabs/root задачу на ежедневное обновление geo-файлов
# в 04:00 по местному времени и запускает crond.
setup_cron_geodat() {
    script_path="$1"
    cron_file="/etc/crontabs/root"
    cron_entry="0 4 * * * $script_path --update-geodat >> /var/log/xray-geoupdate.log 2>&1"
    tmp=""

    [ -n "$script_path" ] || {
        print_warning "Не удалось определить путь к скрипту — задача cron автообновления geo-файлов не создана."
        print_info "Добавьте её вручную в /etc/crontabs/root (пример):"
        print_info "  0 4 * * * <путь к xray-tproxy-install.sh> --update-geodat >> /var/log/xray-geoupdate.log 2>&1"
        return 1
    }

    mkdir -p /etc/crontabs 2>/dev/null
    touch "$cron_file" 2>/dev/null || {
        print_warning "Не удалось создать $cron_file — задача cron автообновления geo-файлов не создана."
        return 1
    }

    tmp="/etc/crontabs/root.xray-tproxy.tmp.$$"
    awk 'index($0, "--update-geodat") == 0' "$cron_file" > "$tmp" 2>/dev/null || {
        rm -f "$tmp"
        print_warning "Не удалось обновить $cron_file."
        return 1
    }
    printf "%s\n" "$cron_entry" >> "$tmp"
    mv "$tmp" "$cron_file"
    chmod 644 "$cron_file" 2>/dev/null

    if [ -x /etc/init.d/cron ]; then
        /etc/init.d/cron enable >/dev/null 2>&1 || true
        /etc/init.d/cron start >/dev/null 2>&1 || true
    elif command -v crond >/dev/null 2>&1; then
        crond >/dev/null 2>&1 || true
    else
        print_warning "crond не найден — установите пакет cron и запустите crond, иначе автообновление geo-файлов не сработает."
    fi

    print_success "Задача cron автообновления geo-файлов создана: $cron_entry"
    return 0
}

# -------------------- Быстрый режим: только обновление geo-файлов --------------------

# Запускается задачей cron (--update-geodat): обновляет geo-файлы до
# последних версий и перезапускает xray-tproxy, чтобы новые базы вступили в силу.
if [ "$1" = "--update-geodat" ]; then
    update_geodat_files /usr/share/xray
    rc=$?
    if pidof xray >/dev/null 2>&1; then
        /etc/init.d/xray-tproxy restart >/dev/null 2>&1 || print_warning "Не удалось перезапустить xray-tproxy после обновления geo-файлов."
    fi
    exit "$rc"
fi

# -------------------- Удаление --------------------

remove_xray_tproxy() {
    printf "\n  Удаление xray-tproxy...\n\n"

    # 1. Остановить и отключить сервис.
    if [ -x /etc/init.d/xray-tproxy ]; then
        /etc/init.d/xray-tproxy stop >/dev/null 2>&1
        /etc/init.d/xray-tproxy disable >/dev/null 2>&1
    fi

    # 1.5. Удалить задачу cron автообновления geo-файлов.
    if [ -f /etc/crontabs/root ]; then
        tmp="/etc/crontabs/root.xray-tproxy.tmp.$$"
        awk 'index($0, "--update-geodat") == 0' /etc/crontabs/root > "$tmp" 2>/dev/null
        mv "$tmp" /etc/crontabs/root 2>/dev/null
        chmod 644 /etc/crontabs/root 2>/dev/null
    fi

    # 2. Убрать nftables-правила и policy routing.
    nft delete table ip xray_tproxy 2>/dev/null
    ip rule del fwmark 0x100/0x100 lookup 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null

    # 3. Удалить файлы, установленные скриптом.
    #    НЕ трогаем: dnscrypt-proxy2, nfqws2 и конфигурации xray
    #    (/etc/xray/confs, /etc/xray/config.json).
    rm -f /etc/init.d/xray-tproxy
    rm -f /usr/bin/xray
    rm -rf /usr/share/xray
    rm -rf /var/log/xray
    rm -f /etc/xray/tproxy.nft
    rm -f /etc/config/xray
    rm -rf /tmp/xray-install /tmp/xray-gh-release.json

    # 4. Удалить /etc/xray, если там ничего не осталось.
    rmdir /etc/xray 2>/dev/null

    printf "  ${green}xray-tproxy удален.${reset}\n"
    printf "  Для полной очистки выполните самостоятельно:\n"
    printf "    ${yellow}rm -rf /etc/xray/confs /etc/xray/config.json${reset}\n"
    printf "  dnscrypt-proxy2 и nfqws2 не удалены.\n\n"
}

# -------------------- Главное меню --------------------

while true; do
    printf "\n"
    printf "  ${light_blue}Xray TProxy Installer${reset}\n\n"
    printf "  Выберите действие:\n\n"
    printf "  1) Установка xray-tproxy (по умолчанию)\n"
    printf "  2) Удаление и полная очистка xray-tproxy\n\n"
    printf "  Выберите пункт меню [1]: "

    read -r action

    [ -z "$action" ] && action=1

    case "$action" in
        1)
            printf "\n  Выбрана ${light_blue}установка xray-tproxy${reset}\n"
            break
            ;;
        2)
            remove_xray_tproxy
            exit 0
            ;;
        *)
            printf "\n"
            print_error "Неверный выбор. Введите 1 или 2."
            ;;
    esac
done

# -------------------- Проверка интернета --------------------

check_internet() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 15 \
            https://api.github.com/ \
            -o /dev/null 2>/dev/null
        return $?
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 15 -O /dev/null \
            https://api.github.com/ 2>/dev/null
        return $?
    fi

    return 1
}

offline=0

if ! check_internet; then
    printf "\n"
    printf "  ${red}Не удалось проверить доступность интернета.${reset}\n"
    printf "  Вы должны самостоятельно установить ядро Xray\n"
    printf "  под вашу архитектуру (${yellow}%s${reset}) и файлы geodat.\n\n" "$arch"

    printf "  Продолжить оффлайн-установку? [y/N]: "
    read -r offline_choice

    case "$offline_choice" in
        y|Y)
            offline=1
            print_warning "Продолжаем оффлайн-установку."
            ;;
        *)
            printf "\n"
            print_warning "Установка отменена."
            exit 0
            ;;
    esac
fi

# -------------------- Установка Xray --------------------

install_xray() {
    if [ -z "$xray_arch" ]; then
        print_error "Неизвестная архитектура: $arch"
        return 1
    fi

    if ! command -v jsonfilter >/dev/null 2>&1; then
        print_error "Не найдена утилита jsonfilter (установите пакет jsonfilter)."
        return 1
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        print_warning "Утилита unzip не найдена, устанавливаем..."

        if [ "$pkg_manager" = "opkg" ]; then
            opkg update && opkg install unzip || return 1
        else
            apk add unzip || return 1
        fi
    fi

    while true; do
        printf "\n  Какую версию ${yellow}Xray${reset} вы хотите установить?\n\n"
        printf "  1) Последнюю стабильную версию (${light_blue}Stable${reset})\n"
        printf "  2) Последнюю предварительную версию (${light_blue}Alpha / Pre-release${reset})\n\n"
        printf "  Выберите пункт [1]: "

        read -r version_choice
        [ -z "$version_choice" ] && version_choice=1

        case "$version_choice" in
            1)
                release_api="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
                release_type="stable"
                break
                ;;
            2)
                release_api="https://api.github.com/repos/XTLS/Xray-core/releases?per_page=30"
                release_type="prerelease"
                break
                ;;
            *)
                print_error "Неверный выбор."
                ;;
        esac
    done

    tmp_dir="/tmp/xray-install"
    mkdir -p "$tmp_dir" || return 1

    printf "\n  Получаем информацию о релизе Xray...\n"

    if ! download_file "$release_api" "$tmp_dir/releases.json"; then
        print_error "Не удалось получить информацию о релизах."
        return 1
    fi

    # Определяем тег релиза.
    if [ "$release_type" = "stable" ]; then
        release_index=""
        release_tag="$(jsonfilter -i "$tmp_dir/releases.json" \
            -e '@.tag_name')"
    else
        release_index=0
        release_tag=""

        while [ "$release_index" -lt 30 ]; do
            is_prerelease="$(jsonfilter -i "$tmp_dir/releases.json" \
                -e "@[${release_index}].prerelease")"

            if [ "$is_prerelease" = "true" ]; then
                release_tag="$(jsonfilter -i "$tmp_dir/releases.json" \
                    -e "@[${release_index}].tag_name")"
                break
            fi

            release_index=$((release_index + 1))
        done
    fi

    if [ -z "$release_tag" ]; then
        print_error "Не удалось определить версию Xray."
        return 1
    fi

    printf "  Выбрана версия: ${yellow}%s${reset}\n" "$release_tag"

    # Имя официального архива.
    asset_name="Xray-linux-${xray_arch}.zip"

    # Получаем URL архива из списка assets.
    asset_index=0
    asset_url=""

    while [ "$asset_index" -lt 100 ]; do
        if [ -n "$release_index" ]; then
            asset_name_check="$(jsonfilter -i "$tmp_dir/releases.json" \
                -e "@[${release_index}].assets[${asset_index}].name")"

            candidate_url="$(jsonfilter -i "$tmp_dir/releases.json" \
                -e "@[${release_index}].assets[${asset_index}].browser_download_url")"
        else
            asset_name_check="$(jsonfilter -i "$tmp_dir/releases.json" \
                -e "@.assets[${asset_index}].name")"

            candidate_url="$(jsonfilter -i "$tmp_dir/releases.json" \
                -e "@.assets[${asset_index}].browser_download_url")"
        fi

        [ -z "$asset_name_check" ] && break

        if [ "$asset_name_check" = "$asset_name" ]; then
            asset_url="$candidate_url"
            break
        fi

        asset_index=$((asset_index + 1))
    done

    if [ -z "$asset_url" ]; then
        print_error "Архив $asset_name не найден в релизе $release_tag."
        return 1
    fi

    printf "\n  Скачиваем ${yellow}%s${reset}...\n" "$asset_name"

    if ! download_file "$asset_url" "$tmp_dir/xray.zip"; then
        print_error "Не удалось скачать Xray."
        return 1
    fi

    mkdir -p "$tmp_dir/unpacked"

    if ! unzip -o "$tmp_dir/xray.zip" xray \
        -d "$tmp_dir/unpacked" >/dev/null 2>&1; then
        print_error "Не удалось распаковать архив Xray."
        return 1
    fi

    if [ ! -f "$tmp_dir/unpacked/xray" ]; then
        print_error "В архиве отсутствует исполняемый файл xray."
        return 1
    fi

    # Установка бинарника в /usr/bin (стандартное место для пользовательских демонов в OpenWrt).
    install -m 0755 "$tmp_dir/unpacked/xray" /usr/bin/xray || return 1

    if ! /usr/bin/xray version >/dev/null 2>&1; then
        print_error "Xray не запускается. Возможно, бинарник несовместим с архитектурой."
        rm -f /usr/bin/xray
        return 1
    fi

    rm -rf "$tmp_dir"

    print_success "Xray успешно установлен в /usr/bin/xray."
    /usr/bin/xray version

    return 0
}

# -------------------- Запуск установки Xray --------------------

if [ "$offline" -eq 0 ]; then
    install_xray || exit 1
else
    print_warning "Пропущена установка ядра Xray (оффлайн-режим)."
fi

# -------------------- Создание каталогов --------------------

printf "\n  Создаём необходимые каталоги...\n"

mkdir -p /etc/xray || exit 1
mkdir -p /etc/xray/confs || exit 1
mkdir -p /usr/share/xray || exit 1
mkdir -p /var/log/xray || exit 1

touch /var/log/xray/access.log
touch /var/log/xray/error.log

print_success "Каталоги успешно созданы."

# -------------------- IPv4 прокси-сервер в исключение роутинга --------------------

printf "\n  Добавить IPv4 прокси-сервера в исключение роутинга (рекомендуется):?\n"
printf "  Введите IPv4-адрес (или Enter для пропуска): "
read -r proxy_ipv4

proxy_ipv4_set=0

validate_ipv4() {
    ip="$1"
    [ -z "$ip" ] && return 1
    case "$ip" in
        ''|*[!0-9.]*) return 1 ;;
    esac
    # Разбиваем на октеты.
    old_ifs="$IFS"
    IFS=.
    set -- $ip
    IFS="$old_ifs"
    [ $# -eq 4 ] || return 1
    for octet do
        [ -n "$octet" ] || return 1
        case "$octet" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$octet" -ge 0 ] 2>/dev/null || return 1
        [ "$octet" -le 255 ] 2>/dev/null || return 1
        # Запрещаем ведущие нули, кроме самого "0".
        [ "$octet" = "0" ] || {
            [ "${octet#0}" = "$octet" ] || return 1
        }
    done
    return 0
}

if [ -n "$proxy_ipv4" ] && validate_ipv4 "$proxy_ipv4"; then
    proxy_ipv4_set=1
    print_success "IPv4 прокси сервера (${proxy_ipv4}) был добавлен в исключение роутинга."
else
    if [ -n "$proxy_ipv4" ]; then
        print_warning "Пропущено добавление IPv4 прокси-сервера в исключение роутинга."
    else
        print_warning "Пропущено добавление IPv4 прокси-сервера в исключение роутинга."
    fi
fi

# -------------------- dnscrypt-proxy2 --------------------

printf "\n  Установить ${yellow}dnscrypt-proxy2${reset} (рекомендуется)? [Y/n]: "
read -r dnscrypt_choice
[ -z "$dnscrypt_choice" ] && dnscrypt_choice="y"

dnscrypt_installed=0

case "$dnscrypt_choice" in
    y|Y)
        if [ "$pkg_manager" = "opkg" ]; then
            opkg update && opkg install dnscrypt-proxy2 || {
                print_error "Не удалось установить dnscrypt-proxy2 через opkg."
            }
        else
            apk add dnscrypt-proxy2 || {
                print_error "Не удалось установить dnscrypt-proxy2 через apk."
            }
        fi

        if command -v dnscrypt-proxy >/dev/null 2>&1 || opkg list-installed dnscrypt-proxy2 >/dev/null 2>&1 || apk info -e dnscrypt-proxy2 >/dev/null 2>&1; then
            dnscrypt_installed=1
            print_success "dnscrypt-proxy2 установлен."
        else
            print_warning "dnscrypt-proxy2 не найден после установки."
        fi
        ;;
    *)
        print_warning "Пропущена установка dnscrypt-proxy2."
        ;;
esac

if [ "$dnscrypt_installed" -eq 1 ]; then
    # Включаем сервис.
    /etc/init.d/dnscrypt-proxy enable >/dev/null 2>&1 || true

    # Пишем конфигурационный файл dnscrypt-proxy2.
    mkdir -p /etc/dnscrypt-proxy2
    cat > /etc/dnscrypt-proxy2/dnscrypt-proxy.toml <<'EOF'
server_names = ['google', 'cloudflare']

listen_addresses = ['127.0.0.53:53']

max_clients = 250
ipv4_servers = true
ipv6_servers = false

dnscrypt_servers = false

doh_servers = true
odoh_servers = false
require_dnssec = false
require_nolog = true
require_nofilter = true
disabled_server_names = []
force_tcp = false
http3 = false
http3_probe = false
timeout = 5000
keepalive = 30
log_files_max_size = 10
log_files_max_age = 7
log_files_max_backups = 1
cert_refresh_delay = 240

bootstrap_resolvers = ['8.8.8.8:53', '8.8.4.4:53', '1.1.1.1:53']

ignore_system_dns = true
netprobe_timeout = 60
netprobe_address = '8.8.8.8:53'

block_ipv6 = false
block_unqualified = true
block_undelegated = true
reject_ttl = 10

cache = true
cache_size = 4096
cache_min_ttl = 2400
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600

[captive_portals]
[local_doh]
[query_log]
format = 'tsv'
[nx_log]
format = 'tsv'
[blocked_names]
[blocked_ips]
[allowed_names]
[allowed_ips]
[schedules]
[sources]

[sources.public-resolvers]
urls = [
 'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md',
 'https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md',
]
cache_file = 'public-resolvers.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 73
prefix = ''

[sources.relays]
urls = [
 'https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/relays.md',
 'https://download.dnscrypt.info/resolvers-list/v3/relays.md',
]
cache_file = 'relays.md'
minisign_key = 'RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3'
refresh_delay = 73
prefix = ''

[broken_implementations]
fragments_blocked = [
 'cisco',
 'cisco-ipv6',
 'cisco-familyshield',
 'cisco-familyshield-ipv6',
 'cisco-sandbox',
 'cleanbrowsing-adult',
 'cleanbrowsing-adult-ipv6',
 'cleanbrowsing-family',
 'cleanbrowsing-family-ipv6',
 'cleanbrowsing-security',
 'cleanbrowsing-security-ipv6',
]

[doh_client_x509_auth]

[anonymized_dns]
skip_incompatible = false

[dns64]
[ip_encryption]
algorithm = "none"
key = ""

# [monitoring_ui]
# enabled = false
# listen_address = "127.0.0.1:8080"
# username = "admin"
# password = "changeme"
# tls_certificate = ""
# tls_key = ""
# enable_query_log = true
# privacy_level = 1

[static]
EOF
    print_success "Конфигурация dnscrypt-proxy2 записана в /etc/dnscrypt-proxy2/dnscrypt-proxy.toml."

    # Настройка /etc/config/dhcp.
    if [ -f /etc/config/dhcp ]; then
        grep -q "option noresolv '1'" /etc/config/dhcp || {
            printf "\noption noresolv '1'\n" >> /etc/config/dhcp
        }
        grep -q "list server '127.0.0.53'" /etc/config/dhcp || {
            printf "list server '127.0.0.53'\n" >> /etc/config/dhcp
        }
        grep -q "option cachesize '0'" /etc/config/dhcp || {
            printf "option cachesize '0'\n" >> /etc/config/dhcp
        }
    else
        cat > /etc/config/dhcp <<'EOF'
config dnsmasq
    option noresolv '1'
    list server '127.0.0.53'
    option cachesize '0'
EOF
    fi
    print_success "В /etc/config/dhcp включены noresolv, server 127.0.0.53 и cachesize 0."
fi

# -------------------- nfqws2 --------------------

printf "\n  Установить ${yellow}nfqws2${reset} (по туториалу с GitHub)? [Y/n]: "
read -r nfqws_choice
[ -z "$nfqws_choice" ] && nfqws_choice="y"

case "$nfqws_choice" in
    y|Y)
        if [ "$pkg_manager" = "opkg" ]; then
            print_info "Установка nfqws2 через opkg (OpenWrt)..."
            wget -O /tmp/nfqws2-keenetic.pub "https://nfqws.github.io/nfqws2-keenetic/openwrt/nfqws2-keenetic.pub" 2>/dev/null && \
                opkg-key add /tmp/nfqws2-keenetic.pub 2>/dev/null || true
            echo "src/gz nfqws2-keenetic https://nfqws.github.io/nfqws2-keenetic/openwrt" > /etc/opkg/nfqws2-keenetic.conf
            opkg update && opkg install nfqws2-keenetic || {
                print_error "Не удалось установить nfqws2 через opkg."
            }
        else
            print_info "Установка nfqws2 через apk (OpenWrt 25.xx / snapshot)..."
            wget -O /etc/apk/keys/nfqws2-keenetic.pem "https://nfqws.github.io/nfqws2-keenetic/openwrt/nfqws2-keenetic.pem" 2>/dev/null || true
            echo "https://nfqws.github.io/nfqws2-keenetic/openwrt/packages.adb" > /etc/apk/repositories.d/nfqws2-keenetic.list
            apk --update-cache add nfqws2-keenetic || {
                print_error "Не удалось установить nfqws2 через apk."
            }
        fi
        if command -v nfqws2 >/dev/null 2>&1 || opkg list-installed nfqws2-keenetic >/dev/null 2>&1 || apk info -e nfqws2-keenetic >/dev/null 2>&1; then
            print_success "nfqws2 установлен."
        else
            print_warning "nfqws2 не найден после установки."
        fi
        ;;
    *)
        print_warning "Пропущена установка nfqws2."
        ;;
esac

# -------------------- Init-скрипт /etc/init.d/xray-tproxy --------------------

cat > /etc/init.d/xray-tproxy <<'EOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=15

NAME="xray-tproxy"
CONF="xray"
PROG="/usr/bin/xray"
NFT_TABLE="xray_tproxy"
NFT_FILE="/etc/xray/tproxy.nft"

start_service() {
   config_load "$CONF"

   local enabled
   config_get_bool enabled "enabled" "enabled" "0"
   [ "$enabled" -eq "1" ] || return 1

   # --- Получаем параметры конфигурации ---
   local confdir conffiles datadir dialer format

   config_get confdir "config" "confdir"
   config_get conffiles "config" "conffiles"
   config_get datadir "config" "datadir" "/usr/share/xray"
   config_get dialer "config" "dialer"
   config_get format "config" "format" "json"

   # --- 1. Проверка наличия конфигурации ---
   if [ -n "$confdir" ]; then
       if [ ! -d "$confdir" ]; then
           echo "Xray confdir does not exist: $confdir" >&2
           stop_service
           return 1
       fi
   elif [ -n "$conffiles" ]; then
       for i in $conffiles; do
           if [ ! -f "$i" ]; then
               echo "Xray config file does not exist: $i" >&2
               stop_service
               return 1
           fi
       done
   else
       echo "No Xray confdir or conffiles configured" >&2
       stop_service
       return 1
   fi

   # --- 2. Проверка синтаксиса конфигурации Xray ---
   local check_args=""

   if [ -n "$confdir" ]; then
       check_args="-confdir $confdir"
   else
       for i in $conffiles; do
           check_args="$check_args -config $i"
       done
   fi

   [ -n "$format" ] && check_args="$check_args -format $format"

   if ! "$PROG" run $check_args -test; then
       echo "Xray configuration test failed. Disabling TPROXY." >&2
       stop_service
       return 1
   fi

   # --- 3. Modules & logs ---
   modprobe nf_tproxy_ipv4 || return 1
   modprobe nft_tproxy || return 1

   mkdir -p /var/log/xray
   touch /var/log/xray/access.log /var/log/xray/error.log

   # --- 4. Policy routing ---
   ip route replace local 0.0.0.0/0 dev lo table 100

   if ! ip rule show | grep -q "fwmark 0x100/0x100 lookup 100"; then
       ip rule add pref 100 fwmark 0x100/0x100 lookup 100
   fi

   # --- 5. nftables rules ---
   nft delete table ip "$NFT_TABLE" 2>/dev/null
   nft -f "$NFT_FILE" || {
       echo "Failed to load $NFT_FILE" >&2
       stop_service
       return 1
   }

   # --- 6. Start Xray ---
   procd_open_instance "$NAME"
   procd_set_param command "$PROG" run

   [ -n "$confdir" ] && procd_append_param command -confdir "$confdir"

   if [ -n "$conffiles" ]; then
       for i in $conffiles; do
           procd_append_param command -config "$i"
       done
   fi

   [ -n "$format" ] && procd_append_param command -format "$format"
   [ -n "$dialer" ] && procd_set_param env XRAY_BROWSER_DIALER="$dialer"
   procd_set_param env XRAY_LOCATION_ASSET="$datadir"

   [ -n "$conffiles" ] && procd_set_param file $conffiles

   procd_set_param limits core="unlimited"
   procd_set_param limits nofile="1000000 1000000"
   procd_set_param stdout 1
   procd_set_param stderr 1
   procd_set_param respawn

   procd_close_instance
}

stop_service() {
   # 1. Убираем nft-правила
   nft delete table ip "$NFT_TABLE" 2>/dev/null

   # 2. Чистим policy routing
   ip rule del fwmark 0x100/0x100 lookup 100 2>/dev/null
}

reload_service() {
   stop
   start
}

service_triggers() {
   procd_add_reload_trigger "$CONF"
}
EOF
chmod +x /etc/init.d/xray-tproxy
print_success "Init-скрипт создан: /etc/init.d/xray-tproxy."

# -------------------- /etc/xray/tproxy.nft --------------------

if [ "$proxy_ipv4_set" -eq 1 ]; then
    nft_proxy_suffix=",
           ${proxy_ipv4}/32"
else
    nft_proxy_suffix=""
fi

nft_file_content() {
    cat <<EOF
table ip xray_tproxy {
   chain prerouting {
       type filter hook prerouting priority mangle + 10; policy accept;

       # Exclude private and reserved destinations
       ip daddr {
           0.0.0.0/8,
           10.0.0.0/8,
           100.64.0.0/10,
           127.0.0.0/8,
           169.254.0.0/16,
           172.16.0.0/12,
           192.0.0.0/24,
           192.168.0.0/16,
           198.18.0.0/15,
           224.0.0.0/4,
           240.0.0.0/4,
           255.255.255.255${nft_proxy_suffix}
       } return

       # Router-originated packets (already marked)
       meta mark & 0x00000100 == 0x00000100 meta l4proto tcp tproxy ip to :12345 accept

       meta mark & 0x00000100 == 0x00000100 meta l4proto udp tproxy ip to :12345 accept

       # LAN devices
       iifname "br-lan" ip saddr 192.168.1.0/24 meta l4proto tcp tproxy ip to :12345 meta mark set meta mark | 0x100 accept

       iifname "br-lan" ip saddr 192.168.1.0/24 meta l4proto udp tproxy ip to :12345 meta mark set meta mark | 0x100 accept
   }

   chain output {
       type route hook output priority mangle; policy accept;

       # Do not proxy private and reserved destinations
       ip daddr {
           0.0.0.0/8,
           10.0.0.0/8,
           100.64.0.0/10,
           127.0.0.0/8,
           169.254.0.0/16,
           172.16.0.0/12,
           192.0.0.0/24,
           192.168.0.0/16,
           198.18.0.0/15,
           224.0.0.0/4,
           240.0.0.0/4,
           255.255.255.255${nft_proxy_suffix}
       } return

       # Xray outbound sockets: mark 255
       meta mark 0x000000ff return

       # Preserve NFQWS2-marked packets
       meta mark & 0x40000000 != 0 return

       # Do not mark packets already marked for TProxy
       meta mark & 0x00000100 != 0 return

       # Mark router-originated TCP and UDP
       meta l4proto tcp meta mark set meta mark | 0x00000100
       meta l4proto udp meta mark set meta mark | 0x00000100
   }
}
EOF
}

nft_file_content > /etc/xray/tproxy.nft
print_success "Правила nftables записаны в /etc/xray/tproxy.nft."

# -------------------- /etc/config/xray --------------------

printf "\n  Использовать папку с конфигурациями Xray (по умолчанию: Y) или один файл с конфигурацией? [Y/n]: "
read -r xray_conf_choice
[ -z "$xray_conf_choice" ] && xray_conf_choice="y"

case "$xray_conf_choice" in
    n|N)
        cat > /etc/config/xray <<'EOF'
config xray 'enabled'
	option enabled '1'

config xray 'config'
#    option confdir '/etc/xray/confs'
	option conffiles '/etc/xray/config.json'
	option datadir '/usr/share/xray'
	option dialer ''
	option format 'json'
EOF
        print_success "Конфигурация Xray записана в /etc/config/xray (один файл: /etc/xray/config.json)."
        ;;
    *)
        cat > /etc/config/xray <<'EOF'
config xray 'enabled'
	option enabled '1'

config xray 'config'
	option confdir '/etc/xray/confs'
#    list conffiles '/etc/xray/config.json'
	option datadir '/usr/share/xray'
	option dialer ''
	option format 'json'
EOF
        print_success "Конфигурация Xray записана в /etc/config/xray (папка: /etc/xray/confs)."
        ;;
esac

# -------------------- Скачивание geo-файлов и задача cron автообновления --------------------

if [ "$offline" -eq 1 ]; then
    print_warning "Пропущена загрузка geo-файлов (оффлайн-режим)."
    print_warning "Автообновление geo-файлов по cron не настроено."
else
    update_geodat_files /usr/share/xray || print_warning "Некоторые geo-файлы не удалось скачать."
    setup_cron_geodat "$install_script_path"
fi

# -------------------- Ядерные модули --------------------

printf "\n  Устанавливаем ядерные модули для TPROXY...\n"

if [ "$pkg_manager" = "apk" ]; then
    apk add kmod-nf-tproxy kmod-nft-tproxy || print_warning "Не удалось установить кемоды через apk."
fi

modprobe nf_tproxy_ipv4 2>/dev/null || print_warning "modprobe nf_tproxy_ipv4 не выполнен (модуль может быть уже загружен или отсутствовать)."
modprobe nft_tproxy 2>/dev/null || print_warning "modprobe nft_tproxy не выполнен (модуль может быть уже загружен или отсутствовать)."

print_success "Ядерные модули обработаны."

# -------------------- Конфигурационные файлы Xray в /etc/xray/confs --------------------

cat > /etc/xray/confs/01_log.json <<'EOF'
{
 "log": {
   "access": "/var/log/xray/access.log",
   "error": "/var/log/xray/error.log",
   "dnsLog": false,
   "loglevel": "none"
 }
}
EOF

cat > /etc/xray/confs/02_dns.json <<'EOF'
{
 "dns": {
   "servers": [
     "127.0.0.53"
   ]
 }
}
EOF

cat > /etc/xray/confs/03_inbounds.json <<'EOF'
{
 "inbounds": [
   {
     "tag": "tproxy-in",
     "port": 12345,
     "protocol": "dokodemo-door",
     "settings": {
       "network": "tcp,udp",
       "followRedirect": true
     },
     "streamSettings": {
       "sockopt": {
         "tproxy": "tproxy"
       }
     },
     "sniffing": {
       "enabled": true,
       "routeOnly": true,
       "destOverride": [
         "http",
         "tls"
       ]
     }
   }
 ]
}
EOF

cat > /etc/xray/confs/04_outbounds.json <<'EOF'
{
   "outbounds": [
     {
       "protocol": "vless",
       "tag": "proxy",
       "streamSettings": {
         "network": "xhttp",
         "realitySettings": {
           "fingerprint": "firefox",
           "mldsa65Verify": "",
           "publicKey": "YOUR_PBK",
           "serverName": "YOUR_SNI",
           "shortId": "YOUR_SID",
           "show": false,
           "spiderX": "/YOUR_SPX"
         },
         "security": "reality",
         "xhttpSettings": {
           "host": "YOUR_HOST",
           "mode": "auto",
           "path": "/",
           "xPaddingBytes": "100-1000"
         },
         "sockopt": {
           "mark": 255
         }
       },
       "settings": {
         "address": "YOUR_HOST_IP",
         "encryption": "none",
         "id": "YOUR_UUID",
         "level": 8,
         "port": 443
       }
     },
     {
       "protocol": "freedom",
       "streamSettings": {
         "sockopt": {
           "mark": 255
         }
       },
       "settings": {
         "domainStrategy": "AsIs",
         "noises": [],
         "redirect": ""
       },
       "tag": "direct"
     },
     {
       "protocol": "blackhole",
       "settings": {
         "response": {
           "type": "http"
         }
       },
       "tag": "block"
     }
   ]
}
EOF

cat > /etc/xray/confs/05_routing.json <<'EOF'
{
 "routing": {
   "rules": [
//  Proccess name routing (dnscrypt -> direct)
     {
       "type": "field",
       "process": ["dnscrypt-proxy"],
       "outboundTag": "direct"
     },
//  Block (ads and analytics)
     {
       "type": "field",
       "inboundTag": ["tproxy-in"],
       "outboundTag": "block",
       "domain": [
         "appcenter.ms",
         "ext:geosite_v2fly.dat:category-ads"
       ]
     },

//  Direct connection | Domains (only geosite)
     {
       "type": "field",
       "inboundTag": ["tproxy-in"],
       "outboundTag": "direct",
       "domain": [
         //  GEOSITE RU
         "ext:geosite_v2fly.dat:category-ru",
         "ext:geosite_v2fly.dat:category-ip-geo-detect",
//         "ext:geosite_v2fly.dat:private",

         //  YouTube
         "ext:geosite_zkeen.dat:youtube"
       ]
     },

// Direct connection | IPs (only geoip)
     {
       "type": "field",
       "inboundTag": ["tproxy-in"],
       "outboundTag": "direct",
       "ip": [
         // GEOIP RU
//         "ext:geoip_v2fly.dat:private",
         "ext:geoip_v2fly.dat:RU",
         "ext:geoip_zkeenip.dat:RU",
//         YouTube IP
         "ext:geoip_zkeenip.dat:youtube"
       ]
     },

//  Direct connection | Torrent
     {
       "type": "field",
       "inboundTag": ["tproxy-in"],
       "outboundTag": "direct",
       "protocol": ["bittorrent"]
     },

//  VPS connection (everything else)
     {
       "type": "field",
       "inboundTag": ["tproxy-in"],
       "outboundTag": "proxy"
     }
   ]
 }
}
EOF

cat > /etc/xray/confs/06_policy.json <<'EOF'
{
 "policy": {
   "levels": {
     "0": {
       "uplinkOnly": 0,
       "downlinkOnly": 0
     }
   }
 }
}
EOF

print_success "Конфигурационные файлы Xray созданы в /etc/xray/confs."

# -------------------- Проверка init-скрипта --------------------

printf "\n  Проверяем запуск init-скрипта /etc/init.d/xray-tproxy...\n"

if [ -x /usr/bin/xray ]; then
    /etc/init.d/xray-tproxy start >/dev/null 2>&1 && {
        print_success "Init-скрипт xray-tproxy запущен."
        /etc/init.d/xray-tproxy stop >/dev/null 2>&1
        print_success "Init-скрипт остановлен."
    } || {
        print_warning "Init-скрипт не запустился. Проверьте конфигурацию Xray."
    }
else
    print_warning "Xray не установлен, проверка запуска init-скрипта пропущена."
fi

# -------------------- Завершение --------------------

printf "\n"
printf "  ${green}Установка xray-tproxy завершена.${reset}\n\n"

printf "  Xray:        /usr/bin/xray\n"
printf "  Конфиг:      /etc/config/xray\n"
printf "  ConfDir:     /etc/xray/confs\n"
printf "  Geo-файлы:   /usr/share/xray\n"
printf "  nft rules:   /etc/xray/tproxy.nft\n"
printf "  Init-скрипт: /etc/init.d/xray-tproxy\n"
printf "  Логи:        /var/log/xray\n"
printf "  Автообновление geo-файлов: cron task (ежедневно 04:00) -> /etc/crontabs/root\n"

if [ "$dnscrypt_installed" -eq 1 ]; then
    printf "  dnscrypt:    /etc/dnscrypt-proxy2/dnscrypt-proxy.toml (включён)\n"
fi

printf "\n  Отредактируйте конфигурацию Xray по адресу:\n"
printf "    confdir:  /etc/xray/confs\n"
printf "    или      conffile: /etc/xray/config.json\n"
printf "  Затем запустите: /etc/init.d/xray-tproxy enable && /etc/init.d/xray-tproxy start\n\n"

exit 0

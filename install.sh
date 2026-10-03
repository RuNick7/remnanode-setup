#!/usr/bin/env bash
# remnanode-setup — установка и обслуживание ноды Remnawave на Ubuntu с нуля.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/RuNick7/remnanode-setup/main/install.sh)
#   bash install.sh [install|cert|status|update] [опции]          подробно: bash install.sh --help
#
# install: ждёт освобождения apt, ставит Docker (с запасным путём для новых Ubuntu), настраивает ядро
# (BBR, буферы QUIC/HY2, conntrack, резерв портов сервисов), swap, лимит журналов, синхронизацию
# времени, Cloudflare WARP в режиме proxy, сертификат Let's Encrypt с продлением, которому не мешает
# занятый 80-й порт, и саму ноду (compose из панели + volumes + ротация логов).
set -euo pipefail

VERSION="1.0.0"
NODE_DIR="/opt/remnanode"
COMPOSE="$NODE_DIR/docker-compose.yml"
NODE_NAME="remnanode"
DEFAULT_IMAGE="remnawave/node:latest"
CERT_DIR="/etc/certs/remna"
HOOK_DIR="/usr/local/lib/remnanode-setup"
SYSCTL_FILE="/etc/sysctl.d/60-remnanode.conf"
LOG_FILE="/var/log/remnanode-setup.log"

CMD="install"
DOMAIN=""
EMAIL=""
SECRET_KEY="${SECRET_KEY:-}"
SECRET_KEY_FILE=""
NEW_KEY=0
NODE_PORT=""
NODE_PORT_ARG=""
NODE_IMAGE=""
ENV_EXTRA=()
VOL_EXTRA=()
WARP=1
WARP_PORT=40000
SWAP=1
FIREWALL=0
PANEL_IP=""
INBOUND_PORTS=""
FOLLOW_LOGS=1
DRY_RUN=0
ASSUME_YES=0
ACME_PORT=""
CERT_CHANGED=0
IS_CONTAINER=0
OS_ID="" OS_PRETTY="" OS_CODENAME="" ARCH=""
APT_UPDATED=0
WARNINGS=()

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT=(apt-get -y -q -o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

if [ -t 1 ]; then R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' B=$'\e[36m' N=$'\e[0m'; else R='' G='' Y='' B='' N=''; fi
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; WARNINGS+=("$*"); }
die()  { printf '%sОШИБКА:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
on_exit() { local rc=$?; [ "$rc" = 0 ] || [ "$rc" = 130 ] || printf '%sПрервано (код %s).%s Полный лог: %s\n' "$R" "$rc" "$N" "$LOG_FILE" >&2; }
trap on_exit EXIT

usage() {
  cat <<EOF
remnanode-setup $VERSION — нода Remnawave на Ubuntu с нуля

Команды:
  install   (по умолчанию) полная установка/донастройка; безопасно запускать повторно
  cert      выпустить/починить сертификат для HY2/TLS и его автопродление (нужен --domain)
  status    проверка: нода, инбаунды, WARP, сертификаты, ядро, память, диск (ничего не меняет)
  update    обновить образ ноды и перезапустить её

Опции:
  --domain fl6.example.com   домен ноды для сертификата Let's Encrypt (HY2 и другие TLS-инбаунды)
  --email you@example.com    почта для Let's Encrypt (необязательно)
  --secret-key-file FILE     файл с SECRET_KEY или docker-compose.yml из панели (иначе спросит)
  --new-key                  не брать ключ из существующего $COMPOSE, спросить новый
  --node-port 2222           порт, по которому панель подключается к ноде (по умолчанию из панели или 2222)
  --inbound-ports LIST       порты инбаундов, например "443/tcp,9997/udp,9998/tcp" (резерв, firewall)
  --no-warp                  не ставить Cloudflare WARP (нужен, если в профиле есть outbound на socks :$WARP_PORT)
  --warp-port 40000          порт локального SOCKS-прокси WARP
  --no-swap                  не создавать swap
  --firewall                 включить ufw: SSH, 80, 443, инбаунды; порт ноды — только для --panel-ip
  --panel-ip 1.2.3.4         IP панели Remnawave (для --firewall)
  --no-logs                  не открывать логи ноды в конце установки
  --dry-run                  показать, что будет сделано, ничего не меняя
  -y, --yes                  ничего не спрашивать (ключ тогда через SECRET_KEY=... или --secret-key-file)

Примеры:
  bash install.sh                                       # спросит ключ и домен
  bash install.sh --domain de15.example.com --panel-ip 1.2.3.4 --firewall
  SECRET_KEY='eyJ...' bash install.sh -y --domain de15.example.com
  bash install.sh cert --domain fl1.example.com         # починить сертификат существующей ноды
EOF
}

# ---------- общие помощники ----------
run() { if [ "$DRY_RUN" = 1 ]; then printf '   %s[dry-run]%s %s\n' "$Y" "$N" "$*"; else "$@"; fi; }

write_file() {  # write_file PATH MODE < содержимое (в --dry-run только показывает, длинные ключи скрыты)
  local path=$1 mode=${2:-644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [ "$DRY_RUN" = 1 ]; then
    printf '   %s[dry-run]%s записать %s (права %s):\n' "$Y" "$N" "$path" "$mode"
    sed -E 's/[A-Za-z0-9+\/=_-]{60,}/<скрыто>/g; s/^/      | /' "$tmp"
    rm -f "$tmp"; return 0
  fi
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
}

have_tty() { [ "$ASSUME_YES" = 0 ] && { : </dev/tty; } 2>/dev/null; }

ask() {  # ask "вопрос" ИМЯ_ПЕРЕМЕННОЙ [значение по умолчанию]
  local q=$1 var=$2 def=${3:-} ans=""
  if have_tty; then printf '%s ' "$q" >/dev/tty; IFS= read -r ans </dev/tty || true; fi
  printf -v "$var" '%s' "${ans:-$def}"
}

port_busy() { local f=-t; [ "$1" = udp ] && f=-u; [ -n "$(ss -Hln "$f" "sport = :$2" 2>/dev/null)" ]; }
port_owner() {  # имена процессов, слушающих порт (пусто, если свободен)
  local f=-t; [ "$1" = udp ] && f=-u
  ss -Hlnp "$f" "sport = :$2" 2>/dev/null | grep -oP 'users:\(\("\K[^"]+' | sort -u | paste -sd, - || true
}

public_ip4() { curl -4 -fsS -m 8 https://api.ipify.org 2>/dev/null || curl -4 -fsS -m 8 https://ifconfig.me 2>/dev/null || true; }

start_log() {
  touch "$LOG_FILE" 2>/dev/null || return 0
  printf '\n===== %s remnanode-setup %s: %s =====\n' "$(date '+%F %T')" "$VERSION" "$CMD" >>"$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

# ---------- система ----------
detect_os() {
  [ -r /etc/os-release ] || die "нет /etc/os-release — неизвестная система"
  OS_ID=$(. /etc/os-release && echo "${ID:-}")
  OS_PRETTY=$(. /etc/os-release && echo "${PRETTY_NAME:-${ID:-?}}")
  OS_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")
  ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
  local virt; virt=$(systemd-detect-virt 2>/dev/null || true)
  case "$OS_ID" in
    ubuntu) ;;
    debian) warn "$OS_PRETTY: скрипт написан под Ubuntu; на Debian должен работать, но не проверялся" ;;
    *) die "нужна Ubuntu, а здесь $OS_PRETTY" ;;
  esac
  case "$virt" in lxc|lxc-libvirt|openvz) IS_CONTAINER=1; warn "сервер — контейнер ($virt): часть настроек ядра и swap недоступны" ;; esac
  info "Система: $OS_PRETTY, $ARCH, ядро $(uname -r)${virt:+, виртуализация $virt}"
}

wait_dpkg() {  # на свежем VPS apt часто занят unattended-upgrades
  command -v fuser >/dev/null || return 0
  local i=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    [ "$i" = 0 ] && info "apt занят другим процессом (на свежем сервере обычно unattended-upgrades) — жду…"
    i=$((i + 1))
    [ "$i" -gt 180 ] && die "apt занят дольше 15 минут: $(ps -eo pid,cmd | grep -E '[a]pt|[d]pkg|[u]nattended' | head -3 | tr '\n' ';')"
    sleep 5
  done
  return 0
}

apt_update() {
  [ "$APT_UPDATED" = 1 ] && return 0
  if [ "$DRY_RUN" = 1 ]; then printf '   %s[dry-run]%s apt-get update\n' "$Y" "$N"; APT_UPDATED=1; return 0; fi
  wait_dpkg
  dpkg --configure -a >/dev/null 2>&1 || true   # «dpkg was interrupted…» после оборванной установки
  local n
  for n in 1 2 3; do
    if "${APT[@]}" update >/dev/null; then APT_UPDATED=1; return 0; fi
    warn "apt-get update: попытка $n не удалась"; sleep 5
  done
  die "apt-get update не работает — проверьте сеть и источники в /etc/apt/"
}

apt_install() {  # ставит только недостающие пакеты
  local missing=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  apt_update
  if [ "$DRY_RUN" = 1 ]; then printf '   %s[dry-run]%s apt-get install %s\n' "$Y" "$N" "${missing[*]}"; return 0; fi
  info "Ставлю пакеты: ${missing[*]}"
  wait_dpkg
  "${APT[@]}" install "${missing[@]}" >/dev/null || die "не удалось установить: ${missing[*]}"
}

preflight_ports() {
  info "Порты сейчас"
  local spec proto port who
  for spec in tcp/80 tcp/443 "tcp/${NODE_PORT_ARG:-2222}" "tcp/$WARP_PORT"; do
    proto=${spec%/*}; port=${spec#*/}
    if port_busy "$proto" "$port"; then who=$(port_owner "$proto" "$port"); printf '    %-10s занят: %s\n' "$port/$proto" "${who:-?}"
    else printf '    %-10s свободен\n' "$port/$proto"; fi
  done
  if port_busy tcp 443; then
    who=$(port_owner tcp 443)
    case "$who" in *rw-core*|*xray*) ;; *) warn "443/tcp занят ($who): инбаунды Xray на 443 не запустятся — в профиле нужны другие порты (или проксирование через этот $who по SNI)" ;; esac
  fi
  if port_busy tcp 80; then info "80/tcp занят ($(port_owner tcp 80)) — это не помешает: сертификат продлевается через временное перенаправление"; fi
}

# ---------- ядро, swap, журналы, время ----------
inbound_ports_from_node() {  # порты инбаундов из работающего Xray ноды (если панель уже отдала конфиг)
  local cfg; cfg=$(node_xray_config) || return 0
  jq -r '.inbounds[]? | select(.port != null) | .port | tostring' <<<"$cfg" 2>/dev/null | grep -E '^[0-9]+(-[0-9]+)?$' || true
}

reserved_ports() {  # порты сервисов, которые ядро не должно отдавать под исходящие соединения
  local list=() p saved
  list+=("${NODE_PORT:-${NODE_PORT_ARG:-2222}}")
  [ "$WARP" = 1 ] && list+=("$WARP_PORT")
  [ -n "$ACME_PORT" ] && list+=("$ACME_PORT")
  for p in ${INBOUND_PORTS//,/ }; do list+=("${p%%/*}"); done
  for p in $(inbound_ports_from_node); do list+=("$p"); done
  if [ -f "$SYSCTL_FILE" ]; then  # не терять порты, сохранённые прошлыми запусками
    saved=$(sed -nE 's/^net\.ipv4\.ip_local_reserved_ports *= *//p' "$SYSCTL_FILE")
    for p in ${saved//,/ }; do list+=("$p"); done
  fi
  printf '%s\n' "${list[@]}" | grep -E '^[0-9]+(-[0-9]+)?$' | sort -n -u | paste -sd, -
}

write_sysctl() {
  local reserved; reserved=$(reserved_ports)
  write_file "$SYSCTL_FILE" 644 <<EOF
# remnanode-setup: сеть VPN-ноды. Применяется до /etc/sysctl.conf, так что значения оттуда главнее.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# Hysteria2/QUIC: quic-go просит UDP-буфер ~7 МБ, по умолчанию ядро даёт 208 КБ
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
# Порты сервисов не раздаются под исходящие соединения, иначе после перезапуска «address already in use»
net.ipv4.ip_local_reserved_ports = $reserved
# conntrack: мобильные клиенты пропадают без FIN, а по умолчанию запись живёт 5 суток
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
vm.swappiness = 10
EOF
}

apply_sysctl() {
  [ "$DRY_RUN" = 1 ] && return 0
  local out cc qd
  if ! out=$(sysctl -e -p "$SYSCTL_FILE" 2>&1); then
    warn "не все sysctl применились: $(grep -iE 'error|denied|invalid|cannot' <<<"$out" | head -3 | tr '\n' ' ')"
  fi
  sysctl --system >/dev/null 2>&1 || true   # как при загрузке: /etc/sysctl.conf перекрывает наш файл
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')
  if [ "$cc" = bbr ]; then ok "BBR включён (qdisc $qd)"; else warn "congestion control = $cc, а не bbr: его перекрывает /etc/sysctl.conf или файл в /etc/sysctl.d"; fi
  ok "резерв портов: $(sysctl -n net.ipv4.ip_local_reserved_ports 2>/dev/null)"
}

tune_kernel() {
  info "Ядро: BBR, буферы UDP для Hysteria2/QUIC, conntrack, резерв портов сервисов"
  if [ "$IS_CONTAINER" = 1 ]; then warn "контейнерная виртуализация — настройки ядра пропущены"; return 0; fi
  write_sysctl
  printf 'tcp_bbr\nnf_conntrack\n' | write_file /etc/modules-load.d/remnanode.conf 644
  printf 'options nf_conntrack hashsize=65536\n' | write_file /etc/modprobe.d/remnanode-conntrack.conf 644
  [ "$DRY_RUN" = 1 ] && return 0
  modprobe tcp_bbr 2>/dev/null || warn "модуль tcp_bbr не загрузился — в этом ядре нет BBR"
  modprobe nf_conntrack 2>/dev/null || true
  if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then echo 65536 >/sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true; fi
  apply_sysctl
}

setup_swap() {
  [ "$SWAP" = 1 ] || return 0
  info "Swap"
  if [ "$IS_CONTAINER" = 1 ]; then warn "в контейнере swap не настроить — пропускаю"; return 0; fi
  if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then ok "уже есть: $(swapon --show --noheadings | awk '{print $1" "$3}' | paste -sd' ' -)"; return 0; fi
  local mem_mb free_mb fstype
  mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if [ "$mem_mb" -ge 8000 ]; then ok "RAM ${mem_mb} МБ — swap не нужен"; return 0; fi
  free_mb=$(df -Pm / | awk 'NR==2{print $4}')
  if [ "$free_mb" -lt 4096 ]; then warn "на диске свободно ${free_mb} МБ — swap не создаю"; return 0; fi
  fstype=$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)
  info "Создаю /swapfile 2 ГБ: RAM ${mem_mb} МБ, без swap ядро при нехватке памяти убивает процессы"
  [ "$DRY_RUN" = 1 ] && { printf '   %s[dry-run]%s fallocate/mkswap/swapon /swapfile, строка в /etc/fstab\n' "$Y" "$N"; return 0; }
  if [ ! -f /swapfile ]; then
    case "$fstype" in
      btrfs) btrfs filesystem mkswapfile --size 2g /swapfile >/dev/null 2>&1 || { warn "не удалось создать swap на btrfs"; return 0; } ;;
      ext4|ext3|xfs) fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none ;;
      *) dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none ;;
    esac
    chmod 600 /swapfile
    [ "$fstype" = btrfs ] || mkswap /swapfile >/dev/null
  fi
  if swapon /swapfile 2>/dev/null; then
    grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    ok "swap 2 ГБ включён"
  else
    warn "swapon не сработал (файловая система $fstype?) — swap не включён"
  fi
}

setup_journald() {
  info "Журналы: systemd-journald не больше 300 МБ (по умолчанию может разрастись на гигабайты)"
  printf '[Journal]\nSystemMaxUse=300M\n' | write_file /etc/systemd/journald.conf.d/60-remnanode.conf 644
  run systemctl restart systemd-journald || true
}

setup_time() {
  if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" = yes ]; then ok "время синхронизировано"; return 0; fi
  info "Включаю синхронизацию времени"
  if ! systemctl is-active --quiet chrony 2>/dev/null && ! systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
    apt_install systemd-timesyncd
  fi
  run timedatectl set-ntp true || warn "не удалось включить NTP"
}

# ---------- Docker ----------
install_docker() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), compose $(docker compose version --short 2>/dev/null || echo '?')"
    run systemctl enable --now docker >/dev/null 2>&1 || true
    return 0
  fi
  info "Ставлю Docker"
  if [ "$DRY_RUN" = 1 ]; then printf '   %s[dry-run]%s curl -fsSL https://get.docker.com | sh  (запасной путь: docker.io + docker-compose-v2 из Ubuntu)\n' "$Y" "$N"; return 0; fi
  wait_dpkg
  local gd; gd=$(mktemp)
  if curl -fsSL --retry 3 https://get.docker.com -o "$gd" && sh "$gd" >/dev/null; then
    ok "Docker установлен через get.docker.com"
  else
    warn "get.docker.com не справился (так бывает на только что вышедших версиях Ubuntu) — ставлю docker.io из репозитория Ubuntu"
    apt_update
    "${APT[@]}" install docker.io >/dev/null || die "не удалось установить docker.io"
    "${APT[@]}" install docker-compose-v2 >/dev/null 2>&1 || "${APT[@]}" install docker-compose-plugin >/dev/null 2>&1 || die "не удалось установить docker compose"
  fi
  rm -f "$gd"
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || die "docker compose не работает"
  ok "Docker $(docker version --format '{{.Server.Version}}'), compose $(docker compose version --short)"
}

# ---------- Cloudflare WARP ----------
warp_codename() {  # для новых/промежуточных Ubuntu у Cloudflare может не быть репозитория — берём ближайший LTS
  local c
  for c in "$OS_CODENAME" noble jammy focal bookworm; do
    [ -n "$c" ] || continue
    curl -fsSI -m 10 "https://pkg.cloudflareclient.com/dists/$c/Release" >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  return 1
}

warp_ok() { curl -fsS -m 6 -x "socks5h://127.0.0.1:$WARP_PORT" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q '^warp=on'; }

setup_warp() {
  [ "$WARP" = 1 ] || { info "WARP пропущен (--no-warp)"; return 0; }
  info "Cloudflare WARP (SOCKS-прокси 127.0.0.1:$WARP_PORT для outbound «warp» в профиле)"
  case "$ARCH" in amd64|arm64) ;; *) warn "WARP нет под $ARCH — пропускаю"; return 0 ;; esac
  local who; who=$(port_owner tcp "$WARP_PORT")
  if [ -n "$who" ] && [ "$who" != warp-svc ]; then warn "порт $WARP_PORT занят ($who) — WARP не настроен; задайте --warp-port и поменяйте порт outbound warp в профиле"; return 0; fi
  if warp_ok; then ok "WARP уже работает (warp=on)"; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then printf '   %s[dry-run]%s установить cloudflare-warp, режим proxy на %s, connect\n' "$Y" "$N" "$WARP_PORT"; return 0; fi
  if ! command -v warp-cli >/dev/null; then
    local cn; cn=$(warp_codename) || { warn "репозиторий Cloudflare WARP недоступен — пропускаю"; return 0; }
    [ "$cn" = "$OS_CODENAME" ] || warn "у Cloudflare нет пакета под $OS_CODENAME — беру репозиторий $cn"
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $cn main" >/etc/apt/sources.list.d/cloudflare-client.list
    APT_UPDATED=0; apt_update
    wait_dpkg
    "${APT[@]}" install cloudflare-warp >/dev/null || { warn "не удалось установить cloudflare-warp"; return 0; }
  fi
  systemctl enable --now warp-svc >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 20); do warp-cli --accept-tos status >/dev/null 2>&1 && break; sleep 1; done
  warp-cli --accept-tos registration show >/dev/null 2>&1 || warp-cli --accept-tos registration new >/dev/null || { warn "WARP: регистрация не удалась"; return 0; }
  # Сначала режим proxy, потом connect: в обычном режиме WARP заберёт весь трафик сервера, включая SSH
  warp-cli --accept-tos mode proxy >/dev/null
  warp-cli --accept-tos proxy port "$WARP_PORT" >/dev/null
  warp-cli --accept-tos connect >/dev/null
  for i in $(seq 1 30); do warp_ok && { ok "WARP работает: socks5 127.0.0.1:$WARP_PORT (warp=on)"; return 0; }; sleep 2; done
  warn "WARP не поднялся — проверьте: warp-cli --accept-tos status"
}

# ---------- сертификат ----------
check_dns() {
  local d=$1 ip4 dns4 dns6
  ip4=$(public_ip4)
  dns4=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}')
  if [ -z "$dns4" ]; then warn "$d не резолвится — нужна A-запись на ${ip4:-IP этого сервера}"; return 1; fi
  if [ -n "$ip4" ] && [ "$dns4" != "$ip4" ]; then warn "$d указывает на $dns4, а у сервера $ip4 — Let's Encrypt будет проверять другой сервер"; return 1; fi
  dns6=$(getent ahostsv6 "$d" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1; exit}')
  ok "DNS: $d → $dns4${dns6:+, $dns6}"
  return 0
}

pick_acme_port() {  # свой порт для certbot: 80-й не трогаем вообще
  local conf="/etc/letsencrypt/renewal/$DOMAIN.conf" p
  p=$(sed -nE 's/^http01_port *= *([0-9]+).*/\1/p' "$conf" 2>/dev/null | head -1)
  if [ -n "$p" ] && [ "$p" != 80 ] && ! port_busy tcp "$p"; then echo "$p"; return 0; fi
  for p in 8089 18089 28089 38089 48089; do port_busy tcp "$p" || { echo "$p"; return 0; }; done
  die "не нашёл свободный порт для certbot (8089, 18089, …)"
}

write_acme_hooks() {
  write_file "$HOOK_DIR/acme-pre.sh" 755 <<EOF
#!/bin/sh
# remnanode-setup: на время проверки Let's Encrypt входящий :80 этого сервера уходит в certbot (:$ACME_PORT).
# Поэтому неважно, кто держит 80-й порт (nginx, apache, HestiaCP, docker) — его не нужно ни освобождать, ни останавливать.
for ipt in iptables ip6tables; do
  command -v \$ipt >/dev/null 2>&1 || continue
  \$ipt -t nat -C PREROUTING -p tcp --dport 80 -m addrtype --dst-type LOCAL -m comment --comment remnanode-acme -j REDIRECT --to-ports $ACME_PORT 2>/dev/null ||
    \$ipt -t nat -I PREROUTING -p tcp --dport 80 -m addrtype --dst-type LOCAL -m comment --comment remnanode-acme -j REDIRECT --to-ports $ACME_PORT 2>/dev/null || true
  \$ipt -C INPUT -p tcp --dport $ACME_PORT -m conntrack --ctstate DNAT -m comment --comment remnanode-acme -j ACCEPT 2>/dev/null ||
    \$ipt -I INPUT -p tcp --dport $ACME_PORT -m conntrack --ctstate DNAT -m comment --comment remnanode-acme -j ACCEPT 2>/dev/null || true
done
exit 0
EOF
  write_file "$HOOK_DIR/acme-post.sh" 755 <<EOF
#!/bin/sh
# remnanode-setup: убрать временное перенаправление :80 (выполняется и при неудачной проверке)
for ipt in iptables ip6tables; do
  command -v \$ipt >/dev/null 2>&1 || continue
  while \$ipt -t nat -D PREROUTING -p tcp --dport 80 -m addrtype --dst-type LOCAL -m comment --comment remnanode-acme -j REDIRECT --to-ports $ACME_PORT 2>/dev/null; do :; done
  while \$ipt -D INPUT -p tcp --dport $ACME_PORT -m conntrack --ctstate DNAT -m comment --comment remnanode-acme -j ACCEPT 2>/dev/null; do :; done
done
exit 0
EOF
  write_file "$HOOK_DIR/acme-deploy-$DOMAIN.sh" 755 <<EOF
#!/bin/sh
# remnanode-setup: после выпуска/продления кладёт сертификат туда, откуда его читает нода, и перезапускает её
L="\${RENEWED_LINEAGE:-/etc/letsencrypt/live/$DOMAIN}"
[ "\$L" = "/etc/letsencrypt/live/$DOMAIN" ] || exit 0
install -d -m 755 "$CERT_DIR"
install -m 644 "\$L/fullchain.pem" "$CERT_DIR/fullchain.pem"
install -m 600 "\$L/privkey.pem" "$CERT_DIR/privkey.pem"
[ "\${REMNANODE_SETUP_NO_RESTART:-0}" = 1 ] && exit 0   # во время install нода пересоздаётся один раз в конце
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NODE_NAME"; then docker restart "$NODE_NAME" >/dev/null; fi
exit 0
EOF
}

check_old_hooks() {
  local f
  for f in /etc/letsencrypt/renewal-hooks/deploy/*; do
    [ -f "$f" ] || continue
    if grep -qE "$CERT_DIR|restart +$NODE_NAME" "$f"; then
      warn "старый хук $f тоже копирует сертификат/перезапускает ноду — удалите его, иначе нода будет перезапускаться дважды"
    fi
  done
}

sync_node_cert() {  # нода читает копию; если certbot продлил, а копия старая — обновить
  [ "$DRY_RUN" = 1 ] && return 0
  local live="/etc/letsencrypt/live/$DOMAIN"
  [ -f "$live/fullchain.pem" ] || { warn "нет $live/fullchain.pem"; return 0; }
  if ! cmp -s "$live/fullchain.pem" "$CERT_DIR/fullchain.pem"; then
    info "Копия у ноды отличается от сертификата certbot — обновляю $CERT_DIR"
    RENEWED_LINEAGE="$live" "$HOOK_DIR/acme-deploy-$DOMAIN.sh"
  fi
  ok "сертификат ноды действует до $(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -enddate | cut -d= -f2)"
}

verify_renewal() {
  [ "$DRY_RUN" = 1 ] && return 0
  info "Проверяю будущее автопродление (certbot renew --dry-run на тестовом сервере Let's Encrypt)"
  local log=/var/log/remnanode-renew-test.log
  if certbot renew --cert-name "$DOMAIN" --dry-run --no-random-sleep-on-renew --non-interactive >"$log" 2>&1; then
    ok "автопродление работает"
  else
    warn "пробное продление не прошло: $(grep -iE 'error|problem|detail' "$log" | tail -2 | tr '\n' ' ') (полностью: $log)"
  fi
}

ensure_renew_timer() {
  [ "$DRY_RUN" = 1 ] && return 0
  if systemctl enable --now certbot.timer >/dev/null 2>&1; then ok "certbot.timer включён (проверяет сертификаты дважды в день)"; return 0; fi
  if systemctl enable --now snap.certbot.renew.timer >/dev/null 2>&1; then ok "snap.certbot.renew.timer включён"; return 0; fi
  echo '17 3,15 * * * root certbot -q renew --no-random-sleep-on-renew' | write_file /etc/cron.d/remnanode-certbot 644
  ok "certbot.timer нет — добавил /etc/cron.d/remnanode-certbot"
}

setup_cert() {
  if [ -z "$DOMAIN" ]; then
    info "Домен не задан — сертификат пропускаю (нужен для HY2 и других TLS-инбаундов). Позже: bash install.sh cert --domain node.example.com"
    run install -d -m 755 "$CERT_DIR"
    return 0
  fi
  info "Сертификат Let's Encrypt для $DOMAIN"
  check_dns "$DOMAIN" || { warn "сертификат не выпущен: поправьте DNS и запустите bash install.sh cert --domain $DOMAIN"; return 0; }
  apt_install certbot iptables
  [ -n "$ACME_PORT" ] || ACME_PORT=$(pick_acme_port)
  write_acme_hooks
  check_old_hooks
  local conf="/etc/letsencrypt/renewal/$DOMAIN.conf"
  local args=(certonly --cert-name "$DOMAIN" -d "$DOMAIN" --standalone --http-01-port "$ACME_PORT"
              --pre-hook "$HOOK_DIR/acme-pre.sh" --post-hook "$HOOK_DIR/acme-post.sh"
              --deploy-hook "$HOOK_DIR/acme-deploy-$DOMAIN.sh" --non-interactive --agree-tos)
  if [ -n "$EMAIL" ]; then args+=(-m "$EMAIL"); else args+=(--register-unsafely-without-email); fi
  [ "$CMD" = install ] && export REMNANODE_SETUP_NO_RESTART=1
  if [ ! -f "$conf" ]; then
    info "Выпускаю сертификат: на время проверки входящий :80 перенаправляется на certbot :$ACME_PORT"
    run certbot "${args[@]}" || die "certbot не выпустил сертификат — подробности в /var/log/letsencrypt/letsencrypt.log"
  elif grep -q "$HOOK_DIR/acme-pre.sh" "$conf" && grep -qE "^http01_port *= *$ACME_PORT\b" "$conf"; then
    ok "продление $DOMAIN уже настроено этим скриптом"
    run certbot renew --cert-name "$DOMAIN" --no-random-sleep-on-renew --non-interactive || warn "certbot renew вернул ошибку"
  else
    info "Сертификат $DOMAIN уже есть, но продлевается иначе ($(sed -nE 's/^authenticator *= *//p' "$conf")) — перевыпускаю с устойчивым продлением"
    run certbot "${args[@]}" --force-renewal || die "certbot не перевыпустил сертификат — подробности в /var/log/letsencrypt/letsencrypt.log"
  fi
  local before after
  before=$(md5sum "$CERT_DIR/fullchain.pem" 2>/dev/null || true)
  sync_node_cert
  after=$(md5sum "$CERT_DIR/fullchain.pem" 2>/dev/null || true)
  [ "$before" = "$after" ] || CERT_CHANGED=1
  verify_renewal
  ensure_renew_timer
}

# ---------- нода ----------
parse_compose_text() {  # из compose/ключа панели берём SECRET_KEY, NODE_PORT, image, прочие env и volumes
  local line k v port=""
  ENV_EXTRA=(); VOL_EXTRA=()
  local key_found=""
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*# ]] && continue
    if [[ $line =~ ^[[:space:]]*-[[:space:]]*[\"\']?([A-Z_][A-Z0-9_]*)=(.*)$ ]] || [[ $line =~ ^[[:space:]]+([A-Z_][A-Z0-9_]*):[[:space:]]*(.*)$ ]] \
       || [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*)=(.*)$ && ${BASH_REMATCH[2]} = SECRET_KEY ]]; then
      [ "${BASH_REMATCH[2]:-}" = SECRET_KEY ] && BASH_REMATCH=("" "SECRET_KEY" "${BASH_REMATCH[3]}")
      k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
      v=${v%"${v##*[![:space:]]}"}; v=${v%\"}; v=${v%\'}; v=${v#\"}; v=${v#\'}
      case "$k" in
        SECRET_KEY) key_found=$v ;;
        NODE_PORT|APP_PORT) port=$v ;;
        *) ENV_EXTRA+=("$k=$v") ;;
      esac
    elif [[ $line =~ ^[[:space:]]*image:[[:space:]]*[\"\']?([^\"\'[:space:]]+) ]]; then
      NODE_IMAGE=${BASH_REMATCH[1]}
    elif [[ $line =~ ^[[:space:]]*-[[:space:]]*[\"\']?(/[^:\"\']+:/[^\"\']+)[\"\']?[[:space:]]*$ ]]; then
      [ "${BASH_REMATCH[1]}" = "$CERT_DIR:$CERT_DIR:ro" ] || VOL_EXTRA+=("${BASH_REMATCH[1]}")
    fi
  done <<<"$1"
  if [ -z "$key_found" ]; then  # вставили только сам ключ
    key_found=$(grep -oE '[A-Za-z0-9+/]{200,}={0,2}' <<<"$1" | head -1 || true)
  fi
  [ -n "$key_found" ] || return 1
  SECRET_KEY=$key_found
  [ -z "$NODE_PORT" ] && [ -n "$port" ] && NODE_PORT=$port
  return 0
}

ask_paste() {  # редактор вместо read: строки длиннее 4 КБ терминал при вводе молча обрезает
  local tmp ed
  tmp=$(mktemp --suffix=.yml)
  cat >"$tmp" <<'EOF'
# Вставьте сюда docker-compose.yml, который панель Remnawave показывает при добавлении ноды
# (или только строку SECRET_KEY=...). Сохранить: Ctrl+O, Enter. Выйти: Ctrl+X.
# volumes, logging и остальное скрипт добавит сам.

EOF
  ed=${EDITOR:-nano}
  command -v "$ed" >/dev/null || ed=nano
  command -v "$ed" >/dev/null || apt_install nano
  "$ed" "$tmp" </dev/tty >/dev/tty 2>&1 || true
  cat "$tmp"
  rm -f "$tmp"
}

get_secret_key() {
  local raw="" src=""
  if [ -n "$SECRET_KEY_FILE" ]; then
    [ -r "$SECRET_KEY_FILE" ] || die "не читается $SECRET_KEY_FILE"
    raw=$(cat "$SECRET_KEY_FILE"); src="файл $SECRET_KEY_FILE"
  elif [ -n "$SECRET_KEY" ]; then
    raw="SECRET_KEY=$SECRET_KEY"; src="переменная SECRET_KEY"
  elif [ -f "$COMPOSE" ] && [ "$NEW_KEY" = 0 ]; then
    raw=$(cat "$COMPOSE"); src="из $COMPOSE; другой ключ — --new-key"
  elif have_tty; then
    info "Нужен ключ ноды из панели: Ноды → добавить ноду → скопируйте docker-compose.yml. Сейчас откроется редактор."
    ask "Нажмите Enter, чтобы открыть редактор…" _unused ""
    raw=$(ask_paste); src="вставка из панели"
  else
    die "нет SECRET_KEY: передайте SECRET_KEY='...' или --secret-key-file FILE, либо запустите в терминале"
  fi
  parse_compose_text "$raw" || die "не нашёл SECRET_KEY ($src)"
  if ! base64 -d <<<"$SECRET_KEY" 2>/dev/null | grep -q 'caCertPem'; then
    warn "ключ не похож на SECRET_KEY Remnawave (не раскодировался в набор сертификатов) — проверьте, что скопировали его целиком"
  fi
  ok "SECRET_KEY: ${#SECRET_KEY} символов ($src)"
}

render_compose() {
  local e v
  cat <<EOF
# Создано remnanode-setup $VERSION ($(date -u +%F)). Повторный запуск скрипта пересоздаёт файл, прошлая версия — рядом в .bak-*
services:
  remnanode:
    container_name: $NODE_NAME
    hostname: $NODE_NAME
    image: ${NODE_IMAGE:-$DEFAULT_IMAGE}
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=$NODE_PORT
      - SECRET_KEY="$SECRET_KEY"
EOF
  for e in "${ENV_EXTRA[@]}"; do printf '      - %s\n' "$e"; done
  printf '    volumes:\n      - %s:%s:ro\n' "$CERT_DIR" "$CERT_DIR"
  for v in "${VOL_EXTRA[@]}"; do printf '      - %s\n' "$v"; done
  cat <<'EOF'
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
EOF
}

node_xray_config() {  # JSON работающего Xray ноды (появляется, когда панель подключилась и отдала профиль)
  local pid cmd sock tok
  pid=$(pgrep -x rw-core 2>/dev/null | head -1 || true)
  [ -n "$pid" ] || return 1
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
  sock=$(grep -oP -- '-config @\K[^:]+' <<<"$cmd" || true)
  tok=$(grep -oP 'token=\K[^ &]+' <<<"$cmd" || true)
  [ -n "$sock" ] && [ -n "$tok" ] || return 1
  curl -fsS -m 5 --abstract-unix-socket "$sock" "http://localhost/internal/get-config?token=$tok" 2>/dev/null
}

check_inbounds() {
  local cfg tag port net proto l4 who
  cfg=$(node_xray_config) || { info "Xray ноды ещё не запущен панелью — порты инбаундов проверю позже: bash install.sh status"; return 0; }
  info "Инбаунды из профиля панели"
  while IFS=$'\t' read -r tag port net proto; do
    [ -n "$port" ] || continue
    l4=tcp
    case "$proto/$net" in hysteria*|*/hysteria|*/kcp|*/quic|wireguard/*) l4=udp ;; esac
    who=$(port_owner "$l4" "${port%%-*}")
    if [ -z "$who" ]; then warn "инбаунд «$tag» ($port/$l4) не слушается — Xray не смог занять порт? Смотрите логи ноды"
    elif [[ ! "$who" =~ (rw-core|xray) ]]; then warn "порт $port/$l4 инбаунда «$tag» занят процессом $who, а не Xray"
    else ok "$tag: $port/$l4"; fi
  done < <(jq -r '.inbounds[]? | select(.port != null) | [.tag, (.port|tostring), (.streamSettings.network // "tcp"), .protocol] | @tsv' <<<"$cfg" 2>/dev/null)
}

wait_node() {
  [ "$DRY_RUN" = 1 ] && return 0
  local i
  for i in $(seq 1 30); do port_busy tcp "$NODE_PORT" && break; sleep 2; done
  if port_busy tcp "$NODE_PORT"; then ok "нода слушает порт $NODE_PORT ($(port_owner tcp "$NODE_PORT"))"
  else warn "нода не открыла порт $NODE_PORT за 60 с — логи: cd $NODE_DIR && docker compose logs -t --tail 100"; fi
}

setup_node() {
  info "Нода Remnawave: $COMPOSE"
  [ -n "$SECRET_KEY" ] || die "нет SECRET_KEY"
  local who wd
  if port_busy tcp "$NODE_PORT"; then
    who=$(port_owner tcp "$NODE_PORT")
    case "$who" in rw-node|node|"") ;; *) die "порт ноды $NODE_PORT занят ($who). Освободите его или задайте --node-port (тот же порт укажите в панели)" ;; esac
  fi
  run install -d -m 755 "$NODE_DIR" "$CERT_DIR"
  local new changed=0
  new=$(render_compose)
  # строка с датой в шапке не считается изменением
  if [ ! -f "$COMPOSE" ] || [ "$(grep -v '^# Создано remnanode-setup' "$COMPOSE")" != "$(grep -v '^# Создано remnanode-setup' <<<"$new")" ]; then
    changed=1
    [ -f "$COMPOSE" ] && run cp -a "$COMPOSE" "$COMPOSE.bak-$(date +%Y%m%d-%H%M%S)"
    printf '%s\n' "$new" | write_file "$COMPOSE" 600
  else
    ok "$COMPOSE не изменился"
  fi
  wd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$NODE_NAME" 2>/dev/null || true)
  if docker inspect "$NODE_NAME" >/dev/null 2>&1 && [ "$wd" != "$NODE_DIR" ]; then
    warn "контейнер $NODE_NAME был создан не из $NODE_DIR (${wd:-вручную}) — пересоздаю"
    run docker rm -f "$NODE_NAME" >/dev/null
  fi
  info "Скачиваю образ и запускаю ноду"
  local n
  for n in 1 2 3; do run docker compose -f "$COMPOSE" pull -q && break; warn "docker pull: попытка $n не удалась"; sleep 5; done
  if [ "$CERT_CHANGED" = 1 ] && [ "$changed" = 0 ]; then
    info "Сертификат обновился — перезапускаю ноду, чтобы Xray его перечитал"
    run docker compose -f "$COMPOSE" up -d --force-recreate --remove-orphans
  else
    run docker compose -f "$COMPOSE" up -d --remove-orphans
  fi
  wait_node
}

post_node_checks() {
  [ "$DRY_RUN" = 1 ] && return 0
  local i
  for i in $(seq 1 15); do node_xray_config >/dev/null && break; sleep 2; done
  check_inbounds
  if [ "$IS_CONTAINER" = 0 ] && [ -n "$(inbound_ports_from_node)" ]; then write_sysctl; apply_sysctl >/dev/null; fi
  open_ports_if_firewall_active
}

open_ports_if_firewall_active() {  # частая причина «нода offline»: у провайдера в образе уже включён ufw
  [ "$FIREWALL" = 1 ] && return 0
  command -v ufw >/dev/null || return 0
  ufw status 2>/dev/null | grep -q 'Status: active' || return 0
  info "ufw включён — открываю порт ноды и инбаунды, иначе панель и клиенты не достучатся"
  ufw_allow_node_ports
}

ufw_allow_node_ports() {
  local p
  if [ -n "$PANEL_IP" ]; then run ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'remnawave panel' >/dev/null
  else run ufw allow "$NODE_PORT/tcp" comment 'remnawave node' >/dev/null; fi
  for p in ${INBOUND_PORTS//,/ }; do run ufw allow "$p" comment 'xray inbound' >/dev/null; done
  local cfg; cfg=$(node_xray_config 2>/dev/null) || return 0
  while IFS=$'\t' read -r port net proto; do
    case "$proto/$net" in hysteria*|*/hysteria|*/kcp|*/quic|wireguard/*) run ufw allow "${port/-/:}/udp" comment 'xray inbound' >/dev/null ;;
      *) run ufw allow "${port/-/:}/tcp" comment 'xray inbound' >/dev/null ;; esac
  done < <(jq -r '.inbounds[]? | select(.port != null and (.listen // "0.0.0.0") != "127.0.0.1") | [(.port|tostring), (.streamSettings.network // "tcp"), .protocol] | @tsv' <<<"$cfg" 2>/dev/null)
}

setup_firewall() {
  [ "$FIREWALL" = 1 ] || return 0
  info "Firewall (ufw)"
  apt_install ufw
  local sshp p
  sshp=$( (sshd -T 2>/dev/null || true) | awk '/^port /{print $2}' | sort -u)
  [ -n "$sshp" ] || sshp=22
  for p in $sshp; do run ufw allow "$p/tcp" comment 'ssh' >/dev/null; done
  run ufw allow 80/tcp comment 'acme' >/dev/null
  run ufw allow 443/tcp comment 'https' >/dev/null
  ufw_allow_node_ports
  [ -n "$PANEL_IP" ] || warn "--panel-ip не задан: порт ноды $NODE_PORT открыт для всех"
  run ufw --force enable >/dev/null
  ok "ufw включён (SSH: $(echo "$sshp" | paste -sd, -))"
}

# ---------- команды ----------
collect_inputs() {
  get_secret_key
  NODE_PORT=${NODE_PORT_ARG:-${NODE_PORT:-2222}}
  [[ $NODE_PORT =~ ^[0-9]+$ ]] || die "неверный порт ноды: $NODE_PORT"
  if [ -z "$DOMAIN" ]; then
    local cur=""
    [ -f "$CERT_DIR/fullchain.pem" ] && cur=$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject 2>/dev/null | sed -nE 's/.*CN *= *([^,/]+).*/\1/p')
    ask "Домен этой ноды для сертификата HY2/TLS (например de15.example.com)${cur:+, Enter — $cur}${cur:-, Enter — без сертификата}:" DOMAIN "$cur"
  fi
  if [ -n "$DOMAIN" ] && ! [[ $DOMAIN =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]; then die "неверный домен: $DOMAIN"; fi
  [ -n "$DOMAIN" ] && ACME_PORT=$(pick_acme_port)   # заранее, чтобы попал в резерв портов
  return 0
}

cmd_install() {
  info "remnanode-setup $VERSION: установка ноды Remnawave${DRY_RUN:+}"
  [ "$DRY_RUN" = 1 ] && info "режим --dry-run: ничего не меняю, только показываю"
  preflight_ports
  collect_inputs
  apt_install curl ca-certificates gnupg iproute2 iptables openssl psmisc jq
  tune_kernel
  setup_swap
  setup_journald
  setup_time
  install_docker
  setup_warp
  setup_cert
  setup_node
  post_node_checks
  setup_firewall
}

cmd_cert() {
  [ -n "$DOMAIN" ] || ask "Домен ноды для сертификата:" DOMAIN ""
  [ -n "$DOMAIN" ] || die "нужен --domain"
  apt_install curl ca-certificates iproute2 iptables openssl
  setup_cert
}

cmd_update() {
  [ -f "$COMPOSE" ] || die "нет $COMPOSE — сначала bash install.sh"
  NODE_PORT=$(sed -nE 's/.*NODE_PORT=([0-9]+).*/\1/p' "$COMPOSE" | head -1); NODE_PORT=${NODE_PORT:-2222}
  info "Обновляю образ ноды"
  run docker compose -f "$COMPOSE" pull -q
  run docker compose -f "$COMPOSE" up -d --remove-orphans
  run docker image prune -f >/dev/null
  wait_node
  post_node_checks
}

cmd_status() {
  detect_os
  NODE_PORT=$(sed -nE 's/.*NODE_PORT=([0-9]+).*/\1/p' "$COMPOSE" 2>/dev/null | head -1 || true); NODE_PORT=${NODE_PORT:-2222}
  info "Нода"
  if docker inspect "$NODE_NAME" >/dev/null 2>&1; then
    ok "контейнер $NODE_NAME: $(docker inspect -f '{{.State.Status}}, запущен {{.State.StartedAt}}, образ {{.Config.Image}}' "$NODE_NAME")"
    local errs; errs=$(docker logs --since 1h "$NODE_NAME" 2>&1 | grep -ciE '\b(error|failed)\b' || true)
    [ "${errs:-0}" -gt 0 ] && warn "в логах ноды за час $errs строк с error/failed: docker logs --since 1h $NODE_NAME | grep -iE 'error|failed'"
  else
    warn "контейнера $NODE_NAME нет"
  fi
  if port_busy tcp "$NODE_PORT"; then ok "порт для панели $NODE_PORT: $(port_owner tcp "$NODE_PORT")"; else warn "порт $NODE_PORT никто не слушает"; fi
  if [ -f "$COMPOSE" ]; then
    grep -q "$CERT_DIR:$CERT_DIR" "$COMPOSE" && ok "volume $CERT_DIR подключён" || warn "в $COMPOSE нет volume $CERT_DIR"
    grep -q 'max-size' "$COMPOSE" || warn "у контейнера нет ротации логов (logging max-size)"
  fi
  check_inbounds

  info "WARP"
  if command -v warp-cli >/dev/null; then
    if warp_ok; then ok "warp=on через 127.0.0.1:$WARP_PORT"; else warn "WARP не отвечает на 127.0.0.1:$WARP_PORT (warp-cli --accept-tos status)"; fi
  else
    info "WARP не установлен (нужен, только если в профиле есть outbound на socks 127.0.0.1:$WARP_PORT)"
  fi

  info "Сертификаты"
  local conf name live days auth
  for conf in /etc/letsencrypt/renewal/*.conf; do
    [ -f "$conf" ] || continue
    name=$(basename "$conf" .conf); live="/etc/letsencrypt/live/$name/fullchain.pem"
    [ -f "$live" ] || continue
    days=$(( ($(date -d "$(openssl x509 -in "$live" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
    auth=$(sed -nE 's/^authenticator *= *//p' "$conf")
    if grep -q "$HOOK_DIR/acme-pre.sh" "$conf"; then auth="$auth через перенаправление :80 (remnanode-setup)"
    elif [ "$auth" = standalone ]; then auth="standalone — упадёт, если 80-й порт кто-то займёт"; fi
    if [ "$days" -lt 0 ]; then warn "$name: ИСТЁК $((-days)) дн. назад; продление: $auth"
    elif [ "$days" -lt 20 ]; then warn "$name: осталось $days дн. (должен был продлиться на 30-й день); продление: $auth"
    else ok "$name: $days дн.; продление: $auth"; fi
  done
  if [ -f "$CERT_DIR/fullchain.pem" ]; then
    local cn exp; cn=$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -subject | sed -nE 's/.*CN *= *([^,/]+).*/\1/p')
    exp=$(openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -enddate | cut -d= -f2)
    if [ -f "/etc/letsencrypt/live/$cn/fullchain.pem" ] && ! cmp -s "/etc/letsencrypt/live/$cn/fullchain.pem" "$CERT_DIR/fullchain.pem"; then
      warn "копия у ноды ($CERT_DIR, до $exp) отличается от сертификата certbot для $cn — bash install.sh cert --domain $cn"
    else ok "у ноды: $cn до $exp"; fi
  fi

  info "Система"
  local cc rmem res
  cc=$(sysctl -n net.ipv4.tcp_congestion_control); rmem=$(sysctl -n net.core.rmem_max)
  if [ "$cc" = bbr ]; then ok "BBR, qdisc $(sysctl -n net.core.default_qdisc)"; else warn "congestion control: $cc (не bbr) — bash install.sh включит BBR"; fi
  if [ "$rmem" -ge 8388608 ]; then ok "UDP-буфер для HY2/QUIC: $rmem"; else warn "net.core.rmem_max=$rmem — мало для Hysteria2/QUIC (нужно ≥ 8 МБ)"; fi
  res=$(sysctl -n net.ipv4.ip_local_reserved_ports 2>/dev/null || true)
  if [ -n "$res" ]; then ok "резерв портов: $res"; else warn "порты сервисов не зарезервированы — исходящее соединение может занять их перед перезапуском"; fi
  if [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
    ok "conntrack: $(cat /proc/sys/net/netfilter/nf_conntrack_count)/$(cat /proc/sys/net/netfilter/nf_conntrack_max), established timeout $(cat /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established) c"
  fi
  local swap; swap=$(swapon --show --noheadings 2>/dev/null | awk '{print $1" "$3}' | paste -sd' ' -)
  ok "память: $(free -m | awk 'NR==2{print "доступно "$7" из "$2" МБ"}'), swap: ${swap:-нет}"
  if [ -z "$swap" ] && [ "$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)" -lt 8000 ]; then warn "swap нет — при нехватке памяти ядро будет убивать процессы"; fi
  local oom; oom=$(journalctl -k --since -1d --no-pager 2>/dev/null | grep -c 'Out of memory\|oom-kill' || true)
  if [ "${oom:-0}" -gt 0 ]; then warn "OOM за сутки: $oom — памяти не хватает (swap, меньше сервисов на сервере)"; fi
  ok "диск /: $(df -h / | awk 'NR==2{print $4" свободно из "$2}'), журналы: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1)"
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" = yes ] && ok "время синхронизировано" || warn "время не синхронизировано"
}

summary() {
  echo
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    printf '%sПредупреждения (%d):%s\n' "$Y" "${#WARNINGS[@]}" "$N"
    printf '  - %s\n' "${WARNINGS[@]}"
  else
    ok "готово, предупреждений нет"
  fi
  if [ "$CMD" = install ] && [ "$DRY_RUN" = 0 ]; then
    cat <<EOF

Дальше:
  - в панели у ноды: адрес этого сервера, порт $NODE_PORT; когда панель подключится, Xray запустится с профилем
  - логи ноды:      cd $NODE_DIR && docker compose logs -f -t
  - проверка всего: bash $0 status
EOF
  fi
}

parse_args() {
  if [ $# -gt 0 ]; then case "$1" in install|cert|status|update) CMD=$1; shift ;; esac; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain) DOMAIN=${2:-}; shift 2 ;;
      --email) EMAIL=${2:-}; shift 2 ;;
      --secret-key-file) SECRET_KEY_FILE=${2:-}; shift 2 ;;
      --new-key) NEW_KEY=1; shift ;;
      --node-port) NODE_PORT_ARG=${2:-}; shift 2 ;;
      --inbound-ports) INBOUND_PORTS=${2:-}; shift 2 ;;
      --no-warp) WARP=0; shift ;;
      --warp-port) WARP_PORT=${2:-}; shift 2 ;;
      --no-swap) SWAP=0; shift ;;
      --firewall) FIREWALL=1; shift ;;
      --panel-ip) PANEL_IP=${2:-}; shift 2 ;;
      --no-logs) FOLLOW_LOGS=0; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "неизвестный параметр: $1 (bash install.sh --help)" ;;
    esac
  done
  [[ $WARP_PORT =~ ^[0-9]+$ ]] || die "неверный --warp-port"
  if [ -n "$NODE_PORT_ARG" ] && ! [[ $NODE_PORT_ARG =~ ^[0-9]+$ ]]; then die "неверный --node-port"; fi
  if [ -n "$PANEL_IP" ] && ! [[ $PANEL_IP =~ ^[0-9a-fA-F:.]+(/[0-9]+)?$ ]]; then die "неверный --panel-ip"; fi
  return 0
}

main() {
  parse_args "$@"
  [ "$(id -u)" = 0 ] || die "запустите от root (sudo -i)"
  if [ "$CMD" = status ]; then cmd_status; summary; exit 0; fi
  start_log
  detect_os
  case "$CMD" in
    install) cmd_install ;;
    cert) cmd_cert ;;
    update) cmd_update ;;
  esac
  summary
  if [ "$CMD" = install ] && [ "$DRY_RUN" = 0 ] && [ "$FOLLOW_LOGS" = 1 ] && have_tty; then
    echo; info "Логи ноды (Ctrl+C — выйти из логов, нода продолжит работать):"
    cd "$NODE_DIR" && docker compose logs -f -t --tail 50 || true
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ] || [ -z "${BASH_SOURCE[0]:-}" ] || [[ ${BASH_SOURCE[0]} == /dev/fd/* ]] || [[ ${BASH_SOURCE[0]} == /proc/self/fd/* ]]; then
  main "$@"
fi

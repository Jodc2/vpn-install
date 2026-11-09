#!/bin/bash
# install-vpn.sh — свой VPN «под ключ» на чистом сервере Ubuntu 22.04/24.04 или Debian 12.
#
# Скрипт спросит, есть ли у вас домен, и поставит один из двух вариантов:
#   • С доменом (лучше): VLESS + XHTTP + Reality «steal-oneself» на порту 2083 —
#     SNI ваш домен, а тому, кто прощупывает сервер, Reality показывает настоящий сайт с этого же сервера;
#     nginx на 443: сайт-заглушка, панель и подписка за доменом по секретным путям; Let's Encrypt.
#     Нужна A-запись домена на IP сервера (в Cloudflare — серое облако, Proxy выключен).
#   • Без домена: VLESS + XHTTP + Reality на порту 443 под крупный чужой сайт (скрипт сам проверит
#     и выберет подходящий). Ссылки привязаны к IP сервера, панель — только через SSH-туннель.
# В обоих: 3x-ui 3.3.1 + Xray 26.6.1 (sha256 закреплены), BBR, IPv6 выключен, swap, фаервол ufw,
# fail2ban против подбора пароля SSH, ежедневный бэкап для переезда в /root/backups.
# До установки скрипт проверяет через check-host.net, не заблокирован ли IP сервера в России,
# после установки — открыты ли порты VPN из России и Европы.
#
# Запуск от root:
#   bash install-vpn.sh                           — спросит, есть ли домен
#   bash install-vpn.sh --domain vpn.example.com  — с доменом, без вопросов
#   bash install-vpn.sh --no-domain               — без домена, без вопросов
#   bash install-vpn.sh --check                   — проверить уже установленный VPN (ничего не меняет)
#
# Опции:
#   --domain ДОМЕН    свой домен, A-запись которого уже указывает на этот сервер
#   --no-domain       без домена: Reality на 443 под крупный чужой сайт
#   --sni САЙТ        (без домена) под какой сайт маскироваться вместо автовыбора, например www.samsung.com
#   --clients N       сколько клиентов (устройств) создать, по умолчанию 5; потом — в панели
#   --exit РЕЖИМ      куда выходит трафик клиентов:
#                       direct  — с IP сервера (по умолчанию, быстрее всего);
#                       warp    — всё через Cloudflare WARP: IP сервера не виден сайтам,
#                                 но бывают капчи Google и потолок около 100 Мбит/с;
#                       warp-ru — российские сайты через WARP, остальное напрямую
#   --ssh-key-only    выключить вход по паролю (только если у root уже есть SSH-ключ)
#   --no-fail2ban     не ставить fail2ban
#   --no-ufw          не трогать фаервол
#   --tz ЗОНА         часовой пояс для cron (по умолчанию Europe/Moscow)
#   --skip-dns-check  не сверять A-запись домена с IP сервера
#   --skip-ip-check   не проверять до установки, доступен ли IP из России
#   --check           только проверить: службы, туннель, доступность портов из России и Европы
# Повторный запуск безопасен: ключи, пароли и клиенты сохраняются (/etc/vpn-install.env).
set -euo pipefail
umask 022
export LC_ALL=C.UTF-8 LANG=C.UTF-8 DEBIAN_FRONTEND=noninteractive

XUI_VERSION=3.3.1
XRAY_VERSION=26.6.1
XUI_SHA256_AMD64=06adfff2b27af6d59225338a8112caca882d32d11136d962649826d42c24d12e
XUI_SHA256_ARM64=0f7907b56554eba624c51c6aed2a9ba4af1378c8134b30afa5cee622e3100209
ACME_TAG=v3.1.6
ACME_SHA256=c7d68b021cfd6380ea83a82962abde5b484779fee0b97d38681dfa1396bbc8d7
SUB_PORT=2096
STATE=/etc/vpn-install.env
INFO=/root/vpn-info.txt
LOG=/root/vpn-install.log
DB=/etc/x-ui/x-ui.db
XUI=/usr/local/x-ui/x-ui
F2B_JAIL=/etc/fail2ban/jail.d/vpn-sshd.local
WARP_ENDPOINT=162.159.192.8:2408   # engage.cloudflareclient.com по IP: имя через DNS дало бы петлю
# Без домена Reality маскируется под один из этих сайтов: берётся самый быстрый с этого сервера из тех,
# что держат TLS 1.3 + X25519 + HTTP/2 с верным сертификатом и не стоят за Cloudflare.
SNI_CANDIDATES="www.microsoft.com www.apple.com swdist.apple.com images.apple.com www.samsung.com dl.google.com
www.nvidia.com www.oracle.com www.intel.com www.dell.com www.hp.com www.asus.com www.cisco.com www.amazon.com"

DOMAIN=
NO_DOMAIN=0
SNI_ARG=
CLIENTS=5
EXIT_MODE=direct
SSH_KEY_ONLY=0
DO_F2B=1
DO_UFW=1
TZ_NAME=Europe/Moscow
SKIP_DNS=0
SKIP_IP_CHECK=0
CHECK_ONLY=0
TEST_SELFSIGNED=0   # только для проверки самого скрипта: самоподписанный сертификат вместо Let's Encrypt
ACME_STAGING=0      # только для проверки: тестовый сервер Let's Encrypt
while [ $# -gt 0 ]; do
	case $1 in
		--domain) DOMAIN=${2:-}; shift 2 ;;
		--no-domain) NO_DOMAIN=1; shift ;;
		--sni) SNI_ARG=${2:-}; shift 2 ;;
		--clients) CLIENTS=${2:-}; shift 2 ;;
		--exit) EXIT_MODE=${2:-}; shift 2 ;;
		--ssh-key-only) SSH_KEY_ONLY=1; shift ;;
		--no-fail2ban) DO_F2B=0; shift ;;
		--no-ufw) DO_UFW=0; shift ;;
		--tz) TZ_NAME=${2:-}; shift 2 ;;
		--skip-dns-check) SKIP_DNS=1; shift ;;
		--skip-ip-check) SKIP_IP_CHECK=1; shift ;;
		--check) CHECK_ONLY=1; shift ;;
		--test-selfsigned) TEST_SELFSIGNED=1; SKIP_DNS=1; shift ;;
		--acme-staging) ACME_STAGING=1; shift ;;
		-h | --help) awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 0 ;;
		*) echo "неизвестная опция: $1 (см. --help)" >&2; exit 2 ;;
	esac
done

FAILS=0
say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok() { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mВНИМ.\033[0m %s\n' "$*"; }
bad() { printf '  \033[31mОШИБКА\033[0m %s\n' "$*"; FAILS=$((FAILS + 1)); }
die() { printf '\n\033[31mОстановлено: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "запускать от root (sudo -i, потом снова bash $0 …)"
command -v apt-get >/dev/null || die "нужен Ubuntu или Debian (apt-get)"
case $(uname -m) in
	x86_64 | amd64) ARCH=amd64; XUI_SHA256=$XUI_SHA256_AMD64 ;;
	aarch64 | arm64) ARCH=arm64; XUI_SHA256=$XUI_SHA256_ARM64 ;;
	*) die "архитектура $(uname -m) не поддерживается (нужна x86_64 или arm64)" ;;
esac
XRAY=/usr/local/x-ui/bin/xray-linux-$ARCH

# --- Режим: с доменом или без ---
norm_host() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's#^[a-z]+://##; s#[/:].*$##; s#\.$##'; }
is_host() { [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$ ]]; }
state_val() { [ -f "$STATE" ] && sed -n "s/^$1='\(.*\)'\$/\1/p" "$STATE" | head -1; }
MODE=
S_MODE=$(state_val S_MODE || true)
S_DOMAIN_OLD=$(state_val S_DOMAIN || true)
if [ -z "$S_MODE" ] && [ -n "$S_DOMAIN_OLD" ]; then S_MODE=domain; fi   # установка прежней версией скрипта
if [ "$CHECK_ONLY" = 1 ]; then
	[ -n "$S_MODE" ] || die "VPN этим скриптом здесь ещё не ставился (нет $STATE) — сначала bash $0"
	MODE=$S_MODE
	DOMAIN=$S_DOMAIN_OLD
else
	if [ -n "$DOMAIN" ] && [ "$NO_DOMAIN" = 1 ]; then die "--domain и --no-domain вместе нельзя"; fi
	[ -n "$DOMAIN" ] && MODE=domain
	[ "$NO_DOMAIN" = 1 ] && MODE=nodomain
	if [ -z "$MODE" ] && [ -n "$S_MODE" ]; then   # повторный запуск — как в прошлый раз
		MODE=$S_MODE
		[ "$MODE" = domain ] && DOMAIN=$S_DOMAIN_OLD
	fi
	if [ -z "$MODE" ]; then
		{ : > /dev/tty; } 2>/dev/null || die "укажите --domain ДОМЕН или --no-domain (скрипт запущен без терминала, спросить некого)"
		cat > /dev/tty <<'EOF'

Есть ли у вас свой домен для этого сервера?
  1) Да  — лучше: маскировка под свой сайт, подписки в приложениях обновляются сами,
           панель открывается по адресу домена. Нужна A-запись домена на IP этого сервера.
  2) Нет — маскировка под крупный чужой сайт. Ссылки привязаны к IP сервера
           (переедете на другой сервер — ссылки раздать заново), панель — через SSH-туннель.
EOF
		while [ -z "$MODE" ]; do
			printf 'Ваш выбор [1/2]: ' > /dev/tty
			read -r ans < /dev/tty || die "не удалось прочитать ответ"
			case $ans in
				1 | да | Да | ДА | y | Y | yes) MODE=domain ;;
				2 | нет | Нет | НЕТ | n | N | no) MODE=nodomain ;;
			esac
		done
		if [ "$MODE" = domain ]; then
			printf 'Домен (например vpn.example.com): ' > /dev/tty
			read -r DOMAIN < /dev/tty || true
		fi
	fi
	if [ -n "$S_MODE" ] && [ "$S_MODE" != "$MODE" ]; then
		die "сервер уже ставился $([ "$S_MODE" = domain ] && echo "с доменом $S_DOMAIN_OLD" || echo "без домена"). Сменить вариант можно только на чистом сервере"
	fi
fi
if [ "$MODE" = domain ]; then
	DOMAIN=$(norm_host "$DOMAIN")
	is_host "$DOMAIN" || die "нужен домен вида vpn.example.com (сейчас: «$DOMAIN»)"
	[ -z "$S_DOMAIN_OLD" ] || [ "$S_DOMAIN_OLD" = "$DOMAIN" ] ||
		die "сервер уже ставился на домен $S_DOMAIN_OLD. Для другого домена нужен чистый сервер"
	REALITY_PORT=2083
else
	DOMAIN=
	if [ -n "$SNI_ARG" ]; then
		SNI_ARG=$(norm_host "$SNI_ARG")
		is_host "$SNI_ARG" || die "--sni: нужно имя сайта вида www.example.com (сейчас: «$SNI_ARG»)"
	fi
	REALITY_PORT=443
fi
[[ $CLIENTS =~ ^[0-9]+$ ]] && [ "$CLIENTS" -ge 1 ] && [ "$CLIENTS" -le 100 ] || die "--clients: число от 1 до 100"
case $EXIT_MODE in direct | warp | warp-ru) ;; *) die "--exit: direct, warp или warp-ru" ;; esac

# --- Общие проверки и мелочи ---
in_container() {
	if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -cq 2>/dev/null; then return 0; fi
	[ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -qa 'container=' /proc/1/environ 2>/dev/null
}
CONTAINER=0
if in_container; then CONTAINER=1; fi

port_users() {  # имена процессов, слушающих TCP-порт
	{ ss -Htlnp "sport = :$1" 2>/dev/null || true; } | { grep -o 'users:(("[^"]*"' || true; } | cut -d'"' -f2 | sort -u | tr '\n' ' '
}

wait_port() {  # wait_port ADDR:PORT [секунд]
	local _
	for _ in $(seq 1 "${2:-20}"); do
		ss -Htln "sport = :${1##*:}" 2>/dev/null | grep -qF "$1" && return 0
		sleep 1
	done
	return 1
}

rnd() { python3 -c 'import secrets, sys; print("".join(secrets.choice(sys.argv[1]) for _ in range(int(sys.argv[2]))))' "$1" "$2"; }
LOWER=abcdefghijklmnopqrstuvwxyz
DIGITS=0123456789

free_port() {  # случайный свободный TCP-порт из 20000–60000
	python3 - <<'PY'
import random, socket
for _ in range(200):
    p = random.randint(20000, 59999)
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p))
    except OSError:
        continue
    finally:
        s.close()
    print(p)
    break
PY
}

resolve() {  # resolve ИМЯ A|AAAA → записи через DoH (не через локальный резолвер: он кэширует)
	local u out
	for u in "https://cloudflare-dns.com/dns-query?name=$1&type=$2" "https://dns.google/resolve?name=$1&type=$2"; do
		out=$(curl -fsS --max-time 8 -H 'accept: application/dns-json' "$u" 2>/dev/null |
			python3 -c 'import json, sys; t = {"A": 1, "AAAA": 28}[sys.argv[1]]; print(" ".join(a["data"] for a in json.load(sys.stdin).get("Answer", []) if a.get("type") == t))' "$2" 2>/dev/null) || continue
		echo "$out"
		return 0
	done
	return 1
}

is_cloudflare_ip() {
	python3 - "$1" <<'PY'
import ipaddress, sys
nets = "173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22".split()
ip = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if any(ip in ipaddress.ip_network(n) for n in nets) else 1)
PY
}

sni_ms() {  # sni_ms САЙТ → время рукопожатия в мс, если сайт годится в target Reality
	local d=$1 ip out t0 t1
	ip=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR == 1 {print $1}')
	[ -n "$ip" ] || return 1
	! is_cloudflare_ip "$ip" || return 1
	t0=$(date +%s%N)
	out=$(timeout 8 openssl s_client -connect "$ip:443" -servername "$d" -verify_hostname "$d" -verify_return_error \
		-tls1_3 -groups X25519 -alpn h2 < /dev/null 2>&1) || return 1
	t1=$(date +%s%N)
	grep -q 'New, TLSv1.3' <<<"$out" && grep -q 'ALPN protocol: h2' <<<"$out" &&
		grep -q 'Server Temp Key: X25519' <<<"$out" && grep -q 'Verify return code: 0 (ok)' <<<"$out" || return 1
	echo $(((t1 - t0) / 1000000))
}

detect_ips() {  # LISTEN_IP — адрес на интерфейсе, PUBLIC_IP — как сервер видят снаружи
	local u
	LISTEN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
	[ -n "$LISTEN_IP" ] || die "не удалось определить IPv4 сервера (нет IPv4-маршрута в интернет?)"
	PUBLIC_IP=
	for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
		PUBLIC_IP=$(curl -4 -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]') || true
		[[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
		PUBLIC_IP=
	done
	if [ -z "$PUBLIC_IP" ]; then
		[ "$MODE" = domain ] || die "не удалось узнать внешний IP сервера (api.ipify.org, ifconfig.me недоступны), а без домена он нужен для ссылок"
		PUBLIC_IP=$LISTEN_IP
	fi
}

ssh_ports() {  # TCP-порты sshd (обычно 22)
	local p
	p=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -un | tr '\n' ' ' || true)
	[ -n "$p" ] || p=${SSH_CONNECTION:+${SSH_CONNECTION##* }}
	echo "${p:-22}"
}

# --- Доступность из России и Европы: TCP-проверка с узлов check-host.net ---
chk_probe() {  # chk_probe IP ПОРТ… → по строке на порт: порт|ru_ok|ru_done|ru_всего|eu_ok|eu_done|eu_всего|ru_описание|eu_описание
	python3 - "$@" <<'PY'
import json, sys, time, urllib.request
ip, ports = sys.argv[1], sys.argv[2:]
H = {"Accept": "application/json", "User-Agent": "vpn-install-check/1.0"}

def get(url, tries=3):
    err = None
    for _ in range(tries):
        try:
            return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=H), timeout=20))
        except Exception as e:
            err = e
            time.sleep(4)
    raise err

try:
    nodes = get("https://check-host.net/nodes/hosts")["nodes"]
except Exception:
    print("NOAPI")
    sys.exit(0)
ru = sorted(n for n, i in nodes.items() if (i.get("location") or [""])[0] == "ru")
eu = []
for p in ("de1", "nl1", "fi1", "se1", "pl1", "fr2", "de4", "nl2"):
    eu += [n for n in sorted(nodes) if n.split(".")[0] == p and n not in eu]
eu = eu[:2]
if not ru:
    print("NORU")
    sys.exit(0)
city = {n: (nodes[n].get("location") or ["", "", n])[-1] for n in ru + eu}
q = "&".join("node=" + n for n in ru + eu)


def probe(ports):  # один заход: порт → {узел: ok|fail|?}; None — check-host не принял проверку
    rids, res = {}, {p: {} for p in ports}
    for k, port in enumerate(ports):
        if k:
            time.sleep(4)   # check-host не любит частые запросы
        try:
            rids[port] = get("https://check-host.net/check-tcp?host=%s:%s&%s" % (ip, port, q))["request_id"]
        except Exception:
            rids[port] = None
    for _ in range(25):
        time.sleep(3)
        pending = False
        for port, rid in rids.items():
            if not rid or (res[port] and all(v is not None for v in res[port].values())):
                continue
            try:
                res[port] = get("https://check-host.net/check-result/" + rid, tries=1) or {}
            except Exception:
                pass
            if not res[port] or any(v is None for v in res[port].values()):
                pending = True
        if not pending:
            break
    out = {}
    for port in ports:
        if not rids[port]:
            out[port] = None
            continue
        out[port] = {}
        for n in ru + eu:
            v = res[port].get(n)
            out[port][n] = "?" if v is None else ("ok" if v and isinstance(v[0], dict) and "time" in v[0] else "fail")
    return out


# Узлы check-host иногда промахиваются поодиночке: порты, где не все узлы достучались, проверяются второй раз,
# и узел считается достучавшимся, если получилось хоть раз.
first = probe(ports)
again = [p for p in ports if first[p] is not None and any(s != "ok" for s in first[p].values())]
if again:
    time.sleep(4)
    second = probe(again)
    for p in again:
        if second.get(p):
            for n, s in second[p].items():
                if s == "ok" or first[p].get(n) == "?":
                    first[p][n] = s
res = first

def state(port, n):
    return res[port].get(n, "?")

mark = {"ok": "✓", "fail": "✗", "?": "…"}
for port in ports:
    if res[port] is None:
        print("%s|UNAVAILABLE" % port)
        continue
    row = [port]
    for group in (ru, eu):
        st = [state(port, n) for n in group]
        row += [str(st.count("ok")), str(len(st) - st.count("?")), str(len(group))]
    for group in (ru, eu):
        row.append(", ".join("%s %s" % (city.get(n, n), mark[state(port, n)]) for n in group))
    print("|".join(row))
PY
}

port_verdict() {  # port_verdict ru_ok ru_done ru_n eu_ok eu_done → OK | RU_BLOCKED | CLOSED | PARTIAL | UNKNOWN
	if [ "$2" = 0 ] && [ "$5" = 0 ]; then echo UNKNOWN
	elif [ "$1" = "$3" ]; then echo OK
	elif [ "$1" = 0 ] && [ "$4" -gt 0 ]; then echo RU_BLOCKED
	elif [ "$1" = 0 ] && [ "$4" = 0 ] && [ "$5" -gt 0 ]; then echo CLOSED
	elif [ "$1" -gt 0 ]; then echo PARTIAL
	else echo UNKNOWN
	fi
}

ip_precheck() {  # до установки: не заблокирован ли IP в России (по SSH — он слушает всегда)
	local port line p ru_ok ru_done ru_n eu_ok eu_done eu_n ru_s eu_s
	port=$(ssh_ports | awk '{print $1}')
	if [ "$SKIP_IP_CHECK" = 1 ]; then warn "доступность IP из России не проверялась (--skip-ip-check)"; return 0; fi
	line=$(chk_probe "$PUBLIC_IP" "$port" | head -1)
	case $line in
		NOAPI | "") warn "check-host.net недоступен — не проверить, заблокирован ли IP в России; ставлю дальше"; return 0 ;;
		NORU) warn "у check-host.net сейчас нет узлов в России — блокировку IP проверить нечем; ставлю дальше"; return 0 ;;
		*"|UNAVAILABLE") warn "check-host.net не принял проверку — блокировку IP проверить не удалось; ставлю дальше"; return 0 ;;
	esac
	IFS='|' read -r p ru_ok ru_done ru_n eu_ok eu_done eu_n ru_s eu_s <<<"$line"
	if [ "$(port_verdict "$ru_ok" "$ru_done" "$ru_n" "$eu_ok" "$eu_done")" = RU_BLOCKED ]; then
		# Прежде чем отказаться от установки — ещё раз, через полминуты: узлы иногда сбоят вместе.
		sleep 30
		line=$(chk_probe "$PUBLIC_IP" "$port" | head -1)
		case $line in *"|"*"|"*) IFS='|' read -r p ru_ok ru_done ru_n eu_ok eu_done eu_n ru_s eu_s <<<"$line" ;; esac
	fi
	case $(port_verdict "$ru_ok" "$ru_done" "$ru_n" "$eu_ok" "$eu_done") in
		OK) ok "IP $PUBLIC_IP открывается из России (SSH :$port — $ru_s; Европа — $eu_s)" ;;
		RU_BLOCKED)
			die "IP $PUBLIC_IP, похоже, заблокирован в России: SSH :$port не открывается из России ($ru_s), а из Европы открывается ($eu_s). VPN на этом IP работать не будет — возьмите другой сервер или попросите у хостера новый IP. Проверить снова — запустить скрипт ещё раз; поставить всё равно — --skip-ip-check" ;;
		CLOSED) warn "SSH :$port не открылся ни из России, ни из Европы — блокировку IP по нему не проверить (хостер пускает SSH не всех?). Порты VPN проверю после установки" ;;
		PARTIAL)
			warn "из России IP открывается не со всех узлов ($ru_s; Европа — $eu_s): похоже на частичную блокировку — у части провайдеров VPN может не работать"
			if { : > /dev/tty; } 2>/dev/null; then
				printf 'Продолжить установку на этот IP всё равно? [y/N]: ' > /dev/tty
				read -r ans < /dev/tty || ans=
				case $ans in y | Y | yes | да | Да) ok "продолжаю по вашему решению" ;; *) die "установка отменена: лучше взять другой IP (новый сервер или смена IP у хостера). Поставить всё равно — --skip-ip-check" ;; esac
			fi ;;
		*) warn "узлы check-host.net не ответили вовремя — блокировку IP проверить не удалось; ставлю дальше" ;;
	esac
}

reach_check() {  # после установки и в --check: открыты ли SSH и порты VPN из России и Европы
	local ssh_port ports line p ru_ok ru_done ru_n eu_ok eu_done eu_n ru_s eu_s v what ssh_v=UNKNOWN
	say "Доступность снаружи: из России и Европы (check-host.net)"
	if [ "${VPN_TEST_NO_EXTERNAL:-0}" = 1 ]; then warn "пропущено (VPN_TEST_NO_EXTERNAL=1)"; return 0; fi
	ssh_port=$(ssh_ports | awk '{print $1}')
	ports="$ssh_port $REALITY_PORT"
	[ "$MODE" = domain ] && ports="$ssh_port $REALITY_PORT 443 80"
	# shellcheck disable=SC2086
	chk_probe "$PUBLIC_IP" $ports > "$CHK_OUT"
	case $(head -1 "$CHK_OUT") in
		NOAPI | "") warn "check-host.net недоступен — доступность из России не проверена (повторить потом: bash $0 --check)"; return 0 ;;
		NORU) warn "у check-host.net сейчас нет узлов в России — проверить нечем (повторить потом: bash $0 --check)"; return 0 ;;
	esac
	while IFS='|' read -r p ru_ok ru_done ru_n eu_ok eu_done eu_n ru_s eu_s; do
		if [ "$ru_ok" = UNAVAILABLE ]; then warn "порт $p: check-host.net не принял проверку"; continue; fi
		v=$(port_verdict "$ru_ok" "$ru_done" "$ru_n" "$eu_ok" "$eu_done")
		case $p in
			"$ssh_port") what="SSH" ;;
			"$REALITY_PORT") what="VPN" ;;
			443) what="подписка и панель" ;;
			80) what="продление сертификата" ;;
			*) what="порт" ;;
		esac
		if [ "$p" = "$ssh_port" ]; then
			ssh_v=$v
			case $v in
				OK) ok "SSH :$p открывается из России ($ru_s) и Европы ($eu_s)" ;;
				RU_BLOCKED) bad "SSH :$p не открывается из России ($ru_s), а из Европы открывается ($eu_s): IP, похоже, заблокирован в России" ;;
				*) warn "SSH :$p: Россия — $ru_s; Европа — $eu_s" ;;
			esac
			continue
		fi
		if [ "$p" = 80 ]; then   # порт 80 нужен только Let's Encrypt, а он ходит не из России
			if [ "$eu_ok" -gt 0 ]; then ok ":80 ($what) открыт снаружи ($eu_s)"; elif [ "$eu_done" -gt 0 ]; then bad ":80 закрыт снаружи ($eu_s): сертификат не продлится — откройте TCP 80 в фаерволе хостера"; else warn ":80 — узлы не ответили"; fi
			continue
		fi
		case $v in
			OK) ok ":$p ($what) открывается из России ($ru_s) и Европы ($eu_s)" ;;
			RU_BLOCKED)
				if [ "$ssh_v" = RU_BLOCKED ]; then
					bad ":$p ($what) из России не открывается ($ru_s), как и SSH: IP заблокирован в России. Нужен другой IP — новый сервер и переезд из бэкапа (README.md в архиве)"
				else
					bad ":$p ($what) из России не открывается ($ru_s), хотя из Европы открывается ($eu_s), а SSH из России доступен: блокируют именно этот порт. Проверьте с телефона; если не работает — нужен другой IP"
				fi ;;
			CLOSED) bad ":$p ($what) закрыт снаружи — ни из России, ни из Европы ($eu_s): откройте TCP $p в фаерволе хостера (в его панели), проверьте ufw status и что служба работает" ;;
			PARTIAL) warn ":$p ($what) из России открывается не со всех узлов ($ru_s) — частичная блокировка или сбой узла; проверьте с телефона" ;;
			*) warn ":$p ($what): узлы не ответили вовремя (Россия — $ru_s; Европа — $eu_s)" ;;
		esac
	done < "$CHK_OUT"
}

# --- Проверка установленного VPN изнутри сервера ---
link_to_xray() {  # vless-ссылка → конфиг xray-клиента с socks на 127.0.0.1:$3, сервер — адрес $2
	python3 - "$1" "$2" "$3" <<'PY'
import json, sys, urllib.parse as up
link, addr, socks = sys.argv[1], sys.argv[2], int(sys.argv[3])
u = up.urlsplit(link)
q = {k: v[0] for k, v in up.parse_qs(u.query, keep_blank_values=True).items()}
net, sec = q.get("type", "tcp"), q.get("security", "none")
ss = {"network": net, "security": sec}
if sec == "reality":
    r = {"serverName": q.get("sni", ""), "fingerprint": q.get("fp") or "chrome",
         "publicKey": q.get("pbk", ""), "shortId": q.get("sid", ""), "spiderX": q.get("spx", "/")}
    if q.get("pqv"):
        r["mldsa65Verify"] = q["pqv"]
    ss["realitySettings"] = r
if net == "xhttp":
    x = {"path": q.get("path", "/"), "host": q.get("host", ""), "mode": q.get("mode", "auto")}
    if q.get("extra"):
        x["extra"] = json.loads(q["extra"])
    ss["xhttpSettings"] = x
user = {"id": up.unquote(u.username or ""), "encryption": q.get("encryption", "none"), "flow": q.get("flow", "")}
print(json.dumps({
    "log": {"loglevel": "warning"},
    "inbounds": [{"listen": "127.0.0.1", "port": socks, "protocol": "socks", "settings": {"udp": False}}],
    "outbounds": [{"protocol": "vless", "settings": {"vnext": [{"address": addr, "port": u.port, "users": [user]}]},
                   "streamSettings": ss}],
}, indent=1))
PY
}

tunnel_check() {  # tunnel_check ССЫЛКА → «код ip_выхода warp строка_лога» через временный xray-клиент
	local dir socks pid trace code=000 ip=- warp=-
	dir=$(mktemp -d)
	socks=10809
	while ss -Htln "sport = :$socks" | grep -q .; do socks=$((socks + 1)); done
	link_to_xray "$1" "$LISTEN_IP" "$socks" > "$dir/client.json"
	"$XRAY" run -c "$dir/client.json" > "$dir/client.log" 2>&1 &
	pid=$!
	if wait_port "127.0.0.1:$socks" 10; then
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -x "socks5h://127.0.0.1:$socks" https://www.gstatic.com/generate_204 || true)
		if [ "$code" = 204 ]; then
			trace=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:$socks" https://www.cloudflare.com/cdn-cgi/trace || true)
			ip=$(sed -n 's/^ip=//p' <<<"$trace"); ip=${ip:--}
			warp=$(sed -n 's/^warp=//p' <<<"$trace"); warp=${warp:--}
		fi
	fi
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	echo "$code $ip $warp $(tail -2 "$dir/client.log" | tr '\n' ' ')"
	rm -rf "$dir"
}

sub_list() {  # «подпись|subId» включённых клиентов; подпись — комментарий из панели или email
	sqlite3 -readonly -separator '|' "$DB" "select replace(coalesce(nullif(comment, ''), email), '|', '/'), sub_id from clients where enable=1 and sub_id<>'' order by id;"
}

sub_fetch() {  # sub_fetch SUBID → строки подписки (ссылки) с сервера подписок
	local raw
	if [ "$MODE" = domain ]; then
		raw=$(curl -s $K --max-time 15 --resolve "$DOMAIN:443:$LISTEN_IP" "https://$DOMAIN$SUB_PATH$1") || return 1
	else
		raw=$(curl -s --max-time 15 "http://127.0.0.1:$SUB_PORT$SUB_PATH$1") || return 1
	fi
	base64 -d <<<"$raw" 2>/dev/null || printf '%s\n' "$raw"
}

local_checks() {
	local s p code sid link exit_ip exit_warp log
	say "Проверка изнутри сервера"
	for s in x-ui $([ "$MODE" = domain ] && echo nginx) $([ -f "$F2B_JAIL" ] && echo fail2ban); do
		if systemctl is-active -q "$s"; then ok "служба $s работает"; else bad "служба $s не работает (journalctl -u $s)"; fi
	done
	for p in $([ "$MODE" = domain ] && echo "$LISTEN_IP:443 127.0.0.1:8443") "127.0.0.1:$WEB_PORT" "127.0.0.1:$SUB_PORT" ":$REALITY_PORT"; do
		if wait_port "$p" 15; then ok "слушает $p"; else bad "никто не слушает $p"; fi
	done
	if [ -f "$F2B_JAIL" ]; then
		if s=$(fail2ban-client status sshd 2>/dev/null); then
			ok "fail2ban охраняет SSH: сейчас в бане $(sed -n 's/.*Currently banned:[[:space:]]*//p' <<<"$s" | head -1), всего забанено $(sed -n 's/.*Total banned:[[:space:]]*//p' <<<"$s" | head -1)"
		else
			bad "fail2ban не отвечает по jail sshd (journalctl -u fail2ban)"
		fi
	fi
	if [ "$MODE" = domain ]; then
		if openssl x509 -checkend 604800 -noout -in "$CERT_DIR/fullchain.pem" >/dev/null 2>&1; then
			ok "сертификат действует до $(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" | cut -d= -f2)"
		else
			bad "сертификат $DOMAIN истёк или истекает меньше чем через неделю (продление: /root/.acme.sh/acme.sh --cron)"
		fi
		code=$(curl -s $K -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$DOMAIN:443:$LISTEN_IP" "https://$DOMAIN/" || true)
		if [ "$code" = 200 ]; then ok "сайт-заглушка https://$DOMAIN/ отвечает 200"; else bad "сайт-заглушка отвечает $code"; fi
		code=$(curl -s $K -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$DOMAIN:443:$LISTEN_IP" "https://$DOMAIN/$(rnd "$LOWER" 9)" || true)
		if [ "$code" = 404 ]; then ok "чужой путь — 404 сайта"; else bad "чужой путь отвечает $code (ждали 404)"; fi
		code=$(curl -s $K -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$DOMAIN:443:$LISTEN_IP" "https://$DOMAIN$WEB_PATH" || true)
		if [ "$code" = 200 ]; then ok "панель отвечает 200"; else bad "панель отвечает $code"; fi
		code=$(curl -s $K -o /dev/null -w '%{http_code}' --max-time 10 --resolve "other.example:443:$LISTEN_IP" "https://other.example/" || true)
		if [ "$code" = 000 ]; then ok "чужой SNI на :443 обрывается"; else bad "чужой SNI на :443 получил ответ $code"; fi
	else
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://127.0.0.1:$WEB_PORT$WEB_PATH" || true)
		if [ "$code" = 200 ]; then ok "панель отвечает 200 (на 127.0.0.1)"; else bad "панель отвечает $code"; fi
		# Кто прощупывает сервер без ключа, должен увидеть настоящий сайт с верным сертификатом.
		if timeout 10 openssl s_client -connect "$LISTEN_IP:$REALITY_PORT" -servername "$REALITY_SNI" -verify_hostname "$REALITY_SNI" \
			-verify_return_error < /dev/null 2>&1 | grep -q 'Verify return code: 0 (ok)'; then
			ok "чужим на :$REALITY_PORT отвечает настоящий $REALITY_SNI (сертификат верный)"
		else
			bad "проба :$REALITY_PORT с SNI $REALITY_SNI не получила настоящий сертификат сайта"
		fi
	fi
	sid=$(sqlite3 -readonly "$DB" "select sub_id from clients where enable=1 and sub_id<>'' order by id limit 1;" 2>/dev/null || true)
	link=$( { [ -n "$sid" ] && sub_fetch "$sid"; } | grep -m1 '^vless://' || true)
	if [ -n "$link" ]; then
		ok "подписка отдаёт ссылку"
		case $link in *"@$SHARE_ADDR:$REALITY_PORT"*) ok "в ссылке адрес $SHARE_ADDR:$REALITY_PORT" ;; *) bad "в ссылке не тот адрес: ${link%%\?*}" ;; esac
		read -r code exit_ip exit_warp log <<<"$(tunnel_check "$link")"
		if [ "$code" != 204 ]; then
			bad "туннель по ссылке клиента не работает (ответ $code): $log"
		elif [ "$exit_warp" = on ] || [ "$exit_warp" = plus ]; then
			ok "туннель по ссылке клиента работает, выход через Cloudflare WARP ($exit_ip)"
		else
			ok "туннель по ссылке клиента работает, выход с IP $exit_ip"
		fi
	else
		bad "подписка не отдала vless-ссылку — туннель не проверить"
	fi
}

verdict() {
	echo
	if [ "$FAILS" = 0 ]; then
		printf '\033[1;32mПроверка: всё OK.\033[0m\n'
	else
		printf '\033[1;31mПроверка: ошибок %s — см. выше.\033[0m\n' "$FAILS"
	fi
}

CHK_OUT=$(mktemp)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK" "$CHK_OUT"' EXIT

# --- Только проверка ---
if [ "$CHECK_ONLY" = 1 ]; then
	# shellcheck source=/dev/null
	. "$STATE"
	CERT_DIR=${DOMAIN:+/root/cert/$DOMAIN}
	K=
	[ -n "$DOMAIN" ] && ! openssl x509 -noout -issuer -in "$CERT_DIR/fullchain.pem" 2>/dev/null | grep -qi "let's encrypt" && K=-k
	detect_ips
	if [ "$MODE" = domain ]; then SHARE_ADDR=$DOMAIN; else SHARE_ADDR=$PUBLIC_IP; fi
	printf '\033[1mПроверка VPN на %s (%s)\033[0m\n' "${DOMAIN:-$PUBLIC_IP}" "$([ "$MODE" = domain ] && echo "с доменом" || echo "без домена, Reality под ${REALITY_SNI:-?}")"
	local_checks
	reach_check
	verdict
	exit $((FAILS > 0))
fi

touch "$LOG" && chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
START=$(date +%s)
if [ "$MODE" = domain ]; then
	printf '\033[1mУстановка VPN на %s (3x-ui %s, Xray %s, выход: %s)\033[0m\n' "$DOMAIN" "$XUI_VERSION" "$XRAY_VERSION" "$EXIT_MODE"
else
	printf '\033[1mУстановка VPN без домена (3x-ui %s, Xray %s, выход: %s)\033[0m\n' "$XUI_VERSION" "$XRAY_VERSION" "$EXIT_MODE"
fi

say "Проверка сервера"
OS_NOW=$(. /etc/os-release && echo "$ID $VERSION_ID|$PRETTY_NAME")
case ${OS_NOW%%|*} in
	"ubuntu 22.04" | "ubuntu 24.04" | "debian 12") ok "система ${OS_NOW#*|}" ;;
	*) warn "система ${OS_NOW#*|} не проверялась (рассчитано на Ubuntu 22.04/24.04 и Debian 12)" ;;
esac
[ "$CONTAINER" = 0 ] || warn "это контейнер: настройки ядра и swap будут пропущены"
APT=(apt-get -y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
# Сразу после первой загрузки apt часто занят автообновлениями — ждём, а не падаем.
for try in 1 2 3 4 5 6; do
	"${APT[@]}" update >/dev/null 2>&1 && break
	[ "$try" = 6 ] && die "apt-get update не прошёл (apt занят или нет сети): запустите скрипт ещё раз через пару минут"
	sleep 20
done
"${APT[@]}" install iproute2 curl ca-certificates python3 >/dev/null || die "не установились iproute2, curl, python3"
if [ "$MODE" = domain ]; then
	for p in 80 443; do
		u=$(port_users "$p")
		case $u in "" | "nginx ") ;; *) die "порт $p занят: $u— освободите его (на этом сервере не должно быть другого сайта)" ;; esac
	done
fi
u=$(port_users "$REALITY_PORT")
case $u in "" | xray* | x-ui*) ;; *) die "порт $REALITY_PORT занят: $u— освободите его (на этом сервере не должно быть другого сайта)" ;; esac
if [ "$MODE" = domain ]; then ok "порты 80, 443 и $REALITY_PORT свободны"; else ok "порт $REALITY_PORT свободен"; fi

detect_ips
if [ "$PUBLIC_IP" = "$LISTEN_IP" ]; then ok "IP сервера $PUBLIC_IP"; else ok "IP сервера $PUBLIC_IP (на интерфейсе $LISTEN_IP — сервер за NAT, так тоже работает)"; fi
ip_precheck

if [ "$MODE" = nodomain ]; then
	:
elif [ "$SKIP_DNS" = 1 ]; then
	warn "A-запись домена не проверялась (--skip-dns-check)"
else
	A=$(resolve "$DOMAIN" A) || die "не удалось проверить DNS (нет доступа к cloudflare-dns.com и dns.google)"
	if [ -z "$A" ]; then
		die "у $DOMAIN нет A-записи. Создайте её: $DOMAIN → $PUBLIC_IP (в Cloudflare — Proxy выключен, серое облако), подождите пару минут и запустите снова"
	fi
	case " $A " in
		*" $PUBLIC_IP "*) ok "A-запись $DOMAIN указывает на этот сервер" ;;
		*)
			first=${A%% *}
			if is_cloudflare_ip "$first"; then
				die "$DOMAIN смотрит на Cloudflare ($A): в Cloudflare у A-записи выключите Proxy (облако должно быть серым) и запустите снова"
			fi
			die "A-запись $DOMAIN указывает на $A, а IP этого сервера $PUBLIC_IP. Поправьте A-запись, подождите пару минут и запустите снова (или --skip-dns-check, если знаете, что делаете)"
			;;
	esac
	AAAA=$(resolve "$DOMAIN" AAAA || true)
	[ -z "$AAAA" ] || die "у $DOMAIN есть AAAA-запись ($AAAA): IPv6 на сервере выключается, а Let's Encrypt и клиенты пойдут по IPv6. Удалите AAAA-запись и запустите снова"
fi

say "Пакеты"
PKGS=(sqlite3 ufw cron openssl tar tzdata qrencode procps coreutils)
[ "$MODE" = domain ] && PKGS+=(nginx libnginx-mod-stream socat)
"${APT[@]}" install "${PKGS[@]}" >/dev/null || die "не установились пакеты: ${PKGS[*]}"
mkdir -p /etc/systemd/system /etc/sysctl.d /etc/cron.d
ok "${PKGS[*]}"
[ -e "/usr/share/zoneinfo/$TZ_NAME" ] || die "нет часового пояса $TZ_NAME (--tz Europe/Moscow)"

# --- Настройки: генерируются один раз и хранятся в $STATE, повторный запуск берёт те же ---
if [ -f "$STATE" ]; then
	# shellcheck source=/dev/null
	. "$STATE"
	ok "найдены настройки прошлой установки ($STATE): ключи, пароли и клиенты остаются прежними"
fi
: "${PANEL_USER:=$(rnd "$LOWER$DIGITS" 10)}"
: "${PANEL_PASS:=$(rnd "$LOWER${LOWER^^}$DIGITS" 22)}"
: "${WEB_PORT:=$(free_port)}"
: "${WEB_PATH:=/$(rnd "$LOWER${LOWER^^}$DIGITS" 18)/}"
: "${SUB_PATH:=/$(rnd "$LOWER" 8)/}"
: "${CLASH_PATH:=/$(rnd "$LOWER" 7)/}"
: "${JSON_PATH:=/$(rnd "$LOWER" 6)/}"
[ -n "$WEB_PORT" ] || die "не нашёлся свободный порт для панели"
save_state() {
	local tmp
	tmp=$(mktemp "$STATE.XXXXXX")
	cat > "$tmp" <<EOF
# install-vpn.sh: сгенерированные при установке настройки. Секретно: пароль панели и ключи Reality.
S_MODE='$MODE'
S_DOMAIN='$DOMAIN'
PANEL_USER='$PANEL_USER'
PANEL_PASS='$PANEL_PASS'
WEB_PORT='$WEB_PORT'
WEB_PATH='$WEB_PATH'
SUB_PATH='$SUB_PATH'
CLASH_PATH='$CLASH_PATH'
JSON_PATH='$JSON_PATH'
REALITY_PRIV='${REALITY_PRIV:-}'
REALITY_PUB='${REALITY_PUB:-}'
SHORT_IDS='${SHORT_IDS:-}'
REALITY_SNI='${REALITY_SNI:-}'
EOF
	chmod 600 "$tmp"
	mv "$tmp" "$STATE"
}
save_state

say "3x-ui $XUI_VERSION"
CUR=$("$XUI" -v 2>/dev/null | head -1 || true)
if [ "$CUR" = "$XUI_VERSION" ]; then
	ok "3x-ui $CUR уже установлен"
else
	TMP=$(mktemp -d)
	if [ -n "${XUI_TARBALL:-}" ]; then   # для проверки скрипта без скачивания: свой файл, sha256 сверяется так же
		cp "$XUI_TARBALL" "$TMP/x-ui.tgz"
	else
		URL=https://github.com/MHSanaei/3x-ui/releases/download/v$XUI_VERSION/x-ui-linux-$ARCH.tar.gz
		curl -fL --retry 3 --connect-timeout 20 -s -o "$TMP/x-ui.tgz" "$URL" || die "не скачался $URL"
	fi
	echo "$XUI_SHA256  $TMP/x-ui.tgz" | sha256sum -c --quiet - >/dev/null 2>&1 || die "архив 3x-ui не совпал по sha256 — скачан не тот файл"
	systemctl stop x-ui 2>/dev/null || true
	rm -rf /usr/local/x-ui
	tar -C /usr/local -xzf "$TMP/x-ui.tgz"
	rm -rf "$TMP"
	chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/x-ui.sh /usr/local/x-ui/bin/xray-linux-*
	chmod +x /usr/local/x-ui/bin/mtg-linux-* 2>/dev/null || true
	ok "3x-ui $XUI_VERSION установлен из релиза GitHub (sha256 сошлась)"
fi
install -m 755 /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
install -m 644 /usr/local/x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service
systemctl daemon-reload
"$XRAY" version 2>/dev/null | head -1 | grep -q "Xray $XRAY_VERSION" || warn "Xray не $XRAY_VERSION: $("$XRAY" version 2>/dev/null | head -1)"

# Пароль, порт и секретный путь панели — до первого запуска x-ui, чтобы она ни минуты не жила с admin/admin.
systemctl stop x-ui 2>/dev/null || true
mkdir -p /etc/x-ui
"$XUI" setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$WEB_PORT" -webBasePath "$WEB_PATH" -listenIP 127.0.0.1 >/dev/null ||
	die "x-ui setting не прошёл"
if [ "$MODE" = domain ]; then
	ok "панель: только 127.0.0.1:$WEB_PORT, снаружи — через nginx по секретному пути"
else
	ok "панель: только 127.0.0.1:$WEB_PORT, снаружи не видна (заходить через SSH-туннель)"
fi

if [ -z "${REALITY_PRIV:-}" ]; then
	KEYS=$("$XRAY" x25519)
	REALITY_PRIV=$(awk -F': *' '/^Private/ {print $2; exit}' <<<"$KEYS")
	REALITY_PUB=$(awk -F': *' '/Public/ {print $2; exit}' <<<"$KEYS")
	[ -n "$REALITY_PRIV" ] && [ -n "$REALITY_PUB" ] || die "xray не сгенерировал ключи Reality"
	# Восемь shortId разной длины (2…16 hex), как генерирует панель.
	SHORT_IDS=$(for n in $(shuf -e 1 2 3 4 5 6 7 8); do printf '%s,' "$(openssl rand -hex "$n")"; done)
	SHORT_IDS=${SHORT_IDS%,}
	save_state
	ok "ключи Reality сгенерированы"
else
	ok "ключи Reality — прежние"
fi
# Подпись ML-DSA-65 в Reality не включаем (в проверенной схеме её нет): с ней Reality работает,
# только пока цепочка сертификата target длиннее ~3,5 КБ, а у Let's Encrypt она бывает короче.

if [ "$MODE" = nodomain ]; then
	say "Сайт, под который маскируется Reality"
	if [ -n "${REALITY_SNI:-}" ]; then
		[ -z "$SNI_ARG" ] || [ "$SNI_ARG" = "$REALITY_SNI" ] ||
			warn "--sni $SNI_ARG не применён: уже выбран $REALITY_SNI, а смена сайта сломала бы ссылки у клиентов"
		if ms=$(sni_ms "$REALITY_SNI"); then ok "$REALITY_SNI (как в прошлый раз), рукопожатие $ms мс"; else warn "$REALITY_SNI сейчас не прошёл проверку TLS 1.3/h2 с этого сервера — если туннель не заработает, это причина"; fi
	elif [ -n "$SNI_ARG" ]; then
		ms=$(sni_ms "$SNI_ARG") || die "$SNI_ARG не годится: нужен сайт с TLS 1.3, X25519, HTTP/2 и верным сертификатом, не за Cloudflare"
		REALITY_SNI=$SNI_ARG
		ok "$REALITY_SNI (задан --sni), рукопожатие $ms мс"
	else
		: > "$WORK/sni"
		for d in $SNI_CANDIDATES; do
			if ms=$(sni_ms "$d"); then echo "$ms $d" >> "$WORK/sni"; fi
		done
		[ -s "$WORK/sni" ] || die "ни один сайт из списка не прошёл проверку с этого сервера (нет выхода в интернет на 443?). Укажите сайт сами: --sni www.example.com"
		sort -n "$WORK/sni" | head -3 | while read -r ms d; do echo "    $d — $ms мс"; done
		REALITY_SNI=$(sort -n "$WORK/sni" | awk 'NR == 1 {print $2}')
		ok "выбран $REALITY_SNI: самый быстрый с этого сервера из подходящих (TLS 1.3, X25519, HTTP/2)"
	fi
	save_state
fi

CERT_DIR=
if [ "$MODE" = domain ]; then
	say "nginx и сайт-заглушка"
	systemctl stop nginx 2>/dev/null || true
	mkdir -p /etc/nginx/conf.d /etc/nginx/stream-enabled /etc/systemd/system/nginx.service.d /var/www/acme /var/www/html
	cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
	worker_connections 768;
}

http {
	sendfile on;
	tcp_nopush on;
	types_hash_max_size 2048;
	server_tokens off;
	include /etc/nginx/mime.types;
	default_type application/octet-stream;
	ssl_protocols TLSv1.2 TLSv1.3;
	ssl_prefer_server_ciphers on;
	access_log /var/log/nginx/access.log;
	error_log /var/log/nginx/error.log;
	gzip on;
	include /etc/nginx/conf.d/*.conf;
	include /etc/nginx/sites-enabled/*;
}

stream {
	include /etc/nginx/stream-enabled/*.conf;
}
EOF
	rm -f /etc/nginx/sites-enabled/default
	cat > /etc/nginx/conf.d/acme-http.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/acme;
        default_type text/plain;
    }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
	cat > /etc/systemd/system/nginx.service.d/override.conf <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
EOF
	CERT_DIR=/root/cert/$DOMAIN
	if [ ! -s "$CERT_DIR/fullchain.pem" ]; then
		# Первый запуск: конфиги с сертификатом подключаются после его выпуска.
		rm -f /etc/nginx/conf.d/panel.conf /etc/nginx/stream-enabled/443-demux.conf
	fi

	python3 - "$DOMAIN" <<'PY'
# Сайт-заглушка: обычная личная страничка. Имя, цвет и записи случайные, чтобы такие серверы не были одинаковыми.
import datetime, os, random, sys
domain = sys.argv[1]
r = random.SystemRandom()
ini = r.choice("abdefgjklmnprstvz") + r.choice("aeiklmnorsty")
accent, accent_dark = r.choice([("#2f6f6a", "#6fb6ad"), ("#3b5b92", "#86a8e0"), ("#7a4b8c", "#c39ad3"),
                                ("#8a5a2b", "#d7a56f"), ("#2e6b3f", "#79bf8a"), ("#8c3b4a", "#d9879a")])
tagline = r.choice(["notes, reading & small self-hosted tools", "a few notes and side projects",
                    "home lab notes and small utilities", "notes on servers, backups and keeping it simple"])
pool = ["Keeping a home backup honest", "A tiny uptime check that emails me", "Notes on self-hosting without the fuss",
        "Why I stopped tweaking my dotfiles", "Moving a small site between servers", "What I learned running my own DNS",
        "A boring, reliable way to rotate logs", "Static pages are underrated", "Cron jobs I actually keep",
        "Reading list: autumn", "Making old laptops useful again", "Small scripts, fewer regrets"]
tools = [("snip", "A clipboard scratchpad that syncs between my own machines."),
         ("watchdog", "Pings a few services and nudges me when one goes quiet."),
         ("shelf", "Keeps track of the books I'm reading and the ones I gave up on."),
         ("tide", "A tiny dashboard for disk space on my machines."),
         ("relay", "Forwards a few notifications to my phone."),
         ("crate", "Packs and checks my backups every night.")]
today = datetime.date.today()
days = sorted(r.sample(range(9, 200), 4))
posts = "\n".join('    <li><a href="/">%s</a><time>%s</time></li>' % (t, (today - datetime.timedelta(days=d)).isoformat())
                  for t, d in zip(r.sample(pool, 4), days))
cards = "\n".join('    <div class="tool"><h3>%s</h3><p>%s</p></div>' % t for t in r.sample(tools, 2))
mail = r.choice(["hi", "hello", "mail"]) + "@" + domain
icon = ("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='7' fill='"
        + accent.replace("#", "%23") + "'/%3E%3Ctext x='16' y='22' font-family='monospace' font-size='18' fill='%23fff' text-anchor='middle'%3E"
        + ini + "%3C/text%3E%3C/svg%3E")
css_vars = "--bg:#fbfbfa;--fg:#1d2321;--muted:#5d6763;--line:#e6e6e3;--accent:%s;--card:#ffffff" % accent
css_dark = "--bg:#14181a;--fg:#e7eae8;--muted:#9aa5a1;--line:#262d2f;--accent:%s;--card:#191d20" % accent_dark
index = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%(ini)s · %(tagline)s</title>
<meta name="description" content="A personal homepage — notes and a few small self-hosted tools.">
<meta name="robots" content="noindex">
<link rel="icon" href="%(icon)s">
<style>
  :root{%(css_vars)s}
  @media (prefers-color-scheme: dark){:root{%(css_dark)s}}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;padding:0 20px}
  .wrap{max-width:680px;margin:0 auto;padding:72px 0 96px}
  header{display:flex;align-items:center;gap:14px;margin-bottom:40px}
  .logo{width:40px;height:40px;border-radius:10px;background:var(--accent);color:#fff;display:grid;place-items:center;font:700 18px/1 ui-monospace,SFMono-Regular,Menlo,monospace}
  h1{font-size:20px;margin:0} h1 span{display:block;font-weight:400;font-size:14px;color:var(--muted)}
  h2{font-size:14px;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);margin:44px 0 14px;font-weight:600}
  p{margin:0 0 16px} a{color:var(--accent);text-decoration:none} a:hover{text-decoration:underline}
  ul{list-style:none;padding:0;margin:0}
  .posts li{display:flex;justify-content:space-between;gap:16px;padding:10px 0;border-bottom:1px solid var(--line)}
  .posts time{color:var(--muted);font-variant-numeric:tabular-nums;white-space:nowrap;font-size:14px}
  .tools{display:grid;gap:12px;grid-template-columns:1fr 1fr} @media (max-width:520px){.tools{grid-template-columns:1fr}}
  .tool{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px}
  .tool h3{margin:0 0 4px;font-size:15px} .tool p{margin:0;color:var(--muted);font-size:14px}
  footer{margin-top:56px;padding-top:20px;border-top:1px solid var(--line);color:var(--muted);font-size:13px;display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="logo">%(ini)s</div>
    <h1>%(ini)s<span>%(tagline)s</span></h1>
  </header>
  <p>Hi — this is a small personal corner of the web. I keep a few notes here, mostly about
  home servers, backups and keeping things simple. Nothing fancy, and not much traffic.</p>
  <h2>Recent notes</h2>
  <ul class="posts">
%(posts)s
  </ul>
  <h2>Small tools</h2>
  <div class="tools">
%(cards)s
  </div>
  <h2>Elsewhere</h2>
  <p>Best way to reach me is email: <a href="mailto:%(mail)s">%(mail)s</a>.</p>
  <footer><span>© %(year)s %(ini)s</span><span>built by hand · no trackers</span></footer>
</div>
</body>
</html>
""" % dict(ini=ini, tagline=tagline, icon=icon, css_vars=css_vars, css_dark=css_dark, posts=posts, cards=cards, mail=mail, year=today.year)
notfound = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Not found · %(ini)s</title>
<meta name="robots" content="noindex">
<link rel="icon" href="%(icon)s">
<style>
  :root{--bg:#fbfbfa;--fg:#1d2321;--muted:#5d6763;--accent:%(accent)s}
  @media (prefers-color-scheme: dark){:root{--bg:#14181a;--fg:#e7eae8;--muted:#9aa5a1;--accent:%(accent_dark)s}}
  body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;text-align:center;padding:24px}
  .code{font:700 64px/1 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--accent);margin-bottom:8px}
  p{color:var(--muted);margin:0 0 20px} a{color:var(--accent)}
</style>
</head>
<body>
<div><div class="code">404</div><p>That page isn’t here.</p><a href="/">← back home</a></div>
</body>
</html>
""" % dict(ini=ini, icon=icon, accent=accent, accent_dark=accent_dark)
# Повторный запуск сайт не меняет: у настоящего сайта страница не должна меняться от каждой настройки.
for path, body in (("/var/www/html/index.html", index), ("/var/www/html/404.html", notfound)):
    if not os.path.exists(path):
        with open(path, "w") as f:
            f.write(body)
PY
	rm -f /var/www/html/index.nginx-debian.html
	systemctl daemon-reload
	nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx -t: ошибка в конфиге"; }
	systemctl enable nginx >/dev/null 2>&1 || true
	systemctl restart nginx || die "nginx не запустился (journalctl -u nginx)"
	ok "nginx на :80 (выпуск и продление сертификата), заглушка сайта в /var/www/html"

	say "Сертификат для $DOMAIN"
	install -d -m 700 /root/cert "$CERT_DIR"
	if [ "$TEST_SELFSIGNED" = 1 ]; then
		if [ ! -s "$CERT_DIR/fullchain.pem" ]; then
			openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 365 -subj "/CN=$DOMAIN" \
				-addext "subjectAltName=DNS:$DOMAIN" -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" >/dev/null 2>&1 ||
				die "не создался самоподписанный сертификат"
		fi
		warn "сертификат самоподписанный (--test-selfsigned): так только для проверки скрипта"
	else
		ACME=/root/.acme.sh/acme.sh
		if [ ! -x "$ACME" ]; then
			TMP=$(mktemp -d)
			curl -fsSL --retry 3 -o "$TMP/acme.sh" "https://raw.githubusercontent.com/acmesh-official/acme.sh/$ACME_TAG/acme.sh" ||
				die "не скачался acme.sh"
			echo "$ACME_SHA256  $TMP/acme.sh" | sha256sum -c --quiet - >/dev/null 2>&1 || die "acme.sh не совпал по sha256"
			(cd "$TMP" && sh ./acme.sh --install --home /root/.acme.sh --nocron --noprofile >/dev/null 2>&1) || die "acme.sh не установился"
			rm -rf "$TMP"
		fi
		CA=letsencrypt
		[ "$ACME_STAGING" = 1 ] && CA=letsencrypt_test
		"$ACME" --set-default-ca --server "$CA" >/dev/null 2>&1 || true
		"$ACME" --register-account --server "$CA" >/dev/null 2>&1 || true
		rc=0
		"$ACME" --issue -d "$DOMAIN" -w /var/www/acme --keylength ec-256 --server "$CA" > /root/.acme-issue.log 2>&1 || rc=$?
		case $rc in
			0) ok "Let's Encrypt выдал сертификат" ;;
			2) ok "сертификат уже выпущен, продлевать рано" ;;
			*)
				tail -15 /root/.acme-issue.log | sed 's/^/    /'
				die "Let's Encrypt не выдал сертификат. Частые причины: A-запись ещё не разошлась; порт 80 закрыт фаерволом хостера (откройте 80, 443 и $REALITY_PORT в панели хостера); в Cloudflare включён Proxy. Исправьте и запустите скрипт снова"
				;;
		esac
		rm -f /root/.acme-issue.log
		"$ACME" --install-cert -d "$DOMAIN" --ecc --key-file "$CERT_DIR/privkey.pem" --fullchain-file "$CERT_DIR/fullchain.pem" \
			--reloadcmd "systemctl reload nginx ; x-ui restart" >/dev/null 2>&1 || die "acme.sh --install-cert не прошёл"
		"$ACME" --upgrade --auto-upgrade >/dev/null 2>&1 || true
		CRON_LINE="$((RANDOM % 60)) $((RANDOM % 24)) * * * \"/root/.acme.sh\"/acme.sh --cron --home \"/root/.acme.sh\" > /dev/null"
		{ crontab -l 2>/dev/null || true; } | { grep -vF 'acme.sh --cron' || true; } > /root/.crontab.new
		echo "$CRON_LINE" >> /root/.crontab.new
		crontab /root/.crontab.new
		rm -f /root/.crontab.new
		ok "автопродление: acme.sh по cron, проверка через nginx :80"
	fi
	chmod 600 "$CERT_DIR/privkey.pem"
	ok "сертификат действует до $(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" | cut -d= -f2)"

	say "nginx: :443 — свой домен к сайту, панели и подписке, остальное сброс"
	cat > /etc/nginx/conf.d/panel.conf <<EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location $WEB_PATH {
        proxy_pass https://127.0.0.1:$WEB_PORT;
        proxy_ssl_server_name on;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }
    location $SUB_PATH { proxy_pass https://127.0.0.1:$SUB_PORT; proxy_ssl_server_name on; proxy_set_header Host \$host; proxy_set_header X-Forwarded-Proto https; }
    location $CLASH_PATH { proxy_pass https://127.0.0.1:$SUB_PORT; proxy_ssl_server_name on; proxy_set_header Host \$host; proxy_set_header X-Forwarded-Proto https; }
    location $JSON_PATH { proxy_pass https://127.0.0.1:$SUB_PORT; proxy_ssl_server_name on; proxy_set_header Host \$host; proxy_set_header X-Forwarded-Proto https; }
    location / {
        root /var/www/html;
        try_files \$uri \$uri/ =404;
    }
    error_page 404 /404.html;
    location = /404.html { root /var/www/html; internal; }
}
EOF
	# 127.0.0.1:443 никто не слушает: соединение с чужим SNI или без SNI сразу обрывается.
	cat > /etc/nginx/stream-enabled/443-demux.conf <<EOF
map \$ssl_preread_server_name \$backend_443 {
    $DOMAIN  127.0.0.1:8443;
    default            127.0.0.1:443;
}
server {
    listen $LISTEN_IP:443;
    ssl_preread on;
    proxy_pass \$backend_443;
    proxy_timeout 300s;
}
EOF
	nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx -t: ошибка в конфиге"; }
	systemctl reload nginx || systemctl restart nginx || die "nginx не перезапустился"
	ok "nginx: $LISTEN_IP:443 (демультиплексор по SNI) и 127.0.0.1:8443 (сайт, панель, подписка — target для Reality)"
fi

say "3x-ui: подписка, шаблон Xray, подключение VLESS + XHTTP + Reality"
xui_set() {  # xui_set КЛЮЧ=ЗНАЧЕНИЕ… — строки таблицы settings (x-ui должен быть остановлен)
	python3 - "$DB" "$@" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
for kv in sys.argv[2:]:
    k, v = kv.split("=", 1)
    if db.execute("update settings set value=? where key=?", (v, k)).rowcount == 0:
        db.execute("insert into settings(key, value) values(?, ?)", (k, v))
db.commit()
PY
}
template_json() {  # template_json РЕЖИМ ФАЙЛ_WARP|- → шаблон Xray (проверенная схема)
	python3 - "$1" "$2" <<'PY'
import json, sys
mode, warp_file = sys.argv[1], sys.argv[2]
warp = json.load(open(warp_file)) if warp_file != "-" else None
direct = {"protocol": "freedom", "settings": {"domainStrategy": "AsIs", "finalRules": [{"action": "allow"}]}, "tag": "direct"}
blocked = {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
rules = [{"inboundTag": ["api"], "outboundTag": "api", "type": "field"},
         {"ip": ["geoip:private"], "outboundTag": "blocked", "type": "field"},
         {"outboundTag": "blocked", "protocol": ["bittorrent"], "type": "field"}]
dns = ["1.1.1.1", "1.0.0.1"]
if warp:
    dns = [{"address": "localhost", "domains": ["full:engage.cloudflareclient.com"], "skipFallback": True}] + dns
if mode == "warp" and warp:
    outbounds, main, dns_out = [warp, direct, blocked], "warp", "warp"
elif mode == "warp-ru" and warp:
    outbounds, main, dns_out = [direct, warp, blocked], "direct", "warp"
    rules += [{"type": "field", "outboundTag": "warp", "domain": ["geosite:category-ru", "domain:ru", "domain:su", "domain:xn--p1ai"]},
              {"type": "field", "outboundTag": "warp", "ip": ["geoip:ru"]}]
else:
    outbounds, main, dns_out = [direct, blocked], "direct", "direct"
rules += [{"type": "field", "inboundTag": ["dns-internal"], "outboundTag": dns_out},
          {"type": "field", "network": "tcp,udp", "outboundTag": main}]
print(json.dumps({
    "log": {"access": "none", "dnsLog": False, "error": "", "loglevel": "warning", "maskAddress": ""},
    "routing": {"domainStrategy": "AsIs", "rules": rules},
    "inbounds": [{"listen": "127.0.0.1", "port": 62789, "protocol": "tunnel", "settings": {"rewriteAddress": "127.0.0.1"}, "tag": "api"}],
    "outbounds": outbounds,
    "policy": {"levels": {"0": {"statsUserDownlink": True, "statsUserOnline": True, "statsUserUplink": True}},
               "system": {"statsInboundDownlink": True, "statsInboundUplink": True, "statsOutboundDownlink": False, "statsOutboundUplink": False}},
    "api": {"services": ["HandlerService", "LoggerService", "StatsService", "RoutingService"], "tag": "api"},
    "stats": {},
    "metrics": {"listen": "127.0.0.1:11111", "tag": "metrics_out"},
    "dns": {"servers": dns, "queryStrategy": "UseIP", "tag": "dns-internal"},
}, ensure_ascii=False))
PY
}
current_warp() {  # outbound warp из нынешнего шаблона (повторный запуск не регистрирует WARP заново)
	python3 - "$DB" "$1" <<'PY'
import json, sqlite3, sys
row = sqlite3.connect(sys.argv[1]).execute("select value from settings where key='xrayTemplateConfig'").fetchone()
t = json.loads(row[0]) if row and row[0] else {}
w = next((o for o in t.get("outbounds", []) if o.get("tag") == "warp"), None)
if not w:
    sys.exit(1)
json.dump(w, open(sys.argv[2], "w"))
PY
}
systemctl stop x-ui 2>/dev/null || true
COMMON_SETTINGS=("subEnable=true" "subListen=127.0.0.1" "subPort=$SUB_PORT" "subPath=$SUB_PATH" "subDomain="
	"subUpdates=1" "subEncrypt=true" "subShowInfo=true" "subEmailInRemark=true" "subEnableRouting=true"
	"subJsonEnable=false" "subJsonPath=$JSON_PATH" "subClashPath=$CLASH_PATH"
	"remarkModel=-ieo" "timeLocation=Local" "trustedProxyCIDRs=127.0.0.1/32,::1/128" "webDomain=")
if [ "$MODE" = domain ]; then
	xui_set "${COMMON_SETTINGS[@]}" "webCertFile=$CERT_DIR/fullchain.pem" "webKeyFile=$CERT_DIR/privkey.pem" \
		"subCertFile=$CERT_DIR/fullchain.pem" "subKeyFile=$CERT_DIR/privkey.pem" "subURI=https://$DOMAIN$SUB_PATH" \
		"subClashEnable=true" "subClashURI=https://$DOMAIN$CLASH_PATH" "subJsonURI=https://$DOMAIN$JSON_PATH"
	SCHEME=https
	SHARE_ADDR=$DOMAIN
else
	# Без домена панель и подписка — только на 127.0.0.1 без TLS: снаружи их не видно,
	# подписку скрипт читает сам, чтобы выдать готовые ссылки.
	xui_set "${COMMON_SETTINGS[@]}" "webCertFile=" "webKeyFile=" "subCertFile=" "subKeyFile=" "subURI=" \
		"subClashEnable=false" "subClashURI=" "subJsonURI="
	SCHEME=http
	SHARE_ADDR=$PUBLIC_IP
	# Повторный запуск после смены IP сервера: ссылки должны вести на нынешний адрес.
	sqlite3 "$DB" "update inbounds set share_addr='$PUBLIC_IP' where port=$REALITY_PORT and share_addr_strategy='custom' and share_addr<>'$PUBLIC_IP';" 2>/dev/null || true
fi
HAVE_WARP=0
if [ "$EXIT_MODE" != direct ] && current_warp "$WORK/warp.json"; then HAVE_WARP=1; fi
if [ "$HAVE_WARP" = 1 ]; then
	xui_set "xrayTemplateConfig=$(template_json "$EXIT_MODE" "$WORK/warp.json")"
else
	xui_set "xrayTemplateConfig=$(template_json direct -)"
fi
systemctl enable x-ui >/dev/null 2>&1 || true
systemctl restart x-ui || die "x-ui не запустился (journalctl -u x-ui)"
wait_port "127.0.0.1:$WEB_PORT" 40 || die "панель x-ui не поднялась на 127.0.0.1:$WEB_PORT (journalctl -u x-ui)"

# API панели — по одноразовому токену, после настройки токен удаляется.
TOKEN_OUT=$("$XUI" setting -getApiToken 2>&1 || true)
API_TOKEN=$(sed -n 's/^apiToken: *//p' <<<"$TOKEN_OUT" | tail -1)
[ -n "$API_TOKEN" ] || die "x-ui не выдал API-токен: $TOKEN_OUT"
TOKEN_ID=$(sqlite3 "$DB" 'select max(id) from api_tokens;')
api() {  # api POST|GET ПУТЬ [аргументы curl] → тело ответа
	local m=$1 p=$2
	shift 2
	curl -sk --max-time 60 -X "$m" -H "Authorization: Bearer $API_TOKEN" "$@" "$SCHEME://127.0.0.1:$WEB_PORT${WEB_PATH}panel/api/$p"
}
api_ok() { python3 -c 'import json, sys; d = json.load(sys.stdin); sys.exit(0 if d.get("success") else 1)' 2>/dev/null; }

INBOUND_ID=$(sqlite3 "$DB" "select id from inbounds where port=$REALITY_PORT limit 1;")
if [ -n "$INBOUND_ID" ]; then
	ok "подключение на :$REALITY_PORT уже есть (#$INBOUND_ID), клиенты прежние"
else
	if [ "$MODE" = domain ]; then TARGET=127.0.0.1:8443; SNI=$DOMAIN; else TARGET=$REALITY_SNI:443; SNI=$REALITY_SNI; fi
	python3 - "$WORK/inbound.json" "$SNI" "$TARGET" "$SHARE_ADDR" "$REALITY_PORT" "$CLIENTS" "$REALITY_PRIV" "$REALITY_PUB" "$SHORT_IDS" <<'PY'
import json, secrets, string, sys, uuid
out, sni, target, share, port, n, priv, pub, sids = sys.argv[1:10]
alnum = string.ascii_lowercase + string.digits
clients = [{"id": str(uuid.uuid4()), "flow": "", "email": "".join(secrets.choice(alnum) for _ in range(10)),
            "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": True, "tgId": 0,
            "subId": "".join(secrets.choice(alnum) for _ in range(16)), "comment": "client-%d" % (i + 1), "reset": 0}
           for i in range(int(n))]
stream = {
    "network": "xhttp",
    "xhttpSettings": {"path": "/", "host": "", "mode": "auto", "xPaddingBytes": "100-1000",
                      "scMaxEachPostBytes": "1000000", "scMaxBufferedPosts": 30, "scStreamUpServerSecs": "20-80",
                      "xmux": {"maxConcurrency": "16-32", "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-3000"}},
    "security": "reality",
    "realitySettings": {"show": False, "xver": 0, "target": target, "serverNames": [sni],
                        "privateKey": priv, "minClientVer": "", "maxClientVer": "", "maxTimediff": 0,
                        "shortIds": sids.split(","), "mldsa65Seed": "",
                        "settings": {"publicKey": pub, "fingerprint": "chrome", "serverName": "", "spiderX": "",
                                     "mldsa65Verify": ""}},
}
json.dump({"up": 0, "down": 0, "total": 0, "remark": "", "enable": True, "expiryTime": 0, "trafficReset": "never",
           "listen": "", "port": int(port), "protocol": "vless",
           "settings": json.dumps({"clients": clients, "decryption": "none", "encryption": "none"}),
           "streamSettings": json.dumps(stream), "sniffing": json.dumps({"enabled": False}),
           "shareAddrStrategy": "custom", "shareAddr": share, "subSortIndex": 1}, open(out, "w"))
PY
	RESP=$(api POST inbounds/add -H 'Content-Type: application/json' --data-binary @"$WORK/inbound.json")
	api_ok <<<"$RESP" || die "панель не приняла подключение: $RESP"
	INBOUND_ID=$(sqlite3 "$DB" "select id from inbounds where port=$REALITY_PORT limit 1;")
	if [ "$MODE" = domain ]; then
		ok "подключение VLESS + XHTTP + Reality на :$REALITY_PORT, клиентов: $CLIENTS"
	else
		ok "подключение VLESS + XHTTP + Reality на :$REALITY_PORT под $REALITY_SNI, клиентов: $CLIENTS"
	fi
fi

if [ "$EXIT_MODE" != direct ] && [ "$HAVE_WARP" = 0 ]; then
	# Регистрация WARP — та же, что у кнопки WARP в панели; ключи WireGuard в обычном base64.
	openssl genpkey -algorithm X25519 -outform DER -out "$WORK/wg.der" 2>/dev/null
	WG_PRIV=$(tail -c 32 "$WORK/wg.der" | base64)
	WG_PUB=$(openssl pkey -inform DER -in "$WORK/wg.der" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)
	RESP=$(api POST xray/warp/reg --data-urlencode "privateKey=$WG_PRIV" --data-urlencode "publicKey=$WG_PUB")
	printf '%s' "$RESP" > "$WORK/warp-reg.json"
	if python3 - "$WORK/warp.json" "$WG_PRIV" "$WARP_ENDPOINT" "$WORK/warp-reg.json" <<'PY'; then
import base64, json, sys
out, priv, endpoint, reg = sys.argv[1:5]
d = json.load(open(reg))
if not d.get("success"):
    sys.exit(1)
cfg = json.loads(d["obj"])["config"]["config"]
addr = cfg["interface"]["addresses"]
reserved = list(base64.b64decode(cfg["client_id"]))
json.dump({"tag": "warp", "protocol": "wireguard", "settings": {
    "mtu": 1420, "secretKey": priv,
    "address": [a for a in (addr.get("v4") and addr["v4"] + "/32", addr.get("v6") and addr["v6"] + "/128") if a],
    "reserved": reserved, "domainStrategy": "ForceIPv4v6",
    "peers": [{"publicKey": cfg["peers"][0]["public_key"], "endpoint": endpoint, "keepAlive": 10}],
    "noKernelTun": True}}, open(out, "w"))
PY
		HAVE_WARP=1
		ok "Cloudflare WARP зарегистрирован (бесплатный аккаунт)"
	else
		bad "WARP не зарегистрировался — выход остаётся напрямую с IP сервера. Ответ: $(head -c 300 <<<"$RESP")"
		EXIT_MODE=direct
	fi
	if [ "$HAVE_WARP" = 1 ]; then
		systemctl stop x-ui
		xui_set "xrayTemplateConfig=$(template_json "$EXIT_MODE" "$WORK/warp.json")"
	fi
fi
sqlite3 "$DB" "delete from api_tokens where id=${TOKEN_ID:-0};" 2>/dev/null || true
systemctl restart x-ui || bad "x-ui не перезапустился (journalctl -u x-ui)"
case $EXIT_MODE in
	direct) ok "выход клиентов в интернет — напрямую с IP сервера $PUBLIC_IP" ;;
	warp) ok "выход клиентов — через Cloudflare WARP (IP сервера сайтам не виден)" ;;
	warp-ru) ok "выход: российские сайты — через WARP, остальное — напрямую с $PUBLIC_IP" ;;
esac

say "Ядро, swap, часовой пояс"
cat > /etc/sysctl.d/99-vpn.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv4.ip_nonlocal_bind=1
EOF
if [ "$CONTAINER" = 1 ]; then
	warn "контейнер: /etc/sysctl.d/99-vpn.conf записан, но не применён"
else
	modprobe tcp_bbr 2>/dev/null || true
	if sysctl -p /etc/sysctl.d/99-vpn.conf >/dev/null 2>&1; then
		ok "BBR ($(sysctl -n net.ipv4.tcp_congestion_control)), IPv6 выключен"
	else
		warn "часть настроек ядра не применилась (бывает на OpenVZ/LXC-серверах) — VPN это не мешает"
	fi
fi
if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
	ok "swap уже есть"
elif [ "$CONTAINER" = 1 ]; then
	warn "контейнер: swap пропущен"
elif [ "$(df -Pm / | awk 'NR==2 {print $4}')" -lt 4096 ]; then
	warn "на диске меньше 4 ГБ свободно — swap не создаю"
else
	{ fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; } &&
		chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile &&
		{ grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab; } &&
		ok "swap 2 ГБ" || warn "swap не создался"
fi
# Не через timedatectl: в контейнере он сдвигает часы хоста.
ln -sfn "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime && echo "$TZ_NAME" > /etc/timezone
ok "часовой пояс $TZ_NAME (по нему cron запускает бэкап$([ "$MODE" = domain ] && echo " и продление сертификата"))"

say "SSH"
if ! command -v sshd >/dev/null; then
	warn "sshd не установлен — пропущено"
elif [ "$SSH_KEY_ONLY" = 1 ]; then
	if [ -s /root/.ssh/authorized_keys ]; then
		mkdir -p /etc/ssh/sshd_config.d
		cat > /etc/ssh/sshd_config.d/00-disable-password.conf <<'EOF'
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
EOF
		if sshd -t; then
			systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
			ok "вход по паролю выключен, root — только по ключу"
		else
			rm -f /etc/ssh/sshd_config.d/00-disable-password.conf
			bad "sshd -t не прошёл — вход по паролю оставлен"
		fi
	else
		warn "у root нет ключа в /root/.ssh/authorized_keys — вход по паролю оставлен, иначе вы потеряете доступ"
	fi
else
	warn "вход по паролю не трогали. Безопаснее: добавить свой SSH-ключ и запустить скрипт с --ssh-key-only"
fi
SSH_PORTS=$(ssh_ports)
SSH_PORT=${SSH_PORTS%% *}

say "fail2ban: бан за подбор пароля SSH"
if [ "$DO_F2B" = 0 ]; then
	warn "пропущено (--no-fail2ban)"
elif ! command -v sshd >/dev/null; then
	warn "sshd не установлен — защищать нечего"
elif ! "${APT[@]}" install fail2ban python3-systemd >/dev/null; then
	bad "fail2ban не установился"
else
	CLIENT_IP=${SSH_CONNECTION:-}   # пусто, если зашли не по SSH или через sudo -i (sudo её сбрасывает)
	CLIENT_IP=${CLIENT_IP%% *}
	[[ $CLIENT_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || CLIENT_IP=
	mkdir -p /etc/fail2ban/jail.d
	{
		echo "# install-vpn.sh: 5 неудачных входов по SSH за 10 минут — бан на час, повторно — дольше (до недели)."
		echo "# Адрес, с которого ставили VPN, в исключениях: чтобы не запереть самого себя опечаткой в пароле."
		echo "[sshd]"
		echo "enabled = true"
		echo "port = $(echo $SSH_PORTS | tr ' ' ',')"
		# Debian 12 по умолчанию без rsyslog: файла /var/log/auth.log нет, входы SSH — только в журнале systemd.
		[ -f /var/log/auth.log ] || echo "backend = systemd"
		echo "maxretry = 5"
		echo "findtime = 10m"
		echo "bantime = 1h"
		echo "bantime.increment = true"
		echo "bantime.maxtime = 1w"
		echo "ignoreip = 127.0.0.1/8 ::1${CLIENT_IP:+ $CLIENT_IP}"
	} > "$F2B_JAIL"
	systemctl enable fail2ban >/dev/null 2>&1 || true
	systemctl restart fail2ban || true
	f2b_ok=0
	for _ in $(seq 1 15); do
		if fail2ban-client status sshd >/dev/null 2>&1; then f2b_ok=1; break; fi
		sleep 1
	done
	if [ "$f2b_ok" = 1 ]; then
		ok "fail2ban следит за SSH :$(echo $SSH_PORTS | tr ' ' ','): 5 неудачных входов за 10 мин — бан на 1 ч, повторно — дольше"
		[ -z "$CLIENT_IP" ] || ok "ваш адрес $CLIENT_IP — в исключениях fail2ban"
	else
		bad "fail2ban не запустился (journalctl -u fail2ban)"
	fi
fi

say "Фаервол ufw"
if [ "$DO_UFW" = 1 ]; then
	OPEN=$( {
		for p in $SSH_PORTS; do echo "$p/tcp"; done
		[ -n "${SSH_CONNECTION:-}" ] && echo "${SSH_CONNECTION##* }/tcp"
		if [ "$MODE" = domain ]; then echo 80/tcp; echo 443/tcp; fi
		echo "$REALITY_PORT/tcp"
	} | sort -u -t/ -k1,1n)
	for p in $OPEN; do ufw allow "$p" >/dev/null || bad "ufw allow $p не прошёл"; done
	if ufw --force enable >/dev/null 2>&1; then ok "включён, открыто: $(echo $OPEN)"; else bad "ufw не включился (ufw status)"; fi
else
	warn "фаервол не трогали (--no-ufw)"
fi

say "Ежедневный бэкап и команда проверки"
install -d -m 755 /usr/local/lib/vpn-backup
cat > /usr/local/bin/vpn-backup.sh <<'VPN_KIT_EOF_0'
#!/bin/bash
# vpn-backup.sh — полный бэкап VPN-сервера для переезда: база 3x-ui (клиенты, ключи Reality,
# настройки панели), nginx, сертификат домена и acme.sh, настройки ядра, SSH, служба, cron,
# вотчдог выхода (если стоит), установщик для друзей и скрипт для мака.
# Из архива restore.sh поднимает такую же копию на чистом сервере (см. README.md в архиве).
#
# Архивы: /root/backups/vpn-backup-<домен>-<дата>.tgz, ссылка latest.tgz, хранится KEEP штук.
# Запуск: vpn-backup.sh (ежедневно из /etc/cron.d/vpn-backup). Последняя строка вывода — путь к архиву.
set -euo pipefail
umask 077

BACKUP_DIR=${BACKUP_DIR:-/root/backups}
KEEP=${KEEP:-14}
KIT_DIR=/usr/local/lib/vpn-backup   # restore.sh и README.md — кладутся в каждый архив
DB=/etc/x-ui/x-ui.db

die() { echo "vpn-backup: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "нужен root"
[ -f "$DB" ] || die "нет базы $DB"
for f in restore.sh README.md; do [ -f "$KIT_DIR/$f" ] || die "нет $KIT_DIR/$f"; done
command -v sqlite3 >/dev/null || die "нет sqlite3 (apt-get install sqlite3)"

setting() { sqlite3 -readonly "$DB" "select value from settings where key='$1';"; }

# Домен — из пути к сертификату панели: /root/cert/<домен>/fullchain.pem. Нет сертификата —
# сервер поставлен без домена (Reality под чужой сайт), архив тогда называется по IP.
CERT_FILE=$(setting webCertFile)
DOMAIN=
if [ -n "$CERT_FILE" ]; then
	DOMAIN=$(basename "$(dirname "$CERT_FILE")")
	case $DOMAIN in . | /) die "не удалось определить домен по webCertFile ($CERT_FILE)" ;; esac
fi

SRC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
PUBLIC_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "$SRC_IP")
TS=$(date +%Y%m%d-%H%M%S)
NAME=vpn-backup-${DOMAIN:-ip-$PUBLIC_IP}-$TS
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
WORK=$(mktemp -d "$BACKUP_DIR/.work.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
B=$WORK/$NAME
F=$B/files          # копия файлов с полными путями: files/etc/x-ui/x-ui.db и т. д.
mkdir -p "$F/etc/x-ui" "$B/info"

# База: снимок через SQLite backup API — целостный даже на работающей панели (WAL учитывается).
sqlite3 "$DB" ".backup '$F/etc/x-ui/x-ui.db'"
[ "$(sqlite3 "$F/etc/x-ui/x-ui.db" 'pragma integrity_check;')" = ok ] || die "снимок базы не прошёл integrity_check"
sqlite3 "$F/etc/x-ui/x-ui.db" .dump > "$B/info/x-ui.sql"

keep() {  # копирует существующие пути в files/ с сохранением структуры и прав
	local p
	for p in "$@"; do
		[ -e "$p" ] && cp -a --parents "$p" "$F/"
	done
	return 0
}
keep /etc/x-ui/warp /etc/x-ui/install-result.env /etc/default/x-ui \
	/etc/systemd/system/x-ui.service /usr/bin/x-ui \
	/etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/stream-enabled /etc/nginx/sites-enabled \
	/var/www/html \
	/etc/systemd/system/nginx.service.d \
	${DOMAIN:+"/root/cert/$DOMAIN"} /root/.acme.sh \
	/etc/sysctl.d/99-vpn.conf /etc/sysctl.conf \
	/etc/ssh/sshd_config.d /root/.ssh/authorized_keys \
	/usr/local/bin/vpn-backup.sh /etc/cron.d/vpn-backup \
	/usr/local/bin/vpn-exit-watchdog.sh /etc/systemd/system/vpn-exit-watchdog.service \
	"$KIT_DIR/install-vpn.sh" "$KIT_DIR/mac" /usr/local/bin/vpn-check /etc/vpn-install.env \
	/etc/fail2ban/jail.d/vpn-sshd.local \
	/etc/ufw/user.rules /etc/ufw/user6.rules

# В acme.sh не берём сертификаты «на IP» (каталоги вида 1.2.3.4_ecc): они привязаны к старым адресам.
if [ -d "$F/root/.acme.sh" ]; then
	find "$F/root/.acme.sh" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
		-regex '.*/[0-9]{1,3}(\.[0-9]{1,3}){3}(_ecc)?' -exec rm -rf {} +
fi

# Справка для сверки (restore.sh отсюда берёт только строку cron acme.sh).
crontab -l > "$B/info/crontab-root.txt" 2>/dev/null || :
ufw status verbose > "$B/info/ufw-status.txt" 2>&1 || :
cp /usr/local/x-ui/bin/config.json "$B/info/xray-config.json" 2>/dev/null || :
dpkg-query -W -f='${Package} ${Version}\n' > "$B/info/packages.txt" 2>/dev/null || :
ss -tulpn > "$B/info/listening.txt" 2>&1 || :
{ ip -4 addr; ip -4 route; } > "$B/info/network.txt" 2>&1 || :
{ cat /etc/fstab; echo; swapon --show; echo; free -m; } > "$B/info/fstab-swap.txt" 2>&1 || :
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv6.conf.all.disable_ipv6 \
	net.ipv4.ip_nonlocal_bind vm.swappiness > "$B/info/sysctl.txt" 2>&1 || :

XRAY_BIN=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -1)
cat > "$B/manifest.env" <<EOF
CREATED='$(date -Iseconds)'
SRC_HOST='$(hostname -f 2>/dev/null || hostname)'
SRC_IP='$SRC_IP'
SRC_PUBLIC_IP='$PUBLIC_IP'
DOMAIN='$DOMAIN'
XUI_VERSION='$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1)'
XRAY_VERSION='$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}')'
ARCH='$(dpkg --print-architecture 2>/dev/null || uname -m)'
XUI_SHA256='$(sha256sum /usr/local/x-ui/x-ui | cut -d' ' -f1)'
XRAY_SHA256='$(sha256sum "$XRAY_BIN" | cut -d' ' -f1)'
TIMEZONE='$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)'
OS='$(. /etc/os-release && echo "$PRETTY_NAME")'
SSH_PORT='$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')'
EOF

python3 - "$F/etc/x-ui/x-ui.db" "$DOMAIN" "$PUBLIC_IP" > "$B/info/summary.txt" <<'PY'
import json, os, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
domain, ip = sys.argv[2], sys.argv[3]
st = dict(db.execute("select key, value from settings"))
if domain:
    print("Панель:   https://%s%s" % (domain, st.get("webBasePath", "/")))
    print("Подписка: https://%s%s<subId>" % (domain, st.get("subPath", "/sub/")))
else:
    print("Сервер без домена, ссылки клиентов ведут на IP %s" % ip)
    print("Панель:   через SSH-туннель — ssh -N -L %s:127.0.0.1:%s root@%s, потом http://127.0.0.1:%s%s" % (
        st.get("webPort"), st.get("webPort"), ip, st.get("webPort"), st.get("webBasePath", "/")))
print()
for iid, remark, port, listen, proto, enable, ss in db.execute(
        "select id, remark, port, listen, protocol, enable, stream_settings from inbounds order by id"):
    try:
        s = json.loads(ss or "{}")
    except ValueError:
        s = {}
    r = s.get("realitySettings") or {}
    sni = ",".join(r.get("serverNames") or []) or (s.get("tlsSettings") or {}).get("serverName", "")
    try:
        n = db.execute("select count(*) from client_inbounds where inbound_id=?", (iid,)).fetchone()[0]
    except sqlite3.Error:
        n = "?"
    print("Inbound #%s %s: %s порт %s, %s/%s, sni %s, клиентов %s%s" % (
        iid, remark or "", proto, port, s.get("network"), s.get("security"), sni or "-", n,
        "" if enable else " (выключен)"))
try:
    total, on = db.execute("select count(*), coalesce(sum(enable), 0) from clients").fetchone()
    print("Клиентов всего %s, включено %s" % (total, on))
except sqlite3.Error:
    pass
try:
    t = json.loads(st.get("xrayTemplateConfig") or "{}")
except ValueError:
    t = {}
rules = (t.get("routing") or {}).get("rules") or []
main = next((r.get("outboundTag") for r in rules if r.get("network") == "tcp,udp"), None)
obs = t.get("outbounds") or []
main = main or (obs[0].get("tag") if obs else "direct (шаблон по умолчанию)")
print("Выход клиентов: outbound %s" % main)
for o in obs:
    if o.get("protocol") in ("vless", "vmess", "trojan"):
        v = ((o.get("settings") or {}).get("vnext") or [{}])[0]
        wd = os.path.exists("/etc/systemd/system/vpn-exit-watchdog.service")
        print("  цепочка: outbound %s -> %s:%s%s" % (
            o.get("tag"), v.get("address"), v.get("port"),
            " (если выход недоступен, вотчдог переключает на WARP)" if wd else ""))
PY
if [ -n "$DOMAIN" ]; then
	{
		printf 'Сертификат %s: ' "$DOMAIN"
		openssl x509 -in "/root/cert/$DOMAIN/fullchain.pem" -noout -enddate 2>/dev/null || echo "нет"
	} >> "$B/info/summary.txt"
fi

cp "$KIT_DIR/restore.sh" "$KIT_DIR/README.md" "$B/"
chmod 700 "$B/restore.sh"
(cd "$B" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)

OUT=$BACKUP_DIR/$NAME.tgz
tar -C "$WORK" -czf "$OUT.part" "$NAME"
mv "$OUT.part" "$OUT"
chmod 600 "$OUT"
ln -sfn "$NAME.tgz" "$BACKUP_DIR/latest.tgz"

# Ротация: оставить KEEP последних архивов.
ls -1t "$BACKUP_DIR"/vpn-backup-*.tgz | tail -n +$((KEEP + 1)) | while IFS= read -r old; do rm -f -- "$old"; done

echo "$OUT"
VPN_KIT_EOF_0
chmod 755 /usr/local/bin/vpn-backup.sh
cat > /usr/local/lib/vpn-backup/restore.sh <<'VPN_KIT_EOF_1'
#!/bin/bash
# restore.sh — поднимает копию VPN-сервера из этого архива на чистом Ubuntu/Debian и проверяет её.
#   tar xzf vpn-backup-*.tgz && bash vpn-backup-*/restore.sh
# Сервер с доменом переезжает незаметно для клиентов (меняется A-запись); сервер без домена —
# с новым IP в ссылках: restore.sh в конце печатает новые ссылки, их раздают клиентам заново.
# Опции:
#   --listen-ip IP       IP для nginx :443 (по умолчанию — адрес основного интерфейса)
#   --xui-version VER    версия 3x-ui (по умолчанию как на старом сервере; latest — последняя)
#   --keep-password-ssh  не выключать вход по паролю
#   --no-ufw             не трогать фаервол
#   --verify             только проверить уже восстановленный сервер
set -euo pipefail
umask 022
export LC_ALL=C.UTF-8 LANG=C.UTF-8   # ssh с мака передаёт ru_RU.UTF-8, которой на сервере обычно нет

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
F=$HERE/files
# shellcheck source=/dev/null
. "$HERE/manifest.env"
# Сервер без домена (Reality под чужой сайт): нет сертификата и nginx, ссылки клиентов ведут на IP сервера.
DOMAIN=${DOMAIN:-}
HAS_NGINX=0
if [ -f "$F/etc/nginx/nginx.conf" ]; then HAS_NGINX=1; fi
LABEL=${DOMAIN:-"сервера без домена ($SRC_PUBLIC_IP)"}
CURL_K=
if [ "${VPN_TEST_INSECURE:-0}" = 1 ]; then CURL_K=-k; fi   # только для проверки скрипта на стенде с самоподписанным сертификатом

LISTEN_IP=
XUI_WANT=$XUI_VERSION
HARDEN_SSH=1
DO_UFW=1
VERIFY_ONLY=0
while [ $# -gt 0 ]; do
	case $1 in
		--listen-ip) LISTEN_IP=$2; shift 2 ;;
		--xui-version) XUI_WANT=${2#v}; shift 2 ;;
		--keep-password-ssh) HARDEN_SSH=0; shift ;;
		--no-ufw) DO_UFW=0; shift ;;
		--verify) VERIFY_ONLY=1; shift ;;
		-h | --help) awk 'NR > 1 && /^#/ {sub(/^# ?/, ""); print; next} NR > 1 {exit}' "$0"; exit 0 ;;
		*) echo "неизвестная опция: $1" >&2; exit 2 ;;
	esac
done

FAILS=0
say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok() { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mВНИМ.\033[0m %s\n' "$*"; }
bad() { printf '  \033[31mОШИБКА\033[0m %s\n' "$*"; FAILS=$((FAILS + 1)); }
die() { printf '\n\033[31mОстановлено: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "запускать от root"
command -v apt-get >/dev/null || die "нужен Debian/Ubuntu (apt-get)"
case $(uname -m) in
	x86_64 | amd64) ARCH_NEW=amd64 ;;
	aarch64 | arm64) ARCH_NEW=arm64 ;;
	*) die "архитектура $(uname -m) скриптом не поддержана" ;;
esac
DB=/etc/x-ui/x-ui.db
exec > >(tee -a /root/vpn-restore.log) 2>&1

detect_ips() {
	[ -n "$LISTEN_IP" ] || LISTEN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
	[ -n "$LISTEN_IP" ] || die "не удалось определить IP сервера — укажите --listen-ip"
	PUBLIC_IP=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
	[ -n "$PUBLIC_IP" ] || PUBLIC_IP=$LISTEN_IP
}

setting() { sqlite3 -readonly "$DB" "select value from settings where key='$1';"; }

port_users() {  # имена процессов, слушающих TCP-порт
	{ ss -Htlnp "sport = :$1" 2>/dev/null || true; } | { grep -o 'users:(("[^"]*"' || true; } | cut -d'"' -f2 | sort -u | tr '\n' ' '
}

inbound_ports() {  # «порт/протокол» внешних (не loopback) включённых inbound'ов из базы $1
	python3 - "$1" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
out = set()
for port, listen, proto, ss, st, enable in db.execute(
        "select port, listen, protocol, stream_settings, settings, enable from inbounds"):
    if not enable or (listen or "").strip() in ("127.0.0.1", "::1", "localhost"):
        continue
    def load(v):
        try:
            return json.loads(v or "{}")
        except ValueError:
            return {}
    s, cfg = load(ss), load(st)
    udp_only = proto in ("wireguard", "hysteria", "hysteria2", "tuic") or s.get("network") in ("kcp", "quic")
    if not udp_only:
        out.add("%s/tcp" % port)
    if udp_only or "udp" in str(cfg.get("network", "")).lower() or cfg.get("udp") is True:
        out.add("%s/udp" % port)
for p in sorted(out):
    print(p)
PY
}

first_link_subid() {  # subId первого включённого клиента
	sqlite3 -readonly "$DB" "select sub_id from clients where enable=1 and sub_id<>'' order by id limit 1;" 2>/dev/null || true
}

chain_exit() {  # «адрес:порт» сервера-выхода, если выход клиентов идёт цепочкой (vless/vmess/trojan outbound в шаблоне Xray)
	python3 - "$DB" <<'PY' 2>/dev/null || true
import json, sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
row = db.execute("select value from settings where key='xrayTemplateConfig'").fetchone()
t = json.loads(row[0]) if row and row[0] else {}
for o in t.get("outbounds") or []:
    if o.get("protocol") in ("vless", "vmess", "trojan"):
        v = ((o.get("settings") or {}).get("vnext") or [{}])[0]
        if v.get("address") and v.get("port"):
            print("%s:%s" % (v["address"], v["port"]))
            break
PY
}

local_scheme() {  # local_scheme webCertFile|subCertFile → https, если панель/подписка сама держит TLS, иначе http
	if [ -n "$(setting "$1")" ]; then echo https; else echo http; fi
}

reality_foreign() {  # «порт SNI» Reality-подключения под чужой сайт (сервер без домена), иначе пусто
	python3 - "$DB" <<'PY' 2>/dev/null || true
import json, sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
for port, ss, enable in db.execute("select port, stream_settings, enable from inbounds order by id"):
    try:
        r = json.loads(ss or "{}").get("realitySettings") or {}
    except ValueError:
        continue
    target = r.get("target") or r.get("dest") or ""
    names = r.get("serverNames") or []
    if enable and names and target and not target.startswith(("127.", "localhost", "[::1]", "@", "/")):
        print(port, names[0])
        break
PY
}

sub_get() {  # sub_get SUBID ФАЙЛ → код ответа подписки (с доменом — через nginx :443, без домена — локально)
	if [ -n "$DOMAIN" ]; then
		curl -s $CURL_K -o "$2" -w '%{http_code}' --max-time 15 --resolve "$DOMAIN:443:$LISTEN_IP" "https://$DOMAIN$(setting subPath)$1" || true
	else
		curl -sk -o "$2" -w '%{http_code}' --max-time 15 "$(local_scheme subCertFile)://127.0.0.1:$(setting subPort)$(setting subPath)$1" || true
	fi
}

client_links() {  # «подпись: ссылка» всех включённых клиентов — с нынешним адресом сервера
	local c s T
	T=$(mktemp)
	sqlite3 -readonly -separator '|' "$DB" "select replace(coalesce(nullif(comment, ''), email), '|', '/'), sub_id from clients where enable=1 and sub_id<>'' order by id;" 2>/dev/null |
		while IFS='|' read -r c s; do
			[ "$(sub_get "$s" "$T")" = 200 ] || continue
			echo "  $c:"
			{ base64 -d "$T" 2>/dev/null || cat "$T"; } | grep -E '^(vless|vmess|trojan|ss)://' | sed 's/^/    /'
		done
	rm -f "$T"
}

link_to_xray() {  # vless-ссылка → конфиг xray-клиента с socks на 127.0.0.1:$3, сервер — адрес $2
	python3 - "$1" "$2" "$3" <<'PY'
import json, sys, urllib.parse as up
link, addr, socks = sys.argv[1], sys.argv[2], int(sys.argv[3])
u = up.urlsplit(link)
q = {k: v[0] for k, v in up.parse_qs(u.query, keep_blank_values=True).items()}
net, sec = q.get("type", "tcp"), q.get("security", "none")
ss = {"network": net, "security": sec}
if sec == "reality":
    r = {"serverName": q.get("sni", ""), "fingerprint": q.get("fp") or "chrome",
         "publicKey": q.get("pbk", ""), "shortId": q.get("sid", ""), "spiderX": q.get("spx", "/")}
    if q.get("pqv"):
        r["mldsa65Verify"] = q["pqv"]
    ss["realitySettings"] = r
elif sec == "tls":
    ss["tlsSettings"] = {"serverName": q.get("sni", ""), "fingerprint": q.get("fp") or "chrome",
                         "alpn": [a for a in q.get("alpn", "").split(",") if a]}
if net == "xhttp":
    x = {"path": q.get("path", "/"), "host": q.get("host", ""), "mode": q.get("mode", "auto")}
    if q.get("extra"):
        x["extra"] = json.loads(q["extra"])
    ss["xhttpSettings"] = x
elif net in ("ws", "httpupgrade"):
    ss[net + "Settings"] = {"path": q.get("path", "/"), "host": q.get("host", "")}
elif net == "grpc":
    ss["grpcSettings"] = {"serviceName": q.get("serviceName", "")}
user = {"id": up.unquote(u.username or ""), "encryption": q.get("encryption", "none"), "flow": q.get("flow", "")}
print(json.dumps({
    "log": {"loglevel": "warning"},
    "inbounds": [{"listen": "127.0.0.1", "port": socks, "protocol": "socks", "settings": {"udp": False}}],
    "outbounds": [{"protocol": "vless",
                   "settings": {"vnext": [{"address": addr, "port": u.port, "users": [user]}]},
                   "streamSettings": ss}],
}, indent=1))
PY
}

wait_port() {  # wait_port ADDR:PORT [секунд]
	local _
	for _ in $(seq 1 "${2:-20}"); do
		ss -Htln "sport = :${1##*:}" 2>/dev/null | grep -qF "$1" && return 0
		sleep 1
	done
	return 1
}

tunnel_check() {  # tunnel_check LINK XRAY → «код_ответа ip_выхода warp(on|plus|off|-) последние_строки_лога» через временный xray-клиент
	local dir socks pid trace code=000 ip=- warp=-
	dir=$(mktemp -d)
	socks=10809
	while ss -Htln "sport = :$socks" | grep -q .; do socks=$((socks + 1)); done
	link_to_xray "$1" "$LISTEN_IP" "$socks" > "$dir/client.json"
	"$2" run -c "$dir/client.json" > "$dir/client.log" 2>&1 &
	pid=$!
	if wait_port "127.0.0.1:$socks" 10; then
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -x "socks5h://127.0.0.1:$socks" https://www.gstatic.com/generate_204 || true)
		if [ "$code" = 204 ]; then
			# cdn-cgi/trace: IP выхода и warp=on|plus|off (выход клиентов идёт через Cloudflare WARP — outbound warp в шаблоне Xray)
			trace=$(curl -s --max-time 15 -x "socks5h://127.0.0.1:$socks" https://www.cloudflare.com/cdn-cgi/trace || true)
			ip=$(sed -n 's/^ip=//p' <<<"$trace"); ip=${ip:--}
			warp=$(sed -n 's/^warp=//p' <<<"$trace"); warp=${warp:--}
		fi
	fi
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
	echo "$code $ip $warp $(tail -2 "$dir/client.log" | tr '\n' ' ')"
	rm -rf "$dir"
}

verify() {
	say "Проверка"
	local T s p code code2 n link xray_bin exit_ip exit_warp chain log web_port web_path sub_port subid
	T=$(mktemp -d)
	web_port=$(setting webPort); web_path=$(setting webBasePath)
	sub_port=$(setting subPort)

	for s in x-ui $([ "$HAS_NGINX" = 1 ] && echo nginx) $([ -f /etc/fail2ban/jail.d/vpn-sshd.local ] && echo fail2ban); do
		if systemctl is-active -q "$s"; then ok "служба $s работает"; else bad "служба $s не работает (journalctl -u $s)"; fi
	done
	if [ -f /etc/systemd/system/vpn-exit-watchdog.service ]; then
		if systemctl is-active -q vpn-exit-watchdog; then ok "вотчдог выхода работает"; else bad "вотчдог выхода не работает (journalctl -u vpn-exit-watchdog)"; fi
	fi
	for p in $([ "$HAS_NGINX" = 1 ] && echo "$LISTEN_IP:443 127.0.0.1:8443") "127.0.0.1:$web_port" "127.0.0.1:$sub_port"; do
		if wait_port "$p" 10; then ok "слушает $p"; else bad "никто не слушает $p"; fi
	done
	for p in $(inbound_ports "$DB" | grep /tcp | cut -d/ -f1); do
		if wait_port ":$p" 10; then ok "inbound слушает порт $p"; else bad "inbound на порту $p не слушает"; fi
	done

	if [ -n "$DOMAIN" ]; then
		if openssl x509 -checkend 604800 -noout -in "/root/cert/$DOMAIN/fullchain.pem" >/dev/null 2>&1; then
			ok "сертификат $DOMAIN действует до $(openssl x509 -enddate -noout -in "/root/cert/$DOMAIN/fullchain.pem" | cut -d= -f2)"
		else
			bad "сертификат $DOMAIN истёк или истекает меньше чем через неделю"
		fi
	fi

	if [ -n "$DOMAIN" ]; then
		code=$(curl -s $CURL_K -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$DOMAIN:443:$LISTEN_IP" "https://$DOMAIN$web_path" || true)
		if [ "$code" = 200 ]; then ok "панель https://$DOMAIN$web_path отвечает 200"; else bad "панель отвечает $code"; fi
	else
		code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "$(local_scheme webCertFile)://127.0.0.1:$web_port$web_path" || true)
		if [ "$code" = 200 ]; then ok "панель на 127.0.0.1:$web_port отвечает 200 (снаружи — через SSH-туннель)"; else bad "панель отвечает $code"; fi
	fi

	if [ "$HAS_NGINX" = 1 ] && [ -n "$DOMAIN" ]; then
		code=$(curl -s $CURL_K -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$DOMAIN:443:$LISTEN_IP" "https://$DOMAIN/" || true)
		if [ "$code" = 200 ]; then ok "заглушка сайта на / отвечает 200"; else bad "заглушка сайта на / отвечает $code — self-steal покажет ошибку вместо сайта"; fi
	fi
	read -r p s <<<"$(reality_foreign)"
	if [ -n "${s:-}" ]; then
		# Reality под чужой сайт: кто прощупывает без ключа, должен получить настоящий сайт с верным сертификатом.
		if timeout 10 openssl s_client -connect "$LISTEN_IP:$p" -servername "$s" -verify_hostname "$s" -verify_return_error \
			< /dev/null 2>&1 | grep -q 'Verify return code: 0 (ok)'; then
			ok "чужим на :$p отвечает настоящий $s (сертификат верный)"
		else
			bad "проба :$p с SNI $s не получила настоящий сертификат сайта — target недоступен с этого сервера?"
		fi
	fi

	subid=$(first_link_subid)
	link=
	if [ -z "$subid" ]; then
		warn "нет включённых клиентов с subId — подписку и туннель не проверить"
	else
		code=$(sub_get "$subid" "$T/sub")
		if [ "$code" = 200 ]; then
			base64 -d "$T/sub" > "$T/links" 2>/dev/null || cp "$T/sub" "$T/links"
			n=$(grep -cE '^(vless|vmess|trojan|ss)://' "$T/links" || true)
			if [ "${n:-0}" -gt 0 ]; then ok "подписка отдаёт ссылки ($n шт.)"; else bad "подписка пустая"; fi
			link=$(grep -m1 '^vless://' "$T/links" || true)
		else
			bad "подписка отвечает $code"
		fi
	fi

	xray_bin=$(ls /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -1 || true)
	if [ -n "$link" ] && [ -n "$xray_bin" ]; then
		read -r code exit_ip exit_warp log <<<"$(tunnel_check "$link" "$xray_bin")"
		chain=$(chain_exit)
		if [ "$code" = 204 ]; then
			if [ "$exit_warp" = on ] || [ "$exit_warp" = plus ]; then
				ok "туннель по ссылке клиента работает (выход через Cloudflare WARP, IP $exit_ip — IP сервера не светится)"
				[ -z "$chain" ] || warn "основной выход — сервер ${chain%:*}, а сейчас работает запасной WARP: выход недоступен с этого IP? (на нём: ufw allow from $PUBLIC_IP to any port ${chain##*:} proto tcp)"
			elif [ -n "$chain" ] && [ "$exit_ip" = "${chain%:*}" ]; then
				ok "туннель по ссылке клиента работает (выход цепочкой через сервер ${chain%:*})"
			else
				ok "туннель по ссылке клиента работает (выход в интернет с IP $exit_ip)"
				[ "$exit_ip" = "$PUBLIC_IP" ] || warn "IP выхода $exit_ip не совпал с IP сервера $PUBLIC_IP"
			fi
		elif [[ $link == *fp=random* ]] && read -r code2 _ <<<"$(tunnel_check "${link/fp=random/fp=chrome}" "$xray_bin")" &&
			[ "$code2" = 204 ]; then
			# Найдено на 3x-ui 3.10.2: Xray 26.10 и на сервере, и в клиенте с fp=random не проходит Reality.
			bad "туннель с fp=random из ссылки не работает, с fp=chrome работает: клиенты на свежем Xray не подключатся — в панели в inbound поставьте uTLS chrome (или оставьте прежнюю версию 3x-ui)"
		else
			bad "туннель по ссылке клиента не работает (ответ $code): $log"
			if [ -n "$chain" ]; then
				warn "выход идёт цепочкой через ${chain%:*}: на нём должен быть открыт порт ${chain##*:} для этого сервера — ufw allow from $PUBLIC_IP to any port ${chain##*:} proto tcp (через 2 мин вотчдог переключит на WARP)"
			elif grep -q '"warp"' <<<"$(setting xrayTemplateConfig)"; then
				warn "выход клиентов идёт через Cloudflare WARP (outbound warp в шаблоне Xray): без WARP туннель не работает — см. README, «Тонкости»"
			fi
		fi
	elif [ -n "$subid" ]; then
		warn "в подписке нет vless-ссылки — туннель не проверялся"
	fi
	rm -rf "$T"

	echo
	if [ "$FAILS" = 0 ]; then
		printf '\033[1;32mПроверка: всё OK.\033[0m\n'
	else
		printf '\033[1;31mПроверка: ошибок %s — см. выше.\033[0m\n' "$FAILS"
	fi
}

final_note() {
	local chain
	chain=$(chain_exit)
	if [ -n "$chain" ]; then
		cat <<EOF

Выход клиентов идёт цепочкой через сервер ${chain%:*}. До переключения DNS на нём должен быть открыт порт для нового IP:
  ufw allow from $PUBLIC_IP to any port ${chain##*:} proto tcp comment 'vpn entry'
(старое правило для прежнего IP входа потом удалить: ufw status numbered → ufw delete N)
EOF
	fi
	if [ -z "$DOMAIN" ]; then
		cat <<EOF

Сервер без домена: ссылки клиентов ведут на IP. Теперь это $PUBLIC_IP — раздайте клиентам новые
ссылки (в приложении удалить старую и добавить новую: «+» → «Импорт из буфера обмена»):
EOF
		client_links
		cat <<EOF
Ключи те же, меняется только адрес. Старый сервер ($SRC_PUBLIC_IP) не удалять, пока все не перейдут.
EOF
		return 0
	fi
	cat <<EOF

Осталось переключить DNS:
  Cloudflare → $DOMAIN → A-запись → $PUBLIC_IP  (TTL 300, без оранжевого облака / Proxy off)
Клиентам ничего менять не нужно — в ссылках домен, ключи те же.
Проверить, что DNS разошёлся:
  curl -s -H 'accept: application/dns-json' 'https://cloudflare-dns.com/dns-query?name=$DOMAIN&type=A'
Старый сервер ($SRC_PUBLIC_IP) не удалять, пока клиенты не переедут (сутки). Откат — вернуть A-запись.
EOF
}

if [ "$VERIFY_ONLY" = 1 ]; then
	detect_ips
	verify
	[ "$FAILS" = 0 ] && final_note
	exit $((FAILS > 0))
fi

START=$(date +%s)
printf '\033[1mВосстановление %s из бэкапа от %s (старый сервер %s, 3x-ui %s)\033[0m\n' \
	"$LABEL" "$CREATED" "$SRC_PUBLIC_IP" "$XUI_VERSION"

say "Проверка архива и сервера"
(cd "$HERE" && sha256sum --quiet -c SHA256SUMS) || die "архив повреждён: не сходятся SHA256SUMS"
ok "контрольные суммы архива сходятся"
OS_NOW=$(. /etc/os-release && echo "$ID $VERSION_ID|$PRETTY_NAME")
case ${OS_NOW%%|*} in
	"ubuntu 22.04" | "ubuntu 24.04" | "debian 12") ok "система ${OS_NOW#*|}" ;;
	*) warn "система ${OS_NOW#*|} не проверялась (рассчитано на Ubuntu 22.04/24.04, Debian 12)" ;;
esac
# ip и ss нужны уже для проверки портов; на урезанных образах iproute2 бывает не установлен.
if ! command -v ss >/dev/null || ! command -v ip >/dev/null; then
	DEBIAN_FRONTEND=noninteractive apt-get -y -q -o DPkg::Lock::Timeout=600 update >/dev/null &&
		DEBIAN_FRONTEND=noninteractive apt-get -y -q -o DPkg::Lock::Timeout=600 install iproute2 >/dev/null ||
		die "не установился iproute2 (ip, ss)"
fi
if [ "$HAS_NGINX" = 1 ]; then
	for p in 80 443; do
		u=$(port_users "$p")
		case $u in "" | "nginx ") ;; *) die "порт $p занят: $u— освободите его" ;; esac
	done
fi
if command -v python3 >/dev/null; then
	for p in $(inbound_ports "$F$DB" | grep /tcp | cut -d/ -f1); do
		u=$(port_users "$p")
		case $u in "" | xray* | x-ui*) ;; *) die "порт $p (inbound) занят: $u" ;; esac
	done
fi
if [ "$HAS_NGINX" = 1 ]; then ok "порты 80, 443 и порты inbound'ов свободны"; else ok "порты inbound'ов свободны"; fi

say "Пакеты"
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
"${APT[@]}" update >/dev/null || die "apt-get update не прошёл"
PKGS=(sqlite3 curl ufw cron ca-certificates openssl python3 tar tzdata iproute2 procps)
if [ "$HAS_NGINX" = 1 ]; then PKGS+=(nginx libnginx-mod-stream socat); fi
"${APT[@]}" install "${PKGS[@]}" >/dev/null || die "не установились пакеты"
if [ "$HAS_NGINX" = 1 ]; then systemctl stop nginx 2>/dev/null || true; fi
ok "${PKGS[*]}"
detect_ips
if [ "$HAS_NGINX" = 1 ]; then ok "IP сервера: $PUBLIC_IP (nginx будет слушать $LISTEN_IP:443)"; else ok "IP сервера: $PUBLIC_IP"; fi

say "3x-ui"
if [ "$XUI_WANT" = latest ]; then
	XUI_WANT=$(curl -fsSL https://api.github.com/repos/MHSanaei/3x-ui/releases/latest | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)
	[ -n "$XUI_WANT" ] || die "не удалось узнать последнюю версию 3x-ui"
fi
CUR=$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 || true)
if [ "$CUR" = "$XUI_WANT" ]; then
	ok "3x-ui $CUR уже установлен"
else
	URL=https://github.com/MHSanaei/3x-ui/releases/download/v$XUI_WANT/x-ui-linux-$ARCH_NEW.tar.gz
	TMP=$(mktemp -d)
	if [ -n "${XUI_TARBALL:-}" ]; then   # для проверки скрипта без скачивания: тот же релиз из файла
		cp "$XUI_TARBALL" "$TMP/x-ui.tgz"
	else
		curl -fL --retry 3 --connect-timeout 20 -s -o "$TMP/x-ui.tgz" "$URL" || die "не скачался $URL"
	fi
	systemctl stop x-ui 2>/dev/null || true
	rm -rf /usr/local/x-ui
	tar -C /usr/local -xzf "$TMP/x-ui.tgz"
	rm -rf "$TMP"
	chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/x-ui.sh /usr/local/x-ui/bin/xray-linux-*
	chmod +x /usr/local/x-ui/bin/mtg-linux-* 2>/dev/null || true
	ok "3x-ui $XUI_WANT установлен из релиза GitHub"
fi
if [ "$XUI_WANT" = "$XUI_VERSION" ]; then
	if [ "$ARCH_NEW" != "$ARCH" ]; then
		warn "архитектура $ARCH_NEW (было $ARCH) — файлы со старым сервером не сравнить"
	elif [ "$(sha256sum /usr/local/x-ui/x-ui | cut -d' ' -f1)" = "$XUI_SHA256" ] &&
		[ "$(sha256sum /usr/local/x-ui/bin/xray-linux-"$ARCH_NEW" | cut -d' ' -f1)" = "$XRAY_SHA256" ]; then
		ok "x-ui и Xray $XRAY_VERSION — те же файлы, что на старом сервере"
	else
		warn "файлы x-ui/Xray отличаются от старого сервера (sha256)"
	fi
	install -m 755 "$F/usr/bin/x-ui" /usr/bin/x-ui 2>/dev/null || install -m 755 /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
	install -m 644 "$F/etc/systemd/system/x-ui.service" /etc/systemd/system/x-ui.service 2>/dev/null ||
		install -m 644 /usr/local/x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service
else
	install -m 755 /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
	install -m 644 /usr/local/x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service
	warn "версия $XUI_WANT вместо $XUI_VERSION — после переключения DNS проверьте подключение на своём телефоне"
fi
if [ -f "$F/etc/default/x-ui" ]; then install -m 644 "$F/etc/default/x-ui" /etc/default/x-ui; fi
systemctl daemon-reload

say "База 3x-ui: клиенты, ключи Reality, настройки панели и подписки"
systemctl stop x-ui 2>/dev/null || true
mkdir -p /etc/x-ui
if [ -f "$DB" ] && ! cmp -s "$DB" "$F$DB"; then
	cp -a "$DB" "$DB.before-restore-$(date +%Y%m%d-%H%M%S)"
fi
# Старые -wal/-shm удалить до копирования: иначе SQLite «наложит» их на восстановленную базу.
rm -f "$DB-wal" "$DB-shm"
install -m 644 "$F$DB" "$DB"
if [ -f "$F/etc/x-ui/install-result.env" ]; then install -m 600 "$F/etc/x-ui/install-result.env" /etc/x-ui/install-result.env; fi
# Копия регистрации WARP (основная — в базе, настройка warp).
if [ -d "$F/etc/x-ui/warp" ]; then cp -a "$F/etc/x-ui/warp" /etc/x-ui/; fi
# Как официальный install.sh после установки: приводит базу к схеме установленной версии.
if out=$(/usr/local/x-ui/x-ui migrate 2>&1); then ok "x-ui migrate: база приведена к версии $XUI_WANT"; else bad "x-ui migrate: $out"; fi
ok "база восстановлена: inbound'ов $(sqlite3 -readonly "$DB" 'select count(*) from inbounds;'), клиентов $(sqlite3 -readonly "$DB" 'select count(*) from clients;' 2>/dev/null || echo '?')"
# Без домена адрес в ссылках клиентов — IP сервера (share_addr подключения): переносим на новый.
if [ -z "$DOMAIN" ] && [[ $SRC_PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$SRC_PUBLIC_IP" != "$PUBLIC_IP" ]; then
	n=$(sqlite3 "$DB" "update inbounds set share_addr='$PUBLIC_IP' where share_addr_strategy='custom' and share_addr='$SRC_PUBLIC_IP'; select changes();")
	ok "адрес в ссылках клиентов: $SRC_PUBLIC_IP → $PUBLIC_IP (подключений: $n)"
fi

if [ -n "$DOMAIN" ]; then
say "Сертификат $DOMAIN и acme.sh"
[ -d "$F/root/cert/$DOMAIN" ] || die "в архиве нет сертификата /root/cert/$DOMAIN"
install -d -m 755 /root/cert
cp -a "$F/root/cert/$DOMAIN" /root/cert/
chmod 600 "/root/cert/$DOMAIN/privkey.pem"
ok "сертификат действует до $(openssl x509 -enddate -noout -in "/root/cert/$DOMAIN/fullchain.pem" | cut -d= -f2)"
fi
if [ -n "$DOMAIN" ] && [ -d "$F/root/.acme.sh" ]; then
	mkdir -p /root/.acme.sh /var/www/acme
	cp -a "$F/root/.acme.sh/." /root/.acme.sh/
	CRON_LINE=$(grep -F 'acme.sh --cron' "$HERE/info/crontab-root.txt" 2>/dev/null | head -1 || true)
	[ -n "$CRON_LINE" ] || CRON_LINE='10 11 * * * "/root/.acme.sh"/acme.sh --cron --home "/root/.acme.sh" > /dev/null'
	{ crontab -l 2>/dev/null || true; } | { grep -vF 'acme.sh --cron' || true; } > /root/.crontab.new
	echo "$CRON_LINE" >> /root/.crontab.new
	crontab /root/.crontab.new
	rm -f /root/.crontab.new
	crontab -l | grep -qF 'acme.sh --cron' || die "не записалась строка cron для acme.sh"
	grep -qF 'acme.sh.env' /root/.bashrc 2>/dev/null || echo '. "/root/.acme.sh/acme.sh.env"' >> /root/.bashrc
	ok "acme.sh: аккаунт Let's Encrypt и автопродление (webroot /var/www/acme через nginx :80)"
fi

if [ "$HAS_NGINX" = 1 ]; then
say "nginx: SNI-демультиплексор :443, панель и подписка за доменом, ACME на :80"
install -m 644 "$F/etc/nginx/nginx.conf" /etc/nginx/nginx.conf
for d in conf.d stream-enabled; do
	mkdir -p "/etc/nginx/$d"
	if [ -d "$F/etc/nginx/$d" ]; then cp -a "$F/etc/nginx/$d/." "/etc/nginx/$d/"; fi
done
rm -f /etc/nginx/sites-enabled/default
if [ -d "$F/etc/nginx/sites-enabled" ]; then
	find "$F/etc/nginx/sites-enabled" -mindepth 1 -maxdepth 1 -type f -exec cp -a {} /etc/nginx/sites-enabled/ \;
fi
# Старый IP сервера в конфигах nginx (listen демультиплексора) → новый.
if [[ $SRC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$SRC_IP" != "$LISTEN_IP" ]; then
	OLD_RE="(^|[^0-9.])${SRC_IP//./\\.}([^0-9.]|$)"
	{ grep -rlE "$OLD_RE" /etc/nginx/conf.d /etc/nginx/stream-enabled /etc/nginx/sites-enabled 2>/dev/null || true; } |
		while IFS= read -r f; do sed -i -E "s/$OLD_RE/\1$LISTEN_IP\2/g" "$f"; done
fi
# Заглушка сайта на / домена: её видят self-steal и зондирование, без неё nginx отдаёт 403.
if [ -d "$F/var/www/html" ]; then
	mkdir -p /var/www/html
	cp -a "$F/var/www/html/." /var/www/html/
	rm -f /var/www/html/index.nginx-debian.html
fi
mkdir -p /etc/systemd/system/nginx.service.d
if [ -d "$F/etc/systemd/system/nginx.service.d" ]; then
	cp -a "$F/etc/systemd/system/nginx.service.d/." /etc/systemd/system/nginx.service.d/
fi
systemctl daemon-reload
nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx -t: конфигурация с ошибкой"; }
ok "конфиг nginx проверен, :443 слушает $LISTEN_IP (было $SRC_IP)"
fi

say "Ядро: BBR, IPv6 выключен, ip_nonlocal_bind"
if [ -f "$F/etc/sysctl.d/99-vpn.conf" ]; then
	install -m 644 "$F/etc/sysctl.d/99-vpn.conf" /etc/sysctl.d/99-vpn.conf
	modprobe tcp_bbr 2>/dev/null || true
	if sysctl -p /etc/sysctl.d/99-vpn.conf >/dev/null 2>&1; then ok "$(sysctl -n net.ipv4.tcp_congestion_control), IPv6 off"; else warn "часть настроек sysctl не применилась"; fi
fi

say "Swap и часовой пояс"
if [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
	ok "swap уже есть"
elif systemd-detect-virt -cq 2>/dev/null || [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then
	warn "это контейнер — swap пропущен"
elif { fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none; } &&
	chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile; then
	grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
	ok "swap 2 ГБ"
else
	warn "swap не создался — VPN это не мешает"
fi
if [ -z "${TIMEZONE:-}" ] || [ ! -e "/usr/share/zoneinfo/$TIMEZONE" ]; then
	warn "часовой пояс «${TIMEZONE:-}» не выставлен"
# Не через timedatectl: в контейнере его первый вызов сдвигает часы ядра хоста на смещение пояса.
elif ln -sfn "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime && echo "$TIMEZONE" > /etc/timezone; then
	ok "часовой пояс $TIMEZONE (по нему cron запускает бэкап$([ -n "$DOMAIN" ] && echo " и продление сертификата"))"
else
	warn "часовой пояс $TIMEZONE не выставлен"
fi

say "SSH"
if [ -f "$F/root/.ssh/authorized_keys" ]; then
	install -d -m 700 /root/.ssh
	touch /root/.ssh/authorized_keys
	chmod 600 /root/.ssh/authorized_keys
	while IFS= read -r k; do
		[ -n "$k" ] || continue
		grep -qxF -- "$k" /root/.ssh/authorized_keys || printf '%s\n' "$k" >> /root/.ssh/authorized_keys
	done < "$F/root/.ssh/authorized_keys"
	ok "ключи root из бэкапа добавлены ($(grep -c . /root/.ssh/authorized_keys) шт.)"
fi
if ! command -v sshd >/dev/null; then
	warn "sshd не установлен — настройки SSH пропущены"
elif [ "$HARDEN_SSH" = 1 ] && [ -s /root/.ssh/authorized_keys ] && [ -f "$F/etc/ssh/sshd_config.d/00-disable-password.conf" ]; then
	install -m 644 "$F/etc/ssh/sshd_config.d/00-disable-password.conf" /etc/ssh/sshd_config.d/00-disable-password.conf
	if sshd -t; then
		systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
		ok "вход по паролю выключен, root — только по ключу (запасной вход — консоль VNC у хостера)"
	else
		rm -f /etc/ssh/sshd_config.d/00-disable-password.conf
		bad "sshd -t не прошёл — вход по паролю оставлен как был"
	fi
else
	warn "вход по паролю не трогали"
fi
# fail2ban (ставит install-vpn.sh) — если был на старом сервере.
if [ -f "$F/etc/fail2ban/jail.d/vpn-sshd.local" ] && command -v sshd >/dev/null; then
	if "${APT[@]}" install fail2ban python3-systemd >/dev/null; then
		install -d -m 755 /etc/fail2ban/jail.d
		install -m 644 "$F/etc/fail2ban/jail.d/vpn-sshd.local" /etc/fail2ban/jail.d/vpn-sshd.local
		# Нет /var/log/auth.log (Debian без rsyslog) — читать журнал systemd; есть — как настроено.
		if [ ! -f /var/log/auth.log ] && ! grep -q '^backend' /etc/fail2ban/jail.d/vpn-sshd.local; then
			echo "backend = systemd" >> /etc/fail2ban/jail.d/vpn-sshd.local
		fi
		systemctl enable fail2ban >/dev/null 2>&1 || true
		if systemctl restart fail2ban; then ok "fail2ban: бан за подбор пароля SSH, как на старом сервере"; else bad "fail2ban не запустился (journalctl -u fail2ban)"; fi
	else
		bad "fail2ban не установился"
	fi
fi

say "Фаервол ufw"
if [ "$DO_UFW" = 1 ]; then
	OPEN=$( {
		sshd -T 2>/dev/null | awk '$1=="port"{print $2"/tcp"}'
		[ -n "${SSH_CONNECTION:-}" ] && echo "${SSH_CONNECTION##* }/tcp"
		if [ "$HAS_NGINX" = 1 ]; then echo 80/tcp; echo 443/tcp; fi
		inbound_ports "$DB"
	} | sort -u -t/ -k1,1n -k2)
	for p in $OPEN; do ufw allow "$p" >/dev/null || bad "ufw allow $p не прошёл"; done
	if ufw --force enable >/dev/null 2>&1; then ok "включён, открыто: $(echo $OPEN)"; else bad "ufw не включился"; fi
else
	warn "фаервол не трогали (--no-ufw)"
fi

say "Ежедневный бэкап на этом сервере"
install -m 755 "$F/usr/local/bin/vpn-backup.sh" /usr/local/bin/vpn-backup.sh
install -d -m 755 /usr/local/lib/vpn-backup
install -m 755 "$HERE/restore.sh" /usr/local/lib/vpn-backup/restore.sh
install -m 644 "$HERE/README.md" /usr/local/lib/vpn-backup/README.md
# Установщик для друзей и скрипт для мака лежат рядом с комплектом и переезжают вместе с ним.
if [ -d "$F/usr/local/lib/vpn-backup" ]; then
	find "$F/usr/local/lib/vpn-backup" -mindepth 1 -maxdepth 1 ! -name restore.sh ! -name README.md -exec cp -a {} /usr/local/lib/vpn-backup/ \;
fi
install -m 644 "$F/etc/cron.d/vpn-backup" /etc/cron.d/vpn-backup
# Сервер, поставленный install-vpn.sh: его настройки (для повторного запуска и vpn-check) и команда vpn-check.
if [ -f "$F/etc/vpn-install.env" ]; then install -m 600 "$F/etc/vpn-install.env" /etc/vpn-install.env; fi
if [ -f "$F/usr/local/bin/vpn-check" ]; then install -m 755 "$F/usr/local/bin/vpn-check" /usr/local/bin/vpn-check; fi
ok "vpn-backup.sh по cron, архивы в /root/backups"

WATCHDOG=0
if [ -f "$F/usr/local/bin/vpn-exit-watchdog.sh" ] && [ -f "$F/etc/systemd/system/vpn-exit-watchdog.service" ]; then
	say "Вотчдог выхода: цепочка через сервер-выход, при его падении — WARP"
	install -m 755 "$F/usr/local/bin/vpn-exit-watchdog.sh" /usr/local/bin/vpn-exit-watchdog.sh
	install -m 644 "$F/etc/systemd/system/vpn-exit-watchdog.service" /etc/systemd/system/vpn-exit-watchdog.service
	systemctl daemon-reload
	WATCHDOG=1
	ok "вотчдог установлен, запустится вместе с x-ui (журнал: journalctl -t vpn-watchdog)"
fi

say "Запуск"
systemctl enable x-ui cron $([ "$HAS_NGINX" = 1 ] && echo nginx) >/dev/null 2>&1 || warn "не удалось включить автозапуск служб"
systemctl restart cron || warn "cron не перезапустился"
systemctl restart x-ui || bad "x-ui не запустился (journalctl -u x-ui)"
wait_port "127.0.0.1:$(setting webPort)" 30 || true
if [ "$HAS_NGINX" = 1 ]; then systemctl restart nginx || bad "nginx не запустился (journalctl -u nginx)"; fi
if [ "$WATCHDOG" = 1 ]; then
	systemctl enable vpn-exit-watchdog >/dev/null 2>&1 || warn "не удалось включить автозапуск вотчдога"
	systemctl restart vpn-exit-watchdog || bad "вотчдог не запустился (journalctl -u vpn-exit-watchdog)"
fi

verify
echo "Заняло $(( $(date +%s) - START )) с. Журнал: /root/vpn-restore.log"
[ "$FAILS" = 0 ] && final_note
exit $((FAILS > 0))
VPN_KIT_EOF_1
chmod 755 /usr/local/lib/vpn-backup/restore.sh
cat > /usr/local/lib/vpn-backup/README.md <<'VPN_KIT_EOF_2'
# VPN-сервер: бэкап и переезд

Архив `vpn-backup-<домен>-<дата>.tgz` (у сервера без домена — `vpn-backup-ip-<IP>-<дата>.tgz`) —
полный снимок VPN-сервера. `restore.sh` из этого архива за несколько минут поднимает такую же копию
на чистом сервере и сам её проверяет. Ключи и клиенты переезжают вместе с базой.
- **С доменом:** клиентам ничего менять не нужно — в подписках домен, а не IP. После переезда
  меняется только A-запись домена.
- **Без домена:** в ссылках IP сервера, а у нового сервера он другой. `restore.sh` в конце
  печатает новые ссылки — их нужно раздать и заново добавить в приложения.

> ⚠️ Архив секретный: в нём ключ Reality, ключ сертификата, доступ к панели.
> Не пересылать в мессенджеры и не выкладывать.

## Что внутри

| Что | Путь на сервере |
|---|---|
| База 3x-ui: подключение, все клиенты и их подписки, ключи Reality, настройки панели и подписки, шаблон Xray | `/etc/x-ui/x-ui.db` |
| (с доменом) nginx: SNI-демультиплексор на :443, сайт-заглушка, панель и подписка за доменом, ACME на :80 | `/etc/nginx/`, `/var/www/html` |
| (с доменом) сертификат домена и acme.sh (автопродление) | `/root/cert/<домен>/`, `/root/.acme.sh/` |
| Ядро: BBR, IPv6 выключен | `/etc/sysctl.d/99-vpn.conf` |
| SSH-ключи root и настройки входа | `/root/.ssh/authorized_keys`, `/etc/ssh/sshd_config.d/` |
| Служба x-ui, скрипт бэкапа и его cron | `/etc/systemd/system/x-ui.service`, `/usr/local/bin/vpn-backup.sh`, `/etc/cron.d/vpn-backup` |
| fail2ban (бан за подбор пароля SSH), настройки установки и команда проверки `vpn-check` | `/etc/fail2ban/jail.d/vpn-sshd.local`, `/etc/vpn-install.env`, `/usr/local/bin/vpn-check` |

`info/summary.txt` — коротко: адрес панели, подписки, число клиентов, срок сертификата.

## Если VPN перестал работать

```bash
vpn-check
```

Ничего не меняет, только проверяет: службы, сайт или маскировку, подписку, настоящий туннель изнутри
сервера и — через check-host.net — открываются ли SSH и порты VPN из России и Европы. По итогу видно,
что случилось: служба упала (перезапуск: `systemctl restart x-ui`), порт закрыт фаерволом хостера
(открыть в панели хостера) или IP заблокирован в России (нужен другой IP — переезд ниже).

## Бэкап

Каждый день в 04:17 сервер сам кладёт архив в `/root/backups/` (14 последних, `latest.tgz` —
свежий). Сделать сейчас: `vpn-backup.sh`. Забрать к себе на компьютер:

```bash
scp root@IP_СЕРВЕРА:/root/backups/latest.tgz ./vpn-backup.tgz
```

## Переезд на новый сервер

1. Новый сервер: Ubuntu 22.04/24.04 или Debian 12, от 1 ГБ ОЗУ, доступ root по SSH.
   Проверить, что его IP открывается из России: check-host.net → TCP-порт 22 с узлов в России
   (install-vpn.sh делает это сам перед установкой и не ставит VPN на заблокированный IP).
2. Залить архив и восстановить:
   ```bash
   scp vpn-backup.tgz root@НОВЫЙ_IP:/root/
   ssh root@НОВЫЙ_IP
   tar xzf vpn-backup.tgz && bash vpn-backup-*/restore.sh
   ```
3. В конце должно быть **«Проверка: всё OK»**.
4. С доменом: поменять A-запись домена на новый IP (TTL 300, в Cloudflare — Proxy выключен).
   Клиенты переподключатся сами за несколько минут. Старый сервер держать ещё сутки.
   Без домена: раздать клиентам новые ссылки, которые напечатал `restore.sh` (в приложении удалить
   старую и добавить новую). Старый сервер не удалять, пока все не перейдут.

Опции `restore.sh`: `--listen-ip IP` (сервер за NAT: внутренний IP), `--keep-password-ssh`,
`--no-ufw`, `--verify` (только проверить).

## Тонкости

- Порт 80 должен оставаться открытым: через него продлевается сертификат.
- Клиентов добавлять и удалять в панели (3x-ui хранит их в отдельных таблицах базы).
- В приложениях нужно ядро Xray (Happ, v2RayTun, v2rayNG, v2rayN, Streisand): транспорт XHTTP
  приложения на sing-box (Hiddify и похожие) не поддерживают.
- С доменом — Reality «steal-oneself»: подключение на порту 2083, SNI — сам домен, Reality отдаёт чужим
  настоящий сайт с nginx (`127.0.0.1:8443`). На 443 nginx пускает свой домен к сайту, панели и подписке,
  остальное обрывает.
- Без домена — Reality на 443 под крупный чужой сайт (какой — видно в панели, поле SNI подключения):
  тот, кто прощупывает сервер, получает настоящий сайт. Панель и подписка слушают только 127.0.0.1;
  панель открывать через SSH-туннель: `ssh -N -L ПОРТ:127.0.0.1:ПОРТ root@IP`, потом
  `http://127.0.0.1:ПОРТ/путь` (порт и путь — в `/root/vpn-info.txt`).
- В подключении стоят uTLS `chrome` и xmux (меньше TLS-рукопожатий — меньше заморозок у провайдеров);
  если их поменять, клиентам надо обновить подписку или ссылки.
VPN_KIT_EOF_2
chmod 644 /usr/local/lib/vpn-backup/README.md
cat > /etc/cron.d/vpn-backup <<'VPN_KIT_EOF_3'
# Ежедневный полный бэкап VPN-сервера для переезда (см. /usr/local/lib/vpn-backup/README.md)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 4 * * * root /usr/local/bin/vpn-backup.sh >/var/log/vpn-backup.log 2>&1
VPN_KIT_EOF_3
chmod 644 /etc/cron.d/vpn-backup
ok "vpn-backup.sh каждый день в 04:17, архивы в /root/backups (переезд — README.md внутри архива)"
# Копия самого скрипта — рядом с комплектом: для vpn-check и повторных запусков, даже если скачанный файл удалят.
if [ -f "$0" ] && [ "$(readlink -f "$0")" != /usr/local/lib/vpn-backup/install-vpn.sh ]; then
	install -m 755 "$0" /usr/local/lib/vpn-backup/install-vpn.sh
fi
if [ -f /usr/local/lib/vpn-backup/install-vpn.sh ]; then
	cat > /usr/local/bin/vpn-check <<'EOF'
#!/bin/bash
# Проверка VPN: службы, туннель, доступность портов из России и Европы (install-vpn.sh --check).
exec bash /usr/local/lib/vpn-backup/install-vpn.sh --check "$@"
EOF
	chmod 755 /usr/local/bin/vpn-check
	ok "команда vpn-check: проверить VPN в любой момент (ничего не меняет)"
fi

say "Запуск"
SERVICES="x-ui cron"
[ "$MODE" = domain ] && SERVICES="x-ui nginx cron"
# shellcheck disable=SC2086
systemctl enable $SERVICES >/dev/null 2>&1 || warn "не удалось включить автозапуск служб"
systemctl restart cron || warn "cron не перезапустился"
systemctl restart x-ui || bad "x-ui не запустился (journalctl -u x-ui)"
wait_port "127.0.0.1:$WEB_PORT" 40 || true
if [ "$MODE" = domain ]; then systemctl restart nginx || bad "nginx не запустился (journalctl -u nginx)"; fi

K=
[ "$TEST_SELFSIGNED" = 1 ] && K=-k
local_checks
reach_check

say "Готово"
mkdir -p /root/vpn-qr
chmod 700 /root/vpn-qr
: > "$WORK/qr"
{
	if [ "$MODE" = domain ]; then
		echo "VPN на $DOMAIN ($PUBLIC_IP), установлен $(date '+%F %R')"
		echo
		echo "Панель управления: https://$DOMAIN$WEB_PATH"
		echo "  логин:  $PANEL_USER"
		echo "  пароль: $PANEL_PASS"
		echo
		echo "Подписки — по одной на устройство. В приложении: «+» → добавить подписку по ссылке (или отсканировать QR):"
		sub_list | while IFS='|' read -r c s; do
			echo "  $c: https://$DOMAIN$SUB_PATH$s"
			printf '%s|%s\n' "$c" "https://$DOMAIN$SUB_PATH$s" >> "$WORK/qr"
		done
	else
		echo "VPN на сервере $PUBLIC_IP без домена (Reality под $REALITY_SNI), установлен $(date '+%F %R')"
		echo
		echo "Ссылки — по одной на устройство. В приложении: «+» → «Импорт из буфера обмена» (или отсканировать QR):"
		sub_list | while IFS='|' read -r c s; do
			l=$(sub_fetch "$s" | grep -m1 '^vless://' || true)
			[ -n "$l" ] || continue
			echo "  $c:"
			echo "    $l"
			printf '%s|%s\n' "$c" "$l" >> "$WORK/qr"
		done
		echo
		echo "Ссылки привязаны к IP $PUBLIC_IP. Переедете на другой сервер (restore.sh из бэкапа) —"
		echo "restore.sh напечатает новые ссылки, их надо заново добавить в приложения."
		echo
		echo "Панель управления — только через SSH-туннель, снаружи её не видно:"
		echo "  1) на своём компьютере в терминале (окно не закрывать):"
		echo "       ssh -N -L $WEB_PORT:127.0.0.1:$WEB_PORT -p $SSH_PORT root@$PUBLIC_IP"
		echo "  2) в браузере: http://127.0.0.1:$WEB_PORT$WEB_PATH"
		echo "     логин:  $PANEL_USER"
		echo "     пароль: $PANEL_PASS"
	fi
	echo
	echo "Приложения (нужно ядро Xray, sing-box-приложения вроде Hiddify XHTTP не умеют):"
	echo "  iPhone/iPad — Happ, v2RayTun, Streisand; Android — Happ, v2RayTun, v2rayNG; Windows/macOS — Happ, v2RayTun, v2rayN."
	echo "Новые устройства — в панели: Подключения → клиенты → «+»; у каждого своя ссылка."
	echo
	echo "Если VPN перестал работать — проверка одной командой (службы, туннель, доступность из России):"
	if [ -x /usr/local/bin/vpn-check ]; then echo "  vpn-check"; else echo "  bash install-vpn.sh --check"; fi
	echo
	echo "Бэкап: /root/backups/latest.tgz — каждый день в 04:17. Архив секретный: забрать к себе"
	echo "  scp -P $SSH_PORT root@$PUBLIC_IP:/root/backups/latest.tgz ."
	echo "Переезд на другой сервер — README.md в архиве (restore.sh$([ "$MODE" = domain ] && echo ", потом смена A-записи"))."
} > "$INFO"
chmod 600 "$INFO"
cat "$INFO"
echo
while IFS='|' read -r c l; do
	qrencode -o "/root/vpn-qr/$(printf '%s' "$c" | tr -c 'A-Za-z0-9._-' '_').png" -s 6 -m 2 "$l" 2>/dev/null || true
	echo "QR $c:"
	qrencode -t ansiutf8 -m 1 "$l" 2>/dev/null || true
done < "$WORK/qr"
echo "То же самое — в $INFO, QR-картинки — в /root/vpn-qr/. Журнал установки: $LOG"
echo "Заняло $(($(date +%s) - START)) с."
verdict
exit $((FAILS > 0))

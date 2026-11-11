#!/bin/bash
# install-vpn.sh — свой VPN «под ключ» на чистом сервере Ubuntu 22.04/24.04 или Debian 12.
#
# Скрипт спросит, есть ли у вас домен, и поставит один из двух вариантов:
#   • С доменом (лучше): VLESS + XHTTP + Reality «steal-oneself» на порту 2083 —
#     SNI ваш домен, а тому, кто прощупывает сервер, Reality показывает настоящий сайт с этого же сервера;
#     nginx на 443: сайт-заглушка, панель и подписка за доменом по секретным путям; Let's Encrypt.
#     Нужна A-запись домена на IP сервера (в Cloudflare — серое облако, Proxy выключен).
#   • Без домена: VLESS + XHTTP + Reality на порту 2083 под крупный чужой сайт (скрипт сам проверит
#     и выберет подходящий). Ссылки привязаны к IP сервера, панель — https://IP:порт/секретный-путь/.
# В обоих: 3x-ui 3.3.1 + Xray 26.6.1 (sha256 закреплены), BBR, IPv6 выключен, swap, фаервол ufw,
# fail2ban против подбора пароля SSH, бэкап для переезда — вручную (vpn-backup.sh), сам не запускается.
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
#   --domain ДОМЕН    свой домен: A-запись на этот сервер (с токеном Cloudflare в CF_API_TOKEN скрипт
#                     поставит её сам, если её нет; без флага в терминале — выбор домена из Cloudflare)
#   --no-domain       без домена: Reality на 2083 под крупный чужой сайт
#   --sni САЙТ        (без домена) под какой сайт маскироваться вместо автовыбора, например www.samsung.com
#   --panel-local     (без домена) панель только на 127.0.0.1 — заходить через SSH-туннель, снаружи не видна
#   --no-ip-cert      (без домена) не брать сертификат Let's Encrypt на IP: подписка только внутри сервера
#                     (в QR — прямые ссылки), панель с самоподписанным сертификатом. По умолчанию сертификат
#                     берётся (нужен открытый TCP 80): подписка по https://IP:2096/…, панель без предупреждений
#   --clients N       сколько клиентов (устройств) создать, по умолчанию 1; остальные — в панели
#   --port N          порт подключения (по умолчанию 2083, как у основного сервера); на уже
#                     установленном сервере переносит подключение — клиентам выдать новые ссылки
#   --exit РЕЖИМ      куда выходит трафик клиентов:
#                       direct  — с IP сервера (по умолчанию, быстрее всего);
#                       warp    — всё через Cloudflare WARP: IP сервера не виден сайтам,
#                                 но бывают капчи Google и потолок около 100 Мбит/с;
#                       warp-ru — российские сайты через WARP, остальное напрямую
#                       chain   — через другой мой сервер (его IP как выход); нужен --exit-host
#                     выбор запоминается; переключить WARP потом — vpn-warp off|on|ru
#   --ssh-key-only    выключить вход по паролю (только если у root уже есть SSH-ключ)
#   --no-fail2ban     не ставить fail2ban (запоминается; вернуть — --fail2ban)
#   --no-ufw          не трогать фаервол (запоминается; вернуть — --ufw)
#   --tz ЗОНА         часовой пояс сервера (по умолчанию Europe/Moscow; запоминается)
#   --skip-dns-check  не сверять A-запись домена с IP сервера
#   --skip-ip-check   не проверять до установки, доступен ли IP из России
#   --check           только проверить: службы, туннель, доступность портов из России и Европы
#   --warp off|on|ru  быстро переключить выход без переустановки (то же — команда vpn-warp):
#                     off — напрямую, on — всё через WARP, ru — российские сайты через WARP
#   --exit-host IP    (с --exit chain) IP старого сервера, через который выходить; его настроит скрипт по SSH
#                     (можно ubuntu@IP — тогда пользователь ubuntu)
#   --exit-ssh-port N порт SSH старого сервера (по умолчанию 22); пароль — в EXIT_PASS или спросит
#   --exit-ssh-user И пользователь на старом сервере (по умолчанию root; AWS и Oracle — ubuntu). Не root —
#                     настройка через sudo; пароль sudo, если нужен, — EXIT_SUDO_PASS или спросит
#   --exit-ssh-key Ф  вместо пароля — файл SSH-ключа к старому серверу (OpenSSH, PEM, PKCS#8 или
#                     PuTTY .ppk; парольная фраза — в EXIT_KEY_PASS). На вопросе ключ можно вставить целиком
#   --exit-port N     порт цепочки на старом сервере (по умолчанию 2087)
#   --exit-stop-xui   выключить 3x-ui на старом сервере (если он теперь только выход); --exit-keep-xui — оставить
#   --bot             (с доменом в Cloudflare) поставить или обновить Телеграм-бота для управления VPN: клиенты,
#                     статистика, проверка блокировки, бэкапы, переезд. Токены — CF_API_TOKEN и VPN_BOT_TOKEN в
#                     окружении или спросит; владелец — VPN_BOT_ADMIN_ID или привязка в терминале (написать боту)
#   --no-bot          не ставить бота и не спрашивать про него (запоминается)
# Повторный запуск безопасен: ключи, пароли, клиенты и выбранный выход сохраняются (/etc/vpn-install.env).
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
# www.microsoft.com из списков убран: 2026-11-10 Reality (Xray 26.6.1) с ним не проходит рукопожатие — ни на
# одном из двух проверенных хостингов, — хотя openssl он устраивает (TLS 1.3, X25519, h2); 13 остальных проходят.
SNI_CANDIDATES="www.apple.com swdist.apple.com images.apple.com www.samsung.com dl.google.com
www.nvidia.com www.oracle.com www.intel.com www.dell.com www.hp.com www.asus.com www.cisco.com www.amazon.com"

DOMAIN=
NO_DOMAIN=0
SNI_ARG=
PANEL_LOCAL_ARG=
IP_CERT_ARG=
SUB_TLS=0
IP_CERT_OK=0
IPK=
CLIENTS=1
PORT_ARG=
EXIT_MODE=
SSH_KEY_ONLY=0
DO_F2B=     # пусто — как в прошлый раз, по умолчанию 1
DO_UFW=
TZ_NAME=
SKIP_DNS=0
SKIP_IP_CHECK=0
CHECK_ONLY=0
WARP_CMD=
EXIT_HOST=
EXIT_SSH_PORT=
EXIT_SSH_USER=
EXIT_SSH_KEY=
EXIT_KEY_TEXT=
EXIT_PORT_ARG=
EXIT_STOP_XUI=
BOT_ARG=     # --bot / --no-bot; пусто — как в прошлый раз или спросить
TEST_SELFSIGNED=0   # только для проверки самого скрипта: самоподписанный сертификат вместо Let's Encrypt
ACME_STAGING=0      # только для проверки: тестовый сервер Let's Encrypt
while [ $# -gt 0 ]; do
	case $1 in   # у опции нет значения — сказать об этом, а не молча выйти на shift 2
		--domain | --sni | --clients | --port | --exit | --exit-host | --exit-ssh-port | --exit-ssh-user | --exit-ssh-key | --exit-port | --tz)
			[ $# -ge 2 ] && [ -n "$2" ] || { echo "опции $1 нужно значение (см. --help)" >&2; exit 2; } ;;
	esac
	case $1 in
		--domain) DOMAIN=${2:-}; shift 2 ;;
		--no-domain) NO_DOMAIN=1; shift ;;
		--sni) SNI_ARG=${2:-}; shift 2 ;;
		--panel-local) PANEL_LOCAL_ARG=1; shift ;;
		--panel-public) PANEL_LOCAL_ARG=0; shift ;;
		--no-ip-cert) IP_CERT_ARG=0; shift ;;
		--ip-cert) IP_CERT_ARG=1; shift ;;
		--clients) CLIENTS=${2:-}; shift 2 ;;
		--port) PORT_ARG=${2:-}; shift 2 ;;
		--exit) EXIT_MODE=${2:-}; shift 2 ;;
		--exit-host) EXIT_HOST=${2:-}; shift 2 ;;
		--exit-ssh-port) EXIT_SSH_PORT=${2:-22}; shift 2 ;;
		--exit-ssh-user) EXIT_SSH_USER=${2:-}; shift 2 ;;
		--exit-ssh-key) EXIT_SSH_KEY=${2:-}; shift 2 ;;
		--exit-port) EXIT_PORT_ARG=${2:-}; shift 2 ;;
		--exit-stop-xui) EXIT_STOP_XUI=1; shift ;;
		--exit-keep-xui) EXIT_STOP_XUI=0; shift ;;
		--bot) BOT_ARG=1; shift ;;
		--no-bot) BOT_ARG=0; shift ;;
		--ssh-key-only) SSH_KEY_ONLY=1; shift ;;
		--no-fail2ban) DO_F2B=0; shift ;;
		--fail2ban) DO_F2B=1; shift ;;
		--no-ufw) DO_UFW=0; shift ;;
		--ufw) DO_UFW=1; shift ;;
		--tz) TZ_NAME=${2:-}; shift 2 ;;
		--skip-dns-check) SKIP_DNS=1; shift ;;
		--skip-ip-check) SKIP_IP_CHECK=1; shift ;;
		--check) CHECK_ONLY=1; shift ;;
		--warp) WARP_CMD=${2:-status}; if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
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
is_host() { [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]*[a-z][a-z0-9-]*$ ]]; }   # в последней части буква: 1.2.3.44 — не имя
state_val() { [ -f "$STATE" ] && sed -n "s/^$1='\(.*\)'\$/\1/p" "$STATE" | head -1; }
tty_flush() { local _; while IFS= read -r -t 0.1 _ < /dev/tty; do :; done 2>/dev/null || true; }   # выбросить набранное заранее
exit_host_parse() {  # EXIT_HOST «пользователь@адрес» → адрес (IPv4 или имя); пользователь — если не задан опцией
	local h
	h=$(printf '%s' "$EXIT_HOST" | tr -d '[:space:]')
	if [[ $h == *@* ]]; then
		[ -n "$EXIT_SSH_USER_ARG" ] || EXIT_SSH_USER_ARG=${h%%@*}
		h=${h#*@}
	fi
	h=$(norm_host "$h")
	[[ $h =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || is_host "$h" || return 1
	EXIT_HOST=$h
}
exit_ssh_defaults() {  # пользователь и порт SSH старого сервера: заданы — как заданы; тот же сервер — как в прошлый раз; другой — root:22
	if [ -n "$EXIT_HOST" ] && [ "$EXIT_HOST" != "$CHAIN_IP" ]; then
		EXIT_SSH_USER=${EXIT_SSH_USER_ARG:-root}
		EXIT_SSH_PORT=${EXIT_SSH_PORT_ARG:-22}
	else
		EXIT_SSH_USER=${EXIT_SSH_USER_ARG:-${CHAIN_SSH_USER:-root}}
		EXIT_SSH_PORT=${EXIT_SSH_PORT_ARG:-${CHAIN_SSH_PORT:-22}}
	fi
}
# --- Телеграм-бот vpn-bot: функции (src/bot.sh) и его код (src/bot/worker.js) ---
# shellcheck shell=bash
# shellcheck disable=SC2034  # переменные BOT_* читает install-vpn.sh, куда этот файл вшит
# Телеграм-бот vpn-bot в установщике: всё, что ходит в Cloudflare и Телеграм. build.py вшивает этот
# файл в install-vpn.sh (__EMBED_BOT_FUNCS__); здесь только функции и значения по умолчанию.
# Секреты — только в файлах $BOT_DIR (600), в argv процессов их нет: curl берёт заголовок с токеном
# Cloudflare из файла (-H @файл), адрес с токеном бота — из своего конфига (-K файл).
BOT_WORKER=${VPN_BOT_WORKER:-vpn-bot}   # имя воркера; занято VPN другого сервера — свой воркер (bot_validate)
BOT_WORKER_AUTO=1   # имя не задано явно (VPN_BOT_WORKER) и не запомнено прошлой установкой — его можно сменить
[ -z "${VPN_BOT_WORKER:-}" ] || BOT_WORKER_AUTO=0
BOT_CRON='0 */3 * * *'
CF_API_BASE=${CF_API_BASE:-https://api.cloudflare.com/client/v4}
TG_API_BASE=${TG_API_BASE:-https://api.telegram.org}
BOT_DIR=
BOT_AUTH_KEYS=${BOT_AUTH_KEYS:-/root/.ssh/authorized_keys}   # куда класть ключ бота на этом сервере
BOT_KNOWN_HOSTS=${BOT_KNOWN_HOSTS:-/etc/x-ui/chain/known_hosts}   # ключ хоста выхода (его запомнила цепочка)
BOT_HOST_KEYS=${BOT_HOST_KEYS:-/etc/ssh/ssh_host_*_key.pub}   # ключи этого сервера — бот сверяет их при входе
BOT_BACKUP_CMD=${BOT_BACKUP_CMD:-/usr/local/bin/vpn-backup.sh}

jget() {  # jget ПУТЬ ← JSON на stdin: значение по пути «a.0.b» (числа — индексы списков); нет — пусто
	python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in sys.argv[1].split("."):
    if isinstance(d, list):
        try:
            d = d[int(k)]
        except (ValueError, IndexError):
            d = None
    elif isinstance(d, dict):
        d = d.get(k)
    else:
        d = None
    if d is None:
        sys.exit(0)
if isinstance(d, bool):
    print("true" if d else "false")
elif isinstance(d, (dict, list)):
    print(json.dumps(d, ensure_ascii=False))
else:
    print(d)' "$1"
}
cf_ok() { python3 -I -c 'import json, sys; sys.exit(0 if json.load(sys.stdin).get("success") is True else 1)' 2> /dev/null; }
cf_err() {  # первая ошибка ответа Cloudflare: «текст (код N)»
	python3 -I -c '
import json, sys
try:
    e = (json.load(sys.stdin).get("errors") or [{}])[0]
except Exception:
    e = {}
print("%s (код %s)" % (e.get("message") or "нет ответа", e.get("code", "-")))'
}

bot_init_secrets() {  # BOT_CF_TOKEN / BOT_TG_TOKEN → файлы в $BOT_DIR (600), переменные стираются
	if [ -z "${BOT_DIR:-}" ]; then
		if [ -n "${WORK:-}" ]; then
			BOT_DIR=$WORK/bot
		else   # вопросы установщика идут раньше, чем появляется $WORK: свой каталог (его убирает и on_exit)
			BOT_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/vpn-bot.XXXXXX")
			trap 'rm -rf "$BOT_DIR"' EXIT
		fi
	fi
	(umask 077 && mkdir -p "$BOT_DIR")
	if [ -n "${BOT_CF_TOKEN:-}" ]; then
		(umask 077 && printf 'Authorization: Bearer %s\n' "$BOT_CF_TOKEN" > "$BOT_DIR/cf.hdr" && printf '%s' "$BOT_CF_TOKEN" > "$BOT_DIR/cf.token")
	fi
	if [ -n "${BOT_TG_TOKEN:-}" ]; then (umask 077 && printf '%s' "$BOT_TG_TOKEN" > "$BOT_DIR/tg.token"); fi
	unset BOT_CF_TOKEN BOT_TG_TOKEN
}
bot_have_cf_token() { [ -n "${BOT_CF_TOKEN:-}" ] || { [ -n "${BOT_DIR:-}" ] && [ -s "$BOT_DIR/cf.hdr" ]; }; }

cf_api() {  # cf_api МЕТОД ПУТЬ [аргументы curl…] → тело ответа; код ≠ 0 — нет ответа
	local m=$1 p=$2
	shift 2
	curl -sS --max-time 60 -X "$m" -H @"$BOT_DIR/cf.hdr" "$@" "$CF_API_BASE$p"
}

tg_api() {  # tg_api МЕТОД [JSON_ФАЙЛ] → тело ответа; токен бота — в конфиге curl, не в argv
	local m=$1 data=${2:-} cfg rc=0
	cfg=$(umask 077 && mktemp "$BOT_DIR/tg.XXXXXX")
	printf 'url = "%s/bot%s/%s"\n' "$TG_API_BASE" "$(cat "$BOT_DIR/tg.token")" "$m" > "$cfg"
	if [ -n "$data" ]; then
		curl -sS --max-time 40 -K "$cfg" -H 'Content-Type: application/json' --data-binary @"$data" || rc=$?
	else
		curl -sS --max-time 40 -K "$cfg" || rc=$?
	fi
	rm -f "$cfg"
	return "$rc"
}

bot_template_url() {  # ссылка на создание токена Cloudflare с уже отмеченными правами — строкой: на первом вопросе
	# python3 может ещё не быть. В ней: workers_scripts edit, workers_kv_storage edit, account_settings read, zone read, dns edit
	printf '%s\n' 'https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22workers_scripts%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22workers_kv_storage%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22account_settings%22%2C%22type%22%3A%22read%22%7D%2C%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%2C%7B%22key%22%3A%22dns%22%2C%22type%22%3A%22edit%22%7D%5D&accountId=%2A&zoneId=all&name=vpn-bot'
}

bot_zone_candidates() {  # ИМЯ → само имя и родительские вплоть до двух меток, по строке
	local n=$1
	while :; do
		printf '%s\n' "$n"
		case $n in
			*.*.*) n=${n#*.} ;;
			*) break ;;
		esac
	done
}

cf_code() { python3 -I -c 'import json, sys
try:
    print(((json.load(sys.stdin).get("errors") or [{}])[0]).get("code", ""))
except Exception:
    print("")'; }

# ——— домен из Cloudflare: выбор на вопросах (dns_ask_token, dns_pick), запись — на шаге DNS (dns_apply) ———
bot_need_python() {  # python3 и curl нужны уже на вопросах (ответы Cloudflare); нет — поставить
	command -v python3 > /dev/null && command -v curl > /dev/null && return 0
	bot_say "Ставлю python3 и curl — без них не спросить Cloudflare о доменах…"
	apt-get -y -q -o DPkg::Lock::Timeout=600 update > /dev/null 2>&1 || true
	apt-get -y -q -o DPkg::Lock::Timeout=600 install python3 curl ca-certificates > /dev/null 2>&1
}

bot_public_ip() {  # внешний IPv4 — на вопросах (detect_ips установщика определена ниже); не узнать — пусто
	local u ip
	for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
		ip=$(curl -4 -fsS --max-time 8 "$u" 2> /dev/null | tr -d '[:space:]') || true
		if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then printf '%s' "$ip"; return 0; fi
	done
}

cf_zones() {  # активные домены, которые видит токен → DNS_ZONES («ID<TAB>ИМЯ» по строке); 1 и BOT_ERR
	local body   # не в $(…): BOT_ERR из подоболочки не вернулся бы
	BOT_ERR='' DNS_ZONES=''
	body=$(cf_api GET "/zones?per_page=50") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
	cf_ok <<< "$body" || { BOT_ERR="Cloudflare не принял токен ($(cf_err <<< "$body")) — скопирован целиком и с правами из ссылки?"; return 1; }
	DNS_ZONES=$(python3 -I -c 'import json, sys
for z in json.load(sys.stdin).get("result") or []:
    if z.get("status") == "active" and z.get("id") and z.get("name"):
        print(z["id"] + "\t" + z["name"])' <<< "$body")
}

dns_ask_token() {  # токен Cloudflare (из окружения или спросить, с ссылкой) и проверка списком доменов → DNS_ZONES
	local try
	if bot_have_cf_token; then
		bot_init_secrets
		if cf_zones; then return 0; fi
		bot_say "  ✗ токен из окружения: $BOT_ERR"
	fi
	bot_tty_ok || { BOT_ERR=${BOT_ERR:-"спросить токен Cloudflare некого (нет терминала)"}; return 1; }
	bot_say "Нужен токен Cloudflare: открой ссылку (права уже отмечены) → «Continue to summary» → «Create Token» → скопируй токен:"
	bot_say "  $(bot_template_url)"
	for try in 1 2 3; do
		bot_ask_secret "Токен Cloudflare: " || return 1
		if [ -z "$BOT_ANSWER" ]; then BOT_ERR="токен Cloudflare не введён"; continue; fi
		BOT_CF_TOKEN=$BOT_ANSWER
		bot_init_secrets
		if cf_zones; then return 0; fi
		bot_say "  ✗ $BOT_ERR"
	done
	return 1
}

dns_records() {  # dns_records ЗОНА ИМЯ → DNS_RECS: «ТИП<TAB>ID<TAB>ЗНАЧЕНИЕ<TAB>ОБЛАКО(0|1)» для A, AAAA, CNAME имени
	local body
	DNS_RECS=''
	body=$(cf_api GET "/zones/$1/dns_records?name=$2&per_page=100") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
	cf_ok <<< "$body" || { BOT_ERR="не прочитать DNS-записи $2 — $(cf_err <<< "$body")"; return 1; }
	DNS_RECS=$(python3 -I -c 'import json, sys
for r in json.load(sys.stdin).get("result") or []:
    if r.get("name") == sys.argv[1] and r.get("type") in ("A", "AAAA", "CNAME"):
        print("\t".join([r["type"], r.get("id", ""), str(r.get("content", "")), "1" if r.get("proxied") else "0"]))' "$2" <<< "$body")
}

dns_conflicts() {  # dns_conflicts ЗАПИСИ IP → что мешает направить имя на этот сервер без спроса; пусто — ничего
	local t id c p out=''
	while IFS=$'\t' read -r t id c p; do
		case $t in
			A) [ -n "$2" ] && [ "$c" = "$2" ] || out+="${out:+, }A-запись указывает на $c" ;;
			AAAA) out+="${out:+, }AAAA-запись $c (IPv6 на сервере выключается)" ;;
			CNAME) out+="${out:+, }CNAME на $c" ;;
		esac
	done <<< "$1"
	printf '%s' "$out"
}

dns_zone_of() {  # dns_zone_of ИМЯ → домен аккаунта (из DNS_ZONES), в котором лежит имя: «ID<TAB>ДОМЕН»; самый длинный
	local id z best='' bl=0
	while IFS=$'\t' read -r id z; do
		[ -n "$z" ] || continue
		if [ "$1" = "$z" ] || [[ $1 == *".$z" ]]; then
			if [ "${#z}" -gt "$bl" ]; then best="$id"$'\t'"$z" bl=${#z}; fi
		fi
	done <<< "$DNS_ZONES"
	printf '%s' "$best"
}

dns_pick() {  # выбрать домен из Cloudflare и адрес VPN на нём → DOMAIN DNS_ZONE_ID DNS_REPOINT; 1 и BOT_ERR
	local zones n i=1 ans zid zname name myip recs conflicts oz
	DNS_REPOINT=0 BOT_ERR=
	[ -n "${DNS_ZONES:-}" ] || cf_zones || return 1
	zones=$DNS_ZONES
	n=$(grep -c . <<< "$zones" || true)
	if [ "$n" = 0 ]; then
		BOT_ERR="в аккаунте Cloudflare нет доменов (или токен их не видит) — добавь домен в Cloudflare или ставь без домена"
		return 1
	fi
	if [ "$n" = 1 ]; then
		bot_say "Домен в Cloudflare: $(cut -f2 <<< "$zones")"
	else
		bot_say "Домены в Cloudflare:"
		while IFS=$'\t' read -r zid zname; do bot_say "  $i) $zname"; i=$((i + 1)); done <<< "$zones"
		while :; do
			bot_ask "Какой взять [1-$n]: " || return 1
			if [[ $BOT_ANSWER =~ ^[0-9]+$ ]] && [ "$BOT_ANSWER" -ge 1 ] && [ "$BOT_ANSWER" -le "$n" ]; then i=$BOT_ANSWER; break; fi
		done
	fi
	zid=$(sed -n "${i}p" <<< "$zones" | cut -f1)
	zname=$(sed -n "${i}p" <<< "$zones" | cut -f2)
	myip=$(bot_public_ip)
	while :; do
		bot_ask "Адрес VPN — Enter: сам $zname, или впиши поддомен (например, vpn): " || return 1
		ans=$(printf '%s' "$BOT_ANSWER" | tr 'A-Z' 'a-z' | tr -d '[:space:]')
		ans=${ans%.}
		case $ans in
			"" | "$zname") name=$zname ;;
			*".$zname") name=$ans ;;
			*)
				oz=$(dns_zone_of "$ans")
				if [ -n "$oz" ]; then   # вписали полное имя в другом домене аккаунта — берём тот домен
					zid=${oz%%$'\t'*} zname=${oz#*$'\t'} name=$ans
				elif [[ $ans == *.* ]] && ! bot_consent "Адрес будет $ans.$zname — так?"; then
					continue   # похоже на полное имя чужого домена, а не на поддомен
				else
					name=$ans.$zname
				fi
				;;
		esac
		if ! [[ $name =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9-]+$ ]]; then
			bot_say "  ✗ «$name» — не имя домена"
			continue
		fi
		dns_records "$zid" "$name" || return 1
		recs=$DNS_RECS
		conflicts=$(dns_conflicts "$recs" "$myip")
		[ -n "$conflicts" ] || break
		bot_say "Сейчас в Cloudflare у $name: $conflicts."
		# Там может работать сайт или другой VPN — по умолчанию не трогаем.
		if bot_consent "Перенаправить $name на этот сервер${myip:+ ($myip)}? Если там сайт или другой VPN, они перестанут открываться"; then
			DNS_REPOINT=1
			break
		fi
		bot_say "Тогда другое имя — например, поддомен."
	done
	DOMAIN=$name DNS_ZONE_ID=$zid
	bot_say "Адрес VPN: $DOMAIN"
}

dns_find_zone() {  # зона домена по имени (--domain без выбора из списка) → DNS_ZONE_ID; 1 и BOT_ERR
	local z body
	DNS_ZONE_ID=
	for z in $(bot_zone_candidates "$DOMAIN"); do
		body=$(cf_api GET "/zones?name=$z") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
		cf_ok <<< "$body" || { BOT_ERR="Cloudflare не принял токен ($(cf_err <<< "$body"))"; return 1; }
		DNS_ZONE_ID=$(jget result.0.id <<< "$body")
		[ -z "$DNS_ZONE_ID" ] || return 0
	done
	BOT_ERR="токен Cloudflare не видит домен $DOMAIN"
	return 1
}

dns_req() {  # dns_req МЕТОД [ID [JSON]] → запрос к записям зоны DNS_ZONE_ID; 1 и BOT_ERR
	local body
	if [ "$1" = DELETE ]; then
		body=$(cf_api DELETE "/zones/$DNS_ZONE_ID/dns_records/$2") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
	else
		printf '%s' "$3" > "$BOT_DIR/req.json"
		body=$(cf_api "$1" "/zones/$DNS_ZONE_ID/dns_records${2:+/$2}" -H 'Content-Type: application/json' --data-binary @"$BOT_DIR/req.json") ||
			{ BOT_ERR="Cloudflare не отвечает"; return 1; }
	fi
	cf_ok <<< "$body" || { BOT_ERR="Cloudflare не принял изменение DNS $DOMAIN — $(cf_err <<< "$body")"; return 1; }
}

dns_apply() {  # шаг DNS (IP известен): одна A-запись $DOMAIN → $PUBLIC_IP без облака → DNS_REPORT; 1 и BOT_ERR
	local recs conflicts t id c p keep='' keep_c='' keep_p='' json
	DNS_REPORT='' BOT_ERR=''
	dns_records "$DNS_ZONE_ID" "$DOMAIN" || return 1
	recs=$DNS_RECS
	conflicts=$(dns_conflicts "$recs" "$PUBLIC_IP")
	if [ -n "$conflicts" ] && [ "${DNS_REPOINT:-0}" != 1 ]; then
		# Домен задан флагом (выбора из списка не было) — спросить здесь, если есть кого; по умолчанию «нет».
		if bot_tty_ok; then
			bot_say "Сейчас в Cloudflare у $DOMAIN: $conflicts."
			if bot_consent "Перенаправить $DOMAIN на этот сервер ($PUBLIC_IP)? Если там сайт или другой VPN, они перестанут открываться"; then
				DNS_REPOINT=1
			else
				BOT_ERR="у $DOMAIN в Cloudflare $conflicts — не перенаправляю: выберите другое имя (поддомен) и запустите снова"
				return 1
			fi
		else
			BOT_ERR="у $DOMAIN в Cloudflare $conflicts — без согласия не перенаправляю: запустите установку в терминале (спросит) или выберите другое имя"
			return 1
		fi
	fi
	# Оставить A-запись, что уже указывает сюда, иначе первую; мешающее убрать ДО записи (CNAME не уживается с A).
	while IFS=$'\t' read -r t id c p; do
		if [ "$t" = A ] && [ "$c" = "$PUBLIC_IP" ] && [ -z "$keep" ]; then keep=$id keep_c=$c keep_p=$p; fi
	done <<< "$recs"
	if [ -z "$keep" ]; then
		while IFS=$'\t' read -r t id c p; do
			if [ "$t" = A ] && [ -z "$keep" ]; then keep=$id keep_c=$c keep_p=$p; fi
		done <<< "$recs"
	fi
	while IFS=$'\t' read -r t id c p; do
		[ -n "$t" ] && [ "$id" != "$keep" ] || continue
		dns_req DELETE "$id" || return 1
		DNS_REPORT+="удалена $t-запись $DOMAIN ($c)"$'\n'
	done <<< "$recs"
	json=$(python3 -I -c 'import json, sys; print(json.dumps({"type": "A", "name": sys.argv[1], "content": sys.argv[2], "proxied": False, "ttl": 1}))' "$DOMAIN" "$PUBLIC_IP")
	if [ -z "$keep" ]; then
		dns_req POST "" "$json" || return 1
		DNS_REPORT+="A-запись $DOMAIN → $PUBLIC_IP создана в Cloudflare"$'\n'
	elif [ "$keep_c" != "$PUBLIC_IP" ]; then
		dns_req PATCH "$keep" "$json" || return 1
		DNS_REPORT+="A-запись $DOMAIN перенаправлена с $keep_c на этот сервер ($PUBLIC_IP)"$'\n'
	elif [ "$keep_p" = 1 ]; then
		dns_req PATCH "$keep" "$json" || return 1
		DNS_REPORT+="у A-записи $DOMAIN выключено облако Cloudflare (с ним VPN не работает)"$'\n'
	fi
}

dns_wait() {  # запись только что поставлена: ждать, пока DNS отдаёт $DOMAIN → $PUBLIC_IP (до ~2 мин)
	local i a
	sleep "${DNS_WAIT_FIRST:-5}"   # не спрашивать сразу: ответ «нет такого имени» осел бы в кэше резолвера
	for i in $(seq 1 "${DNS_WAIT_TRIES:-24}"); do
		a=$(resolve "$DOMAIN" A 2> /dev/null || true)
		case " $a " in *" $PUBLIC_IP "*) return 0 ;; esac
		[ "$i" = "${DNS_WAIT_TRIES:-24}" ] || sleep "${DNS_WAIT_SLEEP:-5}"
	done
	return 1
}

bot_cf_check() {  # → BOT_ZONE BOT_ACC BOT_KV_ID BOT_SUBDOMAIN BOT_EXISTING(none|ours|foreign); 1 и BOT_ERR
	local z body n
	BOT_ZONE='' BOT_ACC='' BOT_KV_ID='' BOT_SUBDOMAIN='' BOT_EXISTING='' BOT_ERR=''
	for z in $(bot_zone_candidates "$DOMAIN"); do
		body=$(cf_api GET "/zones?name=$z") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
		if ! cf_ok <<< "$body"; then
			BOT_ERR="Cloudflare не принял токен ($(cf_err <<< "$body")) — скопирован целиком и с правами из ссылки?"
			return 1
		fi
		BOT_ZONE=$(jget result.0.id <<< "$body")
		[ -z "$BOT_ZONE" ] || { BOT_ACC=$(jget result.0.account.id <<< "$body"); break; }
	done
	if [ -z "$BOT_ZONE" ]; then
		BOT_ERR="токен Cloudflare не видит домен $DOMAIN: зоны для него нет в этом аккаунте или у токена нет права Zone Read"
		return 1
	fi
	body=$(cf_api GET "/zones/$BOT_ZONE/dns_records?type=A&name=$DOMAIN") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
	if ! cf_ok <<< "$body"; then BOT_ERR="у токена нет права DNS на зону домена — $(cf_err <<< "$body")"; return 1; fi
	n=$(python3 -I -c 'import json, sys; print(len(json.load(sys.stdin).get("result") or []))' <<< "$body")
	case $n in
		0) BOT_ERR="в Cloudflare нет A-записи $DOMAIN"; return 1 ;;
		1) ;;
		*) BOT_ERR="у $DOMAIN в Cloudflare $n A-записи, а бот при переезде меняет одну — оставьте одну"; return 1 ;;
	esac
	if [ "$(jget result.0.proxied <<< "$body")" = true ]; then
		BOT_ERR="у A-записи $DOMAIN в Cloudflare включён Proxy (оранжевое облако) — выключите его"
		return 1
	fi
	if [ "$(jget result.0.content <<< "$body")" != "$PUBLIC_IP" ]; then
		BOT_ERR="A-запись $DOMAIN в Cloudflare указывает на $(jget result.0.content <<< "$body"), а этот сервер — $PUBLIC_IP"
		return 1
	fi
	body=$(cf_api GET "/accounts/$BOT_ACC/storage/kv/namespaces?per_page=100") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
	if ! cf_ok <<< "$body"; then BOT_ERR="у токена нет права Workers KV Storage Edit — $(cf_err <<< "$body")"; return 1; fi
	BOT_KV_ID=$(python3 -I -c 'import json, sys
t = sys.argv[1]
print(next((n["id"] for n in json.load(sys.stdin).get("result") or [] if n.get("title") == t), ""))' "$BOT_WORKER-state" <<< "$body")
	body=$(cf_api GET "/accounts/$BOT_ACC/workers/subdomain") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
	if cf_ok <<< "$body"; then
		BOT_SUBDOMAIN=$(jget result.subdomain <<< "$body")
	elif [ "$(cf_code <<< "$body")" = 10000 ]; then
		BOT_ERR="у токена нет права Workers Scripts Edit — $(cf_err <<< "$body")"
		return 1
	fi
	body=$(cf_api GET "/accounts/$BOT_ACC/workers/scripts/$BOT_WORKER/settings") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
	if cf_ok <<< "$body"; then
		printf '%s' "$body" > "$BOT_DIR/settings.json"
		if python3 -I -c 'import json, sys
kv = sys.argv[1]
b = (json.load(sys.stdin).get("result") or {}).get("bindings") or []
ours = any(x.get("name") == "VPN_BOT_INSTALLER" and x.get("type") == "plain_text" for x in b) or \
       (kv != "" and any(x.get("type") == "kv_namespace" and x.get("name") == "STATE" and x.get("namespace_id") == kv for x in b))
sys.exit(0 if ours else 1)' "$BOT_KV_ID" <<< "$body"; then BOT_EXISTING=ours; else BOT_EXISTING=foreign; fi
	elif [ "$(cf_code <<< "$body")" = 10007 ]; then
		BOT_EXISTING=none
	else
		BOT_ERR="у токена нет права Workers Scripts Edit — $(cf_err <<< "$body")"
		return 1
	fi
}

bot_tg_check() {  # → BOT_USERNAME BOT_HOOK_URL; 1 и BOT_ERR
	local body
	BOT_USERNAME='' BOT_HOOK_URL='' BOT_ERR=''
	body=$(tg_api getMe) || { BOT_ERR="Телеграм не отвечает"; return 1; }
	BOT_USERNAME=$(jget result.username <<< "$body")
	if [ "$(jget ok <<< "$body")" != true ] || [ -z "$BOT_USERNAME" ]; then
		BOT_ERR="Телеграм не принял токен бота — скопирован целиком? (вида 123456789:AAE…)"
		return 1
	fi
	body=$(tg_api getWebhookInfo) || { BOT_ERR="Телеграм не отвечает"; return 1; }
	BOT_HOOK_URL=$(jget result.url <<< "$body")
}

bot_hook_is_ours() { [ -z "${BOT_HOOK_URL:-}" ] || [ "$BOT_HOOK_URL" = "https://$BOT_WORKER.${BOT_SUBDOMAIN:-}.workers.dev/tg" ]; }
bot_hook_host() {  # адрес вебхука без пути и логина: в пути у многих лежит сам токен бота — его не печатаем
	local h=${BOT_HOOK_URL#*://}
	h=${h%%[/?#]*}
	h=${h##*@}
	printf '%s://%s' "${BOT_HOOK_URL%%://*}" "$h"
}
bot_tg_fatal() {  # bot_tg_fatal ОТВЕТ → 0 и BOT_ERR, если ждать бессмысленно (бота читает другая программа, токен отозван)
	case $(jget error_code <<< "$1") in
		409) BOT_ERR="бота @$BOT_USERNAME уже читает другая программа (Телеграм: «$(jget description <<< "$1" | cut -c1-60)») — останови её или возьми для VPN отдельного бота у @BotFather" ;;
		401 | 404) BOT_ERR="Телеграм больше не принимает токен бота @$BOT_USERNAME" ;;
		*) return 1 ;;
	esac
}

# Вопросы человеку — через терминал (в тестах — дескриптор BOT_TTY_FD с ответами, вопросы в $WORK/tty.out).
bot_tty_ok() { [ -n "${BOT_TTY_FD:-}" ] || { : > /dev/tty; } 2> /dev/null; }
bot_say() { if [ -n "${BOT_TTY_FD:-}" ]; then printf '%s\n' "$*" >> "$WORK/tty.out"; else printf '%s\n' "$*" > /dev/tty; fi; }
bot_ask() {  # bot_ask ВОПРОС → BOT_ANSWER; 1 — спросить некого
	BOT_ANSWER=
	bot_tty_ok || return 1
	if [ -n "${BOT_TTY_FD:-}" ]; then
		printf '%s' "$1" >> "$WORK/tty.out"
		IFS= read -r BOT_ANSWER <&"$BOT_TTY_FD" || BOT_ANSWER=
	else
		printf '%s' "$1" > /dev/tty
		IFS= read -r BOT_ANSWER < /dev/tty || BOT_ANSWER=
	fi
}
bot_tty_flush() {  # выбросить набранное заранее: поздний вопрос не должен получить ответ, набранный на другой
	local _
	[ -z "${BOT_TTY_FD:-}" ] || return 0
	while IFS= read -r -t 0.1 _ < /dev/tty; do :; done 2> /dev/null || true
}
bot_consent() {  # bot_consent ВОПРОС → 0 только на явное «да»
	bot_tty_flush
	bot_ask "$1 [y/N]: " || return 1
	case $BOT_ANSWER in y | Y | yes | Yes | д | Д | да | Да | ДА) return 0 ;; *) return 1 ;; esac
}

# shellcheck disable=SC2120  # срок ожидания — необязательный аргумент (в тестах — короткий)
bot_pair() {  # bot_pair [СЕКУНД=300] → BOT_ADMIN_ID BOT_ADMIN_NAME: кто написал боту и подтвердил «это я»
	local secs=${1:-300} deadline left offset=0 body uid fid fname uname ctype try
	BOT_ADMIN_ID='' BOT_ADMIN_NAME='' BOT_ERR=''
	bot_tty_ok || { BOT_ERR="привязать владельца можно только в терминале (или задайте VPN_BOT_ADMIN_ID)"; return 1; }
	if [ -n "${BOT_HOOK_URL:-}" ]; then   # чужой вебхук доходит сюда только с явного «да» (bot_validate)
		echo '{"drop_pending_updates":false}' > "$BOT_DIR/req.json"
		body=$(tg_api deleteWebhook "$BOT_DIR/req.json") || { BOT_ERR="Телеграм не отвечает"; return 1; }
		[ "$(jget ok <<< "$body")" = true ] || { BOT_ERR="Телеграм не снял вебхук бота @$BOT_USERNAME — $(jget description <<< "$body")"; return 1; }
	fi
	# Что уже лежит в очереди (сообщения друзей, если ботом пользовались), — не повод спрашивать «это ты?»:
	# offset −1 отдаёт последнее обновление и забывает прежние, ждём следующих. allowed_updates не задаём —
	# Телеграм запомнил бы его за ботом.
	for try in 1 2 3; do
		echo '{"offset":-1,"timeout":0}' > "$BOT_DIR/req.json"
		body=$(tg_api getUpdates "$BOT_DIR/req.json") || body=''
		if [ "$(jget ok <<< "$body")" = true ]; then
			uid=$(jget result.0.update_id <<< "$body")
			[ -z "$uid" ] || offset=$((uid + 1))
			break
		fi
		! bot_tg_fatal "$body" || return 1
		[ "$try" = 3 ] || sleep "${BOT_TG_PAUSE:-3}"
	done
	bot_say "Открой https://t.me/$BOT_USERNAME и отправь боту любое сообщение — так я узнаю, что это ты (жду до $(((secs + 59) / 60)) мин)…"
	deadline=$(($(date +%s) + secs))
	while left=$((deadline - $(date +%s))) && [ "$left" -gt 0 ]; do
		printf '{"offset":%s,"timeout":%s}' "$offset" "$((left < 25 ? left : 25))" > "$BOT_DIR/req.json"
		body=$(tg_api getUpdates "$BOT_DIR/req.json") || body=''
		if [ "$(jget ok <<< "$body")" != true ]; then   # 409/401 — конец; 429, 5xx, обрыв — пауза, не долбить Телеграм
			! bot_tg_fatal "$body" || return 1
			sleep "${BOT_TG_PAUSE:-3}"
			continue
		fi
		while IFS=$'\t' read -r uid fid fname uname ctype; do
			offset=$((uid + 1))
			[ "$ctype" = private ] || continue
			# Ответ отдаёт полное управление VPN — только явное «да» (Enter — «нет»).
			bot_ask "Это ты: $fname${uname:+ (@$uname)}, id $fid? [y/N]: " || continue
			case $BOT_ANSWER in y | Y | yes | Yes | д | Д | да | Да | ДА) ;; *) continue ;; esac
			BOT_ADMIN_ID=$fid
			BOT_ADMIN_NAME=$fname
			printf '{"offset":%s,"timeout":0}' "$offset" > "$BOT_DIR/req.json"
			tg_api getUpdates "$BOT_DIR/req.json" > /dev/null || true
			return 0
		done < <(python3 -I -c 'import json, sys
for u in json.load(sys.stdin).get("result") or []:
    m = u.get("message") or {}
    f = m.get("from") or {}
    clean = lambda v: str(v or "").replace("\t", " ").replace("\n", " ")
    print("\t".join([str(u.get("update_id", 0)), str(f.get("id", "")), clean(f.get("first_name")), clean(f.get("username")), clean((m.get("chat") or {}).get("type"))]))' <<< "$body" 2> /dev/null)
	done
	BOT_ERR="не дождался сообщения боту @$BOT_USERNAME"
	return 1
}

bot_has_binding() {  # bot_has_binding ИМЯ — есть ли у прежней версии нашего воркера такая привязка
	[ "${BOT_EXISTING:-}" = ours ] && [ -s "$BOT_DIR/settings.json" ] && python3 -I -c 'import json, sys
b = (json.load(open(sys.argv[1])).get("result") or {}).get("bindings") or []
sys.exit(0 if any(x.get("name") == sys.argv[2] for x in b) else 1)' "$BOT_DIR/settings.json" "$1"
}

bot_other_server() {  # наш воркер управляет VPN другого сервера (второй сервер в том же аккаунте)? → 0, BOT_OTHER_DN/IP
	local dn zone ip='' body
	BOT_OTHER_DN='' BOT_OTHER_IP=''
	[ "${BOT_EXISTING:-}" = ours ] || return 1
	dn=$(bot_plain DNS_NAME)
	[ -n "$dn" ] && [ "$dn" != "$DOMAIN" ] || return 1
	zone=$(bot_plain CF_ZONE_ID)
	if body=$(cf_api GET "/zones/${zone:-$BOT_ZONE}/dns_records?type=A&name=$dn") && cf_ok <<< "$body"; then
		ip=$(jget result.0.content <<< "$body")
	fi
	[ "$ip" != "$PUBLIC_IP" ] || return 1   # тот же сервер, сменился только домен
	BOT_OTHER_DN=$dn BOT_OTHER_IP=$ip
}
bot_other_server_ok() {  # имя воркера задано явно, а он управляет VPN другого сервера — забрать только с «да»
	bot_other_server || return 0
	bot_consent "Воркер $BOT_WORKER в этом аккаунте Cloudflare управляет VPN на $BOT_OTHER_DN${BOT_OTHER_IP:+ ($BOT_OTHER_IP)} — перенастроить его на этот сервер? Тот VPN останется без бота, а его бэкап в Cloudflare заменится бэкапом этого" && return 0
	BOT_ERR="воркер $BOT_WORKER уже управляет VPN на $BOT_OTHER_DN — не трогаю. Для этого сервера запустите без VPN_BOT_WORKER: скрипт заведёт отдельный воркер"
	return 1
}
bot_worker_name() {  # bot_worker_name N → имя отдельного воркера для этого домена: vpn-bot-<домен>[-N], до 63 символов
	local w
	w=vpn-bot-$(printf '%s' "$DOMAIN" | tr 'A-Z.' 'a-z-' | tr -cd 'a-z0-9-')
	if [ "$1" -gt 1 ]; then w=${w:0:$((62 - ${#1}))}; w="${w%%-}-$1"; else w=${w:0:63}; fi
	while [ "${w%-}" != "$w" ]; do w=${w%-}; done
	printf '%s' "$w"
}

bot_kv_admin() {  # владелец из KV нашего воркера (admin:id — так его хранит бот, поставленный руками) → id или пусто
	local v
	[ "${BOT_EXISTING:-}" = ours ] && [ -n "${BOT_KV_ID:-}" ] || return 0
	v=$(cf_api GET "/accounts/$BOT_ACC/storage/kv/namespaces/$BOT_KV_ID/values/admin%3Aid" 2> /dev/null) || return 0
	if [[ $v =~ ^[0-9]+$ ]]; then printf '%s' "$v"; fi
}

bot_validate() {  # всё, что проверяется до установки: токены, чужой воркер и вебхук, бот другого сервера, владелец
	local n=0 was why
	BOT_USERNAME='' BOT_HOOK_URL='' BOT_ADMIN_ID='' BOT_ADMIN_NAME=''
	bot_cf_check || return 1
	# Имя не задано явно, а воркер с ним — чужой или управляет VPN другого сервера: этому серверу — свой воркер.
	while [ "${BOT_WORKER_AUTO:-0}" = 1 ]; do
		if [ "$BOT_EXISTING" = foreign ]; then
			why="в аккаунте уже есть и он не от установщика"
		elif bot_other_server; then
			why="управляет VPN на $BOT_OTHER_DN"
		else
			break
		fi
		n=$((n + 1))
		[ "$n" -le 5 ] || { BOT_ERR="не нашлось свободного имени воркера — задайте своё: VPN_BOT_WORKER=имя"; return 1; }
		was=$BOT_WORKER
		BOT_WORKER=$(bot_worker_name "$n")
		printf '  …     воркер %s %s — для этого сервера отдельный бот: воркер %s\n' "$was" "$why" "$BOT_WORKER"
		bot_cf_check || return 1
	done
	if [ "$BOT_EXISTING" = foreign ] && ! bot_consent "Воркер $BOT_WORKER в аккаунте Cloudflare уже есть, и он не от установщика — перезаписать?"; then
		BOT_ERR="воркер $BOT_WORKER в аккаунте Cloudflare не от установщика — не трогаю"
		return 1
	fi
	bot_other_server_ok || return 1
	if [ -s "$BOT_DIR/tg.token" ]; then
		bot_tg_check || return 1
		# Чужой вебхук (вставили токен рабочего бота) — только с явного «да», будет привязка или нет.
		if ! bot_hook_is_ours && ! bot_consent "Бот @$BOT_USERNAME сейчас подключён к $(bot_hook_host) — перенастроить его на этот сервер?"; then
			BOT_ERR="бот @$BOT_USERNAME подключён к другому адресу ($(bot_hook_host)) — его не трогаю; для этого VPN нужен отдельный бот: @BotFather → /newbot"
			return 1
		fi
	elif [ "$BOT_EXISTING" != ours ]; then
		BOT_ERR="нужен токен бота от @BotFather"
		return 1
	fi
	if [ -n "${VPN_BOT_ADMIN_ID:-}" ]; then
		if ! [[ $VPN_BOT_ADMIN_ID =~ ^[0-9]+$ ]]; then
			BOT_ERR="VPN_BOT_ADMIN_ID — числовой id в Телеграме (вида 123456789), а не @имя"
			return 1
		fi
		BOT_ADMIN_ID=$VPN_BOT_ADMIN_ID
	elif bot_has_binding ADMIN_ID; then
		:   # владелец прежний
	elif BOT_ADMIN_ID=$(bot_kv_admin) && [ -n "$BOT_ADMIN_ID" ]; then
		:   # бот, поставленный руками: владелец записан в его KV — сохраняется
	elif [ ! -s "$BOT_DIR/tg.token" ]; then
		BOT_ERR="у бота нет владельца, а привязать его можно только по токену бота — дай токен бота (или VPN_BOT_ADMIN_ID)"
		return 1
	else
		bot_pair || return 1
	fi
}

bot_plain() {  # bot_plain ИМЯ → значение plain_text прежней версии нашего воркера (нет — пусто)
	[ -s "$BOT_DIR/settings.json" ] || return 0
	python3 -I -c 'import json, sys
b = (json.load(open(sys.argv[1])).get("result") or {}).get("bindings") or []
print(next((x.get("text", "") for x in b if x.get("name") == sys.argv[2] and x.get("type") == "plain_text"), ""))' "$BOT_DIR/settings.json" "$1"
}

bot_key_fpr() { grep -E ' vpn-bot$' "$BOT_AUTH_KEYS" 2> /dev/null | head -1 | ssh-keygen -lf - 2> /dev/null | awk '{print $2}' || true; }

bot_keys() {  # bot_keys НУЖЕН_ВЫХОД(0|1) → BOT_KEY_NEW; в authorized_keys ровно одна строка «… vpn-bot»
	local need_exit=${1:-0} f=$BOT_AUTH_KEYS tmp have
	# Прежний ключ — только если воркер держит именно его (отпечаток лежит рядом с ключом, в той же загрузке:
	# оборванный запуск мог заменить строку, не успев отдать новый ключ воркеру) и выход остаётся (ключ входа —
	# он же ключ выхода: ушли с выхода — ключ новый, и старый выход прежний больше не пустит).
	if [ "$need_exit" = 0 ] && [ "${BOT_EXISTING:-}" = ours ] && bot_has_binding ENTRY_SSH_KEY; then
		have=$(bot_key_fpr)
		if [ -n "$have" ] && [ "$have" = "$(bot_plain ENTRY_SSH_KEY_FPR)" ] &&
			! { bot_has_binding EXIT_SSH_KEY && [ "${EXIT_MODE:-}" != chain ]; }; then
			BOT_KEY_NEW=0
			return 0
		fi
	fi
	rm -f "$BOT_DIR/id" "$BOT_DIR/id.pub"
	ssh-keygen -q -t ed25519 -N '' -C vpn-bot -f "$BOT_DIR/id" > /dev/null
	install -d -m 700 "$(dirname "$f")"
	tmp=$(mktemp "$f.XXXXXX")
	{
		grep -vE ' vpn-bot$' "$f" 2> /dev/null || true
		cat "$BOT_DIR/id.pub"
	} > "$tmp"
	chmod 600 "$tmp"
	mv -f "$tmp" "$f"
	BOT_KEY_NEW=1
}

bot_panel_token() {  # → BOT_PANEL_NEW; в api_tokens ровно одна строка name='vpn-bot', открытый текст — в $BOT_DIR
	local n out t
	BOT_ERR=
	n=$(sqlite3 "$DB" "select count(*) from api_tokens where name='vpn-bot';") || { BOT_ERR="не прочитать базу 3x-ui"; return 1; }
	if [ "$n" = 1 ] && bot_has_binding PANEL_TOKEN; then
		BOT_PANEL_NEW=0
		return 0
	fi
	sqlite3 "$DB" "delete from api_tokens where name='vpn-bot';" || { BOT_ERR="не записать базу 3x-ui"; return 1; }
	out=$("$XUI" setting -getApiToken 2>&1) || true
	t=$(sed -n 's/^apiToken: *//p' <<< "$out" | tail -1)
	[ -n "$t" ] || { BOT_ERR="x-ui не выдал API-токен: $(head -c 200 <<< "$out")"; return 1; }
	sqlite3 "$DB" "update api_tokens set name='vpn-bot' where id=(select max(id) from api_tokens);" || { BOT_ERR="не записать базу 3x-ui"; return 1; }
	(umask 077 && printf '%s' "$t" > "$BOT_DIR/panel.token")
	BOT_PANEL_NEW=1
}

bot_exit_bindings() {  # → $BOT_DIR/exit.list: «plain|secret|inherit ИМЯ [ЗНАЧЕНИЕ|@ФАЙЛ]» про выход цепочки
	local out=$BOT_DIR/exit.list
	: > "$out"
	[ "${EXIT_MODE:-}" = chain ] && [ -n "${CHAIN_IP:-}" ] || return 0
	printf 'plain %s %s\n' EXIT_HOST "$CHAIN_IP" EXIT_PORT "${CHAIN_SSH_PORT:-22}" EXIT_USER "${CHAIN_SSH_USER:-root}" \
		CHAIN_PORT "$CHAIN_PORT" EXIT_FW "${CHAIN_FW:-ufw}" >> "$out"
	# Доступ бота к выходу: новый — если в этом запуске выход настроен с ключом бота и sudo там без пароля;
	# прежний — если выход тот же; иначе без доступа (при переезде бот покажет команду для ручного запуска).
	if [ "${BOT_EXIT_SETUP:-0}" = 1 ] && [ "${EXIT_SUDO:-}" != pass ] && [ -s "$BOT_DIR/id" ] && [ -s "$BOT_KNOWN_HOSTS" ]; then
		ssh-keygen -lf "$BOT_KNOWN_HOSTS" | awk '{print $2}' |
			python3 -I -c 'import json, sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))' > "$BOT_DIR/exit.fpr"
		if [ "$(cat "$BOT_DIR/exit.fpr")" != "[]" ]; then
			printf 'secret EXIT_SSH_KEY @%s\nsecret EXIT_HOSTKEY_FPR @%s\n' "$BOT_DIR/id" "$BOT_DIR/exit.fpr" >> "$out"
		fi
	elif bot_has_binding EXIT_SSH_KEY && bot_has_binding EXIT_HOSTKEY_FPR && [ "$(bot_plain EXIT_HOST)" = "$CHAIN_IP" ]; then
		printf 'inherit EXIT_SSH_KEY\ninherit EXIT_HOSTKEY_FPR\n' >> "$out"
	fi
}

# ——— развёртывание ———
# Имена привязок, которыми распоряжается установщик. Прочие привязки нашего воркера (например,
# GLOBALPING_TOKEN, заданный владельцем руками) при обновлении наследуются как есть.
BOT_MANAGED="STATE PANEL_ORIGIN PANEL_BASE SUB_PREFIX CF_ZONE_ID DNS_NAME ENTRY_USER ENTRY_SSH_PORT SELF_ORIGIN
VPN_BOT_INSTALLER CF_API_TOKEN SELFTEST_SECRET BOT_TOKEN WEBHOOK_SECRET ADMIN_ID PANEL_TOKEN ENTRY_SSH_KEY ENTRY_SSH_KEY_FPR
EXIT_HOST EXIT_PORT EXIT_USER CHAIN_PORT EXIT_FW EXIT_SSH_KEY EXIT_HOSTKEY_FPR EXIT_SSH_PASS"

bot_rand() { python3 -I -c 'import secrets; print(secrets.token_urlsafe(24))'; }
bot_put_secret() { (umask 077 && printf '%s' "$2" > "$BOT_DIR/$1"); }   # bot_put_secret ФАЙЛ ЗНАЧЕНИЕ
bot_http() { curl -sS --max-time "${2:-40}" -H @"$BOT_DIR/selftest.hdr" "$BOT_ORIGIN$1"; }   # bot_http ПУТЬ [СЕКУНД] — к самому воркеру
bot_alive() { [ "$(curl -sS --max-time 15 "$1/healthz" 2> /dev/null)" = ok ]; }   # bot_alive АДРЕС_ВОРКЕРА

bot_wipe() {  # стереть секреты из $BOT_DIR (они уже в воркере или больше не нужны)
	local f
	for f in id id.pub panel.token tg.token cf.token cf.hdr metadata.json webhook.secret selftest.secret selftest.hdr \
		admin.id hook.json req.json exit.fpr fpr.json backup.meta bindings.list settings.json; do
		rm -f "${BOT_DIR:?}/$f"
	done
}

bot_secret_or_inherit() {  # ИМЯ ФАЙЛ → строка привязки: новый секрет из файла или наследование от прежней версии
	if [ -s "$BOT_DIR/$2" ]; then
		printf 'secret %s @%s\n' "$1" "$BOT_DIR/$2"
	elif [ "${BOT_EXISTING:-}" = ours ]; then
		printf 'inherit %s\n' "$1"
	else
		BOT_ERR="для нового бота нет $1"
		return 1
	fi
}

bot_deploy() {  # → BOT_ORIGIN BOT_REPORT; 1 и BOT_ERR. Секреты из $BOT_DIR стираются при любом исходе
	local rc=0
	bot_deploy_steps || rc=1
	bot_wipe
	return "$rc"
}

bot_deploy_steps() {
	local body sub f p kb res kfpr subnew=0 tries=15
	BOT_ERR='' BOT_REPORT=''
	if [ -z "${BOT_KV_ID:-}" ]; then
		printf '{"title":"%s-state"}' "$BOT_WORKER" > "$BOT_DIR/req.json"
		body=$(cf_api POST "/accounts/$BOT_ACC/storage/kv/namespaces" -H 'Content-Type: application/json' --data-binary @"$BOT_DIR/req.json") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
		cf_ok <<< "$body" || { BOT_ERR="не создать хранилище KV — $(cf_err <<< "$body")"; return 1; }
		BOT_KV_ID=$(jget result.id <<< "$body")
	fi
	if [ -z "${BOT_SUBDOMAIN:-}" ]; then
		sub=vpnbot-$(python3 -I -c 'import secrets, string; print("".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(6)))')
		printf '{"subdomain":"%s"}' "$sub" > "$BOT_DIR/req.json"
		body=$(cf_api PUT "/accounts/$BOT_ACC/workers/subdomain" -H 'Content-Type: application/json' --data-binary @"$BOT_DIR/req.json") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
		if ! cf_ok <<< "$body"; then
			BOT_ERR="в аккаунте Cloudflare нет адреса workers.dev, и создать его не вышло ($(cf_err <<< "$body")): открой dash.cloudflare.com → Workers & Pages один раз и запусти установку снова"
			return 1
		fi
		BOT_SUBDOMAIN=$(jget result.subdomain <<< "$body")
		BOT_SUBDOMAIN=${BOT_SUBDOMAIN:-$sub}
		subnew=1
	fi
	BOT_ORIGIN=https://$BOT_WORKER.$BOT_SUBDOMAIN.workers.dev
	# Секреты этого развёртывания: самопроверка — всегда новый; вебхук — новый, если есть токен бота.
	bot_put_secret selftest.secret "$(bot_rand)"
	(umask 077 && printf 'X-Selftest-Secret: %s\n' "$(cat "$BOT_DIR/selftest.secret")" > "$BOT_DIR/selftest.hdr")
	if [ -s "$BOT_DIR/tg.token" ]; then bot_put_secret webhook.secret "$(bot_rand)"; fi
	if [ -n "${BOT_ADMIN_ID:-}" ]; then bot_put_secret admin.id "$BOT_ADMIN_ID"; fi
	{
		printf 'plain %s %s\n' PANEL_ORIGIN "https://$DOMAIN" PANEL_BASE "$WEB_PATH" SUB_PREFIX "https://$DOMAIN$SUB_PATH" \
			CF_ZONE_ID "$BOT_ZONE" DNS_NAME "$DOMAIN" ENTRY_USER root ENTRY_SSH_PORT "$SSH_PORT" SELF_ORIGIN "$BOT_ORIGIN" \
			VPN_BOT_INSTALLER 1
		kfpr=$(bot_key_fpr)   # отпечаток ключа, который воркер получит в этой же загрузке (см. bot_keys)
		[ -z "$kfpr" ] || printf 'plain ENTRY_SSH_KEY_FPR %s\n' "$kfpr"
		printf 'secret CF_API_TOKEN @%s\nsecret SELFTEST_SECRET @%s\n' "$BOT_DIR/cf.token" "$BOT_DIR/selftest.secret"
		bot_secret_or_inherit BOT_TOKEN tg.token
		bot_secret_or_inherit WEBHOOK_SECRET webhook.secret
		bot_secret_or_inherit ADMIN_ID admin.id
		bot_secret_or_inherit PANEL_TOKEN panel.token
		bot_secret_or_inherit ENTRY_SSH_KEY id
		cat "$BOT_DIR/exit.list"
	} > "$BOT_DIR/bindings.list" || return 1
	(umask 077 && python3 -I -c '
import json, sys
lst, kv, settings, managed, out = sys.argv[1:6]
managed = set(managed.split())
b = [{"type": "kv_namespace", "name": "STATE", "namespace_id": kv}]
seen = {"STATE"}
for line in open(lst, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line:
        continue
    kind, name, *rest = line.split(" ", 2)
    val = rest[0] if rest else ""
    if kind == "plain":
        b.append({"type": "plain_text", "name": name, "text": val})
    elif kind == "secret":
        b.append({"type": "secret_text", "name": name, "text": open(val[1:], encoding="utf-8").read()})
    elif kind == "inherit":
        b.append({"type": "inherit", "name": name})
    seen.add(name)
if settings:
    for x in (json.load(open(settings)).get("result") or {}).get("bindings") or []:
        n = x.get("name")
        if n and n not in seen and n not in managed and x.get("type") in ("secret_text", "plain_text"):
            b.append({"type": "inherit", "name": n})
            seen.add(n)
json.dump({"main_module": "worker.js", "compatibility_date": "2026-10-20", "bindings": b}, open(out, "w"))' \
		"$BOT_DIR/bindings.list" "$BOT_KV_ID" "$([ "${BOT_EXISTING:-}" = ours ] && echo "$BOT_DIR/settings.json")" "$BOT_MANAGED" "$BOT_DIR/metadata.json") ||
		{ BOT_ERR="не собрать настройки воркера"; return 1; }
	bot_extract_bundle || { BOT_ERR="не распаковать код бота"; return 1; }
	body=$(cf_api PUT "/accounts/$BOT_ACC/workers/scripts/$BOT_WORKER?bindings_inherit=strict" \
		-F "metadata=@$BOT_DIR/metadata.json;type=application/json" \
		-F "worker.js=@$BOT_DIR/worker.js;type=application/javascript+module") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
	cf_ok <<< "$body" || { BOT_ERR="Cloudflare не принял воркер — $(cf_err <<< "$body")"; return 1; }
	# Cloudflare сохраняет секрет, которого нет в загрузке: ненужные (ключ выхода после перехода на прямой
	# выход или на другой выход без доступа, пароль выхода перезаписанного чужого бота) удалить явно —
	# иначе бот держит доступ, которого быть не должно, и при переезде идёт с ним не туда.
	if [ "${BOT_EXISTING:-none}" != none ] && [ -s "$BOT_DIR/settings.json" ]; then
		for f in $(python3 -I -c 'import json, sys
keep = {l.split()[1] for l in open(sys.argv[2], encoding="utf-8") if l.strip()}
managed = set(sys.argv[3].split())
for x in (json.load(open(sys.argv[1])).get("result") or {}).get("bindings") or []:
    n = x.get("name")
    if x.get("type") == "secret_text" and n in managed and n not in keep:
        print(n)' "$BOT_DIR/settings.json" "$BOT_DIR/bindings.list" "$BOT_MANAGED"); do
			if ! body=$(cf_api DELETE "/accounts/$BOT_ACC/workers/scripts/$BOT_WORKER/secrets/$f") || ! cf_ok <<< "$body"; then
				BOT_REPORT+="⚠ старый секрет $f в воркере не удалён — $(cf_err <<< "$body")"$'\n'
			fi
		done
	fi
	echo '{"enabled":true,"previews_enabled":false}' > "$BOT_DIR/req.json"
	body=$(cf_api POST "/accounts/$BOT_ACC/workers/scripts/$BOT_WORKER/subdomain" -H 'Content-Type: application/json' --data-binary @"$BOT_DIR/req.json") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
	cf_ok <<< "$body" || { BOT_ERR="не включить адрес workers.dev — $(cf_err <<< "$body")"; return 1; }
	printf '[{"cron":"%s"}]' "$BOT_CRON" > "$BOT_DIR/req.json"
	body=$(cf_api PUT "/accounts/$BOT_ACC/workers/scripts/$BOT_WORKER/schedules" -H 'Content-Type: application/json' --data-binary @"$BOT_DIR/req.json") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
	cf_ok <<< "$body" || { BOT_ERR="не поставить расписание — $(cf_err <<< "$body")"; return 1; }
	# Отпечатки ключей этого сервера: по ним бот узнаёт его при входе по SSH.
	# shellcheck disable=SC2086
	for f in $BOT_HOST_KEYS; do [ -f "$f" ] && ssh-keygen -lf "$f" | awk '{print $2}'; done |
		python3 -I -c 'import json, sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))' > "$BOT_DIR/fpr.json"
	[ "$(cat "$BOT_DIR/fpr.json")" != "[]" ] || { BOT_ERR="не найдены ключи SSH этого сервера ($BOT_HOST_KEYS)"; return 1; }
	body=$(cf_api PUT "/accounts/$BOT_ACC/storage/kv/namespaces/$BOT_KV_ID/values/entry%3Afpr" --data-binary @"$BOT_DIR/fpr.json") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
	cf_ok <<< "$body" || { BOT_ERR="не записать отпечаток сервера в KV — $(cf_err <<< "$body")"; return 1; }
	# Первый бэкап — сразу в хранилище: переезд работает с первой минуты. Не вышло — не беда, бот снимет сам.
	if [ -x "$BOT_BACKUP_CMD" ] && p=$("$BOT_BACKUP_CMD" 2> /dev/null | tail -1) && [ -f "$p" ]; then
		python3 -I -c 'import json, os, sys, time; print(json.dumps({"name": os.path.basename(sys.argv[1]), "size": os.path.getsize(sys.argv[1]), "createdAt": int(time.time() * 1000)}))' "$p" > "$BOT_DIR/backup.meta"
		kb=$(($(stat -c %s "$p") / 1024))
		if body=$(cf_api PUT "/accounts/$BOT_ACC/storage/kv/namespaces/$BOT_KV_ID/values/backup%3Abytes" -F "value=@$p" -F "metadata=<$BOT_DIR/backup.meta") && cf_ok <<< "$body"; then
			BOT_REPORT+="бэкап в хранилище Cloudflare: $kb КБ ✓"$'\n'
		else
			BOT_REPORT+="⚠ первый бэкап в хранилище не лёг — бот снимет его сам ночью или по кнопке «Бэкап»"$'\n'
		fi
	fi
	# Воркер отвечает? Только что заведённый адрес workers.dev Cloudflare включает около минуты (до того — 523),
	# поэтому ждём дольше — и до вебхука, иначе Телеграм получит ошибку на первом же обновлении.
	if [ "$subnew" = 1 ]; then
		tries=90
		printf '  …     адрес %s заведён только что — Cloudflare включает такой около минуты, жду до 3 мин\n' "$BOT_ORIGIN"
	fi
	for f in $(seq 1 "$tries"); do
		[ "$(bot_http /healthz 10 2> /dev/null)" = ok ] && break
		[ "$f" = "$tries" ] && { BOT_ERR="воркер не отвечает на $BOT_ORIGIN/healthz"; return 1; }
		sleep "${BOT_HEALTH_SLEEP:-2}"
	done
	if [ -s "$BOT_DIR/tg.token" ]; then
		# Очередь стираем только у бота без прежнего вебхука: чужой (перенастроенный с согласия) и наш её хранят.
		(umask 077 && python3 -I -c 'import json, sys
print(json.dumps({"url": sys.argv[1] + "/tg", "secret_token": open(sys.argv[2]).read(), "allowed_updates": ["message", "callback_query"],
                  "drop_pending_updates": sys.argv[3] == "1"}))' "$BOT_ORIGIN" "$BOT_DIR/webhook.secret" \
			"$([ -z "${BOT_HOOK_URL:-}" ] && [ "${BOT_EXISTING:-none}" = none ] && echo 1 || echo 0)" > "$BOT_DIR/hook.json")
		body=$(tg_api setWebhook "$BOT_DIR/hook.json") || { BOT_ERR="Телеграм не отвечает"; return 1; }
		[ "$(jget ok <<< "$body")" = true ] || { BOT_ERR="Телеграм не принял вебхук — $(jget description <<< "$body")"; return 1; }
	fi
	res=$(python3 -I -c '
import json, sys
def load(s):
    try:
        return json.loads(s)
    except Exception:
        return {}
base, entry, ex = (load(x) for x in sys.argv[1:4])
chain = sys.argv[4] == "chain"
out, bad = [], []
def line(ok, good, fail):
    out.append(good if ok else "⚠ " + fail)
    if not ok:
        bad.append(fail)
p = base.get("panel") or {}
line(p.get("ok"), "панель: клиентов %s ✓" % p.get("clients"), "бот не видит панель: %s" % p.get("error"))
d = base.get("dns") or {}
line(d.get("ok"), "A-запись: %s ✓" % d.get("ip"), "бот не видит A-запись: %s" % d.get("error"))
w = base.get("webhook") or {}
line(w.get("ok"), "вебхук Телеграма ✓" + (" (последняя ошибка доставки: %s)" % w["error"] if w.get("error") else ""), "вебхук Телеграма не стоит: %s" % w.get("error"))
line((base.get("admin") or {}).get("ok"), "владелец бота назначен ✓", "владелец бота не назначен")
line(entry.get("ok"), "вход по SSH на этот сервер ✓", "вход по SSH на этот сервер не прошёл: %s" % entry.get("error"))
if ex.get("ok"):
    out.append("выход по SSH ✓")
elif ex.get("skipped"):
    if chain:
        out.append("выход: при переезде порт новому входу открывать руками (у бота нет входа на выход)")
else:
    out.append("⚠ выход по SSH не прошёл (%s) — при переезде порт новому входу открывать руками" % ex.get("error"))
print("\n".join(out))
print("RESULT " + ("; ".join(bad) if bad else "ok"))' "$(bot_http '/selftest?part=base')" "$(bot_http '/selftest?part=entry')" "$(bot_http '/selftest?part=exit')" "${EXIT_MODE:-}")
	BOT_REPORT+=$(grep -v '^RESULT ' <<< "$res")
	res=$(sed -n 's/^RESULT //p' <<< "$res")
	[ "$res" = ok ] || { BOT_ERR=$res; return 1; }
}

bot_decide() {  # → BOT_DO (разворачивать сейчас), BOT_KEEP (бот есть — не трогать), BOT_STALE, BOT_ASK (спросить [y/N])
	BOT_DO=0 BOT_KEEP=0 BOT_STALE=0 BOT_ASK=0
	[ "${MODE:-}" = domain ] || return 0
	[ "${DNS_NOT_CF:-0}" != 1 ] || return 0   # домен не в Cloudflare — боту не на чем работать
	[ "${BOT_ARG:-}" != 0 ] || return 0
	if [ "${S_BOT:-}" = 1 ]; then
		# Повтор меняет то, на что бот опирается, — без обновления он открыл бы при переезде порт не там.
		if [ "${DOMAIN:-}" != "${S_DOMAIN_OLD:-}" ] || [ "${EXIT_MODE:-}" != "${S_EXIT:-}" ] ||
			{ [ -n "${EXIT_HOST:-}" ] && [ "$EXIT_HOST" != "${CHAIN_IP:-}" ]; } ||
			{ [ -n "${EXIT_PORT_ARG:-}" ] && [ "$EXIT_PORT_ARG" != "${CHAIN_PORT:-}" ]; } ||
			{ [ -n "${S_BOT_SSH_PORT:-}" ] && [ -n "${SSH_PORT_NOW:-}" ] && [ "$S_BOT_SSH_PORT" != "$SSH_PORT_NOW" ]; }; then
			BOT_STALE=1
		fi
		if [ -n "${BOT_CF_TOKEN:-}" ] || [ "${BOT_ARG:-}" = 1 ]; then BOT_DO=1; else BOT_KEEP=1; fi
	elif [ "${BOT_ARG:-}" = 1 ]; then
		BOT_DO=1
	elif [ -z "${S_BOT:-}" ] && bot_tty_ok; then
		BOT_ASK=1
	fi
}

bot_ask_secret() {  # bot_ask_secret ВОПРОС → BOT_ANSWER без пробелов; ввод виден (решение владельца); 1 — спросить некого
	BOT_ANSWER=
	bot_tty_ok || return 1
	if [ -n "${BOT_TTY_FD:-}" ]; then
		printf '%s' "$1" >> "$WORK/tty.out"
		IFS= read -r BOT_ANSWER <&"$BOT_TTY_FD" || BOT_ANSWER=
	else
		printf '%s' "$1" > /dev/tty
		IFS= read -r BOT_ANSWER < /dev/tty || BOT_ANSWER=
	fi
	BOT_ANSWER=$(printf '%s' "$BOT_ANSWER" | tr -d '[:space:]')   # вставка из буфера несёт пробелы и \r
}

bot_read_tokens() {  # спросить недостающие токены; без терминала — что дано окружением
	if [ "${BOT_KEEP:-0}" = 1 ]; then   # бот есть, но знает прежние настройки — предложить обновить
		bot_tty_ok || return 0
		bot_say "Бот @${S_BOT_USER:-?} знает прежние настройки (домен, выход или порт SSH) — чтобы обновить его, нужен токен Cloudflare:"
		bot_say "  $(bot_template_url)"
		bot_ask_secret "Токен Cloudflare (Enter — оставить бота как есть): " || return 0
		[ -n "$BOT_ANSWER" ] || return 0
		BOT_CF_TOKEN=$BOT_ANSWER BOT_DO=1 BOT_KEEP=0
		return 0
	fi
	if ! bot_have_cf_token && bot_tty_ok; then
		bot_say "1) Токен Cloudflare: открой ссылку (права уже отмечены) → «Continue to summary» → «Create Token» → скопируй токен:"
		bot_say "   $(bot_template_url)"
		bot_ask_secret "   Токен Cloudflare: " || true
		BOT_CF_TOKEN=$BOT_ANSWER
	fi
	if [ -z "${BOT_TG_TOKEN:-}" ] && ! { [ -n "${BOT_DIR:-}" ] && [ -s "$BOT_DIR/tg.token" ]; } && bot_tty_ok; then
		if [ "${S_BOT:-}" = 1 ]; then
			bot_ask_secret "2) Токен бота (Enter — прежний бот): " || true
		else
			bot_say "2) Токен бота: в Телеграме открой @BotFather → /newbot → придумай имя → скопируй токен вида 123456789:AAE…"
			bot_ask_secret "   Токен бота: " || true
		fi
		BOT_TG_TOKEN=$BOT_ANSWER
	fi
	if ! bot_have_cf_token; then
		BOT_DO=0
		BOT_SKIP="не дан токен Cloudflare"
	fi
}

bot_retry() {  # после неудачной проверки: «ещё раз?» и, если надо, другие токены (Enter — те же)
	bot_ask "Попробовать ещё раз? [Y/n]: " || return 1
	case $BOT_ANSWER in n | N | no | No | н | Н | нет | Нет | НЕТ) return 1 ;; esac
	bot_ask_secret "Токен Cloudflare (Enter — тот же): " || true
	[ -z "$BOT_ANSWER" ] || BOT_CF_TOKEN=$BOT_ANSWER
	bot_ask_secret "Токен бота (Enter — тот же): " || true
	[ -z "$BOT_ANSWER" ] || BOT_TG_TOKEN=$BOT_ANSWER
	bot_init_secrets
}
bot_extract_bundle() {  # код бота (vpn-bot acf1836) → $BOT_DIR/worker.js
	base64 -d <<'VPN_BOT_BUNDLE_EOF' | gzip -dc > "$BOT_DIR/worker.js"
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
3WANjQnsithXYr3hWB14jthv5tSdFCQInkDuEkJkOlWHTLY0KCT7JOa7ccs1WTnx2Zj3PPPLtllZ
oDDshYYx4UyShtSQ1Q/Ha0fUMsU2DahjivLxWNheLPvlRNyeqq7NBCXtUFYtcTbSzIC+iQSpuV2D
euuycnVEa1KfkdJo7fOoa1FYx016cdR6dVYqVGpA8Xac/5r7hU6rXi+Viru1ZqlcaVaau7ulWqNW
aDWLzVaxtF8oVdqFWq2+u9ds7lUKpUKj0a7vlhvF8n6jVKoWK/VCbW+/1i5XCpVWq93Zrxb3G+Vm
q1yvlIuNcqHUKNR3W51StVOslPcqnXaxXN1t7baqxWapUm1XatVGdU/0WW3vtZu7nYoYQqm9L3rY
a7d2G4VGp1NtNsT7wm5DvGm3y7XdRqdRrdf29zv1ar293ylVisW9ZqVR7LR3K/ul2u5utdhutivV
RrnVLBUKe81GrV4UQ+4Uqvu1Vh3yohab1WqrLLrZFx869VqnVao0O9WO+CQ+lETFerne2hfldksd
MeBSoVatlhqN/XarKtZkb6+wv7u/K+axV2iWq5V2pd5o7tcKlU5xr7LbLNSa9WKtJEZVFoXFJHdL
7fJus11utMv77b29UrNYK7RruwVYw71auV5qNwt79VJNTAwG1imICTerpeZ+q11qNBud3f1qtVbc
K9bK+/vVyv5es13fr+7W29WiGGxpt1jbr3XqhWqxUKzulWptsTr1erNe3625+y2ZIIQJSOb6v2Di
/1cwURcL2aq3yuXiXqFVqFRFB+VyHaZRrDdanWKzUd+ttJudRq0qvtZajXanIOq163uikWqrsFto
7rUa5f29QqdWre+2i+1Kc6/e6Ig1rzVbjcJ+udzaK4rf+wJAKnVxCxb3W02xQTiieqvUboudKpY6
YmS7rf2agJPdSqu2t1so7ZXL7WZtV/QvBtMpNYpibnsNsVVNAVxiM6t7e/VdMbXdJix0rdYsNMRm
VHbbYhvapYpocK8iJtkoC5BqNaqNTrMtwLgoPlYatZKA2kJ9vyQeC8Vifa9UbhZL9b3aXnu3tVer
7RX368VCo9WoVxul3f19sUViXXfrnUobStZFN7VypSG6F4XErGrl9n6zXqq3BGS2xSo1Gs2SmH2l
1a4JYC/Bv81ipdhptOEQlmp7zep+RQxvt9EsVFv7YoP3d2HE+wJQxDkrlxsCNASEVhsC4FvFzq44
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
VPN_BOT_BUNDLE_EOF
}
BOT_SOURCE=acf1836

# Токены — сразу из окружения: токен Cloudflare нужен уже на первом вопросе (домен выбирается из списка).
BOT_CF_TOKEN=${CF_API_TOKEN:-}
BOT_TG_TOKEN=${VPN_BOT_TOKEN:-}
unset CF_API_TOKEN VPN_BOT_TOKEN   # дальше токены — только в переменных скрипта и файлах 600
DNS_FROM_CF=0 DNS_NOT_CF=0 DNS_ZONES='' DNS_ZONE_ID='' DNS_REPOINT=0 DNS_REPORT='' DNS_SET_BY_API=0

MODE=
S_MODE=$(state_val S_MODE || true)
S_DOMAIN_OLD=$(state_val S_DOMAIN || true)
if [ -z "$S_MODE" ] && [ -n "$S_DOMAIN_OLD" ]; then S_MODE=domain; fi   # установка прежней версией скрипта
S_EXIT=$(state_val S_EXIT || true)
CHAIN_IP=$(state_val CHAIN_IP || true)
CHAIN_PORT=$(state_val CHAIN_PORT || true)
CHAIN_UUID=$(state_val CHAIN_UUID || true)
CHAIN_PUB=$(state_val CHAIN_PUB || true)
CHAIN_PRIV=$(state_val CHAIN_PRIV || true)
CHAIN_SID=$(state_val CHAIN_SID || true)
CHAIN_SNI=$(state_val CHAIN_SNI || true)
CHAIN_SSH_USER=$(state_val CHAIN_SSH_USER || true)
CHAIN_SSH_PORT=$(state_val CHAIN_SSH_PORT || true)
CHAIN_FW=$(state_val CHAIN_FW || true)
EXIT_SSH_USER_ARG=$EXIT_SSH_USER   # заданы опциями (пусто — нет): другой сервер-выход прошлые не наследует
EXIT_SSH_PORT_ARG=$EXIT_SSH_PORT
exit_ssh_defaults
# Фаервол, fail2ban и часовой пояс — как в прошлый раз, если не заданы опциями.
DO_UFW=${DO_UFW:-$(state_val S_DO_UFW || true)}; DO_UFW=${DO_UFW:-1}
DO_F2B=${DO_F2B:-$(state_val S_DO_F2B || true)}; DO_F2B=${DO_F2B:-1}
TZ_NAME=${TZ_NAME:-$(state_val S_TZ || true)}; TZ_NAME=${TZ_NAME:-Europe/Moscow}
foreign_xui_check() {  # 3x-ui здесь ставили без этого скрипта: сказать, что будет, и спросить сразу — до любых вопросов и изменений
	local n
	[ -f "$DB" ] && [ ! -f "$STATE" ] || return 0
	! compgen -G "$STATE.failed-*" > /dev/null || return 0   # следы неудачной попытки этого скрипта — 3x-ui его
	n=$(python3 -I -c 'import sqlite3, sys; print(sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True).execute("select count(*) from inbounds").fetchone()[0])' "$DB" 2> /dev/null ||
		sqlite3 -readonly "$DB" 'select count(*) from inbounds;' 2> /dev/null || echo '?')
	warn "здесь уже есть 3x-ui, поставленный не этим скриптом (подключений: $n). Удалять его скрипт не будет: подключения и клиенты останутся, их порты фаервол не закроет. Заменятся логин, пароль, порт и путь панели, шаблон Xray (маршрутизация), адреса подписок и сама программа — на 3x-ui $XUI_VERSION. Копия базы останется рядом с ней"
	bot_tty_ok || die "здесь уже есть 3x-ui, поставленный не этим скриптом: запустите скрипт в терминале (он спросит) или поставьте VPN на чистый сервер"
	bot_consent "Продолжить?" || die "ничего не менял. Для нового VPN лучше чистый сервер"
	FOREIGN_XUI=1
}
FOREIGN_XUI=0
[ "$CHECK_ONLY" = 1 ] || [ -n "$WARP_CMD" ] || foreign_xui_check
if [ "$CHECK_ONLY" = 1 ] || [ -n "$WARP_CMD" ]; then
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
  1) Да, в Cloudflare — лучше всего: скрипт сам направит домен на этот сервер (нужен токен
           Cloudflare), маскировка под свой сайт, подписки в приложениях обновляются сами,
           панель — по адресу домена; можно поставить Телеграм-бота.
  2) Да, но не в Cloudflare — то же, но A-запись домена на IP сервера сделаете сами (без бота).
  3) Нет — маскировка под крупный чужой сайт. Ссылки привязаны к IP сервера
           (переедете на другой сервер — ссылки раздать заново), панель — по IP сервера.
EOF
		while [ -z "$MODE" ]; do
			printf 'Ваш выбор [1/2/3]: ' > /dev/tty
			read -r ans < /dev/tty || die "не удалось прочитать ответ"
			case $ans in
				1) MODE=domain DNS_FROM_CF=1 ;;
				2) MODE=domain DNS_NOT_CF=1 ;;
				3 | нет | Нет | НЕТ | n | N | no) MODE=nodomain ;;
			esac
		done
		if [ "$DNS_FROM_CF" = 1 ]; then
			# Сначала токен, потом домен — из тех, что в Cloudflare; запись поставит шаг DNS (там уже известен IP).
			bot_need_python || die "не установились python3 и curl (apt занят или нет сети) — запустите скрипт ещё раз"
			if ! { dns_ask_token && dns_pick; }; then
				warn "домен из Cloudflare выбрать не вышло: $BOT_ERR"
				printf 'Тогда впишите домен вручную, а A-запись на IP сервера сделайте сами.\n' > /dev/tty
				DNS_FROM_CF=0 DNS_NOT_CF=1
			fi
		fi
		if [ "$MODE" = domain ] && [ -z "$DOMAIN" ]; then
			printf 'Домен (например vpn.example.com): ' > /dev/tty
			read -r DOMAIN < /dev/tty || true
		fi
	fi
	if [ -n "$S_MODE" ] && [ "$S_MODE" != "$MODE" ]; then
		MODE_CHANGED=1   # можно ли — решится ниже, когда будет видно, есть ли уже подключение
	fi
fi
if [ "$MODE" = domain ]; then
	DOMAIN=$(norm_host "$DOMAIN")
	if [[ $DOMAIN == *[![:ascii:]]* ]]; then   # кириллический домен (пример.рф) — в punycode
		DOMAIN=$(python3 -c 'import sys; print(sys.argv[1].encode("idna").decode())' "$DOMAIN" 2>/dev/null) ||
			die "домен с нелатинскими буквами: укажите его в виде xn--… (punycode)"
	fi
	is_host "$DOMAIN" || die "нужен домен вида vpn.example.com (сейчас: «$DOMAIN»)"
	[ -z "$S_DOMAIN_OLD" ] || [ "$S_DOMAIN_OLD" = "$DOMAIN" ] || MODE_CHANGED=1
else
	DOMAIN=
	if [ -n "$SNI_ARG" ]; then
		SNI_ARG=$(norm_host "$SNI_ARG")
		is_host "$SNI_ARG" || die "--sni: нужно имя сайта вида www.example.com (сейчас: «$SNI_ARG»)"
	fi
fi
# Порт подключения Reality — как у основного сервера, 2083, с доменом и без (--port меняет).
# Повторный запуск берёт порт уже созданного подключения из базы: иначе установка прежней версией
# (без домена ставила 443) получила бы второе подключение.
existing_reality_port() {
	[ -f "$DB" ] && command -v python3 >/dev/null 2>&1 || return 0
	python3 - "$DB" <<'PY' 2>/dev/null || true
import json, sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
for port, ss in db.execute("select port, stream_settings from inbounds where protocol='vless' order by id"):
    try:
        if json.loads(ss or "{}").get("security") == "reality":
            print(port)
            break
    except ValueError:
        pass
PY
}
OLD_REALITY_PORT=$(existing_reality_port)
S_REALITY_PORT=$(state_val S_REALITY_PORT || true)
reset_failed_attempt() {  # смена варианта после неудачной первой установки: убрать то, что успела сделать прошлая попытка
	local d=$S_DOMAIN_OLD ip
	ip=$(state_val S_IP_CERT_IP || true)
	if [ -n "$d" ] && [ "$d" != "$DOMAIN" ]; then
		[ ! -x /root/.acme.sh/acme.sh ] || /root/.acme.sh/acme.sh --remove -d "$d" --ecc >/dev/null 2>&1 || true
		rm -rf "/root/.acme.sh/${d}_ecc" "/root/cert/$d"
	fi
	if [ "$MODE" = nodomain ]; then   # nginx без домена не нужен, а :80 нужен Let's Encrypt для сертификата на IP
		rm -f /etc/nginx/conf.d/acme-http.conf /etc/nginx/conf.d/panel.conf /etc/nginx/stream-enabled/443-demux.conf
		systemctl disable --now nginx >/dev/null 2>&1 || true
	elif [ -n "$ip" ]; then
		[ ! -x /root/.acme.sh/acme.sh ] || /root/.acme.sh/acme.sh --remove -d "$ip" --ecc >/dev/null 2>&1 || true
		rm -rf "/root/.acme.sh/${ip}_ecc" /etc/x-ui/ip-cert
	fi
	mv -f "$STATE" "$STATE.failed-$(date +%Y%m%d-%H%M%S)"   # по этому следу foreign_xui_check потом узнает свой 3x-ui
	S_MODE='' S_DOMAIN_OLD='' S_EXIT='' S_REALITY_PORT='' CHAIN_IP='' CHAIN_PORT='' CHAIN_UUID='' CHAIN_PUB='' CHAIN_PRIV='' CHAIN_SID='' CHAIN_SNI='' CHAIN_SSH_USER='' CHAIN_SSH_PORT=''
	exit_ssh_defaults
}
if [ "${MODE_CHANGED:-0}" = 1 ]; then
	PREV_DESC=$([ "$S_MODE" = domain ] && echo "с доменом $S_DOMAIN_OLD" || echo "без домена")
	if [ "$(state_val S_DONE || true)" = 1 ] || [ -n "$OLD_REALITY_PORT" ]; then
		die "сервер уже ставился $PREV_DESC, и VPN на нём настроен. Сменить вариант или домен можно только на чистом сервере"
	fi
	warn "прошлая установка ($PREV_DESC) не дошла до конца — её настройки не нужны, ставлю заново $([ "$MODE" = domain ] && echo "с доменом $DOMAIN" || echo "без домена")"
	reset_failed_attempt
fi
if [ -n "$PORT_ARG" ] && [ "$CHECK_ONLY" = 0 ] && [ -z "$WARP_CMD" ]; then
	[[ $PORT_ARG =~ ^[1-9][0-9]{0,4}$ ]] && [ "$PORT_ARG" -le 65535 ] || die "--port: число от 1 до 65535"
	case $PORT_ARG in 62789 | 11111) die "--port $PORT_ARG: на нём внутренние службы Xray (API, статистика) — выберите другой" ;; esac
	[ "$PORT_ARG" != "$(state_val WEB_PORT || true)" ] || die "--port $PORT_ARG: на нём панель 3x-ui — выберите другой"
	[ "$MODE" = domain ] || [ "$PORT_ARG" != 80 ] || die "--port 80: он нужен Let's Encrypt для сертификата на IP — выберите другой"
	[ "$PORT_ARG" != "$SUB_PORT" ] || die "--port $PORT_ARG: на нём подписка 3x-ui — выберите другой"
	if [ "$MODE" = domain ]; then
		case $PORT_ARG in 80 | 443 | 8443) die "--port $PORT_ARG: с доменом 80, 443 и 8443 заняты nginx — выберите другой (по умолчанию 2083)" ;; esac
	fi
	REALITY_PORT=$PORT_ARG
else
	REALITY_PORT=${OLD_REALITY_PORT:-${S_REALITY_PORT:-2083}}
fi
[[ $CLIENTS =~ ^[0-9]+$ ]] && [ "$CLIENTS" -ge 1 ] && [ "$CLIENTS" -le 100 ] || die "--clients: число от 1 до 100"
key_line() {  # строка вставленного ключа без \r, маркеров вставки терминала и пробелов по краям
	local l=${1//$'\r'/}
	l=${l//$'\e[200~'/}
	l=${l//$'\e[201~'/}
	l=${l#"${l%%[![:space:]]*}"}
	printf '%s' "${l%"${l##*[![:space:]]}"}"
}
normalize_key() {  # пустые строки убрать (вставка с \r\n их удваивает), кроме одной после заголовков зашифрованного PEM
	awk 'NF == 0 {next} {print} /^DEK-Info:/ {print ""}'
}
read_key_rest() {  # $1 — первая строка вставленного ключа; дочитать до -----END … PRIVATE KEY----- (PuTTY — до Private-MAC)
	local line n=1 end='-----END*PRIVATE KEY-----' what='-----END … PRIVATE KEY-----'
	[[ $1 == PuTTY-User-Key-File* ]] && { end='Private-MAC:*'; what='Private-MAC: …'; }
	EXIT_KEY_TEXT=$1
	while [ "$n" -lt 300 ] && IFS= read -r line < /dev/tty; do
		line=$(key_line "$line")
		n=$((n + 1))
		EXIT_KEY_TEXT+=$'\n'"$line"
		# shellcheck disable=SC2053
		[[ $line == $end ]] && break
	done
	# Хвост вставки (лишний перевод строки после \r\n) дочитать, иначе его получит следующий вопрос.
	while IFS= read -r -t 0.3 _ < /dev/tty; do :; done
	# shellcheck disable=SC2053
	[[ ${EXIT_KEY_TEXT##*$'\n'} == $end ]] || die "ключ вставлен не целиком: нет последней строки «$what»"
	EXIT_KEY_TEXT=$(normalize_key <<<"$EXIT_KEY_TEXT")
	printf '  ключ получен (%s строк)\n' "$(grep -c . <<<"$EXIT_KEY_TEXT")" > /dev/tty
}
ask_exit_auth() {  # доступ к старому серверу: пароль root или SSH-ключ (вставить целиком / путь к файлу)
	local ans first clean
	printf 'Вход на старый сервер под %s: 1) по паролю, 2) по SSH-ключу [1]: ' "$EXIT_SSH_USER" > /dev/tty
	read -r ans < /dev/tty || ans=
	if [ "$ans" = 2 ]; then
		printf 'Вставьте приватный ключ целиком (от -----BEGIN до -----END)\nили путь к файлу ключа на этом сервере: ' > /dev/tty
	else
		printf 'Пароль %s на старом сервере (можно вставить и SSH-ключ целиком): ' "$EXIT_SSH_USER" > /dev/tty
	fi
	IFS= read -r first < /dev/tty || first=
	clean=$(key_line "$first")
	if [[ $clean == -----BEGIN*PRIVATE\ KEY----- || $clean == PuTTY-User-Key-File* ]]; then
		read_key_rest "$clean"
	elif [ "$ans" = 2 ]; then
		[ -f "$clean" ] || die "файл ключа не найден: $clean"
		EXIT_SSH_KEY=$clean
	else
		EXIT_PASS=${first%$'\r'}
	fi
}
# Первая установка без --exit и без терминала-ответа — спросить, куда выходить (как спрашивали про домен).
if [ "$CHECK_ONLY" = 0 ] && [ -z "$WARP_CMD" ] && [ -z "$EXIT_MODE" ] && [ -z "$S_EXIT" ] && { : > /dev/tty; } 2>/dev/null; then
	cat > /dev/tty <<'EOF'

Куда выпускать трафик клиентов в интернет?
  1) Напрямую с IP этого сервера (по умолчанию, быстрее всего)
  2) Через Cloudflare WARP (IP сервера не виден сайтам; бывают капчи Google, потолок ~100 Мбит/с)
  3) Российские сайты — через WARP, остальное напрямую
  4) Через другой мой сервер (его IP как выход; например старый IP, забаненный как вход из РФ)
EOF
	while [ -z "$EXIT_MODE" ]; do
		printf 'Ваш выбор [1/2/3/4]: ' > /dev/tty
		read -r ans < /dev/tty || die "не удалось прочитать ответ"
		case $ans in
			1 | "") EXIT_MODE=direct ;;
			2) EXIT_MODE=warp ;;
			3) EXIT_MODE=warp-ru ;;
			4) EXIT_MODE=chain ;;
		esac
	done
	if [ "$EXIT_MODE" = chain ]; then
		tries=0
		while :; do
			printf 'IP старого сервера-выхода: ' > /dev/tty; read -r EXIT_HOST < /dev/tty || EXIT_HOST=
			exit_host_parse && break
			tries=$((tries + 1)); [ "$tries" -lt 3 ] || die "не получил адрес старого сервера"
			tty_flush   # вставили не то (например ключ) — остаток вставки не должен уйти в следующие вопросы
			printf '  нужен IPv4-адрес вида 203.0.113.5 или имя сервера (можно ubuntu@203.0.113.5)\n' > /dev/tty
		done
		exit_ssh_defaults
		printf 'SSH-порт старого сервера [%s]: ' "$EXIT_SSH_PORT" > /dev/tty; read -r a < /dev/tty || true; [ -n "$a" ] && EXIT_SSH_PORT=$a EXIT_SSH_PORT_ARG=$a
		printf 'Пользователь на старом сервере [%s] (AWS, Oracle — ubuntu): ' "$EXIT_SSH_USER" > /dev/tty; read -r a < /dev/tty || true; [ -n "$a" ] && EXIT_SSH_USER=$a EXIT_SSH_USER_ARG=$a
		if [ -z "$EXIT_SSH_KEY" ] && [ -z "${EXIT_PASS:-}" ]; then ask_exit_auth; fi
	fi
fi
EXIT_MODE=${EXIT_MODE:-${S_EXIT:-direct}}   # не указан — как в прошлый раз
case $EXIT_MODE in direct | warp | warp-ru | chain) ;; *) die "--exit: direct, warp, warp-ru или chain" ;; esac
if [ "$EXIT_MODE" = chain ]; then
	if [ -n "$EXIT_HOST" ]; then
		exit_host_parse || die "--exit-host: нужен IPv4-адрес старого сервера вида 203.0.113.5 или его имя (сейчас: «$EXIT_HOST»)"
		exit_ssh_defaults
	fi
	if [ -n "$EXIT_PORT_ARG" ]; then
		[[ $EXIT_PORT_ARG =~ ^[1-9][0-9]{0,4}$ ]] && [ "$EXIT_PORT_ARG" -le 65535 ] || die "--exit-port: число от 1 до 65535"
	fi
	[ -n "$EXIT_HOST" ] || [ -z "$EXIT_STOP_XUI" ] || warn "--exit-stop-xui и --exit-keep-xui действуют только вместе с --exit-host (при настройке старого сервера)"
	[[ $EXIT_SSH_USER =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] || die "--exit-ssh-user: имя пользователя вида ubuntu (сейчас: «$EXIT_SSH_USER»)"
	[[ $EXIT_SSH_PORT =~ ^[1-9][0-9]{0,4}$ ]] && [ "$EXIT_SSH_PORT" -le 65535 ] || die "--exit-ssh-port: число от 1 до 65535"
	# Первый раз (нет сохранённой цепочки) нужен IP старого сервера; повторный запуск берёт из state.
	if [ -z "$EXIT_HOST" ] && [ -z "$CHAIN_IP" ]; then
		die "для --exit chain укажите --exit-host IP старого сервера (и EXIT_PASS=… либо --exit-ssh-key)"
	fi
	[ -z "$EXIT_SSH_KEY" ] || [ -f "$EXIT_SSH_KEY" ] || die "--exit-ssh-key: файл не найден: $EXIT_SSH_KEY"
	if [ -n "$EXIT_HOST" ] && [ -z "$EXIT_SSH_KEY" ] && [ -z "$EXIT_KEY_TEXT" ] && [ -z "${EXIT_PASS:-}" ]; then
		if { : > /dev/tty; } 2>/dev/null; then
			ask_exit_auth
		else
			die "нужен доступ к старому серверу: EXIT_PASS='root-пароль' либо --exit-ssh-key ПУТЬ (EXIT_KEY_PASS — если у ключа парольная фраза)"
		fi
	fi
fi
# --- Телеграм-бот: решить и спросить токены сейчас, проверить — после установки пакетов ---
S_BOT=$(state_val S_BOT || true)
S_BOT_USER=$(state_val S_BOT_USER || true)
S_BOT_ORIGIN=$(state_val S_BOT_ORIGIN || true)
S_BOT_WORKER=$(state_val S_BOT_WORKER || true)
S_BOT_SSH_PORT=$(state_val S_BOT_SSH_PORT || true)
[ -n "${VPN_BOT_WORKER:-}" ] || BOT_WORKER=${S_BOT_WORKER:-vpn-bot}
[ -z "${S_BOT_WORKER:-}" ] || BOT_WORKER_AUTO=0   # воркер прошлой установки молча не меняем
SSH_PORT_NOW=$(sshd -T 2> /dev/null | awk '$1 == "port" {print $2; exit}' || true)
BOT_DO=0 BOT_KEEP=0 BOT_STALE=0 BOT_SKIP='' BOT_RESULT=''
if [ "$CHECK_ONLY" = 0 ] && [ -z "$WARP_CMD" ]; then
	bot_decide
	[ "$BOT_ARG" != 0 ] || S_BOT=0   # --no-bot запоминается
	if [ "$BOT_ASK" = 1 ]; then
		cat > /dev/tty <<'EOF'

Телеграм-бот для управления VPN: клиенты (создать — ссылка на подписку, выключить, удалить),
статистика, проверка блокировки в России раз в 3 часа, бэкапы и переезд на новый сервер кнопкой.
Бесплатно, на вашем аккаунте Cloudflare. Нужны домен в Cloudflare и бот от @BotFather.
EOF
		if bot_consent "Поставить бота?"; then BOT_DO=1; else S_BOT=0; fi
	fi
	if [ "$BOT_DO" = 1 ] || { [ "$BOT_KEEP" = 1 ] && [ "$BOT_STALE" = 1 ]; }; then bot_read_tokens; fi
fi
# Дальше на вопросы отвечают только через /dev/tty. Служебные программы (openssl s_client, apt, ssh…)
# терминал не читают — иначе съели бы клавиши, нажатые во время установки, или ответ на следующий вопрос.
# Запуск через конвейер (stdin — не терминал) не трогаем: тогда bash читает из stdin сам скрипт.
if [ -t 0 ]; then exec < /dev/null; fi
case $WARP_CMD in
	"") ;;
	off | direct) TARGET_EXIT=direct ;;
	on | warp | all) TARGET_EXIT=warp ;;
	ru | warp-ru) TARGET_EXIT=warp-ru ;;
	status | show) TARGET_EXIT=status ;;
	*) die "--warp: off (напрямую), on (всё через WARP), ru (российские сайты через WARP) или status" ;;
esac

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

free_port() {  # случайный свободный TCP-порт из 20000–60000 (не порт подключения)
	python3 - "${REALITY_PORT:-0}" <<'PY'
import random, socket, sys
for _ in range(200):
    p = random.randint(20000, 59999)
    if p == int(sys.argv[1]):
        continue
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

dns_verify() {  # A-запись домена указывает сюда (по DoH)? Если её только что поставил сам скрипт (DNS_SET_BY_API),
	# старый ответ из кэша DNS (до 5 мин) — не повод останавливаться: в Cloudflare уже верно, Let's Encrypt спросит сам.
	local A first AAAA
	A=$(resolve "$DOMAIN" A) || die "не удалось проверить DNS (нет доступа к cloudflare-dns.com и dns.google)"
	case " $A " in
		*" $PUBLIC_IP "*) ok "A-запись $DOMAIN указывает на этот сервер" ;;
		*)
			if [ "${DNS_SET_BY_API:-0}" = 1 ]; then
				warn "в Cloudflare $DOMAIN уже указывает на этот сервер, а DNS ещё отдаёт ${A:-пустой ответ} — это кэш (до 5 мин), продолжаю"
			elif [ -z "$A" ]; then
				die "у $DOMAIN нет A-записи. Создайте её: $DOMAIN → $PUBLIC_IP (в Cloudflare — Proxy выключен, серое облако), подождите пару минут и запустите снова"
			else
				first=${A%% *}
				if is_cloudflare_ip "$first"; then
					die "$DOMAIN смотрит на Cloudflare ($A): в Cloudflare у A-записи выключите Proxy (облако должно быть серым) и запустите снова"
				fi
				die "A-запись $DOMAIN указывает на $A, а IP этого сервера $PUBLIC_IP. Поправьте A-запись, подождите пару минут и запустите снова (или --skip-dns-check, если знаете, что делаете)"
			fi
			;;
	esac
	AAAA=$(resolve "$DOMAIN" AAAA || true)
	if [ -n "$AAAA" ]; then
		if [ "${DNS_SET_BY_API:-0}" = 1 ]; then
			warn "DNS ещё отдаёт удалённую AAAA-запись $DOMAIN ($AAAA) — это кэш, пройдёт сам"
		else
			die "у $DOMAIN есть AAAA-запись ($AAAA): IPv6 на сервере выключается, а Let's Encrypt и клиенты пойдут по IPv6. Удалите AAAA-запись и запустите снова"
		fi
	fi
}

dns_step() {  # шаг DNS: есть токен Cloudflare — A-запись ставит сам скрипт (запись на чужой IP — только с согласием,
	# без терминала — остановка); потом проверка через DNS. Без бота токен стирается сразу.
	local l
	[ "$MODE" = domain ] || return 0
	if [ "$SKIP_DNS" = 1 ]; then
		warn "A-запись домена не проверялась (--skip-dns-check)"
		return 0
	fi
	if [ "$DNS_NOT_CF" = 0 ] && bot_have_cf_token; then
		bot_init_secrets
		if [ -n "$DNS_ZONE_ID" ] || dns_find_zone; then
			dns_apply || die "$BOT_ERR"
			DNS_SET_BY_API=1
			if [ -n "$DNS_REPORT" ]; then
				while IFS= read -r l; do [ -z "$l" ] || ok "$l"; done <<< "$DNS_REPORT"
				dns_wait || true   # не дождались — dns_verify скажет про кэш
			fi
		else
			warn "${BOT_ERR:-токен Cloudflare не видит домен $DOMAIN} — A-запись проверяю как обычно"
		fi
		[ "$BOT_DO" = 1 ] || bot_wipe   # без бота токен был нужен только для DNS
	fi
	dns_verify
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
		if [ "$MODE" != domain ] && [ "$CHECK_ONLY" = 0 ] && [ -z "$WARP_CMD" ]; then
			die "не удалось узнать внешний IP сервера (api.ipify.org, ifconfig.me, icanhazip.com недоступны), а без домена он нужен для ссылок"
		fi
		# Проверке и vpn-warp хватит адреса из ссылок клиентов (или адреса на интерфейсе).
		[ "$MODE" = domain ] || PUBLIC_IP=$(sqlite3 -readonly "$DB" "select share_addr from inbounds where share_addr<>'' order by id limit 1;" 2>/dev/null || true)
		[[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || PUBLIC_IP=$LISTEN_IP
		[ "$MODE" = domain ] || warn "внешний IP сервера не узнать (сервисы определения IP недоступны — нет выхода в интернет?): считаю, что это $PUBLIC_IP"
	fi
}

root_has_own_key() {  # у root в authorized_keys есть ключ человека; ключ бота («… vpn-bot») не в счёт
	local f=${1:-/root/.ssh/authorized_keys}
	[ -f "$f" ] && grep -qvE -e ' vpn-bot$' -e '^[[:space:]]*(#|$)' "$f"
}

ssh_login_method() {  # как вошли в эту SSH-сессию: publickey | password | keyboard-interactive | пусто (не узнать)
	local cip cport rest
	read -r cip cport rest <<<"${SSH_CONNECTION:-}" || true
	[ -n "${cport:-}" ] || return 0
	{ journalctl -q --no-pager -o cat -t sshd -t sshd-session 2>/dev/null || true; cat /var/log/auth.log 2>/dev/null || true; } |
		{ grep -oE "Accepted [a-z-]+ for [^ ]+ from ${cip//./\\.} port $cport( |\$)" || true; } | tail -1 | awk '{print $2}'
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
END = time.monotonic() + 240   # весь опрос — не дольше 4 минут, как бы ни тормозил check-host


def left():
    return END - time.monotonic()


def get(url, tries=3):
    err = TimeoutError("check-host: время вышло")
    for _ in range(tries):
        if left() < 2:
            break
        try:
            return json.load(urllib.request.urlopen(urllib.request.Request(url, headers=H), timeout=min(20, left())))
        except Exception as e:
            err = e
            time.sleep(min(4, max(0, left() - 1)))
    raise err


def probe(ports, ru, eu, q):  # один заход: порт → {узел: ok|fail|?}; None — check-host не принял проверку
    rids, res = {}, {p: {} for p in ports}
    for k, port in enumerate(ports):
        if k:
            time.sleep(4)   # check-host не любит частые запросы
        try:
            rids[port] = get("https://check-host.net/check-tcp?host=%s:%s&%s" % (ip, port, q))["request_id"]
        except Exception:
            rids[port] = None
    for _ in range(25):
        if left() < 5:
            break
        time.sleep(3)
        pending = False
        for port, rid in rids.items():
            if not rid or (res[port] and all(v is not None for v in res[port].values())):
                continue
            try:
                r = get("https://check-host.net/check-result/" + rid, tries=1)
                res[port] = r if isinstance(r, dict) else {}
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
            ok = isinstance(v, list) and v and isinstance(v[0], dict) and "time" in v[0]
            out[port][n] = "?" if v is None else ("ok" if ok else "fail")
    return out


def main():
    try:
        nodes = get("https://check-host.net/nodes/hosts")["nodes"]
    except Exception:
        return ["NOAPI"]
    ru = sorted(n for n, i in nodes.items() if (i.get("location") or [""])[0] == "ru")
    eu = []
    for p in ("de1", "nl1", "fi1", "se1", "pl1", "fr2", "de4", "nl2"):
        eu += [n for n in sorted(nodes) if n.split(".")[0] == p and n not in eu]
    eu = eu[:2]
    if not ru:
        return ["NORU"]
    city = {n: (nodes[n].get("location") or ["", "", n])[-1] for n in ru + eu}
    q = "&".join("node=" + n for n in ru + eu)
    # Узлы check-host иногда промахиваются поодиночке: порты, где не все узлы достучались, проверяются второй раз,
    # и узел считается достучавшимся, если получилось хоть раз.
    res = probe(ports, ru, eu, q)
    again = [p for p in ports if res[p] is not None and any(st != "ok" for st in res[p].values())]
    if again and left() > 60:
        time.sleep(4)
        second = probe(again, ru, eu, q)
        for p in again:
            if second.get(p):
                for n, st in second[p].items():
                    if st == "ok" or res[p].get(n) == "?":
                        res[p][n] = st
    mark = {"ok": "✓", "fail": "✗", "?": "…"}
    rows = []
    for port in ports:
        if res[port] is None:
            rows.append("%s|UNAVAILABLE" % port)
            continue
        row = [port]
        for group in (ru, eu):
            st = [res[port].get(n, "?") for n in group]
            row += [str(st.count("ok")), str(len(st) - st.count("?")), str(len(group))]
        for group in (ru, eu):
            row.append(", ".join("%s %s" % (city.get(n, n), mark[res[port].get(n, "?")]) for n in group))
        rows.append("|".join(row))
    return rows


try:
    out = main()
except Exception:   # check-host ответил чем-то неожиданным: «проверить не удалось», а не обрыв установки
    out = ["NOAPI"]
print("\n".join(out))
PY
}

port_verdict() {  # port_verdict ru_ok ru_done ru_n eu_ok eu_done → OK | RU_BLOCKED | CLOSED | PARTIAL | UNKNOWN
	# Считаются только ответившие узлы: молчащий узел — «неизвестно», а не «закрыто».
	if [ "$2" = 0 ]; then echo UNKNOWN          # из России не ответил ни один узел
	elif [ "$1" = "$2" ]; then echo OK         # все ответившие узлы в России достучались
	elif [ "$1" -gt 0 ]; then echo PARTIAL
	elif [ "$4" -gt 0 ]; then echo RU_BLOCKED  # из России — нет, из Европы — да
	elif [ "$5" -gt 0 ]; then echo CLOSED      # ни оттуда, ни оттуда
	else echo UNKNOWN
	fi
}

ip_precheck() {  # до установки: не заблокирован ли IP в России (по SSH — он слушает всегда)
	local port line p ru_ok ru_done ru_n eu_ok eu_done eu_n ru_s eu_s
	port=$(ssh_ports | awk '{print $1}')
	if [ "$SKIP_IP_CHECK" = 1 ]; then warn "доступность IP из России не проверялась (--skip-ip-check)"; return 0; fi
	line=$(chk_probe "$PUBLIC_IP" "$port" | head -1) || line=
	case $line in
		NOAPI | "") warn "check-host.net недоступен — не проверить, заблокирован ли IP в России; ставлю дальше"; return 0 ;;
		NORU) warn "у check-host.net сейчас нет узлов в России — блокировку IP проверить нечем; ставлю дальше"; return 0 ;;
		*"|UNAVAILABLE") warn "check-host.net не принял проверку — блокировку IP проверить не удалось; ставлю дальше"; return 0 ;;
	esac
	IFS='|' read -r p ru_ok ru_done ru_n eu_ok eu_done eu_n ru_s eu_s <<<"$line"
	if [ "$(port_verdict "$ru_ok" "$ru_done" "$ru_n" "$eu_ok" "$eu_done")" = RU_BLOCKED ]; then
		# Прежде чем отказаться от установки — ещё раз, через полминуты: узлы иногда сбоят вместе.
		sleep 30
		line=$(chk_probe "$PUBLIC_IP" "$port" | head -1) || line=
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
				tty_flush
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
	if [ "${PANEL_PUBLIC:-0}" = 1 ]; then ports="$ports $WEB_PORT"; fi
	if [ "${SUB_TLS:-0}" = 1 ]; then ports="$ports $SUB_PORT"; fi   # :80 при сертификате на IP открыт только во время продления
	# shellcheck disable=SC2086
	chk_probe "$PUBLIC_IP" $ports > "$CHK_OUT" || true
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
			"$SUB_PORT") what="подписка" ;;
			"$WEB_PORT") what="панель" ;;
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
		if [ "${SUB_TLS:-0}" = 1 ]; then
			raw=$(curl -sk --max-time 15 "https://127.0.0.1:$SUB_PORT$SUB_PATH$1") || return 1
		else
			raw=$(curl -s --max-time 15 "http://127.0.0.1:$SUB_PORT$SUB_PATH$1") || return 1
		fi
	fi
	base64 -d <<<"$raw" 2>/dev/null || printf '%s\n' "$raw"
}

local_checks() {
	local s p code sid link exit_ip exit_warp log
	say "Проверка изнутри сервера"
	for s in x-ui $([ "$MODE" = domain ] && echo nginx) $([ -f "$F2B_JAIL" ] && echo fail2ban); do
		if systemctl is-active -q "$s"; then ok "служба $s работает"; else bad "служба $s не работает (journalctl -u $s)"; fi
	done
	for p in $([ "$MODE" = domain ] && echo "$LISTEN_IP:443 127.0.0.1:8443") ":$WEB_PORT" "$([ "${SUB_TLS:-0}" = 1 ] && echo ":$SUB_PORT" || echo "127.0.0.1:$SUB_PORT")" ":$REALITY_PORT"; do
		if wait_port "$p" 15; then ok "слушает $p"; else bad "никто не слушает $p"; fi
	done
	if [ "$(exit_mode_now)" = chain ]; then
		s=$(chain_active)
		if [ "$s" = chain ]; then
			ok "выход клиентов: $(exit_label chain)"
		else
			warn "выход клиентов: $(exit_label chain), но сейчас $(active_label "$s"): старый сервер $CHAIN_IP:$CHAIN_PORT отсюда недоступен (выключен? порт закрыт у хостера?) — когда вернётся, вотчдог переключит сам"
		fi
		if [ -f /etc/systemd/system/vpn-exit-watchdog.service ]; then
			if systemctl is-active -q vpn-exit-watchdog; then ok "вотчдог следит за старым сервером (упадёт — российские сайты через WARP, остальное напрямую; вернётся — назад)"; else bad "вотчдог не работает (journalctl -u vpn-exit-watchdog)"; fi
		fi
	else
		ok "выход клиентов: $(exit_label "$(exit_mode_now)") (переключить: vpn-warp off|on|ru)"
	fi
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
		if [ "$PANEL_PUBLIC" = 1 ]; then
			code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://$LISTEN_IP:$WEB_PORT$WEB_PATH" || true)
			if [ "$code" = 200 ]; then ok "панель отвечает 200 по IP (https://$PUBLIC_IP:$WEB_PORT/…)"; else bad "панель по IP отвечает $code"; fi
			code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://$LISTEN_IP:$WEB_PORT/" || true)
			case $code in
				2* | 3*) warn "без секретного пути порт панели отвечает $code — панель проще найти сканерам" ;;
				*) ok "без секретного пути панель не открывается (ответ $code)" ;;
			esac
		else
			code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://127.0.0.1:$WEB_PORT$WEB_PATH" || true)
			if [ "$code" = 200 ]; then ok "панель отвечает 200 (на 127.0.0.1, снаружи — через SSH-туннель)"; else bad "панель отвечает $code"; fi
		fi
		# Кто прощупывает сервер без ключа, должен увидеть настоящий сайт с верным сертификатом.
		if timeout 10 openssl s_client -connect "$LISTEN_IP:$REALITY_PORT" -servername "$REALITY_SNI" -verify_hostname "$REALITY_SNI" \
			-verify_return_error < /dev/null 2>&1 | grep 'Verify return code: 0 (ok)' >/dev/null; then
			ok "чужим на :$REALITY_PORT отвечает настоящий $REALITY_SNI (сертификат верный)"
		else
			bad "проба :$REALITY_PORT с SNI $REALITY_SNI не получила настоящий сертификат сайта"
		fi
		if [ "${SUB_TLS:-0}" = 1 ]; then
			if openssl x509 -checkend 172800 -noout -in "$IPCERT_DIR/fullchain.pem" >/dev/null 2>&1; then
				ok "сертификат Let's Encrypt на IP действует до $(openssl x509 -enddate -noout -in "$IPCERT_DIR/fullchain.pem" | cut -d= -f2) (продлевается сам)"
			else
				bad "сертификат на IP истёк или истекает меньше чем через 2 дня — продление не идёт (порт 80 открыт? /root/.acme.sh/acme.sh --cron --home /root/.acme.sh)"
			fi
		fi
	fi
	sid=$(sqlite3 -readonly "$DB" "select sub_id from clients where enable=1 and sub_id<>'' order by id limit 1;" 2>/dev/null || true)
	if [ "$MODE" = nodomain ] && [ "${SUB_TLS:-0}" = 1 ] && [ -n "$sid" ]; then
		# Как приложение: по адресу IP, с проверкой сертификата.
		code=$(curl -s $IPK -o /dev/null -w '%{http_code}' --max-time 15 --connect-to "$PUBLIC_IP:$SUB_PORT:$LISTEN_IP:$SUB_PORT" "https://$PUBLIC_IP:$SUB_PORT$SUB_PATH$sid" || true)
		if [ "$code" = 200 ]; then ok "подписка открывается по https://$PUBLIC_IP:$SUB_PORT/… с проверкой сертификата"; else bad "подписка по https://$PUBLIC_IP:$SUB_PORT/… отвечает $code"; fi
	fi
	link=$( { [ -n "$sid" ] && sub_fetch "$sid"; } | grep -m1 '^vless://' || true)
	if [ -n "$link" ]; then
		ok "подписка отдаёт ссылку"
		case $link in *"@$SHARE_ADDR:$REALITY_PORT"*) ok "в ссылке адрес $SHARE_ADDR:$REALITY_PORT" ;; *) bad "в ссылке не тот адрес: ${link%%\?*}" ;; esac
		read -r code exit_ip exit_warp log <<<"$(tunnel_check "$link")"
		s=$(exit_mode_now); p=
		[ "$s" != chain ] || p=$(chain_active)
		if [ "$code" != 204 ]; then
			bad "туннель по ссылке клиента не работает (ответ $code): $log"
		elif [ "$exit_warp" = on ] || [ "$exit_warp" = plus ]; then
			ok "туннель по ссылке клиента работает, выход через Cloudflare WARP ($exit_ip)"
		elif [ "$s" = warp ] || [ "$p" = warp ]; then
			bad "туннель работает, но выход с IP $exit_ip, а должен идти через Cloudflare WARP — WARP отсюда не работает (выход напрямую: vpn-warp off)"
		elif [ "$p" = chain ] && [ "$exit_ip" != "$CHAIN_IP" ] && [ "$exit_ip" != "$(getent ahostsv4 "$CHAIN_IP" 2>/dev/null | awk 'NR == 1 {print $1}')" ]; then
			warn "туннель работает, выход с IP $exit_ip — не с адреса старого сервера $CHAIN_IP (у него другой IP выхода в интернет?)"
		else
			ok "туннель по ссылке клиента работает, выход с IP $exit_ip$([ "$p" = chain ] && echo " (старый сервер)")"
		fi
	else
		bad "подписка не отдала vless-ссылку — туннель не проверить"
	fi
}

xui_stop() {  # остановить x-ui на время правки базы; вотчдог цепочки — тоже, чтобы не перезапустил x-ui посреди правки
	systemctl stop vpn-exit-watchdog 2>/dev/null || true
	systemctl stop x-ui 2>/dev/null || true
	# Первая остановка работавшего VPN — снимок базы: оборвётся установка — база вернётся как была до запуска.
	if [ "$XUI_TOUCHED" = 0 ] && [ "$XUI_WAS_ACTIVE" = 1 ] && [ -f "$DB" ]; then
		sqlite3 "$DB" ".backup '$WORK/db.before'" 2>/dev/null || cp -a "$DB" "$WORK/db.before" 2>/dev/null || true
	fi
	XUI_TOUCHED=1
}
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
	python3 - "$1" "$2" "${3:--}" <<'PY'
import json, sys
mode, warp_file, chain_file = sys.argv[1], sys.argv[2], sys.argv[3]
warp = json.load(open(warp_file)) if warp_file != "-" else None
chain = json.load(open(chain_file)) if chain_file != "-" else None
# Внутренние адреса (127.0.0.1, 10/8, 169.254/16, 192.168/16 …) клиентам закрыты и по имени: правило geoip:private
# в routing ловит только IP, а «localhost» или имя, указывающее внутрь, freedom разрешает сам — без блокировки здесь
# клиент VPN достучался бы до служб самого сервера (API Xray, метрики, панель на 127.0.0.1) и его сети.
# Проверено на Xray 26.6.1: без finalRules «localhost» тоже открыт, с этим правилом — нет.
direct = {"protocol": "freedom", "settings": {"domainStrategy": "AsIs", "finalRules": [
    {"action": "block", "ip": ["geoip:private"]}, {"action": "allow"}]}, "tag": "direct"}
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
elif mode == "chain" and chain:
    # Цепочка через чужой сервер первым выходом; WARP — для российских сайтов в запасном режиме (вотчдог переключает).
    outbounds = [chain] + ([warp] if warp else []) + [direct, blocked]
    main, dns_out = "chain", "chain"
else:
    outbounds, main, dns_out = [direct, blocked], "direct", "direct"
# Метки main и dns-out: по ним вотчдог и vpn-check находят главные правила, а не по признакам.
rules += [{"type": "field", "ruleTag": "dns-out", "inboundTag": ["dns-internal"], "outboundTag": dns_out},
          {"type": "field", "ruleTag": "main", "network": "tcp,udp", "outboundTag": main}]
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
S_EXIT='$EXIT_MODE'
S_PANEL_PUBLIC='${PANEL_PUBLIC:-0}'
S_IP_CERT='${IP_CERT-${S_IP_CERT:-0}}'
S_IP_CERT_IP='${IP_CERT_IP-${S_IP_CERT_IP:-}}'
S_DO_UFW='${DO_UFW:-1}'
S_DO_F2B='${DO_F2B:-1}'
S_TZ='${TZ_NAME:-}'
S_DONE='${S_DONE:-0}'
S_REALITY_PORT='$REALITY_PORT'
CHAIN_IP='${CHAIN_IP:-}'
CHAIN_PORT='${CHAIN_PORT:-}'
CHAIN_UUID='${CHAIN_UUID:-}'
CHAIN_PUB='${CHAIN_PUB:-}'
CHAIN_PRIV='${CHAIN_PRIV:-}'
CHAIN_SID='${CHAIN_SID:-}'
CHAIN_SNI='${CHAIN_SNI:-}'
CHAIN_SSH_USER='${CHAIN_SSH_USER:-}'
CHAIN_SSH_PORT='${CHAIN_SSH_PORT:-}'
CHAIN_FW='${CHAIN_FW:-}'
S_BOT='${S_BOT:-}'
S_BOT_USER='${S_BOT_USER:-}'
S_BOT_ORIGIN='${S_BOT_ORIGIN:-}'
S_BOT_WORKER='${S_BOT_WORKER:-}'
S_BOT_SSH_PORT='${S_BOT_SSH_PORT:-}'
EOF
	# Файл потом читается через «.»: значение с кавычкой исполнилось бы как команда — такой не сохранять.
	if grep -v '^#' "$tmp" | grep -q "^[A-Z_0-9]*='.*'.*'"; then rm -f "$tmp"; die "в настройках оказалась кавычка — $STATE не записан"; fi
	chmod 600 "$tmp"
	mv "$tmp" "$STATE"
}
WARP_SAVED=/etc/x-ui/warp/outbound.json   # копия outbound warp: vpn-warp on после off берёт её, а не регистрирует заново

current_warp() {  # current_warp ФАЙЛ ← outbound warp: из шаблона Xray, а если WARP выключен — из сохранённой копии
	python3 - "$DB" "$1" <<'PY' || { [ -s "$WARP_SAVED" ] && cp "$WARP_SAVED" "$1"; }
import json, sqlite3, sys
row = sqlite3.connect(sys.argv[1]).execute("select value from settings where key='xrayTemplateConfig'").fetchone()
t = json.loads(row[0]) if row and row[0] else {}
w = next((o for o in t.get("outbounds", []) if o.get("tag") == "warp"), None)
if not w:
    sys.exit(1)
json.dump(w, open(sys.argv[2], "w"))
PY
}

save_warp() { install -d -m 700 /etc/x-ui/warp && install -m 600 "$1" "$WARP_SAVED"; }

exit_mode_now() {  # → direct | warp | warp-ru — по шаблону Xray в базе
	python3 - "$DB" <<'PY'
import json, sqlite3, sys
row = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True).execute("select value from settings where key='xrayTemplateConfig'").fetchone()
t = json.loads(row[0]) if row and row[0] else {}
rules = (t.get("routing") or {}).get("rules") or []
main = next((r.get("outboundTag") for r in rules if r.get("ruleTag") == "main"), None) or \
    next((r.get("outboundTag") for r in rules if r.get("network") == "tcp,udp"), None)
main = main or ((t.get("outbounds") or [{}])[0].get("tag") or "direct")
if any(o.get("tag") == "chain" for o in t.get("outbounds") or []):
    print("chain")           # цепочка настроена; активный путь (chain/warp) — отдельно, chain_active
elif main == "warp":
    print("warp")
elif any(r.get("outboundTag") == "warp" and (r.get("domain") or r.get("ip")) for r in rules):
    print("warp-ru")
else:
    print("direct")
PY
}

exit_label() {
	case $1 in
		direct) echo "напрямую с IP сервера" ;;
		warp) echo "всё через Cloudflare WARP" ;;
		warp-ru) echo "российские сайты через WARP, остальное напрямую" ;;
		chain) echo "цепочкой через сервер ${CHAIN_IP:-?}" ;;
		*) echo "$1" ;;
	esac
}

chain_active() {  # активный выход цепочки: chain (старый сервер) | direct (запасной: РФ через WARP) | warp (запасной прежней версии)
	python3 - "$DB" <<'PY'
import json, sqlite3, sys
row = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True).execute("select value from settings where key='xrayTemplateConfig'").fetchone()
t = json.loads(row[0]) if row and row[0] else {}
rules = (t.get("routing") or {}).get("rules") or []
cat = [r for r in rules if r.get("ruleTag") == "main"] or [r for r in rules if r.get("network") == "tcp,udp"]
print(cat[0].get("outboundTag", "chain") if cat else "chain")
PY
}

active_label() {  # понятное имя активного пути цепочки
	case $1 in
		direct) echo "запасной режим — российские сайты через WARP, остальное напрямую" ;;
		warp) echo "аварийный WARP (весь трафик)" ;;
		chain) echo "старый сервер ${CHAIN_IP:-?}" ;;
		*) echo "$1" ;;
	esac
}

chain_activate() {  # chain_activate chain|fallback — как переключение вотчдога (x-ui остановлен)
	python3 - "$DB" "$1" chain <<'PY'
import json
import sqlite3
import sys

path, mode, chain = sys.argv[1:4]
RU_TAG = "ru-via-warp"
db = sqlite3.connect(path, timeout=30)
t = json.loads(db.execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0])
tags = {o.get("tag") for o in t.get("outbounds", [])}
main = chain if mode == "chain" else "direct"
if main not in tags:
    sys.exit(3)
all_rules = t["routing"]["rules"]
# Главные правила помечены ruleTag (main — весь трафик, dns-out — DNS самого Xray). В шаблонах прежних версий
# меток нет — тогда по признакам; свои правила человека с network tcp,udp при метках не трогаются.
tagged = any(r.get("ruleTag") in ("main", "dns-out") for r in all_rules)


def is_ru(r):
    return r.get("ruleTag") == RU_TAG or (r.get("outboundTag") == "warp" and (
        "geosite:category-ru" in (r.get("domain") or []) or "geoip:ru" in (r.get("ip") or [])))


def is_main(r):
    if tagged:
        return r.get("ruleTag") in ("main", "dns-out")
    return r.get("network") == "tcp,udp" or "dns-internal" in (r.get("inboundTag") or [])


rules = [r for r in all_rules if not is_ru(r)]
for r in rules:
    if is_main(r):
        r["outboundTag"] = main
        r.pop("balancerTag", None)
if mode == "fallback" and "warp" in tags:
    at = next((i for i, r in enumerate(rules) if is_main(r)), len(rules))
    rules[at:at] = [
        {"type": "field", "ruleTag": RU_TAG, "outboundTag": "warp",
         "domain": ["geosite:category-ru", "domain:ru", "domain:su", "domain:xn--p1ai"]},
        {"type": "field", "ruleTag": RU_TAG, "outboundTag": "warp", "ip": ["geoip:ru"]},
    ]
t["routing"]["rules"] = rules
# Основной выход первым, остальные в постоянном порядке — переключение туда-обратно даёт тот же шаблон.
rank = {chain: 0, "warp": 1, "direct": 2, "blocked": 3}
t["outbounds"] = sorted(t["outbounds"], key=lambda o: (o.get("tag") != main, rank.get(o.get("tag"), 9)))
db.execute("update settings set value=? where key='xrayTemplateConfig'", (json.dumps(t, ensure_ascii=False),))
db.commit()
PY
}

CHAIN_SAVED=/etc/x-ui/chain/outbound.json   # копия outbound цепочки (для повторной сборки шаблона и бэкапа)
save_chain() { install -d -m 700 /etc/x-ui/chain && install -m 600 "$1" "$CHAIN_SAVED"; }

build_chain_outbound() {  # build_chain_outbound ФАЙЛ ← outbound chain из CHAIN_* (VLESS-TCP+Reality на старый сервер)
	python3 - "$1" "$CHAIN_IP" "$CHAIN_PORT" "$CHAIN_UUID" "$CHAIN_PUB" "$CHAIN_SID" "$CHAIN_SNI" <<'PY'
import json, sys
out, ip, port, uuid, pub, sid, sni = sys.argv[1:8]
json.dump({"tag": "chain", "protocol": "vless",
           "settings": {"vnext": [{"address": ip, "port": int(port),
                                    "users": [{"id": uuid, "encryption": "none", "flow": ""}]}]},
           "streamSettings": {"network": "tcp", "security": "reality",
                              "realitySettings": {"serverName": sni, "publicKey": pub, "shortId": sid,
                                                  "fingerprint": "chrome"}}}, open(out, "w"))
PY
}

exit_ssh_opts() {  # общие опции ssh/scp к старому серверу; ключ — только он и без вопросов, пароль — без попыток ключей
	EXIT_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o "UserKnownHostsFile=$WORK/exit_known_hosts")
	if [ -n "$EXIT_SSH_KEY" ]; then
		EXIT_SSH_OPTS+=(-i "$EXIT_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o PasswordAuthentication=no)
	else
		EXIT_SSH_OPTS+=(-o PubkeyAuthentication=no)
	fi
}
# Соединение не установилось (потерянный SYN, обрыв на приветствии или обмене ключами — бывает у хостеров
# с фильтрами от DDoS): команда на старом сервере не начиналась, и повтор безопасен. Обрыв посреди сеанса
# («closed by remote host», «client_loop: …») и отказ в пароле не повторяются — команда могла уже пройти.
exit_conn_failed() {  # exit_conn_failed КОД ФАЙЛ_STDERR
	[ "$1" = 255 ] && grep -qE '^(ssh: connect to host [^ ]+ port [0-9]+: Connection timed out|Connection to [^ ]+ port [0-9]+ timed out|Connection timed out during banner exchange|kex_exchange_identification: .*|Connection (closed|reset) by [^ ]+ port [0-9]+)$' "$2"
}
exit_retry() {  # exit_retry [--in СТРОКА] КОМАНДА… — до 3 попыток, пока соединение не установилось; stderr — последней
	local feed=0 in='' try=1 rc err=$WORK/exit_ssh.err
	if [ "$1" = --in ]; then feed=1 in=$2; shift 2; fi
	while :; do
		rc=0
		if [ "$feed" = 1 ]; then "$@" <<< "$in" 2> "$err" || rc=$?; else "$@" 2> "$err" || rc=$?; fi
		if [ "$try" -lt "${EXIT_SSH_TRIES:-3}" ] && exit_conn_failed "$rc" "$err"; then
			try=$((try + 1))
			sleep "${EXIT_SSH_RETRY_SLEEP:-3}"
			continue
		fi
		cat "$err" >&2
		rm -f "$err"
		return "$rc"
	done
}
ssh_exit() {  # ssh на старый сервер (ключ EXIT_SSH_KEY, иначе пароль из EXIT_PASS); -n — не трогать терминал
	exit_ssh_opts
	if [ -n "$EXIT_SSH_KEY" ]; then
		exit_retry ssh -n "${EXIT_SSH_OPTS[@]}" -p "$EXIT_SSH_PORT" "$EXIT_SSH_USER@$EXIT_HOST" "$@"
	else
		SSHPASS="${EXIT_PASS:-}" exit_retry sshpass -e ssh -n "${EXIT_SSH_OPTS[@]}" -p "$EXIT_SSH_PORT" "$EXIT_SSH_USER@$EXIT_HOST" "$@"
	fi
}
scp_exit() {  # scp файла $1 на старый сервер в $2
	exit_ssh_opts
	if [ -n "$EXIT_SSH_KEY" ]; then
		exit_retry scp "${EXIT_SSH_OPTS[@]}" -P "$EXIT_SSH_PORT" "$1" "$EXIT_SSH_USER@$EXIT_HOST:$2"
	else
		SSHPASS="${EXIT_PASS:-}" exit_retry sshpass -e scp "${EXIT_SSH_OPTS[@]}" -P "$EXIT_SSH_PORT" "$1" "$EXIT_SSH_USER@$EXIT_HOST:$2"
	fi
}

ssh_exit_in() {  # как ssh_exit, но stdin уходит удалённой команде (пароль для sudo -S); при повторе — тот же
	local in
	in=$(cat; echo .)
	in=${in%.}
	in=${in%$'\n'}   # <<< вернёт перевод строки сам
	exit_ssh_opts
	if [ -n "$EXIT_SSH_KEY" ]; then
		exit_retry --in "$in" ssh "${EXIT_SSH_OPTS[@]}" -p "$EXIT_SSH_PORT" "$EXIT_SSH_USER@$EXIT_HOST" "$@"
	else
		SSHPASS="${EXIT_PASS:-}" exit_retry --in "$in" sshpass -e ssh "${EXIT_SSH_OPTS[@]}" -p "$EXIT_SSH_PORT" "$EXIT_SSH_USER@$EXIT_HOST" "$@"
	fi
}

prepare_exit_key() {  # ключ (вставленный или файл) → $WORK/exit_key: OpenSSH, права 600, без \r, без парольной фразы
	local k=$WORK/exit_key src=$WORK/exit_key.src ppf=$WORK/exit_key.pp err pp=${EXIT_KEY_PASS:-}
	if [ -n "$EXIT_KEY_TEXT" ]; then
		(umask 077 && printf '%s\n' "$EXIT_KEY_TEXT" | tr -d '\r' | normalize_key > "$src") || { CHAIN_ERR="не удалось сохранить ключ"; return 1; }
	else
		(umask 077 && tr -d '\r' < "$EXIT_SSH_KEY" | normalize_key > "$src") || { CHAIN_ERR="не удалось прочитать ключ $EXIT_SSH_KEY"; return 1; }
	fi
	EXIT_KEY_TEXT=
	if grep -q '^PuTTY-User-Key-File' "$src"; then   # ключ PuTTY (.ppk) — в формат OpenSSH
		command -v puttygen >/dev/null || "${APT[@]}" install putty-tools >/dev/null 2>&1 ||
			{ CHAIN_ERR="это ключ PuTTY (.ppk), а putty-tools не установился — сохраните ключ в PuTTYgen: Conversions → Export OpenSSH key"; return 1; }
		(umask 077 && : > "$ppf")
		if ! grep -q '^Encryption: none' "$src"; then
			if [ -z "$pp" ] && { : > /dev/tty; } 2>/dev/null; then
				tty_flush
				printf 'Ключ защищён парольной фразой — введите её: ' > /dev/tty
				IFS= read -r pp < /dev/tty || true
			fi
			[ -n "$pp" ] || { CHAIN_ERR="ключ PuTTY защищён парольной фразой — передайте её в EXIT_KEY_PASS"; return 1; }
			printf '%s' "$pp" > "$ppf"
		fi
		if ! puttygen "$src" --old-passphrase "$ppf" -O private-openssh -o "$k" >/dev/null 2>&1; then
			rm -f "$ppf" "$src"; CHAIN_ERR="ключ PuTTY не перевёлся в OpenSSH (неверная парольная фраза?)"; return 1
		fi
		rm -f "$ppf" "$src"
	else
		mv -f "$src" "$k"
	fi
	chmod 600 "$k"
	if ! err=$(ssh-keygen -y -P "" -f "$k" 2>&1 >/dev/null); then
		if grep -qi passphrase <<<"$err"; then
			if [ -z "$pp" ] && { : > /dev/tty; } 2>/dev/null; then
				tty_flush
				printf 'Ключ защищён парольной фразой — введите её: ' > /dev/tty
				IFS= read -r pp < /dev/tty || true
			fi
			[ -n "$pp" ] || { CHAIN_ERR="ключ защищён парольной фразой — передайте её в EXIT_KEY_PASS"; return 1; }
			ssh-keygen -p -P "$pp" -N "" -f "$k" >/dev/null 2>&1 || { CHAIN_ERR="парольная фраза к ключу не подошла"; return 1; }
		else
			CHAIN_ERR="ключ не читается — нужен приватный ключ целиком, от -----BEGIN до -----END ($(tr '\n' ' ' <<<"$err" | head -c 120))"
			return 1
		fi
	fi
	EXIT_SSH_KEY=$k
	ok "SSH-ключ к старому серверу прочитан ($(ssh-keygen -l -f "$k" 2>/dev/null | awk '{print $NF}' | tr -d '()'))"
}

emit_exit_setup() {  # пишет в $WORK/exit-setup.sh скрипт настройки старого сервера (запускается там)
	cat > "$WORK/exit-setup.sh" <<'VPN_EXIT_SETUP'
#!/bin/bash
# Настройка сервера-выхода: Xray с одним входом VLESS-TCP+Reality, который дёргает новый сервер.
# Запускается от root (напрямую или через sudo). Параметры и секреты — в exit.env рядом со скриптом;
# папка со скриптом (~/.vpn-exit-stage) удаляется в конце, в том числе при ошибке.
set -eu
trap 'echo "EXIT_RESULT=FAIL на старом сервере не прошла команда (строка $LINENO скрипта настройки)"' ERR
STAGE=$(dirname "$(readlink -f "$0")")
case $STAGE in */.vpn-exit-stage) trap 'rm -rf "$STAGE"' EXIT ;; esac
[ -f "$STAGE/exit.env" ] || { echo "EXIT_RESULT=FAIL нет параметров (exit.env)"; exit 1; }
# shellcheck source=/dev/null
. "$STAGE/exit.env"
[ "$(id -u)" = 0 ] || { echo "EXIT_RESULT=FAIL настройка старого сервера запущена не от root"; exit 1; }
export LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive
command -v apt-get >/dev/null || { echo "EXIT_RESULT=FAIL нужен Ubuntu/Debian на старом сервере"; exit 1; }
case $(uname -m) in
	x86_64 | amd64) A=amd64; SHA=$XUI_SHA_AMD64 ;;
	aarch64 | arm64) A=arm64; SHA=$XUI_SHA_ARM64 ;;
	*) echo "EXIT_RESULT=FAIL архитектура $(uname -m) не поддержана"; exit 1 ;;
esac
# Пакеты — только если чего-то нет: на старом сервере apt бывает сломан (снятый с поддержки релиз), а всё нужное стоит.
need=
for c in curl python3 openssl ss tar; do command -v "$c" >/dev/null 2>&1 || need=1; done
[ -s /etc/ssl/certs/ca-certificates.crt ] || need=1
if [ -n "$need" ]; then
	for t in 1 2 3 4 5 6; do apt-get -y -q -o DPkg::Lock::Timeout=600 update >/dev/null 2>&1 && break; [ "$t" = 6 ] && { echo "EXIT_RESULT=FAIL apt-get update на старом сервере не прошёл"; exit 1; }; sleep 15; done
	apt-get -y -q -o DPkg::Lock::Timeout=600 install curl ca-certificates python3 openssl iproute2 tar >/dev/null 2>&1 ||
		{ echo "EXIT_RESULT=FAIL на старом сервере не установились curl, python3, openssl, iproute2 (apt-get install)"; exit 1; }
fi
# Старый сервер мог быть прежним VPN на 3x-ui. Цепочке он не мешает (отдельный процесс, другой порт),
# но по желанию (STOP_XUI=1) выключаем — если старый теперь только выход.
XUISTAT=absent
if [ -f /etc/systemd/system/x-ui.service ] || [ -x /usr/local/x-ui/x-ui ]; then
	if systemctl is-active -q x-ui 2>/dev/null; then XUISTAT=running; else XUISTAT=stopped; fi
fi
if [ "${STOP_XUI:-0}" = 1 ] && [ "$XUISTAT" != absent ]; then
	systemctl disable --now x-ui >/dev/null 2>&1 || true
	XUISTAT=stopped
fi
# Порт цепочки занят чужим процессом — отказ до любых изменений (свой прежний vpn-exit не в счёт).
own=$(systemctl show -p MainPID --value vpn-exit 2>/dev/null || true); own=${own:-0}
lst=$(ss -Htlnp "sport = :$EXIT_PORT" 2>/dev/null || true)
if [ -n "$lst" ] && { [ "$own" = 0 ] || ! grep -q "pid=$own," <<<"$lst"; }; then
	who=$(grep -o 'users:(("[^"]*"' <<<"$lst" | cut -d'"' -f2 | sort -u | tr '\n' ' ')
	echo "EXIT_RESULT=FAIL порт $EXIT_PORT на старом сервере занят (${who:-другой процесс}) — укажи другой --exit-port или выключи 3x-ui (--exit-stop-xui)"; exit 1
fi
DIR=/usr/local/vpn-exit; install -d -m 755 "$DIR"
if [ -s "$STAGE/xray" ]; then
	install -m 755 "$STAGE/xray" "$DIR/xray"
	cp -a "$STAGE/geoip.dat" "$STAGE/geosite.dat" "$DIR/" 2>/dev/null || true
else
	TMP=$(mktemp -d); U=https://github.com/MHSanaei/3x-ui/releases/download/v$XUI_VER/x-ui-linux-$A.tar.gz
	curl -fL --retry 3 -s -o "$TMP/x.tgz" "$U" || { echo "EXIT_RESULT=FAIL не скачался Xray"; exit 1; }
	echo "$SHA  $TMP/x.tgz" | sha256sum -c --quiet - >/dev/null 2>&1 || { echo "EXIT_RESULT=FAIL sha256 Xray не сошёлся"; exit 1; }
	tar -C "$TMP" -xzf "$TMP/x.tgz"
	install -m 755 "$TMP/x-ui/bin/xray-linux-$A" "$DIR/xray"
	cp -a "$TMP/x-ui/bin/geoip.dat" "$TMP/x-ui/bin/geosite.dat" "$DIR/" 2>/dev/null || true
	rm -rf "$TMP"
fi
# Сайт для маскировки Reality на старом сервере — реальный, доступный отсюда, TLS1.3/X25519/HTTP2, не Cloudflare.
cf() { python3 - "$1" <<'PYC'
import ipaddress,sys
nets="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22".split()
ip=ipaddress.ip_address(sys.argv[1]); sys.exit(0 if any(ip in ipaddress.ip_network(n) for n in nets) else 1)
PYC
}
SNI=
for d in ${EXIT_SNI_HINT:-} www.apple.com swdist.apple.com www.samsung.com dl.google.com www.nvidia.com www.intel.com www.amazon.com; do
	[ -n "$d" ] || continue
	ip=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}'); [ -n "$ip" ] || continue
	cf "$ip" && continue
	o=$(timeout 8 openssl s_client -connect "$ip:443" -servername "$d" -verify_hostname "$d" -verify_return_error -tls1_3 -groups X25519 -alpn h2 </dev/null 2>&1) || continue
	grep -q 'New, TLSv1.3' <<<"$o" && grep -q 'ALPN protocol: h2' <<<"$o" && grep -q 'Server Temp Key: X25519' <<<"$o" && grep -q 'Verify return code: 0 (ok)' <<<"$o" && { SNI=$d; break; }
done
[ -n "$SNI" ] || { echo "EXIT_RESULT=FAIL не нашёлся сайт для маскировки (нет выхода на 443?)"; exit 1; }
# Секреты — через окружение, не аргументами: командную строку процесса видят все пользователи сервера.
EXIT_PORT=$EXIT_PORT CHAIN_PRIV=$CHAIN_PRIV CHAIN_UUID=$CHAIN_UUID CHAIN_SID=$CHAIN_SID SNI=$SNI python3 - "$DIR/config.new.json" <<'PYJ'
import json,os,sys
e=os.environ
out=sys.argv[1]
port,priv,uuid,sid,sni=e["EXIT_PORT"],e["CHAIN_PRIV"],e["CHAIN_UUID"],e["CHAIN_SID"],e["SNI"]
json.dump({"log":{"loglevel":"warning"},
 "inbounds":[{"listen":"0.0.0.0","port":int(port),"protocol":"vless",
   "settings":{"clients":[{"id":uuid,"flow":""}],"decryption":"none"},
   "streamSettings":{"network":"tcp","security":"reality",
     "realitySettings":{"show":False,"dest":sni+":443","xver":0,"serverNames":[sni],"privateKey":priv,"shortIds":[sid]}},
   "sniffing":{"enabled":False}}],
 "outbounds":[{"protocol":"freedom","tag":"direct",
   "settings":{"finalRules":[{"action":"block","ip":["geoip:private"]},{"action":"allow"}]}},
  {"protocol":"blackhole","tag":"blocked"}],
 "routing":{"rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"},
                     {"type":"field","protocol":["bittorrent"],"outboundTag":"blocked"}]}},open(out,"w"))
PYJ
chmod 600 "$DIR/config.new.json"
if ! XRAY_LOCATION_ASSET=$DIR "$DIR/xray" run -test -c "$DIR/config.new.json" >/dev/null 2>&1; then
	rm -f "$DIR/config.new.json"; echo "EXIT_RESULT=FAIL Xray на старом сервере не принял конфиг выхода (xray run -test)"; exit 1
fi
[ ! -f "$DIR/config.json" ] || cp -a "$DIR/config.json" "$DIR/config.bak.json"
mv -f "$DIR/config.new.json" "$DIR/config.json"
cat > /etc/systemd/system/vpn-exit.service <<UNIT
[Unit]
Description=VPN exit node (Xray VLESS-TCP+Reality inbound)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
Environment=XRAY_LOCATION_ASSET=$DIR
ExecStart=$DIR/xray run -c $DIR/config.json
Restart=always
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable vpn-exit >/dev/null 2>&1 || true
systemctl restart vpn-exit || true
ok=0; for _ in $(seq 1 20); do systemctl is-active -q vpn-exit 2>/dev/null && ss -Htln "sport = :$EXIT_PORT" 2>/dev/null | grep -q . && { ok=1; break; }; sleep 1; done
if [ "$ok" != 1 ]; then
	# Новый конфиг не поднялся — вернуть прежний, если был: выход для уже работающего входа не пропадёт.
	# (Временные файлы — с расширением .json: по нему Xray узнаёт формат конфига.)
	if [ -f "$DIR/config.bak.json" ]; then mv -f "$DIR/config.bak.json" "$DIR/config.json"; systemctl restart vpn-exit 2>/dev/null || true; fi
	echo "EXIT_RESULT=FAIL vpn-exit не слушает порт $EXIT_PORT (journalctl -u vpn-exit)"; exit 1
fi
rm -f "$DIR/config.bak.json"
# Фаервол: если ufw активен — пустить новый сервер на порт цепочки (ssh не трогаем). Неактивный ufw не включаем, чтобы не запереть.
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
	ufw allow from "$ENTRY_IP" to any port "$EXIT_PORT" proto tcp >/dev/null 2>&1 || true
	echo "EXIT_UFW=restricted"
elif command -v iptables >/dev/null && iptables -S INPUT 2>/dev/null | grep -qE -- '-j (REJECT|DROP)|^-P INPUT DROP'; then
	# iptables без ufw, лишнее отклоняется (так у образов Oracle Cloud): пустить новый сервер и сохранить правило.
	iptables -C INPUT -p tcp -s "$ENTRY_IP" --dport "$EXIT_PORT" -j ACCEPT 2>/dev/null ||
		iptables -I INPUT 1 -p tcp -s "$ENTRY_IP" --dport "$EXIT_PORT" -j ACCEPT
	saved=
	if command -v netfilter-persistent >/dev/null; then
		netfilter-persistent save >/dev/null 2>&1 && saved=1
	elif [ -d /etc/iptables ]; then
		iptables-save > /etc/iptables/rules.v4 2>/dev/null && saved=1
	fi
	if [ -n "$saved" ]; then echo "EXIT_UFW=iptables"; else echo "EXIT_UFW=iptables-unsaved"; fi
else
	echo "EXIT_UFW=open"
fi
# >>> vpn-bot key — ключ Телеграм-бота владельца: бот открывает здесь порт новому входу при переезде
if [ -n "${BOT_PUBKEY:-}" ]; then
	bh=$(getent passwd "${BOT_SSH_USER:-root}" | cut -d: -f6)
	if [ -n "$bh" ] && [ -d "$bh" ]; then
		install -d -m 700 "$bh/.ssh"
		ak=$bh/.ssh/authorized_keys
		{ grep -vE ' vpn-bot$' "$ak" 2> /dev/null || true; printf '%s\n' "$BOT_PUBKEY"; } > "$ak.vpn-bot.tmp"
		chmod 600 "$ak.vpn-bot.tmp"
		chown "${BOT_SSH_USER:-root}:" "$bh/.ssh" "$ak.vpn-bot.tmp" 2> /dev/null || true
		mv -f "$ak.vpn-bot.tmp" "$ak"
		echo "EXIT_BOTKEY=ok"
	fi
fi
# <<< vpn-bot key
echo "EXIT_SNI=$SNI"
echo "EXIT_XUI=$XUISTAT"
echo "EXIT_RESULT=OK"
VPN_EXIT_SETUP
}

install_watchdog() {  # вотчдог: выход на цепочке; старый сервер недоступен — РФ через WARP, остальное напрямую; вернулся — назад
	cat > /usr/local/bin/vpn-exit-watchdog.sh <<'VPN_WD'
#!/bin/bash
# Выход цепочкой через EXIT_IP:EXIT_PORT. Сервер-выход недоступен FAIL_LIMIT проверок подряд — запасной режим:
# российские сайты (.ru/.su/.рф, geosite:category-ru, geoip:ru) через WARP, остальное и DNS напрямую.
# Доступен OK_LIMIT проверок подряд — обратно на цепочку.
set -u
DB=/etc/x-ui/x-ui.db
EXIT_IP=${EXIT_IP:?}
EXIT_PORT=${EXIT_PORT:?}
CHAIN=chain
FAIL_LIMIT=${FAIL_LIMIT:-4}; OK_LIMIT=${OK_LIMIT:-3}; INTERVAL=${INTERVAL:-30}
fails=0; oks=0
state() {  # chain | direct (запасной) | warp (запасной прежней версии)
python3 - "$DB" <<'PY'
import json, sqlite3, sys
t = json.loads(sqlite3.connect(sys.argv[1], timeout=30).execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0])
rules = t["routing"]["rules"]
cat = [r for r in rules if r.get("ruleTag") == "main"] or [r for r in rules if r.get("network") == "tcp,udp"]
print(cat[0].get("outboundTag", "?") if cat else "?")
PY
}
switch() {  # switch chain|fallback → 0, если шаблон переписан и x-ui перезапущен
python3 - "$DB" "$1" "$CHAIN" <<'PY' || return 1
import json
import sqlite3
import sys

path, mode, chain = sys.argv[1:4]
RU_TAG = "ru-via-warp"
db = sqlite3.connect(path, timeout=30)
t = json.loads(db.execute("select value from settings where key='xrayTemplateConfig'").fetchone()[0])
tags = {o.get("tag") for o in t.get("outbounds", [])}
main = chain if mode == "chain" else "direct"
if main not in tags:
    sys.exit(3)
all_rules = t["routing"]["rules"]
# Главные правила помечены ruleTag (main — весь трафик, dns-out — DNS самого Xray). В шаблонах прежних версий
# меток нет — тогда по признакам; свои правила человека с network tcp,udp при метках не трогаются.
tagged = any(r.get("ruleTag") in ("main", "dns-out") for r in all_rules)


def is_ru(r):
    return r.get("ruleTag") == RU_TAG or (r.get("outboundTag") == "warp" and (
        "geosite:category-ru" in (r.get("domain") or []) or "geoip:ru" in (r.get("ip") or [])))


def is_main(r):
    if tagged:
        return r.get("ruleTag") in ("main", "dns-out")
    return r.get("network") == "tcp,udp" or "dns-internal" in (r.get("inboundTag") or [])


rules = [r for r in all_rules if not is_ru(r)]
for r in rules:
    if is_main(r):
        r["outboundTag"] = main
        r.pop("balancerTag", None)
if mode == "fallback" and "warp" in tags:
    at = next((i for i, r in enumerate(rules) if is_main(r)), len(rules))
    rules[at:at] = [
        {"type": "field", "ruleTag": RU_TAG, "outboundTag": "warp",
         "domain": ["geosite:category-ru", "domain:ru", "domain:su", "domain:xn--p1ai"]},
        {"type": "field", "ruleTag": RU_TAG, "outboundTag": "warp", "ip": ["geoip:ru"]},
    ]
t["routing"]["rules"] = rules
# Основной выход первым, остальные в постоянном порядке — переключение туда-обратно даёт тот же шаблон.
rank = {chain: 0, "warp": 1, "direct": 2, "blocked": 3}
t["outbounds"] = sorted(t["outbounds"], key=lambda o: (o.get("tag") != main, rank.get(o.get("tag"), 9)))
db.execute("update settings set value=? where key='xrayTemplateConfig'", (json.dumps(t, ensure_ascii=False),))
db.commit()
PY
systemctl restart x-ui
}
probe() { timeout 3 bash -c "cat </dev/null >/dev/tcp/$EXIT_IP/$EXIT_PORT" 2>/dev/null; }
logger -t vpn-watchdog "started exit=$EXIT_IP:$EXIT_PORT (fail=$FAIL_LIMIT ok=$OK_LIMIT interval=${INTERVAL}s; fallback: RU via WARP, rest direct)"
while true; do
  st=$(state)
  if probe; then oks=$((oks+1)); fails=0; else fails=$((fails+1)); oks=0; fi
  if [ "$st" = "$CHAIN" ] && [ "$fails" -ge "$FAIL_LIMIT" ]; then
     if switch fallback; then logger -t vpn-watchdog "exit $EXIT_IP unreachable x$fails -> fallback: RU via WARP, rest direct"
     else logger -t vpn-watchdog "exit $EXIT_IP unreachable x$fails, switch to fallback FAILED (no direct outbound in template?)"; fi
     fails=0; oks=0
  elif { [ "$st" = direct ] || [ "$st" = warp ]; } && [ "$oks" -ge "$OK_LIMIT" ]; then
     if switch chain; then logger -t vpn-watchdog "exit $EXIT_IP recovered x$oks -> chain"
     else logger -t vpn-watchdog "exit $EXIT_IP recovered x$oks, switch to chain FAILED (no outbound $CHAIN in template?)"; fi
     oks=0; fails=0
  fi
  sleep "$INTERVAL"
done
VPN_WD
	chmod 755 /usr/local/bin/vpn-exit-watchdog.sh
	cat > /etc/systemd/system/vpn-exit-watchdog.service <<EOF
[Unit]
Description=VPN exit watchdog (chain primary, WARP on real exit-down)
After=network-online.target x-ui.service
[Service]
Type=simple
Environment=EXIT_IP=$CHAIN_IP EXIT_PORT=$CHAIN_PORT FAIL_LIMIT=4 OK_LIMIT=3 INTERVAL=30
ExecStart=/usr/local/bin/vpn-exit-watchdog.sh
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable vpn-exit-watchdog >/dev/null 2>&1 || true
	systemctl restart vpn-exit-watchdog || warn "вотчдог не запустился (journalctl -u vpn-exit-watchdog)"
}

chain_apply() {  # шаблон с цепочкой ($CHAIN_SAVED); порт старого отсюда закрыт — сразу запасной режим
	xui_stop
	xui_set "xrayTemplateConfig=$(template_json chain "$WORK/warp.json" "$CHAIN_SAVED")"
	if timeout 6 bash -c "cat </dev/null >/dev/tcp/$CHAIN_IP/$CHAIN_PORT" 2>/dev/null; then
		CHAIN_BLOCKED=0
		ok "весь трафик пойдёт через $CHAIN_IP; если он упадёт — вотчдог включит запасной режим (российские сайты через WARP, остальное напрямую) и вернёт назад"
	else
		CHAIN_BLOCKED=1
		chain_activate fallback
		warn "порт $CHAIN_PORT старого сервера $CHAIN_IP отсюда не открывается — почти всегда это фаервол хостера: откройте входящий TCP $CHAIN_PORT для $PUBLIC_IP в панели хостера (AWS — Security Group, Oracle — Security List или NSG). Пока — запасной режим (российские сайты через WARP, остальное напрямую); как порт откроется, вотчдог сам переключит на старый сервер"
	fi
}

setup_chain_exit() {  # настроить старый сервер по SSH и собрать outbound цепочки; ошибка → CHAIN_ERR
	# Новые настройки цепочки остаются только при удаче: неудачная попытка (другой сервер, неверный пароль)
	# возвращает прежние — работавшая цепочка не теряется.
	local p_ip=$CHAIN_IP p_port=$CHAIN_PORT p_uuid=$CHAIN_UUID p_pub=$CHAIN_PUB p_priv=$CHAIN_PRIV p_sid=$CHAIN_SID
	local p_sni=$CHAIN_SNI p_user=$CHAIN_SSH_USER p_sport=$CHAIN_SSH_PORT
	PREV_CHAIN_IP=$p_ip
	setup_chain_exit_try && return 0
	CHAIN_IP=$p_ip CHAIN_PORT=$p_port CHAIN_UUID=$p_uuid CHAIN_PUB=$p_pub CHAIN_PRIV=$p_priv CHAIN_SID=$p_sid
	CHAIN_SNI=$p_sni CHAIN_SSH_USER=$p_user CHAIN_SSH_PORT=$p_sport
	return 1
}

setup_chain_exit_try() {
	CHAIN_ERR=
	if [ -z "$EXIT_HOST" ] && [ -n "$CHAIN_IP" ]; then
		if [ -z "$CHAIN_PORT" ] || [ -z "$CHAIN_UUID" ] || [ -z "$CHAIN_PUB" ] || [ -z "$CHAIN_SID" ] || [ -z "$CHAIN_SNI" ]; then
			CHAIN_ERR="в $STATE не хватает настроек цепочки — настройте старый сервер заново: --exit-host $CHAIN_IP"
			return 1
		fi
		ok "цепочка: прежние настройки выхода ($CHAIN_IP:$CHAIN_PORT), старый сервер не трогаю"
		build_chain_outbound "$WORK/chain.json"; save_chain "$WORK/chain.json"
		return 0
	fi
	if [ "$EXIT_HOST" = "$PUBLIC_IP" ] || [ "$EXIT_HOST" = "$LISTEN_IP" ]; then
		CHAIN_ERR="$EXIT_HOST — это сам этот сервер, а выходом нужен другой (старый) сервер"
		return 1
	fi
	CHAIN_IP=$EXIT_HOST
	CHAIN_PORT=${EXIT_PORT_ARG:-${CHAIN_PORT:-2087}}
	"${APT[@]}" install openssh-client >/dev/null 2>&1 || true
	if [ -n "$EXIT_KEY_TEXT" ] || [ -n "$EXIT_SSH_KEY" ]; then prepare_exit_key || return 1; fi
	if [ -z "$EXIT_SSH_KEY" ] && ! command -v sshpass >/dev/null; then
		"${APT[@]}" install sshpass >/dev/null 2>&1 || { CHAIN_ERR="не установился sshpass (вход по паролю к старому серверу)"; return 1; }
	fi
	# Ключ SSH старого сервера запоминается: при повторной настройке того же сервера подменённый ключ не пройдёт.
	local kh=/etc/x-ui/chain/known_hosts
	if [ "$EXIT_HOST" = "${PREV_CHAIN_IP:-}" ] && [ -s "$kh" ]; then cp "$kh" "$WORK/exit_known_hosts"; else : > "$WORK/exit_known_hosts"; fi
	local sshe uhint
	sshe=$(ssh_exit true 2>&1) && sshe=OK
	# Облака с cloud-init (AWS, Oracle и др.) пускают root по ключу, но вместо входа отвечают
	# «Please login as the user "ubuntu" rather than the user "root"» — войти под ним.
	uhint=$(grep -oE 'Please login as the user "[a-z_][a-z0-9_.-]*"' <<<"$sshe" | head -1 | cut -d'"' -f2)
	if [ "$sshe" != OK ] && [ "$EXIT_SSH_USER" = root ] && [ -n "$uhint" ]; then
		ok "root на старом сервере хостер не пускает и просит входить под $uhint — вхожу под ним (настройка через sudo)"
		EXIT_SSH_USER=$uhint
		sshe=$(ssh_exit true 2>&1) && sshe=OK
	fi
	if [ "$sshe" != OK ] && grep -qE 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed' <<<"$sshe"; then
		CHAIN_ERR="SSH-ключ старого сервера $EXIT_HOST не тот, что при прошлой настройке (сервер переустановлен — или подмена по дороге). Если переустанавливали сами: rm $kh и запустите снова"
		return 1
	fi
	if [ "$sshe" != OK ]; then
		sshe=$(grep -v -e '^Warning: Permanently added' -e '^$' <<<"$sshe" | tail -1 | tr -d '\000-\037\177' | cut -c1-200)
		if [ -n "$EXIT_SSH_KEY" ]; then
			CHAIN_ERR="SSH к старому серверу $EXIT_SSH_USER@$EXIT_HOST:$EXIT_SSH_PORT по ключу не прошёл (${sshe:-нет ответа}) — публичная часть ключа должна быть в ~$EXIT_SSH_USER/.ssh/authorized_keys старого сервера"
		else
			CHAIN_ERR="SSH к старому серверу $EXIT_SSH_USER@$EXIT_HOST:$EXIT_SSH_PORT по паролю не прошёл (${sshe:-нет ответа}) — проверь адрес, порт и пароль; если там вход только по ключу — выбери вход по ключу"
		fi
		[ "$EXIT_SSH_USER" != root ] || CHAIN_ERR="$CHAIN_ERR; если root там запрещён — укажи пользователя (--exit-ssh-user ubuntu)"
		return 1
	fi
	# Не root: всё, что требует root, — через sudo (AWS, Oracle: ubuntu с sudo без пароля). Проверяем до передачи секретов.
	EXIT_SUDO=
	if [ "$EXIT_SSH_USER" != root ]; then
		if ssh_exit 'sudo -n true' >/dev/null 2>&1; then
			EXIT_SUDO=nopass
		else
			local spw=${EXIT_SUDO_PASS:-${EXIT_PASS:-}} serr=""
			if [ -z "$spw" ] && { : > /dev/tty; } 2>/dev/null; then
				tty_flush
				printf 'Пароль sudo для %s на старом сервере: ' "$EXIT_SSH_USER" > /dev/tty
				IFS= read -r spw < /dev/tty || true
			fi
			if [ -n "$spw" ] && serr=$(printf '%s\n' "$spw" | ssh_exit_in "sudo -S -p '' true" 2>&1); then
				EXIT_SUDO=pass
				EXIT_SUDO_PW=$spw
			else
				serr=$(grep -v -e '^Warning: Permanently added' -e '^$' <<<"$serr" | tail -1 | tr -d '\000-\037\177' | cut -c1-200)
				CHAIN_ERR="у $EXIT_SSH_USER на старом сервере нет sudo без пароля, а пароль sudo $([ -n "$spw" ] && echo "не подошёл${serr:+ ($serr)}" || echo "не задан (EXIT_SUDO_PASS)")"
				return 1
			fi
		fi
		ok "на старом сервере вхожу под $EXIT_SSH_USER, настройка — через sudo$([ "$EXIT_SUDO" = pass ] && echo " (с паролем)")"
	fi
	# Ключи цепочки генерируем на новом сервере (у него есть xray); приватный уйдёт в вход старого по SSH.
	if [ -z "$CHAIN_PRIV" ]; then
		local kk
		kk=$("$XRAY" x25519)
		CHAIN_PRIV=$(awk -F': *' '/^Private/ {print $2; exit}' <<<"$kk")
		CHAIN_PUB=$(awk -F': *' '/Public/ {print $2; exit}' <<<"$kk")
		CHAIN_SID=$(openssl rand -hex 8)
		CHAIN_UUID=$("$XRAY" uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')
		[ -n "$CHAIN_PRIV" ] && [ -n "$CHAIN_PUB" ] && [ -n "$CHAIN_UUID" ] || { CHAIN_ERR="не сгенерировались ключи цепочки"; return 1; }
	fi
	# Временная папка в домашней папке пользователя: туда скрипт, параметры и (при той же архитектуре) Xray.
	local rhome stage rarch="" ra=""
	rhome=$(ssh_exit 'printf %s "$HOME"' 2>/dev/null) || rhome=
	[[ $rhome == /* ]] || { CHAIN_ERR="не удалось узнать домашнюю папку $EXIT_SSH_USER на старом сервере"; return 1; }
	stage=$rhome/.vpn-exit-stage
	ssh_exit "rm -rf '$stage' && install -d -m 700 '$stage'" >/dev/null 2>&1 || { CHAIN_ERR="не удалось создать $stage на старом сервере"; return 1; }
	rarch=$(ssh_exit 'uname -m' 2>/dev/null | tr -d '\r\n')
	case $rarch in x86_64 | amd64) ra=amd64 ;; aarch64 | arm64) ra=arm64 ;; esac
	if [ "$ra" = "$ARCH" ] && [ -x "$XRAY" ]; then   # та же архитектура — свой Xray и гео-файлы, без скачивания там
		scp_exit "$XRAY" "$stage/xray" >/dev/null 2>&1 || true
		scp_exit /usr/local/x-ui/bin/geoip.dat "$stage/geoip.dat" >/dev/null 2>&1 || true
		scp_exit /usr/local/x-ui/bin/geosite.dat "$stage/geosite.dat" >/dev/null 2>&1 || true
	fi
	# На старом сервере может работать 3x-ui (прежний VPN). Цепочке он не мешает, но можно выключить.
	if [ -z "$EXIT_STOP_XUI" ]; then
		local rxui
		rxui=$(ssh_exit 'command -v systemctl >/dev/null 2>&1 && systemctl is-active x-ui 2>/dev/null || echo none' 2>/dev/null | tr -d '\r')
		if [ "$rxui" = active ]; then
			if { : > /dev/tty; } 2>/dev/null; then
				tty_flush
				printf 'На старом сервере работает панель 3x-ui. Выключить её (старый теперь только выход)? [y/N]: ' > /dev/tty
				read -r a < /dev/tty || a=
				case $a in y | Y | yes | да | Да) EXIT_STOP_XUI=1 ;; *) EXIT_STOP_XUI=0 ;; esac
			else
				EXIT_STOP_XUI=0
				warn "на старом сервере работает 3x-ui — оставляю (цепочке не мешает). Выключить: переустанови с --exit-stop-xui"
			fi
		fi
	fi
	emit_exit_setup
	# Параметры (и приватный ключ цепочки) — файлом рядом со скриптом: в командной строке sudo их видно в ps.
	(umask 077 && {
		printf 'CHAIN_PRIV=%q\nCHAIN_UUID=%q\nCHAIN_SID=%q\nENTRY_IP=%q\nEXIT_PORT=%q\nEXIT_SNI_HINT=%q\nSTOP_XUI=%q\n' \
			"$CHAIN_PRIV" "$CHAIN_UUID" "$CHAIN_SID" "$PUBLIC_IP" "$CHAIN_PORT" "${REALITY_SNI:-}" "${EXIT_STOP_XUI:-0}"
		printf 'XUI_VER=%q\nXUI_SHA_AMD64=%q\nXUI_SHA_ARM64=%q\n' "$XUI_VERSION" "$XUI_SHA256_AMD64" "$XUI_SHA256_ARM64"
		printf 'BOT_PUBKEY=%q\nBOT_SSH_USER=%q\n' "${BOT_PUBKEY:-}" "$EXIT_SSH_USER"   # пусто — без бота
	} > "$WORK/exit.env")
	if ! { scp_exit "$WORK/exit-setup.sh" "$stage/exit-setup.sh" && scp_exit "$WORK/exit.env" "$stage/exit.env"; } >/dev/null 2>&1; then
		rm -f "$WORK/exit.env"
		ssh_exit "rm -rf '$stage'" >/dev/null 2>&1 || true
		CHAIN_ERR="не удалось передать файлы на старый сервер"
		return 1
	fi
	rm -f "$WORK/exit.env"
	local out run="bash '$stage/exit-setup.sh'"
	case $EXIT_SUDO in
		nopass) out=$(ssh_exit "sudo -n $run" 2>&1) || true ;;
		pass) out=$(printf '%s\n' "$EXIT_SUDO_PW" | ssh_exit_in "sudo -S -p '' $run" 2>&1) || true ;;
		*) out=$(ssh_exit "$run" 2>&1) || true ;;
	esac
	EXIT_SUDO_PW=
	ssh_exit "rm -rf '$stage'" >/dev/null 2>&1 || true   # скрипт удаляет её сам; это — если он не дошёл до старта
	if ! grep -q '^EXIT_RESULT=OK' <<<"$out"; then
		# Текст ошибки пришёл со старого сервера — без управляющих символов и не длиннее строки.
		CHAIN_ERR=$(grep -m1 '^EXIT_RESULT=FAIL' <<<"$out" | sed 's/^EXIT_RESULT=FAIL //' | tr -d '\000-\037\177' | cut -c1-300)
		CHAIN_ERR=${CHAIN_ERR:-"настройка старого сервера не прошла"}
		return 1
	fi
	# Имя сайта ляжет в $STATE, а он читается через «.»: принять только имя хоста.
	CHAIN_SNI=$(sed -n 's/^EXIT_SNI=//p' <<<"$out" | tail -1)
	is_host "$CHAIN_SNI" || { CHAIN_ERR="старый сервер не выбрал сайт для маскировки"; return 1; }
	case $(sed -n 's/^EXIT_UFW=//p' <<<"$out" | tail -1) in
		open) warn "на старом сервере ufw выключен — порт $CHAIN_PORT открыт всем; включи там ufw и оставь доступ только новому серверу" ;;
		iptables) ok "на старом сервере фаервол iptables (как у Oracle): порт $CHAIN_PORT открыт новому серверу, правило сохранено" ;;
		iptables-unsaved) warn "на старом сервере фаервол iptables: порт $CHAIN_PORT открыт новому серверу, но правило не переживёт перезагрузку — поставь там iptables-persistent" ;;
	esac
	case $(sed -n 's/^EXIT_UFW=//p' <<<"$out" | tail -1) in   # как бот будет пускать новый вход при переезде
		restricted) CHAIN_FW=ufw ;;
		iptables | iptables-unsaved) CHAIN_FW=iptables ;;
		open) CHAIN_FW=open ;;
	esac
	if grep -qx 'EXIT_BOTKEY=ok' <<<"$out"; then BOT_EXIT_SETUP=1; fi
	case $(sed -n 's/^EXIT_XUI=//p' <<<"$out" | tail -1) in
		running) ok "на старом сервере 3x-ui продолжает работать — цепочке не мешает (выключить: переустанови с --exit-stop-xui)" ;;
		stopped) [ "${EXIT_STOP_XUI:-0}" = 1 ] && ok "3x-ui на старом сервере выключен (теперь он только выход)" ;;
	esac
	CHAIN_SSH_USER=$EXIT_SSH_USER
	CHAIN_SSH_PORT=$EXIT_SSH_PORT
	{ install -d -m 700 /etc/x-ui/chain && install -m 600 "$WORK/exit_known_hosts" "$kh"; } 2>/dev/null || true
	ok "старый сервер $CHAIN_IP настроен: вход цепочки на :$CHAIN_PORT (маскировка под $CHAIN_SNI)"
	build_chain_outbound "$WORK/chain.json"; save_chain "$WORK/chain.json"
	return 0
}

api_open() {  # одноразовый API-токен панели (x-ui должен работать); api_close его удаляет
	local out
	out=$("$XUI" setting -getApiToken 2>&1 || true)
	API_TOKEN=$(sed -n 's/^apiToken: *//p' <<<"$out" | tail -1)
	[ -n "$API_TOKEN" ] || die "x-ui не выдал API-токен: $out"
	TOKEN_ID=$(sqlite3 "$DB" 'select max(id) from api_tokens;')
}
api_close() { sqlite3 "$DB" "delete from api_tokens where id=${TOKEN_ID:-0};" 2>/dev/null || true; API_TOKEN=; TOKEN_ID=; }
api() {  # api POST|GET ПУТЬ [аргументы curl] → тело ответа
	local m=$1 p=$2
	shift 2
	curl -sk --max-time 60 -X "$m" -H "Authorization: Bearer $API_TOKEN" "$@" "$SCHEME://127.0.0.1:$WEB_PORT${WEB_PATH}panel/api/$p"
}
api_ok() { python3 -c 'import json, sys; d = json.load(sys.stdin); sys.exit(0 if d.get("success") else 1)' 2>/dev/null; }

warp_register() {  # warp_register ФАЙЛ ← новый outbound warp (регистрация как у кнопки WARP в панели); ошибка — в WARP_ERR
	local der=$WORK/wg.der priv pub
	WARP_ERR=
	openssl genpkey -algorithm X25519 -outform DER -out "$der" 2>/dev/null || { WARP_ERR="openssl не создал ключ"; return 1; }
	priv=$(tail -c 32 "$der" | base64)   # ключи WireGuard — в обычном base64
	pub=$(openssl pkey -inform DER -in "$der" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)
	rm -f "$der"
	api POST xray/warp/reg --data-urlencode "privateKey=$priv" --data-urlencode "publicKey=$pub" > "$WORK/warp-reg.json" || true
	if python3 - "$1" "$priv" "$WARP_ENDPOINT" "$WORK/warp-reg.json" <<'PY'; then
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
		rm -f "$WORK/warp-reg.json"
		save_warp "$1"
		return 0
	fi
	WARP_ERR=$(head -c 300 "$WORK/warp-reg.json" 2>/dev/null)
	rm -f "$WORK/warp-reg.json"
	return 1
}

apply_exit() {  # apply_exit РЕЖИМ ФАЙЛ_WARP|- — записать шаблон Xray и перезапустить x-ui
	systemctl stop x-ui 2>/dev/null || true
	xui_set "xrayTemplateConfig=$(template_json "$1" "$2")"
	systemctl restart x-ui || return 1
	wait_port ":$WEB_PORT" 40
}

IPCERT_DIR=/etc/x-ui/ip-cert   # без домена: сертификат Let's Encrypt на IP (подписка и панель)
# 3x-ui перечитывает сертификаты панели и подписки по HUP (перезапускает их, Xray — нет). НЕ systemctl reload x-ui:
# там USR1 — перезапуск Xray (обрыв VPN у клиентов), а сертификат панели остаётся старым. PID 0 (x-ui не запущен)
# не трогаем: kill -HUP 0 разослал бы сигнал всей группе процессов, и acme.sh тоже.
XUI_RELOAD_CERT='p=$(systemctl show -p MainPID --value x-ui); [ "${p:-0}" -gt 0 ] && kill -HUP "$p"; true'

ensure_acme() {  # acme.sh закреплённой версии (sha256) в /root/.acme.sh
	ACME=/root/.acme.sh/acme.sh
	if [ -x "$ACME" ]; then
		# Автообновление (его включала прежняя версия скрипта) тянуло бы незакреплённый код с GitHub мимо sha256.
		sed -i '/^AUTO_UPGRADE=/d' /root/.acme.sh/account.conf 2>/dev/null || true
		return 0
	fi
	local tmp
	tmp=$(mktemp -d)
	if curl -fsSL --retry 3 -o "$tmp/acme.sh" "https://raw.githubusercontent.com/acmesh-official/acme.sh/$ACME_TAG/acme.sh" &&
		echo "$ACME_SHA256  $tmp/acme.sh" | sha256sum -c --quiet - >/dev/null 2>&1 &&
		(cd "$tmp" && sh ./acme.sh --install --home /root/.acme.sh --nocron --noprofile >/dev/null 2>&1); then
		rm -rf "$tmp"
		return 0
	fi
	rm -rf "$tmp"
	return 1
}

acme_cron() {  # строка cron acme.sh: acme_cron 1 — раз в сутки, acme_cron 2 — дважды (короткие сертификаты на IP)
	local m=$((RANDOM % 60)) h=$((RANDOM % 12)) when
	if [ "${1:-1}" = 2 ]; then when="$m $h,$((h + 12))"; else when="$m $((RANDOM % 24))"; fi
	{ crontab -l 2>/dev/null || true; } | { grep -vF 'acme.sh --cron' || true; } > /root/.crontab.new
	echo "$when * * * \"/root/.acme.sh\"/acme.sh --cron --home \"/root/.acme.sh\" > /dev/null" >> /root/.crontab.new
	crontab /root/.crontab.new
	rm -f /root/.crontab.new
}

issue_ip_cert() {  # сертификат Let's Encrypt на PUBLIC_IP в $IPCERT_DIR; ошибка → IPCERT_ERR
	IPCERT_ERR=
	local rc=0 ca=letsencrypt log=$WORK/acme-ip.log opened80=0 have
	[ "$ACME_STAGING" = 1 ] && ca=letsencrypt_test
	"${APT[@]}" install socat >/dev/null 2>&1 || { IPCERT_ERR="не установился socat (им acme.sh отвечает Let's Encrypt на :80)"; return 1; }
	ensure_acme || { IPCERT_ERR="не скачался или не установился acme.sh $ACME_TAG"; return 1; }
	"$ACME" --register-account --server "$ca" >/dev/null 2>&1 || true
	# Сервер сменил IP — сертификат прежнего адреса снять, иначе acme.sh так и будет пытаться его продлевать.
	if [ -n "$IP_CERT_IP" ] && [ "$IP_CERT_IP" != "$PUBLIC_IP" ]; then
		"$ACME" --remove -d "$IP_CERT_IP" --ecc >/dev/null 2>&1 || true
		rm -rf "/root/.acme.sh/${IP_CERT_IP}_ecc"
	fi
	# Сертификат тестового центра, а нужен настоящий (или наоборот) — выпустить заново.
	have=/root/.acme.sh/${PUBLIC_IP}_ecc/$PUBLIC_IP.cer
	if [ -s "$have" ]; then
		if openssl x509 -noout -issuer -in "$have" 2>/dev/null | grep -qi staging; then
			[ "$ACME_STAGING" = 1 ] || rm -rf "/root/.acme.sh/${PUBLIC_IP}_ecc"
		else
			[ "$ACME_STAGING" != 1 ] || rm -rf "/root/.acme.sh/${PUBLIC_IP}_ecc"
		fi
	fi
	[ -z "$(port_users 80)" ] || { IPCERT_ERR="порт 80 занят ($(port_users 80)) — Let's Encrypt не сможет проверить сервер"; return 1; }
	if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active' && ! ufw status | grep -qE '^80/tcp +ALLOW'; then
		ufw allow 80/tcp >/dev/null 2>&1 && opened80=1
	fi
	# Let's Encrypt проверяет сервер по http://IP/ — на время проверки acme.sh сам слушает :80 (socat).
	# Сертификат на IP бывает только коротким (профиль shortlived, ~160 ч): продление через 2–3 дня.
	"$ACME" --issue -d "$PUBLIC_IP" --standalone --httpport 80 --server "$ca" --cert-profile shortlived --days 3 \
		--keylength ec-256 > "$log" 2>&1 || rc=$?
	case $rc in
		0) ok "Let's Encrypt выдал сертификат на IP $PUBLIC_IP$([ "$ACME_STAGING" = 1 ] && echo " (тестовый центр — браузеры и приложения ему не верят)")" ;;
		2) ok "сертификат на IP $PUBLIC_IP уже есть, продлевать рано" ;;
		*)
			IPCERT_ERR=$(grep -vE '^\s*$' "$log" | tail -3 | sed -E 's/^\[[^]]*\] //' | tr '\n' ' ' | cut -c1-320)
			[ "$opened80" = 0 ] || ufw delete allow 80/tcp >/dev/null 2>&1 || true
			return 1
			;;
	esac
	install -d -m 700 "$IPCERT_DIR"
	# После продления 3x-ui перечитывает сертификат по HUP: перезапускаются панель и подписка, Xray — нет.
	if ! "$ACME" --install-cert -d "$PUBLIC_IP" --ecc --key-file "$IPCERT_DIR/privkey.pem" --fullchain-file "$IPCERT_DIR/fullchain.pem" \
		--reloadcmd "$XUI_RELOAD_CERT" >/dev/null 2>&1; then
		IPCERT_ERR="acme.sh --install-cert не прошёл"
		return 1
	fi
	chmod 600 "$IPCERT_DIR/privkey.pem"
	acme_cron 2
	IP_CERT_IP=$PUBLIC_IP
	if [ "$ACME_STAGING" = 1 ]; then IPK=-k; else IPK=; fi
	return 0
}

drop_ip_cert() {  # --no-ip-cert после сертификата на IP: снять его и его продление
	local ip=${IP_CERT_IP:-$PUBLIC_IP}
	if [ -x /root/.acme.sh/acme.sh ]; then /root/.acme.sh/acme.sh --remove -d "$ip" --ecc >/dev/null 2>&1 || true; fi
	rm -rf "/root/.acme.sh/${ip}_ecc" "$IPCERT_DIR"
	IP_CERT_IP=
	ok "сертификат на IP снят (--no-ip-cert): подписка только внутри сервера, панель — с самоподписанным"
}

ip_cert_valid() {  # прежний сертификат на IP ещё годен (больше суток) и выписан на нынешний IP
	[ -s "$IPCERT_DIR/fullchain.pem" ] && [ -s "$IPCERT_DIR/privkey.pem" ] &&
		openssl x509 -checkend 86400 -noout -in "$IPCERT_DIR/fullchain.pem" >/dev/null 2>&1 &&
		openssl x509 -noout -ext subjectAltName -in "$IPCERT_DIR/fullchain.pem" 2>/dev/null | grep -qE "IP Address:${PUBLIC_IP//./\\.}(,|\$)"
}

PANEL_CERT_DIR=/etc/x-ui/panel-cert   # без домена: самоподписанный сертификат панели на IP сервера

xui_get() { sqlite3 -readonly "$DB" "select value from settings where key='$1';" 2>/dev/null || true; }

make_panel_cert() {  # самоподписанный сертификат панели на IP — выпустить, если его нет или в нём не нынешний IP
	local san="IP:$PUBLIC_IP"
	[ "$LISTEN_IP" = "$PUBLIC_IP" ] || san="$san,IP:$LISTEN_IP"
	if [ -s "$PANEL_CERT_DIR/fullchain.pem" ] &&
		openssl x509 -noout -ext subjectAltName -in "$PANEL_CERT_DIR/fullchain.pem" 2>/dev/null | grep -qE "IP Address:${PUBLIC_IP//./\\.}(,|\$)"; then
		return 0
	fi
	install -d -m 700 "$PANEL_CERT_DIR"
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=$PUBLIC_IP" \
		-addext "subjectAltName=$san" -keyout "$PANEL_CERT_DIR/privkey.pem" -out "$PANEL_CERT_DIR/fullchain.pem" >/dev/null 2>&1 ||
		die "не создался сертификат панели"
	chmod 600 "$PANEL_CERT_DIR/privkey.pem"
}

panel_fingerprint() { openssl x509 -noout -fingerprint -sha256 -in "$PANEL_CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2; }

derive_vars() {  # для --check и --warp: то, что установка вычисляет по ходу (после detect_ips)
	CERT_DIR=${DOMAIN:+/root/cert/$DOMAIN}
	K=
	if [ -n "$DOMAIN" ] && ! openssl x509 -noout -issuer -in "$CERT_DIR/fullchain.pem" 2>/dev/null | grep -qi "let's encrypt"; then K=-k; fi
	if [ "$MODE" = domain ]; then SHARE_ADDR=$DOMAIN; else SHARE_ADDR=$PUBLIC_IP; fi
	if [ -n "$(xui_get webCertFile)" ]; then SCHEME=https; else SCHEME=http; fi
	PANEL_PUBLIC=0
	if [ "$MODE" = nodomain ] && [ "$(xui_get webListen)" != 127.0.0.1 ]; then PANEL_PUBLIC=1; fi
	SUB_TLS=0
	IP_CERT_OK=0
	IPK=
	if [ "$MODE" = nodomain ] && [ -n "$(xui_get subCertFile)" ]; then SUB_TLS=1; fi
	if [ "$SUB_TLS" = 1 ] || [ "$(xui_get webCertFile)" = "$IPCERT_DIR/fullchain.pem" ]; then IP_CERT_OK=1; fi
	if openssl x509 -noout -issuer -in "$IPCERT_DIR/fullchain.pem" 2>/dev/null | grep -qi staging; then IPK=-k; fi
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
# Остановка посреди установки (die, ошибка, Ctrl-C) не оставляет VPN выключенным: что работало до запуска —
# запускается снова; одноразовый API-токен панели удаляется.
XUI_WAS_ACTIVE=0; systemctl is-active -q x-ui 2>/dev/null && XUI_WAS_ACTIVE=1
WD_WAS_ACTIVE=0; systemctl is-active -q vpn-exit-watchdog 2>/dev/null && WD_WAS_ACTIVE=1
XUI_TOUCHED=0
on_exit() {
	local rc=$?
	[ -z "${TOKEN_ID:-}" ] || sqlite3 "$DB" "delete from api_tokens where id=$TOKEN_ID;" 2>/dev/null || true
	if [ "$rc" != 0 ] && [ "$XUI_TOUCHED" = 1 ] && [ "${INSTALL_DONE:-0}" != 1 ]; then
		if [ "$XUI_WAS_ACTIVE" = 1 ]; then
			systemctl stop x-ui >/dev/null 2>&1 || true
			if [ -s "$WORK/db.before" ] && cp -f "$WORK/db.before" "$DB"; then
				rm -f "$DB-wal" "$DB-shm"
				printf '  база 3x-ui возвращена такой, как была до запуска\n' >&2
			fi
			{ systemctl start x-ui >/dev/null 2>&1 && printf '  x-ui запущен снова — VPN работает, как до запуска скрипта\n' >&2; } || true
		fi
		if [ "$WD_WAS_ACTIVE" = 1 ]; then systemctl start vpn-exit-watchdog >/dev/null 2>&1 || true; fi
	fi
	rm -rf "$WORK" "$CHK_OUT"
	[ -z "${BOT_DIR:-}" ] || rm -rf "$BOT_DIR"   # каталог токенов с вопросов (вне $WORK)
}
trap on_exit EXIT

# --- Только проверка ---
if [ "$CHECK_ONLY" = 1 ]; then
	# shellcheck source=/dev/null
	. "$STATE"
	detect_ips
	derive_vars
	printf '\033[1mПроверка VPN на %s (%s)\033[0m\n' "${DOMAIN:-$PUBLIC_IP}" "$([ "$MODE" = domain ] && echo "с доменом" || echo "без домена, Reality под ${REALITY_SNI:-?}")"
	local_checks
	reach_check
	verdict
	exit $((FAILS > 0))
fi

# --- Только переключить выход: vpn-warp off | on | ru | status ---
if [ -n "$WARP_CMD" ]; then
	# shellcheck source=/dev/null
	. "$STATE"
	NOW=$(exit_mode_now)
	if [ "$NOW" = chain ]; then
		echo "Выход цепочкой через ${CHAIN_IP:-?}, сейчас активно: $(active_label "$(chain_active)"). В запасной режим (российские сайты через WARP, остальное напрямую) и обратно переключает вотчдог (journalctl -t vpn-watchdog)."
		[ "$TARGET_EXIT" != status ] || exit 0
		echo "Чтобы сменить выход насовсем — переустанови: bash install-vpn.sh --exit direct (или warp)."
		exit 1
	fi
	if [ "$TARGET_EXIT" = status ]; then
		echo "Выход клиентов сейчас: $(exit_label "$NOW")"
		if [ "$NOW" = direct ]; then echo "Включить WARP: vpn-warp on — весь трафик, vpn-warp ru — только российские сайты"; else echo "Выключить WARP: vpn-warp off"; fi
		exit 0
	fi
	detect_ips
	derive_vars
	if [ "$NOW" = "$TARGET_EXIT" ]; then
		ok "выход уже такой: $(exit_label "$NOW")"
		EXIT_MODE=$NOW
		save_state
		exit 0
	fi
	say "Выход клиентов: $(exit_label "$NOW") → $(exit_label "$TARGET_EXIT")"
	systemctl is-active -q x-ui || die "x-ui не работает — сначала vpn-check"
	sqlite3 -readonly "$DB" "select value from settings where key='xrayTemplateConfig';" > "$WORK/template.before"
	if current_warp "$WORK/warp.json"; then save_warp "$WORK/warp.json"; HAVE_WARP=1; else HAVE_WARP=0; fi
	WARP_FILE=-
	if [ "$TARGET_EXIT" != direct ]; then
		if [ "$HAVE_WARP" = 1 ]; then
			ok "WARP: прежняя регистрация (новое устройство у Cloudflare не нужно)"
		else
			api_open
			if ! warp_register "$WORK/warp.json"; then api_close; die "WARP не зарегистрировался, выход не менял: $WARP_ERR"; fi
			api_close
			ok "Cloudflare WARP зарегистрирован (бесплатный аккаунт)"
		fi
		WARP_FILE=$WORK/warp.json
	else
		ok "WARP выключается целиком: сервер больше не держит туннель к Cloudflare (регистрация сохранена для vpn-warp on)"
	fi
	apply_exit "$TARGET_EXIT" "$WARP_FILE" || warn "x-ui долго поднимается после смены выхода"
	# Настоящий туннель по ссылке первого клиента: на проверочном адресе (не российском) WARP должен
	# включиться только в режиме on.
	sid=$(sqlite3 -readonly "$DB" "select sub_id from clients where enable=1 and sub_id<>'' order by id limit 1;")
	link=$(sub_fetch "$sid" | grep -m1 '^vless://' || true)
	read -r code exit_ip exit_warp log <<<"$(tunnel_check "$link")"
	want_warp=off
	[ "$TARGET_EXIT" = warp ] && want_warp=on
	got_warp=off
	{ [ "$exit_warp" = on ] || [ "$exit_warp" = plus ]; } && got_warp=on
	if [ "$code" = 204 ] && [ "$got_warp" = "$want_warp" ]; then
		EXIT_MODE=$TARGET_EXIT
		save_state
		[ ! -f "$INFO" ] || sed -i "s|^Выход клиентов сейчас: .*|Выход клиентов сейчас: $(exit_label "$TARGET_EXIT"). Переключить без переустановки:|" "$INFO"
		ok "готово: $(exit_label "$TARGET_EXIT") — туннель работает, выход с IP $exit_ip$([ "$got_warp" = on ] && echo " (Cloudflare WARP)")"
		[ "$TARGET_EXIT" = warp-ru ] && ok "российские сайты пойдут через WARP — это видно только на них, проверочный адрес нероссийский"
		exit 0
	fi
	bad "после переключения туннель не работает как надо (ответ $code, выход ${exit_ip:--}, warp=${exit_warp:--}): $log"
	systemctl stop x-ui 2>/dev/null || true
	xui_set "xrayTemplateConfig=$(cat "$WORK/template.before")"
	systemctl restart x-ui || true
	wait_port ":$WEB_PORT" 40 || true
	die "вернул как было: $(exit_label "$NOW")$([ "$TARGET_EXIT" != direct ] && echo ". WARP с этого сервера сейчас не работает — попробуйте позже")"
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

dns_step

if [ "$BOT_DO" = 1 ]; then
	say "Телеграм-бот: проверка токенов"
	bot_init_secrets
	BOT_TRY=1
	until bot_validate; do
		warn "бот: $BOT_ERR"
		if [ "$BOT_TRY" -ge 3 ] || ! bot_retry; then BOT_DO=0; BOT_SKIP=$BOT_ERR; break; fi
		BOT_TRY=$((BOT_TRY + 1))
	done
	if [ "$BOT_DO" = 1 ]; then
		ok "бот${BOT_USERNAME:+ @$BOT_USERNAME}: домен $DOMAIN в Cloudflare${BOT_ADMIN_NAME:+, владелец — $BOT_ADMIN_NAME}"
		bot_keys "$([ "$EXIT_MODE" = chain ] && [ -n "$EXIT_HOST" ] && echo 1 || echo 0)"
		if [ "$BOT_KEY_NEW" = 1 ]; then BOT_PUBKEY=$(cat "$BOT_DIR/id.pub"); fi
	else
		warn "ставлю без бота (VPN работает и без него). Повторить: bash $0 --bot — токены скрипт спросит сам"
		bot_wipe
	fi
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
elif [ "$FOREIGN_XUI" = 1 ]; then   # чужой 3x-ui (согласие — в самом начале, foreign_xui_check): копия базы до первых изменений
	cp -a "$DB" "$DB.before-install-$(date +%Y%m%d-%H%M%S)"
	ok "копия прежней базы 3x-ui — рядом с ней: $DB.before-install-…"
fi
: "${PANEL_USER:=$(rnd "$LOWER$DIGITS" 10)}"
: "${PANEL_PASS:=$(rnd "$LOWER${LOWER^^}$DIGITS" 22)}"
: "${WEB_PORT:=$(free_port)}"
: "${WEB_PATH:=/$(rnd "$LOWER${LOWER^^}$DIGITS" 18)/}"
: "${SUB_PATH:=/$(rnd "$LOWER" 8)/}"
: "${CLASH_PATH:=/$(rnd "$LOWER" 7)/}"
: "${JSON_PATH:=/$(rnd "$LOWER" 6)/}"
# Панель без домена: по умолчанию открыта по IP (https://IP:порт/путь/, сертификат самоподписанный);
# --panel-local — только 127.0.0.1 и SSH-туннель. С доменом панель всегда за nginx по домену.
if [ "$MODE" = domain ]; then
	PANEL_PUBLIC=0
elif [ -n "$PANEL_LOCAL_ARG" ]; then
	PANEL_PUBLIC=$((1 - PANEL_LOCAL_ARG))
else
	PANEL_PUBLIC=${S_PANEL_PUBLIC:-}
	if [ -z "$PANEL_PUBLIC" ]; then   # прежняя версия скрипта выбор не записывала — как сейчас в базе; чистый сервер — открыта
		if [ -f "$STATE" ] && [ -f "$DB" ] && [ "$(xui_get webListen)" = 127.0.0.1 ]; then PANEL_PUBLIC=0; else PANEL_PUBLIC=1; fi
	fi
fi
# Без домена: сертификат Let's Encrypt на IP (короткий, ~6 дней, продлевается сам) — подписка по https://IP:2096/…
# и панель без предупреждения браузера. --no-ip-cert — как раньше: подписка только внутри, панель с самоподписанным.
if [ "$MODE" = domain ]; then
	IP_CERT=0
elif [ -n "$IP_CERT_ARG" ]; then
	IP_CERT=$IP_CERT_ARG
else
	IP_CERT=${S_IP_CERT:-1}
fi
IP_CERT_IP=${S_IP_CERT_IP:-}
[ -n "$WEB_PORT" ] || die "не нашёлся свободный порт для панели"
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
	xui_stop
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
XV=$("$XRAY" version 2>/dev/null || true)
case $XV in "Xray $XRAY_VERSION "*) ;; *) warn "Xray не $XRAY_VERSION: ${XV%%$'\n'*}" ;; esac

# Пароль, порт и секретный путь панели — до первого запуска x-ui, чтобы она ни минуты не жила с admin/admin.
xui_stop
mkdir -p /etc/x-ui
"$XUI" setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$WEB_PORT" -webBasePath "$WEB_PATH" -listenIP 127.0.0.1 >/dev/null ||
	die "x-ui setting не прошёл"
if [ "$MODE" = domain ]; then
	ok "панель: только 127.0.0.1:$WEB_PORT, снаружи — через nginx по секретному пути"
else
	ok "панель: случайные логин, пароль, порт $WEB_PORT и секретный путь (где она слушает — ниже)"
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
		ensure_acme || die "не скачался, не совпал по sha256 или не установился acme.sh $ACME_TAG"
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
			--reloadcmd "systemctl reload nginx ; $XUI_RELOAD_CERT" >/dev/null 2>&1 || die "acme.sh --install-cert не прошёл"
		acme_cron 1
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

if [ "$MODE" = nodomain ]; then
	if [ "$IP_CERT" = 1 ]; then
		say "Сертификат Let's Encrypt на IP $PUBLIC_IP: подписка и панель по https"
		if issue_ip_cert; then
			IP_CERT_OK=1
			ok "сертификат на IP действует до $(openssl x509 -enddate -noout -in "$IPCERT_DIR/fullchain.pem" | cut -d= -f2), продлевается сам (проверка дважды в сутки)"
		elif ip_cert_valid; then
			# Let's Encrypt сейчас не выдал (лимит, :80 закрыт на время), а прежний ещё годен — оставить его, а не
			# отключать подписку у всех клиентов; продлить cron попробует сам.
			IP_CERT_OK=1
			IP_CERT_IP=$PUBLIC_IP
			if openssl x509 -noout -issuer -in "$IPCERT_DIR/fullchain.pem" 2>/dev/null | grep -qi staging; then IPK=-k; fi
			warn "Let's Encrypt сейчас не выдал сертификат на IP (${IPCERT_ERR:-?}), но прежний действует до $(openssl x509 -enddate -noout -in "$IPCERT_DIR/fullchain.pem" | cut -d= -f2) — оставляю его, продлить cron попробует сам"
		else
			warn "сертификат на IP не получен — подписка останется внутри сервера, в QR будут прямые ссылки. Ответ: ${IPCERT_ERR:-?}"
			warn "чаще всего порт 80 закрыт фаерволом хостера: откройте TCP 80 в панели хостера и запустите скрипт ещё раз"
		fi
	elif [ -d "$IPCERT_DIR" ] || [ -n "$IP_CERT_IP" ]; then
		drop_ip_cert
	fi
fi

say "3x-ui: подписка, шаблон Xray, подключение VLESS + XHTTP + Reality"
xui_stop
# Повторный запуск с другим --port: перенести уже созданное подключение (ключи и клиенты те же).
MOVED_FROM=
if [ -n "$OLD_REALITY_PORT" ] && [ "$OLD_REALITY_PORT" != "$REALITY_PORT" ]; then
	[ -z "$(sqlite3 "$DB" "select id from inbounds where port=$REALITY_PORT limit 1;")" ] ||
		die "на порту $REALITY_PORT в панели уже есть другое подключение — выберите другой --port"
	# Имя подключения 3x-ui содержит порт (in-2083-tcp, в старых версиях inbound-2083) — заменить в нём номер.
	python3 - "$DB" "$OLD_REALITY_PORT" "$REALITY_PORT" <<'PY' || die "не удалось перенести подключение на порт $REALITY_PORT"
import re, sqlite3, sys
path, old, new = sys.argv[1:4]
db = sqlite3.connect(path)
for iid, tag in db.execute("select id, tag from inbounds where port=?", (int(old),)).fetchall():
    newtag = re.sub(r"(?<![0-9])%s(?![0-9])" % re.escape(old), new, tag or "") or "in-%s-tcp" % new
    db.execute("update inbounds set port=?, listen='0.0.0.0', tag=? where id=?", (int(new), newtag, iid))
db.commit()
PY
	MOVED_FROM=$OLD_REALITY_PORT
	ok "подключение перенесено с :$OLD_REALITY_PORT на :$REALITY_PORT (ключи и клиенты те же)"
	if [ "$MODE" = domain ]; then
		warn "у кого подписка — обновится сама; у кого ссылка без подписки — выдать новую (порт в ней сменился)"
	else
		warn "порт в ссылках клиентов сменился — старые ссылки перестанут работать, новые будут в конце"
	fi
fi
COMMON_SETTINGS=("subEnable=true" "subListen=127.0.0.1" "subPort=$SUB_PORT" "subPath=$SUB_PATH" "subDomain="
	"subUpdates=1" "subEncrypt=true" "subShowInfo=true" "subEmailInRemark=true" "subEnableRouting=true"
	"subJsonEnable=false" "subJsonPath=$JSON_PATH" "subClashPath=$CLASH_PATH"
	"remarkModel=-ieo" "timeLocation=Local" "trustedProxyCIDRs=127.0.0.1/32,::1/128" "webDomain=")
if [ "$MODE" = domain ]; then
	xui_set "${COMMON_SETTINGS[@]}" "webListen=127.0.0.1" "webCertFile=$CERT_DIR/fullchain.pem" "webKeyFile=$CERT_DIR/privkey.pem" \
		"subCertFile=$CERT_DIR/fullchain.pem" "subKeyFile=$CERT_DIR/privkey.pem" "subURI=https://$DOMAIN$SUB_PATH" \
		"subClashEnable=true" "subClashURI=https://$DOMAIN$CLASH_PATH" "subJsonURI=https://$DOMAIN$JSON_PATH"
	SCHEME=https
	SHARE_ADDR=$DOMAIN
else
	# Без домена подписка: с сертификатом Let's Encrypt на IP — открыта по https://IP:2096/…; без него — только на
	# 127.0.0.1 без TLS (скрипт читает её сам, чтобы выдать прямые ссылки). Панель — по IP (сертификат на IP или
	# самоподписанный) либо только на 127.0.0.1 (--panel-local).
	if [ "$IP_CERT_OK" = 1 ]; then
		xui_set "${COMMON_SETTINGS[@]}" "subListen=" "subCertFile=$IPCERT_DIR/fullchain.pem" "subKeyFile=$IPCERT_DIR/privkey.pem" \
			"subURI=https://$PUBLIC_IP:$SUB_PORT$SUB_PATH" "subClashEnable=false" "subClashURI=" "subJsonURI="
		SUB_TLS=1
		ok "подписка открыта по https://$PUBLIC_IP:$SUB_PORT/… (секретный путь, сертификат Let's Encrypt)"
	else
		xui_set "${COMMON_SETTINGS[@]}" "subCertFile=" "subKeyFile=" "subURI=" "subClashEnable=false" "subClashURI=" "subJsonURI="
		SUB_TLS=0
	fi
	if [ "$PANEL_PUBLIC" = 1 ]; then
		make_panel_cert   # самоподписанный держим всегда: запасной, если сертификата на IP не станет (восстановление из бэкапа)
		if [ "$IP_CERT_OK" = 1 ]; then
			xui_set "webListen=" "webCertFile=$IPCERT_DIR/fullchain.pem" "webKeyFile=$IPCERT_DIR/privkey.pem"
			ok "панель открыта по IP: https://$PUBLIC_IP:$WEB_PORT/… (секретный путь, сертификат Let's Encrypt)"
		else
			xui_set "webListen=" "webCertFile=$PANEL_CERT_DIR/fullchain.pem" "webKeyFile=$PANEL_CERT_DIR/privkey.pem"
			ok "панель открыта по IP: https://$PUBLIC_IP:$WEB_PORT/… (секретный путь, сертификат самоподписанный)"
		fi
		SCHEME=https
	else
		xui_set "webListen=127.0.0.1" "webCertFile=" "webKeyFile="
		SCHEME=http
		ok "панель только на 127.0.0.1 (--panel-local), снаружи — через SSH-туннель"
	fi
	SHARE_ADDR=$PUBLIC_IP
	# Повторный запуск после смены IP сервера: ссылки должны вести на нынешний адрес.
	sqlite3 "$DB" "update inbounds set share_addr='$PUBLIC_IP' where port=$REALITY_PORT and share_addr_strategy='custom' and share_addr<>'$PUBLIC_IP';" 2>/dev/null || true
fi
# Выход клиентов. Копия outbound warp сохраняется всегда — чтобы vpn-warp on не регистрировал WARP заново.
HAVE_WARP=0
if current_warp "$WORK/warp.json"; then save_warp "$WORK/warp.json"; [ "$EXIT_MODE" = direct ] || HAVE_WARP=1; fi
EXIT_WAS=$(exit_mode_now 2>/dev/null || echo direct)   # выход до этого запуска (свежая база — direct)
if [ "$EXIT_MODE" = chain ] && [ "$EXIT_WAS" = chain ]; then
	:   # цепочка уже работает: шаблон перепишет блок цепочки ниже, а до того клиенты ходят как ходили
elif [ "$HAVE_WARP" = 1 ] && [ "$EXIT_MODE" != chain ]; then
	xui_set "xrayTemplateConfig=$(template_json "$EXIT_MODE" "$WORK/warp.json")"
else
	xui_set "xrayTemplateConfig=$(template_json direct -)"
fi
systemctl enable x-ui >/dev/null 2>&1 || true
systemctl restart x-ui || die "x-ui не запустился (journalctl -u x-ui)"
wait_port ":$WEB_PORT" 40 || die "панель x-ui не поднялась на порту $WEB_PORT (journalctl -u x-ui)"

# API панели — по одноразовому токену, после настройки токен удаляется.
api_open
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
           "listen": "0.0.0.0", "port": int(port), "protocol": "vless",
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
	if warp_register "$WORK/warp.json"; then
		HAVE_WARP=1
		ok "Cloudflare WARP зарегистрирован (бесплатный аккаунт)"
		if [ "$EXIT_MODE" != chain ]; then   # цепочку применим ниже, когда соберём outbound
			xui_stop
			xui_set "xrayTemplateConfig=$(template_json "$EXIT_MODE" "$WORK/warp.json")"
		fi
	else
		bad "WARP не зарегистрировался — выход остаётся напрямую с IP сервера. Ответ: $WARP_ERR"
		EXIT_MODE=direct
		xui_stop
		xui_set "xrayTemplateConfig=$(template_json direct -)"
	fi
fi
api_close
if [ "$EXIT_MODE" = chain ]; then
	say "Выход цепочкой через другой сервер"
	if [ "$HAVE_WARP" != 1 ]; then
		bad "без WARP у цепочки нет запасного режима — оставляю прямой выход"
		EXIT_MODE=direct
		xui_stop
		xui_set "xrayTemplateConfig=$(template_json direct -)"
	elif setup_chain_exit; then
		chain_apply
	elif [ "$EXIT_WAS" = chain ] && [ -n "$CHAIN_IP" ] && [ -s "$CHAIN_SAVED" ]; then
		# Не вышло перенастроить или сменить сервер-выход, а прежняя цепочка работала — её и оставляем.
		bad "старый сервер настроить не удалось: ${CHAIN_ERR:-?}"
		warn "оставляю прежнюю цепочку через $CHAIN_IP:$CHAIN_PORT — она работала до запуска"
		chain_apply
	else
		case $EXIT_WAS in warp | warp-ru) EXIT_MODE=$EXIT_WAS ;; *) EXIT_MODE=direct ;; esac
		bad "цепочку настроить не удалось — выход клиентов: $(exit_label "$EXIT_MODE"). Причина: ${CHAIN_ERR:-?}"
		warn "проверь адрес, порт, пользователя и пароль/ключ старого сервера и повтори: bash install-vpn.sh --exit chain --exit-host ${EXIT_HOST:-IP}$([ "$EXIT_SSH_USER" = root ] || echo " --exit-ssh-user $EXIT_SSH_USER")"
		xui_stop
		if [ "$EXIT_MODE" = direct ]; then
			xui_set "xrayTemplateConfig=$(template_json direct -)"
		else
			xui_set "xrayTemplateConfig=$(template_json "$EXIT_MODE" "$WORK/warp.json")"
		fi
	fi
fi
if [ "$EXIT_MODE" != chain ] && grep -qs 'EXIT_IP=' /etc/systemd/system/vpn-exit-watchdog.service; then
	systemctl disable --now vpn-exit-watchdog >/dev/null 2>&1 || true
	rm -f /etc/systemd/system/vpn-exit-watchdog.service /usr/local/bin/vpn-exit-watchdog.sh
	systemctl daemon-reload 2>/dev/null || true
	ok "вотчдог цепочки снят — выход больше не через другой сервер"
fi
save_state
systemctl restart x-ui || bad "x-ui не перезапустился (journalctl -u x-ui)"
# Вотчдог — только на окончательном шаблоне: раньше он мог переключить выход и перезапустить x-ui посреди установки.
[ "$EXIT_MODE" != chain ] || install_watchdog
case $EXIT_MODE in
	direct) ok "выход клиентов в интернет — напрямую с IP сервера $PUBLIC_IP (включить WARP потом: vpn-warp on или vpn-warp ru)" ;;
	warp) ok "выход клиентов — через Cloudflare WARP (IP сервера сайтам не виден; выключить: vpn-warp off)" ;;
	warp-ru) ok "выход: российские сайты — через WARP, остальное — напрямую с $PUBLIC_IP (выключить: vpn-warp off)" ;;
	chain)
		if [ "${CHAIN_BLOCKED:-0}" = 1 ]; then
			warn "выход клиентов — цепочкой через $CHAIN_IP, но пока порт $CHAIN_PORT закрыт фаерволом хостера — запасной режим (российские сайты через WARP, остальное напрямую), вотчдог переключит сам"
		else
			ok "выход клиентов — цепочкой через $CHAIN_IP (упадёт — российские сайты через WARP, остальное напрямую; управляет вотчдог vpn-exit-watchdog)"
		fi ;;
esac

OTHER_VPN=; OTHER_VPN_PORTS=
detect_other_vpn() {  # уже работающий на этом сервере WireGuard/AmneziaWG/Amnezia(Docker): описание и порты
	local found="" ports="" ifc pt name pp pr
	if command -v wg >/dev/null 2>&1; then
		while read -r ifc pt; do [ -n "$pt" ] && [ "$pt" != 0 ] && { found="$found WireGuard($ifc)"; ports="$ports $pt/udp"; }; done < <(wg show all listen-port 2>/dev/null)
	fi
	if command -v awg >/dev/null 2>&1; then
		while read -r ifc pt; do [ -n "$pt" ] && [ "$pt" != 0 ] && { found="$found AmneziaWG($ifc)"; ports="$ports $pt/udp"; }; done < <(awg show all listen-port 2>/dev/null)
	fi
	if [ -z "$found" ]; then
		for ifc in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | { grep -E '^(wg|awg)[0-9]' || true; }); do found="$found туннель($ifc)"; done
	fi
	if command -v docker >/dev/null 2>&1; then
		while IFS='|' read -r name pp; do
			case $name in
				*amnezia* | *wireguard* | *wg-easy* | *openvpn* | *xray* | *cloak* | *shadowsocks* | *outline* | *wstunnel*)
					found="$found Docker:$name"
					for pr in $({ grep -oE '[0-9]+->[0-9]+/(tcp|udp)' <<<"$pp" || true; } | sed -E 's#.*->([0-9]+)/(tcp|udp)#\1/\2#'); do ports="$ports $pr"; done ;;
			esac
		done < <(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null || true)
	fi
	OTHER_VPN=$(echo $found | sed 's/^ *//; s/ /, /g')
	OTHER_VPN_PORTS=$(echo $ports | tr ' ' '\n' | { grep -E '^[0-9]+/(tcp|udp)$' || true; } | sort -u | tr '\n' ' ')
	return 0
}
detect_other_vpn

say "Ядро, swap, часовой пояс"
# IPv6 выключается (клиенты и Let's Encrypt — по IPv4). Зашли на сервер по IPv6 — не трогать: вход оборвался бы.
SSH_FROM=${SSH_CONNECTION:-}; SSH_FROM=${SSH_FROM%% *}
V6_OFF=1
case $SSH_FROM in ::ffff:*) ;; *:*) V6_OFF=0 ;; esac
{
	echo "net.core.default_qdisc=fq"
	echo "net.ipv4.tcp_congestion_control=bbr"
	if [ "$V6_OFF" = 1 ]; then
		echo "net.ipv6.conf.all.disable_ipv6=1"
		echo "net.ipv6.conf.default.disable_ipv6=1"
	fi
	echo "net.ipv4.ip_nonlocal_bind=1"
} > /etc/sysctl.d/99-vpn.conf
[ "$V6_OFF" = 1 ] || warn "вы зашли на сервер по IPv6 — IPv6 оставляю включённым (выключение оборвало бы вход)"
if [ "$CONTAINER" = 1 ]; then
	warn "контейнер: /etc/sysctl.d/99-vpn.conf записан, но не применён"
else
	modprobe tcp_bbr 2>/dev/null || true
	if sysctl -p /etc/sysctl.d/99-vpn.conf >/dev/null 2>&1; then
		ok "BBR ($(sysctl -n net.ipv4.tcp_congestion_control))$([ "$V6_OFF" = 1 ] && echo ", IPv6 выключен")"
	else
		warn "часть настроек ядра не применилась (бывает на OpenVZ/LXC-серверах) — VPN это не мешает"
	fi
	[ -z "$OTHER_VPN" ] || warn "рядом работает $OTHER_VPN. IPv6 на сервере выключается — если тот VPN ходит по IPv6, он может перестать работать (проверь). И один IP на два VPN рискованно: заблокируют один протокол — пострадает и другой; надёжнее держать их на разных серверах"
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
ok "часовой пояс $TZ_NAME$([ "$MODE" = domain ] && echo " (по нему cron продлевает сертификат)")"

# Раздел «SSH» — только когда есть что сказать: вход по паролю без --ssh-key-only не трогаем и не напоминаем.
if ! command -v sshd >/dev/null; then
	say "SSH"
	warn "sshd не установлен — пропущено"
elif [ "$SSH_KEY_ONLY" = 1 ]; then
	say "SSH"
	SSH_HOW=$(ssh_login_method)
	if [ "$SSH_HOW" = password ] || [ "$SSH_HOW" = keyboard-interactive ]; then
		bad "вы сами вошли сейчас по паролю — выключать его нельзя, иначе после выхода не войдёте. Войдите по ключу и запустите скрипт ещё раз с --ssh-key-only"
	elif root_has_own_key; then
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
		warn "у root нет своего ключа в /root/.ssh/authorized_keys (ключ бота не в счёт) — вход по паролю оставлен, иначе вы потеряете доступ"
	fi
fi
SSH_PORTS=$(ssh_ports)
SSH_PORT=${SSH_PORTS%% *}
SSH_LOGIN=root   # под кем входить в инструкциях: зашли через sudo (AWS, Oracle — ubuntu) — под тем же пользователем
if [[ ${SUDO_USER:-} =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] && [ "$SUDO_USER" != root ]; then SSH_LOGIN=$SUDO_USER; fi

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

xui_inbound_ports() {  # «порт/протокол» включённых подключений панели, которые слушают не только localhost
	[ -f "$DB" ] || return 0
	python3 -I - "$DB" <<'PY' 2>/dev/null || true
import json, sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
out = set()
for port, listen, proto, settings, stream, enable in db.execute(
        "select port, listen, protocol, settings, stream_settings, enable from inbounds"):
    listen = (listen or "").strip()
    if not enable or not port or listen.startswith(("127.", "/", "@")) or listen in ("::1", "[::1]", "localhost"):
        continue
    try:
        st = json.loads(settings or "{}")
    except ValueError:
        st = {}
    try:
        ss = json.loads(stream or "{}")
    except ValueError:
        ss = {}
    proto = (proto or "").lower()
    net = str(ss.get("network") or "tcp").lower()
    if proto in ("wireguard", "hysteria", "hysteria2", "tuic") or net in ("kcp", "mkcp", "quic"):
        kinds = {"udp"}
    elif proto in ("shadowsocks", "dokodemo-door", "tunnel"):
        n = str(st.get("network") or "tcp").lower()
        kinds = {k for k in ("tcp", "udp") if k in n} or {"tcp"}
    elif proto in ("mixed", "socks"):
        kinds = {"tcp", "udp"} if st.get("udp") else {"tcp"}
    else:
        kinds = {"tcp"}
    out.update((int(port), k) for k in kinds)
for port, kind in sorted(out):
    print("%d/%s" % (port, kind))
PY
}
fw_kept_ports() {  # фаервол ещё выключен — подключения панели снаружи доступны; их порты включённый ufw не должен закрыть
	! ufw status 2>/dev/null | grep -q '^Status: active' || return 0   # уже включён — его правила остаются как есть
	xui_inbound_ports
}
say "Фаервол ufw"
if [ "$DO_UFW" = 1 ]; then
	KEEP=$(fw_kept_ports)
	OPEN=$( {
		for p in $SSH_PORTS; do echo "$p/tcp"; done
		[ -n "${SSH_CONNECTION:-}" ] && echo "${SSH_CONNECTION##* }/tcp"
		if [ "$MODE" = domain ]; then echo 80/tcp; echo 443/tcp; fi
		if [ "$PANEL_PUBLIC" = 1 ]; then echo "$WEB_PORT/tcp"; fi
		if [ "${SUB_TLS:-0}" = 1 ]; then echo 80/tcp; echo "$SUB_PORT/tcp"; fi   # :80 — продление сертификата на IP
		echo "$REALITY_PORT/tcp"
		for pp in $OTHER_VPN_PORTS $KEEP; do echo "$pp"; done
	} | sort -u | sort -t/ -k1,1n -k2,2)
	for p in $OPEN; do ufw allow "$p" >/dev/null || bad "ufw allow $p не прошёл"; done
	KEPT=$(for pp in $KEEP; do [ "$pp" = "$REALITY_PORT/tcp" ] || printf '%s ' "$pp"; done)
	[ -z "$KEPT" ] || ok "подключения панели на других портах доступны, как раньше: ${KEPT% }"
	if [ -n "${MOVED_FROM:-}" ] && ! grep -qx "$MOVED_FROM/tcp" <<<"$OPEN" && [ -z "$(port_users "$MOVED_FROM")" ]; then
		ufw delete allow "$MOVED_FROM/tcp" >/dev/null 2>&1 || true
		ok "старый порт подключения $MOVED_FROM закрыт в ufw"
	fi
	[ -z "$OTHER_VPN_PORTS" ] || warn "рядом работает ${OTHER_VPN:-другой VPN} — открыл его порты в ufw ($OTHER_VPN_PORTS), чтобы фаервол его не отрубил"
	# Подписка без сертификата на IP — внутри сервера: её порт и :80 снаружи не нужны.
	if [ "$MODE" = nodomain ] && [ "${SUB_TLS:-0}" != 1 ]; then
		for p in "$SUB_PORT/tcp" 80/tcp; do grep -qx "$p" <<<"$OPEN" || ufw delete allow "$p" >/dev/null 2>&1 || true; done
	fi
	# Панель убрали с внешнего адреса (--panel-local) — закрыть и её порт.
	if [ "$MODE" = nodomain ] && [ "$PANEL_PUBLIC" = 0 ]; then ufw delete allow "$WEB_PORT/tcp" >/dev/null 2>&1 || true; fi
	if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
		# Что ещё слушает снаружи, фаервол закроет — назвать, чтобы чужая служба не пропала молча.
		CLOSING=$(ss -Htuln 2>/dev/null | awk '{print $1, $5}' | while read -r proto addr; do
			case $addr in 127.* | "[::1]"* | *%lo:*) continue ;; esac
			p=${addr##*:}
			case $p in '' | *[!0-9]*) continue ;; esac
			echo "$p/$proto"
		done | sort -u | { grep -vxF -f <(printf '%s\n' 68/udp 546/udp $OPEN) || true; } | sort -t/ -k1,1n | tr '\n' ' ')
		[ -z "$CLOSING" ] || warn "фаервол закроет и порты, которые сейчас слушает этот сервер: ${CLOSING}— если там нужная служба, откройте: ufw allow ПОРТ/tcp (или /udp)"
	fi
	if ufw --force enable >/dev/null 2>&1; then ok "включён, открыто: $(echo $OPEN)"; else bad "ufw не включился (ufw status)"; fi
else
	warn "фаервол не трогали (--no-ufw)"
fi

say "Команды проверки и бэкап для переезда"
install -d -m 755 /usr/local/lib/vpn-backup
cat > /usr/local/bin/vpn-backup.sh <<'VPN_KIT_EOF_0'
#!/bin/bash
# vpn-backup.sh — полный бэкап VPN-сервера для переезда: база 3x-ui (клиенты, ключи Reality,
# настройки панели), nginx, сертификат домена и acme.sh, настройки ядра, SSH, служба, cron,
# вотчдог выхода (если стоит), установщик для друзей и скрипт для мака.
# Из архива restore.sh поднимает такую же копию на чистом сервере (см. README.md в архиве).
#
# Архивы: /root/backups/vpn-backup-<домен>-<дата>.tgz, ссылка latest.tgz, хранится KEEP штук.
# Запуск: vpn-backup.sh (вручную; на основном сервере — ежедневно из /etc/cron.d/vpn-backup).
# Последняя строка вывода — путь к архиву.
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
case $CERT_FILE in
	/root/cert/*/*)
		DOMAIN=$(basename "$(dirname "$CERT_FILE")")
		# Самоподписанный сертификат панели на IP (сервер без домена) — не домен.
		if [[ $DOMAIN != *.* ]] || [[ $DOMAIN =~ ^[0-9.]+$ ]]; then DOMAIN=; fi
		;;
esac

SRC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
PUBLIC_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "$SRC_IP")
TS=$(date +%Y%m%d-%H%M%S)
NAME=vpn-backup-${DOMAIN:-ip-$PUBLIC_IP}-$TS
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
WORK=$(mktemp -d "$BACKUP_DIR/.work.XXXXXX")
trap 'rm -rf "$WORK"; [ -z "${OUT:-}" ] || rm -f "$OUT.part"' EXIT   # и недописанный архив — при ошибке
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
keep /etc/x-ui/warp /etc/x-ui/chain /etc/x-ui/panel-cert /etc/x-ui/install-result.env /etc/default/x-ui \
	/etc/systemd/system/x-ui.service /usr/bin/x-ui \
	/etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/stream-enabled /etc/nginx/sites-enabled \
	/var/www/html \
	/etc/systemd/system/nginx.service.d \
	${DOMAIN:+"/root/cert/$DOMAIN"} /root/.acme.sh \
	/etc/sysctl.d/99-vpn.conf /etc/sysctl.conf \
	/etc/ssh/sshd_config.d /root/.ssh/authorized_keys \
	/usr/local/bin/vpn-backup.sh /etc/cron.d/vpn-backup \
	/usr/local/bin/vpn-exit-watchdog.sh /etc/systemd/system/vpn-exit-watchdog.service \
	"$KIT_DIR/install-vpn.sh" "$KIT_DIR/mac" /usr/local/bin/vpn-check /usr/local/bin/vpn-warp /etc/vpn-install.env \
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
    if (st.get("webListen") or "") not in ("127.0.0.1", "localhost"):
        kind = "Let's Encrypt на IP" if "/ip-cert/" in (st.get("webCertFile") or "") else "самоподписанный"
        print("Панель:   https://%s:%s%s (сертификат %s)" % (ip, st.get("webPort"), st.get("webBasePath", "/"), kind))
    else:
        print("Панель:   через SSH-туннель — ssh -N -L %s:127.0.0.1:%s root@%s, потом http://127.0.0.1:%s%s" % (
            st.get("webPort"), st.get("webPort"), ip, st.get("webPort"), st.get("webBasePath", "/")))
    if st.get("subCertFile"):
        print("Подписка: https://%s:%s%s<subId> (сертификат Let's Encrypt на IP; в архив не входит — после переезда\n"
              "          его выпустит повторный запуск install-vpn.sh)" % (ip, st.get("subPort"), st.get("subPath", "/sub/")))
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
touch /root/vpn-restore.log && chmod 600 /root/vpn-restore.log   # в журнале ссылки клиентов и пароль панели
exec > >(tee -a /root/vpn-restore.log) 2>&1

detect_ips() {
	local u
	[ -n "$LISTEN_IP" ] || LISTEN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
	[ -n "$LISTEN_IP" ] || die "не удалось определить IP сервера — укажите --listen-ip"
	PUBLIC_IP=
	for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
		PUBLIC_IP=$(curl -4 -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]') || true
		[[ $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
		PUBLIC_IP=
	done
	if [ -z "$PUBLIC_IP" ]; then
		PUBLIC_IP=$LISTEN_IP
		warn "внешний IP не узнать (api.ipify.org, ifconfig.me, icanhazip.com недоступны) — считаю, что это $PUBLIC_IP"
	fi
}

release_sha() {  # release_sha ВЕРСИЯ АРХИТЕКТУРА → sha256 архива релиза 3x-ui, если он известен (как в install-vpn.sh)
	case $1/$2 in
		3.3.1/amd64) echo 06adfff2b27af6d59225338a8112caca882d32d11136d962649826d42c24d12e ;;
		3.3.1/arm64) echo 0f7907b56554eba624c51c6aed2a9ba4af1378c8134b30afa5cee622e3100209 ;;
	esac
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
	local T s p code code2 n link xray_bin exit_ip exit_warp chain log web_port web_path sub_port subid want sub_listen
	T=$(mktemp -d)
	web_port=$(setting webPort); web_path=$(setting webBasePath)
	sub_port=$(setting subPort)

	for s in x-ui $([ "$HAS_NGINX" = 1 ] && echo nginx) $([ -f /etc/fail2ban/jail.d/vpn-sshd.local ] && echo fail2ban); do
		if systemctl is-active -q "$s"; then ok "служба $s работает"; else bad "служба $s не работает (journalctl -u $s)"; fi
	done
	if [ -f /etc/systemd/system/vpn-exit-watchdog.service ]; then
		if systemctl is-active -q vpn-exit-watchdog; then ok "вотчдог выхода работает"; else bad "вотчдог выхода не работает (journalctl -u vpn-exit-watchdog)"; fi
	fi
	# Подписка слушает 127.0.0.1 или (сертификат на IP) все адреса — проверять там, где она должна быть.
	sub_listen=$(setting subListen)
	for p in $([ "$HAS_NGINX" = 1 ] && echo "$LISTEN_IP:443 127.0.0.1:8443") ":$web_port" "$sub_listen:$sub_port"; do
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
		if [ "$code" != 200 ]; then
			bad "панель отвечает $code"
		elif [ "$(setting webListen)" != 127.0.0.1 ]; then
			ok "панель отвечает 200 — открыта по IP: https://$PUBLIC_IP:$web_port/…"
		else
			ok "панель на 127.0.0.1:$web_port отвечает 200 (снаружи — через SSH-туннель)"
		fi
	fi

	if [ "$HAS_NGINX" = 1 ] && [ -n "$DOMAIN" ]; then
		code=$(curl -s $CURL_K -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$DOMAIN:443:$LISTEN_IP" "https://$DOMAIN/" || true)
		if [ "$code" = 200 ]; then ok "заглушка сайта на / отвечает 200"; else bad "заглушка сайта на / отвечает $code — self-steal покажет ошибку вместо сайта"; fi
	fi
	read -r p s <<<"$(reality_foreign)"
	if [ -n "${s:-}" ]; then
		# Reality под чужой сайт: кто прощупывает без ключа, должен получить настоящий сайт с верным сертификатом.
		if timeout 10 openssl s_client -connect "$LISTEN_IP:$p" -servername "$s" -verify_hostname "$s" -verify_return_error \
			< /dev/null 2>&1 | grep 'Verify return code: 0 (ok)' >/dev/null; then
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
			# Адрес в ссылке — этого сервера (домен или нынешний IP), а не старого: иначе клиенты уйдут туда.
			want=${DOMAIN:-$PUBLIC_IP}
			if [ -n "$link" ]; then
				case $link in
					*"@$want:"*) ok "в ссылках адрес этого сервера: $want" ;;
					*) bad "в ссылках не адрес этого сервера ($want) — клиенты пойдут на прежний (адрес подключения в панели: share_addr)" ;;
				esac
			fi
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

Выход клиентов идёт цепочкой через сервер ${chain%:*}. На нём должен быть открыт порт для нового IP:
  ufw allow from $PUBLIC_IP to any port ${chain##*:} proto tcp comment 'vpn entry'
(у AWS и Oracle — ещё и в панели хостера: Security Group / Security List; старое правило для прежнего IP
входа потом удалить: ufw status numbered → ufw delete N). Как порт откроется, вотчдог сам вернёт цепочку.
EOF
	fi
	if [ "$FAILS" != 0 ]; then
		cat <<EOF

Сначала разберитесь с ошибками выше$([ -n "$chain" ] && echo " (не работает туннель — скорее всего, ещё не открыт порт на сервере-выходе)"),
потом проверьте ещё раз: bash $HERE/restore.sh --verify
$([ -n "$DOMAIN" ] && echo "DNS переключать — только после «Проверка: всё OK»." || echo "Новые ссылки раздавать клиентам — только после «Проверка: всё OK».")
EOF
		return 0
	fi
	if [ -z "$DOMAIN" ]; then
		cat <<EOF

Сервер без домена: ссылки клиентов ведут на IP. Теперь это $PUBLIC_IP — раздайте клиентам новые
ссылки (в приложении удалить старую и добавить новую: «+» → «Импорт из буфера обмена»):
EOF
		client_links
		if [ "$(setting webListen)" != 127.0.0.1 ]; then
			if [ "$(setting webCertFile)" = /etc/x-ui/ip-cert/fullchain.pem ]; then
				echo "Панель: https://$PUBLIC_IP:$(setting webPort)$(setting webBasePath) (сертификат Let's Encrypt на IP, логин и пароль — прежние)"
			else
				echo "Панель: https://$PUBLIC_IP:$(setting webPort)$(setting webBasePath) (сертификат самоподписанный, логин и пароль — прежние)"
			fi
		fi
		if [ "${IPCERT_FALLBACK:-0}" = 1 ]; then
			echo "Подписку по IP (https://$PUBLIC_IP:$(setting subPort)/…) вернёт повторный запуск: bash /usr/local/lib/vpn-backup/install-vpn.sh"
			echo "(выпустит сертификат Let's Encrypt на этот IP; до тех пор выше — прямые ссылки)"
		fi
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
	final_note   # что делать дальше — и при ошибках проверки: в цепочке их часто даёт ещё не открытый порт выхода
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
	# Порты панели и подписки из бэкапа — тоже свободны (иначе x-ui поднимется без них).
	for p in $(python3 - "$F$DB" 2>/dev/null <<'PY' || true
import sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
for k in ("webPort", "subPort"):
    r = db.execute("select value from settings where key=?", (k,)).fetchone()
    if r and str(r[0]).isdigit():
        print(r[0])
PY
	); do
		u=$(port_users "$p")
		case $u in "" | xray* | x-ui*) ;; *) die "порт $p (панель или подписка 3x-ui) занят: $u" ;; esac
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
	# Известный релиз сверяется по sha256 до распаковки: подменённый или битый архив не ставится.
	want_sha=$(release_sha "$XUI_WANT" "$ARCH_NEW")
	if [ -n "$want_sha" ]; then
		echo "$want_sha  $TMP/x-ui.tgz" | sha256sum -c --quiet - >/dev/null 2>&1 || die "архив 3x-ui $XUI_WANT не совпал по sha256 — скачан не тот файл"
		ok "архив 3x-ui $XUI_WANT сверен по sha256"
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
# Без домена адрес в ссылках клиентов — IP сервера (share_addr подключения): переносим на новый. Не только прежний
# IP из бэкапа: если старый сервер менял адрес, в ссылках мог остаться и более ранний.
if [ -z "$DOMAIN" ]; then
	n=$(sqlite3 "$DB" "update inbounds set share_addr='$PUBLIC_IP' where share_addr_strategy='custom' and share_addr<>'$PUBLIC_IP' and (share_addr='$SRC_PUBLIC_IP' or share_addr glob '[0-9]*.[0-9]*.[0-9]*.[0-9]*'); select changes();")
	[ "${n:-0}" = 0 ] || ok "адрес в ссылках клиентов теперь $PUBLIC_IP (подключений: $n)"
fi
# Без домена панель открыта по IP с самоподписанным сертификатом (install-vpn.sh): на новом IP — новый сертификат.
if [ -z "$DOMAIN" ] && [ -d "$F/etc/x-ui/panel-cert" ]; then
	cp -a "$F/etc/x-ui/panel-cert" /etc/x-ui/
	if [ "$SRC_PUBLIC_IP" != "$PUBLIC_IP" ]; then
		san="IP:$PUBLIC_IP"
		[ "$LISTEN_IP" = "$PUBLIC_IP" ] || san="$san,IP:$LISTEN_IP"
		if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=$PUBLIC_IP" \
			-addext "subjectAltName=$san" -keyout /etc/x-ui/panel-cert/privkey.pem -out /etc/x-ui/panel-cert/fullchain.pem >/dev/null 2>&1; then
			chmod 600 /etc/x-ui/panel-cert/privkey.pem
			ok "сертификат панели выпущен заново на новый IP $PUBLIC_IP"
		else
			bad "не перевыпустился сертификат панели на новый IP"
		fi
	fi
fi

# Без домена с сертификатом Let's Encrypt на IP (install-vpn.sh): его в архиве нет — он на ~6 дней и привязан к адресу.
# Панель — на самоподписанный, подписка — внутрь сервера; подписку по IP вернёт повторный запуск install-vpn.sh.
IPCERT_FALLBACK=0
if [ -z "$DOMAIN" ] && { [ "$(setting subCertFile)" = /etc/x-ui/ip-cert/fullchain.pem ] || [ "$(setting webCertFile)" = /etc/x-ui/ip-cert/fullchain.pem ]; }; then
	if [ ! -s /etc/x-ui/panel-cert/fullchain.pem ]; then
		install -d -m 700 /etc/x-ui/panel-cert
		san="IP:$PUBLIC_IP"
		[ "$LISTEN_IP" = "$PUBLIC_IP" ] || san="$san,IP:$LISTEN_IP"
		openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=$PUBLIC_IP" \
			-addext "subjectAltName=$san" -keyout /etc/x-ui/panel-cert/privkey.pem -out /etc/x-ui/panel-cert/fullchain.pem >/dev/null 2>&1 ||
			bad "не создался самоподписанный сертификат панели"
		chmod 600 /etc/x-ui/panel-cert/privkey.pem 2>/dev/null || true
	fi
	sqlite3 "$DB" "update settings set value='/etc/x-ui/panel-cert/fullchain.pem' where key='webCertFile' and value like '/etc/x-ui/ip-cert/%';
		update settings set value='/etc/x-ui/panel-cert/privkey.pem' where key='webKeyFile' and value like '/etc/x-ui/ip-cert/%';
		update settings set value='127.0.0.1' where key='subListen';
		update settings set value='' where key in ('subCertFile', 'subKeyFile', 'subURI');"
	IPCERT_FALLBACK=1
	warn "сертификата Let's Encrypt на IP в архиве нет (он на ~6 дней): панель — на самоподписанном, подписка — внутри сервера"
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
	[ ! -f /root/.acme.sh/acme.sh.env ] || grep -qF 'acme.sh.env' /root/.bashrc 2>/dev/null || echo '. "/root/.acme.sh/acme.sh.env"' >> /root/.bashrc
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
elif [ "$(df -Pm / | awk 'NR==2 {print $4}')" -lt 4096 ]; then
	warn "на диске меньше 4 ГБ свободно — swap не создаю"
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
	ok "часовой пояс $TIMEZONE$([ -n "$DOMAIN" ] && echo " (по нему cron продлевает сертификат)")"
else
	warn "часовой пояс $TIMEZONE не выставлен"
fi

say "SSH"
if [ -f "$F/root/.ssh/authorized_keys" ]; then
	install -d -m 700 /root/.ssh
	touch /root/.ssh/authorized_keys
	chmod 600 /root/.ssh/authorized_keys
	# Последняя строка без перевода строки — новый ключ приклеился бы к ней и испортил оба.
	if [ -s /root/.ssh/authorized_keys ] && [ -n "$(tail -c1 /root/.ssh/authorized_keys)" ]; then echo >> /root/.ssh/authorized_keys; fi
	while IFS= read -r k || [ -n "$k" ]; do   # и последний ключ бэкапа без перевода строки — тоже
		k=${k%$'\r'}
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
		# Без домена панель может быть открыта по IP (install-vpn.sh) — её порт тоже.
		if [ -z "$DOMAIN" ] && [ "$(setting webListen)" != 127.0.0.1 ]; then echo "$(setting webPort)/tcp"; fi
		inbound_ports "$DB"
	} | sort -u -t/ -k1,1n -k2)
	for p in $OPEN; do ufw allow "$p" >/dev/null || bad "ufw allow $p не прошёл"; done
	if ufw --force enable >/dev/null 2>&1; then ok "включён, открыто: $(echo $OPEN)"; else bad "ufw не включился"; fi
else
	warn "фаервол не трогали (--no-ufw)"
fi

say "Бэкап на этом сервере"
install -m 755 "$F/usr/local/bin/vpn-backup.sh" /usr/local/bin/vpn-backup.sh
install -d -m 755 /usr/local/lib/vpn-backup
install -m 755 "$HERE/restore.sh" /usr/local/lib/vpn-backup/restore.sh
install -m 644 "$HERE/README.md" /usr/local/lib/vpn-backup/README.md
# Установщик для друзей и скрипт для мака лежат рядом с комплектом и переезжают вместе с ним.
if [ -d "$F/usr/local/lib/vpn-backup" ]; then
	find "$F/usr/local/lib/vpn-backup" -mindepth 1 -maxdepth 1 ! -name restore.sh ! -name README.md -exec cp -a {} /usr/local/lib/vpn-backup/ \;
fi
# Ежедневный автобэкап — только если он был на старом сервере (install-vpn.sh его не ставит).
if [ -f "$F/etc/cron.d/vpn-backup" ]; then install -m 644 "$F/etc/cron.d/vpn-backup" /etc/cron.d/vpn-backup; fi
# Сервер, поставленный install-vpn.sh: его настройки (для повторного запуска и vpn-check) и команда vpn-check.
if [ -f "$F/etc/vpn-install.env" ]; then install -m 600 "$F/etc/vpn-install.env" /etc/vpn-install.env; fi
for f in vpn-check vpn-warp; do
	if [ -f "$F/usr/local/bin/$f" ]; then install -m 755 "$F/usr/local/bin/$f" "/usr/local/bin/$f"; fi
done
if [ -f /etc/cron.d/vpn-backup ]; then ok "vpn-backup.sh по cron, архивы в /root/backups"; else ok "vpn-backup.sh — бэкап вручную, архивы в /root/backups"; fi

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
wait_port ":$(setting webPort)" 30 || true
if [ "$HAS_NGINX" = 1 ]; then systemctl restart nginx || bad "nginx не запустился (journalctl -u nginx)"; fi
if [ "$WATCHDOG" = 1 ]; then
	systemctl enable vpn-exit-watchdog >/dev/null 2>&1 || warn "не удалось включить автозапуск вотчдога"
	systemctl restart vpn-exit-watchdog || bad "вотчдог не запустился (journalctl -u vpn-exit-watchdog)"
fi

verify
echo "Заняло $(( $(date +%s) - START )) с. Журнал: /root/vpn-restore.log"
final_note
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
| Служба x-ui и скрипт бэкапа | `/etc/systemd/system/x-ui.service`, `/usr/local/bin/vpn-backup.sh` |
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

## Выход через другой сервер (chain)

При установке можно выбрать пункт «через другой мой сервер» (или `--exit chain --exit-host IP_СТАРОГО`).
Новый сервер сам зайдёт на старый по SSH, поднимет там лёгкий вход Xray и пустит весь трафик
новый → старый → интернет — сайты будут видеть IP старого сервера.

- Вход на старый — по паролю или по SSH-ключу: ключ можно вставить целиком (OpenSSH, PEM, PKCS#8,
  PuTTY .ppk) или указать файл (`--exit-ssh-key`, парольная фраза — `EXIT_KEY_PASS`). Пользователь — root
  или, как на AWS/Oracle, `ubuntu` с sudo (`--exit-ssh-user ubuntu`; пароль sudo — `EXIT_SUDO_PASS` или спросит).
- Старый сервер упал — примерно через 2 минуты вотчдог включает запасной режим: российские сайты (зоны
  .ru/.su/.рф, список российских сервисов `geosite:category-ru`, российские IP `geoip:ru`) — через Cloudflare
  WARP, остальное — напрямую с IP нового сервера. Старый поднялся — примерно через 1,5 минуты всё снова
  через него. Что активно сейчас — `vpn-check` или `vpn-warp`.
- На облаках откройте порт цепочки (TCP 2087) для IP нового сервера в панели хостера (AWS — Security Group,
  Oracle — Security List). Пока он закрыт — запасной режим, потом вотчдог переключит сам.
- Если на старом ещё работает 3x-ui — цепочке это не мешает; захочешь, скрипт предложит его выключить
  (или сразу `--exit-stop-xui`). Переехал новый сервер на другой IP — на старом открой ему порт:
  `ufw allow from НОВЫЙ_IP to any port 2087 proto tcp`.
- Не вышло настроить другой старый сервер (не тот пароль, сервер недоступен) — прежняя цепочка остаётся как
  была. SSH-ключ старого сервера запоминается (`/etc/x-ui/chain/known_hosts`): переустановили старый сервер —
  удалите этот файл, иначе скрипт примет новый ключ за подмену.

## Выход через WARP

`vpn-warp off` — напрямую с IP сервера, `vpn-warp on` — весь трафик через Cloudflare WARP,
`vpn-warp ru` — российские сайты через WARP, `vpn-warp` — как сейчас. После переключения туннель
проверяется; не заработало — возвращается как было.

## Бэкап

Сам сервер бэкапы не делает. Когда нужен (перед переездом) — `vpn-backup.sh`: архив ляжет в
`/root/backups/` (`latest.tgz` — последний). Забрать к себе на компьютер:

```bash
scp root@IP_СЕРВЕРА:/root/backups/latest.tgz ./vpn-backup.tgz
# вход не под root (AWS, Oracle):
ssh ubuntu@IP_СЕРВЕРА 'sudo cat /root/backups/latest.tgz' > vpn-backup.tgz
```

## Переезд на новый сервер

Если при установке ставили Телеграм-бота, проще всего — из бота: «🚚 Переезд», IP, логин и пароль нового
сервера. Бот сам снимет свежий бэкап, поднимет из него новый сервер и сменит A-запись. Вручную:

1. Новый сервер: Ubuntu 22.04/24.04 или Debian 12, от 1 ГБ ОЗУ, доступ root по SSH.
   Проверить, что его IP открывается из России: check-host.net → TCP-порт 22 с узлов в России
   (install-vpn.sh делает это сам перед установкой и не ставит VPN на заблокированный IP).
2. Залить архив и восстановить:
   ```bash
   scp vpn-backup.tgz root@НОВЫЙ_IP:/root/
   ssh root@НОВЫЙ_IP
   tar xzf vpn-backup.tgz && bash vpn-backup-*/restore.sh
   ```
3. В конце должно быть **«Проверка: всё OK»**. Выход цепочкой: на старом сервере сначала откройте порт новому IP
   (команду напечатает `restore.sh`), потом `bash vpn-backup-*/restore.sh --verify`.
4. С доменом: поменять A-запись домена на новый IP (TTL 300, в Cloudflare — Proxy выключен).
   Клиенты переподключатся сами за несколько минут. Старый сервер держать ещё сутки.
   Без домена: раздать клиентам новые ссылки, которые напечатал `restore.sh` (в приложении удалить
   старую и добавить новую). Старый сервер не удалять, пока все не перейдут.

Опции `restore.sh`: `--listen-ip IP` (сервер за NAT: внутренний IP), `--keep-password-ssh`,
`--no-ufw`, `--verify` (только проверить).

## Тонкости

- Порт 80 должен оставаться открытым: через него продлевается сертификат.
- Повторный запуск установщика оборвался (ошибка, Ctrl-C) — база 3x-ui возвращается такой, какой была до
  запуска, VPN работает как работал. Первая установка не дошла до конца — можно запустить снова с другим
  вариантом (`--no-domain`) или другим доменом.
- Клиенты VPN не достают до внутренних адресов серверов (127.0.0.1, 10/8, 192.168/16 и т. п.) ни по IP, ни по
  имени вроде `localhost`: службы самих серверов (API Xray, панель) через VPN не видны.
- Клиентов добавлять и удалять в панели (3x-ui хранит их в отдельных таблицах базы).
- В приложениях нужно ядро Xray (Happ, v2RayTun, v2rayNG, v2rayN, Streisand): транспорт XHTTP
  приложения на sing-box (Hiddify и похожие) не поддерживают.
- С доменом — Reality «steal-oneself»: подключение на порту 2083, SNI — сам домен, Reality отдаёт чужим
  настоящий сайт с nginx (`127.0.0.1:8443`). На 443 nginx пускает свой домен к сайту, панели и подписке,
  остальное обрывает.
- Без домена — Reality на порту 2083 (как у основного сервера; другой — `--port`) под крупный чужой сайт
  (какой — видно в панели, поле SNI подключения):
  тот, кто прощупывает сервер, получает настоящий сайт. Сертификат Let's Encrypt на IP (короткий, ~6 дней,
  продлевается сам через порт 80): подписка — `https://IP:2096/путь/…`, панель — `https://IP:ПОРТ/путь/`
  без предупреждения браузера; адреса, логин и пароль — в `/root/vpn-info.txt`. Сертификат не получен
  (порт 80 закрыт у хостера) — подписка только внутри сервера, в QR прямые ссылки, панель с самоподписанным:
  откройте TCP 80 и запустите установщик ещё раз. После переезда из бэкапа сертификат на новый IP выпускает
  повторный запуск установщика. Спрятать панель за SSH-туннель — запуск с `--panel-local` (вернуть — `--panel-public`).
- В подключении стоят uTLS `chrome` и xmux (меньше TLS-рукопожатий — меньше заморозок у провайдеров);
  если их поменять, клиентам надо обновить подписку или ссылки.
VPN_KIT_EOF_2
chmod 644 /usr/local/lib/vpn-backup/README.md
# Автобэкап не ставим; прежняя версия скрипта ставила ежедневный — снять.
if [ -f /etc/cron.d/vpn-backup ]; then rm -f /etc/cron.d/vpn-backup && ok "ежедневный автобэкап снят (бэкап — вручную, когда нужен)"; fi
ok "vpn-backup.sh — бэкап для переезда вручную, сам не запускается (архив в /root/backups, README.md внутри)"
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
	cat > /usr/local/bin/vpn-warp <<'EOF'
#!/bin/bash
# Выход клиентов через Cloudflare WARP: vpn-warp off | on | ru | status (install-vpn.sh --warp).
exec bash /usr/local/lib/vpn-backup/install-vpn.sh --warp "${1:-status}"
EOF
	chmod 755 /usr/local/bin/vpn-warp
	ok "команда vpn-check: проверить VPN в любой момент (ничего не меняет)"
	ok "команда vpn-warp: off — WARP выключить, on — всё через WARP, ru — российские сайты через WARP"
fi

say "Запуск"
SERVICES="x-ui cron"
[ "$MODE" = domain ] && SERVICES="x-ui nginx cron"
# shellcheck disable=SC2086
systemctl enable $SERVICES >/dev/null 2>&1 || warn "не удалось включить автозапуск служб"
systemctl restart cron || warn "cron не перезапустился"
systemctl restart x-ui || bad "x-ui не запустился (journalctl -u x-ui)"
wait_port ":$WEB_PORT" 40 || true
if [ "$MODE" = domain ]; then systemctl restart nginx || bad "nginx не запустился (journalctl -u nginx)"; fi
INSTALL_DONE=1   # дальше — проверки и итог: ловушка на выходе x-ui уже не трогает
S_DONE=1
save_state

if [ "$BOT_DO" = 1 ]; then
	say "Телеграм-бот"
	if bot_panel_token && bot_exit_bindings && bot_deploy; then
		S_BOT=1 S_BOT_ORIGIN=$BOT_ORIGIN S_BOT_WORKER=$BOT_WORKER S_BOT_SSH_PORT=$SSH_PORT
		S_BOT_USER=${BOT_USERNAME:-$S_BOT_USER}
		while IFS= read -r l; do
			case $l in "⚠"*) warn "${l#⚠ }" ;; ?*) ok "$l" ;; esac
		done <<< "$BOT_REPORT"
		BOT_RESULT=ok
	else
		bot_wipe
		BOT_RESULT=fail
		warn "бот не поставился: $BOT_ERR"
		warn "VPN работает и без бота. Повторить: bash $0 --bot"
	fi
	save_state
elif [ "$BOT_KEEP" = 1 ]; then
	if bot_alive "$S_BOT_ORIGIN"; then ok "Телеграм-бот @$S_BOT_USER работает — не трогал"; else warn "Телеграм-бот @$S_BOT_USER не отвечает ($S_BOT_ORIGIN/healthz)"; fi
	[ "$BOT_STALE" = 0 ] || warn "бот знает прежние настройки (домен, выход или порт SSH) — обнови его: bash $0 --bot (спросит токен Cloudflare)"
fi

K=
[ "$TEST_SELFSIGNED" = 1 ] && K=-k
local_checks
reach_check

say "Готово"
mkdir -p /root/vpn-qr
chmod 700 /root/vpn-qr
rm -f /root/vpn-qr/*.png   # прежние QR (удалённых клиентов, старых адресов) не оставлять
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
		if [ "${SUB_TLS:-0}" = 1 ]; then
			echo "Подписки — по одной на устройство. В приложении: «+» → добавить подписку по ссылке (или отсканировать QR):"
			sub_list | while IFS='|' read -r c s; do
				echo "  $c: https://$PUBLIC_IP:$SUB_PORT$SUB_PATH$s"
				printf '%s|%s\n' "$c" "https://$PUBLIC_IP:$SUB_PORT$SUB_PATH$s" >> "$WORK/qr"
			done
			echo "Подписка сама обновляет настройки в приложениях. Сертификат — Let's Encrypt на IP: ~6 дней, продлевается сам."
		else
			echo "Ссылки — по одной на устройство. В приложении: «+» → «Импорт из буфера обмена» (или отсканировать QR):"
			sub_list | while IFS='|' read -r c s; do
				l=$(sub_fetch "$s" | grep -m1 '^vless://' || true)
				[ -n "$l" ] || continue
				echo "  $c:"
				echo "    $l"
				printf '%s|%s\n' "$c" "$l" >> "$WORK/qr"
			done
		fi
		echo
		echo "Ссылки привязаны к IP $PUBLIC_IP. Переедете на другой сервер (restore.sh из бэкапа) —"
		echo "restore.sh напечатает новые ссылки, их надо заново добавить в приложения."
		echo
		if [ "$PANEL_PUBLIC" = 1 ]; then
			echo "Панель управления: https://$PUBLIC_IP:$WEB_PORT$WEB_PATH"
			echo "  логин:  $PANEL_USER"
			echo "  пароль: $PANEL_PASS"
			if [ "$IP_CERT_OK" = 1 ]; then
				echo "  Сертификат Let's Encrypt на IP — браузер откроет без предупреждений."
			else
				echo "  Сертификат самоподписанный: браузер предупредит — «Дополнительно» → «Перейти на сайт»."
				echo "  Отпечаток сертификата SHA-256 (сверить в браузере): $(panel_fingerprint)"
			fi
		else
			echo "Панель управления — только через SSH-туннель, снаружи её не видно:"
			echo "  1) на своём компьютере в терминале (окно не закрывать):"
			echo "       ssh -N -L $WEB_PORT:127.0.0.1:$WEB_PORT -p $SSH_PORT $SSH_LOGIN@$PUBLIC_IP"
			echo "  2) в браузере: http://127.0.0.1:$WEB_PORT$WEB_PATH"
			echo "     логин:  $PANEL_USER"
			echo "     пароль: $PANEL_PASS"
		fi
	fi
	echo
	echo "Приложения (нужно ядро Xray, sing-box-приложения вроде Hiddify XHTTP не умеют):"
	echo "  iPhone/iPad — Happ, v2RayTun, Streisand; Android — Happ, v2RayTun, v2rayNG; Windows/macOS — Happ, v2RayTun, v2rayN."
	echo "Новые устройства — в панели: Подключения → клиенты → «+»; у каждого своя ссылка."
	echo
	echo "Если VPN перестал работать — проверка одной командой (службы, туннель, доступность из России):"
	if [ -x /usr/local/bin/vpn-check ]; then echo "  vpn-check"; else echo "  bash install-vpn.sh --check"; fi
	if [ "$EXIT_MODE" = chain ]; then
		echo "Выход клиентов: цепочкой через $CHAIN_IP (его IP видят сайты). Если он упадёт — вотчдог включит запасной режим (российские сайты через WARP, остальное напрямую) и вернёт обратно."
		if [ "${CHAIN_BLOCKED:-0}" = 1 ]; then
			echo "  ⚠ Сейчас — запасной режим (РФ через WARP, остальное напрямую): порт $CHAIN_PORT закрыт фаерволом хостера. Откройте входящий TCP $CHAIN_PORT"
			echo "    для $PUBLIC_IP (AWS — Security Group, Oracle — Security List/NSG) — вотчдог сам переключит на старый сервер."
		fi
		echo "  Переехал новый сервер на другой IP — на старом открой порт новому (ufw allow from НОВЫЙ_IP to any port $CHAIN_PORT"
		echo "  proto tcp; у AWS/Oracle — ещё и в панели хостера) или переустанови с --exit-host."
	else
		echo "Выход клиентов сейчас: $(exit_label "$EXIT_MODE"). Переключить без переустановки:"
		echo "  vpn-warp off — напрямую, vpn-warp on — всё через WARP, vpn-warp ru — российские сайты через WARP"
	fi
	echo
	echo "Переезд на другой сервер с теми же ключами и клиентами: vpn-backup.sh — архив в /root/backups"
	if [ "$SSH_LOGIN" = root ]; then
		echo "  (секретный; забрать: scp -P $SSH_PORT root@$PUBLIC_IP:/root/backups/latest.tgz .), дальше — README.md"
	else
		echo "  (секретный; забрать: ssh -p $SSH_PORT $SSH_LOGIN@$PUBLIC_IP 'sudo cat /root/backups/latest.tgz' > latest.tgz), дальше — README.md"
	fi
	echo "  в архиве (restore.sh$([ "$MODE" = domain ] && echo ", потом смена A-записи")). Сам бэкап не запускается."
	if [ "${S_BOT:-}" = 1 ]; then
		echo
		echo "Телеграм-бот для управления VPN: @${S_BOT_USER:-?} — https://t.me/${S_BOT_USER:-}"
		echo "  клиенты, статистика, проверка блокировки раз в 3 часа, бэкапы, переезд на новый сервер кнопкой"
		[ "${BOT_RESULT:-}" != fail ] || echo "  ⚠ в этот раз бот не обновился: ${BOT_ERR:-} (повторить: bash install-vpn.sh --bot)"
	elif [ -n "${BOT_SKIP:-}" ] || [ "${BOT_RESULT:-}" = fail ]; then
		echo
		echo "Телеграм-бот не поставлен: ${BOT_ERR:-$BOT_SKIP}"
		echo "  повторить: bash install-vpn.sh --bot — токены скрипт спросит сам"
	fi
} > "$INFO"
chmod 600 "$INFO"
cat "$INFO"
echo
qn=0
while IFS='|' read -r c l; do
	qn=$((qn + 1))   # номер в имени файла: у клиентов бывают одинаковые или нелатинские имена
	qrencode -o "/root/vpn-qr/$(printf '%02d' "$qn")-$(printf '%s' "$c" | tr -c 'A-Za-z0-9._-' '_').png" -s 6 -m 2 "$l" 2>/dev/null || true
	echo "QR $c:"
	qrencode -t ansiutf8 -m 1 "$l" 2>/dev/null || true
done < "$WORK/qr"
echo "То же самое — в $INFO, QR-картинки — в /root/vpn-qr/. Журнал установки: $LOG"
echo "Заняло $(($(date +%s) - START)) с."
if [ "${S_BOT:-}" = 1 ] && [ -n "${S_BOT_USER:-}" ]; then
	printf '\n\033[1;36m═══ Телеграм-бот ═══\033[0m\n'
	printf '  \033[1mhttps://t.me/%s\033[0m — управление VPN из Телеграма\n' "$S_BOT_USER"
fi
# Панель — последним блоком: QR-коды выше длинные, и начало вывода уезжает за экран.
printf '\n\033[1;36m═══ Панель 3x-ui ═══\033[0m\n'
if [ "$MODE" = domain ]; then
	printf '  Адрес:  \033[1mhttps://%s%s\033[0m\n' "$DOMAIN" "$WEB_PATH"
elif [ "$PANEL_PUBLIC" = 1 ]; then
	printf '  Адрес:  \033[1mhttps://%s:%s%s\033[0m\n' "$PUBLIC_IP" "$WEB_PORT" "$WEB_PATH"
	if [ "$IP_CERT_OK" != 1 ]; then echo "  Браузер предупредит о самоподписанном сертификате — «Дополнительно» → «Перейти на сайт»."; fi
else
	echo "  Снаружи панель не видна (так её не найдут сканеры) — открывать через SSH-туннель:"
	echo "  1) на своём компьютере в терминале, окно не закрывать:"
	printf '       \033[1mssh -N -L %s:127.0.0.1:%s -p %s %s@%s\033[0m\n' "$WEB_PORT" "$WEB_PORT" "$SSH_PORT" "$SSH_LOGIN" "$PUBLIC_IP"
	printf '  2) в браузере:  \033[1mhttp://127.0.0.1:%s%s\033[0m\n' "$WEB_PORT" "$WEB_PATH"
fi
printf '  Логин:  \033[1m%s\033[0m\n' "$PANEL_USER"
printf '  Пароль: \033[1m%s\033[0m\n' "$PANEL_PASS"
echo "  Показать ещё раз (вместе со ссылками клиентов): cat $INFO"
verdict
exit $((FAILS > 0))

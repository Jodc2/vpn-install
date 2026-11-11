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
#                     окружении или спросит; первый админ — VPN_BOT_ADMIN_ID или привязка в терминале (написать
#                     боту); остальных админов добавляют в самом боте, повтор с VPN_BOT_ADMIN_ID дописывает этот id
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
	bot_tty_ok || { BOT_ERR="привязать первого админа бота можно только в терминале (или задайте VPN_BOT_ADMIN_ID)"; return 1; }
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

bot_kv_admin() {  # админ из KV нашего воркера: первый из списка admins (его ведёт бот) или admin:id (бот, поставленный руками) → id или пусто
	local v
	[ "${BOT_EXISTING:-}" = ours ] && [ -n "${BOT_KV_ID:-}" ] || return 0
	v=$(cf_api GET "/accounts/$BOT_ACC/storage/kv/namespaces/$BOT_KV_ID/values/admins" 2> /dev/null) || v=
	v=$(python3 -I -c 'import json, sys
try:
    a = json.loads(sys.argv[1])
    print(next(x["id"] for x in a if isinstance(x, dict) and type(x.get("id")) is int and x["id"] > 0))
except Exception:
    pass' "$v")
	if [[ $v =~ ^[0-9]+$ ]]; then printf '%s' "$v"; return 0; fi
	v=$(cf_api GET "/accounts/$BOT_ACC/storage/kv/namespaces/$BOT_KV_ID/values/admin%3Aid" 2> /dev/null) || return 0
	if [[ $v =~ ^[0-9]+$ ]]; then printf '%s' "$v"; fi
}
bot_kv_grant() {  # VPN_BOT_ADMIN_ID у бота, где админ уже есть, — заявкой admins:grant: бот вольёт её в список сам, не заменяя прежних
	local body
	[ -n "${BOT_GRANT_ID:-}" ] && [ -n "${BOT_KV_ID:-}" ] || return 0
	body=$(cf_api GET "/accounts/$BOT_ACC/storage/kv/namespaces/$BOT_KV_ID/values/admins%3Agrant" 2> /dev/null) || body=
	# Ответ — сама заявка (список) или конверт ошибки: «ключа нет» (10009) — заявок нет, остальное — сбой, вслепую не пишем.
	if ! python3 -I -c 'import json, sys
uid = int(sys.argv[2])
try:
    v = json.loads(sys.argv[1])
except ValueError:
    sys.exit(2)
if isinstance(v, dict):
    if v.get("success") is False and any(isinstance(e, dict) and e.get("code") == 10009 for e in v.get("errors") or []):
        v = []
    else:
        sys.exit(2)
if not isinstance(v, list):
    sys.exit(2)
if not any(isinstance(x, dict) and x.get("id") == uid for x in v):
    v.append({"id": uid, "name": ""})
print(json.dumps(v))' "$body" "$BOT_GRANT_ID" > "$BOT_DIR/grant.json"; then
		BOT_REPORT+="⚠ админа $BOT_GRANT_ID не добавил: Cloudflare не отдал заявки бота (повторить: VPN_BOT_ADMIN_ID=$BOT_GRANT_ID bash $0 --bot)"$'\n'
		return 0
	fi
	if body=$(cf_api PUT "/accounts/$BOT_ACC/storage/kv/namespaces/$BOT_KV_ID/values/admins%3Agrant" --data-binary @"$BOT_DIR/grant.json") && cf_ok <<< "$body"; then
		BOT_REPORT+="админ $BOT_GRANT_ID добавлен к админам бота ✓"$'\n'
	else
		BOT_REPORT+="⚠ админа $BOT_GRANT_ID не добавил — $(cf_err <<< "${body:-}") (повторить: VPN_BOT_ADMIN_ID=$BOT_GRANT_ID bash $0 --bot)"$'\n'
	fi
}

bot_validate() {  # всё, что проверяется до установки: токены, чужой воркер и вебхук, бот другого сервера, владелец
	local had=''
	local n=0 was why
	BOT_USERNAME='' BOT_HOOK_URL='' BOT_ADMIN_ID='' BOT_ADMIN_NAME='' BOT_GRANT_ID=''
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
		had=$(bot_kv_admin)
		if bot_has_binding ADMIN_ID || [ -n "$had" ]; then
			# У бота уже есть админ: этот добавится к нему (заявкой admins:grant, bot_kv_grant), а не заменит его.
			BOT_GRANT_ID=$VPN_BOT_ADMIN_ID
			bot_has_binding ADMIN_ID || BOT_ADMIN_ID=$had   # бот, поставленный руками: прежний админ — в ADMIN_ID
		else
			BOT_ADMIN_ID=$VPN_BOT_ADMIN_ID
		fi
	elif bot_has_binding ADMIN_ID; then
		:   # админ прежний
	elif BOT_ADMIN_ID=$(bot_kv_admin) && [ -n "$BOT_ADMIN_ID" ]; then
		:   # бот, поставленный руками: админ записан в его KV — сохраняется
	elif [ ! -s "$BOT_DIR/tg.token" ]; then
		BOT_ERR="у бота нет админа, а привязать первого можно только по токену бота — дай токен бота (или VPN_BOT_ADMIN_ID)"
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
	bot_kv_grant   # не роняет развёртывание: сбой — строкой ⚠ в отчёте
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
line((base.get("admin") or {}).get("ok"), "админ бота назначен ✓", "у бота нет админа")
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
bot_extract_bundle() {  # код бота (vpn-bot 137315e) → $BOT_DIR/worker.js
	base64 -d <<'VPN_BOT_BUNDLE_EOF' | gzip -dc > "$BOT_DIR/worker.js"
H4sIAAAAAAAC/+S9W5McR5Ym9s5fEczmcDKJrKy4Z0SBIKZQKJA1BAEMqkD2DBqNiotHVQ6yMpMZ
mQWg0SmbmTVp12xWkslMMpPpQQ960IteWrvbq9npnR6z/QXgX9hfou/4JcI9IrKqwGbLxkxsa1RG
hF+Pn8t3jt92d61yme0W8+VFshqtyo+K9SxbTeYzK327YmV/NrDefWRZk8Lqf/xofZGy5WhSPpjM
JitG3379a2tmfX7HsgfWkq3Wy5nVs61frG3fcXq3kS+bz8qVtbbuWM978vXQEr/2G88HjWfPfHbd
xvcH8vkF1TNlK2uCWmz1cImHGT28Pp9MmdW/tL64Yzm261uffoqUn1vr0ZTNzlbn1o7liD5ayLQr
Et3mj5Nbt+jHpupHiUJlQTZ1HTXeQZ3WXeubZHU+Ws7Xs7x/ORit5ser5WR21h9Ye9YlHh9M3rBc
tQHJHbx3B1S4pNrpJ+/KjfXJu/XzyYvN6e2PNvU45Otlv2RoQF6KdtZt4bVeJG/69lD8LqbzeZ16
UI9ArlLLFNauFYW+bWtJzptJ/kQkQVIvNFJetFNSCiQMRTLiltz6QuOKc3pCx9HPfMMZxPPR3XPx
2x+fgiD6t1NVzLlRzEVdTJUVxVzIbJyFvIj/e18WWVehirwwijzdlr01OrwYxxyc5GzevygPF/Ps
fGjN5q9BmfvJio3wsz/QREemIaZRP02pEZVqDeDi4R3yfz1BFP6vrclVPikKcyz61IYdVccAQ+Iw
rx4TSv95s1rf1aq6x98c6E2Q9NOT9holhj9RkTW9ieup8IEcG0Eam/871n775niwN4vJ8u2PHRIu
zY0xcfi/gRh87V+77qHoiGxiTZtqoFtlPtCp4GrF8X99v8kGvtcu9A71rVFupLWPFxuI1u9rPDNl
xarBM6rMHVFkzTPmcFBONRyHzZrkcNxrfT0wByibThb9EgOj67IEDdpfLpO3o2I5v+iXeuWJ0tNf
wNLcxWM5nWSMNN5sMPrr+WTW7/VIzZYmH5RZX6pLWY7UyOVgtGSLaYIidj/dPYMx+TS5WNzuaa8/
F6+nK+PtF+LtGb2lqj7aFZZzxabsbJlcGLZzXbLlo+SC9dd6N2d4Q5ZwPSomy3L1kp6HZIgS+fAC
H6Yrtuzfm8+nLKk6aKEhaP5Fnxvc00lOlmI0yTe6kuKUXY+oal4R15L0a2P1/4zSqy+bAalGUXlk
Dwy6XSTLV+tF/1WqCQo9yDou56jb1ioVdnMym05m7OUr9jadJ8t8z3qVwiwt+vyjZfWXxFZ3vrDw
l7/vp/wxHa2XU7TznbVib1Z7eKa/oMhyuic/btDS5ucsmU7TJHv1Mk9WCb2mv9ZmwGujfzfUpctk
aZ3IsQHRMxC5rMdiuc5WYH02u1S2f3U+KUd4Rlr8q+x+Ur6dZbzG/gVbnc/zoZXO87cqkxjXJSsX
yJa8TiYrq2Cr7Lx/er5aLcq93d1kMRlVLDJfnu2m89Un71Rlo3uPT16ePP768NFmF3aI17A5HcrS
LUu82bN6Tx4fn/SG8u05S3K2LIkyvYP5bMVmq52TtwvWQ8JksYB8JDSYu39dzmc9a6OyUcP3rD8/
fvxoVHJhmBRv+7w3PMFmcFvrE+Wt+kQdHNGb/mCEstG/Ph/A/rvNQObinEJJRvNXAxATQ23N2Gvr
cLkEnU9XZ1bVvz385ClzSOlysuCMB77mtZSrZLUuN6eyWMlmPDm+ryGUcmRKBqyVnSdgCMEWimer
TJzIfOh6lPgbVpbJGevV1KXcLycgLy9GvuSFyd+LZFmylxfznIGyX51887AaAvD7q5eLJbucsNcv
57wLfDwm5ct8UibplKFYcBmryU+a5O1LIWB7mqBpxKd+sXyykv26EC0+ym/SRconu3iCxNd1U5bN
39f1/AuhAVTr+//1/X/+4X+03v/f73//w9+9/431X//mf7be/4f3v8O7H/4W//v79797/4/v/2Hn
/T//8Dfv/+H9v8fjb374N+9/+/6f3v8D0qxGF2z3c3xAIV/cBVMtV3f+69/8nx9Rx/vbiXjGQEMi
ndmW/+2Hf4W6f2O9/z9Qwe/w/3+PSn/z/j9bqPF3P/xPP/yd9f73aOk/4d9/x7+LRrz/B7SftxRZ
f0dPv0eGf0DKf6Q3/wGPf0udQyZ0xepX/aOyURZ1jUr8Lf4iwWBE7gxLz+fzV0ezYn51P76rE7Y7
9L+jWioXDf8nagr+ef8fQcC/Q+t+a6Ey6so/81ZxwqPxP/ybH/6t9V/+rx/+NZL9LZLh23/5nfXD
v7J4l3+DtoM0P/zbH/67978ZWe//F4zI76nc3wrSUTZ08P9BQt6rH/7WEn3/4W9o1Kz/xgnwYiib
98/UbXz9/Q9/Q8X/FlT8b1EOqDbgZXLaodb/KFoP2qOYv0dK9ACtVAS0eKP+E6/o37V6NqrUezIr
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
JlsaFJJ9EvPduuWarJz4bMx7nvtlW6wsUBj2QsOYcCZpQ9qX1Q9HS0d0YIqtGlDbFOXjsbC9WPar
sbg9VV2bCUrbobxa4nykmQF9EwlSc70G9dbl5eqI1qQ+I6PR2udR16Kwjpv08ujg+LxSqu0Axdt2
/mvultoHjUalUt7aaVaqtWatubVV2dnfKR00y82DcmW3VKm1Sjs7ja3tZnO7VqqU9vdbja3qfrm6
u1+pbJZrjdLO9u5Oq1or1Q4OWu3dzfLufrV5UG3UquX9aqmyX2psHbQrm+1yrbpda7fK1c2tg62D
zXKzUtts1XY29ze3RZ+bre1Wc6tdE0OotHZFD9utg6390n67vdncF+9LW/viTatV3dnab+9vNnZ2
d9uNzUZrt12plcvbzdp+ud3aqu1Wdra2NsutZqu2uV89aFZKpe3m/k6jLIbcLm3u7hw0IC9qubm5
eVAV3eyKD+3GTvugUmu2N9vik/hQERUb1cbBrii3VWmLAVdKO5ublf393dbBpliT7e3S7tbulpjH
dqlZ3ay1ao395u5OqdYub9e2mqWdZqO8UxGjqorCYpJblVZ1q9mq7requ63t7UqzvFNq7WyVYA23
d6qNSqtZ2m5UdsTEYGDtkphwc7PS3D1oVfab++2t3c3NnfJ2eae6u7tZ291uthq7m1uN1mZZDLay
Vd7Z3Wk3SpvlUnlzu7LTEqvTaDQbja0dd78lE4QwAclc/zdM/P8KJhpiIQ8aB9Vqebt0UKptig6q
1QZMo9zYP2iXm/uNrVqr2d7f2RRfdw72W+2SqNdqbItGNg9KW6Xm9sF+dXe71N7ZbGy1yq1ac7ux
3xZrvtM82C/tVqsH22Xxe1cASK0hbsHy7kFTbBCOqHFQabXETpUrbTGyrYPdHQEnW7WDne2tUmW7
Wm01d7ZE/2Iw7cp+Wcxte19sVVMAl9jMze3txpaY2lYTFnpnp1naF5tR22qJbWhVaqLB7ZqY5H5V
gNTB/uZ+u9kSYFwWH2v7OxUBtaXGbkU8lsrlxnal2ixXGts7262tg+2dne3ybqNc2j/Yb2zuV7Z2
d8UWiXXdarRrLSjZEN3sVGv7ontRSMxqp9rabTYqjQMBmS2xSvv7zYqYfe2gtSOAvQL/Nsu1cnu/
BYewsrPd3NytieFt7TdLmwe7YoN3t2DEuwJQxDmrVvcFaAgI3dwXAH9Qbm+JMyaAqNWqHGw3xGaU
9w8OtrcE7AgsLk5gqSRAtLJ9sLlf2mw0dner+zWx9zs7BwJkxRHd2Wq397cPxDFuANi1awftWnWz
uStO41a1LI6IjxM+75YRxLm+ZE5/VEmcBTNx8OycEuxVS3n95qR1/OL34hVmqPtRcBw/nhy9PuYv
ZJ2KelY1qubF//G6dQplakoFDq/3D88oQd0N8E5w1eWlaTWyO9XSdgVu2k91zF8dcQEv8CiSOtWM
6v5wfJEu81GxNrBOkXiv31IeJ/cjMXopH8H2130nhSPax5ONJ8DigOdMlsKozLrD93nJsFjG0ujS
8phFDAq420CWeiVobDUPngmyCZ76Tags3h0jNRtBIntd7nfkb8IpvEl3MHXFm1fxCLLrxSDglO43
lE3+TYaotP3BLLHkqLSgx/MLiKPnJem11f2fHNkpjKA4warAGVIOAbEyYiNGodQjALRFA6563fkY
bC7FT54iBVZKjQS9ka8vbx0BWfBgRp6V8yUqsM069UPiyXQImPTCpBZTzh6VYCH0dhaMIXlAY54K
2JaiARC5s1wJybtWXCGw4NV0O0UrSR81iZKCAZjJB9qTOqg8+lhUKx1LV0THYqXonDebV95eSlSu
VAg0eR+y7MRnyrhIgWjWBXwBbNhPXQ1uocBPVCGAz6NZnxtcj/ovglPkbRZNplEMAD+k+0uqUcOS
Ne1Gw/HHwngKgtSJ4Gdm0tKBIiys3sktNEXlX5WYpZauTdRKWHu3EV2ogaHLDKjcIErCFHOs0wCj
7DI40EFpAjrIf0/QINHlvWFhwY41iJJcicfNRIxFwkpAsKRkTs9AHxQSFxmfCxJlpt1yYYwnX/IV
tOVeRniUW+7wwfrKG9RUZ1jKl8rhpBbK8Hw23h9cAS6T7gX6tCQVy2tMXGKlUaQ8QrOd0qeHd7iX
RfBS1j4M2QtqoDgbS7F5eStXnIDjN8TQFSUypYzA1OSUAy45OUYtQFMwHBksRdsdX6MkHV9aDSsc
K76rwf5FJKZA5Tulh3fi16LjKOoYHELFG7RE3CgWN65yTylBBUAXzmPSnSYxzBfeoJlGDgRRCN/c
XWjcPx5/zIKnCKzzZDwSu41hs+fDObOfFgcUPPAfR+WRviz+OO+imE+6mcg6lqoCvfAe64b36MUT
sSHq5xNokl8p+Po7fKk7lT9+o/q0OovMSOSPcDnmN0XtKUC6GEh/GwQmuYEQRt/etYoxSWRueniO
W3J+2QknsWAnCUgtxd9WLQc2GdlJVIgqI35MQJNTGYHOH+D1k+//QicuK+P/TNz0SvgebOjLI0Da
9CgWGHqC9Vx+Fys/toCxhy9DX0VeXhP+McTDci9nSGKl3MYihieY4goPxvL2PP9q7R6lfoCxXmWk
PUzjT9rSVRODIUG6oQkZr6GVm4rRgPj8/kvNbgTKdz8Fxe1yxjCl9WhJzTMFKMkomhg4xDblHaI+
Xy3/LK0LBxg9wxwVAeqGdMGvP0R8IQAA8fWTyJrvvWgGEqSjZy20tSiIf2ldwAt0lgz6sYx7wbte
vJ1XSuUqf9n9tKC8n4CaghQEelwBDh7RrYETuDKH6YodpNVkmB44bSK6f0uaB9TnPgkGe8QvqHsc
HCOxqxuJ7qLjUBOfML68i60Y4QDmKXQZXOUjQQxMHCbpQfhUwLl8GmkoBG4JxuHyTwRT+paMcx6p
cB8GyukUmSi716/BV10y/I1F+MFYi6fiSPsSEXbGjlZBODpjMXPpVJ9ePrlRl3KjcgFCEGNjJJio
OoXCC2BBqvR18JozZDFK99WVscSSHQegxHl1mbPoTY/G/HzCsh5SV8pxKUbf8U2ezkfP40+pN6Ei
3MRny7jPOdFo5ZdyodZTRTmfrwHSv3TqwheHrVdn5zKhOMj9T0+fFSrFUsG0cV4qljMmE8Z+49Ur
tKvasXJgnLSet35/vv/7sxZI3SrRb34TVUv8E9mo6o8VlYNDDcnyV/mWHDnQwRQ2+lt08jGPyuQT
lYcl6xXpOOkdEvisDD7zAqSI40XkG16IDCWeIxWiUwl8m+ic1q6bKoLmt9r8wUSt+1Y6HrA3fi67
b00eTJmQlbobw7hoiDpABD7K+EayrmCxkdbcQ59cqdn3eVnK9mPMdlTvlnQS4AEJKW2sxccOQYqe
W2FDVNDDPlp0SbtoaU/Sr5NpAAasgnBfN7HYeBUlYRoXxMB1bG3xu6VblduAAafgMmVXLeYuFU2g
gSPE286CZcpOtbQjSxTE0S90h1cJBKmekrmMQHx41vt4JyeCGZRJObDGqcIVDR57w0r1Jf2oaEfC
8alkMo2xNGc2m6c+mUps+3QGbL3BeHPrcCAqmJ0JnGGlVDabzxKb4cvGpQAj+iIYQXZU7erM5G5/
TnZBcpYYWhRCZPk5nKd6fhjjCgq5obB4nO8PErT08aAAGApauOGQFRUMgvAJwue9SWbFDMFVDQm3
SdYa5kV8Jfh2FrnNyXigJNXoGuMYssO8jxElZB1nB8rwqapJ533toaHSf3I7UDvTirhBtJ9tatWD
w9PmkcC3zTPFwvUHiYz5FfdX1z/88dXRSQuIWLvZ1v7rH/0cAempdeUUKIWuzD+vcux2AoH098ez
6whodIguNBrPAZQhuFESYzbtgQw2EEHihOgivgTM0B3dUngkoI2tvfe31wcBP/v7mWi7NYIEMUBG
xfgLIvfYd97i7fRBJ8dCjSaTeMTCfqbCy3AwigPAIoYAX7LmqrR2B75ZFAHct3bob/R8C5aDe1mQ
DN99F4W/l4u7u05jS6XwMlYNOH2I5gLBaCgiGhUSnXeCSS1lGnD73oAGTWEJ+Pylqk/L/YhqGHe3
Ml80KvOEkR+51CiJnBNDi0O8dS66GKgTLx9tvCjTtkvwA4ZVIqdMAKJPweQ96hoPui7gVABa29gR
6aboY/cW7zWVfdZODA88leNiL83sCI609aAFXRotQkDnPT91k4rZzJECOo86H+TQbe8MmbhZ3ltE
2lDc5bTIuibjvOAD5DbMxrQJ1rc9B83KO5FPTVB7RdvtUg1E03S5Pe6B61B7/jsMlfLkiQlbK68C
RQA+eixH4kTklBewJgIfPQr5qlm4xnIDjGhxnxazNlK2e3/i39iAop2+RTGLdM6F7rOFddUZohQ2
dElQZS1Z/jRzfHz5jef4vIYuyMGoiP6KHAO623c4cgbJiHfvlbNzbOXg42PHM9YimxQxrzaNQulY
jrQpweQyAi9geioJFRl7mWQjXsIMIGjw5KgrsSsTlcjMHrNx1O0BGi1Gz8bzROx2PIHtERi2L8Cd
4vNQUxAGtS7eXsyvIMInGOuiSfREUdNaWHsl2Nvu0CQW6Mc9wJ2imEBhKvuGTvAnaFz4BJjdMcsW
BAgMUBLtorCfN6MXg82kFhH4V6FJc2H4HTDYtndtDXDHUja05+wbxgb7X59q+zVJL+/t61eHL49f
tF4KwqR14BNmXuPKQciOF6zv4TATk/rNXEaCO1jejJ1Pmo9xkTbWH18c7TdeaNG5F4o95OqjTq0v
0TbpE1LyarFkdeTbkqMUrHJeIy+GxhsYpBzdebtx+OL1SetdagKBRe4zlkBzAG5C3XRWIL11HyeF
KJXxfGqo9jF6xwIOuB6DaBANDaIxxF5GakRQLbPBENGMPsagCxLFJOWiTp/rhc5oFZ6RDQlpTBS+
5yfAhvWXMhNIXY1CE/Dx/YM4WdZqUwugmTP5qikppJVYV8tdorpsJasIEarnXJUwjCVXo4okguYE
yu3PZczzCp6khMW+X/itxORAdzJ+JQwgr2Ynw8AbGNX0GhmDpQ3UJKOwsLq8iVQK0K5085HsteG6
ifZVEWk9lutbKW6nnKrUxpJ74L7ImN3MYFMCqwY95YLAHSz+GShaUrrjQWJfAQGUHepMIe7ANwt9
80FTZ8CwqSVcxXMbXZhhs02Pi0igQ3En96P+HBAfHlm+/2rfJW+O8XD78zig9+JCGfTgx4R3dlsY
y90iPiRKQZKGgwugMO7FGby0bTsVTfypF3vLcsl+q2WQjVH/VNBN4lBojsgKCxug+BmlyUTALgHy
2KfAH7sMRECqy8MCaaml4Rv0IOm8a7o9JfEtZ53AfMLkqV0xBLcfandl1lu5f4HV9WPtugEvlqBA
vuE6OK/x+Q2hU7Z5cHSkl7VKS2xE8NJfxnJfdLI4AMJ7LIcpDp/TBrO7o6KmiGFDwMytnKrulRXF
abCSrqHAIRnfxCrON0oW5JnJMCGTdnY089Gv9uzQGmQGI3MnkdZJB2XBito3lSfoglu9HhnCDmxa
/BtGR8FMo3VMTBW6D3RWEMLWgWRPehpuvi8+ZSshc4AeCtwYbkIsW/QRuKyWZnmyLLTrjhosb2tB
6gEJlx2JmueIYqEfPlsbqYNGKGMlJyAWxXPQ1LnyIHN9q52eKxQqIpduh2Ebk+qKMtY8Jw5xhP1x
THYNqOsGq4yMZVfBt7Tb68WT2TMa2LIBp2AArsqCzu2lVg57ee1px5Kj2U6/moiGlS1y/1m5FwHP
WnsEeev48Z0PnLAQr/Gq9RPEU4d4XG4oQSkMw0DmNCVfiqTxWC4oCyspYncJiWuLFZUxkRqYc4SU
nAfT1dHqOnHC0odkFKtmszCEgN56FlMG90zFNdc9W7pHtVIM51ke+SY8PfPP1I7EFPeGv9MDr7uX
hEnRxG5JG4oTjz3G4LMXHpOkvNJtsYlYou6Q7AJ5qeIFHltsaD0xN5hQC2wW9zFhMV6IIzJ0QXIO
rBVQvSo2LuOEu/INqSkkjibA1MzqnDvHscmk13ol/cWQX3A+Kt+4GEM8nQjSdaaMLtgrCCsOTeuY
qMpro44x0U6T62P1hgryPFqWPFll/QLEJLfraREC2nCYNtpvGeFSc9CQSOdqPO5f3MYquS1LtCM4
4zkFLRmBWvIKHoui0iWmBAQBYDT7OOjpRJ+U28cii5Xa/+nTx+yNJg6ty02WdUMxWq0yOZwkHRVN
Y46Py62pCT5OCV/DuCsdmbCs7cAzGeun5XXvIBiJCmV/YWJjYd0c1kxgjRzAtzeDsitmcr4yW2WZ
DKA9O/HSmrhS6rmxEoj4lzDn90yoRAQJzzrwV69fHoO1TJXsZA5a7cbrF2fnZ4cvW0evIR5SNeZJ
CEbj6U13OPhT3DbniVukS5CShs3TwQ2EUKDkwNmNvz59Bm6Z9Y1BPoLd1B8eP3q4ga8s4yd5cJpw
utCBXfy1YmRAljtA12/wkzpobGRkj/6ueDnszsDGrTvJhiaQK14OhgCW++PxMO6OtOEa9WDb+gOX
Tf0RffTMxropjHZmNDaokuEiMBex2kFWWqWxcfSkHwfizAMlNJvOgZMeSd5jnsSZYPYOSUUDQjKg
408MpiTf6LAsok6RjTPnRehUOvvHch+kdwAWhs46crMf3uG7RUc5NsCUM7m9tYx0H97BOPT1sDBr
KFZFd+CMdUGeXFRfjXOhR5xqnBvYVVwaOpqBr7iw69obp08ldR4ICzI/EuRWsjoPyVoCdvSg+jkQ
WAqtBQAxCBooIbN+ENieDW5iDBqk3DAgdfSUh5Ghqq489TwgScWqqACYyWYd7IuEq+4zy4gElKZa
iY9kxpvx+H00HI90DsKHdzfJQsxA21IsYD4E92ROrOU66gzg7mnjOcA3b2gd1NxkYFQ4luJSveVk
Fc7oGy0FzomTGHenagL42YqXL2iHJp1VZWZ4bl65EbLN9QJjmcyurcubXT6P2U3Ebh+sIz7iX62G
n3Sn1L+S2kDuQm2RGczUZ1ov6oKqPagtEWuwrrH1lKV4RUMVrKhrCvLqFi+8ogWrrEVloZwqMUmR
2cKCCgNFmaiigDyJXXXPA5YaqBjOksSCMcWQeH3VKmIhNQhIfYvJAfGzsq5zWjBgIigxu2ReSvpZ
W4o4cwtaUIRJKRhl6ss9+dfosXvf2gkt0wSJKrExUcJrUC5ctxUUF2odKjPZRUMrDcN2b/ngfBRx
z1L4sjRnmMHXPJsEvqzMItCEa+aI7Tgv66lGkQvblILvBNl6ja8oy0DAFkZTiOa8GVPFPacQywEQ
Z3UNkx5bXChTsvh+oycuqihCyRQcj/bRpMkkdLVJb+t2MWmtxyiNN1I91dyMEOdLtA91SE1TOqNO
0ugqY97ScpjpS5I6Jb4yAIw5U3i1NPX5DC0J2EwIuvBDnFPHaB2494azUhAOKAkSKGIud5lyVaZa
RXqPjO2iDv7tAI03mNk6EFnLnHqZrDoQrl+w7HAd8DjTDEuhQU1GNpcxu263aOFSGlwXrDlu0NYD
dL0Ah9FFt/cejdsoEW9C2SnFZk/mkCVxTJmEgXMF3TBi1xF9ii5jjWGTSffjKCtbD9s8W0yrtxaZ
+FPcy+SDYTNks3ZUBa3fhKTZonhXrM2HOEKWKU+JrboRWOzMR0OQKnfE7zpJljvo/a58vtQMoGJ2
7YHfMeySj7BtncNedAqGEtN5DFROBlvOOErZZH6R3CazGHIhR3SkVfLYTnI5m3RgpTujeCb2/bKj
xqgqSbePz1hm3UTKWmPyw+BCn8xFT6Ch5zA0xQzeg5kKKykuUMc0N+4tBwtlLUsZutUa3nQ/HSEI
aqt0K7cex00oWRo+LeLJPbxsQM7x2MmAoA6spXkOw6xVDxOYg4GB0ZDIpmS32czzwxcvMsCIIg0q
b0xVSCKXZfIDdxrdfr8lmMgZhK2EQCjZDA4C8mFeIOK7Q3ONuoSvXFAddCdOcx+jjGYgqsGsLxAa
/Y4/DWYCG8zm4roDQhNjq0AwdfDAwNOhrgqpnBsPhzGqy+TlpvJ1Q6J266JTfAdaVKurP/40O4il
jbVCsUDfvBeYmmtP10+Yruc6Ht+gITEATgEbtI18eEL16AmWV37jRT1n0FJO57FjHgRNP+Ex8Y1K
4A3M+x0YGsqZFumv7E4bJJXy1GMe9wKm4OyYElRP0NgU83vdiMsXKuWtZPAhTdWDtYakbsI0ssX4
ZyiYnvUHIz9RudbrCnxP1qPZMKUDi6fhGdqyWDC+mNQg3SRk2yG22q6KLq6ElcCXNdVk36oFNj7W
C77YgYTrOIKg2Xpa/nU6uyspZJt7Fagh+4YBMJ6pLFt2jBOZoR+ZXH5ZUXGUqaj4wYvK3ZHP79zc
G58GLPWRbA1eqmLroVOtGTN4BIM4CFoHNoNro/AltZazauErVYsK2KvmYE+HQuRKT5f396cxjW/G
H+JlGNW3eSEj2UZ01jzmTKdj7QJXXgdYrzrQkR3yLatVNmsQ9bhYESdf3OVdaqsD19gpcj2dOiG7
CDkk8fNjd9pH7zNUDkBuv5kyG4Zk3Yzu0/a3shbG+spHkh6eDogJIc2ywPblynaxVATvTCqDeR9W
MMBIWirRZ38wFa8Ls95kMMkEwwizmGNaCQBd6S80qqJVQL6jcn4KTb4HkvQnS2kSvKFcVbnSdwEc
ur3rPNLt86trJLrJ7Pqjzq4trZ6Ry4yJbuGMVp+IdUHcfASPo6lgIf/X3/xn/UaJ+/LqjWxtGveh
BXFlYnFoValtQOoIsJvgVl6PJ/Bmiu5OkJgyiT4KitA1p/7D/GbiChm0ipBERk8eG9H/kmyfM6DY
IeTwbZQMwH/qegBTBl+XBDJI6zYW2CnOMOkEzBMIbsAlt5IHehftwBauU6Lk+ufIClkUlg+nVic9
JXGjKiFRyp3qNi+dCOuqI5WAj1bmUVRWTcsWtDgNStk5mLBEiD0aRafts2NNLTKwkJxeMWrCvkaS
g446YC+c69juO4J6d+VMp+IduWNxls6Q8xmolLHp7aaCINAjMIkjkd63bOuUAAyPQtxXZ8Eala0P
DPOVFr7lei1ay6e8AGqwHJE1MANa+Z3q/bpKSERxe6i6RSEzEc/TNaRAEHlwoUJIGOJnpTTGCvWs
7QfqkScwNYYhtjVQWLRp8KeSmPKi5i0zLHAutyWSi8U9Xf7pS7KBmSFAq+jsJKrTcQvw7BK3yXCB
kQc9jspxjW+sdmoW10aW0AirvtABBbW+wt0aW+Kv1pjkkzCuuM+voqWKjbWUG1rBwWWg2TSbt8gh
4H0VyEhcVaPkI3j5DcDOD2xt1XJZGhCpBdEfGXn5wJBwYTmWXGvwb5dGoIKYFghGcIaCkMaRiEOC
H4rKULgeSW8IbvoJN8zGs7Oz4wLE6uojMA968cagOINYF9DDWpqy3ng+JI95iVDgyn54p7Z/AepE
AQALSAfxE0If3k8Y9kZsqkNr4YUvEOC8fzkUuOd7QsKHxxR3KimCAIVIAHm5mbIg23EQIf96RrcH
LJbAVlH2bYfuk7edXLFjiOk7serzRHDZtLaL9MiC1wO8ZTYm0/GnW+V1JdUP1ipCIKtidHgpaYIE
w/54w8+b9emBa/SMJgMoHs3sxDrtBeaTldPo5KAaBsrK7IWTv6+/Uw/vYOAL8Q31wHlvVb6G/o1F
aVFBBOqRE1UgH6nQAXU3lkCebra65EXtMxxUrAK40arZ1JbcTjQMUWmon9GT5jHlVwqOQb/Bnjqb
eT25mopHQWlnPsYXNIqMNkfQTAkdrrPx+1gHtrOaabYLjV5PnNcCEUKFw37GiLp5dRlE+FC5Lyxv
5hRtF5c3dWri5iyccXexMTlsu6dL1RN+ZT3wOu46CEJ4JmAGHlLb+ytB3hQOTEHWNK/O40OJa3GU
GKf7yxgQeOd6Npsk9Y2Nh3d6FxWobyBMqy1f8FhL6hZTrRbFtp7qMB3kRCa/JMQGo0V4qQwuIN9Q
dRtZS0ThVgMxR7WEuRlDn2qlKiAO68zTCgmSbzQjbQTupTjGYq2BkRR0LK0+veLYQNqJq44gqelT
xwoqBcejLYSkvbvARXirKa89gXcf3jlTWWiEi14kP6m1VKjFZv/kISZryiyP5KQ34RRFapLKDIUh
DGptU3kbmleeaOrH0Zt3yO5IPspheJSPAwkx7kzBvGS8EbdDZpeMInpMtTfKNwLra6bqHXQqfkP/
efr2TsHZN3LRwaIFaxM37Zt8KnROvsVdOUuUNVATmRCAy9afaoWwxo70BSRq5pMkCs04ZLo75OZh
0rCantZQE30Ox2cYPovfk1k95RBd8xB0L1PB2iYYjDKG9XDalnwgctWi3BJayipv8UCOMpBdVoqH
JLIbSGpIGOgT0oIquIgVT8TY4BDB7K0yF++UN+OqnTlSWUjboTWMXbvPjdkx0S4n07pqhVsveS2m
n67jbpIIVsIWRIGOGmIZJ6BKnCjfIJP/mPZZZ0sjmgur4i+l4q5TQ7RDc0i0fhe9H4DXSmYiu81Q
N/Czjr+U6t83KKzjUPLa3AnBsh5VxKpKC6S0Odobp6aH8qBfaXY6ADTMTz/U0eTsiyaoQBVUvvNJ
AFoBZBrDYZbrXJg6JkHUuOcnYaTyoDiQFuCGyxvPEE2WdOxf7hiqYJkcXikorQ3A8RSJwCzjVqBw
LroQr9+bl8ySlQxKYLjFyTy5lp+0fh8H9EgFXgZr5hcsUsTCioxJrhaOjwa2oCc4vry0pieXC9AS
DSJnkkYhidPLQx2l/BO1xVh6zjgYohHVQml358PhPu5iNh59sOjXMUu23JtPQXBzMEoOqaC+U1Ku
kLfzUq16gP9uRvCnVsWHbfahhO8r+G8zMq+qNXxFvzfxd5k+U1l8VW2ZotUSfd6hLqKDV6cZva4A
zXoeArBaI3EDtCdTaxpQyIncYQOWKMAAKoCMX81vLmJstNh6dXby+/PT02fnx0cnZ4pJl+N4I/6+
4yRUYg9JIgMnTDsLtO5hk/SeIWu5evn6tHXCn6HQ89bvWXfmYpSH0mh5xI2E+vfMxjyZbgzHve5w
42Iw2vgwGRUkDhAjrDzZ6McfNjD23c/RTDCuUQFUBnfaL4ar4ikdiuXVMaxHqCUixY669bPlSlzL
BTznJ100fpxKtZc0NmdObFDAil21ATGrPD7WnoUHuQrG8N99etU2IK0AuI7+09ChSvpXrpRyC1sa
DtJZa1lJxpumV6W48RYeQ6wKQmDBYwl8DmhSkrDQec71QccQvxGNazIczHANBI0FgmXBKGTY3GdX
f8o4GrI7aVByQRsmh7NIU5nJacHoUJzNMGFQAompkW3ZoxsDfBxGTikDMwfURmvQuvowM+/zvJWK
TdRIS5rBn2LVPEOtgRUxl+KwexEP4U7Us0i6o8FMtPQCvkhNsTa3BqRA73BDxO4YOMZgKsZJ4s3b
ZOPtWwFu4r8C/Clfwr/bl+8ebVzlo0whE6z1128ndy8W4p9Xi+J5AcrOUwsXdEvMaaPw6OfCo4f4
IcNXKbGcNeajwR/nco4q1v8A+OsrS1zffY8u2hu/if7y/Pz49Unr/Dz6zQaex9OYpyFWMaPFBWga
wupg2pKFqPkvxoJNbHbRMkbhe1z+ikoZAEsqM9QaNgjbuO4mWSrrNKRjQ9BXOy0ysHl74s8PIK0W
PyAZMkeaPVCqPI46D++g+0Xh4d2AMix4fUPJtJ7hm3N9sxYPxLkvjsYfszlo2gDezeBK7NjIAr3e
dXcwao5Hl4OrOUTZ1OdINiv9Xej2+N3h2fmzo9Mz4BDhRfNZ4/AVXSXWToO+nUQHXnvB/kRzXj/y
/oENst4dN05PwzVgZBC2qX18klNpFY6aZy1M2Z6tbL4pFTbf/VwRf2rv3r7t/1wW/8DfN+XC7run
4ldOBhc+PP5tTUcBump9mmQ7f/3wDptaZN++Larfubvq4qGVgWOQHB5/qGVtWh2ak9LZnJNOQazF
MWiiHOwl5QXs4rZWWoIKfS6KPkez+ApiFSG/B4FBoL6AQP37SbS1uVndDNxt5rYigqkmiS6iybYM
iWUVIiqtQURV9PZTY//hnT3MxdtP+/v+XSlr7hDRRjcmtdvhiIPcCxyIan/0oEnvffsnsuIZTFBW
m2QsuFFfgeMFCx/+QfBB88uPGa+3Z92kPZjGH8GgxuuWjeYb3bCd06Q7mneHDQhu07zp02UymAQ2
2QYCxLgY9YLMWmQvGocAyqLe6vZNrMRuVEIvg1Oqoz5EhcPo8NXx6zMBJIUJaNCiAoTfHEwWUaHQ
x7FJ6XxU+EPUaDZbx2cST/Xjy+58OHObFqtIwXzIfIXaAmuK0W1ktSeIY7Dh7E066lK3Fl4sVyIv
3/jjISRZGPYPJxgB2mQZ+UaeNCwSotkIJvFzABShbscIi7EDkHrJVvFFeqv4eWmrK3ZY0nqgUFOQ
COS3QqvmBQLXdDyeYXKSZN4fRwWx11rMKpnHIVwpehb0A6ri9EVNemNXErv1mAOy5nQ+srOSs8GL
f9cgZt9v0znFyQJYBxe/+wKXvCUFDMAV/aZzB7qhhQHbpgTbh3fQk9z/hc1a/OzUMaBu19qLFp13
5u4Vq5Sjnomd9/o+sPuG8l7PaOMZGareao4aHMUzciYtTEDwBaZioGD9EKuRCyaj0Iu+Vx0X8NuT
aCOe9TbUyw0YQlL8UPte9BaxMVSefFcODERdvzge6WUpYCXjMJLwHdcdxuGdaDpOyw81Gm3DjL4X
rIMAZ8G0fN95x44arbG1xNBRoSCIqF4ssAsEbrf7FbVW9erOmM3Xma7HQ1xO4+T6aHo6GwNBAgRY
G96ANTO8AVdROCuKqiJ4T2eGdQOumUeUjOdTsKfOYI8ZxT0I/lT8zUfEsPUbs3qExJuyzVCSZPug
3SRgHhtrnbtYAKV0tzlKw07SBHm2v1xgcFRMjy7xR5cU9UOeZNZ1HM4iRQ/MLvsKIyi2mExmlzAp
FqodMOqCuOp2xNrAz7W2LxyymHL6gsRFbYcTGpDaT4x2kctHTDYk224ZAZKUL5VM05usf/kvCZmq
smU+ChpexzKakUQ4pBwNSvDjy+Hg6nrmie+1r05YxG8RHhfitkhm065kYGdGAyxFBl1UXMI9c9p6
0T4/Ojn88fCVYebebmhHe90x2cZkEsHgFGJpn5kRYCnwDlxOG0WQEqiJCez1ww/ft45Ov1clv/0G
hUGi52v1ipqaj6PJYBKDCYNutR9hm/K505tPh1HhMjl9ITCEGI44dtWoMI5kx6JTkEtEGcn9bPSH
Gw/vcNKLjLSyyExvosL0klUBVHDzvj+YAu1jXqsxzAQPIC4aVr7w6U+XTpeqMMyKfWIir8JvNkBf
JE5T0UxcrIue6vXNuB89+hQFF1EtwGh8PZ9E2AtcCuEFD+3DcHyFl8FeNO09fvhU8KKTxw+zej3F
ct50PxVAhhbtREp13Z0MioPJ4PK2OJ5eIQ3dux7n9iJeTe+CaaC8GRV+Fx0Da6h3QowDBOhmO6LC
sygjWD+47wpntxOBXLqTyRAsYwXgbvwhGQvivNCPMndv32amPfFP/eG0lxd/BxN4EP8/xF+LjEL3
33s333dq02Hg0elZ4+SsdQChD97Ja+DtKHgJDLvi1zWdmfFkZqlxA9JVrY+CslI9iT+1yyC5UKq3
qKN6g79BvruuPNU5zFifTnS61HSnvFtZR2rqCU2RrtbCUh3mIaMWcYl1VidNnG+JRhmGLXO8vc0x
PROclg2Klxyjhe7bDNEyXQDHzLUySF2zU+nNgKYPcoI5I4etlJgc9kukkdP56GjUEjQ1bZcgPjgY
SQH/X50evSpiZsw00YUNd55E5Kkv6LcasiX+8JYL+xVvkfcaVmrGegqof3knILshIeb91ApiIcF8
JgjpK2Hcgu8pdyf5hityfKAOgg387jD6RGqZgCdgTUMoExnaxoKyrwBjwJcBiLXHU8YlWxrUm75k
7RxWWvN4CJg6kKMLsiFLttGBQOVUROD1vLhSwAh2gh47wKOD7+hgehP325Op4dKnPXuNLfOkoCTw
adTBw13e9CREO5KuiwzxKPFEydUZyhqbKJliiKPq0W+bpniIirRoQE4hVth7SepJeUClVK5xHVCJ
gUnFxVi1Zp6JxWSrFh1Z8qlZX70pSV4+tAbrZJ+J9FJlfRZBW2G/m7R0nErmONefU7Ue/QAuWk8E
nR2QghmwgbME1BSqiBc/bGClYocZkTkW8uP30nNUR9Ij5qdOR7K81o1gr64YoxzBIlr7EpM3UzvK
hjFBb5ErEhjzq63KGmizvjRgpxBxPjSkbtXam1TdLEqLOBpnzd1wtXKRnKm/NhUPvKt8nYodO3Ch
yu7yEWV5YSDgVkeCG/owGM8TrrSDzOwHo+Rs7CK1FE35G46W3mkNEKDGFxSxyMi10hQTIVkwd5py
dB3sOmHa2iiMbYPiTjVxbrzPR8wg/fMl9r8igvl6eCQfeWRgyQM63qxFSQYGWHw70hpsX67iLLRA
KZWthqjfbpUI/sv3X7H1RRJakrPI3f8WibxLqbkcCUsJqMS5Dzp2ageZFRjDwKljKI6C/q1ly2bp
7IX7rLVqsg9bHJTW2lufMwicjvVBaT0IlRdA26MVGNOiN5nNWF4CIMeUa7rIpw/d063limrHFo5n
wwN1TQJ3TLckvyMr2yVa7HLVO9DWiZXXV8CeajnvtckqWAYxChx+uHii5Mg/bFw8yUeNQpgH5DpC
ta8tRof5aGbfu/FLYp2iRwY2H0nYbHCy0q1lHyM++h2GSTd9wV/NpShDBmwHHnaQRIYF8UUwUfMp
0G02513T5yYDa02a8FXle1ay4JcdvB13SAJfPoC/lZRTQydPim5XnRcPupV89x5UF9XeRcrCsqgZ
jWcgsvJFqvSh0b8ZjOQlC7GC89H7C5CMWmYnVzqQyDAWtNeNo6wbDijRwBhMz+kyh1emads/RNMs
LC4DhZnrZ6EehcLsUsCqK8oG1C0O+maAuRyXwIomVQTSLKWfmXLfjczlfCg+DyH4rM5HZtYHPE+H
4Pnir5BgQvsyAhbpqC2RhZy1mS8VNRPW+RTFlKCpbLaHo+sVwV9QjGwQ5CeT6/HH7OwqjwnG8gpF
HYrpJ4Z71G910EM/IcdVMe4LaspvpkjrmBTfX4QjTcvr/87OQaFaxQ2hVp2mvLnQ4r6e9CGSGq7h
HH+vB10wUSpfhHjNIDk+/+M8nt5q1cx41JQfJARfqR7cGk57cjlYQy/pjdeOKhnk/L1KN4llsIU6
usfwtgg/tXkKPPBcTMq8uzuTpeGnABPzbUapH7PwEX979m4yVhIeOgsunXNIKQrwXRGyYKij1lVg
CYMrModTXsGEvM3SiOCAbaCZKAmeIaGhZZhFRXzmCbFWixKlKt+P7uAGFLgOs8C+4lRote/E8amr
sZIxIpnzvxK/srTAbiAYwQQdDLqCb5TGwqryXXQjSD3BWg8EtGa8ajbMZ9ahETiZWqt4fEeAQD1w
m1I8Q9l7JUvxbneLUUZc4TeCT3sZj+bZnDyY7EXaYX/AIwF9AOvCv35LO/o2eZR9e/oo93CDRI3Q
JJMXDoAL1OfncPRhMGMnARZX4TBR8k35XV4Cp6X63bOwyzS+iUFyinuITVEVtlf2FmuITodGy4YZ
H6JM7jNh9e7BZwNTCJTW2i57nWij5uhxLrtk4YZxPNxgn49wPuhbNlRUugijtW2ouv3+OZwn10JK
vKc7ri06Nltk7qq5uqRz3ODqZnB1DhIMtznx/scx5mlYvx3Y/XA7r5N4GmxHTpP0UMFGQQMVbhTk
+6sblQ+k02I9OMZg6cjEInw5HcjU+dV9yXekCBoUIojSwLceyZMRArOQMH3pkUZNmz7R7MojHCKF
UnH83mrE8kP+BoqCn+6yy0iUKV6YMOEqQD74s6eupyTKy4wQ3+dkdcFjTHdcIaSk5T0GSLFEnjmD
xeHsegy1p6izpeucL6tHLgAoRoDLBQ5cXjjABnGuRDI9O5FnXlLhbBIXBVRdQKvuSBDkIOrJYCS3
s5Mi8ZLNtorGvEpmAJqOJ2FgUZzDH9HTd+W1Dw4GdQk4AkJn9cgYfZPMVbsznFCgCCV8/yMnpJL3
AMcAmqqUKuCFsZEgqLtM3kt8Dr/UCbOIaqros2BuVevOTKPCM544PbApvpQyTTJjyQrkjjc8Ubbl
PBbg+NsuyFongfPCNW6zlA8I1X3JB/1bLWbCZLnPFPT+yHHUaiJZ2pHFCgQSycE52Kn3x6KiljVW
u4lzLnSQS35WlAaYtXC+hwVI29XOYEjQ+LNopZvYppTkKHNsZkRAYEGP/xDFJdPzVPEhwNibubIF
wmZ4Bfnj3CJLurMuFcNfyLkwZ3z04u1Or8D9HgooZ6t6xjltinB5z7M0yWtc398py24lJiYHHIfP
hiUzF6PxBcP2e8NM3Q8mntqFnBk5zySQKQIzJYQkH9k3ruxAFW+J0Qzp1bv1hk/9QYTFrNO1NkkQ
64zEb8nMcGHP9F4TZYNpdqd9l1bCUbGe0/pMPmN1eybEiCOnCXUoD2cvt2z90F7ztDeNIbI3u/dS
paFpckuJsnY9yuAAYtMIYMqtt6HJ/OLFYPReDqmnX0iDBIhdd9jPpS7rJ2tZv2zZ7rwQrukbFP37
W2Q3pCzqQ0HYIGFWrO03vWKMr7yEAB4KVyXB84ApA/bd6dRanlj8AD0UTKW04sqgNnPP09bjW+HA
Q/9/H7Mw3iRV+AGa12d7qeep/81XOlC9nE57CV3ySgK0AO+vhkFidVL0ASHo+Xd4KaXfQt17XOhB
eczcksVokYYVOHDJqDm6A4JcnVlued/wQXHbY7wCGi5f/29Rzmtp4J4yTowzsZbyfIeHdmhadjkH
KdzCjis+qJXy2lSszCcmlWlg2pUrskwjUfT+oh69eXNnrRtnPJq+MjJD6TLqeGqjxbt3D/xAjwQZ
IEdahcQsOYClGd1xeR5AuZVSZSsFzYLJYhLAsylgezFae3DldYwXqEwrn8JSWQYBNTXBlOlM55CN
BtMT3WNC7++72gceGMl1XuHFsnzcJurAOqO+uQrg6Yt5cqtx3c3gal88a37PoGYo9itRO9B0HniV
ZYTJFyzuF/oRpe6AWCyMzRykN+ZLdmHMkLhpq0m3LWfOU1tUAumvw94hg4w3kWKVoS+3s8FnUEkU
9U87QqALGBdmzQN1LsZGfyzav7EyUS2ZxQDblTClAyvORAMbD+9Eozo/1eIpCnwfKy+TTtpt2/30
GVPuurKRTygb+aRkI0vIw27uC3ZpHUruBPMNkLawmzfyGqshdw2+8aF1atqpcHglJsAZMkpewlSf
7KLr99CdTKZ6qF/ewzQ0B4iNvLKDUKOOAmM5ZCyCDpnhGisz+a5CpZZvZ4aJNncYwitzHJdhmFfl
m8QgJZhIBQcSJ71st4hhf8CTYQAhNAF00P/FC9IWhozD9G2zzUdkWMvl8kW5uK7zB+tcW6bogKik
xBx2BaGUvgmH68ohudVR2SOeUi0Ly54kueZpTCyil4mCfZsrFDMbfXo1SvM54BaVZa8rX2TNdTRK
Eb/pNquE0VKf5OtidjTP6Yls10RwKIjNOf7mw/jSgg+ycGIQ8o2BELbz3QvIM4/6728IyNYAgwo3
tAvZ56buT+Y+84UpebMNsm+pmnS0PKDTQe2sAeMrjDUyK1GPxctUKhwQOI/Bzk9t5/5LmWIIYh+U
ANQL7ot4rncOFvX1S52387tyu7bVkr4NX3v0oeHVybAVkW1WQiQauHIL4WqAhG2xE2zZH3PfohQV
ba0FkeRl4PM8nqUlupRlZ6LsO7xnuGPF/QDe0RjqvjjRXl4D9YY4/O11UGmLe4oFgcm/nRds6BZM
4YICYJE/tgEutuM3sdzt5dMhWCjlPndCqVCmEgpIUJDJfS9naRiVNotSlni6xTRybe1rn7TY2j7H
UkBzLSLomtfAbOsofQMewyXPOH0/8qzydyLPBHtzud116lH5sutQZuXt9z3zP7FKzAwAnpB64/AK
ZgWhVV62qjVPbpSqH1+FCqR1Lt4eyskAARWITTVgfkDWMRb8DCSsToEnm7Oug6UnrbZvpHSCI4es
KaydSnmXKKtyyHROV7xR0r1FAB2q7cwwb4xUzFhdvks7qe6xKyaZvoRvR29Ha1hZ/oroc70526h0
vVnX06AyhD6Xk6R4etGsV72hfU3DqSkMqoNS741GP//4exZ2FqrjHtWt+xx/GPNTQgLlLe46d4/+
6kuRh+0q4iF8O/zO+ndrk/yO73nhfPaVoZQJHqr6PBRDWUL+mEvHNesaT90Hf6SadK5hC2XjrjSC
LOg4kqoWto/Pm94K9V/A9SVVA/jvUOO7Uh2J66QXgWLKSsXrEiOL4JKnqoj4epM/kup9lfL1gUlo
RzEzSAVLpKurmCW3RndrHqjMZTISMNk6gBUW1dXIW/kkSdMH7SGlAyiOVlbCwIr+QvK2ltm44Po5
CySr5tXAYcGCO7BCq4V7kI6eIQMfhIW7t0YOsqDdJ6o+UjKekWyNKSWrOxluoDeYrJE/AAJJrnnq
OhKDKd9J5y5Yx9NUkFHkbSvaOH/VeNmCZGRapuq792GmV7E5Pw7HF93hBMPvUajXlRH/l0zqojs6
wdzDkPopHSTSFIb3AYgv1GhasfNWQItcRDfezx0GGmRhHqyY7iulVg+4/YLl4nz/YILgh5/F0WxE
5VKlJmjfcXvwKe5nS7kFMxIul3Pc1Pw+sQP5LZtW1r4bscyuvCVMbi5ptGwJEQ7u6ZqsQ9d4jsNL
/bvlEaqZNIZfTMZEOsVfWLmy3tFfvuOrgjHI5YGIYSYYQ8dRqbiykrXchZCE5adymRmPKwj+hmqv
5RVSTguf1uJTt2xlilZoC0bUNjWEV7Z3N6M1hAaBGG2bBno3ywEquRj01LEiVdrJEWgxnKj9OvE8
JgFY6rAs1Q4qB0B6TgLy0NZEAN327O4aXYzno/5hn1nGTZPZoXrtpJUgbblFbaqSeTkaAhMTL2yn
xPvrXs7i6Rozk5FZoSTUcJyycRqoV6A+GW1L9daFs3VIW44WFcrgqC4f+UE+0qhhOqKb5UAMJt+8
aykKsyLQc5PWSgoa3rHCsazjmSYn7hMXMvBBGOjtxaYLElZcyU3MxbZq8TX77MrdVmwIoYJVnmWB
4EG+0ZY/94ZWboQXM8VTx0IkEoXw/E+SD6/KyGMPHqioNzB/m8khCFesjop9I++wZbZ8K6LNNLzA
GJVw4KVaVd98nV794Z0aEWjfxT2Yj8I36Bq2klxsaYwLQ4QjNwrjMQPnU5cWf4khyEQdmx6HkgL9
ij9WAAoI9ZoJfaD8xG4keZU0YH1iI03qIpek5nj4GSAzkd5gaBjpLb887uiuFQDt4V33apyV05pi
1Ovcoujfh1uucEPFrsmviH3S4pShF+XI8pL1cZfEgp3wVi83afvqfMJXDPLdWidgU9XXqi6Peqd4
EIgCNxn03ldshgRfmQvdiguvHJxxjUlKlb2TMdKzAcYlVyS2JqdoZKpDoaFfxrOuEmGodLRplO+6
tGJ0PzZ5/UOXfilvczOZZXSzQjPvL8ASCZe5mMJn8ZA7GE5Mlsbw9BKlYPh8JWdWOpRfKcA88ITv
LxzuD4XFfoC4rxgp6SAt7l7FZdwUt4hB5MSlR+tFedMpgEooolxqlExuM1T1BTxfL07+EhtdxI3Z
1B0hjEzz1JkIcgKrh3bqHndofh39kx9l7IBt8eYKM7FUPj2fKlJfa6P8G6HY2VuP39ShKyQeWekw
IkUtgspcGnQ1FZGkBTG91ykBovbBg4d3gCQWDx6s5Sii5JnreKisd51IIPWSWtXsCb2+mI9m842D
+GLQHeVTxWQW7EQQDFaCb6XtEwdMPaAiZVqURK3sh7Frp4RY8B1iAiIhS9K04vDmLfHYCplSinOg
wj6poWlT1f33ccWxFGle/q6WjBxohLofr28rVlKODgCfGyg0bao142bUds2/7KiJcsl1jqm1IqLc
K+Ym3RZWUHcp5Py3iBENcRmzsJgY8jubBrG+stcKE1qty2ngtixyFDs6B4Ee85FvYcsdVQO0t498
7UUOMhrrhWhl7O+a0cjboSO01vXwueepbvHOKQnsTMzYxk+n+eho2u0NY4u88EV+jm1KO6ytty2y
Nj09UgD9FlPYnmUhlygf9Z2thIKXLMwcMrobf/2mVNjtFv7UKPyHYr3w7q6aL5dKi4cblMsR1uJe
AXsO0kK8B2iGTY+vtKlvfZWt8oQs3sOFcpWsNtSjDDYWCG3rYS1fEbDvxcdZSahgbCzaxDpsXcjC
iha9w5iCVFxkgiQDyA9YRGQPR9c8YY8KGJR2w3qeBoGQRV6cJGUK7F34ARxuydvXdJal+QJtIWcq
DZQD8JAiZQsSSytC5PisuzVZwU/lUk9yatAzCkwGEMHP8xyk+uKdPM7IAmFCKX6wxak+fwf/ihN+
Lo52KV8t65M9z60rBbedjr8OANTanuQjoCHkF/Hm1zzkxUzuHnwDRpXjO1EX67/iTJa/fIma9rmd
28e2spZ56VqrtRR6rajUqyik+/MWFumfGhO5FXCo8IX93A5td3m8N4vM56ZaXhInle9hLZZ3bRqp
urMMGaQGKzQgmI8AKlmqWHr8GvrT3bWg4lc4jlY+2UplLz1IWqXarkb3tvRZXy614wnK0q1GPPWO
pYHzVCUq1kRabJkSd94GCe7lZKp+kiHZbyGf6ngUsjKZXJqIjaE8iyRBFS2CxPGyKJuO7Ibpm9fX
1xPdpkJnx4+hWQtTyBJ4t1Nz1vDKknuiBDx1lVVVUvOSQdTRoRfF9QGraSjUtARH68HbWvGDipIO
7Why8qumeYHGNJuw54Ui5/mokStgdm3TOBkPP8T4DVc5FH08ohoq6dHCRB+eqKGtnWHGSw82mITz
yJDcQuuUf23RwX0S0wQYiVTLphV62mJn7XwvaRIfHh49kCQlkAAl3BJSoofH52a5SUpFAWfk7yr9
PjfMC2VCI7tKWZS/AVHWAHJ8Z3TMrVAyhW0/RVqIZAc4zeT2AjHxV5KCMipBxr+KCcNixr+8g08X
a1k+rObjLHLQSifmUx/MVTvgPuA51ii8aUtHrGnY5GcIWVnjE+tgrA+c9CRSkp2W/S5E5wUCpX8N
AfuKJEQ1j5fbcu0Kq00ezdkWSzfCWkTbb2OFOd/Olwu1bZFjMWQLYlDkWhJbJlm+Gmc8q47PEk2n
kMPrxJhhjPF6gdPh2mFB09G1yTrfy4Ne3EsRnfkK1h+2TWfk0ZRNX2vp0fV2Nj76N5+m7bZy9gW8
lyyn+6ASfGmQJjc807Jl/rUMBJwYTmEX8qWORdWUo24FIrvn8Nf1cLjHaO6RR/hXysLI7FGkdREk
ipkPhzYPQxGFcAEcA5Kcl7Y2k+YGt0rhHjCaSoP7e+h8Vx0RlanACjHVm95OZuPitDvqj29evz48
yOZMhvrCxpVOUB+xZbtTAfsBNA779eh0NgWwgMeckhlbSQ20QRcPn07eOvNEgN90PhqJFjIUUV2D
INSyrON0S9bBBPr49Kxx1ipO5rNsR5x0cfPXdaAqnVMB6aI7QQZMBtTk2WxYj8o7pZIT6oLnKFdk
pz8r+QFoLv0BCTD5gcR0PJ+DqiFoNVMDCDf5AYbNB6vYD5jHmnGNPDeNu3J7a7exiO6bt3U9mz0/
5RwQXmyVpN9vtBZxuZRu2fGMh38lGmaZx4aJGxTQMvniqtJaed9CcUDvYZ6Y/1WV/1Egk2laCH0u
ULc8kv5NHFgAdyv0oC797vS9RiBtNJC10cgXxw7rrJ1VzyKKmssPWdm1OgsFx1pxjJe716iMdUnv
Ou7PhzFkrIMoZvuN5vPXx+evz5rnz45enwhsX9ozxhqD5EAs4i1ZX57MR9m+ZaLRLwpiV1R9Np5P
E5kByWmQZ8tL4uElKIJU36etF+2z1unZ+XHj5OxUdP0mA64iQNzFkG4YfwgeLvNuD8t/vAbyDgAA
bERNvgAQAMgrKc45ieH3Ag5+Z9N5nAV5DqVlxxm5Ys0kudakJBRV4RW5aMiNrAY55jHXlWgVaa3u
p6P5TNxR+7di2vWoVtrdEqA4uBp1xT3UuBB3xyk+FGeDm3gs7rJKXOOJx1QQviKswqmx/S5FT0Xz
KhupOBp1+Ug5vAlg61EWLKv74gEj0oUzarOmFx2VEc5eQnVJLyBGdXc4dHMFwrR7w3GiQ1CGg/mp
TKqBgYqNhXKLFF8wsWWnEnToNE/EYTZ6CHgi+1WEnpy1j28m3VE8FGgFQsN8jC+ux+P3MmrMMv9p
31W6OLsWUKDlW9LzJ2u2Qbsf16OeSnVnjJQjDbfLFiAnS+tqnvuuOwzw4hWtoqSKjwVU+Clg0fl6
LrzR4gvn56VuLMo9OhxdjrPebD/yLvbH42HcHWU/FudT8LwX/4qe4CEfFYvFj0UIY3iOIzhXmAIW
SY0p9B3XbPHl++ZkhaF5yFgnsqWuApInEdCj1MQ7m6G8i9LB12SAtw8BoU4uYge6jInBpYYnAYP8
N+98tCaLL/Efl7RrUuFCD54h3pHGc9HwmmiAS+u/IdOiJTW/KkibJIXf4CTlPi0dQCpvuL6qznJd
SVXVrQockMXtr4MoVHNXJhY23nxE/Aj0OIp7s+fxrdTWpXvV5yPz8vVp64Q/Q6Hnrd/nCR5E0Qzg
H2N+hMvoKVr0SibvB5NJ3FcXGVNAJjajDm8EtP3V6dErwUJNk9jWkoghnLePTwLJspZtmlvdlnxB
XxlzyqQ/1w1wxLpvWA5UJVkvULaHtjGgP0jm/XFUGOEUUZeAP3gOYrkxD4w3i25Prq9oh22YNXV7
5+At3zQ1przXJG1ZTgxItgwmAB/HFALmC5s/bpyeko+E7IXwolg8JXVVNOFg1I8/KYIwGcbxpEKZ
anEZ4HqQl7NKz5zEszNJLU0hZS6QuJpS+BBP+4Pe7OgyO7UIVdtzbvwe9mWKzHvypvTuaVHWwyG/
fvX81dFPr3Cn1O89GfO3efSq+eL16eFvW5Dq9DfRX56fH78+aZ2fR7/ZwMGexrPsm8zRcyBdgao9
bLyAnyevz/dfHDWftzDSTPPF0an49c4nTrvDadzt355ilGKT8fjQkje/j4EM7ohP9Yd3qsCio4Sc
roxEoGZMeqVPHYCfkfvZwhRMp5UpZwJyk6oWm8h28DCplcF9PJcxn0Fm9EC5dF3GwHFN4z8ijAgq
afbJJtHEhS2TOL8+eYGhleA+59KrSXcG1Lh4XYSf4H1rkDR9xOSt13F3OLv+k/GJhEZP4mQiWomz
sO+5YD3FmGTgKMMAbuLZ9ZjixGZ+bJ1lcrZOGtdMMS+nreZJ6wxAB2qKIfQhITiseuZ3BUW3ih+C
f4SgyoAbAvW57jQ4+NFYoEVwbMe9UZK0WqnG+IWFxZgQSYCrlsTdae/6uCuoLDk0+Gii9eOsbHas
OBj1hvN+nCBpkUtZUvj2GMjun/He+RnZNXuAJZ+hUfWLf0jGIwmwYSI/59ICbNdmV8H9OhZIy9mw
wMYoorOwP54VGpOB3KDCGcje2Db91Np/dnT0fN1duhxPLwb9vmjCXoRqYJfgoqPjuxe0O6BvzOLh
j7ReOVfzvmJMF93+ki1ZsHWa3U7i8aXs+GmR/p7LgMmZEd4DGZNzOwVbmXq5letljqQZScj6IjUX
/HIrBLspHfKhNxsD167mqfMPQorCpzJjofpop4I3Zfb8ZlcmhnTTPkBZGotYX4qRKC4m2U59SaRE
KI81rWZxC8eaXF0Sxtl1q1kR/t4RLRnxgLgTciZO8mzMU5N4wLlw9nkFQNhn3s7E3R9uUPL35cja
1n1QMzj0mo35tMZQXndQ4bfd4aDPk8mmYMAr8M9PR8lSM8kZJS8IkxzFRS4N80vd1JJuQhUvihcg
d+LpqCQSBLlApjkezQTSLpyJQ5+BqKyTiVgbXICNqz8NJkipyDIHA9FmMoBvominO5t1e9c34ste
JKAzhgv5cebh3QXsBSVBWGQ6ZsPX2FGx+BDpIGVbHZyeuq+sHXUM/o03ety/DWBsS+ycvVuw1Buz
T0Uo/Ho0GwyzvfHNBHK6OUowqX6ThDj08bQ47QGWKovjJ0Wf9BoEQWCzxPI6rnXOgoU+TEaFi7F9
oVf07YGyH0HG//L//PIPf/5Pv/x3uMKbU0HF/vKvf/6bP//fv/z3X/4l+uW/Rb/8yy//9c9/88vf
//Jff/mXP//HP/+fv/zTL//8yz9G2V/+h/hXTz1XF9V++UdR8B+huqj03/Dpn3/5+0jU/HtR+u+j
P/+tKPNPf/6PkWj7n375H3/+O9He3+UjKPL/iiL/Kl787S///Oe/k+P6VzEA6FlW+1ts5Z/+/H+x
YF/RL/8gvv8naPIfROnyJmv6/yvtalYihoHw3adYYQ8WSlnt6kFQEHr0HdwqRRdlKxZUWPruZjKZ
dKaTbNO6l8LSpkk6yfx9+abwJiwFzY2YfBuhd4bsE7NkvQ0DE4AfDaaysuoKnil8G+C9+Li88gBO
S8DXi8UdMmfAyHIivwjcaYxUcylw5YCJgxLPaO2xVYTrhjwJlW3NhpK84xg65/NrD1VLkD3TBA3F
uocTZQdMM6R78n/kktxbYPzkDNqm23dw0pFm5dbTqpyCHyep1BmpV4XapExQBCMmOZvibE+bZaVV
HMyCH04oNWlCqrEQmnY5yTKr4Kth7ru30SIwbURwAFgJMyCc8YwCW6jtz7z63qhK0DiTscHQKpgi
4yRE8li9uUMJ8bCc1Dz1R+PgGt7QeKw7Y2zgNmD16G593H/2qyEa4UG84Iuk0m8yWD/2nUVdmg7f
xCMeoNDPXfcyZdljzOfiptmKIl0LuiK9Xwrp3K1k9+SIsQq6uWmI7FgaWvdMaJjJ48N+vLJCbZq/
3UGcicUdf4jiuC63vcJHhg6w5ql8sjwUfqkOHT2oGpfqxFiIEX+KmLYAMgnJu2qJ7/sdH/K4qsA0
hEUBRSllzoGiGidq2i43VZ984GIJ9+LQg+eDVT18pLhv+D+E0HtpBKG5h0y89tHprmyA+bF1ntMa
Xx+duPoduB+Fxik6r3L8sB+SHHMHOkoiG/K90zXllWJaEQcYKgWwnsNGqmluRuDzNM8WP5rA7/dn
za/dom0aWkQ/646K34GB9wcU+vMoWP4CAA==
VPN_BOT_BUNDLE_EOF
}
BOT_SOURCE=137315e

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
статистика, проверка блокировки в России раз в 3 часа, бэкапы, переезд на новый сервер кнопкой
и несколько админов (приглашение ссылкой).
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
ufw_active() {  # ufw включён? Вывод — через переменную: «ufw status | grep -q» под pipefail путает «включён» с «выключен»
	local s
	s=$(ufw status 2>/dev/null) || return 1
	[[ $s == "Status: active"* ]]
}
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
# Состояние ufw — через переменную: «ufw status | grep -q» под pipefail путает «включён» с «выключен».
UFW_STATUS=$(command -v ufw >/dev/null && ufw status 2>/dev/null || true)
if [[ $UFW_STATUS == "Status: active"* ]]; then
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
	if ufw_active && ! grep -qE '^80/tcp +ALLOW' <<<"$(ufw status 2>/dev/null || true)"; then
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
		ok "бот${BOT_USERNAME:+ @$BOT_USERNAME}: домен $DOMAIN в Cloudflare${BOT_ADMIN_NAME:+, админ — $BOT_ADMIN_NAME}"
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
    alpn = (ss.get("tlsSettings") or {}).get("alpn") or []
    if proto in ("wireguard", "hysteria", "hysteria2", "tuic") or net in ("kcp", "mkcp", "quic"):
        kinds = {"udp"}
    elif net in ("xhttp", "splithttp") and "h3" in alpn:   # XHTTP поверх HTTP/3 слушает и UDP
        kinds = {"tcp", "udp"}
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
	! ufw_active || return 0   # уже включён — его правила остаются как есть
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
	if ! ufw_active; then
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

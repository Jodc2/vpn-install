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
bot_kv_grant() {  # админ, заданный явно (VPN_BOT_ADMIN_ID, «это ты?»), — в список админов бота, если бот его уже ведёт
	local body
	[ "${BOT_ADMIN_GRANT:-0}" = 1 ] && [ -n "${BOT_ADMIN_ID:-}" ] && [ -n "${BOT_KV_ID:-}" ] || return 0
	body=$(cf_api GET "/accounts/$BOT_ACC/storage/kv/namespaces/$BOT_KV_ID/values/admins" 2> /dev/null) || return 0
	# Списка нет — бот возьмёт первого админа из ADMIN_ID сам; админ уже в списке — писать нечего.
	python3 -I -c 'import json, sys
try:
    a = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
uid = int(sys.argv[2])
if not isinstance(a, list) or not a or any(isinstance(x, dict) and x.get("id") == uid for x in a):
    sys.exit(1)
a.append({"id": uid, "name": sys.argv[3]})
print(json.dumps(a, ensure_ascii=False))' "$body" "$BOT_ADMIN_ID" "${BOT_ADMIN_NAME:-}" > "$BOT_DIR/admins.json" || return 0
	body=$(cf_api PUT "/accounts/$BOT_ACC/storage/kv/namespaces/$BOT_KV_ID/values/admins" --data-binary @"$BOT_DIR/admins.json") || { BOT_ERR="Cloudflare не отвечает"; return 1; }
	cf_ok <<< "$body" || { BOT_ERR="не дописать админа в список бота — $(cf_err <<< "$body")"; return 1; }
	BOT_REPORT+="админ ${BOT_ADMIN_NAME:-$BOT_ADMIN_ID} добавлен в список админов бота ✓"$'\n'
}

bot_validate() {  # всё, что проверяется до установки: токены, чужой воркер и вебхук, бот другого сервера, владелец
	local n=0 was why
	BOT_USERNAME='' BOT_HOOK_URL='' BOT_ADMIN_ID='' BOT_ADMIN_NAME='' BOT_ADMIN_GRANT=0
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
		BOT_ADMIN_ID=$VPN_BOT_ADMIN_ID BOT_ADMIN_GRANT=1
	elif bot_has_binding ADMIN_ID; then
		:   # владелец прежний
	elif BOT_ADMIN_ID=$(bot_kv_admin) && [ -n "$BOT_ADMIN_ID" ]; then
		:   # бот, поставленный руками: владелец записан в его KV — сохраняется
	elif [ ! -s "$BOT_DIR/tg.token" ]; then
		BOT_ERR="у бота нет админа, а привязать первого можно только по токену бота — дай токен бота (или VPN_BOT_ADMIN_ID)"
		return 1
	else
		bot_pair || return 1
		BOT_ADMIN_GRANT=1
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
	bot_kv_grant || return 1
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
bot_extract_bundle() {  # код бота (vpn-bot 12c6225) → $BOT_DIR/worker.js
	base64 -d <<'VPN_BOT_BUNDLE_EOF' | gzip -dc > "$BOT_DIR/worker.js"
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
VPN_BOT_BUNDLE_EOF
}
BOT_SOURCE=12c6225

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

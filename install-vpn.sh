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
unset LANGUAGE   # sudo её сохраняет, а программы на Python (ufw) переводят по ней ответы даже при LC_ALL=C

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
UFW_RULES="/etc/ufw/user.rules /etc/ufw/user6.rules"   # правила ufw, как он сам их хранит (IPv4 и IPv6)
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
		# Поля — через символ-разделитель 0x1f, а не табуляцию: пустое поле между табуляциями read выбрасывает,
		# и у человека без @имени тип чата оказывался на месте имени — привязка его не узнавала вовсе.
		while IFS=$'\x1f' read -r uid fid fname uname ctype; do
			offset=$((uid + 1))
			[ "$ctype" = private ] || continue
			# Ответ отдаёт полное управление VPN — только явное «да» (Enter — «нет»).
			bot_ask "Это ты: ${fname:+$fname}${uname:+ (@$uname)}, id $fid? [y/N]: " || continue
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
    # имя приходит из Телеграма и печатается на терминал: управляющие символы — в пробел
    clean = lambda v: "".join(c if c.isprintable() else " " for c in str(v or "")).strip()
    print("\x1f".join([str(u.get("update_id", 0)), str(f.get("id", "")), clean(f.get("first_name")), clean(f.get("username")), clean((m.get("chat") or {}).get("type"))]))' <<< "$body" 2> /dev/null)
	done
	BOT_ERR="не дождался сообщения боту @$BOT_USERNAME (писать нужно ему в личный чат). Можно и без переписки: VPN_BOT_ADMIN_ID=<ваш числовой id в Телеграме> bash $0 --bot — id подскажет @userinfobot"
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
	if [ -n "${VPN_BOT_WORKER:-}" ]; then
		BOT_ERR="воркер $BOT_WORKER уже управляет VPN на $BOT_OTHER_DN — не трогаю. Для этого сервера запустите без VPN_BOT_WORKER: скрипт заведёт отдельный воркер"
	else   # имя запомнено прошлой установкой: без переменной оно останется тем же
		BOT_ERR="воркер $BOT_WORKER уже управляет VPN на $BOT_OTHER_DN — не трогаю. Для этого сервера задайте другое имя воркера: VPN_BOT_WORKER=$(bot_worker_name 1) bash $0 --bot"
	fi
	return 1
}
bot_worker_name() {  # bot_worker_name N → имя отдельного воркера для этого домена: vpn-bot-<домен>[-N], до 63 символов
	local w
	w=vpn-bot-$(printf '%s' "$DOMAIN" | tr 'A-Z.' 'a-z-' | tr -cd 'a-z0-9-')
	if [ "$1" -gt 1 ]; then w=${w:0:$((62 - ${#1}))}; w="${w%%-}-$1"; else w=${w:0:63}; fi
	while [ "${w%-}" != "$w" ]; do w=${w%-}; done
	printf '%s' "$w"
}

bot_id_ok() {  # id в Телеграме, как его понимает бот: обычное положительное целое (до 2^53 − 1), без ведущих нулей
	[[ $1 =~ ^[1-9][0-9]{0,15}$ ]] && [ "$1" -le 9007199254740991 ]
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
bot_kv_grant() {  # админ заявкой admins:grant (BOT_GRANT_ID, имя — BOT_GRANT_NAME): бот вольёт её в свой список сам, не заменяя прежних
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
    v.append({"id": uid, "name": sys.argv[3][:80]})
print(json.dumps(v, ensure_ascii=False))' "$body" "$BOT_GRANT_ID" "${BOT_GRANT_NAME:-}" > "$BOT_DIR/grant.json"; then
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
	BOT_USERNAME='' BOT_HOOK_URL='' BOT_ADMIN_ID='' BOT_ADMIN_NAME='' BOT_GRANT_ID='' BOT_GRANT_NAME='' BOT_ERR=''
	# То, что проверяется без сети, — сразу: негодное имя воркера Cloudflare отверг бы только при загрузке, после
	# всей установки (а с пробелом в имени запрос не уходит вовсе — и это выглядело как «Cloudflare не отвечает»).
	if ! [[ $BOT_WORKER =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
		BOT_ERR="VPN_BOT_WORKER: имя воркера — строчные латинские буквы, цифры и дефис (не с краю), до 63 знаков; сейчас «$BOT_WORKER»"
		return 1
	fi
	if [ -n "${VPN_BOT_ADMIN_ID:-}" ] && ! bot_id_ok "$VPN_BOT_ADMIN_ID"; then
		BOT_ERR="VPN_BOT_ADMIN_ID — числовой id в Телеграме (вида 123456789, без нулей в начале), а не @имя; сейчас «$VPN_BOT_ADMIN_ID»"
		return 1
	fi
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
		if ! bot_hook_is_ours && ! bot_consent "Бот @$BOT_USERNAME сейчас подключён к $(bot_hook_host) — похоже, он управляет другим VPN. Перенастроить его на этот сервер? Тот VPN останется без бота: команды и кнопки пойдут сюда, а его уведомления, пока жив его воркер, будут приходить с кнопками, которые уже не про него. Для второго сервера заводят второго бота: @BotFather → /newbot"; then
			BOT_ERR="бот @$BOT_USERNAME подключён к другому адресу ($(bot_hook_host)) — его не трогаю; для этого VPN нужен отдельный бот: @BotFather → /newbot"
			return 1
		fi
	elif [ "$BOT_EXISTING" != ours ]; then
		BOT_ERR="нужен токен бота от @BotFather"
		return 1
	fi
	if [ -n "${VPN_BOT_ADMIN_ID:-}" ]; then
		had=$(bot_kv_admin)
		if bot_has_binding ADMIN_ID || [ -n "$had" ]; then
			# У бота уже есть админ: этот добавится к нему (заявкой admins:grant, bot_kv_grant), а не заменит его.
			BOT_GRANT_ID=$VPN_BOT_ADMIN_ID
			bot_has_binding ADMIN_ID || BOT_ADMIN_ID=$had   # бот, поставленный руками: прежний админ — в ADMIN_ID
		else
			BOT_ADMIN_ID=$VPN_BOT_ADMIN_ID
			bot_grant_if_storage_kept "$VPN_BOT_ADMIN_ID" ''
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
		bot_grant_if_storage_kept "$BOT_ADMIN_ID" "$BOT_ADMIN_NAME"
	fi
}
bot_grant_if_storage_kept() {  # ID ИМЯ — хранилище бота уже было (воркер удаляли, список админов остался или не прочитался):
	# бот слушает свой список, а не ADMIN_ID, пока список не пуст, — назначенного админа туда впишет заявка
	[ -z "${BOT_KV_ID:-}" ] || { BOT_GRANT_ID=$1; BOT_GRANT_NAME=$2; }
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
		admin.id req.json exit.fpr fpr.json backup.meta bindings.list settings.json grant.json; do
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

bot_bindings_list() {  # строки привязок воркера → stdout; 1 и BOT_ERR, если новому боту чего-то не хватает
	local kfpr
	printf 'plain %s %s\n' PANEL_ORIGIN "https://$DOMAIN" PANEL_BASE "$WEB_PATH" SUB_PREFIX "https://$DOMAIN$SUB_PATH" \
		CF_ZONE_ID "$BOT_ZONE" DNS_NAME "$DOMAIN" ENTRY_USER root ENTRY_SSH_PORT "$SSH_PORT" SELF_ORIGIN "$BOT_ORIGIN" \
		VPN_BOT_INSTALLER 1
	kfpr=$(bot_key_fpr)   # отпечаток ключа, который воркер получит в этой же загрузке (см. bot_keys)
	[ -z "$kfpr" ] || printf 'plain ENTRY_SSH_KEY_FPR %s\n' "$kfpr"
	printf 'secret CF_API_TOKEN @%s\nsecret SELFTEST_SECRET @%s\n' "$BOT_DIR/cf.token" "$BOT_DIR/selftest.secret"
	# Каждая строка проверяется: в «{ …; } > файл || return» виден был только итог последней команды, и новый бот
	# без админа (его забрал бы первый, кто напишет /start) загружался бы как ни в чём не бывало.
	bot_secret_or_inherit BOT_TOKEN tg.token || return 1
	bot_secret_or_inherit WEBHOOK_SECRET webhook.secret || return 1
	bot_secret_or_inherit ADMIN_ID admin.id || return 1
	bot_secret_or_inherit PANEL_TOKEN panel.token || return 1
	bot_secret_or_inherit ENTRY_SSH_KEY id || return 1
	cat "$BOT_DIR/exit.list"
}

bot_deploy_steps() {
	local body sub f p kb res subnew=0 tries=15
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
	# Секреты этого развёртывания: самопроверка — всегда новый. Секрет вебхука у работающего бота не меняем:
	# сменить — значит заглушить его, пока воркер не переставит вебхук (а любой сбой до того оставил бы глухим);
	# новый — только когда секрета ещё нет. Вебхук воркер ставит себе сам (ниже, part=hook).
	bot_put_secret selftest.secret "$(bot_rand)"
	(umask 077 && printf 'X-Selftest-Secret: %s\n' "$(cat "$BOT_DIR/selftest.secret")" > "$BOT_DIR/selftest.hdr")
	if ! bot_has_binding WEBHOOK_SECRET; then bot_put_secret webhook.secret "$(bot_rand)"; fi
	if [ -n "${BOT_ADMIN_ID:-}" ]; then bot_put_secret admin.id "$BOT_ADMIN_ID"; fi
	bot_bindings_list > "$BOT_DIR/bindings.list" || return 1
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
	# Воркер отвечает? Только что заведённый адрес workers.dev Cloudflare включает около минуты (до того — 523),
	# поэтому ждём дольше — и до вебхука, иначе Телеграм получит ошибку на первом же обновлении. Вебхук — сразу
	# за этим, до расписания, отпечатков и бэкапа: сбой на любом из них не должен оставить бота без вебхука.
	if [ "$subnew" = 1 ]; then
		tries=90
		printf '  …     адрес %s заведён только что — Cloudflare включает такой около минуты, жду до 3 мин\n' "$BOT_ORIGIN"
	fi
	for f in $(seq 1 "$tries"); do
		[ "$(bot_http /healthz 10 2> /dev/null)" = ok ] && break
		[ "$f" = "$tries" ] && { BOT_ERR="воркер не отвечает на $BOT_ORIGIN/healthz"; return 1; }
		sleep "${BOT_HEALTH_SLEEP:-2}"
	done
	# Вебхук воркер ставит себе сам — на свой адрес, со своим секретом, — и при каждом развёртывании: так повтор
	# чинит и вебхук, оставшийся от оборванного запуска. Очередь стираем только у бота без прежнего вебхука:
	# чужой (перенастроенный с согласия) и наш её хранят.
	f='/selftest?part=hook'
	if [ -z "${BOT_HOOK_URL:-}" ] && [ "${BOT_EXISTING:-none}" = none ]; then f+='&drop=1'; fi
	# Ответ без «ok» — отвечает ещё прежняя версия воркера (её секрет самопроверки другой: 404): новая расходится
	# по сети Cloudflare несколько секунд после загрузки. Ждём её — заодно дальше работаем уже точно с новой.
	tries=${BOT_HOOK_TRIES:-20}
	for p in $(seq 1 "$tries"); do
		body=$(bot_http "$f" 2> /dev/null) || body=
		case $(jget ok <<< "$body") in
			true) break ;;
			false) BOT_ERR="Телеграм не принял вебхук — $(jget error <<< "$body")"; return 1 ;;
		esac
		[ "$p" != "$tries" ] || { BOT_ERR="воркер не поставил вебхук: новая версия так и не ответила (ответ: $(head -c 80 <<< "$body" | tr -d '\n'))"; return 1; }
		sleep "${BOT_HEALTH_SLEEP:-2}"
	done
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
adm = base.get("admin") or {}
line(adm.get("ok"), "админ бота назначен ✓", "у бота нет админа")
cron = base.get("cron")
if cron and cron != sys.argv[7]:
    out.append("⚠ расписание воркера (%s) не то, на которое рассчитан бот (%s): суточный бэкап может не сниматься — возьмите свежий install-vpn.sh" % (sys.argv[7], cron))
want, fresh = sys.argv[5], sys.argv[6] == "1"
ids = [str(i) for i in adm.get("ids") or []]
if want and ids:
    if want not in ids:
        # не роняем: хранилище Cloudflare отдаёт новую запись не сразу, заявка могла ещё не дочитаться
        out.append("⚠ бот пока не видит админа %s — обычно он появляется в течение минуты; не появился — повторите: VPN_BOT_ADMIN_ID=%s bash install-vpn.sh --bot" % (want, want))
    elif fresh and len(ids) > 1:
        out.append("⚠ в хранилище бота остались прежние админы (id %s) — %s добавлен к ним; лишних уберите в боте: «Админы»" % (", ".join(i for i in ids if i != want), want))
line(entry.get("ok"), "вход по SSH на этот сервер ✓", "вход по SSH на этот сервер не прошёл: %s" % entry.get("error"))
if ex.get("ok"):
    out.append("выход по SSH ✓")
elif ex.get("skipped"):
    if chain:
        out.append("выход: при переезде порт новому входу открывать руками (у бота нет входа на выход)")
else:
    out.append("⚠ выход по SSH не прошёл (%s) — при переезде порт новому входу открывать руками" % ex.get("error"))
print("\n".join(out))
print("RESULT " + ("; ".join(bad) if bad else "ok"))' "$(bot_http '/selftest?part=base')" "$(bot_http '/selftest?part=entry')" "$(bot_http '/selftest?part=exit')" "${EXIT_MODE:-}" \
		"${BOT_GRANT_ID:-${BOT_ADMIN_ID:-}}" "$([ "${BOT_EXISTING:-none}" = none ] && echo 1 || echo 0)" "$BOT_CRON")
	BOT_REPORT+=$(grep -v '^RESULT ' <<< "$res")
	res=$(sed -n 's/^RESULT //p' <<< "$res")
	[ "$res" = ok ] || { BOT_ERR=$res; return 1; }
}

# «Нет» на вопрос о боте и --no-bot запоминаются. Говорятся они до того, как установщик перечитывает настройки
# прошлого запуска («. $STATE»), а те затирали S_BOT прежним значением — отказ забывался, и вопрос задавался снова.
# Работающего бота отказ не забывает: «--no-bot» при нём значит «в этот раз не трогать» — воркер жив, и установщик
# должен о нём помнить (и предупредить, если бот знает прежние настройки).
bot_decline() { BOT_DECLINED=1; [ "${S_BOT:-}" = 1 ] || S_BOT=0; }
bot_keep_decision() { [ "${BOT_DECLINED:-0}" != 1 ] || [ "${S_BOT:-}" = 1 ] || S_BOT=0; }   # после перечитывания настроек — вернуть отказ

bot_summary() {  # строки итога установки про бота (в файл с данными доступа)
	if [ "${S_BOT:-}" = 1 ]; then
		echo
		echo "Телеграм-бот для управления VPN: @${S_BOT_USER:-?} — https://t.me/${S_BOT_USER:-}"
		echo "  клиенты, статистика, проверка блокировки раз в 3 часа, бэкапы, переезд на новый сервер кнопкой"
		[ "${BOT_RESULT:-}" != fail ] || echo "  ⚠ в этот раз бот не обновился: ${BOT_ERR:-} (повторить: bash install-vpn.sh --bot)"
		[ -z "${BOT_SKIP:-}" ] || echo "  ⚠ в этот раз бот не обновлён: $BOT_SKIP (повторить: bash install-vpn.sh --bot)"
		# Бот не обновлён, а то, на что он опирается, сменилось: при переезде он пошёл бы не туда.
		if [ "${BOT_OUTDATED:-0}" = 1 ] && [ "${BOT_RESULT:-}" != ok ] && [ -z "${BOT_SKIP:-}" ]; then
			echo "  ⚠ бот знает прежние настройки (домен, выход или порт SSH) — обновите его: bash install-vpn.sh --bot"
		fi
		if { [ -n "${BOT_SKIP:-}" ] || [ "${BOT_RESULT:-}" = fail ]; } && [ -n "${VPN_BOT_ADMIN_ID:-}" ]; then
			echo "  ⚠ админ $VPN_BOT_ADMIN_ID не добавлен"
		fi
	elif [ -n "${BOT_SKIP:-}" ] || [ "${BOT_RESULT:-}" = fail ]; then
		echo
		echo "Телеграм-бот не поставлен: ${BOT_ERR:-$BOT_SKIP}"
		echo "  повторить: bash install-vpn.sh --bot — токены скрипт спросит сам"
	fi
}

bot_decide() {  # → BOT_DO (разворачивать сейчас), BOT_KEEP (бот есть — не трогать), BOT_STALE (предложить обновить),
	# BOT_OUTDATED (бот знает прежние настройки — сказать в итоге), BOT_ASK (спросить [y/N])
	BOT_DO=0 BOT_KEEP=0 BOT_STALE=0 BOT_OUTDATED=0 BOT_ASK=0
	[ "${MODE:-}" = domain ] || return 0
	[ "${DNS_NOT_CF:-0}" != 1 ] || return 0   # домен не в Cloudflare — боту не на чем работать
	if [ "${S_BOT:-}" = 1 ]; then
		# Повтор меняет то, на что бот опирается, — без обновления он открыл бы при переезде порт не там.
		if [ "${DOMAIN:-}" != "${S_DOMAIN_OLD:-}" ] || [ "${EXIT_MODE:-}" != "${S_EXIT:-}" ] ||
			{ [ -n "${EXIT_HOST:-}" ] && [ "$EXIT_HOST" != "${CHAIN_IP:-}" ]; } ||
			{ [ -n "${EXIT_PORT_ARG:-}" ] && [ "$EXIT_PORT_ARG" != "${CHAIN_PORT:-}" ]; } ||
			{ [ -n "${S_BOT_SSH_PORT:-}" ] && [ -n "${SSH_PORT_NOW:-}" ] && [ "$S_BOT_SSH_PORT" != "$SSH_PORT_NOW" ]; }; then
			BOT_OUTDATED=1
		fi
		if [ "${BOT_ARG:-}" = 0 ]; then
			BOT_KEEP=1   # --no-bot: бота в этот раз не трогаем и токен не спрашиваем, но о нём помним
			return 0
		fi
		BOT_STALE=$BOT_OUTDATED
		if [ -n "${BOT_CF_TOKEN:-}" ] || [ "${BOT_ARG:-}" = 1 ]; then BOT_DO=1; else BOT_KEEP=1; fi
		return 0
	fi
	[ "${BOT_ARG:-}" != 0 ] || return 0
	if [ "${BOT_ARG:-}" = 1 ]; then
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
bot_extract_bundle() {  # код бота (vpn-bot 035973f) → $BOT_DIR/worker.js
	base64 -d <<'VPN_BOT_BUNDLE_EOF' | gzip -dc > "$BOT_DIR/worker.js"
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
vr23Xd1v1Vr7tfpOtd5oV7e3m5tbrdZWo1qv7u21m5vre7X1nb16faPWaFa3t3a22+uNamN/v32w
s1Hb2Vtv7a83G+u1vfVqfa/a3Nw/qG8c1BrrW42Ddm19Y3N/c3+j1qo3NtqN7Y29jS3oc6O91W5t
HjRgCPX2DvSw1d7f3KvuHRxstPbgfXVzD9602+vbm3sHexvN7Z2dg+ZGs71zUG/Ualutxl7toL3Z
2Klvb25u1NqtdmNjb32/Va9Wt1p7280aDPmgurGzvd/EBKm11sbG/jp0swMfDprbB/v1Rutg4wA+
wYc6VGyuN/d3oNxm/QAGXK9ub2zU9/Z22vsbsCZbW9WdzZ1NmMdWtbW+0Wg3mnutne1q46C21dhs
Vbdbzdp2HUa1DoVhkpv19vpmq72+117faW9t1Vu17Wp7e7OKa7i1vd6st1vVrWZ9GyaGAzuowoRb
G/XWzn67vtfaO9jc2djYrm3Vttd3djYaO1utdnNnY7PZ3qjBYOubte2d7YNmdaNWrW1s1bfbsDrN
ZqvZ3NwO91uYIIIJzOr632Hi/1cw0YSF3G/ur6/Xtqr71cYGdLC+3sRp1Jp7+we11l5zs9FuHext
b8DX7f299kEV6rWbW9DIxn51s9ra2t9b39mqHmxvNDfbtXajtdXcO4A1327t71V31tf3t2rwewcA
pNGEW7C2s9+CDaIRNffr7TbsVK1+ACPb3N/ZBjjZbOxvb21W61vr6+3W9ib0D4M5qO/VYG5be7BV
LQAu2MyNra3mJkxts4ULvb3dqu7BZjQ227AN7XoDGtxqwCT31gGk9vc29g5abQDjGnxs7G3XAWqr
zZ06PFZrteZWfb1Vqze3trfam/tb29tbtZ1mrbq3v9fc2Ktv7uzAFsG6bjYPGm0s2YRuttcbe9A9
FIJZba+3d1rNenMfILMNq7S316rD7Bv77W0A9jr+26o1agd7bTyE9e2t1sZOA4a3udeqbuzvwAbv
bOKIdwBQ4Jytr+8BaACEbuwBwO/XDjbhjAEQtdv1/a0mbEZtb39/axNgB7A4nMBqFUC0vrW/sVfd
aDZ3dtb3GrD329v7ALJwRLc3Dw72tvbhGDcR7A4a+weN9Y3WDpzGzfUaHJEYJ3zaLQPEub1kjr4x
2ZyBmdh/+Joz7a1Xy/bN8/azR7+CV5Sq7hvgOL55/vTFM/1C6tTNs6mx7l78Dy/aR1imYVTg+Hrv
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
AwA=
VPN_BOT_BUNDLE_EOF
}
BOT_SOURCE=035973f

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
foreign_on_port() {  # foreign_on_port ПОРТ [СВОЙ_ID] → id другого подключения панели на этом порту (включённого или нет:
	# панель не даст создать на нём второе); пусто — порт в панели свободен или базу нечем прочитать
	[ -f "$DB" ] || return 0
	python3 -I -c 'import sqlite3, sys
r = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True).execute(
    "select id from inbounds where port=? and id<>? order by id limit 1", (int(sys.argv[2]), int(sys.argv[3]))).fetchone()
print(r[0] if r else "")' "$DB" "$1" "${2:-0}" 2> /dev/null ||
		sqlite3 -readonly "$DB" "select id from inbounds where port=$((10#$1)) and id<>$((10#${2:-0})) order by id limit 1;" 2> /dev/null || true
}
xui_inbound_ports() {  # xui_inbound_ports [local] → «порт/протокол» включённых подключений панели, которые слушают не только
	# localhost (это нужно фаерволу); с «local» — и тех, что слушают только localhost (это нужно сверке портов).
	# Код 1 — база есть, а прочитать её не вышло: «подключений нет» и «не знаю» — разные ответы.
	[ -f "$DB" ] || return 0
	python3 -I - "$DB" "${1:-}" <<'PY' 2>/dev/null
import json, sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
local = sys.argv[2] == "local"


def obj(text):  # JSON-объект из поля базы; всё остальное (null, список, строка, не JSON) — пустой объект
    try:
        v = json.loads(text or "{}")
    except (TypeError, ValueError):
        return {}
    return v if isinstance(v, dict) else {}


def kinds_of(proto, st, ss):  # что слушает подключение: tcp, udp или оба
    proto = str(proto or "").lower()
    net = str(ss.get("network") or "tcp").lower()
    tls = ss.get("tlsSettings")
    alpn = (tls.get("alpn") if isinstance(tls, dict) else None) or []
    if proto in ("wireguard", "hysteria", "hysteria2", "tuic") or net in ("kcp", "mkcp", "quic"):
        return {"udp"}
    if net in ("xhttp", "splithttp") and "h3" in alpn:   # XHTTP поверх HTTP/3 слушает и UDP
        return {"tcp", "udp"}
    if proto in ("shadowsocks", "dokodemo-door", "tunnel"):
        n = str(st.get("network") or "tcp").lower()
        return {k for k in ("tcp", "udp") if k in n} or {"tcp"}
    if proto in ("mixed", "socks"):
        return {"tcp", "udp"} if st.get("udp") else {"tcp"}
    return {"tcp"}


out = set()
for port, listen, proto, settings, stream, enable in db.execute(
        "select port, listen, protocol, settings, stream_settings, enable from inbounds"):
    listen = str(listen or "").strip()
    try:
        port = int(port)
    except (TypeError, ValueError):
        continue
    if not enable or port <= 0 or listen.startswith(("/", "@")):   # выключено; unix-сокет порта не занимает
        continue
    if not local and (listen.startswith("127.") or listen in ("::1", "[::1]", "localhost")):
        continue
    try:
        kinds = kinds_of(proto, obj(settings), obj(stream))
    except Exception:   # строку не разобрать — порт всё равно не терять (считаем его TCP), остальные строки читаем дальше
        kinds = {"tcp"}
    out.update((port, k) for k in kinds)
for port, kind in sorted(out):
    print("%d/%s" % (port, kind))
PY
}
service_ports() {  # service_ports РЕЖИМ → «порт|зачем он скрипту»: порты, которые скрипт занимает сам (кроме порта своего подключения)
	echo "$SUB_PORT|под подписку (её отдаёт сама панель)"
	[ "$1" = domain ] || return 0
	echo "80|под nginx — выпуск и продление сертификата"
	echo "443|под nginx — сайт, панель и подписка по адресу домена"
	echo "8443|под nginx — внутренний порт сайта, под который маскируется VPN"
}
service_port_check() {  # service_port_check РЕЖИМ [ХВОСТ] — на порту, который скрипт займёт сам, у панели есть включённое подключение:
	# остановиться, пока ничего не изменено. Иначе (проверено на настоящих x-ui и Xray) не поднимается либо Xray — и не
	# работает ни одно подключение, чужое и своё, — либо сама панель.
	local p why busy
	busy=$(xui_inbound_ports local) || return 0   # базу не прочитать — сверить не с чем
	[ -n "$busy" ] || return 0
	while IFS='|' read -r p why; do
		! grep -qx "$p/tcp" <<<"$busy" ||
			die "в панели есть включённое подключение на порту $p, а этот порт нужен скрипту $why. Вдвоём на одном порту они не уживутся: не поднимется либо Xray со всеми подключениями, либо сама панель. Перенесите то подключение на другой порт (в панели) и запустите скрипт ещё раз — или ставьте VPN на чистый сервер.${2:+ $2}"
	done < <(service_ports "$1")
}
foreign_xui_check() {  # 3x-ui здесь ставили без этого скрипта: сказать, что будет, и спросить сразу — до любых вопросов и изменений
	local n msg p=${PORT_ARG:-2083}
	[ -f "$DB" ] && [ ! -f "$STATE" ] || return 0
	! compgen -G "$STATE.failed-*" > /dev/null || return 0   # следы неудачной попытки этого скрипта — 3x-ui его
	# Своё подключение скрипт создаёт сам, на своём порту, а чужие не трогает. Порт занят чужим — сказать сразу.
	if [[ $p =~ ^[0-9]{1,5}$ ]] && [ -n "$(foreign_on_port "$p")" ]; then
		die "здесь уже есть 3x-ui, поставленный не этим скриптом, и на порту $p у него есть подключение. Своё подключение скрипт создаёт на этом порту, а чужие не трогает — запустите с другим портом: bash $0 --port N. Ничего не менял"
	fi
	# То же — для портов, которые скрипт займёт сам: подписка, а с доменом (если он уже назван опцией) — ещё и nginx.
	service_port_check "$([ -n "$DOMAIN" ] && [ "$NO_DOMAIN" != 1 ] && echo domain || echo nodomain)" "Ничего не менял."
	n=$(python3 -I -c 'import sqlite3, sys; print(sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True).execute("select count(*) from inbounds").fetchone()[0])' "$DB" 2> /dev/null ||
		sqlite3 -readonly "$DB" 'select count(*) from inbounds;' 2> /dev/null || echo '?')
	msg="здесь уже есть 3x-ui, поставленный не этим скриптом (подключений: $n). Удалять его скрипт не будет: подключения и клиенты останутся, их порты фаервол не закроет. Заменятся логин, пароль, порт и путь панели, шаблон Xray (маршрутизация), адреса подписок и сама программа — на 3x-ui $XUI_VERSION. Копия базы останется рядом с ней"
	warn "$msg"
	# Вопрос задаётся в терминале, а вывод скрипта могли перенаправить (> файл): тогда объяснение — и туда, где вопрос.
	[ -t 1 ] || ! bot_tty_ok || bot_say "$msg"
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
# Своё подключение скрипт узнаёт по настройкам установки ($STATE), по порядку:
#  а) в подключении стоит ключ Reality из настроек (REALITY_PRIV) — какой бы номер ни был записан: ключ скрипт генерирует
#     сам и хранит только там, так что подключение с этим ключом создано им;
#  б) иначе — подключение с записанным номером (S_INBOUND_ID), если оно стоит на записанном порту (S_REALITY_PORT): ключи
#     ему сменили в панели — это обычное обслуживание, и повторный запуск от него ломаться не должен;
#  в) в настройках прежних версий номера нет: по ключу, иначе — VLESS + Reality на записанном порту; нет ни ключа, ни
#     порта (самые первые версии) — первое VLESS + Reality в базе, как тогда;
#  г) во всех остальных случаях своего нет. Номер совпал, а ни ключ, ни порт — нет: это чужое подключение, которому
#     достался тот же номер (базу панели сбросили, заменили или вернули из копии).
# Подключения, которые были в панели до скрипта, своими не считаются никогда: он их не переносит и не трогает.
# Ключи найденного подключения становятся ключами установки (own_to_settings): иначе на следующем запуске оно узнавалось
# бы хуже, а при пересоздании получило бы прежние ключи.
own_inbound() {  # own_inbound КЛЮЧ НОМЕР ПОРТ → «номер порт ключ открытый_ключ shortIds» своего подключения (чего нет — «-»);
	# «-» — своего нет; пусто — базу не прочитать
	[ -f "$DB" ] || { echo -; return 0; }
	command -v python3 >/dev/null 2>&1 || return 0
	# Ключ — через окружение, а не аргументом: аргументы процесса видны всем пользователям сервера (ps).
	OWN_KEY_WANT=$1 python3 -I - "$DB" "$2" "$3" <<'PY' 2>/dev/null || true
import json, os, re, sqlite3, sys
key, want, port = os.environ.get("OWN_KEY_WANT", ""), sys.argv[2], sys.argv[3]
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)


def b64(v):  # ключ Reality — base64url; всё остальное в настройки установки не переносится
    return v if isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9_-]+", v) else ""


rows = []   # все подключения: (номер, порт, это VLESS + Reality?, ключ, открытый ключ, shortIds)
for iid, p, proto, ss in db.execute("select id, port, protocol, stream_settings from inbounds order by id"):
    try:
        iid, p = int(iid), int(p)
    except (TypeError, ValueError):
        continue
    vr, priv, pub, sids = False, "", "", ""
    try:
        s = json.loads(ss or "{}")
        if s.get("security") == "reality":
            vr = str(proto or "").lower() == "vless"
            rs = s.get("realitySettings") or {}
            priv, pub = b64(rs.get("privateKey")), b64((rs.get("settings") or {}).get("publicKey"))
            ids = rs.get("shortIds")
            if isinstance(ids, list) and all(isinstance(i, str) and re.fullmatch(r"[0-9A-Fa-f]*", i) for i in ids):
                sids = ",".join(ids)
    except (TypeError, ValueError, AttributeError):   # не JSON, не объект — подключение без Reality
        pass
    rows.append((iid, p, vr, priv, pub, sids))
mine = None
if key:   # а) ключ из настроек (если таких подключений несколько — то, чей номер записан)
    mine = next(iter(sorted((r for r in rows if r[3] == key), key=lambda r: str(r[0]) != want)), None)
if mine is None and want.isdigit() and int(want) > 0 and port.isdigit():   # б) записанный номер на записанном порту
    mine = next((r for r in rows if r[0] == int(want) and r[1] == int(port)), None)
if mine is None and not want:   # в) настройки без номера
    if port.isdigit():
        mine = next((r for r in rows if r[2] and r[1] == int(port)), None)
    elif not key:
        mine = next((r for r in rows if r[2]), None)
print(" ".join(str(v) if v != "" else "-" for v in (mine[0], mine[1], mine[3], mine[4], mine[5])) if mine else "-")
PY
}
find_own_inbound() {  # → OWN_INBOUND_ID и OLD_REALITY_PORT (номер и нынешний порт своего подключения; пусто — его нет),
	# OWN_KEY, OWN_PUB, OWN_SIDS (его нынешние ключи Reality и shortIds), S_INBOUND_ID (номер для настроек: найденного
	# подключения; 0 — записанный не подтвердился), OWN_KNOWN (0 — базу панели было нечем прочитать: своё не найдено,
	# но и «не своим» ничего не объявлено)
	local got
	S_INBOUND_ID=$(state_val S_INBOUND_ID || true)
	[[ $S_INBOUND_ID =~ ^[0-9]+$ ]] || S_INBOUND_ID=
	OWN_INBOUND_ID='' OLD_REALITY_PORT='' OWN_KEY='' OWN_PUB='' OWN_SIDS='' OWN_KNOWN=1
	# Настроек установки нет — чистый сервер, чужой 3x-ui или сброшенная неудачная попытка: своего подключения ещё нет.
	if [ ! -f "$STATE" ]; then S_INBOUND_ID=0; return 0; fi
	got=$(own_inbound "$(state_val REALITY_PRIV || true)" "$S_INBOUND_ID" "$(state_val S_REALITY_PORT || true)")
	if [ -z "$got" ]; then OWN_KNOWN=0; return 0; fi
	read -r OWN_INBOUND_ID OLD_REALITY_PORT OWN_KEY OWN_PUB OWN_SIDS <<<"$got" || true
	if [[ $OWN_INBOUND_ID =~ ^[1-9][0-9]*$ ]] && [[ $OLD_REALITY_PORT =~ ^[0-9]+$ ]]; then
		S_INBOUND_ID=$OWN_INBOUND_ID
		[ "$OWN_KEY" != - ] || OWN_KEY=''
		[ "$OWN_PUB" != - ] || OWN_PUB=''
		[ "$OWN_SIDS" != - ] || OWN_SIDS=''
	else
		OWN_INBOUND_ID='' OLD_REALITY_PORT='' OWN_KEY='' OWN_PUB='' OWN_SIDS=''
		S_INBOUND_ID=${S_INBOUND_ID:+0}   # записанный номер не подтвердился — он больше ничей; не было номера — так и нет
	fi
}
own_inbound_late() {  # python3 только что поставлен: если в начале запуска базу панели было нечем прочитать — прочитать сейчас.
	# Иначе своё подключение сошло бы за чужое («порт занят») или переехало бы на порт из настроек.
	[ "$OWN_KNOWN" != 1 ] || return 0
	find_own_inbound
	[ -n "$PORT_ARG" ] || REALITY_PORT=${OLD_REALITY_PORT:-$REALITY_PORT}
}
own_to_settings() {  # сразу после чтения настроек ($STATE): номер своего подключения — подтверждённый (find_own_inbound), а не
	# просто записанный; ключи установки — те, что стоят в нём сейчас. Их могли сменить в панели, а в настройках самых
	# первых версий их не было вовсе. Переносится пара целиком (закрытый и открытый): нет в подключении открытого ключа —
	# ключи установки остаются прежними, иначе пересозданное подключение получило бы несогласованную пару.
	S_INBOUND_ID=${OWN_INBOUND_ID:-${S_INBOUND_ID:+0}}
	[ -n "$OWN_KEY" ] && [ -n "$OWN_PUB" ] && [ "$OWN_KEY" != "${REALITY_PRIV:-}" ] || return 0
	[ -z "${REALITY_PRIV:-}" ] || ok "ключи Reality своего подключения сменили в панели — запомнил нынешние"
	REALITY_PRIV=$OWN_KEY REALITY_PUB=$OWN_PUB
	[ -z "$OWN_SIDS" ] || SHORT_IDS=$OWN_SIDS
}
port_taken_check() {  # порт своего подключения или порт, который скрипт занимает сам, занят в панели другим подключением —
	# остановиться, пока ничего не изменено
	local other why=""
	other=$(foreign_on_port "$REALITY_PORT" "${OWN_INBOUND_ID:-0}")
	if [ -n "$other" ]; then
		# Повторный запуск: подсказать, почему подключение на своём же порту могло оказаться «другим».
		[ ! -f "$STATE" ] || why=" Своё подключение скрипт узнаёт по ключу Reality из $STATE или по записанным там же номеру и порту — у этого не совпало ни то, ни другое."
		die "на порту $REALITY_PORT в панели уже есть другое подключение (#$other). Скрипт его не трогает, а своему нужен свободный порт — запустите с другим: bash $0 --port N.$why"
	fi
	service_port_check "$MODE"   # и порты, которые скрипт занимает сам: подписка, с доменом — nginx
}
inbound_move() {  # inbound_move ID СТАРЫЙ_ПОРТ НОВЫЙ_ПОРТ — перенести своё подключение, и только его (x-ui остановлен)
	# Имя подключения 3x-ui содержит порт (in-2083-tcp, в старых версиях inbound-2083) — заменить в нём номер.
	python3 - "$DB" "$1" "$2" "$3" <<'PY'
import re, sqlite3, sys
path, iid, old, new = sys.argv[1:5]
db = sqlite3.connect(path)
for iid, tag in db.execute("select id, tag from inbounds where id=?", (int(iid),)).fetchall():
    newtag = re.sub(r"(?<![0-9])%s(?![0-9])" % re.escape(old), new, tag or "") or "in-%s-tcp" % new
    db.execute("update inbounds set port=?, listen='0.0.0.0', tag=? where id=?", (int(new), newtag, iid))
db.commit()
PY
}
find_own_inbound
S_REALITY_PORT=$(state_val S_REALITY_PORT || true)
forget_failed_state() {  # настройки неудачной попытки — в сторону (по этому следу foreign_xui_check потом узнает свой 3x-ui),
	# а в памяти от них не остаётся ничего: дальше установка идёт как на чистом сервере. В том числе номер подключения —
	# иначе он попал бы в новые настройки, хотя своего подключения ещё нет.
	mv -f "$STATE" "$STATE.failed-$(date +%Y%m%d-%H%M%S)"
	S_MODE='' S_DOMAIN_OLD='' S_EXIT='' S_REALITY_PORT='' S_INBOUND_ID=0 CHAIN_IP='' CHAIN_PORT='' CHAIN_UUID='' CHAIN_PUB='' CHAIN_PRIV='' CHAIN_SID='' CHAIN_SNI='' CHAIN_SSH_USER='' CHAIN_SSH_PORT=''
	OWN_INBOUND_ID='' OLD_REALITY_PORT='' OWN_KEY='' OWN_PUB='' OWN_SIDS=''
}
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
	forget_failed_state
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
	[ "$BOT_ARG" != 0 ] || bot_decline   # --no-bot запоминается
	if [ "$BOT_ASK" = 1 ]; then
		cat > /dev/tty <<'EOF'

Телеграм-бот для управления VPN: клиенты (создать — ссылка на подписку, выключить, удалить),
статистика, проверка блокировки в России раз в 3 часа, бэкапы, переезд на новый сервер кнопкой
и несколько админов (приглашение ссылкой).
Бесплатно, на вашем аккаунте Cloudflare. Нужны домен в Cloudflare и бот от @BotFather.
EOF
		if bot_consent "Поставить бота?"; then BOT_DO=1; else bot_decline; fi
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
ufw_state() {  # → active | inactive | unknown. «Выключен» — только когда ufw сам так ответил: не ответил или ответил
	# непонятно (сломан, нет iptables) — unknown, и по такому ответу нельзя ни открывать лишнее, ни закрывать.
	# Ответ — через переменную («ufw status | grep -q» под pipefail путает «включён» с «выключен») и на английском.
	local s
	s=$(LANGUAGE=C LC_ALL=C ufw status 2>/dev/null) || s=
	case $s in
		"Status: active"*) echo active ;;
		"Status: inactive"*) echo inactive ;;
		*) echo unknown ;;
	esac
}
ufw_allows() {  # ufw_allows ПОРТ [tcp|udp] — в правилах ufw уже есть разрешение (allow или limit) входящих на этот порт по
	# этому протоколу (не назван — TCP), пусть и только с одного адреса. Правила — из файлов ufw: «ufw status» у правила по имени приложения (OpenSSH) порт
	# не называет, а в файле он есть всегда. Строка правила (ufw 0.36, проверено на настоящем):
	#   ### tuple ### allow tcp 22 0.0.0.0/0 any 203.0.113.5 in
	# — действие, протокол, порты («22», «80,443», «6000:6007», «any»), куда, порты источника, откуда, [приложения,] направление.
	# Файлов нет или они другого вида — «правила нет», и скрипт разрешит порт сам, как делал всегда.
	# shellcheck disable=SC2086  # файлов два — по словам
	{ cat $UFW_RULES 2>/dev/null || true; } | awk -v p="$1" -v proto="${2:-tcp}" '
		$1 == "###" && $2 == "tuple" && $4 ~ /^(allow|limit)/ && ($5 == proto || $5 == "any") {
			dir = ($NF ~ /^comment=/) ? $(NF - 1) : $NF
			if (dir != "in" && (dir !~ /^in_/ || dir == "in_lo")) next   # исходящие, пересылка и «только на lo» — не про вход снаружи
			n = split($6, a, ",")
			for (i = 1; i <= n; i++) {
				m = split(a[i], r, ":")
				if (a[i] == "any" || (m == 1 && r[1] == p) || (m == 2 && p + 0 >= r[1] + 0 && p + 0 <= r[2] + 0)) found = 1
			}
		}
		END { exit !found }'
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

root_has_own_key() {  # у root в authorized_keys есть ключ человека. Не в счёт: ключ бота («… vpn-bot») и ключи с
	# принудительной командой — такова заглушка облачных образов («Please login as the user ubuntu…»): войти по ней нельзя
	local f=${1:-/root/.ssh/authorized_keys}
	[ -f "$f" ] && grep -qvE -e ' vpn-bot$' -e '^[[:space:]]*(#|$)' -e 'command="' "$f"
}
ssh_connection() {  # SSH_CONNECTION этого входа («адрес_клиента порт адрес_сервера порт»); пусто — вошли не по SSH.
	# sudo и «su -» её стирают — тогда она берётся из окружения родительских процессов (оболочки, из которой запущен
	# sudo). Читать переменную напрямую нельзя: под sudo скрипт не знал бы ни как вошёл человек (--ssh-key-only
	# выключал пароль тому, кто вошёл по паролю), ни откуда (IPv6, исключения fail2ban), ни через какой порт.
	local c=${SSH_CONNECTION:-} pid=$$ n=0
	while [ -z "$c" ] && [ "${pid:-0}" -gt 1 ] && [ "$n" -lt 32 ]; do
		c=$({ tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^SSH_CONNECTION=//p'; } 2>/dev/null || true)
		pid=$(awk '$1 == "PPid:" {print $2}' "/proc/$pid/status" 2>/dev/null || true)
		n=$((n + 1))
	done
	echo "${c%%$'\n'*}"
}

ssh_login_method() {  # как вошли в эту SSH-сессию: publickey | password | keyboard-interactive | пусто (не узнать)
	local cip cport rest
	read -r cip cport rest <<<"$(ssh_connection)" || true
	[ -n "${cport:-}" ] || return 0
	{ journalctl -q --no-pager -o cat -t sshd -t sshd-session 2>/dev/null || true; cat /var/log/auth.log 2>/dev/null || true; } |
		{ grep -oE "Accepted [a-z-]+ for [^ ]+ from ${cip//./\\.} port $cport( |\$)" || true; } | tail -1 | awk '{print $2}'
}

ssh_conn_port() {  # порт сервера, через который человек вошёл сейчас (из ssh_connection); пусто — вошли не по SSH
	local c
	c=$(ssh_connection)
	echo "${c##* }"
}
ssh_socket_ports() {  # порты из ListenStream у ssh.socket / sshd.socket: когда sshd запускает systemd по обращению к порту,
	# порт задан там (в том числе в drop-in), и sshd -T его не знает. Сокет, который не включён и не работает, — не в счёт.
	local u
	for u in ssh.socket sshd.socket; do
		systemctl -q is-active "$u" 2>/dev/null || systemctl -q is-enabled "$u" 2>/dev/null || continue
		{ systemctl show -p Listen --value "$u" 2>/dev/null || true; } | sed -n 's/.*:\([0-9][0-9]*\) (Stream)$/\1/p'
	done
}
sshd_listen_ports() {  # порты, которые сам sshd слушает на деле (не только на localhost). Порт, проброшенный сеансом
	# («ssh -R», X11), тоже слушает процесс sshd — но у него и родитель sshd, а у самого sshd — нет.
	local port pid ppid
	{ ss -Htlnp 2>/dev/null || true; } | awk 'match($0, /\("sshd",pid=[0-9]+/) && $4 !~ /^(127\.|\[::1\])/ {
			n = split($4, a, ":"); print a[n], substr($0, RSTART + 12, RLENGTH - 12) }' |
		while read -r port pid; do
			ppid=$(awk '$1 == "PPid:" {print $2}' "/proc/$pid/status" 2>/dev/null || true)
			[ "$(cat "/proc/${ppid:-0}/comm" 2>/dev/null || true)" = sshd ] || echo "$port"
		done
}
ssh_ports() {  # TCP-порты SSH из всех источников, без повторов; первым — как раньше, порт из sshd -T (обычно 22).
	# Одного sshd -T мало: порт, через который человек вошёл, может быть задан не в sshd_config, и фаервол его закрыл бы.
	local p
	p=$( {
		sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -un || true
		ssh_conn_port
		ssh_socket_ports
		sshd_listen_ports
	} | awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 65535 && !seen[$1]++' | tr '\n' ' ')
	p=${p% }
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

check_sub_id() {  # subId клиента, по ссылке которого проверяется туннель: первый включённый клиент своего подключения.
	# У чужих подключений панели свои клиенты и свои адреса в ссылках — проверка по ним была бы не о том. Своё подключение
	# неизвестно (настройки прежних версий) или клиентов у него нет — первый включённый клиент панели, как раньше.
	local sid=""
	if [[ ${OWN_INBOUND_ID:-} =~ ^[1-9][0-9]*$ ]]; then
		sid=$(sqlite3 -readonly "$DB" "select c.sub_id from clients c join client_inbounds ci on ci.client_id = c.id where ci.inbound_id = $OWN_INBOUND_ID and c.enable = 1 and c.sub_id <> '' order by c.id limit 1;" 2>/dev/null || true)
	fi
	[ -n "$sid" ] || sid=$(sqlite3 -readonly "$DB" "select sub_id from clients where enable=1 and sub_id<>'' order by id limit 1;" 2>/dev/null || true)
	echo "$sid"
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
	sid=$(check_sub_id)
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

db_ok() {  # db_ok ФАЙЛ — это целая база SQLite? (открывается на запись: заодно дочитывает журнал -wal, если копия с ним)
	[ -s "$1" ] || return 1
	[ "$(sqlite3 "$1" 'pragma integrity_check;' 2>/dev/null || true)" = ok ] ||
		python3 -I -c 'import sqlite3, sys
sys.exit(0 if sqlite3.connect(sys.argv[1]).execute("pragma integrity_check").fetchone()[0] == "ok" else 1)' "$1" 2>/dev/null
}
db_copy() {  # db_copy БАЗА КОПИЯ — согласованная копия базы, в которую прямо сейчас может писать x-ui; 1 — копии нет
	# 3x-ui держит базу в режиме WAL: свежие изменения лежат в x-ui.db-wal, и «cp x-ui.db» их не захватывает — у недавно
	# запущенной панели в самом x-ui.db нет ещё ничего. Поэтому копия — средствами SQLite (sqlite3, нет его — python3),
	# и только если не вышло — cp вместе с журналом. Каждая попытка проверяется: копия должна быть целой базой.
	local src=$1 dst=$2 how
	[ -f "$src" ] || return 1   # sqlite3 несуществующую базу молча создал бы пустой — и «скопировал»
	for how in sqlite3 python3 cp; do
		rm -f "$dst" "$dst-wal" "$dst-shm" "$dst-journal"
		case $how in
			sqlite3) sqlite3 "$src" ".backup '$dst'" >/dev/null 2>&1 || continue ;;
			python3)
				python3 -I -c 'import sqlite3, sys
src = sqlite3.connect(sys.argv[1])
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close()' "$src" "$dst" 2>/dev/null || continue ;;
			cp)
				cp -a "$src" "$dst" 2>/dev/null || continue
				[ ! -f "$src-wal" ] || cp -a "$src-wal" "$dst-wal" 2>/dev/null || true ;;
		esac
		if db_ok "$dst"; then
			chmod --reference="$src" "$dst" 2>/dev/null || true
			return 0
		fi
	done
	rm -f "$dst" "$dst-wal" "$dst-shm" "$dst-journal"
	return 1
}
foreign_db_copy() {  # копия базы чужого 3x-ui рядом с ней. Панель ещё работает и пишет в базу; другой копии не будет —
	# не получилась эта, дальше не идём.
	db_copy "$DB" "$DB.before-install-$(date +%Y%m%d-%H%M%S)" ||
		die "не получилась копия базы прежнего 3x-ui ($DB), а другой копии не будет — 3x-ui и его базу не трогаю. Проверьте базу (sqlite3 $DB 'pragma integrity_check;') и запустите скрипт ещё раз"
	ok "копия прежней базы 3x-ui — рядом с ней: $DB.before-install-…"
}
xui_stop() {  # остановить x-ui на время правки базы; вотчдог цепочки — тоже, чтобы не перезапустил x-ui посреди правки
	local first=0 snap=$WORK/db.before
	[ "$XUI_TOUCHED" != 0 ] || first=1
	# Отметка «x-ui трогали» — раньше самой остановки: сигнал (Ctrl-C, обрыв SSH), пришедший во время остановки, bash
	# обрабатывает сразу после неё, и on_exit уже должен знать, что x-ui надо запустить снова.
	XUI_TOUCHED=1
	systemctl stop vpn-exit-watchdog 2>/dev/null || true
	systemctl stop x-ui 2>/dev/null || true
	# Первая остановка работавшего VPN — снимок базы: оборвётся установка — база вернётся как была до запуска.
	# (Пока снимка нет, база ещё не менялась: возвращать нечего, on_exit только запустит x-ui.)
	# Своё имя снимок получает, только когда записан целиком: обрыв SSH убивает и sqlite3 (сигнал получает вся группа
	# процессов), и on_exit вернул бы в базу панели обрывок снимка — а она к этому моменту ещё не менялась.
	if [ "$first" = 1 ] && [ "$XUI_WAS_ACTIVE" = 1 ] && [ -f "$DB" ]; then
		rm -f "$snap.part"
		if { sqlite3 "$DB" ".backup '$snap.part'" 2>/dev/null && [ -s "$snap.part" ]; } ||
			{ cp -a "$DB" "$snap.part" 2>/dev/null && [ -s "$snap.part" ]; }; then
			mv -f "$snap.part" "$snap" 2>/dev/null || true
		fi
	fi
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
S_INBOUND_ID='${S_INBOUND_ID:-}'
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
unset LANGUAGE   # sudo её сохраняет, а ufw (Python) переводит по ней ответы даже при LC_ALL=C
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
# Ответ ufw — в переменную и на английском: по нему видно «включён», «выключен» и «понять не удалось» (ufw не ответил).
UFW_STATUS=$(command -v ufw >/dev/null && LANGUAGE=C LC_ALL=C ufw status 2>/dev/null || true)
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
elif command -v ufw >/dev/null && [[ $UFW_STATUS != "Status: inactive"* ]]; then
	# ufw есть, а включён ли он — понять не удалось: правило новому серверу добавляем (больше оно никому ничего не
	# открывает), ufw не включаем и «порт открыт всем» не говорим.
	ufw allow from "$ENTRY_IP" to any port "$EXIT_PORT" proto tcp >/dev/null 2>&1 || true
	echo "EXIT_UFW=unknown"
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
		unknown) warn "на старом сервере не удалось понять, включён ли ufw («ufw status» не ответил): правило для нового сервера на порт $CHAIN_PORT добавлено, но работает ли там фаервол — проверь сам: ufw status" ;;
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

ip_cert_port80() {  # перед выпуском сертификата на IP: Let's Encrypt приходит на порт 80 — во включённом ufw он должен быть разрешён.
	# → OPENED80=1, если правило добавил скрипт (сертификат не выдадут — он же его и уберёт)
	OPENED80=0
	[ "$(ufw_state)" = active ] || return 0
	! ufw_allows 80 tcp || return 0   # разрешён — пусть и не отдельным правилом «80/tcp» (80,443/tcp, профиль приложения)
	if [ "$DO_UFW" != 1 ]; then   # --no-ufw: фаервол скрипт не трогает — и здесь тоже. Сказать, чтобы открыли сами
		warn "ufw включён, а порт 80 в нём не разрешён: по нему Let's Encrypt проверяет сервер, без него сертификат на IP не выдадут и не продлят. Фаервол скрипт не трогает (--no-ufw) — откройте порт сами: ufw allow 80/tcp"
		return 0
	fi
	if ufw allow 80/tcp >/dev/null 2>&1; then OPENED80=1; fi
}
issue_ip_cert() {  # сертификат Let's Encrypt на PUBLIC_IP в $IPCERT_DIR; ошибка → IPCERT_ERR
	IPCERT_ERR=
	local rc=0 ca=letsencrypt log=$WORK/acme-ip.log have
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
	ip_cert_port80
	# Let's Encrypt проверяет сервер по http://IP/ — на время проверки acme.sh сам слушает :80 (socat).
	# Сертификат на IP бывает только коротким (профиль shortlived, ~160 ч): продление через 2–3 дня.
	"$ACME" --issue -d "$PUBLIC_IP" --standalone --httpport 80 --server "$ca" --cert-profile shortlived --days 3 \
		--keylength ec-256 > "$log" 2>&1 || rc=$?
	case $rc in
		0) ok "Let's Encrypt выдал сертификат на IP $PUBLIC_IP$([ "$ACME_STAGING" = 1 ] && echo " (тестовый центр — браузеры и приложения ему не верят)")" ;;
		2) ok "сертификат на IP $PUBLIC_IP уже есть, продлевать рано" ;;
		*)
			IPCERT_ERR=$(grep -vE '^\s*$' "$log" | tail -3 | sed -E 's/^\[[^]]*\] //' | tr '\n' ' ' | cut -c1-320)
			[ "$OPENED80" = 0 ] || ufw delete allow 80/tcp >/dev/null 2>&1 || true
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
	# Откат — до конца, что бы ни случилось: повторный сигнал (второй Ctrl-C) его не прерывает; сообщение, которое некуда
	# напечатать (терминал пропал, tee уже нет — SIGPIPE), тоже: под set -e первый же неудавшийся printf оборвал бы ловушку
	# между «x-ui остановлен» и «x-ui запущен».
	trap '' INT HUP TERM PIPE
	set +e
	[ -z "${TOKEN_ID:-}" ] || sqlite3 "$DB" "delete from api_tokens where id=$TOKEN_ID;" 2>/dev/null || true
	if [ "$rc" != 0 ] && [ "$XUI_TOUCHED" = 1 ] && [ "${INSTALL_DONE:-0}" != 1 ]; then
		if [ "$XUI_WAS_ACTIVE" = 1 ]; then
			systemctl stop x-ui >/dev/null 2>&1 || true
			if [ -s "$WORK/db.before" ] && cp -f "$WORK/db.before" "$DB"; then
				rm -f "$DB-wal" "$DB-shm"
				# Своё подключение создано в этом запуске и исчезло вместе с возвращённой базой: его номер в настройках
				# больше ничей — под ним окажется подключение, которое хозяин панели создаст следующим. Номер — «ещё не создано».
				if [ "${OWN_CREATED:-0}" = 1 ] && [ -f "$STATE" ]; then sed -i "s/^S_INBOUND_ID='[^']*'\$/S_INBOUND_ID='0'/" "$STATE" 2>/dev/null; fi
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
# Сигнал — тоже обрыв: Ctrl-C, пропавший терминал (обрыв SSH), kill. Без этих ловушек bash запускает on_exit с кодом
# последней завершившейся команды, то есть 0, — и ни база не возвращается, ни x-ui не запускается заново. Подействует
# сигнал, когда закончится текущая внешняя команда (она получает его от терминала сама и обычно завершается сразу).
# SIGPIPE — когда выводить стало некуда (tee, через который идёт весь вывод, убит): такой же обрыв.
trap 'trap "" INT HUP TERM; exit 130' INT
trap 'trap "" INT HUP TERM; exit 129' HUP
trap 'trap "" INT HUP TERM; exit 143' TERM
trap 'trap "" INT HUP TERM; exit 141' PIPE

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
	sid=$(check_sub_id)
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
# tee сигналы не слушает: от терминала их получает вся группа процессов, и без этого он умирал бы раньше, чем скрипт
# допишет, что вернул при обрыве, — в журнал это не попадало, а на экран тем более. Кончится tee сам — вместе со скриптом.
# -p: пропал тот, кто читает вывод (запуск без терминала — «ssh сервер 'bash install-vpn.sh …'», бот, — и связь оборвалась), —
# tee пишет журнал дальше, а не умирает на первой же строке, утягивая за собой скрипт посреди установки.
exec > >(trap '' INT HUP TERM; exec tee -p -a "$LOG") 2>&1
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
own_inbound_late
port_taken_check   # сначала — подключения панели: про них можно сказать точнее, чем «порт занят: xray»
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
	foreign_db_copy
fi
bot_keep_decision   # «нет» и --no-bot сказаны раньше, чем прочитаны прошлые настройки, — они главнее прочитанного
own_to_settings     # номер и ключи своего подключения — нынешние, а не просто прочитанные из настроек
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
	inbound_move "$OWN_INBOUND_ID" "$OLD_REALITY_PORT" "$REALITY_PORT" || die "не удалось перенести подключение на порт $REALITY_PORT"
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
port_taken_check   # ещё раз, перед самим созданием: панель уже работает, и база с начала запуска могла измениться
if [ -n "$OWN_INBOUND_ID" ]; then
	ok "подключение на :$REALITY_PORT уже есть (#$OWN_INBOUND_ID), клиенты прежние"
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
	# Созданное подключение — то, в котором ключ из настроек: его номер и записывается, а не «того, что стоит на порту».
	find_own_inbound
	[ -n "$OWN_INBOUND_ID" ] || die "панель приняла подключение, но в её базе его не видно — запустите скрипт ещё раз"
	OWN_CREATED=1   # для on_exit: оборвётся запуск и вернётся прежняя база — этот номер из настроек надо убрать
	if [ "$MODE" = domain ]; then
		ok "подключение VLESS + XHTTP + Reality на :$REALITY_PORT, клиентов: $CLIENTS"
	else
		ok "подключение VLESS + XHTTP + Reality на :$REALITY_PORT под $REALITY_SNI, клиентов: $CLIENTS"
	fi
fi
# Номер своего подключения — в настройки сразу, пока запуск не оборвался.
S_INBOUND_ID=$OWN_INBOUND_ID
save_state

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
SSH_FROM=$(ssh_connection); SSH_FROM=${SSH_FROM%% *}
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
SSH_NOW_PORT=$(ssh_conn_port)   # порт, через который вошли сейчас (пусто — не по SSH): фаервол его без разрешения не оставит
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
	CLIENT_IP=$(ssh_connection)   # пусто, если зашли не по SSH
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

listens_outside() {  # listens_outside ПОРТ — на этом TCP-порту кто-то слушает не только на localhost
	{ ss -Htln 2>/dev/null || true; } | awk -v p="$1" '
		{ n = split($4, a, ":") }
		a[n] == p && $4 !~ /^(127\.|\[::1\])/ { found = 1 }
		END { exit !found }'
}
fw_close() {  # fw_close ПОРТ/tcp — убрать разрешение в ufw; 1 — не тронуто: на этом порту работает подключение панели или
	# снаружи слушает кто-то ещё (сайт хозяина сервера на :80) — скрипту порт не нужен, но и закрывать его не ему
	case " $FW_INBOUND " in *" ${1%/*}/"*) return 1 ;; esac
	! listens_outside "${1%/*}" || return 1
	ufw delete allow "$1" >/dev/null 2>&1 || true
}
fw_step() {  # шаг «Фаервол ufw»: что открыть, что закрыть, включить
	local KEEP="" OPEN KEPT CLOSING p pp state inb inb_ok=1 lost="" lost_ssh="" as_is="" ssh_ok="" ssh_left="" vpn_as_is="" vpn_opened="" opened=""
	# Состояние ufw спрашивается один раз на весь шаг: от ответа зависит и что открывать, и можно ли включать. Два вопроса
	# могли получить два разных ответа — и ufw включался без разрешений, которые по первому ответу были нужны.
	state=$(ufw_state)
	# Порты включённых подключений панели, слушающих не только localhost. Скрипт их не закрывает никогда, был ufw включён
	# или нет: ни удалением разрешения (fw_close), ни включением ufw, в котором для них нет разрешения.
	inb=$(xui_inbound_ports) || inb_ok=0   # база есть, а прочитать её не вышло — на каких портах подключения, неизвестно
	FW_INBOUND=${inb//$'\n'/ }
	# ufw выключен (сам так ответил) — подключения панели сейчас доступны снаружи, и включённый ufw не должен их закрыть.
	# Включён — его правила остаются как есть; состояние не понять — лишнего не открываем.
	[ "$state" != inactive ] || KEEP=$FW_INBOUND
	# SSH. Когда ufw включает скрипт, разрешение для всех портов SSH обязательно. Когда ufw уже включён (или его состояние
	# не понять), главнее правила хозяина сервера:
	# — у порта есть разрешающее правило, пусть только с адреса админа, — общее не добавляется: оно открыло бы SSH всем,
	#   кому админ его закрыл. Нынешний вход от этого не страдает: его пускают правила, которые есть;
	# — у порта правила нет (или стоит deny), а вход по SSH разрешён через другой порт — порт остаётся как есть: общее
	#   разрешение отменило бы и явный deny. Кроме порта, через который вошли сейчас: он без разрешения не остаётся;
	# — разрешающего правила нет ни у одного порта SSH — разрешаются все, как раньше.
	if [ "$state" != inactive ]; then
		for p in $SSH_PORTS; do ! ufw_allows "$p" tcp || ssh_ok="$ssh_ok $p"; done
		for p in $SSH_PORTS; do
			if [[ " $ssh_ok " == *" $p "* ]]; then
				as_is="$as_is $p/tcp"
			elif [ -n "$ssh_ok" ] && [ "$p" != "${SSH_NOW_PORT:-}" ]; then
				as_is="$as_is $p/tcp" ssh_left="$ssh_left $p"
			fi
		done
		# Порт соседнего VPN, у которого разрешающее правило уже есть (пусть только с одной подсети), — тоже как есть.
		for pp in $OTHER_VPN_PORTS; do
			! ufw_allows "${pp%/*}" "${pp#*/}" || as_is="$as_is $pp" vpn_as_is="$vpn_as_is $pp"
		done
	fi
	OPEN=$( {
		for p in $SSH_PORTS; do echo "$p/tcp"; done   # среди них и порт нынешнего входа (ssh_ports)
		if [ "$MODE" = domain ]; then echo 80/tcp; echo 443/tcp; fi
		if [ "$PANEL_PUBLIC" = 1 ]; then echo "$WEB_PORT/tcp"; fi
		if [ "${SUB_TLS:-0}" = 1 ]; then echo 80/tcp; echo "$SUB_PORT/tcp"; fi   # :80 — продление сертификата на IP
		echo "$REALITY_PORT/tcp"
		for pp in $OTHER_VPN_PORTS $KEEP; do echo "$pp"; done
	} | sort -u | sort -t/ -k1,1n -k2,2)
	for p in $OPEN; do
		case " $as_is " in *" $p "*) continue ;; esac
		if ufw allow "$p" >/dev/null; then opened="$opened $p"; continue; fi
		bad "ufw allow $p не прошёл"
		case " $KEEP $OTHER_VPN_PORTS " in *" $p "*) lost="$lost $p" ;; esac   # то, что работает сейчас и чего включённый ufw не должен закрыть
		for pp in $SSH_PORTS; do [ "$pp/tcp" != "$p" ] || lost_ssh="$lost_ssh $pp"; done
	done
	if [ -n "$ssh_ok" ]; then
		p=${ssh_ok# }
		ok "SSH :${p// /,} уже разрешён правилами ufw — их не менял"
	fi
	if [ -n "$ssh_left" ]; then
		p=${ssh_left# }
		ok "SSH :${p// /,} в ufw не разрешён, а вход по SSH разрешён через другой порт — оставил как есть (нужен и этот: ufw allow ПОРТ/tcp)"
	fi
	KEPT=$(for pp in $KEEP; do [ "$pp" = "$REALITY_PORT/tcp" ] || [[ " $lost " == *" $pp "* ]] || printf '%s ' "$pp"; done)
	[ -z "$KEPT" ] || ok "подключения панели на других портах доступны, как раньше: ${KEPT% }"
	# «Открыл» — только про то, что действительно открыл скрипт: не про несостоявшийся «ufw allow» и не про оставленное правило.
	vpn_opened=$(for pp in $OTHER_VPN_PORTS; do [[ " $opened " != *" $pp "* ]] || printf '%s ' "$pp"; done)
	[ -z "$vpn_opened" ] || warn "рядом работает ${OTHER_VPN:-другой VPN} — открыл его порты в ufw (${vpn_opened% }), чтобы фаервол его не отрубил"
	[ -z "$vpn_as_is" ] || ok "рядом работает ${OTHER_VPN:-другой VPN}: его порты (${vpn_as_is# }) уже разрешены правилами ufw — их не менял"
	if [ "$state" = unknown ]; then
		# Включён ufw или нет — неизвестно: включение закрыло бы порты, о которых скрипт не знает, а убирать правила вслепую нельзя.
		bad "состояние ufw понять не удалось («ufw status» не ответил ни «active», ни «inactive») — включать его и убирать в нём правила не стал${opened:+; разрешения добавил:$opened}. Проверьте: ufw status"
		return 0
	fi
	if [ "$state" = inactive ] && { [ -n "$lost_ssh$lost" ] || [ "$inb_ok" = 0 ]; }; then
		[ -z "$lost_ssh" ] || bad "ufw не включал: не удалось разрешить в нём порт SSH$lost_ssh — с включённым фаерволом вы остались бы без входа на сервер. Разберитесь с ufw (ufw status) и запустите скрипт ещё раз"
		[ -z "$lost" ] || bad "ufw не включал: не удалось разрешить в нём$lost, а включённый фаервол закрыл бы то, что работает на этих портах сейчас (подключения панели, соседний VPN). Разберитесь с ufw (ufw status) и запустите скрипт ещё раз"
		[ "$inb_ok" = 1 ] || bad "ufw не включал: базу панели ($DB) прочитать не удалось, и на каких портах её подключения — неизвестно; включённый фаервол мог бы их закрыть. Запустите скрипт ещё раз"
		return 0
	fi
	if [ "$inb_ok" = 0 ]; then   # ufw включён: нужное разрешено, а убирать правила, не зная портов подключений, нельзя
		warn "базу панели ($DB) прочитать не удалось — лишние правила ufw не убирал: на каких портах её подключения, неизвестно"
	else
		if [ -n "${MOVED_FROM:-}" ] && ! grep -qx "$MOVED_FROM/tcp" <<<"$OPEN" && [ -z "$(port_users "$MOVED_FROM")" ] && fw_close "$MOVED_FROM/tcp"; then
			ok "старый порт подключения $MOVED_FROM закрыт в ufw"
		fi
		# Подписка без сертификата на IP — внутри сервера: её порт и :80 снаружи не нужны.
		if [ "$MODE" = nodomain ] && [ "${SUB_TLS:-0}" != 1 ]; then
			for p in "$SUB_PORT/tcp" 80/tcp; do grep -qx "$p" <<<"$OPEN" || fw_close "$p" || true; done
		fi
		# Панель убрали с внешнего адреса (--panel-local) — закрыть и её порт.
		if [ "$MODE" = nodomain ] && [ "$PANEL_PUBLIC" = 0 ]; then fw_close "$WEB_PORT/tcp" || true; fi
	fi
	if [ "$state" = inactive ]; then
		# Что ещё слушает снаружи, фаервол закроет — назвать, чтобы чужая служба не пропала молча.
		CLOSING=$(ss -Htuln 2>/dev/null | awk '{print $1, $5}' | while read -r proto addr; do
			case $addr in 127.* | "[::1]"* | *%lo:*) continue ;; esac
			p=${addr##*:}
			case $p in '' | *[!0-9]*) continue ;; esac
			echo "$p/$proto"
		done | sort -u | { grep -vxF -f <(printf '%s\n' 68/udp 546/udp $OPEN) || true; } | sort -t/ -k1,1n | tr '\n' ' ')
		[ -z "$CLOSING" ] || warn "фаервол закроет и порты, которые сейчас слушает этот сервер: ${CLOSING}— если там нужная служба, откройте: ufw allow ПОРТ/tcp (или /udp)"
	fi
	if ufw --force enable >/dev/null 2>&1; then
		ok "включён, открыто: $(echo $opened)"
	elif [ "$state" != inactive ]; then
		bad "ufw не включился (ufw status)"   # он был включён и до запуска: выключать его — не скрипту
	elif ufw --force disable >/dev/null 2>&1; then
		# После неудачного включения ufw оставляет политику «всё закрыто», а правила мог и не загрузить — вплоть до правила
		# для SSH (проверено на настоящем ufw 0.36.1). До запуска он был выключен — вернуть как было.
		bad "ufw не включился — вернул его в выключенное состояние, как было до запуска (после неудачного включения он оставляет «всё закрыто», иногда и для SSH). Сервер сейчас без фаервола; что мешает включению, покажет: ufw enable"
	else
		bad "ufw не включился, и выключить его обратно не удалось — проверьте, что вход по SSH работает (в новом окне, не закрывая это), и разберитесь с ufw: ufw status, ufw disable"
	fi
}
say "Фаервол ufw"
if [ "$DO_UFW" = 1 ]; then
	fw_step
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

sshd_listen_ports() {  # порты, которые сам sshd слушает на деле (не только на localhost). Порт, проброшенный сеансом
	# («ssh -R», X11), тоже слушает процесс sshd — но у него и родитель sshd, а у самого sshd — нет.
	local port pid ppid
	{ ss -Htlnp 2>/dev/null || true; } | awk 'match($0, /\("sshd",pid=[0-9]+/) && $4 !~ /^(127\.|\[::1\])/ {
			n = split($4, a, ":"); print a[n], substr($0, RSTART + 12, RLENGTH - 12) }' |
		while read -r port pid; do
			ppid=$(awk '$1 == "PPid:" {print $2}' "/proc/$pid/status" 2>/dev/null || true)
			[ "$(cat "/proc/${ppid:-0}/comm" 2>/dev/null || true)" = sshd ] || echo "$port"
		done
}

inbound_ports() {  # «порт/протокол» внешних (не loopback) включённых inbound'ов из базы $1
	# Разбор — тот же, что в install-vpn.sh (xui_inbound_ports): строка со странным содержимым (null, список, не JSON)
	# не роняет функцию. Раньше роняла — и restore под set -e обрывался на шаге фаервола.
	python3 - "$1" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)


def obj(text):  # JSON-объект из поля базы; всё остальное (null, список, строка, не JSON) — пустой объект
    try:
        v = json.loads(text or "{}")
    except (TypeError, ValueError):
        return {}
    return v if isinstance(v, dict) else {}


def kinds_of(proto, st, ss):  # что слушает подключение: tcp, udp или оба
    proto = str(proto or "").lower()
    net = str(ss.get("network") or "tcp").lower()
    tls = ss.get("tlsSettings")
    alpn = (tls.get("alpn") if isinstance(tls, dict) else None) or []
    if proto in ("wireguard", "hysteria", "hysteria2", "tuic") or net in ("kcp", "mkcp", "quic"):
        return {"udp"}
    if net in ("xhttp", "splithttp") and "h3" in alpn:   # XHTTP поверх HTTP/3 слушает и UDP
        return {"tcp", "udp"}
    if proto in ("shadowsocks", "dokodemo-door", "tunnel"):
        n = str(st.get("network") or "tcp").lower()
        return {k for k in ("tcp", "udp") if k in n} or {"tcp"}
    if proto in ("mixed", "socks"):
        return {"tcp", "udp"} if st.get("udp") else {"tcp"}
    return {"tcp"}


out = set()
for port, listen, proto, settings, stream, enable in db.execute(
        "select port, listen, protocol, settings, stream_settings, enable from inbounds"):
    listen = str(listen or "").strip()
    try:
        port = int(port)
    except (TypeError, ValueError):
        continue
    if not enable or port <= 0 or listen.startswith(("127.", "/", "@")) or listen in ("::1", "[::1]", "localhost"):
        continue
    try:
        kinds = kinds_of(proto, obj(settings), obj(stream))
    except Exception:   # строку не разобрать — порт всё равно не терять (считаем его TCP), остальные строки читаем дальше
        kinds = {"tcp"}
    out.update((port, k) for k in kinds)
for port, kind in sorted(out):
    print("%d/%s" % (port, kind))
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

# Раздел «SSH»: заголовок печатается вместе с первым сообщением раздела. Нет в бэкапе ни ключей, ни настроек SSH,
# ни fail2ban — сказать нечего, и пустой заголовок не нужен.
SSH_SAID=0
ssh_say() {
	[ "$SSH_SAID" = 1 ] || say "SSH"
	SSH_SAID=1
}
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
	ssh_say
	ok "ключи root из бэкапа добавлены ($(grep -c . /root/.ssh/authorized_keys) шт.)"
fi
if ! command -v sshd >/dev/null; then
	ssh_say
	warn "sshd не установлен — настройки SSH пропущены"
elif [ "$HARDEN_SSH" = 1 ] && [ -s /root/.ssh/authorized_keys ] && [ -f "$F/etc/ssh/sshd_config.d/00-disable-password.conf" ]; then
	ssh_say
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
	ssh_say
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
	# Порты SSH: из настроек sshd, тот, через который вошли сейчас (в том числе бот при переезде), и те, что sshd
	# слушает на деле (порт может быть задан не в sshd_config, а SSH_CONNECTION под sudo или с консоли нет).
	SSH_OPEN=$( {
		sshd -T 2>/dev/null | awk '$1=="port"{print $2"/tcp"}' || true
		[ -z "${SSH_CONNECTION:-}" ] || echo "${SSH_CONNECTION##* }/tcp"
		sshd_listen_ports | sed 's|$|/tcp|'
	} | sort -u | tr '\n' ' ')
	OPEN=$( {
		for p in $SSH_OPEN; do echo "$p"; done
		if [ "$HAS_NGINX" = 1 ]; then echo 80/tcp; echo 443/tcp; fi
		# Без домена панель может быть открыта по IP (install-vpn.sh) — её порт тоже.
		if [ -z "$DOMAIN" ] && [ "$(setting webListen)" != 127.0.0.1 ]; then echo "$(setting webPort)/tcp"; fi
		inbound_ports "$DB"
	} | sort -u -t/ -k1,1n -k2)
	SSH_LOST=""
	for p in $OPEN; do
		ufw allow "$p" >/dev/null && continue
		bad "ufw allow $p не прошёл"
		case " $SSH_OPEN " in *" $p "*) SSH_LOST="$SSH_LOST ${p%/tcp}" ;; esac
	done
	if [ -n "$SSH_LOST" ]; then
		# Перенос идёт без человека за консолью: включить фаервол, в котором SSH не разрешён, — остаться без входа на сервер.
		bad "ufw не включал: не удалось разрешить в нём порт SSH$SSH_LOST — с включённым фаерволом на сервер было бы не войти. Разберитесь с ufw и включите его сами: ufw allow ПОРТ/tcp && ufw enable"
	elif ufw --force enable >/dev/null 2>&1; then
		ok "включён, открыто: $(echo $OPEN)"
	else
		bad "ufw не включился"
	fi
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
	bot_summary
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

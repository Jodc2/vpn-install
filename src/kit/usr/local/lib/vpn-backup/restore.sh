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

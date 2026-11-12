#!/bin/sh
# Тесты install-keenetic.sh. Запуск: sh test/keenetic.test.sh [ИМЯ_ТЕСТА…]
# Набор идёт под busybox ash (оболочка Entware на роутере) и под dash. Роутер поддельный: opkg, curl, xkeen и
# служба роутера — заглушки в $WORK. Собранные настройки проверяет настоящий Xray, если дан путь к нему для
# этой машины: VPNK_TEST_XRAY=/путь/к/xray (без него такие тесты пропускаются).
# shellcheck disable=SC3043,SC2030,SC2031   # local есть в обеих оболочках; каждый тест — в своей подоболочке
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
SCRIPT=$ROOT/install-keenetic.sh

if [ -z "${VPNK_TEST_INNER:-}" ]; then
	rc=0
	for sh in "busybox ash" dash; do
		command -v "${sh%% *}" > /dev/null 2>&1 || { echo "# нет ${sh%% *} — пропуск"; continue; }
		echo "# === $sh"
		# shellcheck disable=SC2086
		VPNK_TEST_INNER="$sh" $sh "$0" "$@" || rc=1
	done
	exit $rc
fi
SH=$VPNK_TEST_INNER

t_fail() { printf '    %s\n' "$*" >&2; exit 1; }
t_eq() { [ "$1" = "$2" ] || t_fail "$3: ждали «$1», получили «$2»"; }
t_has() { case $2 in *"$1"*) ;; *) t_fail "$3: нет «$1» в «$2»" ;; esac; }
t_hasnt() { case $2 in *"$1"*) t_fail "$3: есть «$1» в «$2»" ;; esac; }

lib() {  # функции скрипта — в эту оболочку, корень системы — $WORK
	VPNK_LIB=1 VPNK_PREFIX=$WORK
	export VPNK_LIB VPNK_PREFIX
	# shellcheck source=../install-keenetic.sh
	. "$SCRIPT"
}

# Эталон разбора ссылки — тот же, что проверен на живых серверах в install-vpn.sh (link_to_xray), на Python.
oracle() {
	python3 -I -c '
import json, sys, urllib.parse as up
u = up.urlsplit(sys.argv[1])
q = {k: v[0] for k, v in up.parse_qs(u.query, keep_blank_values=True).items()}
net, sec = q.get("type", "tcp"), q.get("security", "none")
r = {"serverName": q.get("sni", ""), "fingerprint": q.get("fp") or "chrome", "publicKey": q.get("pbk", ""),
     "shortId": q.get("sid", ""), "spiderX": q.get("spx", "/")}
if q.get("pqv"):
    r["mldsa65Verify"] = q["pqv"]
ss = {"network": net, "security": sec, "realitySettings": r}
if net == "xhttp":
    x = {"path": q.get("path", "/"), "host": q.get("host", ""), "mode": q.get("mode", "auto")}
    if q.get("extra"):
        x["extra"] = json.loads(q["extra"])
    ss["xhttpSettings"] = x
user = {"id": up.unquote(u.username or ""), "encryption": q.get("encryption", "none"), "flow": q.get("flow", "")}
print(json.dumps({"tag": "vless-reality", "protocol": "vless",
                  "settings": {"vnext": [{"address": u.hostname, "port": u.port, "users": [user]}]},
                  "streamSettings": ss}, ensure_ascii=False, sort_keys=True))' "$1" | jq -S .
}

U=6f1c2d3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f
PBK=Zx3kPq7vYt1mNc8bWd5sLg2hJf4aRe6uTi9oKp0lMnB
LINK="vless://$U@vpn.example.com:2083?type=xhttp&encryption=none&path=%2F&host=&mode=auto&security=reality&pbk=$PBK&fp=chrome&sni=vpn.example.com&sid=ab12cd34&spx=%2F#home-router"

# ——— Ссылка vless:// → подключение Xray ———
test_parse_matches_reference() {
	lib
	local n=0 link
	while IFS= read -r link; do
		[ -n "$link" ] || continue
		n=$((n + 1))
		t_eq "$(oracle "$link")" "$(vpnk_parse "$link" | jq -S .outbound)" "ссылка $n ($link)"
	done <<EOF
$LINK
vless://$U@203.0.113.5:2083?type=xhttp&security=reality&pbk=$PBK&sni=www.example.org&sid=&fp=firefox&path=%2Fapi%2Fv1&host=cdn.example.org&mode=packet-up
vless://$U@[2001:db8::1]:443?type=tcp&security=reality&pbk=$PBK&sni=example.org&sid=0a&flow=xtls-rprx-vision
vless://$U@VPN.Example.COM:8443?security=reality&pbk=$PBK&sni=vpn.example.com
vless://$U@vpn.example.com:2083/?type=xhttp&security=reality&pbk=$PBK&sni=vpn.example.com&sid=ab&extra=%7B%22xmux%22%3A%7B%22maxConcurrency%22%3A%2216-32%22%2C%22hMaxRequestTimes%22%3A%22600-900%22%7D%2C%22xPaddingBytes%22%3A%22100-1000%22%7D#name
vless://$U@vpn.example.com:2083?type=xhttp&security=reality&pbk=$PBK&sni=vpn.example.com&path=%2Fa+b%2F%D0%BF%D1%83%D1%82%D1%8C&host=A.example.com&pqv=AbC_-123&spx=%2Fx%3Fy%3D1
vless://$U@vpn.example.com:2083?type=xhttp&type=tcp&security=reality&pbk=$PBK&pbk=other&sni=a.example.com&unknown=1&flag&=x
vless://%36f1c2d3e-4a5b-4c6d-8e7f-9a0b1c2d3e4f@vpn.example.com:2083?type=raw&security=reality&pbk=$PBK&sni=vpn.example.com&encryption=none&flow=
vless://$U:pass@vpn.example.com:2083?type=xhttp&security=reality&pbk=$PBK&sni=vpn.example.com&path=%2f%3F%26%3d%25&mode=stream-one
EOF
	[ "$n" -ge 9 ] || t_fail "проверено только $n ссылок"
}
test_parse_result_fields() {  # имя клиента (после #) — в UTF-8, адрес — строчными, порт — числом
	lib
	local p
	p=$(vpnk_parse "vless://$U@VPN.example.com:2083?type=xhttp&security=reality&pbk=$PBK&sni=vpn.example.com#%D0%A0%D0%BE%D1%83%D1%82%D0%B5%D1%80+1")
	t_eq "Роутер+1" "$(printf '%s' "$p" | jq -r .name)" "имя"
	t_eq "vpn.example.com 2083 number" "$(printf '%s' "$p" | jq -r '.host + " " + (.port | tostring) + " " + (.port | type)')" "адрес и порт"
	t_eq "vless-reality" "$(printf '%s' "$p" | jq -r .outbound.tag)" "имя подключения — как в шаблонах XKeen"
}
test_parse_errors() {  # непонятная ссылка — понятная причина, а не настройки с дырой
	lib
	local link want got
	while IFS='|' read -r want link; do
		[ -n "$want" ] || continue
		got=$(vpnk_parse "$link" | jq -r '.error // "нет ошибки"')
		t_has "$want" "$got" "«$link»"
	done <<EOF
не ссылка vless|просто текст
не ссылка vless|vless:$U@vpn.example.com:2083
не VLESS, а trojan|trojan://secret@vpn.example.com:443?security=tls
нет порта|vless://$U@vpn.example.com?security=reality&pbk=$PBK
нет порта|vless://$U@vpn.example.com:abc?security=reality&pbk=$PBK
вне 1–65535|vless://$U@vpn.example.com:70000?security=reality&pbk=$PBK
вне 1–65535|vless://$U@vpn.example.com:0?security=reality&pbk=$PBK
нет адреса|vless://$U@:2083?security=reality&pbk=$PBK
нет идентификатора|vless://vpn.example.com:2083?security=reality&pbk=$PBK
security=tls|vless://$U@vpn.example.com:443?type=ws&security=tls&sni=vpn.example.com
security=none|vless://$U@vpn.example.com:443?type=tcp
type=ws|vless://$U@vpn.example.com:443?type=ws&security=reality&pbk=$PBK
нет открытого ключа|vless://$U@vpn.example.com:2083?type=xhttp&security=reality&sni=vpn.example.com
extra в ссылке — не JSON|vless://$U@vpn.example.com:2083?type=xhttp&security=reality&pbk=$PBK&extra=%7Bbroken
extra в ссылке — не JSON|vless://$U@vpn.example.com:2083?type=xhttp&security=reality&pbk=$PBK&extra=%5B1%5D
EOF
}
test_parse_never_runs_link_content() {  # в ссылке — чужие данные: ни команды, ни разрыв JSON
	lib
	local evil p
	evil="vless://$U@vpn.example.com:2083?type=xhttp&security=reality&pbk=$PBK&sni=%24%28touch+$WORK%2Fpwned%29&path=%60touch+$WORK%2Fpwned%60&host=%22%2C%22x%22%3A%22y&sid=%0A%27%3B+touch+$WORK%2Fpwned#\$(touch $WORK/pwned)"
	p=$(vpnk_parse "$evil")
	[ ! -e "$WORK/pwned" ] || t_fail "содержимое ссылки выполнилось"
	t_eq "\$(touch $WORK/pwned)" "$(printf '%s' "$p" | jq -r .outbound.streamSettings.realitySettings.serverName)" "значение — как текст"
	t_eq '","x":"y' "$(printf '%s' "$p" | jq -r .outbound.streamSettings.xhttpSettings.host)" "кавычки не рвут JSON"
	vpnk_outbounds "$p" | jq -e '.outbounds | length == 3' > /dev/null || t_fail "файл настроек — не JSON"
	[ ! -e "$WORK/pwned" ] || t_fail "содержимое ссылки выполнилось при сборке настроек"
}

# ——— Подписка → ссылки ———
test_links_from_base64_subscription() {  # так отдаёт 3x-ui: base64 от списка ссылок
	lib
	local body
	body=$(printf '%s\nvless://second@vpn.example.com:1?x=1\ntrojan://x@y:1\n' "$LINK" | base64 | tr -d '\n')
	t_eq "$LINK
vless://second@vpn.example.com:1?x=1" "$(printf '%s\n' "$body" | vpnk_links)" "ссылки из base64"
	t_eq "$LINK" "$(printf '%s\r\n' "$(printf '%s\n' "$LINK" | base64 -w 20)" | vpnk_links)" "base64 с переносами и CRLF"
}
test_links_from_plain_list() {  # подписка без кодирования и прямой список
	lib
	t_eq "$LINK" "$(printf 'ss://x\r\n%s\r\n' "$LINK" | vpnk_links)" "список как есть"
}
test_links_garbage_gives_nothing() {
	lib
	t_eq "" "$(printf '<html><body>404 Not Found</body></html>\n' | vpnk_links)" "страница ошибки"
	t_eq "" "$(printf '' | vpnk_links)" "пусто"
}

# ——— Настройки Xray ———
tpl() {  # шаблоны настроек, какими их кладёт XKeen (входы redirect/tproxy на 1181 и force-proxy на 1191)
	mkdir -p "$1"
	echo '{"log": {"loglevel": "warning"}}' > "$1/01_log.json"
	cat > "$1/03_inbounds.json" <<'EOF'
{"inbounds": [
 {"protocol": "tunnel", "port": 1181, "settings": {"allowedNetwork": "tcp", "followRedirect": true},
  "sniffing": {"enabled": true, "routeOnly": true, "destOverride": ["http", "tls"]}, "tag": "redirect"},
 {"protocol": "tunnel", "port": 1181, "settings": {"allowedNetwork": "udp", "followRedirect": true},
  "streamSettings": {"sockopt": {"tproxy": "tproxy"}},
  "sniffing": {"enabled": true, "routeOnly": true, "destOverride": ["quic"]}, "tag": "tproxy"},
 {"protocol": "tunnel", "port": 1191, "settings": {"allowedNetwork": "tcp", "followRedirect": true}, "tag": "force-proxy-redirect"},
 {"protocol": "tunnel", "port": 1191, "settings": {"allowedNetwork": "udp", "followRedirect": true},
  "streamSettings": {"sockopt": {"tproxy": "tproxy"}}, "tag": "force-proxy-tproxy"}
]}
EOF
	printf '{\n// создайте файл генератором\n}\n' > "$1/04_outbounds.json"
	printf '// пример\n{"routing": {"rules": [{"inboundTag": ["redirect", "tproxy"], "outboundTag": "direct"}]}}\n' > "$1/05_routing.json"
	echo '{"policy": {"levels": {"0": {"uplinkOnly": 0, "downlinkOnly": 0}}}}' > "$1/06_policy.json"
}
test_routing_everything_through_vpn_except_home_and_server() {
	lib
	local r
	r=$(vpnk_routing "$(vpnk_parse "$LINK")")
	t_eq '["full:vpn.example.com"]' "$(printf '%s' "$r" | jq -c '[.routing.rules[] | select(.outboundTag == "direct" and has("domain"))][0].domain')" "сам сервер — напрямую"
	t_eq "vless-reality" "$(printf '%s' "$r" | jq -r '.routing.rules[-1].outboundTag')" "остальное — через VPN"
	t_eq '["redirect","tproxy"]' "$(printf '%s' "$r" | jq -c '.routing.rules[-1].inboundTag')" "входы XKeen"
	printf '%s' "$r" | jq -e '[.routing.rules[] | select(.outboundTag == "direct" and has("ip"))][0].ip | index("192.168.0.0/16") != null' > /dev/null || t_fail "домашняя сеть не напрямую"
	r=$(vpnk_routing "$(vpnk_parse "vless://$U@203.0.113.5:2083?security=reality&pbk=$PBK")")
	t_eq '["203.0.113.5"]' "$(printf '%s' "$r" | jq -c '[.routing.rules[] | select(.outboundTag == "direct" and has("ip"))][1].ip')" "сервер по IP — напрямую"
	r=$(vpnk_routing "$(vpnk_parse "vless://$U@[2001:db8::1]:2083?security=reality&pbk=$PBK")")
	t_eq '["2001:db8::1"]' "$(printf '%s' "$r" | jq -c '[.routing.rules[] | select(.outboundTag == "direct" and has("ip"))][1].ip')" "сервер по IPv6 — напрямую"
}
test_configs_accepted_by_real_xray() {  # то, что скрипт положит рядом с шаблонами XKeen, Xray принимает целиком
	[ -n "${VPNK_TEST_XRAY:-}" ] || { echo "    (пропуск: нет VPNK_TEST_XRAY)"; return 0; }
	lib
	local d=$WORK/conf p link n=0
	while IFS= read -r link; do
		[ -n "$link" ] || continue
		n=$((n + 1))
		rm -rf "$d"; tpl "$d"
		p=$(vpnk_parse "$link")
		vpnk_outbounds "$p" > "$d/04_outbounds.json"
		vpnk_routing "$p" > "$d/05_routing.json"
		vpnk_selftest_inbound > "$d/09_vpnk_selftest.json"
		XRAY_LOCATION_CONFDIR=$d "$VPNK_TEST_XRAY" -format=json -test > "$WORK/xray.out" 2>&1 || t_fail "Xray не принял настройки для ссылки $n: $(tail -3 "$WORK/xray.out")"
	done <<EOF
$LINK
vless://$U@203.0.113.5:2083?type=xhttp&security=reality&pbk=$PBK&sni=www.example.org&sid=&fp=firefox&path=%2Fapi&mode=packet-up&extra=%7B%22xmux%22%3A%7B%22maxConcurrency%22%3A%2216-32%22%7D%2C%22xPaddingBytes%22%3A%22100-1000%22%7D
vless://$U@[2001:db8::1]:443?type=tcp&security=reality&pbk=$PBK&sni=example.org&sid=0a&flow=xtls-rprx-vision
EOF
	[ "$n" = 3 ] || t_fail "проверено $n ссылок"
}

# ——— Поддельный роутер ———
router() {  # Entware в $WORK/opt, заглушки в $WORK/bin, их журнал и «ответы мира» — в $FAKE
	FAKE=$WORK/fake
	export FAKE
	mkdir -p "$WORK/bin" "$FAKE/tpl" "$FAKE/proc/net" "$WORK/opt/etc/init.d" "$WORK/opt/sbin" "$WORK/opt/tmp" "$WORK/pkg/_xkeen"
	: > "$WORK/opt/etc/opkg.conf"
	printf 'TPROXY\nREDIRECT\n' > "$FAKE/proc/net/ip_tables_targets"
	printf 'socket\ncomment\n' > "$FAKE/proc/net/ip_tables_matches"
	echo '{"release": "4.03.C.6.3-9", "title": "4.3.6.3", "model": "Giga (KN-1011)", "hw_id": "KN-1011", "region": "EA"}' > "$FAKE/version.json"
	tpl "$FAKE/tpl"
	: > "$FAKE/tunnel.ok"
	printf '%s\n' "$LINK" | base64 | tr -d '\n' > "$FAKE/sub.body"
	cat > "$WORK/bin/opkg" <<'EOF'
#!/bin/sh
echo "opkg $*" >> "$FAKE/calls"
EOF
	cat > "$WORK/bin/curl" <<'EOF'
#!/bin/sh
out= fmt= proxy= hdr= url=
while [ $# -gt 0 ]; do
	case $1 in
		-o) out=$2; shift 2 ;;
		-w) fmt=$2; shift 2 ;;
		-x) proxy=$2; shift 2 ;;
		-H) hdr="$hdr|$2"; shift 2 ;;
		-A | -m | --connect-timeout | --retry) shift 2 ;;
		-*) shift ;;
		*) url=$1; shift ;;
	esac
done
echo "curl $url${proxy:+ via $proxy}" >> "$FAKE/calls"
case $url in
	*/rci/show/version)
		code=$(cat "$FAKE/rci.code" 2> /dev/null || echo 200)
		if [ -f "$FAKE/rci.token" ]; then
			case $hdr in *"X-Ndma-Tkn: $(cat "$FAKE/rci.token")"*) code=200 ;; *) code=401 ;; esac
		fi
		if [ -n "$fmt" ]; then printf '%s' "$code"; exit 0; fi
		[ "$code" = 200 ] || exit 22
		cat "$FAKE/version.json" ;;
	*xkeen.tar.gz) [ -f "$FAKE/xkeen.tar.gz" ] || exit 22; cat "$FAKE/xkeen.tar.gz" > "$out" ;;
	*cdn-cgi/trace*)
		if [ -n "$proxy" ]; then
			[ -f "$FAKE/tunnel.ok" ] || exit 7
			printf 'fl=1\nip=203.0.113.9\nwarp=off\n'
		else
			printf 'ip=198.51.100.7\n'
		fi ;;
	https://vpn.example.com/sub/*)
		[ -f "$FAKE/sub.body" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
		cat "$FAKE/sub.body" ;;
	*) echo "curl: (6) Could not resolve host" >&2; exit 6 ;;
esac
EOF
	cat > "$WORK/pkg/xkeen" <<'EOF'
#!/bin/sh
echo "xkeen $*" >> "$FAKE/calls"
OPT=$(cd "$(dirname "$0")/.." && pwd)
case $1 in
	-i)
		[ ! -f "$FAKE/xkeen.install.fail" ] || { echo "  Ошибка: недостаточно места"; exit 1; }
		mkdir -p "$OPT/etc/xray/configs" "$OPT/etc/xray/dat"
		cp "$FAKE/tpl"/*.json "$OPT/etc/xray/configs/"
		cp "$FAKE/xray" "$OPT/sbin/xray" && chmod +x "$OPT/sbin/xray" ;;
esac
exit 0
EOF
	cat > "$FAKE/xray" <<'EOF'
#!/bin/sh
echo "xray $*" >> "$FAKE/calls"
case "$*" in
	version*) echo "Xray 26.6.1 (заглушка)" ;;
	*-test*)
		[ ! -f "$FAKE/xray.test.fail" ] || { echo "Failed to start: infra/conf: bad outbound" >&2; exit 23; }
		[ -z "${VPNK_TEST_XRAY:-}" ] || exec "$VPNK_TEST_XRAY" "$@" ;;
esac
exit 0
EOF
	printf '#!/bin/sh\necho "cron $*" >> "$FAKE/calls"\n' > "$WORK/opt/etc/init.d/S10cron"
	chmod +x "$WORK/bin/opkg" "$WORK/bin/curl" "$WORK/pkg/xkeen" "$FAKE/xray" "$WORK/opt/etc/init.d/S10cron"
	tar -czf "$FAKE/xkeen.tar.gz" -C "$WORK/pkg" xkeen _xkeen
	: > "$FAKE/calls"
	SUB=https://vpn.example.com/sub/s3cr3t
}
run() {  # run АРГУМЕНТЫ… → OUT, RC: скрипт на поддельном роутере, без терминала
	RC=0
	OUT=$(cd "$WORK" && VPNK_PREFIX=$WORK VPNK_PROC=$FAKE/proc VPNK_MODDIRS=$FAKE/nomods VPNK_WAIT=0 \
		VPNK_XKEEN_SHA256=$(sha256sum "$FAKE/xkeen.tar.gz" | cut -d' ' -f1) PATH="$WORK/bin:$PATH" \
		$SH "$SCRIPT" "$@" 2>&1 < /dev/null) || RC=$?
}
calls() { grep -c -- "$1" "$FAKE/calls" || true; }
conf() { jq -r "$2" "$WORK/opt/etc/xray/configs/$1"; }

test_install_fresh_router() {
	router
	run "$SUB"
	t_eq 0 "$RC" "установка: $OUT"
	t_eq 1 "$(calls '^xkeen -i auto cores=xray xray=v26.6.1 geo=off geoipset=off cron=off$')" "XKeen — без вопросов, только ядро Xray нужной версии"
	t_eq "vpn.example.com 2083 $U" "$(conf 04_outbounds.json '.outbounds[0].settings.vnext[0] | .address + " " + (.port | tostring) + " " + .users[0].id')" "сервер из подписки"
	t_eq "vless-reality direct block" "$(conf 04_outbounds.json '[.outbounds[].tag] | join(" ")')" "подключения"
	t_eq "socks 127.0.0.1" "$(conf 09_vpnk_selftest.json '.inbounds[0] | .protocol + " " + .listen')" "вход для самопроверки — только локальный"
	t_eq 1 "$(calls '^xray -format=json -test$')" "настройки проверены Xray до запуска"
	t_eq 1 "$(calls '^xkeen -restart$')" "XKeen перезапущен"
	t_has "через VPN интернет видит адрес 203.0.113.9" "$OUT" "туннель проверен"
	t_has "без VPN был бы 198.51.100.7" "$OUT" "и сравнён с прямым адресом"
	t_eq "$SUB" "$(cat "$WORK/opt/etc/vpn-keenetic/source")" "ссылка запомнена"
	t_eq 600 "$(stat -c %a "$WORK/opt/etc/vpn-keenetic/source")" "ссылка — только root"
	t_eq 600 "$(stat -c %a "$WORK/opt/etc/xray/configs/04_outbounds.json")" "ключи клиента — только root"
	grep -q "^17 5 \* \* \* $WORK/opt/sbin/vpn-keenetic --update" "$WORK/opt/var/spool/cron/crontabs/root" || t_fail "нет задания на обновление подписки"
	[ -x "$WORK/opt/sbin/vpn-keenetic" ] || t_fail "скрипт не положен в /opt/sbin"
	t_hasnt "s3cr3t" "$(cat "$FAKE/calls" | grep -v '^curl https://vpn.example.com/sub/')" "ссылка подписки не утекла в чужие команды"
}
test_install_checks_link_before_installing() {  # кривая ссылка — стоп до установки чего-либо
	router
	printf 'ничего полезного\n' > "$FAKE/sub.body"
	run "$SUB"
	[ "$RC" != 0 ] || t_fail "прошла с пустой подпиской"
	t_has "нет подключений VLESS" "$OUT" "причина"
	t_eq 0 "$(calls '^xkeen ')" "XKeen не трогали"
	[ ! -e "$WORK/opt/sbin/xkeen" ] || t_fail "XKeen установлен до проверки ссылки"
	rm -f "$FAKE/sub.body"
	run "$SUB"
	t_has "подписка не открылась" "$OUT" "недоступная подписка"
	t_has "404" "$OUT" "с ответом сервера"
	run "ftp://vpn.example.com/x"
	t_has "должна начинаться с https://" "$OUT" "не та ссылка"
	run
	t_has "дайте ссылку параметром" "$OUT" "без терминала и без ссылки"
}
test_install_unsupported_link_explains() {
	router
	printf 'vless://%s@vpn.example.com:443?type=ws&security=tls&sni=vpn.example.com\n' "$U" | base64 | tr -d '\n' > "$FAKE/sub.body"
	run "$SUB"
	[ "$RC" != 0 ] || t_fail "приняла ссылку не Reality"
	t_has "только VLESS + Reality" "$OUT" "причина"
	t_eq 0 "$(calls '^xkeen ')" "XKeen не трогали"
}
test_install_tunnel_down_leaves_home_online() {  # туннель не поднялся — VPN выключен, прежние настройки на месте
	router
	rm -f "$FAKE/tunnel.ok"
	run "$SUB"
	[ "$RC" != 0 ] || t_fail "сообщила об успехе без туннеля"
	t_eq 1 "$(calls '^xkeen -stop$')" "XKeen остановлен — интернет идёт напрямую"
	t_has "интернет идёт напрямую" "$OUT" "сказано человеку"
	t_eq "direct" "$(conf 05_routing.json '.routing.rules[0].outboundTag' 2> /dev/null || sed 1d "$WORK/opt/etc/xray/configs/05_routing.json" | jq -r '.routing.rules[0].outboundTag')" "прежние маршруты возвращены"
	[ ! -e "$WORK/opt/etc/xray/configs/09_vpnk_selftest.json" ] || t_fail "остался вход самопроверки"
	[ ! -s "$WORK/opt/etc/vpn-keenetic/source" ] || t_fail "неработающая ссылка запомнена"
	[ ! -s "$WORK/opt/var/spool/cron/crontabs/root" ] || t_fail "задание планировщика поставлено без рабочего туннеля"
}
test_install_config_rejected_restores() {  # Xray не принял настройки — не запускаем, возвращаем прежние
	router
	: > "$FAKE/xray.test.fail"
	run "$SUB"
	[ "$RC" != 0 ] || t_fail "прошла с отвергнутыми настройками"
	t_has "Xray не принял настройки" "$OUT" "причина"
	t_has "bad outbound" "$OUT" "с ответом Xray"
	t_eq 0 "$(calls '^xkeen -restart$')" "с негодными настройками не перезапускали"
	grep -q 'создайте файл генератором' "$WORK/opt/etc/xray/configs/04_outbounds.json" || t_fail "прежний файл не возвращён"
}
test_install_xkeen_failure_is_reported() {
	router
	: > "$FAKE/xkeen.install.fail"
	run "$SUB"
	[ "$RC" != 0 ] || t_fail "прошла при сбое установки XKeen"
	t_has "установка XKeen не прошла" "$OUT" "причина"
	t_has "недостаточно места" "$OUT" "сообщение XKeen видно"
}
test_install_refuses_tampered_xkeen() {  # архив не тот — не ставим
	router
	RC=0
	OUT=$(cd "$WORK" && VPNK_PREFIX=$WORK VPNK_PROC=$FAKE/proc VPNK_MODDIRS=$FAKE/nomods VPNK_WAIT=0 PATH="$WORK/bin:$PATH" $SH "$SCRIPT" "$SUB" 2>&1 < /dev/null) || RC=$?
	[ "$RC" != 0 ] || t_fail "поставила архив с чужой контрольной суммой"
	t_has "не совпал по контрольной сумме" "$OUT" "причина"
	[ ! -e "$WORK/opt/sbin/xkeen" ] || t_fail "чужой XKeen оказался в /opt/sbin"
}
test_rerun_keeps_xkeen_and_link() {  # повтор без ссылки: XKeen не переустанавливается, ссылка прежняя
	router
	run "$SUB"; t_eq 0 "$RC" "первый запуск: $OUT"
	: > "$FAKE/calls"
	run
	t_eq 0 "$RC" "повтор: $OUT"
	t_eq 0 "$(calls '^xkeen -i ')" "XKeen не переустанавливали"
	t_has "с прошлого запуска" "$OUT" "ссылка прежняя"
	t_has "туннель работает" "$OUT" "туннель проверен снова"
	t_eq 1 "$(grep -c 'vpn-keenetic --update' "$WORK/opt/var/spool/cron/crontabs/root")" "задание одно"
}
test_direct_vless_link_has_no_schedule() {  # прямая ссылка vless:// — перечитывать нечего
	router
	run "$LINK"
	t_eq 0 "$RC" "установка по прямой ссылке: $OUT"
	t_eq 0 "$(calls 'curl https://vpn.example.com/sub/')" "подписку не запрашивали"
	! grep -q 'vpn-keenetic --update' "$WORK/opt/var/spool/cron/crontabs/root" 2> /dev/null || t_fail "задание на обновление поставлено"
}
test_token_needed_on_new_firmware() {  # KeeneticOS 5.2: без токена доступа XKeen не работает
	router
	echo good-token > "$FAKE/rci.token"
	run "$SUB"
	[ "$RC" != 0 ] || t_fail "прошла без токена"
	t_has "токен доступа" "$OUT" "объяснено"
	t_has "Пользователи и доступ" "$OUT" "где его взять"
	t_eq 0 "$(calls '^xkeen ')" "XKeen не трогали"
	mkdir -p "$WORK/opt/etc/xkeen"
	echo '{"xkeen": {"rci_token": "good-token", "gh_proxy": ""}}' > "$WORK/opt/etc/xkeen/xkeen.json"
	run "$SUB"
	t_eq 0 "$RC" "с токеном в настройках XKeen: $OUT"
}
test_old_firmware_stops() {
	router
	echo '{"release": "3.09.C.8.0-0", "title": "3.9.8", "model": "Giga (KN-1011)"}' > "$FAKE/version.json"
	run "$SUB"
	[ "$RC" != 0 ] || t_fail "прошла на KeeneticOS 3"
	t_has "нужна 4.0 или новее" "$OUT" "причина"
	t_eq 0 "$(calls '^xkeen ')" "XKeen не трогали"
}
test_missing_kernel_modules_named() {  # нет компонента прошивки — сказать какой, до установки
	router
	: > "$FAKE/proc/net/ip_tables_targets"
	run "$SUB"
	[ "$RC" != 0 ] || t_fail "прошла без модулей ядра"
	t_has "Модули ядра подсистемы Netfilter" "$OUT" "назван компонент"
	t_has "xt_TPROXY" "$OUT" "и чего не хватает"
	t_eq 0 "$(calls '^xkeen ')" "XKeen не трогали"
	mkdir -p "$FAKE/nomods" && : > "$FAKE/nomods/xt_TPROXY.ko"   # модуль есть файлом, просто не загружен
	run "$SUB"
	t_eq 0 "$RC" "модуль на диске — годится: $OUT"
}
test_low_space_in_internal_memory() {
	router
	printf 'rootfs / rootfs rw 0 0\n/dev/ubi0_0 %s ubifs rw,relatime 0 0\n' "$WORK/opt" > "$FAKE/proc/mounts"
	VPNK_MIN_FREE_MB=999999999   # места «не хватает», сколько бы его ни было на этой машине
	export VPNK_MIN_FREE_MB
	run "$SUB"
	[ "$RC" != 0 ] || t_fail "прошла, когда во внутренней памяти мало места"
	t_has "во внутренней памяти" "$OUT" "причина"
	t_has "на флешку" "$OUT" "что делать"
	t_eq 0 "$(calls '^xkeen ')" "XKeen не трогали"
}
test_not_entware_explains() {
	router
	rm -f "$WORK/opt/etc/opkg.conf"
	run "$SUB"
	[ "$RC" != 0 ] || t_fail "прошла без Entware"
	t_has "не консоль Entware" "$OUT" "причина"
}
test_update_unchanged_touches_nothing() {
	router
	run "$SUB"; t_eq 0 "$RC" "установка: $OUT"
	: > "$FAKE/calls"
	run --update
	t_eq 0 "$RC" "обновление: $OUT"
	t_has "не изменилась" "$OUT" "итог"
	t_eq 0 "$(calls '^xkeen ')" "XKeen не перезапускали"
}
test_update_changed_subscription_applies() {  # сервер сменил порт — роутер подхватил сам
	router
	run "$SUB"; t_eq 0 "$RC" "установка: $OUT"
	printf '%s\n' "$LINK" | sed 's/:2083?/:8443?/' | base64 | tr -d '\n' > "$FAKE/sub.body"
	: > "$FAKE/calls"
	run --update
	t_eq 0 "$RC" "обновление: $OUT"
	t_eq 8443 "$(conf 04_outbounds.json '.outbounds[0].settings.vnext[0].port')" "новый порт"
	t_eq 1 "$(calls '^xkeen -restart$')" "перезапуск один"
	t_has "настройки обновлены" "$OUT" "итог"
}
test_update_broken_subscription_keeps_working_setup() {  # новые настройки не работают — остаются прежние
	router
	run "$SUB"; t_eq 0 "$RC" "установка: $OUT"
	printf '%s\n' "$LINK" | sed 's/:2083?/:8443?/' | base64 | tr -d '\n' > "$FAKE/sub.body"
	rm -f "$FAKE/tunnel.ok"
	: > "$FAKE/calls"
	run --update
	[ "$RC" != 0 ] || t_fail "приняла неработающие настройки"
	t_eq 2083 "$(conf 04_outbounds.json '.outbounds[0].settings.vnext[0].port')" "прежний порт возвращён"
	t_eq 2 "$(calls '^xkeen -restart$')" "перезапуск с новыми и ещё раз — с прежними"
	rm -f "$FAKE/sub.body"
	: > "$FAKE/calls"
	run --update
	[ "$RC" != 0 ] || t_fail "недоступная подписка — не ошибка"
	t_eq 0 "$(calls '^xkeen ')" "при недоступной подписке ничего не трогали"
	t_eq 2083 "$(conf 04_outbounds.json '.outbounds[0].settings.vnext[0].port')" "настройки целы"
}
test_status_and_switch() {
	router
	run "$SUB"; t_eq 0 "$RC" "установка: $OUT"
	run --status
	t_has "Сервер: vpn.example.com:2083" "$OUT" "сервер"
	t_has "Туннель работает, выход в интернет с адреса 203.0.113.9" "$OUT" "туннель"
	rm -f "$FAKE/tunnel.ok"
	run --status
	t_has "Туннель НЕ работает" "$OUT" "туннель лежит"
	: > "$FAKE/calls"
	run --off; t_eq 1 "$(calls '^xkeen -stop$')" "выключение"
	run --on; t_eq 1 "$(calls '^xkeen -start$')" "включение"
}
test_remove_cleans_up() {  # убрать — значит вернуть то, что было до скрипта, а не просто стереть
	router
	run "$SUB"; t_eq 0 "$RC" "установка: $OUT"
	printf '%s\n' "$LINK" | sed 's/:2083?/:8443?/' | base64 | tr -d '\n' > "$FAKE/sub.body"
	run --update; t_eq 0 "$RC" "обновление: $OUT"   # после него «прежние» — уже наши; исходные лежат отдельно
	run --remove
	t_eq 0 "$RC" "удаление: $OUT"
	[ ! -e "$WORK/opt/etc/vpn-keenetic" ] && [ ! -e "$WORK/opt/sbin/vpn-keenetic" ] || t_fail "остались настройки скрипта"
	! grep -rq "$U" "$WORK/opt/etc/xray/configs" || t_fail "остались ключи клиента"
	grep -q 'создайте файл генератором' "$WORK/opt/etc/xray/configs/04_outbounds.json" || t_fail "исходный файл XKeen не возвращён"
	[ ! -e "$WORK/opt/etc/xray/configs/09_vpnk_selftest.json" ] || t_fail "остался вход самопроверки"
	! grep -q 'vpn-keenetic' "$WORK/opt/var/spool/cron/crontabs/root" || t_fail "осталось задание планировщика"
	[ -x "$WORK/opt/sbin/xkeen" ] || t_fail "XKeen снесён, хотя обещано оставить"
}
test_help_and_unknown_option() {
	router
	run --help
	t_has "--update" "$OUT" "справка"
	t_has "--remove" "$OUT" "справка"
	run --wat
	[ "$RC" != 0 ] || t_fail "неизвестный параметр принят"
	t_eq 0 "$(calls '^xkeen ')" "ничего не делали"
}
test_script_is_posix_and_self_contained() {  # роутеру: без bash, без регулярных выражений jq, без скрытого ввода
	! grep -nE '\[\[|<<<|\$\{[A-Za-z_]+//|function |=~|read +-[a-z]*s' "$SCRIPT" || t_fail "в скрипте конструкции не из POSIX sh"
	! sed -n "/^JQ_LINK='/,/^'\$/p" "$SCRIPT" | grep -nE '\b(test|match|capture|scan|splits|sub|gsub|ascii)\(' || t_fail "в jq — функции с регулярными выражениями (в Entware их нет)"
}

PASS=0
FAILN=0
want=" $* "
for t in $(sed -n 's/^\(test_[a-z0-9_]*\)().*/\1/p' "$0"); do
	[ $# -eq 0 ] || case $want in *" $t "*) ;; *) continue ;; esac
	(
		set -eu
		WORK=$(mktemp -d)
		trap 'rm -rf "$WORK"' EXIT
		"$t"
	)
	rc=$?
	if [ "$rc" = 0 ]; then
		PASS=$((PASS + 1))
		echo "ok   $t"
	else
		FAILN=$((FAILN + 1))
		echo "FAIL $t"
	fi
done
echo "# pass $PASS"
echo "# fail $FAILN"
[ "$FAILN" = 0 ]

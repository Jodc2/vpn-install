#!/bin/sh
# install-keenetic.sh — VPN на роутер Keenetic / Netcraze с родной прошивкой (KeeneticOS 4 и новее) одной командой.
# Ставит XKeen с ядром Xray и настраивает его по ссылке на подписку 3x-ui (VLESS + Reality, транспорт XHTTP или TCP):
# после этого весь дом выходит в интернет через VPN. Подписка перечитывается сама раз в сутки.
#
# До запуска на роутере должна стоять среда Entware (лучше на флешке) — см. README, раздел «Роутер Keenetic».
# Запуск — в SSH-консоли Entware (ssh root@192.168.1.1 -p 222):
#   opkg update && opkg install curl && curl -fsSL -o /tmp/vpn-keenetic.sh https://raw.githubusercontent.com/Jodc2/vpn-install/main/install-keenetic.sh && sh /tmp/vpn-keenetic.sh
#
#   sh vpn-keenetic.sh [ССЫЛКА]   поставить или перенастроить; ссылку (подписка https://… или vless://…) спросит, если не дана
#   vpn-keenetic --update         перечитать подписку и применить, если она изменилась (так запускает планировщик)
#   vpn-keenetic --status         что сейчас настроено и работает ли туннель
#   vpn-keenetic --off | --on     выключить VPN (интернет идёт напрямую) / включить обратно
#   vpn-keenetic --remove         убрать настройки этого скрипта (XKeen остаётся: его снимает «xkeen -remove»)
#
# Повторный запуск безопасен. Сам скрипт ничего не шлёт никуда, кроме вашего сервера и проверки адреса выхода.
# shellcheck disable=SC3043   # local есть и в busybox ash (оболочка Entware), и в dash
set -eu

XKEEN_VER=${VPNK_XKEEN_VER:-2.1}
XKEEN_SHA256=${VPNK_XKEEN_SHA256:-4b9350b11fab7fd3e4973db609db0fb780994f4b5ab0096f0549bc52acac8c73}
XRAY_VER=${VPNK_XRAY_VER:-26.6.1}      # как на сервере из install-vpn.sh: клиент и сервер XHTTP — одной версии
P=${VPNK_PREFIX:-}                      # для проверки скрипта: корень поддельной системы
OPT=$P/opt
CONF_DIR=$OPT/etc/xray/configs
STATE_DIR=$OPT/etc/vpn-keenetic
XKEEN_JSON=$OPT/etc/xkeen/xkeen.json
SELF=$OPT/sbin/vpn-keenetic
CRON_FILE=$OPT/var/spool/cron/crontabs/root
SOCKS_PORT=${VPNK_SOCKS_PORT:-1090}     # локальный вход для самопроверки туннеля (только 127.0.0.1)
RCI=${VPNK_RCI:-127.0.0.1:79}
MIN_FREE_MB=${VPNK_MIN_FREE_MB:-60}
TRACE_URL=${VPNK_TRACE_URL:-https://www.cloudflare.com/cdn-cgi/trace}
PROC=${VPNK_PROC:-/proc}
MODDIRS=${VPNK_MODDIRS:-"/lib/modules/$(uname -r) $OPT/lib/modules $OPT/lib/system-modules/$(uname -r) /lib/system-modules/$(uname -r)"}
TAG=vless-reality                       # имя исходящего подключения — как в шаблонах XKeen

say() { printf '\n==> %s\n' "$*"; }
ok() { printf '  OK    %s\n' "$*"; }
warn() { printf '  ВНИМ. %s\n' "$*"; }
die() { printf '\nОстановлено: %s\n' "$*" >&2; exit 1; }
note() { command -v logger > /dev/null 2>&1 && logger -t vpn-keenetic "$*" || true; }

# ——— Ссылка vless:// → исходящее подключение Xray. Целиком на jq, без регулярных выражений: jq в Entware собран без них. ———
# shellcheck disable=SC2016
JQ_LINK='
def hexval: if . >= 48 and . <= 57 then . - 48 elif . >= 65 and . <= 70 then . - 55 elif . >= 97 and . <= 102 then . - 87 else -1 end;
def cp2utf8:
  if . < 128 then [.]
  elif . < 2048 then [192 + (. / 64 | floor), 128 + (. % 64)]
  elif . < 65536 then [224 + (. / 4096 | floor), 128 + ((. / 64 | floor) % 64), 128 + (. % 64)]
  else [240 + (. / 262144 | floor), 128 + ((. / 4096 | floor) % 64), 128 + ((. / 64 | floor) % 64), 128 + (. % 64)] end;
def pctbytes($plus):
  . as $c | length as $n | {i: 0, out: []}
  | until(.i >= $n;
      $c[.i] as $ch
      | if $ch == 37 and (.i + 2 < $n) and (($c[.i + 1] | hexval) >= 0) and (($c[.i + 2] | hexval) >= 0)
        then .out += [($c[.i + 1] | hexval) * 16 + ($c[.i + 2] | hexval)] | .i += 3
        elif $plus and $ch == 43 then .out += [32] | .i += 1
        else .out += ($ch | cp2utf8) | .i += 1 end)
  | .out;
def okcp: if (. >= 55296 and . <= 57343) or . > 1114111 or . == 0 then 65533 else . end;
def utf8str:
  reduce .[] as $b ({o: [], need: 0, cp: 0};
    if .need > 0 and $b >= 128 and $b < 192
    then .cp = .cp * 64 + ($b - 128) | .need -= 1 | if .need == 0 then .o += [.cp | okcp] else . end
    else (if .need > 0 then .o += [65533] | .need = 0 else . end)
      | if $b < 128 then .o += [$b | okcp]
        elif $b >= 192 and $b < 224 then .need = 1 | .cp = $b - 192
        elif $b >= 224 and $b < 240 then .need = 2 | .cp = $b - 224
        elif $b >= 240 and $b < 248 then .need = 3 | .cp = $b - 240
        else .o += [65533] end
    end)
  | (if .need > 0 then .o += [65533] else . end) | .o | implode;
def urld: pctbytes(false) | utf8str;
def urldq: pctbytes(true) | utf8str;
def pos($c): . as $a | (first(range(0; length) | select($a[.] == $c)) // null);
def rpos($c): . as $a | (last(range(0; length) | select($a[.] == $c)) // null);
def cut($c): pos($c) as $i | if $i == null then [., null] else [.[:$i], .[$i + 1:]] end;
def lower: map(if . >= 65 and . <= 90 then . + 32 else . end);
def digits: length > 0 and all(.[]; . >= 48 and . <= 57);
def fail($m): {error: $m};

($link | explode) as $all
| ($all | pos(58)) as $colon
| if $colon == null or ($all[$colon + 1:$colon + 3] != [47, 47]) then fail("это не ссылка vless://")
  elif ($all[:$colon] | lower | implode) != "vless" then fail("это ссылка не VLESS, а " + ($all[:$colon] | lower | implode) + " — скрипт умеет только VLESS + Reality")
  else
    ($all[$colon + 3:] | cut(35)) as [$nofrag, $frag]
    | ($nofrag | cut(63)) as [$head, $query]
    | ($head | cut(47)) as [$netloc, $path]
    | ($netloc | rpos(64)) as $at
    | (if $at == null then [] else $netloc[:$at] end | cut(58) | .[0] | urld) as $id
    | (if $at == null then $netloc else $netloc[$at + 1:] end) as $hp
    | (if ($hp | length) > 0 and $hp[0] == 91
       then ($hp | pos(93)) as $rb
         | if $rb == null then [null, null] else [($hp[1:$rb] | lower | implode), (if $hp[$rb + 1:$rb + 2] == [58] then $hp[$rb + 2:] else null end)] end
       else ($hp | rpos(58)) as $pc
         | if $pc == null then [($hp | lower | implode), null] else [($hp[:$pc] | lower | implode), $hp[$pc + 1:]] end
       end) as [$host, $portcp]
    | (reduce (($query // []) | implode | split("&") | .[] | select(length > 0)) as $pair ({};
        ($pair | split("=")) as $kv
        | ($kv[0] | explode | urldq) as $k
        | if has($k) then . else .[$k] = ($kv[1:] | join("=") | explode | urldq) end)) as $q
    | ($q.type // "tcp") as $net
    | ($q.security // "none") as $sec
    | if ($id | length) == 0 then fail("в ссылке нет идентификатора клиента (до знака @)")
      elif $host == null or ($host | length) == 0 then fail("в ссылке нет адреса сервера")
      elif $portcp == null or ($portcp | digits | not) or ($portcp | length) > 5 then fail("в ссылке нет порта сервера")
      elif ($portcp | implode | tonumber) < 1 or ($portcp | implode | tonumber) > 65535 then fail("порт сервера в ссылке вне 1–65535")
      elif $sec != "reality" then fail("скрипт умеет только VLESS + Reality, а в ссылке security=" + $sec)
      elif ($net != "xhttp" and $net != "tcp" and $net != "raw") then fail("скрипт умеет транспорт XHTTP и TCP, а в ссылке type=" + $net)
      elif (($q.pbk // "") | length) == 0 then fail("в ссылке нет открытого ключа Reality (pbk)")
      else
        (if (($q.extra // "") | length) > 0 then (try ($q.extra | fromjson) catch "bad") else null end) as $extra
        | if $extra == "bad" or ($extra != null and ($extra | type) != "object") then fail("параметр extra в ссылке — не JSON")
          else {
            name: (($frag // []) | urld),
            host: $host,
            port: ($portcp | implode | tonumber),
            outbound: {
              tag: $tag,
              protocol: "vless",
              settings: {vnext: [{address: $host, port: ($portcp | implode | tonumber),
                users: [{id: $id, encryption: ($q.encryption // "none"), flow: ($q.flow // "")}]}]},
              streamSettings: (
                {network: $net, security: $sec,
                 realitySettings: ({serverName: ($q.sni // ""), fingerprint: (if (($q.fp // "") | length) > 0 then $q.fp else "chrome" end),
                   publicKey: $q.pbk, shortId: ($q.sid // ""), spiderX: ($q.spx // "/")}
                   + (if (($q.pqv // "") | length) > 0 then {mldsa65Verify: $q.pqv} else {} end))}
                + (if $net == "xhttp"
                   then {xhttpSettings: ({path: ($q.path // "/"), host: ($q.host // ""), mode: ($q.mode // "auto")}
                     + (if $extra != null then {extra: $extra} else {} end))}
                   else {} end))
            }
          } end
      end
  end
'

vpnk_parse() {  # vpnk_parse ССЫЛКА → JSON {name, host, port, outbound} или {error}
	jq -cn --arg link "$1" --arg tag "$TAG" "$JQ_LINK"
}

# Подписка: тело ответа (base64 от списка ссылок, как отдаёт 3x-ui, или сам список) → строки vless://
vpnk_links() {
	local body dec
	body=$(cat)
	dec=$(printf '%s' "$body" | tr -d ' \t\r\n' | jq -Rr '@base64d' 2> /dev/null) || dec=
	case $dec in *://*) ;; *) dec=$body ;; esac
	printf '%s\n' "$dec" | tr -d '\r' | grep -i '^vless://' || true
}

# Настройки Xray: исходящие подключения, маршруты и локальный вход для самопроверки.
vpnk_outbounds() {  # vpnk_outbounds РАЗОБРАННАЯ_ССЫЛКА(JSON)
	printf '%s' "$1" | jq '{outbounds: [.outbound, {tag: "direct", protocol: "freedom"}, {tag: "block", protocol: "blackhole"}]}'
}
vpnk_routing() {  # vpnk_routing РАЗОБРАННАЯ_ССЫЛКА(JSON) — всё через VPN, кроме домашних адресов и самого сервера
	printf '%s' "$1" | jq --arg tag "$TAG" '
	def isip: (explode | any(.[]; . == 58)) or (length > 0 and (explode | all(.[]; . == 46 or (. >= 48 and . <= 57))));
	.host as $h
	| {routing: {domainStrategy: "AsIs", rules: [
		{inboundTag: ["vpnk-selftest"], outboundTag: $tag},
		{inboundTag: ["force-proxy-redirect", "force-proxy-tproxy"], outboundTag: $tag},
		{ip: ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
			"224.0.0.0/3", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"], outboundTag: "direct"},
		(if ($h | isip) then {ip: [$h], outboundTag: "direct"} else {domain: ["full:" + $h], outboundTag: "direct"} end),
		{network: "udp", port: "443", outboundTag: "block"},
		{ip: ["::/0"], outboundTag: "block"},
		{inboundTag: ["redirect", "tproxy"], outboundTag: $tag}
	]}}'
}
vpnk_selftest_inbound() {
	jq -n --argjson port "$SOCKS_PORT" '{inbounds: [{tag: "vpnk-selftest", listen: "127.0.0.1", port: $port, protocol: "socks", settings: {udp: false}}]}'
}

# ——— Роутер ———
rci_token() {  # токен доступа к роутеру из настроек XKeen (нужен с KeeneticOS 5.2); нет — пусто
	[ -f "$XKEEN_JSON" ] || return 0
	jq -r '.xkeen.rci_token // empty' "$XKEEN_JSON" 2> /dev/null || true
}
rci_code() { curl --connect-timeout 2 -m 5 -ks -o /dev/null -w '%{http_code}' ${1:+-H "X-Ndma-Tkn: $1"} "$RCI/rci/show/version" 2> /dev/null || true; }
rci_get() { curl --connect-timeout 2 -m 5 -kfs ${2:+-H "X-Ndma-Tkn: $2"} "$RCI/rci/$1" 2> /dev/null || true; }

ask() {  # ask ВОПРОС → ANSWER (ввод виден); спросить некого — 1
	ANSWER=
	[ -t 0 ] || return 1
	printf '%s' "$1"
	IFS= read -r ANSWER || ANSWER=
	ANSWER=$(printf '%s' "$ANSWER" | tr -d ' \t\r')
}

need_entware() {
	[ -f "$OPT/etc/opkg.conf" ] && command -v opkg > /dev/null 2>&1 ||
		die "это не консоль Entware. Сначала поставьте на роутер Entware (README, раздел «Роутер Keenetic») и зайдите так: ssh root@192.168.1.1 -p 222"
}

check_router() {
	local code token ver major model dev free mods m d found missing=
	say "Проверка роутера"
	command -v curl > /dev/null 2>&1 && command -v jq > /dev/null 2>&1 || die "нет curl или jq — не установились пакеты Entware"
	token=$(rci_token)
	code=$(rci_code "$token")
	case $code in
		401 | 403)
			warn "роутер требует токен доступа (так с KeeneticOS 5.2): без него XKeen не узнает настройки роутера"
			printf '%s\n' "  Создайте токен в веб-интерфейсе роутера: «Управление» → «Пользователи и доступ» → добавить токен → скопировать."
			ask "  Вставьте токен: " || die "нужен токен доступа к роутеру — запустите скрипт в терминале, он спросит"
			[ -n "$ANSWER" ] || die "токен не введён"
			token=$ANSWER
			code=$(rci_code "$token")
			[ "$code" = 200 ] || die "роутер не принял токен (ответ $code) — создайте новый и запустите скрипт ещё раз"
			mkdir -p "$(dirname "$XKEEN_JSON")"
			if [ -s "$XKEEN_JSON" ] && jq -e . "$XKEEN_JSON" > /dev/null 2>&1; then
				jq --arg t "$token" '.xkeen.rci_token = $t' "$XKEEN_JSON" > "$XKEEN_JSON.new"
			else
				jq -n --arg t "$token" '{xkeen: {rci_token: $t}}' > "$XKEEN_JSON.new"
			fi
			chmod 600 "$XKEEN_JSON.new" && mv -f "$XKEEN_JSON.new" "$XKEEN_JSON"
			ok "токен принят и сохранён в настройках XKeen"
			;;
		200) ;;
		*) die "не отвечает служба роутера ($RCI, ответ ${code:-нет}) — это точно Keenetic с KeeneticOS? Скрипт запускается в SSH-консоли Entware на самом роутере" ;;
	esac
	ver=$(rci_get show/version "$token")
	major=$(printf '%s' "$ver" | jq -r '.release // empty' 2> /dev/null | cut -d. -f1)
	model=$(printf '%s' "$ver" | jq -r '.model // .hw_id // empty' 2> /dev/null)
	case $major in
		'' | *[!0-9]*) warn "не удалось узнать версию KeeneticOS — продолжаю (XKeen нужна версия 4 или новее)" ;;
		*)
			[ "$major" -ge 4 ] || die "на роутере KeeneticOS $(printf '%s' "$ver" | jq -r '.title // .release'), а XKeen нужна 4.0 или новее — обновите прошивку в веб-интерфейсе"
			ok "${model:-Keenetic}, KeeneticOS $(printf '%s' "$ver" | jq -r '.title // .release')"
			;;
	esac
	# Где стоит Entware и хватит ли места ядру Xray (≈30 МБ, XKeen просит 45).
	dev=$(awk -v o="$OPT" '$2 == o {d = $1} END {print d}' "$PROC/mounts" 2> /dev/null || true)
	free=$(df -m "$OPT" 2> /dev/null | awk 'NR == 2 {print $4}')
	case $free in '' | *[!0-9]*) free= ;; esac
	if [ ! -x "$OPT/sbin/xray" ] && [ -n "$free" ] && [ "$free" -lt "$MIN_FREE_MB" ]; then
		case $dev in
			/dev/ubi*) die "Entware стоит во внутренней памяти роутера, и там свободно только $free МБ — ядру Xray нужно $MIN_FREE_MB. Поставьте Entware на флешку (README, раздел «Роутер Keenetic»)" ;;
			*) die "на накопителе с Entware свободно $free МБ, а нужно $MIN_FREE_MB" ;;
		esac
	fi
	case $dev in
		/dev/ubi*) warn "Entware стоит во внутренней памяти роутера: авторы XKeen ручаются только за установку на флешку" ;;
		*) ok "Entware на накопителе ${dev:-?}${free:+, свободно $free МБ}" ;;
	esac
	# Без этих модулей ядра XKeen не перехватит трафик.
	mods=" $(cat "$PROC/net/ip_tables_matches" "$PROC/net/ip_tables_targets" 2> /dev/null | tr '\n' ' ') $(awk '{print $1}' "$PROC/modules" 2> /dev/null | tr '\n' ' ') "
	for m in TPROXY socket comment; do
		case $mods in *" $m "* | *" xt_$m "*) continue ;; esac
		found=0
		for d in $MODDIRS; do [ ! -f "$d/xt_$m.ko" ] || found=1; done
		[ "$found" = 1 ] || missing="$missing xt_$m"
	done
	[ -z "$missing" ] ||
		die "в прошивке нет модулей ядра${missing} — установите компонент «Модули ядра подсистемы Netfilter»: «Управление» → «Параметры системы» → «Изменить набор компонентов», затем запустите скрипт снова"
	ok "модули ядра для перехвата трафика на месте"
}

# ——— Ссылка и подписка ———
source_get() {  # → SOURCE: ссылка из параметра, из прошлого запуска или вопросом
	SOURCE=${1:-}
	if [ -z "$SOURCE" ] && [ -s "$STATE_DIR/source" ]; then
		SOURCE=$(cat "$STATE_DIR/source")
		ok "ссылка — с прошлого запуска (другую можно дать параметром)"
	fi
	if [ -z "$SOURCE" ]; then
		printf '%s\n' "" "Нужна ссылка на подписку для этого роутера — в боте: «Клиенты» → «➕ Добавить» (имя «роутер») или «Ссылка на подписку»." \
			"Подойдёт и прямая ссылка vless://…"
		ask "Ссылка: " || die "дайте ссылку параметром: sh $0 ССЫЛКА"
		SOURCE=$ANSWER
	fi
	case $SOURCE in
		https://?* | http://?* | [Vv][Ll][Ee][Ss][Ss]://?*) ;;
		*) die "ссылка должна начинаться с https:// (подписка) или vless:// (сейчас: «$(printf '%s' "$SOURCE" | cut -c1-40)»)" ;;
	esac
}

links_fetch() {  # → LINKS (строки vless://) по SOURCE; 1 и ERR — не вышло
	local body
	ERR='' LINKS=''
	case $SOURCE in
		[Vv][Ll][Ee][Ss][Ss]://*) LINKS=$SOURCE; return 0 ;;
	esac
	body=$(curl -fsSL --connect-timeout 10 -m 25 --retry 2 -A "vpn-keenetic" "$SOURCE" 2> "$WORK/curl.err") || {
		ERR="подписка не открылась ($(tr -d '\r' < "$WORK/curl.err" | tail -1 | sed 's/^curl: *//' | cut -c1-160))"
		return 1
	}
	LINKS=$(printf '%s' "$body" | vpnk_links)
	[ -n "$LINKS" ] || { ERR="по ссылке нет подключений VLESS — это точно ссылка на подписку?"; return 1; }
}

link_pick() {  # → PARSED (JSON разобранной ссылки) из LINKS; несколько серверов — прежний выбор или вопрос; 1 и ERR — не вышло
	local n want i line p name
	ERR='' PARSED=''
	n=$(printf '%s\n' "$LINKS" | grep -c .)
	want=${VPNK_SERVER:-}
	[ -n "$want" ] || { [ ! -s "$STATE_DIR/index" ] || want=$(cat "$STATE_DIR/index"); }
	case $want in '' | *[!0-9]*) want= ;; esac
	if [ "$n" -gt 1 ] && [ -z "$want" ] && [ "${MODE:-install}" = install ] && [ -t 0 ]; then
		printf '%s\n' "" "В подписке несколько серверов:"
		i=0
		printf '%s\n' "$LINKS" | while IFS= read -r line; do
			i=$((i + 1))
			name=$(vpnk_parse "$line" | jq -r 'if has("error") then "(не подходит: " + .error + ")" else (.name + " — " + .host) end')
			printf '  %s) %s\n' "$i" "$name"
		done
		ask "Какой использовать [1]: " || true
		want=$ANSWER
		case $want in '' | *[!0-9]*) want=1 ;; esac
	fi
	[ -n "$want" ] && [ "$want" -ge 1 ] && [ "$want" -le "$n" ] || want=1
	line=$(printf '%s\n' "$LINKS" | sed -n "${want}p")
	p=$(vpnk_parse "$line") || { ERR="ссылку не удалось разобрать"; return 1; }
	if printf '%s' "$p" | jq -e 'has("error")' > /dev/null; then
		ERR=$(printf '%s' "$p" | jq -r .error)
		return 1
	fi
	PARSED=$p INDEX=$want
}

# ——— XKeen ———
fetch_release() {  # fetch_release URL ФАЙЛ — с GitHub, а если он не отвечает, через зеркала; целость проверяет вызывающий
	local u
	for u in "$1" "https://gh-proxy.com/$1" "https://ghfast.top/$1"; do
		curl -fsSL --connect-timeout 10 -m 60 -o "$2" "$u" 2> /dev/null && [ -s "$2" ] && return 0
	done
	return 1
}
sha256_of() {
	if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
	elif command -v openssl > /dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
	fi
}

xkeen_install() {
	local tgz stage sum
	if [ -x "$OPT/sbin/xkeen" ] && [ -x "$OPT/sbin/xray" ] && [ -d "$CONF_DIR" ]; then
		ok "XKeen и ядро Xray уже стоят ($("$OPT/sbin/xray" version 2> /dev/null | head -1 | cut -d' ' -f1-2))"
		return 0
	fi
	say "XKeen $XKEEN_VER и ядро Xray $XRAY_VER (несколько минут)"
	if [ ! -x "$OPT/sbin/xkeen" ]; then
		tgz=$WORK/xkeen.tar.gz
		fetch_release "https://github.com/jameszeroX/XKeen/releases/download/$XKEEN_VER/xkeen.tar.gz" "$tgz" ||
			die "не скачался XKeen с GitHub (и через зеркала) — проверьте интернет на роутере и запустите ещё раз"
		command -v sha256sum > /dev/null 2>&1 || command -v openssl > /dev/null 2>&1 || opkg install coreutils-sha256sum > /dev/null 2>&1 || true
		sum=$(sha256_of "$tgz")
		[ "$sum" = "$XKEEN_SHA256" ] || die "архив XKeen не совпал по контрольной сумме (получено ${sum:-ничего}) — скачан не тот файл, ставить не буду"
		stage=$OPT/sbin/.vpnk-xkeen.$$
		rm -rf "$stage" && mkdir -p "$stage"
		tar -xzf "$tgz" -C "$stage" && [ -f "$stage/xkeen" ] && [ -d "$stage/_xkeen" ] || { rm -rf "$stage"; die "архив XKeen не распаковался"; }
		chmod +x "$stage/xkeen"
		rm -rf "$OPT/sbin/.xkeen"
		mv "$stage/_xkeen" "$OPT/sbin/.xkeen" && mv "$stage/xkeen" "$OPT/sbin/xkeen" || { rm -rf "$stage"; die "не удалось положить XKeen в $OPT/sbin"; }
		rm -rf "$stage"
		ok "XKeen $XKEEN_VER скачан, контрольная сумма сошлась"
	fi
	# Без вопросов: только ядро Xray нужной версии; базы адресов не нужны — через VPN идёт всё.
	"$OPT/sbin/xkeen" -i auto cores=xray "xray=v$XRAY_VER" geo=off geoipset=off cron=off < /dev/null ||
		die "установка XKeen не прошла (сообщение — выше). Частые причины: нет токена доступа, мало места, не отвечает GitHub. Повторный запуск продолжит с этого места"
	[ -x "$OPT/sbin/xray" ] && [ -d "$CONF_DIR" ] || die "XKeen отработал, но ядра Xray или папки $CONF_DIR нет — пришлите вывод выше"
	ok "XKeen и ядро Xray установлены, автозапуск включён"
}

# ——— Настройки и запуск ———
FILES="04_outbounds.json 05_routing.json 09_vpnk_selftest.json"   # файлы настроек Xray, которые ведёт этот скрипт
configs_keep() {  # configs_keep ПАПКА — запомнить в ней нынешние файлы (которого нет — пометкой .absent)
	local f
	mkdir -p "$1"
	rm -f "$1"/*.json "$1"/*.absent
	for f in $FILES; do
		if [ -f "$CONF_DIR/$f" ]; then cp -p "$CONF_DIR/$f" "$1/$f"; else : > "$1/$f.absent"; fi
	done
}
configs_back() {  # configs_back ПАПКА — вернуть файлы, как они запомнены в ней
	local f
	for f in $FILES; do
		if [ -f "$1/$f" ]; then cp -p "$1/$f" "$CONF_DIR/$f"
		elif [ -f "$1/$f.absent" ]; then rm -f "$CONF_DIR/$f"
		fi
	done
}
configs_write() {  # новые файлы из PARSED → CHANGED=1, если что-то изменилось; прежние — в prev, самые первые — в original
	local f
	CHANGED=0
	mkdir -p "$WORK/new" "$STATE_DIR"
	chmod 700 "$STATE_DIR"
	vpnk_outbounds "$PARSED" > "$WORK/new/04_outbounds.json"
	vpnk_routing "$PARSED" > "$WORK/new/05_routing.json"
	vpnk_selftest_inbound > "$WORK/new/09_vpnk_selftest.json"
	for f in $FILES; do
		[ -s "$WORK/new/$f" ] || die "не собрался файл настроек $f"
		cmp -s "$WORK/new/$f" "$CONF_DIR/$f" 2> /dev/null && continue
		CHANGED=1
	done
	[ "$CHANGED" = 1 ] || return 0
	[ -d "$STATE_DIR/original" ] || configs_keep "$STATE_DIR/original"   # то, что было до этого скрипта, — для --remove
	configs_keep "$STATE_DIR/prev"
	for f in $FILES; do
		cp "$WORK/new/$f" "$CONF_DIR/$f.vpnk-new" && chmod 600 "$CONF_DIR/$f.vpnk-new" && mv -f "$CONF_DIR/$f.vpnk-new" "$CONF_DIR/$f"
	done
}
configs_restore() { configs_back "$STATE_DIR/prev"; }   # вернуть файлы, которые были до configs_write

tunnel_ip() {  # адрес, под которым интернет видит роутер через VPN; пусто — туннель не работает
	local i out
	for i in 1 2 3 4 5 6; do
		out=$(curl -s --connect-timeout 5 -m 12 -x "socks5h://127.0.0.1:$SOCKS_PORT" "$TRACE_URL" 2> /dev/null | sed -n 's/^ip=//p' | head -1) || out=
		[ -z "$out" ] || { printf '%s' "$out"; return 0; }
		sleep "${VPNK_WAIT:-3}"
	done
	return 0
}

apply() {  # проверить настройки, запустить и убедиться, что туннель работает; иначе вернуть как было. → VPN_IP
	local out
	VPN_IP=
	if ! out=$(XRAY_LOCATION_CONFDIR="$CONF_DIR" XRAY_LOCATION_ASSET="$OPT/etc/xray/dat" "$OPT/sbin/xray" -format=json -test 2>&1 < /dev/null); then
		configs_restore
		die "Xray не принял настройки, вернул прежние. Его ответ: $(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-300)"
	fi
	"$OPT/sbin/xkeen" -restart < /dev/null > "$WORK/xkeen.out" 2>&1 || true
	VPN_IP=$(tunnel_ip)
	[ -n "$VPN_IP" ]
}

cron_set() {  # раз в сутки перечитывать подписку (для прямой ссылки vless:// не нужно)
	local line="17 5 * * * $SELF --update > /dev/null 2>&1"
	mkdir -p "$(dirname "$CRON_FILE")"
	touch "$CRON_FILE"
	grep -v 'vpn-keenetic --update' "$CRON_FILE" > "$WORK/cron" || true
	case $SOURCE in
		[Vv][Ll][Ee][Ss][Ss]://*) ;;
		*) printf '%s\n' "$line" >> "$WORK/cron" ;;
	esac
	cmp -s "$WORK/cron" "$CRON_FILE" || { cp "$WORK/cron" "$CRON_FILE.vpnk-new" && chmod 600 "$CRON_FILE.vpnk-new" && mv -f "$CRON_FILE.vpnk-new" "$CRON_FILE"; }
	case $SOURCE in [Vv][Ll][Ee][Ss][Ss]://*) return 0 ;; esac
	[ -x "$OPT/etc/init.d/S10cron" ] || opkg install cron > /dev/null 2>&1 || true
	if [ -x "$OPT/etc/init.d/S10cron" ]; then
		"$OPT/etc/init.d/S10cron" restart > /dev/null 2>&1 || "$OPT/etc/init.d/S10cron" start > /dev/null 2>&1 || true
		ok "подписка перечитывается сама раз в сутки (в 05:17)"
	else
		warn "планировщик cron не установился — подписка сама обновляться не будет (вручную: vpn-keenetic --update)"
	fi
}

state_save() {
	mkdir -p "$STATE_DIR"
	chmod 700 "$STATE_DIR"
	(umask 077 && printf '%s\n' "$SOURCE" > "$STATE_DIR/source" && printf '%s\n' "$INDEX" > "$STATE_DIR/index" && date '+%F %R' > "$STATE_DIR/updated")
}

do_install() {
	local direct host
	MODE=install
	need_entware
	say "Пакеты Entware"
	opkg update > /dev/null 2>&1 || warn "список пакетов не обновился — если дальше не найдётся пакет, замените зеркало: sed -i 's,http://bin.entware.net/,http://mirrors.nju.edu.cn/entware/,g' $OPT/etc/opkg.conf"
	opkg install curl jq tar ca-bundle > /dev/null 2>&1 || true
	command -v curl > /dev/null 2>&1 && command -v jq > /dev/null 2>&1 && command -v tar > /dev/null 2>&1 || die "не установились пакеты curl, jq, tar (нет доступа к репозиторию Entware?)"
	ok "curl, jq, tar"
	check_router
	say "Подписка"
	source_get "${1:-}"
	links_fetch || die "$ERR"
	link_pick || die "$ERR"
	host=$(printf '%s' "$PARSED" | jq -r '.host + ":" + (.port | tostring)')
	ok "сервер $host ($(printf '%s' "$PARSED" | jq -r '.outbound.streamSettings.network | ascii_upcase') + Reality)$(printf '%s' "$PARSED" | jq -r 'if (.name | length) > 0 then ", клиент «" + .name + "»" else "" end')"
	xkeen_install
	say "Настройки и запуск"
	configs_write
	if apply; then
		state_save
		if [ -f "$0" ] && [ "$(readlink -f "$0" 2> /dev/null || echo "$0")" != "$SELF" ]; then cp "$0" "$SELF.new" && chmod 755 "$SELF.new" && mv -f "$SELF.new" "$SELF"; fi
		direct=$(curl -s --connect-timeout 5 -m 12 "$TRACE_URL" 2> /dev/null | sed -n 's/^ip=//p' | head -1) || direct=
		ok "туннель работает: через VPN интернет видит адрес $VPN_IP${direct:+ (без VPN был бы $direct)}"
		cron_set
		note "VPN настроен: сервер $host, выход $VPN_IP"
		cat <<EOF

Готово: весь дом выходит в интернет через VPN (проверка с любого устройства: https://2ip.ru — должен быть адрес $VPN_IP).

  Выключить VPN:            vpn-keenetic --off     (интернет идёт напрямую; включить — vpn-keenetic --on)
  Что сейчас:               vpn-keenetic --status
  Через VPN — не все:       в веб-интерфейсе роутера создайте политику доступа в интернет с именем xkeen и перенесите
                            в неё нужные устройства, затем: xkeen -restart. Без такой политики через VPN идут все.
  Важно:                    в роутере должен быть задан шифрованный DNS (DNS-over-TLS или DNS-over-HTTPS), иначе часть
                            сайтов может не открываться: README, раздел «Роутер Keenetic», шаг про DNS.
EOF
	else
		# Туннель не поднялся: дом не должен остаться без интернета.
		"$OPT/sbin/xkeen" -stop < /dev/null > /dev/null 2>&1 || true
		configs_restore
		die "туннель до сервера $host не заработал — VPN выключен, интернет идёт напрямую, прежние настройки возвращены.
Что проверить: ссылка свежая и клиент не выключен в боте; сервер работает (на нём: vpn-check); в роутере задан шифрованный DNS.
Ответ XKeen: $(tail -4 "$WORK/xkeen.out" 2> /dev/null | sed "s/$(printf '\033').[0-9;]*m//g" | tr '\n' ' ' | cut -c1-300)"
	fi
}

do_update() {  # для планировщика: тихо; меняет что-то, только если подписка изменилась и новый туннель работает
	MODE=update
	[ -s "$STATE_DIR/source" ] && [ -x "$OPT/sbin/xkeen" ] || die "VPN этим скриптом ещё не настраивался"
	SOURCE=$(cat "$STATE_DIR/source")
	links_fetch || { note "подписка не прочиталась: $ERR"; die "$ERR"; }
	link_pick || { note "подписка не подошла: $ERR"; die "$ERR"; }
	configs_write
	if [ "$CHANGED" = 0 ]; then
		date '+%F %R' > "$STATE_DIR/updated"
		echo "подписка не изменилась"
		return 0
	fi
	if apply; then
		state_save
		note "подписка изменилась — настройки обновлены, выход $VPN_IP"
		echo "подписка изменилась — настройки обновлены, туннель работает (выход $VPN_IP)"
	else
		configs_restore
		"$OPT/sbin/xkeen" -restart < /dev/null > /dev/null 2>&1 || true
		note "новые настройки из подписки не заработали — возвращены прежние"
		die "новые настройки из подписки не заработали — вернул прежние"
	fi
}

do_status() {
	local ip
	[ -s "$STATE_DIR/source" ] || die "VPN этим скриптом ещё не настраивался"
	if [ -f "$CONF_DIR/04_outbounds.json" ]; then
		echo "Сервер: $(jq -r '.outbounds[0].settings.vnext[0] | .address + ":" + (.port | tostring)' "$CONF_DIR/04_outbounds.json" 2> /dev/null || echo '?')"
	fi
	echo "Подписка проверялась: $(cat "$STATE_DIR/updated" 2> /dev/null || echo 'ни разу')"
	VPNK_WAIT=1
	ip=$(tunnel_ip)
	if [ -n "$ip" ]; then echo "Туннель работает, выход в интернет с адреса $ip"; else echo "Туннель НЕ работает (VPN выключен? включить: vpn-keenetic --on)"; fi
}

do_remove() {
	local f
	[ -d "$STATE_DIR" ] || die "настроек этого скрипта на роутере нет"
	"$OPT/sbin/xkeen" -stop < /dev/null > /dev/null 2>&1 || true
	if [ -d "$STATE_DIR/original" ]; then configs_back "$STATE_DIR/original"; else for f in $FILES; do rm -f "$CONF_DIR/$f"; done; fi
	if [ -f "$CRON_FILE" ]; then grep -v 'vpn-keenetic --update' "$CRON_FILE" > "$WORK/cron" || true; cp "$WORK/cron" "$CRON_FILE"; fi
	rm -rf "$STATE_DIR"
	rm -f "$SELF"
	echo "Настройки VPN убраны (файлы Xray — какими были до этого скрипта), XKeen остановлен: интернет идёт напрямую."
	echo "Сам XKeen снимается командой: xkeen -remove"
}

main() {
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/vpnk.XXXXXX")
	trap 'rm -rf "$WORK"' EXIT
	case ${1:-} in
		--update) do_update ;;
		--status) do_status ;;
		--off) "$OPT/sbin/xkeen" -stop < /dev/null && echo "VPN выключен: интернет идёт напрямую" ;;
		--on) "$OPT/sbin/xkeen" -start < /dev/null && echo "VPN включён" ;;
		--remove) do_remove ;;
		-h | --help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' ;;
		--*) die "неизвестный параметр $1 (справка: --help)" ;;
		*) do_install "${1:-}" ;;
	esac
}

[ "${VPNK_LIB:-0}" = 1 ] || main "$@"

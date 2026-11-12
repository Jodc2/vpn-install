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
	# Имя — сразу при выпуске. С 3x-ui 3.7 «-getApiToken» без имени перевыпускает на месте одну и ту же строку
	# «cli-fallback», и прежнее «переименовать последнюю строку» отдало бы боту чужой токен.
	out=$("$XUI" setting -getApiToken -tokenName vpn-bot -tokenScope admin 2>&1) || true
	t=$(sed -n 's/^apiToken: *//p' <<< "$out" | tail -1)
	[ -n "$t" ] || { BOT_ERR="x-ui не выдал API-токен: $(head -c 200 <<< "$out")"; return 1; }
	n=$(sqlite3 "$DB" "select count(*) from api_tokens where name='vpn-bot';") || { BOT_ERR="не прочитать базу 3x-ui"; return 1; }
	[ "$n" = 1 ] || { BOT_ERR="x-ui выдал API-токен, но записи vpn-bot в его базе нет"; return 1; }
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

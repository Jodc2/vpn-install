# shellcheck shell=bash
# Телеграм-бот vpn-bot в установщике: всё, что ходит в Cloudflare и Телеграм. build.py вшивает этот
# файл в install-vpn.sh (__EMBED_BOT_FUNCS__); здесь только функции и значения по умолчанию.
# Секреты — только в файлах $BOT_DIR (600), в argv процессов их нет: curl берёт заголовок с токеном
# Cloudflare из файла (-H @файл), адрес с токеном бота — из своего конфига (-K файл).
BOT_WORKER=${VPN_BOT_WORKER:-vpn-bot}   # другое имя — только для проверки самого скрипта
BOT_CRON='0 */3 * * *'
CF_API_BASE=${CF_API_BASE:-https://api.cloudflare.com/client/v4}
TG_API_BASE=${TG_API_BASE:-https://api.telegram.org}
BOT_DIR=

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

bot_init_secrets() {  # BOT_CF_TOKEN / BOT_TG_TOKEN → файлы в $WORK/bot (600), переменные стираются
	BOT_DIR=$WORK/bot
	(umask 077 && mkdir -p "$BOT_DIR")
	if [ -n "${BOT_CF_TOKEN:-}" ]; then (umask 077 && printf 'Authorization: Bearer %s\n' "$BOT_CF_TOKEN" > "$BOT_DIR/cf.hdr"); fi
	if [ -n "${BOT_TG_TOKEN:-}" ]; then (umask 077 && printf '%s' "$BOT_TG_TOKEN" > "$BOT_DIR/tg.token"); fi
	unset BOT_CF_TOKEN BOT_TG_TOKEN
}

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

bot_template_url() {  # ссылка на создание токена Cloudflare с уже отмеченными правами
	python3 -I -c '
import json, urllib.parse as u
p = [{"key": "workers_scripts", "type": "edit"}, {"key": "workers_kv_storage", "type": "edit"},
     {"key": "account_settings", "type": "read"}, {"key": "zone", "type": "read"}, {"key": "dns", "type": "edit"}]
print("https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys="
      + u.quote(json.dumps(p, separators=(",", ":")), safe="") + "&accountId=%2A&zoneId=all&name=vpn-bot")'
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

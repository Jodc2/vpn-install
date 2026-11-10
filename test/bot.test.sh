#!/bin/bash
# Тесты src/bot.sh. Каждый test_* — в своей подоболочке под set -euo pipefail (как в установщике),
# с чистым $WORK; сеть подменяется функциями-заглушками cf_api/tg_api или фальшивым curl в PATH.
# Запуск: bash test/bot.test.sh [ИМЯ_ТЕСТА…]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
FIX=$HERE/fixtures

t_fail() { printf '    %s\n' "$*" >&2; exit 1; }
t_eq() { [ "$1" = "$2" ] || t_fail "$3: ждали «$1», получили «$2»"; }
t_has() { case $2 in *"$1"*) ;; *) t_fail "$3: нет «$1» в «$2»" ;; esac; }

# ——— Task 4: сетевой слой и чистые помощники ———
test_template_url_permissions() {
	local q
	q=$(bot_template_url | python3 -I -c 'import sys, urllib.parse as u; print(u.parse_qs(u.urlsplit(sys.stdin.read().strip()).query)["permissionGroupKeys"][0])')
	t_eq '[{"key":"workers_scripts","type":"edit"},{"key":"workers_kv_storage","type":"edit"},{"key":"account_settings","type":"read"},{"key":"zone","type":"read"},{"key":"dns","type":"edit"}]' "$q" "права в ссылке"
	bot_template_url | grep -q '^https://dash.cloudflare.com/profile/api-tokens?.*&accountId=%2A&zoneId=all&name=vpn-bot$' || t_fail "формат ссылки: $(bot_template_url)"
}
test_zone_candidates() {
	t_eq $'vpn.a.example.com\na.example.com\nexample.com' "$(bot_zone_candidates vpn.a.example.com)" "зоны"
	t_eq "example.com" "$(bot_zone_candidates example.com)" "зона из двух меток"
}
test_jget() {
	t_eq "z1" "$(echo '{"result":[{"id":"z1"}]}' | jget result.0.id)" "jget"
	t_eq "" "$(echo '{}' | jget result.0.id)" "нет пути"
	t_eq "false" "$(echo '{"result":{"proxied":false}}' | jget result.proxied)" "false как false"
	t_eq "" "$(echo 'не json' | jget a)" "не JSON — пусто"
}
test_cf_ok_and_err() {
	echo '{"success":true}' | cf_ok || t_fail "success:true"
	! echo '{"success":false}' | cf_ok || t_fail "success:false"
	t_eq "Authentication error (код 10000)" "$(echo '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}' | cf_err)" "cf_err"
}
test_secrets_not_in_argv() {
	BOT_CF_TOKEN=cfSECRET BOT_TG_TOKEN=tgSECRET bot_init_secrets
	t_eq 600 "$(stat -c %a "$BOT_DIR/cf.hdr")" "права cf.hdr"
	t_eq 600 "$(stat -c %a "$BOT_DIR/tg.token")" "права tg.token"
	[ -z "${BOT_CF_TOKEN:-}${BOT_TG_TOKEN:-}" ] || t_fail "переменные не стёрты"
	mkdir -p "$WORK/bin"
	cat > "$WORK/bin/curl" <<'CURL'
#!/bin/bash
printf '%s\n' "$@" >> "$WORK/curl.argv"
for ((i = 1; i <= $#; i++)); do if [ "${!i}" = -K ]; then j=$((i + 1)); cat "${!j}" >> "$WORK/curl.cfg"; fi; done
echo '{}'
CURL
	chmod +x "$WORK/bin/curl"
	PATH="$WORK/bin:$PATH" cf_api GET /zones > /dev/null
	PATH="$WORK/bin:$PATH" tg_api getMe > /dev/null
	! grep -q SECRET "$WORK/curl.argv" || t_fail "секрет в argv curl: $(tr '\n' ' ' < "$WORK/curl.argv")"
	grep -q 'tgSECRET/getMe' "$WORK/curl.cfg" || t_fail "токен бота не попал в конфиг curl"
	grep -qx "@$BOT_DIR/cf.hdr" "$WORK/curl.argv" || t_fail "заголовок Cloudflare не из файла"
	[ -z "$(ls "$BOT_DIR"/tg.?????? 2> /dev/null)" ] || t_fail "временный конфиг curl не удалён"
}

# ——— заглушки сети и терминала (Task 5 и дальше) ———
# Cloudflare: ответ по «МЕТОД ПУТЬ»; неизвестный путь — пустой успех. Вызовы — в $WORK/cf.calls.
cf_stub() {
	cf_api() {
		local k="$1 $2" f
		printf '%s\n' "$k" >> "$WORK/cf.calls"
		f="$WORK/cf/$(printf '%s' "$k" | md5sum | cut -c1-16)"
		if [ -f "$f" ]; then cat "$f"; else echo '{"success":true,"result":[]}'; fi
	}
}
cf_set() { mkdir -p "$WORK/cf"; printf '%s' "$2" > "$WORK/cf/$(printf '%s' "$1" | md5sum | cut -c1-16)"; }
# Телеграм: ответы по методу очередью; кончились — пустой успех. Вызовы с телом — в $WORK/tg.calls.
tg_stub() {
	tg_api() {
		local q="$WORK/tg/$1" n body=
		[ -z "${2:-}" ] || body=$(cat "$2")
		printf '%s %s\n' "$1" "$body" >> "$WORK/tg.calls"
		n=$(ls "$q" 2> /dev/null | sort -n | head -1 || true)
		if [ -n "$n" ]; then cat "$q/$n"; rm -f "$q/$n"; else echo '{"ok":true,"result":[]}'; fi
	}
}
tg_push() { mkdir -p "$WORK/tg/$1"; local n; n=$(ls "$WORK/tg/$1" | wc -l); printf '%s' "$2" > "$WORK/tg/$1/$((n + 1))"; }
# Ответы человека — строками; вопросы пишутся в $WORK/tty.out.
answers() { printf '%s\n' "$@" > "$WORK/answers"; exec {BOT_TTY_FD}< "$WORK/answers"; }
base_env() {
	DOMAIN=vpn.example.com
	PUBLIC_IP=1.2.3.4
	BOT_CF_TOKEN=c BOT_TG_TOKEN=t bot_init_secrets
	cf_stub
	tg_stub
}
# Типовой аккаунт: зона example.com, A-запись на этот сервер, KV доступен, воркера нет.
good_cf() {
	cf_set "GET /zones?name=example.com" '{"success":true,"result":[{"id":"Z1","account":{"id":"A1"}}]}'
	cf_set "GET /zones/Z1/dns_records?type=A&name=vpn.example.com" '{"success":true,"result":[{"id":"R1","content":"1.2.3.4","proxied":false}]}'
	cf_set "GET /accounts/A1/storage/kv/namespaces?per_page=100" '{"success":true,"result":[{"id":"K9","title":"other"}]}'
	cf_set "GET /accounts/A1/workers/subdomain" '{"success":true,"result":{"subdomain":"sub1"}}'
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot/settings" '{"success":false,"errors":[{"code":10007,"message":"This Worker does not exist on your account."}]}'
}
msg() { printf '{"update_id":%s,"message":{"from":{"id":%s,"first_name":"%s","username":"%s"},"chat":{"type":"private"},"text":"hi"}}' "$@"; }

# ——— Task 5: проверка токенов и привязка владельца ———
test_cf_check_zone_from_parent() {
	base_env; good_cf
	bot_cf_check || t_fail "не прошла: $BOT_ERR"
	t_eq Z1 "$BOT_ZONE" "зона"; t_eq A1 "$BOT_ACC" "аккаунт"; t_eq none "$BOT_EXISTING" "воркера нет"
	t_eq sub1 "$BOT_SUBDOMAIN" "поддомен"; t_eq "" "$BOT_KV_ID" "своего KV ещё нет"
	grep -qx "GET /zones?name=vpn.example.com" "$WORK/cf.calls" || t_fail "сперва само имя"
}
test_cf_check_no_zone() {
	base_env
	! bot_cf_check || t_fail "прошла без зоны"
	t_has "не видит домен vpn.example.com" "$BOT_ERR" "причина"
}
test_cf_check_proxied_record() {
	base_env; good_cf
	cf_set "GET /zones/Z1/dns_records?type=A&name=vpn.example.com" '{"success":true,"result":[{"id":"R1","content":"1.2.3.4","proxied":true}]}'
	! bot_cf_check || t_fail "прошла с Proxy"
	t_has "Proxy" "$BOT_ERR" "причина"
}
test_cf_check_record_other_ip() {
	base_env; good_cf
	cf_set "GET /zones/Z1/dns_records?type=A&name=vpn.example.com" '{"success":true,"result":[{"id":"R1","content":"9.9.9.9","proxied":false}]}'
	! bot_cf_check || t_fail "прошла с чужим IP"
	t_has "9.9.9.9" "$BOT_ERR" "старый IP"; t_has "1.2.3.4" "$BOT_ERR" "IP сервера"
}
test_cf_check_no_kv_permission() {
	base_env; good_cf
	cf_set "GET /accounts/A1/storage/kv/namespaces?per_page=100" '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}'
	! bot_cf_check || t_fail "прошла без прав на KV"
	t_has "Workers KV Storage" "$BOT_ERR" "какого права нет"
	case $BOT_ERR in *'{'*) t_fail "сырой JSON в причине: $BOT_ERR" ;; esac
}
test_cf_check_existing() {
	base_env; good_cf
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot/settings" '{"success":true,"result":{"bindings":[{"type":"plain_text","name":"VPN_BOT_INSTALLER","text":"1"}]}}'
	bot_cf_check; t_eq ours "$BOT_EXISTING" "по метке"
	[ -s "$BOT_DIR/settings.json" ] || t_fail "настройки не сохранены"
	cf_set "GET /accounts/A1/storage/kv/namespaces?per_page=100" '{"success":true,"result":[{"id":"K1","title":"vpn-bot-state"}]}'
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot/settings" '{"success":true,"result":{"bindings":[{"type":"kv_namespace","name":"STATE","namespace_id":"K1"}]}}'
	bot_cf_check; t_eq ours "$BOT_EXISTING" "по своему KV (ручной бот владельца)"; t_eq K1 "$BOT_KV_ID" "KV"
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot/settings" '{"success":true,"result":{"bindings":[{"type":"kv_namespace","name":"STATE","namespace_id":"K7"}]}}'
	bot_cf_check; t_eq foreign "$BOT_EXISTING" "чужой"
}
test_tg_check_bad_token() {
	base_env
	tg_push getMe '{"ok":false,"error_code":401,"description":"Unauthorized"}'
	! bot_tg_check || t_fail "прошла с плохим токеном"
	t_has "токен бота" "$BOT_ERR" "причина"
	tg_push getMe '{"ok":true,"result":{"username":"my_vpn_bot"}}'
	tg_push getWebhookInfo '{"ok":true,"result":{"url":""}}'
	bot_tg_check || t_fail "хороший токен: $BOT_ERR"
	t_eq my_vpn_bot "$BOT_USERNAME" "имя бота"; t_eq "" "$BOT_HOOK_URL" "вебхука нет"
}
test_pair_takes_confirmed_sender() {
	base_env; BOT_USERNAME=my_vpn_bot; BOT_HOOK_URL=
	tg_push getUpdates "{\"ok\":true,\"result\":[$(msg 10 42 Ann ann)]}"
	answers y
	bot_pair 30 || t_fail "не привязал: $BOT_ERR"
	t_eq 42 "$BOT_ADMIN_ID" "id"; t_eq Ann "$BOT_ADMIN_NAME" "имя"
	t_has '"offset":11' "$(tail -1 "$WORK/tg.calls")" "очередь очищена"
	grep -q "t.me/my_vpn_bot" "$WORK/tty.out" || t_fail "нет подсказки, кому писать"
}
test_pair_skips_rejected() {
	base_env; BOT_USERNAME=my_vpn_bot; BOT_HOOK_URL=
	tg_push getUpdates "{\"ok\":true,\"result\":[$(msg 10 42 Ann ann),$(msg 11 77 Bob bob)]}"
	answers n y
	bot_pair 30 || t_fail "не привязал: $BOT_ERR"
	t_eq 77 "$BOT_ADMIN_ID" "второй отправитель"
}
test_pair_timeout() {
	base_env; BOT_USERNAME=my_vpn_bot; BOT_HOOK_URL=
	answers y
	! bot_pair 1 || t_fail "привязал без сообщений"
	t_has "не дождался" "$BOT_ERR" "причина"
}
test_pair_foreign_webhook_needs_consent() {
	base_env; BOT_USERNAME=my_vpn_bot; BOT_SUBDOMAIN=sub1; BOT_HOOK_URL=https://other.example/tg
	answers n
	! bot_pair 30 || t_fail "привязал без согласия"
	grep -q "other.example" "$WORK/tty.out" || t_fail "не спросил про чужой вебхук"
	t_has "other.example" "$BOT_ERR" "причина называет адрес"
	! grep -q '^deleteWebhook' "$WORK/tg.calls" 2> /dev/null || t_fail "вебхук снят без согласия"
}
test_validate_foreign_worker_declined() {
	base_env; good_cf
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot/settings" '{"success":true,"result":{"bindings":[]}}'
	answers n
	! bot_validate || t_fail "прошла с чужим воркером"
	t_has "не от установщика" "$BOT_ERR" "причина"
}
test_validate_rerun_skips_pairing() {
	base_env; good_cf
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot/settings" '{"success":true,"result":{"bindings":[{"type":"plain_text","name":"VPN_BOT_INSTALLER","text":"1"},{"type":"secret_text","name":"ADMIN_ID"}]}}'
	tg_push getMe '{"ok":true,"result":{"username":"my_vpn_bot"}}'
	tg_push getWebhookInfo '{"ok":true,"result":{"url":"https://vpn-bot.sub1.workers.dev/tg"}}'
	bot_validate || t_fail "не прошла: $BOT_ERR"
	! grep -q '^getUpdates' "$WORK/tg.calls" || t_fail "владельца спросили заново"
}

# ——— прогон ———
PASS=0
FAILN=0
want=" $* "
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
	[ $# -eq 0 ] || [[ $want == *" $t "* ]] || continue
	if (
		set -euo pipefail
		WORK=$(mktemp -d)
		export WORK FIX
		trap 'rm -rf "$WORK"' EXIT
		# shellcheck source=../src/bot.sh
		. "$ROOT/src/bot.sh"
		"$t"
	); then
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

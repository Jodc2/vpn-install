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

# ——— Task 6: ключи, токен панели, доступ к выходу ———
keys_env() {
	base_env
	BOT_AUTH_KEYS=$WORK/root.ssh/authorized_keys
	mkdir -p "$WORK/root.ssh"
	printf '%s\n' 'ssh-rsa AAAAuser user@laptop' > "$BOT_AUTH_KEYS"
}
settings() {  # settings 'привязки JSON' → прежняя версия нашего воркера
	BOT_EXISTING=ours
	printf '{"success":true,"result":{"bindings":%s}}' "$1" > "$BOT_DIR/settings.json"
}
test_keys_new_when_missing() {
	keys_env; BOT_EXISTING=none
	bot_keys 0
	t_eq 1 "$BOT_KEY_NEW" "ключ новый"
	t_eq 1 "$(grep -c ' vpn-bot$' "$BOT_AUTH_KEYS")" "строк vpn-bot"
	grep -qx 'ssh-rsa AAAAuser user@laptop' "$BOT_AUTH_KEYS" || t_fail "чужая строка пропала"
	t_eq 600 "$(stat -c %a "$BOT_AUTH_KEYS")" "права authorized_keys"
	[ -s "$BOT_DIR/id" ] && [ -s "$BOT_DIR/id.pub" ] || t_fail "нет ключа в BOT_DIR"
}
test_keys_replace_line() {
	keys_env; BOT_EXISTING=none
	bot_keys 1; local first; first=$(cat "$BOT_DIR/id.pub")
	bot_keys 1
	t_eq 1 "$(grep -c ' vpn-bot$' "$BOT_AUTH_KEYS")" "строк vpn-bot после двух раз"
	[ "$first" != "$(cat "$BOT_DIR/id.pub")" ] || t_fail "ключ не сменился"
	grep -qxF "$(cat "$BOT_DIR/id.pub")" "$BOT_AUTH_KEYS" || t_fail "в authorized_keys не новый ключ"
}
test_keys_inherit() {
	keys_env
	printf '%s\n' 'ssh-ed25519 AAAAold vpn-bot' >> "$BOT_AUTH_KEYS"
	settings '[{"type":"secret_text","name":"ENTRY_SSH_KEY"}]'
	bot_keys 0
	t_eq 0 "$BOT_KEY_NEW" "ключ унаследован"
	[ ! -e "$BOT_DIR/id" ] || t_fail "лишний новый ключ"
	grep -qx 'ssh-ed25519 AAAAold vpn-bot' "$BOT_AUTH_KEYS" || t_fail "прежняя строка тронута"
}
panel_env() {
	base_env
	DB=$WORK/x-ui.db
	sqlite3 "$DB" "create table api_tokens (id integer primary key autoincrement, name text not null unique, token text not null, enabled numeric default 1, created_at integer);"
	XUI=$WORK/x-ui
	cat > "$XUI" <<'X'
#!/bin/bash
[ "$1 $2" = "setting -getApiToken" ] || exit 2
sqlite3 "$DB" "insert into api_tokens (name, token) values ('cli-' || abs(random()), 'hash');"
echo "apiToken: P$(sqlite3 "$DB" 'select max(id) from api_tokens;')"
X
	chmod +x "$XUI"
	export DB
}
test_panel_token_new() {
	panel_env; BOT_EXISTING=none
	bot_panel_token || t_fail "не создал: $BOT_ERR"
	t_eq 1 "$BOT_PANEL_NEW" "новый"
	t_eq P1 "$(cat "$BOT_DIR/panel.token")" "открытый токен"
	t_eq 1 "$(sqlite3 "$DB" "select count(*) from api_tokens where name='vpn-bot';")" "строка vpn-bot"
	t_eq 600 "$(stat -c %a "$BOT_DIR/panel.token")" "права"
}
test_panel_token_replaces_row() {
	panel_env; BOT_EXISTING=none
	sqlite3 "$DB" "insert into api_tokens (name, token) values ('vpn-bot', 'old');"
	bot_panel_token || t_fail "не создал: $BOT_ERR"
	t_eq 1 "$(sqlite3 "$DB" "select count(*) from api_tokens where name='vpn-bot';")" "строк vpn-bot"
	t_eq 1 "$(sqlite3 "$DB" "select count(*) from api_tokens;")" "старая строка удалена"
	t_eq hash "$(sqlite3 "$DB" "select token from api_tokens where name='vpn-bot';")" "строка — новая"
}
test_panel_token_inherit() {
	panel_env
	sqlite3 "$DB" "insert into api_tokens (name, token) values ('vpn-bot', 'old');"
	settings '[{"type":"secret_text","name":"PANEL_TOKEN"}]'
	bot_panel_token
	t_eq 0 "$BOT_PANEL_NEW" "унаследован"
	t_eq old "$(sqlite3 "$DB" "select token from api_tokens where name='vpn-bot';")" "строка не тронута"
}
chain_env() {
	base_env
	EXIT_MODE=chain CHAIN_IP=5.6.7.8 CHAIN_PORT=2087 CHAIN_SSH_USER=ubuntu CHAIN_SSH_PORT=22 CHAIN_FW=iptables
	ssh-keygen -q -t ed25519 -N '' -f "$WORK/hostkey"
	BOT_KNOWN_HOSTS=$WORK/known_hosts
	printf '5.6.7.8 %s\n' "$(cut -d' ' -f1-2 "$WORK/hostkey.pub")" > "$BOT_KNOWN_HOSTS"
}
test_exit_bindings_none() {
	base_env; EXIT_MODE=direct
	bot_exit_bindings
	[ -f "$BOT_DIR/exit.list" ] || t_fail "нет exit.list"
	t_eq "" "$(cat "$BOT_DIR/exit.list")" "без цепочки — пусто"
}
test_exit_bindings_new_access() {
	chain_env; BOT_EXISTING=none; BOT_AUTH_KEYS=$WORK/ak; touch "$WORK/ak"
	bot_keys 1; BOT_EXIT_SETUP=1; EXIT_SUDO=nopass
	bot_exit_bindings
	local l; l=$(cat "$BOT_DIR/exit.list")
	t_has "plain EXIT_HOST 5.6.7.8" "$l" "адрес"; t_has "plain EXIT_USER ubuntu" "$l" "пользователь"
	t_has "plain CHAIN_PORT 2087" "$l" "порт"; t_has "plain EXIT_FW iptables" "$l" "фаервол"
	t_has "secret EXIT_SSH_KEY @$BOT_DIR/id" "$l" "ключ"; t_has "secret EXIT_HOSTKEY_FPR @$BOT_DIR/exit.fpr" "$l" "отпечаток"
	t_eq "[\"$(ssh-keygen -lf "$WORK/hostkey.pub" | awk '{print $2}')\"]" "$(cat "$BOT_DIR/exit.fpr")" "отпечаток ключа выхода"
}
test_exit_bindings_sudo_pass() {
	chain_env; BOT_EXISTING=none; BOT_AUTH_KEYS=$WORK/ak; touch "$WORK/ak"
	bot_keys 1; BOT_EXIT_SETUP=1; EXIT_SUDO=pass
	bot_exit_bindings
	local l; l=$(cat "$BOT_DIR/exit.list")
	t_has "plain EXIT_HOST 5.6.7.8" "$l" "адрес есть"
	case $l in *EXIT_SSH_KEY*) t_fail "доступ при sudo с паролем: $l" ;; esac
}
test_exit_bindings_inherit() {
	chain_env; BOT_EXIT_SETUP=0
	settings '[{"type":"secret_text","name":"EXIT_SSH_KEY"},{"type":"secret_text","name":"EXIT_HOSTKEY_FPR"},{"type":"plain_text","name":"EXIT_HOST","text":"5.6.7.8"}]'
	bot_exit_bindings
	local l; l=$(cat "$BOT_DIR/exit.list")
	t_has "inherit EXIT_SSH_KEY" "$l" "ключ наследуется"; t_has "inherit EXIT_HOSTKEY_FPR" "$l" "отпечаток наследуется"
}
test_exit_bindings_host_changed() {
	chain_env; BOT_EXIT_SETUP=0
	settings '[{"type":"secret_text","name":"EXIT_SSH_KEY"},{"type":"secret_text","name":"EXIT_HOSTKEY_FPR"},{"type":"plain_text","name":"EXIT_HOST","text":"9.9.9.9"}]'
	bot_exit_bindings
	local l; l=$(cat "$BOT_DIR/exit.list")
	case $l in *EXIT_SSH_KEY* | *EXIT_HOSTKEY_FPR*) t_fail "доступ к старому выходу перенесён на новый: $l" ;; esac
	t_has "plain EXIT_HOST 5.6.7.8" "$l" "новый адрес"
}
test_exit_setup_bot_key() {  # блок шаблона, который кладёт ключ бота на выходе
	local code h
	code=$(sed -n '/^# >>> vpn-bot key/,/^# <<< vpn-bot key/p' "$ROOT/src/install-vpn.sh.in")
	[ -n "$code" ] || t_fail "в шаблоне нет блока vpn-bot key"
	h=$WORK/home/u; mkdir -p "$h/.ssh"; printf '%s\n' 'ssh-rsa AAAAu u@x' 'ssh-ed25519 AAAAold vpn-bot' > "$h/.ssh/authorized_keys"
	mkdir -p "$WORK/bin"; printf '#!/bin/bash\necho "u:x:0:0::%s:/bin/bash"\n' "$h" > "$WORK/bin/getent"; chmod +x "$WORK/bin/getent"
	(
		PATH="$WORK/bin:$PATH" BOT_PUBKEY='ssh-ed25519 AAAAnew vpn-bot' BOT_SSH_USER=root
		eval "$code"
	) > "$WORK/out"
	grep -qx 'EXIT_BOTKEY=ok' "$WORK/out" || t_fail "нет EXIT_BOTKEY=ok"
	t_eq $'ssh-rsa AAAAu u@x\nssh-ed25519 AAAAnew vpn-bot' "$(cat "$h/.ssh/authorized_keys")" "ключ бота заменён, чужой цел"
	t_eq 600 "$(stat -c %a "$h/.ssh/authorized_keys")" "права"
}

# ——— прогон ———
PASS=0
FAILN=0
want=" $* "
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
	[ $# -eq 0 ] || [[ $want == *" $t "* ]] || continue
	# Подоболочка — отдельной командой, не в условии if: там bash молча выключает set -e.
	(
		set -euo pipefail
		WORK=$(mktemp -d)
		export WORK FIX
		trap 'rm -rf "$WORK"' EXIT
		# shellcheck source=../src/bot.sh
		. "$ROOT/src/bot.sh"
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

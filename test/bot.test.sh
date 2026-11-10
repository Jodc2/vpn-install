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

# ——— Task 7: развёртывание воркера ———
# Заглушка Cloudflare с копией файлов из аргументов (развёртывание потом стирает секреты).
cf_stub_capture() {
	cf_api() {
		local k="$1 $2" f n a
		printf '%s\n' "$k" >> "$WORK/cf.calls"
		n=$(wc -l < "$WORK/cf.calls")
		for a in "$@"; do
			f=
			case $a in
				*=@*) f=${a#*=@} ;;
				*"=<"*) f=${a#*=<} ;;
				@*) f=${a#@} ;;
			esac
			f=${f%%;*}
			if [ -n "$f" ] && [ -f "$f" ]; then cp "$f" "$WORK/cap.$n.$(basename "$f")"; fi
		done
		f="$WORK/cf/$(printf '%s' "$k" | md5sum | cut -c1-16)"
		if [ -f "$f" ]; then cat "$f"; else echo '{"success":true,"result":{}}'; fi
	}
}
deploy_env() {
	base_env; good_cf; cf_stub_capture
	BOT_ACC=A1 BOT_ZONE=Z1 BOT_SUBDOMAIN=sub1 BOT_KV_ID=K1 BOT_EXISTING=none BOT_ADMIN_ID=42
	WEB_PATH=/panel123/ SUB_PATH=/sub456/ SSH_PORT=22 EXIT_MODE=direct
	BOT_AUTH_KEYS=$WORK/ak; touch "$WORK/ak"; bot_keys 0
	(umask 077 && printf P1 > "$BOT_DIR/panel.token"); BOT_PANEL_NEW=1
	bot_exit_bindings
	mkdir -p "$WORK/etc_ssh"; ssh-keygen -q -t ed25519 -N '' -f "$WORK/etc_ssh/ssh_host_ed25519_key"
	BOT_HOST_KEYS="$WORK/etc_ssh/ssh_host_*_key.pub"
	head -c 2048 /dev/urandom > "$WORK/latest.tgz"
	printf '#!/bin/bash\necho "Бэкап готов"\necho %s\n' "$WORK/latest.tgz" > "$WORK/backup.sh"; chmod +x "$WORK/backup.sh"
	BOT_BACKUP_CMD=$WORK/backup.sh
	bot_extract_bundle() { echo 'export default {}' > "$BOT_DIR/worker.js"; }
	bot_http() { printf '%s\n' "$1" >> "$WORK/http.calls"; case $1 in /healthz) echo ok ;; "/selftest?part="*) cat "$WORK/st.${1#*part=}" ;; esac; }
	echo '{"panel":{"ok":true,"clients":3},"dns":{"ok":true,"ip":"1.2.3.4"},"webhook":{"ok":true,"url":"https://vpn-bot.sub1.workers.dev/tg"},"admin":{"ok":true}}' > "$WORK/st.base"
	echo '{"ok":true}' > "$WORK/st.entry"
	echo '{"skipped":true}' > "$WORK/st.exit"
	tg_push setWebhook '{"ok":true,"result":true}'
}
mb() {  # mb ИМЯ → «тип|значение» привязки из загруженного metadata.json
	python3 -I -c 'import json, sys
m = json.load(open(sys.argv[1]))
for b in m["bindings"]:
    if b["name"] == sys.argv[2]:
        print(b["type"] + "|" + str(b.get("text", b.get("namespace_id", ""))))' "$(ls "$WORK"/cap.*.metadata.json | head -1)" "$1"
}
test_deploy_first_install() {
	deploy_env
	bot_deploy || t_fail "не развернул: $BOT_ERR"
	grep -qx 'PUT /accounts/A1/workers/scripts/vpn-bot?bindings_inherit=strict' "$WORK/cf.calls" || t_fail "нет загрузки с bindings_inherit=strict"
	! grep -q '"inherit"' "$WORK"/cap.*.metadata.json || t_fail "наследование при первой установке"
	t_eq "plain_text|1" "$(mb VPN_BOT_INSTALLER)" "метка"
	t_eq "secret_text|42" "$(mb ADMIN_ID)" "владелец"
	t_eq "secret_text|c" "$(mb CF_API_TOKEN)" "токен Cloudflare"
	t_eq "secret_text|P1" "$(mb PANEL_TOKEN)" "токен панели"
	t_eq "secret_text|t" "$(mb BOT_TOKEN)" "токен бота"
	t_eq "plain_text|https://vpn.example.com" "$(mb PANEL_ORIGIN)" "панель"
	t_eq "plain_text|/panel123/" "$(mb PANEL_BASE)" "путь панели"
	t_eq "plain_text|https://vpn.example.com/sub456/" "$(mb SUB_PREFIX)" "подписка"
	t_eq "plain_text|https://vpn-bot.sub1.workers.dev" "$(mb SELF_ORIGIN)" "адрес воркера"
	t_eq "kv_namespace|K1" "$(mb STATE)" "KV"
	t_eq "" "$(mb EXIT_HOST)" "без цепочки нет EXIT_*"
	t_has '"drop_pending_updates": true' "$(grep '^setWebhook' "$WORK/tg.calls")" "очередь сброшена при первой установке"
	t_has '"url": "https://vpn-bot.sub1.workers.dev/tg"' "$(grep '^setWebhook' "$WORK/tg.calls")" "адрес вебхука"
	grep -qF '0 */3 * * *' "$WORK"/cap.*.req.json 2> /dev/null || grep -rqF '0 */3 * * *' "$WORK"/cap.* || t_fail "нет cron"
	grep -qx 'PUT /accounts/A1/storage/kv/namespaces/K1/values/entry%3Afpr' "$WORK/cf.calls" || t_fail "нет entry:fpr"
	grep -q "$(ssh-keygen -lf "$WORK/etc_ssh/ssh_host_ed25519_key.pub" | awk '{print $2}')" "$WORK"/cap.*.fpr.json || t_fail "в entry:fpr не тот ключ"
	grep -qx 'PUT /accounts/A1/storage/kv/namespaces/K1/values/backup%3Abytes' "$WORK/cf.calls" || t_fail "нет бэкапа в KV"
}
test_deploy_creates_kv() {
	deploy_env; BOT_KV_ID=
	cf_set "POST /accounts/A1/storage/kv/namespaces" '{"success":true,"result":{"id":"K2","title":"vpn-bot-state"}}'
	bot_deploy || t_fail "не развернул: $BOT_ERR"
	t_eq "kv_namespace|K2" "$(mb STATE)" "новый KV"
	grep -q '"title":"vpn-bot-state"' "$WORK"/cap.*.req.json || t_fail "KV не с тем именем"
}
test_deploy_rerun_inherits() {
	deploy_env
	settings '[{"type":"secret_text","name":"BOT_TOKEN"},{"type":"secret_text","name":"WEBHOOK_SECRET"},{"type":"secret_text","name":"ADMIN_ID"},{"type":"secret_text","name":"PANEL_TOKEN"},{"type":"secret_text","name":"ENTRY_SSH_KEY"},{"type":"secret_text","name":"GLOBALPING_TOKEN"},{"type":"plain_text","name":"EXIT_HOST","text":"7.7.7.7"}]'
	rm -f "$BOT_DIR/tg.token" "$BOT_DIR/id" "$BOT_DIR/panel.token"; BOT_KEY_NEW=0 BOT_PANEL_NEW=0 BOT_ADMIN_ID=
	bot_deploy || t_fail "не развернул: $BOT_ERR"
	for n in BOT_TOKEN WEBHOOK_SECRET ADMIN_ID PANEL_TOKEN ENTRY_SSH_KEY; do t_eq "inherit|" "$(mb $n)" "$n наследуется"; done
	t_eq "inherit|" "$(mb GLOBALPING_TOKEN)" "чужая настройка владельца сохраняется"
	t_eq "" "$(mb EXIT_HOST)" "цепочки больше нет — EXIT_HOST не тянется"
	! grep -q '^setWebhook' "$WORK/tg.calls" 2> /dev/null || t_fail "вебхук трогали без токена бота"
}
test_deploy_no_secret_on_disk_after() {
	deploy_env
	bot_deploy || t_fail "не развернул: $BOT_ERR"
	local f
	for f in id panel.token tg.token cf.token cf.hdr metadata.json webhook.secret selftest.secret selftest.hdr admin.id hook.json; do
		[ ! -e "$BOT_DIR/$f" ] || t_fail "остался $f"
	done
}
test_deploy_no_subdomain_forbidden() {
	deploy_env; BOT_SUBDOMAIN=
	cf_set "PUT /accounts/A1/workers/subdomain" '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}'
	! bot_deploy || t_fail "развернул без workers.dev"
	t_has "Workers & Pages" "$BOT_ERR" "что сделать"
	[ ! -e "$BOT_DIR/cf.hdr" ] || t_fail "секреты не стёрты после неудачи"
}
test_deploy_selftest_report() {
	deploy_env; EXIT_MODE=chain CHAIN_IP=5.6.7.8 CHAIN_PORT=2087; bot_exit_bindings
	bot_deploy || t_fail "не развернул: $BOT_ERR"
	t_has "панель" "$BOT_REPORT" "панель"; t_has "вход по SSH" "$BOT_REPORT" "вход"; t_has "руками" "$BOT_REPORT" "выход без доступа"
	t_has "3" "$BOT_REPORT" "число клиентов"
}
test_deploy_selftest_entry_fail() {
	deploy_env
	echo '{"ok":false,"error":"permission denied (publickey)"}' > "$WORK/st.entry"
	! bot_deploy || t_fail "успех при провале входа по SSH"
	t_has "permission denied" "$BOT_ERR" "причина"
}

test_deploy_deletes_dropped_secrets() {  # Cloudflare не убирает секрет, которого нет в загрузке, — только явным DELETE
	deploy_env
	settings '[{"type":"secret_text","name":"BOT_TOKEN"},{"type":"secret_text","name":"WEBHOOK_SECRET"},{"type":"secret_text","name":"ADMIN_ID"},{"type":"secret_text","name":"EXIT_SSH_KEY"},{"type":"secret_text","name":"EXIT_HOSTKEY_FPR"},{"type":"secret_text","name":"GLOBALPING_TOKEN"},{"type":"plain_text","name":"EXIT_HOST","text":"5.6.7.8"}]'
	rm -f "$BOT_DIR/tg.token"; BOT_ADMIN_ID=''
	EXIT_MODE=direct; bot_exit_bindings
	bot_deploy || t_fail "не развернул: $BOT_ERR"
	grep -qx 'DELETE /accounts/A1/workers/scripts/vpn-bot/secrets/EXIT_SSH_KEY' "$WORK/cf.calls" || t_fail "ключ выхода не удалён"
	grep -qx 'DELETE /accounts/A1/workers/scripts/vpn-bot/secrets/EXIT_HOSTKEY_FPR' "$WORK/cf.calls" || t_fail "отпечаток выхода не удалён"
	! grep -qE 'DELETE .*/secrets/(BOT_TOKEN|WEBHOOK_SECRET|ADMIN_ID|GLOBALPING_TOKEN)$' "$WORK/cf.calls" || t_fail "удалён нужный секрет: $(grep DELETE "$WORK/cf.calls" | tr '\n' ' ')"
}

test_deploy_foreign_drops_stale_exit_access() {  # перезаписали чужой воркер — его доступ к выходу не должен остаться
	deploy_env
	printf '{"success":true,"result":{"bindings":%s}}' '[{"type":"secret_text","name":"BOT_TOKEN"},{"type":"secret_text","name":"EXIT_SSH_PASS"},{"type":"secret_text","name":"EXIT_SSH_KEY"},{"type":"secret_text","name":"GLOBALPING_TOKEN"}]' > "$BOT_DIR/settings.json"
	BOT_EXISTING=foreign
	bot_deploy || t_fail "не развернул: $BOT_ERR"
	grep -qx 'DELETE /accounts/A1/workers/scripts/vpn-bot/secrets/EXIT_SSH_PASS' "$WORK/cf.calls" || t_fail "пароль выхода чужого бота не удалён"
	grep -qx 'DELETE /accounts/A1/workers/scripts/vpn-bot/secrets/EXIT_SSH_KEY' "$WORK/cf.calls" || t_fail "ключ выхода чужого бота не удалён"
	! grep -qE 'DELETE .*/secrets/(BOT_TOKEN|GLOBALPING_TOKEN)$' "$WORK/cf.calls" || t_fail "удалено лишнее: $(grep DELETE "$WORK/cf.calls" | tr '\n' ' ')"
}

# ——— Task 8: решение «ставить / обновить / не трогать» ———
decide_env() {
	MODE=domain BOT_ARG= S_BOT= BOT_CF_TOKEN= DOMAIN=vpn.example.com S_DOMAIN_OLD=vpn.example.com
	EXIT_MODE=direct S_EXIT=direct EXIT_HOST= CHAIN_IP= EXIT_PORT_ARG= CHAIN_PORT= S_BOT_SSH_PORT= SSH_PORT_NOW=22
}
test_decide_no_bot_flag() {
	decide_env; BOT_ARG=0; answers y
	bot_decide
	t_eq 0 "$BOT_DO" "не ставить"; t_eq 0 "$BOT_ASK" "не спрашивать"
}
test_decide_nodomain_never_asks() {
	decide_env; MODE=nodomain; answers y
	bot_decide
	t_eq 0 "$BOT_DO" "без домена не ставить"; t_eq 0 "$BOT_ASK" "без домена не спрашивать"
}
test_rerun_without_tokens_keeps_bot() {
	decide_env; S_BOT=1
	bot_decide
	t_eq 0 "$BOT_DO" "без токена не разворачивать"; t_eq 1 "$BOT_KEEP" "бот есть — не трогать"
}
test_decide_rerun_with_token_updates() {
	decide_env; S_BOT=1; BOT_CF_TOKEN=c
	bot_decide
	t_eq 1 "$BOT_DO" "с токеном — обновить"; t_eq 0 "$BOT_KEEP" "не «не трогать»"
}
test_decide_said_no_before() {
	decide_env; S_BOT=0; answers y
	bot_decide
	t_eq 0 "$BOT_DO" "отказались раньше"; t_eq 0 "$BOT_ASK" "не переспрашивать"
}
test_decide_stale_on_exit_change() {
	decide_env; S_BOT=1; S_EXIT=chain; EXIT_MODE=direct
	bot_decide
	t_eq 1 "$BOT_STALE" "выход сменился"
}
test_decide_stale_on_ssh_port() {
	decide_env; S_BOT=1; S_BOT_SSH_PORT=22; SSH_PORT_NOW=2222
	bot_decide
	t_eq 1 "$BOT_STALE" "порт SSH сменился"
}
test_decide_first_time_asks() {
	decide_env; answers y
	bot_decide
	t_eq 1 "$BOT_ASK" "первый раз — спросить"; t_eq 0 "$BOT_DO" "до ответа не ставить"
}
test_cf_check_bad_token() {
	base_env
	cf_set "GET /zones?name=vpn.example.com" '{"success":false,"errors":[{"code":6003,"message":"Invalid request headers"}]}'
	! bot_cf_check || t_fail "прошла с плохим токеном"
	t_has "не принял токен" "$BOT_ERR" "причина — токен, не домен"
}

test_read_tokens_prompts_missing() {
	decide_env; BOT_DO=1 BOT_KEEP=0 BOT_TG_TOKEN=
	answers cfX tgY
	bot_read_tokens
	t_eq cfX "$BOT_CF_TOKEN" "токен Cloudflare"; t_eq tgY "$BOT_TG_TOKEN" "токен бота"; t_eq 1 "$BOT_DO" "ставим"
	grep -q 'dash.cloudflare.com/profile/api-tokens' "$WORK/tty.out" || t_fail "нет ссылки на токен"
	grep -q '@BotFather' "$WORK/tty.out" || t_fail "нет подсказки про @BotFather"
}
test_read_tokens_without_cf_token_skips() {
	decide_env; BOT_DO=1 BOT_KEEP=0 BOT_TG_TOKEN=
	answers "" tgY
	bot_read_tokens
	t_eq 0 "$BOT_DO" "без токена Cloudflare — без бота"
}
test_read_tokens_keep_offers_update() {
	decide_env; S_BOT=1 BOT_DO=0 BOT_KEEP=1 BOT_STALE=1
	answers ""
	bot_read_tokens
	t_eq 0 "$BOT_DO" "Enter — оставить как есть"
	answers cfZ
	bot_read_tokens
	t_eq 1 "$BOT_DO" "дали токен — обновить"; t_eq cfZ "$BOT_CF_TOKEN" "токен"; t_eq 0 "$BOT_KEEP" "уже не «не трогать»"
}
test_retry_keeps_same_tokens() {
	base_env
	answers y "" ""
	bot_retry || t_fail "отказался повторять"
	t_eq "Authorization: Bearer c" "$(cat "$BOT_DIR/cf.hdr")" "тот же токен Cloudflare"
	t_eq t "$(cat "$BOT_DIR/tg.token")" "тот же токен бота"
}
test_retry_new_cf_token() {
	base_env
	answers y cf2 ""
	bot_retry
	t_eq "Authorization: Bearer cf2" "$(cat "$BOT_DIR/cf.hdr")" "новый токен Cloudflare"
	t_eq t "$(cat "$BOT_DIR/tg.token")" "токен бота прежний"
}
test_retry_declined() {
	base_env
	answers n
	! bot_retry || t_fail "повторил после «нет»"
	grep -q "ещё раз" "$WORK/tty.out" || t_fail "не спросил «ещё раз?»"
}

# ——— шаблон: сайты-прикрытия Reality ———
test_cover_sites_exclude_broken() {  # проверено живьём 2026-11-10: с dest www.microsoft.com Reality (Xray 26.6.1) не проходит
	local exit_list nodomain_list
	nodomain_list=$(sed -n '/^SNI_CANDIDATES="/,/"$/p' "$ROOT/src/install-vpn.sh.in")
	exit_list=$(grep -E '^for d in \$\{EXIT_SNI_HINT:-\}' "$ROOT/src/install-vpn.sh.in")
	[ -n "$nodomain_list" ] && [ -n "$exit_list" ] || t_fail "списки прикрытий не найдены в шаблоне"
	case "$nodomain_list $exit_list" in *www.microsoft.com*) t_fail "www.microsoft.com в списке прикрытий" ;; esac
	t_has "www.apple.com" "$exit_list" "у выхода остались рабочие кандидаты"
}

# ——— SSH к старому серверу: повтор, если соединение не установилось (живая проверка 10.11) ———
# Функции берутся из шаблона установщика; ssh/scp/sshpass — заглушки, ответы — по строкам $WORK/ssh.plan
# («КОД|СТРОКА_STDERR|STDOUT»), каждый вызов дописывает в $WORK/ssh.calls имя и то, что пришло на stdin.
exit_fns() {
	eval "$(awk '/^(exit_ssh_opts|exit_conn_failed|exit_retry|ssh_exit|scp_exit|ssh_exit_in)\(\) \{/,/^}/' "$ROOT/src/install-vpn.sh.in")"
	EXIT_SSH_KEY='' EXIT_PASS=pw EXIT_SSH_PORT=22 EXIT_SSH_USER=root EXIT_HOST=5.6.7.8 EXIT_SSH_RETRY_SLEEP=0
	mkdir -p "$WORK/bin"
	cat > "$WORK/bin/ssh" <<'SSH'
#!/bin/bash
n=$(($(cat "$WORK/ssh.n" 2> /dev/null || echo 0) + 1)); echo "$n" > "$WORK/ssh.n"
in=; [ -t 0 ] || in=$(timeout 1 cat 2> /dev/null | tr '\n' '/')
echo "$(basename "$0") in=$in" >> "$WORK/ssh.calls"
IFS='|' read -r code err out < <(sed -n "${n}p" "$WORK/ssh.plan")
[ -z "$err" ] || echo "$err" >&2
[ -z "$out" ] || echo "$out"
exit "${code:-0}"
SSH
	chmod +x "$WORK/bin/ssh"; cp "$WORK/bin/ssh" "$WORK/bin/scp"
	printf '#!/bin/bash\n[ "$1" = -e ] && shift\nexec "$@"\n' > "$WORK/bin/sshpass"; chmod +x "$WORK/bin/sshpass"
	PATH="$WORK/bin:$PATH"
}
test_exit_ssh_retries_lost_connection() {
	exit_fns
	printf '%s\n' '255|Connection to 5.6.7.8 port 22 timed out|' '0||/root' > "$WORK/ssh.plan"
	local out rc=0
	out=$(ssh_exit 'printf %s "$HOME"' 2> "$WORK/err") || rc=$?
	t_eq 0 "$rc" "код после повтора"
	t_eq /root "$out" "ответ второй попытки"
	t_eq 2 "$(wc -l < "$WORK/ssh.calls")" "попыток"
}
test_exit_ssh_retries_banner_and_kex_drops() {
	exit_fns
	printf '%s\n' '255|kex_exchange_identification: read: Connection reset by peer|' '255|Connection closed by 5.6.7.8 port 22|' '0||ok' > "$WORK/ssh.plan"
	t_eq ok "$(ssh_exit true 2> /dev/null)" "третья попытка"
	t_eq 3 "$(wc -l < "$WORK/ssh.calls")" "попыток"
}
test_exit_ssh_no_retry_once_session_started() {  # команда могла уже выполниться — повторять нельзя
	exit_fns
	local e rc
	for e in 'Connection to 5.6.7.8 closed by remote host.' 'client_loop: send disconnect: Connection reset by peer' 'Permission denied, please try again.'; do
		rm -f "$WORK/ssh.n" "$WORK/ssh.calls"
		printf '%s\n' "255|$e|" '0||второй раз' > "$WORK/ssh.plan"
		rc=0; ssh_exit 'rm -rf /x' > /dev/null 2> "$WORK/err" || rc=$?
		t_eq 255 "$rc" "код при «$e»"
		t_eq 1 "$(wc -l < "$WORK/ssh.calls")" "попыток при «$e»"
		t_has "$e" "$(cat "$WORK/err")" "сообщение ssh не потерялось"
	done
}
test_exit_ssh_gives_up() {
	exit_fns
	printf '%s\n' '255|Connection to 5.6.7.8 port 22 timed out|' '255|Connection to 5.6.7.8 port 22 timed out|' '255|Connection to 5.6.7.8 port 22 timed out|' '0||поздно' > "$WORK/ssh.plan"
	local rc=0
	ssh_exit true > /dev/null 2> "$WORK/err" || rc=$?
	t_eq 255 "$rc" "код"
	t_eq 3 "$(wc -l < "$WORK/ssh.calls")" "попыток"
	t_has "timed out" "$(cat "$WORK/err")" "причина видна"
}
test_exit_ssh_in_replays_stdin() {
	exit_fns
	printf '%s\n' '255|Connection to 5.6.7.8 port 22 timed out|' '0||ok' > "$WORK/ssh.plan"
	t_eq ok "$(printf '%s\n' 'sudo-pw' | ssh_exit_in "sudo -S true" 2> /dev/null)" "ответ"
	t_eq "ssh in=sudo-pw/" "$(sed -n 2p "$WORK/ssh.calls")" "пароль sudo дошёл и до повтора"
}
test_scp_exit_retries() {
	exit_fns
	printf '%s\n' '255|ssh: connect to host 5.6.7.8 port 22: Connection timed out|' '0||' > "$WORK/ssh.plan"
	echo x > "$WORK/f"
	scp_exit "$WORK/f" /tmp/f 2> /dev/null || t_fail "scp не повторился"
	t_eq 2 "$(grep -c '^scp ' "$WORK/ssh.calls")" "попыток scp"
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

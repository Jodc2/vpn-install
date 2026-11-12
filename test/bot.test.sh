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
	tg_push getUpdates '{"ok":true,"result":[]}'   # старая очередь пуста
	tg_push getUpdates "{\"ok\":true,\"result\":[$(msg 10 42 Ann ann)]}"
	answers y
	bot_pair 30 || t_fail "не привязал: $BOT_ERR"
	t_eq 42 "$BOT_ADMIN_ID" "id"; t_eq Ann "$BOT_ADMIN_NAME" "имя"
	t_has '"offset":11' "$(tail -1 "$WORK/tg.calls")" "очередь очищена"
	grep -q "t.me/my_vpn_bot" "$WORK/tty.out" || t_fail "нет подсказки, кому писать"
}
test_pair_skips_rejected() {
	base_env; BOT_USERNAME=my_vpn_bot; BOT_HOOK_URL=
	tg_push getUpdates '{"ok":true,"result":[]}'
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
test_validate_foreign_worker_declined() {  # имя воркера задано явно — чужой перезаписывается только с «да»
	base_env; good_cf; BOT_WORKER_AUTO=0
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
	local line; line=$(realkey old); printf '%s\n' "$line" >> "$BOT_AUTH_KEYS"
	settings "[{\"type\":\"secret_text\",\"name\":\"ENTRY_SSH_KEY\"},$(fpr_binding old)]"
	bot_keys 0
	t_eq 0 "$BOT_KEY_NEW" "ключ унаследован"
	[ ! -e "$BOT_DIR/id" ] || t_fail "лишний новый ключ"
	grep -qxF "$line" "$BOT_AUTH_KEYS" || t_fail "прежняя строка тронута"
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
test_decide_domain_not_in_cloudflare_never_asks() {  # «домен не в Cloudflare» — бот невозможен, не предлагать
	decide_env; DNS_NOT_CF=1; answers y
	bot_decide
	t_eq 0 "$BOT_ASK" "не спрашивать"; t_eq 0 "$BOT_DO" "не ставить"
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

# ——— финальное ревью (10.11): чужой вебхук, бот другого сервера, ручной бот, привязка, ключи ———
validate_env() {  # нового воркера нет, токен бота дан
	base_env; good_cf
	tg_push getMe '{"ok":true,"result":{"username":"my_vpn_bot"}}'
}
test_validate_foreign_webhook_needs_consent() {  # Review Focus 1 — и когда привязки владельца нет
	validate_env; VPN_BOT_ADMIN_ID=42
	tg_push getWebhookInfo '{"ok":true,"result":{"url":"https://other.example/bot123:SECRETtok/hook"}}'
	answers n
	! bot_validate || t_fail "прошла с чужим вебхуком без согласия"
	grep -q "https://other.example" "$WORK/tty.out" || t_fail "не спросил про чужой вебхук"
	t_has "https://other.example" "$BOT_ERR" "причина называет адрес"
	case "$BOT_ERR $(cat "$WORK/tty.out")" in *SECRETtok*) t_fail "путь вебхука (в нём бывает токен) попал в текст" ;; esac
	! grep -qE '^(deleteWebhook|setWebhook)' "$WORK/tg.calls" || t_fail "вебхук тронут без согласия"
}
test_validate_foreign_webhook_rerun_inherited_owner() {  # повтор: вставили не тот токен, владелец унаследован
	validate_env
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot/settings" '{"success":true,"result":{"bindings":[{"type":"plain_text","name":"VPN_BOT_INSTALLER","text":"1"},{"type":"secret_text","name":"ADMIN_ID"},{"type":"plain_text","name":"DNS_NAME","text":"vpn.example.com"}]}}'
	tg_push getWebhookInfo '{"ok":true,"result":{"url":"https://other.example/hook"}}'
	answers n
	! bot_validate || t_fail "чужой бот перехвачен без согласия"
}
test_validate_foreign_webhook_enter_is_no() {
	validate_env; VPN_BOT_ADMIN_ID=42
	tg_push getWebhookInfo '{"ok":true,"result":{"url":"https://other.example/hook"}}'
	answers ''
	! bot_validate || t_fail "Enter сошёл за согласие"
}
test_validate_foreign_webhook_consented() {
	validate_env; VPN_BOT_ADMIN_ID=42
	tg_push getWebhookInfo '{"ok":true,"result":{"url":"https://other.example/hook"}}'
	answers y
	bot_validate || t_fail "не прошла с согласием: $BOT_ERR"
	t_eq 42 "$BOT_ADMIN_ID" "владелец"
}
test_deploy_keeps_queue_of_previous_webhook() {  # перенастроили чужой вебхук — его очередь не стираем
	deploy_env; BOT_HOOK_URL=https://other.example/hook
	bot_deploy || t_fail "не развернул: $BOT_ERR"
	t_has '"drop_pending_updates": false' "$(grep '^setWebhook' "$WORK/tg.calls")" "очередь сохранена"
}
other_server_env() {  # наш воркер, но управляет он VPN на другом домене
	validate_env
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot/settings" '{"success":true,"result":{"bindings":[{"type":"plain_text","name":"VPN_BOT_INSTALLER","text":"1"},{"type":"secret_text","name":"ADMIN_ID"},{"type":"plain_text","name":"DNS_NAME","text":"vpn.other.org"},{"type":"plain_text","name":"CF_ZONE_ID","text":"Z2"}]}}'
	tg_push getWebhookInfo '{"ok":true,"result":{"url":"https://vpn-bot.sub1.workers.dev/tg"}}'
}
test_validate_bot_of_other_server_needs_consent() {  # C2, имя задано явно: забрать бота другого сервера — только с «да»
	other_server_env; BOT_WORKER_AUTO=0
	cf_set "GET /zones/Z2/dns_records?type=A&name=vpn.other.org" '{"success":true,"result":[{"id":"R2","content":"9.9.9.9","proxied":false}]}'
	answers n
	! bot_validate || t_fail "забрал бота другого сервера без вопроса"
	t_has "vpn.other.org" "$(cat "$WORK/tty.out")" "вопрос называет тот домен"
	t_has "vpn.other.org" "$BOT_ERR" "причина называет тот домен"
}
test_validate_bot_of_other_server_enter_is_no() {
	other_server_env; BOT_WORKER_AUTO=0
	cf_set "GET /zones/Z2/dns_records?type=A&name=vpn.other.org" '{"success":true,"result":[{"id":"R2","content":"9.9.9.9","proxied":false}]}'
	answers ''
	! bot_validate || t_fail "Enter сошёл за согласие"
}
test_validate_bot_of_unknown_server_asks() {  # A-запись того домена не прочитать — считаем, что сервер другой
	other_server_env; BOT_WORKER_AUTO=0
	answers n
	! bot_validate || t_fail "без проверки решил, что сервер тот же"
}
test_validate_same_server_new_domain_no_question() {  # домен сменился, а сервер тот же — бот его
	other_server_env
	cf_set "GET /zones/Z2/dns_records?type=A&name=vpn.other.org" '{"success":true,"result":[{"id":"R2","content":"1.2.3.4","proxied":false}]}'
	answers n
	bot_validate || t_fail "не прошла: $BOT_ERR"
	[ ! -s "$WORK/tty.out" ] || t_fail "лишний вопрос: $(cat "$WORK/tty.out")"
}
second_env() {  # имя vpn-bot занято ботом VPN другого сервера; токен бота — новый (вебхука нет)
	validate_env
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot/settings" '{"success":true,"result":{"bindings":[{"type":"plain_text","name":"VPN_BOT_INSTALLER","text":"1"},{"type":"secret_text","name":"ADMIN_ID"},{"type":"plain_text","name":"DNS_NAME","text":"vpn.other.org"},{"type":"plain_text","name":"CF_ZONE_ID","text":"Z2"}]}}'
	cf_set "GET /zones/Z2/dns_records?type=A&name=vpn.other.org" '{"success":true,"result":[{"id":"R2","content":"9.9.9.9","proxied":false}]}'
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot-vpn-example-com/settings" '{"success":false,"errors":[{"code":10007,"message":"This Worker does not exist on your account."}]}'
	VPN_BOT_ADMIN_ID=42
	answers ''
}
test_validate_other_server_gets_own_worker() {  # второй сервер в том же аккаунте — свой воркер, без вопросов
	second_env
	tg_push getWebhookInfo '{"ok":true,"result":{"url":""}}'
	bot_validate || t_fail "не прошла: $BOT_ERR"
	t_eq vpn-bot-vpn-example-com "$BOT_WORKER" "отдельный воркер под этот домен"
	t_eq none "$BOT_EXISTING" "воркер новый"
	! grep -q '\[y/N\]' "$WORK/tty.out" 2> /dev/null || t_fail "спросил, хотя мог завести свой воркер: $(cat "$WORK/tty.out")"
}
test_validate_foreign_default_worker_gets_own_worker() {  # имя vpn-bot занято чужим воркером — тоже свой воркер
	second_env
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot/settings" '{"success":true,"result":{"bindings":[]}}'
	tg_push getWebhookInfo '{"ok":true,"result":{"url":""}}'
	bot_validate || t_fail "не прошла: $BOT_ERR"
	t_eq vpn-bot-vpn-example-com "$BOT_WORKER" "отдельный воркер"
	! grep -q '\[y/N\]' "$WORK/tty.out" 2> /dev/null || t_fail "спросил про чужой воркер"
}
test_validate_auto_worker_name_taken_too() {  # и vpn-bot-<домен> занят ботом третьего сервера — номер
	second_env
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot-vpn-example-com/settings" '{"success":true,"result":{"bindings":[{"type":"plain_text","name":"VPN_BOT_INSTALLER","text":"1"},{"type":"plain_text","name":"DNS_NAME","text":"vpn.third.org"},{"type":"plain_text","name":"CF_ZONE_ID","text":"Z2"}]}}'
	cf_set "GET /zones/Z2/dns_records?type=A&name=vpn.third.org" '{"success":true,"result":[{"id":"R3","content":"8.8.8.8","proxied":false}]}'
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot-vpn-example-com-2/settings" '{"success":false,"errors":[{"code":10007,"message":"This Worker does not exist on your account."}]}'
	tg_push getWebhookInfo '{"ok":true,"result":{"url":""}}'
	bot_validate || t_fail "не прошла: $BOT_ERR"
	t_eq vpn-bot-vpn-example-com-2 "$BOT_WORKER" "следующее свободное имя"
}
test_validate_auto_reuses_worker_of_this_domain() {  # повтор на том же сервере: vpn-bot-<домен> уже его — остаётся
	second_env
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot-vpn-example-com/settings" '{"success":true,"result":{"bindings":[{"type":"plain_text","name":"VPN_BOT_INSTALLER","text":"1"},{"type":"secret_text","name":"ADMIN_ID"},{"type":"plain_text","name":"DNS_NAME","text":"vpn.example.com"}]}}'
	tg_push getWebhookInfo '{"ok":true,"result":{"url":"https://vpn-bot-vpn-example-com.sub1.workers.dev/tg"}}'
	bot_validate || t_fail "не прошла: $BOT_ERR"
	t_eq vpn-bot-vpn-example-com "$BOT_WORKER" "свой воркер"; t_eq ours "$BOT_EXISTING" "наш"
}
test_validate_second_worker_with_first_bots_token() {  # для второго воркера вставили токен уже работающего бота
	second_env
	tg_push getWebhookInfo '{"ok":true,"result":{"url":"https://vpn-bot.sub1.workers.dev/tg"}}'
	! bot_validate || t_fail "перехватил вебхук работающего бота"
	t_eq vpn-bot-vpn-example-com "$BOT_WORKER" "воркер — отдельный"
	t_has "подключён к другому адресу" "$BOT_ERR" "причина — вебхук бота, а не воркер"
	t_has "@BotFather" "$BOT_ERR" "подсказка: нужен другой бот"
	! grep -qE '^(deleteWebhook|setWebhook)' "$WORK/tg.calls" || t_fail "вебхук тронут"
}
test_worker_name_valid() {  # имя воркера: строчные, цифры, дефис; до 63 символов; без дефиса на краях
	DOMAIN=Very-Long-Subdomain-Name-That-Goes-On.and-another-quite-long-label.example.com
	local n w
	for n in 1 2 12; do
		w=$(bot_worker_name "$n")
		[ "${#w}" -le 63 ] || t_fail "длиннее 63: $w"
		[[ $w =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || t_fail "недопустимые символы или дефис на краю: $w"
		case $w in vpn-bot-*) ;; *) t_fail "не с vpn-bot-: $w" ;; esac
	done
	[ "$(bot_worker_name 1)" != "$(bot_worker_name 2)" ] || t_fail "номер не меняет имя"
	case $(bot_worker_name 12) in *-12) ;; *) t_fail "номер не в конце: $(bot_worker_name 12)" ;; esac
}

manual_bot_env() {  # бот, поставленный руками: наш по KV, владелец — в KV admin:id, секрета ADMIN_ID нет
	base_env; good_cf
	cf_set "GET /accounts/A1/storage/kv/namespaces?per_page=100" '{"success":true,"result":[{"id":"K1","title":"vpn-bot-state"}]}'
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot/settings" '{"success":true,"result":{"bindings":[{"type":"kv_namespace","name":"STATE","namespace_id":"K1"},{"type":"plain_text","name":"DNS_NAME","text":"vpn.example.com"}]}}'
	rm -f "$BOT_DIR/tg.token"
}
test_validate_manual_bot_owner_from_kv() {  # I4: владелец ручного бота сохраняется, установка не падает
	manual_bot_env
	cf_set "GET /accounts/A1/storage/kv/namespaces/K1/values/admin%3Aid" '123456789'
	bot_validate || t_fail "не прошла: $BOT_ERR"
	t_eq ours "$BOT_EXISTING" "бот наш"
	t_eq 123456789 "$BOT_ADMIN_ID" "владелец из KV"
	! grep -q '^getUpdates' "$WORK/tg.calls" 2> /dev/null || t_fail "привязывал заново"
}
test_validate_manual_bot_no_owner_no_token() {
	manual_bot_env; answers y   # терминал есть — путь человека, а не «без терминала»
	cf_set "GET /accounts/A1/storage/kv/namespaces/K1/values/admin%3Aid" '{"success":false,"errors":[{"code":10009,"message":"key not found"}]}'
	! bot_validate || t_fail "прошла без владельца и без токена бота"
	t_has "токен бота" "$BOT_ERR" "понятная причина"
}
test_validate_admins_list_from_kv() {  # бот уже ведёт список админов (KV admins) — первый из него, без привязки
	manual_bot_env
	cf_set "GET /accounts/A1/storage/kv/namespaces/K1/values/admins" '[{"id":555,"name":"Оля"},{"id":123456789,"name":"Антон"}]'
	cf_set "GET /accounts/A1/storage/kv/namespaces/K1/values/admin%3Aid" '{"success":false,"errors":[{"code":10009,"message":"key not found"}]}'
	bot_validate || t_fail "не прошла: $BOT_ERR"
	t_eq 555 "$BOT_ADMIN_ID" "админ из списка бота"
	t_eq "" "$BOT_GRANT_ID" "заявки нет — никого не добавляли"
	! grep -q '^getUpdates' "$WORK/tg.calls" 2> /dev/null || t_fail "привязывал заново"
}
test_validate_explicit_admin_fresh_bot_is_first() {  # VPN_BOT_ADMIN_ID у нового бота — он и есть первый админ
	validate_env; VPN_BOT_ADMIN_ID=42
	tg_push getWebhookInfo '{"ok":true,"result":{"url":""}}'
	bot_validate || t_fail "не прошла: $BOT_ERR"
	t_eq 42 "$BOT_ADMIN_ID" "первый админ"
	t_eq "" "$BOT_GRANT_ID" "добавлять не к кому"
}
test_validate_explicit_admin_added_not_replacing() {  # у бота уже есть админ (ADMIN_ID) — VPN_BOT_ADMIN_ID добавляется, а не заменяет
	other_server_env; BOT_WORKER_AUTO=0; VPN_BOT_ADMIN_ID=42
	cf_set "GET /accounts/A1/workers/scripts/vpn-bot/settings" '{"success":true,"result":{"bindings":[{"type":"plain_text","name":"VPN_BOT_INSTALLER","text":"1"},{"type":"secret_text","name":"ADMIN_ID"},{"type":"plain_text","name":"DNS_NAME","text":"vpn.example.com"}]}}'
	tg_push getWebhookInfo '{"ok":true,"result":{"url":"https://vpn-bot.sub1.workers.dev/tg"}}'
	bot_validate || t_fail "не прошла: $BOT_ERR"
	t_eq "" "$BOT_ADMIN_ID" "ADMIN_ID прежний — не перезаписывается"
	t_eq 42 "$BOT_GRANT_ID" "заявка на добавление"
}
test_validate_explicit_admin_manual_bot_keeps_owner() {  # бот, поставленный руками (admin:id в KV), + VPN_BOT_ADMIN_ID
	manual_bot_env; VPN_BOT_ADMIN_ID=42
	cf_set "GET /accounts/A1/storage/kv/namespaces/K1/values/admin%3Aid" '123456789'
	bot_validate || t_fail "не прошла: $BOT_ERR"
	t_eq 123456789 "$BOT_ADMIN_ID" "прежний админ остаётся первым"
	t_eq 42 "$BOT_GRANT_ID" "новый — заявкой"
}
grant_env() {  # повтор у нашего бота с админом: VPN_BOT_ADMIN_ID=42 → заявка admins:grant
	deploy_env
	settings '[{"type":"secret_text","name":"BOT_TOKEN"},{"type":"secret_text","name":"WEBHOOK_SECRET"},{"type":"secret_text","name":"ADMIN_ID"},{"type":"secret_text","name":"PANEL_TOKEN"},{"type":"secret_text","name":"ENTRY_SSH_KEY"}]'
	BOT_EXISTING=ours BOT_ADMIN_ID= BOT_GRANT_ID=42
}
grant_body() { python3 -I -c 'import json, sys; print(" ".join(str(a["id"]) for a in json.load(open(sys.argv[1]))))' "$(ls "$WORK"/cap.*.grant.json | tail -1)"; }
test_deploy_grant_request_for_bot() {
	grant_env
	cf_set "GET /accounts/A1/storage/kv/namespaces/K1/values/admins%3Agrant" '{"result":null,"success":false,"errors":[{"code":10009,"message":"get: '"'"'key not found'"'"'"}],"messages":[]}'
	bot_deploy || t_fail "не развернул: $BOT_ERR"
	grep -qx 'PUT /accounts/A1/storage/kv/namespaces/K1/values/admins%3Agrant' "$WORK/cf.calls" || t_fail "заявка не записана"
	t_eq "42" "$(grant_body)" "в заявке — новый админ"
	t_eq "inherit|" "$(mb ADMIN_ID)" "ADMIN_ID не перезаписан"
	! grep -q 'values/admins$' "$WORK/cf.calls" || t_fail "трогал сам список админов бота"
	t_has "добавлен к админам бота" "$BOT_REPORT" "отчёт"
}
test_deploy_grant_merges_pending_request() {  # прошлая заявка ещё не влита (бот не получал обновлений) — дописываем
	grant_env
	cf_set "GET /accounts/A1/storage/kv/namespaces/K1/values/admins%3Agrant" '[{"id":5,"name":""}]'
	bot_deploy || t_fail "не развернул: $BOT_ERR"
	t_eq "5 42" "$(grant_body)" "обе заявки"
}
test_deploy_grant_failure_is_not_fatal() {  # сбой записи заявки — бот всё равно разворачивается до конца (вебхук!)
	grant_env
	cf_set "GET /accounts/A1/storage/kv/namespaces/K1/values/admins%3Agrant" '[]'
	cf_set "PUT /accounts/A1/storage/kv/namespaces/K1/values/admins%3Agrant" '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}'
	tg_push setWebhook '{"ok":true,"result":true}'
	bot_deploy || t_fail "сбой заявки уронил развёртывание: $BOT_ERR"
	t_has "⚠ админа 42 не добавил" "$BOT_REPORT" "сказано в отчёте"
}
test_deploy_grant_read_error_skips() {  # Cloudflare не отдал заявки (не «ключа нет») — не пишем вслепую
	grant_env
	cf_set "GET /accounts/A1/storage/kv/namespaces/K1/values/admins%3Agrant" '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}'
	bot_deploy || t_fail "не развернул: $BOT_ERR"
	! grep -q '^PUT .*values/admins%3Agrant$' "$WORK/cf.calls" || t_fail "записал заявку вслепую"
	t_has "⚠ админа 42 не добавил" "$BOT_REPORT" "сказано в отчёте"
}
test_deploy_no_grant_when_not_requested() {
	deploy_env
	bot_deploy || t_fail "не развернул: $BOT_ERR"
	! grep -q 'values/admins' "$WORK/cf.calls" || t_fail "трогал админов бота без VPN_BOT_ADMIN_ID"
}
test_validate_admin_id_must_be_number() {  # I6: @имя вместо id дало бы немого бота при «✓»
	validate_env; VPN_BOT_ADMIN_ID=@ann
	tg_push getWebhookInfo '{"ok":true,"result":{"url":""}}'
	! bot_validate || t_fail "принял @имя вместо id"
	t_has "числовой" "$BOT_ERR" "причина"
}
test_pair_skips_backlog() {  # I3: старые сообщения из очереди — не повод спрашивать «это ты?»
	base_env; BOT_USERNAME=my_vpn_bot; BOT_HOOK_URL=
	tg_push getUpdates "{\"ok\":true,\"result\":[$(msg 5 77 Bob bob)]}"
	tg_push getUpdates "{\"ok\":true,\"result\":[$(msg 6 42 Ann ann)]}"
	answers y
	bot_pair 30 || t_fail "не привязал: $BOT_ERR"
	t_eq 42 "$BOT_ADMIN_ID" "владелец — из новых сообщений"
	! grep -q Bob "$WORK/tty.out" || t_fail "спросил про старое сообщение"
	t_has '"offset":-1' "$(sed -n 1p "$WORK/tg.calls")" "сперва выбрана старая очередь"
	t_has '"offset":6' "$(sed -n 2p "$WORK/tg.calls")" "дальше — после неё"
	! grep -q allowed_updates "$WORK/tg.calls" || t_fail "опрос меняет боту allowed_updates"
}
test_pair_enter_is_no() {  # I3: «это ты?» — по умолчанию «нет»
	base_env; BOT_USERNAME=my_vpn_bot; BOT_HOOK_URL=
	tg_push getUpdates '{"ok":true,"result":[]}'
	tg_push getUpdates "{\"ok\":true,\"result\":[$(msg 10 42 Ann ann)]}"
	answers ''
	! bot_pair 2 || t_fail "Enter сошёл за «это я»"
	grep -q '\[y/N\]' "$WORK/tty.out" || t_fail "вопрос не [y/N]"
}
test_pair_conflict_stops() {  # I3: бота читает другая программа — останавливаемся, а не крутимся
	base_env; BOT_USERNAME=my_vpn_bot; BOT_HOOK_URL=
	tg_push getUpdates '{"ok":false,"error_code":409,"description":"Conflict: terminated by other getUpdates request"}'
	answers y
	! bot_pair 30 || t_fail "привязал при чужом опросе"
	t_has "другая программа" "$BOT_ERR" "причина"
	t_eq 1 "$(grep -c '^getUpdates' "$WORK/tg.calls")" "запросов к Телеграму"
}
test_pair_transient_error_pauses() {  # I3: 429 и прочие сбои — пауза, а не 40 запросов в секунду
	base_env; BOT_USERNAME=my_vpn_bot; BOT_HOOK_URL=
	tg_push getUpdates '{"ok":true,"result":[]}'
	tg_push getUpdates '{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 1"}'
	tg_push getUpdates "{\"ok\":true,\"result\":[$(msg 10 42 Ann ann)]}"
	answers y
	sleep() { echo "sleep $*" >> "$WORK/sleeps"; }
	bot_pair 30 || t_fail "не привязал после 429: $BOT_ERR"
	grep -q '^sleep' "$WORK/sleeps" 2> /dev/null || t_fail "без паузы после ошибки"
}
test_pair_delete_webhook_failure() {  # I3: вебхук не снялся — опрос не начинаем
	base_env; BOT_USERNAME=my_vpn_bot; BOT_SUBDOMAIN=sub1; BOT_HOOK_URL=https://vpn-bot.sub1.workers.dev/tg
	tg_push deleteWebhook '{"ok":false,"error_code":400,"description":"Bad Request"}'
	answers y
	! bot_pair 30 || t_fail "пошёл дальше, не сняв вебхук"
	! grep -q '^getUpdates' "$WORK/tg.calls" || t_fail "опрос при стоящем вебхуке"
}
realkey() {  # realkey ИМЯ → строка настоящего ключа «ssh-ed25519 … vpn-bot»; отпечаток — в $WORK/ИМЯ.fpr
	ssh-keygen -q -t ed25519 -N '' -C vpn-bot -f "$WORK/$1" > /dev/null
	ssh-keygen -lf "$WORK/$1.pub" | awk '{print $2}' > "$WORK/$1.fpr"
	cat "$WORK/$1.pub"
}
fpr_binding() { printf '{"type":"plain_text","name":"ENTRY_SSH_KEY_FPR","text":"%s"}' "$(cat "$WORK/$1.fpr")"; }
test_keys_new_when_worker_holds_other_key() {  # I1: строка от оборванного запуска, у воркера другой ключ
	keys_env
	realkey cut >> "$BOT_AUTH_KEYS"   # её приватную часть стёр оборванный запуск
	realkey old > /dev/null           # этот ключ на самом деле в воркере
	settings "[{\"type\":\"secret_text\",\"name\":\"ENTRY_SSH_KEY\"},$(fpr_binding old)]"
	bot_keys 0
	t_eq 1 "$BOT_KEY_NEW" "ключ выпущен заново"
	t_eq 1 "$(grep -c ' vpn-bot$' "$BOT_AUTH_KEYS")" "строк vpn-bot"
}
test_keys_new_when_worker_has_no_fingerprint() {  # бот прежней версии или ручной: сверить не с чем
	keys_env; realkey old >> "$BOT_AUTH_KEYS"
	settings '[{"type":"secret_text","name":"ENTRY_SSH_KEY"}]'
	bot_keys 0
	t_eq 1 "$BOT_KEY_NEW" "без отпечатка — новый ключ"
}
test_keys_new_when_exit_dropped() {  # I2: ключ входа = ключ выхода; ушли с выхода — ключ меняется
	keys_env; realkey old >> "$BOT_AUTH_KEYS"
	settings "[{\"type\":\"secret_text\",\"name\":\"ENTRY_SSH_KEY\"},$(fpr_binding old),{\"type\":\"secret_text\",\"name\":\"EXIT_SSH_KEY\"}]"
	EXIT_MODE=direct
	bot_keys 0
	t_eq 1 "$BOT_KEY_NEW" "старый выход прежний ключ больше не пустит"
}
test_keys_inherit_when_chain_kept() {
	keys_env; realkey old >> "$BOT_AUTH_KEYS"
	settings "[{\"type\":\"secret_text\",\"name\":\"ENTRY_SSH_KEY\"},$(fpr_binding old),{\"type\":\"secret_text\",\"name\":\"EXIT_SSH_KEY\"}]"
	EXIT_MODE=chain
	bot_keys 0
	t_eq 0 "$BOT_KEY_NEW" "выход тот же — ключ прежний"
}
test_deploy_uploads_key_fingerprint() {  # отпечаток рядом с ключом, в той же загрузке
	deploy_env
	local want; want=$(grep ' vpn-bot$' "$BOT_AUTH_KEYS" | ssh-keygen -lf - | awk '{print $2}')
	bot_deploy || t_fail "не развернул: $BOT_ERR"
	t_eq "plain_text|$want" "$(mb ENTRY_SSH_KEY_FPR)" "отпечаток ключа"
}
test_deploy_new_subdomain_waits_before_webhook() {  # I8: новый адрес workers.dev заводится около минуты
	deploy_env; BOT_SUBDOMAIN=; BOT_HEALTH_SLEEP=0
	cf_set "PUT /accounts/A1/workers/subdomain" '{"success":true,"result":{"subdomain":"vpnbot-abc123"}}'
	bot_http() {
		local n
		case $1 in
			/healthz)
				n=$(($(cat "$WORK/hz.n" 2> /dev/null || echo 0) + 1)); echo "$n" > "$WORK/hz.n"
				if [ "$n" -gt 20 ]; then echo "healthz ok" >> "$WORK/tg.calls"; echo ok; fi ;;
			"/selftest?part="*) cat "$WORK/st.${1#*part=}" ;;
		esac
	}
	bot_deploy || t_fail "не дождался нового адреса: $BOT_ERR"
	t_eq "https://vpn-bot.vpnbot-abc123.workers.dev" "$BOT_ORIGIN" "адрес"
	local hz wh
	hz=$(grep -n '^healthz ok' "$WORK/tg.calls" | head -1 | cut -d: -f1)
	wh=$(grep -n '^setWebhook' "$WORK/tg.calls" | head -1 | cut -d: -f1)
	[ -n "$hz" ] && [ -n "$wh" ] && [ "$hz" -lt "$wh" ] || t_fail "вебхук поставлен раньше, чем адрес заработал (healthz $hz, setWebhook $wh)"
}
test_ssh_key_only_ignores_bot_key() {  # I5: ключ бота — не ключ человека, с ним одним пароль не выключать
	eval "$(awk '/^root_has_own_key\(\) \{/,/^}/' "$ROOT/src/install-vpn.sh.in")"
	local f=$WORK/ak
	printf '%s\n' 'ssh-ed25519 AAAAbot vpn-bot' > "$f"
	! root_has_own_key "$f" || t_fail "ключ бота сошёл за ключ человека"
	printf '%s\n' '# комментарий' '' 'ssh-ed25519 AAAAbot vpn-bot' > "$f"
	! root_has_own_key "$f" || t_fail "комментарий сошёл за ключ"
	printf '%s\n' 'ssh-ed25519 AAAAbot vpn-bot' 'ssh-rsa AAAAuser user@laptop' > "$f"
	root_has_own_key "$f" || t_fail "ключ человека не увиден"
	! root_has_own_key "$WORK/нет-файла" || t_fail "нет файла — нет ключа"
	grep -q 'elif root_has_own_key; then' "$ROOT/src/install-vpn.sh.in" || t_fail "--ssh-key-only проверяет не этой функцией"
}
test_hints_never_put_tokens_in_history() {  # I7: токен в командной строке — это /root/.bash_history
	! grep -nE '(CF_API_TOKEN|VPN_BOT_TOKEN)=…' "$ROOT/src/install-vpn.sh.in" "$ROOT/README.md" || t_fail "подсказка с токеном в командной строке"
}

# ——— домен из Cloudflare (10.11): выбор на вопросах, запись — на шаге DNS ———
test_template_url_without_python() {  # ссылка нужна на первом же вопросе, а python3 там может не быть
	local out
	out=$(PATH=/nonexistent bot_template_url)
	t_eq "$(bot_template_url)" "$out" "без python3 та же ссылка"
	t_has 'permissionGroupKeys=' "$out" "права в ссылке"
}
zones_env() {  # токен уже введён; в аккаунте два домена; IP сервера 1.2.3.4
	base_env; DOMAIN=
	bot_public_ip() { echo 1.2.3.4; }
	cf_set "GET /zones?per_page=50" '{"success":true,"result":[{"id":"Z1","name":"example.com","status":"active"},{"id":"Z2","name":"other.org","status":"active"}]}'
}
one_zone() { cf_set "GET /zones?per_page=50" '{"success":true,"result":[{"id":"Z1","name":"example.com","status":"active"}]}'; }
recs() {  # recs ЗОНА ИМЯ 'записи JSON' — что Cloudflare знает об имени
	cf_set "GET /zones/$1/dns_records?name=$2&per_page=100" "{\"success\":true,\"result\":$3}"
}
test_cf_zones_lists_active() {
	zones_env
	cf_set "GET /zones?per_page=50" '{"success":true,"result":[{"id":"Z1","name":"example.com","status":"active"},{"id":"Z3","name":"pending.net","status":"pending"}]}'
	cf_zones || t_fail "не прочитал: $BOT_ERR"
	t_eq "$(printf 'Z1\texample.com')" "$DNS_ZONES" "только активные"
}
test_cf_zones_bad_token() {
	zones_env
	cf_set "GET /zones?per_page=50" '{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}]}'
	! cf_zones > /dev/null || t_fail "плохой токен прошёл"
	t_has "не принял токен" "$BOT_ERR" "понятная причина"
}
test_dns_pick_single_zone_apex() {
	zones_env; one_zone; recs Z1 example.com '[]'
	answers ''
	dns_pick || t_fail "не выбрал: $BOT_ERR"
	t_eq example.com "$DOMAIN" "сам домен"; t_eq Z1 "$DNS_ZONE_ID" "зона"; t_eq 0 "$DNS_REPOINT" "перенаправлять нечего"
	! grep -q 'Какой взять' "$WORK/tty.out" || t_fail "спросил, какой из одного"
}
test_dns_pick_zone_and_subdomain() {
	zones_env; recs Z2 vpn.other.org '[]'
	answers 2 vpn
	dns_pick || t_fail "не выбрал: $BOT_ERR"
	t_eq vpn.other.org "$DOMAIN" "поддомен второго домена"; t_eq Z2 "$DNS_ZONE_ID" "зона"
	grep -q '2) other.org' "$WORK/tty.out" || t_fail "нет списка доменов"
}
test_dns_pick_full_name() {
	zones_env; recs Z1 vpn.example.com '[]'
	answers 1 VPN.Example.com
	dns_pick || t_fail "не выбрал: $BOT_ERR"
	t_eq vpn.example.com "$DOMAIN" "полное имя принято"
}
test_dns_pick_bad_choice_reasks() {
	zones_env; recs Z1 example.com '[]'
	answers 7 1 ''
	dns_pick || t_fail "не выбрал: $BOT_ERR"
	t_eq example.com "$DOMAIN" "со второй попытки"
}
test_dns_pick_other_ip_declined_asks_name_again() {  # запись указывает на чужой IP: по умолчанию не трогаем
	zones_env; one_zone
	recs Z1 example.com '[{"id":"R1","type":"A","name":"example.com","content":"9.9.9.9","proxied":false}]'
	recs Z1 vpn.example.com '[]'
	answers '' n vpn
	dns_pick || t_fail "не выбрал: $BOT_ERR"
	t_eq vpn.example.com "$DOMAIN" "взял другое имя"; t_eq 0 "$DNS_REPOINT" "без перенаправления"
	t_has "9.9.9.9" "$(cat "$WORK/tty.out")" "вопрос называет нынешний адрес"
	grep -q '\[y/N\]' "$WORK/tty.out" || t_fail "вопрос не [y/N]"
}
test_dns_pick_other_ip_consented() {
	zones_env; one_zone
	recs Z1 example.com '[{"id":"R1","type":"A","name":"example.com","content":"9.9.9.9","proxied":true}]'
	answers '' y
	dns_pick || t_fail "не выбрал: $BOT_ERR"
	t_eq example.com "$DOMAIN" "домен"; t_eq 1 "$DNS_REPOINT" "согласие запомнено"
}
test_dns_pick_points_here_no_question() {
	zones_env; one_zone
	recs Z1 example.com '[{"id":"R1","type":"A","name":"example.com","content":"1.2.3.4","proxied":true}]'
	answers ''
	dns_pick || t_fail "не выбрал: $BOT_ERR"
	! grep -q '\[y/N\]' "$WORK/tty.out" || t_fail "лишний вопрос: запись уже указывает сюда"
	t_eq 0 "$DNS_REPOINT" "перенаправлять нечего"
}
test_dns_pick_aaaa_needs_consent() {
	zones_env; one_zone
	recs Z1 example.com '[{"id":"R2","type":"AAAA","name":"example.com","content":"2001:db8::1","proxied":false}]'
	answers '' n example.com y
	dns_pick || t_fail "не выбрал: $BOT_ERR"
	t_has "2001:db8::1" "$(cat "$WORK/tty.out")" "вопрос называет AAAA"
	t_eq 1 "$DNS_REPOINT" "согласие со второго раза"
}
test_dns_pick_no_zones() {
	zones_env; cf_set "GET /zones?per_page=50" '{"success":true,"result":[]}'
	answers ''
	! dns_pick || t_fail "выбрал из пустого списка"
	t_has "нет доменов" "$BOT_ERR" "причина"
}
dns_env() {  # шаг DNS: известен IP сервера, зона и имя
	base_env; good_cf; cf_stub_capture
	DOMAIN=vpn.example.com PUBLIC_IP=1.2.3.4 DNS_ZONE_ID=Z1 DNS_REPOINT=0
}
cf_writes() { grep -E '^(POST|PATCH|PUT|DELETE) /zones/' "$WORK/cf.calls" || true; }
body_of() {  # body_of 'МЕТОД ПУТЬ' → тело этого запроса
	local n; n=$(grep -nxF "$1" "$WORK/cf.calls" | head -1 | cut -d: -f1)
	[ -n "$n" ] && cat "$WORK/cap.$n.req.json"
}
test_dns_apply_creates_record() {
	dns_env; recs Z1 vpn.example.com '[]'
	dns_apply || t_fail "не создал: $BOT_ERR"
	local b; b=$(body_of "POST /zones/Z1/dns_records")
	t_has '"type": "A"' "$b" "тип"; t_has '"name": "vpn.example.com"' "$b" "имя"
	t_has '"content": "1.2.3.4"' "$b" "адрес"; t_has '"proxied": false' "$b" "без облака"
	t_has "vpn.example.com" "$DNS_REPORT" "в отчёте"
}
test_dns_apply_points_here_untouched() {
	dns_env; recs Z1 vpn.example.com '[{"id":"R1","type":"A","name":"vpn.example.com","content":"1.2.3.4","proxied":false}]'
	dns_apply || t_fail "упал: $BOT_ERR"
	t_eq "" "$(cf_writes)" "ничего не писал"
}
test_dns_apply_turns_off_proxy_here() {
	dns_env; recs Z1 vpn.example.com '[{"id":"R1","type":"A","name":"vpn.example.com","content":"1.2.3.4","proxied":true}]'
	dns_apply || t_fail "упал: $BOT_ERR"
	t_eq "PATCH /zones/Z1/dns_records/R1" "$(cf_writes)" "только облако"
	t_has '"proxied": false' "$(body_of "PATCH /zones/Z1/dns_records/R1")" "облако выключено"
}
test_dns_apply_other_ip_needs_consent() {
	dns_env; recs Z1 vpn.example.com '[{"id":"R1","type":"A","name":"vpn.example.com","content":"9.9.9.9","proxied":false}]'
	answers ''   # Enter — «нет»
	! dns_apply || t_fail "перенаправил без согласия"
	t_eq "" "$(cf_writes)" "ничего не писал"
	t_has "9.9.9.9" "$BOT_ERR" "причина называет адрес"
}
test_dns_apply_asks_in_terminal() {  # --domain в терминале: выбора из списка не было — спросить на шаге DNS
	dns_env; recs Z1 vpn.example.com '[{"id":"R1","type":"A","name":"vpn.example.com","content":"9.9.9.9","proxied":false}]'
	answers y
	dns_apply || t_fail "не перенаправил с согласием: $BOT_ERR"
	t_has '"content": "1.2.3.4"' "$(body_of "PATCH /zones/Z1/dns_records/R1")" "перенаправлено"
	t_has "9.9.9.9" "$(cat "$WORK/tty.out")" "вопрос называет нынешний адрес"
	grep -q '\[y/N\]' "$WORK/tty.out" || t_fail "вопрос не [y/N]"
}
test_dns_apply_repoint_with_consent() {
	dns_env; DNS_REPOINT=1
	recs Z1 vpn.example.com '[{"id":"R1","type":"A","name":"vpn.example.com","content":"9.9.9.9","proxied":true},{"id":"R2","type":"AAAA","name":"vpn.example.com","content":"2001:db8::1","proxied":false},{"id":"R3","type":"A","name":"vpn.example.com","content":"8.8.8.8","proxied":false}]'
	dns_apply || t_fail "не перенаправил: $BOT_ERR"
	local b; b=$(body_of "PATCH /zones/Z1/dns_records/R1")
	t_has '"content": "1.2.3.4"' "$b" "адрес"; t_has '"proxied": false' "$b" "без облака"
	grep -qx 'DELETE /zones/Z1/dns_records/R2' "$WORK/cf.calls" || t_fail "AAAA не удалена"
	grep -qx 'DELETE /zones/Z1/dns_records/R3' "$WORK/cf.calls" || t_fail "лишняя A не удалена"
}
test_dns_apply_cname_replaced_with_consent() {
	dns_env; DNS_REPOINT=1
	recs Z1 vpn.example.com '[{"id":"C1","type":"CNAME","name":"vpn.example.com","content":"x.herokudns.com","proxied":false}]'
	dns_apply || t_fail "не заменил: $BOT_ERR"
	grep -qx 'DELETE /zones/Z1/dns_records/C1' "$WORK/cf.calls" || t_fail "CNAME не удалён"
	t_has '"content": "1.2.3.4"' "$(body_of "POST /zones/Z1/dns_records")" "A-запись создана"
	local d p; d=$(grep -nx 'DELETE /zones/Z1/dns_records/C1' "$WORK/cf.calls" | cut -d: -f1); p=$(grep -nx 'POST /zones/Z1/dns_records' "$WORK/cf.calls" | cut -d: -f1)
	[ "$d" -lt "$p" ] || t_fail "A создаётся раньше, чем ушёл CNAME (Cloudflare не даст)"
}
test_dns_apply_cname_needs_consent() {
	dns_env; recs Z1 vpn.example.com '[{"id":"C1","type":"CNAME","name":"vpn.example.com","content":"x.herokudns.com","proxied":false}]'
	answers ''
	! dns_apply || t_fail "заменил CNAME без согласия"
	t_eq "" "$(cf_writes)" "ничего не писал"
	t_has "x.herokudns.com" "$BOT_ERR" "причина называет, куда ведёт CNAME"
}
test_dns_apply_write_refused() {
	dns_env; recs Z1 vpn.example.com '[]'
	cf_set "POST /zones/Z1/dns_records" '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}'
	! dns_apply || t_fail "сделал вид, что создал"
	t_has "Authentication error" "$BOT_ERR" "причина от Cloudflare"
}
test_dns_find_zone_from_parent() {  # без терминала (--domain): зона — по имени
	base_env; good_cf; DNS_ZONE_ID=
	dns_find_zone || t_fail "не нашёл: $BOT_ERR"
	t_eq Z1 "$DNS_ZONE_ID" "зона родителя"
}
test_dns_ask_token_retries() {  # первый токен не подошёл — спросить ещё раз, второй берётся
	base_env; rm -f "$BOT_DIR/cf.hdr" "$BOT_DIR/cf.token"
	cf_api() {
		printf '%s\n' "$1 $2" >> "$WORK/cf.calls"
		if grep -q good "$BOT_DIR/cf.hdr"; then echo '{"success":true,"result":[{"id":"Z1","name":"example.com","status":"active"}]}'
		else echo '{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}]}'; fi
	}
	answers bad good
	dns_ask_token || t_fail "не принял второй токен: $BOT_ERR"
	t_eq 2 "$(grep -o 'Токен Cloudflare: ' "$WORK/tty.out" | wc -l)" "спросил дважды"
	grep -q 'Invalid API Token' "$WORK/tty.out" || t_fail "не сказал, почему первый не подошёл"
	grep -q 'permissionGroupKeys' "$WORK/tty.out" || t_fail "нет ссылки на токен"
}
test_dns_ask_token_from_env() {  # токен дан окружением (CF_API_TOKEN) — не спрашивать
	base_env
	cf_set "GET /zones?per_page=50" '{"success":true,"result":[{"id":"Z1","name":"example.com","status":"active"}]}'
	answers never-asked
	dns_ask_token || t_fail "не принял токен из окружения: $BOT_ERR"
	! grep -q 'Токен Cloudflare: ' "$WORK/tty.out" 2> /dev/null || t_fail "спросил токен, хотя он дан"
	t_has example.com "$DNS_ZONES" "домены прочитаны"
}
test_dns_wait_until_visible() {
	base_env; DOMAIN=vpn.example.com PUBLIC_IP=1.2.3.4 DNS_WAIT_SLEEP=0
	resolve() { local n; n=$(($(cat "$WORK/rs.n" 2> /dev/null || echo 0) + 1)); echo "$n" > "$WORK/rs.n"; [ "$n" -lt 3 ] || echo 1.2.3.4; }
	dns_wait || t_fail "не дождался"
	t_eq 3 "$(cat "$WORK/rs.n")" "опросов DNS"
}
test_dns_wait_gives_up() {
	base_env; DOMAIN=vpn.example.com PUBLIC_IP=1.2.3.4 DNS_WAIT_SLEEP=0 DNS_WAIT_TRIES=2
	resolve() { echo 9.9.9.9; }
	! dns_wait || t_fail "дождался чужого адреса"
}
test_need_python_no_apt_when_present() {
	base_env; mkdir -p "$WORK/bin"
	printf '#!/bin/bash\necho "$@" >> "$WORK/apt.calls"\n' > "$WORK/bin/apt-get"; chmod +x "$WORK/bin/apt-get"
	PATH="$WORK/bin:$PATH" bot_need_python || t_fail "упала при python3 на месте"
	[ ! -e "$WORK/apt.calls" ] || t_fail "звала apt, хотя python3 и curl есть"
}
test_have_cf_token_from_file() {  # токен ввели на выборе домена — второй раз его не спрашивать
	base_env
	BOT_CF_TOKEN=''
	bot_have_cf_token || t_fail "токен в файле не увиден"
	rm -f "$BOT_DIR/cf.hdr"
	! bot_have_cf_token || t_fail "токена нет, а он «есть»"
}
test_read_tokens_skips_cf_when_in_file() {  # токен Cloudflare в файле (ввели при выборе домена), токена бота нет
	base_env; BOT_CF_TOKEN='' BOT_TG_TOKEN='' S_BOT=''; rm -f "$BOT_DIR/tg.token"
	answers TGTOKEN
	bot_read_tokens
	! grep -q 'Токен Cloudflare' "$WORK/tty.out" || t_fail "токен Cloudflare спрошен второй раз"
	t_eq TGTOKEN "$BOT_TG_TOKEN" "токен бота"
}

# ——— ревью выбора домена (10.11): токен бота из окружения, имена, поздний вопрос, шаг DNS ———
test_read_tokens_keeps_env_bot_token() {  # токен бота дан окружением и уже в файле — не спрашивать заново
	base_env; BOT_CF_TOKEN='' BOT_TG_TOKEN='' S_BOT=''
	answers SHOULD-NOT-BE-ASKED
	bot_read_tokens
	! grep -q 'Токен бота' "$WORK/tty.out" 2> /dev/null || t_fail "токен бота спрошен, хотя он дан"
	t_eq t "$(cat "$BOT_DIR/tg.token")" "прежний токен бота на месте"
}
test_dns_pick_other_zone_full_name() {  # выбрали один домен, а вписали полное имя другого из того же аккаунта
	zones_env; recs Z2 vpn.other.org '[]'
	answers 1 vpn.other.org
	dns_pick || t_fail "не выбрал: $BOT_ERR"
	t_eq vpn.other.org "$DOMAIN" "имя как вписано"; t_eq Z2 "$DNS_ZONE_ID" "зона — того домена"
}
test_dns_pick_dotted_name_confirmed() {  # имя с точкой не из аккаунта — переспросить, по умолчанию «нет»
	zones_env; recs Z1 vpn.example.com '[]'
	answers 1 vpn.unknown.net '' vpn
	dns_pick || t_fail "не выбрал: $BOT_ERR"
	t_eq vpn.example.com "$DOMAIN" "после «нет» — новое имя"
	t_has "vpn.unknown.net.example.com" "$(cat "$WORK/tty.out")" "переспросил с итоговым адресом"
}
test_dns_pick_multilevel_subdomain_yes() {
	zones_env; recs Z1 vpn.eu.example.com '[]'
	answers 1 vpn.eu y
	dns_pick || t_fail "не выбрал: $BOT_ERR"
	t_eq vpn.eu.example.com "$DOMAIN" "многоуровневый поддомен по «да»"
}
test_dns_pick_unknown_server_ip_asks() {  # IP сервера не узнать — любая A-запись под вопросом
	zones_env; one_zone; bot_public_ip() { :; }
	recs Z1 example.com '[{"id":"R1","type":"A","name":"example.com","content":"1.2.3.4","proxied":false}]'
	recs Z1 vpn.example.com '[]'
	answers '' n vpn
	dns_pick || t_fail "не выбрал: $BOT_ERR"
	t_eq vpn.example.com "$DOMAIN" "после «нет» — другое имя"
	grep -q '\[y/N\]' "$WORK/tty.out" || t_fail "не спросил"
}
test_consent_flushes_typeahead() {  # поздний вопрос не должен получить «y», набранное раньше на другой вопрос
	base_env; answers n
	bot_tty_flush() { echo flush >> "$WORK/flush.calls"; }
	! bot_consent "Перенаправить?" || t_fail "согласие из ниоткуда"
	t_eq flush "$(cat "$WORK/flush.calls" 2> /dev/null)" "набранное заранее сброшено перед вопросом"
}
test_dns_apply_no_terminal_refuses() {  # без терминала чужую запись не трогаем никогда
	dns_env; recs Z1 vpn.example.com '[{"id":"R1","type":"A","name":"vpn.example.com","content":"9.9.9.9","proxied":false}]'
	bot_tty_ok() { return 1; }
	! dns_apply || t_fail "перенаправил без терминала"
	t_eq "" "$(cf_writes)" "ничего не писал"
	t_has "в терминале" "$BOT_ERR" "сказано, как дать согласие"
}
test_init_secrets_without_work() {  # на вопросах $WORK ещё нет: свой каталог 700, файлы 600, ловушка его уберёт
	local t=$WORK/tmpd d
	mkdir -p "$t"
	(
		WORK='' BOT_DIR='' TMPDIR=$t
		BOT_CF_TOKEN=cfX bot_init_secrets
		{ echo "$BOT_DIR"; stat -c %a "$BOT_DIR" "$BOT_DIR/cf.hdr"; trap -p EXIT; } > "$t/out"
	)
	d=$(sed -n 1p "$t/out")
	case $d in "$t"/vpn-bot.*) ;; *) t_fail "каталог не в TMPDIR: $d" ;; esac
	t_eq 700 "$(sed -n 2p "$t/out")" "права каталога"
	t_eq 600 "$(sed -n 3p "$t/out")" "права файла"
	t_has 'rm -rf' "$(sed -n 4p "$t/out")" "ловушка выхода"
	[ ! -e "$d" ] || t_fail "каталог с токеном остался после выхода"
}
step_fns() {  # шаг DNS из шаблона (dns_step, dns_verify); die/ok/warn — строками в $WORK/out
	eval "$(awk '/^(dns_step|dns_verify)\(\) \{/,/^}/' "$ROOT/src/install-vpn.sh.in")"
	die() { echo "DIE $*" >> "$WORK/out"; exit 1; }
	ok() { echo "OK $*" >> "$WORK/out"; }
	warn() { echo "WARN $*" >> "$WORK/out"; }
	is_cloudflare_ip() { return 1; }
	MODE=domain SKIP_DNS=0 DNS_NOT_CF=0 BOT_DO=0 DNS_SET_BY_API=0 DNS_WAIT_SLEEP=0 DNS_WAIT_FIRST=0 DNS_WAIT_TRIES=2
	: > "$WORK/out"
}
cf_reqs() { grep -c . "$WORK/cf.calls" 2> /dev/null || true; }
test_dns_step_no_token_no_cloudflare() {
	dns_env; step_fns; rm -f "$BOT_DIR/cf.hdr" "$BOT_DIR/cf.token"; : > "$WORK/cf.calls"
	resolve() { [ "$2" = A ] && echo 1.2.3.4; true; }
	( dns_step ) || t_fail "упал: $(cat "$WORK/out")"
	t_eq 0 "$(cf_reqs)" "запросов к Cloudflare"
	t_has "указывает на этот сервер" "$(cat "$WORK/out")" "обычная проверка"
}
test_dns_step_not_cloudflare_no_requests() {
	dns_env; step_fns; DNS_NOT_CF=1; : > "$WORK/cf.calls"
	resolve() { [ "$2" = A ] && echo 1.2.3.4; true; }
	( dns_step ) || t_fail "упал: $(cat "$WORK/out")"
	t_eq 0 "$(cf_reqs)" "запросов к Cloudflare при домене не в Cloudflare"
}
test_dns_step_skip_dns_no_requests() {
	dns_env; step_fns; SKIP_DNS=1; : > "$WORK/cf.calls"
	( dns_step ) || t_fail "упал: $(cat "$WORK/out")"
	t_eq 0 "$(cf_reqs)" "запросов к Cloudflare при --skip-dns-check"
	t_has "не проверялась" "$(cat "$WORK/out")" "предупреждение"
}
test_dns_step_wipes_token_without_bot() {
	dns_env; step_fns; recs Z1 vpn.example.com '[]'
	resolve() { [ "$2" = A ] && echo 1.2.3.4; true; }
	( dns_step; [ ! -e "$BOT_DIR/cf.hdr" ] && [ ! -e "$BOT_DIR/cf.token" ] || echo "TOKEN LEFT" >> "$WORK/out" ) || t_fail "упал: $(cat "$WORK/out")"
	! grep -q 'TOKEN LEFT' "$WORK/out" || t_fail "без бота токен остался на диске"
	grep -qx 'POST /zones/Z1/dns_records' "$WORK/cf.calls" || t_fail "запись не создана"
}
test_dns_step_keeps_token_for_bot() {
	dns_env; step_fns; BOT_DO=1; recs Z1 vpn.example.com '[]'
	resolve() { [ "$2" = A ] && echo 1.2.3.4; true; }
	( dns_step; [ -s "$BOT_DIR/cf.hdr" ] || echo "TOKEN GONE" >> "$WORK/out" ) || t_fail "упал: $(cat "$WORK/out")"
	! grep -q 'TOKEN GONE' "$WORK/out" || t_fail "токен для бота стёрт"
	grep -qx 'POST /zones/Z1/dns_records' "$WORK/cf.calls" || t_fail "запись не создана"
}
test_dns_step_stale_cache_after_own_write_warns() {  # перенаправили сами, а кэш DNS ещё отдаёт старое — не останавливаться
	dns_env; step_fns; DNS_REPOINT=1
	recs Z1 vpn.example.com '[{"id":"R1","type":"A","name":"vpn.example.com","content":"9.9.9.9","proxied":false},{"id":"R2","type":"AAAA","name":"vpn.example.com","content":"2001:db8::1","proxied":false}]'
	resolve() { case $2 in A) echo 9.9.9.9 ;; AAAA) echo 2001:db8::1 ;; esac; }
	( dns_step ) || t_fail "остановился на собственной записи: $(cat "$WORK/out")"
	! grep -q '^DIE' "$WORK/out" || t_fail "остановка: $(grep '^DIE' "$WORK/out")"
	grep -q '^WARN.*кэш' "$WORK/out" || t_fail "не сказал про кэш DNS: $(cat "$WORK/out")"
}
test_dns_verify_strict_without_own_write() {  # запись ставил не скрипт — прежняя строгая проверка
	dns_env; step_fns
	resolve() { [ "$2" = A ] && echo 9.9.9.9; true; }
	! ( dns_verify ) || t_fail "прошёл с чужой A-записью"
	grep -q '^DIE.*9.9.9.9' "$WORK/out" || t_fail "нет понятной остановки: $(cat "$WORK/out")"
}

test_all_input_visible() {  # решение владельца 11.11: всё, что вводят, видно на экране — ни одного скрытого ввода
	local f
	for f in "$ROOT/src/bot.sh" "$ROOT/src/install-vpn.sh.in" "$ROOT/install-passwall2.sh" "$ROOT/README.md" "$ROOT/src/README-friend.md"; do
		! grep -n 'не отобра[зж]' "$f" || t_fail "в $(basename "$f") осталось «не отобразится» или «не отображается»"
		! grep -nE 'read +(-[a-zA-Z]*s[a-zA-Z]*|-s)( |$)' "$f" || t_fail "в $(basename "$f") остался скрытый ввод (read -s)"
	done
}

test_no_password_login_nag() {  # решение владельца 11.11: без напоминания «вход по паролю не трогали»
	local f
	for f in "$ROOT/src/install-vpn.sh.in" "$ROOT/src/kit/usr/local/lib/vpn-backup/restore.sh"; do
		! grep -n 'вход по паролю не трогали' "$f" || t_fail "в $(basename "$f") осталось напоминание про вход по паролю"
	done
	# Раздел «SSH» установщика — только когда есть что сказать (нет sshd или --ssh-key-only), без пустого заголовка.
	! grep -nx 'say "SSH"' "$ROOT/src/install-vpn.sh.in" || t_fail "заголовок «SSH» печатается всегда"
}

# ——— Чужой 3x-ui: вопрос в самом начале, порты его подключений фаервол не закрывает ———
xui_fns() {  # функции шаблона foreign_xui_check / xui_inbound_ports / fw_kept_ports; die/ok/warn — строками в $WORK/out
	eval "$(awk '/^(foreign_xui_check|xui_inbound_ports|fw_kept_ports|ufw_active|ufw_state)\(\) \{/,/^}/' "$ROOT/src/install-vpn.sh.in")"
	die() { echo "DIE $*" >> "$WORK/out"; exit 1; }
	ok() { echo "OK $*" >> "$WORK/out"; }
	warn() { echo "WARN $*" >> "$WORK/out"; }
	DB=$WORK/x-ui.db STATE=$WORK/vpn-install.env XUI_VERSION=3.3.1 FOREIGN_XUI=0
	: > "$WORK/out"
}
mkdb() {  # mkdb "порт|listen|протокол|settings|stream|enable" … → $DB с таблицей inbounds, как у 3x-ui
	python3 -I - "$DB" "$@" <<'EOF'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("create table inbounds (id integer primary key, port integer, listen text, protocol text, settings text, stream_settings text, enable integer)")
for row in sys.argv[2:]:
    port, listen, proto, settings, stream, enable = row.split("|")
    db.execute("insert into inbounds (port, listen, protocol, settings, stream_settings, enable) values (?, ?, ?, ?, ?, ?)",
               (int(port), listen, proto, settings, stream, int(enable)))
db.commit()
EOF
}
test_foreign_xui_none_no_question() {  # 3x-ui нет — не спрашивает
	xui_fns; answers y
	foreign_xui_check
	t_eq 0 "$FOREIGN_XUI" "не чужой"
	! grep -q '\[y/N\]' "$WORK/tty.out" 2> /dev/null || t_fail "спросил без 3x-ui"
}
test_foreign_xui_own_install_no_question() {  # 3x-ui ставил этот скрипт (есть его настройки или следы неудачной попытки)
	xui_fns; answers y y
	mkdb '2083||vless|{}|{}|1'
	: > "$STATE"
	foreign_xui_check
	rm -f "$STATE"; : > "$STATE.failed-20261111-000000"
	foreign_xui_check
	t_eq 0 "$FOREIGN_XUI" "свой"
	! grep -q '\[y/N\]' "$WORK/tty.out" 2> /dev/null || t_fail "спросил про свой 3x-ui"
}
test_foreign_xui_asks_and_continues_on_yes() {
	xui_fns; answers y
	mkdb '443||vless|{}|{}|1' '8443||vmess|{}|{}|1'
	foreign_xui_check
	t_eq 1 "$FOREIGN_XUI" "согласие запомнено"
	grep -q 'Продолжить? \[y/N\]' "$WORK/tty.out" || t_fail "не спросил"
	t_has "подключений: 2" "$(cat "$WORK/out")" "число подключений"
	t_has "останутся" "$(cat "$WORK/out")" "что останется"
	t_has "фаервол не закроет" "$(cat "$WORK/out")" "порты подключений"
}
test_foreign_xui_no_stops_without_changes() {
	xui_fns; answers n
	mkdb '443||vless|{}|{}|1'
	! ( foreign_xui_check ) || t_fail "продолжил после «n»"
	t_has "DIE ничего не менял" "$(cat "$WORK/out")" "остановка"
}
test_foreign_xui_without_tty_stops() {
	xui_fns
	bot_tty_ok() { return 1; }
	mkdb '443||vless|{}|{}|1'
	! ( foreign_xui_check ) || t_fail "продолжил без терминала"
	t_has "в терминале" "$(cat "$WORK/out")" "подсказка"
}
test_foreign_xui_asked_before_any_question() {  # вопрос — раньше домена, токенов, DNS, бота и пакетов
	local f=$ROOT/src/install-vpn.sh.in call q
	call=$(grep -n 'foreign_xui_check$' "$f" | grep -v '()' | head -1 | cut -d: -f1)
	[ -n "$call" ] || t_fail "foreign_xui_check не вызывается"
	for q in 'Есть ли у вас свой домен' '^dns_step$' 'until bot_validate' '^say "Пакеты"' '^say "Проверка сервера"'; do
		[ "$call" -lt "$(grep -n -m1 "$q" "$f" | cut -d: -f1)" ] || t_fail "вопрос про 3x-ui позже, чем «$q»"
	done
	t_eq 1 "$(grep -c 'Продолжить? \[y/N\]\|bot_consent "Продолжить?"' "$f")" "вопрос про чужой 3x-ui — один, в foreign_xui_check"
}
test_inbound_ports_by_protocol() {  # порты включённых подключений панели, слушающих не только localhost
	xui_fns
	mkdb '2083||vless|{}|{"network":"xhttp","security":"reality"}|1' \
		'8443|0.0.0.0|vmess|{}|{"network":"ws"}|1' \
		'1080||shadowsocks|{"network":"tcp,udp"}|{}|1' \
		'51820||wireguard|{}|{}|1' \
		'4443||vless|{}|{"network":"kcp"}|1' \
		'1081||mixed|{"udp":true}|{}|1' \
		'9000|127.0.0.1|vless|{}|{"network":"ws"}|1' \
		'9001||trojan|{}|{}|0' \
		'9002|::1|vless|{}|{}|1' \
		'8444||vless|{}|{"network":"xhttp","security":"tls","tlsSettings":{"alpn":["h3"]}}|1'
	t_eq "1080/tcp 1080/udp 1081/tcp 1081/udp 2083/tcp 4443/udp 8443/tcp 8444/tcp 8444/udp 51820/udp" "$(xui_inbound_ports | tr '\n' ' ' | sed 's/ $//')" "порты"
}
test_fw_kept_ports_long_active_ufw() {  # длинный вывод включённого ufw: «| grep -q» под pipefail читал его как «выключен»
	xui_fns
	mkdb '8443||vmess|{}|{"network":"ws"}|1'
	ufw() { echo "Status: active"; seq 1 200000 | sed 's/^/22\/tcp ALLOW IN Anywhere # /'; }
	t_eq "" "$(fw_kept_ports)" "включённый ufw — порты не открываем"
}
test_no_ufw_status_pipelines() {  # «ufw status | grep» под pipefail путает «включён» с «выключен» — только через переменную
	! grep -nE '^[^#]*ufw status[^|#]*\| *grep' "$ROOT/src/install-vpn.sh.in" || t_fail "остался конвейер ufw status | grep"
}
test_inbound_ports_no_db() {
	xui_fns
	declare -F xui_inbound_ports > /dev/null || t_fail "нет xui_inbound_ports в шаблоне"
	t_eq "" "$(xui_inbound_ports)" "без базы — ничего"
}
test_fw_kept_ports_only_when_ufw_was_off() {  # фаервол уже включён — его правила остаются как есть, лишнего не открываем
	xui_fns
	mkdb '8443||vmess|{}|{"network":"ws"}|1'
	ufw() { echo "Status: inactive"; }
	t_eq "8443/tcp" "$(fw_kept_ports)" "ufw выключен — порты подключений остаются открытыми"
	ufw() { printf 'Status: active\n\nTo Action From\n'; }
	t_eq "" "$(fw_kept_ports)" "ufw включён — не трогаем"
	grep -q 'OTHER_VPN_PORTS \$KEEP' "$ROOT/src/install-vpn.sh.in" || t_fail "шаг фаервола не открывает порты подключений панели"
}

# ——— ревью 12.11: ядро установщика ———
# Роутер (install-passwall2.sh): всё, что меняет систему, проверяется на настоящем OpenWrt (test/passwall2.container.sh);
# здесь — только функции, которые ничего не трогают. pw_sh ОБОЛОЧКА 'команды' — выполнить их после определений скрипта.
pw_sh() {
	local sh=$1
	shift
	# shellcheck disable=SC2086  # «busybox ash» — два слова
	$sh -c "$(sed -n '/^main() {/q; p' "$ROOT/install-passwall2.sh")
$*"
}
test_passwall_tmp_room_is_free_memory() {  # /tmp роутера — в памяти: df показывает потолок tmpfs, а не свободную память
	local sh df_mb
	printf 'MemTotal:  250000 kB\nMemFree:  9000 kB\nMemAvailable:    40960 kB\n' > "$WORK/low"
	printf 'MemTotal:  250000 kB\nMemAvailable: 999999999999 kB\n' > "$WORK/high"
	printf 'MemTotal:  250000 kB\nMemFree:  9000 kB\n' > "$WORK/old-kernel"
	for sh in dash "busybox ash"; do
		df_mb=$(pw_sh "$sh" 'mb_free /tmp')
		[ "$df_mb" -gt 40 ] || t_fail "$sh: в /tmp этой машины меньше 40 МБ — тест не о том"
		t_eq 40 "$(pw_sh "$sh" "tmp_free '$WORK/low'")" "$sh: свободной памяти меньше, чем показывает df, — считаем по памяти"
		t_eq "$df_mb" "$(pw_sh "$sh" "tmp_free '$WORK/high'")" "$sh: памяти больше, чем места в /tmp, — считаем по df"
		t_eq "$df_mb" "$(pw_sh "$sh" "tmp_free '$WORK/old-kernel'")" "$sh: в meminfo нет MemAvailable — как раньше, по df"
		t_eq "$df_mb" "$(pw_sh "$sh" "tmp_free '$WORK/нет-такого'")" "$sh: meminfo не прочитать — как раньше, по df"
	done
}

# Основной скрипт: функции берутся из шаблона по именам (как в xui_fns), ufw и прочее — заглушки.
test_inbound_ports_odd_row_keeps_the_rest() {  # settings или stream_settings — не объект (null, [], строка): разбор падал, и список портов молча пустел
	xui_fns
	mkdb '2083||vless|{}|{"network":"xhttp","security":"reality"}|1' \
		'8443||vmess|null|null|1' \
		'8444||trojan|[]|[]|1' \
		'8445||vless|"x"|"y"|1' \
		'8446||vless|{}|{"network":"ws","tlsSettings":"не объект"}|1' \
		'8447||shadowsocks|[1]|{}|1' \
		'8448||vless|{}|{"network":"xhttp","tlsSettings":{"alpn":"h3"}}|1' \
		'8449||vless|{не json|{и это тоже|1' \
		'51820||wireguard|null|null|1'
	t_eq "2083/tcp 8443/tcp 8444/tcp 8445/tcp 8446/tcp 8447/tcp 8448/tcp 8448/udp 8449/tcp 51820/udp" \
		"$(xui_inbound_ports | tr '\n' ' ' | sed 's/ $//')" "порты: странные строки не теряются и не роняют остальные"
}

# Шаг «Фаервол ufw» целиком: ufw — заглушка (ответ на status — $UFW_SAYS, код — $UFW_STATUS_RC; команды из $UFW_FAIL
# не проходят), всё, что скрипт у неё просит, — построчно в $WORK/ufw.calls; правила ufw — файл $UFW_RULES.
fw_env() {
	eval "$(awk '/^(fw_step|fw_kept_ports|fw_close|xui_inbound_ports|ufw_active|ufw_state|ufw_allows_tcp)\(\) \{/,/^}/' "$ROOT/src/install-vpn.sh.in")"
	say() { :; }
	ok() { echo "OK $*" >> "$WORK/out"; }
	warn() { echo "WARN $*" >> "$WORK/out"; }
	bad() { echo "BAD $*" >> "$WORK/out"; }
	die() { echo "DIE $*" >> "$WORK/out"; exit 1; }
	ufw() {
		local f
		if [ "$1" = status ]; then
			[ -z "$UFW_STATUS_RC" ] || return "$UFW_STATUS_RC"
			printf '%s\n' "$UFW_SAYS"
			return 0
		fi
		echo "$*" >> "$WORK/ufw.calls"
		while IFS= read -r f; do [ "$f" != "$*" ] || return 1; done <<< "$UFW_FAIL"
		[ "$*" != "--force enable" ] || UFW_SAYS="Status: active"
	}
	ss() { cat "$WORK/ss.out" 2> /dev/null || true; }
	port_users() { :; }
	DB=$WORK/x-ui.db STATE=$WORK/vpn-install.env UFW_RULES=$WORK/user.rules
	MODE=nodomain PANEL_PUBLIC=0 SUB_TLS=0 SUB_PORT=2096 WEB_PORT=54321 REALITY_PORT=2083 SSH_PORTS=22
	OTHER_VPN='' OTHER_VPN_PORTS='' MOVED_FROM='' FAILS=0
	UFW_SAYS="Status: inactive" UFW_STATUS_RC='' UFW_FAIL=''
	unset SSH_CONNECTION   # тесты идут и по SSH: порты SSH шагу задаёт только $SSH_PORTS
	: > "$WORK/out"; : > "$WORK/ufw.calls"; : > "$UFW_RULES"; rm -f "$DB"
}
fw_called() { grep -qxF -- "$1" "$WORK/ufw.calls"; }
ufw_speaks_russian() {  # настоящий ufw (Python, gettext) берёт язык из первой непустой: LANGUAGE, LC_ALL, LC_MESSAGES, LANG —
	# то есть с LANGUAGE=ru отвечает по-русски даже при LC_ALL=C (проверено на ufw 0.36.1 с language-pack-ru)
	local l=${LANGUAGE:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}
	[[ $l == ru* ]]
}
fw_calls() { tr '\n' ';' < "$WORK/ufw.calls"; }
ACTIVE=$'Status: active\n\nTo                         Action      From\n--                         ------      ----\n22/tcp                     ALLOW       Anywhere'

test_fw_never_closes_port_of_enabled_inbound() {  # пункт 3: ufw уже включён — правила портов, на которых работают подключения панели, не удаляются
	local p
	fw_env; UFW_SAYS=$ACTIVE MOVED_FROM=443
	mkdb '2083||vless|{}|{"network":"xhttp","security":"reality"}|1' \
		'80||vless|{}|{"network":"ws"}|1' '2096|0.0.0.0|vmess|{}|{}|1' '54321||trojan|{}|{}|1' '443|203.0.113.7|vless|{}|{}|1'
	fw_step
	for p in 80 2096 54321 443; do
		! grep -q "^delete allow $p/" "$WORK/ufw.calls" || t_fail "закрыт порт $p, на котором работает подключение панели: $(fw_calls)"
		! fw_called "allow $p/tcp" || t_fail "ufw уже включён, а скрипт сам открыл порт чужого подключения $p: $(fw_calls)"
	done
	! grep -q 'старый порт подключения 443 закрыт' "$WORK/out" || t_fail "сказано, что порт 443 закрыт: $(cat "$WORK/out")"
	fw_called "allow 2083/tcp" || t_fail "свой порт не открыт: $(fw_calls)"
}
test_fw_closes_ports_nobody_uses() {  # обратная сторона: порт без включённого подключения, слушающего снаружи, закрывается как раньше
	fw_env; UFW_SAYS=$ACTIVE MOVED_FROM=443
	mkdb '2083||vless|{}|{"network":"xhttp","security":"reality"}|1' \
		'80||vless|{}|{"network":"ws"}|0' '2096|127.0.0.1|vmess|{}|{}|1' '1443||vless|{}|{}|1' '8080||vless|{}|{}|1'
	fw_step
	fw_called "delete allow 80/tcp" || t_fail "выключенное подключение на 80 — порт не закрыт: $(fw_calls)"
	fw_called "delete allow 2096/tcp" || t_fail "подключение только на 127.0.0.1:2096 — порт не закрыт: $(fw_calls)"
	fw_called "delete allow 54321/tcp" || t_fail "порт панели (--panel-local) не закрыт: $(fw_calls)"
	fw_called "delete allow 443/tcp" || t_fail "старый порт подключения 443 не закрыт (на 1443 — другое подключение): $(fw_calls)"
	t_has "старый порт подключения 443 закрыт" "$(cat "$WORK/out")" "сообщение"
}
test_fw_off_keeps_inbound_ports_and_enables() {  # ufw был выключен: порты подключений панели разрешаются до включения
	fw_env
	mkdb '2083||vless|{}|{"network":"xhttp","security":"reality"}|1' '8443||vmess|{}|{"network":"ws"}|1' '80||vless|{}|{}|1'
	fw_step
	t_eq "allow 22/tcp;allow 80/tcp;allow 2083/tcp;allow 8443/tcp;delete allow 2096/tcp;delete allow 54321/tcp;--force enable;" "$(fw_calls)" "что попросили у ufw"
	t_has "доступны, как раньше: 80/tcp 8443/tcp" "$(cat "$WORK/out")" "сказано про порты подключений"
	t_has "OK включён, открыто: 22/tcp 80/tcp 2083/tcp 8443/tcp" "$(cat "$WORK/out")" "итог"
}

test_ufw_state_needs_a_clear_answer() {  # пункт 5: «выключен» — только когда ufw так и сказал; молчание и чужой язык — «не понять»
	fw_env
	t_eq inactive "$(ufw_state)" "Status: inactive"
	UFW_SAYS=$ACTIVE; t_eq active "$(ufw_state)" "Status: active"
	UFW_SAYS=$'Состояние: активен\n\nВ                          Действие    Из'; t_eq unknown "$(ufw_state)" "ответ не на английском"
	UFW_SAYS=''; t_eq unknown "$(ufw_state)" "пустой ответ"
	UFW_SAYS="ERROR: Couldn't determine iptables version" UFW_STATUS_RC=1; t_eq unknown "$(ufw_state)" "ufw status не выполнился"
	ufw() { if ufw_speaks_russian; then echo "Состояние: активен"; else echo "Status: active"; fi; }
	t_eq active "$(LANGUAGE=ru LC_ALL=C ufw_state)" "LANGUAGE=ru в окружении — ответ всё равно читается"
}
test_fw_unknown_state_opens_no_extra_and_closes_nothing() {  # пункт 5: состояние ufw не понять — ни чужих портов, ни удалений, ни включения
	local says
	for says in "RC" $'Состояние: активен\n\nВ   Действие   Из'; do
		fw_env; MOVED_FROM=443
		if [ "$says" = RC ]; then UFW_STATUS_RC=1; else UFW_SAYS=$says; fi
		mkdb '2083||vless|{}|{"network":"xhttp","security":"reality"}|1' '8443||vmess|{}|{"network":"ws"}|1'
		fw_step
		! fw_called "allow 8443/tcp" || t_fail "открыт порт чужого подключения при непонятном состоянии ufw: $(fw_calls)"
		! grep -q '^delete ' "$WORK/ufw.calls" || t_fail "удалено правило при непонятном состоянии ufw: $(fw_calls)"
		! fw_called "--force enable" || t_fail "ufw включён при непонятном состоянии: $(fw_calls)"
		fw_called "allow 2083/tcp" && fw_called "allow 22/tcp" || t_fail "нужные порты не разрешены: $(fw_calls)"
		grep -q '^BAD .*понять не удалось' "$WORK/out" || t_fail "не сказано, что состояние ufw непонятно: $(cat "$WORK/out")"
		! grep -q 'включён, открыто' "$WORK/out" || t_fail "сказано «включён»: $(cat "$WORK/out")"
	done
}
test_fw_inbound_allow_failure_leaves_ufw_off() {  # пункт 3 («ни иначе»): порт чужого подключения не разрешился — включение ufw его закрыло бы
	fw_env; UFW_FAIL="allow 8443/tcp"
	mkdb '2083||vless|{}|{"network":"xhttp","security":"reality"}|1' '8443||vmess|{}|{"network":"ws"}|1'
	fw_step
	! fw_called "--force enable" || t_fail "ufw включён, хотя порт подключения панели в нём не разрешён: $(fw_calls)"
	grep -q '^BAD ufw не включал.*8443' "$WORK/out" || t_fail "не сказано, почему ufw не включён: $(cat "$WORK/out")"
	! grep -q 'доступны, как раньше.*8443' "$WORK/out" || t_fail "порт 8443 назван доступным: $(cat "$WORK/out")"
}

test_language_env_is_dropped_at_start() {  # пункт 5: LANGUAGE из окружения (sudo её сохраняет) переводит ответы ufw — в начале скрипта она снимается
	local pre
	pre=$(sed -n '/^set -euo pipefail$/,/^XUI_VERSION=/p' "$ROOT/src/install-vpn.sh.in" | sed '$d')
	t_eq "unset C.UTF-8" "$(LANGUAGE=ru:en bash -c "$pre"$'\necho "${LANGUAGE-unset} $LC_ALL"')" "LANGUAGE и LC_ALL после начала скрипта"
}
# Кусок скрипта выхода про фаервол (в шаблоне — от «# Фаервол:» до ключа бота) — как он исполняется на старом сервере:
# set -eu, ufw и iptables — заглушки (iptables отвечает «всё разрешено», его ветка не исполняется; путь /etc/iptables
# на всякий случай уведён в $WORK). exit_fw 'ответ ufw status' [код] → что напечатал кусок; просьбы к ufw — в $WORK/ufw.calls.
exit_fw() {
	sed -n '/^# Фаервол: /,/^# >>> vpn-bot key/p' "$ROOT/src/install-vpn.sh.in" | sed "s#/etc/iptables#$WORK/etc-iptables#g" > "$WORK/exit-fw.sh"
	grep -q 'EXIT_UFW=' "$WORK/exit-fw.sh" || t_fail "кусок про фаервол в скрипте выхода не найден"
	: > "$WORK/ufw.calls"
	(
		set -eu
		trap 'echo "ERR в строке $LINENO"' ERR
		ufw() {
			if [ "$1" = status ]; then
				! ufw_speaks_russian || { echo "Состояние: активен"; return 0; }
				printf '%s\n' "$UFW_SAYS"
				return "${UFW_STATUS_RC:-0}"
			fi
			echo "$*" >> "$WORK/ufw.calls"
		}
		iptables() { echo "-P INPUT ACCEPT"; }
		netfilter-persistent() { echo "netfilter-persistent $*" >> "$WORK/ufw.calls"; }
		iptables-save() { echo "iptables-save" >> "$WORK/ufw.calls"; }
		ENTRY_IP=203.0.113.10 EXIT_PORT=2087 UFW_SAYS=$1 UFW_STATUS_RC=${2:-0}
		# shellcheck source=/dev/null
		. "$WORK/exit-fw.sh"
	)
}
test_exit_fw_follows_what_ufw_says() {  # пункт 5: на старом сервере «выключен» — только со слов ufw; не ответил — «не понять», а не «открыт всем»
	local allow="allow from 203.0.113.10 to any port 2087 proto tcp"
	t_eq "EXIT_UFW=restricted" "$(exit_fw "$ACTIVE")" "ufw включён"
	t_eq "$allow" "$(cat "$WORK/ufw.calls")" "новому серверу порт открыт"
	t_eq "EXIT_UFW=open" "$(exit_fw "Status: inactive")" "ufw выключен"
	t_eq "" "$(cat "$WORK/ufw.calls")" "выключенный ufw не трогаем"
	t_eq "EXIT_UFW=unknown" "$(exit_fw "ERROR: Couldn't determine iptables version" 1)" "ufw status не выполнился"
	t_eq "$allow" "$(cat "$WORK/ufw.calls")" "правило новому серверу добавлено и при непонятном состоянии (ufw не включаем)"
	t_eq "EXIT_UFW=unknown" "$(exit_fw "")" "пустой ответ"
	t_eq "EXIT_UFW=restricted" "$(LANGUAGE=ru exit_fw "$ACTIVE")" "LANGUAGE=ru в окружении — ответ всё равно читается"
	sed -n '/^emit_exit_setup() {/,/^VPN_EXIT_SETUP$/p' "$ROOT/src/install-vpn.sh.in" | sed -n '/^set -eu$/,/apt-get/p' | grep -q '^unset LANGUAGE\( \|$\)' ||
		t_fail "скрипт выхода не снимает LANGUAGE в самом начале"
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

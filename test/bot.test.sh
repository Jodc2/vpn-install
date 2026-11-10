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

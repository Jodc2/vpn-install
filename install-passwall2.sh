#!/bin/sh
# shellcheck shell=dash
# install-passwall2.sh — ставит PassWall2 на роутер с OpenWrt 22.03+ (firewall4): последний выпуск с GitHub,
# ядро Xray (нужно для VLESS + XHTTP + Reality), русский перевод, dnsmasq-full. Подписку и настройки не трогает:
# после установки PassWall2 выключен, интернет работает как раньше.
#
# Запуск с компьютера, когда файл лежит в текущей папке (пароль root роутера спросит ssh):
#   Mac, Linux:            ssh root@192.168.1.1 sh < install-passwall2.sh
#   Windows (cmd):         type install-passwall2.sh | ssh root@192.168.1.1 sh
# Или на самом роутере:    sh install-passwall2.sh
# Повторный запуск обновляет PassWall2 до свежего выпуска.

REPO=Openwrt-Passwall/openwrt-passwall2
API=https://api.github.com/repos/$REPO/releases/latest
NEED="xray-core chinadns-ng geoview tcping v2ray-geoip v2ray-geosite"   # из архива выпуска: ядро и его спутники
KMODS="kmod-nft-socket kmod-nft-tproxy kmod-nft-nat"                    # прозрачный прокси на nftables
MIN_RAM_MB=${PW_MIN_RAM_MB:-200}     # роутер на 256 МБ показывает ~240
MIN_ROOT_MB=${PW_MIN_ROOT_MB:-50}    # xray-core, гео-базы и PassWall2 занимают ~40 МБ
LOG=/tmp/passwall2-install.log
W=/tmp/passwall2-install

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok() { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mВНИМ.\033[0m %s\n' "$*"; }
die() {
	printf '\n\033[31mОстановлено:\033[0m %s\n' "$*" >&2
	if [ -s "$LOG" ]; then
		printf 'Последние строки журнала (весь — %s):\n' "$LOG" >&2
		tail -n 12 "$LOG" >&2
	fi
	exit 1
}
run() { echo "+ $*" >> "$LOG"; "$@" >> "$LOG" 2>&1; }   # команда; её вывод — в журнал
# Скачать: curl, если есть. Встроенный wget OpenWrt (uclient-fetch) не скачивает выпуски GitHub (перенаправление
# на objects.githubusercontent.com обрывается «Connection timed out»), а API GitHub отдаёт — им проверяем выпуск
# до любых изменений, а файлы качаем curl, который ставится первым из официальных пакетов.
fetch() {  # fetch ФАЙЛ АДРЕС
	if command -v curl > /dev/null 2>&1; then
		run curl -fsSL --retry 3 --connect-timeout 20 -o "$1" "$2"
	else
		run wget -q -O "$1" "$2"
	fi
}
mb_free() { df -k "$1" 2> /dev/null | tail -n 1 | awk '{print int($(NF-2) / 1024)}'; }   # свободно, МБ

# ——— менеджер пакетов: opkg (OpenWrt 24.10 и старше) или apk (25.x) ———
pm_update() { if [ "$PM" = apk ]; then run apk update; else run opkg update; fi; }
pm_add() { if [ "$PM" = apk ]; then run apk add "$@"; else run opkg install "$@"; fi; }
pm_add_files() { if [ "$PM" = apk ]; then run apk add --allow-untrusted "$@"; else run opkg install "$@"; fi; }
pm_has() {
	if [ "$PM" = apk ]; then apk info -e "$1" > /dev/null 2>&1; else opkg list-installed 2> /dev/null | grep -q "^$1 - "; fi
}
pm_ver() {
	if [ "$PM" = apk ]; then
		apk list --installed "$1" 2> /dev/null | awk -v p="$1-" 'index($1, p) == 1 {print substr($1, length(p) + 1); exit}'
	else
		opkg list-installed "$1" 2> /dev/null | awk '{print $3; exit}'
	fi
}

asset() {  # asset РЕГУЛЯРКА → ссылка на файл выпуска
	jsonfilter -i "$W/release.json" -e '@.assets[*].browser_download_url' 2> /dev/null | grep -E "$1" | head -n 1
}

swap_dnsmasq() {  # dnsmasq → dnsmasq-full (без него PassWall2 не разводит трафик по доменам); при сбое — откат
	if pm_has dnsmasq-full; then
		ok "dnsmasq-full уже стоит"
		return 0
	fi
	cp -p /etc/config/dhcp "$W/dhcp.before" 2> /dev/null || true
	if [ "$PM" = apk ]; then
		pm_add dnsmasq-full || die "не встал dnsmasq-full (apk) — обычный dnsmasq остался, ничего не сломано"
	else
		# opkg не заменяет пакет сам: зависимости и оба пакета — заранее, пока DNS работает; замена — из файлов.
		deps=$(opkg info dnsmasq-full 2> /dev/null | sed -n 's/^Depends: //p' | head -n 1 | tr ',' '\n' |
			sed 's/[[:space:]]//g; s/(.*//' | grep -vE '^(libc|libubus.*|)$' | tr '\n' ' ')
		# shellcheck disable=SC2086  # список пакетов — по словам
		[ -z "$deps" ] || pm_add $deps || die "не встали зависимости dnsmasq-full ($deps) — ничего не изменено"
		(cd "$W" && run opkg download dnsmasq-full && run opkg download dnsmasq) ||
			die "не скачались dnsmasq-full и dnsmasq — ничего не изменено"
		run opkg remove dnsmasq || die "обычный dnsmasq не удаляется (от него зависят другие пакеты) — ничего не изменено"
		if ! run opkg install "$W"/dnsmasq-full_*.ipk; then
			run opkg install "$W"/dnsmasq_*.ipk
			[ ! -f "$W/dhcp.before" ] || cp -p "$W/dhcp.before" /etc/config/dhcp
			run /etc/init.d/dnsmasq enable
			run /etc/init.d/dnsmasq restart
			die "dnsmasq-full не встал — вернул обычный dnsmasq с прежними настройками"
		fi
	fi
	# Настройки DHCP и DNS — прежние: новый пакет кладёт свой файл рядом (dhcp-opkg / dhcp.apk-new).
	rm -f /etc/config/dhcp-opkg /etc/config/dhcp.apk-new
	if [ -f "$W/dhcp.before" ] && ! cmp -s "$W/dhcp.before" /etc/config/dhcp; then cp -p "$W/dhcp.before" /etc/config/dhcp; fi
	run /etc/init.d/dnsmasq enable || true
	run /etc/init.d/dnsmasq restart || warn "dnsmasq не перезапустился — перезагрузите роутер после установки"
	ok "dnsmasq заменён на dnsmasq-full (настройки DHCP и DNS прежние)"
}

main() {
	: > "$LOG"
	trap 'rm -rf "$W"' EXIT
	rm -rf "$W"
	mkdir -p "$W"

	say "Проверка роутера"
	[ -f /etc/openwrt_release ] || die "это не OpenWrt (нет /etc/openwrt_release) — скрипт для роутера с прошивкой OpenWrt"
	# shellcheck source=/dev/null
	. /etc/openwrt_release
	ARCH=$DISTRIB_ARCH
	ok "${DISTRIB_DESCRIPTION:-OpenWrt $DISTRIB_RELEASE}, архитектура $ARCH"
	[ -x /sbin/fw4 ] || die "нужен OpenWrt 22.03 или новее (с firewall4), а здесь ${DISTRIB_RELEASE:-старая версия} — обновите прошивку"
	if command -v apk > /dev/null 2>&1; then PM=apk EXT=apk; elif command -v opkg > /dev/null 2>&1; then PM=opkg EXT=ipk; else die "нет ни opkg, ни apk"; fi
	ram=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
	[ "$ram" -ge "$MIN_RAM_MB" ] || die "у роутера $ram МБ памяти, а Xray нужно от 256 МБ — на этой модели PassWall2 работать не будет"
	root=$(mb_free /)
	[ "$root" -ge "$MIN_ROOT_MB" ] || die "свободно $root МБ во флеш-памяти, а нужно ~$MIN_ROOT_MB МБ (Xray, гео-базы, PassWall2)"
	ok "память $ram МБ, свободно $root МБ, пакеты — $PM"

	say "Выпуск PassWall2 на GitHub"
	fetch "$W/release.json" "$API" || die "GitHub не отвечает (нет интернета на роутере или github.com недоступен) — ничего не изменено"
	tag=$(jsonfilter -i "$W/release.json" -e '@.tag_name' 2> /dev/null)
	[ -n "$tag" ] || die "GitHub ответил непонятно (лимит запросов?) — запустите через час, ничего не изменено"
	if [ "$PM" = apk ]; then
		u_app=$(asset '/luci-app-passwall2-[^/]*\.apk$')
		u_ru=$(asset '/luci-i18n-passwall2-ru-[^/]*\.apk$')
	else
		u_app=$(asset '/luci-app-passwall2_[^/]*_all\.ipk$')
		u_ru=$(asset '/luci-i18n-passwall2-ru_[^/]*_all\.ipk$')
	fi
	zip_name=packages_${EXT}_$ARCH.zip
	u_zip=$(asset "/$zip_name\$")
	[ -n "$u_app" ] && [ -n "$u_zip" ] || die "в выпуске $tag нет пакетов для архитектуры $ARCH ($EXT) — для этой модели PassWall2 не собран"
	zip_mb=$(jsonfilter -i "$W/release.json" -e "@.assets[@.name='$zip_name'].size" 2> /dev/null | awk '{print int($1 / 1048576) + 1}')
	tmp=$(mb_free /tmp)
	[ "$tmp" -ge $((${zip_mb:-60} + 30)) ] || die "для загрузки нужно ~$((${zip_mb:-60} + 30)) МБ памяти в /tmp, свободно $tmp — перезагрузите роутер и запустите снова"
	have=$(pm_ver luci-app-passwall2)
	ok "PassWall2 $tag${have:+ (сейчас стоит $have)}"

	say "Пакеты OpenWrt"
	pm_update || die "не обновился список пакетов ($PM update) — нет интернета на роутере? Ничего не изменено"
	for p in curl unzip; do pm_has "$p" || pm_add "$p" || die "не встал $p — ничего не изменено"; done
	ok "списки пакетов обновлены"

	say "Загрузка PassWall2 $tag (~$((${zip_mb:-55} + 1)) МБ)"
	fetch "$W/app.$EXT" "$u_app" || die "не скачался PassWall2 — ничего не изменено"
	if [ -n "$u_ru" ]; then fetch "$W/ru.$EXT" "$u_ru" || warn "не скачался русский перевод — интерфейс будет на английском"; fi
	fetch "$W/pkgs.zip" "$u_zip" || die "не скачался архив пакетов $zip_name — ничего не изменено"
	mkdir -p "$W/p"
	for p in $NEED; do
		if [ "$PM" = apk ]; then pat="$p-[0-9]*.apk"; else pat="${p}_*.$EXT"; fi
		run unzip -o -j "$W/pkgs.zip" "$pat" -d "$W/p" || die "в архиве $zip_name нет пакета $p — ничего не изменено"
	done
	rm -f "$W/pkgs.zip"   # 50+ МБ в памяти больше не нужны
	ok "скачано: PassWall2, $(echo "$NEED" | tr ' ' ',' | sed 's/,/, /g')"

	say "Установка"
	# shellcheck disable=SC2086  # список пакетов — по словам
	pm_add $KMODS || die "не встали модули ядра ($KMODS) — прошивка не из официальных сборок OpenWrt? Сверьте версию"
	ok "модули ядра для прозрачного прокси"
	swap_dnsmasq
	pm_has luci-base || { pm_add luci && ok "поставил веб-интерфейс LuCI (его не было)"; } || die "не встал веб-интерфейс LuCI"
	pm_add_files "$W"/p/* || die "не встали Xray и его пакеты"
	ok "Xray $(xray version 2> /dev/null | awk 'NR == 1 {print $2}')"
	if [ -s "$W/ru.$EXT" ]; then
		pm_add_files "$W/app.$EXT" "$W/ru.$EXT" || die "не встал PassWall2"
	else
		pm_add_files "$W/app.$EXT" || die "не встал PassWall2"
	fi
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
	run /etc/init.d/rpcd restart || true
	ok "PassWall2 $(pm_ver luci-app-passwall2)"
	if [ "$(uci -q get passwall2.@global[0].enabled 2> /dev/null)" = 1 ]; then
		warn "PassWall2 включён (настроен раньше) — его настройки и подписки не трогал"
	else
		ok "PassWall2 пока выключен — интернет работает как раньше"
	fi

	ip=$(uci -q get network.lan.ipaddr 2> /dev/null | cut -d/ -f1)
	cat << EOF

Готово. Дальше — в браузере: http://${ip:-192.168.1.1} → «Службы» → «PassWall2»
  1. «Подписки» → «Добавить» → вставить ссылку на подписку в «URL подписки» → «Сохранить»
     → «Ручное обновление подписки» (в «Списке узлов» появится сервер).
  2. «Общие параметры» → «Включить модуль», в «Узел» выбрать сервер → «Сохранить и применить».
  3. Проверка: с телефона в Wi-Fi роутера открыть ifconfig.me — должен быть IP VPN, не домашний.
EOF
}

main "$@" < /dev/null
exit $?

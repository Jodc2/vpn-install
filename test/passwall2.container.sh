#!/bin/bash
# Проверка install-passwall2.sh на настоящем OpenWrt в контейнерах: 24.10 (opkg) и 25.12 (apk), x86_64.
# Нужны docker и интернет (GitHub, ленты OpenWrt). Запуск: bash test/passwall2.container.sh [24.10.8 25.12.6]
# Модули ядра в контейнере не грузятся и procd нет — проверяются установка, замена dnsmasq и итог, не сам прокси.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$(dirname "$HERE")/install-passwall2.sh
VERS=${*:-24.10.8 25.12.6}
fails=0
for v in $VERS; do
	echo "=== OpenWrt $v"
	docker run --rm --name "pw-test-${v//./-}" --memory 768m -v "$SCRIPT:/work/install-passwall2.sh:ro" \
		"openwrt/rootfs:x86-64-$v" /bin/sh -c '
		mkdir -p /var/lock /var/run   # на роутере их создаёт загрузка, в контейнере procd нет
		if command -v apk > /dev/null; then
			has() { apk info -e "$1" > /dev/null 2>&1; }
			plain_dnsmasq() { apk list --installed 2> /dev/null | grep -q "^dnsmasq-[0-9]"; }
		else
			has() { opkg list-installed | grep -q "^$1 - "; }
			plain_dnsmasq() { opkg list-installed | grep -q "^dnsmasq - "; }
		fi
		chk() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; BAD=1; fi; }
		BAD=0
		uci set dhcp.@dnsmasq[0].testmarker=keep && uci commit dhcp
		echo "--- отказ: мало места во флеш-памяти"
		PW_MIN_ROOT_MB=999999 sh /work/install-passwall2.sh > /tmp/o1.txt 2>&1; rc=$?
		chk "код 1 и понятная причина" "[ $rc = 1 ] && grep -q \"во флеш-памяти\" /tmp/o1.txt"
		chk "ничего не установлено" "! has luci-app-passwall2 && plain_dnsmasq"
		if ! command -v apk > /dev/null; then
			echo "--- откат: dnsmasq-full не встаёт (opkg)"
			mkdir -p /tmp/fake && cat > /tmp/fake/opkg << "W"
#!/bin/sh
case "$*" in install*dnsmasq-full_*) echo "имитация сбоя установки dnsmasq-full" >&2; exit 1 ;; esac
exec /bin/opkg "$@"
W
			chmod +x /tmp/fake/opkg
			PATH=/tmp/fake:$PATH sh /work/install-passwall2.sh > /tmp/o0.txt 2>&1; rc=$?
			chk "код 1 и «вернул обычный dnsmasq»" "[ $rc = 1 ] && grep -q \"вернул обычный dnsmasq\" /tmp/o0.txt"
			chk "обычный dnsmasq снова стоит, dnsmasq-full нет" "plain_dnsmasq && ! has dnsmasq-full"
			chk "настройки DHCP на месте после отката" "[ \"\$(uci -q get dhcp.@dnsmasq[0].testmarker)\" = keep ]"
			rm -rf /tmp/fake
		fi
		echo "--- установка через stdin (как ssh root@роутер sh < файл)"
		sh < /work/install-passwall2.sh > /tmp/o2.txt 2>&1; rc=$?
		sed "s/\x1b\[[0-9;]*m//g" /tmp/o2.txt | grep -E "OK|ВНИМ|Останов|Готово" | sed "s/^/    /"
		chk "код 0" "[ $rc = 0 ]"
		chk "PassWall2 и русский перевод" "has luci-app-passwall2 && has luci-i18n-passwall2-ru"
		chk "Xray установлен и запускается" "has xray-core && xray version > /dev/null 2>&1"
		chk "гео-базы, geoview, tcping, chinadns-ng" "has v2ray-geoip && has v2ray-geosite && has geoview && has tcping && has chinadns-ng"
		chk "модули ядра nftables" "has kmod-nft-socket && has kmod-nft-tproxy && has kmod-nft-nat"
		chk "dnsmasq-full вместо dnsmasq" "has dnsmasq-full && ! plain_dnsmasq"
		chk "настройки DHCP пережили замену" "[ \"\$(uci -q get dhcp.@dnsmasq[0].testmarker)\" = keep ] && [ ! -e /etc/config/dhcp-opkg ] && [ ! -e /etc/config/dhcp.apk-new ]"
		chk "PassWall2 выключен" "[ \"\$(uci -q get passwall2.@global[0].enabled)\" != 1 ]"
		chk "временные файлы убраны" "[ ! -e /tmp/passwall2-install ]"
		echo "--- повторный запуск"
		sh /work/install-passwall2.sh > /tmp/o3.txt 2>&1; rc=$?
		chk "повтор — код 0" "[ $rc = 0 ]"
		exit $BAD' || fails=$((fails + 1))
done
echo "# версий с ошибками: $fails"
[ "$fails" = 0 ]

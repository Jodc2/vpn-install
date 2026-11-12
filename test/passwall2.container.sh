#!/bin/bash
# Проверка install-passwall2.sh на настоящем OpenWrt в контейнерах: 24.10 (opkg) и 25.12 (apk), x86_64. Каждая версия —
# дважды: роутер с обычным dnsmasq и роутер с dnsmasq-dhcpv6 (PW_VARIANTS="dnsmasq" — только первый).
# Нужны docker и интернет (GitHub, ленты OpenWrt). Запуск: bash test/passwall2.container.sh [24.10.8 25.12.6]
# Модули ядра в контейнере не грузятся и procd нет — проверяются установка, замена dnsmasq (и её сбои: пакеты
# не скачались, откат, двойной сбой, сигналы посреди замены, opkg с неверным кодом возврата) и итог, не сам прокси.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$(dirname "$HERE")/install-passwall2.sh
VERS=${*:-24.10.8 25.12.6}
fails=0
for v in $VERS; do
	for q in ${PW_VARIANTS:-dnsmasq dnsmasq-dhcpv6}; do
		echo "=== OpenWrt $v, на роутере $q"
		docker run --rm --name "pw-test-${v//./-}" --memory 768m -e Q="$q" -v "$SCRIPT:/work/install-passwall2.sh:ro" \
			"openwrt/rootfs:x86-64-$v" /bin/sh -c '
		mkdir -p /var/lock /var/run   # на роутере их создаёт загрузка, в контейнере procd нет
		# Q — вариант dnsmasq на «роутере» до установки; exact ПАКЕТ — стоит именно он (у apk «info -e dnsmasq» верен для любого).
		if command -v apk > /dev/null; then
			has() { apk info -e "$1" > /dev/null 2>&1; }
			exact() { apk list --installed 2> /dev/null | grep -q "^$1-[0-9]"; }
			to_old() { apk del dnsmasq-full > /dev/null 2>&1; [ "$Q" = dnsmasq ] || apk add "$Q" > /dev/null 2>&1; }
			REINSTALL="apk add --allow-untrusted /tmp/passwall2-install/$Q-[0-9]*.apk"
		else
			has() { opkg list-installed | grep -q "^$1 - "; }
			exact() { opkg list-installed | grep -q "^$1 - "; }
			to_old() { opkg remove dnsmasq-full dnsmasq > /dev/null 2>&1; opkg install "$Q" > /dev/null 2>&1; }
			REINSTALL="opkg install /tmp/passwall2-install/${Q}_*.ipk"
		fi
		old_dq() { exact "$Q" && ! exact dnsmasq-full; }
		chk() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; BAD=1; fi; }
		BAD=0
		OLDNAME=$Q; [ "$Q" != dnsmasq ] || OLDNAME="обычный dnsmasq"
		if [ "$Q" != dnsmasq ]; then   # «роутер», на котором обычный dnsmasq уже заменён другим вариантом
			if command -v apk > /dev/null; then apk update > /dev/null 2>&1; else opkg update > /dev/null 2>&1; fi
			to_old
			chk "подготовка: на роутере $Q" "old_dq"
		fi
		uci set dhcp.@dnsmasq[0].testmarker=keep && uci commit dhcp
		echo "--- отказ: мало места во флеш-памяти"
		PW_MIN_ROOT_MB=999999 sh /work/install-passwall2.sh > /tmp/o1.txt 2>&1; rc=$?
		chk "код 1 и понятная причина" "[ $rc = 1 ] && grep -q \"во флеш-памяти\" /tmp/o1.txt"
		chk "ничего не установлено" "! has luci-app-passwall2 && old_dq"
		# Подмена менеджера пакетов, wget и curl: что ломать — в /tmp/fake/mode, остальное уходит настоящей программе.
		# «Сети нет» — имя сервера пакетов ведёт в никуда: на роутере без dnsmasq нет и DNS, докачать нечем.
		mkdir -p /tmp/fake
		net_on() { grep -v "^127.0.0.1 downloads.openwrt.org" /etc/hosts > /tmp/hosts.new; cat /tmp/hosts.new > /etc/hosts; }
		if command -v apk > /dev/null; then
			cat > /tmp/fake/apk << "W"
#!/bin/sh
mode=$(cat /tmp/fake/mode 2> /dev/null)
case "$mode:$*" in
	nofetch:add*dnsmasq-full)   # пакеты не скачиваются
		echo "127.0.0.1 downloads.openwrt.org" >> /etc/hosts ;;
	swapfail:add*dnsmasq-full | double:add*dnsmasq-full)   # прежний dnsmasq снят, dnsmasq-full не встал, сети больше нет
		echo "127.0.0.1 downloads.openwrt.org" >> /etc/hosts
		/usr/bin/apk add dnsmasq-full
		echo "имитация сбоя установки dnsmasq-full" >&2; exit 1 ;;
	double:"add --allow-untrusted "*/dnsmasq-* | double:"add dnsmasq"*) echo "имитация сбоя установки dnsmasq" >&2; exit 1 ;;
	signal:add*dnsmasq-full)   # посреди замены — HUP, INT и TERM скрипту и самому apk (обрыв SSH, Ctrl-C)
		kill -HUP "$PPID"; kill -INT "$PPID"; kill -TERM "$PPID"; kill -HUP $$; kill -INT $$; kill -TERM $$; sleep 1 ;;
	signal:"add --allow-untrusted "*/p/*) kill -TERM "$PPID"; sleep 1; exit 1 ;;   # замена позади: TERM снова должен останавливать
esac
exec /usr/bin/apk "$@"
W
		else
			cat > /tmp/fake/opkg << "W"
#!/bin/sh
mode=$(cat /tmp/fake/mode 2> /dev/null)
case "$mode:$*" in
	swapfail:install*dnsmasq-full_* | double:install*dnsmasq-full_*)   # прежний dnsmasq снят, dnsmasq-full не встал, сети больше нет
		echo "127.0.0.1 downloads.openwrt.org" >> /etc/hosts
		echo "имитация сбоя установки dnsmasq-full" >&2; exit 1 ;;
	double:install*/dnsmasq*) echo "имитация сбоя установки dnsmasq" >&2; exit 1 ;;
	rmfail:"remove dnsmasq"*) echo "имитация: пакет не снимается" >&2; exit 1 ;;
	rmrc:"remove dnsmasq"*)   # пакет снят, а код возврата — ошибка
		/bin/opkg "$@"
		echo "имитация: пакет снят, но opkg сообщает об ошибке" >&2; exit 1 ;;
	rmrc:install*/p/*) echo "стоп: дальше замены dnsmasq этот сценарий не идёт" >&2; exit 1 ;;
	signal:"remove dnsmasq"*)   # прежний dnsmasq снят — и тут HUP, INT и TERM (обрыв SSH, Ctrl-C)
		/bin/opkg "$@"; rc=$?
		kill -HUP "$PPID"; kill -INT "$PPID"; kill -TERM "$PPID"; kill -HUP $$; kill -INT $$; kill -TERM $$; sleep 1
		exit $rc ;;
	signal:install*/p/*) kill -TERM "$PPID"; sleep 1; exit 1 ;;   # замена позади: TERM снова должен останавливать
esac
exec /bin/opkg "$@"
W
		fi
		chmod +x /tmp/fake/*
		faulty() {  # faulty РЕЖИМ — запуск с подменой; вывод в /tmp/o-РЕЖИМ.txt
			if [ -e /tmp/fake/dl ] && [ ! -e /tmp/fake/curl ] && command -v curl > /dev/null; then cp /tmp/fake/dl /tmp/fake/curl; fi
			echo "$1" > /tmp/fake/mode
			PATH=/tmp/fake:$PATH sh /work/install-passwall2.sh > "/tmp/o-$1.txt" 2>&1; rc=$?
			rm -f /tmp/fake/mode
			return $rc
		}

		echo "--- GitHub ответил отказом (403, лимит запросов) и GitHub недоступен — разные слова"
		printf "#!/bin/sh\nexit \"\$(cat /tmp/fake/wget.rc)\"\n" > /tmp/fake/wget; chmod +x /tmp/fake/wget
		echo 8 > /tmp/fake/wget.rc   # uclient-fetch: 8 — сервер ответил ошибкой HTTP
		faulty http; rc=$?
		chk "отказ: код 1, сказано про лимит запросов, не про интернет" "[ $rc = 1 ] && grep -q \"лимит запросов\" /tmp/o-http.txt && ! grep -q \"нет интернета\" /tmp/o-http.txt"
		echo 4 > /tmp/fake/wget.rc   # uclient-fetch: 4 — соединиться не удалось
		faulty net; rc=$?
		chk "нет связи: код 1, сказано про интернет, не про лимит" "[ $rc = 1 ] && grep -q \"нет интернета\" /tmp/o-net.txt && ! grep -q \"лимит запросов\" /tmp/o-net.txt"
		rm -f /tmp/fake/wget /tmp/fake/wget.rc
		printf "#!/bin/sh\nexit 22\n" > /tmp/fake/curl; chmod +x /tmp/fake/curl   # curl -f: 22 — сервер ответил ошибкой HTTP
		faulty http2; rc=$?
		chk "отказ при скачивании через curl: тоже про лимит запросов" "[ $rc = 1 ] && grep -q \"лимит запросов\" /tmp/o-http2.txt && ! grep -q \"нет интернета\" /tmp/o-http2.txt"
		rm -f /tmp/fake/curl
		chk "ничего не установлено" "! has luci-app-passwall2 && old_dq"

		# Дальше сценарии со сбоями идут подряд, и каждый дошёл бы до GitHub: ответ API и файлы выпуска после первой загрузки
		# берутся из /tmp/dl-cache — иначе упрёмся в лимит запросов GitHub (60 в час) и каждый раз качаем архив заново.
		cat > /tmp/fake/dl << "W"
#!/bin/sh
me=${0##*/}; out=; url=; prev=
for a; do
	case $prev in -O | -o) out=$a ;; esac
	prev=$a; url=$a
done
PATH=${PATH#/tmp/fake:}
case $url in
	https://api.github.com/* | https://github.com/*/releases/download/*)
		key=/tmp/dl-cache/$(echo "$url" | md5sum | cut -c1-16)
		if [ -s "$key" ]; then cp "$key" "$out"; exit 0; fi
		"$me" "$@" || exit $?
		mkdir -p /tmp/dl-cache; cp "$out" "$key"; exit 0 ;;
esac
exec "$me" "$@"
W
		chmod +x /tmp/fake/dl; cp /tmp/fake/dl /tmp/fake/wget

		if command -v apk > /dev/null; then
			echo "--- пакеты dnsmasq-full не скачались (apk): замена не начинается"
			faulty nofetch; rc=$?; net_on
			chk "код 1 и «$OLDNAME на месте»" "[ $rc = 1 ] && grep -q \"$OLDNAME на месте\" /tmp/o-nofetch.txt"
			chk "$Q стоит, dnsmasq-full нет" "old_dq"
			chk "список пакетов системы (world) — как был" "grep -qx \"$Q\" /etc/apk/world && ! grep -q dnsmasq-full /etc/apk/world"
		fi

		echo "--- откат без сети: $Q снят, а dnsmasq-full не встаёт"
		faulty swapfail; rc=$?; net_on
		chk "код 1 и «вернул $OLDNAME»" "[ $rc = 1 ] && grep -q \"вернул $OLDNAME\" /tmp/o-swapfail.txt"
		chk "$Q снова стоит, dnsmasq-full нет" "old_dq"
		chk "настройки DHCP на месте после отката" "[ \"\$(uci -q get dhcp.@dnsmasq[0].testmarker)\" = keep ]"
		chk "временные файлы убраны" "[ ! -e /tmp/passwall2-install ]"

		echo "--- двойной сбой без сети: не встаёт ни dnsmasq-full, ни прежний $Q"
		faulty double; rc=$?
		chk "код 1, и не сказано «вернул»" "[ $rc = 1 ] && ! grep -q \"вернул $OLDNAME\" /tmp/o-double.txt"
		chk "сказано, что роутер без DHCP и DNS" "grep -q \"БЕЗ DHCP и DNS\" /tmp/o-double.txt"
		chk "скачанный $Q не удалён" "ls /tmp/passwall2-install/$Q[-_][0-9]* > /dev/null 2>&1"
		chk "команда восстановления названа" "grep -qF \"$REINSTALL\" /tmp/o-double.txt"
		chk "лишнее из памяти убрано (пакеты Xray)" "[ ! -e /tmp/passwall2-install/p ]"
		uci set dhcp.@dnsmasq[0].testmarker=lost && uci commit dhcp   # настройки возвращают команды из сообщения, а не случай
		sed -n -e "s/^  *\(opkg .*\)\$/\1/p" -e "s/^  *\(apk .*\)\$/\1/p" -e "s/^  *\(cp .*\)\$/\1/p" /tmp/o-double.txt > /tmp/fix.sh
		sh /tmp/fix.sh > /tmp/o-fix.txt 2>&1   # сети всё ещё нет: команды из сообщения обходятся скачанным файлом
		chk "названные команды возвращают $Q без сети" "[ -s /tmp/fix.sh ] && old_dq"
		chk "и прежние настройки DHCP" "[ \"\$(uci -q get dhcp.@dnsmasq[0].testmarker)\" = keep ]"
		net_on
		rm -rf /tmp/passwall2-install

		if ! command -v apk > /dev/null; then
			echo "--- opkg не снимает $Q (от него зависят другие пакеты)"
			faulty rmfail; rc=$?
			chk "код 1, «не удаляется» и «ничего не изменено»" "[ $rc = 1 ] && grep -q \"$OLDNAME не удаляется\" /tmp/o-rmfail.txt && grep -q \"ничего не изменено\" /tmp/o-rmfail.txt"
			chk "$Q стоит, временные файлы убраны" "old_dq && [ ! -e /tmp/passwall2-install ]"
			echo "--- opkg снял $Q, но вернул код ошибки: верить списку пакетов"
			faulty rmrc; rc=$?
			chk "замена доведена до конца: dnsmasq-full стоит, $Q нет" "exact dnsmasq-full && ! exact \"$Q\" && grep -q \"$Q заменён на dnsmasq-full\" /tmp/o-rmrc.txt"
			chk "не сказано «ничего не изменено», об ошибке opkg сказано" "! grep -q \"ничего не изменено\" /tmp/o-rmrc.txt && grep -q \"менеджер пакетов сообщил об ошибке\" /tmp/o-rmrc.txt"
			rm -rf /tmp/passwall2-install
			to_old   # следующему сценарию — роутер с прежним dnsmasq
			chk "$Q возвращён для следующего сценария" "old_dq"
		fi

		echo "--- HUP, INT и TERM посреди замены dnsmasq"
		faulty signal; rc=$?
		chk "замена дошла до конца: dnsmasq-full стоит, $Q нет" "exact dnsmasq-full && ! exact \"$Q\" && grep -q \"$Q заменён на dnsmasq-full\" /tmp/o-signal.txt"
		chk "после замены сигналы снова действуют: TERM останавливает скрипт" "[ $rc -gt 128 ] && ! grep -q \"не встали Xray\" /tmp/o-signal.txt"
		rm -rf /tmp/passwall2-install
		to_old   # следующему сценарию — чистый роутер с прежним dnsmasq
		chk "$Q возвращён для следующего сценария" "old_dq"
		rm -rf /tmp/fake
		echo "--- установка через stdin (как ssh root@роутер sh < файл)"
		sh < /work/install-passwall2.sh > /tmp/o2.txt 2>&1; rc=$?
		sed "s/\x1b\[[0-9;]*m//g" /tmp/o2.txt | grep -E "OK|ВНИМ|Останов|Готово" | sed "s/^/    /"
		chk "код 0" "[ $rc = 0 ]"
		chk "PassWall2 и русский перевод" "has luci-app-passwall2 && has luci-i18n-passwall2-ru"
		chk "Xray установлен и запускается" "has xray-core && xray version > /dev/null 2>&1"
		chk "гео-базы, geoview, tcping, chinadns-ng" "has v2ray-geoip && has v2ray-geosite && has geoview && has tcping && has chinadns-ng"
		chk "модули ядра nftables" "has kmod-nft-socket && has kmod-nft-tproxy && has kmod-nft-nat"
		chk "dnsmasq-full вместо $Q" "exact dnsmasq-full && ! exact \"$Q\""
		chk "настройки DHCP пережили замену" "[ \"\$(uci -q get dhcp.@dnsmasq[0].testmarker)\" = keep ] && [ ! -e /etc/config/dhcp-opkg ] && [ ! -e /etc/config/dhcp.apk-new ]"
		chk "PassWall2 выключен" "[ \"\$(uci -q get passwall2.@global[0].enabled)\" != 1 ]"
		chk "временные файлы убраны" "[ ! -e /tmp/passwall2-install ]"
		echo "--- повторный запуск"
		sh /work/install-passwall2.sh > /tmp/o3.txt 2>&1; rc=$?
		chk "повтор — код 0" "[ $rc = 0 ]"
		exit $BAD' || fails=$((fails + 1))
	done
done
echo "# прогонов с ошибками: $fails"
[ "$fails" = 0 ]

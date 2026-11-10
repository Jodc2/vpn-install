"""Собирает install-vpn.sh: шаблон + комплект бэкапа (vpn-backup.sh, restore.sh, README) внутри heredoc'ов (без cron).

python3 -I build.py                       — из src/ рядом со скриптом в install-vpn.sh
python3 -I build.py <шаблон> <kit-root> <README-friend.md> <выход>
"""
import base64
import gzip
import os
import sys

if len(sys.argv) == 1:
    here = os.path.dirname(os.path.abspath(__file__))
    tpl_path, kit, readme, out = (os.path.join(here, p) for p in ("src/install-vpn.sh.in", "src/kit", "src/README-friend.md", "install-vpn.sh"))
else:
    tpl_path, kit, readme, out = sys.argv[1:5]
files = [
    ("/usr/local/bin/vpn-backup.sh", os.path.join(kit, "usr/local/bin/vpn-backup.sh"), "755"),
    ("/usr/local/lib/vpn-backup/restore.sh", os.path.join(kit, "usr/local/lib/vpn-backup/restore.sh"), "755"),
    ("/usr/local/lib/vpn-backup/README.md", readme, "644"),
]
parts = ["install -d -m 755 /usr/local/lib/vpn-backup"]
for i, (dst, src, mode) in enumerate(files):
    body = open(src, encoding="utf-8").read()
    if not body.endswith("\n"):
        body += "\n"
    tag = "VPN_KIT_EOF_%d" % i
    assert tag not in body, tag
    parts.append("cat > %s <<'%s'\n%s%s\nchmod %s %s" % (dst, tag, body, tag, mode, dst))
tpl = open(tpl_path, encoding="utf-8").read()
assert tpl.count("__EMBED_KIT__") == 1
res = tpl.replace("__EMBED_KIT__", "\n".join(parts))

# Телеграм-бот: функции src/bot.sh — как есть; код воркера src/bot/worker.js — gzip + base64 в heredoc
# (mtime=0: одна и та же сборка бота даёт байт в байт тот же установщик).
src = os.path.dirname(os.path.abspath(tpl_path))
bot_funcs = open(os.path.join(src, "bot.sh"), encoding="utf-8").read().rstrip("\n")
source = open(os.path.join(src, "bot", "SOURCE"), encoding="utf-8").read().strip()
b64 = base64.encodebytes(gzip.compress(open(os.path.join(src, "bot", "worker.js"), "rb").read(), mtime=0)).decode()
assert "VPN_BOT_BUNDLE_EOF" not in b64
bundle = (
    "bot_extract_bundle() {  # код бота (vpn-bot %s) → $BOT_DIR/worker.js\n"
    "\tbase64 -d <<'VPN_BOT_BUNDLE_EOF' | gzip -dc > \"$BOT_DIR/worker.js\"\n%sVPN_BOT_BUNDLE_EOF\n}\nBOT_SOURCE=%s"
) % (source, b64, source)
for ph, val in (("__EMBED_BOT_FUNCS__", bot_funcs), ("__EMBED_BOT_BUNDLE__", bundle)):
    assert res.count(ph) == 1, ph
    res = res.replace(ph, val)
with open(out, "w", encoding="utf-8") as f:
    f.write(res)
os.chmod(out, 0o755)
print(out, len(res.splitlines()), "lines")

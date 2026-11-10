// src/telegram.ts
function markup(kb) {
  if (!kb) return void 0;
  return {
    inline_keyboard: kb.map(
      (row) => row.map((b) => b.url ? { text: b.text, url: b.url } : { text: b.text, callback_data: b.data })
    )
  };
}
var Telegram = class {
  constructor(env) {
    this.env = env;
  }
  async call(method, body) {
    const resp = await fetch(`https://api.telegram.org/bot${this.env.BOT_TOKEN}/${method}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body)
    });
    const json = await resp.json().catch(() => ({}));
    if (!json.ok) throw new Error(`tg ${method}: ${json.description || resp.status}`);
    return json.result;
  }
  send(chat, text, kb) {
    return this.call("sendMessage", {
      chat_id: chat,
      text,
      parse_mode: "HTML",
      link_preview_options: { is_disabled: true },
      reply_markup: markup(kb)
    });
  }
  edit(chat, messageId, text, kb) {
    return this.call("editMessageText", {
      chat_id: chat,
      message_id: messageId,
      text,
      parse_mode: "HTML",
      link_preview_options: { is_disabled: true },
      reply_markup: markup(kb)
    });
  }
  // Куда Телеграм шлёт обновления и была ли ошибка доставки (для самопроверки).
  webhookInfo() {
    return this.call("getWebhookInfo", {});
  }
  // Ответ на нажатие кнопки — лишь «часики» у владельца. Его неудача (запрос старше ~15 с,
  // повтор вебхука) не должна обрывать само действие кнопки.
  async answer(callbackId, text, alert = false) {
    try {
      await this.call("answerCallbackQuery", { callback_query_id: callbackId, text, show_alert: alert });
      return true;
    } catch {
      return false;
    }
  }
};

// src/xui.ts
var PanelError = class extends Error {
};
function api(env, path) {
  return `${env.PANEL_ORIGIN.replace(/\/$/, "")}${env.PANEL_BASE}panel/api/${path}`;
}
async function call(env, method, path, body) {
  const init = {
    method,
    headers: { Authorization: `Bearer ${env.PANEL_TOKEN}` }
  };
  if (body !== void 0) {
    init.headers = { ...init.headers, "Content-Type": "application/json" };
    init.body = JSON.stringify(body);
  }
  let resp;
  try {
    resp = await fetch(api(env, path), init);
  } catch (e) {
    throw new PanelError(`\u043F\u0430\u043D\u0435\u043B\u044C \u043D\u0435\u0434\u043E\u0441\u0442\u0443\u043F\u043D\u0430: ${e.message}`);
  }
  if (resp.status === 401 || resp.status === 403) {
    throw new PanelError("\u043F\u0430\u043D\u0435\u043B\u044C \u043D\u0435 \u043F\u0440\u0438\u043D\u044F\u043B\u0430 \u0442\u043E\u043A\u0435\u043D (\u0443\u0441\u0442\u0430\u0440\u0435\u043B? \u0441\u043C\u0435\u043D\u0438 PANEL_TOKEN)");
  }
  const text = await resp.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new PanelError(`\u043F\u0430\u043D\u0435\u043B\u044C \u043E\u0442\u0432\u0435\u0442\u0438\u043B\u0430 \u043D\u0435 JSON (${resp.status})`);
  }
  if (!json || json.success !== true) {
    throw new PanelError(String(json?.msg || `\u043F\u0430\u043D\u0435\u043B\u044C \u0432\u0435\u0440\u043D\u0443\u043B\u0430 \u043E\u0448\u0438\u0431\u043A\u0443 (${resp.status})`).slice(0, 200));
  }
  return json.obj;
}
async function listClients(env) {
  const obj = await call(env, "GET", "clients/list");
  return Array.isArray(obj) ? obj : [];
}
async function serverStatus(env) {
  const o = await call(env, "GET", "server/status");
  return {
    cpu: o.cpu ?? 0,
    mem: o.mem ?? { current: 0, total: 0 },
    disk: o.disk ?? { current: 0, total: 0 },
    uptime: o.uptime ?? 0,
    xrayState: o.xray?.state ?? "?",
    xrayVersion: o.xray?.version ?? "?",
    netTraffic: o.netTraffic ?? { sent: 0, recv: 0 },
    publicIP: o.publicIP?.ipv4 ?? ""
  };
}
async function onlineEmails(env) {
  const obj = await call(env, "POST", "clients/onlines");
  return new Set(Array.isArray(obj) ? obj.map(String) : []);
}
async function firstInboundId(env) {
  const obj = await call(env, "GET", "inbounds/list/slim");
  const first = Array.isArray(obj) ? obj[0] : null;
  if (!first?.id) throw new PanelError("\u043D\u0430 \u0432\u0445\u043E\u0434\u0435 \u043D\u0435\u0442 \u043D\u0438 \u043E\u0434\u043D\u043E\u0433\u043E \u043F\u043E\u0434\u043A\u043B\u044E\u0447\u0435\u043D\u0438\u044F");
  return first.id;
}
async function createClient(env, inboundId, email, comment) {
  const payload = {
    client: { email, comment, enable: true },
    inboundIds: [inboundId]
  };
  await call(env, "POST", "clients/add", payload);
}
async function deleteClient(env, email) {
  await call(env, "POST", `clients/del/${encodeURIComponent(email)}`);
}
function updateBody(c, enable) {
  return {
    id: c.uuid,
    // model.Client.ID (json "id") — это uuid
    email: c.email,
    security: c.security || "auto",
    password: c.password || "",
    flow: c.flow || "",
    auth: c.auth || "",
    limitIp: c.limitIp || 0,
    totalGB: c.totalGB || 0,
    expiryTime: c.expiryTime || 0,
    enable,
    tgId: c.tgId || 0,
    subId: c.subId,
    group: c.group || "",
    comment: c.comment || "",
    reset: c.reset || 0
  };
}
async function setEnabled(env, c, enable) {
  await call(env, "POST", `clients/update/${encodeURIComponent(c.email)}`, updateBody(c, enable));
}
function subLink(env, subId) {
  return `${env.SUB_PREFIX}${subId}`;
}

// src/format.ts
function bytes(n) {
  if (!Number.isFinite(n) || n <= 0) return "0 \u0411";
  const u = ["\u0411", "\u041A\u0411", "\u041C\u0411", "\u0413\u0411", "\u0422\u0411", "\u041F\u0411"];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  const s = v >= 100 || i === 0 ? Math.round(v).toString() : v.toFixed(v >= 10 ? 1 : 2);
  return `${s} ${u[i]}`;
}
function dur(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  const d = Math.floor(s / 86400);
  const h = Math.floor(s % 86400 / 3600);
  const m = Math.floor(s % 3600 / 60);
  if (d > 0) return h > 0 ? `${d} \u0434 ${h} \u0447` : `${d} \u0434`;
  if (h > 0) return m > 0 ? `${h} \u0447 ${m} \u043C\u0438\u043D` : `${h} \u0447`;
  if (m > 0) return `${m} \u043C\u0438\u043D`;
  return `${s} \u0441`;
}
function ago(msEpoch, now = Date.now()) {
  if (!msEpoch || msEpoch <= 0) return "\u043D\u0438\u043A\u043E\u0433\u0434\u0430";
  const diff = Math.floor((now - msEpoch) / 1e3);
  if (diff < 0) return "\u0442\u043E\u043B\u044C\u043A\u043E \u0447\u0442\u043E";
  if (diff < 60) return "\u0442\u043E\u043B\u044C\u043A\u043E \u0447\u0442\u043E";
  return `${dur(diff)} \u043D\u0430\u0437\u0430\u0434`;
}
function expiry(msEpoch, now = Date.now()) {
  if (!msEpoch || msEpoch === 0) return "\u0431\u0435\u0441\u0441\u0440\u043E\u0447\u043D\u043E";
  if (msEpoch < 0) return "\u043F\u043E \u0442\u0440\u0430\u0444\u0438\u043A\u0443";
  if (msEpoch <= now) return "\u0438\u0441\u0442\u0451\u043A";
  const left = Math.floor((msEpoch - now) / 1e3);
  return `${dur(left)} \u043E\u0441\u0442\u0430\u043B\u043E\u0441\u044C`;
}
function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// src/render.ts
function mainMenu() {
  return {
    text: "<b>VPN</b> \u2014 \u043F\u0430\u043D\u0435\u043B\u044C \u0443\u043F\u0440\u0430\u0432\u043B\u0435\u043D\u0438\u044F. \u0412\u044B\u0431\u0435\u0440\u0438 \u0440\u0430\u0437\u0434\u0435\u043B:",
    kb: [
      [{ text: "\u{1F465} \u041A\u043B\u0438\u0435\u043D\u0442\u044B", data: "cl" }],
      [{ text: "\u{1F4CA} \u0421\u0442\u0430\u0442\u0438\u0441\u0442\u0438\u043A\u0430", data: "st" }],
      [{ text: "\u{1F30D} \u041F\u0440\u043E\u0432\u0435\u0440\u043A\u0430 \u0431\u0430\u043D\u0430", data: "bn" }],
      [{ text: "\u{1F4BE} \u0411\u044D\u043A\u0430\u043F", data: "bk" }],
      [{ text: "\u{1F69A} \u041F\u0435\u0440\u0435\u0435\u0437\u0434", data: "mg" }]
    ]
  };
}
var PAGE = 8;
function clientList(clients, online, page = 0) {
  const sorted = [...clients].sort((a, b) => a.email.localeCompare(b.email));
  const pages = Math.max(1, Math.ceil(sorted.length / PAGE));
  const p = Math.min(Math.max(0, page), pages - 1);
  const slice = sorted.slice(p * PAGE, p * PAGE + PAGE);
  const rows = slice.map((c) => {
    const mark = !c.enable ? "\u23F8" : online.has(c.email) ? "\u{1F7E2}" : "\u26AA\uFE0F";
    const name = c.comment || c.email;
    return [{ text: `${mark} ${name}`.slice(0, 60), data: `c:${c.id}` }];
  });
  const nav = [];
  if (p > 0) nav.push({ text: "\u2039", data: `cl:${p - 1}` });
  if (p < pages - 1) nav.push({ text: "\u203A", data: `cl:${p + 1}` });
  const kb = [...rows];
  if (nav.length) kb.push(nav);
  kb.push([{ text: "\u2795 \u0414\u043E\u0431\u0430\u0432\u0438\u0442\u044C", data: "ca" }]);
  kb.push([{ text: "\u2190 \u041C\u0435\u043D\u044E", data: "m" }]);
  const on = clients.filter((c) => c.enable && online.has(c.email)).length;
  return {
    text: `<b>\u041A\u043B\u0438\u0435\u043D\u0442\u044B</b> \u2014 ${clients.length}, \u043E\u043D\u043B\u0430\u0439\u043D ${on}` + (pages > 1 ? ` \xB7 \u0441\u0442\u0440. ${p + 1}/${pages}` : ""),
    kb
  };
}
function clientCard(c, isOnline, subUrl) {
  const used = (c.traffic?.up || 0) + (c.traffic?.down || 0);
  const lines = [
    `<b>${esc(c.comment || c.email)}</b>`,
    `\u043C\u0435\u0442\u043A\u0430: <code>${esc(c.email)}</code>`,
    `\u0441\u043E\u0441\u0442\u043E\u044F\u043D\u0438\u0435: ${!c.enable ? "\u23F8 \u0432\u044B\u043A\u043B\u044E\u0447\u0435\u043D" : isOnline ? "\u{1F7E2} \u043E\u043D\u043B\u0430\u0439\u043D" : "\u26AA\uFE0F \u043D\u0435 \u0432 \u0441\u0435\u0442\u0438"}`,
    `\u0442\u0440\u0430\u0444\u0438\u043A: ${bytes(used)}` + (c.totalGB ? ` \u0438\u0437 ${bytes(c.totalGB)}` : ""),
    `\u0441\u0440\u043E\u043A: ${expiry(c.expiryTime)}`,
    `\u043F\u043E\u0441\u043B\u0435\u0434\u043D\u0438\u0439 \u0440\u0430\u0437: ${ago(c.traffic?.lastOnline || 0)}`
  ];
  return {
    text: lines.join("\n"),
    kb: [
      [{ text: "\u{1F517} \u0421\u0441\u044B\u043B\u043A\u0430 \u043D\u0430 \u043F\u043E\u0434\u043F\u0438\u0441\u043A\u0443", data: `cs:${c.id}` }],
      [
        c.enable ? { text: "\u23F8 \u0412\u044B\u043A\u043B\u044E\u0447\u0438\u0442\u044C", data: `cx:${c.id}` } : { text: "\u25B6\uFE0F \u0412\u043A\u043B\u044E\u0447\u0438\u0442\u044C", data: `cx:${c.id}` },
        { text: "\u{1F5D1} \u0423\u0434\u0430\u043B\u0438\u0442\u044C", data: `cd:${c.id}` }
      ],
      [{ text: "\u2190 \u041A\u043B\u0438\u0435\u043D\u0442\u044B", data: "cl" }]
    ]
  };
}
function subLinkScreen(c, subUrl) {
  return {
    text: `\u0421\u0441\u044B\u043B\u043A\u0430 \u043D\u0430 \u043F\u043E\u0434\u043F\u0438\u0441\u043A\u0443 \u0434\u043B\u044F <b>${esc(c.comment || c.email)}</b> \u2014 \u043E\u0442\u043F\u0440\u0430\u0432\u044C \u0435\u0451 \u0434\u0440\u0443\u0433\u0443, \u043E\u043D \u0434\u043E\u0431\u0430\u0432\u0438\u0442 \u0435\u0451 \u0432 \u043F\u0440\u0438\u043B\u043E\u0436\u0435\u043D\u0438\u0438 (Happ, v2RayTun):

<code>${esc(subUrl)}</code>`,
    kb: [[{ text: "\u2190 \u041A\u0430\u0440\u0442\u043E\u0447\u043A\u0430", data: `c:${c.id}` }]]
  };
}
function confirmDelete(c) {
  return {
    text: `\u0423\u0434\u0430\u043B\u0438\u0442\u044C \u043A\u043B\u0438\u0435\u043D\u0442\u0430 <b>${esc(c.comment || c.email)}</b>? \u0415\u0433\u043E \u0441\u0441\u044B\u043B\u043A\u0430 \u043F\u0435\u0440\u0435\u0441\u0442\u0430\u043D\u0435\u0442 \u0440\u0430\u0431\u043E\u0442\u0430\u0442\u044C.`,
    kb: [
      [
        { text: "\u{1F5D1} \u0414\u0430, \u0443\u0434\u0430\u043B\u0438\u0442\u044C", data: `cd!:${c.id}` },
        { text: "\u041E\u0442\u043C\u0435\u043D\u0430", data: `c:${c.id}` }
      ]
    ]
  };
}
function stats(s, total, enabled, online) {
  const memPct = s.mem.total ? Math.round(s.mem.current / s.mem.total * 100) : 0;
  const diskPct = s.disk.total ? Math.round(s.disk.current / s.disk.total * 100) : 0;
  const lines = [
    `<b>\u0421\u0442\u0430\u0442\u0438\u0441\u0442\u0438\u043A\u0430</b>`,
    ``,
    `\u043A\u043B\u0438\u0435\u043D\u0442\u043E\u0432: ${total}, \u0432\u043A\u043B\u044E\u0447\u0435\u043D\u043E ${enabled}, \u043E\u043D\u043B\u0430\u0439\u043D ${online}`,
    ``,
    `\u0441\u0435\u0440\u0432\u0435\u0440 \u0432\u0445\u043E\u0434\u0430 ${esc(s.publicIP || "?")}`,
    `Xray: ${s.xrayState === "running" ? "\u{1F7E2} \u0440\u0430\u0431\u043E\u0442\u0430\u0435\u0442" : "\u{1F534} " + esc(s.xrayState)} (${esc(s.xrayVersion)})`,
    `\u0430\u043F\u0442\u0430\u0439\u043C: ${dur(s.uptime)}`,
    `CPU: ${Math.round(s.cpu)}% \xB7 \u041E\u0417\u0423: ${memPct}% (${bytes(s.mem.current)}/${bytes(s.mem.total)})`,
    `\u0434\u0438\u0441\u043A: ${diskPct}% (${bytes(s.disk.current)}/${bytes(s.disk.total)})`,
    `\u0442\u0440\u0430\u0444\u0438\u043A: \u2191 ${bytes(s.netTraffic.sent)} \xB7 \u2193 ${bytes(s.netTraffic.recv)}`
  ];
  return {
    text: lines.join("\n"),
    kb: [
      [{ text: "\u{1F504} \u041E\u0431\u043D\u043E\u0432\u0438\u0442\u044C", data: "st" }],
      [{ text: "\u2190 \u041C\u0435\u043D\u044E", data: "m" }]
    ]
  };
}
var VERDICT_RU = {
  OK: "\u{1F7E2} \u043E\u0442\u043A\u0440\u044B\u0432\u0430\u0435\u0442\u0441\u044F \u0438\u0437 \u0420\u043E\u0441\u0441\u0438\u0438",
  RU_BLOCKED: "\u{1F534} \u0437\u0430\u0431\u043B\u043E\u043A\u0438\u0440\u043E\u0432\u0430\u043D \u0432 \u0420\u043E\u0441\u0441\u0438\u0438",
  PARTIAL: "\u{1F7E1} \u043E\u0442\u043A\u0440\u044B\u0432\u0430\u0435\u0442\u0441\u044F \u043D\u0435 \u0443 \u0432\u0441\u0435\u0445 \u043F\u0440\u043E\u0432\u0430\u0439\u0434\u0435\u0440\u043E\u0432",
  CLOSED: "\u26AA\uFE0F \u043D\u0435 \u043E\u0442\u043A\u0440\u044B\u0432\u0430\u0435\u0442\u0441\u044F \u043D\u0438\u043E\u0442\u043A\u0443\u0434\u0430 \u2014 \u0441\u0435\u0440\u0432\u0435\u0440 \u043B\u0451\u0433 \u0438\u043B\u0438 \u043F\u043E\u0440\u0442 \u0437\u0430\u043A\u0440\u044B\u0442",
  UNKNOWN: "\u26AA\uFE0F \u043F\u0440\u043E\u0432\u0435\u0440\u044F\u043B\u043A\u0438 \u043D\u0435 \u043E\u0442\u0432\u0435\u0442\u0438\u043B\u0438 \u2014 \u043F\u043E\u043F\u0440\u043E\u0431\u0443\u0439 \u043F\u043E\u0437\u0436\u0435"
};
function cut(s, n) {
  return s.length > n ? s.slice(0, n - 1) + "\u2026" : s;
}
function banResult(r) {
  const head2 = `<b>\u041F\u0440\u043E\u0432\u0435\u0440\u043A\u0430 \u0431\u0430\u043D\u0430</b> \u2014 IP \u0432\u0445\u043E\u0434\u0430 <code>${esc(r.ip)}</code>`;
  let body;
  const p = r.ports[0];
  if (r.status !== "ok" || !p) {
    body = `\u26AA\uFE0F ${esc(r.note || "\u043F\u0440\u043E\u0432\u0435\u0440\u0438\u0442\u044C \u043D\u0435 \u0432\u044B\u0448\u043B\u043E")} \u2014 \u043F\u043E\u043F\u0440\u043E\u0431\u0443\u0439 \u043F\u043E\u0437\u0436\u0435.`;
  } else {
    const silent = p.ruN - p.ruDone;
    const lines = [
      VERDICT_RU[p.verdict],
      `\u0420\u043E\u0441\u0441\u0438\u044F: \u043F\u043E\u0434\u043A\u043B\u044E\u0447\u0438\u043B\u0438\u0441\u044C ${p.ruOk} \u0438\u0437 ${p.ruDone}` + (silent > 0 ? ` (\u0435\u0449\u0451 ${silent} \u043D\u0435 \u043E\u0442\u0432\u0435\u0442\u0438\u043B\u0438)` : "") + ` \xB7 \u0413\u0435\u0440\u043C\u0430\u043D\u0438\u044F: ${p.euOk} \u0438\u0437 ${p.euDone}`,
      "",
      ...(r.probes || []).filter((x) => x.country === "RU").map((x) => `${x.ok === null ? "\u2026" : x.ok ? "\u2705" : "\u274C"} ${esc(x.city || "?")} \u2014 ${esc(cut(x.network || "?", 40))}`),
      "",
      `<i>Globalping, TCP-\u043F\u043E\u0440\u0442 ${p.port}</i>`
    ];
    body = lines.join("\n");
  }
  return {
    text: `${head2}

${body}`,
    kb: [
      [{ text: "\u{1F504} \u041F\u0440\u043E\u0432\u0435\u0440\u0438\u0442\u044C \u0441\u043D\u043E\u0432\u0430", data: "bn" }],
      [{ text: "\u2190 \u041C\u0435\u043D\u044E", data: "m" }]
    ]
  };
}
function working(what) {
  return { text: `\u23F3 ${esc(what)}\u2026`, kb: [] };
}
function errorScreen(msg, back = "m") {
  return {
    text: `\u26A0\uFE0F ${esc(msg)}`,
    kb: [[{ text: "\u2190 \u041D\u0430\u0437\u0430\u0434", data: back }]]
  };
}

// src/state.ts
var DIALOG_KEY = "dialog";
async function getDialog(env) {
  const v = await env.STATE.get(DIALOG_KEY, "json");
  return v || { mode: "idle" };
}
async function setDialog(env, d) {
  if (d.mode === "idle") await env.STATE.delete(DIALOG_KEY);
  else await env.STATE.put(DIALOG_KEY, JSON.stringify(d), { expirationTtl: 3600 });
}
async function putBackup(env, name, bytes2) {
  const meta = { name, size: bytes2.byteLength, createdAt: Date.now() };
  await env.STATE.put("backup:bytes", bytes2, { metadata: meta });
}
async function backupMeta(env) {
  const r = await env.STATE.list({ prefix: "backup:bytes", limit: 1 });
  const k = r.keys.find((x) => x.name === "backup:bytes");
  return k?.metadata ?? null;
}
async function getBackup(env) {
  const res = await env.STATE.getWithMetadata("backup:bytes", "arrayBuffer");
  if (!res.value || !res.metadata) return null;
  return { bytes: res.value, meta: res.metadata };
}
async function startMigration(env, m) {
  await env.STATE.put("mig:current", JSON.stringify(m), { expirationTtl: 1800 });
  await env.STATE.put(`migtok:${m.token}`, m.token, { expirationTtl: 1800 });
}
async function currentMigration(env) {
  return await env.STATE.get("mig:current", "json");
}
async function migrationTokenValid(env, token) {
  return await env.STATE.get(`migtok:${token}`) === token;
}
async function finishMigration(env, m) {
  if (m.status === "done" || m.status === "failed") {
    await env.STATE.delete("mig:current");
    await env.STATE.delete(`migtok:${m.token}`);
  } else {
    await env.STATE.put("mig:current", JSON.stringify(m), { expirationTtl: 1800 });
  }
}
async function getEntryFpr(env) {
  const v = await env.STATE.get("entry:fpr", "json");
  return Array.isArray(v) ? v : [];
}
async function setEntryFpr(env, fprs) {
  await env.STATE.put("entry:fpr", JSON.stringify(fprs));
}
async function getAdmin(env) {
  if (env.ADMIN_ID && env.ADMIN_ID.trim()) return Number(env.ADMIN_ID);
  const v = await env.STATE.get("admin:id");
  return v ? Number(v) : null;
}
async function claimAdmin(env, id) {
  await env.STATE.put("admin:id", String(id));
}
async function getLastBan(env) {
  return await env.STATE.get("ban:last") || "";
}
async function setLastBan(env, verdict) {
  await env.STATE.put("ban:last", verdict);
}

// src/bancheck.ts
function portVerdict(ruOk, ruDone, euOk, euDone) {
  if (ruDone === 0) return "UNKNOWN";
  if (ruOk === ruDone) return "OK";
  if (ruOk * 2 >= ruDone) return "PARTIAL";
  if (euOk > 0) return "RU_BLOCKED";
  if (ruOk === 0 && euDone > 0) return "CLOSED";
  return "UNKNOWN";
}

// src/bancheck_gp.ts
var API = "https://api.globalping.io/v1/measurements";
var UA = "vpn-bot/1.0";
var RU_PROBES = 8;
var EU_PROBES = 2;
var POLLS = 13;
var POLL_MS = 3e3;
var sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function summarizeGlobalping(ip, port, results) {
  const probes = [];
  let ruOk = 0, ruDone = 0, ruN = 0, euOk = 0, euDone = 0;
  for (const r of results) {
    const country = r.probe?.country || "?";
    const st = r.result?.status;
    const done = st === "finished" || st === "failed";
    const ok = st === "finished" && (r.result?.stats?.rcv ?? 0) > 0;
    if (country === "RU") {
      ruN++;
      if (done) ruDone++;
      if (ok) ruOk++;
    } else {
      if (done) euDone++;
      if (ok) euOk++;
    }
    probes.push({ country, city: r.probe?.city || "", network: r.probe?.network || "", ok: done ? ok : null });
  }
  if (ruN === 0) {
    return { status: "no-nodes", ports: [], ip, probes, note: "\u0443 Globalping \u0441\u0435\u0439\u0447\u0430\u0441 \u043D\u0435\u0442 \u0441\u0432\u043E\u0431\u043E\u0434\u043D\u044B\u0445 \u043F\u0440\u043E\u0432\u0435\u0440\u044F\u043B\u043E\u043A \u0432 \u0420\u043E\u0441\u0441\u0438\u0438" };
  }
  return {
    status: "ok",
    ip,
    probes,
    ports: [{ port, ruOk, ruDone, ruN, euOk, euDone, verdict: portVerdict(ruOk, ruDone, euOk, euDone) }]
  };
}
async function checkBanGlobalping(env, ip, port, pollMs = POLL_MS) {
  const headers = { "Content-Type": "application/json", "User-Agent": UA };
  if (env.GLOBALPING_TOKEN) headers.Authorization = `Bearer ${env.GLOBALPING_TOKEN}`;
  let id;
  try {
    const start = await fetch(API, {
      method: "POST",
      headers,
      body: JSON.stringify({
        type: "ping",
        target: ip,
        locations: [
          { country: "RU", tags: ["eyeball-network"], limit: RU_PROBES },
          { country: "DE", limit: EU_PROBES }
        ],
        measurementOptions: { packets: 3, protocol: "TCP", port }
      }),
      signal: AbortSignal.timeout(15e3)
    });
    if (start.status === 429) {
      return { status: "no-api", ports: [], ip, note: "\u0438\u0441\u0447\u0435\u0440\u043F\u0430\u043D \u0447\u0430\u0441\u043E\u0432\u043E\u0439 \u043B\u0438\u043C\u0438\u0442 \u043F\u0440\u043E\u0432\u0435\u0440\u043E\u043A Globalping" };
    }
    if (start.status === 422) {
      return { status: "no-nodes", ports: [], ip, note: "\u0443 Globalping \u0441\u0435\u0439\u0447\u0430\u0441 \u043D\u0435\u0442 \u0441\u0432\u043E\u0431\u043E\u0434\u043D\u044B\u0445 \u043F\u0440\u043E\u0432\u0435\u0440\u044F\u043B\u043E\u043A \u0432 \u0420\u043E\u0441\u0441\u0438\u0438" };
    }
    if (start.status !== 202) {
      return { status: "no-api", ports: [], ip, note: `Globalping \u043E\u0442\u0432\u0435\u0442\u0438\u043B ${start.status}` };
    }
    id = (await start.json()).id;
  } catch {
    return { status: "no-api", ports: [], ip, note: "Globalping \u0441\u0435\u0439\u0447\u0430\u0441 \u043D\u0435\u0434\u043E\u0441\u0442\u0443\u043F\u0435\u043D" };
  }
  let results = [];
  for (let i = 0; i < POLLS; i++) {
    await sleep(pollMs);
    try {
      const r = await fetch(`${API}/${encodeURIComponent(id)}`, {
        headers: { "User-Agent": UA },
        signal: AbortSignal.timeout(1e4)
      });
      if (!r.ok) continue;
      const data = await r.json();
      results = data.results || results;
      if (data.status === "finished") break;
    } catch {
    }
  }
  return summarizeGlobalping(ip, port, results);
}

// src/cf.ts
async function cfApi(env, method, path, body) {
  const resp = await fetch(`https://api.cloudflare.com/client/v4${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${env.CF_API_TOKEN}`,
      "Content-Type": "application/json"
    },
    body: body === void 0 ? void 0 : JSON.stringify(body)
  });
  const json = await resp.json().catch(() => ({}));
  if (!json.success) {
    const msg = (json.errors || []).map((e) => e.message).join("; ") || `HTTP ${resp.status}`;
    throw new Error(`Cloudflare: ${msg}`);
  }
  return json.result;
}
async function pointDnsTo(env, newIp) {
  const records = await cfApi(
    env,
    "GET",
    `/zones/${env.CF_ZONE_ID}/dns_records?type=A&name=${encodeURIComponent(env.DNS_NAME)}`
  );
  if (!records || records.length === 0) {
    throw new Error(`\u0432 \u0437\u043E\u043D\u0435 \u043D\u0435\u0442 A-\u0437\u0430\u043F\u0438\u0441\u0438 ${env.DNS_NAME}`);
  }
  const rec = records[0];
  const previous = rec.content;
  if (previous === newIp) return { previous, proxied: rec.proxied };
  await cfApi(env, "PATCH", `/zones/${env.CF_ZONE_ID}/dns_records/${rec.id}`, {
    content: newIp,
    proxied: false,
    // для нашего VLESS proxy должен быть выключен (серое облако)
    ttl: 300
  });
  return { previous, proxied: rec.proxied };
}
async function resolveIPv4(name) {
  const r = await fetch(`https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(name)}&type=A`, {
    headers: { Accept: "application/dns-json" },
    signal: AbortSignal.timeout(1e4)
  });
  const j = await r.json().catch(() => ({}));
  const a = (j.Answer || []).find((x) => x.type === 1 && typeof x.data === "string");
  if (!a) throw new Error(`\u0443 \u0438\u043C\u0435\u043D\u0438 ${name} \u043D\u0435\u0442 A-\u0437\u0430\u043F\u0438\u0441\u0438`);
  return a.data;
}
async function currentDnsIp(env) {
  const records = await cfApi(
    env,
    "GET",
    `/zones/${env.CF_ZONE_ID}/dns_records?type=A&name=${encodeURIComponent(env.DNS_NAME)}`
  );
  return records?.[0]?.content || "";
}

// node_modules/@workeryard/undershell/src/workers/index.ts
import { connect as tcp } from "cloudflare:sockets";

// node_modules/@workeryard/undershell/src/carriers/websocket.ts
async function bytesOf(data) {
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data))
    return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  if (typeof Blob !== "undefined" && data instanceof Blob)
    return new Uint8Array(await data.arrayBuffer());
  return null;
}
function webSocketStream(socket) {
  socket.binaryType = "arraybuffer";
  let closed = false;
  let hungUp = false;
  const hangUp = (code = 1e3, reason) => {
    if (hungUp) return;
    hungUp = true;
    try {
      socket.close(code, reason);
    } catch {
    }
  };
  let order = Promise.resolve();
  const readable = new ReadableStream({
    start(controller) {
      socket.addEventListener("message", (event) => {
        order = order.then(async () => {
          const bytes2 = await bytesOf(event.data);
          if (closed) return;
          if (!bytes2) {
            closed = true;
            controller.error(new Error("the tunnel sent a text message where only bytes belong"));
            hangUp(1003, "binary only");
            return;
          }
          controller.enqueue(bytes2);
        });
      });
      socket.addEventListener("close", (event) => {
        void order.then(() => {
          if (closed) return;
          closed = true;
          if (event.code === void 0 || event.code === 1e3 || event.code === 1005)
            controller.close();
          else
            controller.error(
              new Error(
                `the tunnel closed (${event.code}${event.reason ? `: ${event.reason}` : ""})`
              )
            );
        });
      });
      socket.addEventListener("error", () => {
        void order.then(() => {
          if (closed) return;
          closed = true;
          controller.error(new Error("the tunnel failed"));
        });
      });
    },
    cancel() {
      closed = true;
      hangUp();
    }
  });
  const writable = new WritableStream({
    write(chunk) {
      if (closed) throw new Error("the tunnel is closed");
      socket.send(chunk.slice());
    },
    close() {
      hangUp();
    },
    abort() {
      hangUp();
    }
  });
  return {
    readable,
    writable,
    close: () => {
      closed = true;
      hangUp();
      return Promise.resolve();
    }
  };
}

// node_modules/@workeryard/undershell/src/crypto.ts
var subtle = crypto.subtle;
async function digest(hash, data) {
  return new Uint8Array(await subtle.digest(hash, data));
}
function randomBytes(length2) {
  return crypto.getRandomValues(new Uint8Array(length2));
}
function base64(bytes2) {
  let binary = "";
  for (let at = 0; at < bytes2.length; at += 32768) {
    binary += String.fromCharCode(...bytes2.subarray(at, at + 32768));
  }
  return btoa(binary);
}
function fromBase64(text) {
  const binary = atob(text.replace(/-/g, "+").replace(/_/g, "/").replace(/\s+/g, ""));
  const out = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) out[index] = binary.charCodeAt(index);
  return out;
}
function base64Url(bytes2, keepLeadingZeros = false) {
  let start = 0;
  if (!keepLeadingZeros) while (start < bytes2.length - 1 && bytes2[start] === 0) start++;
  return base64(bytes2.subarray(start)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// node_modules/@workeryard/undershell/src/wire.ts
var Writer = class {
  #parts = [];
  #length = 0;
  #push(part) {
    this.#parts.push(part);
    this.#length += part.length;
    return this;
  }
  byte(value) {
    return this.#push(new Uint8Array([value]));
  }
  bool(value) {
    return this.byte(value ? 1 : 0);
  }
  uint32(value) {
    const out = new Uint8Array(4);
    new DataView(out.buffer).setUint32(0, value >>> 0);
    return this.#push(out);
  }
  /** uint64, from a number: file sizes and offsets outgrow a uint32, never 2^53. */
  uint64(value) {
    return this.uint32(Math.floor(value / 2 ** 32)).uint32(value >>> 0);
  }
  /** Raw bytes, with no length in front of them. */
  raw(value) {
    return this.#push(value);
  }
  string(value) {
    const bytes2 = typeof value === "string" ? new TextEncoder().encode(value) : value;
    return this.uint32(bytes2.length).#push(bytes2);
  }
  nameList(names) {
    return this.string(names.join(","));
  }
  /** A positive integer: leading zeros dropped, one added back if the top bit is set. */
  mpint(value) {
    let start = 0;
    while (start < value.length && value[start] === 0) start++;
    const trimmed = value.subarray(start);
    if (trimmed.length === 0) return this.uint32(0);
    if (trimmed[0] & 128) {
      const padded = new Uint8Array(trimmed.length + 1);
      padded.set(trimmed, 1);
      return this.string(padded);
    }
    return this.string(trimmed);
  }
  build() {
    const out = new Uint8Array(this.#length);
    let at = 0;
    for (const part of this.#parts) {
      out.set(part, at);
      at += part.length;
    }
    return out;
  }
};
var Reader = class {
  constructor(bytes2) {
    this.bytes = bytes2;
    this.#view = new DataView(bytes2.buffer, bytes2.byteOffset, bytes2.byteLength);
  }
  #at = 0;
  #view;
  get done() {
    return this.#at >= this.bytes.length;
  }
  byte() {
    if (this.#at >= this.bytes.length) throw new Error("packet ended early");
    return this.bytes[this.#at++];
  }
  bool() {
    return this.byte() !== 0;
  }
  uint32() {
    if (this.#at + 4 > this.bytes.length) throw new Error("packet ended early");
    const value = this.#view.getUint32(this.#at);
    this.#at += 4;
    return value;
  }
  uint64() {
    const high = this.uint32();
    return high * 2 ** 32 + this.uint32();
  }
  /** Exactly `length` bytes, with no length of their own. */
  take(length2) {
    if (this.#at + length2 > this.bytes.length) throw new Error("packet ended early");
    const value = this.bytes.subarray(this.#at, this.#at + length2);
    this.#at += length2;
    return value;
  }
  string() {
    return this.take(this.uint32());
  }
  text() {
    return new TextDecoder().decode(this.string());
  }
  nameList() {
    const value = this.text();
    return value === "" ? [] : value.split(",");
  }
  /**
   * A non-negative mpint's magnitude, the sign byte dropped. Every mpint SSH
   * sends a client — keys, signatures — is positive, so a negative one is a
   * malformed packet rather than a value.
   */
  mpint() {
    const value = this.string();
    if (value.length > 0 && value[0] & 128) throw new Error("a negative mpint where none can be");
    return value[0] === 0 ? value.subarray(1) : value;
  }
  skipString() {
    this.string();
  }
  /** Whatever is left, which some messages end with. */
  rest() {
    return this.take(this.bytes.length - this.#at);
  }
};
function concat(parts) {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(total);
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}
function fixedLength(value, length2) {
  let start = 0;
  while (start < value.length - length2 && value[start] === 0) start++;
  const trimmed = value.subarray(start);
  if (trimmed.length > length2)
    throw new Error(`a ${trimmed.length}-byte integer where ${length2} fit`);
  const out = new Uint8Array(length2);
  out.set(trimmed, length2 - trimmed.length);
  return out;
}
function equalBytes(a, b) {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index++) difference |= a[index] ^ b[index];
  return difference === 0;
}

// node_modules/@workeryard/undershell/src/keys/der.ts
var TAG = {
  INTEGER: 2,
  BIT_STRING: 3,
  OCTET_STRING: 4,
  NULL: 5,
  OID: 6,
  SEQUENCE: 48
};
var Der = class _Der {
  constructor(bytes2) {
    this.bytes = bytes2;
  }
  #at = 0;
  get done() {
    return this.#at >= this.bytes.length;
  }
  /** The next element's tag, without reading it. */
  peek() {
    return this.bytes[this.#at];
  }
  next(expected) {
    const tag = this.bytes[this.#at];
    if (tag === void 0) throw new Error("the key ended early");
    if (expected !== void 0 && tag !== expected) {
      throw new Error(
        `the key has element 0x${tag.toString(16)} where 0x${expected.toString(16)} belongs`
      );
    }
    let at = this.#at + 1;
    let length2 = this.bytes[at++] ?? 0;
    if (length2 & 128) {
      const count = length2 & 127;
      if (count === 0 || count > 4) throw new Error("the key has a length DER does not allow");
      length2 = 0;
      for (let index = 0; index < count; index++) length2 = length2 * 256 + (this.bytes[at++] ?? 0);
    }
    if (at + length2 > this.bytes.length) throw new Error("the key ended early");
    this.#at = at + length2;
    return { tag, content: this.bytes.subarray(at, at + length2) };
  }
  sequence() {
    return new _Der(this.next(TAG.SEQUENCE).content);
  }
  /** An INTEGER's magnitude, its sign byte dropped. */
  integer() {
    const value = this.next(TAG.INTEGER).content;
    return value[0] === 0 && value.length > 1 ? value.subarray(1) : value;
  }
  octetString() {
    return this.next(TAG.OCTET_STRING).content;
  }
  /** An OBJECT IDENTIFIER, dotted. */
  oid() {
    const bytes2 = this.next(TAG.OID).content;
    const parts = [Math.floor(bytes2[0] / 40), bytes2[0] % 40];
    let value = 0;
    for (const byte of bytes2.subarray(1)) {
      value = value * 128 + (byte & 127);
      if (!(byte & 128)) {
        parts.push(value);
        value = 0;
      }
    }
    return parts.join(".");
  }
};
function length(value) {
  if (value < 128) return new Uint8Array([value]);
  const bytes2 = [];
  for (let left = value; left > 0; left = Math.floor(left / 256)) bytes2.unshift(left & 255);
  return new Uint8Array([128 | bytes2.length, ...bytes2]);
}
function element(tag, ...content) {
  const body = concat(content);
  return concat([new Uint8Array([tag]), length(body.length), body]);
}
function oid(dotted) {
  const [first = 0, second = 0, ...rest] = dotted.split(".").map(Number);
  const bytes2 = [first * 40 + second];
  for (const part of rest) {
    const groups = [part & 127];
    for (let left = Math.floor(part / 128); left > 0; left = Math.floor(left / 128))
      groups.unshift(128 | left & 127);
    bytes2.push(...groups);
  }
  return element(TAG.OID, new Uint8Array(bytes2));
}

// node_modules/@workeryard/undershell/src/keys/blowfish-pi.ts
var PI_HEX = "243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89452821e638d01377be5466cf34e90c6cc0ac29b7c97c50dd3f84d5b5b54709179216d5d98979fb1bd1310ba698dfb5ac2ffd72dbd01adfb7b8e1afed6a267e96ba7c9045f12c7f9924a19947b3916cf70801f2e2858efc16636920d871574e69a458fea3f4933d7e0d95748f728eb658718bcd5882154aee7b54a41dc25a59b59c30d5392af26013c5d1b023286085f0ca417918b8db38ef8e79dcb0603a180e6c9e0e8bb01e8a3ed71577c1bd314b2778af2fda55605c60e65525f3aa55ab945748986263e8144055ca396a2aab10b6b4cc5c341141e8cea15486af7c72e993b3ee1411636fbc2a2ba9c55d741831f6ce5c3e169b87931eafd6ba336c24cf5c7a325381289586773b8f48986b4bb9afc4bfe81b6628219361d809ccfb21a991487cac605dec8032ef845d5de98575b1dc262302eb651b8823893e81d396acc50f6d6ff383f442392e0b4482a484200469c8f04a9e1f9b5e21c66842f6e96c9a670c9c61abd388f06a51a0d2d8542f68960fa728ab5133a36eef0b6c137a3be4ba3bf0507efb2a98a1f1651d39af017666ca593e82430e888cee8619456f9fb47d84a5c33b8b5ebee06f75d885c12073401a449f56c16aa64ed3aa62363f77061bfedf72429b023d37d0d724d00a1248db0fead349f1c09b075372c980991b7b25d479d8f6e8def7e3fe501ab6794c3b976ce0bd04c006bac1a94fb6409f60c45e5c9ec2196a246368fb6faf3e6c53b51339b2eb3b52ec6f6dfc511f9b30952ccc814544af5ebd09bee3d004de334afd660f2807192e4bb3c0cba85745c8740fd20b5f39b9d3fbdb5579c0bd1a60320ad6a100c6402c7279679f25fefb1fa3cc8ea5e9f8db3222f83c7516dffd616b152f501ec8ad0552ab323db5fafd23876053317b483e00df829e5c57bbca6f8ca01a87562edf1769dbd542a8f6287effc3ac6732c68c4f5573695b27b0bbca58c8e1ffa35db8f011a010fa3d98fd2183b84afcb56c2dd1d35b9a53e479b6f84565d28e49bc4bfb9790e1ddf2daa4cb7e3362fb1341cee4c6e8ef20cada36774c01d07e9efe2bf11fb495dbda4dae909198eaad8e716b93d5a0d08ed1d0afc725e08e3c5b2f8e7594b78ff6e2fbf2122b648888b812900df01c4fad5ea0688fc31cd1cff191b3a8c1ad2f2f2218be0e1777ea752dfe8b021fa1e5a0cc0fb56f74e818acf3d6ce89e299b4a84fe0fd13e0b77cc43b81d2ada8d9165fa2668095770593cc7314211a1477e6ad206577b5fa86c75442f5fb9d35cfebcdaf0c7b3e89a0d6411bd3ae1e7e4900250e2d2071b35e226800bb57b8e0af2464369bf009b91e5563911d59dfa6aa78c14389d95a537f207d5ba202e5b9c5832603766295cfa911c819684e734a41b3472dca7b14a94a1b5100529a532915d60f573fbc9bc6e42b60a47681e6740008ba6fb5571be91ff296ec6b2a0dd915b6636521e7b9f9b6ff34052ec585566453b02d5da99f8fa108ba47996e85076a4b7a70e9b5b32944db75092ec4192623ad6ea6b049a7df7d9cee60b88fedb266ecaa8c71699a17ff5664526cc2b19ee1193602a575094c29a0591340e4183a3e3f54989a5b429d656b8fe4d699f73fd6a1d29c07efe830f54d2d38e6f0255dc14cdd20868470eb266382e9c6021ecc5e09686b3f3ebaefc93c9718146b6a70a1687f358452a0e286b79c5305aa5007373e07841c7fdeae5c8e7d44ec5716f2b8b03ada37f0500c0df01c1f040200b3ffae0cf51a3cb574b225837a58dc0921bdd19113f97ca92ff69432477322f547013ae5e58137c2dadcc8b576349af3dda7a94461460fd0030eecc8c73ea4751e41e238cd993bea0e2f3280bba1183eb3314e548b384f6db9086f420d03f60a04bf2cb8129024977c795679b072bcaf89afde9a771fd9930810b38bae12dccf3f2e5512721f2e6b7124501adde69f84cd877a5847187408da17bc9f9abce94b7d8cec7aec3adb851dfa63094366c464c3d2ef1c18473215d908dd433b3724c2ba1612a14d432a65c45150940002133ae4dd71dff89e10314e5581ac77d65f11199b043556f1d7a3c76b3c11183b5924a509f28fe6ed97f1fbfa9ebabf2c1e153c6e86e34570eae96fb1860e5e0a5a3e2ab3771fe71c4e3d06fa2965dcb999e71d0f803e89d65266c8252e4cc9789c10b36ac6150eba94e2ea78a5fc3c531e0a2df4f2f74ea7361d2b3d1939260f19c279605223a708f71312b6ebadfe6eeac31f66e3bc4595a67bc883b17f37d1018cff28c332ddefbe6c5aa56558218568ab9802eecea50fdb2f953b2aef7dad5b6e2f841521b62829076170ecdd4775619f151013cca830eb61bd960334fe1eaa0363cfb5735c904c70a239d59e9e0bcbaade14eecc86bc60622ca79cab5cabb2f3846e648b1eaf19bdf0caa02369b9655abb5040685a323c2ab4b3319ee9d5c021b8f79b540b19875fa09995f7997e623d7da8f837889a97e32d7711ed935f166812810e358829c7e61fd696dedfa17858ba9957f584a51b2272639b83c3ff1ac24696cdb30aeb532e30548fd948e46dbc312858ebf2ef34c6ffeafe28ed61ee7c3c735d4a14d9e864b7e342105d14203e13e045eee2b6a3aaabeadb6c4f15facb4fd0c742f442ef6abbb5654f3b1d41cd2105d81e799e86854dc7e44b476a3d816250cf62a1f25b8d2646fc8883a0c1c7b6a37f1524c369cb749247848a0b5692b285095bbf00ad19489d1462b17423820e0058428d2a0c55f5ea1dadf43e233f70613372f0928d937e41d65fecf16c223bdb7cde3759cbee74604085f2a7ce77326ea607808419f8509ee8efd85561d99735a969a7aac50c06c25a04abfc800bcadc9e447a2ec3453484fdd567050e1e9ec9db73dbd3105588cd675fda79e3674340c5c43465713e38d83d28f89ef16dff20153e21e78fb03d4ae6e39f2bdb83adf7e93d5a68948140f7f64c261c94692934411520f77602d4f7bcf46b2ed4a20068d40824713320f46a43b7d4b7500061af1e39f62e9724454614214f74bf8b88404d95fc1d96b591af70f4ddd366a02f45bfbc09ec03bd97857fac6dd031cb850496eb27b355fd3941da2547e6abca0a9a28507825530429f40a2c86dae9b66dfb68dc1462d7486900680ec0a427a18dee4f3ffea2e887ad8cb58ce0067af4d6b6aace1e7cd3375fecce78a399406b2a4220fe9e35d9f385b9ee39d7ab3b124e8b1dc9faf74b6d185626a36631eae397b23a6efa74dd5b43326841e7f7ca7820fbfb0af54ed8feb397454056acba48952755533a3a20838d87fe6ba9b7d096954b55a867bca1159a58cca9296399e1db33a62a4a563f3125f95ef47e1c9029317cfdf8e80204272f7080bb155c05282ce395c11548e4c66d2248c1133fc70f86dc07f9c9ee41041f0f404779a45d886e17325f51ebd59bc0d1f2bcc18f41113564257b7834602a9c60dff8e8a31f636c1b0e12b4c202e1329eaf664fd1cad181156b2395e0333e92e13b240b62eebeb92285b2a20ee6ba0d99de720c8c2da2f728d012784595b794fd647d0862e7ccf5f05449a36f877d48fac39dfd27f33e8d1e0a476341992eff743a6f6eabf4f8fd37a812dc60a1ebddf8991be14cdb6e6b0dc67b55106d672c372765d43bdcd0e804f1290dc7cc00ffa3b5390f92690fed0b667b9ffbcedb7d9ca091cf0bd9155ea3bb132f88515bad247b9479bf763bd6eb37392eb3cc1159798026e297f42e312d6842ada7c66a2b3b12754ccc782ef11c6a124237b79251e706a1bbe64bfb63501a6b101811caedfa3d25bdd8e2e1c3c9444216590a121386d90cec6ed5abea2a64af674eda86a85fbebfe98864e4c3fe9dbc8057f0f7c08660787bf86003604dd1fd8346f6381fb07745ae04d736fccc83426b33f01eab71b08041873c005e5f77a057bebde8ae2455464299bf582e614e58f48ff2ddfda2f474ef388789bdc25366f9c3c8b38e74b475f25546fcd9b97aeb26618b1ddf84846a0e79915f95e2466e598e20b457708cd55591c902de4cb90bace1bb8205d011a862487574a99eb77f19b6e0a9dc09662d09a1c4324633e85a1f0209f0be8c4a99a0251d6efe101ab93d1d0ba5a4dfa186f20f2868f169dcb7da83573906fea1e2ce9b4fcd7f5250115e01a70683faa002b5c40de6d0279af88c27773f8641c3604c0661a806b5f0177a28c0f586e0006058aa30dc7d6211e69ed72338ea6353c2dd94c2c21634bbcbee5690bcb6deebfc7da1ce591d766f05e4094b7c018839720a3d7c927c2486e3725f724d9db91ac15bb4d39eb8fced54557808fca5b5d83d7cd34dad0fc41e50ef5eb161e6f8a28514d96c51133c6fd5c7e756e14ec4362abfceddc6c837d79a323492638212670efa8e406000e03a39ce37d3faf5cfabc277375ac52d1b5cb0679e4fa33742d382274099bc9bbed5118e9dbf0f7315d62d1c7ec700c47bb78c1b6b21a19045b26eb1be6a366eb45748ab2fbc946e79c6a376d26549c2c8530ff8ee468dde7dd5730a1d4cd04dc62939bbdba9ba4650ac9526e8be5ee304a1fad5f06a2d519a63ef8ce29a86ee22c089c2b843242ef6a51e03aa9cf2d0a483c061ba9be96a4d8fe51550ba645bd62826a2f9a73a3ae14ba99586ef5562e9c72fefd3f752f7da3f046f6977fa0a5980e4a91587b086019b09e6ad3b3ee593e990fd5a9e34d7972cf0b7d9022b8b5196d5ac3a017da67dd1cf3ed67c7d2d281f9f25cfadf2b89b5ad6b4725a88f54ce029ac71e019a5e647b0acfded93fa9be8d3c48d283b57ccf8d5662979132e28785f0191ed756055f7960e44e3d35e8c15056dd488f46dba03a161250564f0bdc3eb9e153c9057a297271aeca93a072a1b3f6d9b1e6321f5f59c66fb26dcf3197533d928b155fdf5035634828aba3cbb28517711c20ad9f8abcc5167ccad925f4de817513830dc8e379d58629320f991ea7a90c2fb3e7bce5121ce64774fbe32a8b6e37ec3293d4648de53696413e680a2ae0810dd6db22469852dfd09072166b39a460a6445c0dd586cdecf1c20c8ae5bbef7dd1b588d40ccd2017f6bb4e3bbdda26a7e3a59ff453e350a44bcb4cdd572eacea8fa6484bb8d6612aebf3c6f47d29be463542f5d9eaec2771bf64e6370740e0d8de75b1357f8721671af537d5d4040cb084eb4e2cc34d2466a0115af84e1b0042895983a1d06b89fb4ce6ea0486f3f3b823520ab82011a1d4b277227f8611560b1e7933fdcbb3a792b344525bda08839e151ce794b2f32c9b7a01fbac9e01cc87ebcc7d1f6cf0111c3a1e8aac71a908749d44fbd9ad0dadecbd50ada380339c32ac69136678df9317ce0b12b4ff79e59b743f5bb3af2d519ff27d9459cbf97222c15e6fc2a0f91fc719b941525fae59361ceb69cebc2a8645912baa8d1b6c1075ee3056a0c10d25065cb03a442e0ec6e0e1698db3b4c98a0be3278e9649f1f9532e0d392dfd3a0342b8971f21e1b0a74414ba3348cc5be7120c37632d8df359f8d9b992f2ee60b6f470fe3f11de54cda541edad891ce6279cfcd3e7e6f1618b166fd2c1d05848fd2c5f6fb2299f523f357a632762393a8353156cccd02acf081625a75ebb56e16369788d273ccde96629281b949d04c50901b71c65614e6c6c7bd327a140a45e1d006c3f27b9ac9aa53fd62a80f00bb25bfe235bdd2f671126905b2040222b6cbcf7ccd769c2b53113ec01640e3d338abbd602547adf0ba38209cf746ce7677afa1c52075606085cbfe4e8ae88dd87aaaf9b04cf9aa7e1948c25c02fb8a8c01c36ae4d6ebe1f990d4f869a65cdea03f09252dc208e69fb74e6132ce77e25b578fdfe33ac372e6";

// node_modules/@workeryard/undershell/src/keys/bcrypt-pbkdf.ts
var MAGIC = new TextEncoder().encode("OxychromaticBlowfishSwatDynamite");
var HASH_LENGTH = 32;
var Blowfish = class {
  p = new Uint32Array(18);
  s = new Uint32Array(1024);
  constructor() {
    for (let index = 0; index < 18; index++)
      this.p[index] = parseInt(PI_HEX.slice(index * 8, index * 8 + 8), 16);
    for (let index = 0; index < 1024; index++) {
      const at = (18 + index) * 8;
      this.s[index] = parseInt(PI_HEX.slice(at, at + 8), 16);
    }
  }
  #f(x) {
    const s = this.s;
    return (s[x >>> 24] + s[256 + (x >>> 16 & 255)] ^ s[512 + (x >>> 8 & 255)]) + s[768 + (x & 255)] >>> 0;
  }
  /** Enciphers block[at], block[at + 1] in place. */
  encipher(block, at) {
    const p = this.p;
    let left = block[at] ^ p[0];
    let right = block[at + 1];
    for (let round = 1; round <= 16; round += 2) {
      right ^= this.#f(left) ^ p[round];
      left ^= this.#f(right) ^ p[round + 1];
    }
    block[at] = (right ^ p[17]) >>> 0;
    block[at + 1] = left >>> 0;
  }
  /**
   * The bcrypt key schedule. With `data` it is Blowfish_expandstate, salting
   * every block; without, Blowfish_expand0state.
   */
  expand(key, data) {
    const keyStream = words(key);
    for (let index = 0; index < 18; index++) this.p[index] = (this.p[index] ^ keyStream()) >>> 0;
    const dataStream = data ? words(data) : () => 0;
    const block = new Uint32Array(2);
    const fill = (table, length2) => {
      for (let index = 0; index < length2; index += 2) {
        block[0] = (block[0] ^ dataStream()) >>> 0;
        block[1] = (block[1] ^ dataStream()) >>> 0;
        this.encipher(block, 0);
        table[index] = block[0];
        table[index + 1] = block[1];
      }
    };
    fill(this.p, 18);
    fill(this.s, 1024);
  }
};
function words(bytes2) {
  let at = 0;
  return () => {
    let word = 0;
    for (let index = 0; index < 4; index++) {
      word = (word << 8 | bytes2[at]) >>> 0;
      at = (at + 1) % bytes2.length;
    }
    return word;
  };
}
function bcryptHash(sha2pass, sha2salt) {
  const state = new Blowfish();
  state.expand(sha2pass, sha2salt);
  for (let round = 0; round < 64; round++) {
    state.expand(sha2salt);
    state.expand(sha2pass);
  }
  const block = new Uint32Array(8);
  const next = words(MAGIC);
  for (let index = 0; index < 8; index++) block[index] = next();
  for (let round = 0; round < 64; round++)
    for (let at = 0; at < 8; at += 2) state.encipher(block, at);
  const out = new Uint8Array(HASH_LENGTH);
  const view = new DataView(out.buffer);
  for (let index = 0; index < 8; index++) view.setUint32(index * 4, block[index], true);
  return out;
}
async function bcryptPbkdf(passphrase, salt, length2, rounds) {
  if (rounds < 1) throw new Error("bcrypt_pbkdf needs at least one round");
  if (passphrase.length === 0 || salt.length === 0)
    throw new Error("bcrypt_pbkdf needs a passphrase and a salt");
  if (length2 < 1 || length2 > HASH_LENGTH * HASH_LENGTH)
    throw new Error(`bcrypt_pbkdf cannot make ${length2} bytes`);
  const stride = Math.ceil(length2 / HASH_LENGTH);
  const perBlock = Math.ceil(length2 / stride);
  const key = new Uint8Array(length2);
  const sha2pass = await digest("SHA-512", passphrase);
  for (let count = 1, left = length2; left > 0; count++) {
    let tmp = bcryptHash(
      sha2pass,
      await digest("SHA-512", concat([salt, new Writer().uint32(count).build()]))
    );
    const out = new Uint8Array(tmp);
    for (let round = 1; round < rounds; round++) {
      tmp = bcryptHash(sha2pass, await digest("SHA-512", tmp));
      for (let index = 0; index < HASH_LENGTH; index++) out[index] ^= tmp[index];
    }
    let placed = 0;
    for (; placed < Math.min(perBlock, left); placed++) {
      const at = placed * stride + (count - 1);
      if (at >= length2) break;
      key[at] = out[placed];
    }
    left -= placed;
  }
  return key;
}

// node_modules/@workeryard/undershell/src/keys/public-key.ts
var CURVES = {
  "ecdsa-sha2-nistp256": { id: "nistp256", webCrypto: "P-256", hash: "SHA-256", size: 32 },
  "ecdsa-sha2-nistp384": { id: "nistp384", webCrypto: "P-384", hash: "SHA-384", size: 48 },
  "ecdsa-sha2-nistp521": { id: "nistp521", webCrypto: "P-521", hash: "SHA-512", size: 66 }
};
var MIN_RSA_BITS = 1024;
async function fingerprintOf(blob) {
  return base64(await digest("SHA-256", blob)).replace(/=+$/, "");
}
function blobType(blob) {
  return new Reader(blob).text();
}
function rsaHash(algorithm) {
  if (algorithm === "rsa-sha2-256") return "SHA-256";
  if (algorithm === "rsa-sha2-512") return "SHA-512";
  return null;
}
function bitLength(value) {
  let start = 0;
  while (start < value.length && value[start] === 0) start++;
  if (start === value.length) return 0;
  return (value.length - start - 1) * 8 + (32 - Math.clz32(value[start]));
}
function ecdsaToSsh(signature2) {
  const half = signature2.length / 2;
  return new Writer().mpint(signature2.subarray(0, half)).mpint(signature2.subarray(half)).build();
}
function sshToEcdsa(blob, size) {
  const reader = new Reader(blob);
  const r = reader.mpint();
  const s = reader.mpint();
  return concat([fixedLength(r, size), fixedLength(s, size)]);
}
async function importPublicKey(algorithm, blob) {
  const reader = new Reader(blob);
  const type = reader.text();
  if (algorithm === "ssh-ed25519") {
    if (type !== "ssh-ed25519") throw new Error(`the key is a ${type}, not the ssh-ed25519 agreed`);
    const raw = reader.string();
    if (raw.length !== 32) throw new Error(`an ed25519 key of ${raw.length} bytes`);
    const key = await subtle.importKey("raw", raw, { name: "Ed25519" }, false, ["verify"]);
    return { key, verify: { name: "Ed25519" } };
  }
  const curve = CURVES[algorithm];
  if (curve) {
    if (type !== algorithm) throw new Error(`the key is a ${type}, not the ${algorithm} agreed`);
    const id = reader.text();
    if (id !== curve.id) throw new Error(`a ${algorithm} key on the curve ${id}`);
    const point = reader.string();
    const key = await subtle.importKey(
      "raw",
      point,
      { name: "ECDSA", namedCurve: curve.webCrypto },
      false,
      ["verify"]
    );
    return { key, verify: { name: "ECDSA", hash: curve.hash } };
  }
  const hash = rsaHash(algorithm);
  if (hash) {
    if (type !== "ssh-rsa") throw new Error(`the key is a ${type}, not the RSA agreed`);
    const exponent = reader.mpint();
    const modulus = reader.mpint();
    const bits = bitLength(modulus);
    if (bits < MIN_RSA_BITS)
      throw new Error(`an RSA key of ${bits} bits, below the ${MIN_RSA_BITS} accepted`);
    const key = await subtle.importKey(
      "jwk",
      {
        kty: "RSA",
        n: base64Url(modulus),
        e: base64Url(exponent),
        alg: hash === "SHA-512" ? "RS512" : "RS256"
      },
      { name: "RSASSA-PKCS1-v1_5", hash },
      false,
      ["verify"]
    );
    return { key, verify: { name: "RSASSA-PKCS1-v1_5" } };
  }
  throw new Error(`${algorithm} is not a signature this client can check`);
}
async function verifySignature(algorithm, blob, signature2, data) {
  const signed = new Reader(signature2);
  const signatureType = signed.text();
  if (signatureType !== algorithm) {
    throw new Error(`the signature is a ${signatureType}, not the ${algorithm} that was agreed`);
  }
  let bytes2 = signed.string();
  const { key, verify } = await importPublicKey(algorithm, blob);
  const curve = CURVES[algorithm];
  if (curve) bytes2 = sshToEcdsa(bytes2, curve.size);
  return subtle.verify(verify, key, bytes2, data);
}
function openSshPublicKey(blob) {
  return `${blobType(blob)} ${base64(blob)}`;
}

// node_modules/@workeryard/undershell/src/keys/private-key.ts
var signature = (algorithm, bytes2) => new Writer().string(algorithm).string(bytes2).build();
var ED25519_PKCS8 = new Uint8Array([
  48,
  46,
  2,
  1,
  0,
  48,
  5,
  6,
  3,
  43,
  101,
  112,
  4,
  34,
  4,
  32
]);
async function ed25519Key(seed, publicKey2) {
  if (seed.length !== 32 || publicKey2.length !== 32)
    throw new Error("an ed25519 key that is not 32 bytes");
  const pkcs82 = new Uint8Array(ED25519_PKCS8.length + 32);
  pkcs82.set(ED25519_PKCS8);
  pkcs82.set(seed, ED25519_PKCS8.length);
  const key = await subtle.importKey("pkcs8", pkcs82, { name: "Ed25519" }, false, ["sign"]);
  return {
    type: "ssh-ed25519",
    publicKeyBlob: new Writer().string("ssh-ed25519").string(publicKey2).build(),
    algorithms: ["ssh-ed25519"],
    async sign(_algorithm, data) {
      return signature(
        "ssh-ed25519",
        new Uint8Array(await subtle.sign({ name: "Ed25519" }, key, data))
      );
    }
  };
}
var toBig = (bytes2) => BigInt(`0x${[...bytes2].map((b) => b.toString(16).padStart(2, "0")).join("") || "0"}`);
function fromBig(value) {
  let hex = value.toString(16);
  if (hex.length % 2) hex = `0${hex}`;
  return new Uint8Array(hex.match(/../g).map((pair) => parseInt(pair, 16)));
}
async function rsaKey(numbers) {
  const d = toBig(numbers.d);
  const jwk = {
    kty: "RSA",
    n: base64Url(numbers.n),
    e: base64Url(numbers.e),
    d: base64Url(numbers.d),
    p: base64Url(numbers.p),
    q: base64Url(numbers.q),
    // OpenSSH's file has no CRT exponents; WebCrypto wants them.
    dp: base64Url(fromBig(d % (toBig(numbers.p) - 1n))),
    dq: base64Url(fromBig(d % (toBig(numbers.q) - 1n))),
    qi: base64Url(numbers.qi)
  };
  const keys = {
    "rsa-sha2-512": await subtle.importKey(
      "jwk",
      { ...jwk, alg: "RS512" },
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-512" },
      false,
      ["sign"]
    ),
    "rsa-sha2-256": await subtle.importKey(
      "jwk",
      { ...jwk, alg: "RS256" },
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"]
    )
  };
  return {
    type: "ssh-rsa",
    publicKeyBlob: new Writer().string("ssh-rsa").mpint(numbers.e).mpint(numbers.n).build(),
    algorithms: ["rsa-sha2-512", "rsa-sha2-256"],
    async sign(algorithm, data) {
      const key = keys[algorithm];
      if (!key)
        throw new Error(`an RSA key does not sign ${algorithm} here; SHA-1 ssh-rsa is not offered`);
      return signature(
        algorithm,
        new Uint8Array(await subtle.sign({ name: "RSASSA-PKCS1-v1_5" }, key, data))
      );
    }
  };
}
async function ecdsaKey(type, point, scalar) {
  const curve = CURVES[type];
  if (!curve) throw new Error(`${type} is not an ECDSA key this client signs with`);
  if (point.length !== 1 + 2 * curve.size || point[0] !== 4)
    throw new Error(`a ${type} public key that is not an uncompressed point`);
  const key = await subtle.importKey(
    "jwk",
    {
      kty: "EC",
      crv: curve.webCrypto,
      x: base64Url(point.subarray(1, 1 + curve.size), true),
      y: base64Url(point.subarray(1 + curve.size), true),
      d: base64Url(fixedLength(scalar, curve.size), true)
    },
    { name: "ECDSA", namedCurve: curve.webCrypto },
    false,
    ["sign"]
  );
  return {
    type,
    publicKeyBlob: new Writer().string(type).string(curve.id).string(point).build(),
    algorithms: [type],
    async sign(_algorithm, data) {
      const raw = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: curve.hash }, key, data));
      return signature(type, ecdsaToSsh(raw));
    }
  };
}

// node_modules/@workeryard/undershell/src/keys/openssh.ts
var MAGIC2 = "openssh-key-v1\0";
var CIPHERS = {
  "aes256-ctr": { keyLength: 32, ivLength: 16, gcm: false },
  "aes192-ctr": { keyLength: 24, ivLength: 16, gcm: false },
  "aes128-ctr": { keyLength: 16, ivLength: 16, gcm: false },
  "aes256-gcm@openssh.com": { keyLength: 32, ivLength: 12, gcm: true },
  "aes128-gcm@openssh.com": { keyLength: 16, ivLength: 12, gcm: true }
};
async function unlock(section, tag, cipher, kdf, options, passphrase) {
  const spec = CIPHERS[cipher];
  if (!spec) throw new Error(`the key is encrypted with ${cipher}, which this client cannot read`);
  if (kdf !== "bcrypt")
    throw new Error(`the key uses the ${kdf} derivation, which this client cannot read`);
  if (!passphrase) throw new Error("the key has a passphrase, and none was given");
  const reader = new Reader(options);
  const salt = reader.string();
  const rounds = reader.uint32();
  const material = await bcryptPbkdf(
    // Copied: a Worker's TextEncoder may hand back a view WebCrypto will not take.
    new Uint8Array(new TextEncoder().encode(passphrase)),
    salt,
    spec.keyLength + spec.ivLength,
    rounds
  );
  const raw = material.subarray(0, spec.keyLength);
  const iv = material.subarray(spec.keyLength);
  if (spec.gcm) {
    const key2 = await subtle.importKey("raw", raw, { name: "AES-GCM" }, false, ["decrypt"]);
    const sealed = new Uint8Array(section.length + tag.length);
    sealed.set(section);
    sealed.set(tag, section.length);
    const plain = await subtle.decrypt({ name: "AES-GCM", iv }, key2, sealed).catch(() => {
      throw new Error("the passphrase does not open this key");
    });
    return new Uint8Array(plain);
  }
  const key = await subtle.importKey("raw", raw, { name: "AES-CTR" }, false, ["decrypt"]);
  return new Uint8Array(
    await subtle.decrypt({ name: "AES-CTR", counter: iv, length: 128 }, key, section)
  );
}
function isOpenSshKey(der) {
  return new TextDecoder().decode(der.subarray(0, MAGIC2.length)) === MAGIC2;
}
async function parseOpenSshKey(der, passphrase) {
  if (!isOpenSshKey(der)) throw new Error("not an OpenSSH private key");
  const reader = new Reader(der);
  reader.take(MAGIC2.length);
  const cipher = reader.text();
  const kdf = reader.text();
  const kdfOptions = reader.string();
  const locked = cipher !== "none";
  const count = reader.uint32();
  if (count !== 1) throw new Error(`expected one key in the file, found ${count}`);
  const publicKeyBlob = reader.string();
  const section = reader.string();
  const tag = locked && CIPHERS[cipher]?.gcm ? reader.take(16) : new Uint8Array(0);
  const secret = new Reader(
    locked ? await unlock(section, tag, cipher, kdf, kdfOptions, passphrase) : section
  );
  if (secret.uint32() !== secret.uint32()) {
    throw new Error(
      locked ? "the passphrase does not open this key" : "the key did not decrypt (check values differ)"
    );
  }
  const type = secret.text();
  let key;
  if (type === "ssh-ed25519") {
    const publicKey2 = secret.string();
    const both = secret.string();
    if (both.length !== 64) throw new Error(`expected a 64-byte private part, got ${both.length}`);
    key = await ed25519Key(both.slice(0, 32), publicKey2.slice());
  } else if (type === "ssh-rsa") {
    const n = secret.mpint();
    const e = secret.mpint();
    const d = secret.mpint();
    const qi = secret.mpint();
    const p = secret.mpint();
    const q = secret.mpint();
    key = await rsaKey({ n, e, d, p, q, qi });
  } else if (type.startsWith("ecdsa-sha2-")) {
    secret.skipString();
    const point = secret.string();
    key = await ecdsaKey(type, point.slice(), secret.mpint().slice());
  } else {
    throw new Error(`${type} keys are not read here; ed25519, RSA and ECDSA are`);
  }
  secret.skipString();
  const padding = secret.rest();
  if (padding.some((byte, index) => byte !== index + 1))
    throw new Error("the key has corrupt padding");
  if (!sameBytes(key.publicKeyBlob, publicKeyBlob)) {
    throw new Error("the key's private half does not match the public key stored with it");
  }
  return key;
}
function sameBytes(a, b) {
  return a.length === b.length && a.every((byte, index) => byte === b[index]);
}

// node_modules/@workeryard/undershell/src/keys/pem.ts
var RSA = "1.2.840.113549.1.1.1";
var EC = "1.2.840.10045.2.1";
var ED25519 = "1.3.101.112";
var NAMED_CURVES = {
  "1.2.840.10045.3.1.7": "ecdsa-sha2-nistp256",
  "1.3.132.0.34": "ecdsa-sha2-nistp384",
  "1.3.132.0.35": "ecdsa-sha2-nistp521"
};
function pkcs1(der) {
  const key = new Der(der).sequence();
  key.integer();
  const n = key.integer();
  const e = key.integer();
  const d = key.integer();
  const p = key.integer();
  const q = key.integer();
  key.integer();
  key.integer();
  return rsaKey({ n, e, d, p, q, qi: key.integer() });
}
async function sec1(der, curveOid) {
  const key = new Der(der).sequence();
  key.integer();
  const scalar = key.octetString();
  let named = curveOid;
  let point;
  while (!key.done) {
    const { tag, content } = key.next();
    if (tag === 160) named = new Der(content).oid();
    if (tag === 161) point = new Der(content).next(TAG.BIT_STRING).content.subarray(1);
  }
  const type = named && NAMED_CURVES[named];
  if (!type)
    throw new Error(
      `the EC key is on a curve this client does not sign with (${named ?? "unnamed"})`
    );
  if (!point) {
    const pkcs82 = element(
      TAG.SEQUENCE,
      element(TAG.INTEGER, new Uint8Array([0])),
      element(TAG.SEQUENCE, oid(EC), oid(named)),
      element(TAG.OCTET_STRING, der)
    );
    const curve = { name: "ECDSA", namedCurve: `P-${type.slice(-3)}` };
    const jwk = await subtle.exportKey(
      "jwk",
      await subtle.importKey("pkcs8", pkcs82, curve, true, ["sign"])
    );
    point = new Uint8Array([4, ...fromBase64(jwk.x), ...fromBase64(jwk.y)]);
  }
  return ecdsaKey(type, point, scalar);
}
async function pkcs8(der) {
  const outer = new Der(der).sequence();
  outer.integer();
  const algorithm = outer.sequence();
  const kind = algorithm.oid();
  const inner = outer.octetString();
  if (kind === RSA) return pkcs1(inner);
  if (kind === EC) return sec1(inner, algorithm.oid());
  if (kind === ED25519) {
    const seed = new Der(inner).octetString();
    const jwk = await subtle.exportKey(
      "jwk",
      await subtle.importKey("pkcs8", der, { name: "Ed25519" }, true, ["sign"])
    );
    return ed25519Key(seed.slice(), fromBase64(jwk.x));
  }
  throw new Error(`the PKCS#8 key is a ${kind}, which this client does not sign with`);
}
async function parsePrivateKey(text, passphrase = "") {
  const match = /-----BEGIN ([A-Z0-9 ]+)-----([\s\S]*?)-----END \1-----/.exec(text);
  if (!match) {
    if (/PuTTY-User-Key-File/.test(text)) {
      throw new Error("this is a PuTTY key; export it from PuTTYgen as an OpenSSH key first");
    }
    throw new Error("no PEM private key was found in the text");
  }
  const [, label, body = ""] = match;
  if (/Proc-Type:\s*4,ENCRYPTED/.test(body) || label === "ENCRYPTED PRIVATE KEY") {
    throw new Error(
      "the PEM key is encrypted, which only OpenSSH files are here; ssh-keygen -p -f <file> rewrites it as one"
    );
  }
  const der = fromBase64(body.replace(/^[A-Za-z-]+:.*$/gm, ""));
  switch (label) {
    case "OPENSSH PRIVATE KEY":
      return parseOpenSshKey(der, passphrase);
    case "RSA PRIVATE KEY":
      return pkcs1(der);
    case "EC PRIVATE KEY":
      return sec1(der);
    case "PRIVATE KEY":
      return isOpenSshKey(der) ? parseOpenSshKey(der, passphrase) : pkcs8(der);
    default:
      throw new Error(`a "${label}" is not a private key this client reads`);
  }
}

// node_modules/@workeryard/undershell/src/transport/messages.ts
var MSG = {
  DISCONNECT: 1,
  IGNORE: 2,
  UNIMPLEMENTED: 3,
  DEBUG: 4,
  SERVICE_REQUEST: 5,
  SERVICE_ACCEPT: 6,
  EXT_INFO: 7,
  KEXINIT: 20,
  NEWKEYS: 21,
  KEX_ECDH_INIT: 30,
  KEX_ECDH_REPLY: 31,
  USERAUTH_REQUEST: 50,
  USERAUTH_FAILURE: 51,
  USERAUTH_SUCCESS: 52,
  USERAUTH_BANNER: 53,
  /** Also USERAUTH_PK_OK and USERAUTH_PASSWD_CHANGEREQ: 60 means what the method in progress says. */
  USERAUTH_INFO_REQUEST: 60,
  USERAUTH_INFO_RESPONSE: 61,
  GLOBAL_REQUEST: 80,
  REQUEST_SUCCESS: 81,
  REQUEST_FAILURE: 82,
  CHANNEL_OPEN: 90,
  CHANNEL_OPEN_CONFIRMATION: 91,
  CHANNEL_OPEN_FAILURE: 92,
  CHANNEL_WINDOW_ADJUST: 93,
  CHANNEL_DATA: 94,
  CHANNEL_EXTENDED_DATA: 95,
  CHANNEL_EOF: 96,
  CHANNEL_CLOSE: 97,
  CHANNEL_REQUEST: 98,
  CHANNEL_SUCCESS: 99,
  CHANNEL_FAILURE: 100
};
function toError(value) {
  return value instanceof Error ? value : new Error(String(value));
}
function disconnected(payload) {
  const reader = new Reader(payload.subarray(1));
  const code = reader.uint32();
  return new Error(`the server disconnected (reason ${code}): ${reader.text()}`);
}
function serverSignatureAlgorithms(payload) {
  const reader = new Reader(payload.subarray(1));
  const count = reader.uint32();
  let found = null;
  for (let index = 0; index < count; index++) {
    const name = reader.text();
    const value = reader.text();
    if (name === "server-sig-algs") found = value.split(",");
  }
  return found;
}

// node_modules/@workeryard/undershell/src/auth.ts
var SERVICE = "ssh-connection";
var MAX_ROUNDS = 16;
var AuthenticationError = class extends Error {
  constructor(message, methods) {
    super(message);
    this.methods = methods;
  }
  name = "AuthenticationError";
};
function failure(payload) {
  const reader = new Reader(payload.subarray(1));
  return { ok: false, methods: reader.nameList(), partial: reader.bool() };
}
var METHOD = {
  none: "none",
  password: "password",
  privateKey: "publickey",
  keyboardInteractive: "keyboard-interactive"
};
async function authenticate(transport, username, methods, onBanner) {
  if (methods.length === 0) throw new Error("no authentication method was given");
  await transport.send(new Writer().byte(MSG.SERVICE_REQUEST).string("ssh-userauth").build());
  const accepted = await transport.receive();
  if (accepted[0] !== MSG.SERVICE_ACCEPT)
    throw new Error(`the server refused ssh-userauth (message ${accepted[0]})`);
  const request = (method) => new Writer().byte(MSG.USERAUTH_REQUEST).string(username).string(SERVICE).string(method);
  const answer = async (sixty) => {
    for (; ; ) {
      const reply = await transport.receive();
      const type = reply[0];
      if (type === MSG.USERAUTH_BANNER) {
        onBanner?.(new Reader(reply.subarray(1)).text());
        continue;
      }
      if (type === MSG.USERAUTH_SUCCESS) return { ok: true };
      if (type === MSG.USERAUTH_FAILURE) return failure(reply);
      if (type === MSG.USERAUTH_INFO_REQUEST && sixty) {
        await sixty(reply);
        continue;
      }
      throw new Error(`unexpected message ${type} while authenticating`);
    }
  };
  const attempt = async (auth) => {
    switch (auth.kind) {
      case "none":
        await transport.send(request("none").build());
        return answer();
      case "password":
        await transport.send(request("password").bool(false).string(auth.password).build());
        return answer(() => {
          throw new AuthenticationError(
            `the server wants the password for "${username}" changed first`,
            []
          );
        });
      case "privateKey":
        return publicKey(transport, request, answer, auth);
      case "keyboardInteractive": {
        await transport.send(request("keyboard-interactive").string("").string("").build());
        let rounds = 0;
        return answer(async (payload) => {
          if (++rounds > MAX_ROUNDS)
            throw new Error(
              `the server asked ${MAX_ROUNDS} rounds of questions and was still asking`
            );
          const reader = new Reader(payload.subarray(1));
          const challenge = {
            name: reader.text(),
            instruction: reader.text(),
            prompts: []
          };
          reader.skipString();
          const count = reader.uint32();
          for (let index = 0; index < count; index++)
            challenge.prompts.push({ text: reader.text(), echo: reader.bool() });
          const answers = count === 0 ? [] : await auth.respond(challenge);
          if (answers.length !== count)
            throw new Error(`${answers.length} answers were given to ${count} prompts`);
          const response = new Writer().byte(MSG.USERAUTH_INFO_RESPONSE).uint32(count);
          for (const text of answers) response.string(text);
          await transport.send(response.build());
        });
      }
    }
  };
  let allowed = [];
  let partial = false;
  for (const auth of methods) {
    if (allowed.length && auth.kind !== "none" && !allowed.includes(METHOD[auth.kind])) continue;
    const outcome = await attempt(auth);
    if (outcome.ok) return;
    allowed = outcome.methods;
    partial ||= outcome.partial;
  }
  const tried = methods.map((auth) => METHOD[auth.kind]).join(", ");
  throw new AuthenticationError(
    `the server did not accept ${tried} for "${username}"${partial ? " (some only in part)" : ""}; it will accept ${allowed.join(", ") || "nothing more"}`,
    allowed
  );
}
async function publicKey(transport, request, answer, auth) {
  const key = typeof auth.privateKey === "string" ? await parsePrivateKey(auth.privateKey, auth.passphrase) : auth.privateKey;
  const said = transport.serverSignatureAlgorithms;
  const listed = said && key.type === "ssh-rsa" ? key.algorithms.filter((name) => said.includes(name)) : [];
  const algorithms = listed.length ? listed : key.algorithms;
  let outcome = { ok: false, methods: [], partial: false };
  for (const algorithm of algorithms) {
    const body = request("publickey").bool(true).string(algorithm).string(key.publicKeyBlob).build();
    const signed = new Writer().string(transport.sessionId).raw(body).build();
    await transport.send(
      new Writer().raw(body).string(await key.sign(algorithm, signed)).build()
    );
    outcome = await answer();
    if (outcome.ok || !outcome.methods.includes("publickey")) return outcome;
  }
  return outcome;
}

// node_modules/@workeryard/undershell/src/connection/channel.ts
var WINDOW = 2 * 1024 * 1024;
var MAX_PACKET = 32 * 1024;
var Inbox = class {
  constructor(credit) {
    this.credit = credit;
    this.stream = new ReadableStream(
      {
        pull: async (controller) => {
          while (this.#chunks.length === 0 && !this.#ended) {
            await new Promise((resolve) => this.#wake = resolve);
          }
          const chunk = this.#chunks.shift();
          if (chunk) {
            controller.enqueue(chunk);
            credit(chunk.length);
          } else if (this.#error) controller.error(this.#error);
          else controller.close();
        },
        cancel: () => {
          this.#cancelled = true;
          credit(this.#chunks.reduce((sum, chunk) => sum + chunk.length, 0));
          this.#chunks = [];
        }
      },
      // Nothing is pulled ahead of the reader, or the window would mean nothing.
      { highWaterMark: 0 }
    );
  }
  #chunks = [];
  #wake = null;
  #ended = false;
  #error = null;
  #cancelled = false;
  stream;
  push(chunk) {
    if (this.#cancelled || this.#ended) {
      this.credit(chunk.length);
      return;
    }
    this.#chunks.push(chunk);
    this.#wake?.();
  }
  end(error) {
    if (this.#ended) return;
    this.#ended = true;
    this.#error = error ?? null;
    this.#wake?.();
  }
};
var Channel = class {
  constructor(host, id, remoteId, remoteWindow, remoteMaxPacket) {
    this.host = host;
    this.id = id;
    this.remoteId = remoteId;
    this.#remoteWindow = remoteWindow;
    this.#remoteMax = Math.max(1, Math.min(remoteMaxPacket, MAX_PACKET));
    this.closed = new Promise((resolve) => this.#settle = resolve);
    const credit = (bytes2) => this.#credit(bytes2);
    this.#data = new Inbox(credit);
    this.#extended = new Inbox(credit);
    this.readable = this.#data.stream;
    this.stderr = this.#extended.stream;
    this.writable = new WritableStream({
      write: (chunk) => this.#write(chunk),
      close: () => this.eof(),
      abort: () => this.close()
    });
  }
  readable;
  /** Extended data of type 1, which a session's command writes as stderr. */
  stderr;
  writable;
  /** Settles once both sides have closed, with whatever exit the server reported. */
  closed;
  #remoteWindow;
  #remoteMax;
  #unacknowledged = 0;
  #localWindow = WINDOW;
  #windowWaiters = [];
  #replies = [];
  #eofSent = false;
  #closeSent = false;
  #done = false;
  #error = null;
  #exit = { code: null };
  #settle;
  #data;
  #extended;
  #send(payload) {
    void this.host.send(payload).catch((error) => this.host.fail(error));
  }
  #credit(bytes2) {
    if (this.#done || bytes2 === 0) return;
    this.#unacknowledged += bytes2;
    if (this.#unacknowledged >= WINDOW / 2) {
      this.#localWindow += this.#unacknowledged;
      this.#send(
        new Writer().byte(MSG.CHANNEL_WINDOW_ADJUST).uint32(this.remoteId).uint32(this.#unacknowledged).build()
      );
      this.#unacknowledged = 0;
    }
  }
  async #write(chunk) {
    for (let at = 0; at < chunk.length; ) {
      while (this.#remoteWindow === 0 && !this.#done)
        await new Promise((resolve) => this.#windowWaiters.push(resolve));
      if (this.#done || this.#eofSent)
        throw this.#error ?? new Error("the channel is closed");
      const size = Math.min(chunk.length - at, this.#remoteWindow, this.#remoteMax);
      this.#remoteWindow -= size;
      const data = new Writer().byte(MSG.CHANNEL_DATA).uint32(this.remoteId).string(chunk.subarray(at, at + size)).build();
      await this.host.send(data);
      at += size;
    }
  }
  /** A channel request (RFC 4254 §5.4); with `wantReply`, whether the server agreed. */
  async request(type, wantReply, data = new Uint8Array(0)) {
    if (this.#done) throw this.#error ?? new Error("the channel is closed");
    const reply = wantReply ? new Promise((resolve) => this.#replies.push(resolve)) : Promise.resolve(true);
    await this.host.send(
      new Writer().byte(MSG.CHANNEL_REQUEST).uint32(this.remoteId).string(type).bool(wantReply).raw(data).build()
    );
    return reply;
  }
  /** Says nothing more will be sent; the other direction stays open. */
  async eof() {
    if (this.#eofSent || this.#closeSent) return;
    this.#eofSent = true;
    await this.host.send(new Writer().byte(MSG.CHANNEL_EOF).uint32(this.remoteId).build());
  }
  /** Closes both directions and waits for the server to close its side. */
  async close() {
    if (!this.#closeSent && !this.#done) {
      this.#closeSent = true;
      await this.host.send(new Writer().byte(MSG.CHANNEL_CLOSE).uint32(this.remoteId).build()).catch(() => {
      });
    }
    await this.closed;
  }
  /** A message the connection routed here, the recipient channel already read. */
  handle(type, reader) {
    switch (type) {
      case MSG.CHANNEL_DATA:
        return this.#arrived(this.#data, reader.string());
      case MSG.CHANNEL_EXTENDED_DATA: {
        const code = reader.uint32();
        const data = reader.string();
        if (code === 1) this.#arrived(this.#extended, data);
        else this.#arrived(null, data);
        return;
      }
      case MSG.CHANNEL_WINDOW_ADJUST:
        this.#remoteWindow = Math.min(this.#remoteWindow + reader.uint32(), 2 ** 32 - 1);
        for (const wake of this.#windowWaiters.splice(0)) wake();
        return;
      case MSG.CHANNEL_EOF:
        this.#data.end();
        this.#extended.end();
        return;
      case MSG.CHANNEL_REQUEST:
        return this.#requested(reader);
      case MSG.CHANNEL_SUCCESS:
      case MSG.CHANNEL_FAILURE:
        this.#replies.shift()?.(type === MSG.CHANNEL_SUCCESS);
        return;
      case MSG.CHANNEL_CLOSE:
        if (!this.#closeSent) {
          this.#closeSent = true;
          this.#send(new Writer().byte(MSG.CHANNEL_CLOSE).uint32(this.remoteId).build());
        }
        return this.end();
      default:
        throw new Error(`unexpected message ${type} on channel ${this.id}`);
    }
  }
  #arrived(inbox, data) {
    this.#localWindow -= data.length;
    if (this.#localWindow < 0) throw new Error(`the server overran channel ${this.id}'s window`);
    if (inbox) inbox.push(data.slice());
    else this.#credit(data.length);
  }
  #requested(reader) {
    const type = reader.text();
    const wantReply = reader.bool();
    if (type === "exit-status") this.#exit.code = reader.uint32();
    else if (type === "exit-signal") {
      this.#exit.signal = reader.text();
      this.#exit.coreDumped = reader.bool();
      const message = reader.text();
      if (message) this.#exit.message = message;
    }
    if (wantReply) this.#send(new Writer().byte(MSG.CHANNEL_FAILURE).uint32(this.remoteId).build());
  }
  /** The channel is over, cleanly or because the connection failed. */
  end(error) {
    if (this.#done) return;
    this.#done = true;
    this.#error = error ?? null;
    this.#data.end(error);
    this.#extended.end(error);
    for (const wake of this.#windowWaiters.splice(0)) wake();
    for (const reply of this.#replies.splice(0)) reply(false);
    this.host.forget(this.id);
    this.#settle(this.#exit);
  }
};

// node_modules/@workeryard/undershell/src/connection/connection.ts
var ChannelOpenError = class extends Error {
  constructor(reason, message) {
    super(message);
    this.reason = reason;
  }
  name = "ChannelOpenError";
};
var Connection = class {
  constructor(transport, keepalive) {
    this.transport = transport;
    this.#ended = this.#pump();
    if (keepalive) this.#startKeepalive(keepalive);
  }
  #nextId = 0;
  #failure = null;
  #channels = /* @__PURE__ */ new Map();
  #opening = /* @__PURE__ */ new Map();
  #ended;
  #keepalive;
  #unanswered = 0;
  #host = {
    send: (payload) => this.transport.send(payload),
    fail: (error) => this.#fail(error),
    forget: (id) => this.#channels.delete(id)
  };
  /**
   * keepalive@openssh.com, as ssh's ServerAliveInterval sends it: a global
   * request any server answers, if only to refuse it. Anything heard from
   * the server counts as an answer; silence for maxMissed intervals ends the
   * connection, rather than leaving it to hang until TCP notices.
   */
  #startKeepalive({ intervalMs, maxMissed = 3 }) {
    if (!(intervalMs > 0))
      throw new Error("keepalive.intervalMs must be a positive number of milliseconds");
    const ask = new Writer().byte(MSG.GLOBAL_REQUEST).string("keepalive@openssh.com").bool(true).build();
    this.#keepalive = setInterval(() => {
      if (this.#unanswered >= maxMissed) {
        this.#fail(
          new Error(`the server answered none of ${maxMissed} keepalives, ${intervalMs} ms apart`)
        );
        return;
      }
      this.#unanswered++;
      this.transport.send(ask).catch((error) => this.#fail(error));
    }, intervalMs);
    this.#keepalive.unref?.();
  }
  /** Settles when the connection has ended, closed or failed; it never rejects. */
  get ended() {
    return this.#ended;
  }
  async #pump() {
    try {
      for (; ; ) {
        const message = await this.transport.receive();
        this.#unanswered = 0;
        this.#dispatch(message);
      }
    } catch (error) {
      this.#fail(error);
    }
  }
  #fail(error) {
    if (this.#failure) return;
    this.#failure = error;
    if (this.#keepalive !== void 0) clearInterval(this.#keepalive);
    for (const channel of [...this.#channels.values()]) channel.end(error);
    for (const opening of this.#opening.values()) opening.reject(error);
    this.#opening.clear();
    void this.transport.close();
  }
  #dispatch(message) {
    const type = message[0];
    const reader = new Reader(message.subarray(1));
    if (type === MSG.CHANNEL_OPEN) return this.#refuseOpen(reader);
    if (type === MSG.REQUEST_SUCCESS || type === MSG.REQUEST_FAILURE) return;
    if (type < MSG.CHANNEL_OPEN_CONFIRMATION || type > MSG.CHANNEL_FAILURE) {
      throw new Error(`unexpected message ${type} on an open connection`);
    }
    const id = reader.uint32();
    if (type === MSG.CHANNEL_OPEN_CONFIRMATION || type === MSG.CHANNEL_OPEN_FAILURE) {
      const opening = this.#opening.get(id);
      if (!opening)
        throw new Error(`the server answered an open of channel ${id}, which was not asked for`);
      this.#opening.delete(id);
      if (type === MSG.CHANNEL_OPEN_FAILURE) {
        const reason = reader.uint32();
        opening.reject(
          new ChannelOpenError(
            reason,
            `the server would not open the channel (reason ${reason}): ${reader.text()}`
          )
        );
        return;
      }
      const remoteId = reader.uint32();
      const window = reader.uint32();
      const channel = new Channel(this.#host, id, remoteId, window, reader.uint32());
      this.#channels.set(id, channel);
      opening.resolve(channel);
      return;
    }
    this.#channels.get(id)?.handle(type, reader);
  }
  /**
   * The server opening a channel to us: forwarded ports, X11, an agent.
   * None of them was asked for, so each is refused.
   */
  #refuseOpen(reader) {
    const kind = reader.text();
    const sender = reader.uint32();
    void this.transport.send(
      new Writer().byte(MSG.CHANNEL_OPEN_FAILURE).uint32(sender).uint32(1).string(`${kind} channels are not accepted by this client`).string("").build()
    ).catch((error) => this.#fail(error));
  }
  /** Opens a channel of `type`, with whatever that type puts after the common fields. */
  open(type, extra = new Uint8Array(0)) {
    if (this.#failure) return Promise.reject(toError(this.#failure));
    const id = this.#nextId++;
    const opened = new Promise(
      (resolve, reject) => this.#opening.set(id, { resolve, reject })
    );
    const request = new Writer().byte(MSG.CHANNEL_OPEN).string(type).uint32(id).uint32(WINDOW).uint32(MAX_PACKET).raw(extra);
    this.transport.send(request.build()).catch((error) => {
      this.#opening.delete(id);
      this.#fail(error);
    });
    return opened;
  }
  async close() {
    this.#fail(new Error("the connection was closed"));
    await this.transport.close();
    await this.#ended;
  }
};

// node_modules/@workeryard/undershell/src/connection/session.ts
function ptyRequest(options) {
  const modes = new Writer();
  for (const [opcode, value] of Object.entries(options.modes ?? {}))
    modes.byte(Number(opcode)).uint32(value);
  modes.byte(0);
  return new Writer().string(options.term ?? "xterm-256color").uint32(options.cols ?? 80).uint32(options.rows ?? 24).uint32(options.width ?? 0).uint32(options.height ?? 0).string(modes.build()).build();
}
var Session = class {
  constructor(channel) {
    this.channel = channel;
  }
  /** What the remote side writes; with a pty, stderr arrives here too. */
  get stdout() {
    return this.channel.readable;
  }
  /**
   * What it writes to stderr. It shares the window with stdout: read it, or
   * cancel it, or a command that writes a lot of it will stall.
   */
  get stderr() {
    return this.channel.stderr;
  }
  /** What it reads. Closing this sends EOF, which is how a command reading stdin finishes. */
  get stdin() {
    return this.channel.writable;
  }
  /** How it ended, once the channel has closed. */
  get exit() {
    return this.channel.closed;
  }
  /** Tells the remote terminal its new size (RFC 4254 §6.7). */
  async resize(cols, rows, width = 0, height = 0) {
    await this.channel.request(
      "window-change",
      false,
      new Writer().uint32(cols).uint32(rows).uint32(width).uint32(height).build()
    );
  }
  /** Sends a signal by name without "SIG", such as `INT` or `TERM`. OpenSSH honours it since 7.9. */
  async signal(name) {
    await this.channel.request(
      "signal",
      false,
      new Writer().string(name.replace(/^SIG/, "")).build()
    );
  }
  close() {
    return this.channel.close();
  }
};
async function prepare(channel, options, start, data) {
  try {
    for (const [name, value] of Object.entries(options.env ?? {})) {
      await channel.request("env", false, new Writer().string(name).string(value).build());
    }
    if (options.pty) {
      const pty = options.pty === true ? {} : options.pty;
      if (!await channel.request("pty-req", true, ptyRequest(pty)))
        throw new Error("the server refused a pseudo-terminal");
    }
    if (!await channel.request(start, true, data)) {
      throw new Error(
        start === "subsystem" ? "the server refused the subsystem" : `the server refused the ${start} request`
      );
    }
    return new Session(channel);
  } catch (error) {
    await channel.close().catch(() => {
    });
    throw error;
  }
}

// node_modules/@workeryard/undershell/src/sftp/attributes.ts
var SIZE = 1;
var UIDGID = 2;
var PERMISSIONS = 4;
var ACMODTIME = 8;
var EXTENDED = 2147483648;
var TYPE_MASK = 61440;
var DIRECTORY = 16384;
var FILE = 32768;
var LINK = 40960;
function readAttributes(reader) {
  const flags = reader.uint32();
  const stats2 = {
    size: null,
    uid: null,
    gid: null,
    permissions: null,
    accessedAt: null,
    modifiedAt: null,
    isDirectory: false,
    isFile: false,
    isSymbolicLink: false
  };
  if (flags & SIZE) stats2.size = reader.uint64();
  if (flags & UIDGID) {
    stats2.uid = reader.uint32();
    stats2.gid = reader.uint32();
  }
  if (flags & PERMISSIONS) {
    const mode = reader.uint32();
    stats2.permissions = mode;
    stats2.isDirectory = (mode & TYPE_MASK) === DIRECTORY;
    stats2.isFile = (mode & TYPE_MASK) === FILE;
    stats2.isSymbolicLink = (mode & TYPE_MASK) === LINK;
  }
  if (flags & ACMODTIME) {
    stats2.accessedAt = reader.uint32();
    stats2.modifiedAt = reader.uint32();
  }
  if (flags & EXTENDED) {
    const count = reader.uint32();
    for (let index = 0; index < count; index++) {
      reader.skipString();
      reader.skipString();
    }
  }
  return stats2;
}
function writeAttributes(writer, mode) {
  return mode === void 0 ? writer.uint32(0) : writer.uint32(PERMISSIONS).uint32(mode);
}

// node_modules/@workeryard/undershell/src/transport/buffered.ts
var Buffered = class {
  #buffer = new Uint8Array(0);
  #ended = false;
  #reader;
  constructor(stream) {
    this.#reader = stream.getReader();
  }
  async #pull() {
    if (this.#ended) return false;
    const { value, done } = await this.#reader.read();
    if (done) {
      this.#ended = true;
      return false;
    }
    if (value?.length) {
      this.#buffer = this.#buffer.length ? concat([this.#buffer, value]) : new Uint8Array(value);
    }
    return true;
  }
  async exactly(length2) {
    while (this.#buffer.length < length2) {
      if (!await this.#pull()) {
        throw new Error(`the connection ended after ${this.#buffer.length} of ${length2} bytes`);
      }
    }
    const taken = this.#buffer.slice(0, length2);
    this.#buffer = this.#buffer.subarray(length2);
    return taken;
  }
  /** One CRLF-terminated line, refusing to buffer a hostile server's flood. */
  async line(limit) {
    for (; ; ) {
      const at = this.#buffer.indexOf(10);
      if (at !== -1) {
        const line = this.#buffer.subarray(0, at);
        this.#buffer = this.#buffer.subarray(at + 1);
        return new TextDecoder().decode(line).replace(/\r$/, "");
      }
      if (this.#buffer.length > limit) {
        throw new Error(`the server sent ${this.#buffer.length} bytes without a line`);
      }
      if (!await this.#pull()) throw new Error("the connection ended before a line arrived");
    }
  }
  cancel() {
    void this.#reader.cancel().catch(() => {
    });
  }
};

// node_modules/@workeryard/undershell/src/sftp/protocol.ts
var FXP = {
  INIT: 1,
  VERSION: 2,
  OPEN: 3,
  CLOSE: 4,
  READ: 5,
  WRITE: 6,
  LSTAT: 7,
  FSTAT: 8,
  OPENDIR: 11,
  READDIR: 12,
  REMOVE: 13,
  MKDIR: 14,
  RMDIR: 15,
  REALPATH: 16,
  STAT: 17,
  RENAME: 18,
  STATUS: 101,
  HANDLE: 102,
  DATA: 103,
  NAME: 104,
  ATTRS: 105,
  EXTENDED: 200
};
var STATUS = { OK: 0, EOF: 1, NO_SUCH_FILE: 2 };
var STATUS_TEXT = {
  2: "no such file",
  3: "permission denied",
  4: "failed",
  5: "a bad message",
  6: "no connection",
  7: "the connection was lost",
  8: "an unsupported operation"
};
var VERSION = 3;
var MAX_MESSAGE = 512 * 1024;
var SftpError = class extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
  name = "SftpError";
};
var Protocol = class _Protocol {
  constructor(session) {
    this.session = session;
    this.#writer = session.stdin.getWriter();
  }
  #nextId = 1;
  #failure = null;
  #pending = /* @__PURE__ */ new Map();
  #writer;
  /** What the server's VERSION offered beyond v3, such as posix-rename@openssh.com. */
  extensions = /* @__PURE__ */ new Map();
  static async start(session) {
    const protocol = new _Protocol(session);
    void session.stderr.cancel().catch(() => {
    });
    const input = new Buffered(session.stdout);
    try {
      await protocol.#write(new Writer().byte(FXP.INIT).uint32(VERSION).build());
      const hello = new Reader(await _Protocol.#frame(input));
      const type = hello.byte();
      if (type !== FXP.VERSION)
        throw new Error(`expected the sftp version, got packet type ${type}`);
      const version = hello.uint32();
      if (version < VERSION)
        throw new Error(`the server speaks sftp ${version}, and this client needs ${VERSION}`);
      while (!hello.done) protocol.extensions.set(hello.text(), hello.text());
    } catch (error) {
      await session.close().catch(() => {
      });
      throw error;
    }
    void protocol.#read(input);
    return protocol;
  }
  static async #frame(input) {
    const length2 = new Reader(await input.exactly(4)).uint32();
    if (length2 === 0 || length2 > MAX_MESSAGE) throw new Error(`an sftp packet of ${length2} bytes`);
    return input.exactly(length2);
  }
  async #read(input) {
    try {
      for (; ; ) {
        const reader = new Reader(await _Protocol.#frame(input));
        const type = reader.byte();
        const id = reader.uint32();
        const pending = this.#pending.get(id);
        if (!pending)
          throw new Error(`the server answered sftp request ${id}, which was not asked`);
        this.#pending.delete(id);
        pending.resolve({ type, reader });
      }
    } catch (error) {
      this.#fail(
        error instanceof Error && /connection ended/.test(error.message) ? new Error("the server closed the sftp channel") : error
      );
    }
  }
  #fail(error) {
    this.#failure ??= error;
    for (const pending of this.#pending.values()) pending.reject(this.#failure);
    this.#pending.clear();
  }
  #write(packet) {
    return this.#writer.write(new Writer().uint32(packet.length).raw(packet).build());
  }
  /** Sends one request and waits for the answer with its id. */
  request(type, build) {
    if (this.#failure) return Promise.reject(toError(this.#failure));
    const id = this.#nextId;
    this.#nextId = this.#nextId + 1 >>> 0 || 1;
    const reply = new Promise(
      (resolve, reject) => this.#pending.set(id, { resolve, reject })
    );
    this.#write(build(new Writer().byte(type).uint32(id)).build()).catch(
      (error) => this.#fail(error)
    );
    return reply;
  }
  /** A request answered by a STATUS: resolves on OK, and on EOF when `eof` allows it. */
  async status(type, build, what) {
    expectStatus(await this.request(type, build), what);
  }
  async end() {
    this.#fail(new Error("the sftp session has ended"));
    await this.#writer.close().catch(() => {
    });
    await this.session.close().catch(() => {
    });
  }
};
function expectStatus(reply, what, allowEof = false) {
  if (reply.type !== FXP.STATUS)
    throw new Error(`expected a status for ${what}, got packet type ${reply.type}`);
  const code = reply.reader.uint32();
  if (code === STATUS.OK) return false;
  if (code === STATUS.EOF && allowEof) return true;
  const said = reply.reader.done ? "" : reply.reader.text();
  throw new SftpError(code, `${what}: ${said || STATUS_TEXT[code] || `sftp error ${code}`}`);
}
function expectType(reply, type, what) {
  if (reply.type === type) return reply.reader;
  expectStatus(reply, what);
  throw new Error(`expected packet type ${type} for ${what}, got ${reply.type}`);
}

// node_modules/@workeryard/undershell/src/sftp/streams.ts
var CHUNK = 32 * 1024;
var CONCURRENCY = 16;
function readStream(protocol, handle, what, options, close) {
  const chunkSize = options.chunkSize ?? CHUNK;
  const concurrency = Math.max(1, options.concurrency ?? CONCURRENCY);
  const end = options.end ?? Infinity;
  let next = options.start ?? 0;
  let finished = false;
  const slots = [];
  const read = (offset, length2) => ({
    offset,
    length: length2,
    data: protocol.request(FXP.READ, (w) => w.string(handle).uint64(offset).uint32(length2)).then(
      (reply) => reply.type === FXP.DATA ? reply.reader.string().slice() : expectStatus(reply, what, true) ? null : new Uint8Array(0)
    )
  });
  const fill = () => {
    while (!finished && slots.length < concurrency && next < end) {
      const length2 = Math.min(chunkSize, end - next);
      slots.push(read(next, length2));
      next += length2;
    }
  };
  let closing = null;
  const settle = () => {
    finished = true;
    closing ??= Promise.allSettled(slots.splice(0).map((slot) => slot.data)).then(close);
    return closing;
  };
  return new ReadableStream(
    {
      async pull(controller) {
        fill();
        const slot = slots.shift();
        if (!slot) {
          await settle();
          return controller.close();
        }
        let data;
        try {
          data = await slot.data;
        } catch (error) {
          await settle().catch(() => {
          });
          throw error;
        }
        if (data === null || data.length === 0) {
          await settle();
          return controller.close();
        }
        if (data.length < slot.length)
          slots.unshift(read(slot.offset + data.length, slot.length - data.length));
        controller.enqueue(data);
      },
      async cancel() {
        await settle();
      }
    },
    { highWaterMark: 0 }
  );
}
function writeStream(protocol, handle, what, options, close) {
  const concurrency = Math.max(1, options.concurrency ?? CONCURRENCY);
  let offset = options.start ?? 0;
  const inFlight = [];
  let failure2 = null;
  const write = (at, data) => {
    const done = protocol.request(FXP.WRITE, (w) => w.string(handle).uint64(at).string(data)).then((reply) => void expectStatus(reply, what)).catch((error) => {
      failure2 ??= error;
    });
    inFlight.push(done);
  };
  const drain = async (room) => {
    while (inFlight.length > room) await inFlight.shift();
    if (failure2) throw failure2;
  };
  return new WritableStream({
    async write(chunk) {
      for (let at = 0; at < chunk.length; at += CHUNK) {
        await drain(concurrency - 1);
        write(offset, chunk.slice(at, at + CHUNK));
        offset += Math.min(CHUNK, chunk.length - at);
      }
    },
    async close() {
      try {
        await drain(0);
      } finally {
        await close();
      }
    },
    async abort() {
      await drain(0).catch(() => {
      });
      await close();
    }
  });
}
async function openHandle(protocol, path, flags, mode) {
  const reply = await protocol.request(FXP.OPEN, (w) => {
    const writer = w.string(path).uint32(flags);
    return mode === void 0 ? writer.uint32(0) : writer.uint32(4).uint32(mode);
  });
  return expectType(reply, FXP.HANDLE, `opening "${path}"`).string().slice();
}
function closeHandle(protocol, handle) {
  return protocol.status(FXP.CLOSE, (w) => w.string(handle), "closing a handle").catch(() => {
  });
}

// node_modules/@workeryard/undershell/src/sftp/sftp.ts
var READ = 1;
var WRITE = 2;
var APPEND = 4;
var CREATE = 8;
var TRUNCATE = 16;
var EXCLUSIVE = 32;
var MAX_FILE = 64 * 1024 * 1024;
var Sftp = class _Sftp {
  constructor(protocol) {
    this.protocol = protocol;
  }
  static async start(session) {
    return new _Sftp(await Protocol.start(session));
  }
  /** Extensions the server offered, by name, such as `posix-rename@openssh.com`. */
  get extensions() {
    return this.protocol.extensions;
  }
  async #stat(type, path) {
    const reply = await this.protocol.request(type, (w) => w.string(path));
    return readAttributes(expectType(reply, FXP.ATTRS, `stat "${path}"`));
  }
  /** The file's attributes, following a symbolic link. */
  stat(path) {
    return this.#stat(FXP.STAT, path);
  }
  /** The attributes of the link itself, where `path` is one. */
  lstat(path) {
    return this.#stat(FXP.LSTAT, path);
  }
  async exists(path) {
    try {
      await this.stat(path);
      return true;
    } catch (error) {
      if (error instanceof SftpError && error.code === STATUS.NO_SUCH_FILE) return false;
      throw error;
    }
  }
  /** The canonical absolute path, which is also how to learn the home directory: `realpath('.')`. */
  async realpath(path) {
    const reader = expectType(
      await this.protocol.request(FXP.REALPATH, (w) => w.string(path)),
      FXP.NAME,
      `realpath "${path}"`
    );
    if (reader.uint32() < 1) throw new Error(`realpath "${path}" came back empty`);
    return reader.text();
  }
  /**
   * A directory's entries, read one page — one READDIR — at a time, so a
   * directory of a million files never sits in memory whole.
   */
  async *readdir(path) {
    const reply = await this.protocol.request(FXP.OPENDIR, (w) => w.string(path));
    const handle = expectType(reply, FXP.HANDLE, `opening "${path}"`).string().slice();
    try {
      for (; ; ) {
        const page = await this.protocol.request(FXP.READDIR, (w) => w.string(handle));
        if (page.type !== FXP.NAME && expectStatus(page, `listing "${path}"`, true)) return;
        const count = page.reader.uint32();
        for (let index = 0; index < count; index++) {
          const name = page.reader.text();
          page.reader.skipString();
          const attributes = readAttributes(page.reader);
          if (name === "." || name === "..") continue;
          yield {
            name,
            size: attributes.size,
            directory: attributes.isDirectory,
            modifiedAt: attributes.modifiedAt,
            attributes
          };
        }
      }
    } finally {
      await closeHandle(this.protocol, handle);
    }
  }
  /** Every entry of a directory, collected. */
  async list(path) {
    const entries = [];
    for await (const entry of this.readdir(path)) entries.push(entry);
    return entries;
  }
  async mkdir(path, options = {}) {
    await this.protocol.status(
      FXP.MKDIR,
      (w) => writeAttributes(w.string(path), options.permissions),
      `mkdir "${path}"`
    );
  }
  /** The older name, kept for Flowker's callers. */
  makeDirectory(path) {
    return this.mkdir(path);
  }
  async rmdir(path) {
    await this.protocol.status(FXP.RMDIR, (w) => w.string(path), `rmdir "${path}"`);
  }
  /** Removes a file. A directory needs `rmdir`. */
  async remove(path) {
    await this.protocol.status(FXP.REMOVE, (w) => w.string(path), `remove "${path}"`);
  }
  /**
   * Renames a file or directory. SFTP v3's own rename fails if the target
   * exists; `overwrite: true` asks for POSIX rename(2), which replaces it,
   * where the server offers posix-rename@openssh.com.
   */
  async rename(from, to, options = {}) {
    const what = `rename "${from}" to "${to}"`;
    if (options.overwrite) {
      if (!this.extensions.has("posix-rename@openssh.com")) {
        throw new SftpError(
          8,
          `${what}: the server cannot replace a file by renaming (no posix-rename@openssh.com)`
        );
      }
      return this.protocol.status(
        FXP.EXTENDED,
        (w) => w.string("posix-rename@openssh.com").string(from).string(to),
        what
      );
    }
    return this.protocol.status(FXP.RENAME, (w) => w.string(from).string(to), what);
  }
  /** A file as a stream, read ahead a bounded number of requests at a time. */
  createReadStream(path, options = {}) {
    const opened = openHandle(this.protocol, path, READ);
    let inner = null;
    let reader = null;
    return new ReadableStream(
      {
        pull: async (controller) => {
          if (!reader) {
            const handle = await opened;
            inner = readStream(
              this.protocol,
              handle,
              `reading "${path}"`,
              options,
              () => closeHandle(this.protocol, handle)
            );
            reader = inner.getReader();
          }
          const { value, done } = await reader.read();
          if (done) controller.close();
          else controller.enqueue(value);
        },
        cancel: async (reason) => {
          if (reader) await reader.cancel(reason);
          else await opened.then((handle) => closeHandle(this.protocol, handle)).catch(() => {
          });
        }
      },
      { highWaterMark: 0 }
    );
  }
  /** A file to write as a stream; it is complete, and closed, when the stream is. */
  createWriteStream(path, options = {}) {
    const flags = WRITE | CREATE | (options.mode === "append" ? APPEND : options.mode === "exclusive" ? EXCLUSIVE : TRUNCATE);
    const opened = openHandle(this.protocol, path, flags, options.permissions);
    opened.catch(() => {
    });
    let inner = null;
    const writer = async () => {
      if (!inner) {
        const handle = await opened;
        let start = 0;
        if (options.mode === "append") {
          start = readAttributes(
            expectType(
              await this.protocol.request(FXP.FSTAT, (w) => w.string(handle)),
              FXP.ATTRS,
              "fstat"
            )
          ).size ?? 0;
        }
        const stream = writeStream(
          this.protocol,
          handle,
          `writing "${path}"`,
          { start, ...options.concurrency && { concurrency: options.concurrency } },
          () => closeHandle(this.protocol, handle)
        );
        inner = stream.getWriter();
      }
      return inner;
    };
    return new WritableStream({
      write: async (chunk) => (await writer()).write(chunk),
      close: async () => (await writer()).close(),
      abort: async (reason) => (await writer()).abort(reason)
    });
  }
  /** Reads a whole file into memory, refusing one larger than `limit` (default 64 MiB). */
  async get(path, limit = MAX_FILE) {
    const parts = [];
    let total = 0;
    const stream = this.createReadStream(path);
    for await (const chunk of stream) {
      total += chunk.length;
      if (total > limit) {
        throw new Error(`"${path}" is larger than the ${Math.round(limit / 1024)} KiB limit`);
      }
      parts.push(chunk);
    }
    return concat(parts);
  }
  /** Writes a whole file, from bytes or a stream, replacing whatever was there. */
  async put(path, data, options = {}) {
    const target = this.createWriteStream(path, options);
    if (data instanceof ReadableStream) return data.pipeTo(target);
    const writer = target.getWriter();
    await writer.write(data);
    await writer.close();
  }
  /** Ends the session and its channel; the connection stays open. */
  end() {
    return this.protocol.end();
  }
};

// node_modules/@workeryard/undershell/src/transport/algorithms.ts
var KEX = [
  "curve25519-sha256",
  "curve25519-sha256@libssh.org",
  "ecdh-sha2-nistp256",
  // Finite-field Diffie-Hellman, last: BigInt arithmetic costs more CPU than
  // a curve, and only servers with no curve at all, such as RouterOS 6,
  // need it.
  "diffie-hellman-group-exchange-sha256",
  "diffie-hellman-group16-sha512",
  "diffie-hellman-group14-sha256"
];
var HOST_KEYS = [
  "ssh-ed25519",
  "ecdsa-sha2-nistp256",
  "ecdsa-sha2-nistp384",
  "ecdsa-sha2-nistp521",
  "rsa-sha2-512",
  "rsa-sha2-256"
];
var CIPHERS2 = [
  "aes256-gcm@openssh.com",
  "aes128-gcm@openssh.com",
  "aes256-ctr",
  "aes192-ctr",
  "aes128-ctr"
];
var MACS = [
  "hmac-sha2-256-etm@openssh.com",
  "hmac-sha2-512-etm@openssh.com",
  "hmac-sha2-256",
  "hmac-sha2-512",
  // Last, for servers that offer nothing better, RouterOS 6 among them.
  // SHA-1's collisions do not carry over to HMAC, which OpenSSH still
  // offers by default; SHA-1 signatures and key exchanges stay refused.
  "hmac-sha1-etm@openssh.com",
  "hmac-sha1"
];
function pick(what, given, all) {
  if (!given) return all;
  if (given.length === 0) throw new Error(`no ${what} algorithm was left to offer`);
  for (const name of given) {
    if (!all.includes(name))
      throw new Error(`${name} is not a ${what} algorithm this client implements`);
  }
  return given;
}
function preference(algorithms = {}) {
  return {
    kex: pick("key exchange", algorithms.kex, KEX),
    hostKey: pick("host key", algorithms.hostKey, HOST_KEYS),
    cipher: pick("cipher", algorithms.cipher, CIPHERS2),
    mac: pick("MAC", algorithms.mac, MACS)
  };
}
function choose(what, ours, theirs) {
  const chosen = ours.find((name) => theirs.includes(name));
  if (!chosen) {
    throw new Error(
      `the server offers no ${what} this client speaks; it has ${theirs.join(", ") || "none"}, and this client ${ours.join(", ")}`
    );
  }
  return chosen;
}
function macSpec(mac) {
  if (mac.startsWith("hmac-sha1")) return { hash: "SHA-1", length: 20 };
  if (mac.includes("512")) return { hash: "SHA-512", length: 64 };
  return { hash: "SHA-256", length: 32 };
}
function isGcm(cipher) {
  return cipher.endsWith("-gcm@openssh.com");
}

// node_modules/@workeryard/undershell/src/transport/cipher.ts
var MAX_PACKET2 = 1024 * 1024;
function paddingFor(payloadLength, blockSize, countLengthField) {
  const base = (countLengthField ? 4 : 0) + 1 + payloadLength;
  let padding = blockSize - base % blockSize;
  if (padding < 4) padding += blockSize;
  return padding;
}
function lengthOf(bytes2, at = 0) {
  return new DataView(bytes2.buffer, bytes2.byteOffset + at, 4).getUint32(0);
}
function checkLength(length2, blockSize) {
  if (length2 < 5 || length2 > MAX_PACKET2 || length2 % blockSize !== 0) {
    throw new Error(`a packet of ${length2} bytes is out of range`);
  }
}
function unpad(plain) {
  const padding = plain[0];
  if (padding < 4 || padding + 1 > plain.length)
    throw new Error(`a packet with ${padding} bytes of padding`);
  return plain.subarray(1, plain.length - padding);
}
var PLAIN = {
  seal(payload) {
    const padding = paddingFor(payload.length, 8, true);
    return Promise.resolve(
      new Writer().uint32(1 + payload.length + padding).byte(padding).raw(payload).raw(new Uint8Array(padding)).build()
    );
  },
  async open(source) {
    const length2 = lengthOf(await source.exactly(4));
    if (length2 < 5 || length2 > MAX_PACKET2)
      throw new Error(`a packet of ${length2} bytes is out of range`);
    return unpad(await source.exactly(length2));
  }
};
function bumpCounter(iv) {
  for (let index = 11; index >= 4; index--) {
    if (++iv[index] <= 255) break;
    iv[index] = 0;
  }
}
function advanceCounter(counter, blocks) {
  let carry = blocks;
  for (let index = 15; index >= 0 && carry > 0; index--) {
    const sum = counter[index] + carry % 256;
    counter[index] = sum & 255;
    carry = Math.floor(carry / 256) + (sum >> 8);
  }
}
var Gcm = class {
  constructor(key, iv) {
    this.key = key;
    this.iv = iv;
  }
  async seal(payload) {
    const padding = paddingFor(payload.length, 16, false);
    const lengthBytes = new Writer().uint32(1 + payload.length + padding).build();
    const plain = concat([new Uint8Array([padding]), payload, randomBytes(padding)]);
    const sealed = await subtle.encrypt(
      { name: "AES-GCM", iv: this.iv, additionalData: lengthBytes },
      this.key,
      plain
    );
    bumpCounter(this.iv);
    return concat([lengthBytes, new Uint8Array(sealed)]);
  }
  async open(source) {
    const lengthBytes = await source.exactly(4);
    const length2 = lengthOf(lengthBytes);
    checkLength(length2, 16);
    const sealed = await source.exactly(length2 + 16);
    const plain = await subtle.decrypt({ name: "AES-GCM", iv: this.iv, additionalData: lengthBytes }, this.key, sealed).catch(() => {
      throw new Error("a packet failed its GCM authentication");
    });
    bumpCounter(this.iv);
    return unpad(new Uint8Array(plain));
  }
};
var CtrHmac = class {
  constructor(key, counter, macKey, mac, etm) {
    this.key = key;
    this.counter = counter;
    this.macKey = macKey;
    this.etm = etm;
    this.#macLength = macSpec(mac).length;
  }
  #macLength;
  async #xor(data) {
    const out = await subtle.encrypt(
      { name: "AES-CTR", counter: this.counter, length: 128 },
      this.key,
      data
    );
    advanceCounter(this.counter, data.length / 16);
    return new Uint8Array(out);
  }
  #mac(sequence, data) {
    return subtle.sign("HMAC", this.macKey, concat([new Writer().uint32(sequence).build(), data]));
  }
  async #check(sequence, data, mac) {
    const signed = concat([new Writer().uint32(sequence).build(), data]);
    if (!await subtle.verify("HMAC", this.macKey, mac, signed))
      throw new Error("a packet failed its MAC");
  }
  async seal(payload, sequence) {
    const padding = paddingFor(payload.length, 16, !this.etm);
    const length2 = new Writer().uint32(1 + payload.length + padding).build();
    const body = concat([new Uint8Array([padding]), payload, randomBytes(padding)]);
    if (this.etm) {
      const encrypted = await this.#xor(body);
      const mac2 = await this.#mac(sequence, concat([length2, encrypted]));
      return concat([length2, encrypted, new Uint8Array(mac2)]);
    }
    const packet = concat([length2, body]);
    const mac = await this.#mac(sequence, packet);
    return concat([await this.#xor(packet), new Uint8Array(mac)]);
  }
  async open(source, sequence) {
    if (this.etm) {
      const lengthBytes = await source.exactly(4);
      const length3 = lengthOf(lengthBytes);
      checkLength(length3, 16);
      const encrypted = await source.exactly(length3);
      await this.#check(
        sequence,
        concat([lengthBytes, encrypted]),
        await source.exactly(this.#macLength)
      );
      return unpad(await this.#xor(encrypted));
    }
    const first = await this.#xor(await source.exactly(16));
    const length2 = lengthOf(first);
    if (length2 + 4 < 16 || length2 > MAX_PACKET2 || (length2 + 4) % 16 !== 0) {
      throw new Error(`a packet of ${length2} bytes is out of range`);
    }
    const rest = await this.#xor(await source.exactly(length2 + 4 - 16));
    const packet = concat([first, rest]);
    await this.#check(sequence, packet, await source.exactly(this.#macLength));
    return unpad(packet.subarray(4));
  }
};
function keyLengths(cipher, mac) {
  const key = cipher.startsWith("aes256") ? 32 : cipher.startsWith("aes192") ? 24 : 16;
  if (isGcm(cipher)) return { iv: 12, key, mac: 0 };
  return { iv: 16, key, mac: macSpec(mac).length };
}
async function packetCipher(cipher, mac, keys, usage) {
  if (isGcm(cipher)) {
    const key2 = await subtle.importKey("raw", keys.key, { name: "AES-GCM" }, false, [usage]);
    return new Gcm(key2, new Uint8Array(keys.iv));
  }
  const key = await subtle.importKey("raw", keys.key, { name: "AES-CTR" }, false, ["encrypt"]);
  const { hash } = macSpec(mac);
  const macKey = await subtle.importKey("raw", keys.macKey, { name: "HMAC", hash }, false, [
    "sign",
    "verify"
  ]);
  return new CtrHmac(key, new Uint8Array(keys.iv), macKey, mac, mac.endsWith("-etm@openssh.com"));
}

// node_modules/@workeryard/undershell/src/transport/exchange.ts
var KEX_STRICT = "kex-strict-c-v00@openssh.com";
var KEX_STRICT_SERVER = "kex-strict-s-v00@openssh.com";
var EXT_INFO = "ext-info-c";
function kexinit(p, first) {
  return new Writer().byte(MSG.KEXINIT).raw(randomBytes(16)).nameList(first ? [...p.kex, EXT_INFO, KEX_STRICT] : p.kex).nameList(p.hostKey).nameList(p.cipher).nameList(p.cipher).nameList(p.mac).nameList(p.mac).nameList(["none"]).nameList(["none"]).nameList([]).nameList([]).bool(false).uint32(0).build();
}
function negotiate(p, theirs) {
  const reader = new Reader(theirs.subarray(17));
  const kexList = reader.nameList();
  const hostKeyList = reader.nameList();
  const cipherOut = reader.nameList();
  const cipherIn = reader.nameList();
  const macOut = reader.nameList();
  const macIn = reader.nameList();
  for (let index = 0; index < 4; index++) reader.skipString();
  const guessFollows = reader.bool();
  const kex = choose("key exchange", p.kex, kexList);
  const hostKey = choose("host key algorithm", p.hostKey, hostKeyList);
  const cipher = {
    out: choose("cipher to the server", p.cipher, cipherOut),
    in: choose("cipher to the client", p.cipher, cipherIn)
  };
  return {
    kex,
    hostKey,
    cipher,
    mac: {
      out: isGcm(cipher.out) ? null : choose("MAC to the server", p.mac, macOut),
      in: isGcm(cipher.in) ? null : choose("MAC to the client", p.mac, macIn)
    },
    strictOffered: kexList.includes(KEX_STRICT_SERVER),
    // RFC 4253 §7: a wrong guess is a key exchange packet sent ahead, to be ignored.
    dropGuess: guessFollows && (kexList[0] !== kex || hostKeyList[0] !== hostKey)
  };
}
async function deriveCiphers(hash, secret, exchange, sessionId, chosen) {
  const prefix = new Writer().raw(secret).raw(exchange).build();
  const derive = async (letter, length2) => {
    let material = await digest(
      hash,
      new Writer().raw(prefix).byte(letter.charCodeAt(0)).raw(sessionId).build()
    );
    while (material.length < length2) {
      const more = await digest(hash, new Writer().raw(prefix).raw(material).build());
      material = new Writer().raw(material).raw(more).build();
    }
    return material.slice(0, length2);
  };
  const macOut = chosen.mac.out ?? "hmac-sha2-256";
  const macIn = chosen.mac.in ?? "hmac-sha2-256";
  const sizeOut = keyLengths(chosen.cipher.out, macOut);
  const sizeIn = keyLengths(chosen.cipher.in, macIn);
  const keysOut = {
    iv: await derive("A", sizeOut.iv),
    key: await derive("C", sizeOut.key),
    macKey: await derive("E", sizeOut.mac)
  };
  const keysIn = {
    iv: await derive("B", sizeIn.iv),
    key: await derive("D", sizeIn.key),
    macKey: await derive("F", sizeIn.mac)
  };
  return {
    outgoing: await packetCipher(chosen.cipher.out, macOut, keysOut, "encrypt"),
    incoming: await packetCipher(chosen.cipher.in, macIn, keysIn, "decrypt")
  };
}

// node_modules/@workeryard/undershell/src/transport/modp.ts
var MODP_2048 = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF";
var MODP_4096 = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D788719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA993B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF";

// node_modules/@workeryard/undershell/src/transport/kex.ts
var MSG2 = {
  KEXDH_INIT: 30,
  KEXDH_REPLY: 31,
  GEX_GROUP: 31,
  GEX_INIT: 32,
  GEX_REPLY: 33,
  GEX_REQUEST: 34
};
var GEX_BITS = { min: 2048, preferred: 3072, max: 4096 };
function head(prefix, hostKeyBlob) {
  return new Writer().string(prefix.clientVersion).string(prefix.serverVersion).string(prefix.ours).string(prefix.theirs).string(hostKeyBlob);
}
async function ecdh(name, talk, prefix) {
  const curve = name === "ecdh-sha2-nistp256" ? { name: "ECDH", namedCurve: "P-256" } : { name: "X25519" };
  const pair = await subtle.generateKey(curve, true, ["deriveBits"]);
  const clientPublic = new Uint8Array(await subtle.exportKey("raw", pair.publicKey));
  talk.send(new Writer().byte(MSG2.KEXDH_INIT).string(clientPublic).build());
  const reply = new Reader((await talk.expect(MSG2.KEXDH_REPLY)).subarray(1));
  const hostKeyBlob = reply.string();
  const serverPublic = reply.string();
  const signature2 = reply.string();
  let shared;
  if (curve.name === "X25519") {
    if (serverPublic.length !== 32)
      throw new Error(`the server's X25519 key is ${serverPublic.length} bytes, not 32`);
    const theirs = await subtle.importKey("raw", serverPublic, curve, false, []);
    shared = new Uint8Array(
      await subtle.deriveBits({ name: "X25519", public: theirs }, pair.privateKey, 256)
    );
    if (shared.every((byte) => byte === 0))
      throw new Error("the server's X25519 key is a low-order point");
  } else {
    if (serverPublic.length !== 65 || serverPublic[0] !== 4) {
      throw new Error(
        `the server's P-256 key is not an uncompressed point (${serverPublic.length} bytes)`
      );
    }
    const theirs = await subtle.importKey("raw", serverPublic, curve, false, []);
    shared = new Uint8Array(
      await subtle.deriveBits({ name: "ECDH", public: theirs }, pair.privateKey, 256)
    );
  }
  const secret = new Writer().mpint(shared).build();
  const exchangeHash = await digest(
    "SHA-256",
    head(prefix, hostKeyBlob).string(clientPublic).string(serverPublic).raw(secret).build()
  );
  return { hash: "SHA-256", hostKeyBlob, signature: signature2, secret, exchangeHash };
}
var toBig2 = (bytes2) => bytes2.length === 0 ? 0n : BigInt(`0x${Array.from(bytes2, (b) => b.toString(16).padStart(2, "0")).join("")}`);
function fromBig2(value) {
  let hex = value.toString(16);
  if (hex.length % 2) hex = `0${hex}`;
  return new Uint8Array(hex.match(/../g)?.map((pair) => parseInt(pair, 16)) ?? []);
}
function modPow(base, exponent, modulus) {
  let result = 1n;
  let square = base % modulus;
  for (let left = exponent; left > 0n; left >>= 1n) {
    if (left & 1n) result = result * square % modulus;
    square = square * square % modulus;
  }
  return result;
}
var bitLength2 = (value) => value.toString(2).length;
function privateExponent(p) {
  const x = toBig2(randomBytes(64)) % (p - 2n);
  return x < 2n ? 2n : x;
}
function checkPublic(value, p, what) {
  if (value <= 1n || value >= p - 1n) throw new Error(`the server's ${what} is out of range`);
}
async function dh(name, talk, prefix) {
  const hash = name === "diffie-hellman-group16-sha512" ? "SHA-512" : "SHA-256";
  const gex = name === "diffie-hellman-group-exchange-sha256";
  let p;
  let g = 2n;
  if (gex) {
    talk.send(
      new Writer().byte(MSG2.GEX_REQUEST).uint32(GEX_BITS.min).uint32(GEX_BITS.preferred).uint32(GEX_BITS.max).build()
    );
    const group = new Reader((await talk.expect(MSG2.GEX_GROUP)).subarray(1));
    p = toBig2(group.mpint());
    g = toBig2(group.mpint());
    const bits = bitLength2(p);
    if (bits < GEX_BITS.min || bits > GEX_BITS.max) {
      throw new Error(
        `the server chose a ${bits}-bit group, outside the ${GEX_BITS.min}\u2013${GEX_BITS.max} asked for`
      );
    }
    if (p % 2n === 0n || g <= 1n || g >= p - 1n)
      throw new Error("the server chose a group that is not one");
  } else {
    p = BigInt(`0x${name === "diffie-hellman-group16-sha512" ? MODP_4096 : MODP_2048}`);
  }
  const x = privateExponent(p);
  const e = modPow(g, x, p);
  talk.send(
    new Writer().byte(gex ? MSG2.GEX_INIT : MSG2.KEXDH_INIT).mpint(fromBig2(e)).build()
  );
  const reply = new Reader((await talk.expect(gex ? MSG2.GEX_REPLY : MSG2.KEXDH_REPLY)).subarray(1));
  const hostKeyBlob = reply.string();
  const f = toBig2(reply.mpint());
  const signature2 = reply.string();
  checkPublic(f, p, "Diffie-Hellman value");
  const secret = new Writer().mpint(fromBig2(modPow(f, x, p))).build();
  const fields = head(prefix, hostKeyBlob);
  if (gex) {
    fields.uint32(GEX_BITS.min).uint32(GEX_BITS.preferred).uint32(GEX_BITS.max).mpint(fromBig2(p)).mpint(fromBig2(g));
  }
  fields.mpint(fromBig2(e)).mpint(fromBig2(f)).raw(secret);
  return { hash, hostKeyBlob, signature: signature2, secret, exchangeHash: await digest(hash, fields.build()) };
}
function runKex(name, talk, prefix) {
  return name.startsWith("diffie-hellman-") ? dh(name, talk, prefix) : ecdh(name, talk, prefix);
}

// node_modules/@workeryard/undershell/src/transport/transport.ts
var CLIENT_VERSION = "SSH-2.0-undershell_0.1";
var MAX_BANNER = 8 * 1024;
var REKEY_BYTES = 2 ** 30;
var REKEY_PACKETS = 2 ** 28;
var Transport = class {
  #out = PLAIN;
  #in = PLAIN;
  #sequenceIn = 0;
  #sequenceOut = 0;
  #bytesIn = 0;
  #bytesOut = 0;
  #packetsIn = 0;
  #packetsOut = 0;
  #strictKex = false;
  #sending = Promise.resolve();
  #exchange = null;
  #failed = null;
  #closing = null;
  #reader;
  #writer;
  #socket;
  #preference;
  #options;
  #rekeyBytes;
  sessionId = new Uint8Array(0);
  hostKey = null;
  serverVersion = "";
  negotiated = null;
  /** Key exchanges completed, the first included: more than one means it has re-keyed. */
  keyExchanges = 0;
  /** What the server said it verifies (RFC 8308 server-sig-algs), or null if it did not say. */
  serverSignatureAlgorithms = null;
  constructor(socket, options = {}) {
    this.#socket = socket;
    this.#options = options;
    this.#preference = preference(options.algorithms);
    this.#rekeyBytes = options.rekeyAfterBytes ?? REKEY_BYTES;
    this.#reader = new Buffered(socket.readable);
    this.#writer = socket.writable.getWriter();
  }
  /** The version exchange and the first key exchange. */
  async handshake() {
    await this.exchangeVersions();
    this.#begin();
    for (; ; ) {
      const payload = await this.#readPacket();
      const type = payload[0];
      if (type === MSG.KEXINIT) return this.#run(payload);
      if (type === MSG.DISCONNECT) throw disconnected(payload);
      if (type === MSG.IGNORE || type === MSG.DEBUG) continue;
      throw new Error(`expected KEXINIT, got message ${type}`);
    }
  }
  /** Both sides announce themselves in plain text before anything else. */
  async exchangeVersions() {
    await this.#writer.write(new TextEncoder().encode(`${CLIENT_VERSION}\r
`));
    let spent = 0;
    for (; ; ) {
      const line = await this.#reader.line(MAX_BANNER);
      if (line.startsWith("SSH-")) {
        if (!line.startsWith("SSH-2.0-") && !line.startsWith("SSH-1.99-")) {
          throw new Error(`the server speaks ${line}, and this client only speaks 2.0`);
        }
        this.serverVersion = line;
        return line;
      }
      spent += line.length + 1;
      if (spent > MAX_BANNER)
        throw new Error("the server sent more banner than RFC 4253 allows before its version");
    }
  }
  /** Sends a payload, after any key exchange under way has finished. */
  async send(payload) {
    while (this.#exchange) await this.#exchange.done;
    return this.#enqueue(payload);
  }
  #enqueue(payload, after) {
    const next = this.#sending.then(async () => {
      if (this.#failed) throw toError(this.#failed);
      const packet = await this.#out.seal(payload, this.#sequenceOut);
      this.#sequenceOut = this.#sequenceOut + 1 >>> 0;
      this.#bytesOut += packet.length;
      this.#packetsOut++;
      await this.#writer.write(packet);
      after?.();
      if (this.#bytesOut > this.#rekeyBytes || this.#packetsOut > REKEY_PACKETS) this.#begin();
    });
    this.#sending = next.catch(() => {
    });
    return next;
  }
  async #readPacket() {
    const payload = await this.#in.open(this.#reader, this.#sequenceIn);
    this.#sequenceIn = this.#sequenceIn + 1 >>> 0;
    this.#bytesIn += payload.length;
    this.#packetsIn++;
    if (payload.length === 0) throw new Error("an empty packet");
    return payload;
  }
  /**
   * The next message a caller needs to act on. Housekeeping is dealt with
   * here: debug chatter dropped, the server's global requests declined, its
   * extensions noted, and a key exchange run to completion.
   */
  async receive() {
    for (; ; ) {
      if (!this.#exchange && (this.#bytesIn > this.#rekeyBytes || this.#packetsIn > REKEY_PACKETS))
        this.#begin();
      const payload = await this.#readPacket();
      const type = payload[0];
      if (type === MSG.DISCONNECT) throw disconnected(payload);
      if (type === MSG.IGNORE || type === MSG.DEBUG || type === MSG.UNIMPLEMENTED) continue;
      if (type === MSG.EXT_INFO) {
        this.serverSignatureAlgorithms = serverSignatureAlgorithms(payload) ?? this.serverSignatureAlgorithms;
        continue;
      }
      if (type === MSG.GLOBAL_REQUEST) {
        const reader = new Reader(payload.subarray(1));
        reader.skipString();
        if (reader.bool()) void this.send(new Uint8Array([MSG.REQUEST_FAILURE])).catch(() => {
        });
        continue;
      }
      if (type === MSG.KEXINIT) {
        await this.#run(payload);
        continue;
      }
      return payload;
    }
  }
  /** Sends our KEXINIT, once, and holds every other send until the exchange is over. */
  #begin() {
    if (this.#exchange) return;
    let settle;
    const done = new Promise((resolve, reject) => {
      settle = (error) => error === void 0 ? resolve() : reject(toError(error));
    });
    done.catch(() => {
    });
    const ours = kexinit(this.#preference, this.sessionId.length === 0);
    this.#exchange = { ours, done, settle };
    void this.#enqueue(ours).catch(() => {
    });
  }
  /** A key exchange message, where a strict first exchange allows nothing else. */
  async #expect(type, strict) {
    for (; ; ) {
      const payload = await this.#readPacket();
      if (payload[0] === type) return payload;
      if (payload[0] === MSG.DISCONNECT) throw disconnected(payload);
      const noise = payload[0] === MSG.IGNORE || payload[0] === MSG.DEBUG || payload[0] === MSG.UNIMPLEMENTED;
      if (noise && !strict) continue;
      throw new Error(
        `message ${payload[0]} arrived during the key exchange, where ${type} was due`
      );
    }
  }
  /** The rest of a key exchange, from the server's KEXINIT on. */
  async #run(theirs) {
    this.#begin();
    const exchange = this.#exchange;
    try {
      await this.#negotiateAndSwitch(exchange.ours, theirs);
      this.#bytesIn = this.#bytesOut = this.#packetsIn = this.#packetsOut = 0;
      this.#exchange = null;
      this.keyExchanges++;
      exchange.settle();
    } catch (error) {
      this.#failed = error;
      this.#exchange = null;
      exchange.settle(error);
      throw error;
    }
  }
  async #negotiateAndSwitch(ours, theirs) {
    const first = this.sessionId.length === 0;
    const chosen = negotiate(this.#preference, theirs);
    if (first) this.#strictKex = chosen.strictOffered;
    const strict = first && this.#strictKex;
    if (strict && this.#sequenceIn !== 1)
      throw new Error("strict KEX: the server sent something before KEXINIT");
    let dropGuess = chosen.dropGuess;
    const result = await runKex(
      chosen.kex,
      {
        send: (payload) => void this.#enqueue(payload).catch(() => {
        }),
        expect: async (type) => {
          if (dropGuess) {
            dropGuess = false;
            await this.#readPacket();
          }
          return this.#expect(type, strict);
        }
      },
      { clientVersion: CLIENT_VERSION, serverVersion: this.serverVersion, ours, theirs }
    );
    const { hostKeyBlob, signature: signature2, secret, exchangeHash: hash } = result;
    if (!await verifySignature(chosen.hostKey, hostKeyBlob, signature2, hash)) {
      throw new Error("the server's signature over the exchange hash does not check out");
    }
    await this.#acceptHostKey(chosen.hostKey, hostKeyBlob);
    if (first) this.sessionId = hash;
    const { outgoing, incoming } = await deriveCiphers(
      result.hash,
      secret,
      hash,
      this.sessionId,
      chosen
    );
    void this.#enqueue(new Uint8Array([MSG.NEWKEYS]), () => {
      this.#out = outgoing;
      if (this.#strictKex) this.#sequenceOut = 0;
    }).catch(() => {
    });
    await this.#expect(MSG.NEWKEYS, strict);
    this.#in = incoming;
    if (this.#strictKex) this.#sequenceIn = 0;
    const { kex, hostKey, cipher, mac } = chosen;
    this.negotiated = {
      kex,
      hostKey,
      cipher: cipher.out,
      mac: mac.out,
      strictKex: this.#strictKex
    };
  }
  async #acceptHostKey(signatureAlgorithm, blob) {
    if (this.hostKey) {
      if (!equalBytes(this.hostKey.blob, blob))
        throw new Error("the server presented a different host key on re-keying");
      return;
    }
    const key = {
      algorithm: new Reader(blob).text(),
      signatureAlgorithm,
      blob,
      fingerprint: await fingerprintOf(blob),
      publicKey: openSshPublicKey(blob)
    };
    await this.#options.checkHostKey?.(key);
    this.hostKey = key;
  }
  /** Says goodbye if the connection is up, then hangs up. Safe to call twice. */
  close() {
    this.#closing ??= this.#close();
    return this.#closing;
  }
  async #close() {
    if (!this.#failed && this.negotiated) {
      const goodbye = new Writer().byte(MSG.DISCONNECT).uint32(11).string("").string("").build();
      await this.#enqueue(goodbye).catch(() => {
      });
    }
    this.#failed ??= new Error("the connection is closed");
    this.#reader.cancel();
    await this.#writer.close().catch(() => {
    });
    await this.#socket.close?.().catch(() => {
    });
  }
};

// node_modules/@workeryard/undershell/src/client.ts
var MAX_JUMPS = 3;
var DEFAULT_TIMEOUT = 3e4;
function normalizeFingerprint(value) {
  return value.trim().replace(/^SHA256:/i, "").replace(/=+$/, "");
}
function hostKeyChecker(check) {
  const pinned = [check.hostKeyFingerprint ?? []].flat().map(normalizeFingerprint).filter(Boolean);
  if (pinned.length === 0 && !check.verifyHostKey) {
    throw new Error(
      "no host key fingerprint or verifyHostKey was given, and this client will not trust on first use"
    );
  }
  return async (key) => {
    if (pinned.length && !pinned.includes(key.fingerprint)) {
      const expected = pinned.map((print) => `SHA256:${print}`).join(" or ");
      throw new Error(
        `the ${key.algorithm} host key is SHA256:${key.fingerprint}, not the ${expected} expected`
      );
    }
    if (check.verifyHostKey && !await check.verifyHostKey(key)) {
      throw new Error(
        `the ${key.algorithm} host key SHA256:${key.fingerprint} was refused by verifyHostKey`
      );
    }
  };
}
async function withDeadline(work, ms, what, onTimeout) {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => {
      void onTimeout();
      reject(new Error(`${what} took longer than ${ms} ms`));
    }, ms);
  });
  try {
    return await Promise.race([work, deadline]);
  } finally {
    if (timer !== void 0) clearTimeout(timer);
  }
}
var SshClient = class _SshClient {
  constructor(connection, depth) {
    this.connection = connection;
    this.depth = depth;
  }
  #parent = null;
  get transport() {
    return this.connection.transport;
  }
  get hostKey() {
    return this.transport.hostKey;
  }
  get negotiated() {
    return this.transport.negotiated;
  }
  get serverVersion() {
    return this.transport.serverVersion;
  }
  /** Settles when the connection ends, whether it was closed or it failed. */
  get ended() {
    return this.connection.ended;
  }
  static connect(options) {
    return _SshClient.#connect(options, 0);
  }
  static async #connect(options, depth) {
    let checkHostKey;
    try {
      checkHostKey = hostKeyChecker(options);
    } catch (error) {
      await options.socket.close?.().catch(() => {
      });
      throw error;
    }
    const transport = new Transport(options.socket, {
      checkHostKey,
      ...options.algorithms && { algorithms: options.algorithms },
      ...options.rekeyAfterBytes && { rekeyAfterBytes: options.rekeyAfterBytes }
    });
    try {
      const login = async () => {
        await transport.handshake();
        await authenticate(transport, options.username, [options.auth].flat(), options.onBanner);
      };
      await withDeadline(
        login(),
        options.timeoutMs ?? DEFAULT_TIMEOUT,
        "connecting",
        () => transport.close()
      );
      return new _SshClient(new Connection(transport, options.keepalive), depth);
    } catch (error) {
      await transport.close();
      throw error;
    }
  }
  /** Opens a session channel and starts `start` on it. */
  async #session(options, start, data) {
    return prepare(await this.connection.open("session"), options, start, data);
  }
  /** Starts a command and hands back its streams, for output too large to hold or input to feed. */
  spawn(command, options = {}) {
    return this.#session(options, "exec", new Writer().string(command).build());
  }
  /** An interactive shell, with a pty unless `pty: false` is asked for. */
  shell(options = {}) {
    return this.#session({ ...options, pty: options.pty ?? true }, "shell");
  }
  /** A subsystem by name, such as `sftp` or `netconf`. */
  subsystem(name, options = {}) {
    return this.#session(options, "subsystem", new Writer().string(name).build());
  }
  /** Runs one command and reads it to the end. */
  async exec(command, options = {}) {
    const limit = options.maxOutputBytes ?? 1024 * 1024;
    options.signal?.throwIfAborted();
    const session = await this.spawn(command, options);
    const abort = () => void session.signal("KILL").finally(() => session.close()).catch(() => {
    });
    options.signal?.addEventListener("abort", abort, { once: true });
    const result = { stdout: "", stderr: "", exitStatus: null, truncated: false };
    const collect = async (stream, into) => {
      const decoder = new TextDecoder();
      let kept = 0;
      for await (const chunk of stream) {
        const room = limit - kept;
        if (chunk.length > room) result.truncated = true;
        if (room > 0) {
          result[into] += decoder.decode(chunk.subarray(0, room), { stream: true });
          kept += Math.min(room, chunk.length);
        }
      }
      result[into] += decoder.decode();
    };
    try {
      const writer = session.stdin.getWriter();
      const feeding = (async () => {
        if (options.stdin !== void 0) {
          const input = typeof options.stdin === "string" ? new TextEncoder().encode(options.stdin) : options.stdin;
          await writer.write(input);
        }
        await writer.close();
      })().catch(() => {
      });
      await Promise.all([
        collect(session.stdout, "stdout"),
        collect(session.stderr, "stderr"),
        feeding
      ]);
      const exit = await session.exit;
      options.signal?.throwIfAborted();
      result.exitStatus = exit.code;
      if (exit.signal) result.exitSignal = exit.signal;
      await session.close();
      return result;
    } finally {
      options.signal?.removeEventListener("abort", abort);
    }
  }
  /**
   * A TCP connection from the server to `host:port` (RFC 4254 §7.2), as a
   * `ByteSocket`: for a port forward, or to carry the next SSH connection.
   */
  forward(host, port, origin = { host: "127.0.0.1", port: 0 }) {
    return this.connection.open(
      "direct-tcpip",
      new Writer().string(host).uint32(port).string(origin.host).uint32(origin.port).build()
    );
  }
  /**
   * Connects to a host this server can reach, through it. The new client is
   * checked and authenticated on its own terms — its own host key, its own
   * credentials — and closing it closes the hop it rides on as well.
   */
  async jump(options) {
    if (this.depth >= MAX_JUMPS)
      throw new Error(`a target may sit behind at most ${MAX_JUMPS} jump hosts`);
    const { host, port = 22, ...rest } = options;
    const tunnel = await this.forward(host, port);
    const client = await _SshClient.#connect({ ...rest, socket: tunnel }, this.depth + 1);
    client.#parent = this;
    return client;
  }
  /** Starts an SFTP session on its own channel. Close it with `end()`. */
  async sftp() {
    return Sftp.start(await this.subsystem("sftp"));
  }
  /** Closes this connection, and any jump hosts it was reached through. */
  async close() {
    await this.connection.close();
    await this.#parent?.close();
  }
};
async function readHostKey(socket, options = {}) {
  const transport = new Transport(
    socket,
    options.algorithms ? { algorithms: options.algorithms } : {}
  );
  try {
    await transport.handshake();
    return {
      hostKey: transport.hostKey,
      serverVersion: transport.serverVersion,
      negotiated: transport.negotiated
    };
  } finally {
    await transport.close();
  }
}

// node_modules/@workeryard/undershell/src/workers/index.ts
async function openSocket(hostname, port = 22, timeoutMs = 1e4) {
  const socket = tcp({ hostname, port });
  let timer;
  try {
    await Promise.race([
      socket.opened,
      new Promise((_, reject) => {
        timer = setTimeout(() => {
          void socket.close().catch(() => {
          });
          reject(new Error(`no answer within ${timeoutMs} ms`));
        }, timeoutMs);
      })
    ]);
  } catch (error) {
    const said = error instanceof Error ? error.message : String(error);
    if (/HTTP-based service/i.test(said)) {
      throw new Error(
        `could not connect to ${hostname}:${port}: a Worker may not open TCP connections to Cloudflare's own IP ranges. A server behind Cloudflare is reached through Cloudflare Tunnel instead (\`tunnel\`).`,
        { cause: error }
      );
    }
    const hint = /proxy request failed/i.test(said) ? ". If the host is behind Cloudflare, a Worker cannot reach it over TCP; Cloudflare Tunnel (`tunnel`) can" : "";
    throw new Error(`could not connect to ${hostname}:${port}: ${said}${hint}`, { cause: error });
  } finally {
    if (timer !== void 0) clearTimeout(timer);
  }
  return { readable: socket.readable, writable: socket.writable, close: () => socket.close() };
}
async function openTunnel(options) {
  const headers = new Headers(options.headers);
  headers.set("Upgrade", "websocket");
  if (options.serviceToken) {
    headers.set("CF-Access-Client-Id", options.serviceToken.clientId);
    headers.set("CF-Access-Client-Secret", options.serviceToken.clientSecret);
  }
  if (options.accessToken) headers.set("Cf-Access-Token", options.accessToken);
  if (options.destination) headers.set("Cf-Access-Jump-Destination", options.destination);
  const response = await fetch(`https://${options.hostname}/`, { headers });
  const socket = response.webSocket;
  if (response.status !== 101 || !socket) {
    const hint = response.status === 302 || response.status === 403 ? "; Cloudflare Access wants a service token or an access token" : "";
    await response.body?.cancel();
    throw new Error(
      `the tunnel at ${options.hostname} answered ${response.status} instead of a WebSocket${hint}`
    );
  }
  socket.accept();
  return webSocketStream(socket);
}
async function connect(options) {
  const { host, port = 22, tunnel, jump = [], ...target } = options;
  const final = { ...target, host: host ?? "", port };
  const [first = final, ...rest] = [...jump, final];
  if (!tunnel && !first.host) throw new Error("connect needs a host, or a tunnel");
  const socket = tunnel ? await openTunnel(tunnel) : await openSocket(first.host, first.port ?? 22, options.timeoutMs);
  let client = await SshClient.connect({ ...first, socket });
  try {
    for (const hop of rest) client = await client.jump(hop);
  } catch (error) {
    await client.close();
    throw error;
  }
  return client;
}

// src/ssh.ts
async function probeHostKey(host, port) {
  const socket = await openSocket(host, port, 15e3);
  const { hostKey, serverVersion } = await readHostKey(socket);
  return { fpr: hostKey.fingerprint, serverVersion };
}
async function connectPassword(host, port, user, pass, fprs) {
  return connect({
    host,
    port,
    username: user,
    auth: { kind: "password", password: pass },
    hostKeyFingerprint: fprs,
    timeoutMs: 25e3
  });
}
async function connectKey(host, port, user, key, fprs) {
  return connect({
    host,
    port,
    username: user,
    auth: { kind: "privateKey", privateKey: key },
    hostKeyFingerprint: fprs,
    timeoutMs: 25e3
  });
}

// src/backup.ts
async function readAll(stream) {
  const chunks = [];
  const reader = stream.getReader();
  let total = 0;
  for (; ; ) {
    const { done, value } = await reader.read();
    if (done) break;
    if (value) {
      chunks.push(value);
      total += value.byteLength;
    }
  }
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    out.set(c, off);
    off += c.byteLength;
  }
  return out;
}
async function pullBackup(env) {
  const host = await currentDnsIp(env);
  if (!host) throw new Error("\u043D\u0435 \u0443\u0437\u043D\u0430\u0442\u044C \u0430\u0434\u0440\u0435\u0441 \u0432\u0445\u043E\u0434\u0430 \u0438\u0437 DNS");
  let fprs = await getEntryFpr(env);
  if (fprs.length === 0) {
    const { fpr } = await probeHostKey(host, Number(env.ENTRY_SSH_PORT));
    fprs = [fpr];
    await setEntryFpr(env, fprs);
  }
  const ssh = await connectKey(host, Number(env.ENTRY_SSH_PORT), env.ENTRY_USER, env.ENTRY_SSH_KEY, fprs);
  try {
    const r = await ssh.exec("/usr/local/bin/vpn-backup.sh 2>/dev/null | tail -1", {
      maxOutputBytes: 4096,
      signal: AbortSignal.timeout(12e4)
    });
    const path = r.stdout.trim();
    if (!path.startsWith("/")) throw new Error(`vpn-backup.sh \u043D\u0435 \u0434\u0430\u043B \u043F\u0443\u0442\u044C: ${path.slice(0, 120)}`);
    const sftp = await ssh.sftp();
    try {
      const bytes2 = await readAll(sftp.createReadStream(path));
      const name = path.split("/").pop() || "vpn-backup.tgz";
      return { name, bytes: bytes2 };
    } finally {
      await sftp.end();
    }
  } finally {
    await ssh.close();
  }
}
async function doBackup(env) {
  const { name, bytes: bytes2 } = await pullBackup(env);
  await putBackup(env, name, bytes2);
  return { name, size: bytes2.byteLength, bytes: bytes2 };
}

// src/label.ts
function sanitizeLabel(input) {
  let s = (input || "").trim();
  s = s.replace(/[\s/\\\u0000-\u001f\u007f]+/g, "-");
  s = s.replace(/[^\p{L}\p{N}._-]+/gu, "-");
  s = s.replace(/-+/g, "-").replace(/^-+|-+$/g, "");
  return s;
}
function uniqueLabel(base, existing) {
  const taken = /* @__PURE__ */ new Set();
  for (const e of existing) taken.add(e.toLowerCase());
  let label = base || "client";
  if (!taken.has(label.toLowerCase())) return label;
  for (let i = 2; i < 1e4; i++) {
    const cand = `${base}-${i}`;
    if (!taken.has(cand.toLowerCase())) return cand;
  }
  return `${base}-${Date.now()}`;
}

// src/migplan.ts
function chainConfigured(env) {
  return Boolean(env.EXIT_HOST && env.CHAIN_PORT);
}
function exitAccess(env) {
  return chainConfigured(env) && Boolean(env.EXIT_SSH_KEY || env.EXIT_SSH_PASS) && Boolean(env.EXIT_HOSTKEY_FPR);
}
var OCTET = "(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)";
var IPV4 = new RegExp(`^${OCTET}(\\.${OCTET}){3}$`);
function isIPv4(s) {
  return IPV4.test(s);
}
function chainPort(env) {
  const port = Number(env.CHAIN_PORT);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`\u043F\u043E\u0440\u0442 \u0446\u0435\u043F\u043E\u0447\u043A\u0438 \xAB${env.CHAIN_PORT}\xBB \u043D\u0435 \u0447\u0438\u0441\u043B\u043E`);
  return port;
}
function exitFw(env) {
  return env.EXIT_FW === "iptables" || env.EXIT_FW === "open" ? env.EXIT_FW : "ufw";
}
function exitHasFirewall(env) {
  return exitFw(env) !== "open";
}
function manualAllowCmd(env, ip) {
  const port = chainPort(env);
  switch (exitFw(env)) {
    case "open":
      return "";
    case "iptables":
      return `iptables -I INPUT 1 -p tcp -s ${ip} --dport ${port} -j ACCEPT`;
    default:
      return `ufw allow from ${ip} to any port ${port} proto tcp`;
  }
}
function exitCmds(env, newIp, oldIp = "") {
  if (!isIPv4(newIp)) throw new Error(`\xAB${newIp}\xBB \u043D\u0435 IPv4`);
  if (oldIp && !isIPv4(oldIp)) throw new Error(`\xAB${oldIp}\xBB \u043D\u0435 IPv4`);
  const port = chainPort(env);
  const s = env.EXIT_USER && env.EXIT_USER !== "root" ? "sudo -n " : "";
  const old = oldIp && oldIp !== newIp ? oldIp : "";
  const fw = exitFw(env);
  if (fw === "open") return "";
  if (fw === "iptables") {
    const rule = (ip) => `-p tcp -s ${ip} --dport ${port} -j ACCEPT`;
    const cmds2 = [`{ ${s}iptables -C INPUT ${rule(newIp)} 2>/dev/null || ${s}iptables -I INPUT 1 ${rule(newIp)}; }`];
    if (old) cmds2.push(`{ ${s}iptables -D INPUT ${rule(old)} 2>/dev/null || true; }`);
    cmds2.push(`{ { ${s}netfilter-persistent save || ${s}sh -c 'iptables-save > /etc/iptables/rules.v4'; } >/dev/null 2>&1 || true; }`);
    return cmds2.join(" && ");
  }
  const cmds = [`${s}ufw allow from ${newIp} to any port ${port} proto tcp comment 'vpn entry'`];
  if (old) cmds.push(`{ ${s}ufw --force delete allow from ${old} to any port ${port} proto tcp || true; }`);
  return cmds.join(" && ");
}
async function freshOrStored(takeFresh, stored, now = Date.now) {
  try {
    const r = await takeFresh();
    return { source: "fresh", size: r.size, createdAt: now() };
  } catch (e) {
    const msg = e.message || String(e);
    const s = await stored();
    if (s) return { source: "stored", size: s.size, createdAt: s.createdAt, error: msg };
    throw new Error(`\u0441\u0432\u0435\u0436\u0438\u0439 \u0431\u044D\u043A\u0430\u043F \u0441\u043D\u044F\u0442\u044C \u043D\u0435 \u0432\u044B\u0448\u043B\u043E (${msg}), \u0430 \u0441\u043E\u0445\u0440\u0430\u043D\u0451\u043D\u043D\u043E\u0433\u043E \u043D\u0435\u0442`);
  }
}

// src/migrate.ts
async function preflight(host, port) {
  return probeHostKey(host, port);
}
function bootstrap(env, token) {
  const base = env.SELF_ORIGIN.replace(/\/$/, "");
  return [
    "set -e",
    "cat >/root/.vpn-migrate.sh <<'EOS'",
    "#!/bin/bash",
    "set -euo pipefail",
    "cd /root",
    `curl -fsSL --retry 3 -o /root/.mig.tgz "${base}/dl/${token}"`,
    "rm -rf /root/.mig && mkdir -p /root/.mig",
    "tar -C /root/.mig -xzf /root/.mig.tgz",
    "bash /root/.mig/vpn-backup-*/restore.sh",
    "EOS",
    "chmod +x /root/.vpn-migrate.sh",
    `nohup bash -c '/root/.vpn-migrate.sh >/root/.vpn-migrate.log 2>&1; rc=$?; ip=$(curl -fsS --max-time 8 https://api.ipify.org || echo); curl -fsS --retry 3 --max-time 15 -X POST "${base}/migdone/${token}" -H "Content-Type: application/json" -d "{\\"rc\\":$rc,\\"ip\\":\\"$ip\\"}" || true' >/dev/null 2>&1 &`,
    "echo STARTED"
  ].join("\n");
}
async function launch(env, opts) {
  const ssh = await connectPassword(opts.host, opts.port, opts.user, opts.pass, [opts.fpr]);
  try {
    const r = await ssh.exec(bootstrap(env, opts.token), {
      maxOutputBytes: 8192,
      signal: AbortSignal.timeout(2e4)
    });
    if (!r.stdout.includes("STARTED")) {
      throw new Error(`\u043D\u0435 \u0443\u0434\u0430\u043B\u043E\u0441\u044C \u0437\u0430\u043F\u0443\u0441\u0442\u0438\u0442\u044C \u043F\u0435\u0440\u0435\u043D\u043E\u0441: ${(r.stderr || r.stdout).slice(0, 200)}`);
    }
  } finally {
    await ssh.close();
  }
}
async function runOnExit(env, cmd) {
  const fprs = JSON.parse(env.EXIT_HOSTKEY_FPR);
  const ssh = env.EXIT_SSH_KEY ? await connectKey(env.EXIT_HOST, Number(env.EXIT_PORT), env.EXIT_USER, env.EXIT_SSH_KEY, fprs) : await connectPassword(env.EXIT_HOST, Number(env.EXIT_PORT), env.EXIT_USER, env.EXIT_SSH_PASS || "", fprs);
  try {
    const r = await ssh.exec(cmd, { maxOutputBytes: 8192, signal: AbortSignal.timeout(2e4) });
    if (r.exitStatus !== 0) {
      throw new Error((r.stderr || r.stdout || `\u043A\u043E\u0434 ${r.exitStatus}`).trim().slice(0, 200));
    }
  } finally {
    await ssh.close();
  }
}
async function openExitFor(env, newIp) {
  const cmd = exitCmds(env, newIp);
  if (cmd) await runOnExit(env, cmd);
}
async function onDone(env, mig, rc, reportedIp, confirmedFpr) {
  if (rc !== 0) {
    const hint = chainConfigured(env) ? ` \u0415\u0441\u043B\u0438 \u0432 \u0436\u0443\u0440\u043D\u0430\u043B\u0435 \xAB\u0442\u0443\u043D\u043D\u0435\u043B\u044C \u043D\u0435 \u0440\u0430\u0431\u043E\u0442\u0430\u0435\u0442\xBB \u2014 \u043F\u0440\u043E\u0432\u0435\u0440\u044C, \u0447\u0442\u043E \u043D\u0430 \u0432\u044B\u0445\u043E\u0434\u0435 \u043E\u0442\u043A\u0440\u044B\u0442 \u043F\u043E\u0440\u0442 \u043D\u043E\u0432\u043E\u043C\u0443 \u0441\u0435\u0440\u0432\u0435\u0440\u0443: <code>${manualAllowCmd(env, reportedIp || mig.host)}</code>.` : "";
    return {
      ok: false,
      message: `\u041F\u0435\u0440\u0435\u043D\u043E\u0441 \u043D\u0430 ${mig.host} \u043D\u0435 \u0443\u0434\u0430\u043B\u0441\u044F (\u043A\u043E\u0434 ${rc}). \u0417\u0430\u0433\u043B\u044F\u043D\u0438 \u0432 /root/.vpn-migrate.log \u043D\u0430 \u043D\u043E\u0432\u043E\u043C \u0441\u0435\u0440\u0432\u0435\u0440\u0435.${hint} \u0414\u043E\u043C\u0435\u043D \u044F \u043D\u0435 \u0442\u0440\u043E\u0433\u0430\u043B.`
    };
  }
  const newIp = reportedIp || mig.host;
  const { previous } = await pointDnsTo(env, newIp);
  await setEntryFpr(env, [confirmedFpr]);
  let exitLine = "";
  if (chainConfigured(env) && exitHasFirewall(env)) {
    if (exitAccess(env)) {
      try {
        await runOnExit(env, exitCmds(env, newIp, previous));
        exitLine = "\u041F\u043E\u0440\u0442 \u0446\u0435\u043F\u043E\u0447\u043A\u0438 \u043D\u0430 \u0432\u044B\u0445\u043E\u0434\u0435 \u043E\u0442\u043A\u0440\u044B\u0442 \u043D\u043E\u0432\u043E\u043C\u0443 \u0441\u0435\u0440\u0432\u0435\u0440\u0443, \u0441\u0442\u0430\u0440\u043E\u043C\u0443 \u0437\u0430\u043A\u0440\u044B\u0442.\n";
      } catch (e) {
        exitLine = `\u26A0\uFE0F \u041D\u0430 \u0432\u044B\u0445\u043E\u0434\u0435 \u043D\u0435 \u0432\u044B\u0448\u043B\u043E (${e.message}) \u2014 \u043F\u0440\u043E\u0432\u0435\u0440\u044C \u0442\u0430\u043C: <code>${manualAllowCmd(env, newIp)}</code>
`;
      }
    } else if (previous && previous !== newIp) {
      exitLine = `\u041D\u0430 \u0432\u044B\u0445\u043E\u0434\u0435 \u043C\u043E\u0436\u043D\u043E \u0437\u0430\u043A\u0440\u044B\u0442\u044C \u043F\u043E\u0440\u0442 \u0441\u0442\u0430\u0440\u043E\u043C\u0443 \u0441\u0435\u0440\u0432\u0435\u0440\u0443 (\u043F\u0440\u0430\u0432\u0438\u043B\u043E \u0434\u043B\u044F ${previous}, \u043F\u043E\u0440\u0442 ${env.CHAIN_PORT}).
`;
    }
  }
  return {
    ok: true,
    message: `\u2705 \u0413\u043E\u0442\u043E\u0432\u043E. \u0412\u0445\u043E\u0434 \u043F\u0435\u0440\u0435\u0435\u0445\u0430\u043B \u043D\u0430 <b>${newIp}</b>, A-\u0437\u0430\u043F\u0438\u0441\u044C \u043E\u0431\u043D\u043E\u0432\u043B\u0435\u043D\u0430.
` + exitLine + `\u041A\u043B\u0438\u0435\u043D\u0442\u0430\u043C \u043D\u0438\u0447\u0435\u0433\u043E \u0434\u0435\u043B\u0430\u0442\u044C \u043D\u0435 \u043D\u0443\u0436\u043D\u043E. DNS \u0440\u0430\u0437\u043E\u0439\u0434\u0451\u0442\u0441\u044F \u0437\u0430 \u043F\u0430\u0440\u0443 \u043C\u0438\u043D\u0443\u0442.
\u0421\u0442\u0430\u0440\u044B\u0439 \u0441\u0435\u0440\u0432\u0435\u0440 \u043F\u043E\u043A\u0430 \u043D\u0435 \u0443\u0434\u0430\u043B\u044F\u0439.`
  };
}

// src/handlers.ts
async function findClient(env, id) {
  const list = await listClients(env);
  return list.find((c) => c.id === id);
}
async function show(tg, chat, messageId, s) {
  if (messageId) {
    try {
      await tg.edit(chat, messageId, s.text, s.kb);
      return;
    } catch {
    }
  }
  await tg.send(chat, s.text, s.kb);
}
async function handleUpdate(env, update) {
  const tg = new Telegram(env);
  if (update.callback_query) return onCallback(env, tg, update.callback_query);
  if (update.message) return onMessage(env, tg, update.message);
}
async function onMessage(env, tg, msg) {
  const from = msg.from?.id;
  const chat = msg.chat.id;
  const text = (msg.text || "").trim();
  const admin = await getAdmin(env);
  if (admin === null) {
    if ((text === "/start" || text.toLowerCase() === "\u043C\u0435\u043D\u044E") && from !== void 0) {
      await claimAdmin(env, from);
      await setDialog(env, { mode: "idle" });
      await tg.send(chat, "\u0413\u043E\u0442\u043E\u0432\u043E \u2014 \u0442\u0435\u043F\u0435\u0440\u044C \u044D\u0442\u043E\u0442 \u0431\u043E\u0442 \u0442\u0432\u043E\u0439. " + mainMenu().text, mainMenu().kb);
    }
    return;
  }
  if (from !== admin) return;
  if (text === "/start" || text.toLowerCase() === "\u043C\u0435\u043D\u044E") {
    await setDialog(env, { mode: "idle" });
    await tg.send(chat, mainMenu().text, mainMenu().kb);
    return;
  }
  const dialog = await getDialog(env);
  switch (dialog.mode) {
    case "add_name":
      return addClientFromName(env, tg, chat, text);
    case "mig_host":
      return migGotHost(env, tg, chat, text);
    case "mig_user":
      return migGotUser(env, tg, chat, dialog.host, text);
    case "mig_pass":
      return migGotPass(env, tg, chat, dialog.host, dialog.user, text);
    default:
      await tg.send(chat, "\u041D\u0435 \u043F\u043E\u043D\u044F\u043B. \u041E\u0442\u043A\u0440\u043E\u0439 \u043C\u0435\u043D\u044E: /start", mainMenu().kb);
  }
}
async function onCallback(env, tg, cq) {
  const admin = await getAdmin(env);
  if (admin === null || cq.from.id !== admin) {
    await tg.answer(cq.id, "\u041D\u0435\u043B\u044C\u0437\u044F", true);
    return;
  }
  const chat = cq.message?.chat.id ?? cq.from.id;
  const mid = cq.message?.message_id;
  const data = cq.data || "";
  const [key, arg] = data.split(":");
  try {
    switch (key) {
      case "m":
        await tg.answer(cq.id);
        return show(tg, chat, mid, mainMenu());
      case "cl": {
        await tg.answer(cq.id);
        const [clients, online] = await Promise.all([listClients(env), onlineEmails(env)]);
        return show(tg, chat, mid, clientList(clients, online, Number(arg) || 0));
      }
      case "c": {
        await tg.answer(cq.id);
        return showCard(env, tg, chat, mid, Number(arg));
      }
      case "cs": {
        await tg.answer(cq.id);
        const c = await findClient(env, Number(arg));
        if (!c) return show(tg, chat, mid, errorScreen("\u043A\u043B\u0438\u0435\u043D\u0442 \u043D\u0435 \u043D\u0430\u0439\u0434\u0435\u043D", "cl"));
        return show(tg, chat, mid, subLinkScreen(c, subLink(env, c.subId)));
      }
      case "cx": {
        const c = await findClient(env, Number(arg));
        if (!c) {
          await tg.answer(cq.id);
          return show(tg, chat, mid, errorScreen("\u043A\u043B\u0438\u0435\u043D\u0442 \u043D\u0435 \u043D\u0430\u0439\u0434\u0435\u043D", "cl"));
        }
        await setEnabled(env, c, !c.enable);
        await tg.answer(cq.id, c.enable ? "\u0412\u044B\u043A\u043B\u044E\u0447\u0435\u043D" : "\u0412\u043A\u043B\u044E\u0447\u0451\u043D");
        return showCard(env, tg, chat, mid, c.id);
      }
      case "cd": {
        await tg.answer(cq.id);
        const c = await findClient(env, Number(arg));
        if (!c) return show(tg, chat, mid, errorScreen("\u043A\u043B\u0438\u0435\u043D\u0442 \u043D\u0435 \u043D\u0430\u0439\u0434\u0435\u043D", "cl"));
        return show(tg, chat, mid, confirmDelete(c));
      }
      case "cd!": {
        const c = await findClient(env, Number(arg));
        if (c) await deleteClient(env, c.email);
        await tg.answer(cq.id, "\u0423\u0434\u0430\u043B\u0451\u043D");
        const [clients, online] = await Promise.all([listClients(env), onlineEmails(env)]);
        return show(tg, chat, mid, clientList(clients, online, 0));
      }
      case "ca":
        await tg.answer(cq.id);
        await setDialog(env, { mode: "add_name" });
        return show(tg, chat, mid, {
          text: "\u041A\u0430\u043A \u043D\u0430\u0437\u0432\u0430\u0442\u044C \u043D\u043E\u0432\u043E\u0433\u043E \u043A\u043B\u0438\u0435\u043D\u0442\u0430? \u041F\u0440\u0438\u0448\u043B\u0438 \u0438\u043C\u044F (\u043D\u0430\u043F\u0440\u0438\u043C\u0435\u0440, \xAB\u0412\u0430\u0441\u044F\xBB).",
          kb: [[{ text: "\u041E\u0442\u043C\u0435\u043D\u0430", data: "cl" }]]
        });
      case "st": {
        await tg.answer(cq.id, "\u0421\u043E\u0431\u0438\u0440\u0430\u044E\u2026");
        return showStats(env, tg, chat, mid);
      }
      case "bn": {
        await tg.answer(cq.id, "\u041F\u0440\u043E\u0432\u0435\u0440\u044F\u044E, \u043F\u043E\u0434\u043E\u0436\u0434\u0438\u2026");
        return runBanCheck(env, tg, chat, mid);
      }
      case "bk": {
        await tg.answer(cq.id, "\u0421\u043D\u0438\u043C\u0430\u044E \u0431\u044D\u043A\u0430\u043F\u2026");
        return runBackup(env, tg, chat, mid);
      }
      case "mg":
        await tg.answer(cq.id, "\u0421\u043D\u0438\u043C\u0430\u044E \u0441\u0432\u0435\u0436\u0438\u0439 \u0431\u044D\u043A\u0430\u043F\u2026");
        return migStart(env, tg, chat, mid);
      case "mgo":
        return migConfirm(env, tg, cq, chat, mid);
      default:
        await tg.answer(cq.id);
    }
  } catch (e) {
    await tg.answer(cq.id).catch(() => {
    });
    await show(tg, chat, mid, errorScreen(e.message || "\u043E\u0448\u0438\u0431\u043A\u0430", "m"));
  }
}
async function showCard(env, tg, chat, mid, id) {
  const [c, online] = await Promise.all([findClient(env, id), onlineEmails(env)]);
  if (!c) return show(tg, chat, mid, errorScreen("\u043A\u043B\u0438\u0435\u043D\u0442 \u043D\u0435 \u043D\u0430\u0439\u0434\u0435\u043D", "cl"));
  return show(tg, chat, mid, clientCard(c, online.has(c.email), subLink(env, c.subId)));
}
async function showStats(env, tg, chat, mid) {
  const [status, clients, online] = await Promise.all([
    serverStatus(env),
    listClients(env),
    onlineEmails(env)
  ]);
  const enabled = clients.filter((c) => c.enable).length;
  const on = clients.filter((c) => c.enable && online.has(c.email)).length;
  return show(tg, chat, mid, stats(status, clients.length, enabled, on));
}
async function runBanCheck(env, tg, chat, mid) {
  await show(tg, chat, mid, working("\u041F\u0440\u043E\u0432\u0435\u0440\u044F\u044E IP \u0432\u0445\u043E\u0434\u0430 \u0438\u0437 \u0420\u043E\u0441\u0441\u0438\u0438"));
  const ip = await currentDnsIp(env);
  if (!ip) return show(tg, chat, mid, errorScreen(`\u0432 DNS \u043D\u0435\u0442 A-\u0437\u0430\u043F\u0438\u0441\u0438 ${env.DNS_NAME}`, "m"));
  const res = await checkBanGlobalping(env, ip, Number(env.ENTRY_SSH_PORT));
  return show(tg, chat, mid, banResult(res));
}
async function runBackup(env, tg, chat, mid) {
  await show(tg, chat, mid, working("\u0421\u043D\u0438\u043C\u0430\u044E \u0431\u044D\u043A\u0430\u043F \u0441\u043E \u0432\u0445\u043E\u0434\u0430"));
  try {
    const { size } = await doBackup(env);
    await show(tg, chat, mid, {
      text: `\u2705 \u0411\u044D\u043A\u0430\u043F \u0441\u043D\u044F\u0442 (${(size / 1024).toFixed(0)} \u041A\u0411) \u0438 \u0441\u043E\u0445\u0440\u0430\u043D\u0451\u043D \u0432 \u0445\u0440\u0430\u043D\u0438\u043B\u0438\u0449\u0435 Cloudflare. \u0418\u0437 \u043D\u0435\u0433\u043E \u0434\u0435\u043B\u0430\u0435\u0442\u0441\u044F \u043F\u0435\u0440\u0435\u0435\u0437\u0434.`,
      kb: [[{ text: "\u2190 \u041C\u0435\u043D\u044E", data: "m" }]]
    });
  } catch (e) {
    await show(tg, chat, mid, errorScreen(`\u0431\u044D\u043A\u0430\u043F \u043D\u0435 \u0432\u044B\u0448\u0435\u043B: ${e.message}`, "m"));
  }
}
async function addClientFromName(env, tg, chat, name) {
  await setDialog(env, { mode: "idle" });
  if (!name) return void tg.send(chat, "\u041F\u0443\u0441\u0442\u043E\u0435 \u0438\u043C\u044F. \u041D\u0430\u0436\u043C\u0438 \u2795 \u0414\u043E\u0431\u0430\u0432\u0438\u0442\u044C \u0435\u0449\u0451 \u0440\u0430\u0437.", mainMenu().kb);
  const base = sanitizeLabel(name) || "client";
  const existing = await listClients(env);
  const label = uniqueLabel(base, existing.map((c) => c.email));
  const inboundId = await firstInboundId(env);
  await createClient(env, inboundId, label, name.slice(0, 80));
  const after = await listClients(env);
  const created = after.find((c) => c.email === label);
  if (!created) return void tg.send(chat, "\u041A\u043B\u0438\u0435\u043D\u0442 \u0441\u043E\u0437\u0434\u0430\u043D, \u043D\u043E \u043D\u0435 \u043D\u0430\u0448\u0451\u043B\u0441\u044F \u043F\u0440\u0438 \u043F\u0435\u0440\u0435\u0447\u0438\u0442\u044B\u0432\u0430\u043D\u0438\u0438 \u2014 \u043E\u0442\u043A\u0440\u043E\u0439 \u0441\u043F\u0438\u0441\u043E\u043A.", mainMenu().kb);
  await tg.send(
    chat,
    `\u2705 \u041A\u043B\u0438\u0435\u043D\u0442 <b>${esc(name)}</b> \u0441\u043E\u0437\u0434\u0430\u043D. \u0421\u0441\u044B\u043B\u043A\u0430 \u043D\u0430 \u043F\u043E\u0434\u043F\u0438\u0441\u043A\u0443 \u2014 \u043E\u0442\u043F\u0440\u0430\u0432\u044C \u0435\u0451 \u0434\u0440\u0443\u0433\u0443:

<code>${esc(subLink(env, created.subId))}</code>`,
    [[{ text: "\u041E\u0442\u043A\u0440\u044B\u0442\u044C \u043A\u0430\u0440\u0442\u043E\u0447\u043A\u0443", data: `c:${created.id}` }], [{ text: "\u2190 \u041A\u043B\u0438\u0435\u043D\u0442\u044B", data: "cl" }]]
  );
}
async function migStart(env, tg, chat, mid) {
  await show(tg, chat, mid, working("\u0421\u043D\u0438\u043C\u0430\u044E \u0441\u0432\u0435\u0436\u0438\u0439 \u0431\u044D\u043A\u0430\u043F \u0441\u043E \u0441\u0442\u0430\u0440\u043E\u0433\u043E \u0441\u0435\u0440\u0432\u0435\u0440\u0430"));
  let pick2;
  try {
    pick2 = await freshOrStored(
      async () => ({ size: (await doBackup(env)).size }),
      () => backupMeta(env)
    );
  } catch (e) {
    await setDialog(env, { mode: "idle" });
    return show(tg, chat, mid, errorScreen(`\u043F\u0435\u0440\u0435\u0435\u0437\u0434 \u043D\u0435 \u043D\u0430\u0447\u0430\u0442: ${e.message}`, "m"));
  }
  const kb = (pick2.size / 1024).toFixed(0);
  const line = pick2.source === "fresh" ? `\u2705 \u0421\u0432\u0435\u0436\u0438\u0439 \u0431\u044D\u043A\u0430\u043F \u0441\u043D\u044F\u0442 (${kb} \u041A\u0411).` : `\u26A0\uFE0F \u0421\u0442\u0430\u0440\u044B\u0439 \u0441\u0435\u0440\u0432\u0435\u0440 \u043D\u0435 \u043E\u0442\u0432\u0435\u0442\u0438\u043B (${esc(pick2.error || "")}) \u2014 \u043F\u0435\u0440\u0435\u043D\u0435\u0441\u0443 \u0438\u0437 \u0441\u043E\u0445\u0440\u0430\u043D\u0451\u043D\u043D\u043E\u0433\u043E \u0431\u044D\u043A\u0430\u043F\u0430 (\u0441\u043D\u044F\u0442 ${ago(pick2.createdAt)}, ${kb} \u041A\u0411). \u041A\u043B\u0438\u0435\u043D\u0442\u044B, \u0434\u043E\u0431\u0430\u0432\u043B\u0435\u043D\u043D\u044B\u0435 \u043F\u043E\u0441\u043B\u0435 \u043D\u0435\u0433\u043E, \u043D\u0435 \u043F\u0435\u0440\u0435\u043D\u0435\u0441\u0443\u0442\u0441\u044F.`;
  await setDialog(env, { mode: "mig_host" });
  return show(tg, chat, mid, {
    text: `<b>\u041F\u0435\u0440\u0435\u0435\u0437\u0434 \u043D\u0430 \u043D\u043E\u0432\u044B\u0439 \u0441\u0435\u0440\u0432\u0435\u0440</b>

${line}

\u041F\u0440\u0438\u0448\u043B\u0438 IP \u043D\u043E\u0432\u043E\u0433\u043E \u0441\u0435\u0440\u0432\u0435\u0440\u0430 (\u0447\u0438\u0441\u0442\u044B\u0439 Ubuntu/Debian, \u0432\u0445\u043E\u0434 \u043F\u043E root). \u042F \u0437\u0430\u0439\u0434\u0443, \u043E\u043D \u0441\u0430\u043C \u043F\u043E\u0434\u043D\u0438\u043C\u0435\u0442\u0441\u044F \u0438\u0437 \u0431\u044D\u043A\u0430\u043F\u0430, \u0438 \u044F \u043F\u0435\u0440\u0435\u043A\u043B\u044E\u0447\u0443 \u0434\u043E\u043C\u0435\u043D.`,
    kb: [[{ text: "\u041E\u0442\u043C\u0435\u043D\u0430", data: "m" }]]
  });
}
function manualExitLine(env, ip, why2) {
  return `

\u26A0\uFE0F \u041F\u0435\u0440\u0435\u0434 \xAB\u041F\u043E\u0435\u0445\u0430\u043B\u0438\xBB \u043E\u0442\u043A\u0440\u043E\u0439 \u043D\u0430 \u0432\u044B\u0445\u043E\u0434\u0435 ${esc(env.EXIT_HOST)} \u043F\u043E\u0440\u0442 \u043D\u043E\u0432\u043E\u043C\u0443 \u0441\u0435\u0440\u0432\u0435\u0440\u0443` + (why2 ? ` (\u0441\u0430\u043C \u043D\u0435 \u0441\u043C\u043E\u0433: ${esc(why2)})` : "") + `, \u0438\u043D\u0430\u0447\u0435 \u043E\u043D \u043D\u0435 \u043F\u0440\u043E\u0439\u0434\u0451\u0442 \u043F\u0440\u043E\u0432\u0435\u0440\u043A\u0443 \u0442\u0443\u043D\u043D\u0435\u043B\u044F \u0438 \u044F \u043D\u0435 \u043F\u0435\u0440\u0435\u043A\u043B\u044E\u0447\u0443 \u0434\u043E\u043C\u0435\u043D:
<code>${esc(manualAllowCmd(env, ip))}</code>
AWS, Oracle \u2014 \u0435\u0449\u0451 \u0438 \u0432 \u043F\u0430\u043D\u0435\u043B\u0438 \u0445\u043E\u0441\u0442\u0435\u0440\u0430.`;
}
async function migGotHost(env, tg, chat, host) {
  const ip = host.trim();
  if (!/^[0-9a-zA-Z.:-]{3,100}$/.test(ip)) {
    return void tg.send(chat, "\u042D\u0442\u043E \u043D\u0435 \u043F\u043E\u0445\u043E\u0436\u0435 \u043D\u0430 IP \u0438\u043B\u0438 \u0438\u043C\u044F. \u041F\u0440\u0438\u0448\u043B\u0438 \u0435\u0449\u0451 \u0440\u0430\u0437 \u0438\u043B\u0438 /start \u0434\u043B\u044F \u043E\u0442\u043C\u0435\u043D\u044B.");
  }
  await setDialog(env, { mode: "mig_user", host: ip });
  await tg.send(chat, `\u0421\u0435\u0440\u0432\u0435\u0440: <code>${esc(ip)}</code>
\u041F\u043E\u0434 \u043A\u0430\u043A\u0438\u043C \u043F\u043E\u043B\u044C\u0437\u043E\u0432\u0430\u0442\u0435\u043B\u0435\u043C \u0437\u0430\u0445\u043E\u0434\u0438\u0442\u044C? \u041F\u0440\u0438\u0448\u043B\u0438 <code>root</code> (\u0438\u043B\u0438 \u0434\u0440\u0443\u0433\u043E\u0433\u043E \u0441 \u0435\u0433\u043E \u043F\u0430\u0440\u043E\u043B\u0435\u043C).`);
}
async function migGotUser(env, tg, chat, host, user) {
  const u = user.trim() || "root";
  if (!/^[a-z_][a-z0-9_-]{0,31}$/.test(u)) return void tg.send(chat, "\u0418\u043C\u044F \u043F\u043E\u043B\u044C\u0437\u043E\u0432\u0430\u0442\u0435\u043B\u044F \u0441\u0442\u0440\u0430\u043D\u043D\u043E\u0435. \u041F\u0440\u0438\u0448\u043B\u0438 \u0435\u0449\u0451 \u0440\u0430\u0437.");
  await setDialog(env, { mode: "mig_pass", host, user: u });
  await tg.send(chat, `\u041F\u043E\u043B\u044C\u0437\u043E\u0432\u0430\u0442\u0435\u043B\u044C: <code>${esc(u)}</code>
\u0422\u0435\u043F\u0435\u0440\u044C \u043F\u0440\u0438\u0448\u043B\u0438 \u043F\u0430\u0440\u043E\u043B\u044C \u043E\u0442 \u043D\u043E\u0432\u043E\u0433\u043E \u0441\u0435\u0440\u0432\u0435\u0440\u0430. \u042F \u0443\u0434\u0430\u043B\u044E \u044D\u0442\u043E \u0441\u043E\u043E\u0431\u0449\u0435\u043D\u0438\u0435 \u0438\u0437 \u0434\u0438\u0430\u043B\u043E\u0433\u0430 \u043F\u043E\u0441\u043B\u0435 \u043F\u0440\u043E\u0432\u0435\u0440\u043A\u0438.`);
}
async function migGotPass(env, tg, chat, host, user, pass) {
  if (!pass) return void tg.send(chat, "\u041F\u0443\u0441\u0442\u043E\u0439 \u043F\u0430\u0440\u043E\u043B\u044C. \u041F\u0440\u0438\u0448\u043B\u0438 \u0435\u0449\u0451 \u0440\u0430\u0437.");
  const port = 22;
  await tg.send(chat, "\u23F3 \u041F\u0440\u043E\u0432\u0435\u0440\u044F\u044E \u0441\u0435\u0440\u0432\u0435\u0440 \u0438 \u0441\u043D\u0438\u043C\u0430\u044E \u043E\u0442\u043F\u0435\u0447\u0430\u0442\u043E\u043A \u043A\u043B\u044E\u0447\u0430\u2026");
  let fpr;
  let serverVersion;
  try {
    const pf = await preflight(host, port);
    fpr = pf.fpr;
    serverVersion = pf.serverVersion;
  } catch (e) {
    await setDialog(env, { mode: "idle" });
    return void tg.send(chat, `\u041D\u0435 \u0434\u043E\u0441\u0442\u0443\u0447\u0430\u043B\u0441\u044F \u0434\u043E ${esc(host)}:${port} \u2014 ${esc(e.message)}. \u041F\u0440\u043E\u0432\u0435\u0440\u044C IP \u0438 \u0447\u0442\u043E \u0441\u0435\u0440\u0432\u0435\u0440 \u0432\u043A\u043B\u044E\u0447\u0451\u043D. /start`);
  }
  let exitLine = "";
  if (chainConfigured(env) && exitHasFirewall(env)) {
    let ip = host;
    try {
      if (!isIPv4(ip)) ip = await resolveIPv4(host);
    } catch {
      ip = "";
    }
    if (ip && exitAccess(env)) {
      try {
        await openExitFor(env, ip);
        exitLine = `

\u2705 \u041D\u0430 \u0432\u044B\u0445\u043E\u0434\u0435 ${esc(env.EXIT_HOST)} \u043F\u043E\u0440\u0442 \u0446\u0435\u043F\u043E\u0447\u043A\u0438 \u0434\u043B\u044F \u043D\u0435\u0433\u043E \u043E\u0442\u043A\u0440\u044B\u0442.`;
      } catch (e) {
        exitLine = manualExitLine(env, ip, e.message);
      }
    } else {
      exitLine = manualExitLine(env, ip || "IP_\u041D\u041E\u0412\u041E\u0413\u041E_\u0421\u0415\u0420\u0412\u0415\u0420\u0410", ip ? "" : "\u043D\u0435 \u0443\u0437\u043D\u0430\u043B \u0435\u0433\u043E IPv4");
    }
  }
  await setDialog(env, { mode: "mig_confirm", host, user, pass, port, fpr, serverVersion });
  await tg.send(
    chat,
    `\u0421\u0435\u0440\u0432\u0435\u0440 <code>${esc(host)}</code> \u043F\u0440\u0435\u0434\u0441\u0442\u0430\u0432\u0438\u043B\u0441\u044F:
<code>${esc(serverVersion)}</code>
\u043A\u043B\u044E\u0447 <code>${esc(fpr)}</code>` + exitLine + `

\u0415\u0441\u043B\u0438 \u044D\u0442\u043E \u0442\u0432\u043E\u0439 \u043D\u043E\u0432\u044B\u0439 \u0441\u0435\u0440\u0432\u0435\u0440 \u2014 \u043F\u0440\u043E\u0434\u043E\u043B\u0436\u0430\u0435\u043C. \u041E\u043D \u0441\u043A\u0430\u0447\u0430\u0435\u0442 \u0431\u044D\u043A\u0430\u043F \u0438 \u043F\u043E\u0434\u043D\u0438\u043C\u0435\u0442\u0441\u044F \u0441\u0430\u043C.`,
    [[{ text: "\u2705 \u041F\u043E\u0435\u0445\u0430\u043B\u0438", data: "mgo" }], [{ text: "\u041E\u0442\u043C\u0435\u043D\u0430", data: "m" }]]
  );
}
async function migConfirm(env, tg, cq, chat, mid) {
  const dialog = await getDialog(env);
  if (dialog.mode !== "mig_confirm") {
    await tg.answer(cq.id);
    return show(tg, chat, mid, errorScreen("\u043F\u0435\u0440\u0435\u0435\u0437\u0434 \u0443\u0436\u0435 \u043D\u0435 \u0432 \u0442\u043E\u043C \u0441\u043E\u0441\u0442\u043E\u044F\u043D\u0438\u0438, \u043D\u0430\u0447\u043D\u0438 \u0437\u0430\u043D\u043E\u0432\u043E", "m"));
  }
  await tg.answer(cq.id, "\u0417\u0430\u043F\u0443\u0441\u043A\u0430\u044E\u2026");
  await setDialog(env, { mode: "idle" });
  await show(tg, chat, mid, working("\u0417\u0430\u043F\u0443\u0441\u043A\u0430\u044E \u043F\u0435\u0440\u0435\u043D\u043E\u0441 \u043D\u0430 \u043D\u043E\u0432\u043E\u043C \u0441\u0435\u0440\u0432\u0435\u0440\u0435"));
  try {
    if (!await backupMeta(env)) throw new Error("\u043D\u0435\u0442 \u0431\u044D\u043A\u0430\u043F\u0430 \u2014 \u043D\u0430\u0447\u043D\u0438 \u043F\u0435\u0440\u0435\u0435\u0437\u0434 \u0437\u0430\u043D\u043E\u0432\u043E");
    const token = crypto.randomUUID().replace(/-/g, "");
    await startMigration(env, {
      token,
      chatId: String(chat),
      host: dialog.host,
      startedAt: Date.now(),
      status: "running"
    });
    await env.STATE.put(`migfpr:${token}`, dialog.fpr, { expirationTtl: 1800 });
    await launch(env, {
      host: dialog.host,
      port: dialog.port,
      user: dialog.user,
      pass: dialog.pass,
      fpr: dialog.fpr,
      token
    });
    await show(tg, chat, mid, {
      text: `\u{1F69A} \u041F\u0435\u0440\u0435\u043D\u043E\u0441 \u0437\u0430\u043F\u0443\u0449\u0435\u043D \u043D\u0430 <b>${esc(dialog.host)}</b>. \u0421\u0435\u0440\u0432\u0435\u0440 \u0441\u043A\u0430\u0447\u0438\u0432\u0430\u0435\u0442 \u0431\u044D\u043A\u0430\u043F \u0438 \u043F\u043E\u0434\u043D\u0438\u043C\u0430\u0435\u0442\u0441\u044F \u2014 \u044D\u0442\u043E \u043F\u0430\u0440\u0430 \u043C\u0438\u043D\u0443\u0442.
\u041A\u0430\u043A \u0437\u0430\u043A\u043E\u043D\u0447\u0438\u0442, \u044F \u043F\u0435\u0440\u0435\u043A\u043B\u044E\u0447\u0443 \u0434\u043E\u043C\u0435\u043D \u0438 \u043D\u0430\u043F\u0438\u0448\u0443 \u0441\u044E\u0434\u0430.`,
      kb: [[{ text: "\u2190 \u041C\u0435\u043D\u044E", data: "m" }]]
    });
  } catch (e) {
    await show(tg, chat, mid, errorScreen(`\u043D\u0435 \u0443\u0434\u0430\u043B\u043E\u0441\u044C \u0437\u0430\u043F\u0443\u0441\u0442\u0438\u0442\u044C \u043F\u0435\u0440\u0435\u043D\u043E\u0441: ${e.message}`, "m"));
  }
}

// src/schedule.ts
var BACKUP_UTC_HOUR = 0;
function isDailyBackupRun(d) {
  return d.getUTCHours() === BACKUP_UTC_HOUR;
}

// src/selftest.ts
var SELFTEST_PARTS = ["base", "entry", "exit"];
var why = (e) => (e?.message || String(e)).slice(0, 200);
async function runTrue(open, cmd) {
  try {
    const ssh = await open();
    try {
      const r = await ssh.exec(cmd, { maxOutputBytes: 4096, signal: AbortSignal.timeout(2e4) });
      return r.exitStatus === 0 ? { ok: true } : { ok: false, error: (r.stderr || `\u043A\u043E\u0434 ${r.exitStatus}`).trim().slice(0, 200) };
    } finally {
      await ssh.close();
    }
  } catch (e) {
    return { ok: false, error: why(e) };
  }
}
async function runSelftest(env, part) {
  if (part === "base") {
    const [panel, dns, webhook, admin] = await Promise.all([
      listClients(env).then(
        (c) => ({ ok: true, clients: c.length }),
        (e) => ({ ok: false, error: why(e) })
      ),
      currentDnsIp(env).then(
        (ip) => ip ? { ok: true, ip } : { ok: false, error: `\u043D\u0435\u0442 A-\u0437\u0430\u043F\u0438\u0441\u0438 ${env.DNS_NAME}` },
        (e) => ({ ok: false, error: why(e) })
      ),
      new Telegram(env).webhookInfo().then(
        (w) => ({ ok: Boolean(w.url), url: w.url, ...w.last_error_message ? { error: w.last_error_message } : {} }),
        (e) => ({ ok: false, error: why(e) })
      ),
      getAdmin(env).then((a) => ({ ok: a !== null }))
    ]);
    return { panel, dns, webhook, admin };
  }
  if (part === "entry") {
    let host = "";
    let fprs2 = [];
    try {
      host = await currentDnsIp(env);
      fprs2 = await getEntryFpr(env);
    } catch (e) {
      return { ok: false, error: why(e) };
    }
    if (!host) return { ok: false, error: `\u043D\u0435\u0442 A-\u0437\u0430\u043F\u0438\u0441\u0438 ${env.DNS_NAME}` };
    if (!fprs2.length) return { ok: false, error: "\u043D\u0435\u0442 \u043E\u0442\u043F\u0435\u0447\u0430\u0442\u043A\u0430 \u043A\u043B\u044E\u0447\u0430 \u0432\u0445\u043E\u0434\u0430 (entry:fpr)" };
    return runTrue(() => connectKey(host, Number(env.ENTRY_SSH_PORT), env.ENTRY_USER, env.ENTRY_SSH_KEY, fprs2), "true");
  }
  if (!exitAccess(env)) return { skipped: true };
  let fprs;
  try {
    fprs = JSON.parse(env.EXIT_HOSTKEY_FPR);
  } catch {
    return { ok: false, error: "EXIT_HOSTKEY_FPR \u043D\u0435 JSON" };
  }
  const cmd = env.EXIT_USER && env.EXIT_USER !== "root" ? "sudo -n true" : "true";
  return runTrue(
    () => env.EXIT_SSH_KEY ? connectKey(env.EXIT_HOST, Number(env.EXIT_PORT), env.EXIT_USER, env.EXIT_SSH_KEY, fprs) : connectPassword(env.EXIT_HOST, Number(env.EXIT_PORT), env.EXIT_USER, env.EXIT_SSH_PASS || "", fprs),
    cmd
  );
}

// src/index.ts
var sleep2 = (ms) => new Promise((r) => setTimeout(r, ms));
function verdictOf(r) {
  return r.status === "ok" ? r.ports[0]?.verdict || "UNKNOWN" : "UNKNOWN";
}
var CONCLUSIVE = /* @__PURE__ */ new Set(["OK", "PARTIAL", "RU_BLOCKED", "CLOSED"]);
async function alreadySeen(env, updateId) {
  const key = `upd:${updateId}`;
  if (await env.STATE.get(key)) return true;
  await env.STATE.put(key, "1", { expirationTtl: 300 });
  return false;
}
var index_default = {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    const path = url.pathname;
    if (path === "/healthz") return new Response("ok");
    if (path === "/selftest" && req.method === "GET") {
      if (!env.SELFTEST_SECRET || req.headers.get("X-Selftest-Secret") !== env.SELFTEST_SECRET) {
        return new Response("not found", { status: 404 });
      }
      const part = url.searchParams.get("part");
      if (!SELFTEST_PARTS.includes(part)) return new Response("part=base|entry|exit", { status: 400 });
      return Response.json(await runSelftest(env, part));
    }
    if (path === "/tg" && req.method === "POST") {
      if (req.headers.get("X-Telegram-Bot-Api-Secret-Token") !== env.WEBHOOK_SECRET) {
        return new Response("forbidden", { status: 403 });
      }
      let update;
      try {
        update = await req.json();
      } catch {
        return new Response("bad", { status: 400 });
      }
      if (typeof update?.update_id === "number" && await alreadySeen(env, update.update_id)) {
        return new Response("ok");
      }
      try {
        await handleUpdate(env, update);
      } catch (e) {
        try {
          const admin = await getAdmin(env);
          if (admin !== null) await new Telegram(env).send(admin, `\u26A0\uFE0F \u041E\u0448\u0438\u0431\u043A\u0430: ${e.message}`.slice(0, 300));
        } catch {
        }
      }
      return new Response("ok");
    }
    if (path.startsWith("/dl/") && req.method === "GET") {
      const token = path.slice(4);
      if (!await migrationTokenValid(env, token)) return new Response("gone", { status: 404 });
      const b = await getBackup(env);
      if (!b) return new Response("no backup", { status: 404 });
      return new Response(b.bytes, {
        headers: { "Content-Type": "application/gzip", "Content-Disposition": `attachment; filename="${b.meta.name}"` }
      });
    }
    if (path.startsWith("/migdone/") && req.method === "POST") {
      const token = path.slice("/migdone/".length);
      if (!await migrationTokenValid(env, token)) return new Response("gone", { status: 404 });
      const body = await req.json().catch(() => ({}));
      ctx.waitUntil(completeMigration(env, token, Number(body?.rc ?? 1), String(body?.ip ?? "")));
      return new Response("ok");
    }
    return new Response("vpn-bot", { status: 200 });
  },
  // Ждём runCron прямо в обработчике (не waitUntil): перепроверка бана спит минуту, а запуску
  // по расписанию Cloudflare даёт до 15 минут.
  async scheduled(event, env, _ctx) {
    await runCron(env, new Date(event.scheduledTime));
  }
};
async function completeMigration(env, token, rc, ip) {
  const mig = await currentMigration(env);
  const tg = new Telegram(env);
  if (!mig || mig.token !== token) return;
  const fpr = await env.STATE.get(`migfpr:${token}`) || "";
  try {
    const res = await onDone(env, mig, rc, ip, fpr);
    await tg.send(mig.chatId, res.message, [[{ text: "\u2190 \u041C\u0435\u043D\u044E", data: "m" }]]);
    mig.status = res.ok ? "done" : "failed";
  } catch (e) {
    await tg.send(mig.chatId, `\u26A0\uFE0F \u041F\u0435\u0440\u0435\u043D\u043E\u0441 \u043F\u043E\u0447\u0442\u0438 \u043F\u0440\u043E\u0448\u0451\u043B, \u043D\u043E \u043D\u0430 \u043F\u043E\u0441\u043B\u0435\u0434\u043D\u0435\u043C \u0448\u0430\u0433\u0435 \u043E\u0448\u0438\u0431\u043A\u0430: ${e.message}`);
    mig.status = "failed";
  } finally {
    await finishMigration(env, mig);
    await env.STATE.delete(`migfpr:${token}`);
  }
}
async function runCron(env, now) {
  const tg = new Telegram(env);
  const admin = await getAdmin(env);
  if (admin === null) return;
  try {
    const ip = await currentDnsIp(env);
    if (ip) {
      const port = Number(env.ENTRY_SSH_PORT);
      const alerted = await getLastBan(env) === `${ip} RU_BLOCKED`;
      let res = await checkBanGlobalping(env, ip, port);
      if (verdictOf(res) === "RU_BLOCKED" && !alerted) {
        await sleep2(6e4);
        res = await checkBanGlobalping(env, ip, port);
      }
      const verdict = verdictOf(res);
      if (verdict === "RU_BLOCKED" && !alerted) {
        await tg.send(admin, `\u{1F534} \u041F\u043E\u0445\u043E\u0436\u0435, IP \u0432\u0445\u043E\u0434\u0430 \u0437\u0430\u0431\u043B\u043E\u043A\u0438\u0440\u043E\u0432\u0430\u043B\u0438 \u0432 \u0420\u043E\u0441\u0441\u0438\u0438.

${banResult(res).text}`, [
          [{ text: "\u{1F69A} \u041F\u0435\u0440\u0435\u0435\u0445\u0430\u0442\u044C", data: "mg" }],
          [{ text: "\u{1F30D} \u041F\u0440\u043E\u0432\u0435\u0440\u0438\u0442\u044C \u0435\u0449\u0451 \u0440\u0430\u0437", data: "bn" }]
        ]);
      }
      if (CONCLUSIVE.has(verdict)) await setLastBan(env, `${ip} ${verdict}`);
    }
  } catch {
  }
  if (isDailyBackupRun(now)) {
    try {
      await doBackup(env);
    } catch (e) {
      await tg.send(admin, `\u26A0\uFE0F \u0421\u0443\u0442\u043E\u0447\u043D\u044B\u0439 \u0431\u044D\u043A\u0430\u043F \u043D\u0435 \u0441\u043D\u044F\u043B\u0441\u044F: ${e.message}`.slice(0, 300));
    }
  }
}
export {
  index_default as default
};

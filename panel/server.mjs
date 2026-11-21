// 传达室 · 面板服务
// 一个文件的小服务器：把你机器上的 QQ 收进来，让 agent 和白名单管住「听」和「说」。
// 只用 node 内置模块，不装依赖。读全部走 core 里的 PowerShell（那套已经验过）。
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import os from "node:os";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");
const CORE = path.join(ROOT, "core");
const TOOLS = path.resolve(ROOT, "..", "..", "tools");        // 现阶段 core 还在 tools 里
// 配置放用户目录：装进 node_modules 之后，同目录的文件会被重装覆盖。
const DATA_DIR = process.env.QQIDLE_DATA || path.join(os.homedir(), ".dsh", "qq-idle");
fs.mkdirSync(DATA_DIR, { recursive: true });
const CONFIG = path.join(DATA_DIR, "config.json");
const PORT = Number(process.env.QQIDLE_PORT || 8765);

const DEFAULTS = {
  uin: "",
  read: false,
  write: false,
  requireConfirm: true,
  groupTrigger: "",
  archive: false,       // 11-21：原文落盘，默认关——没经过他点头不自己开
  archiveDir: "",       // 空 = ~/.dsh/qq-idle/messages
  archiveEveryMin: 0,   // >0 才定时落盘（默认关：落一次会把你正在看的聊天切走）
  inbound: true,        // 订阅 OneBot 推送，在后台把连发合成一条
  mergeWindowSec: 3,    // 安静这么久就算「这段说完了」
  onebotWs: "",         // 空 = ws://127.0.0.1:3001
  onebotToken: "",      // OneBot 的 access token（ws 用 ?access_token= 传）
  sessions: {}   // 昵称 -> "off" | "read" | "reply"
};

function loadConfig() {
  try { return { ...DEFAULTS, ...JSON.parse(fs.readFileSync(CONFIG, "utf8")) }; }
  catch { return { ...DEFAULTS }; }
}
function saveConfig(c) {
  fs.writeFileSync(CONFIG, JSON.stringify(c, null, 2), "utf8");
}

// 跑一个 PowerShell 脚本，拿它的 stdout（UTF-8）
// 脚本现在分别住在 core/ 和 tools/ 两处：先找 core，再找 tools。
function scriptPath(name) {
  const inCore = path.join(CORE, name);
  return fs.existsSync(inCore) ? inCore : path.join(TOOLS, name);
}

function ps(script, args = [], timeoutMs = 20000) {
  // 中文键必须走 UTF-8 输出，否则 node 收到的是 GBK 字节，JSON 能解析但字段全变乱码。
  const full = scriptPath(script);
  const q = (s) => "'" + String(s).replace(/'/g, "''") + "'";
  // 开关（-开头）不加引号，否则 PowerShell 会把它当普通字符串，参数绑定不上；值才加引号。
  const cmd = `[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & ${q(full)} ${args.map((a) => (String(a).startsWith("-") ? a : q(a))).join(" ")}`;
  return new Promise((resolve) => {
    execFile("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", cmd],
      { timeout: timeoutMs, maxBuffer: 8 * 1024 * 1024, windowsHide: true, encoding: "utf8" },
      (err, stdout, stderr) => resolve({ ok: !err, stdout: stdout || "", stderr: stderr || "", code: err?.code }));
  });
}

// 从一坨输出里把 JSON 挖出来。
// 11-21：PowerShell 的 Write-Warning 在 -Command 调用下是往 stdout 写的，
// 于是 stdout 变成「警告: …\n[\n {…}\n]」，JSON.parse 直接失败、会话列表变空。
// 脚本那边已经改成 -Json 时不打警告，这里再兜一层：从第一个 [ / { 截到最后一个 ] / }。
function pickJson(text) {
  const t = String(text || "").trim();
  const tryParse = (s) => { try { return JSON.parse(s); } catch { return undefined; } };
  const direct = tryParse(t);
  if (direct !== undefined) return direct;
  for (const [open, close] of [["[", "]"], ["{", "}"]]) {
    const i = t.indexOf(open), j = t.lastIndexOf(close);
    if (i >= 0 && j > i) {
      const v = tryParse(t.slice(i, j + 1));
      if (v !== undefined) return v;
    }
  }
  return undefined;
}

// ---- 原文落盘（C 方案）：只处理「可回」的会话 ----
// 默认不自动跑：读消息要先 Invoke 点开会话，会把你正在看的聊天切走。
// 想常驻就在配置里填 archiveEveryMin（分钟），下面那个心跳会按它来。
let archiving = false;
let lastAuto = 0;

async function runArchive(cfg) {
  const dir = cfg.archiveDir ? cfg.archiveDir : path.join(DATA_DIR, "messages");
  const targets = Object.entries(cfg.sessions || {}).filter(([, v]) => v === "reply").map(([k]) => k);
  if (!targets.length) {
    return { ok: true, at: dir, written: 0, note: "没有设成「可回」的会话，没东西可落。" };
  }
  if (archiving) return { ok: false, error: "上一次还没跑完，等它一下。" };
  archiving = true;
  try {
    const day = new Date();
    const ymd = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, "0")}-${String(day.getDate()).padStart(2, "0")}`;
    const out = [];
    for (const name of targets) {
      const args = ["-Open", name, "-Messages", "-Since", "-Json"];
      if (cfg.uin) args.push("-Uin", String(cfg.uin));
      const r = await ps("qq-read.ps1", args, 40000);
      const list = pickJson(r.stdout);
      const msgs = Array.isArray(list) ? list : [];
      if (!msgs.length) { out.push({ 会话: name, 新增: 0 }); continue; }
      const folder = path.join(dir, name.replace(/[\\/:*?"<>|]/g, "_"));
      fs.mkdirSync(folder, { recursive: true });
      const file = path.join(folder, `${ymd}.jsonl`);
      const lines = msgs.map((m) => JSON.stringify({
        at: new Date().toISOString(), 时间: m.时间 ?? "", 谁: m.谁 ?? "", 内容: m.内容 ?? ""
      }));
      fs.appendFileSync(file, lines.join("\n") + "\n", "utf8");
      out.push({ 会话: name, 新增: msgs.length, 文件: file });
    }
    return { ok: true, at: dir, written: out.reduce((n, x) => n + (x.新增 || 0), 0), 明细: out };
  } finally {
    archiving = false;
  }
}

// 一分钟醒一次，看「现在该不该落」。配置改了不用重启。
function startArchiveHeartbeat() {
  setInterval(async () => {
    let c;
    try { c = loadConfig(); } catch { return; }
    const min = Number(c.archiveEveryMin || 0);
    if (!c.archive || !(min > 0)) { lastAuto = 0; return; }
    if (Date.now() - lastAuto < min * 60 * 1000) return;
    lastAuto = Date.now();
    try { await runArchive(c); } catch {}
  }, 60 * 1000);
}

// ---- 进来的消息：在后台合并 ----
// 他连发三条，不该变成三个回合。办法跟 world 一样：在**后台**攒着，
// 安静 mergeWindowSec 秒之后合成一条，再交出去（这里先落成一条待读记录）。
// 数据来自 OneBot 的 WebSocket（SnowLuma 的 3001），是推送，不点窗口、不碰键鼠。
const inboxBuf = new Map();     // key -> { name, lines, timer }
const inboxQueue = [];          // 已经合并好的，等外面来取
let wsStatus = { on: false, url: "", last: "", events: 0, merged: 0 };

function ymdOf(d = new Date()) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function textOfMessage(ev) {
  const m = ev.message;
  if (Array.isArray(m)) {
    return m.map((seg) => (seg && seg.type === "text" ? (seg.data?.text ?? "") : `[${seg?.type ?? "?"}]`)).join("");
  }
  if (typeof m === "string") return m;
  return String(ev.raw_message ?? "");
}

function feedEvent(ev) {
  if (!ev || ev.post_type !== "message") return false;
  const key = ev.message_type === "group" ? `g${ev.group_id}` : `u${ev.user_id}`;
  const name = ev.sender?.card || ev.sender?.nickname || String(ev.user_id ?? "?");
  const text = textOfMessage(ev).trim();
  if (!text) return false;
  const cfg = loadConfig();
  const win = Math.max(0, Number(cfg.mergeWindowSec ?? 3)) * 1000;
  let b = inboxBuf.get(key);
  if (!b) { b = { name, lines: [], timer: null }; inboxBuf.set(key, b); }
  b.name = name;
  b.lines.push({ 谁: name, 内容: text, at: new Date().toISOString() });
  if (b.timer) clearTimeout(b.timer);
  // 每来一条就把计时往后推：直到安静够久才算「这一段说完了」
  b.timer = setTimeout(() => flushInbox(key), win);
  wsStatus.events++;
  return true;
}

function flushInbox(key) {
  const b = inboxBuf.get(key);
  if (!b || !b.lines.length) return;
  inboxBuf.delete(key);
  const cfg = loadConfig();
  const dir = cfg.archiveDir ? cfg.archiveDir : path.join(DATA_DIR, "messages");
  const folder = path.join(dir, "inbox");
  const rec = {
    at: new Date().toISOString(),
    会话: b.name,
    条数: b.lines.length,
    内容: b.lines.map((x) => x.内容).join("\n"),   // 合成一条：整段话
    分段: b.lines
  };
  try {
    fs.mkdirSync(folder, { recursive: true });
    fs.appendFileSync(path.join(folder, `${ymdOf()}.jsonl`), JSON.stringify(rec) + "\n", "utf8");
  } catch (e) { wsStatus.last = "落盘失败：" + String(e?.message ?? e); }
  inboxQueue.push(rec);
  if (inboxQueue.length > 200) inboxQueue.shift();
  wsStatus.merged++;
}

function startInbound() {
  const cfg = loadConfig();
  if (cfg.inbound === false) return;
  const url = cfg.onebotWs || "ws://127.0.0.1:3001";
  const token = String(cfg.onebotToken || "");
  const full = token ? `${url}${url.includes("?") ? "&" : "?"}access_token=${encodeURIComponent(token)}` : url;
  if (typeof WebSocket !== "function") { wsStatus.last = "这个 node 没有 WebSocket，起不来"; return; }
  wsStatus.url = url;
  let ws;
  try { ws = new WebSocket(full); } catch (e) { wsStatus.last = "连不上：" + String(e?.message ?? e); return; }
  ws.addEventListener("open", () => { wsStatus.on = true; wsStatus.last = "连上了"; });
  ws.addEventListener("message", (m) => {
    let ev;
    try { ev = JSON.parse(typeof m.data === "string" ? m.data : String(m.data)); } catch { return; }
    feedEvent(ev);
  });
  ws.addEventListener("close", () => {
    wsStatus.on = false; wsStatus.last = "断了，5 秒后重连";
    setTimeout(startInbound, 5000);
  });
  ws.addEventListener("error", () => { wsStatus.last = "连接出错"; });
}

// DSH 的设置页在另一个源（端口不同），所以面板接口要允许跨源访问。
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, PUT, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type"
};

function json(res, code, obj) {
  const body = JSON.stringify(obj, null, 2);
  res.writeHead(code, { ...CORS, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = url.pathname;

  if (req.method === "OPTIONS") {
    res.writeHead(204, CORS);
    return res.end();
  }

  if (p === "/" || p === "/index.html") {
    const html = fs.readFileSync(path.join(HERE, "index.html"));
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
    return res.end(html);
  }

  if (p === "/api/config" && req.method === "GET") return json(res, 200, loadConfig());

  if (p === "/api/config" && req.method === "PUT") {
    let body = "";
    for await (const chunk of req) body += chunk;
    try {
      const incoming = JSON.parse(body);
      const merged = { ...loadConfig(), ...incoming };
      saveConfig(merged);
      return json(res, 200, merged);
    } catch (e) { return json(res, 400, { error: String(e) }); }
  }

  if (p === "/api/status") {
    const cfg = loadConfig();
    const args = ["-Json"];
    if (cfg.uin) args.push("-Uin", cfg.uin);
    const r = await ps("selfcheck.ps1", args, 30000);
    let parsed = null;
    parsed = pickJson(r.stdout);
    return json(res, 200, {
      ok: !!parsed,
      selfcheck: parsed,
      raw: parsed ? undefined : (r.stdout + r.stderr).slice(-800),
      at: new Date().toISOString()
    });
  }

  if (p === "/api/sessions") {
    const r = await ps("qq-read.ps1", ["-Sessions", "-Json"], 25000);
    let list = [];
    list = pickJson(r.stdout);
    if (!Array.isArray(list)) list = list ? [list] : [];
    const cfg = loadConfig();
    for (const s of list) s.状态 = cfg.sessions[s.会话] || "off";
    return json(res, 200, { ok: r.ok, sessions: list, raw: r.ok ? undefined : (r.stdout + r.stderr).slice(-800) });
  }

  if (p === "/api/send" && req.method === "POST") {
    const cfg = loadConfig();
    if (!cfg.write) return json(res, 403, { error: "总开关「写」是关的，先在面板里打开" });
    let body = "";
    for await (const chunk of req) body += chunk;
    let payload = {};
    try { payload = JSON.parse(body); } catch { return json(res, 400, { error: "请求不是合法 JSON" }); }
    const { to, text } = payload;
    if (!to || !text) return json(res, 400, { error: "缺 to 或 text" });
    const st = cfg.sessions[to] || "off";
    if (st !== "reply") return json(res, 403, { error: `「${to}」没有设成「可回」` });
    const tmp = path.join(HERE, `.out-${Date.now()}.txt`);
    fs.writeFileSync(tmp, text, "utf8");
    const r = await ps("qq-send.ps1", ["-To", to, "-TextFile", tmp, "-Do"], 40000);
    try { fs.unlinkSync(tmp); } catch {}
    return json(res, r.ok ? 200 : 500, { ok: r.ok, out: (r.stdout + r.stderr).slice(-1200) });
  }

  // 停止自己：先回话，再关服务器退出。
  // 11-21 加：以前要停它，得由外面的人去 taskkill，插件那侧还不知道 pid 是不是面板。
  // 自己停最干净——它本来就只是个本地面板，DSH 关了它也没理由留着。
  if (p === "/api/shutdown" && req.method === "POST") {
    json(res, 200, { ok: true, pid: process.pid, msg: "停止了，这个页面可以关掉" });
    setTimeout(() => {
      try { server.close(); } catch {}
      setTimeout(() => process.exit(0), 120);
    }, 150);
    return;
  }

  // 窗口体检：一次看两件事——主窗还在不在画（元素/文本节点数），有没有置顶浮窗挡着。
  // 11-21 加的：这两天「QQ 白了」「屏幕一块点不动」都是这两件事，每次翻命令行太慢。
  if (p === "/api/health") {
    const cfg = loadConfig();
    const uin = String(cfg.uin || "").trim();
    // 填了 QQ 号就只看那个号——两个号同时登着时，不指定就会验到另一个（11-21 踩过）。
    const rpArgs = uin ? ["-DryRun", "-Uin", uin] : ["-DryRun"];
    const [rp, pu] = await Promise.all([
      ps("qq-repaint.ps1", rpArgs, 25000),
      ps("qq-popups.ps1", [], 25000)
    ]);
    const t1 = (rp.stdout + "\n" + rp.stderr).trim();
    const t2 = (pu.stdout + "\n" + pu.stderr).trim();
    const m = t1.match(/元素=(\d+)\s+文本节点=(\d+)/);
    return json(res, 200, {
      ok: true,
      元素: m ? Number(m[1]) : null,
      文本节点: m ? Number(m[2]) : null,
      有浮窗: /浮窗「/.test(t2),
      窗口: t1.split("\n").filter(Boolean).slice(-3),
      浮窗: t2.split("\n").filter(Boolean).slice(-6)
    });
  }

  // 原文落盘：只处理「可回」的会话。逻辑在 runArchive 里，定时器也调它。
  if (p === "/api/archive/run" && req.method === "POST") {
    const out = await runArchive(loadConfig());
    return json(res, 200, out);
  }
  // 取合并好的消息（给外面接 DSH 用）：?since=N 只给第 N 条之后的
  if (p === "/api/inbox") {
    const since = Math.max(0, Number(url.searchParams.get("since") || 0));
    return json(res, 200, { ok: true, ws: wsStatus, total: inboxQueue.length, since, items: inboxQueue.slice(since) });
  }

  // 灌一条假事件，专门用来验合并（只允许本机调用）
  if (p === "/api/inbox/feed" && req.method === "POST") {
    let body = "";
    for await (const chunk of req) body += chunk;
    let ev = {};
    try { ev = JSON.parse(body || "{}"); } catch { return json(res, 400, { error: "不是合法 JSON" }); }
    if (!ev.post_type) ev.post_type = "message";
    const ok = feedEvent(ev);
    return json(res, 200, { ok, ws: wsStatus, pending: Array.from(inboxBuf.values()).map((b) => ({ 会话: b.name, 条数: b.lines.length })) });
  }

  json(res, 404, { error: "没有这个接口" });
});

startArchiveHeartbeat();
startInbound();

server.listen(PORT, "127.0.0.1", () => {
  console.log(`传达室：http://127.0.0.1:${PORT}`);
  console.log(`配置：${CONFIG}`);
  console.log(`核心：${TOOLS}（暂时借用 tools 目录，搬进 core/ 之后会自动优先用 core/）`);
});

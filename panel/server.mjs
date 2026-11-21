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
    try { parsed = JSON.parse(r.stdout); } catch {}
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
    try { list = JSON.parse(r.stdout); } catch {}
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

  json(res, 404, { error: "没有这个接口" });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`传达室：http://127.0.0.1:${PORT}`);
  console.log(`配置：${CONFIG}`);
  console.log(`核心：${TOOLS}（暂时借用 tools 目录，搬进 core/ 之后会自动优先用 core/）`);
});

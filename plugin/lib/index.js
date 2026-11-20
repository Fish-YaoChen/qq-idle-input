// 传达室 · 服务端
//
// 这一半只做三件事：
//   1. 给设置页那几个按钮开一段自己的网址（DSH 的 webServer 注册，跟 dsh-world 一样）
//   2. 读写「要操作哪个 QQ 号」——没号就不许起进程，免得起来之后抓到别的号出 bug
//   3. 用户点「启动后台进程」时，把 panel/server.mjs 拉起来（隐藏窗口、脱离子进程树）
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";

export const name = "dsh-qq-idle";
export const inject = ["webServer"];

const PANEL_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "panel");
const PORT = Number(process.env.QQIDLE_PORT || 8765);
const PREFIX = "/dsh-qq-idle";
const DATA_DIR = process.env.QQIDLE_DATA || path.join(os.homedir(), ".dsh", "qq-idle");
const CONFIG = path.join(DATA_DIR, "config.json");

function readConfig() {
  try { return JSON.parse(fs.readFileSync(CONFIG, "utf8")); } catch { return {}; }
}
function writeConfig(patch) {
  const next = { ...readConfig(), ...patch };
  fs.mkdirSync(DATA_DIR, { recursive: true });
  fs.writeFileSync(CONFIG, JSON.stringify(next, null, 2), "utf8");
  return next;
}

/** 面板服务在不在听（只看端口，避免连不上时卡住）。 */
function probe(port, timeoutMs = 800) {
  return new Promise((resolve) => {
    const socket = net.connect({ host: "127.0.0.1", port });
    const done = (ok) => { try { socket.destroy(); } catch {} resolve(ok); };
    socket.setTimeout(timeoutMs);
    socket.once("connect", () => done(true));
    socket.once("timeout", () => done(false));
    socket.once("error", () => done(false));
  });
}

function send(res, status, body) {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(JSON.stringify(body));
}

async function readBody(req, limit = 64 * 1024) {
  const chunks = []; let size = 0;
  for await (const chunk of req) { size += chunk.length; if (size <= limit) chunks.push(chunk); }
  return Buffer.concat(chunks).toString("utf8");
}

function startPanel() {
  const server = path.join(PANEL_DIR, "server.mjs");
  if (!fs.existsSync(server)) throw new Error(`找不到 ${server}`);
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: PANEL_DIR,
    detached: true,       // 脱离子进程树：DSH 关了它也不走
    stdio: "ignore",
    windowsHide: true,    // 不弹黑窗口
    env: { ...process.env, QQIDLE_PORT: String(PORT), QQIDLE_DATA: DATA_DIR }
  });
  child.unref();
  return child.pid;
}

export function apply(ctx) {
  const webServer = ctx.webServer ?? ctx.get?.("webServer");
  if (!webServer || typeof webServer.register !== "function") return;

  const route = {
    kind: "prefix",
    path: PREFIX,
    handler: async (req, res) => {
      const url = new URL(req.url ?? PREFIX, "http://localhost");
      const sub = url.pathname.slice(PREFIX.length) || "/";
      try {
        if (req.method === "GET" && sub === "/state") {
          const cfg = readConfig();
          return send(res, 200, { ok: true, running: await probe(PORT), port: PORT, uin: cfg.uin || "" });
        }
        if (req.method === "POST" && sub === "/config") {
          const raw = await readBody(req);
          let body = {};
          try { body = JSON.parse(raw); } catch { return send(res, 400, { ok: false, error: "请求不是合法 JSON" }); }
          const uin = String(body.uin ?? "").trim();
          if (uin && !/^\d{5,12}$/.test(uin)) return send(res, 400, { ok: false, error: "QQ 号应该是 5–12 位数字" });
          const next = writeConfig({ uin });
          return send(res, 200, { ok: true, uin: next.uin || "" });
        }
        if (req.method === "POST" && sub === "/start") {
          const cfg = readConfig();
          const uin = String(cfg.uin || "").trim();
          if (!uin) {
            // 没号就不许起：起来之后可能抓到别的号的窗口，后面每一步都错。
            return send(res, 400, { ok: false, error: "先在上面的输入框里填要操作的 QQ 号，再启动。" });
          }
          if (await probe(PORT)) return send(res, 200, { ok: true, running: true, already: true, port: PORT, uin });
          const pid = startPanel();
          for (let i = 0; i < 20; i++) {
            await new Promise((r) => setTimeout(r, 150));
            if (await probe(PORT)) return send(res, 200, { ok: true, running: true, pid, port: PORT, uin });
          }
          return send(res, 500, { ok: false, error: "起了进程但端口没监听，可能启动失败", pid });
        }
        if (req.method === "GET" && sub === "/") {
          return send(res, 200, { ok: true, name, port: PORT, panel: `http://127.0.0.1:${PORT}` });
        }
        await readBody(req);
        return send(res, 404, { error: "没有这个接口" });
      } catch (e) {
        return send(res, 500, { ok: false, error: String(e?.message ?? e) });
      }
    }
  };

  ctx.effect(() => webServer.register(route), "qq-idle panel route");
}

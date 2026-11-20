/**
 * 传达室 · 浏览器这一半
 *
 * 挂在 DSH 设置的 settings.section 槽上，跟「世界控制台」平级。
 * 它跟面板服务是两回事：面板服务没起的时候，这段界面照样要能用——
 * 因为「启动后台进程」这个按钮就是给它按的。
 *
 * 加载约定跟 dsh-world 的 client 一样：window.__ModuleLoader__.load({ id, factory })，
 * id 必须等于插件包里 bundle 那行的名字。
 */
;(function () {
  var PREFIX = "/dsh-qq-idle";

  window.__ModuleLoader__.load({
    id: "dsh-qq-idle",
    factory: function (require) {
      var react = require("react");
      var h = react.createElement;

      function chip(text, kind) {
        var color = kind === "ok" ? "#12855a" : kind === "bad" ? "#c0392b" : "#6b7280";
        var bg = kind === "ok" ? "#f2fbf7" : kind === "bad" ? "#fdf4f3" : "#f7f8fa";
        return h("span", {
          style: {
            fontSize: 12, padding: "2px 9px", borderRadius: 10, marginRight: 8,
            border: "1px solid #e3e6ec", color: color, background: bg
          }
        }, text);
      }

      function button(label, onClick, primary, disabled) {
        return h("button", {
          onClick: onClick, disabled: !!disabled,
          style: {
            marginRight: 8, padding: "5px 12px", borderRadius: 8, fontSize: 13,
            cursor: disabled ? "not-allowed" : "pointer",
            border: primary ? "1px solid #2563eb" : "1px solid #e3e6ec",
            background: primary ? "#2563eb" : "#fff",
            color: primary ? "#fff" : "#1f2329",
            opacity: disabled ? 0.5 : 1
          }
        }, label);
      }

      function Panel() {
        var s = react.useState({ running: false, port: 8765, uin: "" }), svc = s[0], setSvc = s[1];
        var u = react.useState(""), uin = u[0], setUin = u[1];
        var d = react.useState(null), data = d[0], setData = d[1];
        var m = react.useState(""), msg = m[0], setMsg = m[1];
        var b = react.useState(false), busy = b[0], setBusy = b[1];

        function loadState() {
          return fetch(PREFIX + "/state", { cache: "no-store" })
            .then(function (r) { return r.json(); })
            .then(function (body) {
              setSvc(body);
              if (typeof body.uin === "string") setUin(body.uin);
              return body;
            })
            .catch(function () { setSvc({ running: false, port: 8765, uin: "" }); });
        }

        function loadPanel() {
          fetch("http://127.0.0.1:8765/api/status", { cache: "no-store" })
            .then(function (r) { return r.json(); })
            .then(function (body) { setData(body); })
            .catch(function () { setData(null); });
        }

        function refresh() {
          setBusy(true);
          loadState().then(function (st) {
            if (st.running) loadPanel(); else setData(null);
            setBusy(false);
          });
        }

        function saveUin() {
          var v = String(uin || "").trim();
          if (!v) { setMsg("QQ 号必填：填上才能启动后台进程。"); return Promise.resolve(false); }
          if (!/^\d{5,12}$/.test(v)) { setMsg("QQ 号应该是 5–12 位数字。"); return Promise.resolve(false); }
          return fetch(PREFIX + "/config", {
            method: "POST", headers: { "content-type": "application/json" },
            body: JSON.stringify({ uin: v })
          }).then(function (r) { return r.json(); }).then(function (body) {
            if (body.ok) { setSvc(function (old) { return { ...old, uin: body.uin }; }); setMsg("QQ 号已保存：" + body.uin); return true; }
            setMsg("保存失败：" + (body.error || "未知")); return false;
          }).catch(function (e) { setMsg("保存失败：" + (e && e.message ? e.message : e)); return false; });
        }

        function startPanel() {
          setBusy(true);
          setMsg("正在启动后台进程…");
          saveUin().then(function (ok) {
            if (!ok) { setBusy(false); return; }
            return fetch(PREFIX + "/start", { method: "POST" })
              .then(function (r) { return r.json(); })
              .then(function (body) {
                if (body.ok) {
                  setSvc({ running: true, port: body.port, uin: body.uin || uin });
                  setMsg(body.already ? "后台进程本来就在跑（QQ " + (body.uin || uin) + "）。" : "已启动（PID " + body.pid + "），QQ " + (body.uin || uin) + "。");
                  loadPanel();
                } else {
                  setMsg("启动失败：" + (body.error || "未知原因"));
                }
              })
              .catch(function (e) { setMsg("启动失败：" + (e && e.message ? e.message : e)); })
              .then(function () { setBusy(false); });
          });
        }

        react.useEffect(function () { refresh(); }, []);

        var sc = data && data.selfcheck;
        var port = svc.port || 8765;
        var canStart = String(uin || "").trim().length > 0;
        if (data && data.selfcheck && data.selfcheck.uin) { /* 自检里的号与输入框同一个 */ }

        return h("div", { style: { padding: "4px 0 8px", fontFamily: '"Microsoft YaHei", system-ui, sans-serif' } },
          h("p", { style: { margin: "0 0 10px", fontSize: 13, color: "#6b7280" } },
            "读走 Windows 无障碍接口；写只在你手停的那一下抢两秒前台。白名单和会话都在网页那一页。"),

          h("div", { style: { marginBottom: 12, display: "flex", alignItems: "center", gap: 8 } },
            h("label", { style: { fontSize: 13, color: "#6b7280", minWidth: 72 } }, "QQ 号"),
            h("input", {
              value: uin,
              placeholder: "要操作的那个号，例如 123456789",
              onChange: function (e) { setUin(e.target.value); },
              onBlur: function () { if (String(uin || "").trim()) saveUin(); },
              style: {
                width: 220, padding: "6px 10px", fontSize: 13, borderRadius: 8,
                border: "1px solid #e3e6ec", background: "#fff", color: "#1f2329"
              }
            }),
            h("span", { style: { fontSize: 12, color: canStart ? "#6b7280" : "#a16207" } },
              canStart ? "改了之后会自动保存" : "必填——填上才能启动")
          ),

          h("div", { style: { marginBottom: 10 } },
            chip(svc.running ? "后台进程 运行中" : "后台进程 没启动", svc.running ? "ok" : "bad"),
            chip("端口 " + port, ""),
            sc ? chip(sc.可以读 ? "读 可以" : "读 不可以", sc.可以读 ? "ok" : "bad") : null,
            sc ? chip(sc.可以写 ? "写 可以" : (sc.写状态 || "写 待确认"), sc.可以写 ? "ok" : "warn") : null,
            sc && sc.版本 ? chip("版本 " + sc.版本, "") : null
          ),

          h("div", null,
            button(svc.running ? "后台进程已在跑" : "启动后台进程", startPanel, !svc.running, busy || svc.running || !canStart),
            button("打开网页设置", function () { window.open("http://127.0.0.1:" + port, "_blank"); }, false, !svc.running),
            button(busy ? "刷新中…" : "刷新", refresh, false, busy)
          ),

          msg ? h("p", { style: { marginTop: 10, fontSize: 12, color: "#6b7280" } }, msg) : null,
          !svc.running
            ? h("p", { style: { marginTop: 8, fontSize: 12, color: "#a16207" } },
                "后台进程没起的时候，「打开网页设置」打不开——先填好 QQ 号，再点启动。")
            : null,
          data && data.at
            ? h("p", { style: { marginTop: 8, fontSize: 12, color: "#9aa1ad" } }, "上次自检：" + new Date(data.at).toLocaleTimeString())
            : null
        );
      }

      var exports = { inject: ["slots"] };
      Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
      exports.apply = function (ctx) {
        ctx.slots.inject("settings.section", function () {
          return ctx.slots.register(
            { name: "settings.section", id: "qq-idle", order: 32, label: "传达室" },
            function () { return h(Panel); }
          );
        });
      };
      return exports;
    }
  });
})();

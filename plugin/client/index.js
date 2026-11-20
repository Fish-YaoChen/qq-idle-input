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
        var s = react.useState({ running: false, port: 8765 }), svc = s[0], setSvc = s[1];
        var d = react.useState(null), data = d[0], setData = d[1];
        var m = react.useState(""), msg = m[0], setMsg = m[1];
        var b = react.useState(false), busy = b[0], setBusy = b[1];

        // 后台进程在不在 —— 走插件自己的路由，跟面板服务是否在跑无关
        function loadState() {
          return fetch(PREFIX + "/state", { cache: "no-store" })
            .then(function (r) { return r.json(); })
            .then(function (body) { setSvc(body); return body; })
            .catch(function () { setSvc({ running: false, port: 8765 }); });
        }

        // 自检数据 —— 只有面板服务在跑时才拿得到
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
            setMsg("");
            setBusy(false);
          });
        }

        function startPanel() {
          setBusy(true);
          setMsg("正在启动后台进程…");
          fetch(PREFIX + "/start", { method: "POST" })
            .then(function (r) { return r.json(); })
            .then(function (body) {
              if (body.ok) {
                setSvc({ running: true, port: body.port });
                setMsg(body.already ? "后台进程本来就在跑。" : "已启动（PID " + body.pid + "）。");
                loadPanel();
              } else {
                setMsg("启动失败：" + (body.error || "未知原因"));
              }
            })
            .catch(function (e) { setMsg("启动失败：" + (e && e.message ? e.message : e)); })
            .then(function () { setBusy(false); });
        }

        react.useEffect(function () { refresh(); }, []);

        var sc = data && data.selfcheck;
        var port = svc.port || 8765;

        return h("div", { style: { padding: "4px 0 8px", fontFamily: '"Microsoft YaHei", system-ui, sans-serif' } },
          h("p", { style: { margin: "0 0 10px", fontSize: 13, color: "#6b7280" } },
            "读走 Windows 无障碍接口；写只在你手停的那一下抢两秒前台。白名单和会话都在网页那一页。"),

          h("div", { style: { marginBottom: 10 } },
            chip(svc.running ? "后台进程 运行中" : "后台进程 没启动", svc.running ? "ok" : "bad"),
            chip("端口 " + port, ""),
            sc ? chip(sc.可以读 ? "读 可以" : "读 不可以", sc.可以读 ? "ok" : "bad") : null,
            sc ? chip(sc.可以写 ? "写 可以" : "写 不可以", sc.可以写 ? "ok" : "bad") : null,
            sc && sc.版本 ? chip("版本 " + sc.版本, "") : null
          ),

          h("div", null,
            button(svc.running ? "后台进程已在跑" : "启动后台进程", startPanel, !svc.running, busy || svc.running),
            button("打开网页设置", function () { window.open("http://127.0.0.1:" + port, "_blank"); }, false, !svc.running),
            button(busy ? "刷新中…" : "刷新", refresh, false, busy)
          ),

          msg ? h("p", { style: { marginTop: 10, fontSize: 12, color: "#6b7280" } }, msg) : null,
          !svc.running
            ? h("p", { style: { marginTop: 8, fontSize: 12, color: "#a16207" } },
                "后台进程没起的时候，「打开网页设置」打不开——先点左边那个。")
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

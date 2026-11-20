# 传达室 · qq-idle-input

**不加钩子、不读内存的 QQ 读写。**

读，走 Windows 的无障碍接口（UIA）；写，只在你手停下来的空隙里抢两秒前台。
不是协议层、不是注入、不是 OCR——所以 QQ 怎么更新，它读的那一层都还在。

> 只在 **Windows**、**同一个登录用户**、**QQ NT（Electron 版，9.9.x）** 上生效。
> 别的机器、别的号、别的系统，读不到——这是桌面接口的性质，不是配置问题。

## 能做什么

- **读**：会话列表（谁、最后一条、时间）、进某个会话、读消息气泡（带时间戳）
- **写**：发一条纯文本消息
- **管**：按会话设白名单（关 / 只读 / 可回），读和写各有一个总开关，默认都关

## 不能做什么（先看这段，省得白装）

- **不能后台无窗口跑**：窗口关进托盘时无障碍树是空的，要先让它显示出来（脚本会自动做，不抢焦点）
- **写不是无感的**：一次发送会抢前台 **1.8–2.4 秒**；如果当时你在全屏程序里，**它会被最小化，而且还原不回来**（全屏独占不吃 `SW_RESTORE`，只有你点任务栏它才回来）
- **读不到 QQ 号**：无障碍树里只有显示名（备注优先），没有 uin。所以白名单按名字记——**改了备注就对不上**，面板会提示并给「迁移」按钮
- **群聊 @ 不一定读得到**：先用触发词（关键词）驱动，稳
- **图片、表情、引用、文件**：只有文字，别的都没有
- **慢**：一步 1–3 秒，适合陪伴型对话，不适合高频刷屏

## 前提：让 QQ 带着无障碍参数启动

读的前提是 Chromium 把无障碍树打开。这需要**重启 QQ**，启动参数加：

```
"C:\Program Files\Tencent\QQNT\QQ.exe" "<你的 QQ 安装目录>\versions\<版本>\resources\app\application.asar\background.js" --from-multiple-login <你的号> "--hide-login-window" --force-renderer-accessibility --disable-renderer-backgrounding
```

（`selfcheck.ps1` 会把它在你机器上的实际路径打出来，直接复制。）

QQ 在跑、但没带这个参数时，也能读到一点点（Chromium 有时会懒加载），但**不稳定**——别指望。

## 安装

**还没发布到 npm。** 现在两种装法：

1. **当 DSH 插件**（设置里多一个「传达室」）：把这个仓库下载下来，放进
   `~/.dsh/profiles/desktop/node_modules/dsh-qq-idle`，再在 profile 的
   `cordis.patch.yml` 里加一行 `- { id: dsh-qq-idle }`，重启 DSH。
2. **只用命令行 / 接别的 agent**：下载仓库，核心脚本在 `core/`，面板在 `panel/`。


## 用法

```powershell
# 1. 先自检：能不能用、缺什么，一条一条告诉你
powershell -File core\selfcheck.ps1

# 2. 看会话（只读，不碰窗口）
powershell -File core\qq-read.ps1 -Sessions

# 3. 读某个会话最近的消息（会 Invoke 打开会话；窗口不可见时先显示，不抢焦点）
powershell -File core\qq-read.ps1 -Open "某人" -Messages -MaxMessages 10

# 4. 发一条（会抢前台约两秒；-Do 才真发）
powershell -File core\qq-send.ps1 -To "某人" -Text "你好" -Do

# 5. 面板
node panel\server.mjs      # 然后打开 http://127.0.0.1:8765
```

`-Json` 给结构化输出，agent 直接吃：

```powershell
powershell -File core\qq-read.ps1 -Sessions -Json
powershell -File core\selfcheck.ps1 -Json
```

## 接自己的 agent

任何能执行命令的 agent 都行（Claude Code、Codex CLI、Cursor、Aider……）：

- 读：跑 `qq-read.ps1 ... -Json`，解析 JSON
- 写：把文本写进一个临时文件，跑 `qq-send.ps1 -To "某人" -TextFile 那个文件 -Do`（避开命令行转义）
- 面板：`node panel\server.mjs`，`PUT /api/config` 改开关和白名单，`POST /api/send` 发消息

**注意**：它必须跑在 QQ 所在的那台 Windows、同一个登录用户下。云端、SSH、Docker、WSL 里读不到。

## 面板（传达室）

`panel/server.mjs` + `panel/index.html`，零依赖。

- 会话列表 + 三态白名单（关 / 只读 / 可回）
- 读写两个总开关（默认关）
- 群聊触发词
- 手动发一条（只列「可回」的会话）
- 改名检测：白名单里的名字在列表里找不到时，给「迁移到」和「删掉」按钮
- 重名检测：两个会话同名时标出来（按名字认会分不清）

配置存在 `panel/config.json`。

## 已知问题

见 [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md)。里面记了开发时踩的每个坑，包括**两次把 QQ 窗口卡死**的原因。

## 风险与边界

- **自动化操作可能违反腾讯的服务条款**。用它，风险自负；只在自己的号上用。
- 这个工具**不破解、不注入、不读内存**，但「用程序操作客户端」这件事本身，条款上是不允许的。
- 别拿它做群发、刷屏、冒充别人——那是另一回事，也不在支持的范围内。

## 兼容性

| QQ | 状态 |
|---|---|
| 9.9.37-54395（Electron） | 实测可用（自检十项全绿） |
| 其它 9.9.x | 大概率可用，注意类名有没有变 |
| 老版 QQ（非 Electron） | 不支持 |
| Mac / Linux | 不支持（Windows 接口） |

`compat/` 里存着每个测过的版本的类名快照，只有类名，没有任何聊天内容。

## License

MIT。见 [LICENSE](LICENSE)。

## 开发与发布

```powershell
npm version patch      # 改版本
npm publish  # 要 npm 账号 + 2FA，发布前确认 files 里没有 panel/config.json
```

发布前确认三件事：`package.json` 的 `files` 里没有 `panel/config.json`（那里有会话昵称）；
`.ps1` 都带 BOM；`compat/` 里的快照只有类名。

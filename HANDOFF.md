# 交接：这个项目做到哪儿了，接下来该干什么

写给接手的人（可能是 Claude、GPT，也可能是我自己过几天回来）。**只写有证据的东西**；
推断会说清是推断。日期：2026-11-21。

---

## 一句话定位

`qq-idle-input`（面板中文名「传达室」）= **不注入、不读内存的 QQ 读写工具**。
读走 Windows 无障碍接口（UIA），写靠抢前台打字 + 点发送按钮。
它存在的意义不是替代 NapCat / SnowLuma，而是**那条桥死掉那天还能用**：读得见、喊得出一句。

因此有一条铁律：**收消息的命脉不能接在桥上**。曾经接到 SnowLuma 的 OneBot WS 上，被指出来，已改回默认走自己的 UIA 轮询（见「设计取舍」）。

---

## 现在的状态（2026-11-21 收盘）

### 能用，且实测过

| 能力 | 怎么验的 | 文件 |
|---|---|---|
| 自检（十项） | 跑通，能区分「空白窗口 / 改版 / 没打开会话」 | `core/selfcheck.ps1` |
| 列会话（昵称/时间/预览，带「新」标记） | 9–11 行，连跑两次第二次只标真变的 | `core/qq-read.ps1` |
| 读某个会话的消息 | 能读气泡和时间戳 | 同上 |
| 游标：只吐新消息 | 把游标往回拨一条 → 正好吐 1 条；再跑 → 0 条 | `-Since` / `~/.dsh/qq-idle/cursor.json` |
| 窗口白了叫回来 | 还原 + 抖一像素，实测恢复，不用重启 QQ | `core/qq-repaint.ps1` |
| 关掉「看不见但吃点击」的浮窗 | 按坐标反查 + `WM_CLOSE`，实测关掉 | `core/qq-popups.ps1` |
| 面板：会话/白名单/手动发/体检/停止 | 起服务、点按钮都验过（发送见下方「假失败」） | `panel/server.mjs`、`panel/index.html` |
| 面板：原文落盘（C 方案） | 写一条、再跑 0 条；本机目录指到 `~/.dsh/worlds/default/qq` | `POST /api/archive/run` |
| 面板：进来的消息后台合并 | 灌三条假事件 → 合成 1 条；真实消息触发轮询也验证过一次 | `inboundMode: "uia"` |
| DSH 插件：设置里「传达室」+ 启动后台进程 | 路由 200，进程由插件拉起 | `plugin/lib`、`plugin/client` |

### 坏了 / 没验成

1. **发送会假失败**（优先修，见任务一）。实测：消息已经进会话，脚本却报「没发出去」。
2. **UIA 事件订阅没成立**：`AddStructureChangedEventHandler` + 名称变化都注册成功，
   即使真的切换了会话（树明确变化），10 秒内仍是 **0 事件**。原因未定：
   - 可能 Chromium 在没带 `--force-renderer-accessibility` 时不发事件；
   - 也可能 PowerShell 的 scriptblock 委托在 UIA 线程上收不到（没有报错，静默丢）。
   想分清必须**编译一个常驻的 C# 探针**（我试了两次都死在引用上：`-ReferencedAssemblies`
   一给就把默认引用顶掉，连 `List<>` 都找不到；后来换成 `System.dll,System.Core.dll,
   UIAutomationClient.dll,UIAutomationTypes.dll` 报编译错，细节没截全）。
   原型在 `tools/uia-event-probe.ps1`（未跑通）。
3. **「最后一跳」没做**：合并好的消息还停在 `GET /api/inbox`，没有变成一轮对话。
   三条路的分析见 `docs/接进DSH.md`（推荐用 DSH 自己的定时消息，不碰内部接口）。
4. **插件侧的「停止后台进程」没在真实 DSH 里验过**（改完要重启 DSH，一直没重启）。
5. 面板对「没填号 / 多号同登」的报错还是把 PowerShell 原文甩给用户，没兜住。

---

## 已知问题清单（都在 `docs/KNOWN-ISSUES.md`，这里只列索引）

编号 1–23，全是从真事故里写出来的。最值得先读的几条：

- **五**：QQ 一个进程有五个 `Chrome_WidgetWin_1`，第一个是 32×39 的托盘小窗——「只读到 11 个元素」全是抓错窗。
- **六**：对藏进托盘的窗口做 `Invoke`/`SetFocus` 会把渲染层弄卡死（发生过两次）。
- **十二**：窗口白了 ≠ 树坏了。树还在（100+ 元素），是渲染层不画了 → 用 `qq-repaint.ps1`。
- **十四**：屏幕一块点不动 = QQ 的「资料卡」浮窗置顶且看不见 → `qq-popups.ps1`。
- **十五**：「必须带 `--force-renderer-accessibility`」是**错的**。渲染过一次之后不带也能读。
- **十七**：点**已经选中**的会话行会把聊天区关掉。所以先看顶部，是这个人就别点。
- **十八**：`Write-Warning` 在 `powershell -Command` 调用下跑进 **stdout**，把 JSON 污染成「警告+JSON」。
- **十九**：`Set-Content -Encoding UTF8` 在 PowerShell 7 里**不写 BOM**；5.1 读成 GBK，中文全烂。
- **二十**：`-Open X -Messages -Json` 曾经吐两段 JSON；单条消息 `ConvertTo-Json` 会退化成对象。
- **二十三**：两个号同时登着时**不猜**——直接拒绝，让调用方用 `-Uin` 指定。

---

## 这台机器上的具体事实（别照抄到别人机器）

- 两个 QQ 号同时登着：**A 号 = 日常号**（不能碰），**B 号 = 工具操作的那个号**。
  - 所有自动化都要带 `-Uin <B 号>`；不带脚本会拒绝（这是故意的）。
- 桥是 SnowLuma v2.4.0，装在 `D:\SnowLuma\SnowLuma-v2.4.0-win-x64`；
  OneBot：HTTP `3000`、WS `3001`（access token 在 `config/onebot_<B号>.json`），WebUI `5099`。
  起法：计划任务 `SnowLuma-Run`（`tools/snowluma-boot.vbs`），注入用 `tools/snowluma-inject.ps1`。
- 面板服务跑在 `127.0.0.1:8765`，可以「停止后台进程」自己退。
- 本机存档目录指到 `~/.dsh/worlds/default/qq`（world 那边能直接读）。
- DSH 侧已经有 `dsh-world`（0.7.6），它的 QQ 通道 `qqEnabled: true`，走的也是 SnowLuma SDK；
  **桥活着时的收发它已经做完了**，别重复造。

---

## 设计取舍（这些是踩出来的，不是偏好）

1. **默认 `inboundMode: "uia"`**：自己轮询，不依赖桥。`onebot` 只是可选加速。
2. **读不注入**：UIA 树 + `--force-renderer-accessibility`（可选）。写只能抢前台 ~2 秒，
   全屏程序会被最小化且**还原不回来**——README 里写清了，别当日常通道用。
3. **白名单**：默认全关；只对「可回」的会话落原文、只对「可回」的会话发。
4. **不猜**：多号、多个候选窗口、名字对不上——一律停下来说清楚，不挑一个凑合。
5. **窗口不可见绝不 Invoke**：会卡死渲染层。要么先 `SW_SHOWNOACTIVATE`，要么拒绝。

---

## 接下来干什么（按优先级）

### 任务一：修「发送假失败」（最该先做）

**现象**：`qq-send.ps1 -Do` 打完字、点了「发送」，回读输入框发现字还在，于是报
「字还留在输入框里，**这条没发出去**」。但会话里明明已经有这条消息。

**为什么会这样**：输入框（ProseMirror）的文本回读会拿到**旧内容**（渲染更新比发送慢）。
拿它当「发送成功」的唯一判据，就会假失败。

**为什么危险**：人以为没发出去 → 再发一遍 → 对方收到两遍。比不发更糟。

**改法**：判成功改成「**会话里出现了这条消息**」——点完发送后，用 `qq-read` 读该会话最近
几条，比对文本（取开头 8–12 个字做锚点，别整段比）。输入框只看辅助信号，不作为判据。
失败时要报清依据是哪一个。

**验收**：发一条测试消息，日志里能写出「依据：会话里读到了这条（时间 xx:xx）」。

### 任务二：把 UIA 事件探针编译出来（决定「通知」能不能不靠轮询）

先确认委托能不能收到事件。建议：写一个最小 C# 控制台程序（`Add-Type` 编不过就换
`dotnet build`，或直接用 `powershell.exe` 5.1 + 完整引用），只做一件事：
订阅某窗口的 `StructureChanged` + `NameProperty` 变化，打到控制台，然后人为改一次树
（比如切换会话）看有没有事件。

- 有事件 → ② 可行，接着做「事件触发读 → 合并 → 交付」。
- 没事件 → 试「带 `--force-renderer-accessibility` 启动 QQ」再测一次。
  两个都没有，就老实用轮询（现在这套），别再往里投时间。

### 任务三：「最后一跳」

`docs/接进DSH.md` 里三条路，建议先用**定时消息**（不碰 DSH 内部接口）：
每 N 分钟读一次 `GET /api/inbox?since=N`，有新的就作为一条消息递进来。

### 任务四（小）：面板报错兜底

把「没填号 / 多号同登」翻译成一句人话，别把 PowerShell 原文甩到页面上。

---

## 仓库结构与怎么跑

```
core/    selfcheck / qq-read / qq-send / qq-repaint / qq-popups（PowerShell，全部带 BOM）
panel/   server.mjs（零依赖本地服务，:8765）+ index.html（白底面板）
plugin/  DSH 插件壳（设置里的「传达室」）
compat/  每个测过的 QQ 版本的类名快照（只有类名，没有聊天内容）
docs/    KNOWN-ISSUES（23 条）/ 消息存在哪 / 接进DSH / 面板设计
tools/   uia-event-probe.ps1（未跑通的原型）
```

```powershell
powershell -File core\selfcheck.ps1 -Uin <号>      # 先自检
powershell -File core\qq-read.ps1 -Sessions -Uin <号>
powershell -File core\qq-read.ps1 -Open "某人" -Messages -Since -Uin <号> -Json
powershell -File core\qq-send.ps1 -To "某人" -TextFile x.txt -Do -Uin <号>   # 不带 -Do 是演练
node panel\server.mjs                              # 面板 :8765
```

**改 `.ps1` 之后一定要核前三个字节是 `EF BB BF`。**

---

## 交接时的诚实说明

- 文档里标「实测」的是真的跑过、有输出；标「未验」的**不要当成能用**。
- 我这边上下文会丢，所以把判断依据都写在文档里了；接手的人**不要用推断替代复现**。
- 最容易犯的三个错，我自己各犯过一次：
  1. 拿代理指标当结论（面积当窗口大小、输入框回读当发送结果）；
  2. 把「没看见」当成「没发生」（回读读不到就重打、自检读不到就判坏）；
  3. 挑一个凑合（挑窗口、挑进程、挑号）——挑完必须报出挑的是谁。

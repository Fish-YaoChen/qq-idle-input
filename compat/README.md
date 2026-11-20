# 兼容性快照

每个测过的 QQ 版本一个 JSON：**只有类名、版本号、是否带无障碍参数**，不含任何昵称和消息内容。

- snapshot-9.9.37.json —— 实测可用的基线（自检十项全绿）
- 其它 snapshot-*.json —— 用户在自己机器上跑 selfcheck.ps1 -Snapshot <路径> 生成的

## 怎么新增一个版本

1. 在这个版本的 QQ 上跑：
   ``powershell
   powershell -File core\selfcheck.ps1 -Snapshot compat\snapshot-<版本号>.json
   ``
2. 看一下文件，确认只有类名（没有昵称、没有消息）。
3. 提 PR，或者贴到 issue 里。

## 快照长什么样

``json
{
  "时间": "2026-11-20T20:10:00",
  "QQ版本": "9.9.37-54395",
  "是不是Electron": true,
  "带无障碍参数": true,
  "类名": ["msg-content-container container--self mix-message__container", "..."]
}
``

# qq-read.ps1 — 不碰键鼠，从 QQ 无障碍树里读会话和消息。
#
# 前提：QQ 用 --force-renderer-accessibility 启动（11-20 验过，参数能透到 Chromium）。
# 它只读：不进会话、不发消息、不动焦点。要给会话发消息用 qq-send.ps1。
#
# 用法：
#   powershell -File qq-read.ps1                          # 列出会话（默认自动找小肥鱼那个进程）
#   powershell -File qq-read.ps1 -Sessions                 # 只列会话
#   powershell -File qq-read.ps1 -Open "妈妈" -Messages    # 点开会话读消息（Invoke，不碰鼠标）
#   powershell -File qq-read.ps1 -Uin 2727950855 -Json     # 输出 JSON
#   powershell -File qq-read.ps1 -Open "小林" -Messages -Since   # 只吐上次之后的新消息
#   powershell -File qq-read.ps1 -Open "小林" -Reset          # 把这个会话的游标清掉
param(
  [string]$Uin = "2727950855",
  [string]$Open,
  [switch]$Sessions,
  [switch]$Messages,
  [switch]$Json,
  [switch]$Since,          # 只吐比游标新的（游标在 ~/.dsh/qq-idle/cursor.json）
  [switch]$Reset,          # 清掉这个会话的游标
  [string]$CursorFile,     # 换一个游标文件（默认 ~/.dsh/qq-idle/cursor.json）
  [switch]$ShowFp,         # 连每条消息的指纹一起打出来（调游标用）
  [int]$MaxMessages = 30
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class QQWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
  [StructLayout(LayoutKind.Sequential)] public struct WPLACE { public uint length, flags, showCmd; public POINT min, max; public RECT normal; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WPLACE w);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  // 11-21：窗口缩着的时候 GetWindowRect 只回一个小矩形（实测 160x28），
  // 拿它比面积，会输给旁边那张「资料卡」浮窗（390x475），于是操作到浮窗身上。
  // 最小化时改用「还原后」的位置来比。
  public static long AreaOf(IntPtr h) {
    if (IsIconic(h)) {
      var w = new WPLACE(); w.length = (uint)Marshal.SizeOf(typeof(WPLACE));
      if (GetWindowPlacement(h, ref w)) {
        long aw = Math.Abs((long)(w.normal.R - w.normal.L) * (w.normal.B - w.normal.T));
        if (aw > 0) return aw;
      }
    }
    RECT r; if (!GetWindowRect(h, out r)) return 0;
    return Math.Abs((long)(r.R - r.L) * (r.B - r.T));
  }
  public static IntPtr FindByPid(uint pid) {
    IntPtr best = IntPtr.Zero; long area = 0;
    EnumWindows((h, p) => {
      uint wp; GetWindowThreadProcessId(h, out wp);
      if (wp != pid) return true;
      var sb = new StringBuilder(256); GetClassNameW(h, sb, 256);
      if (sb.ToString() != "Chrome_WidgetWin_1") return true;
      long a = AreaOf(h);
      if (a > area) { area = a; best = h; }
      return true;
    }, IntPtr.Zero);
    return best;
  }
}
'@

# 找进程：命令行里带 --from-multiple-login <uin>
$proc = Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" |
  Where-Object { $_.CommandLine -like "*--from-multiple-login $Uin *" } | Select-Object -First 1
if (-not $proc) { Write-Error "没找到 QQ $Uin 的进程"; exit 2 }
$pidQQ = [uint32]$proc.ProcessId
if (-not ($proc.CommandLine -like "*force-renderer-accessibility*")) {
  # 11-21：Write-Warning 在 -Command 调用下会跑到 stdout，把 JSON 污染成「警告 + JSON」，
  # 面板那边 JSON.parse 直接失败（sessions 变成空数组）。-Json 时就不打这句。
  if (-not $Json) { Write-Warning "这个实例没带 --force-renderer-accessibility。窗口渲染过一次之后树多半还在（11-21 实测），读不通再加这个参数。" }
}
$hwnd = [QQWin]::FindByPid($pidQQ)
if ($hwnd -eq [IntPtr]::Zero) { Write-Error "没找到 $Uin 的窗口"; exit 3 }

$win = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
$all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)

function Get-Sessions {
  # 一行会话 = 一个 Group，它的**直接**子节点里有 2~3 个 Text（昵称、时间、预览）。
  # 11-20 第一版按「子孙里有 2 个以上 Text」找，结果把包着整个列表的外层 Group
  # 也当成一行，输出里出现一大段拼起来的怪物。改成只看直接子节点。
  $list = @()
  $textCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Text)
  $groups = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Group)))
  foreach ($g in $groups) {
    $kids = $g.FindAll([System.Windows.Automation.TreeScope]::Children, $textCond)
    if ($kids.Count -lt 2 -or $kids.Count -gt 3) { continue }
    $names = @(); foreach ($t in $kids) { if ($t.Current.Name) { $names += $t.Current.Name } }
    if ($names.Count -eq 0) { continue }
    # 这一行要么自己支持 Invoke，要么它的父 Group 支持
    $clickable = $g
    if (-not ($g.GetSupportedPatterns() | Where-Object { $_ -eq [System.Windows.Automation.InvokePattern]::Pattern })) {
      $p = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($g)
      if ($p) { $clickable = $p }
    }
    $list += [pscustomobject]@{
      会话 = $names[0]
      时间 = $(if ($names.Count -ge 2) { $names[1] } else { "" })
      预览 = $(if ($names.Count -ge 3) { $names[2] } else { "" })
    }
  }
  return $list
}

# 11-20 两次把 QQ 卡死，都是对**藏进托盘的窗口**做 Invoke。
# 规矩：窗口不可见时先显示出来（不抢焦点），再操作；显示不出来就拒。
function Ensure-Visible {
  Add-Type @"
using System; using System.Runtime.InteropServices;
public static class __RDV { [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }
"@ -ErrorAction SilentlyContinue
  if ([__RDV]::IsWindowVisible($hwnd)) { return $true }
  [__RDV]::ShowWindow($hwnd, 4) | Out-Null      # SW_SHOWNOACTIVATE
  Start-Sleep -Milliseconds 900
  return [__RDV]::IsWindowVisible($hwnd)
}

function Open-Session([string]$name) {
  if (-not (Ensure-Visible)) { Write-Error "窗口显示不出来，不做任何操作（对隐藏窗口 Invoke 会把 QQ 卡死）"; return $false }
  # 11-21：不能「按名字找元素」——那个名字第一个匹配到的往往是顶部自己的昵称或者气泡里的头像名，
  # 点下去等于没点（昨天发错会话就是这么来的）。只认「会话行」：recent-contact-item，
  # 行里的第一个文本等于目标名字才算命中；点完再核对聊天窗口顶部的名字。
  $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $textCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Text)
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $row = $null
  foreach ($e in $all) {
    if ($e.Current.ClassName -notlike "recent-contact-item*") { continue }
    $t = $e.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)
    if ($t.Count -eq 0) { continue }
    if ($t[0].Current.Name -eq $name) { $row = $e; break }
  }
  if (-not $row) { Write-Error "会话列表里没有「$name」（只认会话行，不认名字碰巧相同的元素）"; return $false }

  # 11-21：这个版本的 QQ，点已经选中的那一行会把聊天区**关掉**——再点一次反而没标题了。
  # 所以先看顶部：已经是这个人，就直接读，一次都不点。
  $hdrNow = $null
  $snap = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $hdrNow = $snap | Where-Object { $_.Current.ClassName -eq "chat-header__contact-name" } | Select-Object -First 1
  if ($hdrNow -and $hdrNow.Current.Name -eq $name) { return $true }

  $clickable = $null
  $cur = $row
  for ($i = 0; $i -lt 5 -and $cur; $i++) {
    if ($cur.GetSupportedPatterns() | Where-Object { $_ -eq [System.Windows.Automation.InvokePattern]::Pattern }) { $clickable = $cur; break }
    $cur = $walker.GetParent($cur)
  }
  if (-not $clickable) { Write-Error "「$name」这一行不支持 Invoke"; return $false }
  $clickable.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Start-Sleep -Milliseconds 600

  # 核对：顶部名字对不对。不对就一个字都不往下做。
  # 11-21：聊天区是懒渲染的，点完 600ms 未必已经有标题——轮询 3 秒，别一缺就判「没进对」。
  $hdr = $null
  for ($k = 0; $k -lt 8; $k++) {
    $now = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $hdr = $now | Where-Object { $_.Current.ClassName -eq "chat-header__contact-name" } | Select-Object -First 1
    if ($hdr) { break }
    Start-Sleep -Milliseconds 400
  }
  if (-not $hdr) { Write-Error "点了「$name」，但三秒内聊天窗口顶部都没出现名字——不确定进没进对会话，停手"; return $false }
  $who = $hdr.Current.Name
  if ($who -ne $name) { Write-Error "顶部是「$who」，不是「$name」——不往下做了"; return $false }
  return $true
}

function Get-Messages([int]$max) {
  $win2 = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $all2 = $win2.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $textCond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Text)
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $msgs = @()
  $lastTime = $null
  foreach ($e in $all2) {
    $cls = $e.Current.ClassName
    if ($cls -eq "message__timestamp no-copy") {
      $t = $e.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)
      if ($t.Count -gt 0) { $lastTime = $t[0].Current.Name }
      continue
    }
    if ($cls -notlike "msg-content-container*") { continue }
    # 只取最外层那个容器：祖上也挂着 msg-content-container 的就是内层的重复
    $p = $walker.GetParent($e); $nested = $false
    while ($p) {
      if ($p.Current.ClassName -like "msg-content-container*") { $nested = $true; break }
      $p = $walker.GetParent($p)
    }
    if ($nested) { continue }
    $mine = $cls -like "*container--self*"
    $txt = $e.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)
    $body = @(); $seen = @{}
    foreach ($x in $txt) {
      $nm = $x.Current.Name
      if ($nm -and -not $seen.ContainsKey($nm)) { $seen[$nm] = 1; $body += $nm }
    }
    if ($body.Count) {
      $msgs += [pscustomobject]@{
        时间 = $lastTime
        谁 = $(if ($mine) { "我" } else { "对方" })
        内容 = ($body -join "`n")
      }
    }
  }
  if ($msgs.Count -gt $max) { $msgs = $msgs[($msgs.Count - $max)..($msgs.Count - 1)] }
  return $msgs
}

# ---------- 游标：只吐比上次新的 ----------
# 消息的身份用「谁 + 内容」的指纹，不用时间：QQ 的时间戳会变成「昨天 18:21」，
# 过了零点意思就变了，拿它当键，第二天一定对不上。
# 指纹撞上（连着两条一模一样的话）就取最后一条之后——宁可漏一条重复的，也别把旧消息重放一遍。
function Get-CursorPath {
  if ($CursorFile) { return $CursorFile }
  return (Join-Path $env:USERPROFILE ".dsh\qq-idle\cursor.json")
}

function Read-Cursor {
  $p = Get-CursorPath
  if (-not (Test-Path $p)) { return @{} }
  try {
    $o = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
    $h = @{}
    foreach ($k in $o.PSObject.Properties.Name) { $h[$k] = $o.$k }
    return $h
  } catch { return @{} }
}

function Write-Cursor([hashtable]$c) {
  $p = Get-CursorPath
  New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
  ($c | ConvertTo-Json -Depth 5) | Set-Content -Path $p -Encoding UTF8
}

function Get-Fp($m) {
  return (Get-Hash16 "$($m.谁)|$($m.内容)")
}

function Get-Hash16([string]$s) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
  return ([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 16).ToLower()
}

# 会话列表的「上次长什么样」：按会话名记 时间+预览 的指纹。
# 跟消息游标分开存（sessions.json / cursor.json）——一个是「谁在找我」，一个是「我读到哪了」。
function Get-SessionsStatePath {
  if ($CursorFile) { return (Join-Path (Split-Path $CursorFile -Parent) "sessions.json") }
  return (Join-Path $env:USERPROFILE ".dsh\qq-idle\sessions.json")
}

function Read-JsonMap([string]$p) {
  $h = @{}
  if (-not (Test-Path $p)) { return $h }
  try {
    $o = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in $o.PSObject.Properties.Name) { $h[$k] = $o.$k }
  } catch {}
  return $h
}

function Write-JsonMap([string]$p, [hashtable]$h) {
  New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
  ($h | ConvertTo-Json -Depth 6) | Set-Content -Path $p -Encoding UTF8
}

if (-not $Messages -or $Open) {
  $s = @(Get-Sessions)
  # 「谁在找我」：拿每个会话的 时间+预览 跟上次比。变了就是有新动静。
  # 第一次跑没有上次，全部算新（并说一句这是基线），第二次开始只标真变的。
  $sp = Get-SessionsStatePath
  $prevS = Read-JsonMap $sp
  $firstRun = ($prevS.Count -eq 0)
  $state = @{}
  foreach ($x in $s) {
    $fp = Get-Hash16 ("{0}|{1}" -f $x.时间, $x.预览)
    $isNew = -not ($prevS.ContainsKey($x.会话) -and $prevS[$x.会话].fp -eq $fp)
    $x | Add-Member -NotePropertyName 新 -NotePropertyValue $isNew -Force
    $state[$x.会话] = [pscustomobject]@{
      fp = $fp; 时间 = $x.时间; 预览 = ($x.预览 -replace "`n", " "); at = (Get-Date).ToString("s")
    }
  }
  Write-JsonMap $sp $state

  if ($Json) {
    $s | ConvertTo-Json -Depth 4
  } else {
    "=== 会话 $($s.Count) 个$(if ($firstRun) { '（第一次记基线，下次开始只标新的）' } else { '' }) ==="
    $s | ForEach-Object {
      $mark = if ($_.新) { '●' } else { ' ' }
      "  {0} {1,-10} {2,-10} {3}" -f $mark, $_.会话, $_.时间, ($_.预览 -replace "`n", " ")
    }
    if (-not $firstRun) {
      $hot = @($s | Where-Object { $_.新 } | ForEach-Object { $_.会话 })
      if ($hot.Count) { "  —— 有新动静：$($hot -join '、')" }
      else { "  —— 跟上次一样，没有新动静。" }
    }
  }
}



if ($Open) {
  if (Open-Session $Open) {
    if ($Messages -or $Json) {
      $m = @(Get-Messages $MaxMessages)
      $cur = Read-Cursor
      if ($Reset) { $cur.Remove($Open) | Out-Null }
      $prev = $cur[$Open]
      $new = $m
      $why = ""
      if ($prev -and $prev.fp -and $m.Count -gt 0) {
        $idx = -1
        for ($i = $m.Count - 1; $i -ge 0; $i--) {
          if ((Get-Fp $m[$i]) -eq $prev.fp) { $idx = $i; break }
        }
        if ($idx -ge 0) {
          $new = if ($idx -lt $m.Count - 1) { @($m[($idx + 1)..($m.Count - 1)]) } else { @() }
        } else {
          $why = "游标对不上（上次看到的那条已经不在窗口里了），这次把窗口里的都给你"
        }
      }
      if ($Since) {
        if ($Json) { $new | ConvertTo-Json -Depth 4 } else {
          if ($why) { "! $why" }
          if ($new.Count -eq 0) { "=== 「$Open」没有新消息 ===" }
          else {
            "=== 「$Open」新 $($new.Count) 条 ==="
            $new | ForEach-Object { "  [$($_.时间)] $($_.谁)：$(($_.内容 -replace "`n"," ").Substring(0,[Math]::Min(60,($_.内容 -replace "`n"," ").Length)))" }
          }
        }
      } else {
        if ($Json) { $m | ConvertTo-Json -Depth 4 } else {
          "=== 「$Open」最近 $($m.Count) 条 ==="
          $m | ForEach-Object { "  [$($_.时间)] $($_.谁)：$(($_.内容 -replace "`n"," ").Substring(0,[Math]::Min(60,($_.内容 -replace "`n"," ").Length)))" }
        }
      }
      if ($ShowFp) {
        "---- 指纹（从旧到新，最后一条是游标会记的）----"
        $m | ForEach-Object { "  {0}  [{1}] {2}" -f (Get-Fp $_), $_.时间, $_.谁 }
        if ($prev) { "  游标现在指着：" + $prev.fp + "（" + $prev.时间 + "）" }
      }
      # 记到窗口里最后一条：下次从这里往下数
      if ($m.Count -gt 0) {
        $last = $m[$m.Count - 1]
        $cur[$Open] = [pscustomobject]@{ fp = (Get-Fp $last); 时间 = $last.时间; at = (Get-Date).ToString("s") }
        Write-Cursor $cur
      }
    }
  }
}

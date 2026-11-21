# selfcheck.ps1 — 先跑这个。它不读消息、不发消息，只回答「这台机器上能不能用」。
#
# 设计原则：
#   * 每一项都说「为什么、怎么办」，不只说失败；
#   * 快照只存**类名**——不含昵称、不含消息正文、不含 QQ 号；
#   * 任何一项不过都不抛异常，一路跑到底，最后一句给结论。
#
# 用法：
#   powershell -File selfcheck.ps1                # 打勾 + 结论
#   powershell -File selfcheck.ps1 -Json          # 输出 JSON（给 agent / 面板用）
#   powershell -File selfcheck.ps1 -Snapshot 路径   # 额外写一份类名快照
param(
  [string]$Uin = "",
  [switch]$Json,
  [string]$Snapshot = ""
)

$ErrorActionPreference = "Continue"
$results = New-Object System.Collections.ArrayList
$classNameSet = New-Object System.Collections.Generic.HashSet[string]

function Add-Check([string]$id, [string]$title, [string]$status, [string]$detail, [string]$fix) {
  [void]$results.Add([pscustomobject]@{ id = $id; 项目 = $title; 结果 = $status; 说明 = $detail; 怎么办 = $fix })
}

function Say([string]$id, [string]$title, [string]$status, [string]$detail, [string]$fix) {
  Add-Check $id $title $status $detail $fix
  if (-not $Json) {
    $mark = switch ($status) { "ok" { "✅" } "warn" { "⚠️ " } default { "❌" } }
    "{0} {1}" -f $mark, $title
    if ($detail) { "     $detail" }
    if ($fix -and $status -ne "ok") { "     → $fix" }
  }
}

# ---------- 1. 平台 ----------
if ($env:OS -ne "Windows_NT") {
  Say "os" "运行平台" "fail" "当前不是 Windows（$($PSVersionTable.OS)）" "这个工具只用 Windows 的无障碍接口，Mac / Linux 用不了"
} else {
  Say "os" "运行平台" "ok" "Windows $([System.Environment]::OSVersion.Version)" ""
}

# ---------- 2. PowerShell 与无障碍程序集 ----------
$uiaOk = $false
try {
  Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
  Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
  $uiaOk = $true
  Say "uia" "无障碍接口（UIAutomation）" "ok" "PowerShell $($PSVersionTable.PSVersion)" ""
} catch {
  Say "uia" "无障碍接口（UIAutomation）" "fail" $_.Exception.Message "系统组件缺失，换一台机器或修复 .NET Framework"
}

# ---------- 3. 找 QQ ----------
$qqs = @()
try {
  $qqs = @(Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" -ErrorAction Stop)
} catch {
  Say "qqproc" "找到 QQ 进程" "fail" $_.Exception.Message "请用管理员/当前用户身份运行"
}
if ($qqs.Count -eq 0) {
  Say "qqproc" "找到 QQ 进程" "fail" "一个 QQ.exe 都没在跑" "先启动 QQ 并登录"
} else {
  if ($Uin) {
    $qqs = @($qqs | Where-Object { $_.CommandLine -like "*$Uin*" })
    if ($qqs.Count -eq 0) { Say "qqproc" "找到 QQ 进程" "fail" "没找到账号 $Uin 的进程" "去掉 -Uin 让它自己挑，或确认号对不对" }
  } else {
    # 没指定号时，优先挑带 --force-renderer-accessibility 的那个实例：
    # 一台机器上可能登着两个号，另一个号没带参数，挑错了就会误报「读不可以」。11-20 踩过。
    $withFlag = @($qqs | Where-Object { $_.CommandLine -like "*force-renderer-accessibility*" })
    if ($withFlag.Count -gt 0) { $qqs = $withFlag }
  }
  if ($qqs.Count -gt 0) {
    # 挑主实例：命令行里有 background.js 的那个，不是一个 gpu/renderer 子进程
    $all = @($qqs | Where-Object { $_.CommandLine -like "*background.js*" })
    if ($all.Count -eq 0) { $all = @($qqs) }
    # 多个号同时登着时，别静悄悄挑一个：把号打出来。
    # 11-21 早上就吃过这个闷亏：自检验的是 2653935317，读会话读的却是 2727950855，
    # 两边数对不上，我还以为是树坏了。
    $uins = @($all | ForEach-Object {
      if ($_.CommandLine -match 'from-multiple-login\s+(\d+)') { $Matches[1] } else { '未知号' }
    })
    $main = @($all | Select-Object -First 1)
    $qqPid = [int]$main[0].ProcessId
    $who = if ($main[0].CommandLine -match 'from-multiple-login\s+(\d+)') { $Matches[1] } else { '共用一个实例' }
    if ($uins.Count -gt 1) {
      Say "qqproc" "找到 QQ 进程" "warn" "PID=$qqPid（登录号 $who）" "这台机器上同时登着 $($uins -join '、')，这次只验了 $who；要验另一个用 -Uin 指定"
    } else {
      Say "qqproc" "找到 QQ 进程" "ok" "PID=$qqPid（登录号 $who）" ""
    }
  }
}

# ---------- 4. 是不是 Electron 版 ----------
$exePath = $null
if ($qqPid) { try { $exePath = (Get-Process -Id $qqPid).Path } catch {} }
$isElectron = $false
if ($exePath) {
  $root = Split-Path $exePath -Parent
  $asar = Get-ChildItem $root -Recurse -Depth 6 -Filter "*.asar" -ErrorAction SilentlyContinue | Select-Object -First 1
  $isElectron = [bool]$asar
  if ($isElectron) { Say "electron" "QQ 是不是 Electron 版（NT）" "ok" "找到 $($asar.FullName)" "" }
  else { Say "electron" "QQ 是不是 Electron 版（NT）" "fail" "安装目录里没找到 app.asar" "这是老版 QQ，界面是另一套控件，本工具不支持" }
} else {
  Say "electron" "QQ 是不是 Electron 版（NT）" "fail" "读不到 QQ 的安装路径" "权限不够，换当前用户身份运行"
}

# ---------- 5. 版本号 ----------
$version = ""
if ($exePath) {
  $rootDir = Split-Path $exePath -Parent
  $verDir = @(Get-ChildItem "$rootDir\versions" -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path "$($_.FullName)\resources\app\application.asar" } | Select-Object -First 1)
  if ($verDir.Count -gt 0) { $version = $verDir[0].Name }
  else { try { $version = (Get-Item $exePath).VersionInfo.ProductVersion } catch {} }
}
if ($version) {
  $tested = "9.9.37"
  if ($version -like "$tested*") { Say "version" "QQ 版本" "ok" $version "（这个版本实测过）" }
  else { Say "version" "QQ 版本" "warn" $version "没实测过的版本，继续看下面几项；类名对得上就大概率能用" }
} else {
  Say "version" "QQ 版本" "warn" "读不到版本号" "不影响使用，只是有兼容问题时少了线索"
}

# ---------- 6. 无障碍启动参数 ----------
$cmdLine = ""
if ($qqPid) { try { $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$qqPid").CommandLine } catch {} }
$hasFlag = $cmdLine -like "*force-renderer-accessibility*"
if ($hasFlag) {
  Say "flag" "带无障碍参数启动" "ok" "--force-renderer-accessibility 已开" ""
} else {
  $base = '"' + $exePath + '"'
  $asarPath = if ($isElectron) { (Get-ChildItem (Split-Path $exePath -Parent) -Recurse -Depth 3 -Filter "background.js" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like "*application.asar*" } | Select-Object -First 1).FullName } else { "" }
  $hint = if ($asarPath) { "关掉 QQ，再用这条命令启动：`n     `"$exePath`" `"$asarPath`" --force-renderer-accessibility --disable-renderer-backgrounding" } else { "关掉 QQ，用带 --force-renderer-accessibility 的方式重新启动" }
  Say "flag" "带无障碍参数启动" "warn" "没带这个参数" "11-21 实测：窗口渲染过一次之后，树一直留着，不带参数也能读。参数的作用是让树一开始就建好（不用先把窗口拉出来看一次）。读到底行不行，看下面「无障碍树」那项。"
}

# ---------- 7/8. 窗口与无障碍树 ----------
if ($uiaOk -and $qqPid) {
  $h = [IntPtr]::Zero
  $found = @()
  $cb = [System.Func[object, bool]]{ param($x) $true }
  # 用 UIA 直接按进程找窗口，避开自写 P/Invoke
  # QQ 一个进程有好几个 Chrome_WidgetWin_1：主窗口、托盘小窗（32x39）、悬浮窗……
  # 11-20 就是抓到了第一个（32x39 那个），一直读到 11 个元素、什么都读不出。
  # 规则：先按「无障碍元素多」挑，元素数一样再比面积。
  # 11-21 补：窗口最小化时 GetWindowRect 只回一个小矩形（160x28），
  # 按面积挑会挑到旁边那张「资料卡」浮窗（390x475，61 个元素）——
  # 结果自检报「读不可以、一行会话都没有」，可主窗其实好好的（290 个元素）。
  # 面积在缩着的时候不可信，元素数可信。
  if (-not ("__WW" -as [type])) {
    Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class __WW {
 public delegate bool EnumProc(IntPtr h, IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
 public static IntPtr[] List(uint pid) {
   var l = new List<IntPtr>();
   EnumWindows((h, p) => {
     uint wp; GetWindowThreadProcessId(h, out wp);
     if (wp != pid) return true;
     var sb = new StringBuilder(256); GetClassNameW(h, sb, 256);
     if (sb.ToString() != "Chrome_WidgetWin_1") return true;
     l.Add(h); return true;
   }, IntPtr.Zero);
   return l.ToArray();
 }
 public static long Area(IntPtr h) {
   RECT r; if (!GetWindowRect(h, out r)) return 0;
   return Math.Abs((long)(r.R - r.L) * (r.B - r.T));
 }
 public static bool Minimized(IntPtr h) { return IsIconic(h); }
}
"@ -ErrorAction SilentlyContinue
  }

  function Select-MainWindow([uint32]$procId) {
    $best = [IntPtr]::Zero; $bestN = -1; $bestArea = -1
    foreach ($h in [__WW]::List($procId)) {
      $n = -1
      try {
        $ae = [System.Windows.Automation.AutomationElement]::FromHandle($h)
        $n = $ae.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition).Count
      } catch { $n = -1 }
      $a = [__WW]::Area($h)
      if ($n -gt $bestN -or ($n -eq $bestN -and $a -gt $bestArea)) { $best = $h; $bestN = $n; $bestArea = $a }
    }
    return $best
  }

  $win = $null
  $mainHwnd = Select-MainWindow ([uint32]$qqPid)
  if ($mainHwnd -ne [IntPtr]::Zero) { $win = [System.Windows.Automation.AutomationElement]::FromHandle($mainHwnd) }
  if (-not $win) {
    Say "window" "找到 QQ 窗口" "fail" "进程在，但没找到它的顶层窗口" "QQ 可能藏在托盘里，点开一次再跑"
  } else {
    # 窗口藏在托盘时，界面树几乎是空的——先显示出来（SW_SHOWNOACTIVATE，不抢焦点）
    # 注意：IsOffscreen 不可靠（关到托盘后它还是报 False），要用 IsWindowVisible 才算数。
    Add-Type @"
using System; using System.Runtime.InteropServices;
public static class __VIS { [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }
"@ -ErrorAction SilentlyContinue
    $hwndReal = [IntPtr]$win.Current.NativeWindowHandle
    if (-not [__VIS]::IsWindowVisible($hwndReal)) {
      if (-not $Json) { "      （窗口藏在托盘里，先显示出来——不抢焦点）" }
      [__VIS]::ShowWindow($hwndReal, 4) | Out-Null
      Start-Sleep -Milliseconds 900
      $mainHwnd2 = Select-MainWindow ([uint32]$qqPid)
      if ($mainHwnd2 -ne [IntPtr]::Zero) { $win = [System.Windows.Automation.AutomationElement]::FromHandle($mainHwnd2) }
      $hwndReal = [IntPtr]$win.Current.NativeWindowHandle
    }
    if ($false) {
      Add-Type @"
using System; using System.Runtime.InteropServices;
public static class __SW { [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd); }
"@ -ErrorAction SilentlyContinue
      [__SW]::ShowWindow([IntPtr]$win.Current.NativeWindowHandle, 4) | Out-Null
      Start-Sleep -Milliseconds 600
      $cond2 = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $qqPid)
      $win = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond2)
    }
    Say "window" "找到 QQ 窗口" "ok" "标题「$($win.Current.Name)」 屏外=$($win.Current.IsOffscreen)" ""
    $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    # 界面没加载完的时候元素很少（11 个左右）。别急着报错：等两秒重读，最多三次；
    # 还不行就最小化再还原一次（逼它重画）。11-20 实测这两步能救回大半「空白窗口」。
    $tries = 0
    while ($all.Count -le 20 -and $tries -lt 3) {
      Start-Sleep -Milliseconds 1500
      $mm = Select-MainWindow ([uint32]$qqPid)
      if ($mm -ne [IntPtr]::Zero) { $win = [System.Windows.Automation.AutomationElement]::FromHandle($mm) } else { $win = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$win.Current.NativeWindowHandle) }
      $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
      if ($all.Count -le 20 -and $tries -eq 1) {
        Add-Type @"
using System; using System.Runtime.InteropServices;
public static class __RC { [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }
"@ -ErrorAction SilentlyContinue
        [__RC]::ShowWindow([IntPtr]$win.Current.NativeWindowHandle, 6) | Out-Null
        Start-Sleep -Milliseconds 400
        [__RC]::ShowWindow([IntPtr]$win.Current.NativeWindowHandle, 9) | Out-Null
        Start-Sleep -Milliseconds 1200
        $win = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$win.Current.NativeWindowHandle)
        $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
      }
      $tries++
    }
    if ($tries -gt 0 -and $all.Count -gt 20) { if (-not $Json) { "      （等了 $tries 次才读到界面，QQ 加载慢）" } }
    foreach ($e in $all) { $c = $e.Current.ClassName; if ($c) { [void]$classNameSet.Add($c) } }
    $textCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    $texts = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)
    if ($all.Count -le 20 -or $texts.Count -eq 0) {
      # 区分两种情况：参数没生效 vs QQ 自己窗口是空白的（11-20 遇到过：重启后界面没加载完，元素只有 11 个）
      $hint2 = if ($all.Count -le 20) { "窗口看起来是空白的（只有 $($all.Count) 个元素），多半是 QQ 没加载完——重启 QQ 再跑一次自检" } else { "无障碍参数可能没生效，或者窗口藏在托盘里；先点开窗口再跑" }
      Say "tree" "无障碍树有内容" "fail" "只读到 $($all.Count) 个元素、$($texts.Count) 个文本节点" $hint2
    } else {
      Say "tree" "无障碍树有内容" "ok" "$($all.Count) 个元素、$($texts.Count) 个文本节点" ""
    }

    # ---------- 9. 关键类名 ----------
    $need = @{
      "msg-content-container" = "消息气泡"
      "ExEditor-qq-msg-editor" = "输入框"
      "send-msg" = "发送按钮"
      "chat-header__contact-name" = "会话标题"
      "message__timestamp" = "时间戳"
    }
    $missing = @()
    foreach ($k in $need.Keys) {
      $hit = @($classNameSet | Where-Object { $_ -like "*$k*" })
      if ($hit.Count -eq 0) { $missing += "$k（$($need[$k])）" }
    }
    if ($missing.Count -eq 0) {
      Say "classnames" "五个关键类名都在" "ok" ($need.Keys -join "、") ""
    } elseif ($all.Count -gt 50) {
      # 会话列表读得到、元素也不少，却缺这几个——多半是**没打开任何聊天**，
      # 输入框、气泡、发送按钮只在打开会话后才存在。这不该判「改版」。
      Say "classnames" "五个关键类名都在" "warn" ("没打开会话，这几项现在看不到：" + ($missing -join "；")) "打开任意一个聊天，再跑一次自检；写的那项要等这时才能确认"
    } else {
      $hint3 = if ($all.Count -le 20) { "界面是空白的，先别当成改版——重启 QQ 再看" } else { "QQ 大概率改版了。把类名快照发出去，等人补适配" }
      Say "classnames" "五个关键类名都在" "fail" ("缺：" + ($missing -join "；")) $hint3
    }

    # ---------- 10. 会话行 ----------
    $textCond2 = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    $rows = 0
    $groups = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Group)))
    foreach ($g in $groups) {
      $kids = $g.FindAll([System.Windows.Automation.TreeScope]::Children, $textCond2)
      if ($kids.Count -ge 2 -and $kids.Count -le 3) { $rows++ }
    }
    if ($rows -gt 0) { Say "sessions" "认得出会话列表" "ok" "像是 $rows 行" "" }
    else { Say "sessions" "认得出会话列表" "fail" "一行都没认出来" "可能没登录、或者界面停在别的页" }
  }
} else {
  Say "window" "找到 QQ 窗口" "fail" "前面没通过，跳过" ""
  Say "tree" "无障碍树有内容" "fail" "前面没通过，跳过" ""
  Say "classnames" "五个关键类名都在" "fail" "前面没通过，跳过" ""
  Say "sessions" "认得出会话列表" "fail" "前面没通过，跳过" ""
}

# ---------- 结论 ----------
$fail = @($results | Where-Object { $_.结果 -eq "fail" })
$verbose = @($results | Where-Object { $_.结果 -eq "fail" })

# 能不能用，看实际读到了什么，而不是看「参数有没有带」——11-20 发现 Chromium 可能被 UIA 查询唤醒
$canRead = (-not ($fail | Where-Object { $_.id -in @("os", "uia", "qqproc", "window", "tree", "classnames", "sessions") }))
# 写要看两样：会话行认得出来 + 输入框/发送按钮真存在。
# 没打开会话时那两样看不见，只能算「待确认」，不能报「可以」。
$clsState = ($results | Where-Object { $_.id -eq "classnames" } | Select-Object -First 1).结果
$canWrite = $canRead -and ($clsState -eq "ok")
$writeLabel = if ($clsState -eq "ok") { "可以" } elseif ($canRead) { "待确认（先打开一个聊天）" } else { "不可以" }

if ($Json) {
  [pscustomobject]@{
    可以读 = $canRead
    可以写 = $canWrite
    写状态 = $writeLabel
    版本 = $version
    结果 = $results
  } | ConvertTo-Json -Depth 6
} else {
  ""
  "———— 结论 ————"
  "读：{0}    写：{1}" -f $(if ($canRead) { "可以" } else { "不可以" }), $writeLabel
  if ($fail.Count) { "没过的项：" + (($fail | ForEach-Object { $_.项目 }) -join "、") }
  if (-not $canWrite -and $canRead) { "写还要求输入框和发送按钮可用，上面都绿了才行" }
}

# ---------- 快照（只存类名） ----------
if ($Snapshot) {
  $snap = [pscustomobject]@{
    时间 = (Get-Date).ToString("s")
    QQ版本 = $version
    是不是Electron = $isElectron
    带无障碍参数 = $hasFlag
    类名 = @($classNameSet | Sort-Object)
  }
  $dir = Split-Path $Snapshot -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $snap | ConvertTo-Json -Depth 4 | Set-Content -Path $Snapshot -Encoding utf8
  if (-not $Json) { "快照已写：$Snapshot（只有类名，没有任何消息内容）" }
}

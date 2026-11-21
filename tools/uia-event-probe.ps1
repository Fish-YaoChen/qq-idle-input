# uia-event-probe.ps1 —— 挂上 QQ 的无障碍事件，看「来消息」会不会自己冒出来
# 只订阅、只读，不点窗口、不碰键鼠、不发消息。
# 用法：pwsh -File uia-event-probe.ps1 -Uin 2727950855 -Seconds 60 -Out C:\temp\probe.log

param(
  [string]$Uin = "",
  [int]$Seconds = 60,
  [string]$Out = "$env:TEMP\uia-probe.log"
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ("__EV" -as [type])) {
  # 编译这段 C# 要 UIAutomation + 基础程序集。只给两个名字会把默认引用顶掉，
  # 连 List<> 都找不到（两次都栽在这儿）。这里把基础程序集显式列全，
  # 并且**跑在 Windows PowerShell 5.1 下**（.NET Framework 那套按名字给引用最听话）。
  Add-Type -ReferencedAssemblies 'System.dll','System.Core.dll','UIAutomationClient.dll','UIAutomationTypes.dll' -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Automation;

public static class __EV {
  static AutomationElement _list;
  static AutomationElement _root;
  static AutomationEventHandler _structHandler;
  static AutomationPropertyChangedEventHandler _nameHandler;
  static List<string> _log = new List<string>();
  static string _file;

  static void Emit(string s) {
    lock (_log) {
      _log.Add(s);
      try { File.AppendAllText(_file, s + Environment.NewLine, Encoding.UTF8); } catch {}
    }
  }

  public static string Start(IntPtr hwnd, int seconds, string file) {
    _file = file;
    try { File.WriteAllText(_file, "", Encoding.UTF8); } catch {}
    _root = AutomationElement.FromHandle(hwnd);
    if (_root == null) return "no-root";

    // 会话列表：recent-contact-list 那个滚动区。找不到就退回整棵树。
    var byClass = _root.FindFirst(TreeScope.Descendants,
      new PropertyCondition(AutomationElement.ClassNameProperty, "q-scroll-view scroll-view--memory scroll-view--show-scrollbar recent-contact-list"));
    if (byClass == null) {
      byClass = _root.FindFirst(TreeScope.Descendants,
        new PropertyCondition(AutomationElement.ClassNameProperty, "recent-contact-item"));
      if (byClass != null) byClass = TreeWalker.ControlViewWalker.GetParent(byClass);
    }
    _list = byClass;

    _structHandler = new AutomationEventHandler((s, e) => {
      Emit(DateTime.Now.ToString("HH:mm:ss.fff") + "  STRUCT  " + e.EventId.ProgrammaticName);
    });
    _nameHandler = new AutomationPropertyChangedEventHandler((s, e) => {
      string nm = "";
      try { var el = (AutomationElement)s; nm = el.Current.Name; } catch {}
      Emit(DateTime.Now.ToString("HH:mm:ss.fff") + "  NAME    「" + nm + "」");
    });

    var target = _list ?? _root;
    Automation.AddAutomationEventHandler(AutomationElement.StructureChangedEvent, target, TreeScope.Subtree, _structHandler);
    Automation.AddAutomationPropertyChangedEventHandler(_root, TreeScope.Subtree, _nameHandler, AutomationElement.NameProperty);

    Emit("probe start  list=" + (target == _root ? "整棵树" : "会话列表") + "  seconds=" + seconds);
    Thread.Sleep(seconds * 1000);

    try { Automation.RemoveAllEventHandlers(); } catch {}
    int n;
    lock (_log) n = _log.Count;
    return "events=" + (n - 1);
  }
}
"@
}

# 找 QQ 主窗（不猜号：多号同登又没指定就退出）
$cands = @(Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" | Where-Object { $_.CommandLine -match 'from-multiple-login\s+\d+' })
if ($Uin) {
  $cands = @($cands | Where-Object { $_.CommandLine -like "*--from-multiple-login $Uin *" })
  if (-not $cands.Count) { Write-Error "没找到 QQ $Uin 的进程"; exit 2 }
} else {
  $uins = @($cands | ForEach-Object { if ($_.CommandLine -match 'from-multiple-login\s+(\d+)') { $Matches[1] } })
  if ($uins.Count -gt 1) { Write-Error ("同时登着 $($uins -join '、')，用 -Uin 指定"); exit 2 }
}
if (-not $cands.Count) { Write-Error "没找到 QQ 进程"; exit 2 }
$procId = [uint32]$cands[0].ProcessId

# 主窗 = 这个进程里元素最多的那个（用 selfcheck 的同一条规矩）
$best = $null; $bestN = -1
foreach ($p in Get-Process -Id $procId) {
  $h = $p.MainWindowHandle
  if ($h -eq [IntPtr]::Zero) { continue }
}
$uiaProbe = @'
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public class __WH {
  public delegate bool Proc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(Proc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  public static List<IntPtr> List(uint pid){
    var l=new List<IntPtr>();
    EnumWindows((h,p)=>{ uint wp; GetWindowThreadProcessId(h,out wp); if(wp!=pid) return true;
      var c=new StringBuilder(256); GetClassName(h,c,256);
      if(c.ToString()=="Chrome_WidgetWin_1") l.Add(h); return true; }, IntPtr.Zero);
    return l;
  }
}
'@
Add-Type -TypeDefinition $uiaProbe -ErrorAction SilentlyContinue
foreach ($h in [__WH]::List($procId)) {
  $n = -1
  try {
    $ae = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    $n = $ae.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition).Count
  } catch {}
  if ($n -gt $bestN) { $bestN = $n; $best = $h }
}
if (-not $best) { Write-Error "没找到主窗"; exit 3 }

Write-Host ("挂到窗口 hwnd=$best（元素 $bestN），跑 $Seconds 秒…")
$r = [__EV]::Start($best, $Seconds, $Out)
Write-Host $r
Write-Host ("日志：$Out")

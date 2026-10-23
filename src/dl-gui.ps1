# =====================================================================
#  设备诊断修复 · DeviceLens —— 图形界面
#  版本 0.2.2      作者：永远的兰兰
#
#  用法：双击「设备诊断修复.exe」，或双击 bat（脚本版，内容完全一样）
#  参数：-Lang zh|en     强制界面语言
#        -Shot <png>      截图后退出（自测用）
#        -AutoScan        启动即体检（自测用）
#
#  体检全程只读：不写注册表、不写盘、不卸载任何设备。
#  修复只做两种、且都可撤销：给数据分区分配盘符、重新启用被禁用的设备。
#  每一处「没有盘符」都要先判分区身份 —— EFI / MSR / 恢复分区本来就没有盘符。
# =====================================================================
param(
    [string]$Lang = '',
    [string]$Shot = '',
    [switch]$AutoScan,
    [string]$ShotDlg = '',
    [string]$SwitchTo = '',
    [switch]$ShotHw,
    [switch]$ShotFix
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- 核心引擎 ----------
$corePath = Join-Path $PSScriptRoot 'dl-core.ps1'
if (-not (Test-Path $corePath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "缺少核心文件 dl-core.ps1，请把压缩包整个解压后再运行。`r`n`r`nMissing dl-core.ps1 - extract the whole archive first.",
        'DeviceLens', 'OK', 'Error') | Out-Null
    exit 1
}
. $corePath

# ---------- 与前作隔离的自检 ----------
# 两个工具解压到同一目录时，脚本会互相覆盖，调错核心就全乱。
# 宁可拒绝启动，也不能带着别人的核心跑。
if ((Test-Path (Join-Path $PSScriptRoot 'comfix-core.ps1')) -or (Test-Path (Join-Path $PSScriptRoot 'usbprobe.ps1'))) {
    [System.Windows.Forms.MessageBox]::Show(
        "这个目录里还有「USB / 串口 一键修复」的文件。`r`n两款工具不能放在同一个文件夹里，会互相覆盖。`r`n`r`n请把本程序解压到它自己的文件夹。`r`n`r`nAnother tool's files were found here. Please extract this program into its own folder.",
        'DeviceLens', 'OK', 'Warning') | Out-Null
    exit 1
}

# ---------- 控制台窗口 ----------
$script:ConH = [IntPtr]::Zero
$script:ConWasVisible = $null
function Get-ConHandle {
    if ($script:ConH -ne [IntPtr]::Zero) { return $script:ConH }
    try {
        if (-not ('DLNative.DLConsole' -as [type])) {
            $sig = '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();' +
                   '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);' +
                   '[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);'
            Add-Type -MemberDefinition $sig -Name 'DLConsole' -Namespace 'DLNative' | Out-Null
        }
        $script:ConH = [DLNative.DLConsole]::GetConsoleWindow()
    } catch { }
    return $script:ConH
}
function Hide-ConsoleWindow {
    $h = Get-ConHandle
    if ($h -eq [IntPtr]::Zero) { return }
    try {
        if ($null -eq $script:ConWasVisible) { $script:ConWasVisible = [DLNative.DLConsole]::IsWindowVisible($h) }
        [void][DLNative.DLConsole]::ShowWindow($h, 0)
    } catch { }
}
function Show-ConsoleWindow {
    $h = Get-ConHandle
    if ($h -eq [IntPtr]::Zero) { return }
    if ($script:ConWasVisible -ne $true) { return }
    try { [void][DLNative.DLConsole]::ShowWindow($h, 5) } catch { }
}

# ---------- 配色 ----------
$C_BG       = [System.Drawing.Color]::FromArgb(240, 240, 240)
$C_PANEL    = [System.Drawing.Color]::FromArgb(252, 252, 252)
$C_TEXT     = [System.Drawing.Color]::FromArgb(33, 33, 33)
$C_SUB      = [System.Drawing.Color]::FromArgb(112, 112, 112)
$C_GREEN    = [System.Drawing.Color]::FromArgb(46, 125, 50)
$C_BLUE     = [System.Drawing.Color]::FromArgb(21, 101, 192)
$C_GRAY     = [System.Drawing.Color]::FromArgb(96, 125, 139)
$C_RED      = [System.Drawing.Color]::FromArgb(198, 40, 40)
$C_AMBER    = [System.Drawing.Color]::FromArgb(190, 110, 0)
$C_HINT_BG  = [System.Drawing.Color]::FromArgb(255, 244, 214)
$C_HINT_FG  = [System.Drawing.Color]::FromArgb(138, 82, 0)
$C_OK_BG    = [System.Drawing.Color]::FromArgb(226, 242, 229)
$C_OK_FG    = [System.Drawing.Color]::FromArgb(27, 94, 32)
$C_BAD_BG   = [System.Drawing.Color]::FromArgb(253, 232, 232)
$C_BAD_FG   = [System.Drawing.Color]::FromArgb(160, 30, 30)
$C_ROW_WARN = [System.Drawing.Color]::FromArgb(150, 88, 0)
$C_ROW_BAD  = [System.Drawing.Color]::FromArgb(180, 30, 30)

# =====================================================================
#  语言
# =====================================================================
$REG_APP = 'HKCU:\Software\DeviceLens'

function Get-SystemLang {
    try {
        $n = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
        if ($n -eq 'zh') { return 'zh' }
        return 'en'
    } catch { return 'zh' }
}
function Load-LangPref {
    $l = ''
    try { $l = [string](Get-ItemProperty $REG_APP -Name Lang -ErrorAction Stop).Lang } catch { }
    if ($l -eq 'zh' -or $l -eq 'en') { return $l }
    return (Get-SystemLang)
}
function Save-LangPref([string]$l) {
    try {
        if (-not (Test-Path $REG_APP)) { New-Item -Path $REG_APP -Force | Out-Null }
        Set-ItemProperty $REG_APP -Name Lang -Value $l -ErrorAction Stop
    } catch { }
}

# 注意：$script:LANG 不能先给默认值，否则会盖掉命令行 -Lang
if ($Lang -eq 'zh' -or $Lang -eq 'en') { $script:LANG = $Lang }
else { $script:LANG = Load-LangPref }
DL-SetLang $script:LANG

$script:TXT = @{
    'zh' = @{
        'app.title'   = '设备诊断修复'
        'app.sub'     = 'U 盘 · 内存卡 · 移动硬盘 · 串口卡 · 任何接在电脑上的设备：先看清断在哪一层，再决定动不动手'
        'app.author'  = '© 永远的兰兰'

        'menu.tools'  = '工具(&T)'
        'menu.help'   = '使用说明(&H)'
        'menu.disc'   = '免责声明(&D)'
        'menu.about'  = '关于(&A)'

        'hdr.help'    = '使用说明'
        'hdr.disc'    = '免责声明'
        'hdr.about'   = '关于'

        'menu.scan'   = '全面体检'
        'menu.rescan' = '重新识别设备'
        'menu.letters'= '盘符占用看板 (A–Z)'
        'menu.report' = '导出诊断报告'
        'menu.folder' = '打开报告所在文件夹'
        'menu.undo'   = '撤销上一次修复'
        'menu.fixlog' = '打开修复记录'
        'menu.quit'   = '退出'

        'hint.welcome'= '① 把出问题的那台设备插上，并保持插着　→　② 点右下角的「全面体检」'
        'hint.scanning'= '正在读取设备信息，稍等几秒……'
        'hint.ok'     = '✓ 读了 {n} 台设备，{d} 块磁盘，没发现明显问题'
        'hint.warn'   = '● 有 {n} 项需要注意 —— 在左边点一条，右边会说清是什么问题、能不能修'
        'hint.bad'    = '● 有 {n} 项确实有问题 —— 在左边点一条，右边会说清是什么问题、能不能修'
        'hint.noadm'  = '⚠ 当前不是管理员：看和导出都能用，「重新识别」需要管理员'
        'hint.rescan.ok'  = '✓ 已重新扫描硬件改动。新插上的设备现在应该出现了'
        'hint.rescan.fail'= '✕ 重新识别没能完成：需要管理员权限，或被安全软件拦住了'

        'st.switching' = '正在按新语言重新判定…'
        'st.hwscan'    = '正在读取硬件（CPU / 内存 / 显卡 / 主板 / 温度）…'
        'list.count'  = '共 {n} 项 · {w} 项要注意'
        'list.count.ok' = '共 {n} 项'
        'filt.hw'     = '硬件'
        'filt.key'    = '重点'
        'filt.all'    = '全部设备'
        'filt.bad'    = '只看问题'

        'pane.title'  = '这一条，到底怎么回事'
        'pane.empty'  = '在左边点一条，这里会写清三件事：它是什么问题、能不能修、现在最该做什么。'
        'seg.1'       = '① 它是什么问题'
        'seg.2'       = '② 能不能修'
        'seg.3'       = '③ 现在最该做什么'
        'seg.ev'      = '证据'

        'btn.fix'     = '修复这一项（可还原）'
        'btn.fixnone' = '这一项不需要修'
        'btn.fixno'   = '这一项软件修不了'
        'fix.confirm.t' = '确认修复'
        'fix.confirm.m' = '将要执行：{act}{n}{n}对象：{name}{n}{n}改之前的样子会先写进留底文件，随时可以在「工具 → 撤销上一次修复」里还原。{n}{n}继续吗？'
        'fix.act.assign' = '给这个分区分配一个盘符（不动任何数据）'
        'fix.act.enable' = '启用这台设备（等同设备管理器里点「启用设备」）'
        'fix.undoable'  = '可在「工具 → 撤销上一次修复」里还原'
        'fix.done'      = '修复完成'
        'fix.fail'      = '修复没有成功'
        'fix.noadm'     = '修复要写系统设置，需要管理员权限。现在以管理员身份重新打开吗？'
        'st.fixing'     = '正在修复…'
        'undo.none'     = '留底文件里还没有修复记录，没有可撤销的动作。'
        'undo.confirm.m' = '要把上一次修复还原回去吗？{n}{n}对象：{name}{n}{n}还原之后，这一项会回到修复之前的样子。'

        'col.sym'     = ''
        'col.name'    = '设备 / 磁盘 / 卷'
        'col.layer'   = '层'
        'col.bus'     = '接口'
        'col.state'   = '状态'

        'lbl.hwid'    = '硬件 ID（找驱动、报修时直接复制给对面）'
        'btn.copyid'  = '复制硬件 ID'
        'btn.copied'  = '已复制'
        'btn.scan'    = '全面体检'
        'btn.rescan'  = '重新识别'
        'btn.report'  = '导出报告'
        'btn.history' = '历史设备'
        'btn.ok'      = '知道了'
        'btn.elevate' = '以管理员重开'

        'st.ready'    = '就绪'
        'st.scanning' = '读取中…'
        'st.done'     = '体检完成'
        'st.noadmin'  = '只读模式（非管理员）'
        'st.copyok'   = '硬件 ID 已复制到剪贴板'
        'st.reportok' = '报告已保存'
        'st.reportfail' = '报告保存失败'

        'foot.admin'  = '管理员权限：已具备（可以「重新识别」和导出完整报告）'
        'foot.user'   = '管理员权限：没有（只读体检照常可用；「重新识别」需要管理员）'

        'd.elevate.t' = '需要管理员权限'
        'd.elevate.m' = '「重新识别设备」等价于在设备管理器里点「扫描检测硬件改动」，这个动作需要管理员权限。' + "`r`n`r`n" +
                        '要现在以管理员身份重新打开吗？（体检和导出报告不需要）'
        'd.rescan.t'  = '确认重新识别'
        'd.rescan.m'  = '这一步等于在设备管理器里点一下「扫描检测硬件改动」：' + "`r`n`r`n" +
                        '  · 只让 Windows 重新找一遍设备，不改任何设置、不卸载任何东西' + "`r`n" +
                        '  · 已经能用的设备不会掉' + "`r`n" +
                        '  · 有些设备重新识别时会闪一下（比如 U 盘灯），属于正常' + "`r`n`r`n" +
                        '继续吗？'
        'd.hist.t'    = '历史设备'
        'd.hist.m'    = '这里列出的是「以前在这台电脑上插过、现在没插」的设备记录。它们不影响使用，也不占资源。当前的版本只列出来看，不做清理。'

        'log.scan.start' = '开始体检：枚举设备、磁盘、卷、盘符'
        'log.scan.done'  = '体检完成，用时 {ms} 毫秒'
        'log.rescan.start' = '请求重新扫描硬件改动'
        'log.rescan.done'  = '重新识别完成（{how}）'
        'log.rescan.fail'  = '重新识别失败（{how}）'
        'log.report'     = '报告已写入：{p}'
    }
    'en' = @{
        'app.title'   = 'DeviceLens'
        'app.sub'     = 'USB drives, memory cards, portable disks, serial cards - anything plugged into this PC. See which layer is broken before you touch anything.'
        'app.author'  = '© Lanlan Eternal'

        'menu.tools'  = '&Tools'
        'menu.help'   = '&How to use'
        'menu.disc'   = '&Disclaimer'
        'menu.about'  = '&About'

        'hdr.help'    = 'How to use'
        'hdr.disc'    = 'Disclaimer'
        'hdr.about'   = 'About'

        'menu.scan'   = 'Full check'
        'menu.rescan' = 'Rescan devices'
        'menu.letters'= 'Drive letter map (A-Z)'
        'menu.report' = 'Export report'
        'menu.folder' = 'Open report folder'
        'menu.undo'   = 'Undo the last repair'
        'menu.fixlog' = 'Open the repair log'
        'menu.quit'   = 'Exit'

        'hint.welcome'= 'Step 1: plug in the device that misbehaves and keep it plugged in.  Step 2: press "Full check" at the bottom right.'
        'hint.scanning'= 'Reading device information, a few seconds...'
        'hint.ok'     = 'OK - {n} devices, {d} disks checked, no obvious problem'
        'hint.warn'   = 'Found {n} item(s) that need attention - click one on the left, the right side explains it'
        'hint.bad'    = 'Found {n} item(s) with real problems - click one on the left, the right side explains it'
        'hint.noadm'  = 'Not running as administrator: viewing and exporting work; "Rescan" needs admin'
        'hint.rescan.ok'  = 'OK - hardware rescan finished. Devices you just plugged in should appear now'
        'hint.rescan.fail'= 'Rescan did not complete: administrator rights are required, or a security tool blocked it'

        'st.switching' = 'Re-evaluating in the new language...'
        'st.hwscan'    = 'Reading hardware (CPU / memory / GPU / board / thermal)...'
        'list.count'  = '{n} items · {w} flagged'
        'list.count.ok' = '{n} items'
        'filt.hw'     = 'Hardware'
        'filt.key'    = 'Key items'
        'filt.all'    = 'All devices'
        'filt.bad'    = 'Problems only'

        'pane.title'  = 'What is actually going on here'
        'pane.empty'  = 'Click an item on the left. This panel answers three questions: what the problem is, whether it can be fixed, and what to do right now.'
        'seg.1'       = '(1) What the problem is'
        'seg.2'       = '(2) Whether it can be fixed'
        'seg.3'       = '(3) What to do right now'
        'seg.ev'      = 'Evidence'

        'btn.fix'     = 'Fix this (reversible)'
        'btn.fixnone' = 'Nothing to fix here'
        'btn.fixno'   = 'Software cannot fix this'
        'fix.confirm.t' = 'Confirm repair'
        'fix.confirm.m' = 'About to do: {act}{n}{n}Target: {name}{n}{n}The previous state is written to a log first, so you can undo it any time from Tools > Undo the last repair.{n}{n}Continue?'
        'fix.act.assign' = 'Assign a drive letter to this partition (no data touched)'
        'fix.act.enable' = 'Enable this device (same as "Enable device" in Device Manager)'
        'fix.undoable'  = 'undoable from Tools > Undo the last repair'
        'fix.done'      = 'Repair finished'
        'fix.fail'      = 'Repair did not succeed'
        'fix.noadm'     = 'Repairing writes system settings, so it needs administrator rights. Restart elevated now?'
        'st.fixing'     = 'Repairing...'
        'undo.none'     = 'The undo log has no repair record yet, so there is nothing to undo.'
        'undo.confirm.m' = 'Restore the previous state of the last repair?{n}{n}Target: {name}{n}{n}After that, the item goes back to how it was before the repair.'

        'col.sym'     = ''
        'col.name'    = 'Device / disk / volume'
        'col.layer'   = 'Layer'
        'col.bus'     = 'Bus'
        'col.state'   = 'State'

        'lbl.hwid'    = 'Hardware ID (copy this when asking for a driver or a repair)'
        'btn.copyid'  = 'Copy hardware ID'
        'btn.copied'  = 'Copied'
        'btn.scan'    = 'Full check'
        'btn.rescan'  = 'Rescan'
        'btn.report'  = 'Export report'
        'btn.history' = 'Device history'
        'btn.ok'      = 'Got it'
        'btn.elevate' = 'Restart as admin'

        'st.ready'    = 'Ready'
        'st.scanning' = 'Reading...'
        'st.done'     = 'Check finished'
        'st.noadmin'  = 'Read-only (not admin)'
        'st.copyok'   = 'Hardware ID copied'
        'st.reportok' = 'Report saved'
        'st.reportfail' = 'Could not save the report'

        'foot.admin'  = 'Administrator: yes (rescan and full report available)'
        'foot.user'   = 'Administrator: no (read-only checks work; "Rescan" needs admin)'

        'd.elevate.t' = 'Administrator rights required'
        'd.elevate.m' = '"Rescan devices" is the same as pressing "Scan for hardware changes" in Device Manager, which needs administrator rights.' + "`r`n`r`n" +
                        'Restart the program as administrator now? (Viewing and exporting do not need it)'
        'd.rescan.t'  = 'Confirm rescan'
        'd.rescan.m'  = 'This does the same thing as "Scan for hardware changes" in Device Manager:' + "`r`n`r`n" +
                        '  - Windows looks for devices again; no setting is changed, nothing is uninstalled' + "`r`n" +
                        '  - Devices that already work will not drop out' + "`r`n" +
                        '  - Some devices blink briefly during a rescan (an LED, for example) - normal' + "`r`n`r`n" +
                        'Continue?'
        'd.hist.t'    = 'Device history'
        'd.hist.m'    = 'These are devices that were used on this PC before and are not plugged in now. They do not affect anything and take no resources. This version only lists them; nothing is cleaned.'

        'log.scan.start' = 'Scan started: devices, disks, volumes, drive letters'
        'log.scan.done'  = 'Scan finished in {ms} ms'
        'log.rescan.start' = 'Hardware rescan requested'
        'log.rescan.done'  = 'Rescan finished ({how})'
        'log.rescan.fail'  = 'Rescan failed ({how})'
        'log.report'     = 'Report written to: {p}'
    }
}

function T([string]$k) {
    $t = $script:TXT[$script:LANG]
    if ($null -ne $t -and $t.ContainsKey($k)) { return [string]$t[$k] }
    return $k
}
function Fmt([string]$k, $map) {
    $s = T $k
    foreach ($p in $map.Keys) { $s = $s.Replace('{' + $p + '}', [string]$map[$p]) }
    # {n} 是换行占位符。以前漏了这一步，确认框里会原样弹出「{n}{n}」。
    $s = $s.Replace('{n}', "`r`n")
    return $s
}

# =====================================================================
#  状态
# =====================================================================
$script:Col       = $null      # 体检结果
$script:Filter    = 'key'      # key / all / bad
$script:Busy      = $false
$script:AdminOk   = (DL-IsAdmin)
$script:LastReport = ''
$script:HelpOpen  = $false

# =====================================================================
#  窗体
# =====================================================================
$form = New-Object System.Windows.Forms.Form
$form.ClientSize = New-Object System.Drawing.Size(1100, 676)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C_BG
$form.ForeColor = $C_TEXT
$form.MinimumSize = New-Object System.Drawing.Size(1000, 640)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
# Dpi 模式：125% / 150% 缩放下按钮不会挤到一起
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.KeyPreview = $true

# ---------- 菜单栏 ----------
$menu = New-Object System.Windows.Forms.MenuStrip
$menu.BackColor = [System.Drawing.Color]::FromArgb(232, 232, 232)
$menu.ForeColor = $C_TEXT
$menu.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$menu.RenderMode = 'System'
$form.MainMenuStrip = $menu

$mTools = New-Object System.Windows.Forms.ToolStripMenuItem
$mHelp  = New-Object System.Windows.Forms.ToolStripMenuItem
$mDisc  = New-Object System.Windows.Forms.ToolStripMenuItem
$mAbout = New-Object System.Windows.Forms.ToolStripMenuItem

$mScan   = New-Object System.Windows.Forms.ToolStripMenuItem
$mRescan = New-Object System.Windows.Forms.ToolStripMenuItem
$mLetters= New-Object System.Windows.Forms.ToolStripMenuItem
$mReport = New-Object System.Windows.Forms.ToolStripMenuItem
$mFolder = New-Object System.Windows.Forms.ToolStripMenuItem
$mUndo   = New-Object System.Windows.Forms.ToolStripMenuItem
$mFixLog = New-Object System.Windows.Forms.ToolStripMenuItem
$mQuit   = New-Object System.Windows.Forms.ToolStripMenuItem
[void]$mTools.DropDownItems.AddRange(@($mScan, $mRescan, $mUndo, $mFixLog, $mReport, $mLetters, $mFolder))
[void]$mTools.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$mTools.DropDownItems.Add($mQuit)

[void]$menu.Items.AddRange(@($mTools, $mHelp, $mDisc, $mAbout))

# 语言切换：右侧两个分段按键。不放进下拉菜单 ——
# 英文用户不必认识「语言」两个字，看见 English 就能点；当前语言加粗加蓝。
$mZh = New-Object System.Windows.Forms.ToolStripButton
$mEn = New-Object System.Windows.Forms.ToolStripButton
foreach ($lb in @($mZh, $mEn)) {
    $lb.DisplayStyle = 'Text'
    $lb.CheckOnClick = $false
    $lb.AutoToolTip = $false
    $lb.ToolTipText = 'Language / 语言'
    $lb.Alignment = [System.Windows.Forms.ToolStripItemAlignment]::Right
    $lb.Padding = New-Object System.Windows.Forms.Padding(8, 0, 8, 0)
    $lb.Margin = New-Object System.Windows.Forms.Padding(0)
}
$mZh.Text = '中文'
$mEn.Text = 'English'
# Right 对齐是从右往左排，所以先加 English 才显示成「中文 | English」
[void]$menu.Items.Add($mEn)
[void]$menu.Items.Add($mZh)
$form.Controls.Add($menu)

# ---------- 标题 ----------
$lbTitle = New-Object System.Windows.Forms.Label
$lbTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 17, [System.Drawing.FontStyle]::Bold)
$lbTitle.ForeColor = $C_TEXT
$lbTitle.Location = New-Object System.Drawing.Point(24, 34)
$lbTitle.Size = New-Object System.Drawing.Size(440, 36)
$lbTitle.UseMnemonic = $false
$form.Controls.Add($lbTitle)

$lbVer = New-Object System.Windows.Forms.Label
$lbVer.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$lbVer.ForeColor = $C_SUB
$lbVer.Location = New-Object System.Drawing.Point(24, 68)
$lbVer.Size = New-Object System.Drawing.Size(66, 18)
$lbVer.Text = 'v' + $script:DL_VER
$lbVer.UseMnemonic = $false
$form.Controls.Add($lbVer)

$lbAuthor = New-Object System.Windows.Forms.Label
$lbAuthor.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$lbAuthor.ForeColor = $C_SUB
$lbAuthor.Location = New-Object System.Drawing.Point(700, 44)
$lbAuthor.Size = New-Object System.Drawing.Size(376, 20)
$lbAuthor.TextAlign = 'MiddleRight'
$lbAuthor.Anchor = 'Top,Right'
$lbAuthor.UseMnemonic = $false
$form.Controls.Add($lbAuthor)

$lbSub = New-Object System.Windows.Forms.Label
$lbSub.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$lbSub.ForeColor = $C_SUB
$lbSub.Location = New-Object System.Drawing.Point(96, 68)
$lbSub.Size = New-Object System.Drawing.Size(980, 18)
$lbSub.Anchor = 'Top,Left,Right'
$lbSub.UseMnemonic = $false
$form.Controls.Add($lbSub)

# ---------- 提示条 ----------
$lbHint = New-Object System.Windows.Forms.Label
$lbHint.Location = New-Object System.Drawing.Point(24, 96)
$lbHint.Size = New-Object System.Drawing.Size(1052, 34)
$lbHint.TextAlign = 'MiddleLeft'
# Label 默认 UseMnemonic=true，会把「&」当助记符吃掉（英文 "Diagnose & Fix" 变成 "Diagnose  Fix"）
$lbHint.UseMnemonic = $false
$lbHint.BorderStyle = 'FixedSingle'
$lbHint.Padding = New-Object System.Windows.Forms.Padding(12, 0, 8, 0)
$lbHint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)
$lbHint.BackColor = $C_HINT_BG
$lbHint.ForeColor = $C_HINT_FG
$lbHint.Anchor = 'Top,Left,Right'
$form.Controls.Add($lbHint)

# ---------- 左侧：筛选 ----------
$lbListTitle = New-Object System.Windows.Forms.Label
$lbListTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$lbListTitle.ForeColor = $C_TEXT
$lbListTitle.Location = New-Object System.Drawing.Point(24, 140)
$lbListTitle.Size = New-Object System.Drawing.Size(164, 20)
$lbListTitle.UseMnemonic = $false
$form.Controls.Add($lbListTitle)

function New-FiltBtn($x, $w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Location = New-Object System.Drawing.Point($x, 136)
    $b.Size = New-Object System.Drawing.Size($w, 26)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.BackColor = [System.Drawing.Color]::FromArgb(226, 226, 226)
    $b.ForeColor = $C_TEXT
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
    $b.Cursor = 'Hand'
    $b.Anchor = 'Top,Left'
    return $b
}
# ★ 起点必须留出统计文字的位置：lbListTitle 从 x=28 起、宽 164，到 192 结束。
#   原来按钮从 186 开始，压住它 6px —— 表现就是「重点」按钮左边框缺一截。
$btnFKey = New-FiltBtn 200 78
$btnFAll = New-FiltBtn 284 96
$btnFBad = New-FiltBtn 386 100
$btnFHw = New-FiltBtn 492 100
$form.Controls.AddRange(@($btnFKey, $btnFAll, $btnFBad, $btnFHw))

# ---------- 左侧：设备列表 ----------
# OwnerDraw = false 时没法逐行上色，所以用 ForeColor 整行染色，
# 首列用一个符号做色标（✓ ! ✕ ·），色弱的人也能分辨。
$lv = New-Object System.Windows.Forms.ListView
$lv.Location = New-Object System.Drawing.Point(24, 168)
$lv.Size = New-Object System.Drawing.Size(612, 400)
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.MultiSelect = $false
$lv.HideSelection = $false
$lv.ShowItemToolTips = $true
$lv.GridLines = $false
$lv.BorderStyle = 'FixedSingle'
$lv.BackColor = [System.Drawing.Color]::White
$lv.ForeColor = $C_TEXT
$lv.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$lv.Anchor = 'Top,Bottom,Left,Right'
[void]$lv.Columns.Add('', 32)
[void]$lv.Columns.Add('', 266)
[void]$lv.Columns.Add('', 44)
[void]$lv.Columns.Add('', 54)
[void]$lv.Columns.Add('', 182)
$form.Controls.Add($lv)

# 列表底部一行小字：解释「层」是什么，不占地方但很关键
$lbLayerTip = New-Object System.Windows.Forms.Label
$lbLayerTip.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 7.5)
$lbLayerTip.ForeColor = $C_SUB
$lbLayerTip.Location = New-Object System.Drawing.Point(24, 572)
$lbLayerTip.Size = New-Object System.Drawing.Size(612, 32)
$lbLayerTip.UseMnemonic = $false
$lbLayerTip.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($lbLayerTip)

# ---------- 右侧：结论面板 ----------
$pnl = New-Object System.Windows.Forms.Panel
$pnl.Location = New-Object System.Drawing.Point(652, 136)
$pnl.Size = New-Object System.Drawing.Size(424, 468)
$pnl.BackColor = $C_PANEL
$pnl.BorderStyle = 'FixedSingle'
$pnl.Anchor = 'Top,Bottom,Right'
$form.Controls.Add($pnl)

$lbPaneTitle = New-Object System.Windows.Forms.Label
$lbPaneTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)
$lbPaneTitle.ForeColor = $C_TEXT
$lbPaneTitle.Location = New-Object System.Drawing.Point(12, 8)
$lbPaneTitle.Size = New-Object System.Drawing.Size(398, 20)
$lbPaneTitle.UseMnemonic = $false
$pnl.Controls.Add($lbPaneTitle)

$rt = New-Object System.Windows.Forms.RichTextBox
$rt.Location = New-Object System.Drawing.Point(12, 32)
$rt.Size = New-Object System.Drawing.Size(398, 330)
$rt.ReadOnly = $true
$rt.BorderStyle = 'None'
$rt.BackColor = $C_PANEL
$rt.ForeColor = $C_TEXT
$rt.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$rt.ScrollBars = 'Vertical'
$rt.Anchor = 'Top,Bottom,Left,Right'
# 只读 RichTextBox 有个毛病：光标进去会变成插入符、还能拖选全选。
# 关掉 TabStop，并在获得焦点时把光标移走即可。
$rt.TabStop = $false
$pnl.Controls.Add($rt)

$lbHw = New-Object System.Windows.Forms.Label
$lbHw.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$lbHw.ForeColor = $C_SUB
$lbHw.Location = New-Object System.Drawing.Point(12, 366)
$lbHw.Size = New-Object System.Drawing.Size(398, 16)
$lbHw.UseMnemonic = $false
$lbHw.Anchor = 'Bottom,Left,Right'
$pnl.Controls.Add($lbHw)

$tbHw = New-Object System.Windows.Forms.TextBox
$tbHw.Location = New-Object System.Drawing.Point(12, 382)
$tbHw.Size = New-Object System.Drawing.Size(398, 38)
$tbHw.Multiline = $true
$tbHw.ReadOnly = $true
$tbHw.ScrollBars = 'Vertical'
$tbHw.WordWrap = $true
$tbHw.BorderStyle = 'FixedSingle'
$tbHw.BackColor = [System.Drawing.Color]::White
$tbHw.ForeColor = $C_TEXT
$tbHw.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$tbHw.Anchor = 'Bottom,Left,Right'
$pnl.Controls.Add($tbHw)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Location = New-Object System.Drawing.Point(12, 426)
$btnCopy.Size = New-Object System.Drawing.Size(140, 28)
$btnCopy.FlatStyle = 'Flat'
$btnCopy.FlatAppearance.BorderSize = 0
$btnCopy.BackColor = $C_GRAY
$btnCopy.ForeColor = [System.Drawing.Color]::White
$btnCopy.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$btnCopy.Cursor = 'Hand'
$btnCopy.Anchor = 'Bottom,Left'
$btnCopy.Enabled = $false
$pnl.Controls.Add($btnCopy)

# 「修复这一项」。一直显示，但只有真的能修时才可点 ——
# 灰掉的时候会把原因写在按钮上（不需要修 / 软件修不了），
# 这样既回答了「为什么不修」，也不会让人以为功能被藏起来。
$btnFix = New-Object System.Windows.Forms.Button
$btnFix.Location = New-Object System.Drawing.Point(158, 426)
$btnFix.Size = New-Object System.Drawing.Size(252, 28)
$btnFix.FlatStyle = 'Flat'
$btnFix.FlatAppearance.BorderSize = 0
$btnFix.BackColor = $C_GRAY
$btnFix.ForeColor = [System.Drawing.Color]::White
$btnFix.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$btnFix.Cursor = 'Hand'
$btnFix.Anchor = 'Bottom,Left,Right'
$btnFix.Enabled = $false
$pnl.Controls.Add($btnFix)

# ---------- 底部按钮 ----------
function New-Btn($x, $w, $color) {
    $b = New-Object System.Windows.Forms.Button
    $b.Location = New-Object System.Drawing.Point($x, 610)
    $b.Size = New-Object System.Drawing.Size($w, 42)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $color
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $b.Cursor = 'Hand'
    $b.Anchor = 'Bottom,Left'
    return $b
}
$btnScan    = New-Btn 24 190 $C_GREEN
$btnRescan  = New-Btn 222 130 $C_BLUE
$btnReport  = New-Btn 360 130 $C_GRAY
$btnHistory = New-Btn 498 120 $C_GRAY
$form.Controls.AddRange(@($btnScan, $btnRescan, $btnReport, $btnHistory))

$lbStatus = New-Object System.Windows.Forms.Label
$lbStatus.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$lbStatus.ForeColor = $C_SUB
$lbStatus.Location = New-Object System.Drawing.Point(630, 621)
$lbStatus.Size = New-Object System.Drawing.Size(446, 20)
$lbStatus.AutoSize = $false
$lbStatus.TextAlign = 'MiddleRight'
$lbStatus.Anchor = 'Bottom,Right'
$lbStatus.UseMnemonic = $false
$form.Controls.Add($lbStatus)

$lbFoot = New-Object System.Windows.Forms.Label
$lbFoot.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$lbFoot.Location = New-Object System.Drawing.Point(26, 654)
$lbFoot.Size = New-Object System.Drawing.Size(1050, 18)
$lbFoot.Anchor = 'Bottom,Left,Right'
$lbFoot.UseMnemonic = $false
$form.Controls.Add($lbFoot)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object System.Drawing.Point(24, 650)
$bar.Size = New-Object System.Drawing.Size(1052, 2)
$bar.Style = 'Continuous'
$bar.Minimum = 0
$bar.Maximum = 100
$bar.Value = 0
$bar.Anchor = 'Bottom,Left,Right'
$bar.Visible = $false
$form.Controls.Add($bar)

# =====================================================================
#  小工具
# =====================================================================
function Set-Status([string]$s) {
    $lbStatus.Text = $s
    try { [System.Windows.Forms.Application]::DoEvents() } catch { }
}
function Set-Busy([bool]$b) {
    $script:Busy = $b
    $en = -not $b
    $btnScan.Enabled = $en
    $btnRescan.Enabled = $en
    $btnReport.Enabled = $en
    $btnHistory.Enabled = $en
    $btnFKey.Enabled = $en
    $btnFAll.Enabled = $en
    $btnFBad.Enabled = $en
    $btnCopy.Enabled = ($en -and $tbHw.Text -ne '')
    $bar.Visible = $b
    try { [System.Windows.Forms.Application]::DoEvents() } catch { }
}
function Set-Hint([string]$text, [string]$kind) {
    $lbHint.Text = $text
    switch ($kind) {
        'ok'    { $lbHint.BackColor = $C_OK_BG;   $lbHint.ForeColor = $C_OK_FG }
        'bad'   { $lbHint.BackColor = $C_BAD_BG;  $lbHint.ForeColor = $C_BAD_FG }
        default { $lbHint.BackColor = $C_HINT_BG; $lbHint.ForeColor = $C_HINT_FG }
    }
}
# 顶部提示条统一从「这一次的结果」重算。
# ★ 必须做成函数：切换语言时如果只换界面文字，这条横幅会一直留着旧语言，
#   表现就是「英文界面里顶上一行中文」—— v0.2.0 就是这样。
function Update-HintFromCol {
    if ($null -eq $script:Col) { return }
    $n = $script:Col.Stats.Devices
    $d = $script:Col.Stats.Disks
    if ($script:Col.Verdict -eq 'OK') {
        Set-Hint (Fmt 'hint.ok' @{ n = $n; d = $d }) 'ok'
    } elseif ($script:Col.Verdict -eq 'WARN') {
        Set-Hint (Fmt 'hint.warn' @{ n = $script:Col.Stats.Warn }) 'info'
    } else {
        Set-Hint (Fmt 'hint.bad' @{ n = $script:Col.Stats.Bad }) 'bad'
    }
}

function StatusColor([string]$s) {
    switch ($s) {
        'OK'   { return $C_GREEN }
        'WARN' { return $C_ROW_WARN }
        'BAD'  { return $C_ROW_BAD }
        default{ return $C_SUB }
    }
}
function StatusSym([string]$s) {
    switch ($s) {
        'OK'   { return [char]0x2713 }
        'WARN' { return '!' }
        'BAD'  { return [char]0x2715 }
        default{ return [char]0x00B7 }
    }
}

# =====================================================================
#  硬件读数：按需采集
#
#  CPU / 内存 / 显卡 / 主板 / 温度 / 风扇 这一组比设备枚举慢约 3 秒，
#  放进每次体检会拖慢启动，所以只在用户点「硬件」或导出报告时才采。
# =====================================================================
$script:Hw = @()
$script:HwLang = ''

function Ensure-Hw {
    if ($script:HwLang -eq $script:LANG -and $script:Hw.Count -gt 0) { return $true }
    Set-Status (T 'st.hwscan')
    Set-Busy $true
    $ok = $true
    try {
        $script:Hw = @(DL-CollectHw)
        $script:HwLang = $script:LANG
    } catch {
        $script:Hw = @()
        $ok = $false
    } finally {
        Set-Busy $false
    }
    if ($null -ne $script:Col) { $script:Col.Hw = $script:Hw }
    if ($ok) { Set-Status (T 'st.done') }
    return $ok
}

# =====================================================================
#  填充列表
# =====================================================================
function Get-AllItems {
    if ($null -eq $script:Col) { return @() }
    $out = New-Object System.Collections.ArrayList

    # 硬件视图：只放硬件读数，不和几百个设备混在一起
    if ($script:Filter -eq 'hw') {
        foreach ($x in $script:Hw) { [void]$out.Add($x) }
        return $out.ToArray()
    }

    foreach ($x in $script:Col.Disks) { [void]$out.Add($x) }
    foreach ($x in $script:Col.Volumes) {
        # EFI / MSR 这类系统保留分区只放进「全部设备」，
        # 别在「重点」里占位 —— 它们本来就是正常的。
        if ($script:Filter -eq 'key' -and $null -ne $x.Extra -and $x.Extra.ContainsKey('Reserved')) { continue }
        [void]$out.Add($x)
    }
    foreach ($x in $script:Col.Devices) {
        # 「重点」视图只放：磁盘、卷、以及真的报了错的设备。
        # 正常的系统设备（卷影服务、IDE 控制器之类）不进这个视图 ——
        # 它们一多就把真正要看的那几条淹掉了。
        if ($script:Filter -eq 'key' -and $x.Status -eq 'OK') { continue }
        [void]$out.Add($x)
    }
    return $out.ToArray()
}

# 列表上方那行：改成一个真有用的统计（原来这里和表头文字一模一样，纯属浪费）
function Update-ListTitle {
    if ($null -eq $script:Col) { $lbListTitle.Text = ''; return }
    if ($null -eq $lv) { return }
    $n = $lv.Items.Count
    $w = 0
    foreach ($r in $lv.Items) {
        # INFO（比如「这台机器不提供温度」）不算「要注意」，否则提示条永远在报警
        if ($null -ne $r.Tag -and ($r.Tag.Status -eq 'WARN' -or $r.Tag.Status -eq 'BAD')) { $w++ }
    }
    if ($w -gt 0) { $lbListTitle.Text = (Fmt 'list.count' @{ n = $n; w = $w }) }
    else { $lbListTitle.Text = (Fmt 'list.count.ok' @{ n = $n }) }
}

function Fill-List {
    $lv.BeginUpdate()
    try {
        $lv.Items.Clear()
        if ($null -eq $script:Col) { return }
        $rows = Get-AllItems
        foreach ($it in $rows) {
            if ($script:Filter -eq 'bad' -and $it.Status -eq 'OK') { continue }
            $sym = [string](StatusSym $it.Status)
            $row = New-Object System.Windows.Forms.ListViewItem($sym)
            [void]$row.SubItems.Add([string]$it.Name)
            [void]$row.SubItems.Add([string]$it.Level)
            [void]$row.SubItems.Add([string]$it.Bus)
            [void]$row.SubItems.Add([string]$it.StateText)
            $row.ForeColor = StatusColor $it.Status
            $row.Tag = $it
            [void]$lv.Items.Add($row)
        }
    } finally {
        $lv.EndUpdate()
        Update-ListTitle
    }
}

# =====================================================================
#  右侧结论面板
# =====================================================================
# 富文本渲染：先整体写 Text（这一步最可靠），再逐段 Select + 上色加粗。
# 不用 AppendText 逐段推进 —— 在只读控件上偶尔会出现「文字进去了但不显示」，
# 而先赋 Text 再上色，永远不会出现空面板。
function Set-RichText($blocks) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $blocks) { [void]$sb.Append([string]$b.text) }
    $rt.Text = $sb.ToString()

    $pos = 0
    foreach ($b in $blocks) {
        $t = [string]$b.text
        $len = $t.Length
        if ($len -gt 0) {
            $sz = 9.5
            if ($b.ContainsKey('size')) { $sz = [float]$b.size }
            if ($b.ContainsKey('mono') -and $b.mono) {
                $f = New-Object System.Drawing.Font('Consolas', $sz)
            } elseif ($b.ContainsKey('bold') -and $b.bold) {
                $f = New-Object System.Drawing.Font('Microsoft YaHei UI', $sz, [System.Drawing.FontStyle]::Bold)
            } else {
                $f = New-Object System.Drawing.Font('Microsoft YaHei UI', $sz)
            }
            try {
                $rt.Select($pos, $len)
                $rt.SelectionFont = $f
                $rt.SelectionColor = $b.color
            } catch { }
        }
        $pos += $len
    }
    try {
        $rt.Select(0, 0)
        $rt.SelectionStart = 0
    } catch { }
}


function Show-Conclusion($it) {
    if ($null -eq $it) {
        Set-RichText @(
            @{ text = (T 'pane.empty'); color = $C_SUB; size = 9.5 }
        )
        $tbHw.Text = ''
        $btnCopy.Enabled = $false
        $lbHw.Visible = $true
        $tbHw.Visible = $true
        $btnCopy.Visible = $true
        $btnFix.Visible = $true
        $btnFix.Enabled = $false
        $btnFix.BackColor = $C_GRAY
        $btnFix.Text = (T 'btn.fixnone')
        return
    }

    $blocks = New-Object System.Collections.ArrayList
    [void]$blocks.Add(@{ text = ([string]$it.Name + "`r`n"); color = (StatusColor $it.Status); bold = $true; size = 10.5 })
    # 副标题用 Cls（已经是人话），内部的 Kind 是英文枚举值，不该露给用户看
    $kindTx = [string]$it.Cls
    if ($kindTx -eq '') { $kindTx = [string]$it.Kind }
    # 分类和接口同名时（CPU / CPU）不重复写两遍
    $subTx = '[' + $kindTx + '] '
    if ([string]$it.Bus -ne '' -and [string]$it.Bus -ne $kindTx) { $subTx = $subTx + [string]$it.Bus + '  ' }
    [void]$blocks.Add(@{ text = (($subTx + $it.StateText) + "`r`n"); color = $C_SUB; size = 8.5 })

    $seg = @(
        @{ k = 'seg.1'; v = $it.Why },
        @{ k = 'seg.2'; v = $it.Fix },
        @{ k = 'seg.3'; v = $it.Advice }
    )
    foreach ($s in $seg) {
        [void]$blocks.Add(@{ text = ((T $s.k) + "`r`n"); color = $C_BLUE; bold = $true; size = 8.5 })
        [void]$blocks.Add(@{ text = ([string]$s.v + "`r`n"); color = $C_TEXT; size = 8.5 })
    }

    # 没有证据就不写「证据」这个空标题 —— 空标题会让人以为内容丢了
    if (@($it.Evidence).Count -gt 0) {
        [void]$blocks.Add(@{ text = ((T 'seg.ev') + "`r`n"); color = $C_SUB; bold = $true; size = 8.5 })
        foreach ($e in $it.Evidence) {
            [void]$blocks.Add(@{ text = ('  ' + [string]$e + "`r`n"); color = $C_SUB; mono = $true; size = 8.5 })
        }
    }
    Set-RichText ($blocks.ToArray())

    # 硬件读数没有「硬件 ID」这回事（那是给驱动用的），整块收起来，别占地方
    if ($it.Kind -eq 'HW') {
        $lbHw.Visible = $false
        $tbHw.Visible = $false
        $btnCopy.Visible = $false
        $btnFix.Visible = $false
        $tbHw.Text = ''
        return
    }
    $btnFix.Visible = $true
    $lbHw.Visible = $true
    $tbHw.Visible = $true
    $btnCopy.Visible = $true
    $hw = @($it.HwIds)
    if ($hw.Count -gt 0) {
        $tbHw.Text = ($hw -join "`r`n")
        $btnCopy.Enabled = $true
    } else {
        $tbHw.Text = [string]$it.InstanceId
        $btnCopy.Enabled = ($tbHw.Text -ne '')
    }

    # 能不能修，直接写在按钮上
    if ([string]$it.FixAction -ne '') {
        $btnFix.Enabled = $true
        $btnFix.BackColor = $C_GREEN
        $btnFix.Text = (T 'btn.fix')
    } else {
        $btnFix.Enabled = $false
        $btnFix.BackColor = $C_GRAY
        if ($it.Status -eq 'OK' -or $it.Status -eq 'INFO') { $btnFix.Text = (T 'btn.fixnone') }
        else { $btnFix.Text = (T 'btn.fixno') }
    }
}

# =====================================================================
#  应用语言
# =====================================================================
function Apply-Lang {
    DL-SetLang $script:LANG
    $script:LANG = DL-Lang

    $form.Text    = (T 'app.title') + '  v' + $script:DL_VER
    $lbTitle.Text = T 'app.title'
    $lbSub.Text   = T 'app.sub'
    $lbAuthor.Text= T 'app.author'

    $mTools.Text = T 'menu.tools'
    $mHelp.Text  = T 'menu.help'
    $mDisc.Text  = T 'menu.disc'
    $mAbout.Text = T 'menu.about'
    $mScan.Text  = T 'menu.scan'
    $mRescan.Text= T 'menu.rescan'
    $mLetters.Text = T 'menu.letters'
    $mReport.Text= T 'menu.report'
    $mUndo.Text  = T 'menu.undo'
    $mFixLog.Text= T 'menu.fixlog'
    $mFolder.Text= T 'menu.folder'
    $mQuit.Text  = T 'menu.quit'

    $btnScan.Text    = T 'btn.scan'
    $btnRescan.Text  = T 'btn.rescan'
    $btnReport.Text  = T 'btn.report'
    $btnHistory.Text = T 'btn.history'
    $btnCopy.Text    = T 'btn.copyid'
    $btnFKey.Text    = T 'filt.key'
    $btnFAll.Text    = T 'filt.all'
    $btnFBad.Text    = T 'filt.bad'
    $btnFHw.Text     = T 'filt.hw'
    Update-ListTitle
    $lbPaneTitle.Text= T 'pane.title'
    $lbHw.Text       = T 'lbl.hwid'

    $lv.Columns[0].Text = T 'col.sym'
    $lv.Columns[1].Text = T 'col.name'
    $lv.Columns[2].Text = T 'col.layer'
    $lv.Columns[3].Text = T 'col.bus'
    $lv.Columns[4].Text = T 'col.state'

    $lbFoot.Text = $(if ($script:AdminOk) { T 'foot.admin' } else { T 'foot.user' })
    $lbFoot.ForeColor = $(if ($script:AdminOk) { $C_GREEN } else { $C_SUB })

    $lbLayerTip.Text = $(if ($script:LANG -eq 'en') {
        'Layer: E2 enumerate · E3 no driver · E4 load · E5 device · L1 letter · L2 partition · L3 filesystem · HW reading'
    } else {
        '层 ＝ 在哪一层：E2 枚举 / E3 缺驱动 / E4 驱动装不上 / E5 设备本身 / L1 盘符 / L2 分区表 / L3 文件系统 / HW 硬件读数'
    })

    # 语言按键：当前语言加粗变蓝
    $mZh.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, $(if ($script:LANG -eq 'zh') { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
    $mEn.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, $(if ($script:LANG -eq 'en') { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
    $mZh.ForeColor = $(if ($script:LANG -eq 'zh') { $C_BLUE } else { $C_TEXT })
    $mEn.ForeColor = $(if ($script:LANG -eq 'en') { $C_BLUE } else { $C_TEXT })

    Update-HintFromCol
    if ($script:Busy) { Set-Status (T 'st.scanning') }
    else {
        if ($null -eq $script:Col) { Set-Status (T 'st.ready') }
        else { Set-Status (T 'st.done') }
    }

    # 重新渲染当前选中项（文案要跟着语言走）
    if ($lv.SelectedItems.Count -gt 0) { Show-Conclusion $lv.SelectedItems[0].Tag }
    elseif ($null -eq $script:Col) { Show-Conclusion $null }
}

# 切换语言。
# ★ 必须连引擎一起重算：所有判定文案是 DL-Collect 在「收集那一刻」
#   按当时语言生成的。只换界面文字，就会出现「英文界面夹着中文结论」
#   —— 这正是 v0.1.0 的问题（右侧写明「分区无盘符」，左边列表却仍是中文）。
function Switch-Lang([string]$l) {
    if ($script:LANG -eq $l) { return }
    $script:LANG = $l
    Save-LangPref $l
    DL-SetLang $l
    if ($null -ne $script:Col) {
        Set-Status (T 'st.switching')
        Set-Busy $true
        try { $script:Col = DL-Collect } catch { }
        Set-Busy $false
    }
    Apply-Lang
    Update-HintFromCol
    if ($script:Filter -eq 'hw') { Ensure-Hw | Out-Null }
    Fill-List
    if ($lv.Items.Count -gt 0) {
        $pick = 0
        for ($i = 0; $i -lt $lv.Items.Count; $i++) {
            $t = $lv.Items[$i].Tag
            if ($null -ne $t -and $t.Status -ne 'OK') { $pick = $i; break }
        }
        $lv.Items[$pick].Selected = $true
        $lv.EnsureVisible($pick)
        Show-Conclusion $lv.Items[$pick].Tag
    }
}

# =====================================================================
#  长文本：使用说明 / 免责 / 关于
# =====================================================================
function Get-HelpLines {
    $en = ($script:LANG -eq 'en')
    $L = New-Object System.Collections.ArrayList
    if ($en) {
        [void]$L.Add('DeviceLens  v' + $script:DL_VER + '   -   How to use')
        [void]$L.Add('================================================')
        [void]$L.Add('')
        [void]$L.Add('WHAT IT DOES')
        [void]$L.Add('  It reads what Windows knows about the devices on this PC and tells you,')
        [void]$L.Add('  in plain language, which layer of the chain is broken and whether it')
        [void]$L.Add('  can be fixed. Scanning only reads. Two repairs can actually be carried')
        [void]$L.Add('  out in the app, and both are reversible.')
        [void]$L.Add('')
        [void]$L.Add('WHAT IT CAN REPAIR (and what it will not)')
        [void]$L.Add('  It repairs two things, nothing else:')
        [void]$L.Add('     - assign a drive letter to a data partition that lost it')
        [void]$L.Add('     - re-enable a device that got disabled')
        [void]$L.Add('  Select the row, then click the green "Fix this item" button on the right.')
        [void]$L.Add('  Before touching anything it writes the previous state to an undo log,')
        [void]$L.Add('  so Menu - Undo last fix always puts it back.')
        [void]$L.Add('  It does NOT: format, repartition, recover data, flash firmware, or')
        [void]$L.Add('  install drivers from download sites. Those need your decision, not a')
        [void]$L.Add('  button - the report tells you who should do it and how.')
        [void]$L.Add('')
        [void]$L.Add('HOW TO USE IT (4 steps)')
        [void]$L.Add('  1. Plug in the device that misbehaves. Keep it plugged in.')
        [void]$L.Add('     Nothing about a missing device can be diagnosed while it is not there.')
        [void]$L.Add('  2. Press "Full check" (the green button). It takes a few seconds.')
        [void]$L.Add('  3. Click any row on the left. The right panel explains three things:')
        [void]$L.Add('       (1) what the problem is  (2) whether it can be fixed')
        [void]$L.Add('       (3) what to do right now')
        [void]$L.Add('  4. If you need help, press "Export report" and send the whole file.')
        [void]$L.Add('')
        [void]$L.Add('THE FOUR VIEWS')
        [void]$L.Add('  Key items   - disks, volumes and anything with a problem. Start here.')
        [void]$L.Add('  All devices - every device Windows reports, including healthy ones.')
        [void]$L.Add('  Problems    - only the rows with a warning or an error.')
        [void]$L.Add('  Hardware    - CPU, memory, GPU, board, BIOS, disk health, thermal, fan.')
        [void]$L.Add('                This page is about the machine itself, not a broken disk.')
        [void]$L.Add('                It reads extra data, so it runs when you open it.')
        [void]$L.Add('')
        [void]$L.Add('WHAT "LAYER" MEANS - this is the core idea')
        [void]$L.Add('  Every device sits on one chain. The first broken link tells you what')
        [void]$L.Add('  to do, and what NOT to do:')
        [void]$L.Add('    E2  enumeration  - Windows does not see the device at all')
        [void]$L.Add('    E3  matching     - device seen, no driver matches (code 28)')
        [void]$L.Add('    E4  loading      - driver installed but will not start (10/12/31/52)')
        [void]$L.Add('    E5  function     - driver is fine, so the device itself is suspect')
        [void]$L.Add('    L1  volume       - partition is fine, drive letter missing')
        [void]$L.Add('    L2  partition    - no partition table, Windows says "initialise disk"')
        [void]$L.Add('    L3  filesystem   - partition exists, filesystem unreadable (RAW)')
        [void]$L.Add('    L4  healthy')
        [void]$L.Add('    HW  hardware reading - measured values, not a device fault')
        [void]$L.Add('')
        [void]$L.Add('  The practical value: if the chain breaks at E2 or L1, software can')
        [void]$L.Add('  usually fix it with zero risk. If it breaks at E5, no amount of')
        [void]$L.Add('  driver reinstalling will help - stop and look at cable, port, power.')
        [void]$L.Add('')
        [void]$L.Add('"RESCAN" EXPLAINED')
        [void]$L.Add('  It is exactly "Scan for hardware changes" in Device Manager. It only')
        [void]$L.Add('  asks Windows to look for devices again. No setting is changed and')
        [void]$L.Add('  nothing is uninstalled. It needs administrator rights.')
        [void]$L.Add('  Try this first when a device was working a minute ago and vanished.')
        [void]$L.Add('')
        [void]$L.Add('DRIVE LETTER MAP (Tools menu)')
        [void]$L.Add('  Shows which letters are taken and by what. That answers "why is D')
        [void]$L.Add('  not available" without opening Disk Management.')
        [void]$L.Add('')
        [void]$L.Add('WHAT IT WILL NEVER DO, EVEN NOW')
        [void]$L.Add('  Even with the repair button, it will never format a disk, create or')
        [void]$L.Add('  delete partitions, recover data, flash firmware, or install a driver')
        [void]$L.Add('  downloaded from a download site.')
        [void]$L.Add('  Those are the four ways to turn a small problem into a total loss.')
        [void]$L.Add('')
        [void]$L.Add('ABOUT TEMPERATURE AND FAN SPEED')
        [void]$L.Add('  Many desktop boards do not expose sensors through ACPI, so the query')
        [void]$L.Add('  returns nothing. The tool then says "not provided" instead of making')
        [void]$L.Add('  up a number. For real readings use the BIOS Hardware Monitor page.')
        [void]$L.Add('')
        [void]$L.Add('LANGUAGES')
        [void]$L.Add('  Click  中文  or  English  at the top right. The choice is remembered.')
    } else {
        [void]$L.Add('设备诊断修复  v' + $script:DL_VER + '   ——   使用说明')
        [void]$L.Add('================================================')
        [void]$L.Add('')
        [void]$L.Add('它做什么')
        [void]$L.Add('  读出 Windows 对这台电脑上各个设备的认知，用人话说清「这条链断在哪一层、')
        [void]$L.Add('  能不能修」。体检这一步只读不写；软件里真正能动手修的只有两种，')
        [void]$L.Add('  而且两种都能撤销。')
        [void]$L.Add('')
        [void]$L.Add('它能修什么（以及它不会碰什么）')
        [void]$L.Add('  只修两件事，别的都不碰：')
        [void]$L.Add('     · 给丢了盘符的数据分区重新分配一个盘符')
        [void]$L.Add('     · 把被人禁用掉的设备重新启用')
        [void]$L.Add('  做法：在左边点中那一行，点右边绿色的「修复这一项」。')
        [void]$L.Add('  动手之前，它先把「改之前是什么样」写进留底文件，')
        [void]$L.Add('  所以菜单里的「撤销上一次修复」永远能原样放回去。')
        [void]$L.Add('  它不做：格式化、重新分区、恢复数据、刷固件、装下载站的驱动。')
        [void]$L.Add('  这几件事得你自己判断，报告会告诉你该找谁、怎么找。')
        [void]$L.Add('')
        [void]$L.Add('怎么用（四步）')
        [void]$L.Add('  1. 把出问题的那台设备插上，并保持插着。')
        [void]$L.Add('     设备不在场，关于它的任何判断都是空的。')
        [void]$L.Add('  2. 点「全面体检」（绿色那个按钮），几秒钟。')
        [void]$L.Add('  3. 在左边点任意一行，右边会说清三件事：')
        [void]$L.Add('       ① 它是什么问题　② 能不能修　③ 现在最该做什么')
        [void]$L.Add('  4. 需要求助时，点「导出报告」，把整个文件发出去就行。')
        [void]$L.Add('')
        [void]$L.Add('四个视图')
        [void]$L.Add('  重点　　—— 磁盘、卷、以及所有有问题的条目。先看这个。')
        [void]$L.Add('  全部设备 —— Windows 报上来的每一台设备，包括正常的。')
        [void]$L.Add('  只看问题 —— 只留有警告或有错误的行。')
        [void]$L.Add('  硬件　　—— CPU、内存、显卡、主板、BIOS、盘健康、温度、风扇。')
        [void]$L.Add('             这一页看的是「机器本身」，不是「哪块盘坏了」。')
        [void]$L.Add('             要多读一批数据，所以点开才算。')
        [void]$L.Add('')
        [void]$L.Add('「层」是什么意思（这是本工具的核心）')
        [void]$L.Add('  每个设备都挂在同一条链上，第一个断掉的环节决定你该做什么、不该做什么：')
        [void]$L.Add('    E2 枚举　—— Windows 完全看不到这台设备')
        [void]$L.Add('    E3 匹配　—— 设备看到了，但没有匹配的驱动（代码 28）')
        [void]$L.Add('    E4 加载　—— 驱动装上了，但启动不了（10 / 12 / 31 / 52）')
        [void]$L.Add('    E5 功能　—— 驱动正常，那就该怀疑设备本身了')
        [void]$L.Add('    L1 卷　　—— 分区是好的，只是没有盘符')
        [void]$L.Add('    L2 分区表 —— 没有分区，系统会让你「初始化磁盘」')
        [void]$L.Add('    L3 文件系统 —— 分区在，但读不出文件系统（RAW）')
        [void]$L.Add('    L4 正常')
        [void]$L.Add('    HW 硬件读数 —— 实测值，不代表设备故障')
        [void]$L.Add('')
        [void]$L.Add('  实用价值在这里：断在 E2 或 L1，软件通常零风险就能修好；')
        [void]$L.Add('  断在 E5，你再怎么重装驱动也没用 —— 该去看线、口、供电了。')
        [void]$L.Add('')
        [void]$L.Add('「重新识别」是什么')
        [void]$L.Add('  等同于设备管理器里点一下「扫描检测硬件改动」：只让 Windows 重新找一遍')
        [void]$L.Add('  设备，不改任何设置、不卸载任何东西。需要管理员权限。')
        [void]$L.Add('  设备刚才还好好的、忽然不见了，先试这个。')
        [void]$L.Add('')
        [void]$L.Add('盘符占用看板（工具菜单里）')
        [void]$L.Add('  一眼看出每个字母被谁占了。回答「为什么 D 盘用不了」，')
        [void]$L.Add('  不用去翻磁盘管理。')
        [void]$L.Add('')
        [void]$L.Add('关于温度和风扇转速')
        [void]$L.Add('  很多台式机主板不通过 ACPI 暴露传感器，取回来是空的。')
        [void]$L.Add('  这时候工具会写「这台机器不提供」，不会编一个数字。')
        [void]$L.Add('  要看真实温度，进 BIOS 的 Hardware Monitor 页最准。')
        [void]$L.Add('')
        [void]$L.Add('它永远不会做的事（有了修复键也一样）')
        [void]$L.Add('  格式化磁盘、新建或删除分区、恢复数据、刷固件、')
        [void]$L.Add('  装从下载站抓来的驱动。')
        [void]$L.Add('  这五件事，是把「小毛病」变成「全没了」的五条路。')
        [void]$L.Add('')
        [void]$L.Add('语言')
        [void]$L.Add('  点右上角「中文」或「English」。选过就会被记住。')
    }
    return $L.ToArray()
}

function Get-DiscLines {
    $en = ($script:LANG -eq 'en')
    $L = New-Object System.Collections.ArrayList
    if ($en) {
        [void]$L.Add('Disclaimer   -   ' + $script:DL_NAME_EN + '  v' + $script:DL_VER)
        [void]$L.Add('================================================')
        [void]$L.Add('')
        [void]$L.Add('1. This program is provided AS IS, without warranty of any kind.')
        [void]$L.Add('   You use it at your own risk.')
        [void]$L.Add('')
        [void]$L.Add('2. WHAT IT DOES NOT DO. It does not format, partition, initialise,')
        [void]$L.Add('   recover data or flash firmware.')
        [void]$L.Add('   Scanning is read-only. Two repairs can be carried out, and ONLY')
        [void]$L.Add('   when you press the button yourself:')
        [void]$L.Add('     - assign a drive letter to a data partition that lost one')
        [void]$L.Add('     - re-enable a device that has been disabled')
        [void]$L.Add('   Both are recorded in an undo log before they run, and Menu -')
        [void]$L.Add('   Undo last fix restores the previous state. Nothing else on this')
        [void]$L.Add('   PC is modified.')
        [void]$L.Add('')
        [void]$L.Add('3. DATA IS YOUR RESPONSIBILITY. If a disk holds data you cannot')
        [void]$L.Add('   lose, stop using it and go to professional data recovery FIRST.')
        [void]$L.Add('   Never let anyone "fix" a disk that contains the only copy.')
        [void]$L.Add('')
        [void]$L.Add('4. THE JUDGEMENT IS AN OPINION, NOT A VERDICT. This tool infers')
        [void]$L.Add('   from what Windows reports. A conclusion such as "the device is')
        [void]$L.Add('   faulty" is a probability, not proof. Physical inspection by a')
        [void]$L.Add('   qualified person always overrides it.')
        [void]$L.Add('')
        [void]$L.Add('5. NO LIABILITY. The author is not liable for data loss, hardware')
        [void]$L.Add('   damage, lost profit or any other consequence of using this')
        [void]$L.Add('   program, to the maximum extent permitted by law.')
        [void]$L.Add('')
        [void]$L.Add('6. NO NETWORK ACCESS. The program does not connect anywhere, does')
        [void]$L.Add('   not upload anything and does not collect telemetry. Reports are')
        [void]$L.Add('   written locally, to your Desktop, only when you ask for them.')
        [void]$L.Add('')
        [void]$L.Add('7. THIRD-PARTY NAMES. Windows, Device Manager and diskpart are')
        [void]$L.Add('   trademarks of Microsoft. This project is not affiliated with')
        [void]$L.Add('   Microsoft or with any hardware vendor.')
    } else {
        [void]$L.Add('免责声明   ——   ' + $script:DL_NAME_ZH + '  v' + $script:DL_VER)
        [void]$L.Add('================================================')
        [void]$L.Add('')
        [void]$L.Add('一、本程序按「现状」提供，不附带任何明示或暗示的担保。使用风险自负。')
        [void]$L.Add('')
        [void]$L.Add('二、它不做什么。不格式化、不分区、不初始化磁盘、不恢复数据、不刷固件。')
        [void]$L.Add('    体检全程只读。真正会动系统设置的只有两种动作，')
        [void]$L.Add('    而且必须由你亲手点「修复这一项」才会执行：')
        [void]$L.Add('      · 给丢了盘符的数据分区分配一个盘符')
        [void]$L.Add('      · 把被禁用的设备重新启用')
        [void]$L.Add('    执行之前会先把「改之前是什么样」写进留底文件，')
        [void]$L.Add('    菜单「撤销上一次修复」可以原样放回去。除此之外不改这台电脑的任何东西。')
        [void]$L.Add('')
        [void]$L.Add('三、数据是你自己的责任。如果一块盘里存着不能丢的东西，')
        [void]$L.Add('    请先停手、先做专业数据恢复，再谈修盘。')
        [void]$L.Add('    只有一份的资料，不要交给任何人去「修」。')
        [void]$L.Add('')
        [void]$L.Add('四、判断是意见，不是判决。本工具只能依据 Windows 报上来的信息做推断，')
        [void]$L.Add('    「这台设备疑似故障」是一个概率，不是结论。')
        [void]$L.Add('    专业人员上手检查的结果，永远优先于本工具。')
        [void]$L.Add('')
        [void]$L.Add('五、不承担责任。因使用本程序造成的数据丢失、硬件损坏、利润损失')
        [void]$L.Add('    或其他任何后果，作者不承担责任（法律允许的最大范围内）。')
        [void]$L.Add('')
        [void]$L.Add('六、不联网。本程序不连接任何服务器、不上传任何内容、不收集任何信息。')
        [void]$L.Add('    报告只在你点「导出报告」时写在本机桌面上。')
        [void]$L.Add('')
        [void]$L.Add('七、第三方名称。Windows、设备管理器、diskpart 是微软的商标。')
        [void]$L.Add('    本项目与微软及任何硬件厂商都没有隶属关系。')
    }
    return $L.ToArray()
}

function Get-AboutLines {
    $en = ($script:LANG -eq 'en')
    $L = New-Object System.Collections.ArrayList
    if ($en) {
        [void]$L.Add('')
        [void]$L.Add('        ' + $script:DL_NAME_EN + '    v' + $script:DL_VER)
        [void]$L.Add('        ' + $script:DL_NAME_ZH)
        [void]$L.Add('')
        [void]$L.Add('        ' + $script:DL_AUTHOR)
        [void]$L.Add('')
        [void]$L.Add('------------------------------------------------')
        [void]$L.Add('  See which layer is broken before you touch')
        [void]$L.Add('  anything. Read-only by default.')
        [void]$L.Add('------------------------------------------------')
        [void]$L.Add('')
        [void]$L.Add('  Version      : ' + $script:DL_VER)
        [void]$L.Add('  Engine       : dl-core.ps1 (same file as the UI uses)')
        [void]$L.Add('  Interface    : ' + $(if ($script:LANG -eq 'en') { 'English' } else { '中文' }))
        [void]$L.Add('  Windows      : ' + [Environment]::OSVersion.VersionString)
        [void]$L.Add('  Bitness      : ' + $(if ([Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }))
        [void]$L.Add('  PowerShell   : ' + $PSVersionTable.PSVersion.ToString())
        [void]$L.Add('  Administrator: ' + $(if ($script:AdminOk) { 'yes' } else { 'no (read-only)' }))
        [void]$L.Add('')
        [void]$L.Add('  Companion tool: "USB / Serial Port Fix" - it handles COM port')
        [void]$L.Add('  numbers and devices Windows refuses to detect. The two are')
        [void]$L.Add('  separate programs and must live in separate folders.')
        [void]$L.Add('')
        [void]$L.Add('  Free to use. No installer, no service, no telemetry.')
        [void]$L.Add('')
        [void]$L.Add('  ' + $script:DL_AUTHOR)
    } else {
        [void]$L.Add('')
        [void]$L.Add('        ' + $script:DL_NAME_ZH + '    v' + $script:DL_VER)
        [void]$L.Add('        ' + $script:DL_NAME_EN)
        [void]$L.Add('')
        [void]$L.Add('        ' + $script:DL_AUTHOR)
        [void]$L.Add('')
        [void]$L.Add('------------------------------------------------')
        [void]$L.Add('  先看清断在哪一层，再决定动不动手。')
        [void]$L.Add('  默认纯只读，不改任何设置。')
        [void]$L.Add('------------------------------------------------')
        [void]$L.Add('')
        [void]$L.Add('  版本       : ' + $script:DL_VER)
        [void]$L.Add('  核心引擎   : dl-core.ps1（和界面用的是同一份）')
        [void]$L.Add('  界面语言   : ' + $(if ($script:LANG -eq 'en') { 'English' } else { '中文' }))
        [void]$L.Add('  系统       : ' + [Environment]::OSVersion.VersionString)
        [void]$L.Add('  位数       : ' + $(if ([Environment]::Is64BitOperatingSystem) { '64 位' } else { '32 位' }))
        [void]$L.Add('  PowerShell : ' + $PSVersionTable.PSVersion.ToString())
        [void]$L.Add('  管理员权限 : ' + $(if ($script:AdminOk) { '已具备' } else { '没有（只读模式）' }))
        [void]$L.Add('')
        [void]$L.Add('  姊妹工具：「USB / 串口 一键修复」—— 管 COM 端口号，')
        [void]$L.Add('  以及 Windows 死活认不出的设备。两款是彼此独立的程序，')
        [void]$L.Add('  必须放在各自的文件夹里，不能混装。')
        [void]$L.Add('')
        [void]$L.Add('  免费使用。不装服务、不写系统、不联网。')
        [void]$L.Add('')
        [void]$L.Add('  ' + $script:DL_AUTHOR)
    }
    return $L.ToArray()
}

# 通用长文本窗口：标题 + 可滚动文本 + 一个按钮
function Show-TextDialog([string]$title, [string[]]$lines) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $title
    $d.ClientSize = New-Object System.Drawing.Size(700, 560)
    $d.StartPosition = 'CenterParent'
    $d.BackColor = $C_BG
    $d.MinimizeBox = $false
    $d.MaximizeBox = $false
    $d.FormBorderStyle = 'FixedSingle'
    $d.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.ScrollBars = 'Vertical'
    $tb.WordWrap = $true
    $tb.BackColor = $C_PANEL
    $tb.ForeColor = $C_TEXT
    $tb.BorderStyle = 'FixedSingle'
    $tb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $tb.Location = New-Object System.Drawing.Point(14, 14)
    $tb.Size = New-Object System.Drawing.Size(672, 480)
    $tb.Text = ($lines -join "`r`n")
    $tb.SelectionStart = 0
    $tb.SelectionLength = 0
    $tb.TabStop = $false
    $d.Controls.Add($tb)

    $b = New-Object System.Windows.Forms.Button
    $b.Text = T 'btn.ok'
    $b.Location = New-Object System.Drawing.Point(302, 508)
    $b.Size = New-Object System.Drawing.Size(96, 34)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $C_BLUE
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $b.DialogResult = 'OK'
    $d.Controls.Add($b)
    $d.AcceptButton = $b

    # 焦点别落在文本框上，否则多行 TextBox 会全文刷蓝，看着像被选中
    $d.Add_Shown({
        try { $tb.SelectionStart = 0; $tb.SelectionLength = 0; $d.ActiveControl = $b } catch { }
        if ($script:ShotDlgPath -ne '') {
            try {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 500
                $w = $d.Width
                $h = $d.Height
                $bmp = New-Object System.Drawing.Bitmap($w, $h)
                $d.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)))
                $bmp.Save($script:ShotDlgPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
                $d.Close()
            } catch { }
        }
    })
    [void]$d.ShowDialog($form)
    $d.Dispose()
}
$script:ShotDlgPath = $ShotDlg

# =====================================================================
#  体检
# =====================================================================
function Invoke-Scan {
    if ($script:Busy) { return }
    Set-Busy $true
    Set-Status (T 'st.scanning')
    Set-Hint (T 'hint.scanning') 'info'
    DL-Log (T 'log.scan.start')
    try {
        $script:Col = DL-Collect
        Fill-List
        Update-HintFromCol
        DL-Log (Fmt 'log.scan.done' @{ ms = $script:Col.Stats.Ms })

        # 自动选中第一条有问题的，省得用户自己找
        if ($lv.Items.Count -gt 0) {
            $pick = 0
            for ($i = 0; $i -lt $lv.Items.Count; $i++) {
                $t = $lv.Items[$i].Tag
                if ($null -ne $t -and $t.Status -ne 'OK') { $pick = $i; break }
            }
            $lv.Items[$pick].Selected = $true
            $lv.EnsureVisible($pick)
            Show-Conclusion $lv.Items[$pick].Tag
        } else {
            Show-Conclusion $null
        }
        Set-Status (T 'st.done')
    } catch {
        Set-Hint ([string]$_.Exception.Message) 'bad'
        Set-Status (T 'st.ready')
    } finally {
        Set-Busy $false
    }
}

# =====================================================================
#  重新识别（L0）
# =====================================================================
function Invoke-Rescan {
    if ($script:Busy) { return }
    if (-not $script:AdminOk) {
        $r = [System.Windows.Forms.MessageBox]::Show((T 'd.elevate.m'), (T 'd.elevate.t'), 'YesNo', 'Warning')
        if ($r -eq 'Yes') { Restart-Elevated }
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show((T 'd.rescan.m'), (T 'd.rescan.t'), 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }

    Set-Busy $true
    Set-Status (T 'st.scanning')
    DL-Log (T 'log.rescan.start')
    try {
        $ok = DL-Rescan
        $how = [string]$script:DL_LAST_HOW
        if ($ok) {
            Set-Hint (T 'hint.rescan.ok') 'ok'
            DL-Log (Fmt 'log.rescan.done' @{ how = $how })
        } else {
            Set-Hint (T 'hint.rescan.fail') 'bad'
            DL-Log (Fmt 'log.rescan.fail' @{ how = $how })
        }
    } catch {
        Set-Hint (T 'hint.rescan.fail') 'bad'
    } finally {
        Set-Busy $false
    }
    Start-Sleep -Milliseconds 1200
    Invoke-Scan
}

function Get-SelfLaunch {
    # 同一个界面文件有两种活法：
    #   · 双击 bat  → 宿主进程是 powershell.exe，重启要走 powershell -File 脚本
    #   · 双击 exe  → 宿主进程就是本程序，重启必须回到 exe 自己
    #                  （ps2exe 跑脚本时用的是临时解压目录，再去跑那个脚本
    #                    等于绕开 exe，用户看到的现象是「又开了一个，但没提权」）
    $proc = ''
    try { $proc = [string][System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
    $langArg = ''
    if ($script:LANG -ne '') { $langArg = ' -Lang ' + $script:LANG }

    if ($proc -ne '' -and $proc -notmatch '(?i)powershell') {
        return @{ File = $proc; Args = $langArg.Trim() }
    }
    return @{
        File = 'powershell.exe'
        Args = ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"' + $langArg)
    }
}

function Restart-Elevated {
    try {
        $sl = Get-SelfLaunch
        Start-Process -FilePath $sl.File -ArgumentList $sl.Args -Verb RunAs -ErrorAction Stop | Out-Null
        $form.Close()
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "没能以管理员身份重新打开（可能在 UAC 窗口里点了「否」）。`r`n`r`n请关掉本程序，然后右键这个程序文件，选「以管理员身份运行」。",
            'DeviceLens', 'OK', 'Warning') | Out-Null
    }
}

# =====================================================================
#  导出报告
# =====================================================================
function Invoke-Report {
    if ($null -eq $script:Col) {
        Invoke-Scan
        if ($null -eq $script:Col) { return }
    }
    # 报告里要有硬件那一节，所以导出前确保硬件读过（已读过就直接用缓存）
    if ($script:Hw.Count -eq 0) { Ensure-Hw | Out-Null }
    if ($script:Hw.Count -gt 0) { $script:Col.Hw = $script:Hw }
    $name = $(if ($script:LANG -eq 'en') { 'Device-Report.txt' } else { '设备诊断报告.txt' })
    $p = Join-Path (DL-DeskPath) $name
    $ok = DL-BuildReport $script:Col $p
    if ($ok) {
        $script:LastReport = $p
        Set-Status (T 'st.reportok')
        DL-Log (Fmt 'log.report' @{ p = $p })
        [System.Windows.Forms.MessageBox]::Show(
            $(if ($script:LANG -eq 'en') { 'Report saved to your Desktop:' + "`r`n" + $p } else { '报告已保存到桌面：' + "`r`n" + $p }),
            (T 'btn.report'), 'OK', 'Information') | Out-Null
    } else {
        Set-Status (T 'st.reportfail')
        [System.Windows.Forms.MessageBox]::Show(
            $(if ($script:LANG -eq 'en') { 'Could not write the report. Try another location.' } else { '报告没能写入，可能桌面被重定向或没有写入权限。' }),
            (T 'btn.report'), 'OK', 'Warning') | Out-Null
    }
}

# =====================================================================
#  修复：只做能还原的动作
# =====================================================================
function Invoke-FixSelected {
    $it = $null
    if ($lv.SelectedItems.Count -gt 0) { $it = $lv.SelectedItems[0].Tag }
    if ($null -eq $it) { return }
    $act = [string]$it.FixAction
    if ($act -eq '') { return }

    if (-not $script:AdminOk) {
        $r = [System.Windows.Forms.MessageBox]::Show((T 'fix.noadm'), (T 'btn.fix'), 'YesNo', 'Warning')
        if ($r -eq 'Yes') { Restart-Elevated }
        return
    }

    $actTx = $(if ($act -eq 'assign') { T 'fix.act.assign' } else { T 'fix.act.enable' })
    $msg = (Fmt 'fix.confirm.m' @{ act = $actTx; name = [string]$it.Name })
    $r = [System.Windows.Forms.MessageBox]::Show($msg, (T 'fix.confirm.t'), 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }

    Set-Busy $true
    Set-Status (T 'st.fixing')
    $res = $null
    try {
        if ($act -eq 'assign') { $res = DL-AssignLetter ([string]$it.FixTarget) }
        else { $res = DL-EnableDevice ([string]$it.FixTarget) }
    } catch {
        $res = @{ Ok = $false; Msg = [string]$_.Exception.Message; Detail = ''; Undo = '' }
    }
    Set-Busy $false

    # 留底：不管成功失败都记一条，失败也要留痕迹
    DL-FixLogAdd @{
        time   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        action = $act
        target = [string]$it.FixTarget
        name   = [string]$it.Name
        ok     = $res.Ok
        msg    = [string]$res.Msg
        detail = [string]$res.Detail
        undo   = [string]$res.Undo
        undone = $false
    } | Out-Null

    if ($res.Ok) {
        # 先记下要显示的结论：Invoke-Scan 内部会把提示条刷成体检结论，
        # 所以扫完必须再写一次，否则「已分配 M:」一闪就被冲掉。
        $okHint = ('✓ ' + $res.Msg + '  ' + (T 'fix.undoable'))
        Invoke-Scan
        Set-Hint $okHint 'ok'
        Set-Status (T 'fix.done')
    } else {
        Set-Hint ('✕ ' + (T 'fix.fail') + ' - ' + $res.Msg) 'bad'
        [System.Windows.Forms.MessageBox]::Show(((T 'fix.fail') + "`r`n`r`n" + $res.Msg), (T 'btn.fix'), 'OK', 'Warning') | Out-Null
    }
}

# =====================================================================
#  盘符占用看板
# =====================================================================
function Show-LetterBoard {
    $L = New-Object System.Collections.ArrayList
    $en = ($script:LANG -eq 'en')
    [void]$L.Add($(if ($en) { 'Drive letter map - who holds which letter' } else { '盘符占用看板 —— 哪个字母被谁占了' }))
    [void]$L.Add('================================================')
    [void]$L.Add('')
    $map = @{}
    if ($null -ne $script:Col) { $map = $script:Col.Letters }
    foreach ($c in [char[]]'CDEFGHIJKLMNOPQRSTUVWXYZAB') {
        $k = [string]$c
        if ($map.ContainsKey($k)) {
            [void]$L.Add(('  ' + $k + ':   ' + $(if ($en) { 'USED' } else { '已占用' }) + '    ' + $map[$k].By + '   [' + $map[$k].Kind + ']'))
        } else {
            [void]$L.Add(('  ' + $k + ':   ' + $(if ($en) { 'free' } else { '空闲' })))
        }
    }
    [void]$L.Add('')
    [void]$L.Add($(if ($en) {
        'Notes:'
        '  A: and B: are listed last - they are reserved for floppy drives.'
        '  "Held by a stale record" means an old mapping is still registered'
        '  but no volume is behind it. It is why a letter can look taken'
        '  while nothing uses it. Cleaning those needs your confirmation and'
        '  is not done here. Workaround: pick a letter that is truly free.'
    } else {
        '说明：'
        '  A: 和 B: 排在最后 —— 它们留给软驱，Windows 不会自动分配。'
        '  「被旧记录占用」表示注册表里还挂着一个盘符映射，但后面已经没有卷了。'
        '  这就是「字母明明空着却用不了」的原因。清理它要动注册表，'
        '  本工具不擅自做；换一个真正空闲的字母即可。'
    }))
    Show-TextDialog (T 'menu.letters') $L.ToArray()
}

# =====================================================================
#  历史设备
# =====================================================================
function Show-History {
    if ($null -eq $script:Col) {
        Invoke-Scan
        if ($null -eq $script:Col) { return }
    }
    $en = ($script:LANG -eq 'en')
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add((T 'd.hist.m'))
    [void]$L.Add('')
    [void]$L.Add('------------------------------------------------')
    [void]$L.Add(('  ' + $script:Col.History.Count + $(if ($en) { ' record(s)' } else { ' 条记录' })))
    [void]$L.Add('------------------------------------------------')
    foreach ($h in $script:Col.History) {
        [void]$L.Add('  · ' + $h.Name + '   [' + $h.Bus + ']')
        if ($h.InstanceId -ne '') { [void]$L.Add('      ' + $h.InstanceId) }
    }
    Show-TextDialog (T 'btn.history') $L.ToArray()
}

# =====================================================================
#  事件绑定
# =====================================================================
$btnScan.Add_Click({ Invoke-Scan })
$btnRescan.Add_Click({ Invoke-Rescan })
$btnReport.Add_Click({ Invoke-Report })
$btnHistory.Add_Click({ Show-History })
$mScan.Add_Click({ Invoke-Scan })
$mRescan.Add_Click({ Invoke-Rescan })
$mReport.Add_Click({ Invoke-Report })
$mLetters.Add_Click({ Show-LetterBoard })
$mFolder.Add_Click({
    $p = $script:LastReport
    if ($p -eq '' -or -not (Test-Path $p)) { $p = DL-DeskPath }
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $p + '"') } catch {
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList $p } catch { }
    }
})
$mQuit.Add_Click({ $form.Close() })
$mHelp.Add_Click({ Show-TextDialog (T 'hdr.help') (Get-HelpLines) })
$mDisc.Add_Click({ Show-TextDialog (T 'hdr.disc') (Get-DiscLines) })
$mAbout.Add_Click({ Show-TextDialog (T 'hdr.about') (Get-AboutLines) })

$mZh.Add_Click({ Switch-Lang 'zh' })
$mEn.Add_Click({ Switch-Lang 'en' })

$btnFKey.Add_Click({ $script:Filter = 'key'; Fill-List; if ($lv.Items.Count -gt 0) { $lv.Items[0].Selected = $true; Show-Conclusion $lv.Items[0].Tag } })
$btnFHw.Add_Click({
    $script:Filter = 'hw'
    Ensure-Hw | Out-Null
    Fill-List
    if ($lv.Items.Count -gt 0) {
        $lv.Items[0].Selected = $true
        $lv.EnsureVisible(0)
        Show-Conclusion $lv.Items[0].Tag
    } else {
        Show-Conclusion $null
    }
    Set-Status (T 'st.done')
})
$btnFAll.Add_Click({ $script:Filter = 'all'; Fill-List; if ($lv.Items.Count -gt 0) { $lv.Items[0].Selected = $true; Show-Conclusion $lv.Items[0].Tag } })
$btnFBad.Add_Click({ $script:Filter = 'bad'; Fill-List; if ($lv.Items.Count -gt 0) { $lv.Items[0].Selected = $true; Show-Conclusion $lv.Items[0].Tag } })

$lv.Add_SelectedIndexChanged({
    if ($lv.SelectedItems.Count -gt 0) { Show-Conclusion $lv.SelectedItems[0].Tag }
})

$btnFix.Add_Click({ Invoke-FixSelected })

$mUndo.Add_Click({
    $last = DL-FixLast
    if ($null -eq $last) {
        [System.Windows.Forms.MessageBox]::Show((T 'undo.none'), (T 'menu.undo'), 'OK', 'Information') | Out-Null
        return
    }
    $msg = (Fmt 'undo.confirm.m' @{ name = [string]$last.name })
    $r0 = [System.Windows.Forms.MessageBox]::Show($msg, (T 'menu.undo'), 'YesNo', 'Question')
    if ($r0 -ne 'Yes') { return }
    if (-not $script:AdminOk) {
        $r1 = [System.Windows.Forms.MessageBox]::Show((T 'fix.noadm'), (T 'menu.undo'), 'YesNo', 'Warning')
        if ($r1 -eq 'Yes') { Restart-Elevated }
        return
    }
    $r = DL-UndoLast
    if ($r.Ok) {
        $okHint = ('✓ ' + $r.Msg)
        Invoke-Scan
        Set-Hint $okHint 'ok'
        Set-Status (T 'st.done')
    } else {
        [System.Windows.Forms.MessageBox]::Show($r.Msg, (T 'menu.undo'), 'OK', 'Information') | Out-Null
    }
})
$mFixLog.Add_Click({
    try {
        $d = DL-FixDir
        if (Test-Path (DL-FixLogPath)) { [System.Diagnostics.Process]::Start('notepad.exe', ('"' + (DL-FixLogPath) + '"')) | Out-Null }
        else { [System.Diagnostics.Process]::Start('explorer.exe', $d) | Out-Null }
    } catch { }
})

$btnCopy.Add_Click({
    if ($tbHw.Text -eq '') { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText($tbHw.Text)
        $old = $btnCopy.Text
        $btnCopy.Text = T 'btn.copied'
        Set-Status (T 'st.copyok')
        $t = New-Object System.Windows.Forms.Timer
        $t.Interval = 1500
        $t.Add_Tick({ $btnCopy.Text = T 'btn.copyid'; $this.Stop(); $this.Dispose() })
        $t.Start()
    } catch { }
})

# F5 体检、F9 重新识别：给习惯键盘的人
$form.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) { Invoke-Scan; $e.Handled = $true }
    elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::F9) { Invoke-Rescan; $e.Handled = $true }
})

$form.Add_Shown({
    Apply-Lang
    Hide-ConsoleWindow
    if (-not $script:AdminOk) { Set-Hint (T 'hint.noadm') 'info' }
    else { Set-Hint (T 'hint.welcome') 'info' }

    if ($AutoScan -or $script:AutoScanOnOpen) {
        Invoke-Scan
    }

    # 自测：只拍一个对话框（使用说明），用来检查长文本窗口的排版
    if ($ShotDlg -ne '') {
        Show-TextDialog (T 'hdr.help') (Get-HelpLines)
        $form.Close()
        return
    }

    if ($Shot -ne '') {
        # ★ 不能用 DrawToBitmap 截图：RichTextBox 是原生 RichEdit 控件，
        #   DrawToBitmap 拍出来永远是空白（WinForms 的已知缺陷，不是界面 bug）。
        #   这里临时置顶，直接从屏幕上抓，所见即所得。
        try {
            # 自测：先切一次语言，专门验证「切语言后引擎有没有重算」——
            # 只换界面文字的话，英文界面里会夹着中文结论。
            if ($SwitchTo -ne '') { Switch-Lang $SwitchTo }
            if ($ShotHw) {
                $script:Filter = 'hw'
                Ensure-Hw | Out-Null
                Fill-List
                if ($lv.Items.Count -gt 0) { $lv.Items[0].Selected = $true; Show-Conclusion $lv.Items[0].Tag }
            }
            # 自测：挑一条「可修」的条目选中，验证右下角修复按钮是不是绿的、字对不对
            if ($ShotFix) {
                $script:Filter = 'all'
                Fill-List
                $found = -1
                for ($i = 0; $i -lt $lv.Items.Count; $i++) {
                    $tg = $lv.Items[$i].Tag
                    if ($null -ne $tg -and [string]$tg.FixAction -ne '') { $found = $i; break }
                }
                if ($found -ge 0) {
                    $lv.Items[$found].Selected = $true
                    $lv.EnsureVisible($found)
                    Show-Conclusion $lv.Items[$found].Tag
                } elseif ($lv.Items.Count -gt 0) {
                    # 本机没有可修项（很正常：没有丢盘符的分区、没有禁用的设备）。
                    # 为了能验证绿色按钮的排版，借第 0 行点一下灯。
                    # ★ FixTarget 故意留空：就算手滑点下去，引擎会立刻回
                    #   「没有指定分区」，不可能写盘。这只在 -ShotFix 自测里发生。
                    $lv.Items[0].Selected = $true
                    $demo = $lv.Items[0].Tag
                    if ($null -ne $demo) {
                        $demo.FixAction = 'assign'
                        $demo.FixTarget = ''
                        Show-Conclusion $demo
                    }
                }
            }
            # 自测：把右侧面板的纯文本存一份，用来核对「文字是否真的进了控件」
            if ($Shot -ne '') {
                try { [IO.File]::WriteAllText((Join-Path $env:TEMP 'dl_rt.txt'), $rt.Text, (New-Object System.Text.UTF8Encoding($false))) } catch { }
            }
            $form.TopMost = $true
            $form.Activate()
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 900
            [System.Windows.Forms.Application]::DoEvents()
            $b = $form.Bounds
            $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
            $g.Dispose()
            $bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            $form.TopMost = $false
        } catch { }
        $form.Close()
    }
})

$form.Add_FormClosing({ Show-ConsoleWindow })

# 全局兜底：界面里任何未捕获异常都写一份，不让它静默消失
trap {
    try {
        $p = Join-Path (DL-DeskPath) 'DeviceLens-error.txt'
        $enc = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($p, ((Get-Date).ToString() + "`r`n" + $_ + "`r`n" + $_.ScriptStackTrace), $enc)
    } catch { }
    continue
}

[void]$form.ShowDialog()

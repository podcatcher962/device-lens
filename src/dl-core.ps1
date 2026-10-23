# =====================================================================
#  设备诊断修复 · DeviceLens —— 核心引擎
#  版本 0.2.2      作者：永远的兰兰
#
#  这一份被 dl-gui.ps1（界面）与 dlprobe.ps1（命令行取证）共同引用。
#  只做三件事：枚举 → 判定「断在哪一层」→ 生成人话报告。
#  体检全程只读。修复只做两种能还原的动作：分配盘符、启用被禁用的设备，
#  每次动手前写留底，可随时撤销。不格式化、不重新分区、不恢复数据、不刷固件。
# =====================================================================

$script:DL_VER     = '0.2.2'
$script:DL_NAME_ZH = '设备诊断修复'
$script:DL_NAME_EN = 'DeviceLens'
$script:DL_AUTHOR  = '© 永远的兰兰'
$script:DL_LANG    = 'zh'
$script:DL_LOG     = New-Object System.Collections.ArrayList
$script:DL_CFG     = Join-Path $env:APPDATA 'DeviceLens'

# 配色（界面与报告共用一套语义）
$script:DL_C_OK    = 'OK'        # 绿：正常
$script:DL_C_INFO  = 'INFO'      # 灰：只是信息
$script:DL_C_WARN  = 'WARN'      # 黄：要注意
$script:DL_C_BAD   = 'BAD'       # 红：确实有问题

# ---------------------------------------------------------------------
#  语言 / 双语
# ---------------------------------------------------------------------
function DL-SetLang([string]$l) {
    if ($l -eq 'zh' -or $l -eq 'en') { $script:DL_LANG = $l }
}
function DL-Lang { return $script:DL_LANG }
function DL-IsEn { return ($script:DL_LANG -eq 'en') }

# 判定文案是动态拼的，用内联双语比建一张大表更好维护
# ★ 调用一律写成  (DL-Bi '中文' '英文')   —— 括号、空格、无逗号
#   写成 DL-Bi('中文', '英文') 会把两个参数并成一个数组传给 $zh，
#   再经 [string] 转换就变成 "中文 英文" 拼在一起。这个坑踩过一次，记住。
function DL-Bi {
    param([object]$zh, [object]$en)
    if ($zh -is [array]) {
        # 兜底：真写成括号逗号形式，也不至于拼成一坨
        $a = @($zh)
        if ($a.Count -ge 2) { $zh = [string]$a[0]; $en = [string]$a[1] }
        else { $zh = [string]$a[0]; $en = '' }
    }
    if ($script:DL_LANG -eq 'en') { return [string]$en }
    return [string]$zh
}

# ---------------------------------------------------------------------
#  日志
# ---------------------------------------------------------------------
function DL-Log([string]$s, [string]$kind = 'info') {
    $t = (Get-Date -Format 'HH:mm:ss') + '  ' + $s
    [void]$script:DL_LOG.Add(@{ t = $t; k = $kind })
}
function DL-LogRaw([string]$s) {
    [void]$script:DL_LOG.Add(@{ t = $s; k = 'info' })
}
function DL-LogClear { $script:DL_LOG.Clear() }
function DL-LogCount { return $script:DL_LOG.Count }

# ---------------------------------------------------------------------
#  杂项
# ---------------------------------------------------------------------
function DL-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function DL-EnsureCfg {
    try {
        if (-not (Test-Path $script:DL_CFG)) { New-Item -ItemType Directory -Path $script:DL_CFG -Force | Out-Null }
    } catch { }
}

function DL-DeskPath {
    $d = ''
    try { $d = [Environment]::GetFolderPath('Desktop') } catch { $d = '' }
    if ([string]::IsNullOrWhiteSpace($d) -or -not (Test-Path $d)) { $d = $env:TEMP }
    return $d
}

# CIM 查询：优先 Get-CimInstance（快），Win7/PS2 回退 WMI。
# 任何异常都吞掉返回空数组 —— 诊断工具不该因为一个类查不到就整体崩掉。
function DL-Q([string]$cls, [string]$ns = 'root/cimv2') {
    $out = @()
    try {
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
            $out = @(Get-CimInstance -ClassName $cls -Namespace $ns -ErrorAction Stop)
        } else {
            $out = @(Get-WmiObject -Class $cls -Namespace $ns -ErrorAction Stop)
        }
    } catch {
        try { $out = @(Get-WmiObject -Class $cls -Namespace $ns -ErrorAction Stop) } catch { $out = @() }
    }
    return $out
}

# 关联对象统一取 DeviceID：CimInstance 直接有属性，WMI 对象带 __PATH
function DL-RefId($ref) {
    if ($null -eq $ref) { return '' }
    try {
        if ($ref.PSObject.Properties['DeviceID']) { return [string]$ref.DeviceID }
    } catch { }
    try {
        if ($ref.PSObject.Properties['__PATH']) {
            $p = [string]$ref.__PATH
            $i = $p.LastIndexOf('=')
            if ($i -ge 0) { return $p.Substring($i + 1).TrimEnd('"').TrimStart('"') }
        }
    } catch { }
    return ''
}

# ---------------------------------------------------------------------
#  总线归类：把 PNPDeviceID 前缀翻成人话
# ---------------------------------------------------------------------
function DL-BusOf([string]$pnp) {
    if ([string]::IsNullOrWhiteSpace($pnp)) { return (DL-Bi '未知' 'Unknown') }
    $b = ($pnp -split '\\')[0].ToUpper()
    switch ($b) {
        'USB'     { return 'USB' }
        'USBSTOR' { return 'USB' }
        'PCI'     { return 'PCI' }
        'SCSI'    { return 'SCSI' }
        'STORAGE' { return 'Storage' }
        'IDE'     { return 'IDE' }
        'HDAUDIO' { return '音频' }
        'SWD'     { return (DL-Bi '软件设备' 'Software') }
        'ROOT'    { return (DL-Bi '系统根' 'Root') }
        'ACPI'    { return (DL-Bi '主板' 'ACPI') }
        'BTHENUM' { return 'Bluetooth' }
        'BTHLEDEVICE' { return 'Bluetooth' }
        'HID'     { return 'HID' }
        'MONITOR' { return (DL-Bi '显示器' 'Monitor') }
        'PRINTENUM' { return (DL-Bi '打印机' 'Printer') }
        'DISPLAY' { return (DL-Bi '显示适配器' 'Display') }
        'NET'     { return (DL-Bi '网络' 'Network') }
        'PCIIDE'  { return 'IDE' }
        '1394'    { return '1394' }
        'UASPSTOR' { return 'USB' }
        'SD'      { return (DL-Bi '读卡器' 'SD') }
        default   { return $b }
    }
}

# 设备类别（Class）→ 中文
function DL-ClassOf([string]$c) {
    if ([string]::IsNullOrWhiteSpace($c)) { return '' }
    switch ($c.ToUpper()) {
        'USB'           { return 'USB' }
        'DISKDRIVE'     { return (DL-Bi '磁盘驱动器' 'Disk') }
        'CDROM'         { return (DL-Bi '光驱' 'CD/DVD') }
        'PORTS'         { return (DL-Bi '端口' 'Ports') }
        'NET'           { return (DL-Bi '网络适配器' 'Network') }
        'DISPLAY'       { return (DL-Bi '显示适配器' 'Display') }
        'HIDCLASS'      { return 'HID' }
        'KEYBOARD'      { return (DL-Bi '键盘' 'Keyboard') }
        'MOUSE'         { return (DL-Bi '鼠标' 'Mouse') }
        'MEDIA'         { return (DL-Bi '音频' 'Audio') }
        'AUDIOENDPOINT' { return (DL-Bi '音频端点' 'Audio EP') }
        'IMAGE'         { return (DL-Bi '图像设备' 'Imaging') }
        'PRINTER'       { return (DL-Bi '打印机' 'Printer') }
        'BLUETOOTH'     { return 'Bluetooth' }
        'SYSTEM'        { return (DL-Bi '系统设备' 'System') }
        'VOLUME'        { return (DL-Bi '存储卷' 'Volume') }
        'VOLUMESNAPSHOT' { return (DL-Bi '卷影' 'Snapshot') }
        'SCSIADAPTER'   { return (DL-Bi '存储控制器' 'Storage ctrl') }
        'HDC'           { return (DL-Bi '磁盘控制器' 'Disk ctrl') }
        'FIRMWARE'      { return (DL-Bi '固件' 'Firmware') }
        'SOFTWAREDEVICE' { return (DL-Bi '软件设备' 'Software') }
        'PROCESSOR'     { return (DL-Bi '处理器' 'Processor') }
        'COMPUTER'      { return (DL-Bi '计算机' 'Computer') }
        'SECURITYDEVICES' { return (DL-Bi '安全设备' 'Security') }
        'SMARTCARDREADER' { return (DL-Bi '智能卡' 'Smartcard') }
        default         { return $c }
    }
}

# ---------------------------------------------------------------------
#  错误码 → 人话（本作第二块核心资产，一律按「层 + 能不能修 + 做什么」给）
#  返回 @{ L=层; V=判定; Why=; Fix=; Do= }
#    V: OK / FIXABLE / MAYBE / HARDWARE / INFO
# ---------------------------------------------------------------------
function DL-ErrInfo([int]$code) {
    switch ($code) {
        0 {
            return @{
                L = 'E5'; V = 'OK'
                Why = (DL-Bi '驱动已正确加载，没有报错。' 'Driver loaded correctly, no error.')
                Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
                Do  = (DL-Bi '如果它仍然不工作，问题在上一层（数据线 / 供电 / 端口），不在驱动。' 'If it still does not work, look at the layer below (cable, power, port), not the driver.')
            }
        }
        1 {
            return @{
                L = 'E4'; V = 'MAYBE'
                Why = (DL-Bi '设备没有被正确配置：系统知道它存在，但没给出完整的资源配置。' 'Device is not configured correctly: Windows knows it is there but has not assigned a complete resource set.')
                Fix = (DL-Bi '常见于驱动与硬件版本不匹配，换驱动版本多数能解决。' 'Usually a driver / hardware revision mismatch; a different driver version often fixes it.')
                Do  = (DL-Bi '先删掉这台设备（勾选「删除驱动程序」）再重新扫描，让系统重新配一次。' 'Remove the device (tick "delete the driver software") and rescan so Windows assigns resources again.')
            }
        }
        3 {
            return @{
                L = 'E4'; V = 'FIXABLE'
                Why = (DL-Bi '驱动已损坏，或系统内存不足，导致驱动无法加载。' 'The driver is corrupt, or the system is out of memory, so it could not load.')
                Fix = (DL-Bi '重装该驱动即可，属于软件层问题。' 'Reinstalling the driver fixes it — this is a software-layer problem.')
                Do  = (DL-Bi '卸载设备 → 重新扫描硬件改动；如果还不行，重启后再试。' 'Uninstall the device, then scan for hardware changes; reboot and retry if needed.')
            }
        }
        10 {
            return @{
                L = 'E4'; V = 'MAYBE'
                Why = (DL-Bi '无法启动：驱动装上了，但驱动一运行就失败。这是「装了不匹配的驱动」最典型的样子。' 'Cannot start: the driver is installed but fails the moment it runs. This is the classic "wrong driver for this chip" symptom.')
                Fix = (DL-Bi '换一个版本的驱动通常能解决；同一颗芯片的新旧批次可能需要不同版本。' 'Switching to another driver version usually fixes it; different batches of the same chip may need different versions.')
                Do  = (DL-Bi '先看硬件 ID 里的芯片型号，再找厂家对应版本的驱动。别用「万能驱动包」。' 'Read the chip model from the hardware ID, then get the vendor driver for that exact version. Do not use "universal driver packs".')
            }
        }
        12 {
            return @{
                L = 'E4'; V = 'MAYBE'
                Why = (DL-Bi '资源不足：这块设备要用的中断 / 内存地址 / DMA 通道被别的设备占了。' 'Not enough resources: the interrupt / memory range / DMA channel this device needs is already taken.')
                Fix = (DL-Bi '可以在设备管理器里看「资源」页确认冲突；改资源分配要看主板 BIOS 支不支持。' 'Check the Resources tab in Device Manager to confirm the conflict; changing the assignment depends on the motherboard BIOS.')
                Do  = (DL-Bi '换一个插槽（PCIe 卡尤其有效），或在 BIOS 里关掉不用的板载设备腾出资源。' 'Move the card to another slot (very effective for PCIe), or disable unused on-board devices in BIOS to free resources.')
            }
        }
        14 {
            return @{
                L = 'E4'; V = 'FIXABLE'
                Why = (DL-Bi '设备需要重新启动计算机才能完成配置。' 'The device needs a reboot to finish configuring.')
                Fix = (DL-Bi '重启就行。' 'Just reboot.')
                Do  = (DL-Bi '保存好手上的东西，重启。' 'Save your work and reboot.')
            }
        }
        18 {
            return @{
                L = 'E4'; V = 'FIXABLE'
                Why = (DL-Bi '驱动程序需要重新安装。' 'The drivers for this device need to be reinstalled.')
                Fix = (DL-Bi '重装驱动即可。' 'Reinstall the driver.')
                Do  = (DL-Bi '卸载设备（勾选删除驱动）→ 重新扫描硬件改动 → 再装一次驱动。' 'Uninstall the device (delete the driver) → scan for hardware changes → install the driver again.')
            }
        }
        19 {
            return @{
                L = 'E4'; V = 'FIXABLE'
                Why = (DL-Bi '设备的注册表配置已损坏，系统读不出它的设置。' 'The registry configuration for this device is corrupt, so Windows cannot read its settings.')
                Fix = (DL-Bi '删掉这个设备条目再重新扫描，系统会重建一份干净的配置。' 'Delete the device entry and rescan; Windows rebuilds a clean configuration.')
                Do  = (DL-Bi '卸载设备 → 重新扫描硬件改动。' 'Uninstall the device → scan for hardware changes.')
            }
        }
        21 {
            return @{
                L = 'E4'; V = 'INFO'
                Why = (DL-Bi '系统正在移除这台设备。' 'Windows is in the process of removing this device.')
                Fix = (DL-Bi '等几秒再看，通常会自己消失。' 'Wait a few seconds; it usually disappears on its own.')
                Do  = (DL-Bi '不用管。' 'Nothing to do.')
            }
        }
        22 {
            return @{
                L = 'E4'; V = 'FIXABLE'
                Why = (DL-Bi '这台设备被手动禁用了 —— 它没坏，只是被关掉了。' 'This device is disabled — it is not broken, just switched off.')
                Fix = (DL-Bi '启用即可，一秒钟的事。' 'Just enable it — one click.')
                Do  = (DL-Bi '设备管理器里右键 →「启用设备」。如果它是被安全软件或组策略禁用的，要先找管理员。' 'Right-click → "Enable device" in Device Manager. If a security tool or group policy disabled it, ask your admin first.')
            }
        }
        24 {
            return @{
                L = 'E2'; V = 'FIXABLE'
                Why = (DL-Bi '系统里有这台设备的记录，但它现在不在场（没插、或插在别的机器上）。' 'Windows has a record of this device, but it is not present right now (unplugged, or on another machine).')
                Fix = (DL-Bi '插上就会回来；如果是旧记录，属于「历史设备」，不用处理。' 'Plug it in and it returns; if it is an old record it is just history, no action needed.')
                Do  = (DL-Bi '确认它确实插好了，然后点「重新识别」。' 'Make sure it is plugged in, then press "Rescan".')
            }
        }
        28 {
            return @{
                L = 'E3'; V = 'FIXABLE'
                Why = (DL-Bi '驱动程序没有安装：系统完全认出了这块硬件（硬件 ID、型号都读到了），只是没有匹配的驱动。' 'No driver installed: Windows fully identified the hardware (it read the hardware ID and model) but has no matching driver.')
                Fix = (DL-Bi '补上对应驱动就能用。这是最好修的一类 —— 硬件是好的。' 'Install the matching driver and it works. This is the easiest case — the hardware is fine.')
                Do  = (DL-Bi '点「复制硬件 ID」，拿 VEN_/DEV_ 或 USB\VID_/PID_ 去厂家官网找驱动；Win10/11 多数能在 Windows 更新里自动找到。' 'Press "Copy hardware ID" and search the vendor site with VEN_/DEV_ or USB\VID_/PID_; Windows Update usually finds it on 10/11.')
            }
        }
        29 {
            return @{
                L = 'E4'; V = 'MAYBE'
                Why = (DL-Bi '设备的固件没有提供它所需的资源，通常是固件缺陷或硬件版本问题。' 'The device firmware did not provide the resources it requires — usually a firmware defect or hardware revision issue.')
                Fix = (DL-Bi '软件层只能重装驱动试试，固件问题刷固件才有用（本工具不刷固件）。' 'Software can only try a driver reinstall; a firmware problem needs a firmware update, which this tool does not do.')
                Do  = (DL-Bi '先重装驱动；仍不行就联系厂家问固件更新 —— 别自己刷。' 'Reinstall the driver first; if it persists, ask the vendor for a firmware update — do not flash it yourself.')
            }
        }
        31 {
            return @{
                L = 'E4'; V = 'MAYBE'
                Why = (DL-Bi '无法加载这台设备所需的驱动程序。' 'Windows cannot load the drivers required for this device.')
                Fix = (DL-Bi '多半是驱动文件缺失或被安全软件拦了，重装驱动通常能好。' 'Usually a missing driver file or a security tool blocking it; reinstalling the driver usually helps.')
                Do  = (DL-Bi '卸载设备（含驱动）→ 重新扫描 → 重装驱动。装的时候临时关一下杀毒软件。' 'Uninstall the device including its driver → rescan → reinstall. Temporarily pause antivirus while installing.')
            }
        }
        32 {
            return @{
                L = 'E4'; V = 'MAYBE'
                Why = (DL-Bi '这个设备的驱动服务启动失败。常见于服务被禁用、或依赖的另一个服务没起来。' 'The driver service for this device failed to start — often the service is disabled, or a service it depends on is not running.')
                Fix = (DL-Bi '可以查服务状态并重新启动，属于软件层。' 'The service state can be checked and restarted — this is software-layer.')
                Do  = (DL-Bi '卸载重装驱动；若反复出现，看事件查看器里该系统日志的具体错误。' 'Uninstall/reinstall the driver; if it recurs, read the exact error in Event Viewer.')
            }
        }
        37 {
            return @{
                L = 'E4'; V = 'MAYBE'
                Why = (DL-Bi '驱动程序初始化失败。' 'The driver failed to initialize.')
                Fix = (DL-Bi '重装或换驱动版本。' 'Reinstall or switch driver version.')
                Do  = (DL-Bi '卸载设备 → 重新扫描 → 重装驱动。' 'Uninstall → rescan → reinstall the driver.')
            }
        }
        39 {
            return @{
                L = 'E4'; V = 'FIXABLE'
                Why = (DL-Bi '驱动程序已损坏或缺失，系统找不到驱动文件了。' 'The driver is corrupt or missing — Windows cannot find the driver files.')
                Fix = (DL-Bi '重装驱动即可；这也是「驱动丢失」最典型的表现。' 'Reinstalling the driver fixes it; this is the classic "driver went missing" symptom.')
                Do  = (DL-Bi '如果有之前导出的驱动备份，直接导回去最快；没有就去官网重下。' 'If you exported a driver backup earlier, import it — fastest route. Otherwise download it again from the vendor.')
            }
        }
        43 {
            return @{
                L = 'E5'; V = 'HARDWARE'
                Why = (DL-Bi '设备自己报告了故障：驱动向它发指令，它没有正确回应。' 'The device itself reported a failure: the driver sent commands and it did not answer correctly.')
                Fix = (DL-Bi '这一层多半是硬件或连接问题（线材、供电、接触、芯片）。软件层最多只能重新枚举一次。' 'At this layer it is usually hardware or connection (cable, power, contact, chip). Software can only try one re-enumeration.')
                Do  = (DL-Bi '换一根线、换一个口（优先机箱后面的口）再试；仍报 43 就别再折腾软件了，考虑送修。' 'Try another cable and another port (prefer the rear ports). If it still reports 43, stop fighting software and consider repair.')
            }
        }
        45 {
            return @{
                L = 'E2'; V = 'INFO'
                Why = (DL-Bi '这台设备当前没有连接在计算机上（历史记录）。' 'This device is not currently connected (a historical record).')
                Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
                Do  = (DL-Bi '如果它早就不要了，可以在「历史设备」里清理它的记录。' 'If you no longer use it, you can clean its record in "Device history".')
            }
        }
        48 {
            return @{
                L = 'E4'; V = 'MAYBE'
                Why = (DL-Bi '这台设备的驱动被系统阻止启动，通常是因为已知的兼容性问题。' 'Windows blocked the driver from starting, usually because of a known compatibility problem.')
                Fix = (DL-Bi '换驱动版本，或等系统更新修掉这个阻止。不建议强行绕过。' 'Switch driver version, or wait for a Windows update. Forcing a bypass is not recommended.')
                Do  = (DL-Bi '去厂家官网找为你的系统版本签发的驱动。' 'Get the driver signed for your exact OS version from the vendor.')
            }
        }
        52 {
            return @{
                L = 'E4'; V = 'FIXABLE'
                Why = (DL-Bi '驱动的数字签名验证失败。最常见的原因其实是**系统时间不对** —— 证书还没生效或已过期。' 'Digital signature verification failed. The most common cause is actually a **wrong system clock** — the certificate is not yet valid or already expired.')
                Fix = (DL-Bi '先校时，多数情况校完就好；再不行就换一个有签名的驱动版本。' 'Fix the clock first — that alone solves most cases; otherwise get a properly signed driver.')
                Do  = (DL-Bi '打开「设置 → 时间和语言 → 自动设置时间」，同步一次，然后重新扫描硬件。' 'Open Settings → Time & language → set time automatically, sync once, then rescan hardware.')
            }
        }
        54 {
            return @{
                L = 'E4'; V = 'MAYBE'
                Why = (DL-Bi '这台设备用的是未签名的驱动。Win10/11 默认不接受未签名驱动。' 'This device uses an unsigned driver. Windows 10/11 rejects unsigned drivers by default.')
                Fix = (DL-Bi '换成厂家签名的正式版驱动。不建议关闭驱动签名强制 —— 那会降低整机安全性。' 'Use the vendor-signed release driver. Do not turn off driver signature enforcement — that weakens the whole machine.')
                Do  = (DL-Bi '去官网下正式版驱动；老设备可能只有 Win7 驱动，这种情况考虑换设备。' 'Download the release driver from the vendor; old devices with only Win7 drivers may need replacing.')
            }
        }
        default {
            return @{
                L = 'E4'; V = 'MAYBE'
                Why = (DL-Bi ('设备报了一个错误代码 ' + $code + '。') ('The device reports error code ' + $code + '.'))
                Fix = (DL-Bi '未知代码，先按通用办法：卸载设备 → 重新扫描 → 重装驱动。' 'Unknown code. Use the general route: uninstall → rescan → reinstall the driver.')
                Do  = (DL-Bi '把这份报告发出来，附上代码，能查到具体含义。' 'Send this report with the code and it can be looked up.')
            }
        }
    }
}

function DL-ErrShort([int]$code) {
    switch ($code) {
        0  { return (DL-Bi '正常' 'OK') }
        1  { return (DL-Bi '未正确配置' 'Not configured') }
        3  { return (DL-Bi '驱动损坏' 'Driver corrupt') }
        10 { return (DL-Bi '无法启动' 'Cannot start') }
        12 { return (DL-Bi '资源不足' 'No resources') }
        14 { return (DL-Bi '需重启' 'Reboot needed') }
        18 { return (DL-Bi '需重装驱动' 'Reinstall driver') }
        19 { return (DL-Bi '注册表损坏' 'Registry corrupt') }
        21 { return (DL-Bi '正在移除' 'Being removed') }
        22 { return (DL-Bi '已禁用' 'Disabled') }
        24 { return (DL-Bi '不在场' 'Not present') }
        28 { return (DL-Bi '缺驱动' 'No driver') }
        29 { return (DL-Bi '固件资源' 'Firmware resources') }
        31 { return (DL-Bi '驱动加载失败' 'Driver load failed') }
        32 { return (DL-Bi '服务启动失败' 'Service start failed') }
        37 { return (DL-Bi '初始化失败' 'Init failed') }
        39 { return (DL-Bi '驱动缺失' 'Driver missing') }
        43 { return (DL-Bi '设备报故障' 'Device failed') }
        45 { return (DL-Bi '未连接' 'Not connected') }
        48 { return (DL-Bi '驱动被阻止' 'Driver blocked') }
        52 { return (DL-Bi '签名验证失败' 'Signature failed') }
        54 { return (DL-Bi '驱动未签名' 'Unsigned driver') }
        default { return ('Code ' + $code) }
    }
}

# ---------------------------------------------------------------------
#  单台设备判定 → 条目
# ---------------------------------------------------------------------
function DL-NewItem {
    return @{
        Kind      = 'Device'
        Name      = ''
        Detail    = ''
        Bus       = ''
        Cls       = ''
        Status    = 'INFO'      # OK / INFO / WARN / BAD （决定颜色）
        Level     = ''          # E1..E5
        Verdict   = 'INFO'      # OK / FIXABLE / MAYBE / HARDWARE / INFO
        ErrCode   = 0
        StateText = ''
        Why       = ''
        Fix       = ''
        Advice    = ''
        Evidence  = @()
        HwIds     = @()
        InstanceId = ''
        FixAction = ''          # '' 不可修 / enable 启用设备 / assign 分配盘符
        FixTarget = ''
        Extra     = @{}
    }
}

# ---------------------------------------------------------------------
#  设备名对照：Windows 自己报的中文名
#
#  「卷」「母板资源」「ACPI 风扇」这些不是我们生成的文案，是中文版 Windows
#  自己本地化的 FriendlyName。切界面语言它不会变，于是英文界面里就会夹中文。
#  这张表只收 Windows 自带的通用设备名；厂商型号（RTX 4060、ST3000VX000）
#  本来就没中文，不动。
# ---------------------------------------------------------------------
$script:DL_EN_NAME = @{
    '卷'                      = 'Volume'
    '通用卷'                  = 'Generic volume'
    '通用卷影复制'            = 'Generic volume shadow copy'
    '卷管理器'                = 'Volume manager'
    '母板资源'                = 'Motherboard resources'
    '主板资源'                = 'Motherboard resources'
    '系统板'                  = 'System board'
    '系统计时器'              = 'System timer'
    '系统 CMOS/实时时钟'      = 'System CMOS/real time clock'
    '系统扬声器'              = 'System speaker'
    '内存控制器'              = 'Memory controller'
    '直接内存访问控制器'      = 'Direct memory access controller'
    '可编程中断控制器'        = 'Programmable interrupt controller'
    '高精度事件计时器'        = 'High precision event timer'
    '数值数据处理器'          = 'Numeric data processor'
    '复合总线枚举器'          = 'Composite Bus Enumerator'
    '即插即用软件设备枚举器'  = 'Plug and Play Software Device Enumerator'
    'NDIS 虚拟网络适配器枚举器' = 'NDIS Virtual Network Adapter Enumerator'
    'Microsoft 虚拟驱动器枚举器' = 'Microsoft Virtual Drive Enumerator'
    '远程桌面设备重定向程序总线' = 'Remote Desktop Device Redirector Bus'
    'Microsoft 存储空间控制器' = 'Microsoft Storage Spaces Controller'
    'Microsoft 基本呈现驱动程序' = 'Microsoft Basic Render Driver'
    'Microsoft 基本显示驱动程序' = 'Microsoft Basic Display Driver'
    'Microsoft Hyper-V 虚拟化基础结构驱动程序' = 'Microsoft Hyper-V Virtualization Infrastructure Driver'
    'Microsoft GS 波表合成器' = 'Microsoft GS Wavetable Synth'
    'Microsoft ACPI 兼容的控制方法电池' = 'Microsoft ACPI-Compliant Control Method Battery'
    'Microsoft AC 适配器'     = 'Microsoft AC Adapter'
    '基于 ACPI x64 的电脑'    = 'ACPI x64-based PC'
    '基于 ACPI 的电脑'        = 'ACPI-based PC'
    'ACPI 固定功能按钮'       = 'ACPI fixed feature button'
    'ACPI 电源按钮'           = 'ACPI power button'
    'ACPI 睡眠按钮'           = 'ACPI sleep button'
    'ACPI 热区域'             = 'ACPI thermal zone'
    'ACPI 风扇'               = 'ACPI fan'
    'ACPI 模块'               = 'ACPI module'
    'LPC 控制器'              = 'LPC controller'
    'LPC 接口'                = 'LPC interface'
    'PCI 总线'                = 'PCI bus'
    'PCI 到 PCI 桥'           = 'PCI-to-PCI bridge'
    'PCI Express 根复合体'    = 'PCI Express root complex'
    'PCI Express 根端口'      = 'PCI Express root port'
    'SM 总线控制器'           = 'SM bus controller'
    '标准双通道 PCI IDE 控制器' = 'Standard dual channel PCI IDE controller'
    '标准 SATA AHCI 控制器'   = 'Standard SATA AHCI controller'
    '标准 NVM Express 控制器' = 'Standard NVM Express controller'
    'USB 输入设备'            = 'USB input device'
    'USB 复合设备'            = 'USB composite device'
    'USB 根集线器'            = 'USB root hub'
    'USB 集线器'              = 'USB hub'
    '通用 USB 集线器'         = 'Generic USB hub'
    'USB 大容量存储设备'      = 'USB mass storage device'
    '通用串行总线控制器'      = 'Universal Serial Bus controllers'
    '符合 HID 标准的系统控制器' = 'HID-compliant system controller'
    '符合 HID 标准的供应商定义设备' = 'HID-compliant vendor-defined device'
    '符合 HID 标准的用户控制设备' = 'HID-compliant consumer control device'
    '符合 HID 标准的设备'     = 'HID-compliant device'
    '符合 HID 标准的鼠标'     = 'HID-compliant mouse'
    '符合 HID 标准的键盘'     = 'HID-compliant keyboard'
    'High Definition Audio 设备' = 'High Definition Audio device'
    'High Definition Audio 控制器' = 'High Definition Audio controller'
    '高清晰度音频设备'        = 'High Definition Audio device'
    '高清晰度音频控制器'      = 'High Definition Audio controller'
    '扬声器'                  = 'Speakers'
    '麦克风'                  = 'Microphone'
    '耳机'                    = 'Headphones'
    '通信端口'                = 'Communications port'
    '打印机端口'              = 'Printer port'
    '打印机端口逻辑接口'      = 'Printer port logical interface'
    '根打印队列'              = 'Root Print Queue'
    '旧设备'                  = 'Legacy device'
    '通用软件组件'            = 'Generic software component'
    '通用软件设备'            = 'Generic software device'
    '匿名管道'                = 'Anonymous pipe'
}

# 英文界面下把中文通用设备名换成英文。
# 查不到就原样返回 —— 宁可留着原名，也不编一个假型号。
function DL-EnName([string]$s) {
    $n = [string]$s
    if ($script:DL_LANG -ne 'en') { return $n }
    if ($n -eq '') { return $n }
    if ($n -notmatch '[\u4e00-\u9fff]') { return $n }
    if ($script:DL_EN_NAME.ContainsKey($n)) { return $script:DL_EN_NAME[$n] }
    # 「通信端口 (COM1)」这种：剥掉括号后缀，翻前面那段，再把后缀接回去
    $m = [regex]::Match($n, '^(.+?)\s*(\([^)]*\))\s*$')
    if ($m.Success) {
        $base = $m.Groups[1].Value.Trim()
        $suf = $m.Groups[2].Value
        if ($script:DL_EN_NAME.ContainsKey($base)) { return ($script:DL_EN_NAME[$base] + ' ' + $suf) }
    }
    # 「USB 根集线器(USB 3.0)」这种括号前没空格的，也兜一下
    $m2 = [regex]::Match($n, '^(.+?)\(([^)]*)\)\s*$')
    if ($m2.Success) {
        $base = $m2.Groups[1].Value.Trim()
        if ($script:DL_EN_NAME.ContainsKey($base)) { return ($script:DL_EN_NAME[$base] + ' (' + $m2.Groups[2].Value + ')') }
    }
    return $n
}

function DL-JudgeDevice($d) {
    $it = DL-NewItem
    $it.Kind = 'Device'
    $it.Name = [string]$d.Name
    if ([string]::IsNullOrWhiteSpace($it.Name)) { $it.Name = [string]$d.Description }
    if ([string]::IsNullOrWhiteSpace($it.Name)) { $it.Name = (DL-Bi '(未命名设备)' '(unnamed device)') }
    $it.Name = (DL-EnName $it.Name)
    $it.InstanceId = [string]$d.PNPDeviceID
    $it.Bus  = DL-BusOf $it.InstanceId
    $it.Cls  = DL-ClassOf ([string]$d.PNPClass)
    $it.Detail = $it.Cls

    $code = 0
    try { $code = [int]$d.ConfigManagerErrorCode } catch { $code = 0 }
    $it.ErrCode = $code

    $e = DL-ErrInfo $code
    $it.Level   = $e.L
    $it.Verdict = $e.V
    $it.Why     = $e.Why
    $it.Fix     = $e.Fix
    $it.Advice  = $e.Do
    $it.StateText = (DL-ErrShort $code)

    if ($code -eq 0) {
        $it.Status = 'OK'
    } elseif ($code -eq 45 -or $code -eq 24) {
        $it.Status = 'INFO'
    } elseif ($e.V -eq 'FIXABLE') {
        $it.Status = 'WARN'
    } elseif ($e.V -eq 'HARDWARE') {
        $it.Status = 'BAD'
    } else {
        $it.Status = 'WARN'
    }

    # 代码 22 = 设备被禁用。这是所有故障里唯一「点一下就回来」的那种，
    # 给它一个真能按的修复动作（启用设备，可还原成禁用）。
    if ($code -eq 22 -and $it.InstanceId -ne '') {
        $it.FixAction = 'enable'
        $it.FixTarget = $it.InstanceId
    }

    $ev = New-Object System.Collections.ArrayList
    [void]$ev.Add(((DL-Bi '设备状态码：' 'ConfigManagerErrorCode: ') + $code + '  (' + $it.StateText + ')'))
    try { if ($d.Status) { [void]$ev.Add(((DL-Bi 'WMI 状态：' 'WMI status: ') + [string]$d.Status)) } } catch { }
    try { if ($d.Present -eq $false) { [void]$ev.Add(((DL-Bi '是否在场：否' 'Present: no'))) } } catch { }
    try { if ($d.Service) { [void]$ev.Add(((DL-Bi '驱动服务：' 'Driver service: ') + [string]$d.Service)) } } catch { }
    try { if ($d.Manufacturer) { [void]$ev.Add(((DL-Bi '厂商：' 'Manufacturer: ') + [string]$d.Manufacturer)) } } catch { }
    [void]$ev.Add(((DL-Bi '实例 ID：' 'Instance ID: ') + $it.InstanceId))
    $it.Evidence = $ev.ToArray()

    $hw = New-Object System.Collections.ArrayList
    try { if ($d.HardwareID)   { foreach ($h in @($d.HardwareID)) { [void]$hw.Add([string]$h) } } } catch { }
    if ($hw.Count -eq 0 -and $it.InstanceId -ne '') { [void]$hw.Add($it.InstanceId) }
    $it.HwIds = $hw.ToArray()
    return $it
}

# ---------------------------------------------------------------------
#  历史设备（曾插过、现在不在场）—— 学 USBDeview 的「历史清单」
# ---------------------------------------------------------------------
function DL-GetHistory {
    $out = New-Object System.Collections.ArrayList
    $list = @()
    try { $list = @(Get-PnpDevice -ErrorAction Stop) } catch { $list = @() }
    if ($list.Count -eq 0) { return $out.ToArray() }
    foreach ($x in $list) {
        $st = ''
        try { $st = [string]$x.Status } catch { }
        if ($st -ne 'Unknown' -and $st -ne 'Not Present') { continue }
        $it = DL-NewItem
        $it.Kind = 'History'
        $it.Name = [string]$x.FriendlyName
        if ([string]::IsNullOrWhiteSpace($it.Name)) { $it.Name = [string]$x.InstanceId }
        $it.Name = (DL-EnName $it.Name)
        $it.InstanceId = [string]$x.InstanceId
        $it.Bus = DL-BusOf $it.InstanceId
        $it.Cls = DL-ClassOf ([string]$x.Class)
        $it.Detail = $it.Cls
        $it.StateText = (DL-Bi '不在场' 'Not present')
        $it.Status = 'INFO'
        $it.Level = 'E2'
        $it.Verdict = 'INFO'
        $it.Why = (DL-Bi '这台设备以前在这台电脑上用过，现在没有插。记录保留着，插上就会回来。' 'This device was used on this PC before and is not plugged in now. The record remains; it returns when plugged in.')
        $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
        $it.Advice = (DL-Bi '如果早就不用了，可以清理它的旧记录（后续版本提供）。现在只列出，不动它。' 'If you no longer use it, its old record can be cleaned in a later version. For now it is only listed, not touched.')
        [void]$out.Add($it)
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------------
#  分区身份：只有「数据分区」本来才该有盘符
#
#  v0.1.0 在这里判错过一次：看到分区没有盘符就报「缺盘符」，
#  结果把 EFI 启动分区、MSR 保留分区、扩展分区容器全报成了问题。
#  它们**本来就不该有盘符**，Windows 也不会给。
#  先看 Win32_DiskPartition.Type，再决定要不要报。
# ---------------------------------------------------------------------
function DL-PartKind([string]$type, [string]$gpType = '') {
    $t = [string]$type
    if ($t -eq '') { return 'DATA' }
    if ($t -match 'Extended') { return 'CONTAINER' }
    if ($t -match '^(GPT|MBR)\s*:\s*(System|Reserved|Recovery|LDM|Unknown|Microsoft Reserved|Protective)') { return 'SYSTEM' }
    # ★ Win32_DiskPartition.Type 只肯说「GPT: Basic Data」，
    #   分不出「100 MB 的数据分区」和「Windows 装机时建的恢复分区」——
    #   Get-Partition 的 Type 才说真话（Recovery / Reserved / System / EFI）。
    #   两个都有的时候，以 Get-Partition 为准。
    $g = [string]$gpType
    if ($g -match '^(System|EFI|Reserved|Microsoft Reserved|Recovery)') { return 'SYSTEM' }
    if ($g -match '^Extended') { return 'CONTAINER' }
    return 'DATA'
}

function DL-PartLabel([string]$type, [string]$gpType = '') {
    $t = [string]$type
    $g = [string]$gpType
    if ($g -match '^Recovery') { return (DL-Bi '恢复分区（Windows 装机时自动建的）' 'Recovery partition (created by Windows setup)') }
    if ($g -match '^(Reserved|Microsoft Reserved)') { return (DL-Bi 'MSR 保留分区' 'MSR reserved partition') }
    if ($g -match '^(System|EFI)') { return (DL-Bi 'EFI 系统分区（放 Windows 启动文件）' 'EFI system partition (boot files)') }
    if ($t -match 'Extended') { return (DL-Bi '扩展分区（逻辑驱动器的容器）' 'Extended partition (container)') }
    if ($t -match 'Reserved') { return (DL-Bi 'MSR 保留分区' 'MSR reserved partition') }
    if ($t -match 'Recovery') { return (DL-Bi '恢复分区' 'Recovery partition') }
    if ($t -match '^MBR.*System') { return (DL-Bi 'MBR 引导分区' 'MBR boot partition') }
    if ($t -match 'System') { return (DL-Bi 'EFI 系统分区（放 Windows 启动文件）' 'EFI system partition (boot files)') }
    return (DL-Bi '系统分区' 'System partition')
}

# ---------------------------------------------------------------------
#  硬件读数（v0.2 新增）
#
#  这一组回答的不是「盘坏没坏」，而是「这台机器本身什么状况」：
#  CPU 有没有被降频、内存是不是跑在标称频率、显卡驱动多少年没更新、
#  主板 BIOS 多旧、盘的健康状态、温度与风扇转速能不能取到。
#
#  ★ 诚实原则：温度与风扇转速不是每台机器都给。台式机和多数品牌机
#    不通过 ACPI 暴露传感器，取回来是空的。取不到就写「这台机器不提供」，
#    绝对不拿猜的数字冒充读数。
# ---------------------------------------------------------------------
function DL-Mhz([int]$m) {
    if ($m -le 0) { return (DL-Bi '频率未知' 'clock unknown') }
    return ([string][math]::Round($m / 1000.0, 2) + ' GHz')
}

function DL-MemGen([int]$t) {
    switch ($t) {
        20 { return 'DDR' }
        21 { return 'DDR2' }
        22 { return 'DDR2 FB-DIMM' }
        24 { return 'DDR3' }
        26 { return 'DDR4' }
        27 { return 'LPDDR' }
        28 { return 'LPDDR2' }
        29 { return 'LPDDR3' }
        30 { return 'LPDDR4' }
        34 { return 'DDR5' }
        default { return '' }
    }
}

function DL-HwItem([string]$cls, [string]$name, [string]$bus) {
    $it = DL-NewItem
    $it.Kind  = 'HW'
    $it.Cls   = $cls
    $it.Name  = $name
    $it.Bus   = $bus
    $it.Level = 'HW'
    return $it
}

function DL-CollectHw {
    $out = New-Object System.Collections.ArrayList

    # ---------------- CPU ----------------
    try {
        $cpus = @(DL-Q 'Win32_Processor')
        $ci = 0
        foreach ($c in $cpus) {
            $ci++
            $nm = [string]$c.Name
            if ([string]::IsNullOrWhiteSpace($nm)) { $nm = (DL-Bi '处理器' 'Processor') + ' ' + $ci }
            $nm = ($nm -replace '\s+', ' ').Trim()
            $it = DL-HwItem 'CPU' $nm 'CPU'
            $cores = 0; $thr = 0; $mx = 0; $cur = 0; $load = -1
            try { $cores = [int]$c.NumberOfCores } catch { }
            try { $thr = [int]$c.NumberOfLogicalProcessors } catch { }
            try { $mx = [int]$c.MaxClockSpeed } catch { }
            try { $cur = [int]$c.CurrentClockSpeed } catch { }
            try { $load = [int]$c.LoadPercentage } catch { $load = -1 }
            if ($thr -le 0) { $thr = $cores }
            $it.Detail = (DL-Mhz $mx) + ' · ' + $cores + (DL-Bi ' 核 ' ' cores ') + $thr + (DL-Bi ' 线程' ' threads')

            $ev = New-Object System.Collections.ArrayList
            [void]$ev.Add((DL-Bi '最高频率  ' 'max clock   ') + (DL-Mhz $mx))
            [void]$ev.Add((DL-Bi '当前频率  ' 'now clock   ') + (DL-Mhz $cur))
            if ($load -ge 0) { [void]$ev.Add((DL-Bi '当前负载  ' 'load        ') + $load + ' %') }
            $it.Evidence = $ev.ToArray()

            $ratio = 0
            if ($mx -gt 0 -and $cur -gt 0) { $ratio = [double]$cur / [double]$mx }
            $pct = [int][math]::Round($ratio * 100)

            if ($ratio -gt 0 -and $ratio -lt 0.7 -and $load -ge 50) {
                $it.Status = 'WARN'; $it.Verdict = 'FIXABLE'
                $it.StateText = (DL-Bi '疑似被降频' 'possibly throttled')
                $it.Why = (DL-Bi ('负载已经 ' + $load + '%，频率却只有最高的 ' + $pct + '%。这不是 CPU 坏了，是它被压住了：电源方案设成省电、散热跟不上触发了温度保护、或者笔记本没插电源。') ('Load is ' + $load + '% but the clock sits at ' + $pct + '% of maximum. The CPU is not broken - it is being held back: a power-saving plan, thermal protection, or a laptop on battery.'))
                $it.Fix = (DL-Bi '软件层能救一部分：把电源方案改回「平衡」或「高性能」，笔记本插上电源。要是风扇很响、机身很烫，那是散热问题，只有清灰换硅脂才真解决。' 'Software can recover part of it: set the power plan back to Balanced or High performance and plug a laptop in. If the fan is loud and the case is hot it is cooling - only dust removal and fresh thermal paste fixes that.')
                $it.Advice = (DL-Bi '★ 别为了跑分把温度保护关掉。降频是在保护自己，关掉换来的是一台更慢、更短命的机器。' '★ Do not disable thermal protection for benchmark numbers. Throttling protects the chip.')
            }
            elseif ($ratio -gt 0 -and $ratio -lt 0.7) {
                $it.Status = 'OK'; $it.Verdict = 'OK'
                $it.StateText = (DL-Bi '空闲降频（正常）' 'idle downclock (normal)')
                $it.Why = (DL-Bi ('现在跑在 ' + $pct + '% 的最高频率。空闲时自动降频省电，这是设计如此，不是故障。') ('It runs at ' + $pct + '% of maximum right now. Downclocking at idle saves power by design; it is not a fault.'))
                $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
                $it.Advice = (DL-Bi '要看满频，把电源方案换成「高性能」再观察。注意：那会更费电、更热。' 'To see full clock, switch the power plan to High performance. It will use more power and run hotter.')
            }
            else {
                $it.Status = 'OK'; $it.Verdict = 'OK'
                $it.StateText = (DL-Bi '正常' 'OK')
                $it.Why = (DL-Bi '频率正常，没有降频迹象。' 'Clock is normal, no sign of throttling.')
                $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
                $it.Advice = (DL-Bi '如果机器用起来卡，问题通常不在 CPU，在磁盘、内存不足或后台程序。' 'If the machine feels slow the cause is usually disk, low memory or background load - not the CPU.')
            }
            [void]$out.Add($it)
        }
    } catch { }

    # ---------------- 内存 ----------------
    try {
        $mods = @(DL-Q 'Win32_PhysicalMemory')
        $arr = @(DL-Q 'Win32_PhysicalMemoryArray')
        $slots = 0; $maxCap = 0
        foreach ($a in $arr) {
            try { $slots += [int]$a.MemoryDevices } catch { }
            try { if ([double]$a.MaxCapacityEx -gt 0) { $maxCap = [math]::Round([double]$a.MaxCapacityEx / 1GB, 0) } } catch { }
        }
        $spdList = New-Object System.Collections.ArrayList
        $totGB = 0
        $mi = 0
        foreach ($m in $mods) {
            $mi++
            $gb = 0; try { $gb = [math]::Round([double]$m.Capacity / 1GB, 0) } catch { }
            $totGB += $gb
            $loc = [string]$m.DeviceLocator
            if ([string]::IsNullOrWhiteSpace($loc)) { $loc = 'DIMM ' + $mi }
            $spd = 0; try { $spd = [int]$m.Speed } catch { }
            $cfg = 0; try { $cfg = [int]$m.ConfiguredClockSpeed } catch { }
            if ($spd -gt 0) { [void]$spdList.Add($spd) }
            $gen = DL-MemGen ([int]$m.SMBIOSMemoryType)
            if ($gen -eq '') { $gen = DL-MemGen ([int]$m.MemoryType) }

            $it = DL-HwItem (DL-Bi '内存' 'Memory') ($loc + ' · ' + $gb + ' GB') 'DIMM'
            if ($gen -ne '') { $it.Detail = $gen + ' · ' + $spd + ' MHz' } else { $it.Detail = $spd + ' MHz' }

            $ev = New-Object System.Collections.ArrayList
            [void]$ev.Add((DL-Bi '插槽      ' 'slot      ') + $loc)
            [void]$ev.Add((DL-Bi '容量      ' 'size      ') + $gb + ' GB')
            if ($spd -gt 0) { [void]$ev.Add((DL-Bi '标称频率  ' 'rated     ') + $spd + ' MHz') }
            if ($cfg -gt 0) { [void]$ev.Add((DL-Bi '实际频率  ' 'running   ') + $cfg + ' MHz') }
            $vnd = [string]$m.Manufacturer
            if ($vnd.Trim() -ne '') { [void]$ev.Add((DL-Bi '厂商      ' 'vendor    ') + $vnd.Trim()) }
            $pn = [string]$m.PartNumber
            if ($pn.Trim() -ne '') { [void]$ev.Add((DL-Bi '型号      ' 'part no.  ') + $pn.Trim()) }
            $it.Evidence = $ev.ToArray()

            if ($spd -gt 0 -and $cfg -gt 0 -and $cfg -lt $spd) {
                $it.Status = 'WARN'; $it.Verdict = 'FIXABLE'
                $it.StateText = (DL-Bi '没跑满频' 'below rated speed')
                $it.Why = (DL-Bi ('标称 ' + $spd + ' MHz，实际只跑 ' + $cfg + ' MHz。多半是 BIOS 里的 XMP（Intel）或 EXPO / DOCP（AMD）没打开，或者主板 / CPU 本来就不支持这个频率。这不是内存坏了。') ('Rated ' + $spd + ' MHz, running at ' + $cfg + ' MHz. Usually XMP (Intel) or EXPO / DOCP (AMD) is off in BIOS, or the board / CPU cannot reach that speed. The memory is not faulty.'))
                $it.Fix = (DL-Bi '想要标称频率，要进 BIOS 打开 XMP / EXPO。不开也完全能用，只是慢一点。' 'To reach rated speed, enable XMP / EXPO in BIOS. Leaving it off is perfectly usable, just slower.')
                $it.Advice = (DL-Bi '稳定性优先的话，保持现状没问题。这种「没跑满」不会损坏数据。' 'For stability, leaving it as is is fine. Running below rated speed does not corrupt data.')
            }
            else {
                $it.Status = 'OK'; $it.Verdict = 'OK'
                $it.StateText = (DL-Bi '正常' 'OK')
                $it.Why = (DL-Bi '这条内存按标称频率在工作。' 'This module runs at its rated speed.')
                $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
                $it.Advice = (DL-Bi '两条内存要插在同一颜色（通常是 A2 / B2）的插槽上才能开双通道。' 'Two modules must sit in the same-colour slots (usually A2 / B2) for dual channel.')
            }
            [void]$out.Add($it)
        }

        if ($mods.Count -gt 0) {
            $it = DL-HwItem (DL-Bi '内存' 'Memory') (DL-Bi '内存插槽总览' 'Memory slots') 'DIMM'
            $it.Detail = (DL-Bi '已用 ' 'used ') + $mods.Count + '/' + $slots + (DL-Bi ' 个 · 合计 ' ' · total ') + $totGB + ' GB'
            $ev = New-Object System.Collections.ArrayList
            [void]$ev.Add((DL-Bi '已插内存条  ' 'modules     ') + $mods.Count)
            [void]$ev.Add((DL-Bi '主板插槽数  ' 'slots       ') + $slots)
            [void]$ev.Add((DL-Bi '当前合计    ' 'total       ') + $totGB + ' GB')
            if ($maxCap -gt 0) { [void]$ev.Add((DL-Bi '主板最大支持 ' 'board max   ') + $maxCap + ' GB') }
            $it.Evidence = $ev.ToArray()

            $mixed = $false
            if ($spdList.Count -gt 1) {
                $u = @($spdList | Sort-Object -Unique)
                if ($u.Count -gt 1) { $mixed = $true }
            }
            if ($mixed) {
                $it.Status = 'WARN'; $it.Verdict = 'FIXABLE'
                $it.StateText = (DL-Bi '频率不一致' 'mixed speeds')
                $it.Why = (DL-Bi '几条内存的频率不一样。混插时整机通常按最低那条的频率跑，所以贵的那条白花钱了。' 'The modules have different rated speeds. With mixed modules the machine usually runs them all at the slowest speed.')
                $it.Fix = (DL-Bi '换成同一型号同一频率的条子，或者接受按最低频率跑。' 'Use identical modules, or accept running at the slowest speed.')
                $it.Advice = (DL-Bi '混插本身不会坏，只是浪费性能，偶尔会有兼容性蓝屏。' 'Mixing does not damage anything - it wastes performance and occasionally causes instability.')
            }
            elseif ($slots -gt $mods.Count) {
                $it.Status = 'INFO'; $it.Verdict = 'INFO'
                $it.StateText = (DL-Bi '还有空槽' 'free slots')
                $it.Why = (DL-Bi ('主板有 ' + $slots + ' 个插槽，插了 ' + $mods.Count + ' 条，还空 ' + ($slots - $mods.Count) + ' 个。') ('The board has ' + $slots + ' slots, ' + $mods.Count + ' are used and ' + ($slots - $mods.Count) + ' are free.'))
                $it.Fix = (DL-Bi '不需要修。要加内存就加同频率的。' 'Nothing to fix. If you add memory, match the speed.')
                $it.Advice = (DL-Bi '加内存前先确认主板最大支持容量，别买超过主板上限的。' 'Check the board maximum before buying: do not exceed it.')
            }
            else {
                $it.Status = 'OK'; $it.Verdict = 'OK'
                $it.StateText = (DL-Bi '正常' 'OK')
                $it.Why = (DL-Bi '插槽已经插满，没有空位。' 'All slots are populated.')
                $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
                $it.Advice = (DL-Bi '再想加内存只能换更大容量的条子，不能加条。' 'To add memory you must replace modules with larger ones.')
            }
            [void]$out.Add($it)
        }
    } catch { }

    # ---------------- 显卡 ----------------
    try {
        $gpus = @(DL-Q 'Win32_VideoController')
        foreach ($g in $gpus) {
            $nm = [string]$g.Name
            if ([string]::IsNullOrWhiteSpace($nm)) { continue }
            $it = DL-HwItem (DL-Bi '显卡' 'GPU') $nm 'PCIe'
            $dv = [string]$g.DriverVersion
            $dt = $null
            try { $dt = [datetime]$g.DriverDate } catch { $dt = $null }
            $it.Detail = (DL-Bi '驱动 ' 'driver ') + $dv
            if ($null -ne $dt) { $it.Detail = $it.Detail + ' · ' + $dt.ToString('yyyy-MM-dd') }

            $ev = New-Object System.Collections.ArrayList
            [void]$ev.Add((DL-Bi '驱动版本  ' 'version   ') + $dv)
            if ($null -ne $dt) { [void]$ev.Add((DL-Bi '驱动日期  ' 'date      ') + $dt.ToString('yyyy-MM-dd')) }
            $err = 0
            try { $err = [int]$g.ConfigManagerErrorCode } catch { $err = 0 }
            $it.ErrCode = $err

            if ($err -ne 0) {
                $ei = DL-ErrInfo $err
                $it.Status = 'BAD'; $it.Verdict = 'HARDWARE'
                $it.StateText = (DL-Bi ('驱动报错 ' + $err) ('error ' + $err))
                $it.Why = [string]$ei.Why
                $it.Fix = [string]$ei.Fix
                $it.Advice = (DL-Bi '这块显卡现在没有正常工作。先按上面说的做，再回来看这条。' 'This GPU is not working. Do the above first, then come back to this item.')
            }
            else {
                $yrs = -1
                if ($null -ne $dt) { $yrs = [math]::Round(((Get-Date) - $dt).TotalDays / 365.0, 1) }
                if ($yrs -ge 3) {
                    $it.Status = 'WARN'; $it.Verdict = 'FIXABLE'
                    $it.StateText = (DL-Bi '驱动偏旧' 'old driver')
                    $it.Why = (DL-Bi ('驱动是 ' + [int]$yrs + ' 年前发布的（' + $dt.ToString('yyyy-MM-dd') + '）。驱动旧不等于坏 —— 能正常用就别动。') ('The driver is ' + [int]$yrs + ' years old (' + $dt.ToString('yyyy-MM-dd') + '). An old driver is not a broken one.'))
                    $it.Fix = (DL-Bi '只在遇到具体问题（花屏、崩溃、新游戏打不开、视频编码不兼容）时才更新。更新前先建还原点。' 'Only update when you hit a real problem: artifacts, crashes, a game that will not start, unsupported video encoding. Create a restore point first.')
                    $it.Advice = (DL-Bi '★ 驱动不是越新越好。老卡装新驱动反而更容易出问题，能稳定用就别折腾。' '★ Newer is not always better. Old cards often do worse on new drivers: if it is stable, leave it.')
                }
                else {
                    $it.Status = 'OK'; $it.Verdict = 'OK'
                    $it.StateText = (DL-Bi '正常' 'OK')
                    $it.Why = (DL-Bi '驱动加载正常，版本也不算老。' 'The driver loads normally and is not too old.')
                    $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
                    $it.Advice = (DL-Bi '显卡报错很少是卡坏了，多数是驱动装错版本或供电没接。' 'GPU faults are rarely dead cards - usually a wrong driver version or a missing power cable.')
                }
            }
            $it.Evidence = $ev.ToArray()
            [void]$out.Add($it)
        }
    } catch { }

    # ---------------- 主板 / BIOS ----------------
    try {
        $bbs = @(DL-Q 'Win32_BaseBoard')
        foreach ($b in $bbs) {
            $nm = (([string]$b.Manufacturer) + ' ' + ([string]$b.Product)).Trim()
            if ($nm -eq '') { continue }
            $it = DL-HwItem (DL-Bi '主板' 'Board') $nm 'Board'
            $it.Detail = ''
            $bSn = [string]$b.SerialNumber
            if ($bSn.Trim() -ne '' -and $bSn -notmatch 'O\.E\.M|Default|To be filled') { $it.Detail = $bSn.Trim() }
            $ev = New-Object System.Collections.ArrayList
            [void]$ev.Add((DL-Bi '厂商  ' 'maker  ') + [string]$b.Manufacturer)
            [void]$ev.Add((DL-Bi '型号  ' 'model  ') + [string]$b.Product)
            $sn = [string]$b.SerialNumber
            if ($sn.Trim() -ne '' -and $sn -notmatch 'O\.E\.M|Default|To be filled') { [void]$ev.Add((DL-Bi '序列号 ' 'serial ') + $sn.Trim()) }
            $it.Evidence = $ev.ToArray()
            $it.Status = 'OK'; $it.Verdict = 'OK'
            $it.StateText = (DL-Bi '正常' 'OK')
            $it.Why = (DL-Bi '主板信息读取正常。' 'The mainboard reports normally.')
            $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
            $it.Advice = (DL-Bi '主板几乎不会「坏一点点」，要么完全不通电，要么某个接口失效 —— 这类问题软件层判断不了，只能换件。' 'Mainboards rarely fail part-way: they either do not power on or lose one port. Software cannot diagnose that; the part gets replaced.')
            [void]$out.Add($it)
        }
    } catch { }

    try {
        $bios = @(DL-Q 'Win32_BIOS')
        foreach ($b in $bios) {
            $ver = [string]$b.SMBIOSBIOSVersion
            if ($ver.Trim() -eq '') { continue }
            $dt = $null
            try { $dt = [datetime]$b.ReleaseDate } catch { $dt = $null }
            $it = DL-HwItem 'BIOS' ((DL-Bi 'BIOS ' 'BIOS ') + $ver.Trim()) 'BIOS'
            $it.Detail = $(if ($null -ne $dt) { $dt.ToString('yyyy-MM-dd') } else { (DL-Bi '日期未知' 'date unknown') })
            $ev = New-Object System.Collections.ArrayList
            [void]$ev.Add((DL-Bi '版本  ' 'version ') + $ver.Trim())
            if ($null -ne $dt) { [void]$ev.Add((DL-Bi '日期  ' 'date    ') + $dt.ToString('yyyy-MM-dd')) }
            $it.Evidence = $ev.ToArray()

            $yrs = -1
            if ($null -ne $dt) { $yrs = [math]::Round(((Get-Date) - $dt).TotalDays / 365.0, 1) }
            if ($yrs -ge 5) {
                $it.Status = 'INFO'; $it.Verdict = 'INFO'
                $it.StateText = (DL-Bi '版本较老' 'old firmware')
                $it.Why = (DL-Bi ('BIOS 是 ' + [int]$yrs + ' 年前的版本。绝大多数情况下这完全没问题 —— 老机器稳定运行才是常态。') ('The BIOS is ' + [int]$yrs + ' years old. In most cases that is perfectly fine: a stable old machine is the normal case.'))
                $it.Fix = (DL-Bi '不需要修。只有在遇到具体兼容性问题（新 CPU / 新显卡认不出、NVMe 装不上、开机慢、USB 供电异常）时才考虑更新。' 'Nothing to fix. Consider updating only for a concrete compatibility problem: an unrecognised CPU or GPU, an NVMe drive that will not boot, very slow POST, odd USB power behaviour.')
                $it.Advice = (DL-Bi '★ 刷 BIOS 有断电变砖的风险，必须看清主板型号和版本号，中途不能断电。没有具体问题就别刷。' '★ Flashing BIOS can brick the board if power fails. Match the exact board model and never interrupt it. Without a concrete problem, do not flash.')
            }
            else {
                $it.Status = 'OK'; $it.Verdict = 'OK'
                $it.StateText = (DL-Bi '正常' 'OK')
                $it.Why = (DL-Bi 'BIOS 版本不算老。' 'The BIOS is not old.')
                $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
                $it.Advice = (DL-Bi '没有具体兼容性问题就不要刷 BIOS。' 'Do not flash the BIOS without a concrete compatibility problem.')
            }
            [void]$out.Add($it)
        }
    } catch { }

    # ---------------- 存储健康 ----------------
    try {
        $pd = @()
        try { $pd = @(Get-PhysicalDisk -ErrorAction Stop) } catch { $pd = @() }
        if ($pd.Count -gt 0) {
            foreach ($d in $pd) {
                $nm = [string]$d.FriendlyName
                if ([string]::IsNullOrWhiteSpace($nm)) { $nm = ('Disk ' + [string]$d.DeviceId) }
                $hs = [string]$d.HealthStatus
                $mt = [string]$d.MediaType
                $it = DL-HwItem (DL-Bi '硬盘' 'Disk') $nm ([string]$d.BusType)
                if ($mt -eq '') { $mt = (DL-Bi '未知类型' 'unknown') }
                $it.Detail = $mt + ' · ' + $hs
                $ev = New-Object System.Collections.ArrayList
                [void]$ev.Add((DL-Bi '介质类型  ' 'media     ') + $mt)
                [void]$ev.Add((DL-Bi '健康状态  ' 'health    ') + $hs)
                [void]$ev.Add((DL-Bi '运行状态  ' 'status    ') + [string]$d.OperationalStatus)
                [void]$ev.Add((DL-Bi '接口      ' 'bus       ') + [string]$d.BusType)
                $it.Evidence = $ev.ToArray()
                if ($hs -eq 'Healthy') {
                    $it.Status = 'OK'; $it.Verdict = 'OK'
                    $it.StateText = (DL-Bi '正常' 'OK')
                    $it.Why = (DL-Bi '系统报告这块盘健康。' 'The system reports this disk as healthy.')
                    $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
                    $it.Advice = (DL-Bi '「健康」是依据 SMART 判断的，不是绝对保证。重要数据始终要另存一份。' 'Healthy is based on SMART, not a guarantee. Keep a second copy of anything important.')
                }
                else {
                    $it.Status = 'BAD'; $it.Verdict = 'HARDWARE'
                    $it.StateText = (DL-Bi ('健康状态 ' + $hs) ('health ' + $hs))
                    $it.Why = (DL-Bi '系统报告这块盘的健康状态不是 Healthy。' 'The system does not report this disk as Healthy.')
                    $it.Fix = (DL-Bi '先备份能读出来的东西，再谈修。' 'Copy what you can read first, then think about repair.')
                    $it.Advice = (DL-Bi '别再往里写新东西，也别跑全盘检测（会更累）。' 'Stop writing to it and skip full-surface tests: they stress it further.')
                }
                [void]$out.Add($it)
            }
        }
        else {
            $dd = @(DL-Q 'Win32_DiskDrive')
            foreach ($d in $dd) {
                $nm = [string]$d.Model
                if ([string]::IsNullOrWhiteSpace($nm)) { continue }
                $it = DL-HwItem (DL-Bi '硬盘' 'Disk') $nm ([string]$d.InterfaceType)
                $it.Detail = [string]$d.Status
                $it.Status = $(if ([string]$d.Status -eq 'OK') { 'OK' } else { 'WARN' })
                $it.Verdict = 'OK'
                $it.StateText = [string]$d.Status
                $it.Why = (DL-Bi '这块盘的状态来自 WMI（这台机器没有 Storage 模块，读不到详细健康数据）。' 'Status comes from WMI; this machine lacks the Storage module, so detailed health is unavailable.')
                $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
                $it.Advice = (DL-Bi '想看健康度，用管理员身份再跑一次，或者用厂商工具。' 'For health detail, run again as administrator or use the vendor tool.')
                [void]$out.Add($it)
            }
        }
    } catch { }

    # ---------------- 温度 ----------------
    $tempCount = 0
    try {
        $zones = @()
        try { $zones = @(Get-CimInstance -Namespace 'root/wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop) } catch { $zones = @() }
        $zi = 0
        foreach ($z in $zones) {
            $zi++
            $c = 0
            try { $c = [math]::Round(([double]$z.CurrentTemperature / 10.0) - 273.15, 1) } catch { continue }
            # ACPI 温度单位是「开尔文的十分之一」；换算不出合理值的条目直接跳过，不硬凑。
            if ($c -le -50 -or $c -ge 150) { continue }
            $it = DL-HwItem (DL-Bi '温度' 'Thermal') ((DL-Bi '温度区 ' 'Thermal zone ') + $zi) 'ACPI'
            $it.Detail = $c + ' °C'
            $nmz = [string]$z.InstanceName
            $ev = New-Object System.Collections.ArrayList
            [void]$ev.Add((DL-Bi '当前温度  ' 'reading   ') + $c + ' °C')
            if ($nmz.Trim() -ne '') { [void]$ev.Add((DL-Bi '数据来源  ' 'source    ') + $nmz.Trim()) }
            $it.Evidence = $ev.ToArray()
            if ($c -ge 85) {
                $it.Status = 'WARN'; $it.Verdict = 'FIXABLE'
                $it.StateText = (DL-Bi '偏高' 'high')
                $it.Why = (DL-Bi ('系统报告的温度是 ' + $c + ' °C，已经进入会让 CPU 主动降频的区间。') ('The reported temperature is ' + $c + ' C, already in the range where the CPU throttles itself.'))
                $it.Fix = (DL-Bi '清灰、换硅脂、检查风扇是否在转、机箱风道是否被挡。软件层改不了散热。' 'Dust it out, renew thermal paste, check the fan turns, clear blocked airflow. Software cannot fix cooling.')
                $it.Advice = (DL-Bi '别用软件把温度报警关掉。' 'Do not turn the temperature alarm off in software.')
            }
            else {
                $it.Status = 'OK'; $it.Verdict = 'OK'
                $it.StateText = (DL-Bi '正常' 'OK')
                $it.Why = (DL-Bi ('温度 ' + $c + ' °C，在正常范围内。') ('Temperature ' + $c + ' C, within the normal range.'))
                $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
                $it.Advice = (DL-Bi 'ACPI 报的是「温度区」，不一定是 CPU 核心温度，看趋势比看绝对值有用。' 'ACPI reports a thermal zone, not necessarily the CPU core temperature. Trend matters more than one number.')
            }
            [void]$out.Add($it)
            $tempCount++
        }
    } catch { }

    if ($tempCount -eq 0) {
        $it = DL-HwItem (DL-Bi '温度' 'Thermal') (DL-Bi '温度读数' 'Temperature readings') 'ACPI'
        $it.Detail = (DL-Bi '这台机器不提供' 'not provided')
        $it.Status = 'INFO'; $it.Verdict = 'INFO'
        $it.StateText = (DL-Bi '没有读数' 'no reading')
        $it.Why = (DL-Bi 'Windows 是通过 ACPI 向系统要温度的，但很多台式机主板（尤其组装机）根本没实现这一项，所以取回来是空的。这不是工具坏了，是这台机器没给这个数据。' 'Windows asks ACPI for temperature, but many desktop boards - especially self-built ones - do not implement it, so the query returns nothing. The tool is not broken; the machine does not expose the data.')
        $it.Fix = (DL-Bi '软件层修不了 —— 这是主板固件决定的，装什么软件都不会凭空长出传感器。' 'Software cannot fix this: the board firmware decides it. No program can invent a sensor.')
        $it.Advice = (DL-Bi '想看真实温度：① 开机按 Del / F2 进 BIOS，多数主板有 Hardware Monitor 页；② 装主板厂商的工具；③ 用 HWiNFO 这类直接读传感器的程序（需要装驱动）。' 'To see real temperature: 1) enter BIOS at boot, most boards have a Hardware Monitor page; 2) the board vendor tool; 3) a sensor-level program such as HWiNFO, which installs a driver.')
        [void]$out.Add($it)
    }

    # ---------------- 风扇 ----------------
    $fanOk = 0
    try {
        $fans = @(DL-Q 'Win32_Fan')
        foreach ($f in $fans) {
            $ds = 0
            try { $ds = [int]$f.DesiredSpeed } catch { $ds = 0 }
            if ($ds -gt 0) {
                $it = DL-HwItem (DL-Bi '风扇' 'Fan') ([string]$f.Name) 'FAN'
                $it.Detail = $ds + ' RPM'
                $it.Status = 'OK'; $it.Verdict = 'OK'
                $it.StateText = (DL-Bi '正常' 'OK')
                $it.Why = (DL-Bi '风扇转速读数正常。' 'The fan reports a speed.')
                $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
                $it.Advice = (DL-Bi '转速会随温度变，忽快忽慢是正常调速。' 'Speed follows temperature; a changing speed is normal.')
                $it.Evidence = @((DL-Bi '转速  ' 'speed ') + $ds + ' RPM')
                [void]$out.Add($it)
                $fanOk++
            }
        }
    } catch { }

    if ($fanOk -eq 0) {
        $it = DL-HwItem (DL-Bi '风扇' 'Fan') (DL-Bi '风扇转速' 'Fan speed') 'FAN'
        $it.Detail = (DL-Bi '这台机器不提供' 'not provided')
        $it.Status = 'INFO'; $it.Verdict = 'INFO'
        $it.StateText = (DL-Bi '没有读数' 'no reading')
        $it.Why = (DL-Bi '系统里能看到一个「冷却设备」，但主板不给出转速数字。台式机组装板十有八九如此 —— 机箱风扇直接接在主板针脚上由主板自己调速，Windows 拿不到。' 'A cooling device is listed, but the board gives no RPM figure. That is the norm on self-built desktops: case fans plug straight into the board, which controls them without telling Windows.')
        $it.Fix = (DL-Bi '不需要修，这不是故障。' 'Nothing to fix - this is not a fault.')
        $it.Advice = (DL-Bi '想看转速：进 BIOS 的 Hardware Monitor 页，或装主板厂商的风扇软件（技嘉 SIV / 华硕 AI Suite / 微星 Center）。' 'For RPM, use the BIOS Hardware Monitor page or the board vendor fan tool (Gigabyte SIV / ASUS AI Suite / MSI Center).')
        [void]$out.Add($it)
    }

    return $out.ToArray()
}

# ---------------------------------------------------------------------
#  磁盘 / 卷 / 盘符：四层视图的数据来源
# ---------------------------------------------------------------------
function DL-Collect {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = @{
        Time    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Host    = $env:COMPUTERNAME
        OS      = ''
        Bit64   = $false
        Admin   = $false
        Devices = @()
        History = @()
        Disks   = @()
        Volumes = @()
        Letters = @{}
        Hw      = @()
        Stats   = @{}
        Verdict = 'OK'
    }
    try { $r.OS = [Environment]::OSVersion.VersionString } catch { $r.OS = '' }
    try { $r.Bit64 = [Environment]::Is64BitOperatingSystem } catch { $r.Bit64 = $false }
    $r.Admin = DL-IsAdmin

    # --- 设备 ---
    $raw = DL-Q 'Win32_PnPEntity'
    $items = New-Object System.Collections.ArrayList
    $cntOK = 0; $cntWarn = 0; $cntBad = 0
    foreach ($d in $raw) {
        try {
            $it = DL-JudgeDevice $d
            [void]$items.Add($it)
            if ($it.Status -eq 'OK') { $cntOK++ }
            elseif ($it.Status -eq 'BAD') { $cntBad++ }
            elseif ($it.Status -eq 'WARN') { $cntWarn++ }
        } catch { }
    }
    $r.Devices = $items.ToArray()

    # --- 磁盘 + 卷 + 盘符（四层关联）---
    $disks = DL-Q 'Win32_DiskDrive'
    $d2p   = DL-Q 'Win32_DiskDriveToDiskPartition'
    $p2l   = DL-Q 'Win32_LogicalDiskToPartition'
    $logs  = DL-Q 'Win32_LogicalDisk'
    $parts = DL-Q 'Win32_DiskPartition'

    $logById = @{}
    foreach ($l in $logs) { if ($l.DeviceID) { $logById[[string]$l.DeviceID] = $l } }

    # 分区按 DeviceID 建索引：判「这个分区该不该有盘符」要用它自己的 Type
    $partById = @{}
    foreach ($pp in $parts) { if ($pp.DeviceID) { $partById[[string]$pp.DeviceID] = $pp } }

    # Get-Partition 的 Type 比 Win32 的 Type 精确：能把 Recovery 认出来。
    # 用「磁盘号 + StartingOffset」对齐，两个理由：
    #   ① Win32 的「Partition #N」编号会跳过 MSR / ESP，序号和真实分区号对不上；
    #   ② 光看 Offset 也不行 —— 每块盘的第一个分区都在 1048576，
    #      C: 和另一块盘的 EFI 会撞在同一个 key 上（v0.2.1 踩过）。
    $gpTypeByOff = @{}
    try {
        foreach ($gp in @(Get-Partition -ErrorAction Stop)) {
            try { $gpTypeByOff[([string]$gp.DiskNumber + '|' + [string][double]$gp.Offset)] = [string]$gp.Type } catch { }
        }
    } catch { }

    $volItems = New-Object System.Collections.ArrayList
    $diskItems = New-Object System.Collections.ArrayList

    foreach ($dk in $disks) {
        $dkId = [string]$dk.DeviceID
        $it = DL-NewItem
        $it.Kind = 'Disk'
        $it.Name = [string]$dk.Model
        if ([string]::IsNullOrWhiteSpace($it.Name)) { $it.Name = $dkId }
        $it.Bus = DL-BusOf ([string]$dk.PNPDeviceID)
        $gb = 0
        try { $gb = [math]::Round(([double]$dk.Size / 1GB), 1) } catch { $gb = 0 }
        $it.Detail = ((DL-Bi '磁盘 ' 'Disk ') + [string]$dk.Index + ' · ' + $gb + ' GB')
        $it.InstanceId = [string]$dk.PNPDeviceID
        $it.Cls = (DL-Bi '磁盘驱动器' 'Disk drive')

        # 这块盘上的分区 → 卷 → 盘符
        $myParts = @()
        foreach ($a in $d2p) {
            if ((DL-RefId $a.Antecedent) -eq $dkId) { $myParts += $a }
        }

        $chain = New-Object System.Collections.ArrayList
        [void]$chain.Add(((DL-Bi '[设备] ' '[device] ') + $it.Name + '  (' + $it.Bus + ')'))

        $noLetter = 0
        $partCount = 0
        $dataCount = 0
        $sysCount = 0
        $noLetterPart = ''
        foreach ($a in $myParts) {
            $partId = DL-RefId $a.Dependent
            if ($partId -eq '') { continue }
            $partCount++
            # ★ 关键：先看这个分区是什么身份，再决定「没有盘符」算不算问题。
            $pType = ''
            $gpType = ''
            $pMb = 0
            if ($partById.ContainsKey($partId)) {
                $pType = [string]$partById[$partId].Type
                try { $pMb = [math]::Round([double]$partById[$partId].Size / 1MB, 0) } catch { $pMb = 0 }
                try {
                    $k = [string]$partById[$partId].DiskIndex + '|' + [string][double]$partById[$partId].StartingOffset
                    if ($gpTypeByOff.ContainsKey($k)) { $gpType = $gpTypeByOff[$k] }
                } catch { }
            }
            $pKind = DL-PartKind $pType $gpType
            if ($pKind -eq 'DATA') { $dataCount++ } else { $sysCount++ }
            $ltr = ''
            $lg  = $null
            foreach ($b in $p2l) {
                if ((DL-RefId $b.Antecedent) -eq $partId) {
                    $lid = DL-RefId $b.Dependent
                    if ($lid -ne '') {
                        $ltr = $lid.TrimEnd(':')
                        if ($logById.ContainsKey($lid)) { $lg = $logById[$lid] }
                    }
                }
            }
            if ($ltr -eq '') {
                if ($pKind -eq 'DATA') {
                    # 数据分区却没有盘符 —— 「此电脑」里看不到它，这才是真问题
                    $noLetter++
                    if ($noLetterPart -eq '') { $noLetterPart = $partId }
                    [void]$chain.Add('   ' + ((DL-Bi '└ [卷] ' '   └ [volume] ') + $partId + (DL-Bi '  ← 数据分区，却没有盘符' '  <- data partition but no drive letter')))
                } else {
                    # EFI 启动分区 / MSR 保留分区 / 恢复分区 / 扩展分区容器：
                    # 本来就不该有盘符。v0.1.0 把这些一律报成「缺盘符」，是误报。
                    $plabel = DL-PartLabel $pType $gpType
                    [void]$chain.Add('   ' + ((DL-Bi '└ [保留] ' '   └ [reserved] ') + $plabel + ' · ' + $pMb + ' MB' + (DL-Bi '  （不需要盘符）' '  (no letter by design)')))
                    $vi = DL-NewItem
                    $vi.Kind = 'Volume'
                    $vi.Name = $plabel
                    $vi.Bus = ('Disk ' + $dk.Index)
                    $vi.Cls = (DL-Bi '系统保留分区' 'Reserved partition')
                    $vi.Detail = ([string]$pMb + ' MB')
                    $vi.InstanceId = $partId
                    $vi.Status = 'OK'
                    $vi.Level = 'L1'
                    $vi.Verdict = 'OK'
                    $vi.StateText = (DL-Bi '系统保留' 'Reserved')
                    $typeTx = $pType
                    if ($gpType -ne '') { $typeTx = $gpType }
                    $vi.Why = (DL-Bi ('这是分区表里的「' + $typeTx + '」，占 ' + $pMb + ' MB。它不是数据分区，Windows 按设计就不给它盘符，所以「此电脑」里看不到它是正常的。') ('This is a "' + $typeTx + '" entry of ' + $pMb + ' MB. It is not a data partition, so Windows gives it no drive letter by design: not appearing in This PC is correct.'))
                    $vi.Fix = (DL-Bi '不需要修。也别删它 —— EFI 分区没了机器开不了机，MSR 分区删了会影响系统升级，恢复分区删了「重置此电脑」就用不了了。' 'Nothing to fix, and nothing to delete: without the EFI partition the machine will not boot, removing the MSR partition can break upgrades, and removing the recovery partition disables "Reset this PC".')
                    $vi.Advice = (DL-Bi '如果你在算「这块盘为什么少了几百 MB」，答案就在这里。' 'If you wondered where a few hundred MB went, this is it.')
                    $vi.Extra = @{ Reserved = $true; Type = $pType; GpType = $gpType }
                    [void]$volItems.Add($vi)
                }
            } else {
                $fs = ''
                $sz = 0
                if ($null -ne $lg) {
                    try { $fs = [string]$lg.FileSystem } catch { }
                    try { $sz = [math]::Round(([double]$lg.Size / 1GB), 1) } catch { }
                }
                [void]$chain.Add('   ' + ((DL-Bi '└ [卷] ' '   └ [volume] ') + $partId + ' · ' + $fs + ' · ' + $sz + ' GB'))
                [void]$chain.Add('       ' + ((DL-Bi '└ [盘符] ' '       └ [letter] ') + $ltr + ':'))

                # 卷条目
                $vi = DL-NewItem
                $vi.Kind = 'Volume'
                $vi.Name = ($ltr + ':')
                $vi.Bus = ('Disk ' + $dk.Index)
                $vi.Cls = (DL-Bi '卷' 'Volume')
                $volName = ''
                if ($null -ne $lg) { try { $volName = [string]$lg.VolumeName } catch { } }
                $vi.Detail = $fs + ' · ' + $sz + ' GB'
                if ($volName -ne '') { $vi.Detail = $volName + ' · ' + $vi.Detail }
                $vi.InstanceId = $partId
                $vi.Extra = @{ Letter = $ltr; Size = $sz; Free = $(if ($null -ne $lg) { try { [math]::Round(([double]$lg.FreeSpace / 1GB), 1) } catch { 0 } } else { 0 }); FS = $fs }

                $isRaw = $false
                if ($null -eq $lg) { $isRaw = $true }
                elseif ([string]::IsNullOrWhiteSpace($fs)) { $isRaw = $true }

                if ($isRaw) {
                    $vi.Status = 'BAD'
                    $vi.Level = 'L3'
                    $vi.Verdict = 'HARDWARE'
                    $vi.StateText = (DL-Bi '无文件系统' 'No filesystem')
                    $vi.Why = (DL-Bi '这个分区存在，但系统读不出里面的文件系统 —— 可能是分区表或引导记录被写坏了。' 'The partition exists but Windows cannot read a filesystem on it — the partition table or boot record may be damaged.')
                    $vi.Fix = (DL-Bi '软件层有可能修：先备份分区表，再重建。**现在最要紧的是别格式化。**' 'Software may be able to fix it: back up the partition table first, then rebuild. **Most important right now: do not format it.**')
                    $vi.Advice = (DL-Bi '立刻停止往里写东西。如果里面有重要资料，先做数据恢复，再谈修盘。' 'Stop writing to it immediately. If the data matters, recover it first, then repair the disk.')
                } else {
                    $vi.Status = 'OK'
                    $vi.Level = 'L4'
                    $vi.Verdict = 'OK'
                    $vi.StateText = (DL-Bi '正常' 'OK')
                    $vi.Why = (DL-Bi '文件系统可以正常读取。' 'The filesystem reads normally.')
                    $vi.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
                    $vi.Advice = (DL-Bi '如果这里的文件打不开，问题不在盘，在权限（见「拒绝访问」）。' 'If files here will not open, the problem is permissions, not the disk (see "Access denied").')
                }
                [void]$volItems.Add($vi)
            }
        }

        if ($partCount -eq 0) {
            $it.Status = 'BAD'
            $it.Level = 'L2'
            $it.Verdict = 'HARDWARE'
            $it.StateText = (DL-Bi '无分区' 'No partitions')
            $it.Why = (DL-Bi '这块盘上没有任何可识别的分区。磁盘管理里会显示「未分配」，双击时会让你「先初始化磁盘」。' 'This disk has no recognisable partition. Disk Management shows it as unallocated and Windows asks you to initialise it.')
            $it.Fix = (DL-Bi '软件层可以修（重建分区表），但**初始化会清掉分区表**，救不了数据。' 'Software can rebuild the partition table, but **initialising wipes it** and will not recover data.')
            $it.Advice = (DL-Bi '先别点「初始化磁盘」。如果这块盘以前有数据，那说明分区表丢了，先做恢复。' 'Do not press "Initialise disk". If it used to hold data, the partition table is gone — recover first.')
            [void]$chain.Add('   ' + ((DL-Bi '└ [卷] （无）' '   └ [volume] (none)')))
        } elseif ($dataCount -eq 0 -and $sysCount -gt 0) {
            # 整块盘都是系统 / 保留分区（UEFI 启动盘、只有 ESP 的盘）—— 正常
            $it.Status = 'OK'
            $it.Level = 'L4'
            $it.Verdict = 'OK'
            $it.StateText = (DL-Bi '系统保留盘' 'System-reserved disk')
            $it.Why = (DL-Bi ('这块盘上的 ' + $sysCount + ' 个分区全部是系统 / 保留分区，没有数据分区。它本来就不该出现在「此电脑」里。') ('All ' + $sysCount + ' partitions on this disk are system or reserved types, with no data partition. It is not supposed to appear in This PC.'))
            $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
            $it.Advice = (DL-Bi '别删这些分区：删了开不了机。' 'Do not delete these partitions: the machine will not boot.')
        } elseif ($noLetter -gt 0) {
            $it.Status = 'WARN'
            $it.Level = 'L1'
            $it.Verdict = 'FIXABLE'
            $it.StateText = (DL-Bi '分区无盘符' 'Partition without letter')
            $it.Why = (DL-Bi '分区是好的，只是没有分配盘符，所以「此电脑」里看不到它。' 'The partition is fine but has no drive letter, so it does not appear in This PC.')
            $it.Fix = (DL-Bi '分配一个盘符就能用，不动任何数据。' 'Assigning a letter makes it usable, with no data touched.')
            $it.Advice = (DL-Bi '直接按右边绿色的「分配一个盘符」就行，不改动任何数据；也可以自己去磁盘管理 → 右键该分区 →「更改驱动器号和路径」→ 添加。' 'Just press "Assign a drive letter" on the right - no data is touched. Or do it manually in Disk Management → right-click the partition → "Change drive letter and paths" → Add.')
            $it.FixAction = 'assign'
            $it.FixTarget = $noLetterPart
        } else {
            $it.Status = 'OK'
            $it.Level = 'L4'
            $it.Verdict = 'OK'
            $it.StateText = (DL-Bi '正常' 'OK')
            $it.Why = (DL-Bi '磁盘、分区、卷、盘符四层都通。' 'Device, disk, volume and drive letter all check out.')
            $it.Fix = (DL-Bi '不需要修。' 'Nothing to fix.')
            $it.Advice = (DL-Bi '如果访问慢，看「速度慢」那一项；如果找不到文件，看「空间去哪了」。' 'If access is slow see "Slow"; if files are missing see "Where did the space go".')
        }
        $it.Evidence = $chain.ToArray()

        # 磁盘自身状态
        try {
            $st = [string]$dk.Status
            if ($st -ne '' -and $st -ne 'OK') {
                $it.Status = 'BAD'
                $it.Why = ((DL-Bi '磁盘自身报告状态：' 'The disk itself reports status: ') + $st)
            }
        } catch { }

        [void]$diskItems.Add($it)
    }
    $r.Disks = $diskItems.ToArray()
    $r.Volumes = $volItems.ToArray()

    # --- 盘符占用看板 A–Z ---
    $map = @{}
    foreach ($l in $logs) {
        $lid = [string]$l.DeviceID
        if ($lid -match '^[A-Z]:$') {
            $nm = ''
            try { $nm = [string]$l.VolumeName } catch { }
            $dt = ''
            try {
                $dv = [int]$l.DriveType
                switch ($dv) {
                    0 { $dt = (DL-Bi '未知' 'Unknown') }
                    1 { $dt = (DL-Bi '无根目录' 'No root') }
                    2 { $dt = (DL-Bi '可移动' 'Removable') }
                    3 { $dt = (DL-Bi '本地磁盘' 'Local disk') }
                    4 { $dt = (DL-Bi '网络' 'Network') }
                    5 { $dt = (DL-Bi '光驱' 'Optical') }
                    6 { $dt = (DL-Bi '内存盘' 'RAM disk') }
                    default { $dt = ('Type ' + $dv) }
                }
            } catch { }
            $map[$lid.Substring(0,1)] = @{ By = $(if ($nm -ne '') { $nm } else { $dt }); Kind = $dt }
        }
    }
    # 被「已占用但不在场」的盘符：读 MountedDevices 里没有对应卷的 \DosDevices\X:
    try {
        $md = Get-ItemProperty 'HKLM:\SYSTEM\MountedDevices' -ErrorAction Stop
        foreach ($p in $md.PSObject.Properties) {
            if ($p.Name -match '^\\DosDevices\\([A-Z]):$') {
                $L = $Matches[1]
                if (-not $map.ContainsKey($L)) {
                    $map[$L] = @{ By = ((DL-Bi '被旧记录占用（无对应卷）' 'Held by a stale record (no volume)')); Kind = (DL-Bi '残留' 'Stale') }
                }
            }
        }
    } catch { }
    $r.Letters = $map

    # --- 历史设备（单独一次，PnpDevice 模块可能不存在）---
    $r.History = @(DL-GetHistory)

    # 硬件读数不在这里采：它要多花约 3 秒，只在用户点开「硬件」时才算。
    # 由界面调 DL-CollectHw（见 Ensure-Hw）。

    # --- 统计与总判 ---
    $realBad = 0
    foreach ($d in $r.Devices) { if ($d.Status -eq 'BAD') { $realBad++ } }
    foreach ($d in $r.Disks)   { if ($d.Status -eq 'BAD') { $realBad++ } }
    foreach ($d in $r.Volumes) { if ($d.Status -eq 'BAD') { $realBad++ } }
    # 硬件的 WARN（驱动旧、BIOS 旧）只作提示，不拉高全局告警 —— 那会把提示条变成噪音。
    # 但硬件的 BAD（显卡加载失败、盘不健康）必须拉高。
    foreach ($d in $r.Hw) { if ($d.Status -eq 'BAD') { $realBad++ } }
    $realWarn = 0
    foreach ($d in $r.Devices) { if ($d.Status -eq 'WARN') { $realWarn++ } }
    foreach ($d in $r.Disks)   { if ($d.Status -eq 'WARN') { $realWarn++ } }
    foreach ($d in $r.Volumes) { if ($d.Status -eq 'WARN') { $realWarn++ } }

    $r.Stats = @{
        Devices = $r.Devices.Count
        Disks   = $r.Disks.Count
        Volumes = $r.Volumes.Count
        History = $r.History.Count
        Hw      = $r.Hw.Count
        Bad     = $realBad
        Warn    = $realWarn
        Ms      = $sw.ElapsedMilliseconds
    }
    if ($realBad -gt 0) { $r.Verdict = 'BAD' }
    elseif ($realWarn -gt 0) { $r.Verdict = 'WARN' }
    else { $r.Verdict = 'OK' }
    return $r
}

# ---------------------------------------------------------------------
#  【修复】三个真能按的动作 + 留底 + 撤销
#
#  这一节是 v0.2.1 新加的，回答「发现问题为什么不修」。
#  原则没变，只是从「只说不做」变成「只做能还原的」：
#    · 每个动作动手前先把「改之前的样貌」写进留底文件；
#    · 每个动作只做一件事，不顺手做别的；
#    · 动作失败立刻停，不再往下试；
#    · 撤销只认留底文件，不靠记忆。
#  仍然不做：格式化、分区、恢复数据、刷固件、装下载站的驱动。
# ---------------------------------------------------------------------

function DL-FixDir {
    $d = Join-Path $env:APPDATA 'DeviceLens\fix'
    try { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } } catch { }
    return $d
}

function DL-FixLogPath { return (Join-Path (DL-FixDir) 'log.txt') }

function DL-FixLogAdd($rec) {
    try {
        $line = ([pscustomobject]$rec | ConvertTo-Json -Compress -Depth 4)
        Add-Content -Path (DL-FixLogPath) -Value $line -Encoding UTF8
        return $true
    } catch { return $false }
}

function DL-FixLast {
    try {
        $p = DL-FixLogPath
        if (-not (Test-Path $p)) { return $null }
        $ls = @(Get-Content $p -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
        if ($ls.Count -eq 0) { return $null }
        return ($ls[$ls.Count - 1] | ConvertFrom-Json)
    } catch { return $null }
}

# 找一个空闲盘符：跳过 A / B / C，也跳过已经被占的
function DL-FreeLetter {
    $used = @{}
    try { foreach ($v in @(DL-Q 'Win32_LogicalDisk')) { if ($v.DeviceID) { $used[[string]$v.DeviceID] = 1 } } } catch { }
    try {
        $md = Get-ItemProperty 'HKLM:\SYSTEM\MountedDevices' -ErrorAction Stop
        foreach ($pr in $md.PSObject.Properties) {
            if ($pr.Name -match '^\\DosDevices\\([A-Z]):$') { $used[($Matches[1] + ':')] = 1 }
        }
    } catch { }
    foreach ($c in [char[]]'DEFGHIJKLMNOPQRSTUVWXYZ') {
        $k = ([string]$c) + ':'
        if (-not $used.ContainsKey($k)) { return [string]$c }
    }
    return ''
}

# 分配盘符。定位分区用 StartingOffset 对齐 —— 绝不用「Disk #1, Partition #2」里的序号，
# 那个序号会把 MSR / ESP 跳过去，序号和真实分区号对不上，是打错盘最典型的原因。
function DL-AssignLetter([string]$partId, [switch]$DryRun) {
    $r = @{ Ok = $false; Msg = ''; Detail = ''; Undo = ''; Letter = '' }
    if ($partId -eq '') { $r.Msg = (DL-Bi '没有指定分区' 'no partition given'); return $r }

    $wpart = $null
    try {
        $esc = $partId.Replace("'", "''")
        $wpart = @(Get-CimInstance -ClassName Win32_DiskPartition -Filter ("DeviceID='" + $esc + "'") -ErrorAction Stop)
        if ($wpart.Count -gt 0) { $wpart = $wpart[0] } else { $wpart = $null }
    } catch { $wpart = $null }
    if ($null -eq $wpart) { $r.Msg = (DL-Bi '找不到这个分区' 'partition not found'); return $r }

    $off = -1
    try { $off = [double]$wpart.StartingOffset } catch { $off = -1 }
    $dkn = -1
    try { $dkn = [int]$wpart.DiskIndex } catch { $dkn = -1 }

    # 必须连磁盘号一起比：每块盘的第一个分区都在 offset 1048576，
    # 只比 offset 会把手伸到另一块盘上去（这是最危险的一种打错盘）。
    $gp = $null
    try {
        foreach ($g in @(Get-Partition -ErrorAction Stop)) {
            if ($off -lt 0) { continue }
            if ([double]$g.Offset -ne $off) { continue }
            if ($dkn -ge 0 -and [int]$g.DiskNumber -ne $dkn) { continue }
            $gp = $g; break
        }
    } catch { $gp = $null }
    if ($null -eq $gp) {
        $r.Msg = (DL-Bi '这台系统上无法安全定位这个分区（缺少 Partition 模块，或者分区表对不上）。不做猜测，也不写盘。' 'This system cannot locate the partition safely (no Storage module, or the table does not match). It will not guess and will not write.')
        return $r
    }

    # 第二道闸：只给「数据分区」发盘符。
    # 就算上层判断错了，这里也不许碰 EFI / MSR / 恢复分区 —— 那是把自己坑进来的路。
    $gtype = ''
    try { $gtype = [string]$gp.Type } catch { $gtype = '' }
    if ($gtype -ne '' -and $gtype -notmatch '^(Basic|IFS)$') {
        $gtx = $gtype -replace '^XINT13\s+', ''
        if ($gtx -match 'Extended') { $gtx = (DL-Bi '扩展分区（逻辑驱动器的容器）' 'Extended partition (container of logical drives)') }
        elseif ($gtx -match 'Recovery') { $gtx = (DL-Bi '恢复分区' 'Recovery partition') }
        elseif ($gtx -match '^(Reserved|Microsoft Reserved)') { $gtx = (DL-Bi 'MSR 保留分区' 'MSR reserved partition') }
        elseif ($gtx -match '^(System|EFI)') { $gtx = (DL-Bi 'EFI 系统分区' 'EFI system partition') }
        $r.Msg = (DL-Bi ('这个分区是「' + $gtx + '」，不是数据分区，按设计不该有盘符。工具不碰它。') ('This partition is "' + $gtx + '", not a data partition, so it should have no drive letter by design. The tool will not touch it.'))
        return $r
    }

    $ltr = DL-FreeLetter
    if ($ltr -eq '') { $r.Msg = (DL-Bi 'D–Z 已经没有空闲盘符了' 'no free letter left between D and Z'); return $r }

    $r.Letter = $ltr
    $r.Detail = ('Disk ' + $gp.DiskNumber + ' · Partition ' + $gp.PartitionNumber + ' · ' + $ltr + ':')
    if ($DryRun) {
        $r.Ok = $true
        $r.Msg = (DL-Bi '预演通过（没有改动任何东西）' 'dry run passed (nothing changed)')
        return $r
    }

    try {
        Set-Partition -DiskNumber $gp.DiskNumber -PartitionNumber $gp.PartitionNumber -NewDriveLetter $ltr -ErrorAction Stop
        $r.Ok = $true
        $r.Msg = (DL-Bi ('已分配 ' + $ltr + ':') ('assigned ' + $ltr + ':'))
        $r.Undo = ('remove|' + $gp.DiskNumber + '|' + $gp.PartitionNumber + '|' + $ltr)
    } catch {
        $r.Msg = [string]$_.Exception.Message
    }
    return $r
}

# 启用被禁用的设备（代码 22）。可撤销：再禁用一次。
function DL-EnableDevice([string]$inst, [switch]$DryRun) {
    $r = @{ Ok = $false; Msg = ''; Detail = ''; Undo = '' }
    if ($inst -eq '') { $r.Msg = (DL-Bi '没有指定设备' 'no device given'); return $r }
    $r.Detail = $inst
    if ($DryRun) {
        $r.Ok = $true
        $r.Msg = (DL-Bi '预演通过（没有改动任何东西）' 'dry run passed (nothing changed)')
        return $r
    }
    if (-not (DL-IsAdmin)) {
        $r.Msg = (DL-Bi '需要管理员权限' 'administrator rights required')
        return $r
    }
    try {
        $o = (& pnputil.exe /enable-device "$inst" 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0) {
            $r.Ok = $true
            $r.Msg = (DL-Bi '已启用这台设备' 'device enabled')
            $r.Undo = ('disable|' + $inst)
        } else {
            $r.Msg = $o.Trim()
        }
    } catch { $r.Msg = [string]$_.Exception.Message }
    return $r
}

# 撤销留底里的最后一条动作
function DL-UndoLast {
    $r = @{ Ok = $false; Msg = ''; What = '' }
    $rec = DL-FixLast
    if ($null -eq $rec) { $r.Msg = (DL-Bi '还没有任何修复记录' 'no repair recorded yet'); return $r }
    try { if ($rec.undone -eq $true) { $r.Msg = (DL-Bi '最后一条已经撤销过了' 'the last entry was already undone'); return $r } } catch { }
    $u = [string]$rec.undo
    $r.What = [string]$rec.action
    if ($u -eq '') { $r.Msg = (DL-Bi '这条记录没有可撤销的内容' 'this entry cannot be undone'); return $r }
    if (-not (DL-IsAdmin)) { $r.Msg = (DL-Bi '需要管理员权限' 'administrator rights required'); return $r }

    if ($u -like 'remove|*') {
        $a = $u.Split('|')
        if ($a.Count -lt 4) { $r.Msg = (DL-Bi '记录格式不对' 'bad record'); return $r }
        try {
            $g = Get-Partition -DiskNumber ([int]$a[1]) -PartitionNumber ([int]$a[2]) -ErrorAction Stop
            Remove-PartitionAccessPath -DiskNumber ([int]$a[1]) -PartitionNumber ([int]$a[2]) -AccessPath ($a[3] + ':\') -ErrorAction Stop
            $r.Ok = $true
            $r.Msg = (DL-Bi ('已收回盘符 ' + $a[3] + '：') ('drive letter ' + $a[3] + ': removed'))
        } catch { $r.Msg = [string]$_.Exception.Message }
    }
    elseif ($u -like 'disable|*') {
        $a = $u.Split('|')
        try {
            $o = (& pnputil.exe /disable-device "$($a[1])" 2>&1 | Out-String)
            if ($LASTEXITCODE -eq 0) { $r.Ok = $true; $r.Msg = (DL-Bi '已改回禁用' 'device disabled again') }
            else { $r.Msg = $o.Trim() }
        } catch { $r.Msg = [string]$_.Exception.Message }
    }
    else { $r.Msg = (DL-Bi '不认识的记录' 'unknown record type') }

    if ($r.Ok) {
        try {
            # 在留底里补一条「已撤销」，避免重复撤销
            DL-FixLogAdd @{ time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); action = 'undo'; undo = ''; undone = $true; note = $u }
        } catch { }
    }
    return $r
}

# ---------------------------------------------------------------------
#  L0：重新枚举（零写入，可还原）—— 对应「设备管理器 → 扫描检测硬件改动」
#  三条路依次试，全都不需要重启、不改任何配置。
# ---------------------------------------------------------------------
function DL-Rescan {
    $ok = $false
    $how = ''

    # 1) pnputil /scan-devices（Win10 1809+ 最正规）
    try {
        $o = & pnputil.exe /scan-devices 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { $ok = $true; $how = 'pnputil /scan-devices' }
        elseif ($o -match '拒绝访问|Access is denied' -and (DL-IsAdmin)) {
            # 已是管理员还被拒，通常是被组策略/安全软件拦，继续试下一条
            $how = 'pnputil denied'
        }
    } catch { }

    # 2) cfgmgr32 重新枚举：等价于点一下「扫描检测硬件改动」
    if (-not $ok) {
        try {
            if (-not ('DLNative.Cfg' -as [type])) {
                $sig = @'
[DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
public static extern int CM_Locate_DevNodeW(out uint pdnDevInst, string pDeviceID, int ulFlags);
[DllImport("cfgmgr32.dll")]
public static extern int CM_Reenumerate_DevNode(uint dnDevInst, int ulFlags);
[DllImport("cfgmgr32.dll")]
public static extern int CM_Get_Child(out uint pdnDevInst, uint dnDevInst, int ulFlags);
'@
                Add-Type -MemberDefinition $sig -Name 'Cfg' -Namespace 'DLNative' | Out-Null
            }
            $dn = [uint32]0
            # CM_LOCATE_DEVNODE_NORMAL = 0；从「计算机」根节点往下重扫
            $rc = [DLNative.Cfg]::CM_Locate_DevNodeW([ref]$dn, $null, 0)
            if ($rc -eq 0) {
                # CM_REENUMERATE_SYNCHRONOUS = 1
                $rc2 = [DLNative.Cfg]::CM_Reenumerate_DevNode($dn, 1)
                if ($rc2 -eq 0) { $ok = $true; $how = 'cfgmgr32 CM_Reenumerate_DevNode' }
            }
        } catch { }
    }

    # 3) 兜底：走 WMI 的 PnP 服务（老系统）
    if (-not $ok) {
        try {
            $r = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $r) { $ok = $true; $how = 'WMI refresh (fallback)' }
        } catch { }
    }

    $script:DL_LAST_HOW = $how
    return $ok
}

# ---------------------------------------------------------------------
#  报告：三段式（是什么问题 / 能不能修 / 现在该做什么）+ 证据清单
# ---------------------------------------------------------------------
function DL-BuildReport($col, [string]$path) {
    $en = DL-IsEn
    $L = New-Object System.Collections.ArrayList
    $bar = '============================================================'

    if ($en) {
        [void]$L.Add('DeviceLens - DEVICE DIAGNOSIS REPORT   v' + $script:DL_VER)
    } else {
        [void]$L.Add('设备诊断修复 · 设备诊断报告   v' + $script:DL_VER)
    }
    [void]$L.Add($bar)
    [void]$L.Add(((DL-Bi '时间：' 'Time    : ')) + $col.Time)
    [void]$L.Add(((DL-Bi '电脑：' 'Computer: ')) + $col.Host)
    [void]$L.Add(((DL-Bi '系统：' 'OS      : ')) + $col.OS + ((DL-Bi '　' '  ')) + $(if ($col.Bit64) { (DL-Bi '64 位' '64-bit') } else { (DL-Bi '32 位' '32-bit') }))
    [void]$L.Add(((DL-Bi '权限：' 'Admin   : ')) + $(if ($col.Admin) { (DL-Bi '管理员' 'yes') } else { (DL-Bi '普通用户（只能看，不能改）' 'no (read-only)') }))
    [void]$L.Add(((DL-Bi '统计：设备 ' 'Counts  : devices ') + $col.Stats.Devices + (DL-Bi ' 台 · 磁盘 ' ' · disks ') + $col.Stats.Disks + (DL-Bi ' 块 · 卷 ' ' · volumes ') + $col.Stats.Volumes + (DL-Bi ' 个 · 历史设备 ' ' · history ') + $col.Stats.History + (DL-Bi ' 台' '')))
    $vTx = ''
    if ($col.Verdict -eq 'OK')   { $vTx = (DL-Bi '没有发现明显问题' 'no obvious problem found') }
    if ($col.Verdict -eq 'WARN') { $vTx = ((DL-Bi '有 ' 'found ') + $col.Stats.Warn + (DL-Bi ' 项需要注意' ' item(s) that need attention')) }
    if ($col.Verdict -eq 'BAD')  { $vTx = ((DL-Bi '有 ' 'found ') + $col.Stats.Bad + (DL-Bi ' 项确实有问题' ' item(s) with real problems')) }
    [void]$L.Add(((DL-Bi '总结：' 'Summary : ')) + $vTx)
    [void]$L.Add('')

    # ---- 第一段：有问题的东西，逐条三段式 ----
    $bad = New-Object System.Collections.ArrayList
    foreach ($x in @($col.Devices) + @($col.Disks) + @($col.Volumes)) {
        if ($x.Status -eq 'BAD' -or $x.Status -eq 'WARN') { [void]$bad.Add($x) }
    }

    [void]$L.Add('------------------------------------------------------------')
    [void]$L.Add(((DL-Bi '一、有问题的项目' 'PART 1 - ITEMS THAT NEED ATTENTION')))
    [void]$L.Add('------------------------------------------------------------')
    if ($bad.Count -eq 0) {
        [void]$L.Add(((DL-Bi '  没有。设备、磁盘、卷三个层面都没发现明显异常。' '  None. No obvious problem at the device, disk or volume level.')))
        [void]$L.Add('')
    } else {
        $n = 0
        foreach ($x in $bad) {
            $n++
            [void]$L.Add('')
            [void]$L.Add(('[' + $n + '] ' + $x.Name + '   (' + $x.Bus + $(if ($x.Detail) { ' · ' + $x.Detail } else { '' }) + ')'))
            [void]$L.Add('    ' + ((DL-Bi '① 是什么问题：' '(1) What it is      : ')) + $x.Why)
            [void]$L.Add('    ' + ((DL-Bi '② 能不能修  ：' '(2) Can it be fixed : ')) + $x.Fix)
            [void]$L.Add('    ' + ((DL-Bi '③ 该做什么  ：' '(3) What to do now  : ')) + $x.Advice)
            if ($x.Evidence.Count -gt 0) {
                [void]$L.Add('    ' + ((DL-Bi '证据：' 'Evidence:')))
                foreach ($e in $x.Evidence) { [void]$L.Add('      ' + $e) }
            }
        }
        [void]$L.Add('')
    }

    # ---- 第二段：四层视图 ----
    [void]$L.Add('------------------------------------------------------------')
    [void]$L.Add(((DL-Bi '二、四层视图：设备 → 磁盘 → 卷 → 盘符（断在哪层，就从哪层起修）' 'PART 2 - FOUR LAYERS: device -> disk -> volume -> letter (repair starts at the first broken layer)')))
    [void]$L.Add('------------------------------------------------------------')
    if ($col.Disks.Count -eq 0) {
        [void]$L.Add(((DL-Bi '  没有读到磁盘信息。' '  No disk information could be read.')))
    } else {
        foreach ($dk in $col.Disks) {
            if ($dk.Evidence.Count -gt 0) {
                foreach ($e in $dk.Evidence) { [void]$L.Add('  ' + $e) }
            } else {
                [void]$L.Add('  ' + $dk.Name)
            }
            [void]$L.Add('  ' + ((DL-Bi '　结论：' '   verdict: ')) + $dk.StateText + ' — ' + $dk.Why)
            [void]$L.Add('')
        }
    }

    # ---- 第三段：盘符占用 A–Z ----
    [void]$L.Add('------------------------------------------------------------')
    [void]$L.Add(((DL-Bi '三、盘符占用 A–Z（为什么某个字母用不了，看这里）' 'PART 3 - DRIVE LETTER MAP A-Z (why a letter is unavailable)')))
    [void]$L.Add('------------------------------------------------------------')
    foreach ($c in [char[]]'CDEFGHIJKLMNOPQRSTUVWXYZAB') {
        $k = [string]$c
        if ($col.Letters.ContainsKey($k)) {
            [void]$L.Add('  ' + $k + ':  ' + ((DL-Bi '已占用' 'used    ')) + '  ' + $col.Letters[$k].By + '   [' + $col.Letters[$k].Kind + ']')
        } else {
            [void]$L.Add('  ' + $k + ':  ' + ((DL-Bi '空闲' 'free')))
        }
    }
    [void]$L.Add('')

    # ---- 第四段：问题设备明细 ----
    [void]$L.Add('------------------------------------------------------------')
    [void]$L.Add(((DL-Bi '四、所有非正常设备明细' 'PART 4 - DETAILS OF NON-NORMAL DEVICES')))
    [void]$L.Add('------------------------------------------------------------')
    $anyDev = $false
    foreach ($d in $col.Devices) {
        if ($d.Status -eq 'OK') { continue }
        $anyDev = $true
        [void]$L.Add('')
        [void]$L.Add('  ' + $d.Name + '   [' + $d.Bus + ']   ' + $d.StateText + ((DL-Bi '（代码 ' ' (code ') + $d.ErrCode + '）'))
        [void]$L.Add('    ' + $d.Why)
        if ($d.HwIds.Count -gt 0) {
            [void]$L.Add('    ' + ((DL-Bi '硬件 ID：' 'Hardware ID: ')))
            foreach ($h in $d.HwIds) { [void]$L.Add('      ' + $h) }
        }
    }
    if (-not $anyDev) {
        [void]$L.Add(((DL-Bi '  没有。所有在场设备的驱动程序都正常。' '  None. Every present device has a healthy driver.')))
    }
    [void]$L.Add('')

    # ---- 第五段：硬件读数 ----
    if ($col.Hw.Count -gt 0) {
        [void]$L.Add('------------------------------------------------------------')
        [void]$L.Add(((DL-Bi '五、硬件读数（CPU / 内存 / 显卡 / 主板 / 温度 / 风扇）' 'PART 5 - HARDWARE READINGS (CPU / memory / GPU / board / thermal / fan)')))
        [void]$L.Add('------------------------------------------------------------')
        foreach ($h in $col.Hw) {
            [void]$L.Add('')
            [void]$L.Add('  [' + $h.Cls + '] ' + $h.Name + '   ' + $h.Detail + '   -> ' + $h.StateText)
            foreach ($e in $h.Evidence) { [void]$L.Add('      ' + $e) }
            if ($h.Status -ne 'OK') {
                [void]$L.Add('      ' + $h.Why)
                [void]$L.Add('      ' + ((DL-Bi '建议：' 'advice: ')) + $h.Advice)
            }
        }
        [void]$L.Add('')
        [void]$L.Add(((DL-Bi '  说明：取不到的温度 / 风扇转速会直接写「这台机器不提供」，本报告不编数字。' '  Note: unreadable temperature or fan speed is reported as unavailable; no number is invented.')))
        [void]$L.Add('')
    }

    # ---- 第六段：怎么反馈 ----
    [void]$L.Add('------------------------------------------------------------')
    [void]$L.Add(((DL-Bi '六、需要帮忙时怎么反馈' 'PART 6 - HOW TO ASK FOR HELP')))
    [void]$L.Add('------------------------------------------------------------')
    if ($en) {
        [void]$L.Add('  Send this whole file. Add one sentence about what you see:')
        [void]$L.Add('  does Windows stay completely silent, or does it show a yellow mark?')
        [void]$L.Add('  If there is a yellow mark, open it and note the code number.')
    } else {
        [void]$L.Add('  把这个文件整个发出来，再补一句话说明现象：')
        [void]$L.Add('  插上时 Windows 是「完全没动静」，还是「设备管理器里出现黄色感叹号」？')
        [void]$L.Add('  有感叹号的话，双击它看错误代码是几，一起发过来。')
    }
    [void]$L.Add('')
    [void]$L.Add(((DL-Bi '  报告里标了「可修」的问题（设备被禁用 / 数据分区缺盘符），' '  Problems marked fixable (disabled device / data partition without a letter) can be')))
    [void]$L.Add(((DL-Bi '  可以回到软件里选中它，点右边绿色的「修复这一项」。' '  repaired in the app: select it, then click the green "Fix this item" button.')))
    [void]$L.Add(((DL-Bi '  每次动手之前都会把改之前的样貌写进留底文件，随时能撤销。' '  The previous state is written to an undo log first, so every action is reversible.')))
    [void]$L.Add('')
    [void]$L.Add('------------------------------------------------------------')
    [void]$L.Add('  ' + $script:DL_NAME_ZH + ' / ' + $script:DL_NAME_EN + '  v' + $script:DL_VER + '   ' + $script:DL_AUTHOR)
    [void]$L.Add(((DL-Bi '  本报告由程序自动生成。体检过程只读；修复只做「分配盘符 / 启用被禁用的设备」两种，且可撤销。' '  Generated automatically. Scanning is read-only; the app only assigns drive letters or re-enables disabled devices, and every action can be undone.')))

    # ★ 不要用 WriteAllLines：在这套 .NET 上它写出的是 LF，
    #   记事本打开会变成「全部挤在一行」。显式拼 CRLF。
    $enc = New-Object System.Text.UTF8Encoding($true)
    try {
        $txt = ($L -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($path, $txt, $enc)
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------------
#  一句话结论（界面顶部提示条用）
# ---------------------------------------------------------------------
function DL-Headline($col) {
    if ($null -eq $col) { return (DL-Bi '还没有体检' 'Not scanned yet') }
    if ($col.Verdict -eq 'OK') {
        return ((DL-Bi ('✓ 检查了 ' + $col.Stats.Devices + ' 台设备，没有发现明显问题') ('OK - ' + $col.Stats.Devices + ' devices checked, no obvious problem')))
    }
    if ($col.Verdict -eq 'WARN') {
        return ((DL-Bi ('● 有 ' + $col.Stats.Warn + ' 项需要注意，选中看右边怎么说') ('Found ' + $col.Stats.Warn + ' item(s) that need attention - select one for details')))
    }
    return ((DL-Bi ('● 有 ' + $col.Stats.Bad + ' 项确实有问题，选中看右边怎么说') ('Found ' + $col.Stats.Bad + ' item(s) with real problems - select one for details')))
}

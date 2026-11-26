#Requires -Version 5.1
<#
.SYNOPSIS
    [阶段 1 - 只读体检] 全面诊断 Windows 用户目录拓扑、8.3 短名盲区、内核锁、WSL2 与残余项。
.DESCRIPTION
    本脚本为 100% 只读脚本，不会修改任何文件、注册表或系统设置。
    它会帮你判断本机属于以下哪种情况，并给出最安全的修复方案建议：
      1) StandardNonAsciiPhysical  : 标准中文/非 ASCII 实体目录（需标准改名 + 改 ProfileImagePath + 兜底联接）
      2) ReverseJunctionToNonAscii : 反向联接陷阱（英文 Junction -> 中文真身，需原地翻转方向）
      3) HealthyAsciiPhysical      : 物理目录已是纯英文，但可继续检查环境变量/WSL2/乱码目录残留
.PARAMETER ExportReportPath
    可选：将体检摘要保存为 JSON 报告文件。
.EXAMPLE
    .\01-Audit-UserProfile.ps1
.EXAMPLE
    .\01-Audit-UserProfile.ps1 -ExportReportPath D:\profile_audit_report.json
#>
[CmdletBinding()]
param(
    [string]$ExportReportPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$modulePath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'common') -ChildPath 'ProfileFixer.Common.psm1'
Import-Module $modulePath -Force

Write-Banner -Title 'WinProfileFixer :: 阶段 1 - Windows 用户目录深度只读体检' -Subtitle '100% 只读诊断，不修改任何文件或注册表'

$isAdmin = Test-IsAdministrator
if ($isAdmin) {
    Write-Ok '当前运行在管理员权限下（可获取完整内核过滤驱动与 BitLocker 状态）。'
} else {
    Write-Warn '当前为普通权限：核心目录与注册表检查不受影响，但 fltmc / BitLocker (WMI) 检查需要管理员权限。'
}

# 1. System & CodePage info
Write-Step '1. 系统版本与代码页 (GBK / UTF-8 乱码风险)'
$ntKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$prodName = [string](Get-RegistryValueSafe -Path $ntKey -Name 'ProductName')
$dispVer  = [string](Get-RegistryValueSafe -Path $ntKey -Name 'DisplayVersion')
$curBuild = [string](Get-RegistryValueSafe -Path $ntKey -Name 'CurrentBuild')
$ubr      = [string](Get-RegistryValueSafe -Path $ntKey -Name 'UBR')
$buildNum = 0
if ([int]::TryParse($curBuild, [ref]$buildNum) -and $buildNum -ge 22000) {
    $prodName = $prodName -replace 'Windows 10', 'Windows 11'
}
$osLabel = "$prodName $dispVer (Build $curBuild.$ubr)"
$cp = Get-SystemCodePageInfo
Write-Info "系统版本: $osLabel"
Write-Info "系统代码页: ACP=$($cp.ACP), OEMCP=$($cp.OEMCP), Beta UTF-8=$($cp.IsUtf8Beta)"
if (-not $cp.IsUtf8Beta) {
    Write-Warn '当前系统默认代码页非 UTF-8 (通常为 GBK 936)：跨平台工具遇到中文真实路径时极易产生乱码幽灵目录。'
}

# 2. ProfileList Topology Audit
Write-Step '2. 用户配置文件 (ProfileList) 拓扑深度解析'
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$profiles = @(Get-UserProfileInventory)
$needFixProfiles = @()

foreach ($p in $profiles) {
    $marker = if ($p.SID -eq $currentSid) { ' <-- [当前登录]' } else { '' }
    Write-Host ''
    Write-Host "  账户: $($p.Account)$marker" -ForegroundColor White
    Write-Host "  SID : $($p.SID)" -ForegroundColor DarkGray
    Write-Host "  ProfileImagePath : $($p.ProfileImagePath)"
    if ($p.IsReparsePoint) {
        Write-Host "  目录类型         : [ReparsePoint / $($p.LinkType)] -> $($p.LinkTarget)" -ForegroundColor Yellow
    } else {
        Write-Host "  目录类型         : [物理实体目录] (NTUSER.DAT=$($p.HasNtUserDat))"
    }
    Write-Host "  Win32 真实路径   : $($p.FinalPath)"
    Write-Host "  8.3 短路径       : $($p.ShortPath)"

    switch ($p.Topology) {
        'HealthyAsciiPhysical' {
            Write-Ok '  诊断结论: [健康] 物理真身已是纯英文 ASCII 目录，无穿透风险。'
        }
        'ReverseJunctionToNonAscii' {
            Write-Err '  诊断结论: [高危 - 反向联接陷阱] 表面英文壳子 -> 底层仍是中文真身！'
            Write-Warn '  影响: Go EvalSymlinks / Win32 GetFinalPathNameByHandleW / Python realpath / QEMU 均会穿透暴露中文。'
            if ($p.ShortHasNonAscii) {
                Write-Err '  叠加盲区: 8.3 短路径依然包含非 ASCII 字符（常见于 2~4 字中文名），依赖 8.3 兜底的工具会直接崩溃！'
            }
            Write-Info '  推荐动作: 使用 03-Migrate-UserProfile.ps1（将自动识别为 Flip 模式：原地 0 拷贝翻转联接方向）。'
            $needFixProfiles += $p
        }
        'StandardNonAsciiPhysical' {
            Write-Warn '  诊断结论: [待修复 - 标准中文实体目录] 物理目录与 ProfileImagePath 均含非 ASCII 字符。'
            if ($p.ShortHasNonAscii) {
                Write-Warn '  叠加盲区: 8.3 短路径仍含非 ASCII 字符，无法靠短路径绕过。'
            }
            Write-Info '  推荐动作: 使用 03-Migrate-UserProfile.ps1（将自动识别为 Standard 模式：重命名 + 改 ProfileImagePath + 兜底联接）。'
            $needFixProfiles += $p
        }
        'ProfileImagePathIsReparsePoint' {
            Write-Warn '  诊断结论: [不推荐] ProfileImagePath 指向重解析点（虽目标为英文，仍可能影响 Windows 大版本升级与 UWP）。'
        }
        'OrphanOrMissing' {
            Write-Warn '  诊断结论: [孤儿项] ProfileList 注册表指向的目录不存在（可能是已删除的旧测试账号残留）。'
        }
        default {
            Write-Warn "  诊断结论: 未知拓扑 ($($p.Topology))，请人工核查。"
        }
    }
}

# 3. C:\Users Directory & Mojibake / Suspicious Folder Scan
Write-Step '3. C:\Users 目录总览与疑似乱码/多余目录检查'
$usersRoot = 'C:\Users'
$knownSystem = @('Administrator','All Users','Default','Default User','Public','defaultuser0','defaultuser100000','desktop.ini')
$profileLeafNames = @()
$activeProfilePaths = @()
foreach ($p in $profiles) {
    if ($p.ProfileImagePath) {
        $profileLeafNames += (Split-Path -Path $p.ProfileImagePath -Leaf)
        if ($p.Exists) { $activeProfilePaths += $p.ProfileImagePath }
    }
    if ($p.FinalPath -and $p.FinalPath -ne '<ResolveError>') {
        $profileLeafNames += (Split-Path -Path $p.FinalPath -Leaf)
        $activeProfilePaths += $p.FinalPath
    }
}
$suspiciousDirs = @()

Get-ChildItem -LiteralPath $usersRoot -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $name = $_.Name
    $isReparse = [bool]($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
    $tgt = if ($isReparse) { Get-FirstLinkTarget $_ } else { $null }
    if (-not $_.PSIsContainer) {
        $lt = 'File'
    } elseif ($isReparse) {
        $ltype = if ($_.LinkType) { $_.LinkType } else { 'ReparsePoint' }
        $lt = if ($tgt) { "$ltype -> $tgt" } else { "$ltype (System)" }
    } else {
        $lt = 'Directory'
    }

    $isCompatJunction = $false
    if ($isReparse -and $tgt) {
        foreach ($ap in $activeProfilePaths) {
            if ($tgt.Equals($ap, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isCompatJunction = $true
                break
            }
        }
    }

    $isKnown = ($name -in $knownSystem) -or ($name -like 'defaultuser100000.*') -or ($name -in $profileLeafNames)
    if ($isKnown) {
        Write-Info ("  {0,-28} | {1}" -f $name, $lt)
    } elseif ($isCompatJunction) {
        Write-Ok ("  {0,-28} | {1}  <-- [向后兼容兜底联接]" -f $name, $lt)
    } else {
        Write-Warn ("  {0,-28} | {1}  <-- [疑似乱码/历史残留目录]" -f $name, $lt)
        $suspiciousDirs += [PSCustomObject]@{ Name = $name; FullName = $_.FullName; Type = $lt; LastWriteTime = $_.LastWriteTime }
    }
}

# 4. Kernel Lock & Safe Mode Readiness Checks
Write-Step '4. 迁移防锁检查 (CldFlt 云文件驱动 / BitLocker / 内置 Administrator / ARSO)'

# 4a. Built-in Administrator
$builtInAdmin = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -like '*-500' } | Select-Object -First 1
if ($builtInAdmin) {
    if ($builtInAdmin.Enabled) {
        Write-Warn "内置管理员账户 [$($builtInAdmin.Name)] 当前为 [已启用] 状态（迁移完成后请务必禁用以恢复安全基线）。"
    } else {
        Write-Info "内置管理员账户 [$($builtInAdmin.Name)] 当前为 [已禁用]（迁移前需临时启用并设置密码：net user $($builtInAdmin.Name) /active:yes）。"
    }
}

# 4b. BitLocker
$bl = Get-BitLockerStatus -DriveLetter 'C:'
switch ($bl.Status) {
    'On' {
        Write-Warn "检测到 C: 盘已开启 BitLocker / 设备加密（来源: $($bl.Source)，状态: $($bl.ConversionStatus)）！进入安全模式前务必先备好 48 位恢复密钥（https://aka.ms/myrecoverykey），或在「设置 -> 隐私和安全性 -> 设备加密」关闭 / 专业版临时暂停保护 (Suspend-BitLocker)。"
    }
    'EncryptedProtectionOff' {
        $pctText = if ($null -ne $bl.EncryptionPercentage) { "，加密进度: $($bl.EncryptionPercentage)%" } else { '' }
        Write-Warn "检测到 C: 盘存在加密数据或正在转换（来源: $($bl.Source)，状态: $($bl.ConversionStatus)$pctText），虽保护当前关闭/暂停，进入安全模式前仍请在「设置 -> 隐私和安全性 -> 设备加密」核实，若正在加/解密请等待完成，并备好 48 位恢复密钥。"
    }
    'Off' {
        Write-Ok "C: 盘未开启 BitLocker / 设备加密（来源: $($bl.Source)，已完全解密，进入安全模式不会触发恢复密钥拦截）。"
    }
    default {
        if ($isAdmin) {
            Write-Warn "未能自动确认 C: 盘 BitLocker / 设备加密状态（请勿默认未开启！）：$($bl.Raw)"
            Write-Warn '进入安全模式前请务必手动打开「设置 -> 隐私和安全性 -> 设备加密」或运行 manage-bde -status C: 亲眼核实。'
        } else {
            Write-Info '未检测 BitLocker / 设备加密（需管理员权限读取 WMI/manage-bde；也可手动打开「设置 -> 隐私和安全性 -> 设备加密」确认）。'
        }
    }
}

# 4c. Kernel Filter Drivers (CldFlt, AV)
$drivers = @()
if ($isAdmin) {
    $drivers = @(Get-VolumeFilterDrivers -Volume 'C:')
    if ($drivers -contains 'CldFlt') {
        Write-Warn '检测到 C: 卷已加载 OneDrive 云文件内核驱动 [CldFlt]！普通模式下重命名用户目录极易报 Access Denied，强烈建议进入「安全模式 (按 4)」执行迁移！'
    } else {
        Write-Ok '当前 C: 卷未检测到 CldFlt 内核锁。'
    }
    $knownAv = $drivers | Where-Object { $_ -in @('sysdiag','WdFilter','klif','avgSnx','avast','360FsFlt','QMPersonalCenter') }
    if ($knownAv) {
        Write-Warn "检测到安全/杀软内核过滤驱动: $($knownAv -join ', ')（若普通模式重命名被拒，进安全模式即可绕过）。"
    }
} else {
    Write-Info '跳过 fltmc 内核驱动检测（需管理员权限）。'
}

# 4d. SyncRootManager
$syncRoots = @()
$srmRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager'
if (Test-Path $srmRoot) {
    Get-ChildItem -Path $srmRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $providerName = $_.PSChildName
        $usrKey = Join-Path -Path $_.PSPath -ChildPath 'UserSyncRoots'
        if (Test-Path $usrKey) {
            $props = Get-ItemProperty -LiteralPath $usrKey -ErrorAction SilentlyContinue
            if ($props) {
                $props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
                    $valStr = [string]$_.Value
                    $syncRoots += [PSCustomObject]@{ Provider = $providerName; SID = $_.Name; Path = $valStr }
                    if (Test-HasNonAscii $valStr) {
                        Write-Warn "SyncRootManager 存在非 ASCII 同步根: $valStr（迁移后需由阶段 4 脚本修正）"
                    }
                }
            }
        }
    }
}

# 4e. ARSO
$arsoPolicy = Get-RegistryValueSafe -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'DisableAutomaticRestartSignOn'
if ($null -ne $arsoPolicy -and [int]$arsoPolicy -eq 1) {
    Write-Ok 'Win11 自动重启登录 (ARSO) 已通过策略禁用。'
} else {
    Write-Warn 'Win11 默认启用 ARSO：切换到管理员账户前，务必先「注销」原账户，再「重启」（切勿直接点重启或切换用户）。'
}

# 5. Current User High-Risk Residuals (WSL2, Env, Shell Folders, Run)
Write-Step '5. 当前登录账户高危关联项扫描 (WSL2 / 环境变量 / Shell Folders / 自启动)'

# 5a. WSL2 Lxss BasePath
$wslIssues = @()
$lxssRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
if (Test-Path $lxssRoot) {
    Get-ChildItem -Path $lxssRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $distroName = Get-RegistryValueSafe -Path $_.PSPath -Name 'DistributionName'
        $basePath   = Get-RegistryValueSafe -Path $_.PSPath -Name 'BasePath'
        if ($basePath) {
            $nonAscii = Test-HasNonAscii ([string]$basePath)
            if ($nonAscii) {
                Write-Err "WSL2 发行版 [$distroName] BasePath 含非 ASCII 路径: $basePath"
                Write-Warn '  -> Hyper-V 不支持经由 Junction 挂载 ext4.vhdx！迁移后切回日常账户必须先跑阶段 4 脚本修正 BasePath，再启动 WSL！'
                $wslIssues += [PSCustomObject]@{ Name = $distroName; Guid = $_.PSChildName; BasePath = $basePath }
            } else {
                Write-Ok "WSL2 发行版 [$distroName] BasePath 为纯英文: $basePath"
            }
        }
    }
} else {
    Write-Info '当前用户未检测到 WSL 发行版注册表项。'
}

# 5b. HKCU\Environment (inspect each semicolon-separated segment to avoid false positives on unrelated D:\ paths)
$envIssues = @()
$envReg = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
if ($envReg) {
    foreach ($n in ($envReg.GetValueNames() | Sort-Object)) {
        $v = $envReg.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($v -is [string]) {
            $badSegments = @($v -split ';' | Where-Object {
                ($_ -match '[A-Za-z]:\\Users\\') -and (Test-HasNonAscii $_)
            })
            if ($badSegments.Count -gt 0) {
                $envIssues += [PSCustomObject]@{ Name = $n; BadSegments = $badSegments }
                Write-Warn "用户环境变量 [$n] 含非 ASCII 用户路径: $($badSegments -join ' ; ')"
            }
        }
    }
    $envReg.Close()
}
if ($envIssues.Count -eq 0) {
    Write-Ok 'HKCU\Environment 未发现含非 ASCII 的 C:\Users 路径残留。'
}

# 5c. User Shell Folders & Shell Folders
$shellIssues = 0
foreach ($sub in @(
    'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
    'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
)) {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub)
    if ($k) {
        foreach ($n in $k.GetValueNames()) {
            $v = $k.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($v -is [string] -and (Test-HasNonAscii $v) -and ($v -match '[A-Za-z]:\\Users\\')) {
                $shellIssues++
            }
        }
        $k.Close()
    }
}
if ($shellIssues -gt 0) {
    Write-Warn "Explorer Shell Folders / User Shell Folders 检测到 $shellIssues 条含非 ASCII 的绝对用户路径（阶段 4 脚本可一键修复）。"
} else {
    Write-Ok 'Explorer Shell Folders / User Shell Folders 未发现非 ASCII 绝对路径残留。'
}

# 5d. HKCU Run
$runIssues = 0
$runKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Run')
if ($runKey) {
    foreach ($n in $runKey.GetValueNames()) {
        $v = $runKey.GetValue($n)
        if ($v -is [string] -and (Test-HasNonAscii $v) -and ($v -match '[A-Za-z]:\\Users\\')) {
            $runIssues++
            Write-Warn "开机自启动 [$n] 含非 ASCII 用户路径: $v"
        }
    }
    $runKey.Close()
}
if ($runIssues -eq 0) {
    Write-Ok 'HKCU\...\Run 未发现非 ASCII 用户路径启动项。'
}

# Summary
Write-Step '体检总结'
if ($needFixProfiles.Count -gt 0) {
    Write-Warn "发现 $($needFixProfiles.Count) 个需要修复的用户配置文件。建议按顺序执行："
    Write-Host '  1. 运行 02-Backup-BeforeMigrate.ps1（创建系统还原点与注册表备份，务必存放到 C:\Users 之外的盘符，如 D:\）' -ForegroundColor White
    Write-Host '  2. 启用内置 Administrator 或使用另一管理员账户，先注销日常账户 -> 按住 Shift 重启进「安全模式 (4)」' -ForegroundColor White
    Write-Host '  3. 在安全模式管理员账户下运行 03-Migrate-UserProfile.ps1（建议先加 -DryRun 预检）' -ForegroundColor White
    Write-Host '  4. 重启回到日常账户，先别启动 WSL，立即运行 04-PostMigrate-Cleanup.ps1 完成收尾' -ForegroundColor White
} else {
    Write-Ok '未检测到需要目录级迁移的非 ASCII 用户配置（如需清理历史残留或乱码目录，可继续使用阶段 4 / 阶段 5 脚本）。'
}

if ($ExportReportPath) {
    $report = [PSCustomObject]@{
        GeneratedAt     = (Get-Date).ToString('o')
        OS              = $osLabel
        CodePage        = $cp
        Profiles        = $profiles
        SuspiciousDirs  = $suspiciousDirs
        BitLockerC      = $bl
        FilterDriversC  = $drivers
        WslIssues       = $wslIssues
        EnvIssues       = $envIssues
        ShellIssueCount = $shellIssues
        RunIssueCount   = $runIssues
    }
    $dir = Split-Path -Path $ExportReportPath -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ExportReportPath -Encoding UTF8
    Write-Ok "体检报告已导出至: $ExportReportPath"
}

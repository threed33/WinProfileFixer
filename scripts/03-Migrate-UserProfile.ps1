#Requires -Version 5.1
<#
.SYNOPSIS
    [阶段 3 - 核心迁移/翻转] 无损将中文/非 ASCII 用户目录转换为纯英文物理实体目录。
.DESCRIPTION
    自动识别并支持两种常见拓扑：
      - Mode = Standard : 物理目录是 C:\Users\<中文名>，ProfileImagePath 也指向它，且新英文名尚不存在。
                          动作：原子重命名实体 -> 更新 ProfileImagePath -> 建立 <中文名> 兜底 Junction。
      - Mode = Flip     : 此前误用了“反向联接教程”（C:\Users\<英文名> 是 Junction -> C:\Users\<中文名> 实体，
                          且 ProfileImagePath 已指向英文名）。
                          动作：先改实体测锁 -> 删除悬空旧 Junction -> 实体落位纯英文 -> 建立 <中文名> 兜底 Junction。

    安全设计原则：
      1) 必须在「另一个管理员账户」（如内置 Administrator）下运行，强烈建议进入「安全模式 (按 4)」绕开 CldFlt/杀软锁。
      2) 8 项前置守卫全部通过才允许改动任何文件。
      3) 遵循「先原子移动实体目录到临时名」测锁：若存在文件/驱动占用，在尚未删除任何联接、未改注册表前直接中止，保证零改动。
      4) 全程使用 .NET / Win32 原生 UTF-16 Unicode API，100% 免疫 GBK/UTF-8 编码问题，0 字节拷贝，完整保留 NTFS ACL。
.PARAMETER TargetSid
    待迁移账户的 SID（如 S-1-5-21-...-1002）。不填则自动扫描并交互式选择。
.PARAMETER NewEnglishName
    目标纯英文目录名（仅文件夹名，如 Alex）。Flip 模式下自动继承现有 ProfileImagePath 目录名。
.PARAMETER NoCompatJunction
    可选：迁移后不创建 C:\Users\<旧中文名> -> C:\Users\<新英文名> 的向后兼容兜底联接。
.PARAMETER DryRun
    预检演练模式：只执行全部前置守卫与方案展示，不修改任何文件或注册表。
.PARAMETER LogPath
    运行日志保存路径（默认保存在脚本所在目录的 logs\migrate_<时间戳>.log）。
.EXAMPLE
    .\03-Migrate-UserProfile.ps1 -DryRun
.EXAMPLE
    .\03-Migrate-UserProfile.ps1 -TargetSid S-1-5-21-xxx-1002 -NewEnglishName Alex -DryRun
.EXAMPLE
    .\03-Migrate-UserProfile.ps1 -TargetSid S-1-5-21-xxx-1002 -NewEnglishName Alex
#>
[CmdletBinding()]
param(
    [string]$TargetSid = '',
    [string]$NewEnglishName = '',
    [switch]$NoCompatJunction,
    [switch]$DryRun,
    [string]$LogPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'common') -ChildPath 'ProfileFixer.Common.psm1'
Import-Module $modulePath -Force

# Prepare transcript log outside C:\Users if possible
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $logDir = Join-Path -Path $repoRoot -ChildPath 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $LogPath = Join-Path -Path $logDir -ChildPath ("migrate_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
try { Start-Transcript -Path $LogPath -Append | Out-Null } catch {}

function Exit-Safely {
    param([int]$Code)
    try { Stop-Transcript | Out-Null } catch {}
    exit $Code
}

Write-Banner -Title 'WinProfileFixer :: 阶段 3 - 用户目录无损迁移 / 联接方向安全翻转' -Subtitle '支持 Standard 标准改名 与 Flip 反向联接翻转双模式 · 0 字节拷贝'

$safeBoot = Get-SafeBootMode
if ($safeBoot -gt 0) {
    Write-Ok "当前运行于 Windows 安全模式 (SafeBoot=$safeBoot)，CldFlt 云文件锁与第三方杀软驱动已自动跳过。"
} else {
    Write-Warn '当前运行于正常模式：若存在 OneDrive (CldFlt) 或杀软过滤驱动，可能触发 Access Denied。'
    Write-Info '脚本在正常模式下会尝试临时分离 CldFlt；如仍被拦截，将零改动退出，建议按指南进入「安全模式 (按 4)」一次通过。'
}

if ($DryRun) {
    Write-Warn '当前为 -DryRun 预检模式：仅做只读守卫检查，绝不修改任何文件或注册表。'
}

# 1. Discover target profile
Write-Step '定位待迁移的用户配置文件'
$inventory = @(Get-UserProfileInventory)
$targetProfile = $null

if ([string]::IsNullOrWhiteSpace($TargetSid)) {
    $candidates = @($inventory | Where-Object { $_.Topology -in @('StandardNonAsciiPhysical', 'ReverseJunctionToNonAscii') })
    if ($candidates.Count -eq 0) {
        Write-Warn '未自动发现处于 StandardNonAsciiPhysical 或 ReverseJunctionToNonAscii 状态的用户配置。'
        Write-Info '以下是本机全部 ProfileList 列表：'
        $inventory | Select-Object Account, SID, ProfileImagePath, FinalPath, Topology | Format-Table -AutoSize
        Write-Info '如确需对特定 SID 执行，请通过 -TargetSid 参数显式指定。'
        Exit-Safely 1
    }
    if ($candidates.Count -eq 1) {
        $targetProfile = $candidates[0]
        Write-Ok "已自动锁定唯一待修复配置: $($targetProfile.Account) ($($targetProfile.SID))"
    } else {
        Write-Host '发现多个待修复配置，请选择序号：' -ForegroundColor White
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $c = $candidates[$i]
            Write-Host ("  [{0}] {1} | SID={2} | Mode={3} | Path={4} -> Real={5}" -f ($i + 1), $c.Account, $c.SID, $c.Topology, $c.ProfileImagePath, $c.FinalPath)
        }
        $sel = Read-Host '请输入序号 (1..N)'
        $idx = 0
        if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $candidates.Count) {
            Write-Err '输入序号无效，已取消。'
            Exit-Safely 1
        }
        $targetProfile = $candidates[$idx - 1]
    }
    $TargetSid = $targetProfile.SID
} else {
    $targetProfile = $inventory | Where-Object { $_.SID -eq $TargetSid } | Select-Object -First 1
    if ($null -eq $targetProfile) {
        Write-Err "在 ProfileList 中找不到指定的 SID: $TargetSid"
        Exit-Safely 1
    }
}

# Determine Mode, OldPath, NewPath
$mode = ''
$oldPath = ''
$newPath = ''
$usersParent = ''

if ($targetProfile.Topology -eq 'ReverseJunctionToNonAscii') {
    $mode = 'Flip'
    $newPath = Resolve-NormalizedPath $targetProfile.ProfileImagePath
    $oldPath = Resolve-NormalizedPath $targetProfile.LinkTarget
    $usersParent = Split-Path -Path $newPath -Parent
    $detectedEnName = Split-Path -Path $newPath -Leaf
    if ([string]::IsNullOrWhiteSpace($NewEnglishName)) {
        $NewEnglishName = $detectedEnName
    } elseif (-not $NewEnglishName.Equals($detectedEnName, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Err "Flip 模式下 ProfileImagePath 已指向 [$detectedEnName]，与传入的 -NewEnglishName [$NewEnglishName] 不一致！请留空或传入 [$detectedEnName]。"
        Exit-Safely 1
    }
    Write-Ok "自动识别模式: [Flip - 反向联接安全翻转] ($oldPath [实体] <-> $newPath [Junction])"
} elseif ($targetProfile.Topology -eq 'StandardNonAsciiPhysical') {
    $mode = 'Standard'
    $oldPath = Resolve-NormalizedPath $targetProfile.ProfileImagePath
    $usersParent = Split-Path -Path $oldPath -Parent
    if ([string]::IsNullOrWhiteSpace($NewEnglishName)) {
        Write-Host "`n当前中文实体目录: $oldPath" -ForegroundColor White
        $NewEnglishName = (Read-Host '请输入新的纯英文目录名（例如 Alex，禁止空格与中文）').Trim()
    }
    $newPath = Join-Path -Path $usersParent -ChildPath $NewEnglishName
    Write-Ok "自动识别模式: [Standard - 标准无损改名] ($oldPath -> $newPath)"
} else {
    Write-Err "目标配置 [$($targetProfile.Account)] 当前拓扑为 [$($targetProfile.Topology)]，不属于可自动迁移状态。"
    Write-Info "ProfileImagePath=$($targetProfile.ProfileImagePath) | FinalPath=$($targetProfile.FinalPath)"
    Exit-Safely 1
}

$tmpName = "${NewEnglishName}_RENAMING_TMP"
$tmpPath = Join-Path -Path $usersParent -ChildPath $tmpName
$profRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$TargetSid"
$volumeDrive = $oldPath.Substring(0, 2)

# 2. Run 8 Pre-Flight Safety Guards
Write-Step '执行 8 项前置安全守卫检查'
$failedGuards = New-Object System.Collections.Generic.List[string]

# Guard 1: Admin
if (Test-IsAdministrator) {
    Write-Ok '守卫 1/8：当前进程已具备管理员权限'
} else {
    Write-Err '守卫 1/8：未以管理员身份运行！请右键「以管理员身份运行」'
    $failedGuards.Add('Guard1_NotAdmin')
}

# Guard 2: Script & CWD must NOT reside inside target profile paths
$scriptDirNorm = Resolve-NormalizedPath $PSScriptRoot
$cwdNorm = Resolve-NormalizedPath (Get-Location).Path
$insideTarget = (
    $scriptDirNorm.StartsWith($oldPath, [System.StringComparison]::OrdinalIgnoreCase) -or
    $scriptDirNorm.StartsWith($newPath, [System.StringComparison]::OrdinalIgnoreCase) -or
    $cwdNorm.StartsWith($oldPath, [System.StringComparison]::OrdinalIgnoreCase) -or
    $cwdNorm.StartsWith($newPath, [System.StringComparison]::OrdinalIgnoreCase)
)
if (-not $insideTarget) {
    Write-Ok "守卫 2/8：脚本路径与工作目录位于目标用户目录之外 ($scriptDirNorm)"
} else {
    Write-Err "守卫 2/8：脚本或当前工作目录位于待迁移用户目录内！请把整个 WinProfileFixer 移至 D:\WinProfileFixer 等 C:\Users 之外的路径。"
    $failedGuards.Add('Guard2_InsideTargetDir')
}

# Guard 3: Current logged-in user != TargetSid
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($currentIdentity.User.Value -ne $TargetSid) {
    Write-Ok "守卫 3/8：当前操作账户为 $($currentIdentity.Name) (非待迁移目标账户 $($targetProfile.Account))"
} else {
    Write-Err "守卫 3/8：当前仍登录在待迁移账户 $($currentIdentity.Name) 下！必须先注销该账户，再切换/重启至另一个管理员账户运行！"
    $failedGuards.Add('Guard3_SameUser')
}

# Guard 4: Target user registry hive (NTUSER.DAT) must NOT be loaded
if (-not (Test-Path "Registry::HKEY_USERS\$TargetSid")) {
    Write-Ok '守卫 4/8：目标用户的注册表配置单元 (NTUSER.DAT) 未加载，无会话锁'
} else {
    Write-Err '守卫 4/8：检测到目标用户的 NTUSER.DAT 仍处于加载状态！'
    Write-Warn '常见原因：(1) 用了「切换用户」而非「注销」；(2) Win11 ARSO 重启自动预登录。'
    Write-Warn '解决方法：切回锁屏先确认目标账户已注销，再按住 Shift 点重启进入安全模式登录 Administrator。'
    $failedGuards.Add('Guard4_HiveLoaded')
}

# Guard 5: Validate new English name
$nameCheck = Test-ValidAsciiProfileName -Name $NewEnglishName
if ($nameCheck.Valid) {
    Write-Ok "守卫 5/8：目标英文目录名 [$NewEnglishName] 合法（纯 ASCII，无空格与保留字）"
} else {
    Write-Err "守卫 5/8：目标英文目录名 [$NewEnglishName] 不合法：$($nameCheck.Reason)"
    $failedGuards.Add('Guard5_InvalidNewName')
}

# Guard 6: Old physical dir must be a REAL directory containing NTUSER.DAT
$oldItem = Get-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
$oldIsReal = ($null -ne $oldItem) -and (-not ($oldItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) -and (Test-Path -LiteralPath (Join-Path -Path $oldPath -ChildPath 'NTUSER.DAT'))
if ($oldIsReal) {
    Write-Ok "守卫 6/8：源目录 $oldPath 确认为物理实体目录，且包含 NTUSER.DAT"
} else {
    Write-Err "守卫 6/8：源目录 $oldPath 不是包含 NTUSER.DAT 的物理实体目录！"
    $failedGuards.Add('Guard6_OldNotReal')
}

# Guard 7: Target path & ProfileImagePath consistency per mode
$profVal = Resolve-NormalizedPath (Get-RegistryValueSafe -Path $profRegPath -Name 'ProfileImagePath')
if ($mode -eq 'Flip') {
    $newItem = Get-Item -LiteralPath $newPath -Force -ErrorAction SilentlyContinue
    $newIsExpectedJunction = (
        ($null -ne $newItem) -and
        ($newItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
        ($newItem.LinkType -eq 'Junction') -and
        ((Get-FirstLinkTarget $newItem).Equals($oldPath, [System.StringComparison]::OrdinalIgnoreCase))
    )
    if ($newIsExpectedJunction -and $profVal.Equals($newPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Ok "守卫 7/8：[Flip 校验] $newPath 确认为指向 $oldPath 的 Junction，且 ProfileImagePath 已指向 $newPath"
    } else {
        Write-Err "守卫 7/8：[Flip 校验失败] newIsExpectedJunction=$newIsExpectedJunction, ProfileImagePath=[$profVal]"
        $failedGuards.Add('Guard7_FlipMismatch')
    }
} else {
    $newNotExists = -not (Test-Path -LiteralPath $newPath)
    if ($newNotExists -and $profVal.Equals($oldPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Ok "守卫 7/8：[Standard 校验] $newPath 空闲可用，且 ProfileImagePath 当前指向 $oldPath"
    } else {
        Write-Err "守卫 7/8：[Standard 校验失败] $newPath 已存在或 ProfileImagePath=[$profVal] 与 [$oldPath] 不一致！"
        $failedGuards.Add('Guard7_StandardMismatch')
    }
}

# Guard 8: Staging tmp path must not exist
if (-not (Test-Path -LiteralPath $tmpPath)) {
    Write-Ok "守卫 8/8：原子临时中转路径 $tmpPath 空闲"
} else {
    Write-Err "守卫 8/8：临时路径 $tmpPath 已存在！请先核查历史操作残留，避免覆盖数据。"
    $failedGuards.Add('Guard8_TmpExists')
}

if ($failedGuards.Count -gt 0) {
    Write-Host ''
    Write-Err "前置守卫未通过（$($failedGuards -join ', ')），脚本已安全退出，未改动任何文件或注册表。"
    Write-Info "日志路径: $LogPath"
    Exit-Safely 1
}

if ($DryRun) {
    Write-Host ''
    Write-Ok 'DryRun 全部 8 项前置守卫通过！你可以去掉 -DryRun 参数正式执行迁移。'
    Write-Info "日志路径: $LogPath"
    Exit-Safely 0
}

# 3. Display execution plan & require explicit confirmation
Write-Step "即将执行的原子操作计划 (模式: $mode)"
Write-Host "  目标账户       : $($targetProfile.Account) ($TargetSid)" -ForegroundColor White
Write-Host "  1. 测锁中转    : $oldPath  -->  $tmpPath  (若被锁定立刻中止，零改动)" -ForegroundColor White
if ($mode -eq 'Flip') {
    Write-Host "  2. 摘除旧壳    : 仅删除已悬空的 Junction 壳子 $newPath (绝不触碰文件)" -ForegroundColor White
    Write-Host "  3. 实体落位    : $tmpPath  -->  $newPath  (纯英文物理真身，0 字节拷贝)" -ForegroundColor White
} else {
    Write-Host "  2. 实体落位    : $tmpPath  -->  $newPath  (纯英文物理真身，0 字节拷贝)" -ForegroundColor White
    Write-Host "  3. 更新注册表  : ProfileImagePath  -->  $newPath" -ForegroundColor White
}
if ($NoCompatJunction) {
    Write-Host '  4. 兜底联接    : [已按参数跳过] 不创建旧路径向后兼容联接' -ForegroundColor Yellow
} else {
    Write-Host "  4. 兜底联接    : $oldPath [Junction]  -->  $newPath" -ForegroundColor White
}
Write-Host ''

$confirm = Read-Host '确认无误并立即执行？请输入大写 YES 回车（其他任意内容取消）'
if ($confirm -cne 'YES') {
    Write-Warn '用户已取消操作，未改动任何文件。'
    Exit-Safely 0
}

# 4. Execute atomic state machine with automatic rollback
$detachedCldFlt = $false
$stoppedWSearch = $false
$step1MovedToTmp = $false
$step2DeletedOldJunction = $false
$step3MovedToNew = $false
$step4RegUpdated = $false
$origRegValue = $null
$origRegKind = [Microsoft.Win32.RegistryValueKind]::ExpandString

try {
    # Pre-step: if normal mode and CldFlt attached to target volume, temporarily detach
    if ($safeBoot -eq 0) {
        $activeDrivers = @(Get-VolumeFilterDrivers -Volume $volumeDrive)
        if ($activeDrivers -contains 'CldFlt') {
            Write-Step "检测到 $volumeDrive 卷挂载了 OneDrive 云文件内核锁 (CldFlt)，尝试临时分离..."
            $detachOut = (& fltmc.exe detach CldFlt $volumeDrive 2>&1 | Out-String)
            if ($LASTEXITCODE -eq 0) {
                $detachedCldFlt = $true
                Write-Ok "已临时分离 CldFlt（结束后自动重新挂载）。"
            } else {
                Write-Warn "临时分离 CldFlt 未成功：$($detachOut.Trim())，继续尝试重命名..."
            }
        }
    }

    # Step 1: Atomic Move Old -> Tmp (lock probe BEFORE touching anything else!)
    Write-Step "步骤 1：原子重命名实体目录 $oldPath -> $tmpPath"
    try {
        [System.IO.Directory]::Move($oldPath, $tmpPath)
    } catch {
        Write-Warn "首次移动被拦截 ($($_.Exception.Message))，尝试暂时停止 Windows Search (WSearch) 后重试一次..."
        $ws = Get-Service -Name 'WSearch' -ErrorAction SilentlyContinue
        if ($ws -and $ws.Status -eq 'Running') {
            Stop-Service -Name 'WSearch' -Force -ErrorAction SilentlyContinue
            $stoppedWSearch = $true
            Start-Sleep -Seconds 2
        }
        [System.IO.Directory]::Move($oldPath, $tmpPath)
    }
    $step1MovedToTmp = $true
    Write-Ok '步骤 1 完成（证实目录零锁定！）'

    # Step 2 (Flip mode only): remove now-dangling Junction shell
    if ($mode -eq 'Flip') {
        Write-Step "步骤 2：删除已悬空的旧 Junction 壳子 $newPath"
        $recheck = Get-Item -LiteralPath $newPath -Force
        if (-not ($recheck.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "安全拦截：$newPath 不再是 ReparsePoint，拒绝删除！"
        }
        [System.IO.Directory]::Delete($newPath, $false)
        $step2DeletedOldJunction = $true
        Write-Ok '步骤 2 完成（仅移除联接指针，未触碰实体数据）'
    }

    # Step 3: Move physical dir from Tmp -> New
    Write-Step "步骤 3：实体目录原子落位 $tmpPath -> $newPath"
    [System.IO.Directory]::Move($tmpPath, $newPath)
    $step3MovedToNew = $true
    Write-Ok "步骤 3 完成（$newPath 已成为真正的纯英文物理实体目录！）"

    # Step 4a (Standard mode only): update ProfileImagePath preserving original ValueKind
    if ($mode -eq 'Standard') {
        Write-Step "步骤 4a：更新注册表 ProfileImagePath -> $newPath"
        $rk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$TargetSid", $true)
        try {
            $origRegValue = $rk.GetValue('ProfileImagePath', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $origRegKind  = $rk.GetValueKind('ProfileImagePath')
            $rk.SetValue('ProfileImagePath', $newPath, $origRegKind)
            $step4RegUpdated = $true
        } finally {
            if ($rk) { $rk.Close() }
        }
        Write-Ok "步骤 4a 完成（原值 [$origRegValue]，类型 $origRegKind）"
    }

    # Step 4b: Create backward-compat Junction Old -> New
    if (-not $NoCompatJunction) {
        Write-Step "步骤 4b：创建向后兼容兜底联接 $oldPath [Junction] -> $newPath"
        New-Item -ItemType Junction -Path $oldPath -Target $newPath | Out-Null
        Write-Ok '步骤 4b 完成'
    }
} catch {
    Write-Err "执行过程出错：$($_.Exception.Message)"
    if (-not $step1MovedToTmp) {
        Write-Ok '由于出错发生在步骤 1 测锁阶段，原目录、联接与注册表均完好无损（零改动）！'
        Write-Warn "当前挂载在 $volumeDrive 卷的内核过滤驱动："
        & fltmc.exe instances -v $volumeDrive 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($safeBoot -eq 0) {
            Write-Warn '强烈建议：按住 Shift 点重启 -> 疑难解答 -> 高级选项 -> 启动设置 -> 重启 -> 按 4 进入「安全模式」登录管理员后重跑本脚本！'
        }
    } else {
        Write-Warn '正在执行自动安全回滚...'
        try {
            if ($step4RegUpdated -and $null -ne $origRegValue) {
                $rkRb = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$TargetSid", $true)
                try { $rkRb.SetValue('ProfileImagePath', $origRegValue, $origRegKind) } finally { if ($rkRb) { $rkRb.Close() } }
                Write-Ok "已回滚注册表 ProfileImagePath -> $origRegValue"
            }
            if ($step3MovedToNew -and (Test-Path -LiteralPath $newPath) -and -not (Test-IsReparsePoint $newPath) -and -not (Test-Path -LiteralPath $oldPath)) {
                [System.IO.Directory]::Move($newPath, $oldPath)
                Write-Ok "已回滚目录：$newPath -> $oldPath"
            } elseif ($step1MovedToTmp -and -not $step3MovedToNew -and (Test-Path -LiteralPath $tmpPath) -and -not (Test-Path -LiteralPath $oldPath)) {
                [System.IO.Directory]::Move($tmpPath, $oldPath)
                Write-Ok "已回滚目录：$tmpPath -> $oldPath"
            }
            if ($mode -eq 'Flip' -and $step2DeletedOldJunction -and -not (Test-Path -LiteralPath $newPath) -and (Test-Path -LiteralPath $oldPath)) {
                New-Item -ItemType Junction -Path $newPath -Target $oldPath | Out-Null
                Write-Ok "已恢复原 Junction：$newPath -> $oldPath"
            }
        } catch {
            Write-Err "自动回滚遇到异常：$($_.Exception.Message)"
            Write-Warn "请勿重启电脑！检查 $usersParent 目录状态并查阅日志 $LogPath 后手动恢复。"
        }
    }
    Exit-Safely 1
} finally {
    if ($detachedCldFlt) {
        & fltmc.exe attach CldFlt $volumeDrive 2>&1 | Out-Null
    }
    if ($stoppedWSearch) {
        Start-Service -Name 'WSearch' -ErrorAction SilentlyContinue
    }
}

# 5. Post-Migration 4-Point Hardcore Verification
Write-Step '执行迁移后 4 项硬核验收'
$allGood = $true

$newAfter = Get-Item -LiteralPath $newPath -Force -ErrorAction SilentlyContinue
$ntUserOk = Test-Path -LiteralPath (Join-Path -Path $newPath -ChildPath 'NTUSER.DAT')
if ($newAfter -and (-not ($newAfter.Attributes -band [IO.FileAttributes]::ReparsePoint)) -and $ntUserOk) {
    Write-Ok "验收 1/4：$newPath 已是物理实体目录，且 NTUSER.DAT 完好"
} else {
    Write-Err "验收 1/4 异常：$newPath 状态不对！"
    $allGood = $false
}

$profAfter = Resolve-NormalizedPath (Get-RegistryValueSafe -Path $profRegPath -Name 'ProfileImagePath')
if ($profAfter.Equals($newPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Ok "验收 2/4：注册表 ProfileImagePath 已指向 $profAfter"
} else {
    Write-Err "验收 2/4 异常：ProfileImagePath=[$profAfter] != [$newPath]"
    $allGood = $false
}

$finalNew = Get-FinalPath -Path $newPath
$expectedFinal = "\\?\$newPath"
$finalCheckOk = $finalNew.Equals($expectedFinal, [System.StringComparison]::OrdinalIgnoreCase)
if (-not $NoCompatJunction) {
    $oldAfter = Get-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
    $finalOld = Get-FinalPath -Path $oldPath
    $juncOk = ($null -ne $oldAfter) -and ($oldAfter.LinkType -eq 'Junction') -and ((Get-FirstLinkTarget $oldAfter).Equals($newPath, [System.StringComparison]::OrdinalIgnoreCase))
    if ($finalCheckOk -and $juncOk -and $finalOld.Equals($expectedFinal, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Ok "验收 3/4：Win32 GetFinalPathNameByHandleW 对新旧路径均返回纯英文实体：$finalNew"
    } else {
        Write-Err "验收 3/4 异常：juncOk=$juncOk, finalNew=[$finalNew], finalOld=[$finalOld]"
        $allGood = $false
    }
} else {
    if ($finalCheckOk) {
        Write-Ok "验收 3/4：Win32 GetFinalPathNameByHandleW 返回纯英文实体：$finalNew"
    } else {
        Write-Err "验收 3/4 异常：finalNew=[$finalNew]"
        $allGood = $false
    }
}

$aclOut = (& icacls.exe $newPath 2>&1 | Out-String)
$acctShort = ($targetProfile.Account -split '\\')[-1]
if ($aclOut -match [regex]::Escape($acctShort) -or $aclOut -match [regex]::Escape($TargetSid)) {
    Write-Ok "验收 4/4：NTFS ACL 权限完整保留（包含 $($targetProfile.Account)）"
} else {
    Write-Warn "验收 4/4 提示：未在 icacls 输出中匹配到 [$acctShort]，请人工核对下方权限："
    Write-Host $aclOut
}

Write-Host ''
if ($allGood) {
    Write-Host '====================================================================' -ForegroundColor Green
    Write-Host '  迁移与全部验收通过！(0 字节拷贝，数据与权限完整保留)' -ForegroundColor Green
    Write-Host "  下一步：正常重启电脑 -> 登录回日常账户 [$($targetProfile.Account)]" -ForegroundColor Green
    Write-Host '  注意：切回后先别启动 WSL，立即以管理员运行 04-PostMigrate-Cleanup.ps1 收尾！' -ForegroundColor Green
    Write-Host '====================================================================' -ForegroundColor Green
} else {
    Write-Err "部分验收项存在异常，请勿急于关闭管理员账户，先查看日志: $LogPath"
}

Exit-Safely $(if ($allGood) { 0 } else { 1 })

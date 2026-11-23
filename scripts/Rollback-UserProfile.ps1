#Requires -Version 5.1
<#
.SYNOPSIS
    [应急回滚] 将已迁移/已翻转的纯英文用户目录安全回滚到迁移前状态。
.DESCRIPTION
    支持两种对称回滚模式：
      - Flip     : C:\Users\<En>[实体] + C:\Users\<Old>[Junction]  -->  C:\Users\<Old>[实体] + C:\Users\<En>[Junction]
      - Standard : C:\Users\<En>[实体] + ProfileImagePath=<En>     -->  C:\Users\<Old>[实体] + ProfileImagePath=<Old>
    同样必须在「另一个管理员账户」（建议安全模式）下运行，并校验目标用户 NTUSER.DAT 未加载。
.PARAMETER TargetSid
    需要回滚的目标账户 SID。
.PARAMETER OldName
    迁移前的原中文/非 ASCII 目录名（不含 C:\Users\）。
.PARAMETER Mode
    回滚模式：Flip（反向联接翻转回滚）或 Standard（标准改名回滚）。
.EXAMPLE
    .\Rollback-UserProfile.ps1 -TargetSid S-1-5-21-xxx-1002 -OldName "张三" -Mode Flip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetSid,
    [Parameter(Mandatory = $true)][string]$OldName,
    [Parameter(Mandatory = $true)][ValidateSet('Flip', 'Standard')][string]$Mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'common') -ChildPath 'ProfileFixer.Common.psm1'
Import-Module $modulePath -Force

Write-Banner -Title 'WinProfileFixer :: 应急安全回滚脚本' -Subtitle "模式: $Mode | 目标 SID: $TargetSid"

if (-not (Test-IsAdministrator)) {
    Write-Err '请右键以管理员身份运行！'
    exit 1
}
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq $TargetSid) {
    Write-Err '当前登录的就是目标账户！请注销并切换到 Administrator 后再回滚。'
    exit 1
}
if (Test-Path "Registry::HKEY_USERS\$TargetSid") {
    Write-Err '目标账户的 NTUSER.DAT 仍处于加载状态！请先彻底注销并重启进入安全模式 Administrator。'
    exit 1
}

$profReg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$TargetSid"
$newPath = Resolve-NormalizedPath (Get-RegistryValueSafe -Path $profReg -Name 'ProfileImagePath')
if ([string]::IsNullOrWhiteSpace($newPath)) {
    Write-Err "找不到 $profReg 的 ProfileImagePath。"
    exit 1
}

$usersRoot = Split-Path -Path $newPath -Parent
$oldPath   = Join-Path -Path $usersRoot -ChildPath $OldName
$newLeaf   = Split-Path -Path $newPath -Leaf
$tmpPath   = Join-Path -Path $usersRoot -ChildPath "${newLeaf}_ROLLBACK_TMP"

$newItem = Get-Item -LiteralPath $newPath -Force -ErrorAction SilentlyContinue
if (-not $newItem -or ($newItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    Write-Err "$newPath 不是物理实体目录，无法执行回滚。"
    exit 1
}
if (Test-Path -LiteralPath $tmpPath) {
    Write-Err "临时路径 $tmpPath 已存在，请先人工核查。"
    exit 1
}

$oldItem = Get-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue
$hasOldJunction = ($null -ne $oldItem) -and ($oldItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -and ($oldItem.LinkType -eq 'Junction')
if ($null -ne $oldItem -and -not $hasOldJunction) {
    Write-Err "$oldPath 已存在且不是 Junction，拒绝覆盖实体目录！"
    exit 1
}

Write-Host ''
Write-Host "即将把 $newPath [实体] 回滚至 $oldPath [实体] (Mode=$Mode)" -ForegroundColor Yellow
$confirm = Read-Host '确认回滚请输入大写 ROLLBACK 回车（其他任意内容取消）'
if ($confirm -cne 'ROLLBACK') {
    Write-Warn '已取消回滚。'
    exit 0
}

$safeBoot = Get-SafeBootMode
$volumeDrive = $newPath.Substring(0, 2)
$detachedCldFlt = $false

try {
    if ($safeBoot -eq 0 -and ((Get-VolumeFilterDrivers -Volume $volumeDrive) -contains 'CldFlt')) {
        & fltmc.exe detach CldFlt $volumeDrive 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $detachedCldFlt = $true }
    }

    Write-Step "1. 原子测锁移动: $newPath -> $tmpPath"
    [System.IO.Directory]::Move($newPath, $tmpPath)

    if ($hasOldJunction) {
        Write-Step "2. 摘除兜底 Junction: $oldPath"
        [System.IO.Directory]::Delete($oldPath, $false)
    }

    Write-Step "3. 还原实体目录: $tmpPath -> $oldPath"
    [System.IO.Directory]::Move($tmpPath, $oldPath)

    if ($Mode -eq 'Flip') {
        Write-Step "4. 恢复原反向联接: $newPath [Junction] -> $oldPath"
        New-Item -ItemType Junction -Path $newPath -Target $oldPath | Out-Null
    } else {
        Write-Step "4. 恢复注册表 ProfileImagePath -> $oldPath"
        $rk = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$TargetSid", $true)
        try {
            $kind = $rk.GetValueKind('ProfileImagePath')
            $rk.SetValue('ProfileImagePath', $oldPath, $kind)
        } finally {
            if ($rk) { $rk.Close() }
        }
    }

    Write-Ok '已安全回滚到迁移前状态！请重启电脑恢复正常使用。'
} finally {
    if ($detachedCldFlt) {
        & fltmc.exe attach CldFlt $volumeDrive 2>&1 | Out-Null
    }
}

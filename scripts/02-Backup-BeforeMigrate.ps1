#Requires -Version 5.1
<#
.SYNOPSIS
    [阶段 2 - 前置备份] 迁移前创建系统还原点、导出核心注册表并保存 NTFS 权限/重解析点快照。
.DESCRIPTION
    请在「日常账户」下以管理员身份运行本脚本，且务必将 BackupDir 指定在 C:\Users 之外（如 D:\WinProfileBackup），
    以防备份目录本身被锁定或干扰目录重命名。
.PARAMETER BackupDir
    备份存放目录（绝对路径，禁止位于 C:\Users 内）。默认：D:\WinProfileFixer_Backup_<时间戳>（若无 D 盘则使用 C:\WinProfileFixer_Backup_<时间戳>）。
.PARAMETER SkipRestorePoint
    跳过创建 Windows 系统还原点（例如系统还原已关闭时）。
.EXAMPLE
    .\02-Backup-BeforeMigrate.ps1 -BackupDir D:\WinProfileBackup
#>
[CmdletBinding()]
param(
    [string]$BackupDir = '',
    [switch]$SkipRestorePoint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'common') -ChildPath 'ProfileFixer.Common.psm1'
Import-Module $modulePath -Force

Write-Banner -Title 'WinProfileFixer :: 阶段 2 - 迁移前安全备份' -Subtitle '导出注册表 + NTFS ACL 快照 + 系统还原点'

if (-not (Test-IsAdministrator)) {
    Write-Err '请以管理员身份运行本脚本（导出 HKLM 注册表与创建系统还原点需要管理员权限）。'
    exit 1
}

if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $baseDrive = if (Test-Path 'D:\') { 'D:\' } else { 'C:\' }
    $BackupDir = Join-Path -Path $baseDrive -ChildPath "WinProfileFixer_Backup_$ts"
}

$normBackup = Resolve-NormalizedPath $BackupDir
if ($normBackup -match '^[A-Za-z]:\\Users(\\|$)') {
    Write-Err "安全拦截：BackupDir [$normBackup] 不能位于 C:\Users 内部！请改为 D:\WinProfileBackup 或 C:\WinProfileBackup。"
    exit 1
}

New-Item -ItemType Directory -Path $normBackup -Force | Out-Null
Write-Ok "备份目录已就绪: $normBackup"

# 1. Stop WSL cleanly before backup
Write-Step '1. 安全关闭运行中的 WSL 实例'
$wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
if ($wslCmd) {
    try {
        & wsl.exe --shutdown 2>&1 | Out-Null
        Write-Ok '已执行 wsl --shutdown。'
    } catch {
        Write-Warn "执行 wsl --shutdown 时返回提示: $($_.Exception.Message)"
    }
} else {
    Write-Info '本机未安装 WSL，跳过。'
}

# 2. Export critical registry keys
Write-Step '2. 导出关键注册表分支'
$regExports = @(
    @{ Key = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList';              File = 'HKLM_ProfileList.reg' },
    @{ Key = 'HKLM\SOFTWARE\Microsoft\UserManager\Users';                                   File = 'HKLM_UserManager_Users.reg' },
    @{ Key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager';     File = 'HKLM_SyncRootManager.reg' },
    @{ Key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss';                         File = 'HKCU_Lxss.reg' },
    @{ Key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders';  File = 'HKCU_UserShellFolders.reg' },
    @{ Key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders';       File = 'HKCU_ShellFolders.reg' },
    @{ Key = 'HKCU\Environment';                                                            File = 'HKCU_Environment.reg' },
    @{ Key = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';                          File = 'HKCU_Run.reg' },
    @{ Key = 'HKCU\Software\Microsoft\OneDrive\Accounts';                                   File = 'HKCU_OneDrive_Accounts.reg' }
)

foreach ($entry in $regExports) {
    $outPath = Join-Path -Path $normBackup -ChildPath $entry.File
    & reg.exe export $entry.Key $outPath /y 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $outPath)) {
        $size = (Get-Item -LiteralPath $outPath).Length
        Write-Ok "已导出 $($entry.File) ($size bytes)"
    } else {
        Write-Info "跳过不存在的注册表键: $($entry.Key)"
    }
}

# 3. Save filesystem, reparse point, and ACL snapshot
Write-Step '3. 保存 C:\Users 结构、重解析点与 NTFS ACL 快照'
$snapPath = Join-Path -Path $normBackup -ChildPath 'pre_migrate_snapshot.txt'
$snap = New-Object System.Collections.Generic.List[string]
$snap.Add("Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$snap.Add("CurrentUser: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)")
$snap.Add("CurrentSID: $([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)")

$snap.Add("`r`n=== ProfileList Inventory ===")
$inventory = @(Get-UserProfileInventory)
$snap.Add(($inventory | Format-List | Out-String))

$snap.Add("`r`n=== C:\Users Listing ===")
$snap.Add((Get-ChildItem -LiteralPath 'C:\Users' -Force | Select-Object Name, LinkType, Target, Attributes | Format-Table -AutoSize | Out-String))

foreach ($p in $inventory) {
    if ($p.Exists -and $p.ProfileImagePath) {
        $snap.Add("`r`n=== icacls $($p.ProfileImagePath) ===")
        $snap.Add((& icacls.exe $p.ProfileImagePath /L 2>&1 | Out-String))
        if ($p.IsReparsePoint) {
            $snap.Add("--- fsutil reparsepoint query $($p.ProfileImagePath) ---")
            $snap.Add((& fsutil.exe reparsepoint query $p.ProfileImagePath 2>&1 | Out-String))
            if ($p.FinalPath -and (Test-Path -LiteralPath $p.FinalPath)) {
                $snap.Add("--- icacls $($p.FinalPath) ---")
                $snap.Add((& icacls.exe $p.FinalPath 2>&1 | Out-String))
            }
        }
    }
}

$snap.Add("`r`n=== fltmc instances -v C: ===")
$snap.Add((& fltmc.exe instances -v C: 2>&1 | Out-String))

[System.IO.File]::WriteAllText($snapPath, ($snap -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
Write-Ok "已写入快照文件: $snapPath"

# 4. Create System Restore Point
Write-Step '4. 创建 Windows 系统还原点'
if ($SkipRestorePoint) {
    Write-Warn '已按参数跳过创建系统还原点。'
} else {
    try {
        Checkpoint-Computer -Description 'WinProfileFixer_Before_Migration' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Ok '系统还原点 [WinProfileFixer_Before_Migration] 创建成功。'
    } catch {
        Write-Warn "未能创建系统还原点（可能系统保护未开启或 24 小时内已创建过）：$($_.Exception.Message)"
        Write-Info '如需手动开启：Win+R 输入 SystemPropertiesProtection -> 选择 C: 盘 -> 配置 -> 启用系统保护。'
    }
}

# 5. Pre-flight reminder
Write-Step '下一步操作指引'
Write-Host '  1. 确保有一个「不同于待迁移账户」的本地管理员账户可用（例如启用内置 Administrator）：' -ForegroundColor White
Write-Host '       net user Administrator /active:yes' -ForegroundColor Gray
Write-Host '       net user Administrator 你的临时强密码' -ForegroundColor Gray
Write-Host '  2. 如果本机开启了 BitLocker，请先记录 48 位恢复密钥或临时暂停 BitLocker。' -ForegroundColor White
Write-Host '  3. 将本仓库 scripts 文件夹也放在 C:\Users 之外（如 D:\WinProfileFixer），避免脚本自身锁目录。' -ForegroundColor White
Write-Host '  4. 先「注销」日常账户 -> 在登录界面按住 Shift 点「重启」-> 疑难解答 -> 高级选项 -> 启动设置 -> 重启 -> 按 4 进安全模式。' -ForegroundColor White
Write-Host '  5. 在安全模式登录 Administrator，运行 03-Migrate-UserProfile.ps1（强烈建议先加 -DryRun 演练）。' -ForegroundColor White

#Requires -Version 5.1
<#
.SYNOPSIS
    [阶段 4 - 迁移后收尾修复] 修复 WSL2 BasePath、环境变量、Shell Folders、OneDrive/SyncRoot、自启动并验证环境。
.DESCRIPTION
    在阶段 3 完成并重启登录回「日常账户」后，**先不要启动 WSL**，直接以管理员身份运行本脚本！
    它将自动处理目录改名后所有最容易被忽略的硬编码残留：
      1) WSL2 (HKCU\...\Lxss\*\BasePath) —— 防止 Hyper-V 因经由 Junction 挂载 ext4.vhdx 报 Access Denied
      2) HKCU\Environment（Path 及所有自定义变量）—— 严格保留 REG_EXPAND_SZ / REG_SZ 类型并广播 WM_SETTINGCHANGE
      3) Explorer User Shell Folders（规范化为 %USERPROFILE% ExpandString）与旧版 Shell Folders 缓存
      4) OneDrive Personal/Business UserFolder 与 HKLM\...\SyncRootManager 同步根
      5) HKLM\...\UserManager\Users\*\UserPicture 头像路径
      6) HKCU\...\Run 开机自启动项 & 常见开发工具指针文件（如 .lmstudio-home-pointer）
      7) 审计计划任务与系统服务中的旧路径引用
      8) 可选关闭临时启用的内置 Administrator 账户（恢复安全基线）
.PARAMETER OldName
    旧中文/非 ASCII 用户目录名（仅目录名，不含 C:\Users\）。不填则自动检测指向当前 %USERPROFILE% 的兜底 Junction。
.PARAMETER DryRun
    预演模式：仅列出将被修改的注册表和配置项，不写入任何修改。
.PARAMETER DisableBuiltInAdmin
    收尾完成后自动关闭内置 Administrator 账户（SID *-500）。
.PARAMETER SkipWslSmokeTest
    跳过修改后对 WSL 发行版的轻量冒烟测试。
.EXAMPLE
    .\04-PostMigrate-Cleanup.ps1 -DryRun
.EXAMPLE
    .\04-PostMigrate-Cleanup.ps1 -DisableBuiltInAdmin
#>
[CmdletBinding()]
param(
    [string]$OldName = '',
    [switch]$DryRun,
    [switch]$DisableBuiltInAdmin,
    [switch]$SkipWslSmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'common') -ChildPath 'ProfileFixer.Common.psm1'
Import-Module $modulePath -Force

Write-Banner -Title 'WinProfileFixer :: 阶段 4 - 迁移后注册表/WSL2/环境变量全套收尾' -Subtitle '消除所有硬编码旧路径残留 · 验收真身与系统组件'

if ($DryRun) {
    Write-Warn '当前为 -DryRun 预演模式：仅展示将会修复的项目，不会写入任何修改。'
}

$isAdmin = Test-IsAdministrator
if (-not $isAdmin) {
    Write-Warn '当前未以管理员身份运行：HKCU 项可修复，但 SyncRootManager / UserManager / 禁用 Administrator 需要管理员权限。'
}

$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$newPrefix  = Resolve-NormalizedPath $env:USERPROFILE
$usersRoot  = Split-Path -Path $newPrefix -Parent

# Auto-detect OldName from backward-compat Junction pointing to $newPrefix
if ([string]::IsNullOrWhiteSpace($OldName)) {
    $compatJunction = Get-ChildItem -LiteralPath $usersRoot -Force -ErrorAction SilentlyContinue | Where-Object {
        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
        ($_.LinkType -eq 'Junction') -and
        ((Get-FirstLinkTarget $_) -and (Get-FirstLinkTarget $_).Equals($newPrefix, [System.StringComparison]::OrdinalIgnoreCase))
    } | Select-Object -First 1

    if ($compatJunction) {
        $OldName = $compatJunction.Name
        Write-Ok "已自动识别兜底联接对应的旧目录名: [$OldName] -> $newPrefix"
    } else {
        Write-Warn "未自动检测到指向 $newPrefix 的兜底 Junction。"
        $OldName = (Read-Host '请手动输入迁移前的旧目录名（仅目录名，例如 张三）').Trim()
    }
}

if ([string]::IsNullOrWhiteSpace($OldName)) {
    Write-Err '未提供旧目录名，无法执行精确替换。'
    exit 1
}

$oldPrefix = Join-Path -Path $usersRoot -ChildPath $OldName
$escapedOld = [regex]::Escape($oldPrefix)

if ($oldPrefix.Equals($newPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Err "旧路径 [$oldPrefix] 与当前路径 [$newPrefix] 相同，中止执行。"
    exit 1
}

Write-Info "替换规则: [$oldPrefix]  ==>  [$newPrefix]"

# 1. WSL2 Lxss BasePath
Write-Step '1. 检查并修正 WSL2 Lxss BasePath（防 Hyper-V 经 Junction 挂载 VHDX 失败）'
$lxssRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
$wslDistrosFixed = @()
if (Test-Path $lxssRoot) {
    $wslExists = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)
    if ($wslExists -and -not $DryRun) {
        & wsl.exe --shutdown 2>&1 | Out-Null
    }
    Get-ChildItem -Path $lxssRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $distroName = [string](Get-RegistryValueSafe -Path $_.PSPath -Name 'DistributionName')
        $basePath   = [string](Get-RegistryValueSafe -Path $_.PSPath -Name 'BasePath')
        if ($basePath -and ($basePath -match $escapedOld)) {
            $newBase = [regex]::Replace($basePath, $escapedOld, $newPrefix, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($DryRun) {
                Write-Warn "[DryRun] WSL [$distroName]: $basePath -> $newBase"
            } else {
                Set-ItemProperty -LiteralPath $_.PSPath -Name 'BasePath' -Value $newBase
                Write-Ok "已修正 WSL [$distroName] BasePath -> $newBase"
            }
            $wslDistrosFixed += $distroName
        }
    }
    if ($wslDistrosFixed.Count -eq 0) {
        Write-Ok 'WSL2 Lxss BasePath 无需修改（均未含旧路径）。'
    }
} else {
    Write-Info '未检测到 WSL 发行版，跳过。'
}

# 2. HKCU\Environment (preserving ValueKind & unexpanded %VAR%)
Write-Step '2. 修正用户环境变量 (HKCU\Environment) 并广播变更'
$envChanged = 0
$envReg = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', (-not $DryRun))
if ($envReg) {
    try {
        foreach ($varName in ($envReg.GetValueNames() | Sort-Object)) {
            $oldVal = $envReg.GetValue($varName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($oldVal -is [string] -and ($oldVal -match $escapedOld)) {
                $kind = $envReg.GetValueKind($varName)
                $newVal = [regex]::Replace($oldVal, $escapedOld, $newPrefix, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($DryRun) {
                    Write-Warn "[DryRun] Env [$varName] ($kind): 检测到旧路径，将替换为 $newPrefix"
                } else {
                    $envReg.SetValue($varName, $newVal, $kind)
                    Write-Ok "已更新 Env [$varName] ($kind)"
                }
                $envChanged++
            }
        }
    } finally {
        $envReg.Close()
    }
}
if ($envChanged -gt 0 -and -not $DryRun) {
    Send-EnvironmentChangeBroadcast
    Write-Ok '已广播 WM_SETTINGCHANGE (Environment)，新开终端与资源管理器将立即生效。'
} elseif ($envChanged -eq 0) {
    Write-Ok 'HKCU\Environment 无旧路径残留。'
}

# 3. User Shell Folders & legacy Shell Folders
Write-Step '3. 修正 Explorer User Shell Folders 与 Shell Folders'
$usfSub = 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$usfKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($usfSub, (-not $DryRun))
$usfCount = 0
if ($usfKey) {
    try {
        foreach ($n in $usfKey.GetValueNames()) {
            $v = $usfKey.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($v -is [string] -and ($v -match $escapedOld)) {
                $nv = [regex]::Replace($v, $escapedOld, '%USERPROFILE%', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($DryRun) {
                    Write-Warn "[DryRun] User Shell Folders [$n]: $v -> $nv"
                } else {
                    $usfKey.SetValue($n, $nv, [Microsoft.Win32.RegistryValueKind]::ExpandString)
                    Write-Ok "已更新 User Shell Folders [$n] -> $nv"
                }
                $usfCount++
            }
        }
    } finally { $usfKey.Close() }
}

$sfSub = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
$sfKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sfSub, (-not $DryRun))
$sfCount = 0
if ($sfKey) {
    try {
        foreach ($n in $sfKey.GetValueNames()) {
            $v = $sfKey.GetValue($n)
            if ($v -is [string] -and ($v -match $escapedOld)) {
                $nv = [regex]::Replace($v, $escapedOld, $newPrefix, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if (-not $DryRun) {
                    $sfKey.SetValue($n, $nv, $sfKey.GetValueKind($n))
                }
                $sfCount++
            }
        }
    } finally { $sfKey.Close() }
}
if ($DryRun) {
    Write-Info "[DryRun] User Shell Folders 待修 $usfCount 项；旧版 Shell Folders 待修 $sfCount 项。"
} else {
    Write-Ok "User Shell Folders 已修正 $usfCount 项；旧版 Shell Folders 已修正 $sfCount 项。"
}

# 4. OneDrive & HKLM SyncRootManager
Write-Step '4. 修正 OneDrive 账户路径与 SyncRootManager 同步根'
$odRoot = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
if (Test-Path $odRoot) {
    Get-ChildItem -Path $odRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $acctName = $_.PSChildName
        $uf = [string](Get-RegistryValueSafe -Path $_.PSPath -Name 'UserFolder')
        if ($uf -and ($uf -match $escapedOld)) {
            $newUf = [regex]::Replace($uf, $escapedOld, $newPrefix, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($DryRun) {
                Write-Warn "[DryRun] OneDrive [$acctName] UserFolder: $uf -> $newUf"
            } else {
                Set-ItemProperty -LiteralPath $_.PSPath -Name 'UserFolder' -Value $newUf
                Write-Ok "已更新 OneDrive [$acctName] UserFolder -> $newUf"
            }
        }
    }
}

$srmRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager'
if (Test-Path $srmRoot) {
    Get-ChildItem -Path $srmRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $usrPath = Join-Path -Path $_.PSPath -ChildPath 'UserSyncRoots'
        if (Test-Path $usrPath) {
            $srVal = Get-RegistryValueSafe -Path $usrPath -Name $currentSid
            if ($srVal -is [string] -and ($srVal -match $escapedOld)) {
                $newSr = [regex]::Replace($srVal, $escapedOld, $newPrefix, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($DryRun) {
                    Write-Warn "[DryRun] SyncRootManager [$currentSid]: $srVal -> $newSr"
                } elseif ($isAdmin) {
                    Set-ItemProperty -LiteralPath $usrPath -Name $currentSid -Value $newSr
                    Write-Ok "已更新 SyncRootManager -> $newSr"
                } else {
                    Write-Warn "需管理员权限才能更新 SyncRootManager -> $newSr"
                }
            }
        }
    }
}

# 5. HKLM UserManager UserPicture
Write-Step '5. 修正 UserManager 账户头像路径'
$umRoot = 'HKLM:\SOFTWARE\Microsoft\UserManager\Users'
if (Test-Path $umRoot) {
    Get-ChildItem -Path $umRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $umChild = $_.PSChildName
        $up = [string](Get-RegistryValueSafe -Path $_.PSPath -Name 'UserPicture')
        if ($up -and ($up -match $escapedOld)) {
            $newUp = [regex]::Replace($up, $escapedOld, $newPrefix, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($DryRun) {
                Write-Warn "[DryRun] UserManager [$umChild] UserPicture: $up -> $newUp"
            } elseif ($isAdmin) {
                Set-ItemProperty -LiteralPath $_.PSPath -Name 'UserPicture' -Value $newUp
                Write-Ok "已更新 UserManager UserPicture -> $newUp"
            } else {
                Write-Warn "需管理员权限才能更新 UserManager UserPicture -> $newUp"
            }
        }
    }
}

# 6. HKCU Run startup & common pointer files
Write-Step '6. 修正开机自启动项 (HKCU\...\Run) 与工具路径指针文件'
$runSub = 'Software\Microsoft\Windows\CurrentVersion\Run'
$runKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runSub, (-not $DryRun))
$runFixed = 0
if ($runKey) {
    try {
        foreach ($n in $runKey.GetValueNames()) {
            $v = $runKey.GetValue($n)
            if ($v -is [string] -and ($v -match $escapedOld)) {
                $nv = [regex]::Replace($v, $escapedOld, $newPrefix, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($DryRun) {
                    Write-Warn "[DryRun] Run [$n]: $v -> $nv"
                } else {
                    $runKey.SetValue($n, $nv, $runKey.GetValueKind($n))
                    Write-Ok "已更新 Run [$n] -> $nv"
                }
                $runFixed++
            }
        }
    } finally { $runKey.Close() }
}
if ($runFixed -eq 0) { Write-Ok 'HKCU\...\Run 无旧路径残留。' }

$pointerFiles = @('.lmstudio-home-pointer')
foreach ($pf in $pointerFiles) {
    $fullPf = Join-Path -Path $newPrefix -ChildPath $pf
    if (Test-Path -LiteralPath $fullPf) {
        $raw = Get-Content -LiteralPath $fullPf -Raw -ErrorAction SilentlyContinue
        if ($raw -and ($raw -match $escapedOld)) {
            $updated = [regex]::Replace($raw, $escapedOld, $newPrefix, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($DryRun) {
                Write-Warn "[DryRun] 指针文件 [$fullPf] 将更新为: $($updated.Trim())"
            } else {
                [System.IO.File]::WriteAllText($fullPf, $updated, (New-Object System.Text.UTF8Encoding($false)))
                Write-Ok "已更新指针文件 [$fullPf] -> $($updated.Trim())"
            }
        }
    }
}

# 7. Audit Machine Env / Services / Scheduled Tasks (Read-Only Advisory)
Write-Step '7. 审计系统级环境变量 / 服务 / 计划任务中的旧路径引用'
$sysEnv = [Environment]::GetEnvironmentVariables('Machine')
$sysEnvHits = 0
foreach ($k in $sysEnv.Keys) {
    if ([string]$sysEnv[$k] -match $escapedOld) {
        Write-Warn "系统环境变量 [$k] 含旧路径（可按需手动修改）: $($sysEnv[$k])"
        $sysEnvHits++
    }
}
$svcHits = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName -match $escapedOld })
foreach ($s in $svcHits) {
    Write-Warn "Windows 服务 [$($s.Name)] 含旧路径: $($s.PathName)"
}
$taskHits = @()
try {
    Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
        $acts = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ; '
        if ($acts -match $escapedOld) {
            $taskHits += [PSCustomObject]@{ Task = "$($_.TaskPath)$($_.TaskName)"; Actions = $acts }
        }
    }
} catch {}
foreach ($t in $taskHits) {
    Write-Warn "计划任务 [$($t.Task)] 含旧路径: $($t.Actions)"
}
if ($sysEnvHits -eq 0 -and $svcHits.Count -eq 0 -and $taskHits.Count -eq 0) {
    Write-Ok '系统环境变量、服务与计划任务均无旧路径残留。'
}

# 8. Optional: Disable built-in Administrator (SID *-500)
Write-Step '8. 安全基线：内置 Administrator 账户状态'
$builtInAdmin = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -like '*-500' } | Select-Object -First 1
if ($builtInAdmin) {
    if ($DisableBuiltInAdmin) {
        if ($DryRun) {
            Write-Warn "[DryRun] 将禁用内置管理员账户 [$($builtInAdmin.Name)]"
        } elseif ($isAdmin) {
            & net.exe user $builtInAdmin.Name /active:no 2>&1 | Out-Null
            Write-Ok "已关闭内置管理员账户 [$($builtInAdmin.Name)]。"
        } else {
            Write-Warn "请以管理员身份运行：net user $($builtInAdmin.Name) /active:no"
        }
    } else {
        if ($builtInAdmin.Enabled) {
            Write-Warn "内置管理员账户 [$($builtInAdmin.Name)] 仍处于启用状态。确认一切正常后，建议加 -DisableBuiltInAdmin 参数或手动执行：net user $($builtInAdmin.Name) /active:no"
        } else {
            Write-Ok "内置管理员账户 [$($builtInAdmin.Name)] 已处于安全禁用状态。"
        }
    }
}

# 9. Final Live Verification
Write-Step '9. 最终实测验收'
$finalNew = Get-FinalPath -Path $newPrefix
Write-Ok "Win32 GetFinalPathNameByHandleW($newPrefix) = $finalNew"
if (Test-Path -LiteralPath $oldPrefix) {
    $finalOld = Get-FinalPath -Path $oldPrefix
    Write-Ok "Win32 GetFinalPathNameByHandleW($oldPrefix) = $finalOld"
}
$shortNew = Get-ShortPath -Path $newPrefix
Write-Ok "Win32 GetShortPathNameW($newPrefix) = $shortNew"

$storePkg = Get-AppxPackage -Name '*WindowsStore*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($storePkg) {
    Write-Ok "Microsoft Store 状态: $($storePkg.Status) ($($storePkg.Version))"
}

if (-not $DryRun -and -not $SkipWslSmokeTest -and $wslDistrosFixed.Count -gt 0 -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    foreach ($distro in $wslDistrosFixed) {
        $out = & wsl.exe -d $distro -- uname -sr 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "WSL2 [$distro] 实测启动通过: $out"
        } else {
            Write-Err "WSL2 [$distro] 启动失败 (ExitCode=$LASTEXITCODE): $out"
        }
    }
    & wsl.exe --shutdown 2>&1 | Out-Null
}

Write-Host ''
Write-Ok '阶段 4 收尾处理完成！如 C:\Users 下存在历史乱码幽灵目录，可继续运行 05-Clean-MojibakeDirs.ps1 只读审计。'

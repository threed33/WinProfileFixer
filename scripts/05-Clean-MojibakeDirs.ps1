#Requires -Version 5.1
<#
.SYNOPSIS
    [阶段 5 - 乱码幽灵目录与孤儿 ProfileList 安全清理] 默认只读审计，确认后安全删除。
.DESCRIPTION
    在中文用户名环境下（GBK 936 代码页），许多跨平台开发工具会把 UTF-8 路径按 GBK 错误解码，
    在 C:\Users 下生成类似 "鏉庡悰鏄奬AppData" 的乱码幽灵目录，日积月累占用数 GB 空间。
    本脚本具备以下防误删安全机制：
      1) 默认只读审计模式（不传 -Execute 绝不删除任何内容）。
      2) 自动保护全部活跃 ProfileList 路径、真实物理目标、兜底 Junction 以及 Windows 系统保留目录。
      3) 跨目录联接安全校验：扫描待删目录内部所有 ReparsePoint，一旦发现任何指向受保护用户目录的联接，立刻中止！
      4) 使用 robocopy /MIR /XJ（严格排除联接点 + 绕过 260 字符长路径限制）与 \\?\ 扩展路径安全删除。
      5) 可选清理已删除旧测试账号遗留的孤儿 ProfileList 注册表项。
.PARAMETER TargetNames
    仅针对指定的目录名列表（不含 C:\Users\）。不填则自动列出全部非常规可疑目录供审计。
.PARAMETER Execute
    显式开启执行删除模式（仍需人工输入 DELETE 确认）。
.PARAMETER CleanOrphanProfileKeys
    配合 -Execute 使用：顺带清理目标目录已不存在且 SID 不再对应任何本地账户的孤儿 ProfileList 注册表项。
.EXAMPLE
    .\05-Clean-MojibakeDirs.ps1
.EXAMPLE
    .\05-Clean-MojibakeDirs.ps1 -TargetNames "鏉庡悰鏄奬AppData","鏉庡悰鏄奬" -Execute
#>
[CmdletBinding()]
param(
    [string[]]$TargetNames = @(),
    [switch]$Execute,
    [switch]$CleanOrphanProfileKeys
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'common') -ChildPath 'ProfileFixer.Common.psm1'
Import-Module $modulePath -Force

Write-Banner -Title 'WinProfileFixer :: 阶段 5 - C:\Users 乱码幽灵目录与孤儿注册表安全清理' -Subtitle '默认只读审计 · 跨目录联接防误删校验 · robocopy /XJ 安全清理'

$usersRoot = 'C:\Users'
$inventory = @(Get-UserProfileInventory)

# Build strict protected set
$protectedNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
$protectedPaths = New-Object System.Collections.Generic.List[string]

foreach ($sys in @('Administrator','All Users','Default','Default User','Public','defaultuser0','defaultuser100000','desktop.ini')) {
    [void]$protectedNames.Add($sys)
}
foreach ($p in $inventory) {
    if ($p.Exists -and $p.ProfileImagePath) {
        [void]$protectedNames.Add((Split-Path -Path $p.ProfileImagePath -Leaf))
        $protectedPaths.Add((Resolve-NormalizedPath $p.ProfileImagePath))
    }
    if ($p.FinalPath -and $p.FinalPath -ne '<ResolveError>') {
        [void]$protectedNames.Add((Split-Path -Path $p.FinalPath -Leaf))
        $protectedPaths.Add((Resolve-NormalizedPath $p.FinalPath))
    }
}
# Also protect any top-level Junction pointing to a protected profile (e.g., backward-compat junction)
Get-ChildItem -LiteralPath $usersRoot -Force -ErrorAction SilentlyContinue | Where-Object {
    ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
} | ForEach-Object {
    $tgt = Get-FirstLinkTarget $_
    if ($tgt) {
        foreach ($pp in $protectedPaths) {
            if ($tgt.Equals($pp, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$protectedNames.Add($_.Name)
            }
        }
    }
}

# Enumerate candidates
Write-Step '1. 扫描 C:\Users 下的可疑/非常规目录'
$allEntries = @(Get-ChildItem -LiteralPath $usersRoot -Force -ErrorAction SilentlyContinue)
$candidates = @()

foreach ($entry in $allEntries) {
    $isDefaultUserVariant = ($entry.Name -like 'defaultuser100000.*')
    if ($protectedNames.Contains($entry.Name) -or $isDefaultUserVariant) {
        continue
    }
    if ($TargetNames.Count -gt 0 -and ($entry.Name -notin $TargetNames)) {
        continue
    }
    $files = @(Get-ChildItem -LiteralPath $entry.FullName -Force -Recurse -File -ErrorAction SilentlyContinue)
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $bytes) { $bytes = 0 }
    $hex = ($entry.Name.ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' '

    $candidates += [PSCustomObject]@{
        Name          = $entry.Name
        FullName      = $entry.FullName
        IsReparse     = [bool]($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)
        LinkTarget    = (Get-FirstLinkTarget $entry)
        FileCount     = $files.Count
        SizeMB        = [math]::Round($bytes / 1MB, 2)
        LastWriteTime = $entry.LastWriteTime
        UnicodeHex    = $hex
    }
}

if ($candidates.Count -eq 0) {
    Write-Ok 'C:\Users 下未发现可疑乱码或非受保护残留目录，非常整洁！'
} else {
    $totalMB = [math]::Round((($candidates | Measure-Object -Property SizeMB -Sum).Sum), 2)
    Write-Warn "发现 $($candidates.Count) 个非受保护目录（总计约 $totalMB MB）："
    $candidates | Select-Object Name, SizeMB, FileCount, IsReparse, LastWriteTime | Format-Table -AutoSize
    foreach ($c in $candidates) {
        Write-Info "  [$($c.Name)] -> Unicode: $($c.UnicodeHex)"
    }
}

# Scan orphan ProfileList entries
Write-Step '2. 扫描孤儿 ProfileList 注册表项'
$localSids = @(Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object { $_.SID.Value })
$orphans = @($inventory | Where-Object {
    ($_.SID -notin $localSids) -and
    ($_.Account -eq '<Orphaned / Unresolvable SID>') -and
    (-not $_.HiveLoaded)
})
if ($orphans.Count -eq 0) {
    Write-Ok '未发现孤儿 ProfileList 注册表项。'
} else {
    Write-Warn "发现 $($orphans.Count) 条孤儿 ProfileList 注册表项："
    $orphans | Select-Object SID, ProfileImagePath, Exists | Format-Table -AutoSize
}

if (-not $Execute) {
    Write-Host ''
    Write-Info '当前为只读审计模式，未做任何删除。'
    if ($candidates.Count -gt 0 -or $orphans.Count -gt 0) {
        Write-Info '确认列表无误后，可加 -TargetNames "目录1","目录2" -Execute（建议指定具体名称）执行安全删除。'
    }
    exit 0
}

if (-not (Test-IsAdministrator)) {
    Write-Err '执行删除模式 (-Execute) 需要管理员权限！'
    exit 1
}

# 3. Cross-link safety check before ANY deletion
Write-Step '3. 跨目录联接安全校验 (防止误删指向真实用户目录的内部 Junction)'
$unsafeLinks = New-Object System.Collections.Generic.List[string]
foreach ($c in $candidates) {
    if ($c.IsReparse) {
        $unsafeLinks.Add("TOP-LEVEL REPARSE POINT: $($c.FullName) -> $($c.LinkTarget)")
        continue
    }
    Get-ChildItem -LiteralPath $c.FullName -Force -Depth 4 -ErrorAction SilentlyContinue | Where-Object {
        $_.Attributes -band [IO.FileAttributes]::ReparsePoint
    } | ForEach-Object {
        $tgt = Get-FirstLinkTarget $_
        if ($tgt) {
            foreach ($pp in $protectedPaths) {
                if ($tgt.StartsWith($pp, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $unsafeLinks.Add("CROSS-LINK: $($_.FullName) -> $tgt")
                }
            }
        }
    }
}

if ($unsafeLinks.Count -gt 0) {
    Write-Err '安全拦截！待删目录内存在指向受保护用户目录的重解析点/联接，已中止删除：'
    $unsafeLinks | ForEach-Object { Write-Err "  $_" }
    exit 1
}
Write-Ok '跨目录联接校验通过：0 条指向受保护用户目录的联接。'

$confirm = Read-Host "确认永久删除以上 $($candidates.Count) 个目录？请输入大写 DELETE 回车（其他任意内容取消）"
if ($confirm -cne 'DELETE') {
    Write-Warn '已取消删除。'
    exit 0
}

# 4. Execute safe deletion via robocopy /MIR /XJ + \\?\ extended-length path
Write-Step '4. 执行安全清理'
$beforeFreeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
$emptyDir = Join-Path -Path $env:TEMP -ChildPath ("WinProfileFixer_empty_{0}" -f [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null

try {
    foreach ($c in $candidates) {
        $full = $c.FullName
        Write-Info "正在清理: $full ..."
        # Remove shallow internal reparse points non-recursively first
        Get-ChildItem -LiteralPath $full -Force -Depth 4 -ErrorAction SilentlyContinue | Where-Object {
            $_.Attributes -band [IO.FileAttributes]::ReparsePoint
        } | ForEach-Object {
            try { [System.IO.Directory]::Delete($_.FullName, $false) } catch {}
        }
        # Mirror empty dir with /XJ (strictly exclude junctions) to handle >260 char deep paths
        & robocopy.exe $emptyDir $full /MIR /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        try {
            [System.IO.Directory]::Delete("\\?\$full", $true)
        } catch {
            & cmd.exe /c "rd /s /q `"\\?\$full`"" 2>&1 | Out-Null
        }
        if (Test-Path -LiteralPath $full) {
            Write-Warn "未能完全删除（可能有只读或被占用文件）：$full"
        } else {
            Write-Ok "已彻底删除: $full"
        }
    }
} finally {
    Remove-Item -LiteralPath $emptyDir -Force -ErrorAction SilentlyContinue
}

if ($CleanOrphanProfileKeys -and $orphans.Count -gt 0) {
    Write-Step '5. 清理孤儿 ProfileList 注册表项'
    foreach ($o in $orphans) {
        if (-not (Test-Path -LiteralPath $o.ProfileImagePath)) {
            $regKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($o.SID)"
            if (Test-Path $regKey) {
                Remove-Item -Path $regKey -Recurse -Force
                Write-Ok "已删除孤儿注册表项: $($o.SID) ($($o.ProfileImagePath))"
            }
        } else {
            Write-Warn "跳过 $($o.SID)：其目录 $($o.ProfileImagePath) 依然存在，不自动删除注册表项。"
        }
    }
}

$afterFreeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
$freedGB = [math]::Round($afterFreeGB - $beforeFreeGB, 2)
Write-Host ''
Write-Ok "清理完成！C: 盘可用空间: ${beforeFreeGB} GB -> ${afterFreeGB} GB (释放 +${freedGB} GB)"

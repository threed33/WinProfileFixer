#Requires -Version 5.1
<#
.SYNOPSIS
    WinProfileFixer 公共核心模块 (兼容 Windows PowerShell 5.1 与 PowerShell 7+)
.DESCRIPTION
    提供 Win32 底层 Unicode 路径解析 (GetFinalPathNameByHandleW / GetShortPathNameW)、
    环境变更广播 (WM_SETTINGCHANGE)、ProfileList 拓扑自动识别、内核过滤驱动检测、
    BitLocker/SafeBoot 检查以及统一日志输出函数。
#>

Set-StrictMode -Version Latest

if (-not ('WinProfileFixer.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace WinProfileFixer {
    public static class NativeMethods {
        private const uint FILE_READ_ATTRIBUTES = 0x80;
        private const uint FILE_SHARE_ALL = 0x07;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint WM_SETTINGCHANGE = 0x001A;
        private const uint SMTO_ABORTIFHUNG = 0x0002;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle hFile,
            StringBuilder lpszFilePath,
            uint cchFilePath,
            uint dwFlags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetShortPathNameW(
            string lpszLongPath,
            StringBuilder lpszShortPath,
            uint cchBuffer);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr SendMessageTimeoutW(
            IntPtr hWnd,
            uint Msg,
            UIntPtr wParam,
            string lParam,
            uint fuFlags,
            uint uTimeout,
            out UIntPtr lpdwResult);

        public static string GetFinalPath(string path) {
            using (var handle = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero)) {
                if (handle.IsInvalid) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                var sb = new StringBuilder(1024);
                uint len = GetFinalPathNameByHandleW(handle, sb, (uint)sb.Capacity, 0);
                if (len == 0) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                if (len > sb.Capacity) {
                    sb = new StringBuilder((int)len + 1);
                    len = GetFinalPathNameByHandleW(handle, sb, (uint)sb.Capacity, 0);
                    if (len == 0) {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                }
                return sb.ToString();
            }
        }

        public static string GetShortPath(string path) {
            var sb = new StringBuilder(1024);
            uint len = GetShortPathNameW(path, sb, (uint)sb.Capacity);
            if (len == 0) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (len > sb.Capacity) {
                sb = new StringBuilder((int)len + 1);
                len = GetShortPathNameW(path, sb, (uint)sb.Capacity);
                if (len == 0) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            return sb.ToString();
        }

        public static void BroadcastEnvironmentChange() {
            UIntPtr result;
            SendMessageTimeoutW(new IntPtr(0xffff), WM_SETTINGCHANGE, UIntPtr.Zero, "Environment", SMTO_ABORTIFHUNG, 5000, out result);
        }
    }
}
"@
}

function Write-Banner {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Subtitle = ''
    )
    Write-Host '====================================================================' -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    if ($Subtitle) {
        Write-Host "  $Subtitle" -ForegroundColor DarkCyan
    }
    Write-Host '====================================================================' -ForegroundColor Cyan
}

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[OK]   $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "[FAIL] $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Gray }

function Test-IsAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RegistryValueSafe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $props = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $props) { return $null }
    $prop = $props.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-SafeBootMode {
    $val = Get-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option' -Name 'OptionValue'
    if ($null -ne $val) {
        return [int]$val
    }
    return 0
}

function Resolve-NormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim()
    if ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
    elseif ($p.StartsWith('\??\')) { $p = $p.Substring(4) }
    if ($p.Length -gt 3) {
        $p = $p.TrimEnd('\')
    }
    return $p
}

function Test-HasNonAscii {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return ($Text -match '[^\x00-\x7F]')
}

function Get-FinalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [WinProfileFixer.NativeMethods]::GetFinalPath($Path)
}

function Get-ShortPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [WinProfileFixer.NativeMethods]::GetShortPath($Path)
}

function Send-EnvironmentChangeBroadcast {
    [WinProfileFixer.NativeMethods]::BroadcastEnvironmentChange()
}

function Get-FirstLinkTarget {
    param([System.IO.FileSystemInfo]$Item)
    if ($null -eq $Item) { return $null }
    if (-not ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    $raw = @($Item.Target) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return (Resolve-NormalizedPath -Path $raw)
}

function Test-IsReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Resolve-SidToAccountName {
    param([Parameter(Mandatory = $true)][string]$Sid)
    try {
        $sidObj = New-Object System.Security.Principal.SecurityIdentifier($Sid)
        return $sidObj.Translate([System.Security.Principal.NTAccount]).Value
    } catch {
        return '<Orphaned / Unresolvable SID>'
    }
}

function Test-ValidAsciiProfileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return [PSCustomObject]@{ Valid = $false; Reason = '名称不能为空。' }
    }
    if ($Name.Length -gt 64) {
        return [PSCustomObject]@{ Valid = $false; Reason = '名称长度不能超过 64 个字符。' }
    }
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        return [PSCustomObject]@{ Valid = $false; Reason = '仅允许纯英文/数字开头，后续包含字母、数字、点、下划线或连字符（禁止空格与中文）。' }
    }
    if ($Name.EndsWith('.')) {
        return [PSCustomObject]@{ Valid = $false; Reason = '目录名不能以点号结尾。' }
    }
    $reserved = @(
        'CON','PRN','AUX','NUL',
        'COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9',
        'LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9',
        'Administrator','Default','Default User','All Users','Public','defaultuser0','defaultuser100000'
    )
    foreach ($r in $reserved) {
        if ($Name.Equals($r, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{ Valid = $false; Reason = "[$Name] 是 Windows 保留名称，请换一个英文名。" }
        }
    }
    return [PSCustomObject]@{ Valid = $true; Reason = '' }
}

function Get-UserProfileInventory {
    <#
    .SYNOPSIS
        枚举所有普通用户 Profile (S-1-5-21-*) 并自动识别当前路径拓扑类型。
    #>
    $profRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $results = @()

    Get-ChildItem -Path $profRoot -ErrorAction SilentlyContinue | Where-Object {
        $_.PSChildName -like 'S-1-5-21-*'
    } | ForEach-Object {
        $sid = $_.PSChildName
        $rawImg = Get-RegistryValueSafe -Path $_.PSPath -Name 'ProfileImagePath'
        $imgPath = if ($rawImg) { Resolve-NormalizedPath $rawImg } else { '' }
        $account = Resolve-SidToAccountName -Sid $sid
        $exists = $false
        $isReparse = $false
        $linkType = ''
        $linkTarget = ''
        $finalPath = ''
        $shortPath = ''
        $hasNtUser = $false

        if ($imgPath -and (Test-Path -LiteralPath $imgPath)) {
            $exists = $true
            $item = Get-Item -LiteralPath $imgPath -Force -ErrorAction SilentlyContinue
            if ($item) {
                $isReparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
                if ($isReparse) {
                    $linkType = [string]$item.LinkType
                    $linkTarget = Get-FirstLinkTarget -Item $item
                }
            }
            $hasNtUser = Test-Path -LiteralPath (Join-Path -Path $imgPath -ChildPath 'NTUSER.DAT')
            try { $finalPath = Resolve-NormalizedPath (Get-FinalPath -Path $imgPath) } catch { $finalPath = '<ResolveError>' }
            try { $shortPath = Resolve-NormalizedPath (Get-ShortPath -Path $imgPath) } catch { $shortPath = '<ResolveError>' }
        }

        $imgNonAscii   = Test-HasNonAscii $imgPath
        $finalNonAscii = Test-HasNonAscii $finalPath
        $shortNonAscii = Test-HasNonAscii $shortPath

        # Classify topology
        $topology = 'Unknown'
        if (-not $exists) {
            $topology = 'OrphanOrMissing'
        } elseif ($isReparse -and $finalNonAscii) {
            $topology = 'ReverseJunctionToNonAscii'
        } elseif ($isReparse -and -not $finalNonAscii) {
            $topology = 'ProfileImagePathIsReparsePoint'
        } elseif ($imgNonAscii) {
            $topology = 'StandardNonAsciiPhysical'
        } elseif (-not $imgNonAscii -and -not $finalNonAscii) {
            $topology = 'HealthyAsciiPhysical'
        }

        $results += [PSCustomObject]@{
            SID              = $sid
            Account          = $account
            ProfileImagePath = $imgPath
            Exists           = $exists
            HasNtUserDat     = $hasNtUser
            IsReparsePoint   = $isReparse
            LinkType         = $linkType
            LinkTarget       = $linkTarget
            FinalPath        = $finalPath
            ShortPath        = $shortPath
            ImgHasNonAscii   = $imgNonAscii
            FinalHasNonAscii = $finalNonAscii
            ShortHasNonAscii = $shortNonAscii
            Topology         = $topology
            HiveLoaded       = (Test-Path "Registry::HKEY_USERS\$sid")
        }
    }

    return $results
}

function Get-VolumeFilterDrivers {
    param([string]$Volume = 'C:')
    $out = & fltmc.exe instances -v $Volume 2>&1
    if ($LASTEXITCODE -ne 0) {
        return @()
    }
    $drivers = @()
    foreach ($line in $out) {
        $text = [string]$line
        if ($text -match '^\s*([A-Za-z0-9_.-]+)\s+\d+(?:\.\d+)?\s+') {
            $name = $Matches[1]
            if ($name -notin @('Filter','------')) {
                $drivers += $name
            }
        }
    }
    return ($drivers | Select-Object -Unique)
}

function ConvertFrom-ManageBdeOutput {
    <#
    .SYNOPSIS
        Fail-safely parses manage-bde -status output across English, Simplified Chinese, and Traditional Chinese locales.
    #>
    param(
        [string]$RawText = '',
        [string]$DriveLetter = 'C:'
    )

    if ([string]::IsNullOrWhiteSpace($RawText)) {
        return [PSCustomObject]@{
            Drive                = $DriveLetter
            Checked              = $false
            ProtectionOn         = $false
            IsEncrypted          = $false
            Status               = 'Unknown'
            ProtectionStatusCode = 2
            ConversionStatusCode = -1
            ConversionStatus     = 'Unknown'
            EncryptionPercentage = $null
            Source               = 'manage-bde'
            Raw                  = ''
        }
    }

    $protOn = ($RawText -match 'Protection\s+On|保护已开启|保护已打开|保护状态\s*[:：]\s*(?:保护)?已(?:开启|打开)|保護已開啟|保護已打開|保護狀態\s*[:：]\s*(?:保護)?已(?:開啟|打開)')
    $protOff = ($RawText -match 'Protection\s+Off|保护已关闭|保护状态\s*[:：]\s*(?:保护)?已关闭|保護已關閉|保護狀態\s*[:：]\s*(?:保護)?已關閉')
    $convEncrypted = ($RawText -match 'Fully\s+Encrypted|Encryption\s+In\s+Progress|Decryption\s+In\s+Progress|Encryption\s+Paused|Decryption\s+Paused|Used\s+Space\s+Only\s+Encrypted|已完全加密|正在加密|正在解密|已暂停加密|已暂停解密|仅加密已用空间|正在進行加密|正在進行解密|加密已暫停|解密已暫停|僅加密已使用的空間')
    $convDecrypted = ($RawText -match 'Fully\s+Decrypted|已完全解密')

    $pctVal = $null
    if ($RawText -match '(?:Percentage\s+Encrypted|已加密百分比|加密百分比)\s*[:：]\s*(\d+(?:[.,]\d+)?)\s*%') {
        $pctStr = $Matches[1].Replace(',', '.')
        $parsedPct = 0.0
        if ([double]::TryParse($pctStr, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedPct)) {
            $pctVal = $parsedPct
        }
    }
    $pctNonZero = ($null -ne $pctVal -and $pctVal -gt 0)
    $pctIsZero = ($null -ne $pctVal -and $pctVal -eq 0)

    $convStatus = 'Unknown'
    $convCode = -1
    if ($RawText -match 'Encryption\s+In\s+Progress|正在加密|正在進行加密') {
        $convStatus = 'EncryptionInProgress'
        $convCode = 2
    } elseif ($RawText -match 'Decryption\s+In\s+Progress|正在解密|正在進行解密') {
        $convStatus = 'DecryptionInProgress'
        $convCode = 3
    } elseif ($RawText -match 'Encryption\s+Paused|已暂停加密|加密已暫停') {
        $convStatus = 'EncryptionPaused'
        $convCode = 4
    } elseif ($RawText -match 'Decryption\s+Paused|已暂停解密|解密已暫停') {
        $convStatus = 'DecryptionPaused'
        $convCode = 5
    } elseif ($RawText -match 'Used\s+Space\s+Only\s+Encrypted|仅加密已用空间|僅加密已使用的空間') {
        $convStatus = 'UsedSpaceOnlyEncrypted'
        $convCode = 1
    } elseif ($RawText -match 'Fully\s+Encrypted|已完全加密') {
        $convStatus = 'FullyEncrypted'
        $convCode = 1
    } elseif ($convDecrypted) {
        $convStatus = 'FullyDecrypted'
        $convCode = 0
    }

    $protCode = if ($protOn) { 1 } elseif ($protOff) { 0 } else { 2 }

    # Fail-safe classification: never default unrecognized/garbled output to Off
    $checked = $false
    $protectionOn = $false
    $isEncrypted = $false
    $status = 'Unknown'

    if ($protOn) {
        $checked = $true
        $protectionOn = $true
        $isEncrypted = $true
        $status = 'On'
    } elseif ($convEncrypted -or $pctNonZero) {
        $checked = $true
        $protectionOn = $false
        $isEncrypted = $true
        $status = 'EncryptedProtectionOff'
    } elseif ($protOff -and ($convDecrypted -or $pctIsZero)) {
        $checked = $true
        $protectionOn = $false
        $isEncrypted = $false
        $status = 'Off'
    }

    return [PSCustomObject]@{
        Drive                = $DriveLetter
        Checked              = $checked
        ProtectionOn         = $protectionOn
        IsEncrypted          = $isEncrypted
        Status               = $status
        ProtectionStatusCode = $protCode
        ConversionStatusCode = $convCode
        ConversionStatus     = $convStatus
        EncryptionPercentage = $pctVal
        Source               = 'manage-bde'
        Raw                  = $RawText.Trim()
    }
}

function Get-BitLockerStatus {
    param([string]$DriveLetter = 'C:')

    $drive = if ($null -eq $DriveLetter) { '' } else { $DriveLetter.Trim() }
    if ($drive.Length -gt 2 -and $drive.EndsWith('\')) {
        $drive = $drive.TrimEnd('\')
    }
    if ($drive -match '^[A-Za-z]$') {
        $drive = "${drive}:"
    }
    $drive = $drive.ToUpperInvariant()

    if ($drive -notmatch '^[A-Z]:$') {
        return [PSCustomObject]@{
            Drive                = $drive
            Checked              = $false
            ProtectionOn         = $false
            IsEncrypted          = $false
            Status               = 'Unknown'
            ProtectionStatusCode = 2
            ConversionStatusCode = -1
            ConversionStatus     = 'Unknown'
            EncryptionPercentage = $null
            Source               = 'Validation'
            Raw                  = "Invalid drive letter: $DriveLetter"
        }
    }

    # Tier 1: CIM Win32_EncryptableVolume (OS-language & console-codepage independent)
    $cimError = ''
    try {
        $vol = Get-CimInstance -Namespace 'Root\CIMV2\Security\MicrosoftVolumeEncryption' -ClassName 'Win32_EncryptableVolume' -Filter "DriveLetter = '$drive'" -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $vol) {
            $protCode = 2
            $protRes = Invoke-CimMethod -InputObject $vol -MethodName 'GetProtectionStatus' -ErrorAction SilentlyContinue
            $protRvProp = if ($protRes) { $protRes.PSObject.Properties['ReturnValue'] } else { $null }
            $protValProp = if ($protRes) { $protRes.PSObject.Properties['ProtectionStatus'] } else { $null }
            if ($protRvProp -and [int]$protRvProp.Value -eq 0 -and $protValProp -and $null -ne $protValProp.Value) {
                $protCode = [int]$protValProp.Value
            } else {
                $volProtProp = $vol.PSObject.Properties['ProtectionStatus']
                if ($volProtProp -and $null -ne $volProtProp.Value) {
                    $protCode = [int]$volProtProp.Value
                }
            }

            $convCode = -1
            $encPct = $null
            $convRes = Invoke-CimMethod -InputObject $vol -MethodName 'GetConversionStatus' -ErrorAction SilentlyContinue
            $convRvProp = if ($convRes) { $convRes.PSObject.Properties['ReturnValue'] } else { $null }
            $convValProp = if ($convRes) { $convRes.PSObject.Properties['ConversionStatus'] } else { $null }
            $pctValProp = if ($convRes) { $convRes.PSObject.Properties['EncryptionPercentage'] } else { $null }
            if ($convRvProp -and [int]$convRvProp.Value -eq 0 -and $convValProp -and $null -ne $convValProp.Value) {
                $convCode = [int]$convValProp.Value
                if ($pctValProp -and $null -ne $pctValProp.Value) {
                    $encPct = [double]$pctValProp.Value
                }
            } else {
                $volConvProp = $vol.PSObject.Properties['ConversionStatus']
                if ($volConvProp -and $null -ne $volConvProp.Value) {
                    $convCode = [int]$volConvProp.Value
                }
            }

            $convStatus = switch ($convCode) {
                0 { 'FullyDecrypted' }
                1 { 'FullyEncrypted' }
                2 { 'EncryptionInProgress' }
                3 { 'DecryptionInProgress' }
                4 { 'EncryptionPaused' }
                5 { 'DecryptionPaused' }
                default { 'Unknown' }
            }

            $checked = $false
            $protectionOn = $false
            $isEncrypted = $false
            $status = 'Unknown'

            if ($protCode -eq 1) {
                $checked = $true
                $protectionOn = $true
                $isEncrypted = $true
                $status = 'On'
            } elseif ($protCode -eq 0 -and $convCode -eq 0 -and ($null -eq $encPct -or $encPct -eq 0)) {
                $checked = $true
                $protectionOn = $false
                $isEncrypted = $false
                $status = 'Off'
            } elseif ($protCode -eq 0 -and (($convCode -in @(1, 2, 3, 4, 5)) -or ($null -ne $encPct -and $encPct -gt 0))) {
                $checked = $true
                $protectionOn = $false
                $isEncrypted = $true
                $status = 'EncryptedProtectionOff'
            }

            $pctRaw = if ($null -ne $encPct) { "$encPct%" } else { 'N/A' }
            return [PSCustomObject]@{
                Drive                = $drive
                Checked              = $checked
                ProtectionOn         = $protectionOn
                IsEncrypted          = $isEncrypted
                Status               = $status
                ProtectionStatusCode = $protCode
                ConversionStatusCode = $convCode
                ConversionStatus     = $convStatus
                EncryptionPercentage = $encPct
                Source               = 'CIM'
                Raw                  = "Win32_EncryptableVolume Drive=$drive ProtectionStatus=$protCode ConversionStatus=$convCode ($convStatus) EncryptionPercentage=$pctRaw"
            }
        }
    } catch {
        $cimError = $_.Exception.Message
    }

    # Tier 2: BitLocker PowerShell module cmdlet (OS-language independent)
    $cmdError = ''
    if (Get-Command -Name 'Get-BitLockerVolume' -ErrorAction SilentlyContinue) {
        try {
            $bv = Get-BitLockerVolume -MountPoint $drive -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $bv) {
                $protStr = [string]$bv.ProtectionStatus
                $protCode = switch -Regex ($protStr) {
                    '^(On|1)$'  { 1; break }
                    '^(Off|0)$' { 0; break }
                    default     { 2 }
                }
                $volStatusStr = [string]$bv.VolumeStatus
                $convCode = switch ($volStatusStr) {
                    'FullyDecrypted'       { 0 }
                    'FullyEncrypted'       { 1 }
                    'EncryptionInProgress' { 2 }
                    'DecryptionInProgress' { 3 }
                    'EncryptionPaused'     { 4 }
                    'DecryptionPaused'     { 5 }
                    default                { -1 }
                }
                $encPct = if ($null -ne $bv.EncryptionPercentage) { [double]$bv.EncryptionPercentage } else { $null }

                $checked = $false
                $protectionOn = $false
                $isEncrypted = $false
                $status = 'Unknown'

                if ($protCode -eq 1) {
                    $checked = $true
                    $protectionOn = $true
                    $isEncrypted = $true
                    $status = 'On'
                } elseif ($protCode -eq 0 -and $convCode -eq 0 -and ($null -eq $encPct -or $encPct -eq 0)) {
                    $checked = $true
                    $protectionOn = $false
                    $isEncrypted = $false
                    $status = 'Off'
                } elseif ($protCode -eq 0 -and (($convCode -in @(1, 2, 3, 4, 5)) -or ($null -ne $encPct -and $encPct -gt 0))) {
                    $checked = $true
                    $protectionOn = $false
                    $isEncrypted = $true
                    $status = 'EncryptedProtectionOff'
                }

                $convLabel = if ($volStatusStr) { $volStatusStr } else { 'Unknown' }
                $pctRaw = if ($null -ne $encPct) { "$encPct%" } else { 'N/A' }
                return [PSCustomObject]@{
                    Drive                = $drive
                    Checked              = $checked
                    ProtectionOn         = $protectionOn
                    IsEncrypted          = $isEncrypted
                    Status               = $status
                    ProtectionStatusCode = $protCode
                    ConversionStatusCode = $convCode
                    ConversionStatus     = $convLabel
                    EncryptionPercentage = $encPct
                    Source               = 'BitLockerCmdlet'
                    Raw                  = "Get-BitLockerVolume Drive=$drive ProtectionStatus=$protStr VolumeStatus=$convLabel EncryptionPercentage=$pctRaw"
                }
            }
        } catch {
            $cmdError = $_.Exception.Message
        }
    }

    # Tier 3: manage-bde.exe fallback with OEM codepage retry under chcp 65001 consoles
    try {
        $out = (& manage-bde.exe -status $drive 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0) {
            $parsed = ConvertFrom-ManageBdeOutput -RawText $out -DriveLetter $drive
            if (-not $parsed.Checked -or $out.Contains([char]0xFFFD)) {
                $proc = $null
                try {
                    if ('System.Text.CodePagesEncodingProvider' -as [type]) {
                        [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
                    }
                    $oemCp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
                    $oemEnc = [System.Text.Encoding]::GetEncoding($oemCp)
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = 'manage-bde.exe'
                    $psi.Arguments = "-status $drive"
                    $psi.UseShellExecute = $false
                    $psi.RedirectStandardOutput = $true
                    $psi.RedirectStandardError = $true
                    $psi.CreateNoWindow = $true
                    $psi.StandardOutputEncoding = $oemEnc
                    $psi.StandardErrorEncoding = $oemEnc
                    $proc = [System.Diagnostics.Process]::Start($psi)
                    if ($proc) {
                        $retryOut = $proc.StandardOutput.ReadToEnd()
                        $retryErr = $proc.StandardError.ReadToEnd()
                        $proc.WaitForExit()
                        if ($proc.ExitCode -eq 0) {
                            $retryParsed = ConvertFrom-ManageBdeOutput -RawText "$retryOut`r`n$retryErr" -DriveLetter $drive
                            if ($retryParsed.Checked) {
                                return $retryParsed
                            }
                        }
                    }
                } catch {
                    # Preserve original parse outcome if OEM retry fails
                } finally {
                    if ($proc) { $proc.Dispose() }
                }
            }
            return $parsed
        }
        $errDetail = $out.Trim()
        if ([string]::IsNullOrWhiteSpace($errDetail)) {
            $errDetail = [string](@($cimError, $cmdError) | Where-Object { $_ } | Select-Object -First 1)
        }
        return [PSCustomObject]@{
            Drive                = $drive
            Checked              = $false
            ProtectionOn         = $false
            IsEncrypted          = $false
            Status               = 'Unknown'
            ProtectionStatusCode = 2
            ConversionStatusCode = -1
            ConversionStatus     = 'Unknown'
            EncryptionPercentage = $null
            Source               = 'manage-bde'
            Raw                  = $errDetail
        }
    } catch {
        return [PSCustomObject]@{
            Drive                = $drive
            Checked              = $false
            ProtectionOn         = $false
            IsEncrypted          = $false
            Status               = 'Unknown'
            ProtectionStatusCode = 2
            ConversionStatusCode = -1
            ConversionStatus     = 'Unknown'
            EncryptionPercentage = $null
            Source               = 'manage-bde'
            Raw                  = $_.Exception.Message
        }
    }
}

function Test-DirectoryAclContainsSid {
    <#
    .SYNOPSIS
        Checks NTFS DACL directly by SecurityIdentifier (immune to chcp 65001 / localized account name encoding mismatches).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Sid
    )

    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
        $allowRules = @($rules | Where-Object {
            $_.IdentityReference.Value.Equals($Sid, [System.StringComparison]::OrdinalIgnoreCase) -and
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow
        })
        $rights = ($allowRules | ForEach-Object { [string]$_.FileSystemRights } | Select-Object -Unique) -join ', '
        $ownerSid = ''
        try {
            $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        } catch {}
        return [PSCustomObject]@{
            Checked   = $true
            HasAccess = ($allowRules.Count -gt 0)
            Rights    = $rights
            OwnerSid  = $ownerSid
            Error     = ''
        }
    } catch {
        return [PSCustomObject]@{
            Checked   = $false
            HasAccess = $false
            Rights    = ''
            OwnerSid  = ''
            Error     = $_.Exception.Message
        }
    }
}

function Get-SystemCodePageInfo {
    $acp   = Get-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name 'ACP'
    $oemcp = Get-RegistryValueSafe -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name 'OEMCP'
    return [PSCustomObject]@{
        ACP        = if ($acp) { [string]$acp } else { '' }
        OEMCP      = if ($oemcp) { [string]$oemcp } else { '' }
        IsUtf8Beta = ([string]$acp -eq '65001')
    }
}

Export-ModuleMember -Function @(
    'Write-Banner', 'Write-Step', 'Write-Ok', 'Write-Warn', 'Write-Err', 'Write-Info',
    'Test-IsAdministrator', 'Get-RegistryValueSafe', 'Get-SafeBootMode',
    'Resolve-NormalizedPath', 'Test-HasNonAscii',
    'Get-FinalPath', 'Get-ShortPath', 'Send-EnvironmentChangeBroadcast',
    'Get-FirstLinkTarget', 'Test-IsReparsePoint', 'Resolve-SidToAccountName',
    'Test-ValidAsciiProfileName', 'Get-UserProfileInventory',
    'Get-VolumeFilterDrivers', 'ConvertFrom-ManageBdeOutput', 'Get-BitLockerStatus',
    'Test-DirectoryAclContainsSid', 'Get-SystemCodePageInfo'
)

# WinProfileFixer — Lossless Windows Non-ASCII User Profile Migration & Reverse-Junction Flip Toolkit

> [简体中文](README.md) | English

A battle-tested PowerShell toolkit and engineering guide for **losslessly fixing Windows user profile paths containing Chinese / CJK / non-ASCII characters or spaces** — with **0-byte atomic NTFS renaming**, **8 pre-flight safety guards**, **automatic detection of broken reverse-junction workarounds**, and full post-migration remediation for **WSL2, environment variables, Shell Folders, OneDrive SyncRoot, and mojibake ghost directories**.

---

## Why This Exists

When setting up Windows with a Microsoft Account that uses non-ASCII characters (e.g., Chinese, Japanese, Korean, Cyrillic), Windows generates `C:\Users\<NonAsciiName>`. Many developer tools (Go, Rust, Python, QEMU, CMake, Node.js, sandboxed AI agents) break or silently create gigabytes of mojibake folders under Windows' legacy ANSI codepages (e.g. GBK `CP936`).

Even worse, a widely circulated "zero-loss workaround" tells users to leave `C:\Users\<NonAscii>` in place, create an NTFS junction `C:\Users\<English> -> C:\Users\<NonAscii>`, and set `ProfileImagePath = C:\Users\<English>`. This **reverse junction** backfires badly:

1. **Path canonicalization breaks the illusion**: `GetFinalPathNameByHandleW` (Win32), `filepath.EvalSymlinks` (Go), `os.path.realpath` (Python), `fs.realpathSync` (Node.js), and `fs::canonicalize` (Rust) resolve the junction right back to `C:\Users\<NonAscii>` (or fail when the profile root is a reparse point).
2. **NTFS 8.3 short-path blind spot**: Short CJK names (e.g., 3 Chinese characters = 6 GBK bytes <= 8) already satisfy 8.3 length rules, so NTFS **never generates an ASCII `~1` short name** — causing fallback paths in tools like QEMU/Go to fail too.
3. **Unsupported by Windows**: Pointing `ProfileImagePath` at a reparse point risks Windows 11 major feature upgrade rollbacks (`23H2 -> 24H2/25H2`) and UWP/Store ACL glitches.

---

## Supported Topologies (Auto-Detected)

`03-Migrate-UserProfile.ps1` automatically inspects `HKLM\...\ProfileList` and NTFS reparse points to select the right strategy:

| Mode | Current State | Atomic Action |
| :--- | :--- | :--- |
| **`Standard`** | `C:\Users\<Old>` is real dir; `ProfileImagePath = C:\Users\<Old>`; `C:\Users\<New>` does not exist | Probe-move `<Old> -> <New>_RENAMING_TMP -> <New>`, update `ProfileImagePath`, create compat junction `<Old> -> <New>` |
| **`Flip`** | `C:\Users\<Old>` is real dir; `C:\Users\<New>` is a Junction `-> <Old>`; `ProfileImagePath = C:\Users\<New>` | **Probe-move `<Old> -> <New>_RENAMING_TMP` FIRST** (aborts with 0 changes if locked!), remove now-dangling `<New>` junction shell, move `<Tmp> -> <New>`, create compat junction `<Old> -> <New>` |

---

## Quick Start (5 Phases)

> Place this repository **outside** `C:\Users` (e.g., `D:\WinProfileFixer`) before running!

```powershell
# Phase 1: 100% read-only audit (daily user, elevated PowerShell recommended)
.\scripts\01-Audit-UserProfile.ps1

# Phase 2: Backup registry hives, NTFS ACL snapshot, and System Restore Point (outside C:\Users!)
.\scripts\02-Backup-BeforeMigrate.ps1 -BackupDir D:\WinProfileBackup

# Phase 3: Sign out -> Shift+Restart -> Safe Mode (Press 4) -> Log into Administrator
#          (Safe Mode cleanly bypasses OneDrive CldFlt kernel locks & AV minifilters!)
.\scripts\03-Migrate-UserProfile.ps1 -DryRun
.\scripts\03-Migrate-UserProfile.ps1

# Phase 4: Reboot normally into your daily account (DO NOT start WSL yet!), run as Admin:
.\scripts\04-PostMigrate-Cleanup.ps1 -DryRun
.\scripts\04-PostMigrate-Cleanup.ps1 -DisableBuiltInAdmin

# Phase 5 (Optional): Audit & safely remove mojibake ghost directories and orphaned ProfileList keys
.\scripts\05-Clean-MojibakeDirs.ps1
```

---

## Key Safety Engineering Highlights

- **Test-Lock-First Atomic Order**: Moves the real directory to `*_RENAMING_TMP` *before* touching any junction or registry key. If a kernel filter driver (`CldFlt`, antivirus) or open handle blocks the rename (`Access is denied`), the script exits with **zero modifications**.
- **Win11 ARSO & Hive Lock Guard**: Verifies both `CurrentUser.SID != TargetSID` and `!(Test-Path Registry::HKEY_USERS\<TargetSID>)`.
- **WSL2 `ext4.vhdx` Rescue**: Hyper-V refuses to mount `ext4.vhdx` through an NTFS junction; Phase 4 fixes `HKCU\...\Lxss\*\BasePath` before launching WSL.
- **Registry ValueKind Preservation**: Updates `HKCU\Environment` with `DoNotExpandEnvironmentNames` so `REG_EXPAND_SZ` (`%USERPROFILE%`) stays intact, then broadcasts `WM_SETTINGCHANGE`.
- **Cross-Link Safe Deletion**: Phase 5 scans candidate ghost folders for internal reparse points targeting protected profiles before removing deep paths via `robocopy /MIR /XJ`.
- **PowerShell 5.1 UTF-8 BOM + Native Unicode APIs**: Zero `cmd.exe` codepage corruption.

---

## Documentation (Chinese)

- [Full Guide (README.md)](README.md)
- [Real-World Remediation Case Study](docs/CASE_STUDY.md)
- [Technical Architecture & Safety Model](docs/ARCHITECTURE.md)
- [Troubleshooting & FAQ](docs/TROUBLESHOOTING.md)

## License

[MIT](LICENSE)

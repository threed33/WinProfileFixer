# 常见问题排错手册与 FAQ（Troubleshooting）

---

## Q1：步骤 1 报错 `Access to the path 'C:\Users\...' is denied.` 怎么办？

**首先请放心**：由于脚本采用「先移动实体测锁，成功后再删旧联接/改注册表」的原子顺序，出错在步骤 1 时**你电脑的原目录、原联接和注册表都是 100% 零改动、完好无损的**。

### 常见原因与解法
1. **头号原因：OneDrive 云文件内核驱动 `CldFlt` 拦截**（即使 OneDrive 没运行、日常账户已注销也会拦截！）；
2. **第二原因：杀毒软件内核过滤驱动**（如火绒 `sysdiag`、360、电脑管家等）或 `WSearch` 索引服务。

**一劳永逸解法（单次安全模式，1 秒过）**：
1. 先确认本机 C 盘未开启 BitLocker（或已备好 48 位 BitLocker 恢复密钥）；
2. 注销日常账户 → 登录界面**按住 `Shift` 键不放**点电源图标 → **重启**；
3. 蓝屏菜单依次点击：**疑难解答 → 高级选项 → 启动设置 → 重启**；
4. 出现数字列表后按键盘 **`4`**（启用安全模式）；
5. 安全模式登录 `Administrator`，重新运行 `03-Migrate-UserProfile.ps1`。安全模式下 `CldFlt` 与杀软驱动不加载，100% 顺利通过。

---

## Q2：守卫 4 报错 `Guard4_HiveLoaded`（检测到 `NTUSER.DAT` 仍被加载）？

说明目标用户的注册表配置单元还挂在 `HKEY_USERS\<SID>` 里，不能强行改名。

### 两大原因
1. **用了「切换用户」而不是「注销」**：切换用户会让原账户留在后台锁死 `NTUSER.DAT`。
2. **Windows 11 默认开启了 ARSO（自动重启登录）**：如果你没注销就直接点重启，Win11 会在开机停在锁屏界面时就偷偷预加载上一个账户的 `NTUSER.DAT`！

### 解决办法
1. 切回日常账户 → 点击开始菜单头像 → **先点「注销（Sign out）」**；
2. 退到登录界面后再点**重启**（或按住 `Shift` 重启进安全模式）；
3. 开机后**直接选择 `Administrator` 登录**（千万不要先登录一下日常账户）。

---

## Q3：开启了 BitLocker，进安全模式会怎样？

如果 `01-Audit-UserProfile.ps1` 提示 `C:` 盘 **BitLocker 保护已开启**：
- 进入安全模式（或修改启动设置）时，Windows 会要求输入 **48 位 BitLocker 恢复密钥**！
- **操作前务必二选一**：
  1. 提前登录微软账户网页（`https://account.microsoft.com/devices/recoverykey`）或在管理员终端执行 `manage-bde -protectors -get C:` 抄下并核对 48 位恢复密钥；
  2. 或者在迁移前临时暂停 BitLocker 保护 1 次重启：
     ```powershell
     Suspend-BitLocker -MountPoint "C:" -RebootCount 2
     ```
     （迁移完成回到正常系统后执行 `Resume-BitLocker -MountPoint "C:"` 即可立即恢复保护。）

---

## Q4：迁移完成后，WSL2 启动报 `Access is denied` 或找不到镜像？

**原因**：WSL2（Hyper-V）底层不允许经由 NTFS Junction 挂载 `ext4.vhdx` 虚拟磁盘，而注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\{GUID}\BasePath` 还写着旧的中文路径。

**解决办法**：
在日常账户下直接运行阶段 4 收尾脚本即可自动修正并测试启动：
```powershell
.\scripts\04-PostMigrate-Cleanup.ps1
```
如需手动核查：
```powershell
wsl --shutdown
Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss | ForEach-Object {
    Get-ItemProperty $_.PSPath | Select-Object DistributionName, BasePath
}
```
确保 `BasePath` 已指向纯英文新路径（例如 `\\?\C:\Users\Alex\Ubuntu`）。

---

## Q5：验收输出和 WSL 注册表里出现 `\\?\C:\Users\Alex`，里面的 `?` 是乱码吗？

**完全不是乱码！**
- **`\\?\`** 是 Windows 原生的 **Win32 扩展长度路径前缀（Extended-Length Path / 设备命名空间前缀）**，里面的 `?` 就是标准英文问号。
- 它的作用是告诉 Windows I/O 管理器跳过老旧的 260 字符 `MAX_PATH` 限制和传统路径规整逻辑。
- Win32 `GetFinalPathNameByHandleW` 和 WSL2 的 `Lxss\BasePath` 原生都会带这个前缀，属于完全正常的标准格式。

---

## Q6：未来要升级 Windows 11 大版本（例如 `23H2 -> 24H2 / 25H2`）需要注意什么？

虽然 `ProfileImagePath` 现在已经直指纯英文物理实体目录（完全符合微软规范），但部分 Windows 功能升级程序（Setup / WinRE）在扫描 `C:\Users` 时，对额外存在的目录联接点（即我们保留的向后兼容兜底联接 `C:\Users\<旧中文名>`）仍可能比较敏感。

**最佳实践**：
1. 在运行 Windows 大版本升级前，先临时摘除旧目录名的兜底联接（**仅摘指针，绝不影响实体文件**）：
   ```cmd
   rmdir "C:\Users\旧中文名"
   ```
   *(绝对不要用资源管理器直接删，也不要加 `/s`！用 PowerShell 也可执行 `[System.IO.Directory]::Delete("C:\Users\旧中文名", $false)`)*
2. 顺利完成大版本升级后，观察几天如果一切软件正常，甚至可以永久不再重建它；如果发现某个老软件确实写死了旧中文路径，随时再执行一句重建即可：
   ```cmd
   mklink /J "C:\Users\旧中文名" "C:\Users\新英文名"
   ```

---

## Q7：为什么运行某些自己修改过的 `.ps1` 脚本会出现中文乱码或语法报错？

Windows 自带的 **Windows PowerShell 5.1** 在读取**不带 UTF-8 BOM** 的 `.ps1` 文件时，会默认按简体中文系统代码页 **GBK（CP936）** 解析源码，导致 UTF-8 中文字符串甚至紧邻的引号被错误截断引发语法错误！

- 本仓库全部 `.ps1` / `.psm1` 文件均强制使用 **UTF-8 with BOM** 编码保存，同时兼容 Windows PowerShell 5.1 与 PowerShell 7+。
- 如果你在编辑器里修改了脚本，请务必保存为 **`UTF-8 with BOM`**（VS Code 右下角点击编码 → `Save with Encoding` → `UTF-8 with BOM`）。

---

## Q8：怎么安全删除临时启用的内置 `Administrator` 账户？

内置 `Administrator` 账户不能被删除，但迁移验证完毕后**务必禁用**以恢复系统安全基线：
- 运行阶段 4 脚本时加上 `-DisableBuiltInAdmin` 参数；
- 或在管理员终端手动执行：
  ```cmd
  net user Administrator /active:no
  ```
  验证其 `Enabled` 已变回 `False`：
  ```powershell
  Get-LocalUser -Name Administrator | Select-Object Name, Enabled
  ```

---

## Q9：想把整个过程彻底撤销回滚怎么办？

只要还没有删除原有实体数据，可以随时再次进入安全模式 `Administrator`，运行对称回滚脚本：

```powershell
# 反向联接翻转模式的回滚：
.\scripts\Rollback-UserProfile.ps1 -TargetSid <你的SID> -OldName "<旧中文名>" -Mode Flip

# 标准改名模式的回滚：
.\scripts\Rollback-UserProfile.ps1 -TargetSid <你的SID> -OldName "<旧中文名>" -Mode Standard
```

如需同时恢复阶段 4 修改过的注册表，直接双击阶段 2 备份目录（如 `D:\WinProfileBackup\`）里导出的 `.reg` 文件导入即可。

# 真实修复历程复盘（匿名化实战纪实）

> 本文档完整复盘一次真实的 **Windows 11 23H2（Build 22631）中文用户目录排障与无损根治历程**。为保护隐私，文中的个人姓名、目录名与 SID 已统一匿名化为 `张三` → `Alex` 与 `S-1-5-21-...-1002`，其余技术细节、错误码、工具行为、空间数据与内核驱动排查过程均 100% 还原真实实战。

---

## 序章：一个看似普通的开发工具报错，撕开了半年埋下的暗雷

### 初始症状
在一台日常重度开发的 Windows 11 笔记本上，安装一款基于 Go + QEMU 的本地沙盒工具时，初始化阶段直接报错退出：
- Go 在规范化用户配置文件路径时（`filepath.EvalSymlinks`）遇到用户根目录为 NTFS Junction 异常；
- 该工具内置了“遇到中文/非 ASCII 路径降级为 Windows 8.3 短路径”的容错逻辑，结果**降级后依然包含中文**，导致 QEMU 串口绑定直接失败（`The system cannot find the path specified`）。

### 本机历史背景
这台电脑数月前刚装完系统时，由于 OOBE 直接登录了微软账户，生成了中文实体目录 `C:\Users\张三`。用户当时参考了网上流传极广的所谓“最无损改英文名教程”：
1. 保持物理目录 `C:\Users\张三` 不动；
2. 创建反向目录联接：`mklink /J C:\Users\Alex C:\Users\张三`；
3. 将注册表 `ProfileImagePath` 改为 `C:\Users\Alex`。

表面上看，命令行里的 `%USERPROFILE%`、`%APPDATA%` 全都是干干净净的 `C:\Users\Alex`，日常用了好几个月好像“相安无事”——直到今天一查到底，才发现病根早已四处蔓延。

---

## 第一阶段：深度只读体检——暴露 4 个被长期忽视的隐蔽问题

对本机执行全面只读体检后，我们发现了远比单个软件报错严重得多的现状：

### 1. 反向联接被所有现代语言穿透
测试 Win32 `GetFinalPathNameByHandleW("C:\Users\Alex")`、Go `EvalSymlinks` 与 Python `os.path.realpath("C:\Users\Alex")`，**全部返回了 `C:\Users\张三`**。也就是说，这层英文外壳对底层 API 形同虚设。

### 2. 命中 NTFS 8.3 短路径盲区
实测 `dir /x C:\Users` 与 `GetShortPathNameW` 证实：`张三`（实际案例为 3 个汉字）在 GBK 编码下仅占 6 字节（≤ 8 字节），NTFS 认为它天生符合 8.3 长度限制，**压根没有生成类似 `ZHANGS~1` 的纯 ASCII 短路径**！

### 3. 系统早已“病发”：7.7 GB 乱码幽灵目录
本机系统代码页仍为默认的 `ACP/OEMCP = 936`（GBK）。扫描 `C:\Users` 竟然发现多达 **5 个乱码幽灵目录**，形如：
- `C:\Users\寮犱笁\AppData`（**独占 7.08 GB**！内部堆满了数万个旧 AI 工具运行时缓存文件）
- `C:\Users\寮犱笁\.workbuddy`、`C:\Users\寮犱笁\` 等

追根溯源，这些乱码正是 UTF-8 编码的 `<中文名>\` 字节序列被按 GBK 解码后的产物！同时还发现早年启用用来做联接的内置 **`Administrator` 账户至今未关闭**。

### 4. 发现最关键的迁移雷区：44.6 GB WSL2 Ubuntu
盘点仍指向 `C:\Users\张三` 的高危引用时，揪出了头号隐形炸弹：
- 注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\{GUID}\BasePath` 写死了 `\\?\C:\Users\张三\Ubuntu`，里面躺着 **44.6 GB 的 `ext4.vhdx`**！
- 社区大量案例验证：**WSL2 / Hyper-V 严禁通过 NTFS Junction 挂载 `ext4.vhdx`**。如果不提前发现并在翻转后立刻修正这条注册表，重启回来 WSL2 会瞬间报 `Access is denied` 彻底罢工！

此外还发现用户 `Path` 中残留 6 条旧中文路径、`User Shell Folders` 残留 1 条 OneDrive 路径、旧版 `Shell Folders` 29 项、5 条开机自启动项及工具指针文件 `.lmstudio-home-pointer`。

---

## 第二阶段：为什么放弃「新建账户」，选择「原地翻转方向」？

体检发现本机有两个极佳的有利条件：
1. **本地登录账户名 `Name` 本身已是纯英文**（微软账户绑定仅显示名 `FullName` 为中文），`ProfileImagePath` 也早已是 `C:\Users\Alex`；
2. 机器已深度沉淀近两年的 17+ 用户级开发软件、44.6 GB WSL2 与各类登录态，新建纯英文账户重配需折腾半天到一天。

因此决定采用**方案 A：原地翻转联接方向 + 全套收尾**（0 字节拷贝，数据与 NTFS 权限 100% 原地保留）。

### 前置防呆准备（全部放在 `C:\Users` 之外的 `D:\` 盘）
- 导出 7 个核心注册表 `.reg` 备份 + `icacls` / `fsutil` 快照；
- 创建 Windows 系统还原点；
- 设计**「先重命名实体测锁 → 再删悬空联接 → 实体落位 → 建兜底联接」**防呆脚本，并通过 `-DryRun` 在 PowerShell 5.1 下演练通过。

---

## 第三阶段：第一次实操翻车——「先测锁」救场，顺藤摸瓜揪出内核级真凶 `CldFlt`

用户按流程先注销日常账户、再重启登录内置 `Administrator`，以管理员运行脚本：
- **7 项前置守卫全部 `[OK]`**（确认已是 `Administrator`、且 `HKEY_USERS\<SID>` 中 `NTUSER.DAT` 未加载！）；
- **然而在步骤 1 刚尝试 `[System.IO.Directory]::Move("C:\Users\张三", "C:\Users\Alex_RENAMING_TMP")` 时，系统直接报错：**
  ```text
  Exception calling "Move" with "2" argument(s):
  "Access to the path 'C:\Users\张三' is denied."
  ```
- 脚本尝试暂停 `WSearch`（Windows Search）后重试，依然被拒！

### 防呆设计立大功
因为脚本严格遵循**“先移动实体测锁，成功后再删旧 Junction”**的原子顺序，出错直接安全退出，**`C:\Users\Alex` 联接和 `C:\Users\张三` 实体毫发无损、零改动**！用户无缝切回日常账户继续排查。

### 内核取证：到底是谁在无人登录时锁死了目录？
通过 `fltmc instances -v C:`、`fsutil reparsepoint query` 与 `HKLM\...\SyncRootManager` 逐层深挖，锁定了真正的内核级元凶：

1. **头号元凶：OneDrive 云文件微过滤驱动 `CldFlt`（`cldflt.sys`）**
   - 实测 `C:\Users\张三\OneDrive` 带有 NTFS 云同步根重解析标记（Tag `0x9000701a`），并在 `HKLM\...\Explorer\SyncRootManager` 注册了同步根。
   - **关键知识点**：即使 OneDrive 客户端完全没启动、用户账户也已彻底注销，**只要 `CldFlt` 驱动挂载在 `C:` 卷内核层，Windows 内核就会无条件拦截并拒绝（`Access is denied`）对同步根任何父目录（即 `C:\Users\张三`）的重命名！**
2. **潜在帮凶**：普通启动模式下，`C:` 卷还挂载了安全软件内核过滤驱动（如火绒 `sysdiag`）及数十个第三方常驻服务。

### 验证安全模式前提
排查确认了两个关键条件：
- `manage-bde -status C: D:` → **未开启 BitLocker**（进安全模式无恢复密钥拦截风险）；
- 查询 `HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal` → **最小安全模式下 `CldFlt` 与第三方杀软驱动均不会加载**！

---

## 第四阶段：安全模式（按 4）1 秒一把过！

将脚本升级支持安全模式识别及 `fltmc detach CldFlt` 后，用户采用最稳妥的单次安全模式路径：
1. 先注销日常账户 → 登录界面按住 `Shift` 点击重启 → `疑难解答 → 高级选项 → 启动设置 → 重启 → 按 4`；
2. 安全模式登录 `Administrator`，右键以管理员运行脚本；
3. 顶部直接显示 `[OK] 当前运行于 Windows 安全模式 (SafeBoot=1)`，7 项守卫全绿，输入 `YES` 回车：
   - **步骤 1~4 在 1 秒内全部完成（0 字节拷贝）**！
   - 4 项硬核验收全绿：`C:\Users\Alex` 为物理实体目录、`C:\Users\张三` 为兜底 Junction、`GetFinalPathNameByHandleW` 对新旧路径均返回纯英文 `\\?\C:\Users\Alex`、NTFS ACL 完整保留！

---

## 第五阶段：切回日常账户全套收尾与验收

正常重启登录回日常账户后（先不碰 WSL），一次性执行全套收尾修复：
1. **WSL2 拯救**：修正 `HKCU\...\Lxss\{GUID}\BasePath` → `\\?\C:\Users\Alex\Ubuntu`；实测 `wsl -d Ubuntu -- uname -a` 秒启，44.6 GB 虚拟盘原封不动！
2. **环境变量清零**：无损替换 `Path` 等全部用户环境变量并广播 `WM_SETTINGCHANGE`，实现 `HKCU\Environment` **0 条中文残留**。
3. **注册表同步**：修正 `User Shell Folders`、`Shell Folders`（29 项）、`OneDrive\Accounts\Personal`、`SyncRootManager`、`UserManager\UserPicture`、5 条 `Run` 自启动项及 `.lmstudio-home-pointer`。
4. **安全闭环**：关闭内置 `Administrator`（`Enabled = False`）。
5. **复测原 Bug 彻底根治**：重新直接指向 `C:\Users\Alex\.claude-cage\config.json` 运行此前必崩的沙盒工具，直接 `ExitCode = 0` 通过！Microsoft Store 状态 `Ok`。
6. **释放 7.71 GB C 盘空间**：经跨目录联接安全校验后，用 `robocopy /MIR /XJ` 安全清理 8 个乱码与废弃测试目录（含 8.8 万个旧缓存文件）及 1 条孤儿 `ProfileList` 注册表项。

---

## 总结：沉淀为通用工具集的 6 条黄金经验

| 踩过的坑 | 沉淀到 WinProfileFixer 中的工程防线 |
| :--- | :--- |
| 反向联接被 `EvalSymlinks` / `GetFinalPathNameByHandleW` 穿透 | 阶段 1 体检用 Win32 P/Invoke 直接对比 `ProfileImagePath`、`FinalPath` 与 `ShortPath` |
| `CldFlt` 云文件驱动在无人登录时锁死目录报 `Access Denied` | 阶段 1 提前检测 `fltmc` 与 BitLocker；阶段 3 先测锁再改动 + 优先推荐单次安全模式 |
| Win11 ARSO 锁屏预加载 `NTUSER.DAT` | 阶段 3 守卫 4 强制检查 `Registry::HKEY_USERS\<SID>`，并在指引中强调「先注销再重启」 |
| PowerShell 5.1 无 BOM 导致中文脚本乱码 / CMD 编码错位 | 全套脚本统一 UTF-8 BOM + 原生 .NET/Win32 UTF-16 API，拒绝手敲中文到 CMD |
| 改名后 WSL2 经 Junction 挂 `ext4.vhdx` 报 `Access Denied` | 阶段 4 第一步即修正 `Lxss\*\BasePath` 并自动冒烟验证 |
| 乱码目录深层路径超 260 字符或含内部联接易误删 | 阶段 5 先做跨目录联接安全校验，再用 `robocopy /MIR /XJ` + `\\?\` 扩展路径清理 |

# 交接提示词：移植 Magisk Delta 的 System Mode 到官方 Magisk

> 用法：把下面 `=== 提示词开始 ===` 与 `=== 提示词结束 ===` 之间的内容**原样复制**，粘贴到一个**新对话**（同一工作区 `D:\Magisk`）的第一条消息里发送。
> 配套文件：
> - 实施方案（主文档）：`docs/system_mode_port_plan.md`
> - 逐行取证附录：`.agents/tmp_systemmode_archaeology.md`
> - Magisk Delta 备份源码：`D:\a\KitsuneMagisk`

=== 提示词开始 ===

你是一名资深 Android 系统 / Magisk 内核层开发工程师。请在当前工作区 `D:\Magisk`（官方 Magisk 源码，HEAD = `aed0261c3` "Refactor adb patching and emulator setup"）里，**动手实现**一个功能移植：

> 把 Magisk Delta（`D:\a\KitsuneMagisk`，Magisk 的一个分支，作者 HuskyDG）的 **System Mode** 功能移植过来。该功能的作用是：**在无法 patch boot 镜像的环境（Android 模拟器 AVD、Waydroid、redroid/LXC 等容器化 Android）里，通过直接修改 `/system` 分区来安装 Magisk**，并在重启后依然生效。

该功能在官方 Magisk 里被**彻底删除**了（App / Shell / Native 三层都没有了），所以这是一次跨三层的功能回植，不是打开一个开关。

## 第一步（必做，不要跳过）

按顺序读完这些，再动手写代码：

1. **`docs/system_mode_port_plan.md`** —— 完整实施方案。**必须从头读到尾**，它包含原理、Delta 侧逐函数清单、官方侧差距分析、分阶段代码骨架、22+ 条风险清单、测试矩阵、回滚方案、以及所有关键 `file:line` 索引。这是你的施工图。
2. **`.agents/tmp_systemmode_archaeology.md`** —— 调研阶段的逐行取证附录（约 3400 行，含大量 verbatim 代码和行号）。当方案文档里某个细节你需要核实源码时，先在这里查。
3. **`.agents/skills/magisk-native/SKILL.md`** 与 **`.agents/skills/magisk-app/SKILL.md`** —— 官方仓库对 `native/` 和 `app/` 两个子项目的开发规范（架构、约定、构建流程）。改哪一层就先读哪个。
4. **`AGENTS.md`** —— 仓库级硬性规则（见下文"硬性规则"）。

## 工作区事实（先记住，能省你半天）

| 项 | 值 |
|---|---|
| 目标仓库 | `D:\Magisk`（官方 topjohnwu/Magisk，HEAD `aed0261c3`） |
| 参考仓库（Delta 备份） | `D:\a\KitsuneMagisk`（HEAD `5ed3f41fd`） |
| Delta 的 App 侧安装脚本 | `D:\a\KitsuneMagisk\app\src\main\res\raw\manager.sh`（核心是 `:370-541` 的 `direct_install_system`、`:545-551` 的 `xdirect_install_system`、`:291-318` 的 `magiskrc`、`:52-88` 的 `install_addond`） |
| Delta 的 shell 工具函数 | `D:\a\KitsuneMagisk\scripts\util_functions.sh:741-783`（`is_rootfs` / `mkblknode` / `warn_system_ro` / `remount_check` / `force_bind_mount`） |
| Delta 的 native 实现 | `native/src/core/magisk.cpp:65-144`、`native/src/core/deny/revert.cpp:25-110`、`native/src/core/selinux.cpp:13-21`、`native/src/init/init.cpp:65-77` + `native/src/init/selinux.cpp:12-18` |
| 官方 native 入口（要改） | `native/src/core/magisk.rs`、`native/src/core/lib.rs`（cxx bridge）、`native/src/init/init.rs` |
| 官方 App 入口（要改） | `app/core/.../core/tasks/MagiskInstaller.kt`、`app/core/.../core/Info.kt`、`app/core/.../core/Const.kt`、`app/apk/.../ui/install/{InstallDialog,InstallViewModel}.kt`、`app/apk/.../ui/flash/FlashViewModel.kt` |
| 官方脚本（要改） | `scripts/util_functions.sh`、`scripts/app_functions.sh`、`scripts/addon.d.sh`、`scripts/uninstaller.sh`（可选 `scripts/flash_script.sh`） |
| 资产打包（要改） | `app/build-logic/src/main/java/Setup.kt:170-202`（`include(...)` 列表） |
| ⚠ 工作区已有改动 | `tools/futility` 在本次任务前就被修改过（`git status` 显示 ` M`）。**与本任务无关，不要动它、不要提交它。** |

## 必须遵守的核心结论（12 条铁律，写错任何一条都会导致"装上了但没 root"或 bootloop）

1. **官方没有 `magisk64`**。官方只构建一个 `magisk`（按 ABI），`magisk32` 只是把 32 位 ABI 的 `libmagisk.so` 改名的产物。Delta 的 `magisk64` 命名、`$MAGISKSYSTEMDIR/magisk64`、`symlink ./magisk64 ./magisk` 全部必须改成 `magisk`。
2. **官方没有 `manager.sh`**。官方 App 侧脚本是 `scripts/app_functions.sh`（所有 shell 都加载）与 `scripts/util_functions.sh`（仅 root shell 加载），由 `app/core/.../core/utils/ShellInit.kt:66-69` 注入。
3. **脚本加载顺序不能反**：`ShellInit` 是**先 `app_functions.sh` 后 `util_functions.sh`**。两者定义了同名函数（`mount_partitions` / `get_flags` / `grep_prop` / `run_migrations`），后者覆盖前者。顺序反转会导致 `SYSTEM_AS_ROOT` / `LEGACYSAR` / `CRYPTOTYPE` 判定错误。
4. **可用的环境事实**：`$MAGISKBIN` = `/data/adb/magisk` 由 `scripts/util_functions.sh:763` 在加载时赋值；`BOOTMODE=true` 由 `scripts/app_functions.sh:249` 导出（所以 App 路径下 `direct_install_system` 永远走 boot-mode 分支，recovery 分支是死代码）。
5. **System Mode 的前置条件是"已经能拿到 root"**（Delta 的入口是 `allowSystemInstall = isRooted && !Info.isBootPatched`）。它把临时 root 持久化，不是无 root 引导。因此 shell 一定是 root shell，`util_functions.sh` 已注入。
6. **MAGISKTMP 的判据是 `<dir>/.magisk` 是否存在**（`native/src/core/utils.cpp:33-45`，优先级 **先 `/debug_ramdisk` 后 `/sbin`**）。所以新的 `magisk --setup-sbin` **必须**创建 `<DSTDIR>/.magisk`，否则整个 native 栈认为 Magisk 不在运行。
7. **`magisk --setup-sbin SRCDIR [DSTDIR]` 必须自己创建 `.magisk/worker` 并挂 tmpfs**。官方把 worker tmpfs 的创建放在 magiskinit 里（`native/src/init/mount.cpp:218,235`），System Mode 没有 magiskinit，不补的话模块 magic-mount 的工作区不是 tmpfs。
8. **daemon 必须从 MAGISKTMP 里启动**：`connect_daemon` 校验 `/proc/self/exe` 是否以 `get_magisk_tmp()` 开头（`native/src/core/daemon.rs:457-462`）。所以 init rc 里第一条 `--post-fs-data` 必须用 `$MAGISKTMP/magisk`，不能用 `/system/etc/init/magisk/magisk`。
9. **`magisk --setup-sbin` 必须把 `magisk` 本身拷进 DSTDIR**：daemon 的 `setup_magisk_env()`（`native/src/core/bootstages.rs:70-104`）只会补拷 `busybox` / `magisk32` / `magiskpolicy`，**不会补 `magisk`**。
10. **SELinux 是两段式，都不能省**：
    - 运行时 live patch：init rc 里 **三条** `magiskpolicy --live --magisk`，分别是 `u:r:su:s0` / `u:r:magisk:s0` / `u:r:update_engine:s0` 上下文（不同设备 init 能转换的域不同）。**不要"优化"成一条** —— `magisk_rules()` 里的 `deny * kernel:security load_policy` 会在第一次成功后锁死重载。
    - 磁盘离线 patch：仅当 `! is_rootfs` 时，对 `/vendor/etc/selinux/precompiled_sepolicy`（或 `/odm/...`、`/system/...`、`/system_root/sepolicy*`）做 patch，**必须 gzip 备份 + 失败回滚**。
    - `magiskpolicy --live` 与 `--magisk` 在官方**仍然完整可用**（`native/src/sepolicy/cli.rs:14-18,115-129`）→ 运行时 SELinux patch 零移植成本。
11. **离线 sepolicy patch 推荐零 native 改动方案**：`patch_sepol(in,out)` 等价于
    `magiskpolicy --load IN --magisk --save OUT`（官方 `cli.rs:92,115-117,131-135` 三个开关都在）。
    默认走这条（方案 A）；只有需要严格对齐 Delta 命令名时才在 `magiskinit` 里加 `--patch-sepol`（方案 B，见方案文档 §6 阶段 1.3）。
12. **`is_rootfs()` 必须在 core 里重新实现，并包含 OVERLAYFS magic `0x794c7630`**。官方 `native/src/init/mount.rs:68` 的版本是 `pub(crate)`（core 调不到）且只认 RAMFS/TMPFS，Waydroid 上会判错。

## 其他容易踩的坑（详见方案文档 §7 全部 32 条）

- `installDir` 真实路径是 **`/data/user_de/0/<pkg>/install`**（device-protected 存储，`ServiceLocator.deContext`），`Info.noDataExec` 时被搬到 `/dev/tmp`。脚本里不要硬编码，用传入的 `"$installDir"`。
- `install_addond` 从 **`$MAGISKBIN`（`/data/adb/magisk`）** 拷贝，不是从它的参数；因为 `xdirect_install_system` 里的 `fix_env "$1"` 已经把 `installDir` 刷进 `$MAGISKBIN` 并删掉了源目录。**`fix_env` → `install_addond` 的顺序不可交换**。
- `setup_magisk_env()` 在 `/data/adb/magisk/busybox` 不存在时会 `abort` 整个 Magisk 初始化 → `fix_env` 必须成功执行完。
- Delta 有三个 bug 不要照抄：`unmount_system_mirrors` 未定义；`MIRRORDIR` 作用域越界（恰好无害但应显式处理）；`SDK_INT` 从未被赋值（**不要顺手"修复"**，会改变 `Info.crypto`/`isFDE` 行为）。
- 新的 App 安装方法必须是**独立的 action**（如 `Const.Value.FLASH_MAGISK_SYSTEM = "magisk_system"`），**不要复用 `Const.Value.FLASH_MAGISK`** —— 官方在那个分支里对 `Info.isEmulator` 做了 `MagiskInstaller.Emulator`（只刷 `/data/adb/magisk`）的特殊处理。
- 官方 `magisk` CLI 是 **Rust + `argh` 子命令**（`native/src/core/magisk.rs`）。`--auto-selinux` 在 Delta 是"可出现在任意命令前"的**前缀开关**，argh 表达不了 → 必须在 `magisk_main()` 里做 argv 预处理（`cmds.insert(1, "--")` 之前），不要试图做成普通子命令。
- 官方 `magiskinit` **完全没有 CLI 解析器**（`native/src/init/init.rs:179-200` 只认 `argv[0]=="magisk"` 和 `argv[1]=="selinux_setup"`）→ 加 `--patch-sepol` 是**新增分支**，在 `getpid() == 1` 判断之前插入。
- 官方 `native/src/*/*-rs.cpp` 是 cxx **生成文件**，不要手改。若全部逻辑写在 Rust crate 内部，则**不需要新增任何 FFI**。
- 官方是 **boot-image-patching only**，仓库里 `SYSTEMMODE` / `MAGISK_CONFIG` / `/data/adb/magisk/config` / `goldfish` / `ranchu` / `waydroid` **全部不存在**（用了就会报错或静默失效）。
- 官方有两套安装 UI：`app/apk`（Compose，`InstallDialog.kt`）与 `app/apk-legacy`（XML/DataBinding）。字符串只有一份（`app/core/src/main/res/values/strings.xml`），加一条即覆盖两套；但 ViewModel 层若要两套都能用，需确认 `apk-legacy` 是否仍在构建（见 `docs/build.md`）。

## 施工顺序（严格按这个顺序，每阶段结束都要能独立验证）

### 阶段 1：Native（约 1 天）
- [ ] `native/src/core/setup.rs`（新增）：`is_rootfs()`（含 overlayfs）、`tmpfs_mount()`（source 必须为 `"magisk"`，`mode=755`）、`mount_sbin()`（对齐 Delta `deny/revert.cpp:87-110`，rootfs 与 legacy SAR 两条分支）、`recreate_sbin()`（对齐 Delta `:53-85`）、`setup_sbin(src, dst)`（挂 tmpfs → 拷 `magisk`/`magisk32`/`magiskpolicy`/`stub.apk` → `chdir` → `mkdir .magisk` / `.magisk/device` / `.magisk/worker` + worker tmpfs → applet 软链 `su`/`resetprop`→`./magisk`、`supolicy`→`./magiskpolicy`）。
- [ ] `native/src/core/magisk.rs`：`magisk_main()` 里剥离 `--auto-selinux` 前缀并写 `/proc/self/attr/current`（**带 NUL 结尾**，先试 `u:r:magisk:s0`，失败退化 `u:r:su:s0`，失败不报错继续）；新增 `MagiskAction::SetupSbin`（含可选 DSTDIR，默认 `/sbin`）。
- [ ] `native/src/core/lib.rs`：`mod setup;`（若需要 FFI 才加 bridge）。
- [ ] 编译：`scripts/env.py ./build.py native`（或方案文档 §6 阶段 1.5 的 cargo 方式）。
- **验证**：在已 root 的 AVD 上手工跑 `magisk --setup-sbin /system/etc/init/magisk /sbin`，检查 `/sbin` 是 tmpfs 且含 `.magisk/{device,worker}` 与 applet 软链，`magisk --path` 输出 `/sbin`。

### 阶段 2：Shell（约 1 天）
- [ ] `scripts/util_functions.sh`：追加 `is_rootfs` / `mkblknode` / `warn_system_ro` / `remount_check` / `force_bind_mount` / `random_str`（从 Delta 原样搬，见方案文档 §6 阶段 2.1）。
- [ ] 新增 `scripts/system_mode.sh`：`MAGISKSYSTEMDIR`、`magiskrc()`、`backup_restore()`/`restore_from_bak()`、`cleanup_system_installation()`、`installer_cleanup()`、`direct_install_system()`、`xdirect_install_system()`、`install_addond_system()`。
      以 Delta `manager.sh:282-551` 为蓝本，按方案文档 §6 阶段 2.2 的适配点修改：二进制名单 → `magisk magisk32 magiskpolicy [stub.apk]`；sepolicy patch → `magiskpolicy --load … --magisk --save …`；rc 里 `magisk64` → `magisk`；`install_addond` → 从 `$MAGISKBIN` 拷。
- [ ] `scripts/app_functions.sh`：`app_init()` 里加 `SHA1=$(grep_prop SHA1 $MAGISKTMP/.magisk/config)` → `BOOTIMAGE_PATCHED` → `printvar BOOTIMAGE_PATCHED`。
- [ ] `app/build-logic/src/main/java/Setup.kt:177-180`：`include(...)` 里加 `"system_mode.sh"`。
- [ ] `app/core/.../core/utils/ShellInit.kt`：在 `if (shell.isRoot)` 分支里 `add(context.assets.open("system_mode.sh"))`（放在 `util_functions.sh` **之后**）。
- **验证**：`scripts/env.py ./build.py app`，装到已 root 的 AVD，用 `su -c` 手工执行
      `. /data/adb/magisk/... ; xdirect_install_system "$installDir" "dummy" "$apk"`，检查 `/system/etc/init/magisk*` 落盘、`ls -Z` 上下文正确、重启后 `su` 可用且 `/sbin/.magisk` 存在、logcat 有 "Magisk daemon started"、**不 bootloop**。

### 阶段 3：App（约 0.5–1 天）
- [ ] `app/core/.../core/Info.kt`：加 `var isBootPatched = false`，在 `init()` 里 `isBootPatched = getBool("BOOTIMAGE_PATCHED")`。
- [ ] `app/core/.../core/Const.kt`：加 `const val FLASH_MAGISK_SYSTEM = "magisk_system"`。
- [ ] `app/core/.../core/tasks/MagiskInstaller.kt`：加 `protected suspend fun installSystem() = extractFiles() && "xdirect_install_system \"$installDir\" \"dummy\" \"$AppApkPath\"".sh().isSuccess`，以及 `class System(...) : ConsoleInstaller(...)`。
- [ ] `app/apk/.../ui/flash/FlashViewModel.kt`：`when (action)` 加 `Const.Value.FLASH_MAGISK_SYSTEM -> MagiskInstaller.System(...)`。
- [ ] `app/apk/.../ui/install/InstallViewModel.kt`：`Method` 加 `SYSTEM`；加 `allowSystemInstall = isRooted && !Info.isBootPatched`；`install()` 加分支。
- [ ] `app/apk/.../ui/install/InstallDialog.kt`：在 `if (installVm.isRooted)` 那块旁边加一个 `SettingsArrow`，`if (installVm.allowSystemInstall)` 才显示，**并且加二次确认弹窗**（会改系统分区，必须警告）。
- [ ] `app/core/src/main/res/values/strings.xml`：加 `direct_install_system` + 一条警告文案（翻译可选，`lint { disable += "MissingTranslation" }`）。
- **验证**：全流程从 App 点击安装 → 重启 → root 可用。

### 阶段 4（可选但推荐）：OTA 存活
- [ ] `scripts/addon.d.sh`：加 `SYSTEMINSTALL=false` + `main()` 分支（`SYSTEMINSTALL=true` 时改调 `direct_install_system`），脚本从 `/system/etc/init/magisk/` 里已拷好的副本加载（那里会有 `app_functions.sh`/`util_functions.sh`/`system_mode.sh`/`addon.d.sh`）。
- [ ] `scripts/uninstaller.sh`：加 System Mode 识别（读 `/system/etc/init/magisk/config` 的 `SYSTEMMODE`），删除 `/system/etc/init/magisk*`、`/system/addon.d/99-magisk.sh`，还原 `bootanim.rc`。
- [ ] `scripts/flash_script.sh`（可选）：加 `SYSTEMINSTALL` 分支。⚠ 官方**没有独立安装 ZIP，APK 本身就是刷机包**（`update_binary.sh`/`flash_script.sh` 作为 Java resources 打进 APK），改它会影响 recovery 刷入，必须单独回归。

## 硬性规则（违反会被拒）

1. **绝对不要 `git commit` / `git amend`**，除非用户明确要求。也不要动 `tools/futility`（本来就是 dirty 的）。
2. 独立执行 `gradlew` / `cargo` / `rustc` / `ndk-build` / `cargo clippy` 等工具时，**必须**加 `scripts/env.py` 前缀，例如 `scripts/env.py ./build.py native`、`scripts/env.py ./gradlew assembleDebug`。
3. 改 `native/` 前先读 `.agents/skills/magisk-native/SKILL.md`；改 `app/` 前先读 `.agents/skills/magisk-app/SKILL.md`。
4. 每完成一个阶段，**必须实际编译验证**（`scripts/env.py ./build.py native` / `app`），不要写完就宣称完成。
5. **不要顺手重构无关代码**，不要"修复"Delta 与官方共有的历史行为（如 `SDK_INT` 未赋值），不要把 `bootanim.rc` / recovery / A-only 等分支删掉。
6. 涉及 `/system` 写入的代码路径，**必须**有失败回滚（sepolicy 的 `.gz` 备份还原、rc 的删除/还原）。
7. 不确定时**先读源码求证**（方案文档与取证附录里都有 `file:line`），不要凭印象猜 API 名字。

## 调试与验证手段

- 手工跑 shell 层（推荐先做，比走 App 快得多）：
  ```bash
  adb root
  adb shell 'ls -lZ /system/etc/init/magisk* ; cat /system/etc/init/magisk.rc'
  adb shell 'ls -la /sbin /sbin/.magisk; mount | grep -E "sbin|worker"'
  adb shell 'setprop sys.boot_completed 0; stop; start'   # 或在 AVD 里 Cold Boot Now
  adb shell 'logcat -d | grep -iE "magisk|avc" | tail -200'
  adb shell 'su -c id; /sbin/magisk -v; /sbin/magisk --path'
  ```
- 参考实现（官方已有的、最接近的可工作范例）：`scripts/avd_setup.sh`（tmpfs `/sbin` + `magiskpolicy --live --magisk` + `--post-fs-data`/`--service`/`--boot-complete` 的完整 live 流程，167 行，**强烈建议先通读**）。它是"手工版"的同类流程，能帮你对照排错。
- 测试矩阵见方案文档 §8.1（AVD rootfs / AVD legacy SAR / Waydroid overlayfs / 容器），验收标准见 §8.3。

## 交付与汇报要求

- 每个阶段完成后，用**简短**的结构化汇报：改了哪些文件（带路径）、编译是否通过（贴命令与结果摘要）、在什么设备上验证了什么、剩余风险。
- 遇到无法自行决定的取舍（例如 `apk-legacy` 是否要同步改、`--setup-sbin` 的 DSTDIR 默认值、是否启用 OTA 存活），**停下来问用户**，不要默默选一个。
- 如果编译或运行失败，先读错误信息与相关源码再改；**不要靠猜**。超过 3 次尝试仍未解决时，报告具体现象、已排除的可能、以及需要用户提供的信息（如设备型号/API/是否有 `su`）。

## 开工第一件事

先回读 `docs/system_mode_port_plan.md`（全文），然后**用一段话复述**：这个功能的原理是什么、你打算按什么顺序改哪些文件、第一个要写的函数是什么。复述完再开始写代码。

=== 提示词结束 ===

---

## 附：可选补充（若用户希望新对话更聚焦）

- 只想先做 PoC / 只关心模拟器：可在提示词末尾追加"**本次只做阶段 1 + 阶段 2 + 阶段 3 的最小可用路径，OTA 存活与卸载支持暂缓**"。
- 若希望新对话先只出代码骨架不写实现：追加"**先只产出各文件的改动 diff 草案（不落盘），经我确认后再写入**"。
- 若有多台设备：追加"**优先在 AVD（API 33 x86_64）+ Waydroid 两个环境验证**"。

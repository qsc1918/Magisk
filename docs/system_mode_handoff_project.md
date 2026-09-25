# System Mode 移植 — 项目交接文档（给下一个 AI / 开发者）

> **先读这一份。** 它用最短篇幅说明：现在做到哪了、怎么编译、怎么验证、
> 与原版 Magisk 有哪些不同、哪些坑已经踩过、接下来该改什么。
>
> 配套文档：
> - `docs/system_mode_port_plan.md` — 1300 行施工图（原理 + Delta 逐函数清单 + 32 条风险）
> - `docs/system_mode_verification.md` — 实现与设备验证报告（含每项实测输出）
> - `.agents/tmp_systemmode_archaeology.md` — 约 3400 行逐行取证附录（含 verbatim 代码与行号）
> - `docs/system_mode_handoff_prompt.md` — 最初给"探路 AI"的调研提示词（历史资料）

---

## 0. 一句话状态

Magisk Delta 的 **System Mode**（直接修改 `/system` 分区安装 Magisk，用于模拟器 /
Waydroid / redroid 等无法 patch boot 的环境）**已经完整移植到官方 Magisk**，
Native / Shell / App（Compose + legacy）三层接通，**在真实 Android 12 模拟器上端到端验证通过**
（安装 → 重启 → `magiskd` 以 root 运行 → 模块与 su 授权可用 → 无 bootloop）。

第二轮（2026-09-25）修掉了"装完 App 显示 Magisk 未安装 / su 用不了 / 弹需要修复运行环境"
的两个缺陷（`.magisk/device` 权限位、`env_check` preinit 误报），并在 App 路径上重新端到端验证。
细节见 `docs/system_mode_verification.md` §8。

尚未实测的部分见 §8。

- 目标仓库：`D:\Magisk`（官方 topjohnwu/Magisk，HEAD `aed0261c3`）
- 参考仓库：`D:\a\KitsuneMagisk`（Magisk Delta 备份，HEAD `5ed3f41fd`）
- **未做任何 git commit**（AGENTS.md 规定）。`tools/futility` 的既有改动与本任务无关，未触碰。

---

## 1. 编译与检查（Windows 上必须写成 `python scripts/env.py python ./build.py ...`）

```bash
# Windows / PowerShell（本机）—— 注意多出来的 "python"，见下方警告
python scripts/env.py python ./build.py native       # magisk / magiskinit / magiskboot / magiskpolicy
python scripts/env.py python ./build.py app          # out/app-debug.apk      (Compose UI)
python scripts/env.py python ./build.py app-legacy   # out/apk-legacy-debug.apk (XML/DataBinding UI)
python scripts/env.py python ./build.py clippy       # Rust lint，当前零警告

# POSIX / MSYS bash（文档里原本的写法）
scripts/env.py ./build.py native
```

当前状态：以上四条**全部 exit=0**，clippy 零警告。

> ⚠️ **Windows 上不要直接执行 `scripts/env.py ...`**：`.py` 的文件关联是 PyCharm，
> 命令会变成"用 IDE 打开 env.py"——终端里看起来 exit=0，其实一行代码都没编译，
> 而且会把用户的 IDE 拉起来。必须显式加 `python`，并且让 env.py 用 `python` 去跑
> `build.py`（`build.py` 自身是 shebang 脚本，Windows 无法直接 CreateProcess）。

> ⚠️ 本机 **WSL 不可用**，所以 `bash -n` 不可用。改完 shell 脚本后建议用正则做
> if/fi、case/esac 配平与引号检查（注意：**注释里的撇号**和 `elif` 会被朴素实现误判，
> 需要先剥注释、再剔除字符串字面量，并按"整词"匹配）。

---

## 2. 与原版 Magisk 的核心差异（务必先理解）

| 维度 | 官方 | 本仓库现状 |
|---|---|---|
| 安装方式 | 仅 patch boot 镜像 | **增加** System Mode（直接写 `/system`），原路径完全保留 |
| `magisk` CLI | Rust + argh 子命令 | **新增** `--auto-selinux`（前缀开关）与 `--setup-sbin SRCDIR [DSTDIR]` |
| `magiskinit` CLI | 无 CLI 解析器 | **新增** `--patch-sepol IN [OUT]` 分支 |
| 运行期 tmpfs | 由 `magiskinit` 建立 | System Mode 由 `magisk --setup-sbin` 建立 |
| App 安装入口 | Select patch / Download / Direct / Inactive slot | **新增** Direct install (modify /system directly)，两套 UI 都有 |
| OTA 存活 | `addon.d.sh` 仅 boot patch 路径 | **新增** `SYSTEMINSTALL` 分支 |
| 卸载 | 仅 boot 镜像还原 | **新增** System Mode 识别与 `/system` 清理 |

**关键：System Mode 的前置条件是"已经能拿到 root"**（`adb root` / 现成 `su` / 容器内 uid0）。
它把已有的临时 root **持久化**到 `/system`，**不是**无 root 引导。
入口条件为 `allowSystemInstall = isRooted && !Info.isBootPatched`。

---

## 3. 改动清单（按层）

### Native

| 文件 | 说明 |
|---|---|
| `native/src/core/setup.rs` | **新增**（约 260 行）。`is_rootfs()`（**含 OVERLAYFS `0x794c7630`**）、`tmpfs_mount()`（source 固定 `magisk`）、`bind_mount()`、`recreate_sbin()`、`mount_sbin()`（rootfs / legacy SAR 双分支）、`setup_sbin()`。**`INTERNAL_DIR` / `DEVICEDIR` 必须是 0711**（对齐 magiskinit，见 §7 坑 8） |
| `native/src/core/magisk.rs` | `--auto-selinux` 在 argh 之前做 argv 预处理；新增 `--setup-sbin` 子命令（DSTDIR 默认 `/sbin`）；usage 增补 |
| `native/src/core/lib.rs` | `mod setup;` |
| `native/src/core/daemon.rs` | 抽出 `pub fn setcon(&Utf8CStr) -> bool`，daemon 启动复用（原先内联） |
| `native/src/init/selinux.rs` | **新增** `pub fn patch_sepol(in, out)`：`from_file` → `magisk_rules()` → `to_file`，返回 0/1/2 |
| `native/src/init/init.rs` | `--patch-sepol` 分支，**必须在 `getpid()==1` 判断之前** |
| `native/src/sepolicy/policydb.cpp` | 修 `from_file` 空指针解引用（见 §7 坑 3） |

### Shell

| 文件 | 说明 |
|---|---|
| `scripts/system_mode.sh` | **新增**（约 370 行）。`magiskrc` / `backup_restore` / `restore_from_bak` / `cleanup_system_installation` / `installer_cleanup` / `direct_install_system` / `install_addond_system` / `xdirect_install_system`（含系统 shell 守卫） |
| `scripts/util_functions.sh` | 追加 `is_rootfs` / `mkblknode` / `warn_system_ro` / `remount_check` / `force_bind_mount` / `random_str`；`remount_check` 内含失败诊断 `REMOUNT_FAIL` |
| `scripts/app_functions.sh` | `app_init()` 增加 `SHA1` → `BOOTIMAGE_PATCHED` → `printvar`；`env_check()` 的 preinit 检查补上 `[ -f "$MAGISKTMP/.magisk/config" ]` 守卫（对齐 Delta，见 §7 坑 9） |
| `scripts/addon.d.sh` | `SYSTEMINSTALL` 变量 / `system_install()` / `main()` 分支 / 运行时按 `SYSTEMMODE` 自动判定 / trampoline 对 `/system/addon.d/*` 例外 |
| `scripts/uninstaller.sh` | System Mode 识别 + 清理 `/system/etc/init/magisk*`、还原 `bootanim.rc.gz`、删 `99-magisk.sh` |

### App

| 文件 | 说明 |
|---|---|
| `app/core/.../core/Info.kt` | `var isBootPatched`，由 `BOOTIMAGE_PATCHED` 赋值 |
| `app/core/.../core/AppContext.kt` | libsu Builder 的 `.setTimeout(2)` → `.setTimeout(20)`（**不是**移植引入的缺陷，见 §7 坑 12） |
| `app/core/.../core/Const.kt` | `FLASH_MAGISK_SYSTEM = "magisk_system"`（**独立 action，勿复用 `FLASH_MAGISK`**） |
| `app/core/.../core/tasks/MagiskInstaller.kt` | `installSystem()`；`extractFiles()` 增加 `app_functions.sh` / `system_mode.sh`；`class System : ConsoleInstaller` |
| `app/core/.../core/utils/ShellInit.kt` | root 分支在 `util_functions.sh` **之后**注入 `system_mode.sh` |
| `app/apk/.../ui/flash/FlashViewModel.kt` | `when (action)` 新增分支 |
| `app/apk/.../ui/install/InstallViewModel.kt` | `Method.SYSTEM` / `allowSystemInstall` / `showSystemInstallWarning` |
| `app/apk/.../ui/install/InstallDialog.kt` | 新增入口 + **二次确认弹窗** |
| `app/apk-legacy/.../dialog/SystemModeWarningDialog.kt` | **新增**，legacy 的二次确认 |
| `app/apk-legacy/.../ui/install/InstallViewModel.kt` | 同上（沿用 `spuriousMethodId` / `resetMethod()` 模式） |
| `app/apk-legacy/.../ui/flash/{FlashFragment,FlashViewModel}.kt` | `flashSystem()` + action 分支 |
| `app/apk-legacy/.../res/layout/fragment_install_md2.xml` | `RadioButton id=method_direct_system` |
| `app/build-logic/.../Setup.kt` | assets `include(...)` 加入 `system_mode.sh` |
| `app/core/src/main/res/values{,-zh-rCN,-zh-rTW}/strings.xml` | `direct_install_system` / `direct_install_system_msg` 三语 |

---

## 4. 运行原理（30 秒版）

```
安装期（App 内）：
  MIRRORDIR=/proc/$$/attr  ← 用 tmpfs 盖住它，再 bind mount 真实的 / 与 /system
    → 拿到未被 Magisk overlay 覆盖的"真身" /system，写进去才是真写盘
    → 进程退出挂载自动消失（内核技巧，无需显式 unmount）
  写入：/system/etc/init/magisk/{magisk,magisk32,magiskpolicy,magiskinit,stub.apk,config}
        /system/etc/init/magisk.rc（或追加到 bootanim.rc，并备份 .gz）
        /system/addon.d/99-magisk.sh
  然后 fix_env 把 installDir 刷进 /data/adb/magisk

开机期（原厂 init 执行 rc）：
  post-fs-data:
    magiskpolicy --live --magisk   ×3（u:r:su / u:r:magisk / u:r:update_engine）
    magisk --auto-selinux --setup-sbin /system/etc/init/magisk /sbin
        → 挂 /sbin tmpfs、铺二进制、建 .magisk 哨兵 + .magisk/worker(tmpfs)、建 applet 软链
    /sbin/magisk --auto-selinux --post-fs-data   ← 必须用 /sbin 下的副本启动 daemon
  service / boot-complete / zygote-restart 同理
```

四个必须记住的点：

1. **`.magisk` 目录就是 MAGISKTMP 的判据**（`core/utils.cpp:33-45`），`--setup-sbin` 必须创建它。
2. **daemon 必须从 MAGISKTMP 内启动**（`core/daemon.rs:457-462` 校验 `/proc/self/exe` 前缀），
   所以 rc 第一条 `--post-fs-data` 用 `/sbin/magisk`，不是 `/system/etc/init/magisk/magisk`。
3. **`--setup-sbin` 必须把 `magisk` 本身拷进去**：`setup_magisk_env()` 只补 `busybox`/`magisk32`/`magiskpolicy`，不补 `magisk`。
4. **SELinux 是两段式**：运行期 live patch + 磁盘离线 patch，都不能省。

---

## 5. 验证方法

前置：一个能拿到 root 的模拟器（`adb root` 或现成 `su`）。注意 **`su -c` 在这种
emulator 上会被穿透引号**，用 `su 0 sh <脚本>`。

```bash
# 1) native CLI
adb push native/out/x86_64/magisk /data/local/tmp/m/magisk
adb shell su 0 /data/local/tmp/m/magisk --setup-sbin /data/local/tmp/m /sbin

# 2) 离线 sepolicy patch
adb shell su 0 /data/local/tmp/mi/magiskinit --patch-sepol in out

# 3) 完整安装：用 App 点安装，或手工加载脚本
#    . ./app_functions.sh ; . ./util_functions.sh ; . ./system_mode.sh
#    MAGISK_SYSTEM_MODE_LOADED=1 xdirect_install_system "$installDir" dummy "$apk"

# 4) 重启后验收
adb reboot && sleep 60
adb shell getprop sys.boot_completed          # 1
adb shell ps -A | grep magiskd                # root 用户
adb shell ls -la /sbin/.magisk                # busybox/device/modules/worker
adb shell mount | grep magisk                 # /sbin + /system/bin(注入生效)
```

**验收通过的实际证据**（详见 `docs/system_mode_verification.md`）：
`/sbin` 为 `tmpfs(source=magisk)` 且 SELinux `u:object_r:rootfs:s0`；worker 独立 tmpfs；
`magisk --path` = `/sbin`；`magiskpolicy --load in --magisk --save out` 使 508390 → 524100 字节；
重启后 `magiskd` 以 root 运行且 `/system/bin` 出现 tmpfs（magic-mount 生效）；
App 能读写 Magisk 数据库（Zygisk 开关状态变化）即已获得 root。

---

## 6. 设计决策（有意为之，不要"顺手改"）

1. **sepolicy 离线 patch 走方案 B**（`magiskinit --patch-sepol`），与 Delta 命令名严格对齐；
   方案 A（`magiskpolicy --load IN --magisk --save OUT`）**结果逐字节等价**，保留作手工排错手段。
2. **`magiskinit` 被部署到 `/system/etc/init/magisk/`**，因此 OTA 后仍能离线 patch；
   脚本在 `$INSTALLDIR/magiskinit` 缺失时回退到该目录。
3. **`apk-legacy` 两个 UI 都改了**：字符串只有一份（`:core`），没有重复翻译。
4. **System Mode 强制在系统 shell 中运行**（见 §7 坑 1/1b）：`MagiskInstaller.installSystem()`
   会把 `installDir/bootstrap.sh` 用 `sh <脚本> <apk>` 的形式交给系统 shell；
   `xdirect_install_system` 有 `MAGISK_SYSTEM_MODE_LOADED=1` 守卫，只允许从这个入口进入。
5. **没有往 `MagiskD` 里加字段**：System Mode 的判据一律是文件系统状态
   （`.magisk`、`/system/etc/init/magisk/config`），不是内存标志（避免 `transmute` 错位）。
6. **runtime patch 的三条 `magiskpolicy --live --magisk` 不能合并成一条**：
   `magisk_rules()` 里有 `deny * kernel:security load_policy`，第一次成功后就锁死重载，
   三条是针对不同 init 可转换域的**抢占尝试**。
7. **`SDK_INT` 从未被赋值**（Delta 与官方都如此，`check_encryption()` 里 `[ $SDK_INT -lt 24 ]`
   恒为假）——**不要"修复"它**，会改变 `Info.crypto`/`isFDE` 行为。
8. **`tools/futility` 是 dirty 的**，与本任务无关，不要动、不要提交。

---

## 7. 已经踩过的坑（复现过、已解决）

### 坑 1（最重要）：不要在 App 的 busybox shell 里跑挂载操作

**现象**：App 点安装 → `Segmentation fault` ×3 → `! System partition is read-only`，
但 `/system` 实测可写（`dd` 写 64KB 成功、`mount -o rw,remount /system` rc=0）。

**根因**：`ShellInit.kt` 用 APK 里的 `libbusybox.so` 当 shell（`exec $localBB sh`）。
在 libhoudini 之类的二进制转译环境下，**busybox 的 `mount` applet 会 SIGSEGV**，
于是 `mount -o rw,remount` 从未生效（新加的诊断打印出 `rc=139`，即 128+11），
`remount_check` 读回 `/proc/mounts` 看不到 `rw` → 报"只读"。
用 `/system/bin/sh`（toybox）跑同一段逻辑，每一步都成功。
注意该 busybox 经 `od` 确认是**合法的 x86_64 ELF**，所以不是 ABI 问题。

**修复**：`MagiskInstaller.installSystem()` 用 **Kotlin 直接写出**一个自包含的
`system_mode_bootstrap.sh`（放在 App 私有目录 `context.filesDir/`，**不能放 installDir**，
因为 `fix_env()` 会在脚本还执行到一半时把它整目录删掉），再用**参数**把它交给系统 shell：

```
/system/bin/sh <filesDir>/system_mode_bootstrap.sh "<installDir>" "<apk>"
```

bootstrap 用 `$1` 取 installDir（不用 `${0%/*}`，避免依赖脚本位置），
source 三个脚本后调 `xdirect_install_system`。
`system_mode.sh` 保留 `MAGISK_SYSTEM_MODE_LOADED=1` 守卫，防止从 busybox shell 直接调用。

**为什么由 Kotlin 写文件而不是 shell `echo` 写**：App 第一版曾出现"打完
`- Installing` 直接 `! Installation failed`、零输出"的现象，说明失败发生在 bootstrap
真正执行之前；让 shell 去 echo 十行 + chmod 多了一整层不确定性。改为 Kotlin
`writeText()` 后，脚本一定是完整的，失败也会以 `IOException` 明确抛出来。

**给下一个人的提醒**：**不要**用命令行参数去"绕开"某个崩溃的命令
（比如到处写 `/system/bin/mount`）；正确做法是整体换到系统 shell，
否则下一个崩的可能是 `mkdir`/`dd`。

### 坑 1b：**绝对不要**用 `exec /system/bin/sh` 去"接力换 shell"

这是 §7.1 的第一版修复，**它是错的，而且失败方式很恶劣**：

- **现象**：App 打完 `- Device platform` / `- Installing` 后**静默卡住**，什么都不发生。
- **根因**：libsu 是**逐条**把命令写进 shell 的 stdin 的。`exec` 替换掉外层 shell 后，
  外层已经**缓冲**（或尚未收到）的后续命令随之消失，新 shell 永远等不到输入 → 挂起。
  本地用 busybox sh + stdin 管道复现，结论明确：`exec` 之后**后续命令不可达**（丢失），
  而"参数化启动脚本"方式**可达且可靠**：

  | 写法 | 结果 |
  |---|---|
  | `exec /system/bin/sh` + 后续命令走 stdin | 后续命令**全部丢失**，App 侧表现为卡死 |
  | `sh <bootstrap.sh> <arg>`（参数传递） | 后续命令**可靠执行**，内层确认为 `/system/bin/sh` + `/system/bin/mount` |

- **教训**：不要依赖"shell 换 shell 后继续读同一个 stdin"这种隐式契约；
  要把要执行的东西做成**文件 + 参数**，显式传进去。同时这也让失败可诊断
  （脚本落在 `installDir/bootstrap.sh`，可以直接 cat 出来看）。

### 坑 2：`install_addond_system` 的 mirror 已经失效（Delta 同源缺陷）

`direct_install_system` 末尾的 `installer_cleanup` 已经把 `/proc/$$/attr` 卸载，
紧接着 `install_addond_system` 再往 `$MIRRORDIR$MAGISKSYSTEMDIR` 拷贝必然失败。
Delta 因为 `test ! -d $addond && return` **写反了**（`test ! -d` 对目录为假 → `&& return` 不执行），
反而让它变成死代码而从未暴露。
修复：该函数自建 mirror，mirror 不可写时退化为直接写已挂 rw 的 `/system`。

### 坑 3：`SePolicy::from_file` 空指针解引用（新增 `--patch-sepol` 后暴露）

`native/src/sepolicy/policydb.cpp` 原实现把 `xopen_file` 的返回值直接赋给 `pf.fp` 就交给
`policydb_read`。**输入文件不存在**时 `fp` 为空 → SIGSEGV（rc=139）；
文件存在但内容非法时正常返回 1，所以这个洞长期隐藏。
修复：`if (!fp) return {};`（对合法文件零行为变化，也让 `magiskpolicy --load <不存在的文件>` 不再崩）。

### 坑 4：脚本加载顺序不能反

`app_functions.sh` 与 `util_functions.sh` **定义了同名函数**
（`mount_partitions` / `get_flags` / `grep_prop` / `run_migrations`），后者必须覆盖前者。
`ShellInit.kt` 的顺序是"先 app_functions 后 util_functions"，`system_mode.sh` 必须在**最后**。
顺序反了会导致 `SYSTEM_AS_ROOT` / `LEGACYSAR` / `CRYPTOTYPE` 判定错误。

### 坑 5：`fix_env` 会删掉 installDir

`xdirect_install_system` 里 `fix_env "$1"` 把 `installDir` 刷进 `/data/adb/magisk` 后
`rm -rf` 掉源目录。**因此 `fix_env` 必须排在 `install_addond_system` 之前**
（后者从 `$MAGISKBIN` 取文件），顺序不可交换。

### 坑 6：`--auto-selinux` 必须带 NUL 结尾

写 `/proc/self/attr/current` 时内核接口要求包含 NUL，用 `as_bytes_with_nul()`。
先试 `u:r:magisk:s0`，失败退化 `u:r:su:s0`（首启 live policy 里可能还没有 `magisk` 域）。
**写失败不能报错退出**——SELinux 关闭时它就是会失败。

### 坑 7：`worker` 目录在开机后期不再是 tmpfs（不是 bug）

`bootstages.rs:157-158` 的顺序是 `handle_modules()`（内部 `setup_module_mount()`）**再**
`clean_mounts()`，后者按设计卸载 worker。`magiskinit` 建立的同名 tmpfs 也是同样命运，
对功能无影响。`--setup-sbin` 仍然必须建它（模块 magic-mount 期间需要）。

### 坑 8（第二轮发现，最致命）：`DEVICEDIR` 不能是 mode 000

**现象**：装上 System Mode、重启后一切"看起来正常"（`magiskd` root、`/sbin` tmpfs、
magic-mount 都在），但 App 首页显示 **Magisk 未安装**，安装对话框里
"直接安装（推荐）"与"直接安装（直接修改 /system）"两行**都消失**；
命令行 `su -c id` 输出
`Cannot connect to daemon: Permission denied (os error 13)` + `Illegal instruction`。

**根因链**：daemon socket 在 `$MAGISKTMP/.magisk/device/socket`。
`setup_sbin()` 照抄 Delta 的 `xmkdir(DEVICEDIR, 0)`，而官方 magiskinit 是
`xmkdir(DEVICEDIR, 0711)`。UNIX socket 的 `connect()` 要求父目录**可穿越**，
000 让所有非 root 客户端（manager app 也非 root！）直接吃 `EACCES`：
`Info.isRooted=false` → 首页未安装 + System Mode 入口被
`allowSystemInstall = isRooted && !isBootPatched` 隐藏。
随后 `su.cpp:210` 不校验 `connect_daemon()` 的返回值就把 `fd=-1` 交给
`write_to_fd()`，Rust `File::from_raw_fd(-1)` panic → SIGILL，所以只看到
"su 有命令但用不了"。

**修复**：`INTERNAL_DIR` 与 `DEVICEDIR` 都建 `0711`（并 `follow_link().chmod(0o711)`
兜底）。`WORKERDIR` 保持 `0` + 随后 tmpfs `mode=755`，与 magiskinit 一致。

**给下一个人的提醒**：System Mode 的"验收"不能只看 `magiskd` 在不在、
magic-mount 有没有——**必须**验证非 root 客户端能否连上 daemon
（`adb unroot` 后 `su -c id`，或直接看 App 首页是否认出 Magisk）。

### 坑 9：`env_check` 对 System Mode 误报"需要修复运行环境"

`app_functions.sh` 的 `env_check()` 在 `MAGISK_VER_CODE >= 25210` 时无条件要求
`.magisk/device/preinit`（或 `.magisk/block/preinit`）是块设备。该节点只有
magiskinit 跑过才有（即 `.magisk/config` 由 ramdisk 恢复的 boot-patch 安装）；
System Mode 没有 boot patch → 恒返回 **2** → App 弹
"需要修复运行环境 / 需要重新安装才能使 Magisk 正常工作"。

**修复**：补上 Delta 原有的守卫
`if [ "$2" -ge 25210 ] && [ -f "$MAGISKTMP/.magisk/config" ]; then`。
对官方 boot-patch 路径零行为变化。

### 坑 10：模拟器自带的 su 会消失（**不是**本移植造成的）

MuMu 的 `/system/bin/su`、`/system/xbin/su` 在 System Mode 安装后会从 /system 上
消失。已排除本仓库代码（安装路径上没有任何删 su 的语句；`remove_system_su` 只在
`flash_script.sh`/`addon.d.sh` 调用），也排除了"模拟器开机删 su"（手工放的
`/system/bin/su` 重启后仍存在）。MuMu 自己的 `nemu_sys_opt` / `NewFileUpdater`
负责投送 su，其 telemetry 里此时为 `"root_enabled": false`。

**结论**：模拟器侧既有行为。安装后 root 由 MagiskSU 接管；`adb root` 始终可用，
所以**永远救得回来**（`adb root` → 删 `/system/etc/init/magisk*` 与
`/data/adb/magisk*` → 重启）。

### 坑 11：其他小雷

- rootfs 分支的 `link_path` 在 `/sbin` 为空时会打印 `linkat ... EXDEV`，**无害噪音**。
- `su -c '...'` 在部分 emulator 上被穿透引号，用 `su 0 sh <脚本>`。
- `magiskinit` 的 `--patch-sepol` 必须在 `getpid() == 1` 判断**之前**，否则非 1 号进程直接返回。
- `setcon` 的 `$?` 类陷阱：`X=$(...); echo rc=$?` 取到的是赋值的退出码，不是命令的。

### 坑 12：App 首次启动识别不到 root（官方共有缺陷，已单独修）

`AppContext.kt:93` 的 `.setTimeout(2)` 让 libsu 的 **shell check** 只有 2 秒；
需要弹窗授权的 su（模拟器自带 su、第三方 root）必然超时 → libsu 回退并**永久缓存
一个非 root shell** → `Info.isRooted=false`，App 显示"未安装"、System Mode 入口消失，
**关掉 App 再打开**才能恢复。libsu 自己的默认值是 20 秒。

**修复**：`.setTimeout(2)` → `.setTimeout(20)`。A/B 实测（5 秒延迟的 su）与细节见
`docs/system_mode_verification.md` §8.7。

这条与 System Mode 无关、属于上游共有行为，已单独做成干净分支
`fix-shell-check-timeout`（基于 `aed0261c3`，仅 1 行）并推到 origin，
供用户开 issue / PR；`master` 工作区里也改了同一行但**未提交**。

---

## 8. 未完成 / 未实测（下一步候选）

| 项 | 状态 | 建议 |
|---|---|---|
| Waydroid / redroid（overlayfs 根） | 未实测 | `is_rootfs()` 已含 OVERLAYFS magic，但没有对应环境验证 |
| legacy SAR（API 28 AVD） | 未实测 | `mount_sbin()` 非 rootfs 分支已逐行对齐 Delta |
| OTA 存活闭环 | 未实测 | 需要可刷 OTA 的 ROM；脚本落盘与 `SYSTEMINSTALL=true` 已验证 |
| `uninstaller.sh` 的 System Mode 分支 | 未实测 | 需要先有安装再执行卸载 |
| 32 位-only 设备分支 | 未实测 | 逻辑上是 `magisk32` 缺失时容错 |
| 模块 magic-mount 完整回归 | 部分 | 已确认 `/system/xbin`（或 `/system/bin`）出现注入 tmpfs，未装真实模块跑一遍 |
| Zygisk 开关 | 部分 | App 侧能改写该设置，未验证实际注入 |
| **App 首次启动的 root 识别** | **已修** | `.setTimeout(2)` → `20`；干净分支 `fix-shell-check-timeout` 已推送（见 §7 坑 12、verification §8.7） |
| MuMu 自带 su 消失 | 已定性 | 模拟器侧行为，见 §7 坑 10；恢复靠 `adb root` |

**下一步最该做的**：在一个干净 AVD 上走完整 App 流程（点安装 → 重启 → `su` 到手），
再装一个真实模块验证 magic-mount，最后测卸载。

---

## 9. 给下一个 AI 的工作约定

1. **不要 git commit / amend**，除非用户明确要求。**唯一的例外**：用户已明确要求并批准
   的干净上游修复分支 `fix-shell-check-timeout`（已推送，勿在其上追加移植内容）。
2. 独立执行 `gradlew` / `cargo` / `rustc` / `ndk-build` **必须**加 `scripts/env.py` 前缀；
   **Windows 上写成 `python scripts/env.py python ./build.py <target>`**（见 §1 与下方注意事项）。
3. 改 `native/` 前先读 `.agents/skills/magisk-native/SKILL.md`；改 `app/` 前先读 `.agents/skills/magisk-app/SKILL.md`。
4. 每完成一步**实际编译验证**，不要写完就宣称完成。
5. 涉及 `/system` 写入的路径**必须有失败回滚**（sepolicy 的 `.gz` 还原、rc 的删除/还原）。
6. 不要顺手重构无关代码；不要"修复"Delta 与官方共有的历史行为。
7. 遇到不确定的取舍**先问用户**，不要默默选一个。

### 本机环境注意事项

- **Windows 上必须用 `python scripts/env.py python ./build.py <target>`**。
  直接写 `scripts/env.py ./build.py app` 会被 Windows 按 `.py` 文件关联交给
  PyCharm 打开（表现为"命令 exit=0 / IDE 被拉起来"，实际什么都没编译）。
- **工作区里有多台模拟器**（`adb devices` 可见若干 `emulator-55xx` 与 `127.0.0.1:16xxx`）。
  其中几台**已经被我装过 System Mode**：`/system/etc/init/magisk*` 存在、
  `magiskd` 在跑、**原有 `su` 会被 Magisk 接管**（表现为 `su: inaccessible or not found`）。
  这是**预期状态，不是 bug**。需要干净环境时换一台未使用的实例。
- 这些模拟器上 `/system` 是占位块设备（如 `/dev/block/sda6`，ext4 rw），
  `/` 是 tmpfs(ro)；`is_rootfs` 会判为 true，走 rootfs 分支。
- `ro.kernel.qemu` / `ro.boot.qemu` / `ro.product.device` 在这些模拟器上**都识别不出是模拟器**
  （例如 `ro.product.device` 是 `Draco` / `Piaget`），所以
  `module.rs` 里 "emulator 时保留 `/system/xbin/su`" 的分支**不会**生效，
  Magisk 会直接注入 `/system/xbin`（或 `/system/bin`）并接管 `su`。
- `WSL` 不可用 → 没有 `bash`/`bash -n`；shell 脚本检查要靠自写脚本或人工核对。
- 改完 shell 脚本记得重跑 `build.py app`（脚本是 APK 资产，不打进去改动不生效）。

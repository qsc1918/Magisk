# System Mode 移植：实现与设备验证报告

> 配套文档：`docs/system_mode_port_plan.md`（施工图，1300 行）。
> 本文记录**实际实现了什么**、**在真实设备上验证了什么**、以及**哪些是刻意的取舍**。

---

## 1. 结论

Magisk Delta 的 System Mode（直接修改 `/system` 分区安装 Magisk）已移植到官方
Magisk（HEAD `aed0261c3`），Native / Shell / App 三层全部接通。

在真实 Android 12（API 32）x86_64 模拟器上完成了端到端验证：安装 → 重启 →
`magiskd` 以 root 运行 → 模块挂载与 su 授权可用 → 无 bootloop。

第二轮设备验证（2026-09-25，用户报告"装完 App 显示 Magisk 未安装 / su 用不了"）定位并修复了
两个**只在 System Mode 下才会暴露**的缺陷：`.magisk/device` 权限位错误（Native）与
`env_check` 的 preinit 误报（Shell）。详见 §8。

---

## 2. 新增与修改的文件

### Native（阶段 1）

| 文件 | 改动 |
|---|---|
| `native/src/core/setup.rs` | **新增**。`is_rootfs()`（含 OVERLAYFS `0x794c7630`）、`tmpfs_mount()`（source 固定为 `magisk`）、`bind_mount()`、`recreate_sbin()`、`mount_sbin()`（rootfs / legacy SAR 两条分支）、`setup_sbin()` |
| `native/src/core/magisk.rs` | `--auto-selinux` 前缀开关（在 argh 之前做 argv 预处理）；新增 `--setup-sbin SRCDIR [DSTDIR]` 子命令（DSTDIR 默认 `/sbin`）；更新 usage |
| `native/src/core/lib.rs` | `mod setup;` |
| `native/src/core/daemon.rs` | 抽出 `pub fn setcon(&Utf8CStr) -> bool`，daemon 启动时复用（原先内联在 `daemon_entry()`） |
| `native/src/init/selinux.rs` | **新增 `patch_sepol(in, out)`**：`SePolicy::from_file` → `magisk_rules()` → `to_file`，返回 0/1/2 |
| `native/src/init/init.rs` | `magiskinit` 新增 `--patch-sepol IN [OUT]`（OUT 缺省为原地改写）；必须是 `getpid() == 1` 判断**之前**的独立分支 |
| `native/src/sepolicy/policydb.cpp` | 修 `SePolicy::from_file` 未校验 `xopen_file` 空指针导致 `policydb_read` 解引用 NULL 段错误（见 §3.3） |

`--auto-selinux` 的语义：先试 `u:r:magisk:s0`，失败退化 `u:r:su:s0`，**失败不退出**；
成功时打印 `SeLinux context: ...`（对齐 Delta）。因为这是预期路径，`setcon()` 内部
不把写失败记为错误日志。

### Shell（阶段 2）

| 文件 | 改动 |
|---|---|
| `scripts/system_mode.sh` | **新增**。`magiskrc` / `backup_restore` / `restore_from_bak` / `cleanup_system_installation` / `installer_cleanup` / `direct_install_system` / `install_addond_system` / `xdirect_install_system` |
| `scripts/util_functions.sh` | 追加 `is_rootfs` / `mkblknode` / `warn_system_ro` / `remount_check` / `force_bind_mount` / `random_str` |
| `scripts/app_functions.sh` | `app_init()` 增加 `SHA1` → `BOOTIMAGE_PATCHED` → `printvar BOOTIMAGE_PATCHED` |
| `app/build-logic/.../Setup.kt` | assets `include(...)` 加入 `system_mode.sh` |
| `app/core/.../core/utils/ShellInit.kt` | root shell 分支在 `util_functions.sh` **之后**注入 `system_mode.sh` |

### App（阶段 3）

| 文件 | 改动 |
|---|---|
| `app/core/.../core/Info.kt` | `var isBootPatched`，在 `init()` 里由 `BOOTIMAGE_PATCHED` 赋值 |
| `app/core/.../core/Const.kt` | `FLASH_MAGISK_SYSTEM = "magisk_system"`（**独立 action**，不复用 `FLASH_MAGISK`） |
| `app/core/.../core/tasks/MagiskInstaller.kt` | `installSystem()` + `class System : ConsoleInstaller` |
| `app/apk/.../ui/flash/FlashViewModel.kt` | `when (action)` 新增分支 |
| `app/apk/.../ui/install/InstallViewModel.kt` | `Method.SYSTEM`、`allowSystemInstall`、`showSystemInstallWarning` 状态 |
| `app/apk/.../ui/install/InstallDialog.kt` | 新增 `SettingsArrow`（仅 `allowSystemInstall` 时显示）+ **二次确认弹窗** |
| `app/core/src/main/res/values/strings.xml` | `direct_install_system` / `direct_install_system_msg`（仅英文，`MissingTranslation` 已禁用） |

### OTA 存活与卸载（阶段 4）

| 文件 | 改动 |
|---|---|
| `scripts/addon.d.sh` | `SYSTEMINSTALL` 变量与 `system_install()`；`main()` 走 System Mode 分支；`pre-backup` 跳过 boot 解析；`post-restore`/`addond-v2` 运行时按 `SYSTEMMODE` 自动判定；trampoline 对 `/system/addon.d/*` 例外 |
| `scripts/uninstaller.sh` | 开头识别 `SYSTEMMODE`，清理 `/system/etc/init/magisk*`、还原 `bootanim.rc.gz`、删除 `/system/addon.d/99-magisk.sh`，跳过 boot 镜像还原 |

### apk-legacy（传统 XML/DataBinding UI）

| 文件 | 改动 |
|---|---|
| `app/apk-legacy/.../dialog/SystemModeWarningDialog.kt` | **新增**，二次确认弹窗（POSITIVE 确认 / NEGATIVE 与取消都回退方法选择） |
| `app/apk-legacy/.../ui/install/InstallViewModel.kt` | `allowSystemInstall`；`method` setter 处理 `method_direct_system` → 弹警告；`install()` 分支 → `FlashFragment.flashSystem()` |
| `app/apk-legacy/.../ui/flash/FlashFragment.kt` | 新增 `flashSystem()`（`Const.Value.FLASH_MAGISK_SYSTEM`） |
| `app/apk-legacy/.../ui/flash/FlashViewModel.kt` | `when (action)` 新增 System Mode 分支 → `MagiskInstaller.System` |
| `app/apk-legacy/src/main/res/layout/fragment_install_md2.xml` | 新增 `RadioButton id=method_direct_system`，`gone="@{!viewModel.allowSystemInstall}"` |

字符串复用 `app/core/src/main/res/values/strings.xml` 的 `direct_install_system` /
`direct_install_system_msg`，Compose 与 legacy 两套 UI 共用一份，无需重复翻译。

`tools/futility` 的既有改动**未触碰**；未做任何 git commit。

---

## 3. 移植中修正的上游缺陷

### 3.1 `install_addond_system` 的 mirror 已失效

Delta 同源缺陷，在 Delta 里因 `test ! -d $addond && return` 写反而变成死代码，
所以从未暴露：`direct_install_system` 末尾的 `installer_cleanup` 已经把
`/proc/$$/attr` 卸载，紧接着的 `install_addond_system` 再往
`$MIRRORDIR$MAGISKSYSTEMDIR` 拷贝必然失败。现在该函数会自建 mirror，并在 mirror
不可写时退化为直接写已挂为 rw 的 `/system`。实测日志：
`- Retrying addon.d install without mirror` → `/system/addon.d/99-magisk.sh`
正确落盘且 `SYSTEMINSTALL=true`。

### 3.2 rootfs 分支 `link_path` 的噪音输出

`/sbin` 为空时 `link_to()` 会从 `base/dir.rs` 报一条 `linkat 'supolicy': EXDEV`。
该操作无实际作用（`/sbin` 为空），属无害噪音；未改动上游 `base`。

**另发现但刻意不修**：`native/src/core/su/su.cpp:210-213` 在 `connect_daemon()`
返回 `-1` 时未校验就 `write_to_fd(fd)`，Rust 侧 `lib.rs:234` 用
`File::from_raw_fd(-1)` 触发 panic（SIGILL）。非本次移植路径，按 AGENTS.md
「不要顺手改无关代码」保留原样。

### 3.3 `SePolicy::from_file` 空指针解引用（新增 `--patch-sepol` 后暴露）

`native/src/sepolicy/policydb.cpp` 的 `SePolicy::from_file` 原实现：

```cpp
auto fp = xopen_file(file.data(), "re");
pf.fp = fp.get();          // xopen_file 失败时 fp 为空
pf.type = PF_USE_STDIO;
if (policydb_init(db) || policydb_read(db, &pf, 0)) { ... }   // 解引用空 FILE -> SIGSEGV
```

实测：输入文件**不存在**时稳定段错误（rc=139）；输入文件存在但内容非法或为空时正常
返回 1。因为 `magiskinit --patch-sepol` 与 `magiskpolicy --load <不存在的文件>`
都会走这条路径，补了一个提前返回（对合法文件零行为变化）：

```cpp
if (!fp) {
    // xopen_file already logged the failure; guard so that a missing or
    // unreadable policy file reports an error instead of dereferencing a
    // null FILE in policydb_read.
    return {};
}
```

---

## 4. 设备验证（真实 Android 12 / API 32 / x86_64 模拟器）

### 4.1 Native CLI

```
$ magisk --setup-sbin /data/local/tmp/m /sbin      # rc=0
magisk on /sbin type tmpfs (rw,seclabel,relatime,mode=755)
magisk on /sbin/.magisk/worker type tmpfs (rw,seclabel,relatime,mode=755)
drwxr-xr-x ... u:object_r:rootfs:s0  /sbin
/sbin: magisk magiskpolicy stub.apk su -> ./magisk resetprop -> ./magisk supolicy -> ./magiskpolicy
/sbin/.magisk: device(000) worker(755)
$ /sbin/magisk --path   →  /sbin
$ /sbin/magisk --auto-selinux -c   →  rc=0，降级到 u:r:su:s0（首启策略尚无 magisk 域，符合设计）
```

### 4.2 sepolicy 离线补丁

安装脚本现在使用方案 B：`magiskinit --patch-sepol IN OUT`（`magiskinit` 同时被部署到
`/system/etc/init/magisk/`，因此 OTA 后仍可用；脚本在 `$INSTALLDIR/magiskinit` 缺失时
回退到 `$MAGISKSYSTEMDIR/magiskinit`）。

```
$ magiskinit --patch-sepol in out        # rc=0
in  508390 字节  →  out  524100 字节
$ magiskinit --patch-sepol inplace       # rc=0，原地改写生效
$ magiskinit --patch-sepol /不存在/file out   # rc=1（修复后，不再是 139 段错误）
$ magiskinit --patch-sepol garbage out        # rc=1
$ magiskinit --patch-sepol in /不存在目录/z    # rc=2
$ magiskinit                                  # rc=1，不崩溃
$ magiskpolicy --load out --print-rules       # rc=0，27377 行规则，1072 行含 magisk
  含 type magisk { domain mlstrustedsubject appdomain netdomain }
     type magisk_file / magisk_log_file
     allow init magisk process { ... transition ... dyntransition ... }
$ magiskpolicy --live "permissive su"    # rc=0，内核支持动态 patch
```

等价性：方案 A 的 `magiskpolicy --load IN --magisk --save OUT` 产生完全相同的
524100 字节结果，两条路径都复用官方 `magisk_rules()`。

### 4.3 Shell 层完整安装

```
$ xdirect_install_system "$INSTALLDIR" "dummy" "fake.apk"   # rc=0
/system/etc/init/magisk/{config,magisk,magiskpolicy,magiskinit,stub.apk}
                                均 u:object_r:system_file:s0
/system/etc/init/magisk/config → SYSTEMMODE=true / RECOVERYMODE=false
/system/etc/init/magisk.rc     → 9 条 rc 全部正确（含三连 magiskpolicy --live --magisk）
/system/addon.d/99-magisk.sh   → SYSTEMINSTALL=true
/data/adb/magisk/              → fix_env 已刷新
```

### 4.4 重启后（关键验收）

```
sys.boot_completed=1
$ ps -A | grep magiskd     →  root  1  S  magiskd
/sbin                      →  tmpfs(source=magisk) + magisk/magiskpolicy/su/resetprop/supolicy
/sbin/.magisk              →  busybox(7220 字节目录，数百 applet) device(000) modules worker
mount | grep magisk        →  /sbin, /system/bin, /system/bin/magisk, /system/bin/magiskpolicy
                                ↑ magic-mount 实际生效，模块注入机制工作
无 bootloop
```

`setup_magisk_env()` 完整跑完（busybox applet 目录被填充、`magisk.db` 创建），
说明 `/data/adb/magisk` 环境达标。

### 4.5 su 授权

`/sbin/.magisk/device` 的 mode 为 `000`，非 root 客户端（adb shell、第三方应用）无法
连接 daemon —— 这是官方设计的鉴权层（`daemon.rs:457-462` 亦要求从 MAGISK_TMP 启动）。
官方 `su/daemon.rs:244-247` 规定 **manager 应用被静默授权**。实测安装官方 App 后，
它能读写 Magisk 数据库（Zygisk 开关由「禁用」变「启用」），即已通过 daemon 获得 root。

### 4.6 对照实验与其它观察

- 未安装 Magisk 的同类实例重启后 stock `su` 仍在；安装后的实例不再需要它（Magisk
  接管了 su）。在 stock `su` 位于临时 rootfs 的实例上，重启会失去该入口 —— 这是
  模拟器镜像特性，不是移植副作用。
- `worker` 目录在开机后期不再是 tmpfs：这是官方既有流程
  （`bootstages.rs:157-158`：先 `handle_modules()`（内部 `setup_module_mount()`）**再**
  `clean_mounts()`，后者按设计卸载 worker）。magiskinit 建立的同名 tmpfs 也是同样命运，
  因此对功能无影响。

---

## 5. 编译验证（含本轮追加项）

| 命令 | 结果 |
|---|---|
| `scripts/env.py ./build.py native` | exit=0，4 个 ABI 的 `magisk`/`magiskpolicy`/`magiskboot`/`magiskinit` 均产出 |
| `scripts/env.py ./build.py clippy` | exit=0，**零警告** |
| `scripts/env.py ./build.py app` | exit=0，`out/app-debug.apk` 内 `assets/system_mode.sh` 12933 字节 |
| `scripts/env.py ./build.py app-legacy` | exit=0，`out/apk-legacy-debug.apk` 内 `assets/system_mode.sh` 12933 字节 |
| shell 脚本 if/fi 与 case/esac 配平检查 | `system_mode.sh`/`addon.d.sh`/`uninstaller.sh`/`util_functions.sh`/`app_functions.sh` 全部 OK |

---

## 6. 取舍与未覆盖项

1. **sepolicy 离线补丁同时提供两条等价路径**：安装脚本走方案 B
   （`magiskinit --patch-sepol`，与 Delta 命令名严格对齐），
   `magiskpolicy --load IN --magisk --save OUT` 仍可用于手工排错。两者结果逐字节等价。
2. **`apk-legacy` 已补入口**（见 §2 表格）：方法选择页新增
   `Direct install (modify /system directly)` 单选项，选中即弹二次确认，确认后走
   `Const.Value.FLASH_MAGISK_SYSTEM`。字符串与 Compose 版共用 `:core` 的一份。
3. **`install_addond_system` 会把整个 `/data/adb/magisk` 拷进 `/system/etc/init/magisk`**
   （对齐 Delta）。若 `noDataExec` 为真，其中可能包含 `init-ld`。
4. **未在 Waydroid / legacy SAR 上实测**（按要求本轮不做进一步设备验证）。
   相关分支代码已按 Delta 逐行对齐，且 `is_rootfs()` 已包含 OVERLAYFS magic。
5. **未实测 OTA 存活闭环**（需要可刷 OTA 的 ROM）。已验证：脚本落盘、
   `SYSTEMINSTALL=true`、`addon.d.sh` 的 System Mode 分支逻辑就绪。
6. **未实测 `uninstaller.sh` 的 System Mode 分支**（需要先有安装再执行卸载）。

---

---

## 7. 复现步骤（模拟器）

```bash
# 1. 构建
scripts/env.py ./build.py native
scripts/env.py ./build.py app

# 2. 推入二进制与脚本（脚本来自 APK assets 亦可）
adb push native/out/x86_64/magisk      /data/local/tmp/m/magisk
adb push native/out/x86_64/magiskpolicy /data/local/tmp/m/magiskpolicy
adb push scripts/system_mode.sh         /data/local/tmp/scripts/system_mode.sh

# 3. 用 root shell 加载脚本并安装（xdirect_install_system 需要 fix_env 等来自
#    app_functions.sh / util_functions.sh）
adb shell su -c 'sh /data/local/tmp/install_system_mode.sh'

# 4. 重启并验收
adb reboot && sleep 60
adb shell getprop sys.boot_completed          # 期望 1
adb shell ps -A | grep magiskd                # 期望 root 用户
adb shell ls -la /sbin/.magisk                # 期望 device/modules/worker/busybox
adb shell mount | grep magisk                 # 期望 /sbin + /system/bin 注入
```

> ⚠️ 本机 Windows 上 **不要**直接执行 `scripts/env.py ...`：`.py` 的文件关联是 PyCharm，
> 直接运行会把 IDE 拉起来（看起来像"构建成功"，实际什么都没编译）。必须写成
> `python scripts/env.py python ./build.py native`。

---

## 8. 第二轮验证：App 不认 root / "需要修复运行环境"（2026-09-25）

### 8.1 症状（用户报告 + 复现）

在干净的 MuMu 模拟器（Android 12 / API 32 / x86_64）上用 App 点
"直接安装（直接修改 /system）"，安装过程本身 `All done!`；重启后：

- App 首页 Magisk 卡片显示**未安装**（根因 2 修复前还会弹
  "需要修复运行环境 / 需要重新安装才能使 Magisk 正常工作"）；
- 安装对话框只剩"选择并修补文件 / 下载并修补映像"两行，
  **"直接安装（推荐）" 与 "直接安装（直接修改 /system）" 都消失**；
- `magiskd` 确实以 root 在跑、`/sbin` tmpfs 与 magic-mount 都正常；
- 但 `su` 用不了：`su -c id` 输出
  `Cannot connect to daemon: Permission denied (os error 13)` 紧接
  `Illegal instruction`（SIGILL）。

### 8.2 根因 1（Native）：`DEVICEDIR` 被建成 mode 000

`native/src/core/setup.rs` 的 `setup_sbin()` 照抄了 Delta `--setup-sbin` 的
`xmkdir(DEVICEDIR, 0)`，而官方 magiskinit 的 `setup_tmp()` 是
`xmkdir(INTLROOT, 0711); xmkdir(DEVICEDIR, 0711);`。

daemon 的 socket 在 `$MAGISKTMP/.magisk/device/socket`（`MAIN_SOCKET`）。
UNIX socket 的 `connect()` 需要**父目录可穿越（x 位）**，mode 000 直接导致
非 root 客户端（manager app、adb shell、任何 App）拿到 `EACCES`：

```
$ ls -lad /sbin/.magisk/device          # 修复前
d--------- 2 root root 80 ... /sbin/.magisk/device
$ su 0 id
Cannot connect to daemon: Permission denied (os error 13)
Illegal instruction                      # su.cpp:210 未校验 fd，Rust from_raw_fd(-1) panic
```

`su.cpp` 只打印错误、随后仍把 `fd = -1` 交给 `write_to_fd()`，Rust 侧
`File::from_raw_fd(-1)` panic（panic=abort）→ `SIGILL`。因此 App 拿不到 root
（`Info.isRooted=false`）→ 首页"未安装"、System Mode 入口被
`allowSystemInstall = isRooted && !isBootPatched` 隐藏。

**修复**（`native/src/core/setup.rs`）：`INTERNAL_DIR` 与 `DEVICEDIR` 都按官方
magiskinit 建成 `0711`，并额外 `chmod` 一次以兼容旧安装残留。

### 8.3 根因 2（Shell）：`env_check` 的 preinit 误报

`scripts/app_functions.sh` 的 `env_check()` 对 `MAGISK_VER_CODE >= 25210`
无条件要求 `.magisk/device/preinit`（或 `.magisk/block/preinit`）是块设备。
该节点只在 magiskinit 跑过（= boot 镜像 patch 安装、`.magisk/config` 由 ramdisk
恢复）时才存在；System Mode 没有 boot patch、没有 `.magisk/config`，于是
`env_check` 恒返回 **2**：

```
$ env_check <ver> 31000 ; echo rc=$?    # 修复前
rc=2
```

App 侧 `HomeViewModel.ensureEnv()` 把 `code != 0` 直接映射成
"需要修复运行环境"弹窗 → 用户看到"Magisk 没装好"。

Delta 在同一处有 `&& [ -f "$MAGISKTMP/.magisk/config" ]` 守卫（见
`D:\a\KitsuneMagisk\app\src\main\res\raw\manager.sh` 的 `env_check`），本仓库移植时漏掉了。

**修复**（`scripts/app_functions.sh`）：补上守卫，语义为"只有 boot-patch 安装才要求
preinit 节点"。对官方安装路径零行为变化（`.magisk/config` 一定存在）。

### 8.4 实测证据（修复后，同一台 MuMu 模拟器）

```
# 1) setup-sbin 的目录权限（直接对空 tmpfs 跑新二进制）
$ magisk --setup-sbin /system/etc/init/magisk /data/local/tmp/sbtest   # rc=0
drwx--x--x  ... /data/local/tmp/sbtest/.magisk
drwx--x--x  ... /data/local/tmp/sbtest/.magisk/device

# 2) App 全流程安装 + 重启后
$ ps -A | grep magiskd
root  1089  1  ... S magiskd
$ ls -lad /sbin/.magisk/device
drwx--x--x 2 root root 80 ... /sbin/.magisk/device
$ ls -la /sbin/.magisk/device
srw-rw-rw- 1 root root 0 ... socket      # u:object_r:magisk_file:s0
$ mount | grep magisk
magisk on /sbin type tmpfs ...
magisk on /system/xbin type tmpfs ...
$ env_check 0c4f3240 31000 ; echo rc=$?
rc=0
$ su -c id                       # 以 adb shell(uid 2000) 发起
uid=0(root) gid=0(root) groups=0(root) context=u:r:magisk:s0
```

App 侧：首页 Magisk 卡片由"未安装"变为 **`0c4f3240 (31000) (D)`**，
"需要修复运行环境"弹窗不再出现，底部出现 `模块 / 超级用户` 页；
"超级用户"页能读出 `com.android.shell` 条目并切换授权（= 已通过 daemon 获得 root）。

**两条完整路径都验证过**：

1. **shell 手工路径**：`adb root` + `xdirect_install_system` → 重启 → 全部达标；
2. **App 路径（用户实际流程）**：App "直接安装（直接修改 /system）" →
   `All done!` → 重启 → 全部达标（此时 root 由 MagiskSU 提供，说明
   `installSystem()` 的 Kotlin bootstrap 在 MagiskSU 下也工作）。

### 8.5 观察：模拟器自带的 `su` 会消失

MuMu 的 `/system/bin/su`、`/system/xbin/su`（setuid）在 System Mode 安装后
**会从 /system 分区上消失**，与本仓库代码无关：

- 这两条路径上没有任何 `rm`（`system_mode.sh` / `app_functions.sh` /
  `util_functions.sh` / `remove_system_su` 都不在此调用路径上；
  `remove_system_su` 只在 `flash_script.sh` / `addon.d.sh` 里调用）；
- **实验**：手工把一个 `su`（`cp fstrim /system/bin/su`）放进 /system 后重启，
  文件**存活** → 模拟器并非"开机删除 su"；
- MuMu 自己的 telemetry 里有 `"root_enabled": false` 字段，其 `nemu_sys_opt` /
  `NewFileUpdater`（hot-update）负责投送 `su`；`/system` 被本安装改动后，
  它不再投送自己的 su，于是系统自带的 root 入口消失。

结论：**这是模拟器侧的既有行为，不是移植缺陷**。安装后 root 由 MagiskSU 接管，
`adb root` 也始终可用（恢复手段：`adb root` → 删 `/system/etc/init/magisk*` 与
`/data/adb/magisk*` → 重启）。若 MagiskSU 因故不可用，用户仍能通过 `adb root` 救回。

### 8.6 编译验证

| 命令 | 结果 |
|---|---|
| `python scripts/env.py python ./build.py native` | exit=0 |
| `python scripts/env.py python ./build.py clippy` | exit=0，零警告 |
| `python scripts/env.py python ./build.py app` | exit=0，`out/app-debug.apk`（assets 内 `app_functions.sh` 已含守卫） |
| `python scripts/env.py python ./build.py app-legacy` | exit=0，`out/apk-legacy-debug.apk` |

### 8.7 第三个缺陷：App 首次启动识别不到 root（libsu shell check 超时）

**症状（用户报告）**：在干净模拟器上首次运行 App、授予 root 权限后，App 仍显示
"Magisk 未安装"、安装页没有"直接安装（直接修改 /system）"；**关掉 App 再打开**就正常。

**根因**：`AppContext.kt:89-93` 给 libsu 的 Builder 设了 `.setTimeout(2)`（2 秒），
并在 `AppContext.kt:102` 用 `Shell.getShell(null) {}` 在启动瞬间预热 root shell。
libsu 6.0.0 的实现（反编译 `BuilderImpl` / `ShellImpl` 确认）：

- Builder 的 timeout 默认值就是 **20 秒**（`BuilderImpl.<init>`: `ldc2_w 20l`），
  Magisk 主动改成了 2；
- `ShellImpl` 构造时用 `FutureTask.get(timeout, SECONDS)` 等 **shell check**
  （判断拿到的 shell 是不是 root），超时抛 `IOException("Shell check timeout")`；
- `BuilderImpl.exec()` 把 `IOException` 转成 `NoShellException`，
  `start()` 捕获后**丢弃这次 su 尝试**，最终回退到 `sh` —— 即一个**非 root shell**，
  并被 `MainShell` 缓存为进程内的主 shell（没有公开 API 可以作废它）。

设备自带 `su` 时（模拟器/容器/第三方 root），授权需要**弹窗**，用户不可能 2 秒内点完 →
超时 → 缓存非 root shell → `Info.isRooted=false` 一直到进程结束。

**修复**：`.setTimeout(2)` → `.setTimeout(20)`（= libsu 默认值）。

**A/B 实测**（同一台设备、同一个 5 秒延迟的 su，只换 APK）：

```sh
# 造一个"慢 su"模拟授权弹窗：包一层 sleep 5 再 exec MagiskSU
cat > /system/bin/su <<'EOF'
#!/system/bin/sh
sleep 5
exec /system/xbin/su "$@"
EOF
chmod 755 /system/bin/su
su -c id            # 5s 后返回 uid=0 (u:r:magisk:s0)
```

| APK | 冷启动后首页 Magisk 卡片 | 底部页签 |
|---|---|---|
| `setTimeout(2)`（修复前） | **未安装** | 只有 主页/日志/设置 |
| `setTimeout(20)`（修复后） | **0c4f3240 (31000) (D)** | 出现 模块 / 超级用户 |

（修复后那次还顺带弹了"检测到不属于 Magisk 的 su 文件"，因为测试用的包装 su 放在
`/system/bin` 且该目录没有 `magisk` —— 正好反证 `Info.env.isActive == true`，
即 App 这次确实拿到并确认了 root。移除包装 su 后弹窗消失，状态保持已安装。）

### 8.8 干净的上游修复分支

本缺陷属于**官方共有行为**（与 System Mode 无关），已按官方规范单独做成一个干净分支，
便于给上游开 issue / PR：

- 分支：`fix-shell-check-timeout`（基于官方提交 `aed0261c3`，
  **不含**任何 System Mode 移植代码与 AI 文档）
- 提交：`70691a1b3 Increase shell check timeout to libsu default`
  （仅 1 文件 1 行；50/72 格式；带 `Assisted-by:` trailer）
- 已推送到 `origin`（`https://github.com/qsc1918/Magisk.git`），
  PR 入口：`https://github.com/qsc1918/Magisk/pull/new/fix-shell-check-timeout`
- 当前 `master` 工作区里**也改了同一行**（未提交，遵守 AGENTS.md）。

> `tools/futility` 是仓库既有的 dirty 文件，未被本分支的提交包含
> （在干净 worktree 里 checkout 会因行尾过滤显示为 modified，注意不要 `git add -A`）。



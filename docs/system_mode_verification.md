# System Mode 移植：实现与设备验证报告

> 配套文档：`docs/system_mode_port_plan.md`（施工图，1300 行）。
> 本文记录**实际实现了什么**、**在真实设备上验证了什么**、以及**哪些是刻意的取舍**。

---

## 1. 结论

Magisk Delta 的 System Mode（直接修改 `/system` 分区安装 Magisk）已移植到官方
Magisk（HEAD `aed0261c3`），Native / Shell / App 三层全部接通。

在真实 Android 12（API 32）x86_64 模拟器上完成了端到端验证：安装 → 重启 →
`magiskd` 以 root 运行 → 模块挂载与 su 授权可用 → 无 bootloop。

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

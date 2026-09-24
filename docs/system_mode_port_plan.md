# Magisk Delta「System Mode」移植技术方案（直接把 Magisk 安装进 /system）

> 目标读者：明天负责写代码的 AI / 开发者。
> 本文只做**调研结论 + 技术路线 + 落地细节**，不含实现提交。
>
> 基线仓库：
> - 目标仓库（官方最新版）：`D:\Magisk`，HEAD = `aed0261c3dc877221b9f4ef04c0735383cbba16c`（"Refactor adb patching and emulator setup"，2026-09-21）
> - 参考仓库（Magisk Delta 备份）：`D:\a\KitsuneMagisk`，HEAD = `5ed3f41fd`
>
> 结论先行：**这个功能在官方版本里被完全删除了（App / Shell / Native 三层都被删或重写），不能靠"打开开关"或"复制一个脚本"完成，必须做一次跨三层的功能回植。** 好在其依赖的底层能力（SELinux 规则引擎、`magiskpolicy --live --magisk`、`SePolicy::from_file/to_file/magisk_rules`、tmpfs 挂载/`recreate_sbin` 逻辑、`app_functions.sh` 骨架）在官方版本里**依然存在**，因此移植是"重新接线 + 重新写入口"，而不是"从零发明"。

---

## 目录

1. [术语与结论速览](#1-术语与结论速览)
2. [为什么需要 System Mode（需求与现有替代方案的不足）](#2-为什么需要-system-mode需求与现有替代方案的不足)
3. [System Mode 运行时原理（核心章节）](#3-system-mode-运行时原理核心章节)
4. [Delta 侧实现清单（逐文件、逐函数）](#4-delta-侧实现清单逐文件逐函数)
5. [官方仓库现状与差距分析](#5-官方仓库现状与差距分析)
6. [移植技术路线（分阶段、可执行）](#6-移植技术路线分阶段可执行)
7. [关键风险与技术注意事项](#7-关键风险与技术注意事项)
8. [验证方案（模拟器 / 容器测试矩阵）](#8-验证方案模拟器--容器测试矩阵)
9. [回滚与卸载](#9-回滚与卸载)
10. [附录（文件对照表、CLI 对照表、待确认问题）](#10-附录)
11. [交付物与工作区状态](#11-交付物与工作区状态)

---

## 1. 术语与结论速览

| 术语 | 含义 |
|---|---|
| System Mode（系统模式 / system install） | Delta 的安装方式：把 Magisk 的二进制和 init 启动脚本**直接写进 `/system` 分区**，不修改 boot 镜像 |
| Systemless（无系统模式，官方默认） | Magisk 正常模式：patch boot 镜像，运行时用 tmpfs + overlay 模拟修改，不动 `/system` |
| `MAGISKTMP` | Magisk 运行时的 tmpfs 目录，官方为 `/debug_ramdisk` 或 `/sbin`；**判据是 `<dir>/.magisk` 是否存在** |
| `DATABIN` | `/data/adb/magisk`，存放从 APK 解出的二进制与脚本 |
| `MAGISKSYSTEMDIR`（Delta 命名） | `/system/etc/init/magisk`，System Mode 下二进制与 `config` 的落盘目录 |
| `magiskrc` | Delta 生成的 init rc 片段，由 init 在 `post-fs-data` 阶段执行 |
| `--auto-selinux` | Delta 给 `magisk` 增加的 argv 前缀开关：把自己进程的 SELinux 上下文切成 `u:r:magisk:s0`（失败退化为 `u:r:su:s0`） |
| `--setup-sbin` | Delta 给 `magisk` 增加的命令：挂 tmpfs、铺二进制、建 applet 软链、创建 `.magisk` 哨兵目录 |
| `--patch-sepol` | Delta 给 `magiskinit` 增加的命令：离线把 magisk 规则打进磁盘上的 sepolicy 文件 |

### 1.1 必须移植的四层（缺一不可）

| 层 | 内容 | 工作量 | 难度 |
|---|---|---|---|
| Native | 3 个 CLI：`magisk --auto-selinux`、`magisk --setup-sbin/--mount-sbin`、`magiskinit --patch-sepol` | 中 | **高**（需要按官方 Rust 架构重写，且要处理 tmpfs 自举、SELinux 上下文、worker 目录缺失） |
| Shell | `direct_install_system` / `cleanup_system_installation` / `xdirect_install_system` / `install_addond` / `magiskrc` + 6 个工具函数 | 中大 | 中（逻辑已存在，但依赖的函数官方已删除，需要一并搬回） |
| App | 安装入口 UI、`InstallViewModel.Method`、`FlashViewModel` 分支、`MagiskInstaller.System`、`Const.Value`、`Info.isBootPatched`、字符串 | 中 | 中（官方 App 已拆模块 + Compose 重写，路径与 Delta 完全不同） |
| OTA | `addon.d.sh` 的 `SYSTEMINSTALL` 分支（可选但推荐） | 小 | 低 |

> **重要前提：** Delta 的 System Mode 只在**已经能拿到 root**（`adb root` / 现成 `su` / 容器内 uid0）但 boot 未 patch 时提供。它把"临时 root"变成"持久 root"，**不是**在完全未 root 的设备上引导 root。详见 §3.4 前置条件与 §6 阶段 3.4.1。

### 1.2 一句话技术路线

> 在官方 Rust 架构上新增一个 `magisk --setup-sbin`（挂 `/sbin` tmpfs + 铺二进制 + 建 `.magisk` 哨兵 + 建 `worker` 目录），新增 `magisk --auto-selinux` 前缀开关（把 `/proc/self/attr/current` 写成 `u:r:magisk:s0`，退化 `u:r:su:s0`），sepolicy 离线 patch 优先复用官方现成的 `magiskpolicy --load IN --magisk --save OUT`（**不必新增 native 代码**）；新增 shell 脚本 `scripts/system_mode.sh` 承载 Delta 的 `direct_install_system` / `xdirect_install_system` / `magiskrc` / `cleanup_system_installation` / `install_addond`，加上 6 个被官方删除的工具函数（`is_rootfs` / `mkblknode` / `warn_system_ro` / `remount_check` / `force_bind_mount` / `random_str`）；App 侧新增一个安装方法，把命令 `xdirect_install_system "<installDir>" "dummy" "<AppApkPath>"` 交给已有的持久 root shell 执行。

---

## 2. 为什么需要 System Mode（需求与现有替代方案的不足）

### 2.1 目标环境特征

- Android 模拟器（AVD，`goldfish`/`ranchu`/`vsoc`）、Waydroid、LXC/容器化 Android（如 redroid）、部分云手机。
- 这些环境 **boot 镜像无法 patch**（没有可写的 boot 分区、镜像在宿主机上、或 patched boot 无法启动）。
- 但它们几乎都满足：`adb root` 可用 或 已是 root 容器；`/system` 可 remount rw 或本身可写。
- 它们的 stock sepolicy 通常包含 `su` 域（eng/userdebug 镜像），或允许 `init` 做 `dyntransition`。

### 2.2 官方现有的"模拟器方案"及其局限

官方现在有两条与模拟器相关的路径，都**不是** System Mode：

1. `build.py emulator` → `scripts/avd_setup.sh`（PC 侧 adb 推送 + 执行）
   - 做法：`magisk --stop`、停 zygote、在 `/sbin` 或 `/debug_ramdisk` **挂 tmpfs**、把二进制拷进 tmpfs、`magiskpolicy --live --magisk`、`magisk --post-fs-data`、`magisk --service`、`start`。
   - 特点：**临时**（tmpfs，重启即失效）、**需要已有 root**（脚本内部 `exec /system/xbin/su 0 ...`）、**需要 PC + adb**、**不写任何持久化内容到 `/system`**。
   - 与 System Mode 的关系：它是 System Mode 启动流程的"手工版"，可以拿来做**对照实验与调试参考**（`scripts/avd_setup.sh` 就是"没有 init.rc、手动执行 rc 里的命令"）。
2. `build.py patch [--avd]` → `scripts/adb_patch.sh` / `scripts/avd_patch.sh`
   - 在 PC 侧通过 adb 在设备上运行 `magiskboot`/`boot_patch.sh` 来 patch boot 或 AVD 的 `ramdisk.img`。
   - 特点：仍然是 boot patch，只是省去了手工搬运；AVD 需要关机后 "Cold Boot Now"。
3. App 侧的 `MagiskInstaller.Emulator`（`app/core/.../MagiskInstaller.kt:614`，`operations() = fixEnv()`）
   - `fixEnv()` 只执行 `fix_env $installDir`，即"把二进制刷新到 `/data/adb/magisk`"，**完全不碰 `/system`，也不启动 daemon**。它用于"模拟器上已通过 avd_setup.sh 跑过、只想更新二进制"的场景。
   - 注意：`FlashViewModel` 在 `Info.isEmulator` 为真且用户点"直接安装"时就会走这个分支（`app/apk/.../flash/FlashViewModel.kt:88-95`），所以在官方版本里，模拟器上点"Direct Install"**不会真正安装**，只是刷新 `/data/adb/magisk`。这从侧面说明官方放弃了"在模拟器里持久化安装 Magisk"。

### 2.3 需求结论

需要一条**纯设备内、无需 PC、重启后依然有效、无需预先 root**（root 由本功能自己提供）的安装路径 → 这就是 System Mode。其本质是把 Magisk 的"启动点"从 `boot 镜像里的 magiskinit` 换成 `/system` 里的 `init .rc`。

---

## 3. System Mode 运行时原理（核心章节）

> 这一章是整份方案的灵魂。理解了它，后面的代码移植就是"照抄 + 改名字"。

### 3.1 静态布局（安装完成后磁盘上有什么）

```
/system/etc/init/magisk/                 # MAGISKSYSTEMDIR，权限 700，SELinux u:object_r:system_file:s0
├── magisk                               # 主二进制（官方只有一个名字，64/32 由 ABI 决定）
├── magisk32                             # 32 位二进制（仅 64 位设备；来自 APK 的 32 位 ABI libmagisk.so）
├── magiskpolicy                         # SELinux 策略工具
├── magiskinit                           # 仅用于安装期的 --patch-sepol（运行期不用）
├── stub.apk
└── config                               # "SYSTEMMODE=true\nRECOVERYMODE=false"（Delta 写，仅 shell/卸载器读）

/system/etc/init/magisk.rc               # MAGISKSYSTEMDIR + ".rc"，magiskrc() 生成
                                         # ⚠ 若 /system/etc/init/bootanim.rc 存在，则改为「追加」到 bootanim.rc（更隐蔽、更稳）
                                         #   并把原 bootanim.rc 备份成 bootanim.rc.gz

/system/addon.d/99-magisk.sh             # OTA 存活脚本（install_addond 写入，内容为 addon.d.sh + SYSTEMINSTALL=true）
                                         # 旧方案：/system/addon.d/magisk/*

/data/adb/magisk/*                       # DATABIN，fix_env 从 installDir 刷新（magiskboot/busybox/util_functions.sh/...）
/data/adb/modules, post-fs-data.d, service.d, magisk.db
```

运行期（boot 之后）：

```
/sbin/                                   # tmpfs（mode=755，SELinux u:object_r:rootfs:s0）
├── .magisk/                             # ←── MAGISKTMP 的哨兵目录
│   ├── device/                          # 预初始化设备节点（PREINITDEV）
│   ├── worker/                          # 模块 magic-mount 工作区（tmpfs）
│   ├── config                           # 由 daemon 读 RECOVERYMODE（System Mode 下不写）
│   └── ...
├── magisk                               # 由 --setup-sbin 拷贝（= /system/etc/init/magisk/magisk）
├── magisk32                             # 同上
├── magiskpolicy
├── stub.apk
├── su -> ./magisk                       # applet 软链
├── resetprop -> ./magisk
└── supolicy -> ./magiskpolicy
```

### 3.2 启动时序（这是 System Mode 的关键）

正常（systemless）模式下的启动链是：
`boot.img(ramdisk) → magiskinit(作为 init) → 劫持 sepolicy + 挂 /sbin tmpfs + 注入 magisk.rc → init → rc 触发 magisk --post-fs-data/--service/--boot-complete`。

System Mode 没有 ramdisk，于是**把最后一段变成持久化**：

```
内核 → init（原厂）→ 读 /system/etc/init/*.rc
   │
   ├─ on post-fs-data:
   │   1) start logd                                  # 保证 logd 已起（后续 log -t Magisk 才有意义）
   │   2) exec u:r:su:s0           -- /system/etc/init/magisk/magiskpolicy --live --magisk   ┐
   │   3) exec u:r:magisk:s0       -- /system/etc/init/magisk/magiskpolicy --live --magisk   ├ 三连尝试
   │   4) exec u:r:update_engine:s0-- /system/etc/init/magisk/magiskpolicy --live --magisk   ┘
   │        ↑ 谁先成功谁生效（不同设备 init 能 dyntransition 到的域不同）；成功后
   │          magisk_rules() 里的 `deny * kernel:security load_policy` 会锁死后续 reload，
   │          所以这三条本质上是一次「抢占」，不是冗余。
   │   5) exec u:r:su:s0 -- /system/etc/init/magisk/magisk --auto-selinux --setup-sbin /system/etc/init/magisk /sbin
   │        ↑ 挂 /sbin tmpfs、铺二进制、建 .magisk 哨兵、建 worker 目录
   │   6) exec u:r:su:s0 -- /sbin/magisk --auto-selinux --post-fs-data
   │        ↑ 由 /sbin 下的副本启动 daemon；daemon 内部再把自身上下文设为 u:r:magisk:s0
   │
   ├─ on nonencrypted / on property:vold.decrypt=trigger_restart_framework:
   │   7) exec u:r:su:s0 -- /sbin/magisk --auto-selinux --service
   │
   ├─ on property:sys.boot_completed=1:
   │   8) mkdir /data/adb/magisk 755
   │       exec u:r:su:s0 -- /sbin/magisk --auto-selinux --boot-complete
   │
   ├─ on property:init.svc.zygote=restarting / =stopped:
   │   9) exec u:r:su:s0 -- /sbin/magisk --auto-selinux --zygote-restart
```

要抓住的四个要点：

1. **为什么必须 `/sbin`**：`magiskd` 需要一块 tmpfs 作为 MAGISKTMP（放 applet 软链、worker、socket、mirror）。原厂 init 不会给 Magisk 建 tmpfs，所以必须自己挂一个。`/debug_ramdisk` 在多数设备上只剩空目录或不存在，`/sbin` 是最接近 magiskinit 原生行为的选择。
2. **`.magisk` 目录 = MAGISKTMP 的判据**：`get_magisk_tmp()`（官方 `native/src/core/utils.cpp:33-45`）只检查 `access("/debug_ramdisk/.magisk")` 与 `access("/sbin/.magisk")`。所以 `--setup-sbin` 必须 `mkdir <dst>/.magisk`，否则整个 native 栈会认为"Magisk 不在运行"。
3. **daemon 必须从 MAGISKTMP 里启动**：`connect_daemon(create=true)` 会校验 `readlink("/proc/self/exe")` 是否以 `get_magisk_tmp()` 开头，否则报 `Start daemon on magisk tmpfs` 并拒绝（官方 `native/src/core/daemon.rs:457-462`）。所以 rc 第 6 步必须用 `/sbin/magisk`，不能用 `/system/etc/init/magisk/magisk`。
4. **`--auto-selinux` 的作用**：daemon 会把自身上下文设成 `u:r:magisk:s0`；但**客户端进程**（执行 rc 中 `exec` 的那些进程）也需要权限去 connect daemon socket / 写 `/sys/fs/selinux/load`。`magisk_rules()` 会把 `magisk` 域设为 `permissive`，所以"把自己切成 `magisk` 域"= 绕过所有 SELinux 限制；在策略还没 patch 成功的极早期（第一次启动、`magisk` 类型尚不存在），退化用 `u:r:su:s0`（模拟器/eng 镜像里 `su` 域通常也是宽松的）。

### 3.3 SELinux 引导（两段式，必须都做）

System Mode 的 SELinux 引导是**两段**的：

**(A) 运行时 live patch**：rc 第 2~4 步的 `magiskpolicy --live --magisk`。
- 官方 `magiskpolicy` **仍然完整支持**这两个开关（`native/src/sepolicy/cli.rs:14-18` 定义 `--live` / `--magisk`，`:115-117` 应用 `magisk_rules()`，`:127` 写入 `/sys/fs/selinux/load`）。→ **这块零移植成本**。
- 它做的事：把完整策略二进制重新序列化后**整份写回内核**（不是增量追加）。
- 它加入的关键规则（官方 `native/src/sepolicy/rules.rs`，Delta 版为 `sepolicy/rules.cpp`，内容等价）：
  - `type magisk, domain;` + `permissive magisk;` + `allow magisk * * *;`（无约束域）
  - `type magisk_file` / `type magisk_log_file`（无约束文件类型）
  - `allow * tmpfs:file *;`（**让任意域都能访问 /sbin tmpfs 里的文件 —— 这是 System Mode 能跑的前提之一**）
  - `allow init magisk:process *;` + `allow kernel magisk:process dyntransition;`（**让 init 的 `exec u:r:magisk:s0 ...` 合法**）
  - `deny * kernel:security load_policy;`（锁死策略重载，防篡改）

**(B) 磁盘上的离线 patch**：`magiskinit --patch-sepol`（**仅在 `! is_rootfs` 时执行**）。
- 目的：让**下一次开机**时、在 live patch 生效之前，策略里就已经有 `magisk`/`su` 域和 init→magisk 的转换规则，避免早期 `exec` 被拒导致整个 Magisk 起不来（尤其对真实设备）。
- Delta 的目标文件搜索顺序（`manager.sh:501-506`）：
  `/vendor/etc/selinux/precompiled_sepolicy` → `/odm/etc/selinux/precompiled_sepolicy` → `/system/etc/selinux/precompiled_sepolicy` → `/system_root/sepolicy` → `/system_root/sepolicy_debug` → `/system_root/sepolicy.unlocked`
- 先 `gzip` 备份原文件（`backup_restore`），patch 失败就回滚。
- `! is_rootfs` 的原因：rootfs 设备（老模拟器）用不到磁盘策略，live patch 足够。

> **移植简化点（强烈推荐）**：`patch_sepol(in,out)` 的功能 == `magiskpolicy --load IN --magisk --save OUT`。官方 `magiskpolicy` 的 CLI 已同时支持 `--load`/`--magisk`/`--save`（`native/src/sepolicy/cli.rs:29-36, 91-97, 115-117, 131-135`）。因此**可以完全不新增 native 代码**来实现第 (B) 段。（`installDir` 里本来就有 `magiskpolicy`。）若坚持与 Delta 命令名严格对齐，再花 ~20 行在 Rust 里加 `magiskinit --patch-sepol`，见 §6.3。

### 3.4 安装时序（App 内 "Direct Install (modify /system directly)"）

**前置条件（必须先理解）**：Delta 的 System Mode **要求设备已经能拿到 root**——入口条件是 `allowSystemInstall = isRooted && !Info.isBootPatched`（Delta `InstallViewModel.kt:42`）。
- `isRooted` 由 `ShellInit` 在 `shell.isRoot` 时置位（Delta `ShellInit.kt:23-27`；官方 `ShellInit.kt:19-23`）。在模拟器（`adb root`）或已 root 容器里，app 直接就是 uid 0，因此 `isRooted = true`。
- `isBootPatched` = 当前运行中的 Magisk 的 `$MAGISKTMP/.magisk/config` 里是否有 `SHA1`（见 §4.3 与 §6 阶段 2.3）。System Mode / emulator live setup 下没有 `SHA1`，所以为 `false`。
- 结论：**这个功能是"把已有的临时 root 持久化到 `/system`"，不是"无 root 引导"**。任何"让未 root 设备一把装好"的期望都超出了 Delta 的实现范围，需要另行设计（本方案不覆盖）。这个前提同时带来一个重要便利：安装时 shell 已经是 root，`util_functions.sh` 已经被 `ShellInit` 注入（详见 §6 阶段 3.4.1）。

关键难点：**运行中的 Android 上 `/system` 已经被 Magisk 自己的 overlay/tmpfs 覆盖**（如果有模块、或本身就是 systemless Magisk 在跑）。此时直接往 `/system` 写，写的是 overlay，重启即失。Delta 用一个很巧的"镜面目录"技巧绕开：

```
MIRRORDIR=/proc/$$/attr          # 把自己的 /proc/<pid>/attr 用 tmpfs 盖住
   ├─ <mirror>/system_root  ←── bind mount 真实的 "/"      (ROOTDIR)
   ├─ <mirror>/system       ←── bind mount 真实的 "/system" (SYSTEMDIR)
   ├─ <mirror>/vendor       ←── bind mount /vendor 或软链 ./system/vendor (VENDORDIR)
   └─ <mirror>/odm          ←── bind mount /odm  或软链 ./system_root/odm (ODM_DIR)
```

- 妙处 1：`/proc/<pid>/attr` 这个目录的生命周期与安装进程绑定，**进程一退出这些挂载就自动消失**，不需要显式 unmount（Delta 注释里写 "Use kernel trick to clean up mirrors automatically when installer completed"）。
- 妙处 2：通过 bind mount 拿到的是**未叠加 Magisk overlay 的原始 `/` 与 `/system`**，写进去就是真正写盘。
- 因此真正写入的路径是 `$MIRRORDIR/system/etc/init/magisk/...`、`$MIRRORDIR/system/etc/init/magisk.rc`。
- `force_bind_mount()` = `mount -o bind,private $1 $2` + `mount -o rw,remount $2` + `remount_check rw`。

Delta 的完整安装流程（`app/src/main/res/raw/manager.sh:370-541` 的 `direct_install_system`）：

```
1. print_title
2. api_level_arch_detect()                     # 得到 API / ABI / IS64BIT
3. 建立 mirror（boot mode）或直接 remount rw（recovery mode）
4. 保证 <ROOTDIR>/sbin 存在（rootfs 精简镜像可能没有 /sbin）：
     若不存在 → rm -rf && mkdir，失败则报 "Can't create tmpfs path /sbin"
5. 空间/写保护自检：dd 写 20MB 到 <mirror>/system/.check_XXXX，失败即中止
6. cleanup_system_installation                 # 清掉上一次安装的残留
7. mkdir -p <mirror>/system/etc/init/magisk
8. for f in magisk32 magisk64 magiskpolicy magiskinit stub.apk:
       cat "$INSTALLDIR/$f" > <mirror>/system/etc/init/magisk/$f
9. echo -e "SYSTEMMODE=true\nRECOVERYMODE=false" > .../magisk/config
10. chcon -R u:object_r:system_file:s0 ...; chmod -R 700 ...
11. if API > 24:
      a) 先验证内核是否支持动态 SELinux patch：
           boot mode: magiskpolicy --live "permissive su"  必须成功
           recovery:  只打印警告
      b) if ! is_rootfs:
           backup_restore sepolicy 文件
           magiskinit --patch-sepol sepol.in sepol.out; cp sepol.out 回去
      c) 生成 init rc：
           hijackrc=/system/etc/init/magisk.rc
           若 /system/etc/init/bootanim.rc 存在 → 备份为 bootanim.rc.gz 并改为追加到 bootanim.rc
           echo "$(magiskrc /sbin)" >> $hijackrc
12. 打印 "[*] Reflash your ROM if your ROM is unable to start"
13. installer_cleanup: umount -l /proc/$$/attr（boot mode）/ recovery_cleanup；mount -o ro,remount /
```

外层包装（`manager.sh:545-551`）：

```sh
xdirect_install_system() {
  direct_install_system "$@" || { cleanup_system_installation; installer_cleanup; return 1; }
  fix_env "$1"                       # 把 installDir 内容 cp_readlink 到 /data/adb/magisk
  install_addond "$3" "true"         # $3 = AppApkPath；写 /system/addon.d/99-magisk.sh 与 $MAGISKSYSTEMDIR/magisk.apk
  run_migrations
  return 0
}
```

App 侧的调用（Delta `app/.../core/tasks/MagiskInstaller.kt:540`）：

```kotlin
protected suspend fun direct_system() =
    extractFiles() && "xdirect_install_system \"$installDir\" \"dummy\" \"$AppApkPath\"".sh().isSuccess
```

### 3.5 OTA 存活（addon.d）

- `install_addond "$installDir" "true"`（`manager.sh:52-88`）：
  - 若 `/system/addon.d` 存在：把 `$installDir/.` 拷到 **`/system/etc/init/magisk/`**（System Mode 分支），把 `addon.d.sh` 挪成 `/system/addon.d/99-magisk.sh`，把 APK 拷成 `/system/etc/init/magisk/magisk.apk`，最后 `sed -i "s/^SYSTEMINSTALL=.*/SYSTEMINSTALL=true/g" /system/addon.d/99-magisk.sh`。
  - 顺带 `blockdev --setrw` + `mount -o rw,remount /` 以保证可写。
- OTA 后 addon.d 触发 `99-magisk.sh`，其中 `SYSTEMINSTALL=true` 分支（Delta `scripts/addon.d.sh:125-138`）会从 `/system/etc/init/magisk` 重新执行 `direct_install_system`，从而把 magisk 目录与 rc **重新写回新系统**。
- 注意 Delta 的 `addon.d.sh` 从 `$ADDOND/magisk/magisk.apk` 里 `unzip res/raw/manager.sh` —— 这是**官方仓库已经不存在的资产路径**，移植时必须改成官方的资产名（见 §6.4）。

### 3.6 卸载

Delta 的卸载器会读 `/system/etc/init/magisk/config` 里的 `SYSTEMMODE=true` 来判断"这是系统模式安装"，从而走不同的清理分支（`scripts/uninstaller.sh:62`），删除 `/system/etc/init/magisk*` 并还原 `bootanim.rc.gz`。官方没有这个判断，需要一并回植（见 §6.6）。

---

## 4. Delta 侧实现清单（逐文件、逐函数）

> 引用格式 `文件:行`。以下行号基于 `D:\a\KitsuneMagisk` 的当前快照。

### 4.1 Shell 层

| 文件 | 行 | 内容 | 用途 |
|---|---|---|---|
| `app/src/main/res/raw/manager.sh` | 52-88 | `install_addond(installDir, SYSTEM_INSTALL, AppApkPath)` | OTA 存活脚本安装；有 System Mode 分支 |
| 同上 | 282 | `MAGISKSYSTEMDIR="/system/etc/init/magisk"` | 常量 |
| 同上 | 284-289 | `random_str(from,to)` | 随机字符串（用于临时文件名） |
| 同上 | 291-318 | `magiskrc(MAGISKTMP)` | 生成 init rc 内容（本文 §3.2 的那 9 条） |
| 同上 | 320-334 | `remount_check(mode, part, ignore_not_exist)` | 检查/执行 remount |
| 同上 | 336-349 | `backup_restore(f)` / `restore_from_bak(f)` | sepolicy / bootanim.rc 的 gz 备份与还原 |
| 同上 | 351-359 | `cleanup_system_installation()` | 删除 `$MAGISKSYSTEMDIR`、`$MAGISKSYSTEMDIR.rc`，还原 `bootanim.rc` |
| 同上 | 361-368 | `installer_cleanup()` | `umount -l /proc/$$/attr` 或 `recovery_cleanup`，`mount -o ro,remount /` |
| 同上 | 370-541 | `direct_install_system(INSTALLDIR)` | **核心安装函数** |
| 同上 | 545-551 | `xdirect_install_system(...)` | 包装：安装 + `fix_env` + `install_addond` + `run_migrations` |
| 同上 | 559-572 | `app_init()` | 比官方多了 `SHA1`/`BOOTIMAGE_PATCHED` 与 `get_sulist_status` |
| `scripts/util_functions.sh` | 741-751 | `is_rootfs()` | shell 版 rootfs 判定（读 `/proc/self/mountinfo` 第 9 字段） |
| 同上 | 753-756 | `mkblknode(node, mountpoint)` | 由 `mountpoint -d` 造块设备节点 |
| 同上 | 758-761 | `warn_system_ro()` | 报错 + return 1 |
| 同上 | 763-777 | `remount_check(mode, part, ignore)` | 同上（manager.sh 里的重复实现） |
| 同上 | 779-783 | `force_bind_mount(src, dst)` | `mount -o bind,private` + `rw,remount` + `remount_check` |
| `scripts/addon.d.sh` | 10 | `SYSTEMINSTALL=false` | 变量 |
| 同上 | 125-138 | `SYSTEMINSTALL=true` 分支 | 重新执行 `direct_install_system` |
| 同上 | 149-158 | `backup)` 分支 | 把 `$ADDOND/magisk` 和 `$S/etc/init/magisk` 备份到 `/tmp/magisk` |
| `scripts/flash_script.sh` | 29-35, 104-119, 121-136 | zip 安装器的 System Mode 路径 | 可选（`getvar SYSTEMMODE` / 参数含 `systemmagisk`） |
| `scripts/uninstaller.sh` | 62 | 读 `SYSTEMMODE` 决定卸载方式 | 卸载支持 |
| `scripts/avd_magisk.sh` | 全文 | Delta 自己的 AVD live setup（对照参考） | 非 System Mode |

**Delta 遗留缺陷（移植时不要照抄）**：
- `flash_script.sh:113` / `addon.d.sh:132` 的失败分支调用了 **不存在的函数** `unmount_system_mirrors`（全仓库 0 处定义）。移植时应改为 `cleanup_system_installation; installer_cleanup`。
- `direct_install_system` 把 `stub.apk` 也 `chmod 755`（无意义）。
- `magiskrc` 里 `MAGISKTMP` 被硬编码为 `/sbin`（`MAGISKTMP_TO_INSTALL=/sbin`）。

### 4.2 Native 层（Delta 为 C++/Rust 混合；官方已全面 Rust 化）

| 能力 | Delta 位置 | 说明 |
|---|---|---|
| `--auto-selinux` 前缀开关 | `native/src/core/magisk.cpp:65-80` | 写 `/proc/self/attr/current`：先试 `u:r:<SEPOL_PROC_DOMAIN>:s0`，失败试 `u:r:su:s0`，然后 `argc--; argv++` 把真正命令前移。**无对应函数 `auto_selinux()`，是内联实现。** |
| `--mount-sbin` | `native/src/core/magisk.cpp:106-108` | 调 `mount_sbin()` |
| `--setup-sbin SRCDIR [DSTDIR]` | `native/src/core/magisk.cpp:109-138` | 见 §3.1/§3.2；拷贝名单 `{magisk32, magisk64, magiskpolicy, stub.apk}`；`chdir`；`xmkdir(INTLROOT)`；`xmkdir(DEVICEDIR)`；`symlink("./magisk64"|"./magisk32", "./magisk")`；`install_applet()` |
| `--install [dir]` + `install_applet()` | `magisk.cpp:17-25, 139-144` | 建 `su`/`resetprop` → `./magisk`，`supolicy` → `./magiskpolicy` |
| `setcon()` | `native/src/core/selinux.cpp:13-21` | 返回值 0 表示成功（`rc != len`） |
| `SEPOL_PROC_DOMAIN` / `MAGISK_PROC_CON` | `native/src/include/consts.hpp:42-43` | `"magisk"` / `"u:r:magisk:s0"` |
| `getcurrent()` / `setcurrent()` | `native/src/base/cus.cpp:21-33` | 重复实现（native 内无调用者） |
| `tmpfs_mount(from,to)` | `native/src/base/cus.cpp:52-57` | `xmount(from,to,"tmpfs",0,"mode=755")`，**source 必须是 `"magisk"`**（`revert_unmount` 靠它识别） |
| `bind_mount_` / `selinux_enabled` | `native/src/base/cus.cpp:45-61` | |
| `is_rootfs()`（native 版） | `native/src/core/deny/revert.cpp:25-42` | `statfs("/")` 的 magic ∈ {TMPFS 0x01021994, RAMFS 0x858458f6, **OVERLAYFS 0x794c7630**} |
| `recreate_sbin_v2()` | `native/src/core/deny/revert.cpp:53-85` | 把 `$MIRROR` 下的条目在 `/sbin` 里重建（软链或 bind mount） |
| `mount_sbin()` | `native/src/core/deny/revert.cpp:87-110` | rootfs：remount `/` rw → `mkdir /sbin`,`/root` → hardlink 镜像 → `tmpfs_mount("magisk","/sbin")` → `chcon u:object_r:rootfs:s0 /sbin` → `recreate_sbin_v2("/root",false)` → remount ro；非 rootfs：直接 tmpfs + 建 `.magisk`/`.magisk/mirror`... + `recreate_sbin_v2` |
| post-fs-data 时把 `magisk32/magisk64` 只读 bind 自锁 | `native/src/core/bootstages.cpp:296-304` | 防 root 篡改二进制（**官方已无此逻辑**） |
| `--patch-sepol IN [OUT]` | `native/src/init/init.cpp:72-74` + `native/src/init/selinux.cpp:12-18` | `sepolicy::from_file(in) → magisk_rules() → to_file(out)`；返回 1=读取失败 2=写入失败 |
| `magiskpolicy --live --magisk` | `native/src/sepolicy/main.cpp:50-53,108-121,127` | **官方仍有，无需移植** |
| `magisk_rules()` | `native/src/sepolicy/rules.cpp:8-145` | **官方仍有（Rust 版 `sepolicy/rules.rs`），规则内容等价** |
| 二进制构建 | `native/src/Android.mk` | Delta 同样只有 `LOCAL_MODULE := magisk`；`magisk32`/`magisk64` 是 **Gradle 侧重命名**产物（`buildSrc/Setup.kt`） |

### 4.3 App 层

| 位置 | Delta 内容 |
|---|---|
| `app/.../ui/install/InstallViewModel.kt:42` | `val allowSystemInstall = isRooted && !Info.isBootPatched` |
| 同上 `:98` | `R.id.method_direct_system -> FlashFragment.flash(2).navigate(true)` |
| `app/src/main/res/layout/fragment_install_md2.xml:201-207` | `RadioButton android:id="@+id/method_direct_system"`，`gone="@{!viewModel.allowSystemInstall}"`，文本 `@string/direct_install_system` |
| `app/src/main/res/values/strings.xml:256` | `<string name="direct_install_system">Direct Install (modify /system directly)</string>` |
| `app/.../core/Const.kt:65` | `const val FLASH_MAGISK_SYSTEM = "magisk_system"` |
| `app/.../ui/flash/FlashViewModel.kt:74-76` | `Const.Value.FLASH_MAGISK_SYSTEM -> MagiskInstaller.Direct_system(outItems, logItems).exec()` |
| `app/.../core/tasks/MagiskInstaller.kt:540` | `protected suspend fun direct_system() = extractFiles() && "xdirect_install_system \"$installDir\" \"dummy\" \"$AppApkPath\"".sh().isSuccess` |
| 同上（类定义） | `class Direct_system(...) : ConsoleInstaller(...) { override suspend fun operations() = direct_system() }` |
| `app/.../core/Info.kt:39` | `var isBootPatched = false` |
| `app/.../core/utils/ShellInit.kt:69-73, 87` | 注入 `res/raw/manager.sh`；`Info.isBootPatched = getBool("BOOTIMAGE_PATCHED")` |
| `manager.sh:568-569`（`app_init`） | `BOOTIMAGE_PATCHED=false; [ ! -z "$SHA1" ] && BOOTIMAGE_PATCHED=true` |

---

## 5. 官方仓库现状与差距分析

### 5.1 架构级差异（决定了"不能照抄"，必须"重写接线"）

| 维度 | Magisk Delta | 官方最新版 |
|---|---|---|
| `magisk` 主程序 | C++（`core/magisk.cpp`，手写 argv 解析） | **Rust**（`core/magisk.rs`，`argh` 子命令枚举） |
| `magiskinit` | C++（`init/init.cpp`，手写 argv） | **Rust**（`init/init.rs`，只有 `main`/`selinux_setup` 分支，**无额外 CLI**） |
| daemon / bootstages | C++（`core/daemon.cpp`、`core/bootstages.cpp`） | **Rust**（`core/daemon.rs`、`core/bootstages.rs`） |
| `core/deny/revert.cpp`（含 `is_rootfs`/`mount_sbin`/`recreate_sbin_v2`） | 存在 | **整个文件被删除**；SuList 相关逻辑移入 `core/mount.rs` |
| `base/cus.cpp`（`tmpfs_mount`/`setcurrent`/...） | 存在 | **整个文件被删除**；能力并入 Rust `base/mount.rs` 等 |
| `magiskpolicy` | C++ `sepolicy/main.cpp` | **Rust** `sepolicy/cli.rs`；`--live`/`--magisk`/`--load`/`--save` 全在 |
| `magisk_rules()` | C++ `sepolicy/rules.cpp` | **Rust** `sepolicy/rules.rs`（规则等价） |
| App 结构 | 单模块 `app/src/main/...`（ViewBinding/DataBinding + XML 布局） | **多模块** `app/{apk,core,shared,stub,stub-res,test,build-logic,apk-legacy}`；`app/apk` 是 **Compose** 新 UI，`app/apk-legacy` 保留了**旧的 XML/DataBinding UI**（含 `ui/install/InstallViewModel.kt`、`fragment_install_md2.xml` 一类布局） |
| 安装脚本载体 | `app/src/main/res/raw/manager.sh`（raw resource，全 shell 共享） | **无 `manager.sh`**；改为 `scripts/app_functions.sh`（资产，随 ShellInit 注入） |
| 二进制命名 | 实际产物 `magisk32` + `magisk64`，`magisk` 是软链 | 实际产物只有一个 `magisk`（按 ABI），`magisk32` 由 App 从 32 位 ABI 的 `libmagisk.so` 复制而来 |
| 模拟器方案 | System Mode（持久化写 /system） | `avd_setup.sh`（临时 tmpfs，需已有 root，需 PC） |
| `Info.isBootPatched` | 有（`app_init` 里由 `SHA1` 推出） | **没有**，需要新增 |
| `Const.Value.FLASH_MAGISK_SYSTEM` | 有（`"magisk_system"`） | **没有**，需要新增 |
| `InstallViewModel.Method` | DataBinding `methodId`（`R.id.method_*`） | Kotlin `enum class Method { NONE, PATCH, DIRECT, INACTIVE_SLOT, DOWNLOAD }` + `UiState` |
| 安装 UI | `fragment_install_md2.xml` 的 `RadioGroup` + `InstallFragment` | 两套：`app/apk` 的 Compose `InstallDialog.kt`（`SettingsArrow` 列表）+ `app/apk-legacy` 的 XML/DataBinding UI（与 Delta 同源）。**移植时至少要改 Compose 那套；若 `apk-legacy` 仍会被构建/分发，两套都要改** |
| 字符串位置 | `app/src/main/res/values/strings.xml` | `app/core/src/main/res/values/strings.xml`（资源随模块走，Compose 用 `CoreR.string.*`） |

### 5.2 能力缺口表

| 能力 | Delta 实现 | 官方现状 | 需要做什么 |
|---|---|---|---|
| `magisk --auto-selinux` | `core/magisk.cpp:65-80` | **不存在** | 在 `magisk.rs` 的 `magisk_main()` 里做 argv 预处理（新增 ~15 行 Rust） |
| `magisk --setup-sbin` | `core/magisk.cpp:109-138` | **不存在**（官方没有任何 `mount_sbin`） | 新增 Rust 子命令 + 新文件 `core/setup.rs`（挂 tmpfs / 铺二进制 / applet 软链 / 建 `.magisk`+`device`+`worker`） |
| `magisk --mount-sbin` | `magisk.cpp:106-108` | 不存在 | 建议合并进 `--setup-sbin`（或不实现，属于调试用） |
| `magisk --install` | `magisk.cpp:139-144` | **不存在** | 可选；建议一并加（低成本，便于手工修环境） |
| `magiskinit --patch-sepol` | `init/init.cpp:72-74` | **不存在** | 方案 A（推荐）：不改 native，改用 `magiskpolicy --load IN --magisk --save OUT`；方案 B：在 `init.rs` 加 ~15 行 |
| `is_rootfs()`（native） | `core/deny/revert.cpp:25-42` | 仅 `init/mount.rs:68` 有 `pub(crate)` 版（**不含 overlayfs**） | 在 `core/setup.rs` 里重写一个 core 版（**要包含 OVERLAYFS magic**，Waydroid 需要） |
| `tmpfs_mount()` | `base/cus.cpp:52` | 无同名函数，但有 `bind_mount_to`/`remount_*`/`unmount`（`base/mount.rs`） | 用 `nix::mount::mount` 直接写，注意 `source="magisk"`、`data="mode=755"` |
| `recreate_sbin()` | `core/deny/revert.cpp:53-85` | 仅 `init/rootdir.cpp:205` 有 `static` 版（magiskinit 专用，无法直接调用） | 在 `core/setup.rs` 重写（rootfs 与 SAR 两条分支） |
| worker tmpfs | Delta 在 `post_fs_data → setup_mounts()` 里挂（`core/bootstages.cpp:91-95`） | **只有 magiskinit 挂**（`init/mount.cpp:218,235`）；官方 daemon **不再挂** | **必须**在 `--setup-sbin` 里 `mkdir .magisk/worker` + `mount tmpfs`，否则模块 magic-mount 的 worker 目录不是 tmpfs（功能可能仍可用但隔离性/清理会退化） |
| post-fs-data 只读自锁二进制 | `core/bootstages.cpp:296-304` | 无 | 可选（安全加固），若要移植需写 Rust |
| `direct_install_system` 等 shell | `manager.sh:52-88, 282-551` | **无 manager.sh** | 搬进 `scripts/app_functions.sh`（或新建 `scripts/system_mode.sh` 并加入 `Setup.kt` 的资产 include 列表） |
| shell 工具函数 `is_rootfs`/`mkblknode`/`warn_system_ro`/`remount_check`/`force_bind_mount`/`random_str` | `scripts/util_functions.sh:741-783` + `manager.sh` | **全部不存在** | 全部搬回（`util_functions.sh` 官方仍在此文件，直接追加即可） |
| OTA 存活 | `install_addond` + `addon.d.sh` SYSTEMINSTALL 分支 | `install_addond` 已删除（官方改由 `flash_script.sh:80-86` 安装 addon.d）；`addon.d.sh` 仍在但无 SYSTEMINSTALL | 重新引入一个精简版 `install_addond` + addon.d 分支；注意资产名从 `res/raw/manager.sh` 改为 `assets/app_functions.sh` |
| 卸载识别 | `uninstaller.sh:62` 读 `SYSTEMMODE` | 无 | 回植判断分支 |
| App 入口 | `fragment_install_md2.xml` + `InstallViewModel` | Compose `InstallDialog.kt` + `InstallViewModel`（app/apk） | 新增 Method + 一行 `SettingsArrow`（含二次确认弹窗，因为会改系统分区） |
| `Info.isBootPatched` | `Info.kt:39` + `ShellInit.kt:87` + `manager.sh:568` | 无 | 三处都要加 |
| 32 位二进制 | 真实产物 `magisk32`/`magisk64` | `magisk` + App 侧额外拉出的 `magisk32` | 拷贝名单改为 `{magisk, magisk32, magiskpolicy, magiskinit, stub.apk}`；rc 里用 `magisk` 而非 `magisk64` |

### 5.3 官方仓库里可以**直接复用**的资产（重要，能大幅降低工作量）

1. **`magiskpolicy --live --magisk` 完整可用** —— 运行时 SELinux patch 零成本（`native/src/sepolicy/cli.rs`）。
2. **`SePolicy::from_file` / `to_file` / `magisk_rules` 都在 Rust 侧暴露** —— 若要走方案 B，`magiskinit` crate 已依赖 `magiskpolicy`（`native/src/init/Cargo.toml:18`，feature `no-main`），实现 `--patch-sepol` 只需 ~15 行。
3. **`restore_tmpcon()` 仍保留 `/sbin` → `u:object_r:rootfs:s0` 分支**（`native/src/core/selinux.rs:75-97`）—— System Mode 依赖的 tmpfs 标签行为没丢。
4. **`get_magisk_tmp()` 语义未变**（`native/src/core/utils.cpp:33-45`）—— `.magisk` 哨兵仍是指南。
5. **`connect_daemon` 的 "Start daemon on magisk tmpfs" 校验仍在**（`native/src/core/daemon.rs:457-462`）—— 只要 `--setup-sbin` 铺好 `/sbin/magisk`，rc 即可启动 daemon。
6. **`get_magisk_tmp()` 之外的 `DATABIN`/`SECURE_DIR` 自举仍在**（`native/src/core/bootstages.rs:32-107` 的 `setup_magisk_env()`，而且它**仍会从 DATABIN 补拷 `magisk32` 与 `magiskpolicy`**）—— `fix_env` 把 `installDir` 刷进 `/data/adb/magisk` 后，daemon 自己会把缺的东西补进 MAGISKTMP。
7. **`scripts/app_functions.sh` 就是 Delta `manager.sh` 的直系后代**：`fix_env`、`direct_install`、`cp_readlink`、`mount_partitions`、`get_flags`、`app_init` 都还在，只是少了 System Mode 那几个函数。**这是 System Mode shell 层最自然的落点。**
8. **资产流水线已就绪**：`app/build-logic/src/main/java/Setup.kt:171-200` 会把 `scripts/{util_functions.sh,boot_patch.sh,addon.d.sh,app_functions.sh,uninstaller.sh,module_installer.sh}` 打进 APK 的 `assets/`；`ShellInit.kt:66-69` 会把 `app_functions.sh`（所有 shell）+ `util_functions.sh`（root shell）注入。新增脚本只要加进 `include(...)` 列表即可。
9. **`native/src/Android.mk` 的 `magisk` 模块已链接 `magiskpolicy` 所需的 `libpolicy` 吗？** —— 没有；但 `--setup-sbin` 只是拷贝文件，不需要 sepolicy 依赖；而 `--patch-sepol` 走方案 A 时由独立的 `magiskpolicy` 二进制完成，也不需要。
10. **`Info.isEmulator` 已存在**（`app/core/.../Info.kt:58-61`：`vsoc` / `ro.kernel.qemu` / `ro.boot.qemu`）。
11. **`AppApkPath` 已存在**（`com.topjohnwu.magisk.core.AppApkPath`，被 `uninstall()` 使用）—— `install_addond` 需要它。

---

## 6. 移植技术路线（分阶段、可执行）

> 建议实现顺序：**Native → Shell → App → OTA → 卸载**。Native 先行是因为 shell 脚本要调用新的 CLI；Shell 先于 App 是因为 App 只是"发命令的人"，先用 adb 手工验证 shell 层可以极大加快调试。

### 阶段 0：准备与决策（0.5h）

1. 决定 System Mode 的 **MAGISKTMP 目标目录**：默认 `/sbin`（与 Delta 一致）。若目标设备（Android 10+ 2SI 且 rootfs）无法在 `/` 建 `/sbin`，退化到 `/debug_ramdisk`（`get_magisk_tmp()` 天然支持，只需 `--setup-sbin SRCDIR /debug_ramdisk`）。**建议实现成：`--setup-sbin SRCDIR [DSTDIR]`，DSTDIR 缺省 `/sbin`。**
2. 决定 sepolicy 离线 patch 的实现方式：**方案 A（推荐，零 native 改动）** 用 `magiskpolicy --load IN --magisk --save OUT`；方案 B 加 `magiskinit --patch-sepol`。建议：**先做 A，留 B 作为后续对齐项**。
3. 决定脚本落点（两个方案都可行，见 §5.3 第 7 条）：
   - **方案 S1（最小改动）**：把 System Mode 的函数全部**追加到 `scripts/app_functions.sh`**。它已经是 APK 资产（`Setup.kt:177-180`）并且被 `ShellInit.kt:66` 注入到**每个** shell，因此**零打包改动、零 Kotlin 改动**，Kotlin 侧直接 `"xdirect_install_system ...".sh()` 即可。
   - **方案 S2（推荐，整洁）**：新建 `scripts/system_mode.sh`，并在 `Setup.kt:177-180` 的 `include(...)` 里加一行、在 `ShellInit.kt` 的 `if (shell.isRoot)` 分支里加一行 `add(context.assets.open("system_mode.sh"))`（必须在 `util_functions.sh` 之后；或在 `extractFiles()` 列表里加入并从 `installDir` 显式 `.`，见 §6 阶段 3.4.1）。
   - 取舍：S1 少改 2 个文件，但会把 ~200 行 System Mode 代码塞进**非 root shell 也会加载**的脚本；S2 更易 review/回滚。**本文档后续以 S2 为主线描述，S1 只是把内容换个文件放。**
4. 决定 UI 位置：Compose `InstallDialog.kt` 新增一个 `SettingsArrow`（推荐），仅在 `isRooted && !bootPatched` 时显示。

### 阶段 1：Native 层（核心，建议 1 天）

#### 1.1 新增 `magisk --auto-selinux`（前缀开关）

**目标文件**：`native/src/core/magisk.rs`（函数 `magisk_main`，当前实现见 `:288-298`）。

**为什么用预处理而不是 argh 子命令**：Delta 的语义是"`--auto-selinux` 可以出现在任意真实命令之前"（`magisk --auto-selinux --setup-sbin ...`、`magisk --auto-selinux --post-fs-data`）。argh 的子命令模型无法表达"可选前缀 + 后续命令"，而官方 `magisk_main` 在调 argh 之前本来就会 `cmds.insert(1, "--")` 做修正，正好可以在那里插入预处理。

**实现骨架**：

```rust
// native/src/core/magisk.rs
use crate::consts::{MAGISK_PROC_CON, SEPOL_PROC_DOMAIN};
use std::io::Write;

/// 对应 Delta core/magisk.cpp:65-80
/// 尝试把自身进程上下文切成 u:r:magisk:s0，失败退化为 u:r:su:s0。
/// 返回是否至少写入成功一次。
fn try_auto_selinux() -> bool {
    let Ok(mut fd) = cstr!("/proc/self/attr/current")
        .open(OFlag::O_RDWR | OFlag::O_CLOEXEC)
    else {
        return false;
    };
    // 注意：必须带 NUL 结尾，与内核接口一致
    let ok = fd.write_all(cstr!(MAGISK_PROC_CON).as_bytes_with_nul()).is_ok()
        || fd.write_all(cstr!("u:r:su:s0").as_bytes_with_nul()).is_ok();
    // 诊断输出（可选）：读回当前上下文
    if ok {
        // xread 回读并 eprintln，仅用于 install log 可读性
    }
    let _ = SEPOL_PROC_DOMAIN; // 若用 MAGISK_PROC_CON 常量则不需要
    ok
}

pub fn magisk_main(argc: i32, argv: *mut *mut c_char) -> i32 {
    if argc < 2 { print_usage(); exit(1); }

    let mut cmds = CmdArgs::new(argc, argv.cast()).0;

    // ---- 新增：剥离 --auto-selinux 前缀 ----
    let mut auto_selinux = false;
    while cmds.len() > 1 && cmds[1] == "--auto-selinux" {
        auto_selinux = true;
        cmds.remove(1);
    }
    if auto_selinux {
        try_auto_selinux();
    }
    // ---- 新增结束 ----

    if cmds.len() < 2 { print_usage(); exit(1); }
    cmds.insert(1, "--");
    let cli = Cli::from_args(&cmds[..1], &cmds[1..]).on_early_exit(print_usage);
    cli.action.exec().unwrap_or(1)
}
```

**注意**：
- `CmdArgs` 是 `Vec<CString>`（官方 `base::CmdArgs`），`cmds[1] == "--auto-selinux"` 的比较需要按 `Utf8CStr`/`CStr` 语义写。
- `MAGISK_PROC_CON` 在官方 `consts.rs:42` 已存在，直接用。
- **不要**用 `base` 里已有的 setcontext helper（官方把上下文写入逻辑内联在 `core/daemon.rs:298-304`，没有导出通用函数）。若希望少写代码，可在 `base`/`core` 里加一个 `pub fn setcon(con: &Utf8CStr) -> bool` 供两处复用（顺手重构 `daemon.rs`）。
- **语义保持**：写失败时不报错退出（Delta 如是）。SELinux 未开启时 `open` 失败，静默跳过。

#### 1.2 新增 `magisk --setup-sbin SRCDIR [DSTDIR]`（最关键）

**新增文件**：`native/src/core/setup.rs`（并在 `native/src/core/lib.rs` 里 `mod setup;`）。

**职责**（对齐 Delta `magisk.cpp:106-138` + `deny/revert.cpp:87-110` + 官方 `init/mount.cpp:212-249` 的缺失部分）：

```
1. 挂 tmpfs：
   - DSTDIR == "/sbin" → mount_sbin()
   - 否则 → mount("magisk", DSTDIR, "tmpfs", 0, "mode=755") + set_secontext(u:object_r:rootfs:s0)
2. 拷贝二进制（按官方命名调整！）：
   for f in ["magisk", "magisk32", "magiskpolicy", "stub.apk"]:
       if SRCDIR/f 存在: copy_to(DSTDIR/f); chmod 0755
   （magiskinit 不需常驻；但为了离线 patch sepolicy 方便，也建议拷进去，见 §6.3 方案 A）
3. chdir(DSTDIR)
4. mkdir .magisk (0755)、.magisk/device (0)
5. mkdir .magisk/worker (0) + mount("magisk", ".magisk/worker", "tmpfs", 0, "mode=755")
   ★ 官方把 worker tmpfs 的创建放在 magiskinit 里（init/mount.cpp:218,235），
     System Mode 没有 magiskinit，必须在 setup-sbin 补上。
6. 建 applet 软链：su/resetprop -> ./magisk，supolicy -> ./magiskpolicy
7. （可选）set_secontext 修复：DSTDIR -> rootfs:s0，其下条目 -> system_file:s0
```

**代码骨架（Rust + base API）**：

```rust
// native/src/core/setup.rs
use crate::consts::{DEVICEDIR, INTLROOT, WORKERDIR, APPLET_NAMES};
use base::{FsPathBuilder, ResultExt, Utf8CStr, cstr, info, warn, libc};
use nix::mount::MsFlags;

const RAMFS_MAGIC: i64 = 0x858458f6;
const TMPFS_MAGIC: i64 = 0x01021994;
const OVERLAYFS_MAGIC: i64 = 0x794c7630;

/// 对齐 Delta core/deny/revert.cpp:25-42（注意：官方 init/mount.rs:68 的版本不含 overlayfs）
pub fn is_rootfs() -> bool {
    match nix::sys::statfs::statfs("/") {
        Ok(s) => matches!(
            s.filesystem_type().0 as i64,
            RAMFS_MAGIC | TMPFS_MAGIC | OVERLAYFS_MAGIC
        ),
        Err(_) => false,
    }
}

fn tmpfs_mount(to: &Utf8CStr) {
    // source 必须是 "magisk"：revert_unmount 靠 source 字段识别 magisk 挂载
    nix::mount::mount(
        Some(cstr!("magisk")), Some(to), Some(cstr!("tmpfs")),
        MsFlags::empty(), Some(cstr!("mode=755")),
    ).log_ok();
}

/// 对齐 Delta deny/revert.cpp:87-110
pub fn mount_sbin() -> bool { /* rootfs 与 SAR 两条分支，见下 */ }

/// 对齐 Delta deny/revert.cpp:53-85（把 mirror 中的条目在 /sbin 重建）
fn recreate_sbin(mirror: &Utf8CStr, use_bind_mount: bool) { /* ... */ }

pub fn setup_sbin(src: &Utf8CStr, dst: &Utf8CStr) -> bool {
    if dst == "/sbin" {
        if !mount_sbin() { return false; }
    } else {
        // dst 必须已存在（/debug_ramdisk 等）
        if !dst.exists() { let _ = dst.mkdir(0o755); }
        tmpfs_mount(dst);
        dst.set_secontext(cstr!("u:object_r:rootfs:s0")).log_ok();
    }

    for name in ["magisk", "magisk32", "magiskpolicy", "magiskinit", "stub.apk"] {
        let mut p = cstr::buf::default();
        p.append_path(src).append_path(name);
        if !p.exists() { continue; }
        let mut d = cstr::buf::default();
        d.append_path(dst).append_path(name);
        p.copy_to(&d).log_ok();
        unsafe { libc::chmod(d.as_ptr(), 0o755) };
    }

    // chdir + 哨兵目录 + worker tmpfs
    let _ = std::env::set_current_dir(dst.as_str());
    let _ = cstr!(INTLROOT).mkdir(0o755);        // .magisk
    let _ = cstr!(DEVICEDIR).mkdir(0o000);       // .magisk/device
    let _ = cstr!(WORKERDIR).mkdir(0o000);       // .magisk/worker
    // 关键：worker 必须是独立 tmpfs（官方由 magiskinit 负责，System Mode 只能自己做）
    nix::mount::mount(
        Some(cstr!("magisk")), Some(cstr!(WORKERDIR)), Some(cstr!("tmpfs")),
        MsFlags::empty(), Some(cstr!("mode=755")),
    ).log_ok();
    nix::mount::mount(
        None::<&Utf8CStr>, cstr!(WORKERDIR), None::<&Utf8CStr>,
        MsFlags::MS_PRIVATE, None::<&Utf8CStr>,
    ).log_ok();

    // applet 软链
    for name in APPLET_NAMES {  // ["su", "resetprop"]
        let mut d = cstr::buf::default();
        d.append_path(dst).append_path(name);
        d.create_symlink_to(cstr!("./magisk")).log_ok();
    }
    let mut d = cstr::buf::default();
    d.append_path(dst).append_path("supolicy");
    d.create_symlink_to(cstr!("./magiskpolicy")).log_ok();

    true
}
```

**`magisk.rs` 侧的 CLI 注册（argh）**：

```rust
#[derive(FromArgs)]
#[argh(subcommand, name = "--setup-sbin")]
struct SetupSbin {
    #[argh(positional)] src: Utf8CString,
    #[argh(positional)] dst: Option<Utf8CString>,
}
// 在 enum MagiskAction 中加: SetupSbin(SetupSbin),
// 在 match 中加: SetupSbin(self::SetupSbin { src, dst }) => {
//     let dst = dst.unwrap_or_else(|| Utf8CString::from("/sbin"));
//     if !setup::setup_sbin(&src, &dst) { return Ok(1); }
// }
```

**几个必须踩准的点**：

1. **二进制名单必须改**：Delta 是 `{magisk32, magisk64, magiskpolicy, stub.apk}`；官方只有 `magisk`（+ 可选的 `magisk32`），所以是 `{magisk, magisk32, magiskpolicy, magiskinit, stub.apk}`。rc 里引用 `$MAGISKSYSTEMDIR/magisk`，不要写 `magisk64`。
2. **`/sbin` 不存在时的处理**：2SI 设备上 `/` 是 rootfs，`mkdir /sbin` 可行；legacy SAR 设备 `/sbin` 本来就在 system 镜像里；若两者都不是（极少见），`mount` 会失败 → `--setup-sbin` 返回非 0 → 安装期应给出明确错误。**建议在 shell 层安装前就用 `mkdir` 预检**（Delta 的做法，见 §6.5 步骤 4）。
3. **`chdir` 之后才能 `mkdir(".magisk")`**：`INTLROOT`/`DEVICEDIR`/`WORKERDIR` 是相对路径宏（`".magisk"`、`".magisk/device"`、`".magisk/worker"`）。Rust 侧虽然可以直接用绝对路径拼，但为保持与官方 `setup_tmp()`（`init/mount.cpp:212-249`）一致，建议同样 `chdir(dst)` 后用相对路径。
4. **`restore_tmpcon()` 会自动把 `/sbin` 标成 `rootfs:s0`**（官方 `core/selinux.rs:75-81`），所以 `--setup-sbin` 里可以不做 chcon；但**非 `/sbin` 目标目录不会被自动处理**（走 `chmod 0711` 分支），此时需要手工 `set_secontext`。
5. **daemon 侧不用改**：`setup_magisk_env()`（`bootstages.rs:32-107`）会自己从 `/data/adb/magisk` 补拷 `magisk32`/`magiskpolicy`/`busybox` 到 MAGISKTMP。**但注意它不会补 `magisk` 本身** —— `magisk` 必须由 `--setup-sbin` 放到 `/sbin/magisk`，否则 `connect_daemon` 的 "Start daemon on magisk tmpfs" 校验会失败。

#### 1.3 `magiskinit --patch-sepol`（方案 A 推荐 / 方案 B 备选）

**方案 A（推荐，零 native 改动）**：
- shell 里把
  ```sh
  "$INSTALLDIR/magiskinit" --patch-sepol "$INSTALLDIR/sepol.in" "$INSTALLDIR/sepol.out"
  ```
  换成
  ```sh
  "$INSTALLDIR/magiskpolicy" --load "$INSTALLDIR/sepol.in" --magisk --save "$INSTALLDIR/sepol.out"
  ```
- 依据：官方 `native/src/sepolicy/cli.rs`
  - `--load FILE` → `SePolicy::from_file(&file)`（`:92`）
  - `--magisk` → `sepol.magisk_rules()`（`:115-117`）
  - `--save FILE` → `sepol.to_file(&file)`（`:131-135`）
  - 与 `patch_sepol`（Delta `init/selinux.cpp:12-18`）**逐条等价**。
- 返回值语义：官方失败时返回 1（`res.is_ok() { 0 } else { 1 }`，`cli.rs:138`）；Delta 区分 1/2，但 shell 侧只判非零，因此**无影响**。
- 风险：`--load` 走的是 `SePolicy::from_file`，对 `precompiled_sepolicy`/`sepolicy` 这类**单块二进制策略**有效（就是 Delta 用的同一套 libsepol 反序列化）；不适用于 split CIL（`--compile-split` 场景）。安装期目标是磁盘上的 precompiled 文件，所以 A 方案安全。

**方案 B（若要严格对齐 `magiskinit --patch-sepol`）**：

```rust
// native/src/init/selinux.rs 追加
use magiskpolicy::ffi::SePolicy;
use base::{Utf8CStr, debug, error};

/// 对齐 Delta init/selinux.cpp:12-18
pub fn patch_sepol(in_file: &Utf8CStr, out_file: &Utf8CStr) -> i32 {
    let mut sepol = SePolicy::from_file(in_file);
    if sepol._impl.is_null() { return 1; }     // 与 cli.rs:98-100 相同的判空方式
    sepol.magisk_rules();
    if !sepol.to_file(out_file) { return 2; }
    0
}
```

```rust
// native/src/init/init.rs 的 main()（:179-200），在 magisk_proxy_main 分支之后插入
if argc > 2 {
    let a1 = unsafe { CStr::from_ptr(*argv.add(1)) };
    if a1 == c"--patch-sepol" {
        let src = Utf8CStr::from_ptr(unsafe { *argv.add(2) });
        let dst = if argc > 3 {
            Utf8CStr::from_ptr(unsafe { *argv.add(3) })
        } else { src };
        return unsafe { crate::selinux::patch_sepol(src, dst) };
    }
}
```
- 必须在 `if getpid() == 1` 之前（Delta 在 `init.cpp:76` 之前插入），否则非 1 号进程会直接 `return 1`。
- 官方 `magiskinit` **完全没有 argv 解析器**：`native/src/init/init.rs:179-200` 只识别 `argv[0] == "magisk"`（→ `magisk_proxy_main`，且它也不接受任何选项）和 `argv[1] == "selinux_setup"`（在 `start()` 里，`init.rs:148-150`）。因此这是**新增分支**，不是修改现有解析逻辑；也不会与任何现有 flag 冲突。
- 需要 `magiskpolicy` crate 的 `ffi::SePolicy` 在 `magiskinit` 中被正确链接 —— `native/src/init/Cargo.toml:18` 已经依赖了 `magiskpolicy`（feature `no-main`），且 `native/src/init/selinux.rs:9` 已经在用 `use magiskpolicy::ffi::SePolicy;`，无需改构建。
- 判空写法照抄官方 `cli.rs:98-100`（`if sepol._impl.is_null() { ... }`），因为 `FromFile` 失败时返回的是空 `_impl` 而不是 `Option`。

**决策建议**：先做 A（能立刻跑通、改动最小、风险最低）；B 作为"接口对齐/长期可维护"的可选加分项。若做 B，shell 层保持 Delta 原始调用形式不变，可减少脚本 diff。

#### 1.4（可选加固）post-fs-data 把 `/sbin/magisk*` 只读自锁

Delta 在 `core/bootstages.cpp:296-304` 做：
```
for bin in magisk32, magisk64:
    chmod 0755; mount(bin, bin, MS_BIND); mount(NULL, bin, MS_BIND|MS_RDONLY|MS_REMOUNT)
```
官方 Rust 侧无对应代码。若要移植，落点在 `native/src/core/bootstages.rs` 的 `post_fs_data()`（`:109-161`）开头，用 `base::mount` 的 `bind_mount_to` + `remount_mount_point_flags(MsFlags::MS_RDONLY)`。**注意官方现在只有 `magisk`/`magisk32`，没有 `magisk64`。**
优先级：低（安全加固，不影响功能）。

#### 1.5 Native 编译验证

```bash
scripts/env.py ./build.py native          # 或 ./build.py binary（视 build.py 子命令而定，见 docs/build.md）
# 若只改了 Rust：scripts/env.py ./build.py cargo build -p magiskcore ...
```
> 注意仓库规则：独立执行 `gradlew`/`cargo`/`rustc`/`ndk-build` **必须**加 `scripts/env.py` 前缀。

### 阶段 2：Shell 层（建议 1 天）

#### 2.1 工具函数落点

把以下函数原样（或修正后）加进 `scripts/util_functions.sh`（官方该文件仍在，且已作为 APK 资产）：

| 函数 | Delta 行 | 备注 |
|---|---|---|
| `is_rootfs()` | 741-751 | 依赖 `$BOOTMODE`；官方 `util_functions.sh` 末尾已有 BOOTMODE 自动探测（Delta 版本同） |
| `mkblknode()` | 753-756 | 依赖 `mountpoint -d` |
| `warn_system_ro()` | 758-761 | |
| `remount_check()` | 763-777 | |
| `force_bind_mount()` | 779-783 | |
| `random_str()` | `manager.sh:284-289` | 官方 `util_functions.sh` 无此函数；注意它 `tr -dc ... </dev/urandom`，在部分 busybox 上需 `head -c` 配合 |

**官方 `util_functions.sh` 当前函数清单**（便于确认"哪些真的缺"）：
`ui_print, toupper, grep_cmdline, grep_prop, grep_get_prop, getvar, is_mounted, abort, print_title, setup_flashable, ensure_bb, recovery_actions, recovery_cleanup, find_block, setup_mntpoint, mount_name, mount_ro_ensure, mount_partitions, get_flags, is_gt_gki_13, find_boot_image, flash_image, install_magisk, sign_chromeos, remove_system_su, api_level_arch_detect, check_data, run_migrations, copy_preinit_files, set_perm, set_perm_recursive, mktouch, boot_actions, is_legacy_script, set_default_perm, install_module`
→ 即 **`is_rootfs` / `mkblknode` / `warn_system_ro` / `remount_check` / `force_bind_mount` / `random_str` 全部缺失**，需新增。

> 注意 `api_level_arch_detect()` 官方版本（`scripts/util_functions.sh:502-527`）与 Delta 版本（`:491-512`）都要确认是否设置 `IS64BIT` 与 `ABI32`；System Mode 的 shell 需要 `IS64BIT` 来判断要拷哪些二进制（若采用"整目录拷贝"策略则不需要）。

#### 2.2 新增脚本文件 `scripts/system_mode.sh`

内容 = Delta `manager.sh` 的 System Mode 部分 + `install_addond` 的 System 分支，按官方现状做如下**适配**：

1. **常量**
   ```sh
   MAGISKSYSTEMDIR="/system/etc/init/magisk"      # 保持不变
   MAGISKTMP_TO_INSTALL=/sbin                     # 保持不变（或改为可配 /debug_ramdisk）
   ```
2. **`magiskrc()` 适配**（这是与 Delta 差别最明显的地方）
   - `magisk_name` 不再需要 `magisk64`：统一用 `magisk`。
   - 其余 `exec u:r:...` 行保持不变（官方 `magisk_rules()` 仍创建 `magisk` 域并允许 `init → magisk` 的 `process` 转换，见 `native/src/sepolicy/rules.rs:121-126`）。
   - `--auto-selinux` 前缀保留（阶段 1.1 实现）。
   - `--setup-sbin $MAGISKSYSTEMDIR $MAGISKTMP` 保留。
   - 建议的最终 rc（相对 Delta 只改二进制名）：
     ```sh
     on post-fs-data
         start logd
         exec u:r:su:s0 root root -- $MAGISKSYSTEMDIR/magiskpolicy --live --magisk
         exec u:r:magisk:s0 root root -- $MAGISKSYSTEMDIR/magiskpolicy --live --magisk
         exec u:r:update_engine:s0 root root -- $MAGISKSYSTEMDIR/magiskpolicy --live --magisk
         exec u:r:su:s0 root root -- $MAGISKSYSTEMDIR/magisk --auto-selinux --setup-sbin $MAGISKSYSTEMDIR $MAGISKTMP
         exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --post-fs-data
     on nonencrypted
         exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --service
     on property:vold.decrypt=trigger_restart_framework
         exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --service
     on property:sys.boot_completed=1
         mkdir /data/adb/magisk 755
         exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --boot-complete
     on property:init.svc.zygote=restarting
         exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --zygote-restart
     on property:init.svc.zygote=stopped
         exec u:r:su:s0 root root -- $MAGISKTMP/magisk --auto-selinux --zygote-restart
     ```
3. **`direct_install_system()` 的移植**（逐段对齐 Delta，仅改这几处）
   - 二进制拷贝名单：Delta 是 `$magisk_applet magiskpolicy magiskinit stub.apk`（`$magisk_applet` = `magisk32` 或 `magisk32 magisk64`）；移植后改为固定的 **`magisk magisk32 magiskpolicy stub.apk`**（`magisk32` 用 `if [ -f ... ]` 容错，32 位-only 设备上不存在）。
     - **`magiskinit` 是否要拷**：走 sepolicy **方案 B** 时必须拷（`--patch-sepol` 在它里面）；走**方案 A**（`magiskpolicy --load --magisk --save`，本方案默认）**不要拷**，减少 `/system` 上的暴露面。
     - `IS64BIT` 仍然要算（`api_level_arch_detect`），但只用于"是否存在 magisk32"的判断，不再决定 `magisk_name`。
   - sepolicy patch：
     ```sh
     # 方案 A
     if ! "$INSTALLDIR/magiskpolicy" --load "$INSTALLDIR/sepol.in" --magisk --save "$INSTALLDIR/sepol.out" \
        || ! cp -af "$INSTALLDIR/sepol.out" "$MIRRORDIR$sepol"; then
       ui_print "! Unable to patch sepolicy file"
       restore_from_bak "$MIRRORDIR$sepol"
       return 1
     fi
     ```
   - `config` 写入保持不变（卸载器需要 `SYSTEMMODE`）。
   - `is_rootfs` 依然需要（决定是否做离线 patch）。
4. **`cleanup_system_installation()` / `installer_cleanup()` / `backup_restore()` / `restore_from_bak()`**：原样搬。
5. **`xdirect_install_system()`**：原样搬，但把 `install_addond "$3" "true"` 换成移植后的精简版（见阶段 4）。
6. **脚本层可以依赖的两个"环境已就绪"事实**（官方已保证，无需自己设置）：
   - `$MAGISKBIN` = `/data/adb/magisk`：官方 `scripts/util_functions.sh:763` 在加载时就赋值（Delta 是 `set_nvbase "/data/adb"`，`util_functions.sh:795`）。所以 `install_addond_system` 可以放心用 `$MAGISKBIN`。
   - `BOOTMODE=true`：官方 `scripts/app_functions.sh:249` 直接 `export BOOTMODE=true`（且它在 `util_functions.sh` 的自动探测之前被 source，所以探测不会覆盖它）。**这意味着在 App 安装路径里 `direct_install_system` 永远走 `if $BOOTMODE` 分支，recovery 分支是死代码** —— 可以保留（供 addon.d/flash 路径复用），但不要把调试时间花在它上面。
7. **去掉 Delta 的 bug（不要照抄）**：
   - `unmount_system_mirrors` 在 Delta 全仓库**没有定义**（`addon.d.sh:132`、`flash_script.sh:113` 调用了它）→ 失败分支改为 `cleanup_system_installation; installer_cleanup`。
   - `MIRRORDIR` 是 `direct_install_system` 的 `local`，但失败路径 (`xdirect_install_system`，`manager.sh:546`) 里已经离开作用域 → `cleanup_system_installation` 里的 `"$MIRRORDIR$MAGISKSYSTEMDIR"` 退化为字面 `/system/etc/init/magisk`。因为 mirror 本身就是真实 `/system` 的 bind mount，这个 bug **恰好无害**，但移植时应该显式处理：把 `MIRRORDIR`/`SYSTEMDIR` 提升为脚本级全局变量（或用 `local` 但让 `xdirect_install_system` 在同一个函数里做清理）。
   - `SDK_INT` 在 Delta 与官方**都从未被赋值**（只有 `manager.sh:207` / `app_functions.sh:155` 的读取）→ `check_encryption()` 的 `[ $SDK_INT -lt 24 ]` 恒为假，`CRYPTOTYPE` 靠 `getprop ro.crypto.type` 与 `/proc/mounts` 兜底。移植时不要"顺手修复"它去改变行为（会影响 `Info.crypto`/`isFDE` 的判定）。
   - `install_addond` 拷贝的是 `$MAGISKBIN`（`/data/adb/magisk`），**不是它的第一个参数**（`$1` 是 APK 路径）。它之所以能工作，是因为 `xdirect_install_system` 先执行了 `fix_env "$1"` 把 `installDir` 刷进 `MAGISKBIN` 并删掉了源目录（`manager.sh:42-50, 545-551`）。**因此 `fix_env` → `install_addond` 的顺序不可交换**，且 `install_addond` 必须在 `fix_env` 之后才能读到 `addon.d.sh`。

#### 2.3 `app_init` 增加 `BOOTIMAGE_PATCHED`

官方 `scripts/app_functions.sh:227-247` 的 `app_init()` 已经在 `printvar` 一堆变量；官方 `Info.init()`（`app/core/.../Info.kt:106`）通过 `(app_init)` 捕获这些 `KEY=VALUE` 行。

**需要新增**（对齐 Delta `manager.sh:565-569`）：
```sh
  SHA1=$(grep_prop SHA1 $MAGISKTMP/.magisk/config)
  BOOTIMAGE_PATCHED=false
  [ ! -z "$SHA1" ] && BOOTIMAGE_PATCHED=true
  printvar BOOTIMAGE_PATCHED
```
- `SHA1` 的来源仍然有效：官方 `scripts/boot_patch.sh:188` 会写 `SHA1=...`，`util_functions.install_magisk` 也会（`:544-572`）；`app_functions.sh:92` 的 `restore_imgs()` 至今仍读 `$MAGISKTMP/.magisk/config` 的 `SHA1`。→ **判据可靠**。
- 注意 `$MAGISKTMP` 在 `app_functions.sh` 里由 `ShellInit.kt:44` 导出（`export MAGISKTMP=$(magisk --path)`）。**在未安装 Magisk 的设备上 `magisk --path` 无输出**，`MAGISKTMP` 为空 → `grep_prop` 失败 → `BOOTIMAGE_PATCHED=false`，正是我们想要的。

#### 2.4 资产打包

`app/build-logic/src/main/java/Setup.kt:171-200`：
```kotlin
from(rootFile("scripts")) {
    include("util_functions.sh", "boot_patch.sh", "addon.d.sh",
        "app_functions.sh", "uninstaller.sh", "module_installer.sh")
}
```
→ 若新建 `scripts/system_mode.sh`，**必须加进这个 include 列表**，否则 APK 里没有它。

`ShellInit.kt`（`app/core/.../core/utils/ShellInit.kt:66-69`）：
```kotlin
add(context.assets.open("app_functions.sh"))
if (shell.isRoot) {
    add(context.assets.open("util_functions.sh"))
}
```
→ 需要让 `system_mode.sh` 在 root shell 可见。两种做法（择一）：
- (a) 直接在 root 分支里 `add(context.assets.open("system_mode.sh"))`；
- (b) 在 `util_functions.sh` 末尾 `. /path/to/system_mode.sh`（需要路径，麻烦）。
**推荐 (a)**。

#### 2.5 用 adb 手工验证 shell 层（在写 App 之前）

```bash
# 1) 构造 installDir（模拟 App 的 extractFiles 行为）
adb shell 'mkdir -p /data/local/tmp/install'
adb push out/... # 或直接从 APK 里解 lib/<abi>/lib*.so 并重命名
# 2) 跑安装
adb shell 'su -c "sh -c \". /data/local/tmp/install/app_functions.sh; . /data/local/tmp/install/system_mode.sh; xdirect_install_system /data/local/tmp/install dummy /data/local/tmp/magisk.apk\""'
# 3) 检查落盘
adb shell 'ls -lZ /system/etc/init/magisk* ; cat /system/etc/init/magisk.rc'
# 4) 重启并观察
adb shell 'setprop sys.boot_completed 0; stop; start'   # 或在 AVD 里 "Cold Boot Now"
adb shell 'su -c id; /sbin/magisk -v; ls -l /sbin'
```

### 阶段 3：App 层（建议 0.5–1 天）

#### 3.1 `Info.isBootPatched`

- `app/core/src/main/java/com/topjohnwu/magisk/core/Info.kt`
  - 在 `var patchBootVbmeta = false`（`:38`）附近加：`var isBootPatched = false`
  - 在 `init(shell)` 的变量解析处（`:111-118`）加：`isBootPatched = getBool("BOOTIMAGE_PATCHED")`
- 依赖阶段 2.3 的 `app_init` 改动。

#### 3.2 `Const.Value.FLASH_MAGISK_SYSTEM`

- 官方 `Const.Value` 位置：`app/core/src/main/java/com/topjohnwu/magisk/core/Const.kt`（对应 Delta `app/.../core/Const.kt:65`）
- 加：`const val FLASH_MAGISK_SYSTEM = "magisk_system"`（字符串值可自定，只要与 VM 分支一致）

#### 3.3 `FlashViewModel` 分支

- `app/apk/src/main/java/com/topjohnwu/magisk/ui/flash/FlashViewModel.kt:77-116` 的 `when (action)` 加：
  ```kotlin
  Const.Value.FLASH_MAGISK_SYSTEM -> {
      onResult(withContext(Dispatchers.IO) {
          MagiskInstaller.System(outItems, logItems).exec()
      })
  }
  ```
- **注意**：不要复用 `Const.Value.FLASH_MAGISK` 分支，因为官方在那里对 `Info.isEmulator` 做了 `MagiskInstaller.Emulator`（只刷 DATABIN）的特殊处理。System Mode 必须是**独立的 action**，这样也能在日志里明确区分。

#### 3.4 `MagiskInstaller.System`

- `app/core/src/main/java/com/topjohnwu/magisk/core/tasks/MagiskInstaller.kt`
  - 在 `MagiskInstallImpl` 里加（对齐 Delta `:540`）：
    ```kotlin
    protected suspend fun installSystem() =
        extractFiles() && "xdirect_install_system \"$installDir\" \"dummy\" \"$AppApkPath\"".sh().isSuccess
    ```
  - 在 `MagiskInstaller` 对象里加：
    ```kotlin
    class System(console: MutableList<String>, logs: MutableList<String>) : ConsoleInstaller(console, logs) {
        override suspend fun operations() = installSystem()
    }
    ```
- **`extractFiles()` 基本无需改动**：它已经把 `magisk`、`magiskboot`、`magiskinit`、`magiskpolicy`、`init-ld`、`busybox`、`bootctl`（来自 `nativeLibraryDir` / stub APK 的 `lib/<abi>/`）以及 `magisk32`（64 位设备额外从 32 位 ABI 提取）解到 `installDir`，并解出 `util_functions.sh`、`boot_patch.sh`、`addon.d.sh`、`stub.apk`（`MagiskInstaller.kt:163-166`）。

#### 3.4.1 关于 shell 函数可用性（必须先想清楚，否则一定踩坑）

**关键前提（来自 Delta 的实现语义）**：`allowSystemInstall = isRooted && !Info.isBootPatched`（Delta `InstallViewModel.kt:42`）——
**System Mode 只在"已经能拿到 root（`adb root` / 现成的 `su` / 容器内 uid0）但 boot 未 patch"时才提供**。它**不是**"从零获取 root"的引导手段，而是"把已有 root 持久化到 `/system`"。

这个前提带来一个重要的便利：既然 `shell.isRoot == true`，官方 `ShellInit.kt:66-69` 就已经把脚本注入到**持久 root shell** 里了：

```kotlin
add(context.assets.open("app_functions.sh"))          // 所有 shell
if (shell.isRoot) {
    add(context.assets.open("util_functions.sh"))     // 仅 root shell
}
```

而 `MagiskInstaller` 用的正是同一个 `Shell.getShell()` 单例（`MagiskInstaller.kt:59`），所以 `fix_env`、`cp_readlink`、`direct_install`、`is_rootfs`、`flash_image` 等函数在 `.sh()` 执行时**已经存在** —— 这正是 Delta 能直接用一行 `xdirect_install_system ...` 的原因（Delta 用 `res/raw/manager.sh` + `assets/util_functions.sh` 做同样的事，见 Delta `ShellInit.kt:69-73`）。

**因此最小改动方案**：只新增一个脚本 `system_mode.sh`，把它注入到 root shell，然后：

```kotlin
protected suspend fun installSystem() =
    extractFiles() && "xdirect_install_system \"$installDir\" \"dummy\" \"$AppApkPath\"".sh().isSuccess
```

注入方式二选一：
- (a) **改 `ShellInit.kt`**（推荐）：在 `if (shell.isRoot) { ... }` 分支里加 `add(context.assets.open("system_mode.sh"))`（必须在 `util_functions.sh` **之后**，保证同名函数以 `util_functions.sh` 为准）；同时把 `"system_mode.sh"` 加进 `Setup.kt:177-180` 的 `include(...)`。
- (b) **把脚本放进 `installDir`**：在 `extractFiles()` 的脚本列表（`MagiskInstaller.kt:163`）里加 `"system_mode.sh"`，然后显式加载：
  ```kotlin
  protected suspend fun installSystem() = extractFiles() &&
      arrayOf(
          "cd $installDir",
          ". ./app_functions.sh",   // 提供 fix_env / cp_readlink / direct_install / app_init
          ". ./util_functions.sh",  // 提供 is_rootfs / flash_image / mount_partitions（覆盖简化版）
          ". ./system_mode.sh",     // 提供 direct_install_system / xdirect_install_system / *
          "xdirect_install_system \"$installDir\" \"dummy\" \"$AppApkPath\""
      ).sh().isSuccess
  ```
  同时也要把 `"app_functions.sh"` 加进 `extractFiles()` 的列表。

⚠ **加载顺序绝对不能反**：`app_functions.sh` 与 `util_functions.sh` 定义了**同名函数** `mount_partitions` / `get_flags` / `grep_prop` / `run_migrations`。官方的注入顺序就是"先 `app_functions.sh`（简化/非 root 版），再 `util_functions.sh`（完整/root 版）覆盖"，Delta 也是同一顺序（`ShellInit.kt:69-73`；addon.d/zip 路径见 Delta `addon.d.sh:126-130`、`flash_script.sh:105-109`：先 `. ./manager.sh` 再 `. $MAGISKBIN/util_functions.sh`）。顺序反了会导致 `SYSTEM_AS_ROOT` / `LEGACYSAR` / `CRYPTOTYPE` 判定错误，进而在 `direct_install_system` 里选错分支（这是最难 debug 的一类 bug）。

- **`AppApkPath`**：官方 `com.topjohnwu.magisk.core.AppApkPath` 已存在，直接引用（`MagiskInstaller.kt:534` 的 `uninstall()` 已在用）。

- **`install_dir` 的路径（易错点）**：官方是 `installDir = localFS.getFile(context.filesDir.parent, "install")`，而 `context` 来自 `ServiceLocator.deContext` = **设备加密存储（device-protected）** 的 Context（`app/core/.../core/di/ServiceLocator.kt:22`，`AppContext.deviceProtectedContext`），所以真实路径是 **`/data/user_de/0/<pkg>/install`**（**不是** `/data/user/0/...`，也不是 `/data/local/tmp`）。若 `shell.isRoot && Info.noDataExec` 则被搬到 `Const.TMPDIR`（`/dev/tmp`）。两种路径对 root shell 都可读写，脚本无需特殊处理，**但不要硬编码任何一条**。

#### 3.5 UI 入口

官方安装 UI 是 Compose 对话框 `app/apk/src/main/java/com/topjohnwu/magisk/ui/install/InstallDialog.kt`：

- `InstallViewModel`（`app/apk/.../install/InstallViewModel.kt`）
  - `enum class Method`（`:27`）加 `SYSTEM`
  - `val allowSystemInstall get() = isRooted && !Info.isBootPatched`（新增）
  - `install()` 的 `when` 加 `Method.SYSTEM -> navigateTo(Route.Flash(action = Const.Value.FLASH_MAGISK_SYSTEM))`
- `InstallDialog.kt`（`:178-197` 是 `if (installVm.isRooted) { SettingsArrow(direct_install) }` 的位置）
  - 新增一个 `SettingsArrow`：
    ```kotlin
    if (installVm.allowSystemInstall) {
        SettingsArrow(
            title = stringResource(CoreR.string.direct_install_system),
            onClick = {
                onDismiss()
                installVm.selectMethod(InstallViewModel.Method.SYSTEM)
                installVm.install()
            },
        )
    }
    ```
  - **强烈建议加二次确认弹窗**（会改系统分区，风险高于普通安装）。可复用官方现成的 `rememberConfirmDialog()`（`InstallDialog.kt:72-91` 已有用法）。
- 字符串：唯一需要改的是 **`app/core/src/main/res/values/strings.xml`**（`:apk`/`:apk-legacy` 都没有自己的 `strings.xml`，都通过 `import com.topjohnwu.magisk.core.R as CoreR` 引用 `:core`，所以**加一条就同时覆盖两套 UI**）。在 Install 区块（`:35-54`）后面加：
  ```xml
  <string name="direct_install_system">Direct Install (modify /system directly)</string>
  <string name="direct_install_system_msg">This will modify your /system partition directly. If it fails halfway your device may not boot, and you will need to reflash your ROM. Continue?</string>
  ```
  - 翻译**可选**：`Setup.kt:240` 里 `lint { disable += "MissingTranslation" }`，只加英文不会编译失败。中文措辞可直接借用 Delta（`values-zh-rCN/strings.xml:250` = `直接安装（直接修改/system）`、`values-zh-rTW/strings.xml:246`）。
  - ⚠ **不要用按行号编辑的方式批量加翻译**：`app/core/src/main/res/values*/strings.xml` 里有若干文件把多个 `<string>` 挤在同一行（例如默认 `strings.xml:242`，`values-ar:39`），逐行替换会误伤。若确实要补翻译，建议先只做默认语种。
  - 官方翻译机制就是**仓库内的 `values-<lang>/strings.xml`**（`app/core/src/main/res/` 下有 51 个语言目录；另有 `res/xml/locale_config.xml` 声明 API 33+ 的按应用语言列表，**新增语言要同时改这两处**，但本次不需要新增语言）。没有 Crowdin/Weblate 流程。

#### 3.6 首页提示（可选）

官方 `HomeScreen.kt` 已有 `needsFullFix` / `onFixEnv` 逻辑（`:199-203, 923-936`）。System Mode 安装成功后，重启即生效；不需要额外交互。但可以在安装成功页提示"重启后生效"。

### 阶段 4：OTA 存活（addon.d）—— 可选但推荐

1. **新增 `install_addond_system()`**（`system_mode.sh` 内），对齐 Delta `manager.sh:52-88` 的 System 分支。
   ⚠ **关键细节：必须从 `$MAGISKBIN`（`/data/adb/magisk`）拷贝，而不是从 `installDir`** —— 因为 `xdirect_install_system` 里的 `fix_env "$1"` 已经把 `installDir` 刷进 `$MAGISKBIN` 并 `rm -rf` 掉了源目录（`manager.sh:42-50`）。Delta 之所以能工作正是靠这一点。
   ```sh
   install_addond_system() {
       local AppApkPath="$1"
       local addond=/system/addon.d
       [ -d "$addond" ] || return 0          # 无 addon.d 的 ROM 直接跳过（不影响运行期）
       # 与 direct_install_system 相同的 mirror 机制；这里 MIRRORDIR 必须是可见的（见 §6 阶段 2.2 第 7 条）
       [ -d "$MIRRORDIR" ] || local MIRRORDIR=/
       cp -prLf "$MAGISKBIN"/. "$MIRRORDIR$MAGISKSYSTEMDIR" || { ui_print "! Failed to install addon.d"; return 1; }
       mv "$MAGISKBIN/addon.d.sh" "$addond/99-magisk.sh"
       cp "$AppApkPath" "$MIRRORDIR$MAGISKSYSTEMDIR/magisk.apk"
       chmod 0755 "$MIRRORDIR$MAGISKSYSTEMDIR"/*
       sed -i "s/^SYSTEMINSTALL=.*/SYSTEMINSTALL=true/g" "$addond/99-magisk.sh"
   }
   ```
   （原 Delta 版本还做了 `mkblknode` + `blockdev --setrw` + 两次 `mount -o rw,remount`，那是为了兼容 recovery/无 mirror 场景；如果安装路径已经通过 mirror 把 `/system` 弄成 rw，这几步可以保留作为兜底，但要注意它们作用在**全局挂载命名空间**上，结束后必须 `mount -o ro,remount` 还原。）
2. **`scripts/addon.d.sh`** 加：
   - 顶部 `SYSTEMINSTALL=false`
   - `main()` 里（官方 `:117-118` 的 `remove_system_su` / `install_magisk` 处）：
     ```sh
     if [ "$SYSTEMINSTALL" == "true" ]; then
       # 从 /system/etc/init/magisk 里取脚本（官方资产名已变！）
       . $MAGISKSYSTEMDIR/app_functions.sh 2>/dev/null
       . $MAGISKSYSTEMDIR/system_mode.sh    2>/dev/null
       direct_install_system "$MAGISKBINTMP" || { cleanup_system_installation; abort "! Installation failed"; }
     else
       install_magisk
     fi
     ```
   - **资产名变更点**：Delta 从 APK 里 `unzip res/raw/manager.sh`；官方对应资产是 `assets/app_functions.sh` + 我们新增的 `assets/system_mode.sh`。而更稳的是**直接使用 `/system/etc/init/magisk/` 里已经拷好的脚本副本**（`install_addond_system` 会把整个 `installDir` 拷进去，包括这两个脚本）。这样 OTA 后不依赖 APK 内的路径。
3. **`scripts/flash_script.sh`（zip/recovery 安装器）可选**：加 `getvar SYSTEMMODE` → `SYSTEMINSTALL=true` → 分支调用 `direct_install_system`（对齐 Delta `flash_script.sh:29-35,104-119`）。同时注意官方 `flash_script.sh:80-86` 的 addon.d 安装段落需要与 System Mode 分支互斥/兼容。
   - ⚠ **官方已经没有独立的安装 ZIP**：`update_binary.sh` → `META-INF/com/google/android/update-binary`、`flash_script.sh` → `META-INF/com/google/android/updater-script`，作为 **Java resources** 打进 APK（`app/build-logic/src/main/java/Setup.kt:154-168`），也就是说 **APK 本身就是刷机包**（recovery 里刷 APK 即可）。所以"zip 安装器"路径与"App 安装"路径共用同一个 `flash_script.sh`，改动它会影响 recovery 刷入行为，务必单独回归测试。
   - `scripts/addon.d.sh`、`uninstaller.sh`、`module_installer.sh` 同理都是 APK 资产（`Setup.kt:177-180`）。

### 阶段 5：卸载支持

- `scripts/uninstaller.sh` 加判断（对齐 Delta `:62`）：
  ```sh
  if [ "$(grep_prop SYSTEMMODE /system/etc/init/magisk/config)" == "true" ]; then
     # 删除 /system/etc/init/magisk 与 magisk.rc（或从 bootanim.rc.gz 还原 bootanim.rc）
     # 删除 /system/addon.d/99-magisk.sh
     # 然后正常走 data 清理
  fi
  ```
- 仔细对照 Delta `uninstaller.sh:257` 附近的 `ADDOND=/system/addon.d/99-magisk.sh` 处理。

---

## 7. 关键风险与技术注意事项

> 按"踩坑概率 × 后果严重度"排序。

1. **worker tmpfs 缺失（最容易漏）**：官方把 `.magisk/worker` 的创建从 daemon 移到了 magiskinit（`native/src/init/mount.cpp:218,235`），System Mode 下没有 magiskinit。若 `--setup-sbin` 不补，`module.rs` 的 `MountPaths::worker`（`native/src/core/module.rs:164-172`）会落到普通目录上，`clean_mounts()`（`core/mount.rs:80-95`）的 unmount 也会失败（被 `.log_ok()` 吞掉）。**功能可能"看起来正常"，但模块 magic-mount 的隔离与清理会退化为非预期状态。必须在 `--setup-sbin` 里建目录 + 挂 tmpfs。**
2. **`/sbin` 不存在**：2SI 设备的 `/` 是 rootfs → `mkdir /sbin` 可行；legacy SAR 的 `/sbin` 在 system 镜像里；若都不满足则 tmpfs 挂载失败。**安装前先用 shell 预检 `mkdir` 并给出可读错误**（Delta 的做法），不要等到开机失败。
3. **daemon 必须从 `/sbin` 启动**：`connect_daemon` 会校验 `/proc/self/exe` 前缀（`core/daemon.rs:457-462`）。**rc 里第一条 `magisk --post-fs-data` 必须用 `$MAGISKTMP/magisk`**，用 `/system/etc/init/magisk/magisk` 会直接失败。
4. **`.magisk` 哨兵目录**：`get_magisk_tmp()` 只认 `access("/sbin/.magisk")`。`--setup-sbin` 里 **`chdir` 与 `mkdir` 的顺序** 决定了相对路径宏能否正确工作。
5. **SELinux 三连 `magiskpolicy --live --magisk` 不能合并成一条**：`magisk_rules()` 里 `deny(*, kernel, security, load_policy)` 会在第一次成功后锁死重载；三条 `exec` 是针对不同 init 可转换域的**抢占尝试**。**不要"优化"成一条。**
6. **离线 sepolicy patch 的适用条件**：只在 `! is_rootfs` 时做；目标文件要按 `/vendor` → `/odm` → `/system` → `/system_root` 的顺序找；**必须 gz 备份 + 失败回滚**，否则设备可能无法开机。
7. **`--patch-sepol` 用 `magiskpolicy --load/--save` 时注意 split policy 不适用**（见 §6.3 方案 A）；安装期目标是磁盘上的 monolithic `precompiled_sepolicy`，安全。
8. **二进制命名必须统一改为 `magisk`**：官方不再产生 `magisk64`；`magisk32` 是 App 从 32 位 ABI 复制出来的。任何沿用 `magisk64` 的地方（rc、拷贝名单、软链目标）都会 100% 失败。
9. **函数加载顺序（脚本层最隐蔽的坑）**：`app_functions.sh` 与 `util_functions.sh` 定义**同名函数**（`mount_partitions`、`get_flags`、`grep_prop`、`run_migrations`）。必须"先 app_functions 后 util_functions"（与 Delta `addon.d.sh:126-130` 一致），否则 `LEGACYSAR` / `SYSTEM_AS_ROOT` / `CRYPTOTYPE` 会取到简化版实现的结果。
10. **未 root 时 shell 环境没有 `util_functions.sh`**：`ShellInit.kt:67-69` 只在 `shell.isRoot` 时注入 `util_functions.sh`。System Mode 的典型场景正是"还没 root 就要装 Magisk"，**必须把所需脚本放进 `installDir` 并显式 `.` 加载**，不能依赖注入。
11. **`extractFiles()` 的 `installDir` 路径**：官方用 `localFS.getFile(context.filesDir.parent, "install")`，`context` 是 **device-protected** Context（`ServiceLocator.deContext`），因此是 **`/data/user_de/0/<pkg>/install`**；`Info.noDataExec` 时会被移到 `Const.TMPDIR`（`MagiskInstaller.kt:180-191`）。Windows 风格的写法/硬编码会在 device-protected 存储的设备上直接失败 —— `xdirect_install_system` 的参数必须原样传递 Kotlin 侧算出的 `"$installDir"` 字符串（Delta 也是这么做的）。
12. **mirror 技巧依赖 `/proc/<pid>/attr` 可被 tmpfs 覆盖**：极少数内核/容器配置可能不允许（例如已经 noexec/只读 proc 的容器）。需要 fallback：若 `mount -t tmpfs tmpfs /proc/$$/attr` 失败，则退化为"直接 remount rw + 直接写"（在没有任何 Magisk overlay 的容器里其实是正确的）。
13. **`dd` 空间自检可能误报**：Delta 用 20MB 写入测试；某些 F2FS/erofs 设备会误判。建议保留但把失败降级为 warning（或者把阈值调小）。
14. **`bootanim.rc` 追加 vs `magisk.rc` 独立文件**：追加到 `bootanim.rc` 更"隐蔽"且在某些 ROM 上更稳（`bootanim` 服务一定存在），但会污染原文件、依赖 `bootanim.rc.gz` 备份还原。**建议保留 Delta 的双策略，并把 `.gz` 备份纳入 Uninstall/OTA 还原流程。**
15. **`MagiskD` 结构体的 `mem::transmute`**：C++/Rust 通过 `transmute` 共享 `MagiskD`（`native/src/core/lib.rs` / `core-rs` 桥）。**不要往 `MagiskD` 里加字段**来存 System Mode 状态（会错位）。System Mode 的判据应当是文件系统状态（`.magisk`、`config`），而不是内存标志。
16. **`--setup-sbin` 的 `run_migrations` / DB**：System Mode 下 `/data/adb/magisk.db` 不存在，daemon 首次启动会自己创建（`bootstages.rs` 的 `post_fs_data` → `setup_magisk_env`）。**先 `fix_env` 把二进制刷进 `/data/adb/magisk` 再重启**是顺序关键（`xdirect_install_system` 已经这么做）。
17. **`magisk32` 在 32 位-only 设备上不存在**：`--setup-sbin` 的拷贝必须容错（`if exists`），rc 里也只用 `magisk`。
18. **不要在 `--auto-selinux` 写失败时 exit**：Delta 静默继续。而且写 `/proc/self/attr/current` **必须带 NUL 结尾**（`sizeof(literal)`）。
19. **`stub.apk` 的权限**：Delta 给了 `chmod 755`，无意义但无害；官方 `magiskinit` 用 mode 0（`init/rootdir.cpp:228`）。建议跟随官方（mode 0644）。
20. **构建系统规则**：`AGENTS.md` 明确要求独立执行 `cargo`/`rustc`/`ndk-build`/`gradlew` 必须加 `scripts/env.py` 前缀；`native/` 与 `app/` 都有对应的 skill 文档需要先读（`.agents/skills/magisk-native/SKILL.md`、`.agents/skills/magisk-app/SKILL.md`）。
21. **不要在未获批准时提交 git**（AGENTS.md 第 1 条）。
22. **法律/合规**：System Mode 会永久修改系统分区，若 `direct_install_system` 中途失败（写了一半），设备可能无法开机。**必须提供"失败即回滚"路径**：sepolicy 用 `.gz` 备份还原、rc 用"追加到 bootanim.rc"策略可整体还原、并在 UI 上明确警告。
23. **`is_rootfs()` 在官方是 `init` crate 的私有函数**（`native/src/init/mount.rs:68`，`pub(crate)`），而且**不包含 OVERLAYFS magic**（只判 RAMFS 0x858458f6 与 TMPFS）。core crate **无法调用**它。移植时必须：
    - 在 core（或 base）里重新实现一份，并**加上 `0x794c7630`（overlayfs）**，否则 Waydroid 上 `is_rootfs()` 判定失败会走错分支；
    - shell 层的 `is_rootfs()`（Delta `util_functions.sh:741-751`，读 `/proc/self/mountinfo` 第 9 字段）与 native 版判据不同，两者都要保留（shell 版决定是否 patch sepolicy 与是否用 `/` 作 ROOTDIR，native 版只决定 `mount_sbin()` 走哪条分支）。
24. **`magiskpolicy --load` 不做 SHA-256 新鲜度校验**：官方只有 `SePolicy::from_split()` 会 `check_precompiled()`（`native/src/sepolicy/policydb.cpp:36-74, 217-226`），`from_file()` 不会。对我们**有利**（可以直接 load/patch/save 任意 precompiled 文件），但要意识到 `--load` 也会接受过期/不匹配的策略文件 —— shell 层不要多加无谓的校验。
25. **不要依赖 `.magisk/live` 标记**：它由 `scripts/avd_setup.sh:141` 写入，但**整个 native 代码库没有读取者**；全仓库唯一的读者是测试框架 `app/core/src/main/java/com/topjohnwu/magisk/test/Environment.kt:43-47`（用于跳过 preinit 检查）。系统模式若要标记自身，请自定义（例如继续沿用 `/system/etc/init/magisk/config` 的 `SYSTEMMODE`）。
26. **`magisk64` 只是 `argv[0]` 别名，不是构建产物**：`native/src/core/applets.cpp:48` 仍接受 `magisk64` 作为 multicall 名称，但 `native/src/Android.mk` 只产出 `magisk`（32 位 ABI 的 `magisk` 会被 App/脚本重命名为 `magisk32`，见 `app/build-logic/src/main/java/Setup.kt:133-140`、`build.py:673-680`、`scripts/flash_script.sh:58`）。所以 rc 和拷贝名单里**只能出现 `magisk` 与 `magisk32`**。
27. **官方 `magiskinit` 没有 CLI 解析器**（见 §6 阶段 1.3），且 `magisk_proxy_main` 也不接受选项。如果选择方案 A（`magiskpolicy --load/--save`），native 侧可以做到**零改动**；这是风险最低的路线。
28. **App 有两套安装 UI**：`app/apk`（Compose，`InstallDialog.kt`）与 `app/apk-legacy`（XML/DataBinding，与 Delta 结构几乎一致）。先确认 `apk-legacy` 是否仍在构建/分发（`./build.py app` vs `./build.py app-legacy`，见 `docs/build.md`），再决定改一套还是两套，避免"改了一半、用户看到的是另一套 UI"。（好消息：字符串只有一份，见 §6 阶段 3.5。）
29. **`setup_magisk_env()` 是硬约束**：它在 `post-fs-data` 里会 `error!("* Magisk environment incomplete, abort")` 并中止整个 Magisk 初始化，**条件仅仅是 `/data/adb/magisk/busybox` 不存在**（`native/src/core/bootstages.rs:70-73`）。因此 System Mode 安装时 `fix_env "$installDir"` **必须成功执行完**（把 `installDir` 里的 `busybox` 刷到 `/data/adb/magisk`）——否则重启后 `/sbin` 铺好了、rc 也跑了，daemon 却会静默 abort，表现为"装了但没 root"。这也是为什么 `xdirect_install_system` 把 `fix_env` 放在 `install_addond` 之前且不可交换。
30. **PATH 环境**：app 进程会给 shell 追加 `:/debug_ramdisk:/sbin`（`app/core/src/main/java/com/topjohnwu/magisk/core/AppContext.kt:52`）。这对 System Mode 有利（`su`/`resetprop` 软链在 `/sbin`，安装后可立即使用），但也意味着**测试时不要以为 `su` 一定来自 `/system/xbin/su`**。
31. **`isEmulator` 在 Kotlin 与 native 中判据不一致**：Kotlin 用 `Build.DEVICE.contains("vsoc") || ro.kernel.qemu || ro.boot.qemu`（`app/core/.../Info.kt:58-61`），native 用 `ro.kernel.qemu || ro.boot.qemu || ro.product.device` 含 `vsoc`（`native/src/core/daemon.rs:310-312`）。且 `goldfish`/`ranchu`/`waydroid` 在官方仓库**完全没有出现**。若 System Mode 想覆盖 Waydroid/redroid 等容器，需要自行放宽判据（或干脆不依赖 `isEmulator`，只依赖 `isRooted && !isBootPatched`，与 Delta 保持一致）。
32. **`.agents/tmp_systemmode_archaeology.md` 是本次调研产出的原始逐行取证报告**（约 3400 行，含大量 verbatim 代码与 file:line），由子代理生成。实现时可以当作源码索引查阅；如果不需要，可在合并前删除或移到 `docs/` 之外（它是未跟踪文件，不影响构建）。

---

## 8. 验证方案（模拟器 / 容器测试矩阵）

### 8.1 环境矩阵

| 环境 | API | rootfs? | /sbin 存在? | 重点验证 |
|---|---|---|---|---|
| AVD x86_64（`build.py emulator` 可用的镜像） | 30/33/34/35/36 | 是（rootfs） | 否（需自建） | 全流程 + rc 生效 + 重启后 root |
| AVD x86（32 位） | 30 | 是 | 否 | `magisk32`-only 分支 |
| AVD legacy SAR | 28 | 否 | 是 | `mount_sbin()` 非 rootfs 分支 + `--patch-sepol` 分支 |
| Waydroid（overlayfs 根） | 30-33 | **overlayfs** | 视镜像 | `is_rootfs()` 必须包含 OVERLAYFS magic |
| redroid / LXC 容器 | 30+ | 视镜像 | 视镜像 | 容器内 mount 权限、`/proc/<pid>/attr` 可写性 |
| 真实设备（可选） | 29-35 | 否 | 视设备 | `--patch-sepol` 的真实必要性 |

### 8.2 分层测试步骤

**T1：native CLI 单测（不依赖安装流程）**
```bash
# 在已 root 的 AVD 上
adb shell 'mkdir -p /data/local/tmp/m && cd /data/local/tmp/m && ln -sf /system/etc/init/magisk/magisk . 2>/dev/null'
adb shell '/data/local/tmp/magisk --setup-sbin /system/etc/init/magisk /sbin; echo "rc=$?"'
adb shell 'ls -la /sbin; ls -la /sbin/.magisk; mount | grep sbin; ls -laZ /sbin | head'
# 期望：/sbin 是 tmpfs，source=magisk，含 magisk/magisk32/magiskpolicy/stub.apk/su/resetprop/supolicy/.magisk/{device,worker}
adb shell '/sbin/magisk --path'          # 期望输出 /sbin
adb shell '/sbin/magisk --auto-selinux -c; echo rc=$?'   # 期望打印版本，rc=0
```

**T2：sepolicy patch（方案 A）**
```bash
adb shell 'cp /vendor/etc/selinux/precompiled_sepolicy /data/local/tmp/sepol.in'
adb shell '/data/local/tmp/install/magiskpolicy --load /data/local/tmp/sepol.in --magisk --save /data/local/tmp/sepol.out; echo rc=$?'
adb shell 'ls -l /data/local/tmp/sepol.out'   # 期望存在且大小合理（略大于 in）
```

**T3：shell 层端到端（不重启）**
按 §6 阶段 2.5 的命令执行，检查：
- `/system/etc/init/magisk/` 下有全部文件，`ls -Z` 为 `u:object_r:system_file:s0`
- `/system/etc/init/magisk.rc`（或 `bootanim.rc` 末尾）内容正确
- `/data/adb/magisk/` 已被 `fix_env` 填充
- 若原 sepolicy 被 patch：`*.gz` 备份存在

**T4：重启后行为（关键验收）**
```bash
adb shell 'setprop sys.boot_completed 0; stop; start'
# 或 AVD: Cold Boot Now
sleep 60
adb shell 'getprop sys.boot_completed'
adb shell 'ls -la /sbin/.magisk'
adb shell 'logcat -d | grep -iE "magisk|avc" | tail -100'
adb shell 'su -c id'                 # 期望 uid=0，且弹 Magisk 授权（或按策略直接放行）
adb shell '/sbin/magisk -v'
adb shell 'cat /proc/self/attr/current'    # 在 su shell 里看上下文
```
判据：`sys.boot_completed=1`、`/sbin/.magisk` 存在、logcat 有 "Magisk ... daemon started"、**没有 bootloop**、`su` 可用。

**T5：功能回归**
- 安装一个模块（`magisk --install-module`）并重启，验证 magic-mount 生效（`/sbin/.magisk/worker` 与 `/sbin/.magisk/modules`）。
- Zygisk 开关（官方支持）。
- deny list / MagiskHide（官方为 denylist）。
- 卸载流程。
- OTA 存活（模拟器上难做，可在 Waydroid 上验证 addon.d 分支的可执行性）。

**T6：失败回滚测试**
- 人为让 `--patch-sepol` 失败 → 验证 `.gz` 还原且设备仍能启动。
- 人为让 `--setup-sbin` 失败 → 验证安装中止、rc 被 `cleanup_system_installation` 删除、设备能启动（只是没有 Magisk）。

### 8.3 验收标准

1. 全新未 root 的 AVD/Waydroid 上，App 内点一次安装 → 重启 → 获得 root，且**不需要 PC、不需要预先 root、不需要 patch boot**。
2. 重启 3 次稳定，无 bootloop，无 AVC denial 阻塞关键服务。
3. `magisk -v` / `magisk --path` = `/sbin`；模块、denylist、Zygisk（如适用）可用。
4. 卸载后 `/system/etc/init/magisk*`、`/system/addon.d/99-magisk.sh` 被清理，`bootanim.rc` 已还原，重启后无残留。
5. 非 System Mode 的既有路径（boot patch 安装、正常 systemless 启动、`build.py emulator`）**零回归**。

---

## 9. 回滚与卸载

### 9.1 安装期失败回滚（必须实现）

| 失败点 | 回滚动作 |
|---|---|
| sepolicy patch 失败 | `restore_from_bak "$MIRRORDIR$sepol"`（从 `.gz` 还原），并删除 `.gz` |
| rc 写入失败 | `cleanup_system_installation`（删 `$MAGISKSYSTEMDIR` 与 `.rc`；若用的是 `bootanim.rc` 方案则从 `.gz` 还原） |
| 目录拷贝失败 | 同上 |
| 整体失败 | `xdirect_install_system` 的 `|| { cleanup_system_installation; installer_cleanup; return 1; }` |
| App 层 | `MagiskInstallImpl.exec()` 失败时会 `rm -rf $installDir`（官方 `MagiskInstaller.kt:548-551`） |

### 9.2 用户可见的卸载

- App 内"卸载 Magisk"→ `MagiskInstaller.Uninstall` → `run_uninstaller $AppApkPath` → `scripts/uninstaller.sh`。
- 需要新增"System Mode 分支"（§6 阶段 5）：删除 `/system/etc/init/magisk*`、`/system/addon.d/99-magisk.sh`、还原 `bootanim.rc`，再走原有 `/data/adb` 清理。
- 手工兜底（文档应写进 FAQ）：
  ```bash
  adb root
  adb shell 'mount -o rw,remount /; rm -rf /system/etc/init/magisk /system/etc/init/magisk.rc /system/addon.d/99-magisk.sh; mount -o ro,remount /'
  adb shell 'rm -rf /data/adb/magisk /data/adb/modules'
  ```
  （若曾用过 `bootanim.rc` 方案：`gzip -df /system/etc/init/bootanim.rc.gz`）

---

## 10. 附录

### 10.1 文件对照表（Delta → 官方）

| 功能 | Delta 路径 | 官方对应 / 目标路径 |
|---|---|---|
| `magisk` CLI 入口 | `native/src/core/magisk.cpp` | `native/src/core/magisk.rs` |
| `magiskinit` CLI 入口 | `native/src/init/init.cpp` | `native/src/init/init.rs` |
| `patch_sepol` | `native/src/init/selinux.cpp:12-18` | 新增：`native/src/init/selinux.rs`（方案 B）或不用（方案 A） |
| `mount_sbin`/`is_rootfs`/`recreate_sbin_v2` | `native/src/core/deny/revert.cpp:25-110` | 新增：`native/src/core/setup.rs` |
| `tmpfs_mount`/`setcurrent` | `native/src/base/cus.cpp` | 新增于 `core/setup.rs` 或 `base/` |
| post-fs-data 只读自锁 | `native/src/core/bootstages.cpp:296-304` | `native/src/core/bootstages.rs`（可选） |
| 安装脚本主体 | `app/src/main/res/raw/manager.sh` | `scripts/system_mode.sh`（新增，资产） |
| 非 root 工具函数 | 同上（manager.sh 内） | `scripts/app_functions.sh`（已存在） |
| `is_rootfs` 等 shell 工具 | `scripts/util_functions.sh:741-783` | `scripts/util_functions.sh`（新增） |
| OTA 存活 | `scripts/addon.d.sh:125-138` + `manager.sh:52-88` | `scripts/addon.d.sh`（新增分支）+ `scripts/system_mode.sh` |
| 卸载识别 | `scripts/uninstaller.sh:62` | `scripts/uninstaller.sh`（新增分支） |
| 安装 UI（Compose） | `app/src/main/res/layout/fragment_install_md2.xml:201-207` | `app/apk/src/main/java/com/topjohnwu/magisk/ui/install/InstallDialog.kt`（`:110-203`） |
| 安装 UI（legacy XML） | 同上（Delta 只有这一套） | `app/apk-legacy/src/main/java/com/topjohnwu/magisk/ui/install/InstallViewModel.kt` + 对应 `fragment_install_md2.xml` |
| 安装 VM | `app/.../ui/install/InstallViewModel.kt` | `app/apk/.../ui/install/InstallViewModel.kt` |
| Flash VM | `app/.../ui/flash/FlashViewModel.kt:74-76` | `app/apk/.../ui/flash/FlashViewModel.kt:77-116` |
| 安装引擎 | `app/.../core/tasks/MagiskInstaller.kt:540` | `app/core/.../core/tasks/MagiskInstaller.kt` |
| `Const.Value` | `app/.../core/Const.kt:65` | `app/core/.../core/Const.kt` |
| `Info.isBootPatched` | `app/.../core/Info.kt:39` + `ShellInit.kt:87` | `app/core/.../core/Info.kt` + `ShellInit.kt` |
| 安装字符串 | `app/src/main/res/values/strings.xml:256` | `app/core/src/main/res/values/strings.xml` |
| 资产打包 | （Delta 用 raw resource，无需打包脚本） | `app/build-logic/src/main/java/Setup.kt:171-200` |

### 10.2 CLI 对照表

| Delta | 官方现状 | 目标 |
|---|---|---|
| `magisk --auto-selinux <cmd...>` | 无 | 新增（前缀开关） |
| `magisk --mount-sbin` | 无 | 可选（或并入 `--setup-sbin`） |
| `magisk --setup-sbin SRCDIR [DSTDIR]` | 无 | 新增 |
| `magisk --install [DIR]` | 无 | 可选新增 |
| `magiskinit --patch-sepol IN [OUT]` | 无 | `magiskpolicy --load IN --magisk --save OUT`（方案 A）或新增（方案 B） |
| `magiskpolicy --live --magisk` | **已有** | 直接用 |
| `magiskpolicy --apply FILE` | **已有** | 直接用（自定义 sepolicy.rule） |
| `magisk --post-fs-data/--service/--boot-complete/--zygote-restart` | **已有** | 直接用 |
| `magisk --path` | **已有** | 直接用 |

### 10.3 待确认问题（明天实现前先确认，避免返工）

1. **官方中文翻译目录名**：Delta 用 `app/src/main/res/values-zh*`；官方是模块化 + Compose，需要确认 `app/core/src/main/res/values-zh-rCN/strings.xml` 是否存在、以及是否有翻译流程（可能是 Weblate/Crowdin 导出）。→ 用 `glob "app/core/src/main/res/values-zh*"` 确认。
2. **`Setup.kt` 资产 include 列表是否要加 `.sh` 之外的东西**：只需加文件名即可（`Sync` 会整目录同步）。
3. **`Const.TMPDIR` 与 `Info.noDataExec` 的影响**：`extractFiles()` 在 `shell.isRoot && Info.noDataExec` 为真时会把 `installDir` `cp_readlink` 到 `/dev/tmp` 并删除原目录（`MagiskInstaller.kt:180-191`）。System Mode 要求 `isRooted`，所以 `noDataExec` **有可能为真**（Samsung 类设备、部分容器）；两种路径对 root shell 都可读写，但**脚本里不要硬编码**（正常情况下是 `/data/user_de/0/<pkg>/install`，device-protected 存储），一律用传入的 `"$installDir"`。
4. **`magisk --setup-sbin` 的 DSTDIR 选择**：实现为 `--setup-sbin SRCDIR [DSTDIR]`，默认 `/sbin`，允许 App/脚本下发 `/debug_ramdisk`。⚠ 注意 `get_magisk_tmp()` 的优先级是 **先 `/debug_ramdisk` 后 `/sbin`**（`native/src/core/utils.cpp:33-45`）——若设备上两者都带 `.magisk`，会用 `/debug_ramdisk`，因此 `--setup-sbin` 与 rc 里的 `MAGISKTMP` 必须一致，否则 daemon 会认错目录。
5. **`zygisk-restart` 触发器是否仍然必要**：官方 `magisk.rs` 仍支持 `--zygote-restart`（`:70, 238-240`），保留即可。
6. **`magiskinit` 是否需要拷进 `/system/etc/init/magisk`**：只在方案 B（离线 patch）时需要；方案 A 完全不需要。**建议方案 A 时不要拷 `magiskinit`**，减少无谓暴露。
7. **`uninstall_system_mirrors` 的正确实现**：Delta 引用了未定义函数；移植时写明为 `cleanup_system_installation; installer_cleanup`。
8. **是否需要 `magisk --setup-sbin` 把 `busybox` 也铺进 tmpfs**：官方 daemon 的 `setup_magisk_env()` 会自己从 DATABIN 拷 `busybox`（到 `.magisk/busybox/`）并 `--install` applet，还会补 `magisk32` 与 `magiskpolicy`（`native/src/core/bootstages.rs:70-104`），所以**不需要**在 `--setup-sbin` 里拷 busybox。⚠ 两点必须记住：(a) 这一步发生在 `--post-fs-data` 期间，`--setup-sbin` 之后、`--post-fs-data` 之前 `/sbin` 里没有 busybox（正常）；(b) **`magisk` 本身不会被这一步补拷** —— 必须由 `--setup-sbin` 放到 `<DSTDIR>/magisk`，否则 `connect_daemon` 的 "Start daemon on magisk tmpfs" 校验会失败（`native/src/core/daemon.rs:457-462`）。
9. **`VENDORBOOT` / GKI 等新概念**：官方新增了 `VENDORBOOT`（`app_functions.sh:216`、`Info.isVendorBoot`）。System Mode 不涉及 boot 镜像，可忽略；但 `get_flags()` 的调用要保持兼容。
10. **`policyvers` 差异**：Delta 的 `rules.cpp:30-35` 用 `policyvers >= POLICYDB_VERSION_XPERMS_IOCTL` 条件加 `allowxperm`；官方 `rules.rs:85-87` 也用 `allowxperm(...xall)`（`Xperm { low: 0, high: 0xFFFF, reset: false }`）。实现 `--patch-sepol` 时**必须直接复用官方 `rules.rs` 的 `magisk_rules()`**，不要抄 Delta 的 C++ 版本，否则会漏掉官方新增/调整的规则。
11. **`app/apk-legacy` 是否仍在构建**：确认 `./build.py app_legacy` 是否被发布流程使用（见 `docs/build.md`）。若用户在 legacy UI 上点安装却看不到 System Mode 选项，会被误判为"功能没实现"。
12. **产物清单核对**：`native/out/<abi>/` 下应有 `magisk`、`magiskinit`、`magiskboot`、`magiskpolicy`（`resetprop` 仅显式构建）、`libinit-ld.so`；`busybox` 与 `bootctl` 来自下载的预编译包（`app/build-logic/src/main/java/Setup.kt:141-144`）。**没有 `magisk64`**；`magisk32` 只是把 32 位 ABI 的 `libmagisk.so` 改名而来。
13. **`native/src/*/*-rs.cpp` 是生成文件，不要手改**：cxx 桥由各 crate 的 `build.rs` 通过 `include/gen.rs` 生成（`core-rs.cpp`、`init-rs.cpp`、`policy-rs.cpp`、`base-rs.cpp`）。新增 FFI 要在对应 `lib.rs` 的 `#[cxx::bridge]` 里声明，然后用 `./build.py gen` 重新生成。若 `--setup-sbin` / `--auto-selinux` 全部写在 Rust 内（core crate 内部），**不需要任何新的 FFI**。

### 10.4 参考代码索引（关键行号汇总）

**Delta（`D:\a\KitsuneMagisk`）**
- `app/src/main/res/raw/manager.sh:52-88` `install_addond`
- `app/src/main/res/raw/manager.sh:282` `MAGISKSYSTEMDIR`
- `app/src/main/res/raw/manager.sh:291-318` `magiskrc`
- `app/src/main/res/raw/manager.sh:351-359` `cleanup_system_installation`
- `app/src/main/res/raw/manager.sh:361-368` `installer_cleanup`
- `app/src/main/res/raw/manager.sh:370-541` `direct_install_system`
- `app/src/main/res/raw/manager.sh:545-551` `xdirect_install_system`
- `app/src/main/res/raw/manager.sh:559-572` `app_init`
- `scripts/util_functions.sh:741-783` shell 工具函数
- `scripts/addon.d.sh:125-138` SYSTEMINSTALL 分支
- `scripts/uninstaller.sh:62` 卸载识别
- `native/src/core/magisk.cpp:17-25,65-80,106-144`
- `native/src/core/selinux.cpp:13-21,126-143`
- `native/src/core/deny/revert.cpp:25-110`
- `native/src/core/bootstages.cpp:293-306`
- `native/src/init/init.cpp:65-77`
- `native/src/init/selinux.cpp:12-18`
- `native/src/sepolicy/rules.cpp:8-145`

**官方（`D:\Magisk`）**
- `native/src/core/magisk.rs:50-79,288-298`（子命令枚举与 `magisk_main`）
- `native/src/core/utils.cpp:33-45` `get_magisk_tmp`
- `native/src/core/daemon.rs:295-328,426-462`（daemon 启动、config 读取、connect 校验）
- `native/src/core/bootstages.rs:32-107,109-161`（`setup_magisk_env`、`post_fs_data`）
- `native/src/core/mount.rs:67-95`（`setup_module_mount`、`clean_mounts`）
- `native/src/core/module.rs:164-172`（`MountPaths::worker`）
- `native/src/core/selinux.rs:75-97` `restore_tmpcon`
- `native/src/init/init.rs:179-200`（magiskinit main）
- `native/src/init/selinux.rs:219-287`（`handle_sepolicy`）
- `native/src/init/mount.cpp:212-249`（`setup_tmp`：`.magisk`/`device`/`worker` + applet 软链）
- `native/src/init/rootdir.cpp:205-233,340-401`（`recreate_sbin`/`patch_rw_root`/`magisk_proxy_main`）
- `native/src/sepolicy/cli.rs:12-139`（`--live`/`--magisk`/`--load`/`--save`）
- `native/src/sepolicy/rules.rs:50-147` `magisk_rules`
- `native/src/include/consts.rs` / `consts.hpp`（`INTLROOT`/`DEVICEDIR`/`WORKERDIR`/`MAIN_CONFIG`/`MAGISK_PROC_CON`/`APPLET_NAMES`）
- `scripts/app_functions.sh`（全文）
- `scripts/util_functions.sh:502-527`
- `scripts/addon.d.sh`（全文）
- `scripts/avd_setup.sh`（全文，作为"手工版启动流程"参考）
- `app/core/src/main/java/com/topjohnwu/magisk/core/tasks/MagiskInstaller.kt:108-194,480-530,582-645`
- `app/core/src/main/java/com/topjohnwu/magisk/core/utils/ShellInit.kt:17-75`
- `app/core/src/main/java/com/topjohnwu/magisk/core/Info.kt:36-124`
- `app/apk/src/main/java/com/topjohnwu/magisk/ui/install/InstallViewModel.kt`（全文）
- `app/apk/src/main/java/com/topjohnwu/magisk/ui/install/InstallDialog.kt:110-203`
- `app/apk/src/main/java/com/topjohnwu/magisk/ui/flash/FlashViewModel.kt:71-118`
- `app/apk-legacy/src/main/java/com/topjohnwu/magisk/ui/install/InstallViewModel.kt`（legacy XML UI 的 `skipOptions`/`noSecondSlot`，`:39-40`）
- `app/build-logic/src/main/java/Setup.kt:129-202`（jniLibs 改名 + assets 打包）
- `app/core/src/main/java/com/topjohnwu/magisk/core/utils/ShellInit.kt:17-75`
- `native/src/core/daemon.rs:298-304`（daemon 自设 `u:r:magisk:s0`）
- `native/src/core/mount.rs:67-95`（`setup_module_mount` / `clean_mounts`，worker 清理）
- `native/src/core/module.rs:164-172`（`MountPaths::worker` = `$MAGISKTMP/.magisk/worker`）
- `native/src/sepolicy/policydb.cpp:239-268`（`to_file`：整份策略写入 `/sys/fs/selinux/load`）
- `native/src/sepolicy/policydb.cpp:217-226` + `36-74`（`from_split` 与 `check_precompiled` 的 SHA-256 校验）
- `native/src/init/init.rs:148-150, 179-200`（magiskinit 的 `selinux_setup` 与 `argv[0]=="magisk"` 分支，无 CLI 解析器）
- `native/src/init/mount.rs:66-74`（`is_rootfs()`，`pub(crate)`，不含 overlayfs）
- `native/src/init/rootdir.cpp:205-232`（`static recreate_sbin`）、`:262-334`（`patch_ro_root` 选 `/sbin` 或 `/debug_ramdisk`）、`:340-401`（`patch_rw_root` / `magisk_proxy_main`）
- `native/src/init/mount.cpp:212-249`（`setup_tmp`：`.magisk`/`device`/`worker` + applet 软链）
- `native/src/include/consts.hpp` + `consts.rs`（路径常量、`applet_names`/`APPLET_NAMES`、`SEPOL_*`）
- `app/core/src/main/java/com/topjohnwu/magisk/test/Environment.kt:43-59`（`.magisk/live` 标记的唯一读取者）
- `build.py:40-41, 156-162, 629-724`（构建目标、`native/out/<abi>/` 收集、`push_files`/`emulator`/`patch`）

---

## 11. 交付物与工作区状态

本次任务**只做调研与方案，未改动任何代码**。工作区状态（`git status`）：

```
 M tools/futility                    ← 本次任务之前就已存在的改动（与本方案无关，勿动/勿提交）
?? docs/system_mode_port_plan.md          ← 本文档（调研 + 方案，主交付物）
?? docs/system_mode_handoff_prompt.md     ← 给"下一个对话/下一个 AI"的交接提示词（可原样粘贴）
?? .agents/tmp_systemmode_archaeology.md  ← 子代理生成的逐行取证报告（约 3400 行，可作为源码索引）
```

- 本文档即交付给"明天写代码的 AI"的实施方案。
- `docs/system_mode_handoff_prompt.md` 是一段自包含的开工提示词：把它粘贴到同一工作区的**新对话**里，新 AI 就能拿到目标、施工顺序、12 条铁律与全部关键坑点，直接进入编码。
- `.agents/tmp_systemmode_archaeology.md` 是调研过程中生成的**原始证据附录**（大量 verbatim 代码 + file:line），可作为查源码时的快速索引；若不需要可在实现前删除。
- 提交代码时请遵守 `AGENTS.md`：**未经用户明确要求不得 commit / amend**；独立执行 `cargo`/`rustc`/`ndk-build`/`gradlew` 必须先加 `scripts/env.py` 前缀；改 `native/` 前先读 `.agents/skills/magisk-native/SKILL.md`，改 `app/` 前先读 `.agents/skills/magisk-app/SKILL.md`。

---

**文档结束。**

> 实现顺序建议再强调一次：**先在设备上把 §6 阶段 1 + 阶段 2 用 adb 手工跑通（能重启拿到 root），再写阶段 3 的 App 代码。** Shell/Native 层有任何偏差都会表现为"重启后没 root 或 bootloop"，在没有 App 的情况下用 logcat + `dmesg` 调试会快得多。
>
> 另外提醒一句最容易走弯路的地方：**不要试图"简化"成"直接把文件写进 `/system` 就行"**。真正的工作量在 (1) tmpfs `/sbin` 的自举（`.magisk` 哨兵 + `worker` 目录）、(2) SELinux 两段式引导（live patch + 磁盘 sepolicy patch）、(3) init rc 的持久化与失败回滚、(4) shell 与 App 两侧的入口接线。缺任何一环都会表现为"看起来装好了，重启后没 root 或 bootloop"。

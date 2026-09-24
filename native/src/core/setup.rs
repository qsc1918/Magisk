// System Mode support: bootstrap a Magisk tmpfs without magiskinit.
//
// This ports the Magisk Delta `--setup-sbin` / `mount_sbin` / `recreate_sbin`
// logic into the official Rust core. It is used when Magisk is installed by
// directly modifying the /system partition (Android emulators, Waydroid,
// redroid and other containerized Android environments) where the boot image
// cannot be patched, so there is no magiskinit to prepare the tmpfs for us.

use crate::consts::{APPLET_NAMES, DEVICEDIR, INTERNAL_DIR, WORKERDIR};
use base::{
    Directory, LibcReturn, LoggedResult, OsResult, ResultExt, Utf8CStr, Utf8CString, cstr, libc,
    log_err, warn,
};
use nix::mount::{MsFlags, mount};

const RAMFS_MAGIC: i64 = 0x858458f6;
const TMPFS_MAGIC: i64 = 0x01021994;
const OVERLAYFS_MAGIC: i64 = 0x794c7630;

const ROOT_CON: &Utf8CStr = cstr!("u:object_r:rootfs:s0");

/// Join `base` with `name` into a freshly allocated, NUL terminated path.
fn path_join(base: &str, name: &str) -> Utf8CString {
    let mut s = String::with_capacity(4096);
    s.push_str(base);
    if !s.ends_with('/') {
        s.push('/');
    }
    s.push_str(name.trim_start_matches('/'));
    Utf8CString::from(s)
}

/// Detect whether / is a ramdisk-like root.
///
/// This is a core-local reimplementation of the Delta version
/// (core/deny/revert.cpp is_rootfs). The magiskinit variant in
/// init/mount.rs is `pub(crate)` and does NOT recognize overlayfs, which
/// makes it return the wrong answer on Waydroid.
pub fn is_rootfs() -> bool {
    match nix::sys::statfs::statfs("/") {
        Ok(s) => matches!(
            s.filesystem_type().0 as i64,
            RAMFS_MAGIC | TMPFS_MAGIC | OVERLAYFS_MAGIC
        ),
        Err(_) => false,
    }
}

/// Mount a tmpfs with the Magisk flavour.
///
/// The source MUST be "magisk": revert_unmount() and other Magisk mount
/// bookkeeping identify Magisk owned mounts by their source field.
fn tmpfs_mount(to: &Utf8CStr) -> OsResult<'_, ()> {
    mount(
        Some(cstr!("magisk")),
        to,
        Some(cstr!("tmpfs")),
        MsFlags::empty(),
        Some(cstr!("mode=755")),
    )
    .check_os_err("mount", None, None)
}

fn bind_mount<'a>(from: &'a Utf8CStr, to: &'a Utf8CStr) -> OsResult<'a, ()> {
    mount(
        Some(from),
        to,
        None::<&Utf8CStr>,
        MsFlags::MS_BIND,
        None::<&Utf8CStr>,
    )
    .check_os_err("bind_mount", None, None)
}

fn remount_root(flags: MsFlags) -> OsResult<'static, ()> {
    mount(
        None::<&Utf8CStr>,
        cstr!("/"),
        None::<&Utf8CStr>,
        MsFlags::MS_REMOUNT | flags,
        None::<&Utf8CStr>,
    )
    .check_os_err("remount", None, None)
}

/// Recreate everything that used to live in /sbin inside our fresh tmpfs.
///
/// Ported from Delta core/deny/revert.cpp recreate_sbin_v2. `mirror` is a
/// directory holding the pristine contents of the original /sbin.
fn recreate_sbin(mirror: &Utf8CStr, use_bind_mount: bool) {
    let Ok(mut dir) = Directory::open(mirror).log() else {
        return;
    };
    let mut link_buf = cstr::buf::new::<4096>();

    while let Ok(Some(entry)) = dir.read() {
        let sbin_path = path_join("/sbin", entry.name().as_str());
        // Never clobber something we already created ourselves
        if sbin_path.exists() {
            continue;
        }

        if entry.is_symlink() {
            if entry.read_link(&mut link_buf).log().is_ok() {
                sbin_path.create_symlink_to(&link_buf).log_ok();
            }
            continue;
        }

        let src_path = path_join(mirror.as_str(), entry.name().as_str());
        if use_bind_mount {
            // Bind mounts require an existing target
            if entry.is_dir() {
                sbin_path.mkdir(0o755).log_ok();
            } else if let Ok(dummy) = sbin_path.create(
                nix::fcntl::OFlag::O_CREAT | nix::fcntl::OFlag::O_WRONLY,
                0o644,
            ) {
                drop(dummy);
            }
            bind_mount(&src_path, &sbin_path).log_ok();
        } else {
            sbin_path.create_symlink_to(&src_path).log_ok();
        }
    }
}

/// Mount a tmpfs over /sbin and reconstruct whatever was there before.
///
/// Ported from Delta core/deny/revert.cpp mount_sbin.
fn mount_sbin() -> LoggedResult<()> {
    let sbin = cstr!("/sbin");

    if is_rootfs() {
        // rootfs based devices: / is a ramdisk and is writable, so we can
        // temporarily move the original /sbin contents over to /root.
        remount_root(MsFlags::empty())?;

        sbin.mkdir(0o750).log_ok();
        let root = cstr!("/root");
        if root.exists() {
            root.remove_all().log_ok();
        }
        root.mkdir(0o750).log_ok();
        base::clone_attr(sbin, root).log_ok();
        sbin.link_to(root).log_ok();

        tmpfs_mount(sbin)?;
        sbin.set_secontext(ROOT_CON).log_ok();
        recreate_sbin(root, false);

        remount_root(MsFlags::MS_RDONLY)?;
    } else {
        // Legacy SAR: /sbin lives in the read-only system image. Recreate it
        // by mirroring / and bind mounting each entry.
        tmpfs_mount(sbin)?;
        sbin.set_secontext(ROOT_CON).log_ok();

        let mut mirror_root = path_join(INTERNAL_DIR, "mirror");
        mirror_root = path_join(&mirror_root, "system_root");
        mirror_root.mkdirs(0o755).log_ok();
        bind_mount(cstr!("/"), &mirror_root)?;

        let mirror_sbin = path_join(&mirror_root, "sbin");
        recreate_sbin(&mirror_sbin, true);

        mirror_root.unmount().log_ok();
    }

    Ok(())
}

fn copy_binary(src: &Utf8CStr, dst: &Utf8CStr) {
    // installDir contains symlinks into nativeLibraryDir in the normal
    // (non-stub) app flavour, so always dereference the source.
    let src = src.follow_link();
    if !src.exists() {
        return;
    }
    if src.copy_to(dst).log().is_err() {
        return;
    }
    unsafe {
        libc::chmod(dst.as_ptr(), 0o755);
    }
}

/// Configure a Magisk tmpfs at `dst` using the binaries found in `src`.
///
/// This is the System Mode replacement for magiskinit's setup_tmp() plus the
/// binary installation step of Delta's `--setup-sbin`: it mounts the tmpfs,
/// installs the binaries, creates the `.magisk` sentinel directory (which is
/// how get_magisk_tmp() detects the active Magisk tmpfs), recreates the worker
/// directory as its own tmpfs and installs the applet symlinks.
pub fn setup_sbin(src: &Utf8CStr, dst: &Utf8CStr) -> bool {
    let result = || -> LoggedResult<()> {
        if dst == "/sbin" {
            mount_sbin()?;
        } else {
            if !dst.exists() {
                dst.mkdir(0o755)?;
            }
            tmpfs_mount(dst)?;
            dst.set_secontext(ROOT_CON).log_ok();
        }

        // The magisk binary itself is the one thing the daemon will NOT copy
        // for us later, and connect_daemon() refuses to start the daemon from
        // anywhere outside the Magisk tmpfs.
        for name in ["magisk", "magisk32", "magiskpolicy", "stub.apk"] {
            let src_path = path_join(src.as_str(), name);
            let dst_path = path_join(dst.as_str(), name);
            copy_binary(&src_path, &dst_path);
        }

        let magisk_bin = path_join(dst.as_str(), "magisk");
        if !magisk_bin.exists() {
            return log_err!("No magisk binary found in {}", src);
        }

        // Relative paths below are resolved against the tmpfs root
        std::env::set_current_dir(dst.as_str()).log()?;

        cstr!(INTERNAL_DIR).mkdir(0o755)?;
        cstr!(DEVICEDIR).mkdir(0o000).log_ok();
        cstr!(WORKERDIR).mkdir(0o000).log_ok();

        // magiskinit normally prepares the worker tmpfs; System Mode has no
        // magiskinit, so module magic-mount would otherwise use a plain dir.
        tmpfs_mount(cstr!(WORKERDIR)).log_ok();
        mount(
            None::<&Utf8CStr>,
            cstr!(WORKERDIR),
            None::<&Utf8CStr>,
            MsFlags::MS_PRIVATE,
            None::<&Utf8CStr>,
        )
        .log_ok();

        // Applet symlinks
        for name in APPLET_NAMES {
            let path = path_join(dst.as_str(), name);
            path.create_symlink_to(cstr!("./magisk")).log_ok();
        }
        let supolicy = path_join(dst.as_str(), "supolicy");
        supolicy.create_symlink_to(cstr!("./magiskpolicy")).log_ok();

        std::env::set_current_dir("/").log_ok();
        Ok(())
    }();

    if result.is_err() {
        warn!("Failed to setup Magisk tmpfs at {}", dst);
        return false;
    }
    true
}

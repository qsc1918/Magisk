##################################
# Magisk System Mode installation
#
# Ported from Magisk Delta's `direct_install_system` (app/src/main/res/raw/manager.sh).
#
# System Mode installs Magisk by writing the binaries and an init rc snippet
# directly into the /system partition instead of patching the boot image, so it
# works on Android emulators, Waydroid, redroid and other containerized Android
# environments where the boot image cannot be patched.
#
# It requires an already usable root shell (adb root / existing su / uid 0 in a
# container): it persists an existing temporary root, it does not gain root by
# itself.
#
# This script is loaded by ShellInit.kt into the root shell, *after*
# app_functions.sh and util_functions.sh, so fix_env / run_migrations /
# is_rootfs / remount_check are expected to be available.
##################################

# The app shell is spawned from the Magisk APK's busybox (see ShellInit.kt),
# which on some devices runs under a binary translation layer where individual
# applets crash with SIGSEGV - `mount` being a common victim. Because this
# installer drives the system mount table directly, it must not run in that
# shell: the entry point is guarded so that it is only reachable from the
# system shell (see MAGISK_SYSTEM_MODE_LOADED below and MagiskInstaller.kt).

# Directory holding the Magisk binaries and the config file on /system
MAGISKSYSTEMDIR="/system/etc/init/magisk"

# The tmpfs that magiskd will use at runtime
MAGISKTMP_TO_INSTALL=/sbin

# Set by direct_install_system(), needed by cleanup_system_installation()
MIRRORDIR=

# Generate the init rc snippet that starts Magisk on every boot.
#
# $1 = the Magisk tmpfs path that --setup-sbin should create
magiskrc() {
  local MAGISKTMP="$1"

  # "magisk --auto-selinux" switches the process SELinux context before
  # running the real command.
  cat <<EOF
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
EOF
}

# gzip backup / restore helper for files we are about to patch in place
backup_restore() {
  # if gz is not found and orig file is found, backup to gz
  if [ ! -f "${1}.gz" ] && [ -f "$1" ]; then
    gzip -k "$1" && return 0
  elif [ -f "${1}.gz" ]; then
    # if gz found, restore from gz
    rm -rf "$1" && gzip -kdf "${1}.gz" && return 0
  fi
  return 1
}

restore_from_bak() {
  backup_restore "$1" && rm -rf "${1}.gz"
}

# Remove every trace of a previous System Mode installation
cleanup_system_installation() {
  local mirror="$MIRRORDIR"
  # MIRRORDIR is empty when called outside direct_install_system; the mirror
  # directory is just a view of the real /system, so falling back to / is fine.
  [ -d "$mirror" ] || mirror=/
  rm -rf "$mirror$MAGISKSYSTEMDIR"
  rm -rf "$mirror$MAGISKSYSTEMDIR.rc"
  backup_restore "$mirror/system/etc/init/bootanim.rc" \
    && rm -rf "$mirror/system/etc/init/bootanim.rc.gz"
  if [ -e "$mirror$MAGISKSYSTEMDIR" ] || [ -e "$mirror$MAGISKSYSTEMDIR.rc" ]; then
    return 1
  fi
}

installer_cleanup() {
  if $BOOTMODE; then
    # Unmounting the tmpfs covering /proc/$$/attr drops every mirror mount
    # created by direct_install_system in one go
    umount -l "/proc/$$/attr"
  else
    recovery_cleanup
  fi
  mount -o ro,remount /
}

# Install Magisk into /system
#
# $1 = directory holding the extracted Magisk binaries and scripts
direct_install_system() {
  print_title "Magisk (System Mode)"
  print_title "Powered by Magisk"
  api_level_arch_detect
  local INSTALLDIR="$1"

  # Report the interpreter we are running under. If this script is executed by
  # something other than the system shell, that is the first thing to check
  # when a plain mount command behaves unexpectedly.
  local self_sh
  self_sh="$(readlink /proc/$$/exe 2>/dev/null)"
  [ -z "$self_sh" ] && self_sh="$(which sh 2>/dev/null)"
  ui_print "- Shell: ${self_sh:-unknown}"

  ui_print "- Remount system partition as read-write"
  # Use kernel trick to clean up mirrors automatically when installer completed
  local ROOTDIR SYSTEMDIR VENDORDIR ODM_DIR
  MIRRORDIR="/proc/$$/attr"

  ROOTDIR="$MIRRORDIR/system_root"
  SYSTEMDIR="$MIRRORDIR/system"
  VENDORDIR="$MIRRORDIR/vendor"
  ODM_DIR="$MIRRORDIR/odm"

  if $BOOTMODE; then
    umount -l "$MIRRORDIR"
    # setup mirrors to get the original content
    mount -t tmpfs -o 'mode=0755' tmpfs "$MIRRORDIR" || return 1
    if is_rootfs; then
      ROOTDIR=/
      force_bind_mount "/" "$ROOTDIR" || return 1
      mkdir "$SYSTEMDIR"
      force_bind_mount "/system" "$SYSTEMDIR" || return 1
    else
      mkdir "$ROOTDIR"
      force_bind_mount "/" "$ROOTDIR" || return 1
      if mountpoint -q /system; then
        mkdir "$SYSTEMDIR"
        force_bind_mount "/system" "$SYSTEMDIR" || return 1
      else
        ln -fs ./system_root/system "$SYSTEMDIR"
      fi
    fi

    # we are modifying system directly so we need to create /sbin if it does not exist
    if [ ! -d "$ROOTDIR"/sbin ]; then
      rm -rf "$ROOTDIR"/sbin
      mkdir "$ROOTDIR"/sbin
      if [ ! -d "$ROOTDIR"/sbin ]; then
        ui_print "! Can't create tmpfs path /sbin"
        return 1
      fi
    fi

    # check if /vendor is separated fs
    if mountpoint -q /vendor; then
      mkdir "$VENDORDIR"
      force_bind_mount "/vendor" "$VENDORDIR" || return 1
    else
      ln -fs ./system/vendor "$VENDORDIR"
    fi

    # check if /odm is separated fs
    if mountpoint -q /odm; then
      mkdir "$ODM_DIR"
      force_bind_mount "/odm" "$ODM_DIR" || return 1
    else
      ln -fs ./system_root/odm "$ODM_DIR"
    fi
  else
    MIRRORDIR="/"
    ROOTDIR="$MIRRORDIR/system_root"
    SYSTEMDIR="$MIRRORDIR/system"
    VENDORDIR="$MIRRORDIR/vendor"
    ODM_DIR="$MIRRORDIR/odm"
    ui_print "- Mount system partitions as read-write..."
    remount_check rw "$ROOTDIR" 0 || { warn_system_ro; return 1; }
    remount_check rw "$SYSTEMDIR" 0 || { warn_system_ro; return 1; }
    remount_check rw "$VENDORDIR" 0 || { warn_system_ro; return 1; }
    remount_check rw "$ODM_DIR" 0 || { warn_system_ro; return 1; }

    # we are modifying system directly so we need to create /sbin if it does not exist
    if [ -d "$ROOTDIR" ] && [ ! -d "$ROOTDIR"/sbin ]; then
      rm -rf "$ROOTDIR"/sbin
      mkdir "$ROOTDIR"/sbin
      if [ ! -d "$ROOTDIR"/sbin ]; then
        ui_print "! Can't create tmpfs path /sbin"
        return 1
      fi
    fi
  fi

  ui_print "- Cleaning up environment..."
  {
    local checkfile="$MIRRORDIR/system/.check_$(random_str 10 20)"
    # test write, need at least 20mb
    dd if=/dev/zero of="$checkfile" bs=1024 count=20000 2>/dev/null || \
      { rm -rf "$checkfile"; ui_print "! Insufficient free space or system write protection"; return 1; }
    rm -rf "$checkfile"
  }
  cleanup_system_installation || return 1

  ui_print "- Copy files to system partition"
  mkdir -p "$MIRRORDIR$MAGISKSYSTEMDIR" || return 1
  # The official Magisk release only ever produces "magisk" (chosen per ABI);
  # "magisk32" is an extra copy extracted from the 32-bit ABI and is absent on
  # 32-bit only devices. magiskinit is needed here for its offline sepolicy
  # patch (--patch-sepol), which must survive reboots and OTA updates.
  for magisk in magisk magisk32 magiskpolicy magiskinit stub.apk; do
    [ -f "$INSTALLDIR/$magisk" ] || continue
    cat "$INSTALLDIR/$magisk" >"$MIRRORDIR$MAGISKSYSTEMDIR/$magisk" || \
      { ui_print "! Unable to write Magisk binaries to system"; return 1; }
  done
  echo -e "SYSTEMMODE=true\nRECOVERYMODE=false" >"$MIRRORDIR$MAGISKSYSTEMDIR/config"
  chcon -R u:object_r:system_file:s0 "$MIRRORDIR$MAGISKSYSTEMDIR"
  chmod -R 700 "$MIRRORDIR$MAGISKSYSTEMDIR"

  if [ "$API" -gt 24 ]; then
    {
      if $BOOTMODE; then
        ui_print "- Check if kernel supports dynamic SELinux Policy patch"
        if [ -d /sys/fs/selinux ] && ! "$INSTALLDIR/magiskpolicy" --live "permissive su" &>/dev/null; then
          ui_print "! Kernel does not support dynamic SELinux Policy patch"
          return 1
        fi
      else
        ui_print "W: It's impossible to check kernel compatibility in recovery mode"
        ui_print "W: Please make sure your kernel can dynamic patch SELinux Policy"
      fi
      if ! is_rootfs; then
        {
          ui_print "- Patch sepolicy file"
          local sepol file
          for file in /vendor/etc/selinux/precompiled_sepolicy /odm/etc/selinux/precompiled_sepolicy /system/etc/selinux/precompiled_sepolicy /system_root/sepolicy /system_root/sepolicy_debug /system_root/sepolicy.unlocked; do
            if [ -f "$MIRRORDIR$file" ]; then
              sepol="$file"
              break
            fi
          done
          if [ -z "$sepol" ]; then
            ui_print "! Cannot find sepolicy file"
            return 1
          else
            ui_print "- Target sepolicy is $sepol"
            backup_restore "$MIRRORDIR$sepol" || { ui_print "! Backup failed"; return 1; }
            # copy file to cache
            cp -af "$MIRRORDIR$sepol" "$INSTALLDIR/sepol.in"
            # magiskinit --patch-sepol IN OUT == load + magisk_rules + dump.
            # magiskinit is deployed to $MAGISKSYSTEMDIR as well, so this also
            # works after an OTA when only /system survives.
            local patchbin="$INSTALLDIR/magiskinit"
            [ -f "$patchbin" ] || patchbin="$MAGISKSYSTEMDIR/magiskinit"
            if ! "$patchbin" --patch-sepol "$INSTALLDIR/sepol.in" "$INSTALLDIR/sepol.out" \
              || ! cp -af "$INSTALLDIR/sepol.out" "$MIRRORDIR$sepol"; then
              ui_print "! Unable to patch sepolicy file"
              restore_from_bak "$MIRRORDIR$sepol"
              return 1
            fi
            ui_print "- Patching sepolicy file success!"
          fi
        }
      fi
    }
    ui_print "- Add init boot script"
    {
      local hijackrc="$MIRRORDIR/system/etc/init/magisk.rc"
      if [ -f "$MIRRORDIR/system/etc/init/bootanim.rc" ]; then
        backup_restore "$MIRRORDIR/system/etc/init/bootanim.rc" && hijackrc="$MIRRORDIR/system/etc/init/bootanim.rc"
      fi
    }
    echo "$(magiskrc "$MAGISKTMP_TO_INSTALL")" >>"$hijackrc" || return 1
  fi

  ui_print "[*] Reflash your ROM if your ROM is unable to start"
  ui_print "    and do not use this method to install Magisk"

  $BOOTMODE && installer_cleanup
  return 0
}

# Install the addon.d survival script for System Mode
#
# $1 = path to the Magisk APK
#
# NOTE: this must run *after* fix_env, because it copies from $MAGISKBIN
# (/data/adb/magisk), and fix_env is what populates it.
install_addond_system() {
  local AppApkPath="$1"
  local addond=/system/addon.d
  [ -d "$addond" ] || return 0

  local mirror="$MIRRORDIR"
  if [ ! -d "$mirror" ]; then
    # direct_install_system has already torn its mirror down via
    # installer_cleanup, so build a fresh one for this write.
    mirror="/proc/$$/attr"
    umount -l "$mirror" 2>/dev/null
    mount -t tmpfs -o 'mode=0755' tmpfs "$mirror" || mirror=/
  fi

  ui_print "- Adding addon.d survival script"
  local BLOCKNAME="/dev/block/system_block.$(random_str 5 20)"
  rm -rf "$BLOCKNAME"
  if is_rootfs; then
    mkblknode "$BLOCKNAME" /system
  else
    mkblknode "$BLOCKNAME" /
  fi
  blockdev --setrw "$BLOCKNAME" 2>/dev/null
  rm -rf "$BLOCKNAME"
  mount -o rw,remount / 2>/dev/null
  mount -o rw,remount /system 2>/dev/null

  rm -rf "$mirror$addond/99-magisk.sh"
  rm -rf "$mirror$addond/magisk"
  if ! cp -prLf "$MAGISKBIN"/. "$mirror$MAGISKSYSTEMDIR"; then
    if [ "$mirror" != "/" ]; then
      # Some devices cannot make the mirrored /system writable; the live
      # /system is already read-write by now (it was remounted above), so
      # retry without the mirror instead of dropping OTA survival.
      ui_print "- Retrying addon.d install without mirror"
      mirror=/
      cp -prLf "$MAGISKBIN"/. "$mirror$MAGISKSYSTEMDIR" || { ui_print "! Failed to install addon.d"; return 1; }
    else
      ui_print "! Failed to install addon.d"
      return 1
    fi
  fi
  mv "$MAGISKBIN/addon.d.sh" "$mirror$addond/99-magisk.sh"
  cp "$AppApkPath" "$mirror$MAGISKSYSTEMDIR/magisk.apk"
  chmod 0755 "$mirror$MAGISKSYSTEMDIR"/*
  sed -i "s/^SYSTEMINSTALL=.*/SYSTEMINSTALL=true/g" "$mirror$addond/99-magisk.sh"

  [ "$mirror" = "/proc/$$/attr" ] && umount -l "$mirror" 2>/dev/null
  mount -o ro,remount / 2>/dev/null
  mount -o ro,remount /system 2>/dev/null
  return 0
}

# $1 = install dir, $2 = unused (kept for interface compatibility), $3 = APK
xdirect_install_system() {
  # Guarded entry point: running the system mount operations from the app's
  # busybox shell segfaults on some devices (see the file header). Only the
  # system shell may proceed.
  local self_sh
  self_sh="$(readlink /proc/$$/exe 2>/dev/null)"
  [ -z "$self_sh" ] && self_sh="unknown"
  if [ "$MAGISK_SYSTEM_MODE_LOADED" != "1" ]; then
    ui_print "! System Mode was not entered from the system shell"
    ui_print "! reason: current shell is $self_sh"
    ui_print "! Install it from the Magisk app's install screen"
    return 1
  fi
  direct_install_system "$@" || { cleanup_system_installation; installer_cleanup; return 1; }
  # fix_env must run before install_addond_system: it moves the install dir
  # into /data/adb/magisk, which is where the addon.d files are taken from.
  fix_env "$1"
  install_addond_system "$3"
  run_migrations
  return 0
}

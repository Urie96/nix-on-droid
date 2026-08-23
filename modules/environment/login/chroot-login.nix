# Chroot login for nix-on-droid.
#
# Replaces proot with a real chroot (kernel-native syscalls, no ptrace
# interception), while keeping the nix-on-droid app uid by default.
#
# Flow on login (build.container.mode = "chroot"):
#   login runs root_login.sh directly (no prompt, no proot fallback): it
#   sets up the chroot (bind mounts) and always drops back to the app uid
#   via drop_root.sh. If the app is not running, it falls back to a root
#   session inside the chroot.
#
# For root, use `sudo <cmd>` (wrapper around /system/bin/su) or plain `su`.
# After root operations on the nix store, run `sweep-store` to fix ownership.
#
# Based on https://gist.github.com/Yeshey/7bbd1116133b91b1f9406982bdf7fbcc
# and https://github.com/Yeshey/nixOS-Config (modules/hosts/nix-on-droid/root-droid.nix)

{ config, lib, pkgs, ... }:

let
  installationDir = config.build.installationDir;

  # App data dir (grandparent of the installation dir), e.g.
  # /data/data/com.termux.nix for installationDir=/data/data/com.termux.nix/files/usr.
  dataDir = lib.dirOf (lib.dirOf installationDir);

  chrootPath = "${dataDir}/files/chroot";

  cfg = config.build.container;

  # `sudo` wrapper: run a single command as root INSIDE the nix-on-droid
  # chroot. A bare Magisk su -c lands in the host Android root environment,
  # where the nix store (/nix) is not mounted, so nix profile binaries
  # (yazi, vim, htop, ...) cannot be executed there (their store symlinks
  # dangle and the ELF interpreter is missing: "inaccessible or not found").
  # Re-enter the chroot instead: the bind mounts were already set up by
  # root_login.sh, so /nix, /usr, /data etc. resolve inside the chroot.
  # Magisk installs `su` at a device-dependent path
  # (/system/bin, /product/bin, /system/xbin, /sbin, ...), so probe for it.
  # Use `-i` (allocate pty) when attached to a terminal so interactive
  # root tools (yazi, vim, htop, ...) get job control and a proper size.
  # TERM/COLORTERM are passed through explicitly because su -c does not
  # preserve the caller environment.
  fake-sudo-pkg = pkgs.writeScriptBin "sudo" ''
    #!/system/bin/sh
    # Prefer known Magisk locations over PATH lookup: inside the nix env,
    # `command -v su` could match util-linux's su instead.
    SU=
    for p in /system/bin/su /product/bin/su /system/xbin/su /sbin/su; do
      if [ -x "$p" ]; then SU="$p"; break; fi
    done
    if [ -z "$SU" ]; then
      SU=$(command -v su 2>/dev/null || true)
    fi
    if [ -z "$SU" ]; then
      SU=/system/bin/su
    fi
    CHROOT_PATH=${chrootPath}
    ROOT_ENV="/usr/bin/env HOME=/root USER=root TERM=$TERM COLORTERM=$COLORTERM PATH=${config.user.home}/.nix-profile/bin:${config.user.home}/.local/state/nix/profile/bin:/nix/var/nix/profiles/per-user/${config.user.userName}/bin:/usr/bin:/bin:/system/bin"
    if [ -t 0 ]; then
      exec "$SU" -i -c "/system/bin/chroot $CHROOT_PATH $ROOT_ENV /bin/sh -c \"$*\""
    else
      exec "$SU" -c "/system/bin/chroot $CHROOT_PATH $ROOT_ENV /bin/sh -c \"$*\""
    fi
  '';

  # Fix nix store ownership after root operations.
  sweep-store-pkg = pkgs.writeScriptBin "sweep-store" ''
    #!/system/bin/sh
    NOD_UID=$(/system/bin/stat -c %u ${dataDir})
    NOD_GID=$(/system/bin/stat -c %g ${dataDir})
    echo "Sweeping nix store ownership, this will take a while..."
    /system/bin/find ${installationDir}/nix/store \
      -maxdepth 1 -user root \
      -exec /system/bin/chown -R "$NOD_UID:$NOD_GID" {} \;
    echo "Done."
  '';

  # Drop from root to the nix-on-droid app uid inside the chroot.
  # `su -i` (in login) already provides a proper session + controlling
  # terminal on su's own pty, so job control works here without extra work.
  # `su -i` starts us at /, so cd to $HOME so the shell lands in the
  # nix-on-droid home directory.
  drop-root = pkgs.writeScript "drop_root.sh" ''
    #!/system/bin/sh

    uid=$(/system/bin/stat -c %u ${dataDir})

    # chown the session pty to the app uid, otherwise the nix-on-droid user
    # cannot open its own terminal (pinentry/rbw report "pinentry cancelled")
    _tty=$(/system/bin/tty 2>/dev/null || true)
    if [ -n "$_tty" ] && [ -c "$_tty" ]; then
      /system/bin/chown "$uid:$uid" "$_tty" 2>/dev/null || true
    fi

    cd "$HOME" 2>/dev/null || cd /
    exec ${pkgs.util-linux}/bin/setpriv \
      --reuid $uid --regid $uid \
      --groups 3003,3004,2000,9997,20166,50166 \
      --bounding-set -all \
      -- /system/bin/sh -c 'exec sh /usr/lib/login-inner "$@"' sh "$@" \
      || exec sh /usr/lib/login-inner "$@"
  '';

  # Chroot setup: bind-mount everything, then drop to the app uid.
  root-login = pkgs.writeScript "root_login.sh" ''
    #!/system/bin/sh

    set -eu -o pipefail

    export USER="root"
    export HOME="/root"
    export PROOT_TMP_DIR=${installationDir}/tmp
    export PROOT_L2S_DIR=${installationDir}/.l2s
    export PATH=$PATH:/system/bin/
    export TMPDIR=${installationDir}/tmp

    FILES_USR=${installationDir}

    mkdir -p $FILES_USR/root

    if ! /system/bin/pgrep proot-static > /dev/null; then
      if test -e ${installationDir}/bin/.proot-static.new; then
        echo "Installing new proot-static..."
        /system/bin/mv ${installationDir}/bin/.proot-static.new \
          ${installationDir}/bin/proot-static
      fi
      if test -e ${installationDir}/usr/lib/.login-inner.new; then
        echo "Installing new login-inner..."
        /system/bin/mv ${installationDir}/usr/lib/.login-inner.new \
          ${installationDir}/usr/lib/login-inner
      fi
    fi

    CHROOT_PATH=${chrootPath}
    mkdir -p $CHROOT_PATH
    NOD_DIRS="nix bin etc tmp usr dev/shm"

    # Clean up nested copies of the chroot bind mounts left behind by older
    # logins that rbind-mounted /data (which contains the chroot dir itself)
    # into the chroot. Only the top-level mounts are used by running
    # processes (e.g. sshd); the nested copies are unreachable garbage.
    # Lazy-unmount them in batches. Failures are expected (aliased paths)
    # and must NOT abort this script (set -e + pipefail), hence `|| true`.
    /system/bin/awk \
      -v p="$CHROOT_PATH${dataDir}/files/chroot/" \
      'index($2, p) == 1 { print $2 }' /proc/self/mounts \
      | xargs -r -n 100 /system/bin/umount -l 2>/dev/null || true

    /system/bin/mount --make-rslave / 2>/dev/null || true

    # Skip bind mounts that are already mounted (left over from a previous
    # session): re-mounting would stack another instance on top of the old
    # one and grow the mount table on every login. The bound directories are
    # real dirs whose contents are updated in place (store symlinks), so a
    # mount from an earlier session stays correct.
    is_mounted() {
      /system/bin/grep -q " $1 " /proc/self/mounts
    }

    for DIR in /*/; do
      mkdir -p $CHROOT_PATH/$DIR
      for DIR2 in $NOD_DIRS; do
        if test "$DIR" = "/$DIR2/"; then continue 2; fi
      done
      is_mounted "$CHROOT_PATH/$DIR" && continue
      if test "$DIR" = "/data/"; then
        # /data contains the chroot dir itself; a recursive bind would copy
        # the chroot's own mounts into itself on every login (exponential
        # nesting). A plain bind is enough, /data has no useful submounts.
        /system/bin/mount --bind $DIR $CHROOT_PATH/$DIR 2>/dev/null || true
      else
        /system/bin/mount --rbind $DIR $CHROOT_PATH/$DIR 2>/dev/null || true
      fi
    done

    for DIR in $NOD_DIRS; do
      mkdir -p $CHROOT_PATH/$DIR
      if ! is_mounted "$CHROOT_PATH/$DIR"; then
        /system/bin/mount --rbind $FILES_USR/$DIR $CHROOT_PATH/$DIR || true
      fi
    done

    # Bind root home (used by the root fallback)
    mkdir -p $CHROOT_PATH/root
    if ! is_mounted "$CHROOT_PATH/root"; then
      /system/bin/mount --rbind $FILES_USR/root $CHROOT_PATH/root
    fi

    # Always drop to the app uid; fall back to a root session only if the
    # app is not running (drop_root.sh would fail then).
    if ! /system/bin/pgrep com.termux.nix > /dev/null 2>&1; then
      echo "Nix-on-Droid app not running, keeping root as fallback"
      exec /system/bin/chroot $CHROOT_PATH \
        /usr/bin/env HOME=/root USER=root \
        sh -c 'cd "$HOME" && exec sh /usr/lib/login-inner "$@"' sh "$@"
    fi
    exec /system/bin/chroot $CHROOT_PATH \
      /usr/bin/env HOME=${config.user.home} USER=${config.user.userName} \
      sh ${installationDir}/usr/lib/drop_root.sh "$@"
  '';

  # Login script: enter the chroot directly (no prompt, no proot fallback).
  login = pkgs.writeScript "login" ''
    #!/system/bin/sh
    set -eu -o pipefail

    export USER="${config.user.userName}"
    export HOME="${config.user.home}"
    export PROOT_TMP_DIR=${installationDir}/tmp
    export PROOT_L2S_DIR=${installationDir}/.l2s
    export PATH=$PATH:/system/bin/

    if test "$(/system/bin/whoami)" != root; then
      # Locate Magisk su (device-dependent path)
      SU=
      for p in /system/bin/su /product/bin/su /system/xbin/su /sbin/su; do
        if [ -x "$p" ]; then SU="$p"; break; fi
      done
      if [ -z "$SU" ]; then
        SU=$(command -v su 2>/dev/null || true)
      fi
      if [ -z "$SU" ]; then
        SU=/system/bin/su
      fi
      # `-i` makes su allocate its own pty and hand over the session /
      # controlling terminal / foreground pgrp, so the chroot shell gets
      # job control (plain `su -c` always setsids and breaks it).
      if "$SU" -i -c "${installationDir}/usr/lib/root_login.sh"; then
        exit 0
      fi
      echo "chroot login failed: root/su unavailable." >&2
      echo "Set build.container.mode = \"proot\" to use the proot fallback." >&2
      exit 1
    fi

    # Already root: enter the chroot directly.
    exec "${installationDir}/usr/lib/root_login.sh" "$@"
  '';
in
{
  # Naming follows upstream nix-on-droid PR #538 ("Add chroot container
  # mode alongside proot"): build.container.mode = "proot" | "chroot".
  options.build.container.mode = lib.mkOption {
    type = lib.types.enum [ "proot" "chroot" ];
    default = "proot";
    description = ''
      Container mode used for the login session. `proot` (default) needs no
      root and no kernel namespaces. `chroot` uses a kernel-native chroot
      (native syscalls, no ptrace interception) on rooted devices; it
      requires root and has no proot fallback (login fails if root/su is
      unavailable).
    '';
  };

  config = lib.mkIf (cfg.mode == "chroot") {
    # Replace the default proot login script. The default `installLogin`
    # activation installs `environment.files.login` to /bin/login, so the
    # chroot login is picked up there automatically.
    environment.files.login = lib.mkForce login;

    # root_login.sh / drop_root.sh live next to login-inner in
    # ${installationDir}/usr/lib (stable path, out of the home dir)
    build.activationAfter.install-chroot-lib = ''
      mkdir -p ${installationDir}/usr/lib
      cp ${root-login} ${installationDir}/usr/lib/root_login.sh
      chmod 755 ${installationDir}/usr/lib/root_login.sh
      cp ${drop-root} ${installationDir}/usr/lib/drop_root.sh
      chmod 755 ${installationDir}/usr/lib/drop_root.sh
      # clean up the old location in the home dir
      rm -f ${config.user.home}/root_login.sh ${config.user.home}/drop_root.sh
    '';

    environment.motd = lib.mkAfter ''
      chroot login enabled (native syscall speed, no proot fallback).
      Root: use 'sudo <cmd>' or 'su'. If the nix store has permission
      errors after root operations, run 'sweep-store' to fix ownership.
    '';

    environment.packages = [ pkgs.util-linux fake-sudo-pkg sweep-store-pkg ];
  };
}

# nix-ld for the nix-on-droid chroot container (build.container.mode =
# "chroot"). Mirrors the NixOS programs.nix-ld module.
#
# Unpatched dynamic ELF binaries (e.g. downloaded node/deno tarballs) have
# their interpreter hardcoded at build time, e.g. /lib/ld-linux-aarch64.so.1.
# The kernel resolves that path relative to the chroot root, so the chroot
# must provide it: this module symlinks the nix-ld loader into the
# installation dir, which chroot-login.nix binds as the chroot's /lib (or
# /lib64) instead of the read-only host dir (see NOD_DIRS there).

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.nix-ld;

  installationDir = config.build.installationDir;

  # Merged library directory, same layout as NixOS's nix-ld module:
  # $out/share/nix-ld/lib contains every library's lib/ plus a symlink to
  # the real glibc loader (ld.so).
  nixLdLibraries = pkgs.buildEnv {
    name = "nix-ld-libraries";
    pathsToLink = [ "/lib" ];
    paths = map lib.getLib cfg.libraries;
    postBuild = ''
      ln -s ${pkgs.stdenv.cc.bintools.dynamicLinker} $out/share/nix-ld/lib/ld.so
    '';
    extraPrefix = "/share/nix-ld";
    ignoreCollisions = true;
  };

  # Same computation as the nix-ld package's lib/tmpfiles.d/nix-ld.conf:
  # interpreter lives in /lib on aarch64, /lib64 on x86_64.
  nixLdInterp = "/${pkgs.stdenv.hostPlatform.libDir}/${builtins.baseNameOf pkgs.stdenv.cc.bintools.dynamicLinker}";
in
{
  options.programs.nix-ld = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Provide nix-ld in the chroot so unpatched dynamic ELF binaries
        (whose interpreter is hardcoded at build time, e.g.
        /lib/ld-linux-aarch64.so.1) can run. See
        <https://github.com/nix-community/nix-ld>.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nix-ld;
      description = "nix-ld package used as the ELF interpreter shim.";
    };

    libraries = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = ''
        Libraries automatically available to nix-ld programs via
        NIX_LD_LIBRARY_PATH. A plain `libraries = [ ... ]` extends the
        base set defined in this module's config (listOf options
        concatenate definitions), so the default libraries are kept.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && config.build.container.mode == "chroot") {
    # Bind the chroot's /lib (aarch64) or /lib64 (x86_64) from the
    # installation dir instead of the read-only host dir, so the
    # interpreter symlink below is visible inside the chroot.
    build.container.nodDirs = [ pkgs.stdenv.hostPlatform.libDir ];

    # Base library set, defined in config instead of as the option
    # default: multiple listOf definitions are concatenated, so a user's
    # `programs.nix-ld.libraries = [ ... ]` extends this set
    # instead of replacing it. Mirrors NixOS programs.nix-ld (minus
    # systemd, which does not exist here) plus glibc.
    programs.nix-ld.libraries = with pkgs; [
      glibc
      zlib
      zstd
      stdenv.cc.cc
      curl
      openssl
      attr
      libssh
      bzip2
      libxml2
      acl
      libsodium
      util-linux
      xz
    ];

    # The symlink lives in the installation dir, which chroot-login.nix
    # binds as the chroot's /lib (or /lib64) when nix-ld is enabled.
    # `ln -sfn` keeps the switch idempotent.
    build.activationAfter.install-nix-ld = ''
      mkdir -p ${installationDir}/lib ${installationDir}/lib64
      ln -sfn ${cfg.package}/bin/nix-ld ${installationDir}${nixLdInterp}
    '';

    # nix-ld's own defaults point at NixOS-only paths
    # (/run/current-system/sw/share/nix-ld/...), so set NIX_LD (the real
    # glibc loader, symlinked into the merged library dir) and
    # NIX_LD_LIBRARY_PATH explicitly.
    environment.sessionVariables = {
      NIX_LD = "${nixLdLibraries}/share/nix-ld/lib/ld.so";
      NIX_LD_LIBRARY_PATH = "${nixLdLibraries}/share/nix-ld/lib";
    };
  };
}

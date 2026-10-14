# Copyright (c) 2019-2026, see AUTHORS. Licensed under MIT License, see LICENSE.

{ config, lib, pkgs, initialPackageInfo, targetSystem, ... }:

with lib;

let
  cfg = config.environment.files;

  login = pkgs.callPackage ./login.nix { inherit config; };

  loginInner = pkgs.callPackage ./login-inner.nix {
    inherit config initialPackageInfo targetSystem;
  };
in

{

  ###### interface

  options = {

    environment.files = {
      login = mkOption {
        type = types.package;
        internal = true;
        description = ''
          Login script. Can be overridden (e.g. by
          <option>build.container.mode</option> set to
          <literal>"chroot"</literal>) to replace the default proot-based
          login.
        '';
      };

      loginInner = mkOption {
        type = types.package;
        readOnly = true;
        internal = true;
        description = "Login-inner script.";
      };

      prootStatic = mkOption {
        type = types.nullOr types.package;
        default = null;
        internal = true;
        description = ''
          <literal>proot-static</literal> package. Only needed when
          <option>build.container.mode</option> is <literal>"proot"</literal>;
          leave unset (the default) for chroot mode.
        '';
      };
    };

  };


  ###### implementation

  config = {

    build.activation = {
      installLogin = ''
        if ! diff /bin/login ${config.environment.files.login} > /dev/null; then
          $DRY_RUN_CMD mkdir $VERBOSE_ARG --parents /bin
          $DRY_RUN_CMD cp $VERBOSE_ARG ${config.environment.files.login} /bin/.login.tmp
          $DRY_RUN_CMD chmod $VERBOSE_ARG u+w /bin/.login.tmp
          $DRY_RUN_CMD mv $VERBOSE_ARG /bin/.login.tmp /bin/login
        fi
      '';

      installLoginInner = ''
        if (test -e /usr/lib/.login-inner.new && ! diff /usr/lib/.login-inner.new ${loginInner} > /dev/null) || \
            (! test -e /usr/lib/.login-inner.new && ! diff /usr/lib/login-inner ${loginInner} > /dev/null); then
          $DRY_RUN_CMD mkdir $VERBOSE_ARG --parents /usr/lib
          $DRY_RUN_CMD cp $VERBOSE_ARG ${loginInner} /usr/lib/.login-inner.tmp
          $DRY_RUN_CMD chmod $VERBOSE_ARG u+w /usr/lib/.login-inner.tmp
          $DRY_RUN_CMD mv $VERBOSE_ARG /usr/lib/.login-inner.tmp /usr/lib/.login-inner.new
        fi
      '';
    } // lib.optionalAttrs (cfg.prootStatic != null) {
      installProotStatic = ''
        if (test -e /bin/.proot-static.new && ! diff /bin/.proot-static.new ${cfg.prootStatic}/bin/proot-static > /dev/null) || \
            (! test -e /bin/.proot-static.new && ! diff /bin/proot-static ${cfg.prootStatic}/bin/proot-static > /dev/null); then
          $DRY_RUN_CMD mkdir $VERBOSE_ARG --parents /bin
          $DRY_RUN_CMD cp $VERBOSE_ARG ${cfg.prootStatic}/bin/proot-static /bin/.proot-static.tmp
          $DRY_RUN_CMD chmod $VERBOSE_ARG u+w /bin/.proot-static.tmp
          $DRY_RUN_CMD mv $VERBOSE_ARG /bin/.proot-static.tmp /bin/.proot-static.new
        fi
      '';
    };

    environment.files = {
      inherit login loginInner;
    };

  };

}

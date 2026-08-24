# Copyright (c) 2019-2022, see AUTHORS. Licensed under MIT License, see LICENSE.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.environment;

  # dix (Diff Nix) is used after installation to show which packages changed
  # in this update. It is optional: older nixpkgs do not provide it, in which
  # case the diff is simply skipped.
  dix = pkgs.dix or null;
in

{

  ###### interface

  options = {

    environment = {
      packages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = "List of packages to be installed as user packages.";
      };

      path = mkOption {
        type = types.package;
        readOnly = true;
        internal = true;
        description = "Derivation for installing user packages.";
      };

      extraOutputsToInstall = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "doc" "info" "devdoc" ];
        description = "List of additional package outputs to be installed as user packages.";
      };
    };

  };


  ###### implementation

  config = {

    build.activation.installPackages = ''
      # Make sure ~/.nix-profile resolves to the standard user profile so
      # the manifest.json guard below works even if the symlink was lost.
      $DRY_RUN_CMD ln -sfn "${config.user.home}/.local/state/nix/profiles/profile" "${config.user.home}/.nix-profile"
      if [[ -e "${config.user.home}/.nix-profile/manifest.json" ]]; then
        # manual removal and installation as two non-atomical steps is required
        # because of https://github.com/NixOS/nix/issues/6349

        nix_previous="$(command -v nix)"

        ${optionalString (dix != null) ''
          # Store path of the currently installed nix-on-droid-path element,
          # so that dix can diff it against the new one after the install.
          nix_on_droid_path_old="$(
            "$nix_previous" profile list --json \
              | ${pkgs.jq}/bin/jq -r '.elements["nix-on-droid-path"].storePaths[0]'
          )"
        ''}

        # Remove any stale element by name (no-op if absent). The old
        # grep/cut parsing of `nix profile list` broke with nix >= 2.18,
        # whose output is multi-line ("Name: ..." / "Store paths: ...").
        $DRY_RUN_CMD nix profile remove nix-on-droid-path || true

        $DRY_RUN_CMD $nix_previous profile install ${cfg.path}

        unset nix_previous
      else
        ${optionalString (dix != null) ''
          # Store path of the currently installed nix-on-droid-path
          # environment, for the dix diff below.
          nix_on_droid_path_old="$(
            nix-env -q --out-path nix-on-droid-path \
              | sed -n 's/^[^ ]* \(.*\)$/\1/p'
          )"
        ''}

        $DRY_RUN_CMD nix-env --install ${cfg.path}
      fi

      ${optionalString (dix != null) ''
        # Show which packages changed in this update with dix.
        if [[ -n "$nix_on_droid_path_old" && "$nix_on_droid_path_old" != "${cfg.path}" ]]; then
          echo "Package changes in this update:"
          $DRY_RUN_CMD ${dix}/bin/dix "$nix_on_droid_path_old" "${cfg.path}" || true
        fi
      ''}
    '';

    environment = {
      packages = [
        (pkgs.callPackage ../../nix-on-droid { nix = config.nix.package; })
        pkgs.bashInteractive
        pkgs.cacert
        pkgs.coreutils
        pkgs.less # since nix tools really want a pager available, #27
        config.nix.package
      ];

      path = pkgs.buildEnv {
        name = "nix-on-droid-path";

        paths = cfg.packages;

        inherit (cfg) extraOutputsToInstall;

        meta = {
          description = "Environment of packages installed through Nix-on-Droid.";
        };
      };
    };

  };

}

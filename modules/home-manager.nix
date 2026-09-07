# Copyright (c) 2019-2022, see AUTHORS. Licensed under MIT License, see LICENSE.

{ config, lib, pkgs, home-manager-path, ... }:

with lib;

let
  cfg = config.home-manager;

  extendedLib = import (home-manager-path + "/modules/lib/stdlib-extended.nix") lib;

  hmModule = types.submoduleWith {
    specialArgs = { lib = extendedLib; } // cfg.extraSpecialArgs;
    modules = [
      ({ name, ... }: {
        imports = import (home-manager-path + "/modules/modules.nix") {
          inherit pkgs;
          lib = extendedLib;
          useNixpkgsModule = !cfg.useGlobalPkgs;
        };

        config = {
          submoduleSupport.enable = true;
          submoduleSupport.externalPackageInstall = cfg.useUserPackages;

          home.username = config.user.userName;
          home.homeDirectory = config.user.home;
        };
      })
    ] ++ cfg.sharedModules;
  };
in

{

  ###### interface

  options = {

    home-manager = {
      backupFileExtension = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "backup";
        description = ''
          On activation move existing files by appending the given
          file extension rather than exiting with an error.
        '';
      };

      config = mkOption {
        type = types.nullOr hmModule;
        default = null;
        # Prevent the entire submodule being included in the documentation.
        visible = "shallow";
        description = ''
          Home Manager configuration, see
          <link xlink:href="https://nix-community.github.io/home-manager/options.html" />.
        '';
      };

      extraSpecialArgs = mkOption {
        type = types.attrs;
        default = { };
        example = literalExpression "{ inherit emacs-overlay; }";
        description = ''
          Extra <literal>specialArgs</literal> passed to Home Manager. This
          option can be used to pass additional arguments to all modules.
        '';
      };

      sharedModules = mkOption {
        type = with types; listOf raw;
        default = [ ];
        example = literalExpression "[ { home.packages = [ nixpkgs-fmt ]; } ]";
        description = ''
          Extra modules.
        '';
      };

      useGlobalPkgs = mkEnableOption ''
        using the system configuration's <literal>pkgs</literal>
        argument in Home Manager. This disables the Home Manager
        options <option>nixpkgs.*</option>
      '';

      useUserPackages = mkEnableOption ''
        installation of user packages through the
        <option>environment.packages</option> option.
      '' // {
        default = versionAtLeast config.system.stateVersion "20.09";
      };
    };

  };


  ###### implementation

  config = mkIf (cfg.config != null) {

    inherit (cfg.config) assertions warnings;

    # No `activationBefore` step is needed anymore: the old
    # setPriorityHomeManagerPath hack (raising the priority of a stale
    # `home-manager-path` element in the user profile) is obsolete since
    # Home Manager no longer installs `home-manager-path` into the user
    # profile when run as a submodule with `useUserPackages` (a.k.a.
    # `externalPackageInstall`); it removes leftover elements itself.
    # Keeping it around also broke activations for profiles managed by
    # `nix profile`, since `nix-env` refuses to touch those.

    build = {
      activationAfter.homeManager = concatStringsSep " " (
        optional
          (cfg.backupFileExtension != null)
          "HOME_MANAGER_BACKUP_EXT='${cfg.backupFileExtension}'"
        ++ [ "${cfg.config.home.activationPackage}/activate" ]
      );
    };

    environment.packages = mkIf cfg.useUserPackages cfg.config.home.packages;

    # home-manager has a quirk redefining the profile location
    # to "/etc/profiles/per-user/${cfg.username}" if useUserPackages is on.
    # https://github.com/nix-community/home-manager/blob/0006da1381b87844c944fe8b925ec864ccf19348/modules/home-environment.nix#L414
    # Fortunately, it's not that hard to us to workaround with just a symlink.
    environment.etc = mkIf cfg.useUserPackages {
      "profiles/per-user/${config.user.userName}".source = "${config.user.home}/.nix-profile";
    };

  };
}

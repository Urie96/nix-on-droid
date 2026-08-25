# programs.fish: system-wide fish integration.
#
# Migrated from the user's droidModules (home/urie/nix/droidModules/modules/fish.nix).
#
# nixpkgs fish is compiled with $__fish_sysconfdir pointing into the nix
# store, so it never reads /etc/fish/conf.d/*.fish (or
# /etc/fish/config.fish) on its own; the store config.fish it does read
# only hooks into the OS /etc/fish/config.fish if present (the
# useOperatingSystemEtc hook). nix-on-droid's /etc is populated
# exclusively from environment.etc, so this module provides the missing
# /etc/fish/config.fish: it sources the system-wide conf.d hooks (e.g.
# the session environment from environment/session-init.nix) and
# evaluates the init blocks below.

{ config
, lib
, pkgs
, ...
}:

let
  cfg = config.programs.fish;

  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    optionalString
    types
    ;
in
{
  options.programs.fish = {
    enable = mkEnableOption "fish shell integration";

    package = mkOption {
      type = types.package;
      default = pkgs.fish;
      defaultText = lib.literalExpression "pkgs.fish";
      description = "The fish package to use.";
    };

    interactiveShellInit = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Fish shell commands evaluated only in interactive shells
        (wrapped in `if status is-interactive`).
      '';
    };

    loginShellInit = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Fish shell commands evaluated only in login shells
        (wrapped in `if status is-login`).
      '';
    };

    shellInit = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Fish shell commands evaluated in every shell (login, interactive
        and non-interactive alike).
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.packages = [ cfg.package ];

    environment.etc."fish/config.fish".text = ''
      if status is-login
        set fish_function_path ${pkgs.fishPlugins.foreign-env}/share/fish/vendor_functions.d $fish_function_path
        fenv source ${config.build.sessionInit}/etc/profile.d/nix-on-droid-session-init.sh > /dev/null
        set -e fish_function_path[1]
        ${cfg.loginShellInit}
      end

      for f in /etc/fish/conf.d/*.fish
        if test -f "$f"
          source "$f"
        end
      end

      ${cfg.shellInit}

      if status is-interactive
        ${cfg.interactiveShellInit}
      end
    '';
  };
}

# Copyright (c) 2019-2024, see AUTHORS. Licensed under MIT License, see LICENSE.

# Terminal configuration for the Termux app on Android.
#
# All ~/.termux files (fonts, colors.properties, termux.properties) are
# regular files copied directly from the nix store - no symlinks. Termux
# may rewrite these files itself (e.g. a long-press color scheme picker
# writes colors.properties), which would fail against a read-only store
# symlink.

{ config, lib, pkgs, ... }:
with lib; let
  cfg = config.terminal;

  configDir = "${config.user.home}/.termux";

  validColornames =
    [ "background" "foreground" "cursor" ] ++
    (builtins.map (n: "color${builtins.toString n}") (lib.lists.range 0 15));
  validColorname = colorName: builtins.elem colorName validColornames;

  # terminal.font is kept as an alias for the regular variant
  # (terminal.fonts.regular wins if both are set).
  fontFiles = [
    {
      name = "Regular";
      file = "font.ttf";
      path = if cfg.fonts.regular != null then cfg.fonts.regular else cfg.font;
    }
    { name = "Bold"; file = "font-bold.ttf"; path = cfg.fonts.bold; }
    { name = "Italic"; file = "font-italic.ttf"; path = cfg.fonts.italic; }
    { name = "BoldItalic"; file = "font-bold-italic.ttf"; path = cfg.fonts.boldItalic; }
  ];

  # Direct copy from the nix store.  --remove-destination unlinks a
  # stale symlink first, so plain `cp -f` doesn't fail with "are the same
  # file" when the target symlinks the same store file.  cp would inherit
  # the store's read-only mode, so make the copy writable afterwards.
  copyScript = file: source: ''
    $DRY_RUN_CMD mkdir $VERBOSE_ARG -p "${configDir}"
    $DRY_RUN_CMD cp $VERBOSE_ARG --remove-destination "${source}" "${configDir}/${file}"
    $DRY_RUN_CMD chmod u+w "${configDir}/${file}"
  '';

  unlinkScript = file: ''
    target="${configDir}/${file}"
    if [ -e "$target" ]; then
      $DRY_RUN_CMD rm $VERBOSE_ARG -f "$target"
      if [ -e "${target}.bak" ]; then
        $DRY_RUN_CMD mv $VERBOSE_ARG "${target}.bak" "$target"
        $DRY_RUN_CMD echo "${target} has been restored from backup"
      fi
    fi
  '';

  properties = pkgs.writeTextFile {
    name = "termux.properties";
    text = ''
      # Managed by nix-on-droid - do not edit manually.
      # Reconfigure via the `terminal.properties` option, then run `termux-reload-settings`.
    '' + (lib.generators.toKeyValue { } cfg.properties);
  };

  colors = pkgs.writeTextFile {
    name = "colors.properties";
    text = lib.generators.toKeyValue { } cfg.colors;
  };
in
{
  ###### interface

  options = {
    terminal = {
      font = mkOption {
        default = null;
        type = types.nullOr types.path;
        example =
          lib.literalExpression
            ''"''${pkgs.terminus_font_ttf}/share/fonts/truetype/TerminusTTF.ttf"'';
        description = ''
          Font used for the terminal. Alias for
          <option>terminal.fonts.regular</option>.
        '';
      };

      fonts = mkOption {
        default = { };
        type = types.submodule {
          options = {
            regular = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Regular font, copied to `~/.termux/font.ttf`.";
            };
            bold = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Bold font, copied to `~/.termux/font-bold.ttf`.";
            };
            italic = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Italic font, copied to `~/.termux/font-italic.ttf`.";
            };
            boldItalic = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Bold-italic font, copied to `~/.termux/font-bold-italic.ttf`.";
            };
          };
        };
        description = ''
          Fonts used by the Termux terminal.  Each variant is copied
          directly from the nix store into `~/.termux/` (see termux-app
          #4141 for the separate bold/italic font file support).
        '';
      };

      colors = mkOption {
        default = { };
        type = types.lazyAttrsOf types.str;
        example = lib.literalExpression ''
          {
            background = "#000000";
            foreground = "#FFFFFF";
            cursor = "#FFFFFF";
          }
        '';
        description = ''
          Colorscheme used for the terminal, copied to
          `~/.termux/colors.properties`.
          Acceptable attribute names are:
          `background`, `foreground`, `cursor` and `color0`-`color15`.
        '';
      };

      properties = mkOption {
        default = { };
        type = types.lazyAttrsOf (types.oneOf [
          types.bool
          types.int
          types.float
          types.str
        ]);
        example = literalExpression ''
          {
            "bell-character" = "ignore";
            "enforce-char-based-input" = true;
            "terminal-margin-horizontal" = 6;
          }
        '';
        description = ''
          Key-value settings for the Termux app, written to
          `~/.termux/termux.properties`.  Nix values are converted to
          the properties syntax automatically (`true` -> `true`,
          `12` -> `12`, `1.5` -> `1.5`, strings pass through as-is).

          Known keys (from termux-app `TermuxPropertyConstants`):
          - boolean: `disable-file-share-receiver`, `disable-file-view-receiver`,
            `disable-hardware-keyboard-shortcuts`, `disable-terminal-session-change-toast`,
            `enforce-char-based-input`, `extra-keys-text-all-caps`, `hide-soft-keyboard-on-startup`,
            `run-termux-am-socket-server`, `terminal-onclick-url-open`, `ctrl-space-workaround`,
            `fullscreen`, `use-fullscreen-workaround`, `allow-external-apps`
          - int: `bell-character`, `delete-tmpdir-files-older-than-x-days-on-exit`,
            `terminal-cursor-blink-rate`, `terminal-cursor-style`, `terminal-margin-horizontal`,
            `terminal-margin-vertical`, `terminal-transcript-rows`
          - float: `terminal-toolbar-height`
          - string: `back-key`, `default-working-directory`, `extra-keys`, `extra-keys-style`,
            `night-mode`, `soft-keyboard-toggle-behaviour`, `volume-keys`,
            `shortcut.create-session`, `shortcut.next-session`, `shortcut.previous-session`,
            `shortcut.rename-session`

          After changing this, run `termux-reload-settings` inside Termux
          (or restart the app) for the changes to take effect.
        '';
      };
    };
  };

  ###### implementation

  config = {
    assertions = [{
      assertion = builtins.all validColorname (attrNames cfg.colors);
      message = ''
        `terminal.colors` only accepts the following attributes:
        `background`, `foreground`, `cursor` and `color0`-`color15`.
      '';
    }];

    # Drop stale .bak files left over from the old symlink-based
    # activation so they don't get restored by unlinkScript.
    build.activationBefore.cleanupTermuxBackups = ''
      $DRY_RUN_CMD mkdir $VERBOSE_ARG -p "${configDir}"
      for f in colors.properties termux.properties font.ttf font-bold.ttf font-italic.ttf font-bold-italic.ttf; do
        $DRY_RUN_CMD rm -f "${configDir}/$f.bak"
      done
    '';

    build.activation =
      lib.listToAttrs (map (v:
        if v.path != null
        then {
          name = "copyFont${v.name}";
          value = copyScript v.file v.path;
        }
        else {
          name = "unlinkFont${v.name}";
          value = unlinkScript v.file;
        }
      ) fontFiles)
      // (
        if (cfg.properties != { })
        then { copyTermuxProperties = copyScript "termux.properties" properties; }
        else { unlinkTermuxProperties = unlinkScript "termux.properties"; }
      )
      // (
        if (cfg.colors != { })
        then { copyColors = copyScript "colors.properties" colors; }
        else { unlinkColors = unlinkScript "colors.properties"; }
      );
  };
}

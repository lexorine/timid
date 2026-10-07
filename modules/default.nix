{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  inherit (lib) mkOption mkEnableOption mkPackageOption literalExpression;
  inherit (lib.types) listOf str attrs;

  cfg = config.programs.timid;

  # Vendored copy of the debloat profile, regenerated from upstream's
  # src/manifest.yaml by scripts/gen-debloat-policy.py.
  defaultPolicies = import ./policies.nix {debloat-profile = ./brave.json;};
in {
  options.programs.timid = {
    enable = mkEnableOption "Timid, a privacy-conscious sandboxed browser";

    package = mkPackageOption pkgs "brave" {
      example = "brave";
    };

    binPath = mkOption {
      type = lib.types.nullOr str;
      default = null;
      example = "bin/brave-nightly";
      description = ''
        Path to the browser binary inside the package.
        If null, auto-detected from `meta.mainProgram` or package name.
      '';
    };

    policies = mkOption {
      type = attrs;
      default = {};
      description = "Additional managed policies to merge on top of defaults.";
    };

    extensions = mkOption {
      type = listOf str;
      default = [];
      example = ["cjpalhdlnbpafiamejdnhcphjbkeiagm"];
      description = "Chrome Web Store extension IDs to force-install.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (import ../nix/timid.nix {
        inherit (pkgs) lib;
        inherit pkgs;
        inherit (inputs) nixpak;
        browser = cfg.package;
        binPath = cfg.binPath;
        policies =
          defaultPolicies
          // cfg.policies
          // lib.optionalAttrs (cfg.extensions != []) {
            ExtensionInstallForcelist = cfg.extensions;
          };
      }).config.env
    ];
  };
}

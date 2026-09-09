{
  description = "Timid - A privacy-conscious sandboxed browser wrapper";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixpak = {
      url = "github:nixpak/nixpak";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    brave-previews = {
      url = "github:kcalvelli/brave-browser-previews";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    helium-browser = {
      url = "github:oxcl/nix-flake-helium-browser";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    debloat-profile = {
      url = "https://raw.githubusercontent.com/yashgorana/chrome-debloat/refs/heads/main/generated/linux/brave.json";
      flake = false;
    };
  };

  outputs = inputs: let
    inherit (inputs.nixpkgs) lib;
    eachSystem = lib.genAttrs [
      "x86_64-linux"
      "aarch64-linux"
    ];
  in {
    formatter = eachSystem (system:
      inputs.nixpkgs.legacyPackages.${system}.alejandra
    );

    lib = eachSystem (system: {
      mkBrowserSuite = {
        pkgs ? inputs.nixpkgs.legacyPackages.${system},
        browser,
        name,
        basePolicies ? import ./modules/policies-small.nix { },
        policyDirs ? [ ],
        ephemeralPolicies ? {
          HomepageLocation = "about:blank";
          HomepageIsNewTabPage = false;
          ShowHomeButton = true;
          RestoreOnStartup = 4;
          RestoreOnStartupURLs = [ "about:blank" ];
          NewTabPageLocation = "about:blank";
        },
      }:
        let
          browserBin = browser.meta.mainProgram or (lib.getName browser);
          nixpak = inputs.nixpak;

          mkTimid = args:
            import ./nix/timid.nix ({
              inherit lib pkgs nixpak browser;
            } // args);

          drv = mkTimid {
            withProc = true;
            policies = basePolicies.managed or basePolicies;
            recommendedPolicies = basePolicies.recommended or { };
            inherit policyDirs;
            chromeFlags = [ "--password-store=basic" ];
          };

          drvNoProc = mkTimid {
            withProc = false;
            policies = basePolicies.managed or basePolicies;
            recommendedPolicies = basePolicies.recommended or { };
            inherit policyDirs;
            chromeFlags = [ "--password-store=basic" ];
          };

          drvEphemeral = mkTimid {
            withProc = true;
            ephemeral = true;
            policies = (basePolicies.managed or basePolicies) // ephemeralPolicies;
            recommendedPolicies = basePolicies.recommended or { };
            inherit policyDirs;
            chromeFlags = [ "--password-store=basic" ];
          };

          baseEnv = drv.config.env;
          noProcEnv = drvNoProc.config.env;
          ephemeralBaseEnv = drvEphemeral.config.env;

          ephemeralLauncher = pkgs.writeShellScriptBin "${name}-ephemeral" ''
            set -euo pipefail
            runtime_root="''${XDG_RUNTIME_DIR:-/tmp}/${name}-ephemeral"
            mkdir -p "$runtime_root"

            instance_dir="$(mktemp -d "$runtime_root/instance-XXXXXX")"
            profile_dir="$instance_dir/profile"
            cache_dir="$instance_dir/cache"

            mkdir -p "$profile_dir" "$cache_dir"

            cleanup() {
              rm -rf "$instance_dir"
            }
            trap cleanup EXIT INT TERM

            exec "${ephemeralBaseEnv}/bin/${browserBin}" \
              --user-data-dir="$profile_dir" \
              --disk-cache-dir="$cache_dir" \
              --no-first-run \
              --no-default-browser-check \
              "$@"
          '';

          ephemeralEnv = pkgs.symlinkJoin {
            name = "${name}-ephemeral";
            paths = [ ephemeralBaseEnv ephemeralLauncher ];
          };

          renameBin = env: suffix: pkgs.symlinkJoin {
            name = "${name}${suffix}";
            paths = [ env ];
            postBuild = ''
              mkdir -p $out/bin
              if [ -e "${env}/bin/${browserBin}" ]; then
                ln -s "${env}/bin/${browserBin}" $out/bin/${name}${suffix}
              fi
            '';
          };
        in {
          base = renameBin baseEnv "";
          noproc = renameBin noProcEnv "-noproc";
          ephemeral = ephemeralEnv;
        };
    });

    packages = eachSystem (system: let
      libForSystem = inputs.self.lib.${system};
      pkgs = inputs.nixpkgs.legacyPackages.${system};

      braveSuite = libForSystem.mkBrowserSuite {
        browser = inputs.brave-previews.packages.${system}.brave-nightly;
        name = "timid-brave";
      };

      heliumSuite = libForSystem.mkBrowserSuite {
        browser = inputs.helium-browser.packages.${system}.default;
        name = "timid-helium";
      };
    in {
      default = braveSuite.base;
      timid-brave = braveSuite.base;
      timid-brave-noproc = braveSuite.noproc;
      timid-brave-ephemeral = braveSuite.ephemeral;

      timid-helium = heliumSuite.base;
      timid-helium-noproc = heliumSuite.noproc;
      timid-helium-ephemeral = heliumSuite.ephemeral;
    });

    apps = eachSystem (system: let
      pkgsForSystem = inputs.self.packages.${system};
    in {
      default = {
        type = "app";
        program = "${pkgsForSystem.default}/bin/timid-brave";
      };
      timid-brave = { type = "app"; program = "${pkgsForSystem.timid-brave}/bin/timid-brave"; };
      timid-brave-noproc = { type = "app"; program = "${pkgsForSystem.timid-brave-noproc}/bin/timid-brave-noproc"; };
      timid-brave-ephemeral = { type = "app"; program = "${pkgsForSystem.timid-brave-ephemeral}/bin/timid-brave-ephemeral"; };
      
      timid-helium = { type = "app"; program = "${pkgsForSystem.timid-helium}/bin/timid-helium"; };
      timid-helium-noproc = { type = "app"; program = "${pkgsForSystem.timid-helium-noproc}/bin/timid-helium-noproc"; };
      timid-helium-ephemeral = { type = "app"; program = "${pkgsForSystem.timid-helium-ephemeral}/bin/timid-helium-ephemeral"; };
    });

    nixosModules.default = { pkgs, config, lib, ... }@args:
      import ./modules/default.nix (args // { inherit inputs; });
  };
}
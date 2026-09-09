{
  lib,
  pkgs,
  nixpak,
  browser,
  policies ? { },
  recommendedPolicies ? { },
  policyDirs ? [ ],
  binPath ? null,
  debug ? false,
  withProc ? true,
  ephemeral ? false,
  chromeFlags ? [ "--password-store=basic" "--enable-features=BraveAIChatAgentProfile" ],
}:
let
  browserName = lib.getName browser;
  lowerName = lib.toLower browserName;

  isBrave = lib.hasInfix "brave" lowerName;
  isChromium = lib.hasInfix "chromium" lowerName;
  isChrome = lib.hasInfix "chrome" lowerName && !isChromium;

  appBinPath =
    if binPath != null then
      (if lib.hasPrefix "bin/" binPath then binPath else "bin/${binPath}")
    else
      "bin/${browser.meta.mainProgram or browserName}";

  mainProgram =
    if binPath != null then
      lib.removePrefix "bin/" appBinPath
    else
      (browser.meta.mainProgram or browserName);

  flatpakAppId =
    if isBrave then "com.brave.Browser"
    else if isChromium then "org.chromium.Chromium"
    else if isChrome then "com.google.Chrome"
    else "app.${builtins.replaceStrings [ " " "." "/" ] [ "-" "-" "-" ] browserName}";

  profileBackingDir = "/.local/state/nixpak/${lowerName}";

  profileDir =
    if isBrave then
      (if lib.hasInfix "nightly" lowerName then "/.config/BraveSoftware/Brave-Browser-Nightly"
       else if lib.hasInfix "beta" lowerName then "/.config/BraveSoftware/Brave-Browser-Beta"
       else "/.config/BraveSoftware/Brave-Browser")
    else if isChromium then "/.config/chromium"
    else if isChrome then "/.config/google-chrome"
    else "/.config/${browserName}";

  browserCacheDir =
    if isBrave then "BraveSoftware"
    else if isChromium then "chromium"
    else if isChrome then "google-chrome"
    else browserName;

  mprisName =
    if isBrave then "brave"
    else if isChromium then "chromium"
    else if isChrome then "chrome"
    else lowerName;

  customPolicyDirs = [
    "/etc/brave/policies"
    "/etc/brave-browser/policies"
    "/etc/brave-browser-nightly/policies"
    "/etc/chromium/policies"
    "/etc/opt/chrome/policies"
    "/etc/${lowerName}/policies"
    "/etc/${browserName}/policies"
  ] ++ policyDirs;

  allPolicyDirs = lib.unique customPolicyDirs;

  hasPolicies = policies != { };
  policyFile = pkgs.writeText "${lowerName}-policies.json" (builtins.toJSON policies);

  policyBinds = lib.optionals hasPolicies (map (dir: [ "${policyFile}" "${dir}/managed/policies.json" ]) allPolicyDirs);

  hasRecommendedPolicies = recommendedPolicies != { };
  recommendedPolicyFile = pkgs.writeText "${lowerName}-recommended-policies.json" (builtins.toJSON recommendedPolicies);

  recommendedPolicyBinds = lib.optionals hasRecommendedPolicies (map (dir: [ "${recommendedPolicyFile}" "${dir}/recommended/policies.json" ]) allPolicyDirs);

  browserWithClipboard = pkgs.symlinkJoin {
    name = "${lowerName}-with-extras";
    paths = [ browser pkgs.wl-clipboard ];
  };

  browserWithFlags =
    if chromeFlags == [ ] then
      browserWithClipboard
    else
      pkgs.symlinkJoin {
        name = "${lowerName}-with-flags";
        paths = [ browserWithClipboard ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          if [ -e "$out/bin/${mainProgram}" ]; then
            rm -f "$out/bin/${mainProgram}"
          fi

          makeWrapper "${browserWithClipboard}/${appBinPath}" "$out/bin/${mainProgram}" \
            ${lib.concatMapStringsSep " " (flag: "--add-flags ${lib.escapeShellArg flag}") chromeFlags}
        '';
      };

  debugPackage = pkgs.symlinkJoin {
    name = "${lowerName}-debug-shell";
    paths = [ pkgs.fish browserWithFlags ];
  };

  mkNixPak = nixpak.lib.nixpak { inherit lib pkgs; };
in
mkNixPak {
  config = { config, sloth, ... }:
    let
      envSuffix = key: suf: sloth.concat' (sloth.env key) suf;
      envOrSuffix = key: fallback: suf: sloth.concat' (sloth.envOr key fallback) suf;

      home = sloth.homeDir;
      cache = sloth.xdgCacheHome;
      cfgHome = sloth.xdgConfigHome;

      cacheMount = envOrSuffix "HOME" "" "/.var/app/${config.flatpak.appId}/cache";
    in {
      app.package = if debug then debugPackage else browserWithFlags;
      app.binPath = if debug then "bin/fish" else appBinPath;

      flatpak.appId = flatpakAppId;

      dbus.enable = true;
      dbus.policies = {
        "${config.flatpak.appId}" = "own";
        "org.mpris.MediaPlayer2.${mprisName}" = "own";

        "org.freedesktop.DBus" = "talk";
        "org.gtk.vfs" = "talk";
        "org.gtk.vfs.*" = "talk";
        "ca.desrt.dconf" = "talk";
        "org.a11y.Bus" = "talk";

        "org.freedesktop.portal.*" = "talk";
        "org.freedesktop.portal.Desktop" = "talk";
        "org.freedesktop.portal.FileChooser" = "talk";
        "org.freedesktop.portal.OpenURI" = "talk";
        "org.freedesktop.portal.ScreenCast" = "talk";
        "org.freedesktop.portal.Camera" = "talk";
        "org.freedesktop.portal.Settings" = "talk";

        "org.freedesktop.Notifications" = "talk";
        # "org.freedesktop.secrets" = "talk";
        # "org.kde.kwalletd5" = "talk";
        # "org.kde.kwalletd6" = "talk";

        "org.freedesktop.PowerManagement" = "talk";
        "org.freedesktop.ScreenSaver" = "talk";
        # "org.freedesktop.NetworkManager" = "talk";
        # "org.gnome.SessionManager" = "talk";
      };

      gpu.enable = true;
      gpu.provider = "nixos";
      locale.enable = true;

      bubblewrap = {
        network = true;

        apivfs = {
          dev = true;
          proc = withProc;
        };

        sockets = {
          wayland = true;
          pulse = true;
          pipewire = true;
        };

        tmpfs =
          [ "/tmp" ]
          ++ lib.optionals ephemeral [
            (sloth.concat' home profileDir)
            (sloth.concat' home profileBackingDir)
            cache
          ];

        bind.rw =
          [
            [
              (sloth.mkdir (sloth.concat' home "/Downloads/bwrap"))
              (sloth.concat' home "/Downloads")
            ]
            (envSuffix "XDG_RUNTIME_DIR" "/at-spi/bus")
            (envSuffix "XDG_RUNTIME_DIR" "/gvfsd")
            [
              (sloth.mkdir (sloth.concat' home "/.local/share/nixpak-shared"))
              (sloth.concat' home "/.local/share/nixpak-shared")
            ]
          ]
          ++ lib.optionals (!ephemeral) [
            [
              (sloth.mkdir (sloth.concat' home profileBackingDir))
              (sloth.concat' home profileDir)
            ]
            [
              (sloth.mkdir cacheMount)
              cache
            ]
            (sloth.mkdir (sloth.concat' home "/.cache/${browserCacheDir}"))
            (sloth.concat' cache "/fontconfig")
          ];

        bind.ro =
          policyBinds
          ++ recommendedPolicyBinds
          ++ [
            (envSuffix "XDG_RUNTIME_DIR" "/doc")

            "/etc/fonts"
            "/run/current-system/sw/share/X11/fonts"
            "/run/current-system/sw/share/fonts"
            (sloth.concat' home "/.local/share/fonts")
            (sloth.concat' home "/.fonts")

            "/etc/ssl"
            "/etc/ca-certificates"
            "/run/current-system/sw/etc/ssl"
            "/etc/resolv.conf"
            "/etc/zoneinfo"
            "/etc/localtime"

            "/run/current-system/sw/share/mime"
            "/run/current-system/sw/share/icons"

            "/run/current-system/sw/share/gtk-3.0"
            "/run/current-system/sw/share/gtk-4.0"
            (sloth.concat' cfgHome "/gtk-2.0")
            (sloth.concat' cfgHome "/gtk-3.0")
            (sloth.concat' cfgHome "/gtk-4.0")
            (sloth.concat' cfgHome "/fontconfig")
            (sloth.concat' cfgHome "/dconf")
            "/etc/dconf"
            "/etc/xdg/gtk-2.0"
            "/etc/xdg/gtk-3.0"
            "/etc/xdg/gtk-4.0"

            "/run/current-system/sw/share/X11/xkb"

            "/run/dbus"
            "/run/current-system/sw/share/glib-2.0"

            "/sys/dev/char"
            "/sys/devices"
            "/sys/bus/pci"
            "/run/current-system/sw/share/libdrm"
          ];

        bind.dev = [ "/dev/dri" ];

        env = {
          DISPLAY = sloth.envOr "DISPLAY" ":0";
          WAYLAND_DISPLAY = sloth.envOr "WAYLAND_DISPLAY" "wayland-0";
          LANG = sloth.envOr "LANG" "en_US.UTF-8";
          QT_QPA_PLATFORMTHEME = sloth.envOr "QT_QPA_PLATFORMTHEME" "gtk3";

          XDG_DATA_DIRS = lib.makeSearchPath "share" [
            pkgs.adwaita-icon-theme
            pkgs.shared-mime-info
          ];

          XCURSOR_PATH = lib.concatStringsSep ":" [
            "${pkgs.adwaita-icon-theme}/share/icons"
            "${pkgs.adwaita-icon-theme}/share/pixmaps"
          ];
        };
      };
    };
}
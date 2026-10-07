{
  lib,
  pkgs,
  nixpak,
  browser,
  policies ? {},
  binPath ? null,
  debug ? false,
}: let
  browserName = lib.getName browser;
  lowerName = lib.toLower browserName;

  isBrave = lib.hasInfix "brave" lowerName;
  isChromium = lib.hasInfix "chromium" lowerName;
  isChrome = lib.hasInfix "chrome" lowerName && !isChromium;

  appBinPath =
    if binPath != null
    then
      (
        if lib.hasPrefix "bin/" binPath
        then binPath
        else "bin/${binPath}"
      )
    else "bin/${browser.meta.mainProgram or browserName}";

  flatpakAppId =
    if isBrave
    then "com.brave.Browser"
    else if isChromium
    then "org.chromium.Chromium"
    else if isChrome
    then "com.google.Chrome"
    else "app.${builtins.replaceStrings [" " "." "/"] ["-" "-" "-"] browserName}";

  profileBackingDir = "/.local/state/nixpak/${lowerName}";

  profileDir =
    if isBrave
    then
      (
        if lib.hasInfix "nightly" lowerName
        then "/.config/BraveSoftware/Brave-Browser-Nightly"
        else if lib.hasInfix "beta" lowerName
        then "/.config/BraveSoftware/Brave-Browser-Beta"
        else "/.config/BraveSoftware/Brave-Browser"
      )
    else if isChromium
    then "/.config/chromium"
    else if isChrome
    then "/.config/google-chrome"
    else "/.config/${browserName}";

  browserCacheDir =
    if isBrave
    then "BraveSoftware"
    else if isChromium
    then "chromium"
    else if isChrome
    then "google-chrome"
    else browserName;

  mprisName =
    if isBrave
    then "brave"
    else if isChromium
    then "chromium"
    else if isChrome
    then "chrome"
    else lowerName;

  hasPolicies = policies != {};
  policyFile = pkgs.writeText "${lowerName}-policies.json" (builtins.toJSON policies);

  policyBinds = lib.optionals hasPolicies (map (dest: ["${policyFile}" dest]) [
    "/etc/brave/policies/managed/policies.json"
    "/etc/brave-browser/policies/managed/policies.json"
    "/etc/brave-browser-nightly/policies/managed/policies.json"
    "/etc/chromium/policies/managed/policies.json"
    "/etc/opt/chrome/policies/managed/policies.json"
  ]);

  mkNixPak = nixpak.lib.nixpak {inherit lib pkgs;};

  browserWithClipboard = pkgs.symlinkJoin {
    name = "${lowerName}-with-extras";
    paths = [
      browser
      pkgs.wl-clipboard # provides wl-copy and wl-paste inside the sandbox
    ];
  };

  debugPackage = pkgs.symlinkJoin {
    name = "${lowerName}-debug-shell";
    paths = [pkgs.fish browserWithClipboard];
  };
in
  mkNixPak {
    config = {
      config,
      sloth,
      ...
    }: let
      envSuffix = key: suf: sloth.concat' (sloth.env key) suf;
      home = sloth.homeDir;
      cache = sloth.xdgCacheHome;
      cfgHome = sloth.xdgConfigHome;
    in {
      app.package =
        if debug
        then debugPackage
        else browserWithClipboard;
      app.binPath =
        if debug
        then "bin/fish"
        else appBinPath;

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
        "org.freedesktop.secrets" = "talk";
        "org.kde.kwalletd5" = "talk";
        "org.kde.kwalletd6" = "talk";

        "org.freedesktop.PowerManagement" = "talk";
        "org.freedesktop.ScreenSaver" = "talk";
        "org.freedesktop.NetworkManager" = "talk";
        "org.gnome.SessionManager" = "talk";
      };

      # ── Key change: no fonts.enable, no gpu bundle ────────────────────
      # fonts.enable = true  → caused buildEnv crash with bind.ro strings
      # gpu.provider = "bundle" → bundled mesa lacks your system's Vulkan ICDs
      #
      # Instead: gpu.provider = "host" bind-mounts your real drivers,
      # and we handle fonts manually via bind.ro.
      gpu.enable = true;
      gpu.provider = "raw";
      locale.enable = true;

      bubblewrap = {
        network = true;

        apivfs = {
          dev = true;
          proc = true;
        };

        sockets = {
          wayland = true;
          pulse = true;
          pipewire = true;
        };

        tmpfs = ["/tmp"];

        bind.rw = [
          # Profile isolation
          [
            (sloth.mkdir (sloth.concat' home profileBackingDir))
            (sloth.concat' home profileDir)
          ]

          # Cache isolation
          [
            (sloth.mkdir (envSuffix "HOME" "/.var/app/${config.flatpak.appId}/cache"))
            cache
          ]

          [(sloth.mkdir (sloth.concat' sloth.homeDir "/Downloads/bwrap")) (sloth.concat' sloth.homeDir "/Downloads")]

          # Browser cache
          (sloth.mkdir (sloth.concat' home "/.cache/${browserCacheDir}"))

          # Fontconfig cache (fc-cache writes here)
          (sloth.concat' cache "/fontconfig")

          # GPU shader caches
          (sloth.concat' cache "/mesa_shader_cache")
          (sloth.mkdir (sloth.concat' home "/.cache/radv_builtin_shaders64"))
          (sloth.mkdir (sloth.concat' home "/.cache/radv_builtin_shaders"))

          # XDG_RUNTIME_DIR sub-paths
          (envSuffix "XDG_RUNTIME_DIR" "/at-spi/bus")
          (envSuffix "XDG_RUNTIME_DIR" "/gvfsd")
        ];

        bind.ro =
          policyBinds
          ++ [
            (envSuffix "XDG_RUNTIME_DIR" "/doc")

            # ── Fonts (manual — fonts.enable is off) ─────────────────────
            "/etc/fonts"
            "/run/current-system/sw/share/X11/fonts"
            "/run/current-system/sw/share/fonts"
            (sloth.concat' home "/.local/share/fonts")
            (sloth.concat' home "/.fonts")

            # ── TLS / DNS ────────────────────────────────────────────────
            "/etc/ssl"
            "/etc/ca-certificates"
            "/run/current-system/sw/etc/ssl"
            "/etc/resolv.conf"

            # ── Timezone ─────────────────────────────────────────────────
            "/etc/zoneinfo"
            "/etc/localtime"

            # ── MIME ─────────────────────────────────────────────────────
            "/run/current-system/sw/share/mime"

            # ── Icons ────────────────────────────────────────────────────
            "/run/current-system/sw/share/icons"

            # ── GTK theming ──────────────────────────────────────────────
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

            # ── Keyboard ────────────────────────────────────────────────
            "/run/current-system/sw/share/X11/xkb"

            # ── GPU / Vulkan / EGL / VA-API ──────────────────────────────
            # gpu.provider = "host" may already bind some of these;
            # duplicates are harmless — bwrap deduplicates silently.
            "/run/opengl-driver"
            "/run/opengl-driver-32"
            "/etc/vulkan"
            "/etc/egl"
            "/etc/static/egl"
            "/etc/OpenCL"
            "/run/current-system/sw/share/vulkan"
            "/run/current-system/sw/share/glvnd"

            # sysfs — GPU enumeration for Vulkan/VA-API
            "/sys/dev/char"
            "/sys/devices"

            # ── System D-Bus socket ──────────────────────────────────────
            "/run/dbus"

            # ── libdrm / GLib ────────────────────────────────────────────
            "/run/current-system/sw/share/libdrm"
            "/run/current-system/sw/share/glib-2.0"
          ];

        bind.dev = [
          "/dev/dri"
        ];

        env = {
          DISPLAY = sloth.env "DISPLAY";
          WAYLAND_DISPLAY = sloth.env "WAYLAND_DISPLAY";
          QT_QPA_PLATFORMTHEME = sloth.env "QT_QPA_PLATFORMTHEME";
          LANG = sloth.env "LANG";

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

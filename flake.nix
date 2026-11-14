{
  description = "discord-feed: an always-on-top live feed of incoming Discord messages";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let
      forAll = f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ]
        (s: f nixpkgs.legacyPackages.${s});
    in {
      packages = forAll (pkgs: rec {
        # The overlay window.
        discord-feed = pkgs.stdenv.mkDerivation {
          pname = "discord-feed";
          version = "0.1.0";
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [ ./build.zig ./build.zig.zon ./src ];
          };
          nativeBuildInputs = [ pkgs.zig_0_16.hook pkgs.pkg-config pkgs.qt6.wrapQtAppsHook ];
          buildInputs = [ pkgs.qt6.qtbase ];
          meta.mainProgram = "discord-feed";
        };

        # Vencord with the DiscordFeed plugin added as a user plugin. Copied in
        # preBuild rather than postPatch so the upstream pnpm deps hash still applies.
        vencord = pkgs.vencord.overrideAttrs (old: {
          preBuild = (old.preBuild or "") + ''
            mkdir -p src/userplugins
            cp -r ${./plugin/discordFeed} src/userplugins/discordFeed
          '';
        });

        # Vesktop using that Vencord build.
        vesktop = pkgs.vesktop.override { withSystemVencord = true; inherit vencord; };

        default = discord-feed;
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.zig_0_16 pkgs.pkg-config pkgs.qt6.qtbase ];
          shellHook = ''
            export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/${pkgs.qt6.qtbase.qtPluginPrefix}
          '';
        };
      });
    };
}

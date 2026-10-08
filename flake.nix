{
  description = "kwm, a DWM-like window manager for river";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # river 0.5, from its main branch. The screenshots run kwm in it.
    river = {
      url = "git+https://codeberg.org/river/river.git?ref=main";
      flake = false;
    };
    # The GTK themes of the screenshots of the title bar (dark and light).
    win-classic-theme = {
      url = "git+https://github.com/menduz/win-classic-theme.git?ref=main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      river,
      win-classic-theme,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachSystem = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      build =
        pkgs:
        let
          kwm = pkgs.callPackage ./nix/package.nix {
            version = "0-unstable-${self.lastModifiedDate or "dirty"}";
          };
          river-main = pkgs.callPackage ./nix/river.nix { src = river; };
          themes = win-classic-theme.packages.${pkgs.stdenv.hostPlatform.system};
          shots = pkgs.callPackage ./nix/screenshots.nix {
            inherit kwm;
            river = river-main;
            # The light theme is the Windows Standard scheme.
            themes = [
              themes.dark
              themes.windows-standard
            ];
          };
          tests = pkgs.callPackage ./nix/tests.nix {
            inherit kwm;
            river = river-main;
          };
        in
        {
          inherit
            kwm
            river-main
            shots
            tests
            ;
        };
    in
    {
      packages = forEachSystem (
        pkgs:
        let
          b = build pkgs;
        in
        {
          default = b.kwm;
          inherit (b) kwm;
          river = b.river-main;
          inherit (b.shots) screenshots screenshot;
          test-maximize = b.tests.maximize;
          test-focus = b.tests.focus;
          test-bar = b.tests.bar;
          test-title-bar = b.tests.title-bar;
          test-theme = b.tests.theme;
        }
      );

      checks = forEachSystem (pkgs: (build pkgs).tests.checks);

      devShells = forEachSystem (
        pkgs:
        let
          b = build pkgs;
        in
        {
          default = pkgs.callPackage ./nix/shell.nix {
            inherit (b.shots) screenshot;
            update-screenshots = b.shots.update;
          };
        }
      );

      formatter = forEachSystem (pkgs: pkgs.nixfmt-rfc-style);
    };
}

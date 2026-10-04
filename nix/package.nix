# Builds kwm, a window manager for river 0.4 and later. kwm is DWM-like, with
# tags and a tile layout. Upstream is https://github.com/kewuaa/kwm.
#
# `kwmSource` and `version` are for a flake that has kwm as an input. Without
# them, the recipe builds the files of this repository. (callPackage gives the
# packages with the names of the arguments, and nixpkgs has a package "src".)
#
# After a change of the Zig dependencies in build.zig.zon, the hash below
# changes. Then the build fails and shows the new hash. Put that hash below.
{
  lib,
  callPackage,
  stdenv,
  zig_0_16,
  pkg-config,
  makeWrapper,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libxkbcommon,
  fcft,
  pixman,
  systemdLibs,
  libspng,
  resvg,
  # The programs of the widget scripts in contrib/.
  systemd,
  dunst,
  jq,
  pipewire,
  inotify-tools,
  findutils,
  coreutils,
  gnused,
  kwmSource ? builtins.path {
    name = "kwm-source";
    path = ../.;
    # The files of the build. The screenshots and the Nix files are not part
    # of it, so a new screenshot does not build kwm again.
    filter =
      path: type:
      !(builtins.elem (baseNameOf path) [
        ".git"
        ".zig-cache"
        "zig-out"
        "zig-pkg"
        "result"
        "nix"
        "screenshots"
        "flake.nix"
        "flake.lock"
      ]);
  },
  version ? "0-unstable",
}:
let
  zigSystemDeps = callPackage ./zig-system-deps.nix { };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "kwm";
  inherit version;
  src = kwmSource;

  deps = zigSystemDeps {
    inherit (finalAttrs) pname version src;
    # fcft and pixman are lazy dependencies. Only the bar uses them.
    fetchAll = true;
    hash = "sha256-Lz/Wcy40rxN81n/mBj4YJVbyGOolHzSFZMs93T1h0oQ=";
  };

  strictDeps = true;

  nativeBuildInputs = [
    pkg-config
    wayland-scanner
    zig_0_16
    makeWrapper
  ];

  buildInputs = [
    fcft
    libxkbcommon
    pixman
    # sd-bus for the tray, and the icons of the tray.
    systemdLibs
    libspng
    resvg
    wayland
    # build.zig asks pkg-config for the protocol directory of wayland-scanner.
    wayland-scanner
    wayland-protocols
  ];

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
    "-Dversion-string=${finalAttrs.version}"
    # No solid background. The background of kwm covers the layer-shell
    # surfaces on the bottom layer, for example a wallpaper.
    "-Dbackground=false"
    # kwm starts kwim to apply the input rules of the kwm configuration.
    "-Dkwim=true"
    # The tray in the bar (StatusNotifierItem).
    "-Dtray=true"
  ];

  # The widget scripts find their programs. The programs of the system come
  # first, for example the systemd-inhibit of the running systemd.
  postFixup = ''
    wrapProgram $out/bin/kwm-sleep-inhibit \
      --suffix PATH : ${
        lib.makeBinPath [
          systemd
          jq
        ]
      }
    wrapProgram $out/bin/kwm-notifications \
      --suffix PATH : ${
        lib.makeBinPath [
          dunst
          jq
        ]
      }
    wrapProgram $out/bin/kwm-privacy \
      --suffix PATH : ${
        lib.makeBinPath [
          pipewire
          jq
          inotify-tools
          findutils
          coreutils
          gnused
        ]
      }
  '';

  meta = {
    description = "DWM-like dynamic tiling window manager for river";
    homepage = "https://github.com/kewuaa/kwm";
    license = lib.licenses.gpl3Only;
    mainProgram = "kwm";
    platforms = lib.platforms.linux;
  };
})

# The screenshots of kwm.
#
# `kwm-screenshot` runs river with the headless backend of wlroots and kwm
# with config.def.zon, then takes a screenshot with grim. Refer to
# screenshot.sh. `screenshots` runs it in the sandbox, and `update-screenshots`
# copies the result to screenshots/ in the working tree.
{
  lib,
  runCommand,
  runCommandCC,
  writeShellApplication,
  makeFontsConf,
  writeText,
  kwm,
  river,
  foot,
  grim,
  dbus,
  python3,
  coreutils,
  findutils,
  libfaketime,
  adwaita-icon-theme,
  hicolor-icon-theme,
  terminus_font,
  dejavu_fonts,
  nerd-fonts,
}:
let
  # Fixed values for the CPU, memory, disk and battery widgets.
  preload = runCommandCC "kwm-screenshot-preload" { } ''
    mkdir -p "$out/lib"
    $CC -shared -fPIC -O2 -Wall -Wextra -o "$out/lib/kwm-screenshot-preload.so" \
      ${./screenshot-preload.c} -ldl
  '';

  # The fonts of config.def.zon: Terminus for the text, DejaVu Sans Mono for
  # the glyphs that Terminus does not have (the braille meters), and the Nerd
  # Font symbols for the icons of the widgets.
  baseFontsConf = makeFontsConf {
    fontDirectories = [
      terminus_font
      dejavu_fonts
      nerd-fonts.symbols-only
    ];
  };

  # makeFontsConf gives no aliases. kwm asks for "monospace".
  fontsConf = writeText "kwm-screenshot-fonts.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <include>${baseFontsConf}</include>
      <alias>
        <family>monospace</family>
        <prefer>
          <family>DejaVu Sans Mono</family>
          <family>Symbols Nerd Font Mono</family>
        </prefer>
      </alias>
    </fontconfig>
  '';

  screenshot = writeShellApplication {
    name = "kwm-screenshot";
    runtimeInputs = [
      kwm
      river
      foot
      grim
      dbus
      (python3.withPackages (ps: [ ps.dbus-next ]))
      coreutils
      findutils
    ];
    text = ''
      export FONTCONFIG_FILE=${fontsConf}
      # The icons of the tray items.
      export XDG_DATA_DIRS=${adwaita-icon-theme}/share:${hicolor-icon-theme}/share
      export DBUS_SESSION_CONF=${dbus}/share/dbus-1/session.conf
      export FAKETIME_LIB=${libfaketime}/lib/libfaketime.so.1
      export PRELOAD_LIB=${preload}/lib/kwm-screenshot-preload.so
      export TRAY_SCRIPT=${./screenshot-tray.py}
      exec bash ${./screenshot.sh} "$@"
    '';
  };
in
{
  inherit screenshot;

  screenshots =
    runCommand "kwm-screenshots"
      {
        nativeBuildInputs = [ screenshot ];
        meta.description = "Screenshots of kwm";
      }
      ''
        kwm-screenshot "$out"
      '';

  # `update-screenshots` in the development shell. It builds the screenshots
  # and puts them in the working tree.
  update = writeShellApplication {
    name = "update-screenshots";
    text = ''
      if [ ! -e ./build.zig ] || [ ! -e ./flake.nix ]; then
        echo "update-screenshots: run this in the directory of kwm" >&2
        exit 1
      fi
      if ! out=$(nix build --no-link --print-out-paths .#screenshots); then
        echo "update-screenshots: the build failed. Nix reads the files that" >&2
        echo "Git tracks, so a new file needs 'git add' first." >&2
        exit 1
      fi
      mkdir -p screenshots
      install -m 644 "$out"/*.png screenshots/
      echo "update-screenshots: wrote"
      ls -1 screenshots/
    '';
  };
}

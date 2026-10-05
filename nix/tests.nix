# The tests of kwm. They run kwm in river with the headless backend of
# wlroots.
#
# `kwm-test-maximize` runs test-maximize.sh, and `checks.maximize` runs it in
# the sandbox (`nix flake check`).
{
  runCommand,
  writeShellApplication,
  makeFontsConf,
  kwm,
  river,
  dbus,
  python3,
  coreutils,
  findutils,
  gnugrep,
  terminus_font,
  dejavu_fonts,
}:
let
  maximize = writeShellApplication {
    name = "kwm-test-maximize";
    runtimeInputs = [
      kwm
      river
      dbus
      (python3.withPackages (ps: [ ps.pywayland ]))
      coreutils
      findutils
      gnugrep
    ];
    text = ''
      # The fonts of the bar in config.def.zon.
      export FONTCONFIG_FILE=${
        makeFontsConf {
          fontDirectories = [
            terminus_font
            dejavu_fonts
          ];
        }
      }
      export DBUS_SESSION_CONF=${dbus}/share/dbus-1/session.conf
      export TEST_CLIENT=${./test-client.py}
      exec bash ${./test-maximize.sh} "$@"
    '';
  };
in
{
  inherit maximize;

  checks = {
    maximize =
      runCommand "kwm-test-maximize"
        {
          nativeBuildInputs = [ maximize ];
          meta.description = "The maximized state of the windows of kwm";
        }
        ''
          kwm-test-maximize
          touch "$out"
        '';
  };
}

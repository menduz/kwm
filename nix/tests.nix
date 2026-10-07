# The tests of kwm. They run kwm in river with the headless backend of
# wlroots.
#
# `kwm-test-<name>` runs test-<name>.sh, and `checks.<name>` runs it in the
# sandbox (`nix flake check`). test-lib.sh holds the shared part.
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
  wtype,
  wlrctl,
  wayland-scanner,
  pkg-config,
  wlr-protocols,
  wlroots,
  terminus_font,
  dejavu_fonts,
}:
let
  python = python3.withPackages (ps: [ ps.pywayland ]);

  # The pywayland modules of the virtual input protocols, for test-input.py.
  # wayland.xml is necessary for the types of the core protocol.
  # pywayland-scanner finds the directory of wayland.xml with pkg-config.
  protocols =
    runCommand "kwm-test-protocols"
      {
        nativeBuildInputs = [
          python
          pkg-config
          wayland-scanner
        ];
      }
      ''
        mkdir -p $out/kwm_test_protocols
        touch $out/kwm_test_protocols/__init__.py
        pywayland-scanner -o $out/kwm_test_protocols -i \
          ${wayland-scanner}/share/wayland/wayland.xml \
          ${wlr-protocols}/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml \
          ${wlroots.src}/protocol/virtual-keyboard-unstable-v1.xml
      '';

  # The command kwm-test-<name> runs test-<name>.sh in the environment of the
  # tests.
  mkTest =
    name:
    writeShellApplication {
      name = "kwm-test-${name}";
      runtimeInputs = [
        kwm
        river
        dbus
        python
        coreutils
        findutils
        gnugrep
        wtype
        wlrctl
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
        export TEST_LIB=${./test-lib.sh}
        export TEST_INPUT=${./test-input.py}
        export PYTHONPATH=${protocols}
        exec bash ${./. + "/test-${name}.sh"} "$@"
      '';
    };

  # A check runs the test in the sandbox (`nix flake check`).
  mkCheck =
    name: description:
    runCommand "kwm-test-${name}"
      {
        nativeBuildInputs = [ (mkTest name) ];
        meta.description = description;
      }
      ''
        kwm-test-${name}
        touch "$out"
      '';

  maximize = mkTest "maximize";
  focus = mkTest "focus";
in
{
  inherit maximize focus;

  checks = {
    maximize = mkCheck "maximize" "The maximized state of the windows of kwm";
    focus = mkCheck "focus" "The keyboard focus of the windows of kwm";
  };
}

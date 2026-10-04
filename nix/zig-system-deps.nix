# Gives the Zig dependencies of a package in the layout for
# `zig build --system <dir>`.
#
# zig_0_16.fetchDeps gives the package cache of Zig. Zig 0.16 keeps each
# package in that cache as a <hash>.tar.gz archive. `--system` needs a
# <hash> directory for each package. This derivation unpacks each archive.
{
  runCommand,
  zig_0_16,
}:
args:
runCommand "${args.pname}-${args.version}-zig-system-deps" { } ''
  mkdir $out
  for dep in ${zig_0_16.fetchDeps args}/*; do
    case "$dep" in
      *.tar.gz) tar -xzf "$dep" -C $out ;;
      *) ln -s "$dep" $out/ ;;
    esac
  done
''

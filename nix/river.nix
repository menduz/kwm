# Builds river from its main branch, the development version of river 0.5.
# The screenshots of kwm run in it. The recipe of nixpkgs for river 0.4 builds
# it. This file changes only the source, the version and the Zig dependencies.
#
# After an update of the river input, the hash of the Zig dependencies can
# change. Then the build fails and shows the new hash. Put that hash below.
{
  river,
  callPackage,
  src,
}:
let
  zigSystemDeps = callPackage ./zig-system-deps.nix { };
in
river.overrideAttrs (
  finalAttrs: previousAttrs: {
    version = "0.5.0-dev-${src.shortRev or "dirty"}";
    inherit src;

    deps = zigSystemDeps {
      inherit (finalAttrs) pname version src;
      hash = "sha256-1TW4SRIcrBvJSU9m+tCa9mwQK3PRzrNxGOlRwoiVrp4=";
    };

    # The source has no .git directory. Without this flag, build.zig runs git
    # to find the version.
    zigBuildFlags = previousAttrs.zigBuildFlags ++ [ "-Dversion-string=${finalAttrs.version}" ];

    passthru = previousAttrs.passthru // {
      updateScript = null;
    };
  }
)

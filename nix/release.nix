# The published Pounce.app release this flake installs.
#
# CI-OWNED: .github/workflows/release.yml rewrites these on main after every
# tag, pointing the flake at the tarball it just published. Never hand-bump
# them; a hand-typed sha ships a flake that refuses to build. Feel-testing a
# source branch goes through the `prebuilt` dev-app injection (`bench try`)
# instead, which ignores these entirely.
#
# Hand-edit only to bootstrap a brand-new release line. `version` carries no
# leading "v"; `sha256` is the release tarball's SHA-256 in hex.
{
  version = "2026.09.21";
  sha256 = "4cfe3ec4065ebd705569b4c4c2dfb0e3beaeadfee00871afb7bd070f8355270a";
}

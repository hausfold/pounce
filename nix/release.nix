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
  version = "2026.09.03-1";
  sha256 = "2857c9fc99753ad2e3a3806d93a7b45d78f860a4bbb80e168dc927dfb009baa3";
}

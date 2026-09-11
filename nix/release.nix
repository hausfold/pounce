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
  version = "2026.09.11";
  sha256 = "43d80aab2eacee57f3d84ef04145d84ea528298d9105fa272302623cb98e0f63";
}

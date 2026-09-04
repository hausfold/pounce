{
  description = "Pounce — a native, scriptable command palette for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # nebelung is the single source of truth for the default palette; its
    # `palette`/`palettes` outputs are plain name -> "#hex" attrsets baked into
    # the binary at build time (see pkgs/pounce) — the dark default and its
    # latte counterpart, which together are what lets a zero-config pounce
    # follow macOS light/dark. Only palette data is used — the theme-builder
    # packages are never realised — so this stays a pure eval.
    nebelung.url = "github:hausfold/nebelung";
    nebelung.inputs.nixpkgs.follows = "nixpkgs";

    # Injection point for feel-testing a pounce SOURCE branch through `bench try`.
    # bench builds the app from the branch in your login session (re-signed with
    # a stable identity) and overrides this input to that built .app dir; the
    # pounce-app package then wraps your branch's app instead of the release.
    # Default: the empty ./nix/dev-app placeholder → the package fetches the
    # CI-built notarized release as normal. `flake = false`: it's a plain dir.
    prebuilt = {
      url = "path:./nix/dev-app";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nebelung,
      prebuilt,
    }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAll = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };

      # The CI-owned release pin (version + sha256 of the notarized tarball).
      release = import ./nix/release.nix;
    in
    {
      # Consume pounce from anywhere: `overlays.default` puts `pounce` and
      # `pounce-commands` into pkgs.
      overlays.default = final: prev: {
        pounce = final.callPackage ./pkgs/pounce {
          nebelungPalette = nebelung.palette;
          nebelungLattePalette = nebelung.palettes.nebelung-latte;
        };
        # The app haus's launcher room installs: the CI-built, Developer-ID-signed
        # + notarized Pounce.app from the release tarball (pinned by nix/release.nix),
        # NOT a from-source build — an ad-hoc store build would lose the macOS
        # Accessibility grant on every rebuild, which is the whole point of this
        # package. `pounce` above stays the from-source dev package. See
        # nix/app-prebuilt.nix.
        pounce-app = final.callPackage ./nix/app-prebuilt.nix {
          inherit (release) version sha256;
          prebuilt = prebuilt.outPath;
        };

        pounce-commands = final.callPackage ./pkgs/pounce-commands { };

        # The agent skill (ai/SKILL.md), so a consumer can install it without
        # installing pounce — haus's AI room will drop it into every agent client
        # on the machine once its side lands. Its own package rather than a file inside `pounce`:
        # that one compiles Swift and bakes in a palette, and a sentence of
        # prose has no business invalidating it.
        pounce-skill = final.callPackage ./pkgs/pounce-skill { };
      };

      packages = forAll (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.pounce;
          pounce = pkgs.pounce;
          pounce-app = pkgs.pounce-app;
          pounce-commands = pkgs.pounce-commands;
          pounce-skill = pkgs.pounce-skill;
        }
      );

      # `nix run github:hausfold/pounce`
      apps = forAll (system: {
        default = {
          type = "app";
          program = "${(pkgsFor system).pounce}/bin/pounce";
        };
      });
    };
}

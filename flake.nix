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
  };

  outputs =
    { self, nixpkgs, nebelung }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAll = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
    in
    {
      # Consume pounce from anywhere: `overlays.default` puts `pounce` and
      # `pounce-commands` into pkgs.
      overlays.default = final: prev: {
        pounce = final.callPackage ./pkgs/pounce {
          nebelungPalette = nebelung.palette;
          nebelungLattePalette = nebelung.palettes.nebelung-latte;
        };
        pounce-commands = final.callPackage ./pkgs/pounce-commands { };

        # The agent skill (ai/SKILL.md), so a consumer can install it without
        # installing pounce — haus's AI room drops it into every agent client
        # on the machine. Its own package rather than a file inside `pounce`:
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

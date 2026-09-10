# assets

`pounce-banner-rounded.png` — the identity banner the README opens with
(1200×348): the peach wordmark beside the cat-ears mark over a palette input
bar, on a rounded `surface0` tile — the family's shared banner lockup. Flat
pixels, no vector master and no recipe here: re-render from the brand kit to
change it, including when a nebelung token moves.

`pounce-square.png` / `pounce-square-inverted.png` — the app-icon mark
(2048²): peach cat-ears over a command-palette input bar. `-square` is the
dark-squircle version (light backgrounds); `-square-inverted` is the peach
squircle with a dark mark (dark backgrounds). Three
[nebelung](https://github.com/hausfold/nebelung) tokens, baked in as flat pixels
and not themed at runtime: `peach` (#F5B58E), `surface0` (#343434) for the tile,
`surface1` (#494949) for the input bar.

`pounce-square-latte.svg` / `pounce-square-latte.png` — **the light tile's
source of record** and its render (2048²): the same geometry in nebelung's
latte set. That ramp runs the other way, so the tile is `base` (#F1F1F1), its
lightest neutral, and the input bar `surface1` (#C0C0C0) steps darker than the
tile instead of lighter; the ears and the caret are latte `peach` (#F66D2D).
The brand kit's `docs/design.md` is the standard here too: a light artifact is
latte, and there is no light *inverted* tile, because an inverted one already
carries its own colour.

`pounce-square.svg` / `pounce-square-inverted.svg` / `pounce-square-latte.svg` —
**the three marks' source of record**: the same geometry in a 100-unit
viewBox; the brand kit's `docs/design.md` is the standard they answer to. The
PNGs above render from them and the iconset from those, so a nebelung token that moves is
swapped here first, then rendered down. resvg is what the committed PNGs were
checked against; a different rasteriser will not land byte-for-byte on them.

```sh
nix run nixpkgs#resvg -- assets/pounce-square.svg assets/pounce-square.png
nix run nixpkgs#resvg -- assets/pounce-square-inverted.svg assets/pounce-square-inverted.png
nix run nixpkgs#resvg -- assets/pounce-square-latte.svg assets/pounce-square-latte.png
```

`pkgs/pounce/AppIcon.iconset/*.png` are mechanically scaled from
`pounce-square.png`; `build.sh` runs `iconutil` over them into the bundle's
`AppIcon.icns`. They live under `pkgs/pounce/` rather than here because the Nix
derivation sets `src = ./.` on that directory alone — this one is outside its
sandbox. Regenerate every slot with:

```sh
for pair in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 \
            128x128@2x:256 256x256:256 256x256@2x:512 512x512:512 512x512@2x:1024; do
  sips -s format png -Z "${pair#*:}" assets/pounce-square.png \
    --out "pkgs/pounce/AppIcon.iconset/icon_${pair%%:*}.png"
done
```

Keep the 2048 PNG master rather than upscaling a slot — `512x512@2x` already
wants 1024.

The master is deliberately flat and full-bleed — no inset, no drop shadow, no
gloss. macOS 26 adds all three itself when it draws any app icon, so baking
them in would double them; perch ships exactly this flat and renders with the
padding and depth you see in Finder. An Icon Composer `.icon` file is the only
way to control that pass per-layer, and no repo in the family has one.

The animated demo clip and the "a command is a file" illustration were dropped
in 2026-08 and have not come back. Re-render from the brand kit if a future
README wants them.

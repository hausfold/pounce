# assets

`pounce-square.png` / `pounce-square-inverted.png` — the app-icon mark
(2048²): peach cat-ears over a command-palette input bar. `-square` is the
dark-squircle version (light backgrounds); `-square-inverted` is the peach
squircle with a dark mark (dark backgrounds). Three
[nebelung](https://github.com/hausfold/nebelung) tokens, baked in as flat pixels
and not themed at runtime: `peach` (#F5B58E), `surface0` (#343434) for the tile,
`surface1` (#494949) for the input bar.

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

Keep the 2048 master rather than upscaling a slot — `512x512@2x` already wants
1024.

The tile is **full-bleed** — its squircle spans the whole canvas rather than
sitting inside Apple's ~824/1024 inset with a shadow. That is deliberate: perch
and trill ship the same way, and the three marks are meant to read as one set.
Insetting is a family-wide change, not a pounce one.

The README carries no imagery — the banner, the animated demo clip and the
"a command is a file" illustration were dropped in 2026-08. Re-render from the
brand kit if a future README wants one back.

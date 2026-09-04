# dev-app — the `prebuilt` input's empty placeholder

`bench try` overrides this input (`<layer>/pounce/prebuilt`) with a dir holding
a Pounce.app built from the local source branch (`ensure_pounce_dev_app`,
which re-signs the build with your codesigning identity so the palette's
Accessibility grants keep working during the feel-test). `nix/app-prebuilt.nix`
checks for a `Pounce.app` here:

- absent → the package fetches the CI-built, notarized release
  (`nix/release.nix`'s CI-owned pin);
- present → it wraps the dev build instead, same packaging.

Ship this dir with nothing in it but this README.

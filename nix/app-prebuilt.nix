{
  lib,
  stdenvNoCC,
  fetchurl,
  version,
  sha256,
  # The `prebuilt` flake input's store path: normally the empty ./nix/dev-app
  # placeholder, but `bench try` overrides it to a dir holding a locally-built
  # Pounce.app when feel-testing a source branch (see flake.nix / nix/dev-app).
  prebuilt,
}:

# Package the app half of Pounce so haus (and anyone) can install it through
# Nix instead of Homebrew — pounce's handle in the flake-lock chain.
#
# Normally we fetch the CI-built release tarball rather than compiling: the app
# is already Developer-ID signed + Apple notarized, which is exactly what a
# stable permissions grant wants. An ad-hoc store build's cdhash changes on
# every rebuild and takes the macOS Accessibility (TCC) grant with it — the
# reason haus's launcher room used to re-sign impurely, per machine. The
# tarball is arm64-only, matching the nix target.
#
# The one exception is `bench try` feel-testing a source branch: bench builds
# pounce from source (a plain swiftc build — pkgs/pounce/default.nix), re-signs
# it in your login session with a stable identity, and overrides `prebuilt` to
# that build, so we wrap that .app instead of the release. Same packaging.

let
  # bench points `prebuilt` at a dir containing a freshly-built Pounce.app; the
  # placeholder has none, so we fall back to the release tarball.
  useDev = builtins.pathExists "${prebuilt}/Pounce.app";
in

stdenvNoCC.mkDerivation {
  pname = "pounce-app";
  # Tag the dev build so its store path (and haus's bounce marker) differ from
  # the release — a rebuild that flips between the two bounces the daemon.
  version = if useDev then "${version}-dev" else version;

  src =
    if useDev then
      prebuilt
    else
      fetchurl {
        url = "https://github.com/hausfold/pounce/releases/download/v${version}/pounce-v${version}-macos.tar.gz";
        inherit sha256;
      };

  # `ditto` is the macOS-correct copy: the locally-built .app carries its own
  # signature, and a ditto copy preserves bundle contents + xattrs where plain
  # `cp` can drop them.
  unpackPhase = ''
    runHook preUnpack
    if [ -d "$src/Pounce.app" ]; then
      /usr/bin/ditto "$src/Pounce.app" ./Pounce.app   # dev build injected by bench
    else
      # The release tarball (unlike trill's zip) is tar, not PKZip — `ditto -x -k`
      # refuses it. Plain tar keeps every bundle file byte-identical, so the code
      # seal survives; the notarization staple ticket is a Gatekeeper artifact
      # and a nix-installed app carries no quarantine attribute for Gatekeeper
      # to read, so losing it costs nothing here.
      /usr/bin/tar -xzf "$src"
    fi
    runHook postUnpack
  '';

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    # The release tarball keeps a top-level dir named for the release
    # (`pounce-v<date>/Pounce.app`); a dev build injects Pounce.app at the
    # root. Find the bundle either way.
    APP="$(/usr/bin/find . -maxdepth 2 -name Pounce.app -type d | head -n 1)"
    [ -n "$APP" ] || { echo "no Pounce.app in $src" >&2; exit 1; }
    mkdir -p $out/Applications
    /usr/bin/ditto "$APP" $out/Applications/Pounce.app

    # `bin/pounce` is a symlink, never a copy: the app binary IS the CLI — one
    # executable serves the daemon and every client — and it is signed and
    # notarized as part of the bundle, so a copy sitting outside the .app would
    # be nested code torn out of the seal it was signed under. `ports` is a
    # plain script, installed the same way the from-source package
    # (pkgs/pounce) does, so haus can swap between the two packages cleanly.
    if [ -x "$out/Applications/Pounce.app/Contents/MacOS/pounce" ]; then
      mkdir -p $out/bin
      ln -s $out/Applications/Pounce.app/Contents/MacOS/pounce $out/bin/pounce
    else
      echo "Pounce.app has no Contents/MacOS/pounce executable" >&2; exit 1
    fi
    PORTS="$(/usr/bin/find . -maxdepth 2 -name ports -type f | head -n 1)"
    if [ -n "$PORTS" ]; then
      cp "$PORTS" $out/bin/ports
      chmod +x $out/bin/ports
    fi
    runHook postInstall
  '';

  # Don't let Nix strip or re-sign the signed bundle — any rewrite invalidates
  # the signature the permissions grant depends on.
  dontFixup = true;

  meta = {
    description = "A minimal dmenu-like picker for macOS (prebuilt release app)";
    homepage = "https://github.com/hausfold/pounce";
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}

import Foundation

// AppScanner's path predicates: which .app bundles on disk are things a person
// would actually launch. Pure string logic, so it's testable without touching
// the filesystem — and worth pinning, because the failure mode of getting it
// wrong is invisible (an app quietly missing from the palette, or a framework's
// internal helper quietly squatting in it).

func runAppScannerTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // ── nestedInBundle: the candidate lives inside another bundle ───────────

    // The case that motivated it: Sparkle's updater, in a project's own build
    // output, where no /library/ or /deriveddata/ path guard reaches it.
    check(AppScanner.nestedInBundle(
        path: "/Users/x/proj/build/Build/Products/Debug/Sparkle.framework/Versions/B/Updater.app"),
        "framework-internal app is nested")
    check(AppScanner.nestedInBundle(
        path: "/Users/x/proj/build/SourcePackages/Sparkle.xcframework/macos-arm64/Sparkle.framework/Versions/B/Updater.app"),
        ".xcframework is nested (it does not contain the substring \".framework/\")")
    check(AppScanner.nestedInBundle(path: "/Applications/Foo.app/Contents/Library/Bar.app"),
          "app inside an app is nested")
    check(AppScanner.nestedInBundle(path: "/Applications/Foo.app/Contents/PlugIns/Ext.appex/Helper.app"),
          "app inside an appex is nested")
    // Case-insensitive: the volume is, so the predicate must be too.
    check(AppScanner.nestedInBundle(path: "/Applications/Foo.APP/Contents/Helpers/Bar.app"),
          "container extension matches case-insensitively")

    check(!AppScanner.nestedInBundle(path: "/Applications/Safari.app"),
          "a top-level app is not nested")
    check(!AppScanner.nestedInBundle(path: "/Users/x/Applications/Firefox.app"),
          "a top-level app in ~/Applications is not nested")
    // The trailing "/" anchors each extension to a whole path component, so a
    // directory merely *named* like a bundle doesn't swallow its contents.
    check(!AppScanner.nestedInBundle(path: "/Users/x/v1.0.appdir/Foo.app"),
          "a directory named like a bundle is not a container")
    check(!AppScanner.nestedInBundle(path: "/Users/x/my.framework.notes/Foo.app"),
          "an extension mid-component is not a container")
    // The candidate's own ".app" must never match — only ancestors count.
    check(!AppScanner.nestedInBundle(path: "/Applications/Xcode.app"),
          "the candidate's own extension is not an ancestor")

    // ── spotlightAccepts: the full Spotlight-source filter ──────────────────

    check(AppScanner.spotlightAccepts(path: "/Applications/Safari.app"), "accepts a real app")
    check(AppScanner.spotlightAccepts(path: "/Users/x/Applications/Firefox.app"),
          "accepts an app in ~/Applications")
    check(!AppScanner.spotlightAccepts(path: "/Applications/Foo"), "rejects a non-.app path")
    check(!AppScanner.spotlightAccepts(
        path: "/Users/x/proj/build/Sparkle.framework/Versions/B/Updater.app"),
        "rejects a framework-internal app outside any guarded directory")
    check(!AppScanner.spotlightAccepts(path: "/Library/Frameworks/Foo.framework/Bar.app"),
          "rejects framework internals under /Library")
    check(!AppScanner.spotlightAccepts(path: "/nix/store/abc-pounce/Applications/Pounce.app"),
          "rejects the nix store (the ~/Applications symlink is the launch path)")
    check(!AppScanner.spotlightAccepts(path: "/Users/x/.Trash/Old.app"), "rejects the trash")
    check(!AppScanner.spotlightAccepts(
        path: "/Users/x/Library/Developer/Xcode/DerivedData/P-abc/Build/Products/Debug/P.app"),
        "rejects build artifacts")

    if failures == 0 { print("ok — all AppScanner path-filter tests passed") }
    return failures
}

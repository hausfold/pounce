import Foundation

func runCommandRegistryTests() -> Int {
    var failed = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failed += 1
        }
    }

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "pounce-command-registry-\(UUID().uuidString)",
        isDirectory: true)
    let builtin = root.appendingPathComponent("builtin", isDirectory: true)
    let config = root.appendingPathComponent("config", isDirectory: true)

    do {
        try fm.createDirectory(at: builtin, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: config.appendingPathComponent("pounce/commands", isDirectory: true),
            withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try """
        #!/bin/bash
        # pounce: name = Popular Apps
        # pounce: description = Pick an application
        # pounce: icon = app.badge
        # pounce: submenu = true
        """.write(to: builtin.appendingPathComponent("popular-apps.sh"),
                  atomically: true, encoding: .utf8)
        try "Safari\tcom.apple.Safari\n".write(
            to: builtin.appendingPathComponent("popular-apps.tsv"),
            atomically: true, encoding: .utf8)
        try "not a command\n".write(
            to: builtin.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        try "#!/bin/bash\n".write(
            to: builtin.appendingPathComponent("fallback.sh"),
            atomically: true, encoding: .utf8)

        let registry = CommandRegistry(
            env: [
                "POUNCE_BUILTIN_DIR": builtin.path,
                "XDG_CONFIG_HOME": config.path,
            ],
            home: root.path)
        registry.refresh()

        check(registry.entries.map(\.id) == ["fallback", "popular-apps"],
              "only .sh files in command directories are registered")
        check(registry.entries.first(where: { $0.id == "popular-apps" })?.name == "Popular Apps",
              "a .sh command still reads its metadata")
        check(registry.entries.first(where: { $0.id == "popular-apps" })?.submenu == true,
              "a .sh command keeps submenu metadata")
        check(registry.entries.first(where: { $0.id == "fallback" })?.name == "fallback",
              "a headerless .sh command still falls back to its filename")
        check(registry.scriptPath(for: "popular-apps.tsv") == nil,
              "support data cannot be resolved as a runnable command")
    } catch {
        check(false, "command registry fixture setup succeeds: \(error)")
    }

    if failed == 0 { print("ok — all CommandRegistry tests passed") }
    return failed
}

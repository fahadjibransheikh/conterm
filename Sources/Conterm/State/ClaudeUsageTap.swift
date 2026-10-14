import Foundation

/// Feeds the usage-limits widget from Claude Code's own status line data.
///
/// Claude Code hands its status line command a JSON object on stdin whose
/// documented `rate_limits` field carries the 5-hour and weekly windows
/// (`used_percentage`, `resets_at` in epoch seconds) for Pro and Max plans
/// — https://code.claude.com/docs/en/statusline. Installing points
/// `statusLine` in `~/.claude/settings.json` at a small script that saves
/// that field to `~/.conterm/claude-rate-limits.json` and then runs the
/// user's previous status line command unchanged, so their status line
/// looks the same. No credentials and no network: Conterm only reads the
/// file. Uninstall puts the original `statusLine` back exactly.
@MainActor
enum ClaudeUsageTap {
    private static let sentinel = "# conterm"
    nonisolated static var dir: String { "\(InstanceState.userHome)/.conterm" }
    nonisolated static var scriptPath: String { "\(dir)/claude-statusline.sh" }
    /// The user's previous `statusLine` object, verbatim, for uninstall.
    nonisolated static var originalPath: String { "\(dir)/claude-statusline.orig.json" }
    /// Just its command, for the script to run.
    nonisolated static var originalCommandPath: String { "\(dir)/claude-statusline.orig" }
    nonisolated static var dataPath: String { "\(dir)/claude-rate-limits.json" }
    private static let command = "sh \"$HOME/.conterm/claude-statusline.sh\" \(sentinel)"

    nonisolated static let script = #"""
    #!/bin/sh
    # Conterm usage-limits tap (managed; rewritten at launch).
    # Saves Claude Code's rate_limits for Conterm's widget, then runs the
    # status line command you had before, unchanged.
    dir="$HOME/.conterm"
    in=$(cat)
    tmp="$dir/claude-rate-limits.json.$$"
    if printf '%s' "$in" | /usr/bin/plutil -extract rate_limits json -o "$tmp" - 2>/dev/null; then
        chmod 600 "$tmp" && mv -f "$tmp" "$dir/claude-rate-limits.json"
    else
        rm -f "$tmp"
    fi
    if [ -s "$dir/claude-statusline.orig" ]; then
        printf '%s' "$in" | exec sh -c "$(cat "$dir/claude-statusline.orig")"
    fi
    exit 0
    """#

    static var isInstalled: Bool {
        let line = AgentHooks.readJSON(AgentHooks.claude)?["statusLine"] as? [String: Any]
        return (line?["command"] as? String)?.contains(sentinel) == true
    }

    static func install() {
        let spec = AgentHooks.claude
        writeScript()
        guard !isInstalled else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (spec.settingsPath as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        if fm.fileExists(atPath: spec.settingsPath), !fm.fileExists(atPath: spec.backupPath) {
            try? fm.copyItem(atPath: spec.settingsPath, toPath: spec.backupPath)
        }
        var root = AgentHooks.readJSON(spec) ?? [:]
        let original = root["statusLine"] as? [String: Any]
        // Remember what was there (or that nothing was) before replacing it.
        let saved = (try? JSONSerialization.data(withJSONObject: original ?? [:])) ?? Data("{}".utf8)
        try? saved.write(to: URL(fileURLWithPath: originalPath), options: .atomic)
        try? ((original?["command"] as? String) ?? "")
            .write(toFile: originalCommandPath, atomically: true, encoding: .utf8)
        // Keep the user's other keys (padding, refreshInterval, …).
        var line = original ?? [:]
        line["type"] = "command"
        line["command"] = command
        root["statusLine"] = line
        AgentHooks.writeJSON(root, spec)
    }

    static func uninstall() {
        let spec = AgentHooks.claude
        if isInstalled, var root = AgentHooks.readJSON(spec) {
            let saved = (try? Data(contentsOf: URL(fileURLWithPath: originalPath)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if saved.isEmpty { root.removeValue(forKey: "statusLine") }
            else { root["statusLine"] = saved }
            AgentHooks.writeJSON(root, spec)
        }
        for path in [scriptPath, originalPath, originalCommandPath, dataPath] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// At launch: keep the script current while the tap is installed.
    static func refreshIfInstalled() {
        if isInstalled { writeScript() }
    }

    private static func writeScript() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if (try? String(contentsOfFile: scriptPath, encoding: .utf8)) == script { return }
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    }

    /// `{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{…}}`
    nonisolated static func parse(_ data: Data) -> UsageLimits? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let w = obj[key] as? [String: Any],
                  let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return UsageWindow(usedPercent: used, resetsAt: reset)
        }
        let limits = UsageLimits(fiveHour: window("five_hour"), weekly: window("seven_day"))
        return limits.fiveHour == nil && limits.weekly == nil ? nil : limits
    }

    /// The last reading the tap saved, dated by when it was written.
    nonisolated static func read() -> UsageLimits? {
        guard let data = FileManager.default.contents(atPath: dataPath),
              var limits = parse(data) else { return nil }
        limits.observedAt = (try? FileManager.default.attributesOfItem(atPath: dataPath))?[.modificationDate] as? Date
        return limits
    }
}

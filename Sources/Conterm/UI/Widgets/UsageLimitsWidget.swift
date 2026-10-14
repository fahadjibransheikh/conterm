import AppKit
import SwiftUI

/// One rate-limit window: how much of it is spent and when it rolls over.
struct UsageWindow: Equatable {
    var usedPercent: Double
    var resetsAt: Date?

    /// A window whose reset time has passed is fresh again, even if the
    /// last reading we hold was taken before the rollover.
    func used(at now: Date = Date()) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return min(max(usedPercent, 0), 100)
    }
}

/// The two plan limits Claude and Codex both enforce: a rolling 5-hour
/// window and a weekly one. Account-wide, so every pane shares them.
struct UsageLimits: Equatable {
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    /// When the source recorded this reading, if it says (Codex events do).
    var observedAt: Date?
}

/// Polls the 5-hour and weekly plan limits for the agent CLIs that have a
/// live session in some pane (`AgentCenter.openTools`).
///
/// • Claude: the same endpoint Claude Code's `/usage` reads, authorised
///   with the OAuth token Claude Code keeps in the login keychain. The
///   token is read through `/usr/bin/security` — the item's ACL trusts that
///   binary, so no keychain prompt — and never refreshed or written here:
///   an expired token just leaves the last reading in place.
/// • Codex: no network. Codex logs a `token_count` event carrying its
///   `rate_limits` into the session rollout after each turn; the newest one
///   is the current reading.
@MainActor
final class UsageLimitsModel: ObservableObject {
    static let shared = UsageLimitsModel()

    @Published private(set) var limits: [AgentTool: UsageLimits] = [:]
    @Published private(set) var updatedAt: [AgentTool: Date] = [:]
    /// Providers whose last read failed: their numbers are the previous
    /// reading, shown dimmed, never passed off as current.
    @Published private(set) var stale: Set<AgentTool> = []
    /// Set while the Claude endpoint has us rate-limited (a 429), so the
    /// widget says so instead of a bare dash.
    @Published private(set) var claudeLimitedUntil: Date?
    /// `claudeLimitedUntil` while it's still ahead; a passed one is moot.
    var claudeRateLimitedUntil: Date? {
        claudeLimitedUntil.flatMap { $0 > Date() ? $0 : nil }
    }
    /// The retry time, with the date when it's more than 12 hours out.
    static func retryTime(_ d: Date) -> String {
        d.timeIntervalSinceNow > 43_200 ? d.formatted(date: .abbreviated, time: .shortened)
                                        : d.formatted(date: .omitted, time: .shortened)
    }

    private var timer: Timer?
    private var inFlight: Set<AgentTool> = []
    /// Earliest next Claude fetch: the usage endpoint is shared with Claude
    /// Code's own /usage and rate-limits hard, so app activations and agent
    /// churn must not each cost a request, and a 429's Retry-After is obeyed.
    private var claudeNotBefore = Date.distantPast
    nonisolated static let claudeMinInterval: TimeInterval = 180
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?

    private init() {
        let nc = NotificationCenter.default
        activeObs = nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
        inactiveObs = nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        if NSApp?.isActive ?? true { start() }
    }

    private func start() {
        guard timer == nil else { return }
        // Limits move by a few percent per turn; 3 min keeps the pill
        // honest without hammering the usage endpoint.
        let t = Timer(timeInterval: 180, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }
    private func stop() { timer?.invalidate(); timer = nil }

    /// Re-read every open provider. Also called when a provider's first
    /// session appears, so the pill fills in without waiting for a tick.
    func refresh() {
        // The timer outlives the widget; only poll while it's enabled.
        guard (InstanceState.defaults.stringArray(forKey: "conterm.enabledWidgets") ?? [])
            .contains(WidgetKind.usageLimits.rawValue) else { return }
        for tool in AgentCenter.shared.openTools where Self.providers.contains(tool) {
            guard !inFlight.contains(tool) else { continue }
            if tool == .claude {
                // An isolated (dev) instance shares the real token and the
                // endpoint's rate limit; keep it off the network.
                guard !InstanceState.isolated, Date() >= claudeNotBefore else { continue }
                claudeNotBefore = Date().addingTimeInterval(Self.claudeMinInterval)
            }
            inFlight.insert(tool)
            Task.detached(priority: .utility) {
                var retryAfter: TimeInterval?
                let read: UsageLimits?
                if tool == .claude {
                    (read, retryAfter) = await Self.fetchClaude()
                } else {
                    read = Self.readCodex()
                }
                await MainActor.run {
                    self.inFlight.remove(tool)
                    if let retryAfter {
                        self.claudeNotBefore = max(self.claudeNotBefore,
                                                   Date().addingTimeInterval(retryAfter))
                        self.claudeLimitedUntil = self.claudeNotBefore
                    }
                    guard let read else { self.stale.insert(tool); return }
                    if tool == .claude { self.claudeLimitedUntil = nil }
                    self.stale.remove(tool)
                    if self.limits[tool] != read { self.limits[tool] = read }
                    self.updatedAt[tool] = read.observedAt ?? Date()
                }
            }
        }
    }

    /// The agents this widget can report on, in display order.
    static let providers: [AgentTool] = [.claude, .codex]

    // MARK: Claude

    /// No cache or cookie jar for a bearer-token request.
    nonisolated private static let session = URLSession(configuration: .ephemeral)

    /// The reading, plus how long to back off when the endpoint said 429.
    nonisolated private static func fetchClaude() async -> (UsageLimits?, TimeInterval?) {
        guard let token = claudeAccessToken(),
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return (nil, nil) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            guard http?.statusCode == 200 else {
                clog("usage limits: claude HTTP \(http?.statusCode ?? -1)")
                let backoff = http?.statusCode == 429
                    ? retryDelay(http?.value(forHTTPHeaderField: "Retry-After")) : nil
                return (nil, backoff)
            }
            return (parseClaude(data), nil)
        } catch {
            clog("usage limits: claude fetch failed: \(error.localizedDescription)")
            return (nil, nil)
        }
    }

    /// Seconds from a 429's Retry-After (delta-seconds form), between the
    /// normal spacing and a day; 10 min when missing or unparseable, so a
    /// 429 never means "retry next tick".
    nonisolated static func retryDelay(_ header: String?) -> TimeInterval {
        guard let s = header?.trimmingCharacters(in: .whitespaces),
              let secs = TimeInterval(s), secs.isFinite else { return 600 }
        return min(max(secs, claudeMinInterval), 86_400)
    }

    /// Claude Code's OAuth access token, or nil when it's missing or past
    /// its expiry (Claude Code refreshes it on its next request).
    nonisolated private static func claudeAccessToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // A locked keychain or an ACL prompt would block the read forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let ms = oauth["expiresAt"] as? Double,
           Date(timeIntervalSince1970: ms / 1000) <= Date() { return nil }
        return token
    }

    /// `{"five_hour":{"utilization":21.0,"resets_at":"2026-…+00:00"},"seven_day":{…}}`
    nonisolated static func parseClaude(_ data: Data) -> UsageLimits? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let w = obj[key] as? [String: Any],
                  let used = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(usedPercent: used, resetsAt: parseISODate(w["resets_at"] as? String))
        }
        let limits = UsageLimits(fiveHour: window("five_hour"), weekly: window("seven_day"))
        return limits.fiveHour == nil && limits.weekly == nil ? nil : limits
    }

    nonisolated static func parseISODate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: Codex

    nonisolated private static func readCodex() -> UsageLimits? {
        let root = URL(fileURLWithPath: InstanceState.userHome)
            .appendingPathComponent(".codex/sessions")
        for path in newestRollouts(under: root) {
            guard let h = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? h.close() }
            // A token_count lands after every turn, so the tail holds the latest.
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
            guard let data = try? h.readToEnd(),
                  !data.isEmpty else { continue }
            // Lossy decode: the tail can start mid-character; that partial
            // first line just fails to parse.
            let text = String(decoding: data, as: UTF8.self)
            if let limits = parseCodexRollout(text) { return limits }
        }
        return nil
    }

    /// Rollouts live at `sessions/YYYY/MM/DD/rollout-*.jsonl`. Looks at the
    /// newest few day folders only, newest file first.
    /// shortcut: ignores $CODEX_HOME, add it if anyone relocates ~/.codex.
    nonisolated private static func newestRollouts(under root: URL) -> [String] {
        let fm = FileManager.default
        func children(_ dir: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted(by: >).map { "\(dir)/\($0)" }
        }
        var days: [String] = []
        outer: for year in children(root.path) {
            for month in children(year) {
                for day in children(month) {
                    days.append(day)
                    if days.count == 3 { break outer }
                }
            }
        }
        let files = days.flatMap(children).filter { $0.hasSuffix(".jsonl") }
        func mtime(_ p: String) -> Date {
            ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast
        }
        return files.map { ($0, mtime($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Newest `token_count` event with `rate_limits` in a rollout chunk.
    /// `primary` is the 5-hour window and `secondary` the weekly one, but
    /// `window_minutes` decides when present.
    nonisolated static func parseCodexRollout(_ text: String) -> UsageLimits? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }
            let at = parseISODate(obj["timestamp"] as? String) ?? Date()
            var limits = UsageLimits()
            for (key, fallbackIsWeekly) in [("primary", false), ("secondary", true)] {
                guard let w = rl[key] as? [String: Any],
                      let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                var reset: Date?
                if let ts = (w["resets_at"] as? NSNumber)?.doubleValue {
                    reset = Date(timeIntervalSince1970: ts)
                } else if let secs = (w["resets_in_seconds"] as? NSNumber)?.doubleValue {
                    reset = at.addingTimeInterval(secs)  // older Codex builds
                }
                let window = UsageWindow(usedPercent: used, resetsAt: reset)
                let minutes = (w["window_minutes"] as? NSNumber)?.intValue
                if minutes.map({ $0 > 300 }) ?? fallbackIsWeekly {
                    limits.weekly = window
                } else {
                    limits.fiveHour = window
                }
            }
            limits.observedAt = parseISODate(obj["timestamp"] as? String)
            if limits.fiveHour != nil || limits.weekly != nil { return limits }
        }
        return nil
    }
}

// MARK: - Widget

struct UsageLimitsWidget: View {
    var compact: Bool
    @ObservedObject private var model = UsageLimitsModel.shared
    @ObservedObject private var agents = AgentCenter.shared
    @AppStorage("conterm.usageLimitsWidget.selected", store: InstanceState.defaults)
    private var selectedRaw = AgentTool.claude.rawValue
    @State private var showingPopover = false

    private var open: [AgentTool] {
        UsageLimitsModel.providers.filter(agents.openTools.contains)
    }
    private var selected: AgentTool? {
        open.first { $0.rawValue == selectedRaw } ?? open.first
    }

    var body: some View {
        Group {
            if let tool = selected {
                WidgetShell(compact: compact, help: help(tool), onTap: {
                    showingPopover.toggle()
                    SoundEffects.shared.play(.toggle)
                }) {
                    HStack(spacing: Theme.ui(5)) {
                        ForEach(open, id: \.self) { t in
                            if open.count > 1 {
                                // Its own button so a click on a mark switches
                                // provider instead of opening the popover.
                                Button { selectedRaw = t.rawValue } label: {
                                    AgentMark(tool: t, size: Theme.ui(11))
                                        .opacity(t == tool ? 1 : 0.35)
                                }
                                .buttonStyle(.plain)
                                .help("Show \(t.displayName) limits")
                            } else {
                                AgentMark(tool: t, size: Theme.ui(11))
                            }
                        }
                        if model.limits[tool] == nil, let until = limitedUntil(tool) {
                            Text("limited · \(UsageLimitsModel.retryTime(until))")
                                .font(.system(size: Theme.ui(10.5), weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            reading(model.limits[tool]?.fiveHour, label: "5h")
                            widgetChipDivider()
                            reading(model.limits[tool]?.weekly, label: "wk")
                        }
                    }
                    .opacity(model.stale.contains(tool) ? 0.5 : 1)
                }
                .dropPopover(isPresented: $showingPopover) {
                    UsageLimitsPopover(tools: open, model: model)
                }
            }
        }
        .onChange(of: agents.openTools) { model.refresh() }
    }

    private func reading(_ w: UsageWindow?, label: String) -> some View {
        HStack(spacing: Theme.ui(3)) {
            Text(label)
                .font(.system(size: Theme.ui(9.5), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Text(w.map { "\(Int($0.used().rounded()))%" } ?? "–")
                .font(.system(size: Theme.ui(11), weight: .semibold, design: .rounded))
                .foregroundStyle(w.map { usageColor($0.used()) } ?? Theme.textSecondary)
                .monospacedDigit()
        }
    }

    private func limitedUntil(_ tool: AgentTool) -> Date? {
        tool == .claude ? model.claudeRateLimitedUntil : nil
    }

    private func help(_ tool: AgentTool) -> String {
        let limited = limitedUntil(tool).map {
            " · rate limited, retrying at \(UsageLimitsModel.retryTime($0))"
        } ?? ""
        guard let l = model.limits[tool] else {
            return "\(tool.displayName) usage limits — "
                + (model.stale.contains(tool) ? "unavailable" : "loading") + limited
        }
        func part(_ name: String, _ w: UsageWindow?) -> String? {
            w.map { "\(name) \(Int($0.used().rounded()))%" + resetPhrase($0, prefix: ", resets ") }
        }
        let head = model.stale.contains(tool) ? "\(tool.displayName) (unavailable, last reading)"
                                              : tool.displayName
        return ([head] + [part("5-hour", l.fiveHour), part("weekly", l.weekly)]
            .compactMap { $0 }).joined(separator: " · ") + limited
    }
}

private func usageColor(_ used: Double) -> Color {
    used >= 90 ? .red : used >= 75 ? Theme.warning : Theme.textPrimary
}

private func resetPhrase(_ w: UsageWindow, prefix: String) -> String {
    guard let at = w.resetsAt, at > Date() else { return "" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return prefix + f.localizedString(for: at, relativeTo: Date())
}

private struct UsageLimitsPopover: View {
    var tools: [AgentTool]
    @ObservedObject var model: UsageLimitsModel

    var body: some View {
        WidgetPopoverChrome(title: "Usage limits", width: 270, trailing: { EmptyView() }) {
            VStack(alignment: .leading, spacing: Theme.ui(12)) {
                ForEach(tools, id: \.self) { tool in
                    VStack(alignment: .leading, spacing: Theme.ui(7)) {
                        HStack(spacing: Theme.ui(6)) {
                            AgentMark(tool: tool, size: Theme.ui(13))
                            Text(tool.displayName)
                                .font(.system(size: Theme.ui(11.5), weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if tool == .claude, let until = model.claudeRateLimitedUntil {
                                Text("rate limited · retry \(UsageLimitsModel.retryTime(until))")
                                    .font(.system(size: Theme.ui(9.5), weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.warning)
                            } else if model.stale.contains(tool) {
                                Text("unavailable")
                                    .font(.system(size: Theme.ui(9.5), weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.warning)
                            }
                            if let at = model.updatedAt[tool] {
                                Text(at, style: .relative)
                                    .font(.system(size: Theme.ui(9.5), design: .rounded))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        let l = model.limits[tool]
                        bar("5-hour", l?.fiveHour, tint: tool.glowColor)
                        bar("Weekly", l?.weekly, tint: tool.glowColor)
                        if l == nil, !(tool == .claude && model.claudeRateLimitedUntil != nil) {
                            Text(tool == .claude
                                 ? "No reading yet — needs a Claude Code login."
                                 : "No reading yet — Codex logs limits after its first turn.")
                                .font(.system(size: Theme.ui(9.5), design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.ui(14))
            .padding(.vertical, Theme.ui(12))
        }
    }

    private func bar(_ label: String, _ w: UsageWindow?, tint: Color) -> some View {
        let used = w?.used() ?? 0
        return VStack(alignment: .leading, spacing: Theme.ui(3)) {
            HStack {
                Text(label)
                    .font(.system(size: Theme.ui(10.5), design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(w.map { "\(Int($0.used().rounded()))%" + resetPhrase($0, prefix: " · resets ") } ?? "–")
                    .font(.system(size: Theme.ui(10.5), weight: .semibold, design: .rounded))
                    .foregroundStyle(w == nil ? Theme.textSecondary : usageColor(used))
                    .monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.stroke)
                    Capsule().fill(used >= 75 ? usageColor(used) : tint)
                        .frame(width: g.size.width * used / 100)
                }
            }
            .frame(height: Theme.ui(4))
        }
    }
}

import Foundation
import Testing
@testable import Conterm

/// Parsing the two usage-limit sources: Claude's OAuth usage response and
/// the `token_count` events Codex writes into its session rollout.
struct UsageLimitsTests {

    @Test func claudeStatusLineRateLimitsParse() throws {
        // What ClaudeUsageTap saves: the status line input's `rate_limits`.
        let json = #"{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}"#
        let l = try #require(ClaudeUsageTap.parse(Data(json.utf8)))
        #expect(l.fiveHour?.usedPercent == 23.5)
        #expect(l.weekly?.usedPercent == 41.2)
        #expect(l.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_738_425_600))
        // Each window may be absent on its own.
        let only = try #require(ClaudeUsageTap.parse(Data(#"{"seven_day":{"used_percentage":5}}"#.utf8)))
        #expect(only.fiveHour == nil && only.weekly?.resetsAt == nil)
        #expect(ClaudeUsageTap.parse(Data("{}".utf8)) == nil)
        #expect(ClaudeUsageTap.parse(Data("not json".utf8)) == nil)
    }

    @Test func codexRolloutTakesTheNewestTokenCount() throws {
        // Shape from codex-rs protocol.rs: TokenCountEvent { info, rate_limits }.
        let text = [
            #"{"timestamp":"2026-10-14T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1791990000},"secondary":{"used_percent":40.0,"window_minutes":10080,"resets_at":1792216800}}}}"#,
            #"{"timestamp":"2026-10-14T10:05:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"done"}}"#,
            #"{"timestamp":"2026-10-14T10:06:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.5,"window_minutes":300,"resets_at":1791990000},"secondary":{"used_percent":41.0,"window_minutes":10080,"resets_at":1792216800},"credits":null}}}"#,
            #"{"timestamp":"2026-10-14T10:07:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":null}}"#,
            "{truncated partial line",
        ].joined(separator: "\n")
        let l = try #require(UsageLimitsModel.parseCodexRollout(text))
        #expect(l.fiveHour?.usedPercent == 12.5)
        #expect(l.weekly?.usedPercent == 41)
        #expect(l.weekly?.resetsAt == Date(timeIntervalSince1970: 1_792_216_800))
        // The reading is dated by its event, not by when we read it.
        #expect(l.observedAt == UsageLimitsModel.parseISODate("2026-10-14T10:06:00.000Z"))
    }

    @Test func codexWindowMinutesDecideTheSlot() throws {
        // A weekly-only snapshot reported as primary still lands in `weekly`.
        let line = #"{"timestamp":"2026-10-14T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5,"window_minutes":10080,"resets_in_seconds":60}}}}"#
        let l = try #require(UsageLimitsModel.parseCodexRollout(line))
        #expect(l.fiveHour == nil)
        #expect(l.weekly?.usedPercent == 5)
        #expect(l.weekly?.resetsAt == UsageLimitsModel.parseISODate("2026-10-14T10:01:00Z"))
    }

    @Test func passedResetReadsAsFresh() {
        let w = UsageWindow(usedPercent: 80, resetsAt: Date(timeIntervalSince1970: 100))
        #expect(w.used(at: Date(timeIntervalSince1970: 50)) == 80)
        #expect(w.used(at: Date(timeIntervalSince1970: 100)) == 0)
    }
}

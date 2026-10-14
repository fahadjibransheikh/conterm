import Foundation
import Testing
@testable import Conterm

/// Parsing the two usage-limit sources: Claude's OAuth usage response and
/// the `token_count` events Codex writes into its session rollout.
struct UsageLimitsTests {

    @Test func claudeUsageResponseParses() throws {
        let json = #"{"five_hour":{"utilization":21.0,"resets_at":"2026-10-14T15:00:00.524003+00:00"},"seven_day":{"utilization":64.5,"resets_at":"2026-10-17T06:00:00+00:00"},"seven_day_opus":null}"#
        let l = try #require(UsageLimitsModel.parseClaude(Data(json.utf8)))
        #expect(l.fiveHour?.usedPercent == 21)
        #expect(l.weekly?.usedPercent == 64.5)
        // Six-digit fractional seconds must not defeat the date parse.
        #expect(l.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_791_990_000.524))
        #expect(l.weekly?.resetsAt == Date(timeIntervalSince1970: 1_792_216_800))
    }

    @Test func retryAfterIsObeyedWithAFloor() {
        #expect(UsageLimitsModel.retryDelay("3465") == 3465)
        // Never sooner than the normal spacing, and a safe default when absent.
        #expect(UsageLimitsModel.retryDelay("5") == UsageLimitsModel.claudeMinInterval)
        #expect(UsageLimitsModel.retryDelay(nil) == 600)
        #expect(UsageLimitsModel.retryDelay("Wed, 21 Oct 2026 07:28:00 GMT") == 600)
    }

    @Test func claudeResponseWithoutWindowsIsNil() {
        #expect(UsageLimitsModel.parseClaude(Data(#"{"five_hour":null}"#.utf8)) == nil)
        #expect(UsageLimitsModel.parseClaude(Data("not json".utf8)) == nil)
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

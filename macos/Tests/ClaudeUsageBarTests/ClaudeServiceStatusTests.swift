import XCTest
@testable import ClaudeUsageBar

/// Pure-value tests for the domain types backing the Claude service-status indicator.
/// Covers severity ordering, rolled-up severity, forgiving init, and the substring filter.
final class ClaudeServiceStatusTests: XCTestCase {

    func testSeverityOrdering() {
        XCTAssertLessThan(ClaudeServiceStatus.operational.severity,
                          ClaudeServiceStatus.degradedPerformance.severity)
        XCTAssertLessThan(ClaudeServiceStatus.degradedPerformance.severity,
                          ClaudeServiceStatus.partialOutage.severity)
        XCTAssertLessThan(ClaudeServiceStatus.partialOutage.severity,
                          ClaudeServiceStatus.majorOutage.severity)
        // underMaintenance is treated as operational in v1
        XCTAssertEqual(ClaudeServiceStatus.operational.severity,
                       ClaudeServiceStatus.underMaintenance.severity)
    }

    func testRolledUpReturnsMaxSeverity() {
        let mixed: [ClaudeServiceStatus] = [.majorOutage, .operational, .partialOutage]
        XCTAssertEqual(mixed.rolledUp(), .majorOutage)
    }

    func testRolledUpAllOperational() {
        let allGood: [ClaudeServiceStatus] = [.operational, .operational]
        XCTAssertEqual(allGood.rolledUp(), .operational)
    }

    func testRolledUpEmptySequenceIsOperational() {
        let empty: [ClaudeServiceStatus] = []
        XCTAssertEqual(empty.rolledUp(), .operational)
    }

    func testForgivingInitWithKnownString() {
        XCTAssertEqual(ClaudeServiceStatus(forgiving: "major_outage"), .majorOutage)
        XCTAssertEqual(ClaudeServiceStatus(forgiving: "operational"), .operational)
        XCTAssertEqual(ClaudeServiceStatus(forgiving: "under_maintenance"), .underMaintenance)
    }

    func testForgivingInitWithUnknownStringDefaultsToOperational() {
        XCTAssertEqual(ClaudeServiceStatus(forgiving: "completely_made_up_state"), .operational)
        XCTAssertEqual(ClaudeServiceStatus(forgiving: nil), .operational)
        XCTAssertEqual(ClaudeServiceStatus(forgiving: ""), .operational)
    }

    func testFilterSubstringMatchCaseInsensitive() {
        let filter = StatusComponentFilter(substrings: ["Claude API"])
        let component = StatusComponent(id: "1", name: "Claude API (api.anthropic.com)", status: .operational)
        XCTAssertTrue(filter.matches(component))
    }

    func testFilterSubstringExcludesUnrelatedComponent() {
        let filter = StatusComponentFilter(substrings: ["Claude API"])
        let component = StatusComponent(id: "2", name: "claude.ai", status: .operational)
        XCTAssertFalse(filter.matches(component))
    }

    func testFilterDefaultMatchesLiveComponentNames() {
        let filter = StatusComponentFilter.default
        let names = [
            "claude.ai",
            "Claude API (api.anthropic.com)",
            "Claude Code",
            "Claude Console (platform.claude.com)",
            "Claude Cowork",
            "Claude for Government"
        ]
        let matched = names.filter { name in
            filter.matches(StatusComponent(id: name, name: name, status: .operational))
        }
        // The default filter (Claude API + claude.ai + Claude Code) should match exactly 3 of the 6 names.
        XCTAssertEqual(matched.sorted(), [
            "Claude API (api.anthropic.com)",
            "Claude Code",
            "claude.ai"
        ].sorted())
    }

    func testSnapshotMakeAppliesFilterAndRollup() {
        let summary = StatusPageSummary(
            components: [
                StatusComponent(id: "a", name: "claude.ai", status: .operational),
                StatusComponent(id: "b", name: "Claude API", status: .partialOutage),
                StatusComponent(id: "c", name: "Unrelated Service", status: .majorOutage)
            ],
            incidents: []
        )
        let snap = StatusSnapshot.make(from: summary, filter: .default, now: Date(timeIntervalSince1970: 0))
        // The unrelated component is excluded, so the rollup is partialOutage (not majorOutage).
        XCTAssertEqual(snap.rollup, .partialOutage)
        XCTAssertEqual(snap.allMonitoredComponents.count, 2)
        XCTAssertEqual(snap.impactedComponents.map(\.id), ["b"])
    }

    func testSnapshotMakeScopesActiveIncidentsToMonitoredComponents() {
        let summary = StatusPageSummary(
            components: [
                StatusComponent(id: "a", name: "Claude API", status: .degradedPerformance),
                StatusComponent(id: "c", name: "Console", status: .majorOutage)
            ],
            incidents: [
                // Touches only the unmonitored "Console" component — must be filtered out even
                // though it sorts first, so the popover never shows its name for a rollup that
                // is actually caused by the monitored "Claude API" degradation.
                StatusIncident(
                    id: "unrelated",
                    name: "Console outage",
                    status: "investigating",
                    impact: "critical",
                    componentIds: ["c"]
                ),
                StatusIncident(
                    id: "relevant",
                    name: "API degraded",
                    status: "investigating",
                    impact: "minor",
                    componentIds: ["a"]
                )
            ]
        )
        let snap = StatusSnapshot.make(from: summary, filter: .default, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(snap.activeIncidents.map(\.id), ["relevant"])
    }

    func testSnapshotMakeKeepsIncidentWithNoComponentListAsUnscoped() {
        let summary = StatusPageSummary(
            components: [
                StatusComponent(id: "a", name: "Claude API", status: .operational)
            ],
            incidents: [
                StatusIncident(id: "x", name: "Legacy incident", status: "investigating", impact: "minor")
            ]
        )
        let snap = StatusSnapshot.make(from: summary, filter: .default, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(snap.activeIncidents.map(\.id), ["x"])
    }
}

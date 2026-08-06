import XCTest
@testable import ClaudeUsageBar

/// Covers `WindowPositionPreserver.shouldApply`, the pure apply/skip decision behind the
/// popover's account-switch/resize hook. The `setContentSize` AppKit call itself is
/// deliberately not tested here — see Task 8 in the implementation plan.
final class WindowPositionPreserverTests: XCTestCase {
    private let baseSize = CGSize(width: 340, height: 200)

    func testTriggerChangedApplies() {
        XCTAssertTrue(
            WindowPositionPreserver.shouldApply(
                trigger: "account-2",
                size: baseSize,
                lastTrigger: "account-1",
                lastSize: baseSize
            )
        )
    }

    func testSizeChangedBeyondEpsilonApplies() {
        let newSize = CGSize(width: 340, height: baseSize.height + 10)
        XCTAssertTrue(
            WindowPositionPreserver.shouldApply(
                trigger: "account-1",
                size: newSize,
                lastTrigger: "account-1",
                lastSize: baseSize
            )
        )
    }

    func testSizeChangedWithinEpsilonSkips() {
        let newSize = CGSize(width: 340, height: baseSize.height + 0.2)
        XCTAssertFalse(
            WindowPositionPreserver.shouldApply(
                trigger: "account-1",
                size: newSize,
                lastTrigger: "account-1",
                lastSize: baseSize
            )
        )
    }

    func testNothingChangedSkips() {
        XCTAssertFalse(
            WindowPositionPreserver.shouldApply(
                trigger: "account-1",
                size: baseSize,
                lastTrigger: "account-1",
                lastSize: baseSize
            )
        )
    }

    func testZeroSizeSkipsEvenWithTriggerChange() {
        XCTAssertFalse(
            WindowPositionPreserver.shouldApply(
                trigger: "account-2",
                size: .zero,
                lastTrigger: "account-1",
                lastSize: baseSize
            )
        )
    }

    func testExactlyAtEpsilonSkips() {
        let newSize = CGSize(
            width: 340,
            height: baseSize.height + WindowPositionPreserver.resizeEpsilon
        )
        XCTAssertFalse(
            WindowPositionPreserver.shouldApply(
                trigger: "account-1",
                size: newSize,
                lastTrigger: "account-1",
                lastSize: baseSize
            )
        )
    }
}

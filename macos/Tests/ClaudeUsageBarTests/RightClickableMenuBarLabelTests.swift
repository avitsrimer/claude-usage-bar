import AppKit
import XCTest
@testable import ClaudeUsageBar

/// Covers the two pure, testable pieces behind the menu bar icon's right-click-to-quit feature:
/// `MenuBarClickDispatch` (which event types should show the menu) and
/// `MenuBarContextMenuBuilder` (the menu's structure). The AppKit-level interaction itself —
/// `NSStatusItem`/`NSEvent` dispatch, `hitTest`, `NSMenu.popUp` — is not unit-testable and is
/// covered by manual verification instead (see the implementation plan's Post-Completion section).
final class RightClickableMenuBarLabelTests: XCTestCase {

    // MARK: - MenuBarClickDispatch

    func testRightMouseDownShowsContextMenu() {
        XCTAssertTrue(MenuBarClickDispatch.shouldShowContextMenu(for: .rightMouseDown))
    }

    func testRightMouseUpShowsContextMenu() {
        XCTAssertTrue(MenuBarClickDispatch.shouldShowContextMenu(for: .rightMouseUp))
    }

    func testLeftMouseDownDoesNotShowContextMenu() {
        // Left-click must fall through untouched so MenuBarExtra's own popover toggle fires.
        XCTAssertFalse(MenuBarClickDispatch.shouldShowContextMenu(for: .leftMouseDown))
    }

    func testLeftMouseUpDoesNotShowContextMenu() {
        XCTAssertFalse(MenuBarClickDispatch.shouldShowContextMenu(for: .leftMouseUp))
    }

    func testOtherEventTypesDoNotShowContextMenu() {
        XCTAssertFalse(MenuBarClickDispatch.shouldShowContextMenu(for: .mouseMoved))
        XCTAssertFalse(MenuBarClickDispatch.shouldShowContextMenu(for: .scrollWheel))
    }

    // MARK: - MenuBarContextMenuBuilder

    func testQuitMenuHasExactlyOneItem() {
        let menu = MenuBarContextMenuBuilder.buildQuitMenu()
        XCTAssertEqual(menu.items.count, 1)
    }

    func testQuitMenuItemTitleAndKeyEquivalent() {
        let menu = MenuBarContextMenuBuilder.buildQuitMenu()
        let item = menu.items[0]
        XCTAssertEqual(item.title, "Quit")
        XCTAssertEqual(item.keyEquivalent, "q")
    }

    func testQuitMenuItemTerminatesTheApp() {
        let menu = MenuBarContextMenuBuilder.buildQuitMenu()
        let item = menu.items[0]
        XCTAssertEqual(item.action, #selector(NSApplication.terminate(_:)))
        XCTAssertTrue(item.target is NSApplication)
    }

    func testBuildQuitMenuIsStableAcrossCalls() {
        // Building the menu twice must not share state or mutate global fixtures.
        let first = MenuBarContextMenuBuilder.buildQuitMenu()
        let second = MenuBarContextMenuBuilder.buildQuitMenu()
        XCTAssertEqual(first.items.count, second.items.count)
        XCTAssertNotIdentical(first, second)
    }
}

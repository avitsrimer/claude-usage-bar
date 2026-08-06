import AppKit
import SwiftUI

/// Pure, testable dispatch logic: decides whether a mouse event on the menu bar icon should show
/// the right-click "Quit" context menu, or be ignored so the existing left-click (open popover)
/// behaviour of `MenuBarExtra` proceeds completely undisturbed.
enum MenuBarClickDispatch {
    static func shouldShowContextMenu(for eventType: NSEvent.EventType) -> Bool {
        switch eventType {
        case .rightMouseDown, .rightMouseUp:
            return true
        default:
            return false
        }
    }
}

/// Pure, testable menu-construction logic for the right-click context menu shown over the menu
/// bar icon.
enum MenuBarContextMenuBuilder {
    static let quitTitle = "Quit"

    /// Builds the context menu: a single "Quit" item wired to `NSApplication.terminate(_:)`.
    static func buildQuitMenu() -> NSMenu {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)
        return menu
    }
}

/// Transparent overlay view placed on top of the menu bar icon's SwiftUI content. Right-clicks
/// anywhere on it show the Quit context menu; every other event — in particular left-clicks — is
/// passed straight through by `hitTest` returning `nil`, so `MenuBarExtra`'s built-in
/// left-click-opens-popover behaviour never even sees this view and keeps working exactly as
/// before.
final class RightClickCatcherView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let eventType = NSApp.currentEvent?.type,
              MenuBarClickDispatch.shouldShowContextMenu(for: eventType) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = MenuBarContextMenuBuilder.buildQuitMenu()
        let location = convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: location, in: self)
    }
}

private struct RightClickCatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> RightClickCatcherView {
        RightClickCatcherView()
    }

    func updateNSView(_ nsView: RightClickCatcherView, context: Context) {}
}

/// Wraps the menu bar icon's label content so a right-click anywhere on it shows a "Quit" menu,
/// while left-clicks keep opening the popover exactly as they do today. Draws nothing itself —
/// the wrapped content (the icon `Image`) is untouched, so its `isTemplate` menu-bar tinting is
/// unaffected.
struct RightClickableMenuBarLabel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .overlay(RightClickCatcher())
    }
}

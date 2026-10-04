import AppKit
import ObjectiveC

/// Skips `NSCursor.set` when the same cursor was set a moment ago.
///
/// While anything in a window moves (scrolling the editor, a live
/// visualizer), AppKit re-applies the cursor on every display cycle through
/// `NSHostingView.cursorUpdate`, and each `set` re-registers the cursor
/// with the window server. With customized pointer colors (Accessibility,
/// Display, Pointer) every registration also re-renders the pointer
/// images with their shadow, which measured about a quarter of the main
/// thread while the editor scrolled, at 120 Hz. Setting the cursor that is
/// already showing changes nothing on screen, so a repeat within a short
/// window is dropped; a different cursor, or the same one after the window
/// has passed or the app was reactivated, goes through as before.
enum CursorSetThrottle {
    /// How long a repeat of the same cursor is treated as already showing.
    /// Short, so a pointer changed some way other than `set` (a resize
    /// edge, a drag) is put right within a tenth of a second.
    private static let window: TimeInterval = 0.1
    // Main thread only: AppKit sets cursors on the main thread.
    nonisolated(unsafe) private static var last: (cursor: ObjectIdentifier, at: TimeInterval)?
    nonisolated(unsafe) private static var installed = false

    @MainActor static func install() {
        guard !installed,
              let original = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.set)),
              let replacement = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.inputConfig_throttledSet))
        else { return }
        installed = true
        method_exchangeImplementations(original, replacement)
        // Another app may have changed the pointer while this one was in
        // the background: the first set after coming back always applies.
        // So does the first after leaving it, or after a window resize,
        // whose edge cursors the system draws without `set`.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didEndLiveResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in last = nil }
        }
    }

    /// True when this set can be dropped. Records the set otherwise.
    fileprivate static func shouldSkip(_ cursor: NSCursor) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let id = ObjectIdentifier(cursor)
        if let last, last.cursor == id, now - last.at < window { return true }
        last = (id, now)
        return false
    }
}

extension NSCursor {
    /// Swapped with `set` by CursorSetThrottle.install, so calling it here
    /// runs the original `set`.
    @objc fileprivate func inputConfig_throttledSet() {
        if CursorSetThrottle.shouldSkip(self) { return }
        inputConfig_throttledSet()
    }
}

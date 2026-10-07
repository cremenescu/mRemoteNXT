// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import AppKit

/// When the menu bar may come down over a window in full screen.
///
/// A remote desktop runs to the top edge of the screen, and that is where its own windows
/// keep their title bars. With the menu bar sliding down at the first touch of the edge,
/// reaching one means fighting the Mac for it.
enum FullScreenMenuBarMode: String, CaseIterable, Identifiable {
    /// Whatever macOS does (its "Automatically hide and show the menu bar" setting).
    case system
    /// Only after the pointer has rested at the top edge for a few seconds.
    case delayed
    /// Never; full screen is left with ⌃⌘F or Fn+F.
    case immersive
    var id: String { rawValue }

    static var current: FullScreenMenuBarMode {
        FullScreenMenuBarMode(rawValue: UserDefaults.standard.string(forKey: "fullScreenMenuBar") ?? "") ?? .system
    }
}

/// Drives the menu bar of the window in full screen. The toolbar always hides with it
/// (autoHideToolbar), so in full screen the session has the whole screen.
@MainActor
final class FullScreenMenuBar {
    static let shared = FullScreenMenuBar()

    private static let hidden: NSApplication.PresentationOptions =
        [.fullScreen, .hideDock, .hideMenuBar, .autoHideToolbar]
    private static let shown: NSApplication.PresentationOptions =
        [.fullScreen, .autoHideDock, .autoHideMenuBar, .autoHideToolbar]
    /// How long the pointer has to rest at the top edge in the delayed mode.
    private static let delay: TimeInterval = 3

    private weak var window: NSWindow?
    private var timer: Timer?
    private var atTopSince: Date?
    private var revealed = false

    /// The window delegate's answer to what full screen should look like.
    func options(proposed: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        switch FullScreenMenuBarMode.current {
        case .system: return proposed.union(.autoHideToolbar)
        case .delayed, .immersive: return Self.hidden
        }
    }

    func didEnter(_ window: NSWindow) {
        self.window = window
        stopWatching()
        guard FullScreenMenuBarMode.current == .delayed else { return }
        // Scheduled in the default run-loop mode on purpose: it pauses while a menu is being
        // tracked, so an open menu is never pulled away from under the pointer.
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func didExit(_ window: NSWindow) {
        guard window === self.window else { return }
        stopWatching()
        self.window = nil
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        atTopSince = nil
        revealed = false
    }

    private func tick() {
        guard let window, window.styleMask.contains(.fullScreen), window.isKeyWindow,
              let screen = window.screen else {
            atTopSince = nil
            return
        }
        let y = NSEvent.mouseLocation.y
        let top = screen.frame.maxY
        if !revealed {
            guard y >= top - 2 else { atTopSince = nil; return }
            guard let since = atTopSince else { atTopSince = Date(); return }
            if Date().timeIntervalSince(since) >= Self.delay {
                revealed = true
                NSApp.presentationOptions = Self.shown
            }
        } else if y < top - 120 {
            // Past the menu bar and the toolbar under it: hold it back again.
            revealed = false
            atTopSince = nil
            NSApp.presentationOptions = Self.hidden
        }
    }
}

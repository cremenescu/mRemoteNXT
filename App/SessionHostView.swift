// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import AppKit

/// Holds one session's view and decides when it learns about a new size.
///
/// Every open session stays alive in a ZStack, hidden ones at opacity zero, so switching
/// tabs never restarts a process. The price was that a size change reached all of them at
/// once: dragging the sidebar divider hands every hidden view a new frame on every tick,
/// and for a terminal each of those is a full reflow of the scrollback plus a SIGWINCH to
/// the remote shell — with twenty tabs open, one tick of the drag reflowed two hundred
/// thousand lines and woke twenty remote programs. The divider crawled.
///
/// The active session follows the size live, as before. A hidden one is told only once
/// the size has stopped changing, so it still ends up right — switching to it costs
/// nothing extra — but the drag pays for a single view, the one on screen.
final class SessionHostView<Content: NSView>: NSView {
    let content: Content

    /// Flip to true when the tab comes on screen; the content is sized right away.
    var isActive = false {
        didSet { if isActive && !oldValue { syncNow() } }
    }

    private var pending: DispatchWorkItem?

    init(content: Content) {
        self.content = content
        super.init(frame: content.frame)
        // The whole point is deciding when the child resizes, so AppKit must not do it
        // on our behalf.
        autoresizesSubviews = false
        content.autoresizingMask = []
        // Between two syncs a hidden child can be larger than its host; nothing of it may
        // show, or catch a click, outside the tab's own area.
        clipsToBounds = true
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if isActive { syncNow() } else { syncLater() }
    }

    private func syncNow() {
        pending?.cancel()
        pending = nil
        if content.frame.size != bounds.size || content.frame.origin != .zero {
            content.frame = bounds
        }
    }

    /// Quarter of a second of quiet is longer than the gap between two drag ticks and
    /// shorter than anyone notices when they switch to the tab afterwards.
    private func syncLater() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

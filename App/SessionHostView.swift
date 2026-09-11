// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import AppKit

/// Holds one session's view and decides when it learns about a new size.
///
/// Every open session stays alive in a ZStack, hidden ones at opacity zero, so switching
/// tabs never restarts a process. The price was that a size change reached all of them at
/// once: dragging the sidebar divider handed every hidden view a new frame on every tick,
/// and for a terminal each of those is a reallocation of every scrollback line plus a
/// SIGWINCH to the remote shell — with twenty tabs open, one tick of the drag moved tens
/// of megabytes and woke twenty remote programs. The divider crawled.
///
/// The active session follows the size live, as before. What a hidden one does depends
/// on how expensive it is to be wrong:
///
/// - `.whenActive`: the view is sized only when its tab comes on screen. A terminal nobody
///   is looking at gains nothing from being the right size, and sizing it costs a full
///   pass over its scrollback; the one pass it pays at switch time is a few tens of
///   milliseconds, under the tab animation. Measured first as a 250 ms debounce: that
///   still fired inside the drag at every pause of the hand, and each time reflowed every
///   hidden terminal at once, which was half the drag's cost.
/// - `.whenSettled`: the view is sized once the drag is over — the mouse button up and
///   the window out of live resize — so a remote desktop has already been asked for its
///   new size by the time its tab is picked, and picking it shows no re-layout.
final class SessionHostView<Content: NSView>: NSView {
    enum HiddenSizing { case whenActive, whenSettled }

    let content: Content
    let hiddenSizing: HiddenSizing

    /// Flip to true when the tab comes on screen; the content is sized right away.
    var isActive = false {
        didSet { if isActive && !oldValue { syncNow() } }
    }

    private var pending: DispatchWorkItem?

    init(content: Content, hiddenSizing: HiddenSizing) {
        self.content = content
        self.hiddenSizing = hiddenSizing
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
        if isActive {
            syncNow()
        } else if hiddenSizing == .whenSettled {
            syncWhenSettled()
        }
        // .whenActive: nothing until the tab is shown; isActive's didSet does it then.
    }

    private func syncNow() {
        pending?.cancel()
        pending = nil
        if content.frame.size != bounds.size || content.frame.origin != .zero {
            content.frame = bounds
        }
    }

    /// A drag reports itself through the mouse button, not through any pause in the
    /// frames: a hand that stops for a quarter of a second is still mid-drag. Re-arm
    /// until the button is up and the window is not being live-resized either.
    private func syncWhenSettled() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let dragging = NSEvent.pressedMouseButtons != 0 || (self.window?.inLiveResize ?? false)
            if dragging { self.syncWhenSettled() } else { self.syncNow() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

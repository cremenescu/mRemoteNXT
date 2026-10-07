// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import AppKit

/// What the tab bar may ask of a session's view without knowing its kind.
@MainActor
protocol SessionPreviewing: AnyObject {
    /// The session as it looks right now, nil when there is nothing to show yet.
    func previewImage() -> CGImage?
}

/// Session id -> its live view, for the parts of the window that are not the view itself:
/// the preview under a hovered tab and the connection info window. Weak, so a closed tab
/// simply disappears from it.
@MainActor
final class SessionViews {
    static let shared = SessionViews()

    private final class Box { weak var view: SessionPreviewing?; init(_ v: SessionPreviewing) { view = v } }
    private var map: [UUID: Box] = [:]

    func register(_ id: UUID, _ view: SessionPreviewing) {
        map = map.filter { $0.value.view != nil }
        map[id] = Box(view)
    }

    func view(for id: UUID) -> SessionPreviewing? { map[id]?.view }
}

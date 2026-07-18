// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit
import MRNGCore

/// NSView that displays the RDP framebuffer (CGImage in a layer) and sends input.
extension Notification.Name {
    static let mrngSendCAD = Notification.Name("MRNG.SendCtrlAltDel")
}

final class RDPNSView: NSView, RDPClientDelegate {
    private var client: RDPClient?
    private var desktop = CGSize(width: 1280, height: 800)
    private var statusLayer: CATextLayer?
    private var didConnectOnce = false
    private var lastModifierFlags: NSEvent.ModifierFlags = []
    private var cadObserver: NSObjectProtocol?
    /// Called on disconnect AFTER a successful connection (not on connect failure).
    var onDisconnect: (() -> Void)?

    private let session: Session
    private var didStart = false

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        showStatus("Connecting to \(session.node.hostname)...")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    deinit {
        client?.stop()
        if let obs = cadObserver { NotificationCenter.default.removeObserver(obs) }
    }
    func stop() { client?.stop() }

    private var resizeWork: DispatchWorkItem?

    // Connect only after the view has a real size -> RDP resolution = tab pixels (Retina-aware).
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); startIfNeeded() }
    override func layout() {
        super.layout()
        if !didStart { startIfNeeded() } else { scheduleResize() }
    }

    /// Desired RDP desktop size in pixels (Retina-aware), based on current bounds.
    private func targetPixels() -> (w: Int, h: Int, scalePct: Int) {
        let scale = window?.backingScaleFactor ?? 2.0
        var w = Int((bounds.width * scale).rounded())
        var h = Int((bounds.height * scale).rounded())
        w -= w % 2; h -= h % 2
        w = max(640, min(3840, w))
        h = max(480, min(2160, h))
        return (w, h, Int(scale * 100))
    }

    private func startIfNeeded() {
        guard !didStart, window != nil, bounds.width > 100, bounds.height > 100 else { return }
        didStart = true

        let t = targetPixels()
        desktop = CGSize(width: t.w, height: t.h)

        let node = session.node
        var user = node.username
        var domain = node.domain
        if domain.isEmpty, let r = user.range(of: "\\") {
            domain = String(user[..<r.lowerBound])
            user = String(user[r.upperBound...])
        }

        let c = RDPClient(host: node.hostname, port: Int32(node.port),
                          username: user, domain: domain,
                          password: session.password,
                          width: Int32(t.w), height: Int32(t.h), scale: Int32(t.scalePct))
        c.delegate = self
        client = c
        c.start()

        // Observe Ctrl+Alt+Del requests for this session.
        let sessionID = session.id
        cadObserver = NotificationCenter.default.addObserver(
            forName: .mrngSendCAD, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? UUID) == sessionID else { return }
            self.sendCtrlAltDel()
        }
    }

    /// Sends the Ctrl+Alt+Del sequence to the RDP session.
    func sendCtrlAltDel() {
        let ctrl = RDPSpecialKey.keyControl.rawValue
        let alt = RDPSpecialKey.keyAlt.rawValue
        let del = RDPSpecialKey.keyDelete.rawValue
        client?.keySpecial(ctrl, down: true)
        client?.keySpecial(alt, down: true)
        client?.keySpecial(del, down: true)
        client?.keySpecial(del, down: false)
        client?.keySpecial(alt, down: false)
        client?.keySpecial(ctrl, down: false)
    }

    /// Sends a new resolution to the server (debounced) when the window resizes.
    private func scheduleResize() {
        guard didStart, window != nil, bounds.width > 100, bounds.height > 100 else { return }
        let t = targetPixels()
        guard t.w != Int(desktop.width) || t.h != Int(desktop.height) else { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.desktop = CGSize(width: t.w, height: t.h)
            self.client?.resize(toWidth: Int32(t.w), height: Int32(t.h), scale: Int32(t.scalePct))
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Status overlay

    private func showStatus(_ text: String) {
        let tl = statusLayer ?? CATextLayer()
        tl.string = text
        tl.fontSize = 14
        tl.foregroundColor = NSColor.white.cgColor
        tl.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        tl.alignmentMode = .center
        tl.contentsScale = window?.backingScaleFactor ?? 2
        tl.zPosition = 100
        let h: CGFloat = 30
        tl.frame = CGRect(x: 0, y: bounds.midY - h / 2, width: max(1, bounds.width), height: h)
        if statusLayer == nil { layer?.addSublayer(tl); statusLayer = tl }
    }
    private func clearStatus() { statusLayer?.removeFromSuperlayer(); statusLayer = nil }

    // MARK: - RDPClientDelegate

    func rdpClient(_ client: RDPClient, didConnectWithWidth width: Int32, height: Int32) {
        desktop = CGSize(width: Int(width), height: Int(height))
        didConnectOnce = true
    }

    func rdpClient(_ client: RDPClient, didUpdate image: CGImage) {
        clearStatus()
        layer?.contents = image
    }

    // Remote cursor shape from the RDP pointer channel. With cursor redirection the
    // server stops baking the pointer into the framebuffer and sends it separately,
    // so we present it as the view's own cursor (nil = the local system arrow).
    private var remoteCursor: NSCursor = .arrow

    func rdpClient(_ client: RDPClient, didUpdate cursor: NSCursor?) {
        remoteCursor = cursor ?? .arrow
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: remoteCursor)
    }

    func rdpClient(_ client: RDPClient, didDisconnectWithError error: String?) {
        showStatus(error ?? "Disconnected.")
        if didConnectOnce { onDisconnect?() }
    }

    // MARK: - Coordinates (aspect-fit view -> RDP desktop)

    private func rdpPoint(_ event: NSEvent) -> (Int32, Int32) {
        let p = convert(event.locationInWindow, from: nil)
        let vw = bounds.width, vh = bounds.height
        guard vw > 0, vh > 0, desktop.width > 0, desktop.height > 0 else { return (0, 0) }
        let viewAspect = vw / vh
        let imgAspect = desktop.width / desktop.height
        var drawW = vw, drawH = vh, offX: CGFloat = 0, offY: CGFloat = 0
        if viewAspect > imgAspect { drawW = vh * imgAspect; offX = (vw - drawW) / 2 }
        else { drawH = vw / imgAspect; offY = (vh - drawH) / 2 }
        let nx = (p.x - offX) / drawW
        let ny = 1 - (p.y - offY) / drawH // NSView is bottom-left, RDP is top-left
        let x = Int32((nx * desktop.width).rounded())
        let y = Int32((ny * desktop.height).rounded())
        return (max(0, min(Int32(desktop.width) - 1, x)), max(0, min(Int32(desktop.height) - 1, y)))
    }

    // MARK: - Mouse

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with e: NSEvent)    { let (x, y) = rdpPoint(e); client?.mouseMoveTo(x: x, y: y) }
    override func mouseDragged(with e: NSEvent)  { let (x, y) = rdpPoint(e); client?.mouseMoveTo(x: x, y: y) }
    override func rightMouseDragged(with e: NSEvent) { let (x, y) = rdpPoint(e); client?.mouseMoveTo(x: x, y: y) }
    override func mouseDown(with e: NSEvent)     { let (x, y) = rdpPoint(e); client?.mouseButton(1, down: true, x: x, y: y) }
    override func mouseUp(with e: NSEvent)       { let (x, y) = rdpPoint(e); client?.mouseButton(1, down: false, x: x, y: y) }
    override func rightMouseDown(with e: NSEvent){ let (x, y) = rdpPoint(e); client?.mouseButton(2, down: true, x: x, y: y) }
    override func rightMouseUp(with e: NSEvent)  { let (x, y) = rdpPoint(e); client?.mouseButton(2, down: false, x: x, y: y) }
    override func otherMouseDown(with e: NSEvent){ let (x, y) = rdpPoint(e); client?.mouseButton(3, down: true, x: x, y: y) }
    override func otherMouseUp(with e: NSEvent)  { let (x, y) = rdpPoint(e); client?.mouseButton(3, down: false, x: x, y: y) }
    override func scrollWheel(with e: NSEvent)   { let (x, y) = rdpPoint(e); client?.scrollSteps(Int32(e.deltaY.rounded()), x: x, y: y) }

    // Report mouseMoved even without a pressed button.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let ta = NSTrackingArea(rect: bounds,
                                options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
    }

    // MARK: - Keyboard

    override func keyDown(with e: NSEvent) { handleKey(e, down: true) }
    override func keyUp(with e: NSEvent)   { handleKey(e, down: false) }

    /// Maps modifier changes (Shift/Ctrl/Option/Cmd) to RDP scancodes.
    /// Cmd is "virtualized" as Ctrl so Mac shortcuts (Cmd+C) become Ctrl+C in Windows.
    override func flagsChanged(with event: NSEvent) {
        let interesting: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let newFlags = event.modifierFlags.intersection(interesting)

        let virtCtrlNew = newFlags.contains(.control) || newFlags.contains(.command)
        let virtCtrlOld = lastModifierFlags.contains(.control) || lastModifierFlags.contains(.command)
        if virtCtrlNew != virtCtrlOld {
            client?.keySpecial(RDPSpecialKey.keyControl.rawValue, down: virtCtrlNew)
        }
        let shiftNew = newFlags.contains(.shift)
        if shiftNew != lastModifierFlags.contains(.shift) {
            client?.keySpecial(RDPSpecialKey.keyShift.rawValue, down: shiftNew)
        }
        let altNew = newFlags.contains(.option)
        if altNew != lastModifierFlags.contains(.option) {
            client?.keySpecial(RDPSpecialKey.keyAlt.rawValue, down: altNew)
        }
        lastModifierFlags = newFlags
    }

    private func handleKey(_ e: NSEvent, down: Bool) {
        if let special = Self.specialKey(for: e.keyCode) {
            client?.keySpecial(special, down: down)
            return
        }
        if let scalar = e.charactersIgnoringModifiers?.unicodeScalars.first {
            client?.keyChar(UInt16(scalar.value & 0xFFFF), down: down)
        }
    }

    static func specialKey(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 36, 76: return RDPSpecialKey.keyEnter.rawValue
        case 51:     return RDPSpecialKey.keyBackspace.rawValue
        case 117:    return RDPSpecialKey.keyDelete.rawValue
        case 48:     return RDPSpecialKey.keyTab.rawValue
        case 53:     return RDPSpecialKey.keyEscape.rawValue
        case 49:     return RDPSpecialKey.keySpace.rawValue
        case 126:    return RDPSpecialKey.keyUp.rawValue
        case 125:    return RDPSpecialKey.keyDown.rawValue
        case 123:    return RDPSpecialKey.keyLeft.rawValue
        case 124:    return RDPSpecialKey.keyRight.rawValue
        default:     return nil
        }
    }
}

struct RDPContainer: NSViewRepresentable {
    let session: Session
    let isActive: Bool
    var onDisconnect: () -> Void = {}

    func makeNSView(context: Context) -> RDPNSView {
        let view = RDPNSView(session: session)
        view.onDisconnect = onDisconnect
        return view
    }

    func updateNSView(_ nsView: RDPNSView, context: Context) {
        guard isActive else { return }
        DispatchQueue.main.async {
            guard let w = nsView.window else { return }
            // Don't steal focus while the user is typing in a text field (e.g. search).
            if w.firstResponder is NSText { return }
            if w.firstResponder !== nsView { w.makeFirstResponder(nsView) }
        }
    }

    static func dismantleNSView(_ nsView: RDPNSView, coordinator: ()) {
        nsView.stop()
    }
}

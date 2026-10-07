// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit
import Carbon.HIToolbox
import MRNGCore

/// NSView that displays the RDP framebuffer (CGImage in a layer) and sends input.
extension Notification.Name {
    static let mrngSendCAD = Notification.Name("MRNG.SendCtrlAltDel")
}

/// Hosts that turned out to be too old for the graphics pipeline. Kept in the app's own
/// preferences rather than in confCons: mRemoteNG drops attributes it doesn't know at the
/// first save, so anything written there would vanish the moment the file is opened on
/// Windows — and this is a property of the server, not of the connection entry.
enum LegacyGraphicsHosts {
    private static let key = "legacyGraphicsHosts"

    static func contains(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        let all = UserDefaults.standard.stringArray(forKey: key) ?? []
        return all.contains(host.lowercased())
    }

    static func add(_ host: String) {
        guard !host.isEmpty else { return }
        var all = UserDefaults.standard.stringArray(forKey: key) ?? []
        let h = host.lowercased()
        guard !all.contains(h) else { return }
        all.append(h)
        UserDefaults.standard.set(all, forKey: key)
    }
}

final class RDPNSView: NSView, RDPClientDelegate {
    private var client: RDPClient?
    private var desktop = CGSize(width: 1280, height: 800)
    private var statusLayer: CATextLayer?
    private var didConnectOnce = false
    /// Modifiers as the server last heard them. Tracked separately from the Mac's flags
    /// because they don't map one to one: Command can stand in for Ctrl, Option can be kept
    /// away from Alt, and Alt is let go early while a composed character goes out.
    private var sentCtrl = false
    private var sentShift = false
    private var sentAlt = false
    private var cadObserver: NSObjectProtocol?
    /// Called on disconnect AFTER a successful connection (not on connect failure).
    var onDisconnect: (() -> Void)?
    /// Asks the app layer to reconnect this tab (used after learning that the server
    /// needs the legacy graphics path).
    var onNeedsReconnect: (() -> Void)?

    private let session: Session
    private var didStart = false
    /// True when the session was told which keyboard layout we use, which is the only
    /// condition under which sending key positions instead of characters is safe.
    private var layoutAnnounced = false
    /// Shown once over the first frame when the keyboard layout could not be matched exactly.
    private var keyboardNotice: String?
    private var noticeLayer: CALayer?

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

    /// Connecting is gated on the view having a real size, and a view can be handed one
    /// long after it was created — the last restored tab is laid out once, at zero size,
    /// with nothing changing afterwards to lay it out again, so it would sit black forever.
    /// Every path that can give it a size ends up here.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        startIfNeeded()
    }

    /// Called from the SwiftUI container on every update, so selecting a tab that never got
    /// off the ground is enough to start it.
    func ensureStarted() { startIfNeeded() }

    // MARK: - Remote pointer
    //
    // The desktop image never contains the pointer — the server sends its shape separately
    // and expects the client to draw it. Until this was wired up the Mac arrow stayed an
    // arrow over everything: no resize arrows on a window edge, no I-beam over text, no
    // drag feedback in Explorer.

    /// Cursor the remote asked for, nil = the system arrow.
    private var remoteCursor: NSCursor?

    /// Whether this session's tab is the one on screen.
    ///
    /// Every open session stays alive in a ZStack, the hidden ones at opacity zero, and a
    /// tracking area takes no notice of opacity. So every hidden desktop kept its own area
    /// over the same rectangle and kept setting the cursor: when a Windows box in a
    /// background tab hid its pointer — a locked screen, a video, a console that hides it
    /// while typing — the transparent cursor went up over whichever tab was actually
    /// showing, and the mouse vanished there. Hidden tabs also forwarded every mouse move
    /// to their servers. Only the active tab owns a tracking area now.
    var isActiveTab = false {
        didSet {
            guard isActiveTab != oldValue else { return }
            updateTrackingAreas()
            // Leaving: if the pointer still wears this session's shape, hand back the arrow
            // — the tab now on screen sets its own on its first update. Only our own shape is
            // touched, so a tab that became active before this one went inactive keeps its.
            if !isActiveTab, let mine = remoteCursor, NSCursor.current === mine {
                NSCursor.arrow.set()
            }
        }
    }

    /// AppKit asks for the cursor through the tracking machinery, so a change only takes
    /// effect once the rects are rebuilt.
    override func resetCursorRects() {
        if isActiveTab, let c = remoteCursor {
            addCursorRect(bounds, cursor: c)
        } else {
            super.resetCursorRects()
        }
    }

    /// Belt and braces: while the pointer is already inside the view AppKit sends this
    /// instead of rebuilding the rects.
    override func cursorUpdate(with event: NSEvent) {
        guard isActiveTab else { return }
        if let c = remoteCursor { c.set() } else { super.cursorUpdate(with: event) }
    }

    private func applyCursor(_ cursor: NSCursor?) {
        remoteCursor = cursor
        applyCursorIfInside()
    }

    /// Put the remote cursor on screen when the pointer is already over this view.
    ///
    /// AppKit only asks through cursorUpdate(with:) when the pointer crosses into the
    /// tracking area. It never asks for a pointer that is already sitting inside one — and
    /// this view rebuilds its tracking area on every layout, which is every frame. So a
    /// session that connects under a motionless pointer, or a tab brought to the front
    /// under it, kept the plain arrow until the mouse was nudged.
    ///
    /// Deliberately no invalidateCursorRects: it used to run on every shape change and,
    /// mid-drag, rebuilding the window's cursor rects interferes with the drag itself.
    private func applyCursorIfInside() {
        guard isActiveTab, let w = window, w.isKeyWindow,
              bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil))
        else { return }
        let wanted = remoteCursor ?? .arrow
        // Called from every layout pass, so don't churn when it is already right.
        guard NSCursor.current !== wanted else { return }
        wanted.set()
    }

    override func mouseEntered(with event: NSEvent) { applyCursorIfInside() }
    override func layout() {
        super.layout()
        if !didStart { startIfNeeded() } else { scheduleResize() }
        layoutNotice()
    }

    /// Read straight from the defaults rather than threaded down through the view tree:
    /// the value is consulted once per connection, and Preferences writes to the same key.
    static var scancodeTypingEnabled: Bool {
        UserDefaults.standard.object(forKey: "rdpScancodeTyping") as? Bool ?? true
    }

    /// What to tell the user about the layout announced for this session; nil = nothing.
    static func notice(for layout: KeyboardLayoutID.Resolution) -> String? {
        switch layout.match {
        case .exact?: return nil
        case .closest?: return String(format: t("Keyboard.Closest"), layout.name)
        case nil: return String(format: t("Keyboard.Unknown"), layout.name)
        }
    }

    /// Off: Option only ever types what the Mac layout puts on it, and the server never
    /// sees Alt from it.
    static var optionSendsAlt: Bool {
        UserDefaults.standard.object(forKey: "rdpOptionSendsAlt") as? Bool ?? true
    }

    /// Off: ⌘W in a session is Ctrl+W for Windows rather than the menu's Close Tab.
    static var commandWClosesTab: Bool {
        UserDefaults.standard.object(forKey: "commandWClosesTab") as? Bool ?? true
    }

    /// Which Command key stands in for Ctrl. Read per event, so a change applies at once.
    static var commandAsCtrl: CommandAsCtrl {
        CommandAsCtrl(rawValue: UserDefaults.standard.string(forKey: "rdpCommandAsCtrl") ?? "") ?? .both
    }

    /// Whether the Command key held in `flags` is one that stands in for Ctrl. The
    /// device-dependent bits tell the two Command keys apart (NX_DEVICELCMDKEYMASK and
    /// NX_DEVICERCMDKEYMASK in IOKit's event headers).
    static func redirectedCommandHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.command) else { return false }
        switch commandAsCtrl {
        case .both: return true
        case .left: return flags.rawValue & 0x08 != 0
        case .right: return flags.rawValue & 0x10 != 0
        }
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
                          width: Int32(t.w), height: Int32(t.h), scale: Int32(t.scalePct),
                          sharedFolder: {
                              // Two independent switches: the connection's own
                              // RedirectDiskDrives (native mRemoteNG attribute, inheritable)
                              // decides WHETHER, the Settings folder decides WHAT. Either one
                              // unset means nothing is shared with this session.
                              guard node.redirectDiskDrives else { return nil }
                              // Per-connection folder (inheritable, so it can be set once on a
                              // parent folder) wins; the Settings one is the fallback.
                              let own = node.redirectDiskDrivesCustom
                              if !own.isEmpty { return own }
                              let p = UserDefaults.standard.string(forKey: "sharedFolderPath") ?? ""
                              return p.isEmpty ? nil : p
                          }(),
                          useLegacyGraphics: LegacyGraphicsHosts.contains(node.hostname))
        c.delegate = self
        applyGateway(to: c, user: user, domain: domain)
        // Announce the layout before connecting: it travels in the client info PDU, and
        // without it the server resolves key positions through whatever layout the session
        // happens to be configured with.
        if RDPNSView.scancodeTypingEnabled {
            let layout = KeyboardLayoutID.current()
            if let klid = layout.klid {
                c.setKeyboardLayout(klid)
                layoutAnnounced = true
            }
            keyboardNotice = Self.notice(for: layout)
        }
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

    /// The connection's RD Gateway, if it has one. The attributes are mRemoteNG's, so a file
    /// set up on Windows connects the same way here.
    private func applyGateway(to c: RDPClient, user: String, domain: String) {
        let node = session.node
        let usage = node.gatewayUsageMethod
        guard usage == "Always" || usage == "Detect", !node.gatewayHostname.isEmpty else { return }
        let (host, port) = RDPFile.splitHostPort(node.gatewayHostname, defaultPort: 443)
        let same = node.gatewayUseConnectionCredentials == "Yes"
        var gwUser = same ? user : node.gatewayUsername
        var gwDomain = same ? domain : node.gatewayDomain
        if gwDomain.isEmpty, let r = gwUser.range(of: "\\") {
            gwDomain = String(gwUser[..<r.lowerBound])
            gwUser = String(gwUser[r.upperBound...])
        }
        c.setGatewayHost(host, port: Int32(port), usage: usage == "Detect" ? 2 : 1,
                         sameCredentials: same, username: gwUser, domain: gwDomain,
                         password: same ? session.password : session.gatewayPassword)
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

    /// A strip across the top of the desktop that goes away by itself. It sits over the
    /// remote image rather than taking room from it, so the desktop size never changes for
    /// the sake of a message.
    private func showNotice(_ text: String) {
        noticeLayer?.removeFromSuperlayer()
        let strip = CALayer()
        strip.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        strip.zPosition = 101
        let label = CATextLayer()
        label.string = text
        label.fontSize = 13
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.isWrapped = true
        label.contentsScale = window?.backingScaleFactor ?? 2
        strip.addSublayer(label)
        layer?.addSublayer(strip)
        noticeLayer = strip
        layoutNotice()
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self, weak strip] in
            guard let self, let strip, self.noticeLayer === strip else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            CATransaction.setCompletionBlock { strip.removeFromSuperlayer() }
            strip.opacity = 0
            CATransaction.commit()
            self.noticeLayer = nil
        }
    }

    private func layoutNotice() {
        guard let strip = noticeLayer, let label = strip.sublayers?.first else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h: CGFloat = 46
        strip.frame = CGRect(x: 0, y: bounds.height - h, width: max(1, bounds.width), height: h)
        label.frame = strip.bounds.insetBy(dx: 16, dy: 6)
        CATransaction.commit()
    }

    // MARK: - RDPClientDelegate

    func rdpClient(_ client: RDPClient, didConnectWithWidth width: Int32, height: Int32) {
        desktop = CGSize(width: Int(width), height: Int(height))
        didConnectOnce = true
    }

    func rdpClient(_ client: RDPClient, didUpdate image: CGImage) {
        clearStatus()
        layer?.contents = image
        if let notice = keyboardNotice {
            keyboardNotice = nil
            showNotice(notice)
        }
    }

    func rdpClient(_ client: RDPClient, didUpdateCursor image: CGImage, hotSpot: CGPoint) {
        // The image is in remote pixels, which are backing pixels here (the desktop is
        // requested at the tab's pixel size), so points = pixels / backing scale. Without
        // dividing, every cursor would be drawn at twice its size on a Retina display.
        let scale = window?.backingScaleFactor ?? 2.0
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard size.width > 0, size.height > 0 else { return }
        let nsImage = NSImage(cgImage: image, size: size)
        let hot = NSPoint(x: hotSpot.x / scale, y: hotSpot.y / scale)
        applyCursor(NSCursor(image: nsImage, hotSpot: hot))
    }

    func rdpClientDidHideCursor(_ client: RDPClient) {
        // A fully transparent cursor rather than NSCursor.hide(), which is a global
        // counter: one unbalanced call and the pointer stays gone across the whole app.
        let blank = NSImage(size: NSSize(width: 1, height: 1))
        blank.lockFocus()
        NSColor.clear.set()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 1, height: 1))
        blank.unlockFocus()
        applyCursor(NSCursor(image: blank, hotSpot: .zero))
    }

    func rdpClientDidResetCursor(_ client: RDPClient) {
        applyCursor(nil)
    }

    /// A notice or terms of use from the RD Gateway, as a sheet on this window. The tab
    /// may not be the one on screen, so the title names the connection.
    func rdpClient(_ client: RDPClient, gatewayMessage message: String,
                   consentRequired: Bool, reply: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = String(format: t("Gateway.MessageTitle"), session.node.name)
        alert.informativeText = message
        if consentRequired {
            alert.addButton(withTitle: t("Gateway.Accept"))
            alert.addButton(withTitle: t("Gateway.Decline"))
        } else {
            alert.addButton(withTitle: t("Gateway.OK"))
        }
        guard let window else {
            reply(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { reply($0 == .alertFirstButtonReturn) }
    }

    /// Explorer copied files: offer them to the Finder. Nothing is transferred until a paste.
    func rdpClient(_ client: RDPClient, didCopy files: [RDPRemoteFile]) {
        RemoteClipboardServer.shared.offer(files, from: client)
    }

    func rdpClientNeedsLegacyGraphics(_ client: RDPClient) {
        let host = session.node.hostname
        guard !LegacyGraphicsHosts.contains(host) else { return }
        LegacyGraphicsHosts.add(host)
        // The pipeline was advertised before the server identified itself, so this
        // connection can't be salvaged — reconnect, which now starts on the legacy path.
        showStatus(t("Status.ReconnectingLegacyGraphics"))
        onNeedsReconnect?()
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
        // A hidden tab gets none at all — see isActiveTab.
        guard isActiveTab else { return }
        // .cursorUpdate is what makes AppKit ask US for the cursor. Without it the only
        // route is the cursor-rect machinery, which SwiftUI resets underneath a view that
        // redraws every frame — so the remote cursor arrived, was installed, and was
        // immediately replaced by the arrow again.
        let ta = NSTrackingArea(rect: bounds,
                                options: [.activeInKeyWindow, .mouseMoved, .cursorUpdate,
                                          .mouseEnteredAndExited, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        // The new area gets no entered/cursorUpdate for a pointer that is already inside it.
        applyCursorIfInside()
    }

    // MARK: - Keyboard

    /// Key equivalents reach the view before the menu bar. Only ⌘W is claimed here, and only
    /// when Settings gives it to the session: everything else stays with the menus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !Self.commandWClosesTab, event.type == .keyDown, window?.firstResponder === self,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w",
           Self.redirectedCommandHeld(event.modifierFlags),
           let code = Self.scancode(for: event.keyCode) {
            // Ctrl is already down on the server: flagsChanged pressed it with Command.
            client?.keyScancode(code, extended: false, down: true)
            client?.keyScancode(code, extended: false, down: false)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with e: NSEvent) { handleKey(e, down: true) }
    override func keyUp(with e: NSEvent)   { handleKey(e, down: false) }

    /// Maps modifier changes (Shift/Ctrl/Option/Cmd) to RDP scancodes.
    /// Cmd is "virtualized" as Ctrl so Mac shortcuts (Cmd+C) become Ctrl+C in Windows —
    /// both Command keys by default, or just the one chosen in Settings.
    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        let ctrl = flags.contains(.control) || Self.redirectedCommandHeld(flags)
        if ctrl != sentCtrl {
            client?.keySpecial(RDPSpecialKey.keyControl.rawValue, down: ctrl)
            sentCtrl = ctrl
        }
        let shift = flags.contains(.shift)
        if shift != sentShift {
            client?.keySpecial(RDPSpecialKey.keyShift.rawValue, down: shift)
            sentShift = shift
        }
        let alt = flags.contains(.option) && Self.optionSendsAlt
        if alt != sentAlt {
            client?.keySpecial(RDPSpecialKey.keyAlt.rawValue, down: alt)
            sentAlt = alt
        }
    }

    private func handleKey(_ e: NSEvent, down: Bool) {
        let flags = e.modifierFlags
        let redirectedCommand = Self.redirectedCommandHeld(flags)
        // A Command key that doesn't stand in for Ctrl belongs to the Mac. Whatever reaches
        // us with it held was not a menu shortcut, and typing the bare letter would be wrong.
        if flags.contains(.command), !redirectedCommand { return }
        let ctrlHeld = flags.contains(.control) || redirectedCommand
        // Ctrl+Option+Delete is the Mac spelling of Ctrl+Alt+Del: the Mac's Delete is the PC's
        // Backspace, and the secure attention sequence wants Del. Ctrl is already down on the
        // server; Alt may not be, when Option is kept away from it.
        if e.keyCode == 51, ctrlHeld, flags.contains(.option) {
            if down {
                let alt = RDPSpecialKey.keyAlt.rawValue
                let del = RDPSpecialKey.keyDelete.rawValue
                if !sentAlt { client?.keySpecial(alt, down: true) }
                client?.keySpecial(del, down: true)
                client?.keySpecial(del, down: false)
                if !sentAlt { client?.keySpecial(alt, down: false) }
            }
            return
        }
        if let special = Self.specialKey(for: e.keyCode) {
            client?.keySpecial(special, down: down)
            return
        }
        // Shortcuts (Ctrl+C, Cmd+Z, ...) must go out as scancodes: Windows treats a
        // unicode key event as literal text and ignores the held modifiers, so the
        // unicode path types the letter instead of firing the accelerator. Plain
        // typing stays on unicode so any keyboard layout produces the right character
        // without the client and server layouts having to agree.
        if ctrlHeld, let code = Self.scancode(for: e.keyCode) {
            client?.keyScancode(code, extended: false, down: down)
            return
        }
        // Ordinary typing as key positions rather than characters, when the server has
        // been told which layout to read them through. Console applications that read raw
        // input records — powershell.exe is the one that surfaced this — discard key events
        // that carry no virtual key code, which is exactly what a character-only event is;
        // cmd.exe reads in line mode and takes the character, which is why the two disagree.
        //
        // Option is left out on purpose. macOS composes with Option where Windows composes
        // with AltGr, and sending Alt plus a position would arrive as a menu accelerator —
        // the characters that Option produces keep the path that was fixed for them in 0.8.9.
        let optionComposes = e.modifierFlags.contains(.option)
            && e.characters != e.charactersIgnoringModifiers
        if layoutAnnounced, !optionComposes, let code = Self.scancode(for: e.keyCode) {
            client?.keyScancode(code, extended: false, down: down)
            return
        }
        // The character the layout actually produces, Option included. This used to read
        // charactersIgnoringModifiers — the key *without* Option applied — so on any layout
        // that reaches for Option to type @ [ ] { }, the remote received the bare letter
        // instead (issue #9, the RDP half of it). Turkish, German, Polish, Spanish and
        // Romanian all do; a US layout almost never does, which is why it went unseen.
        guard let scalar = e.characters?.unicodeScalars.first else {
            // Empty means a dead key: the layout has swallowed this press and will hand
            // over the composed character on the next one. Nothing to send yet.
            return
        }
        // Option is a modifier to macOS and a composition key to the layout, and we cannot
        // have it both ways: flagsChanged has already pressed Alt on the server, so sending
        // `@` now would arrive as Alt+@ and be read as an accelerator rather than text.
        // Release it for the duration. Whichever way the user lets go of Option afterwards,
        // flagsChanged sends its own release — a duplicate release is harmless, a stuck Alt
        // is not.
        if down, sentAlt, e.modifierFlags.contains(.option), e.characters != e.charactersIgnoringModifiers {
            client?.keySpecial(RDPSpecialKey.keyAlt.rawValue, down: false)
            sentAlt = false
        }
        client?.keyChar(UInt16(scalar.value & 0xFFFF), down: down)
    }

    /// macOS virtual keycode -> PC set-1 scancode for the main typing block, by physical
    /// key position. Used for shortcuts, and for all typing once the layout is announced.
    static func scancode(for keyCode: UInt16) -> UInt8? {
        switch keyCode {
        // Letters
        case 0:  return 0x1E  // A
        case 11: return 0x30  // B
        case 8:  return 0x2E  // C
        case 2:  return 0x20  // D
        case 14: return 0x12  // E
        case 3:  return 0x21  // F
        case 5:  return 0x22  // G
        case 4:  return 0x23  // H
        case 34: return 0x17  // I
        case 38: return 0x24  // J
        case 40: return 0x25  // K
        case 37: return 0x26  // L
        case 46: return 0x32  // M
        case 45: return 0x31  // N
        case 31: return 0x18  // O
        case 35: return 0x19  // P
        case 12: return 0x10  // Q
        case 15: return 0x13  // R
        case 1:  return 0x1F  // S
        case 17: return 0x14  // T
        case 32: return 0x16  // U
        case 9:  return 0x2F  // V
        case 13: return 0x11  // W
        case 7:  return 0x2D  // X
        case 16: return 0x15  // Y
        case 6:  return 0x2C  // Z
        // Digit row
        case 29: return 0x0B  // 0
        case 18: return 0x02  // 1
        case 19: return 0x03  // 2
        case 20: return 0x04  // 3
        case 21: return 0x05  // 4
        case 23: return 0x06  // 5
        case 22: return 0x07  // 6
        case 26: return 0x08  // 7
        case 28: return 0x09  // 8
        case 25: return 0x0A  // 9
        // Punctuation
        case 27: return 0x0C  // -
        case 24: return 0x0D  // =
        case 33: return 0x1A  // [
        case 30: return 0x1B  // ]
        case 42: return 0x2B  // \
        case 41: return 0x27  // ;
        case 39: return 0x28  // '
        // The key left of 1 and, on ISO keyboards, the extra one left of Z. macOS hands the
        // latter over as kVK_ANSI_Grave, so on an ISO Mac that keycode is the PC's 102nd key
        // (0x56) and the key left of 1 arrives as kVK_ISO_Section. Read as ANSI, German `<`
        // came out as the dead `^` on the server.
        case 50: return KeyboardLayoutID.keyboardIsISO ? 0x56 : 0x29
        case 10: return 0x29
        case 43: return 0x33  // ,
        case 47: return 0x34  // .
        case 44: return 0x35  // /
        default: return nil
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
    var onNeedsReconnect: () -> Void = {}

    func makeNSView(context: Context) -> SessionHostView<RDPNSView> {
        let view = RDPNSView(session: session)
        view.onDisconnect = onDisconnect
        view.onNeedsReconnect = onNeedsReconnect
        view.isActiveTab = isActive
        let host = SessionHostView(content: view, hiddenSizing: .whenSettled)
        host.isActive = isActive
        return host
    }

    func updateNSView(_ host: SessionHostView<RDPNSView>, context: Context) {
        let view = host.content
        view.ensureStarted()
        // Only the tab on screen may set the cursor or hear the mouse.
        view.isActiveTab = isActive
        // The host sizes the desktop view only while it is on screen; tell it which that is.
        host.isActive = isActive
        guard isActive else { return }
        DispatchQueue.main.async {
            guard let w = view.window else { return }
            // Don't steal focus while the user is typing in a text field (e.g. search).
            if w.firstResponder is NSText { return }
            if w.firstResponder !== view { w.makeFirstResponder(view) }
        }
    }

    static func dismantleNSView(_ host: SessionHostView<RDPNSView>, coordinator: ()) {
        host.content.stop()
    }
}

/// Which Command key stands in for Ctrl in an RDP session; the other stays the Mac's.
enum CommandAsCtrl: String, CaseIterable, Identifiable {
    case both, left, right
    var id: String { rawValue }
}

// MARK: - Keyboard layout

/// The macOS input source, translated to the Windows keyboard layout id the server needs.
///
/// Only consulted when typing is sent as scancodes. A scancode says "the key in this
/// position went down"; the server resolves the position through the layout it believes the
/// session uses, so unless it is told, a Romanian Mac talking to a US-configured Windows
/// produces the US character for that position. Announcing the layout is what makes the
/// scancode path safe.
///
/// Each entry was checked against what the Mac layout actually types (base and Shift level
/// of the main block, read with UCKeyTranslate) and against the Windows layout it names. Only
/// those two levels matter: whatever a layout composes with Option goes out as a character
/// (see handleKey), so the Option level never has to agree.
///
/// `.exact` means every key of those two levels agrees. `.closest` means the letters and
/// digits agree but some punctuation does not; the session gets a notice. A layout whose
/// letters would come out wrong — QWERTY on the Mac where Windows only has QWERTZ, Colemak —
/// is left out on purpose: it falls back to characters, which are always right except in
/// console programs that read raw input.
enum KeyboardLayoutID {
    enum Match { case exact, closest }

    struct Resolution {
        /// The input source as macOS names it, for the notice.
        let name: String
        /// nil = nothing to announce; typing goes out as characters.
        let klid: UInt32?
        let match: Match?
    }

    /// Windows KLIDs: the low word is the LANGID, the high word picks a variant.
    private static let map: [String: (UInt32, Match)] = [
        // US-shaped
        "US": (0x0000_0409, .exact),
        "ABC": (0x0000_0409, .exact),
        "USExtended": (0x0000_0409, .exact),
        "Australian": (0x0000_0409, .exact),
        "Canadian": (0x0000_0409, .exact),            // en-CA types on the US layout
        "Dutch": (0x0000_0409, .exact),               // the Mac one is plain US, not Windows "Dutch"
        "Brazilian": (0x0000_0409, .exact),           // "Brazilian – Legacy": plain US
        "ABC-India": (0x0000_0409, .closest),         // ₹ where US has `
        "USInternational-PC": (0x0002_0409, .exact),
        "Brazilian-Pro": (0x0002_0409, .exact),       // "Brazilian": US with ` ' ^ ~ " as dead keys
        "Dvorak": (0x0001_0409, .exact),
        "DVORAK-QWERTYCMD": (0x0001_0409, .exact),
        "Dvorak-Left": (0x0003_0409, .exact),
        "Dvorak-Right": (0x0004_0409, .exact),
        "Maori": (0x0000_0481, .exact),
        "NewZealand": (0x0000_0481, .closest),
        "Maltese": (0x0000_043A, .closest),
        // British Isles
        "British-PC": (0x0000_0809, .exact),
        "British": (0x0000_0809, .closest),           // Mac swaps " and @
        "Irish": (0x0000_1809, .closest),
        "IrishExtended": (0x0000_1809, .closest),
        "Welsh": (0x0000_0452, .closest),
        // Canada
        "Canadian-CSA": (0x0001_1009, .exact),        // Canadian Multilingual Standard
        "CanadianFrench-PC": (0x0000_1009, .closest), // Canadian French
        // German-speaking
        "German": (0x0000_0407, .exact),
        "German-DIN-2137": (0x0000_0407, .exact),
        "ABC-QWERTZ": (0x0000_0407, .exact),
        "Austrian": (0x0000_0407, .exact),            // Austria has no layout of its own
        "SwissGerman": (0x0000_0807, .exact),
        "SwissFrench": (0x0000_100C, .exact),
        // French-speaking: the Mac AZERTY is the Belgian one, not the French PC one
        "French": (0x0000_080C, .exact),
        "French-numerical": (0x0000_080C, .exact),
        "ABC-AZERTY": (0x0000_080C, .exact),
        "Belgian": (0x0000_080C, .exact),
        "French-PC": (0x0000_040C, .exact),
        // Southern Europe
        "Italian-Pro": (0x0000_0410, .exact),         // shown as "Italian"
        "Spanish-ISO": (0x0000_040A, .exact),         // shown as "Spanish"
        "Spanish": (0x0000_040A, .closest),           // "Spanish – Legacy"
        "LatinAmerican": (0x0000_080A, .exact),
        "Portuguese": (0x0000_0816, .closest),
        "Brazilian-ABNT2": (0x0001_0416, .exact),
        // Nordic
        "Swedish": (0x0000_041D, .exact),
        "Swedish-Pro": (0x0000_041D, .exact),
        "SwedishSami-PC": (0x0000_041D, .exact),
        "Finnish": (0x0000_040B, .exact),
        "FinnishExtended": (0x0002_083B, .exact),
        "FinnishSami-PC": (0x0001_083B, .exact),
        "Danish": (0x0000_0406, .exact),
        "Norwegian": (0x0000_0414, .closest),
        "NorwegianExtended": (0x0000_0414, .closest),
        "NorwegianSami-PC": (0x0000_0414, .closest),
        "Icelandic": (0x0000_040F, .exact),
        "Faroese": (0x0000_0438, .exact),
        // Central and Eastern Europe
        "PolishPro": (0x0000_0415, .exact),           // "Polish" = Polish (Programmers)
        "Polish": (0x0001_0415, .closest),            // "Polish – QWERTZ" = Polish (214)
        "Czech": (0x0000_0405, .exact),
        "Czech-QWERTY": (0x0001_0405, .exact),
        "Slovak": (0x0000_041B, .exact),
        "Slovak-QWERTY": (0x0001_041B, .exact),
        "Hungarian": (0x0000_040E, .exact),
        "Croatian-PC": (0x0000_041A, .exact),         // "Croatian – QWERTZ"
        "Romanian-Standard": (0x0001_0418, .exact),   // ă î â ș ț on [ ] \ ; '
        "Romanian": (0x0001_0418, .closest),          // QWERTY, diacritics elsewhere
        "Albanian": (0x0000_041C, .closest),
        "Estonian": (0x0000_0425, .exact),
        "Lithuanian": (0x0001_0427, .exact),          // ą č ę ė į š ų ū on the digit row
        "Lithuanian-LST1582": (0x0002_0427, .closest),
        "Latvian": (0x0001_0426, .closest),
        // Turkish: plain "Turkish" is F – Legacy on the Mac, Turkish-Standard is F
        "Turkish-Standard": (0x0001_041F, .exact),
        "Turkish": (0x0001_041F, .closest),
        "Turkish-QWERTY-PC": (0x0000_041F, .exact),   // "Turkish Q"
        "Turkish-QWERTY": (0x0000_041F, .closest),    // "Turkish Q – Legacy"
        "Azeri": (0x0000_042C, .exact),
        // Cyrillic
        "RussianWin": (0x0000_0419, .exact),          // "Russian – PC"
        "Russian": (0x0000_0419, .closest),
        "Russian-Phonetic": (0x0002_0419, .exact),
        "Ukrainian-PC": (0x0000_0422, .exact),
        "Ukrainian": (0x0000_0422, .closest),
        "Byelorussian": (0x0000_0423, .exact),
        "Bulgarian": (0x0000_0402, .exact),
        "Bulgarian-Phonetic": (0x0004_0402, .exact),
        "Serbian": (0x0000_0C1A, .exact),
        "Macedonian": (0x0000_042F, .closest),
        "Kazakh": (0x0000_043F, .closest),
        // Other scripts
        "Greek": (0x0000_0408, .exact),
        "GreekPolytonic": (0x0006_0408, .closest),
        "Hebrew-PC": (0x0000_040D, .exact),
        "Hebrew": (0x0000_040D, .closest),
        "ArabicPC": (0x0000_0401, .closest),
        "Arabic": (0x0000_0401, .closest),
        "Persian-ISIRI2901": (0x0005_0429, .exact),
        "Persian": (0x0005_0429, .closest),
        "Georgian-QWERTY": (0x0001_0437, .exact),
        "Thai": (0x0000_041E, .exact),
        "Thai-PattaChote": (0x0001_041E, .exact),
        "Vietnamese": (0x0000_042A, .exact),
    ]

    static func current() -> Resolution {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return Resolution(name: "?", klid: nil, match: nil) }
        let id = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
        var name = id
        if let rawName = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
            name = Unmanaged<CFString>.fromOpaque(rawName).takeUnretainedValue() as String
        }
        let prefix = "com.apple.keylayout."
        guard id.hasPrefix(prefix), let hit = map[String(id.dropFirst(prefix.count))] else {
            return Resolution(name: name, klid: nil, match: nil)
        }
        return Resolution(name: name, klid: hit.0, match: hit.1)
    }

    /// Whether the keyboard last typed on has the ISO shape (the extra key left of Z).
    /// macOS reports that key as kVK_ANSI_Grave there and the one left of 1 as
    /// kVK_ISO_Section, so the two keycodes mean different positions on ANSI and ISO.
    static var keyboardIsISO: Bool {
        KBGetLayoutType(Int16(LMGetKbdType())) == UInt32(kKeyboardISO)
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import SwiftTerm
import AppKit

/// Terminal with PuTTY-style behavior: copy-on-select + right-click paste.
/// SwiftTerm's `mouseUp` is `public` (not `open`), so we can't override it;
/// instead we use a gesture recognizer (right-click) + an event monitor
/// (left mouse up).
final class MRNGTerminalView: LocalProcessTerminalView {
    private var mouseUpMonitor: Any?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPuttyMouse()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPuttyMouse()
    }

    private func setupPuttyMouse() {
        let rightClick = NSClickGestureRecognizer(target: self, action: #selector(rightClickPaste))
        rightClick.buttonMask = 0x2 // right button only (left stays for selection)
        addGestureRecognizer(rightClick)

        // Copy-on-select: observe left-mouse-up (the selection is built from the drag).
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, event.window === self.window, self.selectionActive else { return event }
            let pt = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(pt), let text = self.getSelection(), !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return event // don't consume -> SwiftTerm still gets the event
        }
    }

    @objc private func rightClickPaste() {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            send(txt: text)
        }
    }

    deinit {
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
    }
}

/// SwiftUI wrapper around SwiftTerm's LocalProcessTerminalView.
/// Spawns the system ssh/telnet in a PTY embedded in the tab.
struct TerminalContainer: NSViewRepresentable {
    let session: Session
    let isActive: Bool
    let fontSize: Double
    var theme: String = "Implicit"

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = MRNGTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        term.font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        TerminalThemes.apply(theme, to: term)
        let (exe, args) = Self.command(for: session)
        term.startProcess(executable: exe, args: args, environment: nil, execName: nil)
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        let desired = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        if nsView.font.pointSize != desired.pointSize {
            nsView.font = desired
        }
        TerminalThemes.apply(theme, to: nsView)
        // Give the terminal first responder status when its tab becomes active.
        guard isActive else { return }
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.firstResponder is NSText { return } // user is typing in search etc.
            if window.firstResponder !== nsView { window.makeFirstResponder(nsView) }
        }
    }

    static func command(for session: Session) -> (String, [String]) {
        let node = session.node
        let host = node.hostname
        let port = node.port
        let user = node.username
        let target = user.isEmpty ? host : "\(user)@\(host)"

        switch session.kind {
        case .ssh:
            let sshArgs = [
                "-p", "\(port)",
                "-o", "UserKnownHostsFile=\(appKnownHostsPath())",
                "-o", "StrictHostKeyChecking=accept-new",
                target,
            ]
            // If we have a password AND sshpass is installed -> inject it.
            // Otherwise plain ssh (uses agent key or prompts interactively).
            if !session.password.isEmpty, let sshpass = sshpassPath() {
                return (sshpass, ["-p", session.password, "/usr/bin/ssh"] + sshArgs)
            }
            return ("/usr/bin/ssh", sshArgs)
        case .telnet:
            return ("/usr/bin/telnet", [host, "\(port)"])
        case .sftp:
            return ("/usr/bin/sftp", [
                "-P", "\(port)", // SFTP uses uppercase -P for the port
                "-o", "UserKnownHostsFile=\(appKnownHostsPath())",
                "-o", "StrictHostKeyChecking=accept-new",
                target,
            ])
        case .externalTool:
            return ("/bin/sh", ["-lc", session.command ?? "echo 'no command'"])
        default:
            return ("/bin/echo", ["Protocol not implemented in the terminal."])
        }
    }

    /// Look for an installed sshpass (brew). Returns the path, or nil.
    static func sshpassPath() -> String? {
        let candidates = ["/opt/homebrew/bin/sshpass", "/usr/local/bin/sshpass"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// App-specific known_hosts (separate from ~/.ssh/known_hosts), so we don't
    /// collide with old system entries and we can auto-accept on first connect.
    static func appKnownHostsPath() -> String {
        let fm = FileManager.default
        let base = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("mRemoteNXT", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("known_hosts").path
    }
}

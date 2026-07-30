// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit

/// What a window should show when it opens. Carried by `WindowGroup(for:)`, so macOS can
/// persist it and bring the same set of files back after a relaunch.
///
/// The `id` makes every request unique on purpose: SwiftUI reuses an existing window when
/// asked to open one for a value it already has, which would turn "New Window" into "focus
/// the window you already had". Opening the same *file* twice is deduplicated deliberately
/// instead, in `WindowRouter.present(url:preferring:)`.
struct WindowRequest: Hashable, Codable {
    var id = UUID()
    /// Configuration file to load. Empty = a deliberately blank window (File > New Window).
    var path: String = ""
}

/// The files that were open when the app last quit.
///
/// Read exactly once, the first time anything asks (`static let` is lazy), which is from the
/// first AppModel's init. That matters: as soon as a window loads a file the live list is
/// recomputed from the open windows, so by the time the restore runs the record of the
/// *other* files would already be gone.
enum LaunchState {
    static let openDocuments: [String] = UserDefaults.standard.stringArray(forKey: "openDocuments") ?? []
}

// MARK: - Focused window

/// Lets the menu bar act on the window the user is actually looking at. Menu commands are
/// built once for the whole app, so they can't capture a model; each window publishes its
/// own through `focusedSceneValue`, and the commands read it back.
struct AppModelFocusedValueKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedValueKey.self] }
        set { self[AppModelFocusedValueKey.self] = newValue }
    }
}

// MARK: - Registry

/// Which AppModel belongs to which NSWindow.
///
/// Needed by the parts that live outside the SwiftUI view tree: the quit confirmation (which
/// must total up every window), the close confirmation, the Settings window (which shows the
/// front document's master password), and the "this file is already open" check.
@MainActor
final class WindowRegistry: ObservableObject {
    static let shared = WindowRegistry()

    /// Model of the document window that was last key. Stays put while an auxiliary window
    /// (Settings, About) is in front, so Settings keeps showing the document it was opened
    /// over rather than blanking out.
    @Published private(set) var frontModel: AppModel?

    /// Set once quitting is under way. Windows closing as part of a quit must not rewrite
    /// the list of open files — otherwise the last one out would leave it empty and the next
    /// launch would come up blank.
    private(set) var isTerminating = false

    private final class Entry {
        weak var model: AppModel?
        /// Filled in once the window exists — the model is created first, while SwiftUI is
        /// still building the view.
        weak var window: NSWindow?
        /// Retained here: NSWindow.delegate is a weak reference.
        var closeGuard: WindowCloseGuard?
        var observers: [NSObjectProtocol] = []

        init(model: AppModel) { self.model = model }
    }

    private var entries: [Entry] = []

    var models: [AppModel] {
        entries.compactMap { $0.model }
    }

    /// Called by AppModel.init, before there is a window. Registering this early is what
    /// lets "is this file already open?" answer correctly while windows are still opening.
    func register(_ model: AppModel) {
        compact()
        guard !entries.contains(where: { $0.model === model }) else { return }
        entries.append(Entry(model: model))
        if frontModel == nil { frontModel = model }
    }

    /// Called (repeatedly, harmlessly) by WindowChrome as SwiftUI updates the view.
    func attach(model: AppModel, to window: NSWindow) {
        compact()
        register(model)
        guard let entry = entries.first(where: { $0.model === model }) else { return }

        if let existing = entry.closeGuard, entry.window === window {
            // SwiftUI can swap the window delegate after we wrapped it; re-wrap if so.
            if window.delegate !== existing {
                existing.next = window.delegate
                window.delegate = existing
            }
            if window.isKeyWindow { frontModel = model }
            return
        }

        let guardDelegate = WindowCloseGuard()
        guardDelegate.model = model
        guardDelegate.next = window.delegate
        window.delegate = guardDelegate
        entry.window = window
        entry.closeGuard = guardDelegate

        entry.observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak model, weak window] _ in
            MainActor.assumeIsolated {
                guard let model else { return }
                WindowRegistry.shared.frontModel = model
                // SwiftUI sometimes installs its own delegate after we wrapped it, which
                // would quietly bypass the close confirmation.
                if let window { WindowRegistry.shared.reassertGuard(for: window) }
                MainMenuFixup.apply()
            }
        })
        entry.observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window else { return }
                WindowRegistry.shared.detach(window)
            }
        })

        if window.isKeyWindow || frontModel == nil { frontModel = model }
        syncOpenDocuments()
    }

    /// Put our close confirmation back in front of the window's delegate chain if something
    /// else has taken over since.
    func reassertGuard(for window: NSWindow) {
        guard let entry = entries.first(where: { $0.window === window }),
              let closeGuard = entry.closeGuard,
              window.delegate !== closeGuard else { return }
        closeGuard.next = window.delegate
        window.delegate = closeGuard
    }

    private func detach(_ window: NSWindow) {
        // The sessions are not stopped here: SwiftUI tears the view hierarchy down and the
        // views stop their own RDP threads and terminal subprocesses. The model's session
        // list is deliberately left alone too, so reopening the file restores its tabs.
        if let entry = entries.first(where: { $0.window === window }) {
            entry.observers.forEach(NotificationCenter.default.removeObserver)
            if frontModel === entry.model { frontModel = nil }
        }
        entries.removeAll { $0.window === window }
        if frontModel == nil { frontModel = models.first }
        syncOpenDocuments()
    }

    private func compact() {
        for entry in entries where entry.model == nil {
            entry.observers.forEach(NotificationCenter.default.removeObserver)
        }
        entries.removeAll { $0.model == nil }
    }

    func window(for model: AppModel) -> NSWindow? {
        entries.first { $0.model === model }?.window
    }

    func model(withFile url: URL) -> AppModel? {
        let path = url.standardizedFileURL.path
        return models.first { $0.fileURL?.standardizedFileURL.path == path }
    }

    func focus(_ model: AppModel) {
        NSApp.activate(ignoringOtherApps: true)
        window(for: model)?.makeKeyAndOrderFront(nil)
    }

    /// Total open sessions and unsaved documents across every window (for the quit guard).
    var totals: (sessions: Int, dirty: Bool) {
        let m = models
        return (m.reduce(0) { $0 + $1.sessions.count }, m.contains { $0.dirty })
    }

    func saveAllDirty() {
        for m in models where m.dirty { m.save() }
    }

    func beginTermination() {
        isTerminating = true
    }

    // MARK: - Which files are open

    /// Remember every open file so the next launch can bring the same windows back.
    /// Recomputed from the live models, so it can't drift out of sync.
    func syncOpenDocuments() {
        guard !isTerminating else { return }
        compact()
        var seen = Set<String>()
        var paths: [String] = []
        for m in models {
            guard let p = m.fileURL?.path, !seen.contains(p) else { continue }
            seen.insert(p)
            paths.append(p)
        }
        UserDefaults.standard.set(paths, forKey: "openDocuments")
    }
}

// MARK: - Opening windows

/// Opening a window is a SwiftUI action that only exists inside a view. This keeps hold of
/// it so the menu bar and the launch-time restore can open windows too.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()
    private init() {}

    var openWindowAction: OpenWindowAction?

    /// A blank window, or one that loads `path`.
    func newWindow(path: String = "") {
        openWindowAction?(value: WindowRequest(path: path))
    }

    /// Show a configuration file, without ever opening it twice: the same file in two windows
    /// would be two independent copies of the same tree, and whichever saved last would
    /// silently discard the other's edits.
    func present(url: URL, preferring model: AppModel?) {
        if let existing = WindowRegistry.shared.model(withFile: url) {
            WindowRegistry.shared.focus(existing)
            return
        }
        // An empty window is a perfectly good place to put it; anything else gets its own.
        if let model, model.doc == nil {
            model.load(url: url)
            return
        }
        newWindow(path: url.path)
    }

    func openFilePanel(preferring model: AppModel?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        present(url: url, preferring: model)
    }

    func newDocumentPanel(preferring model: AppModel?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "confCons.xml"
        panel.message = t("NewDoc.Prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let failure = AppModel.writeEmptyDocument(to: url) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = t("NewDoc.FailedTitle")
            alert.informativeText = failure
            alert.runModal()
            return
        }
        present(url: url, preferring: model)
    }

    private var didRestoreWindows = false

    /// Run the restore once, from the first window that appears — by then `openWindowAction`
    /// exists and that window has loaded its own file, so it won't be opened twice.
    func restoreWindowsOnce() {
        guard !didRestoreWindows else { return }
        didRestoreWindows = true
        restoreWindows()
    }

    /// Reopen the files that were open at quit, one window each. Skips anything already on
    /// screen, so it is safe next to whatever macOS restored by itself.
    func restoreWindows() {
        guard Preferences.shared.restoreWindows else { return }
        let already = Set(WindowRegistry.shared.models.compactMap { $0.fileURL?.path })
        for path in LaunchState.openDocuments where !already.contains(path) {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            newWindow(path: path)
        }
    }
}

// MARK: - Close confirmation

/// Asks before a window takes its open connections down with it.
///
/// Wraps whatever delegate SwiftUI installed rather than replacing it: everything except
/// `windowShouldClose(_:)` is forwarded on untouched.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    weak var next: NSWindowDelegate?
    weak var model: AppModel?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { confirmClose() }
    }

    @MainActor
    private func confirmClose() -> Bool {
        guard let model else { return true }
        let sessions = model.sessions.count
        let dirty = model.dirty
        guard sessions > 0 || dirty else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("CloseWindow.Title")
        alert.informativeText = {
            if sessions > 0 && dirty { return String(format: t("CloseWindow.BodyBoth"), sessions) }
            if sessions > 0 { return String(format: t("CloseWindow.BodySessions"), sessions) }
            return t("CloseWindow.BodyUnsaved")
        }()
        alert.addButton(withTitle: t("CloseWindow.Confirm"))   // first = default
        alert.addButton(withTitle: t("Delete.Cancel"))
        if dirty { alert.addButton(withTitle: t("CloseWindow.SaveAndClose")) }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertThirdButtonReturn where dirty:
            model.save()
            return true
        default:
            return false
        }
    }

    // Forward everything else to SwiftUI's own delegate.
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return next?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if super.responds(to: aSelector) { return nil }
        return next
    }
}

// MARK: - Main menu

/// Cmd+W used to close the whole window — every open connection with it — while Cmd+Q, the
/// neighbouring key, asked for confirmation. Cmd+W is now Close Tab (as in Safari) and the
/// window moves to Shift+Cmd+W, both defined in MRNGCommands. This strips the shortcut from
/// the Close item AppKit adds by itself, which would otherwise claim Cmd+W first.
enum MainMenuFixup {
    @MainActor
    static func apply() {
        guard let main = NSApp.mainMenu else { return }
        for item in main.items {
            guard let submenu = item.submenu else { continue }
            for sub in submenu.items where sub.action == #selector(NSWindow.performClose(_:)) {
                guard !sub.keyEquivalent.isEmpty else { continue }
                sub.keyEquivalent = ""
                sub.keyEquivalentModifierMask = []
                sub.isHidden = true
            }
        }
    }
}

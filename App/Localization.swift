// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation
import SwiftUI

/// Shorthand for NSLocalizedString. Default behavior pulls from the bundle's
/// Localizable.strings for the active language (set via `AppleLanguages`).
func t(_ key: String, _ comment: String = "") -> String {
    LanguageManager.shared.localized(key, comment: comment)
}

/// Manages the user's language preference. macOS resolves `AppleLanguages`
/// at app launch — we re-implement bundle lookup at runtime so the language
/// switch in Settings takes effect immediately (no restart required for
/// 99% of UI; views holding stale strings will refresh on next redraw).
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    enum Choice: String, CaseIterable, Identifiable {
        case auto = "auto"
        case en   = "en"
        case ro   = "ro"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .auto: return NSLocalizedString("Language.Auto", comment: "System default")
            case .en:   return "English"
            case .ro:   return "Romana"
            }
        }
    }

    @Published var choice: Choice {
        didSet {
            UserDefaults.standard.set(choice.rawValue, forKey: "languageChoice")
            applyChoice()
        }
    }

    private var bundle: Bundle = .main

    private init() {
        let raw = UserDefaults.standard.string(forKey: "languageChoice") ?? Choice.auto.rawValue
        self.choice = Choice(rawValue: raw) ?? .auto
        applyChoice()
    }

    func localized(_ key: String, comment: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    private func applyChoice() {
        let lang: String
        switch choice {
        case .auto:
            // Honor the system preference.
            lang = (Locale.preferredLanguages.first ?? "en").prefix(2).lowercased() == "ro" ? "ro" : "en"
        case .en: lang = "en"
        case .ro: lang = "ro"
        }
        // Sync AppleLanguages too, so newly-spawned strings (alerts via OS) pick it up.
        UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let b = Bundle(path: path) {
            bundle = b
        } else {
            bundle = .main
        }
        // Nudge observers so SwiftUI views re-render with new strings.
        objectWillChange.send()
    }
}

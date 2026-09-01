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
///
/// Nothing here names a language. The list comes from the `.lproj` folders that
/// are actually in the bundle, so adding a translation is adding one folder —
/// no enum to extend, no array to remember, no Swift to touch at all.
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    /// Language codes shipped in this build, discovered from the bundle.
    ///
    /// Deduplicated on purpose: Bundle.localizations answers from the .lproj folders *and*
    /// from CFBundleLocalizations, so a language named in both comes back twice — and twice
    /// in a Picker means two identical rows and two views claiming one id.
    static let bundledLanguages: [String] = Array(Set(Bundle.main.localizations))
        .filter { $0 != "Base" }
        .sorted()

    /// What the user picked: a language code, or `auto` to follow the system.
    struct Choice: Identifiable, Hashable {
        let rawValue: String
        init(_ rawValue: String) { self.rawValue = rawValue }

        static let auto = Choice("auto")
        var id: String { rawValue }

        /// The language's own name for itself — "Français", "Türkçe" — so a reader can
        /// find their language without knowing the one the app is currently in.
        ///
        /// Asked as an identifier rather than as a language code, because a regional one
        /// loses its region otherwise: pt-BR comes back as "português" from the language
        /// form and "português (Brasil)" from this one, which is the distinction a Brazilian
        /// reader is looking for. For plain codes the two agree.
        var displayName: String {
            guard rawValue != Choice.auto.rawValue else { return t("Language.Auto") }
            let locale = Locale(identifier: rawValue)
            guard let name = locale.localizedString(forIdentifier: rawValue)
                    ?? locale.localizedString(forLanguageCode: rawValue) else {
                return rawValue.uppercased()
            }
            return name.capitalized(with: locale)
        }

        /// `auto` first, then every bundled language.
        static var allCases: [Choice] {
            [.auto] + LanguageManager.bundledLanguages.map(Choice.init)
        }
    }

    @Published var choice: Choice {
        didSet {
            UserDefaults.standard.set(choice.rawValue, forKey: "languageChoice")
            applyChoice()
        }
    }

    private var bundle: Bundle = .main
    /// English, kept aside to answer for keys a translation has not reached yet.
    private let fallbackBundle: Bundle? = Bundle.main.path(forResource: "en", ofType: "lproj")
        .flatMap(Bundle.init(path:))

    private init() {
        let raw = UserDefaults.standard.string(forKey: "languageChoice") ?? Choice.auto.rawValue
        // A language that was removed from the build (or a stale preference) must not leave
        // the app pointing at a bundle that isn't there.
        let known = [Choice.auto.rawValue] + Self.bundledLanguages
        self.choice = known.contains(raw) ? Choice(raw) : .auto
        applyChoice()
    }

    /// Sentinel that cannot occur as a translated value, so "missing" is distinguishable
    /// from "translated to something short".
    private static let missing = "\u{0}mrng.missing"

    /// A key the active language does not carry falls back to English rather than to the
    /// key itself. Without this a translation had to be complete on its first day or the
    /// interface showed raw identifiers like `Settings.MasterPasswordNote` — which is a
    /// hard thing to ask of someone contributing an evening of their time.
    func localized(_ key: String, comment: String) -> String {
        let value = bundle.localizedString(forKey: key, value: Self.missing, table: nil)
        if value != Self.missing { return value }
        return fallbackBundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    private func applyChoice() {
        let lang: String
        if choice == .auto {
            // The system reports something like "pt-BR" or "en-RO". Take an exact match
            // first, then fall back to any bundled language sharing its base: chopping to
            // two letters and looking for "pt" would miss a translation filed as pt-BR and
            // hand a Brazilian Mac English instead.
            let preferred = Locale.preferredLanguages.first ?? "en"
            let base = String(preferred.prefix(2)).lowercased()
            if Self.bundledLanguages.contains(preferred) {
                lang = preferred
            } else if let regional = Self.bundledLanguages.first(where: {
                $0.lowercased() == base || $0.lowercased().hasPrefix(base + "-")
            }) {
                lang = regional
            } else {
                lang = "en"
            }
        } else {
            lang = choice.rawValue
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

// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import AppKit
import SwiftTerm

struct TerminalTheme {
    let background: String   // hex "RRGGBB"
    let foreground: String
    let cursor: String
    let ansi: [String]       // 16 ANSI colors
}

enum TerminalThemes {
    /// "Implicit" (Default) = SwiftTerm's stock theme; we don't override it.
    static let names = ["Implicit", "macOS Light", "Solarized Dark", "Dracula", "Nord", "Solarized Light"]

    static let all: [String: TerminalTheme] = [
        "macOS Light": TerminalTheme(
            background: "f2f2f2", foreground: "000000", cursor: "000000",
            ansi: ["000000", "990000", "00a600", "999900", "0000b2", "b200b2", "00a6b2", "bfbfbf",
                   "666666", "e50000", "00d900", "e5e500", "0000ff", "e500e5", "00e5e5", "e5e5e5"]),
        "Solarized Dark": TerminalTheme(
            background: "002b36", foreground: "839496", cursor: "93a1a1",
            ansi: ["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                   "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"]),
        "Dracula": TerminalTheme(
            background: "282a36", foreground: "f8f8f2", cursor: "f8f8f2",
            ansi: ["21222c", "ff5555", "50fa7b", "f1fa8c", "bd93f9", "ff79c6", "8be9fd", "f8f8f2",
                   "6272a4", "ff6e6e", "69ff94", "ffffa5", "d6acff", "ff92df", "a4ffff", "ffffff"]),
        "Nord": TerminalTheme(
            background: "2e3440", foreground: "d8dee9", cursor: "d8dee9",
            ansi: ["3b4252", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "88c0d0", "e5e9f0",
                   "4c566a", "bf616a", "a3be8c", "ebcb8b", "81a1c1", "b48ead", "8fbcbb", "eceff4"]),
        "Solarized Light": TerminalTheme(
            background: "fdf6e3", foreground: "657b83", cursor: "586e75",
            ansi: ["073642", "dc322f", "859900", "b58900", "268bd2", "d33682", "2aa198", "eee8d5",
                   "002b36", "cb4b16", "586e75", "657b83", "839496", "6c71c4", "93a1a1", "fdf6e3"]),
    ]

    // SwiftTerm's default ANSI palette (for restoring the "Implicit" theme).
    private static let defaultPalette = [
        "000000", "990001", "00a603", "999900", "0300b2", "b200b2", "00a5b2", "bfbfbf",
        "8a898a", "e50001", "00d800", "e5e500", "0700fe", "e500e5", "00e5e5", "e5e5e5",
    ]
    // Default colors captured once (bg/fg/cursor are not derivable from the palette).
    private static var defaultBg: NSColor?
    private static var defaultFg: NSColor?
    private static var defaultCaret: NSColor?

    static func apply(_ name: String, to term: LocalProcessTerminalView) {
        // Capture the default colors before any modification (once).
        if defaultBg == nil {
            defaultBg = term.nativeBackgroundColor
            defaultFg = term.nativeForegroundColor
            defaultCaret = term.caretColor
        }

        if name == "Implicit" || all[name] == nil {
            term.installColors(defaultPalette.map(swiftTermColor))
            if let bg = defaultBg { term.nativeBackgroundColor = bg }
            if let fg = defaultFg { term.nativeForegroundColor = fg }
            if let c = defaultCaret { term.caretColor = c }
            term.needsDisplay = true
            return
        }

        let theme = all[name]!
        if theme.ansi.count == 16 {
            term.installColors(theme.ansi.map(swiftTermColor))
        }
        term.nativeBackgroundColor = nsColor(theme.background)
        term.nativeForegroundColor = nsColor(theme.foreground)
        term.caretColor = nsColor(theme.cursor)
        term.needsDisplay = true
    }

    private static func bytes(_ hex: String) -> (UInt8, UInt8, UInt8) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        return (UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
    }

    private static func swiftTermColor(_ hex: String) -> SwiftTerm.Color {
        let (r, g, b) = bytes(hex)
        return SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }

    private static func nsColor(_ hex: String) -> NSColor {
        let (r, g, b) = bytes(hex)
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

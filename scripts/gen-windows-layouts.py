#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
# See LICENSE for full text.
"""Generate App/WindowsLayouts.swift from Unicode CLDR's Windows keyboard data.

Usage: scripts/gen-windows-layouts.py <cldr>/keyboards/windows > App/WindowsLayouts.swift

The data is CLDR release-43, the last release that still carries keyboards/windows
(https://github.com/unicode-org/cldr/tree/release-43/keyboards/windows), under the Unicode
License v3 — see NOTICE. For every Windows layout the app announces (KeyboardLayoutID in
App/RDPView.swift) it records which key, on which level, types each character, so a
character the Mac composed can be sent to Windows as the keystroke that types it there.
"""
import os, re, sys
import xml.etree.ElementTree as ET

# KLID -> the layout's name in CLDR (<names><name value=...>) and the file it is in.
LAYOUTS = {
    0x00000409: "en-t-k0-windows.xml",            # US
    0x00020409: "en-t-k0-windows-extended.xml",   # United States-International
    0x00010409: "en-t-k0-windows-dvorak.xml",
    0x00030409: "en-t-k0-windows-dvorakl.xml",
    0x00040409: "en-t-k0-windows-dvorakr.xml",
    0x00000481: "mi-t-k0-windows.xml",            # Maori
    0x0000043A: "mt-t-k0-windows-101key.xml",     # Maltese 47-Key
    0x00000809: "en-GB-t-k0-windows.xml",
    0x00001809: "ga-t-k0-windows.xml",            # Irish
    0x00000452: "en-GB-t-k0-windows-extended.xml",
    0x00011009: "fr-CA-t-k0-windows.xml",         # Canadian Multilingual Standard
    0x00001009: "fr-CA-t-k0-windows-var.xml",     # Canadian French
    0x00000407: "de-t-k0-windows.xml",
    0x00000807: "de-CH-t-k0-windows.xml",
    0x0000100C: "fr-CH-t-k0-windows.xml",
    0x0000080C: "fr-BE-t-k0-windows.xml",         # Belgian French
    0x0000040C: "fr-t-k0-windows.xml",
    0x00000410: "it-t-k0-windows.xml",
    0x0000040A: "es-t-k0-windows.xml",
    0x0000080A: "es-419-t-k0-windows.xml",
    0x00000816: "pt-PT-t-k0-windows.xml",
    0x00010416: "pt-t-k0-windows-var.xml",        # Portuguese (Brazil ABNT2)
    0x0000041D: "sv-t-k0-windows.xml",
    0x0000040B: "fi-t-k0-windows.xml",
    0x0002083B: "se-FI-t-k0-windows.xml",         # Sami Extended Finland-Sweden
    0x0001083B: "fi-t-k0-windows-extended.xml",   # Finnish with Sami
    0x00000406: "da-t-k0-windows.xml",
    0x00000414: "nb-t-k0-windows.xml",
    0x0000040F: "is-t-k0-windows.xml",
    0x00000438: "fo-t-k0-windows.xml",
    0x00000415: "pl-t-k0-windows-extended.xml",   # Polish (Programmers)
    0x00010415: "pl-t-k0-windows.xml",            # Polish (214)
    0x00000405: "cs-t-k0-windows.xml",
    0x00010405: "cs-t-k0-windows-qwerty.xml",
    0x0000041B: "sk-t-k0-windows.xml",
    0x0001041B: "sk-t-k0-windows-qwerty.xml",
    0x0000040E: "hu-t-k0-windows.xml",
    0x0000041A: "sl-t-k0-windows.xml",            # Croatian = the Slovenian layout
    0x00010418: "ro-t-k0-windows.xml",            # Romanian (Standard)
    0x0000041C: "sq-t-k0-windows.xml",
    0x00000425: "et-t-k0-windows.xml",
    0x00010427: "lt-t-k0-windows.xml",
    0x00020427: "lt-t-k0-windows-lt1582.xml",
    0x00010426: "lv-t-k0-windows-qwerty.xml",
    0x0001041F: "tr-t-k0-windows-legacy.xml",     # Turkish F
    0x0000041F: "tr-t-k0-windows.xml",            # Turkish Q
    0x0000042C: "az-t-k0-windows.xml",
    0x00000419: "ru-t-k0-windows.xml",
    0x00020419: "ru-t-k0-windows-phonetic.xml",
    0x00000422: "uk-t-k0-windows.xml",
    0x00000423: "be-t-k0-windows.xml",
    0x00000402: "bg-t-k0-windows-legacy.xml",     # Bulgarian (Typewriter)
    0x00040402: "bg-t-k0-windows-qwerty-legacy.xml",
    0x00000C1A: "sr-t-k0-windows.xml",
    0x0000042F: "mk-t-k0-windows-legacy.xml",
    0x0000043F: "kk-t-k0-windows.xml",
    0x00000408: "el-t-k0-windows.xml",
    0x00060408: "el-POLYTON-t-k0-windows.xml",
    0x0000040D: "he-t-k0-windows.xml",
    0x00000401: "ar-t-k0-windows.xml",
    0x00050429: "fa-t-k0-windows-extended.xml",
    0x00010437: "ka-t-k0-windows-qwerty.xml",
    0x0000041E: "th-t-k0-windows.xml",
    0x0001041E: "th-t-k0-windows-patta.xml",
    0x0000042A: "vi-t-k0-windows.xml",
}

# ISO key position -> PC set-1 scancode.
ISO = {"E00": 0x29, "E11": 0x0C, "E12": 0x0D, "D11": 0x1A, "D12": 0x1B, "D13": 0x2B,
       "C10": 0x27, "C11": 0x28, "C12": 0x2B, "B00": 0x56, "B08": 0x33, "B09": 0x34,
       "B10": 0x35, "A03": 0x39}
ISO.update({f"E{i:02d}": 0x01 + i for i in range(1, 11)})
ISO.update({f"D{i:02d}": 0x0F + i for i in range(1, 11)})
ISO.update({f"C{i:02d}": 0x1D + i for i in range(1, 10)})
ISO.update({f"B{i:02d}": 0x2B + i for i in range(1, 8)})

def unescape(s):
    return re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), s)

def level(mods):
    """0 base, 1 Shift, 2 AltGr, 3 AltGr+Shift; None for Caps Lock and Ctrl maps."""
    if mods is None:
        return 0
    first = mods.split()[0]
    required = {t for t in first.split("+") if not t.endswith("?")}
    if "caps" in required:
        return None
    if "altR" in required or {"ctrl", "alt"} <= required:
        return 3 if "shift" in required else 2
    if "ctrl" in required:
        return None
    if required == {"shift"}:
        return 1
    return 0 if not required else None

def table(path):
    root = ET.parse(path).getroot()
    dead = set()
    for t in root.iter("transform"):
        frm = unescape(t.get("from", ""))
        if len(frm) >= 2:
            dead.add(frm[0])
    best = {}
    for km in root.iter("keyMap"):
        lv = level(km.get("modifiers"))
        if lv is None:
            continue
        for m in km.iter("map"):
            code = ISO.get(m.get("iso"))
            ch = unescape(m.get("to", ""))
            if code is None or len(ch) != 1 or ch in dead or ord(ch) < 0x20:
                continue
            if ch not in best or lv < best[ch][1]:
                best[ch] = (code, lv)
    return best

def literal(entries):
    out = []
    for ch, (code, lv) in sorted(entries.items(), key=lambda e: (e[1][1], e[1][0], e[0])):
        c = ch if 0x21 <= ord(ch) < 0x7F or (ord(ch) > 0xA0 and ch.isprintable() and not 0x300 <= ord(ch) < 0x370) \
            else "\\#u{%X}" % ord(ch)
        out.append(f"{c}{code:02X}{lv}")
    return "".join(out)

def main():
    base = sys.argv[1]
    print("""// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.
//
// GENERATED by scripts/gen-windows-layouts.py — do not edit by hand.
// Keyboard layout data derived from Unicode CLDR release-43 (keyboards/windows),
// Copyright © 1991-2023 Unicode, Inc., used under the Unicode License v3 (see NOTICE).

/// Which key types each character on the Windows layouts the app announces.
enum WindowsLayouts {
    /// KLID -> entries of four scalars each: the character, two hex digits of its set-1
    /// scancode, and the level it sits on — 0 base, 1 Shift, 2 AltGr, 3 AltGr+Shift.
    /// Dead keys are left out: alone they type nothing.
    static let packed: [UInt32: String] = [""")
    for klid, name in sorted(LAYOUTS.items()):
        entries = table(os.path.join(base, name))
        print(f"        0x{klid:08X}: #\"{literal(entries)}\"#,  // {name}, {len(entries)} characters")
    print("""    ]
}""")

main()

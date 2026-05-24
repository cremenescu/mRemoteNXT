// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import AppKit

/// mRemoteNG icon set (v1.76.20), bundled as PNG in Resources/.
/// Names match the values of the `Icon` attribute in confCons.xml.
enum IconLibrary {
    static let names: [String] = [
        "Anti Virus", "Backup", "Build Server", "Database", "Domain Controller", "ESX",
        "Fax", "File Server", "Finance", "Firewall", "Linux", "Log", "Mail Server", "PuTTY",
        "Remote Desktop", "Router", "SSH", "SharePoint", "Switch", "Tel", "Telnet",
        "Terminal Server", "Test Server", "Virtual Machine", "Web Server", "WiFi", "Windows",
        "Workstation", "mRemote", "mRemoteNG",
    ]

    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if name.isEmpty { return nil }
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }
}

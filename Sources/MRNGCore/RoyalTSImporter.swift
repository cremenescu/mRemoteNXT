// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

/// Reads a Royal TS / Royal TSX document (`.rtsz`) into mRemoteNG nodes.
///
/// The format: a `RTSZDocument` root holding a FLAT list of objects, each with its own
/// `ID` and a `ParentID` pointing at its folder, ordered by `PositionNr`. Values are child
/// elements, not attributes. A `.rtsz` file is either that XML directly, or a zip with the
/// XML inside as `Document.rtsz`.
///
/// Passwords are never imported. Royal saves every secret encrypted with the document's
/// key (a base64 blob even for a short password, with or without a document password), so
/// taking `CredentialPassword` as it is would store that blob as the password. The result
/// says how many were left out.
public enum RoyalTSImporter {
    public enum ImportError: Error, LocalizedError {
        case unreadable
        case notARoyalDocument

        public var errorDescription: String? {
            switch self {
            case .unreadable:         return "The file could not be read."
            case .notARoyalDocument:  return "This is not a Royal TS document (no RTSZDocument root)."
            }
        }
    }

    public struct Result {
        public let roots: [MRNGNode]
        public let documentName: String
        public let connections: Int
        /// Passwords the document held, on connections or shared credentials, left out.
        public let passwordsNotImported: Int
        /// Royal object types that were skipped because mRemoteNG has no equivalent.
        public let skipped: [String: Int]
    }

    private static let folderTag = "RoyalFolder"
    private static let credentialTag = "RoyalCredential"
    private static let innerName = "Document.rtsz"

    /// CredentialMode 2 is "a username and password on the connection itself"; the other
    /// modes point at a shared RoyalCredential, by CredentialId or CredentialName.
    private static let credentialModeSpecified = "2"

    /// Usernames of the document's shared credentials, by ID and by name.
    private struct SharedCredentials {
        var byID: [String: String] = [:]
        var byName: [String: String] = [:]
    }

    public static func load(fileURL: URL) throws -> Result {
        let xml = try readXML(at: fileURL)
        guard let root = xml.rootElement(), root.name == "RTSZDocument" else {
            throw ImportError.notARoyalDocument
        }
        let elements = root.children?.compactMap({ $0 as? XMLElement }) ?? []

        var shared = SharedCredentials()
        var passwordsNotImported = 0
        for element in elements where element.name == credentialTag {
            let user = text(element, "UserName")
            let id = text(element, "ID"), name = text(element, "Name")
            if !id.isEmpty, shared.byID[id] == nil { shared.byID[id] = user }
            if !name.isEmpty, shared.byName[name] == nil { shared.byName[name] = user }
            if !text(element, "Password").isEmpty { passwordsNotImported += 1 }
        }

        var nodes: [String: MRNGNode] = [:]
        var parentOf: [String: String] = [:]
        var positionOf: [String: Int] = [:]
        var order: [String] = []
        var documentName = "Royal TS"
        var trash = Set<String>()
        var skipped: [String: Int] = [:]

        for element in elements {
            let tag = element.name ?? ""
            let id = text(element, "ID")

            if tag == "RoyalDocument" {
                let n = text(element, "Name")
                if !n.isEmpty { documentName = n }
                continue
            }
            // Royal keeps deleted objects in the document under RoyalTrash; skip that
            // subtree, otherwise deleted connections reappear on import.
            if tag == "RoyalTrash" { trash.insert(id); continue }
            if tag == credentialTag { continue }   // read above
            guard !id.isEmpty else { continue }

            guard let node = makeNode(tag: tag, element: element, shared: shared) else {
                skipped[tag, default: 0] += 1
                continue
            }
            if !text(element, "CredentialPassword").isEmpty { passwordsNotImported += 1 }
            nodes[id] = node
            parentOf[id] = text(element, "ParentID")
            positionOf[id] = Int(text(element, "PositionNr")) ?? 0
            order.append(id)
        }

        // Assemble the tree. Sorting by PositionNr keeps Royal's own ordering.
        var roots: [MRNGNode] = []
        for id in order.sorted(by: { (positionOf[$0] ?? 0, $0) < (positionOf[$1] ?? 0, $1) }) {
            guard let node = nodes[id] else { continue }
            let parent = parentOf[id] ?? ""
            if trash.contains(parent) { continue }
            if let p = nodes[parent] {
                p.addChild(node)
            } else {
                roots.append(node)
            }
        }

        let connections = roots.flatMap { $0.selfAndDescendants() }.filter { !$0.isContainer }.count
        return Result(roots: roots, documentName: documentName, connections: connections,
                      passwordsNotImported: passwordsNotImported, skipped: skipped)
    }

    // MARK: - One object

    private static func makeNode(tag: String, element: XMLElement,
                                 shared: SharedCredentials) -> MRNGNode? {
        let name = text(element, "Name")

        if tag == folderTag {
            let node = MRNGNode.makeContainer(name: name.isEmpty ? "Folder" : name)
            node.attributes["Expanded"] = text(element, "IsExpanded", default: "True") == "True" ? "true" : "false"
            applyCommon(node, element, shared: shared)
            return node
        }

        let proto: String
        var portField = "Port"
        switch tag {
        case "RoyalRDSConnection":
            proto = "RDP"; portField = "RDPPort"
        case "RoyalSSHConnection":
            // Royal models Telnet as an SSH connection with a flag rather than its own type.
            proto = text(element, "IsTelnetConnection") == "True" ? "Telnet" : "SSH2"
        case "RoyalWebConnection":
            proto = text(element, "URI").lowercased().hasPrefix("http://") ? "HTTP" : "HTTPS"
        case "RoyalVNCConnection":
            proto = "VNC"
        default:
            return nil   // RoyalApplicationConnection, RoyalTerminalServiceGateway, ...
        }

        let node = MRNGNode.makeConnection(name: name.isEmpty ? text(element, "URI") : name,
                                           protocolType: proto,
                                           hostname: hostname(from: text(element, "URI"), proto: proto))
        let port = text(element, portField)
        if let p = Int(port), p > 0 { node.attributes["Port"] = String(p) }
        applyCommon(node, element, shared: shared)
        return node
    }

    private static func applyCommon(_ node: MRNGNode, _ element: XMLElement,
                                    shared: SharedCredentials) {
        let descr = text(element, "Description")
        if !descr.isEmpty { node.attributes["Descr"] = descr }

        // Royal's "take the credentials from the parent folder" is the same idea as
        // mRemoteNG's Inherit* flags, so it maps across instead of being flattened.
        if text(element, "CredentialFromParent") == "True" {
            for key in ["InheritUsername", "InheritDomain", "InheritPassword"] {
                node.attributes[key] = "true"
            }
            return
        }

        var user = text(element, "CredentialUsername")
        if text(element, "CredentialMode") != credentialModeSpecified,
           let sharedUser = shared.byID[text(element, "CredentialId")]
                ?? shared.byName[text(element, "CredentialName")] {
            user = sharedUser
        }
        // A DOMAIN\user in one field becomes the two fields mRemoteNG keeps separately.
        if let slash = user.firstIndex(of: "\\") {
            node.attributes["Domain"] = String(user[user.startIndex..<slash])
            user = String(user[user.index(after: slash)...])
        }
        if !user.isEmpty { node.attributes["Username"] = user }
    }

    /// Royal's URI can carry a scheme and a path for web connections; mRemoteNG's Hostname
    /// is a bare host for everything else.
    private static func hostname(from uri: String, proto: String) -> String {
        if proto == "HTTP" || proto == "HTTPS" { return uri }
        guard let range = uri.range(of: "://") else { return uri }
        let rest = uri[range.upperBound...]
        return String(rest.prefix(while: { $0 != "/" }))
    }

    // MARK: - File

    private static func readXML(at url: URL) throws -> XMLDocument {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magic = try? handle.read(upToCount: 2) else { throw ImportError.unreadable }
        try? handle.close()

        let data: Data
        if magic == Data("PK".utf8) {
            // Zipped container: the XML lives inside as Document.rtsz.
            data = try unzipInner(url)
        } else {
            guard let d = try? Data(contentsOf: url) else { throw ImportError.unreadable }
            data = d
        }
        guard let doc = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]) else {
            throw ImportError.unreadable
        }
        return doc
    }

    /// Uses /usr/bin/unzip rather than pulling in a zip library for one file; it ships with
    /// every macOS.
    private static func unzipInner(_ url: URL) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, innerName]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw ImportError.unreadable }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard !out.isEmpty else { throw ImportError.unreadable }
        return out
    }

    private static func text(_ element: XMLElement, _ name: String, default def: String = "") -> String {
        guard let child = element.elements(forName: name).first,
              let s = child.stringValue else { return def }
        return s
    }
}

extension MRNGNode {
    /// This node plus everything beneath it.
    func selfAndDescendants() -> [MRNGNode] {
        [self] + children.flatMap { $0.selfAndDescendants() }
    }
}

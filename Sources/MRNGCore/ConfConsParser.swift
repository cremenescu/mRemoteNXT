// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation

public enum ConfConsError: Error {
    case fileNotReadable
    case noRootElement
    case fullFileEncryptionUnsupported
}

/// SAX parser for confCons.xml (mRemoteNG format, ConfVersion 2.x).
public final class ConfConsParser: NSObject, XMLParserDelegate {
    private var stack: [MRNGNode] = []
    private var roots: [MRNGNode] = []

    private var encryptionEngine = "AES"
    private var blockCipherMode = "GCM"
    private var kdfIterations = 1000
    private var fullFileEncryption = false
    private var protectedValue = ""
    private var confVersion = ""
    private var foundRoot = false
    private var seenIDs: Set<String> = []
    private var repairedDuplicateIDs = 0

    public static func parse(fileURL: URL) throws -> ConfCons {
        guard let parser = XMLParser(contentsOf: fileURL) else { throw ConfConsError.fileNotReadable }
        let delegate = ConfConsParser()
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? ConfConsError.noRootElement
        }
        guard delegate.foundRoot else { throw ConfConsError.noRootElement }
        if delegate.fullFileEncryption { throw ConfConsError.fullFileEncryptionUnsupported }
        var doc = ConfCons(
            encryptionEngine: delegate.encryptionEngine,
            blockCipherMode: delegate.blockCipherMode,
            kdfIterations: delegate.kdfIterations,
            fullFileEncryption: delegate.fullFileEncryption,
            protected: delegate.protectedValue,
            confVersion: delegate.confVersion,
            roots: delegate.roots
        )
        doc.repairedDuplicateIDs = delegate.repairedDuplicateIDs
        return doc
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String,
                       namespaceURI: String?, qualifiedName qName: String?,
                       attributes attributeDict: [String: String]) {
        switch elementName {
        case "mrng:Connections", "Connections":
            foundRoot = true
            encryptionEngine = attributeDict["EncryptionEngine"] ?? encryptionEngine
            blockCipherMode = attributeDict["BlockCipherMode"] ?? blockCipherMode
            kdfIterations = Int(attributeDict["KdfIterations"] ?? "") ?? kdfIterations
            fullFileEncryption = (attributeDict["FullFileEncryption"] ?? "false") == "true"
            protectedValue = attributeDict["Protected"] ?? ""
            confVersion = attributeDict["ConfVersion"] ?? ""
        case "Node":
            // The first node to claim an Id keeps it; a later one gets a fresh id. Older
            // builds wrote a duplicate's copy with the original's Id, and a file with two
            // nodes under one Id has every lookup landing on the first of them.
            var id = attributeDict["Id"] ?? UUID().uuidString.lowercased()
            if seenIDs.contains(id) {
                id = UUID().uuidString.lowercased()
                repairedDuplicateIDs += 1
            }
            seenIDs.insert(id)
            let node = MRNGNode(
                id: id,
                name: attributeDict["Name"] ?? "(no name)",
                isContainer: (attributeDict["Type"] ?? "") == "Container",
                attributes: attributeDict
            )
            if let parent = stack.last {
                node.parent = parent
                parent.children.append(node)
            } else {
                roots.append(node)
            }
            stack.append(node)
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String,
                       namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Node" && !stack.isEmpty {
            stack.removeLast()
        }
    }
}

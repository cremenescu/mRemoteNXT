// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import MRNGCore
import UniformTypeIdentifiers

extension MRNGNode {
    var sfSymbol: String { iconInfo.symbol }

    /// Map an mRemoteNG icon name -> (SF Symbol, color). Falls back per-protocol.
    var iconInfo: (symbol: String, color: Color) {
        if isContainer { return ("folder.fill", .accentColor) }
        switch icon {
        case "Windows":         return ("pc", .blue)
        case "Linux":           return ("terminal", .teal)
        case "SSH":             return ("terminal", .green)
        case "Switch":          return ("network", .indigo)
        case "Firewall":        return ("flame", .red)
        case "Virtual Machine": return ("macwindow", .purple)
        case "Terminal Server": return ("display", .blue)
        case "Router":          return ("network", .green)
        case "SharePoint":      return ("square.grid.2x2", .teal)
        case "Backup":          return ("externaldrive", .brown)
        case "Web Server":      return ("globe", .blue)
        case "Build Server":    return ("hammer", .orange)
        case "ESX":             return ("square.stack.3d.up.fill", .purple)
        case "Workstation":     return ("desktopcomputer", .gray)
        case "Database":        return ("cylinder.split.1x2", .brown)
        case "WiFi":            return ("wifi", .blue)
        case "Remote Desktop":  return ("display", .blue)
        case "Anti Virus":      return ("shield", .green)
        default:                return protocolIcon
        }
    }

    private var protocolIcon: (symbol: String, color: Color) {
        switch protocolType {
        case "SSH1", "SSH2": return ("terminal", .green)
        case "Telnet":       return ("terminal", .orange)
        case "RDP":          return ("display", .blue)
        case "HTTP", "HTTPS":return ("globe", .blue)
        case "VNC":          return ("rectangle.on.rectangle", .purple)
        case "IntApp":       return ("app.badge", .gray)
        default:             return ("network", .secondary)
        }
    }
}

struct ConnectedBadgeView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .shadow(color: .black.opacity(0.3), radius: 0.5, x: 0, y: 0.5)
            Image(systemName: "play.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: 3.5, height: 3.5)
                .offset(x: 0.3)
        }
    }
}

struct ClassicToggleBox: View {
    let isExpanded: Bool
    let action: () -> Void
    
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(NSColor.textBackgroundColor))
                .frame(width: 9, height: 9)
                .border(Color.primary.opacity(0.25), width: 1)

            Rectangle()
                .fill(Color.primary.opacity(0.6))
                .frame(width: 5, height: 1)

            if !isExpanded {
                Rectangle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 1, height: 5)
            }
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
    }
}

struct TreeColumnView: View {
    let targetDepth: Int
    let rowHeight: CGFloat
    let type: ColumnType
    var isFirstRootAtDepth0: Bool = false
    
    enum ColumnType {
        case empty
        case vertical
        case parent(hasBelow: Bool)
        case leaf(hasBelow: Bool)
        case toggle(isExpanded: Bool, hasBelow: Bool, action: () -> Void)
    }
    
    private var lineColor: Color {
        Color.primary.opacity(0.18)
    }
    
    var body: some View {
        ZStack {
            switch type {
            case .empty:
                Color.clear
            case .vertical:
                Rectangle()
                    .fill(lineColor)
                    .frame(width: 1)
            case .parent(let hasBelow):
                if !isFirstRootAtDepth0 {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 1, height: rowHeight / 2)
                        .frame(maxHeight: .infinity, alignment: .top)
                }

                if hasBelow {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 1, height: rowHeight / 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }

                if targetDepth >= 0 {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 8, height: 1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            case .leaf(let hasBelow):

                if !isFirstRootAtDepth0 {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 1, height: rowHeight / 2)
                        .frame(maxHeight: .infinity, alignment: .top)
                }

                if hasBelow {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 1, height: rowHeight / 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }

                Rectangle()
                    .fill(lineColor)
                    .frame(width: 12, height: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(x: 8)
            case .toggle(let isExpanded, let hasBelow, let action):

                if !isFirstRootAtDepth0 {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 1, height: rowHeight / 2)
                        .frame(maxHeight: .infinity, alignment: .top)
                }

                if hasBelow {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 1, height: rowHeight / 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }

                if targetDepth > 0 {
                    Rectangle()
                        .fill(lineColor)
                        .frame(width: 8, height: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                ClassicToggleBox(isExpanded: isExpanded, action: action)
            }
        }
        .frame(width: 16)
        .frame(height: rowHeight)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var lang: LanguageManager

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 280)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.addConnection() } label: { Image(systemName: "plus.rectangle") }
                    .help(t("Toolbar.NewConnection"))
                Button { model.addFolder() } label: { Image(systemName: "folder.badge.plus") }
                    .help(t("Toolbar.NewFolder"))
                Button { model.save() } label: {
                    Image(systemName: model.dirty ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                }.help(t("Toolbar.Save")).disabled(!model.dirty)
                Button { model.expandAll() } label: { Image(systemName: "arrow.up.backward.and.arrow.down.forward") }
                    .help(t("Toolbar.ExpandAll"))
                Button { model.collapseAll() } label: { Image(systemName: "arrow.down.forward.and.arrow.up.backward") }
                    .help(t("Toolbar.CollapseAll"))
                Button { model.sortAlphabetical() } label: { Image(systemName: "arrow.up.arrow.down") }
                    .help(t("Toolbar.SortAlphabetical"))
                Button { if model.selectedNodeID != nil { model.editorVisible = true } } label: {
                    Image(systemName: "slider.horizontal.3")
                }.help(t("Toolbar.EditSelected"))
                .disabled(model.selectedNodeID == nil)
            }
            ToolbarItem(placement: .principal) {
                if !model.sessions.isEmpty { PanelTabBar() }
            }
        }
        .navigationTitle("")
        .id(lang.choice) // force whole tree rebuild on language switch
        .confirmationDialog(
            String(format: t("Delete.Title"), model.pendingDelete?.name ?? ""),
            isPresented: Binding(get: { model.pendingDelete != nil },
                                 set: { if !$0 { model.pendingDelete = nil } }),
            presenting: model.pendingDelete
        ) { node in
            Button(t("Delete.Confirm"), role: .destructive) { model.deleteNode(node); model.pendingDelete = nil }
            Button(t("Delete.Cancel"), role: .cancel) { model.pendingDelete = nil }
        } message: { node in
            Text(node.isContainer ? t("Delete.Folder") : t("Delete.Connection"))
        }
        .sheet(isPresented: $model.editorVisible) {
            if let id = model.selectedNodeID {
                EditorSheet(nodeID: id).environmentObject(model)
            }
        }
    }

    @ViewBuilder private var sidebar: some View {
        if model.doc != nil {
            VStack(spacing: 0) {
                List {
                    ForEach(model.visibleRows()) { row in
                        TreeRow(row: row)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, model.rowHeight)
                .searchable(text: $model.searchText, placement: .sidebar, prompt: Text(t("Search.Placeholder")))
                .contextMenu {
                    Button(t("Toolbar.NewConnection")) {
                        model.selectedNodeID = nil
                        model.addConnection()
                    }
                    Button(t("Toolbar.NewFolder")) {
                        model.selectedNodeID = nil
                        model.addFolder()
                    }
                }
                .frame(maxHeight: .infinity)

                // Read-only status bar with Host/User/Pass + click-to-copy.
                ConnectionStatusBar()
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text(model.loadError ?? t("Placeholder.NoFile"))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(t("Menu.NewFile")) { model.newDocumentPanel() }
                    Button(t("Menu.OpenFile")) { model.openFilePanel() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            if !model.sessions.isEmpty {
                SessionTabBar()
                Divider()
            }
            ZStack {
                // Sessions stay alive in the hierarchy -> the ssh process doesn't restart when switching tabs.
                ForEach(model.sessions) { session in
                    SessionView(session: session,
                                isActive: session.id == model.selectedSessionID,
                                fontSize: model.terminalFontSize)
                        .opacity(session.id == model.selectedSessionID ? 1 : 0)
                        .allowsHitTesting(session.id == model.selectedSessionID)
                }
                if model.selectedSessionID == nil {
                    placeholder
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text(t("Placeholder.SelectConnection"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TreeRow: View {
    @EnvironmentObject var model: AppModel
    let row: FlatRow
    @State private var hovering = false
    @State private var rowHeight: CGFloat = 26

    private var isDropInto: Bool {
        model.dropIndicator?.id == row.node.id && model.dropIndicator?.pos == .into
    }
    private var rowFill: Color {
        if model.selectedNodeID == row.node.id { return Color.accentColor.opacity(0.22) }
        if isDropInto { return Color.accentColor.opacity(0.30) }
        if hovering { return Color.primary.opacity(0.07) }
        return .clear
    }

    var body: some View {
        let node = row.node
        HStack(spacing: 0) {
            // Tree guide lines (like mRemoteNG on Windows).
            ForEach(0...row.depth, id: \.self) { i in
                let isFirstRootAtDepth0 = (i == 0 && row.node.id == model.doc?.roots.first?.id)
                if i < row.depth {
                    let hasBelow = hasSubsequentSiblings(for: node, atDepth: i, currentDepth: row.depth, doc: model.doc)
                    TreeColumnView(targetDepth: i, rowHeight: CGFloat(model.rowHeight), type: hasBelow ? .vertical : .empty, isFirstRootAtDepth0: isFirstRootAtDepth0)
                } else {
                    let hasBelow = hasSubsequentSiblings(for: node, atDepth: i, currentDepth: row.depth, doc: model.doc)
                    if node.isContainer {
                        TreeColumnView(targetDepth: i, rowHeight: CGFloat(model.rowHeight), type: .toggle(isExpanded: model.expandedIDs.contains(node.id), hasBelow: hasBelow) {
                            model.toggleExpanded(node.id)
                        }, isFirstRootAtDepth0: isFirstRootAtDepth0)
                    } else {
                        TreeColumnView(targetDepth: i, rowHeight: CGFloat(model.rowHeight), type: .leaf(hasBelow: hasBelow), isFirstRootAtDepth0: isFirstRootAtDepth0)
                    }
                }
            }
            
            NodeRow(node: node)
                .padding(.leading, 4)
            
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: model.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.accentColor, lineWidth: isDropInto ? 1.5 : 0)
                )
        )
        .background(
            GeometryReader { g in
                Color.clear.onAppear { rowHeight = g.size.height }
                    .onChange(of: g.size.height) { _, h in rowHeight = h }
            }
        )
        .overlay(alignment: .top) {
            if model.dropIndicator?.id == node.id && model.dropIndicator?.pos == .above {
                insertionLine
            }
        }
        .overlay(alignment: .bottom) {
            if model.dropIndicator?.id == node.id && model.dropIndicator?.pos == .below {
                insertionLine
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.selectedNodeID = node.id }
        .contextMenu {
            Button(t("Context.Edit")) {
                model.selectedNodeID = node.id
                model.editorVisible = true
            }
            .keyboardShortcut(.return)
            Divider()
            if !node.isContainer {
                Button(t("Context.Connect")) { model.connect(node) }
                if node.protocolType.hasPrefix("SSH") {
                    Button(t("Context.SFTP")) { model.openSFTP(node) }
                }
                if !model.externalTools.isEmpty {
                    Menu(t("Context.ExternalToolsSubmenu")) {
                        ForEach(model.externalTools) { tool in
                            Button(tool.name) { model.runTool(tool, on: node) }
                        }
                    }
                }
                Divider()
            }
            Button(t("Context.NewConnectionHere")) { model.selectedNodeID = node.id; model.addConnection() }
            Button(t("Context.NewFolderHere")) { model.selectedNodeID = node.id; model.addFolder() }
            Button(t("Context.Duplicate")) { model.duplicateNode(node) }
            Divider()
            Button(t("Context.Delete"), role: .destructive) { model.pendingDelete = node }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.selectedNodeID = node.id
            if node.isContainer { model.toggleExpanded(node.id) }
            else { model.connect(node) }
        })
        .onDrag {
            NSItemProvider(object: node.id as NSString)
        } preview: {
            HStack(spacing: 6) {
                Image(systemName: node.iconInfo.symbol).foregroundStyle(node.iconInfo.color)
                Text(node.name)
            }
            .padding(8)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .onDrop(of: [.text], delegate: RowDropDelegate(node: node, rowHeight: rowHeight, model: model))
    }

    private var insertionLine: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .overlay(alignment: .leading) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: -2)
            }
            .padding(.leading, CGFloat(row.depth) * 16 + 18)
            .allowsHitTesting(false)
    }

    private func hasSubsequentSiblings(for node: MRNGNode, atDepth targetDepth: Int, currentDepth: Int, doc: ConfCons?) -> Bool {
        guard let doc = doc else { return false }
        var cur = node
        var d = currentDepth
        while d > targetDepth {
            guard let p = cur.parent else { return false }
            cur = p
            d -= 1
        }
        
        if let parent = cur.parent {
            if let idx = parent.children.firstIndex(where: { $0 === cur }) {
                return idx < parent.children.count - 1
            }
        } else {
            if let idx = doc.roots.firstIndex(where: { $0 === cur }) {
                return idx < doc.roots.count - 1
            }
        }
        return false
    }
}

struct RowDropDelegate: DropDelegate {
    let node: MRNGNode
    let rowHeight: CGFloat
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let y = info.location.y
        let pos: DropPos
        if node.isContainer {
            if y < rowHeight * 0.25 { pos = .above }
            else if y > rowHeight * 0.75 { pos = .below }
            else { pos = .into }
        } else {
            pos = y < rowHeight * 0.5 ? .above : .below
        }
        model.setDropIndicator(DropIndicator(id: node.id, pos: pos))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.dropIndicator?.id == node.id { model.clearDropIndicator() }
    }

    func performDrop(info: DropInfo) -> Bool {
        let pos = model.dropIndicator?.pos ?? .into
        model.clearDropIndicator()
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let target = node
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let idStr = obj as? String else { return }
            DispatchQueue.main.async {
                model.performMove(draggedID: idStr, target: target, pos: pos)
            }
        }
        return true
    }
}

struct NodeIconView: View {
    let isContainer: Bool
    let iconName: String
    let fallbackSymbol: String
    let fallbackColor: Color

    init(node: MRNGNode) {
        isContainer = node.isContainer
        iconName = node.icon
        let info = node.iconInfo
        fallbackSymbol = info.symbol
        fallbackColor = info.color
    }

    var body: some View {
        if isContainer {
            Image(systemName: "folder.fill").resizable().scaledToFit().foregroundStyle(Color.accentColor)
        } else if let img = IconLibrary.image(iconName) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: fallbackSymbol).resizable().scaledToFit().foregroundStyle(fallbackColor)
        }
    }
}

struct NodeRow: View {
    @EnvironmentObject var model: AppModel
    let node: MRNGNode
    
    private var isConnected: Bool {
        model.sessions.contains { $0.node.id == node.id }
    }
    
    var body: some View {
        HStack(spacing: 6) {
            NodeIconView(node: node)
                .frame(width: 16, height: 16)
                .overlay(alignment: .bottomTrailing) {
                    if isConnected {
                        ConnectedBadgeView()
                            .offset(x: 3, y: 3)
                    }
                }
            Text(node.name)
                .font(.system(size: model.uiFontSize))
                .lineLimit(1)
            if !node.isContainer && model.showProtocol {
                Spacer(minLength: 4)
                Text(node.protocolType)
                    .font(.system(size: max(9, model.uiFontSize - 4)))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PanelTabBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.panels(), id: \.self) { panel in
                    Button { model.selectPanel(panel) } label: {
                        Text(panel)
                            .font(.callout)
                            .fontWeight(panel == model.selectedPanel ? .semibold : .regular)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(panel == model.selectedPanel ? Color.accentColor.opacity(0.22) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
    }
}

struct SessionTabBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.sessions(inPanel: model.selectedPanel)) { session in
                    HStack(spacing: 6) {
                        NodeIconView(node: session.node).frame(width: 14, height: 14)
                        Text(session.title).lineLimit(1)
                        Button {
                            model.closeSession(session.id)
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(session.id == model.selectedSessionID
                                ? Color.accentColor.opacity(0.22) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { model.selectedSessionID = session.id }
                    .contextMenu {
                        Button(t("Context.Reconnect")) { model.reconnect(session) }
                        Button(t("Context.Disconnect")) { model.closeSession(session.id) }
                        if session.kind == .rdp {
                            Divider()
                            Button(t("Context.SendCtrlAltDel")) { model.sendCtrlAltDel(session) }
                        }
                        Divider()
                        Button(t("Context.RenameTab")) { model.renameSession(session.id, to: session.title) }
                        Button(t("Context.DuplicateTab")) { model.duplicate(session) }
                        if !session.password.isEmpty {
                            Divider()
                            Button(t("Context.CopyPassword")) { model.copyPassword(session) }
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }
}

struct SessionView: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    var isActive: Bool = false
    var fontSize: Double = 13
    var body: some View {
        switch session.kind {
        case .ssh, .telnet, .sftp, .externalTool:
            TerminalContainer(
                session: session,
                isActive: isActive,
                fontSize: fontSize,
                theme: model.terminalTheme,
                cursorBlinkSpeed: model.cursorBlinkSpeed,
                onTitleChange: { newTitle in
                    model.updateTitleFromTerminal(session.id, newTitle)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .rdp:
            RDPContainer(session: session, isActive: isActive, onDisconnect: {
                if model.closeTabOnDisconnect { model.closeSession(session.id) }
            })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .http:
            HTTPContainer(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .externalApp:
            unsupported(t("Error.ExternalAppPending"))
        case .unsupported:
            unsupported(String(format: t("Error.NotImplemented"), session.node.protocolType))
        }
    }

    private func unsupported(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: session.node.sfSymbol).font(.system(size: 36))
            Text("\(session.node.hostname):\(session.node.port)").font(.headline)
            Text(msg).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

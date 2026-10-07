// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import SwiftUI
import AppKit

/// A small window with the live numbers of one RDP session — what to look at, and what to
/// paste into a ticket, when a session feels slow.
@MainActor
enum ConnectionInfoWindow {
    private static var panels: [UUID: NSPanel] = [:]

    static func show(_ session: Session) {
        if let open = panels[session.id] {
            open.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = String(format: t("Info.Title"), session.title)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ConnectionInfoView(session: session))
        panel.center()
        let id = session.id
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                       object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                panels[id] = nil
                if let token { NotificationCenter.default.removeObserver(token) }
            }
        }
        panels[id] = panel
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct ConnectionInfoView: View {
    let session: Session
    @State private var rows: [Row] = []
    /// The previous reading, for rates per second.
    @State private var previous: (at: Date, inBytes: UInt64, outBytes: UInt64, frames: Int)?

    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(rows) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        Text(row.value).textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(t("Info.Copy")) {
                    let text = rows.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 300)
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        let node = session.node
        var out: [Row] = [Row(label: t("Info.Computer"), value: "\(node.hostname):\(node.port)")]
        guard let view = SessionViews.shared.view(for: session.id) as? RDPNSView,
              let stats = view.connectionStats() else {
            out.append(Row(label: t("Info.State"), value: t("Info.NotConnected")))
            rows = out
            return
        }
        let now = Date()
        let inBytes = stats["inBytes"]?.uint64Value ?? 0
        let outBytes = stats["outBytes"]?.uint64Value ?? 0
        let elapsed = previous.map { now.timeIntervalSince($0.at) } ?? 0

        if stats["viaGateway"]?.boolValue == true {
            out.append(Row(label: t("Info.Gateway"), value: node.gatewayHostname))
        }
        out.append(Row(label: t("Info.Desktop"),
                       value: "\(stats["width"]?.intValue ?? 0) × \(stats["height"]?.intValue ?? 0)"))
        out.append(Row(label: t("Info.Graphics"),
                       value: stats["graphicsPipeline"]?.boolValue == true ? t("Info.GraphicsPipeline")
                                                                          : t("Info.GraphicsLegacy")))
        out.append(Row(label: t("Info.Keyboard"), value: view.layoutSummary ?? t("Info.KeyboardCharacters")))
        let avg = stats["averageRTT"]?.uint32Value ?? 0
        let base = stats["baseRTT"]?.uint32Value ?? 0
        out.append(Row(label: t("Info.RoundTrip"),
                       value: avg == 0 ? t("Info.NotReported")
                                       : String(format: t("Info.RoundTripValue"), Int(avg), Int(base))))
        let kbps = stats["bandwidthKbps"]?.uint32Value ?? 0
        out.append(Row(label: t("Info.Bandwidth"),
                       value: kbps == 0 ? t("Info.NotReported")
                                        : String(format: "%.1f Mbit/s", Double(kbps) / 1000)))
        out.append(Row(label: t("Info.Received"), value: amount(inBytes, previous?.inBytes, elapsed)))
        out.append(Row(label: t("Info.Sent"), value: amount(outBytes, previous?.outBytes, elapsed)))
        if let p = previous, elapsed > 0 {
            let fps = Double(view.framesShown - p.frames) / elapsed
            out.append(Row(label: t("Info.Frames"), value: String(format: t("Info.FramesValue"), fps)))
        }
        if let since = view.connectedAt {
            let f = DateComponentsFormatter()
            f.allowedUnits = [.hour, .minute, .second]
            f.unitsStyle = .abbreviated
            out.append(Row(label: t("Info.ConnectedFor"), value: f.string(from: now.timeIntervalSince(since)) ?? ""))
        }
        previous = (now, inBytes, outBytes, view.framesShown)
        rows = out
    }

    /// Total so far, and per second since the last reading.
    private func amount(_ total: UInt64, _ before: UInt64?, _ elapsed: TimeInterval) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        var s = f.string(fromByteCount: Int64(total))
        if let before, elapsed > 0, total >= before {
            s += " · " + f.string(fromByteCount: Int64(Double(total - before) / elapsed)) + "/s"
        }
        return s
    }
}

/// The live picture under a hovered tab.
struct SessionPreviewView: View {
    let sessionID: UUID

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            if let image = SessionViews.shared.view(for: sessionID)?.previewImage() {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 360)
            } else {
                Text(t("Preview.Nothing"))
                    .foregroundStyle(.secondary)
                    .frame(width: 220, height: 80)
            }
        }
        .padding(6)
    }
}

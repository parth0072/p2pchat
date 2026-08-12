import SwiftUI
import MultipeerConnectivity

/// Live diagnostics for "why isn't this connecting" / "where is my message
/// actually going" — a running log of discovery, connect-state, trust, and
/// routing events straight out of MeshManager, plus a snapshot of current
/// mesh state. Not persisted; purely an in-session debugging aid.
struct DebugView: View {
    @ObservedObject var mesh: MeshManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summary
                }
                Section("Live log") {
                    if mesh.debugLog.isEmpty {
                        Text("Nothing yet — discovery, connect, trust, and routing events will show up here as they happen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(mesh.debugLog.reversed()) { entry in
                            DebugLogRow(entry: entry)
                        }
                    }
                }
            }
            .navigationTitle("Debug")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        mesh.clearDebugLog()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(mesh.debugLog.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
        #endif
    }

    private var summary: some View {
        let peers = Array(mesh.discoveredPeers.values)
        let direct = peers.filter { $0.state == .connected && !$0.isRelayed }.count
        let relayed = peers.filter { $0.isRelayed }.count
        let connecting = peers.filter { $0.state == .connecting }.count
        let notConnected = peers.filter { $0.state == .notConnected }.count

        return VStack(alignment: .leading, spacing: 6) {
            Text("\(direct) direct · \(relayed) via relay · \(connecting) connecting · \(notConnected) not connected")
                .font(.subheadline.bold())
            Text("Advertising & browsing for group \u{201c}\(mesh.currentGroup.name)\u{201d}")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !mesh.localNetworkAuthorized {
                Label("Local Network permission denied — discovery/advertising can't work at all until this is enabled in Settings.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct DebugLogRow: View {
    let entry: DebugLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.caption)
                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        switch entry.category {
        case .discovery: return .blue
        case .connect: return .green
        case .route: return .purple
        case .trust: return .orange
        case .error: return .red
        }
    }
}

import SwiftUI
import MultipeerConnectivity

/// Visualizes the mesh as a dark "network operations" style node graph: me
/// at the center, everyone I've learned about (directly or through someone
/// else's gossip) arranged in rings by hop distance. Backed by
/// MeshManager.topologyEdges/topologyNames, which every peer — not just a
/// relay host — broadcasts every few seconds and immediately on
/// connect/disconnect (see broadcastTopology).
struct DiscoveryView: View {
    @ObservedObject var mesh: MeshManager
    @Environment(\.dismiss) private var dismiss

    private var myID: String { DiscoveredPeer.stableID(for: mesh.localPeerID) }

    struct GraphNode: Identifiable {
        let id: String
        let name: String
        let hop: Int
    }

    struct GraphEdge: Identifiable {
        let id: String
        let a: String
        let b: String
        /// True when this edge touches me directly — drawn thicker/brighter
        /// so your own connections read at a glance against the rest of the
        /// mesh, mirroring the "highlighted route vs. background links" look.
        let isDirectToMe: Bool
    }

    private var graph: (nodes: [GraphNode], edges: [GraphEdge]) {
        // topologyEdges is directed (each peer reports its own connections);
        // symmetrize it since "A connected to B" and "B connected to A" are
        // the same physical link for layout/drawing purposes.
        var adjacency: [String: Set<String>] = mesh.topologyEdges
        for (a, neighbors) in mesh.topologyEdges {
            for b in neighbors {
                adjacency[b, default: []].insert(a)
            }
        }

        var allIDs = Set(adjacency.keys)
        for neighbors in adjacency.values { allIDs.formUnion(neighbors) }
        allIDs.insert(myID)

        // BFS from me so each node lands on the ring matching how many hops
        // a message would actually need to reach it.
        var hopByID: [String: Int] = [myID: 0]
        var queue = [myID]
        var head = 0
        while head < queue.count {
            let current = queue[head]; head += 1
            let currentHop = hopByID[current] ?? 0
            for neighbor in adjacency[current] ?? [] where hopByID[neighbor] == nil {
                hopByID[neighbor] = currentHop + 1
                queue.append(neighbor)
            }
        }

        let nodes = allIDs.map { id in
            GraphNode(
                id: id,
                name: id == myID ? "You" : (mesh.topologyNames[id] ?? id),
                hop: hopByID[id] ?? 99
            )
        }.sorted { $0.hop < $1.hop }

        var seen = Set<String>()
        var edges: [GraphEdge] = []
        for (a, neighbors) in adjacency {
            for b in neighbors {
                let key = [a, b].sorted().joined(separator: "|")
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                edges.append(GraphEdge(id: key, a: a, b: b, isDirectToMe: a == myID || b == myID))
            }
        }
        return (nodes, edges)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                background

                VStack(spacing: 0) {
                    GeometryReader { geo in
                        let data = graph
                        let (positions, typicalSpacing) = layout(nodes: data.nodes, edges: data.edges, in: geo.size)
                        // Each node's rough radio-range halo. Overlapping
                        // halos along a chain of hops are what "coverage
                        // area" means here — the mesh's total reach is the
                        // union of everyone's individual range, not any one
                        // device's range alone.
                        let haloRadius = max(typicalSpacing * 0.65, 55)

                        ZStack {
                            Canvas { context, _ in
                                for node in data.nodes {
                                    guard node.hop < 99, let point = positions[node.id] else { continue }
                                    let rect = CGRect(
                                        x: point.x - haloRadius,
                                        y: point.y - haloRadius,
                                        width: haloRadius * 2,
                                        height: haloRadius * 2
                                    )
                                    context.fill(Path(ellipseIn: rect), with: .color(Palette.link.opacity(0.07)))
                                }
                                for edge in data.edges {
                                    guard let a = positions[edge.a], let b = positions[edge.b] else { continue }
                                    var path = Path()
                                    path.move(to: a)
                                    path.addLine(to: b)
                                    context.stroke(
                                        path,
                                        with: .color(edge.isDirectToMe ? Palette.accent.opacity(0.85) : Palette.link.opacity(0.55)),
                                        lineWidth: edge.isDirectToMe ? 2.5 : 1.2
                                    )
                                }
                            }

                            ForEach(data.nodes) { node in
                                if let point = positions[node.id] {
                                    NodeView(node: node, isMe: node.id == myID)
                                        .position(point)
                                }
                            }
                        }
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                    .frame(minHeight: 360)
                    .padding()

                    legend
                }
            }
            .navigationTitle("Discovery")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(iOS)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .tint(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        // Sheets have no default size on macOS, so without this the
        // NavigationStack — and the GeometryReader inside it — collapses to
        // a tiny box and the whole graph bunches up at the center.
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
    }

    /// Dark navy backdrop with a faint grid, echoing an ops/telemetry map
    /// rather than a plain white sheet.
    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [Palette.bgTop, Palette.bgBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            Canvas { context, size in
                let spacing: CGFloat = 32
                var x: CGFloat = 0
                while x < size.width {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(.white.opacity(0.04)), lineWidth: 1)
                    x += spacing
                }
                var y: CGFloat = 0
                while y < size.height {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(.white.opacity(0.04)), lineWidth: 1)
                    y += spacing
                }
            }
        }
        .ignoresSafeArea()
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(coverageSummary)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)

            HStack(spacing: 16) {
                Label("Your connection", systemImage: "minus")
                    .font(.caption)
                    .foregroundStyle(Palette.accent)
                Label("Multi-hop link", systemImage: "minus")
                    .font(.caption)
                    .foregroundStyle(Palette.link)
                Label("Range halo", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.link.opacity(0.5))
            }
            Text("Every device relays messages that aren't addressed to it, one hop at a time, so a message can cross several nearby devices to reach one that's out of your direct range. The hop limit scales with how many devices are known on the mesh (not a fixed number), so it stops looping forever without capping reach short in a larger mesh.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel)
    }

    /// Force-directed layout (a lightweight Fruchterman-Reingold): nodes
    /// repel each other, edges pull their two ends together, everything is
    /// pulled gently toward the center so the graph doesn't drift toward a
    /// corner. This is deliberately *not* a strict concentric-ring layout —
    /// with only two direct peers, evenly-spaced rings put them at exactly
    /// opposite points on a circle, which reads as a straight line through
    /// you. A physics-based layout spreads things out organically instead,
    /// closer to how a real network map looks, without pretending to know
    /// each device's actual physical direction (MultipeerConnectivity has
    /// no compass/GPS/distance data to draw that from — this is a
    /// relationship diagram, not a literal map).
    ///
    /// Starting positions are seeded from each node's own ID (not true
    /// randomness), so the same topology settles into essentially the same
    /// layout every time instead of jumping around on every ~6s refresh.
    private func layout(nodes: [GraphNode], edges: [GraphEdge], in size: CGSize) -> (positions: [String: CGPoint], typicalSpacing: CGFloat) {
        guard !nodes.isEmpty else { return ([:], 90) }
        let width = max(size.width, 240)
        let height = max(size.height, 240)
        let center = CGPoint(x: width / 2, y: height / 2)
        let idealDistance = max(sqrt((width * height) / CGFloat(nodes.count)) * 0.85, 70)
        let padding: CGFloat = 46

        var positions: [String: CGPoint] = [:]
        for node in nodes {
            var rng = SeededGenerator(seed: node.id)
            let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
            let radius = Double.random(in: 0...Double(min(width, height) / 3), using: &rng)
            positions[node.id] = CGPoint(
                x: center.x + CGFloat(cos(angle)) * CGFloat(radius),
                y: center.y + CGFloat(sin(angle)) * CGFloat(radius)
            )
        }
        // "You" anchors the layout near the middle so the graph reads
        // outward from your own position, like the reference.
        positions[myID] = center

        let iterations = 140
        for iteration in 0..<iterations {
            let temperature = idealDistance * (1 - CGFloat(iteration) / CGFloat(iterations))
            var displacement: [String: CGPoint] = [:]
            for node in nodes { displacement[node.id] = .zero }

            for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count {
                    let a = nodes[i].id, b = nodes[j].id
                    guard let pa = positions[a], let pb = positions[b] else { continue }
                    var dx = pa.x - pb.x
                    var dy = pa.y - pb.y
                    var dist = sqrt(dx * dx + dy * dy)
                    if dist < 0.1 {
                        dx = CGFloat.random(in: -1...1)
                        dy = CGFloat.random(in: -1...1)
                        dist = 0.1
                    }
                    let force = (idealDistance * idealDistance) / dist
                    let ux = dx / dist, uy = dy / dist
                    displacement[a]?.x += ux * force
                    displacement[a]?.y += uy * force
                    displacement[b]?.x -= ux * force
                    displacement[b]?.y -= uy * force
                }
            }

            for edge in edges {
                guard let pa = positions[edge.a], let pb = positions[edge.b] else { continue }
                let dx = pa.x - pb.x
                let dy = pa.y - pb.y
                let dist = max(sqrt(dx * dx + dy * dy), 0.1)
                let force = (dist * dist) / idealDistance
                let ux = dx / dist, uy = dy / dist
                displacement[edge.a]?.x -= ux * force
                displacement[edge.a]?.y -= uy * force
                displacement[edge.b]?.x += ux * force
                displacement[edge.b]?.y += uy * force
            }

            for node in nodes {
                guard let p = positions[node.id] else { continue }
                displacement[node.id]?.x += (center.x - p.x) * 0.01
                displacement[node.id]?.y += (center.y - p.y) * 0.01
            }

            for node in nodes {
                guard let p = positions[node.id], let d = displacement[node.id] else { continue }
                let dist = max(sqrt(d.x * d.x + d.y * d.y), 0.1)
                let capped = min(dist, max(temperature, 1))
                var next = CGPoint(x: p.x + (d.x / dist) * capped, y: p.y + (d.y / dist) * capped)
                next.x = min(max(next.x, padding), width - padding)
                next.y = min(max(next.y, padding), height - padding)
                positions[node.id] = next
            }
        }

        return (positions, idealDistance)
    }

    /// Rough, illustrative-only reach estimate: assumes ~10m (about 30ft) of
    /// usable Bluetooth/Wi-Fi Direct range per hop, which is a reasonable
    /// indoor ballpark but varies a lot with walls, interference, and
    /// whether AWDL/Wi-Fi or Bluetooth ends up carrying a given hop. This is
    /// meant to communicate "relaying multiplies your reach," not to be a
    /// precise coverage measurement.
    private var coverageSummary: String {
        let maxHop = graph.nodes.map(\.hop).filter { $0 < 99 }.max() ?? 0
        guard maxHop > 0 else { return "Coverage: just this device so far — no peers connected." }
        let metersPerHop = 10
        let estimate = maxHop * metersPerHop
        return "Coverage: \(maxHop) hop\(maxHop == 1 ? "" : "s") deep · roughly ~\(estimate)m (~\(Int(Double(estimate) * 3.28))ft) of combined reach, vs. ~\(metersPerHop)m for a single direct connection. Actual range depends heavily on walls and interference."
    }
}

/// Deterministic RNG seeded from a peer ID string (FNV-1a hash), so the
/// force-directed layout's starting positions — and therefore its settled
/// result — stay stable across refreshes and app relaunches for the same
/// topology, instead of using true randomness that would reshuffle the
/// whole graph every few seconds.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: String) {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        state = hash == 0 ? 0x9E3779B97F4A7C15 : hash
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Shared color palette for the dark topology-map look.
private enum Palette {
    static let bgTop = Color(red: 0.06, green: 0.08, blue: 0.14)
    static let bgBottom = Color(red: 0.04, green: 0.05, blue: 0.10)
    static let panel = Color(red: 0.09, green: 0.11, blue: 0.18).opacity(0.92)
    static let nodeFillInner = Color(red: 0.14, green: 0.19, blue: 0.32)
    static let nodeFillOuter = Color(red: 0.07, green: 0.10, blue: 0.18)
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.38)   // warm coral — "you" / direct
    static let link = Color(red: 0.35, green: 0.55, blue: 1.0)     // blue — background mesh links
}

private struct NodeView: View {
    let node: DiscoveryView.GraphNode
    let isMe: Bool

    private var ringColor: Color {
        if isMe { return Palette.accent }
        return node.hop <= 1 ? Palette.link : .white.opacity(0.35)
    }

    private var diameter: CGFloat { isMe ? 56 : 44 }

    private var initials: String {
        let parts = node.name.split(separator: " ")
        if node.name == "You" { return "You" }
        let letters = parts.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Soft outer glow for the "hub" node, echoing the
                // dashed-halo treatment on high-traffic nodes.
                if isMe {
                    Circle()
                        .stroke(Palette.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .frame(width: diameter + 18, height: diameter + 18)
                }

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Palette.nodeFillInner, Palette.nodeFillOuter],
                            center: .center,
                            startRadius: 0,
                            endRadius: diameter / 2
                        )
                    )
                    .frame(width: diameter, height: diameter)
                    .overlay(
                        Circle().stroke(ringColor, lineWidth: 3)
                    )
                    .shadow(color: ringColor.opacity(0.5), radius: 6)

                Text(initials)
                    .font(.system(size: isMe ? 12 : 10, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 4)
            }

            Text(node.name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

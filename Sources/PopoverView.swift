import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: ClusterStore
    @Environment(\.snapshotMode) private var snapshotMode
    @State private var hover: String?

    private let width: CGFloat = 400
    private let padding: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let s = store.snapshot {
                YourJobsCard(snapshot: s)
                resources(s)
                Divider()
                nodes(s)
                Divider()
                queue(s)
            } else if store.needsSetup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set the SSH host of your SLURM cluster to get started.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Cluster settings…") { store.showSettings() }
                }
            } else if store.error == nil {
                HStack { ProgressView().controlSize(.small); Text("Connecting to \(store.clusterName)…").foregroundStyle(.secondary) }
                    .font(.system(size: 12))
            }
            if let err = store.error {
                Label(err, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(padding)
        .frame(width: width)
        .onAppear { store.refreshIfStale() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(store.clusterName).font(.system(size: 14, weight: .semibold))
            Spacer()
            if let t = store.updatedAt {
                Text("Updated \(Fmt.ago(t, now: store.now))").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if snapshotMode {
                Image(systemName: "arrow.clockwise").frame(width: 16, height: 16).foregroundStyle(Color.accentColor)
            } else {
                Button { store.refresh() } label: {
                    if store.loading {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
                    }
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }
        }
    }

    // MARK: Free resources

    private func resources(_ s: ClusterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            resourceRow("CPUs", free: "\(Fmt.count(s.cpuFree)) free",
                        of: "of \(Fmt.count(s.cpuTotal))",
                        used: s.cpuTotal > 0 ? 1 - Double(s.cpuFree) / Double(s.cpuTotal) : 0)
            resourceRow("Memory", free: "\(Fmt.mem(s.memFree)) free",
                        of: "of \(Fmt.mem(s.memTotal))",
                        used: s.memTotal > 0 ? 1 - s.memFree / s.memTotal : 0)
            Text(nodeLine(s)).font(.system(size: 11)).foregroundStyle(.secondary)
            if !s.gpuNodes.isEmpty {
                resourceRow("GPUs", free: "\(s.gpuFree) free", of: "of \(s.gpuTotal)",
                            used: s.gpuTotal > 0 ? 1 - Double(s.gpuFree) / Double(s.gpuTotal) : 1)
                Text(s.gpuNodes.map(gpuLine).joined(separator: "\n"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func gpuLine(_ n: Node) -> String {
        if !n.isUp { return "\(n.name): \(n.isDown ? "down" : "draining")" }
        return "\(n.name): \(n.gpuFree) of \(n.gpuTotal) GPUs free"
    }

    private func resourceRow(_ title: String, free: String, of total: String, used: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(free).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(total).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            UsageBar(fraction: used)
        }
    }

    private func nodeLine(_ s: ClusterSnapshot) -> String {
        var parts = ["CPU nodes: \(s.up.count) of \(s.nodes.count) up", "\(s.idleCount) idle"]
        if s.downCount > 0 { parts.append("\(s.downCount) down") }
        if s.drainingCount > 0 { parts.append("\(s.drainingCount) draining") }
        return parts.joined(separator: " · ")
    }

    // MARK: Node map

    private func nodes(_ s: ClusterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NodeMap(snapshot: s, width: width - 2 * padding, hover: $hover)
            if let hover {
                Text(hover).font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                NodeLegend()
            }
            VStack(alignment: .leading, spacing: 3) {
                if let n = s.mostFreeCPU {
                    Text("Most CPUs free: **\(n.cpuFree)** on \(n.name) (\(Fmt.mem(n.memFree)) free)")
                }
                if let n = s.mostFreeMem, n.name != s.mostFreeCPU?.name {
                    Text("Most memory free: **\(Fmt.mem(n.memFree))** on \(n.name) (\(n.cpuFree) CPU free)")
                }
            }
            .font(.system(size: 11))
        }
    }

    // MARK: Queue

    private func queue(_ s: ClusterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Queue").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(s.running.count) running · \(s.pending.count) pending")
                    .font(.system(size: 11.5)).monospacedDigit()
            }
            if !s.pendingReasons.isEmpty {
                Text("Pending because: " + s.pendingReasons.prefix(4).map { "\($0.reason) \($0.count)" }.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        if snapshotMode {
            HStack(spacing: 12) {
                Text("Desktop widget").font(.system(size: 11.5))
                Capsule().fill(Color.accentColor).frame(width: 26, height: 15)
                    .overlay(alignment: .trailing) { Circle().fill(.white).padding(2) }
                Spacer()
                Image(systemName: "gearshape").foregroundStyle(Color.accentColor)
            }
        } else {
            HStack(spacing: 12) {
                Toggle("Desktop widget", isOn: Binding(
                    get: { store.widgetVisible },
                    set: { $0 ? WidgetController.shared.show() : WidgetController.shared.hide() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11.5))
                Spacer()
                Menu {
                    Picker("Refresh every", selection: $store.refreshInterval) {
                        Text("5 minutes").tag(300.0)
                        Text("10 minutes").tag(600.0)
                        Text("30 minutes").tag(1800.0)
                    }
                    Button("Cluster settings…") { store.showSettings() }
                    Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                    Divider()
                    Button("Quit SLURM Meter") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

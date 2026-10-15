import SwiftUI
import AppKit

/// Screenshot aid: `SlurmMeter --snapshot <dir> [--demo]` renders the popover and widget (light + dark)
/// to PNGs and quits. Without `--demo` it uses the cached last fetch (or a fresh one); with `--demo` it
/// uses a made-up cluster, never touches the network, and also renders the README images.
@MainActor
enum Snapshot {
    static var outputDir: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static var demo: Bool { CommandLine.arguments.contains("--demo") }

    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ClusterStore.shared
        if demo {
            store.demoName = "hpc"
            store.show(demoCluster(), at: Date().addingTimeInterval(-180))
        } else if let (snap, date) = ClusterService.loadCache(hidden: store.hidden) {
            store.show(snap, at: date)
        } else {
            store.start()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (store.snapshot == nil ? 20 : 1)) {
            for scheme in [ColorScheme.light, .dark] {
                let name = scheme == .dark ? "dark" : "light"
                render(PopoverView().background(PanelBackground()), scheme: scheme, to: dir.appendingPathComponent("popover-\(name).png"))
                render(WidgetView().padding(20), scheme: scheme, to: dir.appendingPathComponent("widget-\(name).png"))
                if demo {
                    render(Showcase(), scheme: scheme, to: dir.appendingPathComponent("showcase-\(name).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static func render<V: View>(_ view: V, scheme: ColorScheme, to url: URL) {
        let renderer = ImageRenderer(content: view
            .environmentObject(ClusterStore.shared)
            .environment(\.snapshotMode, true)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Demo data

    /// A made-up cluster: deterministic, so screenshots are stable.
    private static func demoCluster() -> ClusterSnapshot {
        var seed: UInt64 = 42
        func rand() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        let gb = 1024.0
        var nodes: [Node] = []
        var n = 0
        func add(_ count: Int, cpu: Int, mem: Double, down: Int = 0, busy: Double) {
            for i in 0..<count {
                n += 1
                let isDown = i >= count - down
                let r = rand()
                let load = r < busy ? (r < busy * 0.6 ? 1 : 0.6 + rand() * 0.3) : rand() * 0.4
                let cpuAlloc = isDown ? 0 : Int((Double(cpu) * load / 4).rounded()) * 4
                nodes.append(Node(name: String(format: "cn%03d", n), partitions: ["normal"],
                                  state: isDown ? "DOWN+NOT_RESPONDING" : cpuAlloc == 0 ? "IDLE" : cpuAlloc == cpu ? "ALLOCATED" : "MIXED",
                                  cpuTotal: cpu, cpuAlloc: cpuAlloc,
                                  memTotal: mem * 0.985, memAlloc: isDown ? 0 : mem * 0.985 * min(load * 1.1, 1)))
            }
        }
        add(12, cpu: 48, mem: 256 * gb, down: 3, busy: 0.5)
        add(30, cpu: 64, mem: 768 * gb, down: 1, busy: 0.6)
        add(4, cpu: 112, mem: 1536 * gb, down: 1, busy: 0.3)
        add(2, cpu: 224, mem: 3072 * gb, busy: 0.2)
        let gpus = [
            Node(name: "gpu01", partitions: ["gpu"], state: "MIXED", cpuTotal: 128, cpuAlloc: 48,
                 memTotal: 512 * gb, memAlloc: 180 * gb, gpuTotal: 8, gpuAlloc: 5),
            Node(name: "gpu02", partitions: ["gpu"], state: "MIXED", cpuTotal: 128, cpuAlloc: 24,
                 memTotal: 512 * gb, memAlloc: 96 * gb, gpuTotal: 8, gpuAlloc: 2),
        ]

        var jobs: [Job] = []
        for i in 0..<64 {
            jobs.append(Job(user: "user\(i % 9)", state: "R", cpus: 8, mem: 64 * gb, timeLeft: 3600 * Double(i % 30 + 1),
                            partition: "normal", reason: "None"))
        }
        let reasons = [("QOSMaxJobsPerUserLimit", 58), ("Resources", 21), ("Priority", 12), ("Dependency", 4)]
        for (reason, count) in reasons {
            for i in 0..<count {
                jobs.append(Job(user: "user\(i % 5)", state: "PD", cpus: 4, mem: 32 * gb, timeLeft: nil,
                                partition: "normal", reason: reason))
            }
        }
        for i in 0..<6 {
            jobs.append(Job(user: "alice", state: "R", cpus: 12, mem: 96 * gb, timeLeft: 7200 * Double(i + 1),
                            partition: "normal", reason: "None"))
        }
        for _ in 0..<3 {
            jobs.append(Job(user: "alice", state: "PD", cpus: 12, mem: 96 * gb, timeLeft: nil,
                            partition: "normal", reason: "Priority"))
        }

        var snap = ClusterSnapshot(user: "alice", nodes: nodes, gpuNodes: gpus, jobs: jobs,
                                   limits: Limits(qos: "normal", maxJobs: 10, maxCPU: 120, maxMem: 3 * gb * gb))
        snap.myMemUsed = 312 * gb
        return snap
    }
}

/// README hero: a desktop with a menu bar, the open popover, and the widget.
private struct Showcase: View {
    @EnvironmentObject var store: ClusterStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack(alignment: .top) {
            LinearGradient(colors: dark ? [Color(hex: 0x1d2b4f), Color(hex: 0x2d4a3e)]
                                        : [Color(hex: 0x9cc7ef), Color(hex: 0xb8e0cf)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "apple.logo")
                    Text("Finder").fontWeight(.semibold)
                    Spacer()
                    MenuBarLabel(store: store)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                }
                .font(.system(size: 13))
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(Color(white: dark ? 0.1 : 1).opacity(0.35))

                HStack(alignment: .top, spacing: 32) {
                    WidgetView()
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                        .padding(.top, 40)
                    Spacer(minLength: 0)
                    PopoverView()
                        .background(PanelBackground())
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
        .frame(width: 900)
    }
}

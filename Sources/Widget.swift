import SwiftUI
import AppKit

/// A small desktop panel with the same live numbers as the menu bar popover.
@MainActor
final class WidgetController {
    static let shared = WidgetController()
    private var panel: WidgetPanel?
    private let frameName = "SlurmMeterWidget"

    var onTop: Bool {
        get { UserDefaults.standard.object(forKey: "widgetOnTop") as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: "widgetOnTop")
            applyLevel()
            ClusterStore.shared.objectWillChange.send()
        }
    }

    func restore() {
        if UserDefaults.standard.object(forKey: "widgetVisible") as? Bool ?? true { show() }
    }

    func show() {
        if panel == nil { makePanel() }
        keepOnScreen()
        panel?.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: "widgetVisible")
        ClusterStore.shared.widgetVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: "widgetVisible")
        ClusterStore.shared.widgetVisible = false
    }

    private func makePanel() {
        let host = NSHostingController(rootView: WidgetView().environmentObject(ClusterStore.shared))
        host.sizingOptions = [.preferredContentSize]

        let p = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 170),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.contentViewController = host
        // Size to the content now, so the default position below uses the real width.
        p.setContentSize(host.view.fittingSize)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel = p
        applyLevel()

        if !p.setFrameUsingName(frameName) { moveToDefaultPosition(p) }
        p.setFrameAutosaveName(frameName)
        keepOnScreen()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in WidgetController.shared.keepOnScreen() }
        }
        // The content can grow after launch (e.g. once data arrives); keep the whole widget visible.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p, queue: .main) { _ in
            Task { @MainActor in WidgetController.shared.keepOnScreen() }
        }
    }

    private func moveToDefaultPosition(_ p: NSPanel) {
        // The primary display (the one with the menu bar), not whichever screen has focus right now.
        guard let vf = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame else { return }
        p.setFrameTopLeftPoint(NSPoint(x: vf.maxX - p.frame.width - 24, y: vf.maxY - 220))
    }

    /// Borderless panels aren't kept on screen by AppKit; a saved position from another display
    /// (or a resolution change) can leave the widget off-screen, so pull it back fully inside.
    func keepOnScreen() {
        guard let p = panel else { return }
        let f = p.frame
        let screen = NSScreen.screens.max {
            $0.visibleFrame.intersection(f).width * $0.visibleFrame.intersection(f).height
                < $1.visibleFrame.intersection(f).width * $1.visibleFrame.intersection(f).height
        }
        guard let vf = screen?.visibleFrame, !vf.intersection(f).isNull else { return moveToDefaultPosition(p) }
        let x = min(max(f.minX, vf.minX), vf.maxX - f.width)
        let y = min(max(f.minY, vf.minY), vf.maxY - f.height)
        if x != f.minX || y != f.minY { p.setFrameOrigin(NSPoint(x: x, y: y)) }
    }

    private func applyLevel() {
        guard let p = panel else { return }
        // "Desktop" mode sits just above the desktop icons and below normal windows, like a widget.
        p.level = onTop ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }
}

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        performDrag(with: event)
    }
}

struct WidgetView: View {
    @EnvironmentObject var store: ClusterStore
    @State private var hover: String?

    private let width: CGFloat = 340
    private let padding: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(store.clusterName).font(.system(size: 12, weight: .semibold))
                if let s = store.snapshot {
                    Text("\(s.up.count)/\(s.nodes.count) nodes up").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let err = store.error {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(.secondary).help(err)
                }
                if let t = store.updatedAt {
                    Text(Fmt.ago(t, now: store.now)).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }

            if let s = store.snapshot {
                HStack(alignment: .top, spacing: 0) {
                    Ring(used: s.cpuTotal > 0 ? 1 - Double(s.cpuFree) / Double(s.cpuTotal) : 0,
                         center: Fmt.count(s.cpuFree), label: "CPUs free")
                    Spacer(minLength: 0)
                    Ring(used: s.memTotal > 0 ? 1 - s.memFree / s.memTotal : 0,
                         center: Fmt.mem(s.memFree), label: "Memory free")
                    if !s.gpuNodes.isEmpty {
                        Spacer(minLength: 0)
                        Ring(used: s.gpuTotal > 0 ? 1 - Double(s.gpuFree) / Double(s.gpuTotal) : 1,
                             center: "\(s.gpuFree)/\(s.gpuTotal)", label: "GPUs free")
                    }
                }
                .padding(.horizontal, 10)
                you(s)
                NodeMap(snapshot: s, width: width - 2 * padding, cell: 7, gap: 2, labelWidth: 62, labelSize: 9, hover: $hover)
                if let hover {
                    Text(hover).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(store.needsSetup ? "Right-click → Cluster settings… to set your cluster's SSH host."
                     : store.error ?? "Connecting to \(store.clusterName)…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(padding)
        .frame(width: width)
        .background(PanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        .contextMenu {
            Button("Refresh now") { store.refresh() }
            Button("Cluster settings…") { store.showSettings() }
            Divider()
            Button {
                WidgetController.shared.onTop = true
            } label: {
                if WidgetController.shared.onTop { Label("Always on top", systemImage: "checkmark") } else { Text("Always on top") }
            }
            Button {
                WidgetController.shared.onTop = false
            } label: {
                if !WidgetController.shared.onTop { Label("On desktop (behind windows)", systemImage: "checkmark") } else { Text("On desktop (behind windows)") }
            }
            Divider()
            Button("Hide widget (double-click the app to show again)") { WidgetController.shared.hide() }
            Button("Quit SLURM Meter") { NSApp.terminate(nil) }
        }
    }

    /// The user's own usage against their per-user limits.
    private func you(_ s: ClusterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                stat("Your jobs", "\(s.myRunning.count)", s.limits?.maxJobs.map { "/\($0)" })
                Spacer(minLength: 0)
                stat("Your CPUs", "\(s.myCPU)", s.limits?.maxCPU.map { "/\($0)" })
                Spacer(minLength: 0)
                stat("Pending jobs", "\(s.myPending.count)", nil)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Your memory").font(.system(size: 9.5)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if let used = s.myMemUsed {
                        Text("\(Fmt.mem(used)) used").font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text("/").foregroundStyle(.secondary)
                    }
                    Text("\(Fmt.mem(s.myMem)) reserved").font(.system(size: 12, weight: .semibold, design: .rounded))
                    if let max = s.limits?.maxMem {
                        Text("(limit \(Fmt.mem(max)))").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
            }
            .help("Used = the sum of each running job's peak memory so far (sstat MaxRSS). Reserved = the memory your jobs requested, which SLURM holds for them.")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func stat(_ label: String, _ value: String, _ limit: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.system(size: 12, weight: .semibold, design: .rounded))
                if let limit { Text(limit).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            .monospacedDigit()
        }
    }
}

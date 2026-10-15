import SwiftUI
import ServiceManagement

@MainActor
final class ClusterStore: ObservableObject {
    static let shared = ClusterStore()

    @Published private(set) var snapshot: ClusterSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var loading = false
    @Published private(set) var now = Date()
    @Published var widgetVisible = false

    @Published var refreshInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            scheduleTimer()
        }
    }

    /// The cluster to read from, as you'd pass it to `ssh` (a `~/.ssh/config` alias or user@host).
    /// Stored only in this Mac's preferences. `SLURM_METER_HOST` overrides it (for testing).
    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "sshHost") }
    }

    /// Partitions to leave out, e.g. a login or debug partition (comma-separated).
    @Published var hiddenPartitions: String {
        didSet { UserDefaults.standard.set(hiddenPartitions, forKey: "hiddenPartitions") }
    }

    var hidden: Set<String> {
        Set(hiddenPartitions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    var effectiveHost: String {
        ProcessInfo.processInfo.environment["SLURM_METER_HOST"] ?? host.trimmingCharacters(in: .whitespaces)
    }

    var needsSetup: Bool { effectiveHost.isEmpty }

    /// Screenshot aid: a name to show instead of the configured host.
    var demoName: String?

    /// Short name for headers: "alice@login1.hpc.example.edu" → "login1".
    var clusterName: String {
        if let demoName { return demoName }
        let h = effectiveHost.split(separator: "@").last.map(String.init) ?? effectiveHost
        return h.split(separator: ".").first.map(String.init) ?? "Cluster"
    }

    private let service = ClusterService()
    private var timer: Timer?
    private var tickTimer: Timer?

    private init() {
        let saved = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = saved >= 60 ? saved : 600
        host = UserDefaults.standard.string(forKey: "sshHost") ?? ""
        hiddenPartitions = UserDefaults.standard.string(forKey: "hiddenPartitions") ?? ""
    }

    func start() {
        if let (snap, date) = ClusterService.loadCache(hidden: hidden) {
            snapshot = snap
            updatedAt = date
        }
        refresh()
        scheduleTimer()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in ClusterStore.shared.now = Date() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { _ in
            // Give Wi-Fi / VPN a moment to come back after wake.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                ClusterStore.shared.refresh()
            }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            Task { @MainActor in ClusterStore.shared.refresh() }
        }
    }

    func refreshIfStale() {
        if let t = updatedAt, Date().timeIntervalSince(t) < 120 { return }
        refresh()
    }

    func refresh() {
        guard !loading, !needsSetup else { return }
        loading = true
        let host = effectiveHost, hidden = hidden
        Task {
            let result = await service.fetch(host: host, hidden: hidden)
            loading = false
            now = Date()
            switch result {
            case .success(let snap):
                snapshot = snap
                updatedAt = now
                error = nil
            case .failure(let err):
                error = err.message
            }
        }
    }

    /// Screenshot aid: show a snapshot without fetching.
    func show(_ snap: ClusterSnapshot, at date: Date) {
        snapshot = snap
        updatedAt = date
        now = Date()
        widgetVisible = true
    }

    // MARK: Settings

    /// A small dialog for the SSH host and hidden partitions.
    func showSettings() {
        let hostField = NSTextField(string: host)
        hostField.placeholderString = "user@login.cluster.edu or an ~/.ssh/config alias"
        let hiddenField = NSTextField(string: hiddenPartitions)
        hiddenField.placeholderString = "e.g. login, debug (optional)"
        for f in [hostField, hiddenField] { f.translatesAutoresizingMaskIntoConstraints = false; f.widthAnchor.constraint(equalToConstant: 300).isActive = true }

        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            l.textColor = .secondaryLabelColor
            return l
        }
        let stack = NSStackView(views: [label("SSH host"), hostField, label("Hide partitions"), hiddenField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(12, after: hostField)
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 110)

        let alert = NSAlert()
        alert.messageText = "Cluster settings"
        alert.informativeText = "SLURM status is read over SSH with key-based login (no password prompt). Only read-only commands are run: scontrol, squeue, sacctmgr, sstat."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = hostField
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        hiddenPartitions = hiddenField.stringValue
        snapshot = nil
        updatedAt = nil
        error = nil
        refresh()
    }

    // MARK: Launch at login

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "Couldn't change launch at login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }
}

import SwiftUI
import AppKit

@main
struct SlurmMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = ClusterStore.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            if let dir = Snapshot.outputDir {
                Snapshot.run(to: dir)
            } else {
                ClusterStore.shared.start()
                WidgetController.shared.restore()
            }
        }
    }

    /// Double-clicking the app while it's already running brings the widget back (e.g. after "Hide widget").
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { WidgetController.shared.show() }
        return false
    }
}

/// Menu bar: free CPUs and memory across the CPU partitions.
struct MenuBarLabel: View {
    @ObservedObject var store: ClusterStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "server.rack")
            if let s = store.snapshot {
                Text("\(s.cpuFree) CPU · \(Fmt.mem(s.memFree))").monospacedDigit()
            } else {
                Text("–")
            }
        }
    }
}

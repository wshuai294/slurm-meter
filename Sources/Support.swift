import SwiftUI
import AppKit

// MARK: - Shell

enum Shell {
    struct Output: Sendable { let status: Int32; let stdout: String; let stderr: String }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> Output? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { p.terminate() }
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: Output(status: p.terminationStatus,
                                              stdout: String(decoding: data, as: UTF8.self),
                                              stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}

// MARK: - Colors

enum Palette {
    /// Green → yellow → orange → red as something fills up.
    static func status(_ percent: Double) -> Color {
        switch percent {
        case ..<50: return Color(hex: 0x0ca30c)
        case ..<75: return Color(hex: 0xfab219)
        case ..<90: return Color(hex: 0xec835a)
        default: return Color(hex: 0xd03b3b)
        }
    }

    static let down = Color.primary.opacity(0.15)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                           green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}

// MARK: - Formatting

enum Fmt {
    static func duration(_ s: TimeInterval) -> String {
        let total = max(Int(s), 0)
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = now.timeIntervalSince(date)
        return s < 60 ? "just now" : "\(duration(s)) ago"
    }

    /// Memory in MB → "415G" / "9.4T".
    static func mem(_ mb: Double) -> String {
        let gb = mb / 1024
        if gb >= 1000 {
            let tb = gb / 1024
            return tb >= 10 ? "\(Int(tb.rounded()))T" : String(format: "%.1fT", tb)
        }
        return "\(Int(gb.rounded()))G"
    }

    static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Bars and rings

struct UsageBar: View {
    let fraction: Double   // 0...1 used
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(Palette.status(fraction * 100))
                    .frame(width: max(fraction > 0 ? height : 0, geo.size.width * min(fraction, 1)))
            }
        }
        .frame(height: height)
    }
}

/// Ring filled by how much is in use, with the free amount in the middle.
struct Ring: View {
    let used: Double       // 0...1
    let center: String
    let label: String
    var size: CGFloat = 64
    var line: CGFloat = 7

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: line)
                Circle()
                    .trim(from: 0, to: min(max(used, 0), 1))
                    .stroke(Palette.status(used * 100), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(center)
                    .font(.system(size: size * 0.22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, line + 2)
            }
            .frame(width: size, height: size)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .animation(.easeOut(duration: 0.4), value: used)
    }
}

// MARK: - Snapshot mode

/// True while rendering screenshots: AppKit-backed views (blur, buttons, switches, menus)
/// don't render through ImageRenderer, so views swap in plain SwiftUI look-alikes.
private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// The widget/popover background: live blur, or a flat fill in snapshot mode.
struct PanelBackground: View {
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        if snapshotMode {
            Color(light: 0xf4f4f6, dark: 0x29292c).opacity(0.94)
        } else {
            VisualEffectBackground()
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

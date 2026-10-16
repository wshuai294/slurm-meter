import SwiftUI

/// The user's own jobs against their per-user limits — the part people check most, so it's prominent.
struct YourJobsCard: View {
    let snapshot: ClusterSnapshot

    var body: some View {
        let s = snapshot, l = s.limits
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Your jobs").font(.system(size: 13, weight: .semibold))
                Text(s.user).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let q = l?.qos {
                    Text("QOS \(q) limits").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                BigStat(label: "Running", value: "\(s.myRunning.count)", limit: l?.maxJobs,
                        fraction: l?.maxJobs.map { Double(s.myRunning.count) / Double(max($0, 1)) })
                BigStat(label: "CPUs", value: "\(s.myCPU)", limit: l?.maxCPU,
                        fraction: l?.maxCPU.map { Double(s.myCPU) / Double(max($0, 1)) })
                BigStat(label: "Pending", value: "\(s.myPending.count)", limit: nil, fraction: nil)
            }
            memory(s)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
    }

    private func memory(_ s: ClusterSnapshot) -> some View {
        let limit = s.limits?.maxMem
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Memory").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let used = s.myMemUsed {
                    Text(Fmt.mem(used)).font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("used ·").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Text(Fmt.mem(s.myMem)).font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("reserved").font(.system(size: 10.5)).foregroundStyle(.secondary)
                if let limit {
                    Text("/ \(Fmt.mem(limit))").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            MemoryBar(used: s.myMemUsed, reserved: s.myMem, scale: limit ?? max(s.myMem, 1))
        }
        .help("Used = the sum of each running job's peak memory so far (sstat MaxRSS). Reserved = the memory your jobs requested, which SLURM holds for them. The bar runs up to your per-user limit.")
    }
}

/// A big number with its limit and a thin bar underneath.
private struct BigStat: View {
    let label: String
    let value: String
    let limit: Int?
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 24, weight: .semibold, design: .rounded))
                if let limit {
                    Text("/\(limit)").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            if let fraction {
                UsageBar(fraction: fraction, height: 5)
            } else {
                Color.clear.frame(height: 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Reserved memory as a light fill, actually-used memory as a solid fill inside it.
private struct MemoryBar: View {
    let used: Double?
    let reserved: Double
    let scale: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let r = min(reserved / scale, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(Palette.status(r * 100).opacity(0.35)).frame(width: w * r)
                if let used {
                    Capsule().fill(Palette.status(r * 100)).frame(width: w * min(used / scale, r))
                }
            }
        }
        .frame(height: 6)
    }
}

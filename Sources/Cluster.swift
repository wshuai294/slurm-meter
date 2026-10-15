import Foundation

// MARK: - Model

struct Node: Identifiable, Sendable {
    let name: String
    let partitions: [String]
    let state: String           // e.g. "MIXED", "DOWN+NOT_RESPONDING", "IDLE+DRAIN"
    let cpuTotal: Int
    let cpuAlloc: Int
    let memTotal: Double        // MB
    let memAlloc: Double        // MB
    var gpuTotal = 0
    var gpuAlloc = 0
    var id: String { name }

    var isDown: Bool {
        ["DOWN", "NOT_RESPONDING", "FAIL", "FUTURE", "POWERED_DOWN", "UNKNOWN", "INVAL"].contains { state.contains($0) }
    }
    var isDraining: Bool { state.contains("DRAIN") }
    /// Accepting new jobs.
    var isUp: Bool { !isDown && !isDraining }

    var cpuFree: Int { isUp ? max(cpuTotal - cpuAlloc, 0) : 0 }
    var memFree: Double { isUp ? max(memTotal - memAlloc, 0) : 0 }
    var gpuFree: Int { isUp ? max(gpuTotal - gpuAlloc, 0) : 0 }
    /// How full the node is for scheduling: whichever of CPU or memory is more allocated.
    var load: Double {
        max(cpuTotal > 0 ? Double(cpuAlloc) / Double(cpuTotal) : 0, memTotal > 0 ? memAlloc / memTotal : 0)
    }

    /// Node type, e.g. "64c · 768G". SLURM's RealMemory is a bit below the installed RAM,
    /// so it's rounded up to the nearest common size.
    var typeLabel: String {
        let gb = memTotal / 1024
        let sizes: [Double] = [16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384]
        let nominal = sizes.first { $0 >= gb && $0 <= gb * 1.15 }
        return "\(cpuTotal)c · \(Fmt.mem((nominal ?? gb) * 1024))"
    }

    var summary: String {
        if isDown { return "\(name) · down" }
        if isDraining { return "\(name) · draining (no new jobs)" }
        let gpu = gpuTotal > 0 ? " · \(gpuFree) of \(gpuTotal) GPU" : ""
        return "\(name) · \(cpuFree) of \(cpuTotal) CPU · \(Fmt.mem(memFree)) of \(Fmt.mem(memTotal))\(gpu) free"
    }
}

struct Job: Sendable {
    let user: String
    let state: String           // R, PD, CG, ...
    let cpus: Int
    let mem: Double             // MB
    let timeLeft: TimeInterval?
    let partition: String
    let reason: String
}

struct Limits: Sendable {
    var qos: String
    var maxJobs: Int?
    var maxCPU: Int?
    var maxMem: Double?         // MB
}

struct ClusterSnapshot: Sendable {
    let user: String
    let nodes: [Node]           // CPU nodes only
    let gpuNodes: [Node]        // nodes with GPUs (gpu partitions)
    let jobs: [Job]             // jobs in CPU partitions
    let limits: Limits?
    /// Actual memory in use by the user's running jobs (sum of each job's peak so far, from sstat); MB.
    var myMemUsed: Double?

    var up: [Node] { nodes.filter(\.isUp) }
    var downCount: Int { nodes.filter(\.isDown).count }
    var drainingCount: Int { nodes.filter { !$0.isDown && $0.isDraining }.count }
    var idleCount: Int { up.filter { $0.cpuAlloc == 0 }.count }

    var cpuTotal: Int { up.reduce(0) { $0 + $1.cpuTotal } }
    var cpuFree: Int { up.reduce(0) { $0 + $1.cpuFree } }
    var memTotal: Double { up.reduce(0) { $0 + $1.memTotal } }
    var memFree: Double { up.reduce(0) { $0 + $1.memFree } }

    var gpuTotal: Int { gpuNodes.filter(\.isUp).reduce(0) { $0 + $1.gpuTotal } }
    var gpuFree: Int { gpuNodes.reduce(0) { $0 + $1.gpuFree } }

    /// Node types, smallest first, each with its nodes in natural order.
    var groups: [(label: String, nodes: [Node])] {
        Dictionary(grouping: nodes, by: \.typeLabel).values
            .map { ns in (ns[0].typeLabel, ns.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { ($0.nodes[0].cpuTotal, $0.nodes[0].memTotal) < ($1.nodes[0].cpuTotal, $1.nodes[0].memTotal) }
    }

    var mostFreeCPU: Node? { up.max { ($0.cpuFree, $0.memFree) < ($1.cpuFree, $1.memFree) } }
    var mostFreeMem: Node? { up.max { ($0.memFree, $0.cpuFree) < ($1.memFree, $1.cpuFree) } }

    var running: [Job] { jobs.filter { $0.state == "R" } }
    var pending: [Job] { jobs.filter { $0.state == "PD" } }

    /// Pending jobs by reason, most common first.
    var pendingReasons: [(reason: String, count: Int)] {
        Dictionary(grouping: pending, by: { Self.reasonText($0.reason) })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }

    var mine: [Job] { jobs.filter { $0.user == user } }
    var myRunning: [Job] { mine.filter { $0.state == "R" } }
    var myPending: [Job] { mine.filter { $0.state == "PD" } }
    var myCPU: Int { myRunning.reduce(0) { $0 + $1.cpus } }
    var myMem: Double { myRunning.reduce(0) { $0 + $1.mem } }

    static func reasonText(_ r: String) -> String {
        switch r {
        case "QOSMaxJobsPerUserLimit": return "owner's job limit"
        case "QOSMaxCpuPerUserLimit", "QOSMaxMemoryPerUser", "QOSMaxTRESPerUser": return "owner's CPU/memory limit"
        case "Resources": return "waiting for free nodes"
        case "Priority": return "behind higher priority"
        case "Dependency": return "waiting on another job"
        case "JobArrayTaskLimit": return "array throttle (%)"
        case "JobHeldUser", "JobHeldAdmin": return "held"
        case "BeginTime": return "scheduled for later"
        case "DependencyNeverSatisfied": return "dependency failed"
        default: return r.hasPrefix("ReqNodeNotAvail") ? "requested nodes unavailable" : r
        }
    }
}

// MARK: - Fetch

enum ClusterError: Error, Sendable {
    case unreachable(String)
    case parse

    var message: String {
        switch self {
        case .unreachable(let detail): return "Can't reach the cluster (offline or VPN?)" + (detail.isEmpty ? "" : " — \(detail)")
        case .parse: return "Unexpected output from SLURM."
        }
    }
}

actor ClusterService {
    private static let script = """
    echo @@user; whoami
    echo @@nodes; scontrol show node -o
    echo @@jobs; squeue -h -r -O "UserName:|,StateCompact:|,NumCPUs:|,TimeLeft:|,Partition:|,Reason:|,tres-alloc:"
    echo @@qos; q=$(sacctmgr -n -P show assoc user=$(whoami) format=DefaultQOS | grep . | head -1)
    sacctmgr -n -P show qos "${q:-normal}" format=Name,MaxJobsPU,MaxTRESPU
    echo @@mymem; ids=$(squeue -h -u $(whoami) -t R -o %i | paste -sd, -)
    if [ -n "$ids" ]; then sstat -a -n -P -j "$ids" -o JobID,MaxRSS 2>/dev/null; fi
    true
    """

    private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SlurmMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last.txt")
    }()

    /// `host` is anything `ssh` accepts (a `~/.ssh/config` alias or user@host); key-based login is required.
    func fetch(host: String, hidden: Set<String>) async -> Result<ClusterSnapshot, ClusterError> {
        let out = await Shell.run("/usr/bin/ssh",
                                  ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=10",
                                   host, Self.script],
                                  timeout: 60)
        // ssh itself exits 255 when it can't connect; any other status comes from the remote script,
        // so judge that by whether the output parses (an optional step failing shouldn't hide the data).
        guard let out, out.status != 255, !out.stdout.isEmpty else {
            let detail = out?.stderr.split(separator: "\n").last.map(String.init) ?? ""
            return .failure(.unreachable(detail.trimmingCharacters(in: .whitespaces)))
        }
        guard let snap = Self.parse(out.stdout, hidden: hidden) else { return .failure(.parse) }
        try? out.stdout.write(to: Self.cacheURL, atomically: true, encoding: .utf8)
        return .success(snap)
    }

    /// The last successful output and when it was fetched, so a restart shows numbers immediately.
    static func loadCache(hidden: Set<String>) -> (ClusterSnapshot, Date)? {
        guard let text = try? String(contentsOf: cacheURL, encoding: .utf8),
              let snap = parse(text, hidden: hidden),
              let date = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
        else { return nil }
        return (snap, date)
    }

    // MARK: Parsing

    /// `hidden`: partitions to leave out (e.g. a login or debug partition). GPU nodes are shown
    /// separately, and jobs in GPU-only partitions don't count toward the CPU queue.
    static func parse(_ text: String, hidden: Set<String>) -> ClusterSnapshot? {
        var sections: [String: [String]] = [:]
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("@@") { current = String(line.dropFirst(2)); continue }
            sections[current, default: []].append(String(line))
        }
        guard let user = sections["user"]?.first?.trimmingCharacters(in: .whitespaces),
              let nodeLines = sections["nodes"], !nodeLines.isEmpty else { return nil }

        let all = nodeLines.compactMap(parseNode)
            .filter { !$0.partitions.isEmpty && !$0.partitions.allSatisfy(hidden.contains) }
        let nodes = all.filter { $0.gpuTotal == 0 }
        let gpuNodes = all.filter { $0.gpuTotal > 0 }
        guard !all.isEmpty else { return nil }

        // Partitions made up only of GPU nodes.
        let partitions = Set(all.flatMap(\.partitions))
        let gpuOnly = partitions.filter { p in all.filter { $0.partitions.contains(p) }.allSatisfy { $0.gpuTotal > 0 } }
        let jobs = (sections["jobs"] ?? []).compactMap(parseJob)
            .filter { !hidden.contains($0.partition) && !gpuOnly.contains($0.partition) }
        let limits = sections["qos"]?.first.flatMap(parseLimits)
        var snap = ClusterSnapshot(user: user, nodes: nodes, gpuNodes: gpuNodes, jobs: jobs, limits: limits)
        if let lines = sections["mymem"] { snap.myMemUsed = parseStepMemory(lines) }
        return snap
    }

    /// One `scontrol show node -o` line of space-separated key=value pairs.
    static func parseNode(_ line: String) -> Node? {
        var kv: [String: String] = [:]
        for token in line.split(separator: " ") {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<eq])
            if kv[key] == nil { kv[key] = String(token[token.index(after: eq)...]) }
        }
        guard let name = kv["NodeName"], let cpuTotal = Int(kv["CPUTot"] ?? "") else { return nil }
        // "CfgTRES=cpu=128,...,gres/gpu=8" and "AllocTRES=...,gres/gpu=2"
        func gpus(_ tres: String?) -> Int {
            (tres ?? "").split(separator: ",").first { $0.hasPrefix("gres/gpu=") }
                .flatMap { Int($0.dropFirst("gres/gpu=".count)) } ?? 0
        }
        return Node(name: name,
                    partitions: (kv["Partitions"] ?? "").split(separator: ",").map(String.init),
                    state: kv["State"] ?? "UNKNOWN",
                    cpuTotal: cpuTotal,
                    cpuAlloc: Int(kv["CPUAlloc"] ?? "") ?? 0,
                    memTotal: Double(kv["RealMemory"] ?? "") ?? 0,
                    memAlloc: Double(kv["AllocMem"] ?? "") ?? 0,
                    gpuTotal: gpus(kv["CfgTRES"]),
                    gpuAlloc: gpus(kv["AllocTRES"]))
    }

    /// "alice|R|8|2-23:52:13|normal|None|cpu=8,mem=150G,node=1,billing=8"
    static func parseJob(_ line: String) -> Job? {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count >= 7 else { return nil }
        let tres = Dictionary(f[6].split(separator: ",").compactMap { pair -> (String, String)? in
            let p = pair.split(separator: "=", maxSplits: 1)
            return p.count == 2 ? (String(p[0]), String(p[1])) : nil
        }, uniquingKeysWith: { a, _ in a })
        return Job(user: f[0], state: f[1], cpus: Int(f[2]) ?? 0,
                   mem: tres["mem"].flatMap(parseMem) ?? 0,
                   timeLeft: parseDuration(f[3]), partition: f[4], reason: f[5])
    }

    /// sstat "1234.batch|96456308K" lines → total MB across job steps (each step counted once; extern skipped).
    static func parseStepMemory(_ lines: [String]) -> Double? {
        var steps: [String: Double] = [:]
        for line in lines {
            let f = line.split(separator: "|").map(String.init)
            guard f.count >= 2, !f[0].hasSuffix(".extern"), let mb = parseMem(f[1]) else { continue }
            steps[f[0]] = mb
        }
        return steps.isEmpty ? nil : steps.values.reduce(0, +)
    }

    /// "normal|10|cpu=120,mem=3T"
    static func parseLimits(_ line: String) -> Limits? {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3 else { return nil }
        var limits = Limits(qos: f[0], maxJobs: Int(f[1]))
        for pair in f[2].split(separator: ",") {
            let p = pair.split(separator: "=", maxSplits: 1)
            guard p.count == 2 else { continue }
            if p[0] == "cpu" { limits.maxCPU = Int(p[1]) }
            if p[0] == "mem" { limits.maxMem = parseMem(String(p[1])) }
        }
        return limits
    }

    /// "150G" / "250000M" / "3T" → MB
    static func parseMem(_ s: String) -> Double? {
        guard let unit = s.last, let v = Double(s.dropLast()) else { return Double(s) }
        switch unit {
        case "K": return v / 1024
        case "M": return v
        case "G": return v * 1024
        case "T": return v * 1024 * 1024
        default: return Double(s)
        }
    }

    /// SLURM time "2-16:37:19", "2:14:07", "14:07" → seconds; nil for UNLIMITED / NOT_SET / INVALID.
    static func parseDuration(_ s: String) -> TimeInterval? {
        var days = 0.0, rest = Substring(s)
        if let dash = s.firstIndex(of: "-") {
            guard let d = Double(s[..<dash]) else { return nil }
            days = d
            rest = s[s.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count == rest.split(separator: ":").count else { return nil }
        let secs: Double
        switch parts.count {
        case 3: secs = parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: secs = parts[0] * 60 + parts[1]
        default: secs = parts[0] * 60
        }
        return days * 86400 + secs
    }
}

// Cuts a guided recording into individual key/click sounds.
//   slice <in.wav>                               print level stats
//   slice <in.wav> <outdir> name:start-end ...   per time window: detect hits, sort into down/up/space, write WAVs
//   MAX=<n> keeps only the n most typical hits of each kind (closest to its median level)
//   SPLIT=bright tells presses from releases by pitch (darker = press) instead of loudness
//   name.kind:start-end (e.g. jade.down:0.85-1.1) puts every hit in that window into <outdir>/name as that kind
import AVFoundation

let args = CommandLine.arguments
let inFile = try! AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
let sr = inFile.processingFormat.sampleRate
let inBuf = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: AVAudioFrameCount(inFile.length))!
try! inFile.read(into: inBuf)
var x = Array(UnsafeBufferPointer(start: inBuf.floatChannelData![0], count: Int(inBuf.frameLength)))
// 40 Hz high-pass removes desk rumble and DC.
let hpA = Float(exp(-2 * .pi * 40 / sr))
var px: Float = 0, py: Float = 0
for i in x.indices { py = hpA * (py + x[i] - px); px = x[i]; x[i] = py }

let hop = Int(sr / 1000)  // envelope resolution: 1 ms
let env = stride(from: 0, to: x.count - hop, by: hop).map { j in x[j..<j + hop].map(abs).max()! }
func db(_ v: Float) -> String { String(format: "%.1fdB", 20 * log10(max(v, 1e-9))) }
func median(_ a: [Float]) -> Float { a.isEmpty ? 0 : a.sorted()[a.count / 2] }

if args.count == 2 {
    let floor = median(env)
    print("duration \(String(format: "%.1f", Double(x.count) / sr))s  peak \(db(x.map(abs).max()!))  floor \(db(floor))")
    // Timeline: one row per 0.5 s, bar = loudest moment above the noise floor, count = hits in that bin.
    for b in stride(from: 0, to: env.count, by: 500) {
        let bin = env[b..<min(env.count, b + 500)], top = bin.max()!
        let n = zip(bin.dropFirst(), bin).filter { $0.0 > floor * 6 && $0.1 <= floor * 6 }.count
        print(String(format: "%5.1fs %2d ", Double(b) / 1000, n) + String(repeating: "█", count: max(0, Int(20 * log10(top / floor) / 2))))
    }
    exit(0)
}

struct Hit { let start, end, peakAt: Int; let peak: Float }  // in ms
func hits(_ lo: Int, _ hi: Int) -> (hits: [Hit], floor: Float) {
    let floor = median(Array(env[lo..<hi])), thr = floor * 6
    var out: [Hit] = [], j = lo
    while j < hi {
        guard env[j] > thr else { j += 1; continue }
        var e = j, quiet = 0
        while e < min(hi, j + 200) && quiet < 8 { quiet = env[e] < floor * 2 ? quiet + 1 : 0; e += 1 }
        let peakAt = (j..<e).max { env[$0] < env[$1] }!
        if quiet >= 8 { out.append(Hit(start: j, end: e - quiet, peakAt: peakAt, peak: env[peakAt])) }  // unended = not a click
        j = e + 15
    }
    return (out, floor)
}
// RMS frequency: a cheap brightness measure.
func brightness(_ s: [Float]) -> Double {
    let e = s.reduce(0) { $0 + Double($1 * $1) }
    let d = zip(s.dropFirst(), s).reduce(0) { $0 + Double(($1.0 - $1.1) * ($1.0 - $1.1)) }
    return sqrt(d / max(e, 1e-12)) * sr / (2 * .pi)
}
// Keeps the case's ringing tail down into the noise floor and fades it out gently; chopping it short sounds fake.
// The laptop mic also caught room echo after each hit (the "cheap recorder" sound), so once the hit has held
// for half its length (12 ms min), what's left decays `tight` ms faster, like a close-mic recording.
let tight = Double(ProcessInfo.processInfo.environment["TIGHT"] ?? "10")!  // tuning: decay τ in ms, 0 = off
func cut(_ h: Hit) -> [Float] {
    let a = max(0, (h.start - 3) * hop), b = min(x.count, (h.end + 20) * hop)
    var s = Array(x[a..<b])
    if tight > 0, let peak = s.indices.max(by: { abs(s[$0]) < abs(s[$1]) }) {
        let hold = peak + max(12, (h.end - h.start) / 2) * hop
        for i in hold..<max(hold, s.count) { s[i] *= Float(exp(-Double(i - hold) / sr * 1000 / tight)) }
    }
    let fi = hop, fo = 15 * hop
    for i in 0..<min(fi, s.count) { s[i] *= Float(i) / Float(fi) }
    for i in 0..<min(fo, s.count) { s[s.count - 1 - i] *= Float(i) / Float(fo) }
    return s
}

var outputs: [(path: String, samples: [Float])] = [], counts: [String: Int] = [:]
for spec in args.dropFirst(3) {
    let p = spec.split(separator: ":"), range = p[1].split(separator: "-").map { Double($0)! }
    let label = p[0].split(separator: "."), name = String(label[0]), forced = label.count > 1 ? String(label[1]) : nil
    let (h, floor) = hits(Int(range[0] * 1000), min(env.count, Int(range[1] * 1000)))
    if ProcessInfo.processInfo.environment["VERBOSE"] != nil {
        for hit in h { print(String(format: "  %@ %6.3fs  peak %@  len %3dms  bright %4.0fHz", String(p[0]) as NSString,
                                    Double(hit.start) / 1000, db(hit.peak), hit.end - hit.start, brightness(cut(hit)))) }
    }
    // Real typing overlaps presses and releases, so hits are sorted by character rather than paired: outliers
    // (bumps, other noises) more than 8 dB from the typical hit are dropped, long hits whose peak comes early are the
    // big keys (space/enter; a late peak means two keystrokes ran together), and of the rest the louder half are
    // presses and the quieter half releases.
    let mid = median(h.map(\.peak)), kept = h.filter { $0.peak > mid / 2.5 && $0.peak < mid * 2.5 }
    // SPLIT=bright sorts presses from releases by pitch instead: on Topre the press is the low, dome-cushioned thock
    // ("도") and the release the louder, higher tick of the slider hitting the housing ("각").
    let byPitch = ProcessInfo.processInfo.environment["SPLIT"] == "bright"
    let pressness = { (h: Hit) in byPitch ? Float(-brightness(cut(h))) : h.peak }
    let big = kept.filter { $0.end - $0.start >= 45 && $0.peakAt - $0.start < 10 }, small = kept.filter { $0.end - $0.start < 45 }
    let split = median(small.map(pressness))
    let maxClips = Int(ProcessInfo.processInfo.environment["MAX"] ?? "") ?? .max
    let typical = { (set: [Hit]) -> [Hit] in
        let m = median(set.map(\.peak))
        return Array(set.sorted { abs(log($0.peak / m)) < abs(log($1.peak / m)) }.prefix(maxClips))
    }
    let groups = forced.map { [($0, kept)] }
        ?? [("down", typical(small.filter { pressness($0) >= split })), ("up", typical(small.filter { pressness($0) < split })),
            ("space", typical(big))]
    for (kind, set) in groups {
        for hit in set {
            let k = counts["\(name)/\(kind)", default: 0]
            counts["\(name)/\(kind)"] = k + 1
            outputs.append(("\(args[2])/\(name)/\(kind)_\(String(format: "%02d", k)).wav", cut(hit)))
        }
        let cuts = set.map(cut)
        print(String(format: "%-8@ %-4@ n=%2d  peak %@  len %3.0fms  bright %4.0fHz  snr %@", String(p[0]) as NSString, kind as NSString,
                     set.count, db(median(set.map(\.peak))), set.map { Double($0.end - $0.start) }.reduce(0, +) / Double(max(set.count, 1)),
                     cuts.map(brightness).reduce(0, +) / Double(max(cuts.count, 1)), db(median(set.map(\.peak)) / floor)))
    }
}
// One gain for every clip keeps the natural loud/soft variation between keystrokes; the app sets the overall level.
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
let gain = 0.9 / outputs.flatMap { $0.samples.map(abs) }.max()!
for o in outputs {
    try? FileManager.default.createDirectory(atPath: (o.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(o.samples.count))!
    b.frameLength = AVAudioFrameCount(o.samples.count)
    for i in o.samples.indices { b.floatChannelData![0][i] = o.samples[i] * gain }
    try! AVAudioFile(forWriting: URL(fileURLWithPath: o.path), settings: fmt.settings).write(from: b)
}
print("wrote \(outputs.count) files to \(args[2])")

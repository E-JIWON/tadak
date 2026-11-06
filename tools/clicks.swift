// Cuts a mouse recording into presses and releases: clicks <in.wav> <outdir> [start-end s]
// A click starts where the 0.5 ms envelope jumps 30 dB over the noise (and is within 30 dB of the loudest click), and
// ends once it has stayed 30 dB under its own peak for 3 ms (at most 60 ms). A click followed by another within
// 250 ms is a press and its release; a lone click counts as a press.
import AVFoundation
let a = CommandLine.arguments
let f = try! AVAudioFile(forReading: URL(fileURLWithPath: a[1]))
let sr = f.processingFormat.sampleRate
let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
try! f.read(into: b)
var x = UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)).map(Double.init)
if a.count > 3 { let r = a[3].split(separator: "-").map { Double($0)! }; x = Array(x[Int(r[0] * sr)..<min(x.count, Int(r[1] * sr))]) }
var hpA = exp(-2 * .pi * 40 / sr), px = 0.0, py = 0.0
for i in x.indices { py = hpA * (py + x[i] - px); px = x[i]; x[i] = py }
let hop = Int(sr / 2000), env = stride(from: 0, to: x.count - hop, by: hop).map { j in x[j..<j + hop].map(abs).max()! }
let sorted = env.sorted(), noise = max(sorted[sorted.count / 10], 1e-7), top = sorted.last!
let on = max(noise * 31.6, top * 0.0316)
var hits: [(start: Int, end: Int, peak: Double)] = [], j = 0
while j < env.count {
    guard env[j] > on else { j += 1; continue }
    let p = (j..<min(env.count, j + 6)).max { env[$0] < env[$1] }!, pk = env[p]
    var e = p, quiet = 0
    while e < min(env.count, j + 120) && quiet < 6 { quiet = env[e] < pk * 0.0316 ? quiet + 1 : 0; e += 1 }
    hits.append((j, e, pk)); j = e + 4
}
var downs: [[Double]] = [], ups: [[Double]] = [], k = 0, gaps: [Int] = []
func cut(_ h: (start: Int, end: Int, peak: Double)) -> [Double] {
    let s = max(0, (h.start - 2) * hop), e = min(x.count, (h.end + 10) * hop)
    var c = Array(x[s..<e]); let fo = min(c.count, 5 * hop)
    for i in 0..<fo { c[c.count - 1 - i] *= Double(i) / Double(fo) }
    return c
}
while k < hits.count {
    if k + 1 < hits.count && (hits[k + 1].start - hits[k].start) * hop < Int(0.25 * sr) { gaps.append((hits[k + 1].start - hits[k].start) / 2); downs.append(cut(hits[k])); ups.append(cut(hits[k + 1])); k += 2 }
    else { downs.append(cut(hits[k])); k += 1 }
}
print("press→release ms:", gaps.sorted())
guard !downs.isEmpty else { print("no clicks found"); exit(1) }
let gain = 0.9 / (downs + ups).flatMap { $0.map(abs) }.max()!
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
try? FileManager.default.createDirectory(atPath: a[2], withIntermediateDirectories: true)
for (kind, set) in [("down", downs), ("up", ups)] {
    for (i, c) in set.enumerated() {
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(c.count))!
        buf.frameLength = AVAudioFrameCount(c.count)
        for n in c.indices { buf.floatChannelData![0][n] = Float(c[n] * gain) }
        try! AVAudioFile(forWriting: URL(fileURLWithPath: "\(a[2])/\(kind)_\(String(format: "%02d", i)).wav"), settings: fmt.settings).write(from: buf)
    }
    let db = { (v: Double) in 20 * log10(max(v, 1e-9)) }
    print(String(format: "%@ n=%2d  median peak %.1f dB  median len %.0f ms", kind, set.count,
                 db(set.map { $0.map(abs).max()! }.sorted()[max(0, set.count / 2)] * gain), set.map { Double($0.count) / sr * 1000 }.sorted()[max(0, set.count / 2)]))
}
print(String(format: "hits %d, noise %.1f dB, loudest %.1f dB", hits.count, 20 * log10(noise), 20 * log10(top)))

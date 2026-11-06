// Summarises folders of short WAV clips so recorded and synthesized sounds can be compared by numbers:
//   compare <dir> [<dir> ...]
// attack = ms from 10% to peak, len = ms until it stays below -20 dB of peak,
// tail = energy of the last 20 ms vs the loudest 5 ms, in dB (hiss and room ring left after the hit),
// bands = octave-band energy (125 Hz … 16 kHz) in dB relative to the loudest band, averaged over clips.
import AVFoundation

let centers: [Double] = [125, 250, 500, 1000, 2000, 4000, 8000, 16000]
func analyse(_ url: URL) -> (attack: Double, len: Double, tail: Double, bands: [Double]) {
    let f = try! AVAudioFile(forReading: url)
    let sr = f.processingFormat.sampleRate
    let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try! f.read(into: b)
    let x = Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))).map(Double.init)
    let peakAt = x.indices.max { abs(x[$0]) < abs(x[$1]) }!, peak = abs(x[peakAt])
    let rise = x.indices.first { abs(x[$0]) >= peak * 0.1 }!
    let end = x.indices.last { abs(x[$0]) >= peak * 0.1 }!
    // Plain DFT of the first 2048 samples, binned into octaves.
    let n = 2048, s = Array(x.prefix(n)) + Array(repeating: 0, count: max(0, n - x.count))
    var bands = [Double](repeating: 1e-12, count: centers.count)
    for k in 1..<n / 2 {
        let hz = Double(k) * sr / Double(n)
        guard let band = centers.firstIndex(where: { hz >= $0 / 2.squareRoot() && hz < $0 * 2.squareRoot() }) else { continue }
        var re = 0.0, im = 0.0
        for (i, v) in s.enumerated() { let a = 2 * .pi * Double(k * i) / Double(n); re += v * cos(a); im -= v * sin(a) }
        bands[band] += re * re + im * im
    }
    let top = bands.max()!
    let w = Int(sr * 0.005), t = Int(sr * 0.02)
    let hit = x[max(0, peakAt - w / 2)..<min(x.count, peakAt + w / 2)].map { $0 * $0 }.reduce(0, +) / Double(w)
    let tail = x.suffix(t).map { $0 * $0 }.reduce(0, +) / Double(t)
    return (Double(peakAt - rise) / sr * 1000, Double(end - rise) / sr * 1000, 10 * log10(max(tail, 1e-20) / hit),
            bands.map { 10 * log10($0 / top) })
}

print("                        n  attack   len    tail   " + centers.map { $0 >= 1000 ? String(format: "%3.0fk", $0 / 1000) : String(format: "%4.0f", $0) }.joined(separator: " "))
for arg in CommandLine.arguments.dropFirst() {  // <dir> or <dir>:<filename prefix>
    let parts = arg.split(separator: ":").map(String.init), dir = parts[0], prefix = parts.count > 1 ? parts[1] : ""
    let files = (try! FileManager.default.contentsOfDirectory(atPath: dir)).filter { $0.hasPrefix(prefix) && $0.hasSuffix(".wav") }.sorted()
    let r = files.map { analyse(URL(fileURLWithPath: dir).appendingPathComponent($0)) }
    let bands = centers.indices.map { i in r.map { $0.bands[i] }.reduce(0, +) / Double(r.count) }
    print(String(format: "%-22@ %2d  %5.1fms %5.1fms %5.0fdB ", ((dir as NSString).lastPathComponent + " " + prefix).padding(toLength: 22, withPad: " ", startingAt: 0) as NSString,
                 r.count, r.map(\.attack).reduce(0, +) / Double(r.count), r.map(\.len).reduce(0, +) / Double(r.count),
                 r.map(\.tail).reduce(0, +) / Double(r.count))
          + bands.map { String(format: "%4.0f", $0) }.joined(separator: " "))
}

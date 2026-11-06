// Tadak — 타이핑·클릭하면 키보드/마우스 소리가 나는 메뉴바 앱
import Cocoa
import SwiftUI
import AVFoundation
import os

let log = Logger(subsystem: "local.tadak", category: "app")
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
let sr = format.sampleRate

// RBJ-cookbook biquad: band-pass (0 dB peak), low-pass, high-pass, peaking, low-shelf or high-shelf.
struct Biquad {
    var b0, b1, b2, a1, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    init(bandpass hz: Double, q: Double) {
        let w = 2 * .pi * hz / sr, al = sin(w) / (2 * q), a0 = 1 + al
        b0 = al / a0; b1 = 0; b2 = -al / a0; a1 = -2 * cos(w) / a0; a2 = (1 - al) / a0
    }
    init(lowpass hz: Double) {
        let w = 2 * .pi * min(hz, sr * 0.45) / sr, al = sin(w) / (2 * 0.707), c = cos(w), a0 = 1 + al
        b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = b0; a1 = -2 * c / a0; a2 = (1 - al) / a0
    }
    init(highpass hz: Double) {
        let w = 2 * .pi * hz / sr, al = sin(w) / (2 * 0.707), c = cos(w), a0 = 1 + al
        b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = b0; a1 = -2 * c / a0; a2 = (1 - al) / a0
    }
    init(peak hz: Double, q: Double, db: Double) {
        let A = pow(10, db / 40), w = 2 * .pi * hz / sr, al = sin(w) / (2 * q), a0 = 1 + al / A
        b0 = (1 + al * A) / a0; b1 = -2 * cos(w) / a0; b2 = (1 - al * A) / a0; a1 = b1; a2 = (1 - al / A) / a0
    }
    init(lowshelf hz: Double, db: Double) {
        let A = pow(10, db / 40), w = 2 * .pi * hz / sr, c = cos(w), k = 2 * A.squareRoot() * sin(w) / 2.squareRoot()
        let a0 = (A + 1) + (A - 1) * c + k
        b0 = A * ((A + 1) - (A - 1) * c + k) / a0; b1 = 2 * A * ((A - 1) - (A + 1) * c) / a0
        b2 = A * ((A + 1) - (A - 1) * c - k) / a0; a1 = -2 * ((A - 1) + (A + 1) * c) / a0; a2 = ((A + 1) + (A - 1) * c - k) / a0
    }
    init(highshelf hz: Double, db: Double) {
        let A = pow(10, db / 40), w = 2 * .pi * hz / sr, c = cos(w), k = 2 * A.squareRoot() * sin(w) / 2.squareRoot()
        let a0 = (A + 1) - (A - 1) * c + k
        b0 = A * ((A + 1) + (A - 1) * c + k) / a0; b1 = -2 * A * ((A - 1) + (A + 1) * c) / a0
        b2 = A * ((A + 1) + (A - 1) * c - k) / a0; a1 = 2 * ((A - 1) - (A + 1) * c) / a0; a2 = ((A + 1) - (A - 1) * c - k) / a0
    }
    mutating func run(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

// Every sound is scaled to the same felt loudness: energy above 300 Hz (what small earbuds reproduce), with
// 1.5 kHz+ weighted +4 dB because the ear is most sensitive there — otherwise bright sounds jump out.
// `gain` is relative to that; peaks are capped below clipping.
let targetEnergy = 1e-3
func audibleEnergy(_ x: [Double]) -> Double {
    var hp = Biquad(highpass: 300), ear = Biquad(highshelf: 1500, db: 4)
    return max(x.reduce(0) { sum, v in let y = ear.run(hp.run(v)); return sum + y * y } / sr, 1e-12)
}
// A keystroke's first spike shouldn't stand more than ~10 dB over its body: a fast compressor (instant attack,
// 2 ms release) pulls anything above that down 6:1, so sharp clicks stay crisp without jumping out.
func soften(_ x: [Double]) -> [Double] {
    let head = x.prefix(Int(sr * 0.02))
    let limit = (head.map { $0 * $0 }.reduce(0, +) / Double(max(head.count, 1))).squareRoot() * pow(10, 10.0 / 20)
    let release = exp(-1 / (sr * 0.002))
    var env = 0.0
    return x.map { v in env = max(abs(v), env * release); return env > limit ? v * pow(limit / env, 5.0 / 6) : v }
}
func pcm(_ x: [Double], scale: Double) -> AVAudioPCMBuffer {
    let s = min(scale, 0.95 / max(x.map(abs).max()!, 1e-9))
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(x.count))!
    buf.frameLength = AVAudioFrameCount(x.count)
    for i in x.indices { buf.floatChannelData![0][i] = Float(x[i] * s) }
    return buf
}
struct Sounds { var down, up, space, enter: [AVAudioPCMBuffer] }

// Clips cut by tools/slice or tools/clicks (from tools/session.sh recordings or CC0 references): bundled in Resources/<folder>,
// or ./sounds/<folder> when run unbundled from the project folder. Any sample rate is converted to 48 kHz;
// `eq` corrects for where the mic sat.
func clips(_ folder: String, _ prefix: String, eq: [Biquad] = []) -> [[Double]] {
    let urls = [Bundle.main.resourceURL!.appendingPathComponent(folder), URL(fileURLWithPath: "sounds/\(folder)")]
        .lazy.compactMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }.first ?? []
    return urls.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "wav" }.compactMap { url in
        guard let f = try? AVAudioFile(forReading: url),
              let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: b)) != nil, b.frameLength > 1 else { return nil }
        var filters = eq, x = UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)).map(Double.init)
        if f.processingFormat.sampleRate != sr { x = resample(x, rate: f.processingFormat.sampleRate / sr) }
        for k in filters.indices { x = x.map { filters[k].run($0) } }
        return x
    }
}

// The set is scaled from the presses' median loudness, and each clip's distance from its own set's median is
// halved (in dB): natural variation stays, but no single keystroke jumps out. Each clip also gets copies
// nudged ±50 cents, so repeats don't sound canned.
func sounds(down: [[Double]], up: [[Double]], big: [[Double]], gain: Float = 1, cents: Double = 0) -> Sounds {
    let median = { (clips: [[Double]]) in clips.map(audibleEnergy).sorted()[clips.count / 2] }
    guard !down.isEmpty else { return Sounds(down: [], up: [], space: [], enter: []) }
    let scale = (targetEnergy / median(down)).squareRoot() * Double(gain)
    let make = { (clips: [[Double]]) -> [AVAudioPCMBuffer] in
        let set = clips.isEmpty ? down : clips, mid = median(set)
        return set.flatMap { c in
            let s = scale * pow(mid / audibleEnergy(c), 0.25)
            return [-50.0, -25, 0, 25, 50].map { pcm(resample(c, cents: cents + $0), scale: s) }
        }
    }
    return Sounds(down: make(down), up: make(up), space: make(big), enter: make(big))
}

// `upGain` sets the releases against the presses, `cents` shifts the whole set's pitch, `tight` (ms) shortens the
// ring after the hit (from `hold` ms past its peak), `body` moves the body toward another recording's (see matchBody),
// `damper` (dB) mutes the first clack as a silent switch's dampers do (see damp), and `outliers` (dB) drops keystrokes
// that much louder than their set's median once processed (0 keeps all).
typealias BodyMatch = (like: String, eq: [Biquad], amount: Double)
func recorded(_ folder: String, gain: Float = 1, upGain: Double = 1, eq: [Biquad] = [], body: BodyMatch? = nil,
              damper: Double = 0, cents: Double = 0, tight: Double = 0, hold: Double = 6, outliers: Double = 0) -> Sounds {
    let eq = eq + (body.map { matchBody(clips(folder, "down", eq: eq), to: clips($0.like, "down", eq: $0.eq), amount: $0.amount) } ?? [])
    let load = { (prefix: String, k: Double) -> [[Double]] in
        var xs = clips(folder, prefix, eq: eq).map { c in
            let x = tight > 0 ? tighten(c, tau: tight, hold: hold) : c
            return soften(dry(damper > 0 ? damp(x, db: damper) : x, noise: noiseFloor(c))).map { $0 * k }
        }
        if outliers > 0, !xs.isEmpty {
            let mid = xs.map(audibleEnergy).sorted()[xs.count / 2]
            xs = xs.filter { audibleEnergy($0) < mid * pow(10, outliers / 10) }
        }
        return xs
    }
    return sounds(down: load("down", 1), up: load("up", upGain), big: load("space", 1), gain: gain, cents: cents)
}

// A silent switch's dampers soften the impact itself: above 1.5 kHz the hit is `db` quieter up to 3 ms past its peak,
// easing back over the next 5 ms, so the clack goes but the case's pop that follows (and the stiff top's crispness)
// stays.
func damp(_ x: [Double], db: Double) -> [Double] {
    guard let peak = x.indices.max(by: { abs(x[$0]) < abs(x[$1]) }) else { return x }
    var a = Biquad(lowpass: 1500), b = Biquad(lowpass: 1500)
    let low = x.map { b.run(a.run($0)) }, g = pow(10, -db / 20)
    return x.indices.map { i in
        let t = Double(i - peak) / sr * 1000, k = t < 3 ? g : t < 8 ? g + (1 - g) * (t - 3) / 5 : 1
        return low[i] + (x[i] - low[i]) * k
    }
}

// Another board's body (its case and bottom-out): each half-octave from 125 Hz to 1.4 kHz, measured against the
// recording's own 2–8 kHz click and scratch, is moved `amount` of the way to `ref`'s level (at most ±9 dB). Above
// 2 kHz the switch keeps its own sound.
func matchBody(_ x: [[Double]], to ref: [[Double]], amount: Double) -> [Biquad] {
    let level = { (set: [[Double]], hz: Double) -> Double in
        set.map { c in var f = Biquad(bandpass: hz, q: 2.9); return c.reduce(0) { s, v in let y = f.run(v); return s + y * y } }.reduce(0, +)
    }
    let click = { (set: [[Double]]) in [2000.0, 2800, 4000, 5600, 8000].map { level(set, $0) }.reduce(0, +) }
    let body = { (set: [[Double]], hz: Double, ref: Double) in 10 * log10(level(set, hz) / ref) }
    let refClick = click(ref), ownClick = click(x)
    return (0..<8).map { 125 * pow(2, Double($0) / 2) }.map { hz in
        Biquad(peak: hz, q: 2, db: max(-9, min(9, amount * (body(ref, hz, refClick) - body(x, hz, ownClick)))))
    }
}

// Holds the hit for `hold` ms past its peak, then lets what's left die away with time constant `tau` ms. Lows (<350 Hz)
// and low-mids (<2 kHz) die faster: that's where a desk mic's box boom and room body linger, and the lingering is
// what made the recordings sound like a mic in a room (통울림) rather than a switch.
func tighten(_ x: [Double], tau: Double, hold: Double = 6) -> [Double] {
    guard let peak = x.indices.max(by: { abs(x[$0]) < abs(x[$1]) }) else { return x }
    let hold = peak + Int(sr * hold / 1000)
    let lowpass = { (hz: Double) -> [Double] in var a = Biquad(lowpass: hz), b = Biquad(lowpass: hz); return x.map { b.run(a.run($0)) } }
    let low = lowpass(350), belowHigh = lowpass(2000)
    let bands = [(low, lowTau), (zip(belowHigh, low).map { $0 - $1 }, midTau), (zip(x, belowHigh).map { $0 - $1 }, 1.0)]
    var out = [Double](repeating: 0, count: x.count)
    for (b, k) in bands {
        for i in b.indices { out[i] += i < hold ? b[i] : b[i] * exp(-Double(i - hold) / sr * 1000 / (tau * k)) }
    }
    return out
}
let lowTau = 0.4, midTau = 0.7

// Desk-mic clean-up: the clip starts 0.5 ms before the hit instead of 3 ms (that lead-in was only hiss and room tone,
// and cost latency), and whatever is 30 dB under the peak, or less than 18 dB over the recording's own `noise` (RMS),
// is pushed further down (2:1 downward expansion), so the hiss and room around each hit don't come along with it.
// Quiet recordings (hiss ~22 dB under the hits) need the second: a fixed −30 dB left their hiss untouched.
func dry(_ x: [Double], noise: Double = 0) -> [Double] {
    guard let top = x.map(abs).max(), top > 0 else { return x }
    let onset = x.firstIndex { abs($0) > top * 0.1 }!, start = max(0, onset - Int(sr * 0.0005))
    let floor = max(top * pow(10, -30.0 / 20), noise * 8), release = exp(-1 / (sr * 0.005))
    var env = 0.0
    return x[start...].enumerated().map { i, v in
        env = max(abs(v), env * release)
        return v * min(1, Double(i) / (sr * 0.0005)) * min(1, env / floor)
    }
}

// A clip's hiss: the RMS of its quietest 2 ms (slice keeps a little silence on both sides of each hit).
func noiseFloor(_ x: [Double]) -> Double {
    let w = Int(sr * 0.002)
    guard x.count > w else { return 0 }
    return stride(from: 0, to: x.count - w, by: w / 2).map { j in (x[j..<j + w].map { $0 * $0 }.reduce(0, +) / Double(w)).squareRoot() }.min()!
}

// Reads a clip `rate`× as fast (pitch and length move together, like a varispeed; also converts sample rates).
func resample(_ x: [Double], cents: Double) -> [Double] { resample(x, rate: pow(2, cents / 1200)) }
func resample(_ x: [Double], rate: Double) -> [Double] {
    (0..<Int(Double(x.count - 1) / rate)).map { i in
        let p = Double(i) * rate, k = Int(p), f = p - Double(k)
        return x[k] * (1 - f) + x[k + 1] * f
    }
}

// Rough left-to-right position (-1…1) of each key on an ANSI layout, by macOS key code; unlisted keys play centered.
let keyPan: [UInt16: Float] = {
    let rows: [[UInt16]] = [[50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24, 51],
                            [48, 12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42],
                            [57, 0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39, 36],
                            [56, 6, 7, 8, 9, 11, 45, 46, 43, 47, 44, 60]]
    var pan: [UInt16: Float] = [123: 0.8, 125: 0.85, 126: 0.85, 124: 0.9]  // arrows
    for row in rows { for (i, k) in row.enumerated() { pan[k] = Float(i) / Float(row.count - 1) * 2 - 1 } }
    return pan
}()
// Clicks follow the cursor across the screen it's on.
func cursorPan() -> Float {
    let loc = NSEvent.mouseLocation
    guard let f = NSScreen.screens.first(where: { $0.frame.contains(loc) })?.frame else { return 0 }
    return Float((loc.x - f.minX) / f.width * 2 - 1)
}
let panWidth: Float = 0.6  // a gentle spread

// Recordings: synthesis can match a keystroke's spectrum but still sounds fake, so every keyboard and mouse sound is
// a real recording. Sources (all CC0 on Freesound, HQ mp3 previews, cut with tools/slice or tools/clicks; see each
// SOURCE.txt): rainy75 #815614 (Rainy 75, a CNC aluminum board known for its 보글보글 sound); boxjade #643558 (Kailh Box
// Jade); mouse-logitech #583087 (a Logitech mouse), mouse-razer #555394 (Razer DeathAdder Essential), trackpad #118206
// (MacBook Pro).
// mykeyboard is the author's own board (fully lubed Durock T1 Silent Shrimp, aluminum case) via the laptop mic, used as
// a reference.
// Desk mics also pick up the desk: a 80–160 Hz thump that outlasts the keystroke, which the loudness match (it
// ignores < 300 Hz) then turns up into a boomy "통울림", so every recording is high-passed. Narrow peaks still
// ringing 8–30 ms after a hit (a spring or case ping, heard as "기계음") are notched out at their measured pitch.
let rainyEQ = [Biquad(highpass: 100)]
// The author's own board: fully lubed Durock T1 Silent Shrimp (silent tactile, PC top, nylon bottom) in an aluminum
// case, known for a hollow "텅 빈" sound. The Rainy 75 (the same kind of case, lubed) made into this switch: the
// dampers take the clack off the impact (the stiff PC top keeps it crisp, so no blanket treble cut), the body is
// matched fully to that recording, whose weight is a hollow 500 Hz–1.3 kHz rather than the Rainy's deep
// 150 Hz thock (its desk boom below 250 Hz filtered out of the reference first), releases are near silent, and three of
// the Rainy's keystrokes with a far bigger thock than the rest are dropped.
func shrimp() -> Sounds {
    recorded("rainy75", gain: 0.8, upGain: 0.4, eq: rainyEQ + [Biquad(highshelf: 3000, db: -4)],
             body: ("mykeyboard", [Biquad(highpass: 250), Biquad(highpass: 250)], 1), damper: 14, cents: -60, tight: 10,
             outliers: 6)
}
// Box Jade: its case adds a hollow 200–250 Hz ring and a 1.2 kHz honk over an empty 400–600 Hz ("plastic body"), so
// ring and honk are cut (its preset adds a little body back). Against a Cherry MX Blue recording (#442260) its
// 6–10 kHz snap was 10+ dB short, so only the 9.1 kHz ping is cut there.
let jadeEQ = [Biquad(peak: 220, q: 1.5, db: -6), Biquad(peak: 1250, q: 1.2, db: -5), Biquad(peak: 9130, q: 4, db: -4)]
let jadeBody = [Biquad(peak: 450, q: 0.8, db: 4)]
let foxEQ = [Biquad(peak: 8870, q: 6, db: -12), Biquad(peak: 4310, q: 6, db: -6), Biquad(peak: 5124, q: 6, db: -4),
             Biquad(peak: 5274, q: 6, db: -5), Biquad(peak: 4836, q: 6, db: -5), Biquad(peak: 1397, q: 5, db: -6),
             Biquad(peak: 1437, q: 6, db: -4), Biquad(peak: 1175, q: 5, db: -4)]
// Melodic (Gateron): the Box Jade recording (also a click bar) with much less 180–500 Hz, ~2 dB more around 2 kHz and
// 3–5 dB less from 4 to 8 kHz; it rings at ~1.1 and 9.4–10 kHz where the Jade rings at 4.1, 5 and 8.4 kHz (and 1.3 kHz
// on release), its releases sit ~6 dB under the presses and the click is down 30 dB ~18 ms on. Frequencies are as in
// the recording, which plays 100 cents lower.
let melodicEQ = [Biquad(peak: 132, q: 2, db: 2), Biquad(peak: 188, q: 2, db: -5), Biquad(peak: 265, q: 2, db: -8),
                 Biquad(peak: 375, q: 2, db: -3), Biquad(peak: 530, q: 2, db: -4), Biquad(peak: 749, q: 2, db: 2),
                 Biquad(peak: 1059, q: 2, db: -8), Biquad(peak: 2119, q: 2, db: 1), Biquad(peak: 4238, q: 2, db: -5),
                 Biquad(peak: 4309, q: 6, db: -6), Biquad(peak: 5274, q: 6, db: -5), Biquad(peak: 5429, q: 8, db: -4),
                 Biquad(peak: 4699, q: 8, db: -4), Biquad(peak: 5993, q: 2, db: -3), Biquad(peak: 8476, q: 2, db: -5),
                 Biquad(peak: 8870, q: 6, db: -6), Biquad(peak: 9129, q: 6, db: -4), Biquad(peak: 1397, q: 10, db: -6),
                 Biquad(peak: 1144, q: 20, db: 3), Biquad(peak: 10171, q: 30, db: 8)]
// A sound the panel offers: its name, a line on what it is and its icon.
struct Preset { var name: String, detail: String, icon: NSImage, sounds: () -> Sounds }
// An icon from icons/ (Phosphor, MIT), bundled in Resources or read from ./icons when run unbundled; a template, so it
// takes whatever color it's drawn in.
func phosphor(_ name: String) -> NSImage {
    let found = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "icons") ?? URL(fileURLWithPath: "icons/\(name).svg")
    let image = NSImage(contentsOf: found) ?? NSImage()
    image.isTemplate = true
    return image
}
// A mouse sound's icon: a white glyph on a colored tile.
func tile(_ color: NSColor, glyph: String) -> NSImage {
    let icon = phosphor(glyph)
    return NSImage(size: NSSize(width: 24, height: 24), flipped: false) { r in
        color.setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        let white = NSImage(size: NSSize(width: 15, height: 15), flipped: false) { g in
            icon.draw(in: g); NSColor.white.set(); g.fill(using: .sourceAtop); return true
        }
        white.draw(in: r.insetBy(dx: 4.5, dy: 4.5))
        return true
    }
}
// A keyboard sound's icon: its switch seen from above with the keycap off, in the real part's colors. Most stems are a
// plain cross; a Kailh Box stem is that cross inside a square wall, and Topre has a hollow round slider and no cross.
enum Stem { case cross, box, topre }
func switchIcon(housing: NSColor, stem: NSColor, _ kind: Stem, wall: NSColor? = nil) -> NSImage {
    NSImage(size: NSSize(width: 28, height: 28), flipped: false) { r in
        let edge = NSColor.black.withAlphaComponent(0.28)
        housing.setFill(); edge.setStroke()
        let body = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: 6, yRadius: 6)
        body.lineWidth = 1; body.fill(); body.stroke()
        NSColor.black.withAlphaComponent(0.1).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 4.5, dy: 4.5)).fill()
        let c = NSPoint(x: 14, y: 14)
        let cross = { (arm: CGFloat, half: CGFloat, fill: NSColor) in
            let p = NSBezierPath()
            p.append(NSBezierPath(roundedRect: NSRect(x: c.x - half, y: c.y - arm, width: half * 2, height: arm * 2), xRadius: 1, yRadius: 1))
            p.append(NSBezierPath(roundedRect: NSRect(x: c.x - arm, y: c.y - half, width: arm * 2, height: half * 2), xRadius: 1, yRadius: 1))
            p.windingRule = .nonZero
            fill.setFill(); edge.setStroke(); p.lineWidth = 0.75
            p.stroke(); p.fill()
        }
        switch kind {
        case .cross: cross(8, 2.4, stem)
        case .box:
            let w = NSBezierPath(roundedRect: NSRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16), xRadius: 2.5, yRadius: 2.5)
            (wall ?? stem).setFill(); edge.setStroke(); w.lineWidth = 0.75; w.fill(); w.stroke()
            NSColor.black.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: NSRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11), xRadius: 1.5, yRadius: 1.5).fill()
            cross(4.6, 1.5, stem)
        case .topre:
            stem.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)).fill()
            NSColor.white.withAlphaComponent(0.2).setStroke()
            let bore = NSBezierPath(ovalIn: NSRect(x: c.x - 4.8, y: c.y - 4.8, width: 9.6, height: 9.6))
            bore.lineWidth = 1; bore.stroke()
        }
        return true
    }
}
let rgb = { (r: CGFloat, g: CGFloat, b: CGFloat) in NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
// HHKB (Topre 45g): a recording of one with more of the 177–250 Hz thock and a little less around 500 Hz and 4 kHz, its
// one-off 5.1 kHz ping notched and the 6.5 kHz ring boards like it share lifted, releases ~2 dB over the presses.
let hhkbEQ = [Biquad(highpass: 100), Biquad(peak: 177, q: 2, db: 8), Biquad(peak: 250, q: 2, db: 4), Biquad(peak: 500, q: 2, db: -2),
              Biquad(peak: 1000, q: 2, db: 2), Biquad(peak: 2828, q: 2, db: 1.5), Biquad(peak: 4000, q: 2, db: -2),
              Biquad(peak: 5085, q: 8, db: -12), Biquad(peak: 6000, q: 3, db: 4), Biquad(peak: 6500, q: 16, db: 5)]
let keyPresets = [
    Preset(name: "보글", detail: "레이니75 · 알루미늄", icon: switchIcon(housing: rgb(196, 160, 185), stem: rgb(176, 130, 181), .cross)) { recorded("rainy75", eq: rainyEQ, tight: 10) },
    Preset(name: "내 키보드", detail: "듀록 저소음 쉬림프 67g", icon: switchIcon(housing: rgb(90, 168, 163), stem: rgb(239, 240, 240), .cross)) { shrimp() },
    Preset(name: "해피해킹", detail: "HHKB · Topre 45g", icon: switchIcon(housing: rgb(217, 213, 204), stem: rgb(32, 32, 32), .topre)) {
        recorded("hhkb", upGain: 1.1, eq: hhkbEQ, tight: 30)
    },
    // Kailh Arctic Fox (Chosfox): a Box click bar like the Box Jade, but with a PC bottom housing (the Jade's is nylon)
    // and a lighter 53 g spring, reviewed as louder and higher-pitched than the Jade, "crisp and hollow". So it's the
    // Box Jade recording a whole tone above the Jade preset, without the body that preset adds. Raised that far, the
    // recording's pings land at 4.6–5.6 and 9.4 kHz and its release rings at 1.5 kHz (a plastic honk), which jumped
    // out, so they're notched (at their pitch in the recording).
    Preset(name: "북극여우", detail: "Kailh Arctic Fox", icon: switchIcon(housing: rgb(120, 175, 206), stem: rgb(238, 234, 232), .box)) { recorded("boxjade", eq: jadeEQ + foxEQ, cents: 100, tight: 6) },
    Preset(name: "Box Jade", detail: "Kailh · 클릭바", icon: switchIcon(housing: rgb(230, 232, 228), stem: rgb(217, 231, 209), .box, wall: rgb(190, 212, 174))) { recorded("boxjade", eq: jadeEQ + jadeBody, cents: -100, tight: 6) },
    Preset(name: "멜로딕", detail: "Gateron Melodic", icon: switchIcon(housing: rgb(177, 200, 228), stem: rgb(245, 201, 196), .cross)) {
        recorded("boxjade", upGain: 0.5, eq: jadeEQ + jadeBody + melodicEQ, cents: -100, tight: 7)
    },
]
// Mouse: the clicks are microswitches whose release snaps back brighter and ~5 dB louder than the press (as recorded),
// so releases are brought down to about the press's level; desk thump below 100 Hz (200 Hz for the trackpad's diving
// board, whose clicks also vary more, so more of its odd ones are dropped) is filtered out. No usable free recording
// of a silent or a heavy mouse was found (the one silent take is buried in room noise), so 저소음 is the Logitech with
// its top shelved off, short and quieter (damping its click instead let a second tick through), and 묵직 the Logitech
// a minor third lower with more 400 Hz body.
let mouseHP = [Biquad(highpass: 100)]
let mousePresets = [
    Preset(name: "기본", detail: "딸깍 · Logitech", icon: tile(.systemBlue, glyph: "mouse")) { recorded("mouse-logitech", upGain: 0.55, eq: mouseHP, tight: 8, outliers: 6) },
    Preset(name: "저소음", detail: "톡", icon: tile(.systemIndigo, glyph: "moon")) {
        recorded("mouse-logitech", gain: 0.6, upGain: 0.5, eq: mouseHP + [Biquad(highshelf: 1500, db: -12)], tight: 4, outliers: 6)
    },
    Preset(name: "게이밍", detail: "짤깍 · Razer DeathAdder", icon: tile(.systemRed, glyph: "lightning")) { recorded("mouse-razer", upGain: 0.55, eq: mouseHP, tight: 8, outliers: 6) },
    Preset(name: "묵직", detail: "딸각", icon: tile(.systemBrown, glyph: "barbell")) {
        recorded("mouse-logitech", upGain: 0.55, eq: mouseHP + [Biquad(peak: 400, q: 1, db: 4)], cents: -300, tight: 10, outliers: 6)
    },
    Preset(name: "트랙패드", detail: "툭 · MacBook", icon: tile(.systemTeal, glyph: "hand-tap")) { recorded("trackpad", eq: [Biquad(highpass: 200)], tight: 8, outliers: 4) },
]

if let i = CommandLine.arguments.firstIndex(of: "--render") {
    // Writes every preset as WAVs so tools/compare can measure them against the recordings.
    let dir = CommandLine.arguments[i + 1]
    func write(_ set: [AVAudioPCMBuffer], _ folder: String, _ kind: String) {
        try! FileManager.default.createDirectory(atPath: "\(dir)/\(folder)", withIntermediateDirectories: true)
        for (k, b) in set.enumerated() {
            try! AVAudioFile(forWriting: URL(fileURLWithPath: "\(dir)/\(folder)/\(kind)_\(k).wav"), settings: format.settings).write(from: b)
        }
    }
    for (k, p) in keyPresets.enumerated() { let s = p.sounds(); write(s.down, "key\(k)", "down"); write(s.up, "key\(k)", "up") }
    for (k, p) in mousePresets.enumerated() { let s = p.sounds(); write(s.down, "mouse\(k)", "down"); write(s.up, "mouse\(k)", "up") }
    exit(0)
}
if CommandLine.arguments.contains("--check") {
    let all = (keyPresets + mousePresets).map { $0.sounds() }
    for s in all {
        precondition(!s.down.isEmpty && !s.up.isEmpty, "empty sound set")
        for b in s.down + s.up + s.space + s.enter {
            let x = UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))
            precondition(x.allSatisfy { $0.isFinite && abs($0) <= 1 }, "bad samples")
        }
    }
    print("ok: \(keyPresets.count) key + \(mousePresets.count) mouse presets"); exit(0)
}

let defaults = UserDefaults.standard
var keyChoice = keyPresets.indices.contains(defaults.integer(forKey: "keySound")) ? defaults.integer(forKey: "keySound") : 0
var mouseChoice = min(defaults.object(forKey: "mouseSound") as? Int ?? 0, mousePresets.count - 1)  // -1 = off
var keys = keyPresets[keyChoice].sounds()
var mouse = mousePresets[max(0, mouseChoice)].sounds()
var level = defaults.object(forKey: "volume") as? Float ?? 0.7  // the volume slider, 0…1
// What the slider does: ears hear level in dB, so a straight line barely changes through its upper half (halfway was
// only −6 dB). This makes halfway about −17 dB. The top stays 2 dB under full scale, where overlapping keystrokes clipped.
func outputGain(_ slider: Float) -> Float { 0.8 * pow(slider, 2.5) }

// The engine and its players are built afresh whenever the output device changes: after wired earphones were
// plugged in, the restarted old engine reported running but drew no audio at all, while a new one plays.
var engine = AVAudioEngine(), players: [AVAudioPlayerNode] = [], engineObserver: NSObjectProtocol?
// Diagnostics, logged once a second while sounds are requested: how many played or were skipped (and why), and
// the loudest sample actually leaving the mixer — so "no sound" can be told apart from "sound sent but not heard".
var played = 0, skipped = (off: 0, stopped: 0, empty: 0), mixerPeak: Float = 0, silentSeconds = 0
func startAudio() {
    engine.stop()
    engineObserver.map(NotificationCenter.default.removeObserver)
    engine = AVAudioEngine()
    players = (0..<16).map { _ in AVAudioPlayerNode() }
    players.forEach { engine.attach($0); engine.connect($0, to: engine.mainMixerNode, format: format) }
    engine.mainMixerNode.outputVolume = outputGain(level)
    engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
    // Smaller hardware buffer = less delay from key press to sound (default 512 frames ≈ 11ms → 128 ≈ 3ms).
    var frames: UInt32 = 128
    AudioUnitSetProperty(engine.outputNode.audioUnit!, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, 4)
    engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in
        for ch in 0..<Int(buf.format.channelCount) {
            let d = buf.floatChannelData![ch]
            for i in 0..<Int(buf.frameLength) { mixerPeak = max(mixerPeak, abs(d[i])) }
        }
    }
    if (try? engine.start()) != nil { players.forEach { $0.play() } }
    // Output device changes (earbuds plugged in or reconnecting, Bluetooth switching profiles) stop the engine.
    engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                            queue: .main) { _ in startAudio() }
    log.notice("audio running: \(engine.isRunning, privacy: .public), output \(engine.outputNode.outputFormat(forBus: 0).description, privacy: .public)")
}
startAudio()
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    guard played + skipped.off + skipped.stopped + skipped.empty > 0 else { return }
    log.notice("""
        played \(played, privacy: .public), skipped off/stopped/empty \(skipped.off, privacy: .public)/\
        \(skipped.stopped, privacy: .public)/\(skipped.empty, privacy: .public), mixer peak \
        \(20 * log10(max(mixerPeak, 1e-9)), format: .fixed(precision: 1), privacy: .public) dB
        """)
    // Self-heal: sounds were wanted for two seconds running but nothing left the mixer (at a volume above 0), or the
    // engine was stopped, so it is stuck however it got there; build a new one.
    silentSeconds = (played > 0 || skipped.stopped > 0) && mixerPeak == 0 && level > 0 ? silentSeconds + 1 : 0
    if silentSeconds >= 2 { log.notice("no audio leaving the mixer; rebuilding the engine"); silentSeconds = 0; startAudio() }
    played = 0; skipped = (0, 0, 0); mixerPeak = 0
}

var next = 0, enabled = defaults.object(forKey: "enabled") as? Bool ?? true
func play(_ set: [AVAudioPCMBuffer], pan: Float = 0) {
    guard enabled else { skipped.off += 1; return }
    guard engine.isRunning else { skipped.stopped += 1; return }
    guard let buffer = set.randomElement() else { skipped.empty += 1; return }
    played += 1
    let p = players[next]; next = (next + 1) % players.count
    p.volume = .random(in: 0.8...1)
    p.pan = pan * panWidth
    p.scheduleBuffer(buffer, at: nil, options: .interrupts)
}

// Short riffs when picking a sound and (shorter) when hovering one; the typing one sweeps left to right.
func typeDemo(_ keys: Sounds = keys, count: Int = 6) {
    for i in 0..<count {
        let t = DispatchTime.now() + .milliseconds(i * 160), pan = i % 5 == 4 || count == 1 ? 0 : Float(i) / Float(count - 1) * 2 - 1
        DispatchQueue.main.asyncAfter(deadline: t) { play(i % 5 == 4 ? keys.space : i == count - 1 && count > 3 ? keys.enter : keys.down, pan: pan) }
        DispatchQueue.main.asyncAfter(deadline: t + .milliseconds(90)) { play(keys.up, pan: pan) }
    }
}
func clickDemo(_ mouse: Sounds = mouse, count: Int = 3) {
    for i in 0..<count {
        let t = DispatchTime.now() + .milliseconds(i * 350)
        DispatchQueue.main.asyncAfter(deadline: t) { play(mouse.down) }
        DispatchQueue.main.asyncAfter(deadline: t + .milliseconds(80)) { play(mouse.up) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
// The menu bar icon: a filled keycap with the name's first syllable cut out, as a template image so it takes the menu
// bar's color.
let menuBarIcon: NSImage = {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4.5, yRadius: 4.5).fill()
        let label = NSAttributedString(string: "탁", attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .heavy)])
        let size = label.size()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        label.draw(at: NSPoint(x: (18 - size.width) / 2, y: (18 - size.height) / 2 + 0.5))
        return true
    }
    image.isTemplate = true
    return image
}()
// Warning icon until Accessibility permission is granted.
status.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Tadak: 권한 필요")
status.button?.appearsDisabled = !enabled
// The panel's mark: the app icon's keycap, drawn at this size so its 탁 stays legible.
let headerMark = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { r in
    NSGradient(starting: rgb(45, 212, 191), ending: rgb(15, 118, 110))!.draw(in: NSBezierPath(roundedRect: r, xRadius: 5.5, yRadius: 5.5), angle: -90)
    let label = NSAttributedString(string: "탁", attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .heavy), .foregroundColor: NSColor.white])
    let size = label.size()
    label.draw(at: NSPoint(x: (22 - size.width) / 2, y: (22 - size.height) / 2 + 0.5))
    return true
}

// What the panel shows; changing a value applies it and remembers it.
final class Panel: NSObject, ObservableObject {
    @Published var on = enabled {
        didSet { enabled = on; status.button?.appearsDisabled = !on; defaults.set(on, forKey: "enabled") }
    }
    // A keystroke at the new level while dragging, at most every 150 ms.
    @Published var volume = level {
        didSet {
            level = volume; engine.mainMixerNode.outputVolume = outputGain(level); defaults.set(level, forKey: "volume")
            guard Date().timeIntervalSince(lastTick) > 0.15 else { return }
            lastTick = Date(); typeDemo(count: 1)
        }
    }
    @Published var key = keyChoice
    @Published var click = mouseChoice
    @Published var trusted = false
    var preview: DispatchWorkItem?, lastTick = Date.distantPast

    func pickKey(_ i: Int) {
        preview?.cancel(); key = i; keyChoice = i
        defaults.set(i, forKey: "keySound")
        keys = keyPresets[i].sounds(); typeDemo()
    }
    func pickMouse(_ i: Int) {
        preview?.cancel(); click = i; mouseChoice = i
        defaults.set(i, forKey: "mouseSound")
        if i >= 0 { mouse = mousePresets[i].sounds(); clickDemo() }
    }
    // Resting on a sound plays a taste of it (loading one takes ~30 ms) without picking it.
    func hover(_ taste: (() -> Void)?) {
        preview?.cancel()
        guard let taste else { return }
        let work = DispatchWorkItem(block: taste)
        preview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    // The trust result is cached per process, so a fresh grant only takes effect after relaunch.
    func restart() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    @objc func toggle() {
        guard !popover.isShown, let button = status.button else { popover.performClose(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        popover.appearance = NSApp.effectiveAppearance  // else it takes the menu bar's, which follows the wallpaper
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
let panel = Panel()

// A rounded backdrop for a sound: tinted when it's the one picked, faint under the pointer.
struct Backdrop: ViewModifier {
    let picked: Bool, hovering: Bool
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(picked ? Color.teal.opacity(0.18) : hovering ? Color.primary.opacity(0.07) : Color.clear))
    }
}
struct KeyRow: View {
    let preset: Preset, picked: Bool, pick: () -> Void, taste: (() -> Void)?
    @State private var hovering = false
    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                Image(nsImage: preset.icon)
                VStack(alignment: .leading, spacing: 0) {
                    Text(preset.name).font(.system(size: 13, weight: .medium))
                    Text(preset.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if picked { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.teal) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
            .modifier(Backdrop(picked: picked, hovering: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; panel.hover($0 ? taste : nil) }
    }
}
struct MouseChip: View {
    let name: String, icon: NSImage, detail: String, picked: Bool, pick: () -> Void, taste: (() -> Void)?
    @State private var hovering = false
    var body: some View {
        Button(action: pick) {
            VStack(spacing: 4) {
                Image(nsImage: icon)
                Text(name).font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .contentShape(Rectangle())
            .modifier(Backdrop(picked: picked, hovering: hovering))
        }
        .buttonStyle(.plain)
        .help(detail)
        .onHover { hovering = $0; panel.hover($0 ? taste : nil) }
    }
}
struct PanelView: View {
    @ObservedObject var m: Panel
    func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 8)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(nsImage: headerMark)
                Text("Tadak").font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("", isOn: $m.on).toggleStyle(.switch).controlSize(.small).tint(.teal).labelsHidden()
            }
            .padding(.horizontal, 8)
            if !m.trusted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("키 입력을 들으려면 손쉬운 사용 권한이 필요해요", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                    HStack {
                        Button("권한 설정 열기", action: m.openSettings)
                        Button("켠 뒤 다시 시작", action: m.restart)
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 8)
            }
            HStack(spacing: 8) {
                Image(nsImage: phosphor("speaker-low")).renderingMode(.template).resizable().frame(width: 15, height: 15).foregroundStyle(.secondary)
                Slider(value: $m.volume, in: 0...1).controlSize(.small).tint(.teal)
                Image(nsImage: phosphor("speaker-high")).renderingMode(.template).resizable().frame(width: 15, height: 15).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                heading("키보드")
                ForEach(keyPresets.indices, id: \.self) { i in
                    KeyRow(preset: keyPresets[i], picked: m.key == i, pick: { m.pickKey(i) },
                           taste: { typeDemo(keyPresets[i].sounds(), count: 3) })
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                heading("마우스")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                    MouseChip(name: "끄기", icon: tile(.systemGray, glyph: "speaker-x"), detail: "마우스 소리 없음",
                              picked: m.click < 0, pick: { m.pickMouse(-1) }, taste: nil)
                    ForEach(mousePresets.indices, id: \.self) { i in
                        MouseChip(name: mousePresets[i].name, icon: mousePresets[i].icon, detail: mousePresets[i].detail,
                                  picked: m.click == i, pick: { m.pickMouse(i) },
                                  taste: { clickDemo(mousePresets[i].sounds(), count: 1) })
                    }
                }
            }
            }
            .opacity(m.on ? 1 : 0.45)
            Divider()
            HStack {
                Text("소리에 마우스를 올리면 미리 들려요").foregroundStyle(.tertiary)
                Spacer()
                Button("종료") { NSApp.terminate(nil) }.keyboardShortcut("q").buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
        }
        .padding(10)
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
    }
}
let popover = NSPopover()
popover.behavior = .transient
let panelHost = NSHostingController(rootView: PanelView(m: panel))
panelHost.sizingOptions = .preferredContentSize  // the popover takes the view's size, also when the permission note goes
popover.contentViewController = panelHost
status.button?.target = panel
status.button?.action = #selector(Panel.toggle)

// Global key/mouse monitoring needs Accessibility permission; poll until granted, then start listening.
AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
    guard AXIsProcessTrusted() else { return }
    timer.invalidate()
    panel.trusted = true
    status.button?.image = menuBarIcon
    log.notice("listening for keys and clicks")
    var heard = false
    NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]) { e in
        if !heard { heard = true; log.notice("first input event") }
        switch e.type {
        case .leftMouseDown, .rightMouseDown: if mouseChoice >= 0 { play(mouse.down, pan: cursorPan()) }
        case .leftMouseUp, .rightMouseUp: if mouseChoice >= 0 { play(mouse.up, pan: cursorPan()) }
        case .keyUp: play(keys.up, pan: keyPan[e.keyCode] ?? 0)
        default:
            if e.isARepeat { return }
            switch e.keyCode {
            case 49: play(keys.space)
            case 36, 76: play(keys.enter, pan: keyPan[36]!)
            default: play(keys.down, pan: keyPan[e.keyCode] ?? 0)
            }
        }
    }
}
app.run()

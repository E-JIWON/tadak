// Records the built-in mic to a WAV file: record <out.wav> <seconds>
// Picks the built-in mic explicitly; the default input may be a Bluetooth headset in low-quality call mode.
// Recording time (and the `<out>.ready` signal for cue scripts) starts once the file is actually being written.
import AVFoundation

let path = CommandLine.arguments[1], seconds = Double(CommandLine.arguments[2])!
let mic = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
    .first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }!

final class Recorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL, from connections: [AVCaptureConnection]) {
        FileManager.default.createFile(atPath: path + ".ready", contents: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { output.stopRecording() }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        print("recorded \(mic.localizedName): \(error.map { "\($0)" } ?? "ok")")
        exit(error == nil ? 0 : 1)
    }
}
let recorder = Recorder()
let session = AVCaptureSession()
session.addInput(try! AVCaptureDeviceInput(device: mic))
let output = AVCaptureAudioFileOutput()
output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false]
session.addOutput(output)
session.startRunning()
output.startRecording(to: URL(fileURLWithPath: path), outputFileType: .wav, recordingDelegate: recorder)
dispatchMain()

// The same cues as the web Radio (public/cal/radio.js beep()): two rising beeps = mic ON (660 then 990 Hz),
// two falling beeps = muted (880 then 440 Hz), one short 520 Hz blip = someone joined. Each beep 0.13 s with a
// 15 ms attack, 0.17 s apart. Played into the call audio, so they come out of the headset.
import Foundation
import AVFoundation

final class Tones {
    static let shared = Tones()
    private var players: [AVAudioPlayer] = []
    private var cache: [String: Data] = [:]

    func on() { play([660, 990]) }
    func off() { play([880, 440]) }
    func blip() { play([520]) }

    private func play(_ freqs: [Double]) {
        let key = freqs.map { String(Int($0)) }.joined(separator: "-")
        let data = cache[key] ?? Self.wav(freqs)
        cache[key] = data
        guard let p = try? AVAudioPlayer(data: data) else { return }
        p.volume = 0.6
        p.prepareToPlay()
        p.play()
        players.append(p)
        players.removeAll { !$0.isPlaying && $0 !== p }
    }

    /// 16-bit mono PCM WAV of the beep sequence.
    static func wav(_ freqs: [Double]) -> Data {
        let rate = 16000.0, step = 0.17, len = 0.15
        let total = Int(rate * (0.02 + step * Double(freqs.count)))
        var samples = [Int16](repeating: 0, count: total)
        for (i, f) in freqs.enumerated() {
            let start = Int(rate * (0.02 + step * Double(i)))
            for n in 0..<Int(rate * len) where start + n < total {
                let t = Double(n) / rate
                // exponential-ish envelope like the web: up over 15 ms to 0.35, down to silence by 130 ms
                let env = t < 0.015 ? 0.35 * (t / 0.015) : (t < 0.13 ? 0.35 * pow(0.0001 / 0.35, (t - 0.015) / 0.115) : 0)
                samples[start + n] = Int16(max(-1, min(1, env * sin(2 * .pi * f * t))) * 32767)
            }
        }
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}

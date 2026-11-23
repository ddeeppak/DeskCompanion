import AVFoundation
import Combine

/// Focus sounds (generated in code, no audio files) and the chime.
/// Rain / Noise / Café are synthesised: pink noise, filtered noise with droplets, low murmur with soft clinks.
final class SoundEngine: ObservableObject {
    static let shared = SoundEngine()

    enum Ambient: String, CaseIterable, Identifiable {
        case off, rain, noise, cafe

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return "Off"
            case .rain: return "Rain"
            case .noise: return "Noise"
            case .cafe: return "Café"
            }
        }
    }

    @Published private(set) var chimePlaying = false

    private let engine = AVAudioEngine()
    private let generator = NoiseGenerator()
    private let chimePlayer = AVAudioPlayerNode()
    private var chimeBuffer: AVAudioPCMBuffer?
    private var configured = false
    private var chimeStop: DispatchWorkItem?
    private var idleStop: DispatchWorkItem?

    private init() {}

    // MARK: Public

    func setAmbient(_ kind: Ambient) {
        if kind == .off {
            generator.fadeOut()
            pauseWhenIdle()
            return
        }
        guard ensureRunning() else { return }
        generator.setKind(kind)
    }

    /// Repeats the chime until stopped (or for `maxSeconds`).
    func startChime(maxSeconds: Double = 30) {
        guard ensureRunning(), let buffer = chimeBuffer else { return }
        chimePlayer.stop()
        chimePlayer.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        chimePlayer.play()
        chimePlaying = true
        chimeStop?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopChime() }
        chimeStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds, execute: work)
    }

    func playChimeOnce() {
        guard ensureRunning(), let buffer = chimeBuffer else { return }
        chimePlayer.stop()
        chimePlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        chimePlayer.play()
        pauseWhenIdle(after: 3)
    }

    func stopChime() {
        chimeStop?.cancel()
        chimePlayer.stop()
        if chimePlaying { chimePlaying = false }
        pauseWhenIdle()
    }

    // MARK: Engine

    private func ensureRunning() -> Bool {
        configure()
        idleStop?.cancel()
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        return true
    }

    private func pauseWhenIdle(after seconds: Double = 1.5) {
        idleStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if !self.generator.isActive && !self.chimePlaying && self.engine.isRunning {
                self.engine.pause()
            }
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func configure() {
        guard !configured else { return }
        configured = true

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        var sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 44_100 }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        generator.sampleRate = Float(sampleRate)

        let gen = generator
        let source = AVAudioSourceNode { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for frame in 0..<Int(frameCount) {
                let sample = gen.next()
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    data.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.attach(chimePlayer)
        engine.connect(chimePlayer, to: engine.mainMixerNode, format: format)
        chimeBuffer = Self.makeChime(format: format)
    }

    /// Two-note "ding-dong" bell, 2.6 s long including a pause (so it can loop).
    private static func makeChime(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(sampleRate * 2.6)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        let notes: [(start: Double, freq: Double)] = [(0.0, 880.0), (0.32, 1174.7)]
        let partials: [(mult: Double, amp: Double)] = [(1, 0.55), (2, 0.18), (3, 0.08), (4.2, 0.04)]
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            var value = 0.0
            for note in notes where t >= note.start {
                let local = t - note.start
                guard local < 1.9 else { continue }
                let envelope = exp(-local * 2.6) * min(1, local * 300)
                for partial in partials {
                    value += sin(2 * Double.pi * note.freq * partial.mult * local) * partial.amp * envelope
                }
            }
            data[i] = Float(value * 0.35)
        }
        return buffer
    }
}

/// Real-time noise synthesiser (runs on the audio thread).
final class NoiseGenerator {
    var sampleRate: Float = 44_100
    private var kind = 0                   // 1 rain · 2 noise · 3 café
    private var target: Float = 0
    private var gain: Float = 0
    private var seed: UInt32 = 0x1234_5678
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0
    private var brown: Float = 0, lowpass: Float = 0
    private var drop: Float = 0
    private var lfo: Float = 0
    private var clinkPhase: Float = 0, clinkFreq: Float = 0, clinkAmp: Float = 0

    var isActive: Bool { target > 0 || gain > 0.001 }

    func setKind(_ ambient: SoundEngine.Ambient) {
        switch ambient {
        case .rain: kind = 1; target = 0.9
        case .noise: kind = 2; target = 0.7
        case .cafe: kind = 3; target = 0.9
        case .off: target = 0
        }
    }

    func fadeOut() { target = 0 }

    @inline(__always) private func white() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Float(seed) / Float(UInt32.max) * 2 - 1
    }

    func next() -> Float {
        gain += (target - gain) * 0.0004                     // smooth fade in/out
        if target == 0 && gain < 0.0005 { gain = 0; return 0 }
        let w = white()
        b0 = 0.99765 * b0 + w * 0.0990460                    // pink noise (Paul Kellet)
        b1 = 0.96300 * b1 + w * 0.2965164
        b2 = 0.57000 * b2 + w * 1.0526913
        let pink = (b0 + b1 + b2 + w * 0.1848) * 0.11
        brown = (brown + 0.02 * w) / 1.02

        var sample: Float = 0
        switch kind {
        case 1:                                              // rain: airy hiss + droplets
            lowpass += (pink - lowpass) * 0.08
            let hiss = pink - lowpass * 0.6
            if drop < 0.001 && white() > 0.9993 { drop = 0.25 + 0.35 * abs(white()) }
            drop *= 0.995
            sample = hiss * 0.5 + w * drop * 0.5
        case 2:                                              // soft pink noise
            sample = pink * 0.55
        case 3:                                              // café: low murmur + occasional clinks
            lfo += 0.35 / sampleRate
            if lfo > 1 { lfo -= 1 }
            let murmur = brown * 3.0 * (0.75 + 0.25 * sin(lfo * 2 * Float.pi))
            if clinkAmp < 0.001 && white() > 0.99999 {
                clinkAmp = 0.10
                clinkFreq = 2200 + 1800 * abs(white())
            }
            clinkPhase += clinkFreq / sampleRate
            if clinkPhase > 1 { clinkPhase -= 1 }
            clinkAmp *= 0.9993
            sample = murmur * 0.6 + sin(clinkPhase * 2 * Float.pi) * clinkAmp
        default:
            sample = 0
        }
        return max(-1, min(1, sample * gain))
    }
}

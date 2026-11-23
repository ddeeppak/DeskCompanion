import AVFoundation
import Combine

/// All app audio: focus sounds (generated rain/noise/café, or your own files), chime, and alarm tones.
/// Everything is generated in code except "My sounds" files.
final class SoundEngine: ObservableObject {
    static let shared = SoundEngine()

    /// Built-in focus sounds (synthesised, no audio files).
    enum Builtin: String, CaseIterable, Identifiable {
        case rain, noise, cafe

        var id: String { rawValue }

        var label: String {
            switch self {
            case .rain: return "Rain"
            case .noise: return "Noise"
            case .cafe: return "Café"
            }
        }
    }

    enum AlarmTone: String, CaseIterable, Identifiable {
        case chime, bells, beep, gentle

        var id: String { rawValue }

        var label: String {
            switch self {
            case .chime: return "Chime"
            case .bells: return "Bells"
            case .beep: return "Beep"
            case .gentle: return "Gentle"
            }
        }
    }

    @Published private(set) var chimePlaying = false
    @Published private(set) var alarmPlaying = false

    /// Focus sound volume (0...1), set from Settings.
    var focusVolume: Float = 0.8 {
        didSet {
            generator.volume = focusVolume
            filePlayer.volume = focusVolume
        }
    }

    private var engine = AVAudioEngine()
    private let generator = NoiseGenerator()
    private var bellPlayer = AVAudioPlayerNode()     // chime + alarms
    private var filePlayer = AVAudioPlayerNode()     // "My sounds"
    /// What should be playing, so it can be restarted after Siri, a call or an iOS audio reset.
    private var focusID = "off"
    private var alarmSettings: (tone: AlarmTone, volume: Float)? = nil
    private var monoFormat: AVAudioFormat?
    private var buffers: [AlarmTone: AVAudioPCMBuffer] = [:]
    private var configured = false
    private var chimeStop: DispatchWorkItem?
    private var idleStop: DispatchWorkItem?
    private var rampTimer: Timer?
    private var currentFile: AVAudioFile?
    private var currentFileName: String?

    private init() {
        let center = NotificationCenter.default
        // Siri, a phone call or another app took the audio: start again when it gives it back.
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.recover(rebuildFirst: false) }
        }
        // iOS restarted its audio system (rare, but it happens over days): build a fresh engine.
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.recover(rebuildFirst: true)
        }
        // The output changed (speaker, Bluetooth, sample rate): the engine stops itself.
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            guard let self = self, (note.object as AnyObject?) === self.engine else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.recover(rebuildFirst: false) }
        }
    }

    /// Starts again whatever should be playing (an alarm, a chime, the focus sound).
    private func recover(rebuildFirst: Bool) {
        if rebuildFirst { rebuild() }
        let alarm = alarmPlaying ? alarmSettings : nil
        let chime = chimePlaying
        let focus = focusID
        guard alarm != nil || chime || focus != "off" else { return }
        StabilityMonitor.shared.noteAudioRecovery()
        if let alarm = alarm {
            alarmPlaying = false
            startAlarm(tone: alarm.tone, volume: alarm.volume, rising: false)
        } else if chime {
            chimePlaying = false
            startChime()
        }
        if focus != "off" {
            currentFileName = nil            // make a sound file start again
            setFocusSound(focus)
        }
    }

    private func rebuild() {
        engine.stop()
        engine = AVAudioEngine()
        bellPlayer = AVAudioPlayerNode()
        filePlayer = AVAudioPlayerNode()
        filePlayer.volume = focusVolume
        buffers = [:]
        currentFile = nil
        currentFileName = nil
        configured = false
    }

    // MARK: Focus sounds

    /// id: "off", "rain", "noise", "cafe" or "file:<file name>"
    func setFocusSound(_ id: String) {
        focusID = id
        if id == "off" {
            generator.fadeOut()
            stopFile()
            pauseWhenIdle()
            return
        }
        guard ensureRunning() else { return }
        if let builtin = Builtin(rawValue: id) {
            stopFile()
            generator.setKind(builtin)
        } else if id.hasPrefix("file:") {
            generator.fadeOut()
            playFile(named: String(id.dropFirst(5)))
        }
    }

    private func playFile(named name: String) {
        if currentFileName == name && filePlayer.isPlaying { return }
        guard let url = SoundLibrary.url(forFile: name),
              let file = try? AVAudioFile(forReading: url) else { return }
        filePlayer.stop()
        engine.disconnectNodeOutput(filePlayer)
        engine.connect(filePlayer, to: engine.mainMixerNode, format: file.processingFormat)
        currentFile = file
        currentFileName = name
        // Two copies queued so the loop restarts without a gap.
        scheduleLoop(file)
        scheduleLoop(file)
        filePlayer.volume = focusVolume
        filePlayer.play()
    }

    private func scheduleLoop(_ file: AVAudioFile) {
        filePlayer.scheduleFile(file, at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.currentFile === file, self.filePlayer.isPlaying else { return }
                self.scheduleLoop(file)
            }
        }
    }

    private func stopFile() {
        guard currentFile != nil else { return }
        currentFile = nil
        currentFileName = nil
        filePlayer.stop()
    }

    // MARK: Chime (focus finished, reminders)

    /// Repeats the chime until stopped (or for `maxSeconds`).
    func startChime(maxSeconds: Double = 30) {
        guard !alarmPlaying, ensureRunning(), let buffer = buffer(for: .chime) else { return }
        bellPlayer.stop()
        bellPlayer.volume = 1
        bellPlayer.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        bellPlayer.play()
        chimePlaying = true
        chimeStop?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopChime() }
        chimeStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds, execute: work)
    }

    func playChimeOnce() {
        guard !alarmPlaying, ensureRunning(), let buffer = buffer(for: .chime) else { return }
        bellPlayer.stop()
        bellPlayer.volume = 1
        bellPlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        bellPlayer.play()
        pauseWhenIdle(after: 3)
    }

    func stopChime() {
        chimeStop?.cancel()
        guard chimePlaying else { return }
        bellPlayer.stop()
        chimePlaying = false
        pauseWhenIdle()
    }

    // MARK: Alarm

    /// Loops the alarm tone. With `rising`, starts quiet and gets louder over 30 seconds.
    func startAlarm(tone: AlarmTone, volume: Float, rising: Bool) {
        alarmSettings = (tone: tone, volume: volume)
        guard ensureRunning(), let buffer = buffer(for: tone) else { return }
        chimeStop?.cancel()
        chimePlaying = false
        bellPlayer.stop()
        bellPlayer.volume = rising ? min(volume, 0.12) : volume
        bellPlayer.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        bellPlayer.play()
        alarmPlaying = true
        rampTimer?.invalidate()
        if rising {
            let step = max(0.01, (volume - 0.12) / 60)            // 60 steps × 0.5 s = 30 s
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] t in
                guard let self = self, self.alarmPlaying else { t.invalidate(); return }
                self.bellPlayer.volume = min(volume, self.bellPlayer.volume + step)
                if self.bellPlayer.volume >= volume { t.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            rampTimer = timer
        }
    }

    func stopAlarm() {
        alarmSettings = nil
        rampTimer?.invalidate()
        guard alarmPlaying else { return }
        bellPlayer.stop()
        bellPlayer.volume = 1
        alarmPlaying = false
        pauseWhenIdle()
    }

    /// Settings "Test" button: one pass of the tone.
    func previewAlarm(tone: AlarmTone, volume: Float) {
        guard !alarmPlaying, ensureRunning(), let buffer = buffer(for: tone) else { return }
        bellPlayer.stop()
        bellPlayer.volume = volume
        bellPlayer.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        bellPlayer.play()
        pauseWhenIdle(after: 4)
    }

    // MARK: Engine

    private func ensureRunning() -> Bool {
        configure()
        idleStop?.cancel()
        if engine.isRunning { return true }
        AudioSessionSetup.ensure()               // after an interruption the session must be active again
        if (try? engine.start()) != nil { return true }
        // The engine is broken (audio reset): build a fresh one and try once more, so alarms still ring.
        rebuild()
        configure()
        AudioSessionSetup.ensure()
        return (try? engine.start()) != nil
    }

    private func pauseWhenIdle(after seconds: Double = 1.5) {
        idleStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let busy = self.generator.isActive || self.chimePlaying || self.alarmPlaying || self.filePlayer.isPlaying
            if !busy && self.engine.isRunning { self.engine.pause() }
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func configure() {
        guard !configured else { return }
        configured = true

        AudioSessionSetup.ensure()       // shared with the microphone (play + record)

        var sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 44_100 }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        monoFormat = format
        generator.sampleRate = Float(sampleRate)
        generator.volume = focusVolume

        let gen = generator
        let source = AVAudioSourceNode { _, _, frameCount, bufferList -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(bufferList)
            for frame in 0..<Int(frameCount) {
                let sample = gen.next()
                for buffer in list {
                    guard let data = buffer.mData else { continue }
                    data.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.attach(bellPlayer)
        engine.connect(bellPlayer, to: engine.mainMixerNode, format: format)
        engine.attach(filePlayer)
        engine.connect(filePlayer, to: engine.mainMixerNode, format: format)
    }

    private func buffer(for tone: AlarmTone) -> AVAudioPCMBuffer? {
        if let cached = buffers[tone] { return cached }
        guard let format = monoFormat else { return nil }
        let made = Self.makeTone(tone, format: format)
        buffers[tone] = made
        return made
    }

    // MARK: Tone synthesis

    private struct ToneSpec {
        let notes: [(start: Double, freq: Double)]
        let partials: [(mult: Double, amp: Double)]
        let decay: Double            // exponential decay rate (ignored when gated)
        let gate: Double?            // fixed note length for beeps
        let noteLength: Double
        let total: Double            // loop length incl. pause
        let gain: Double
    }

    private static func spec(_ tone: AlarmTone) -> ToneSpec {
        let bell: [(mult: Double, amp: Double)] = [(1, 0.55), (2, 0.18), (3, 0.08), (4.2, 0.04)]
        switch tone {
        case .chime:
            return ToneSpec(notes: [(0.0, 880.0), (0.32, 1174.7)], partials: bell,
                            decay: 2.6, gate: nil, noteLength: 1.9, total: 2.6, gain: 0.35)
        case .bells:
            return ToneSpec(notes: [(0.0, 1046.5), (0.25, 1318.5), (0.5, 1568.0), (0.75, 2093.0)], partials: bell,
                            decay: 2.4, gate: nil, noteLength: 2.0, total: 3.0, gain: 0.28)
        case .beep:
            return ToneSpec(notes: [(0.0, 1000.0), (0.2, 1000.0), (0.4, 1000.0), (0.6, 1000.0)],
                            partials: [(1, 0.6), (3, 0.15)],
                            decay: 0, gate: 0.1, noteLength: 0.1, total: 1.6, gain: 0.35)
        case .gentle:
            return ToneSpec(notes: [(0.0, 523.25), (0.6, 659.25), (1.2, 783.99)],
                            partials: [(1, 0.7), (4, 0.08), (10, 0.02)],
                            decay: 1.8, gate: nil, noteLength: 2.2, total: 3.4, gain: 0.4)
        }
    }

    private static func makeTone(_ tone: AlarmTone, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let s = spec(tone)
        let sampleRate = format.sampleRate
        let frames = AVAudioFrameCount(sampleRate * s.total)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            var value = 0.0
            for note in s.notes where t >= note.start {
                let local = t - note.start
                guard local < s.noteLength else { continue }
                var envelope = min(1, local * 300)                       // 3 ms attack
                if let gate = s.gate {
                    envelope *= min(1, max(0, (gate - local) * 200))     // 5 ms release
                } else {
                    envelope *= exp(-local * s.decay)
                }
                for partial in s.partials {
                    value += sin(2 * Double.pi * note.freq * partial.mult * local) * partial.amp * envelope
                }
            }
            data[i] = Float(value * s.gain)
        }
        return buffer
    }
}

/// Real-time noise synthesiser (runs on the audio thread).
final class NoiseGenerator {
    var sampleRate: Float = 44_100
    var volume: Float = 0.8
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

    func setKind(_ builtin: SoundEngine.Builtin) {
        switch builtin {
        case .rain: kind = 1; target = 0.9
        case .noise: kind = 2; target = 0.7
        case .cafe: kind = 3; target = 0.9
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
        return max(-1, min(1, sample * gain * volume))
    }
}

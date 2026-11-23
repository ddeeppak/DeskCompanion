import Speech
import Network
import AVFoundation
import Combine

/// One shared audio session for everything (sounds, voice replies, microphone).
enum AudioSessionSetup {
    static func ensure() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playAndRecord, mode: .default,
                                     options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP])
        }
        try? session.setActive(true)
    }
}

/// Speech to text with Apple's recogniser. Stops by itself ~1.4 s after you stop talking.
final class SpeechService: ObservableObject {
    enum Permission { case unknown, granted, denied }

    @Published private(set) var permission: Permission = .unknown
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var level: Float = 0          // 0...1 microphone level for the waveform
    @Published var localeID: String {
        didSet { UserDefaults.standard.set(localeID, forKey: "speech.locale") }
    }

    static let locales: [(id: String, name: String)] = [
        ("en-US", "English (US)"), ("en-IN", "English (India)"), ("en-GB", "English (UK)"), ("en-AU", "English (Australia)")
    ]

    private var audioEngine = AVAudioEngine()
    /// Privacy option: never send audio to Apple's servers (less accurate on an iPhone 7).
    @Published var onDeviceOnly: Bool {
        didSet { UserDefaults.standard.set(onDeviceOnly, forKey: "speech.onDeviceOnly") }
    }
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var lastChange = Date()
    private var startedAt = Date()
    private var onFinish: ((String) -> Void)?
    private var lastLevelPublish = Date.distantPast
    private var noSpeechTimeout: TimeInterval = 7
    /// Words to listen out for (task and event names, command words). Improves recognition a lot.
    var hints: [String] = []
    /// Apple's server recognizer is far more accurate than the iPhone 7's on-device one: use it when online.
    private static let network: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "speech.network"))
        return monitor
    }()

    init() {
        let saved = UserDefaults.standard.string(forKey: "speech.locale")
        localeID = saved ?? (Locale.current.identifier.hasPrefix("en_IN") ? "en-IN" : "en-US")
        onDeviceOnly = UserDefaults.standard.bool(forKey: "speech.onDeviceOnly")
        permission = Self.currentPermission()
        let center = NotificationCenter.default
        // A call or Siri takes the microphone: finish with what was heard so far.
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began,
                  let self = self, self.isListening else { return }
            self.stop()
        }
        // iOS reset its audio system: the old engine no longer works.
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.isListening { self.cancel() }
            self.audioEngine = AVAudioEngine()
        }
    }

    /// True when this iPhone can recognise speech without internet for the chosen language.
    var worksOffline: Bool {
        SFSpeechRecognizer(locale: Locale(identifier: localeID))?.supportsOnDeviceRecognition ?? false
    }

    private static func currentPermission() -> Permission {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let mic = AVAudioSession.sharedInstance().recordPermission
        if speech == .authorized && mic == .granted { return .granted }
        if speech == .denied || speech == .restricted || mic == .denied { return .denied }
        return .unknown
    }

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioSession.sharedInstance().requestRecordPermission { micGranted in
                DispatchQueue.main.async {
                    let ok = status == .authorized && micGranted
                    self.permission = ok ? .granted : .denied
                    done(ok)
                }
            }
        }
    }

    /// Starts listening. `onFinish` gets the final text ("" if nothing was heard); `onDenied` if permission is off.
    func start(onFinish: @escaping (String) -> Void, onDenied: @escaping () -> Void,
               noSpeechTimeout: TimeInterval = 7) {
        guard !isListening else { return }
        self.noSpeechTimeout = noSpeechTimeout
        requestPermission { [weak self] granted in
            guard let self = self else { return }
            if granted { self.begin(onFinish) } else { onDenied() }
        }
    }

    func stop() { finish(transcript) }

    func cancel() {
        onFinish = nil
        finish("")
    }

    private func begin(_ completion: @escaping (String) -> Void) {
        NotificationCenter.default.post(name: .microphoneNeeded, object: nil)   // noise meter lets go of the mic
        AudioSessionSetup.ensure()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            completion("")
            return
        }
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        let online = Self.network.currentPath.status == .satisfied
        newRequest.requiresOnDeviceRecognition = (onDeviceOnly || !online) && recognizer.supportsOnDeviceRecognition
        newRequest.contextualStrings = Array(hints.prefix(100))
        request = newRequest

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            self?.measure(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            completion("")
            return
        }

        transcript = ""
        isListening = true
        Haptics.suppressed = true
        startedAt = Date()
        lastChange = Date()
        onFinish = completion

        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.isListening else { return }
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    if text != self.transcript {
                        self.transcript = text
                        self.lastChange = Date()
                    }
                    if result.isFinal { self.finish(text) }
                } else if error != nil {
                    self.finish(self.transcript)
                }
            }
        }

        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkSilence() }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func checkSilence() {
        guard isListening else { return }
        let now = Date()
        if transcript.isEmpty {
            if now.timeIntervalSince(startedAt) > noSpeechTimeout { finish("") }   // nothing said
        } else if now.timeIntervalSince(lastChange) > 1.4 {
            finish(transcript)                                             // stopped talking
        }
        if now.timeIntervalSince(startedAt) > 20 { finish(transcript) }    // safety limit
    }

    private func finish(_ text: String) {
        guard isListening else { return }
        isListening = false
        Haptics.suppressed = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        level = 0
        let callback = onFinish
        onFinish = nil
        callback?(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Microphone level (runs on the audio thread, published ~15 times a second).
    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 0.000_01))
        let normalized = max(0, min(1, (db + 50) / 40))
        DispatchQueue.main.async {
            let now = Date()
            if now.timeIntervalSince(self.lastLevelPublish) > 0.066 {
                self.lastLevelPublish = now
                self.level = normalized
            }
        }
    }
}

/// Spoken replies with Apple's built-in voices (work offline).
final class VoiceService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speaking = false
    @Published var enabled: Bool { didSet { save() } }
    @Published var voiceID: String { didSet { save() } }       // "" = automatic
    @Published var rate: Float { didSet { save() } }

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "voice.enabled") as? Bool ?? true
        voiceID = d.string(forKey: "voice.id") ?? ""
        rate = d.object(forKey: "voice.rate") as? Float ?? AVSpeechUtteranceDefaultSpeechRate
        super.init()
        synthesizer.delegate = self
    }

    /// English voices, best quality first.
    var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                return lhs.name < rhs.name
            }
    }

    var voiceName: String {
        if let voice = AVSpeechSynthesisVoice(identifier: voiceID) { return voice.name }
        return "Automatic"
    }

    func speak(_ text: String, force: Bool = false) {
        guard enabled || force, !text.isEmpty else { return }
        AudioSessionSetup.ensure()
        streaming = false
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance(text))
    }

    func stop() {
        streaming = false
        streamBuffer = ""
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// True while anything is still being read out or more sentences are on their way.
    var isBusy: Bool { synthesizer.isSpeaking || streaming }

    // MARK: Streamed speech (AI answers): speak each finished sentence while the rest is still arriving

    private var streaming = false
    private var streamBuffer = ""

    func beginStream() {
        synthesizer.stopSpeaking(at: .immediate)
        streamBuffer = ""
        streaming = true
    }

    func appendStream(_ piece: String) {
        guard streaming else { return }
        streamBuffer += piece
        while let end = streamBuffer.range(of: "[.!?]\\s", options: .regularExpression) {
            let sentence = String(streamBuffer[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
            streamBuffer = String(streamBuffer[end.upperBound...])
            enqueue(sentence)
        }
    }

    func endStream() {
        guard streaming else { return }
        let rest = streamBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { enqueue(rest) }
        streamBuffer = ""
        streaming = false
    }

    private func enqueue(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        AudioSessionSetup.ensure()
        synthesizer.speak(utterance(text))           // queued after the previous sentence
    }

    private func utterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID)
            ?? voices.first { $0.language == "en-US" && $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = rate
        return utterance
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: "voice.enabled")
        d.set(voiceID, forKey: "voice.id")
        d.set(rate, forKey: "voice.rate")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = true }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // More sentences may be queued (streamed answers).
        DispatchQueue.main.async { self.speaking = self.synthesizer.isSpeaking || self.streaming }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = false }
    }
}

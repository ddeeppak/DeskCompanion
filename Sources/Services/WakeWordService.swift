import Foundation
import Speech
import AVFoundation
import Combine

/// "Hey Desk": listens for the wake word with on-device speech recognition only (room audio never leaves the
/// iPhone). Runs only while someone is at the desk and nothing else is using the microphone.
/// "Hey Desk, what's the weather?" works in one go; "Hey Desk" alone opens the assistant.
final class WakeWordService: ObservableObject {
    static let shared = WakeWordService()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "wake.enabled")
            if enabled { evaluate() } else { stop() }
        }
    }
    @Published var atNight: Bool { didSet { UserDefaults.standard.set(atNight, forKey: "wake.atNight") } }
    @Published private(set) var running = false
    @Published private(set) var unavailableReason: String? = nil

    /// The words after "Hey Desk" ("" if nothing more was said).
    var onWake: ((String) -> Void)?
    /// The app says when it's fine to listen (not busy, someone present, not at night…).
    var allowed: (() -> Bool)?
    var localeID = "en-US"
    weak var noise: NoiseMeter?

    private var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartWork: DispatchWorkItem?
    private var watch: Timer?
    private var wakeAt: Date? = nil
    private var afterWake = ""
    private var lastChange = Date()
    private var resumeAfter = Date.distantPast
    private let level = LevelMeter()

    private final class LevelMeter {
        let lock = NSLock()
        var sum: Double = 0
        var count = 0
        func add(_ s: Double, _ n: Int) { lock.lock(); sum += s; count += n; lock.unlock() }
        func take() -> Double? {
            lock.lock(); defer { sum = 0; count = 0; lock.unlock() }
            return count > 0 ? sum / Double(count) : nil
        }
    }

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "wake.enabled")
        atNight = d.bool(forKey: "wake.atNight")
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.stop()
            self?.engine = AVAudioEngine()
        }
    }

    // MARK: Start / stop

    /// Called often (every few seconds and when the app's state changes): starts or stops listening.
    func evaluate() {
        let ok = enabled && Date() >= resumeAfter && (allowed?() ?? false)
            && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
        if ok && !running {
            start()
        } else if !ok && running && wakeAt == nil {
            stop()
        }
    }

    /// The assistant needs the microphone right now (it must not be shared).
    func pauseForAssistant() {
        stop()
        resumeAfter = Date().addingTimeInterval(1.5)
    }

    private func start() {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVAudioSession.sharedInstance().recordPermission == .granted else {
            unavailableReason = "Needs microphone and speech recognition access (ask the assistant something once)."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)), recognizer.isAvailable else {
            unavailableReason = "Speech recognition isn't available right now."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            unavailableReason = "This iPhone can't recognise speech offline in this language, so Hey Desk stays off: room audio is never sent to Apple."
            return
        }
        unavailableReason = nil
        AudioSessionSetup.ensure()
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.requiresOnDeviceRecognition = true          // privacy: never leaves the iPhone
        newRequest.shouldReportPartialResults = true
        newRequest.contextualStrings = ["Hey Desk"]
        request = newRequest

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        let meter = level
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            guard let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var s: Double = 0
            for i in 0..<n { s += Double(data[i] * data[i]) }
            meter.add(s, n)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            request = nil
            return
        }
        running = true
        wakeAt = nil
        afterWake = ""
        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.running else { return }
                if let result = result {
                    self.heard(result.bestTranscription.formattedString)
                    if result.isFinal { self.restartSoon() }
                } else if error != nil {
                    self.restartSoon()
                }
            }
        }
        // Fresh recognition every 50 s (keeps it light), and the noise level for Home every minute.
        scheduleRestart(after: 50)
        watch?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    func stop() {
        restartWork?.cancel()
        watch?.invalidate()
        watch = nil
        guard running || request != nil else { return }
        running = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        wakeAt = nil
        afterWake = ""
        if let meanSquare = level.take() { noise?.report(meanSquare: meanSquare) }
    }

    private func scheduleRestart(after seconds: Double) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.running, self.wakeAt == nil else { return }
            self.stop()
            self.evaluate()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func restartSoon() {
        guard wakeAt == nil else { return }
        scheduleRestart(after: 0.5)
    }

    // MARK: Hearing

    private static let pattern = #"\b(?:hey|hi|hay|okay|ok)[ ,]+(?:desk|desks|disk|desc|deck)\b"#

    private func heard(_ text: String) {
        let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
        if wakeAt == nil {
            guard let range = text.range(of: Self.pattern, options: options) else {
                if text.count > 180 { restartSoon() }         // long room chatter: start a fresh transcript
                return
            }
            wakeAt = Date()
            lastChange = Date()
            afterWake = String(text[range.upperBound...])
            Haptics.tap()
            return
        }
        if let range = text.range(of: Self.pattern, options: options) {
            let rest = String(text[range.upperBound...])
            if rest != afterWake {
                afterWake = rest
                lastChange = Date()
            }
        }
    }

    /// After "Hey Desk": wait for a short pause, then hand over what was said.
    private func check() {
        guard let wakeAt = wakeAt else { return }
        let now = Date()
        let words = afterWake.split(separator: " ").count
        let pause = now.timeIntervalSince(lastChange)
        // Nothing after the wake word for 0.9 s → open the assistant; a sentence → wait for 1.3 s of quiet.
        if (words == 0 && pause > 0.9) || (words > 0 && pause > 1.3) || now.timeIntervalSince(wakeAt) > 8 {
            let said = afterWake.trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!").union(.whitespaces))
            stop()
            resumeAfter = Date().addingTimeInterval(2)
            onWake?(said)
        }
    }
}

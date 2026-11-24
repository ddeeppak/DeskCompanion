import Foundation
import Speech
import AVFoundation
import Combine

/// "Hey Desk": listens for the wake phrase with on-device speech recognition only (room audio never leaves the
/// iPhone). Runs only while someone is at the desk and nothing else is using the microphone.
/// "Hey Desk, what's the weather?" works in one go; "Hey Desk" alone opens the assistant.
final class WakeWordService: ObservableObject {
    static let shared = WakeWordService()

    static let presets = ["Hey Desk", "Hello Desk", "Hey Buddy", "Hey Companion", "Okay Computer"]

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "wake.enabled")
            if enabled { evaluate() } else { stop(); status = "Off" }
        }
    }
    @Published var atNight: Bool { didSet { UserDefaults.standard.set(atNight, forKey: "wake.atNight") } }
    /// The phrase to listen for (a preset or your own).
    @Published var phrase: String {
        didSet {
            UserDefaults.standard.set(phrase, forKey: "wake.phrase")
            if running { stop(); evaluate() }                  // new hints for the recognizer
        }
    }
    @Published private(set) var running = false
    @Published private(set) var unavailableReason: String? = nil
    /// Why it is (or isn't) listening right now, for Settings.
    @Published private(set) var status = "Off"
    /// What the listener hears right now: only while Settings → Voice is open (never stored).
    @Published private(set) var heardPreview = ""
    var showHeard = false {
        didSet { if !showHeard { heardPreview = "" } }
    }

    /// Settings → "Test": say the phrase and see whether the phone catches it (doesn't open the assistant).
    enum TestState: Equatable { case idle, listening, success, failed }
    @Published private(set) var testState: TestState = .idle
    @Published private(set) var testHeard = ""
    private var testTimeout: DispatchWorkItem?

    /// The words after the wake phrase ("" if nothing more was said).
    var onWake: ((String) -> Void)?
    /// The app says why it must not listen right now (nil = fine to listen).
    var blocker: (() -> String?)?
    /// Your speech language; if this iPhone can't recognise it offline, another English model is used.
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
    private var usedLocale = ""
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
        phrase = d.string(forKey: "wake.phrase") ?? "Hey Desk"
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.stop()
            self?.engine = AVAudioEngine()
        }
    }

    // MARK: Start / stop

    /// Called often (every few seconds and when the app's state changes): starts or stops listening.
    func startTest() {
        testTimeout?.cancel()
        stop()
        testHeard = ""
        heardPreview = ""
        showHeard = true
        resumeAfter = .distantPast
        testState = .listening
        start()
        guard running else {
            testState = .failed
            testHeard = ""
            status = unavailableReason ?? "The microphone couldn't start."
            showHeard = false
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.testState == .listening else { return }
            self.testHeard = self.heardPreview
            self.finishTest(.failed)
        }
        testTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func cancelTest() {
        guard testState == .listening else { return }
        finishTest(.idle)
    }

    private func finishTest(_ result: TestState) {
        testTimeout?.cancel()
        testState = result
        showHeard = false
        stop()
        resumeAfter = Date().addingTimeInterval(1)
        if result == .success { Haptics.success() } else if result == .failed { Haptics.error() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.evaluate() }
    }

    func evaluate() {
        if testState == .listening { return }              // a test is running: leave the microphone alone
        guard enabled else {
            if running { stop() }
            status = "Off"
            return
        }
        var reason: String? = nil
        if Date() < resumeAfter {
            reason = "a moment after the assistant"
        } else if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            reason = "the phone is hot"
        } else if let blocked = blocker?() {
            reason = blocked
        }
        if let reason = reason {
            if running && wakeAt == nil { stop() }
            status = "Paused: \(reason)"
            return
        }
        if !running { start() }
        if running {
            let language = usedLocale == localeID ? "" : " (using \(usedLocale) on the iPhone)"
            status = "Listening for “\(phrase)”\(language)"
        } else {
            status = unavailableReason ?? "Couldn't start the microphone"
        }
    }

    /// The assistant needs the microphone right now (it must not be shared).
    func pauseForAssistant() {
        stop()
        resumeAfter = Date().addingTimeInterval(1.5)
    }

    /// Your language if this iPhone can recognise it offline, otherwise another English model that can.
    private func offlineRecognizer() -> SFSpeechRecognizer? {
        var candidates = [localeID]
        for other in ["en-US", "en-GB", "en-AU", "en-CA", "en-IN"] where !candidates.contains(other) {
            candidates.append(other)
        }
        for id in candidates {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)),
               recognizer.supportsOnDeviceRecognition {
                usedLocale = id
                return recognizer
            }
        }
        return nil
    }

    private func start() {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVAudioSession.sharedInstance().recordPermission == .granted else {
            unavailableReason = "Needs microphone and speech recognition access: ask the assistant something once."
            return
        }
        guard let recognizer = offlineRecognizer() else {
            unavailableReason = "This iPhone has no offline English speech model, so the wake phrase stays off (room audio is never sent to Apple). Turning on Dictation in iPhone Settings → General → Keyboard can download it."
            return
        }
        guard recognizer.isAvailable else {
            unavailableReason = "Speech recognition isn't available right now."
            return
        }
        unavailableReason = nil
        AudioSessionSetup.ensure()
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.requiresOnDeviceRecognition = true          // privacy: never leaves the iPhone
        newRequest.shouldReportPartialResults = true
        newRequest.contextualStrings = [phrase, phrase.lowercased()] + Self.tokens(phrase)
        newRequest.taskHint = .search                          // short phrases
        request = newRequest

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            request = nil
            return
        }
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
        // A fresh transcript every 50 s keeps it light; the noise level for Home is reported on each restart.
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
        if testState == .listening {                         // keep listening for the rest of the test
            restartWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.testState == .listening else { return }
                let heardSoFar = self.heardPreview
                self.stop()
                self.start()
                self.heardPreview = heardSoFar
            }
            restartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            return
        }
        scheduleRestart(after: 0.3)
    }

    // MARK: Hearing

    private static func tokens(_ text: String) -> [String] {
        CommandStore.normalize(text).split(separator: " ").map(String.init)
    }

    private static let greetings: Set<String> = ["hey", "hi", "hay", "hello", "hallo", "ok", "okay", "hei", "high", "heya"]

    /// Does this heard word sound like the wake word? ("disk", "deck", "dusk", "dex" for "desk")
    private static func soundsLike(_ heard: String, _ target: String) -> Bool {
        if heard == target { return true }
        if greetings.contains(target) { return greetings.contains(heard) }
        if heard.hasPrefix(target) || target.hasPrefix(heard) && heard.count >= 3 { return true }   // "desks", "desktop"
        let similarity = CommandStore.similarity(heard, target)
        if similarity >= 0.7 { return true }
        // Same first letter, similar length and half the letters right: "dex", "disc" for "desk".
        return similarity >= 0.5 && heard.first == target.first && abs(heard.count - target.count) <= 1
    }

    /// The number of heard words up to and including the wake phrase, if it was said.
    private func wakeEnd(in words: [String]) -> Int? {
        let target = Self.tokens(phrase)
        guard !target.isEmpty else { return nil }
        let joined = target.joined()                       // "heydesk"
        for start in words.indices {
            // Said as separate words: "hey desk", "hey, disk"
            if start + target.count <= words.count {
                let window = Array(words[start..<(start + target.count)])
                if zip(window, target).allSatisfy({ Self.soundsLike($0, $1) }) { return start + target.count }
            }
            // Heard as one word: "heydesk", "hidesk"
            if CommandStore.similarity(words[start], joined) >= 0.75 { return start + 1 }
        }
        return nil
    }

    private func heard(_ text: String) {
        let words = Self.tokens(text)
        if showHeard {
            let recent = words.suffix(8).joined(separator: " ")
            if recent != heardPreview { heardPreview = recent }
        }
        if wakeAt == nil {
            guard let end = wakeEnd(in: words) else {
                if words.count > 40 { restartSoon() }        // long room chatter: start a fresh transcript
                return
            }
            if testState == .listening {                     // the test passed: don't open the assistant
                testHeard = words.suffix(8).joined(separator: " ")
                finishTest(.success)
                return
            }
            wakeAt = Date()
            lastChange = Date()
            afterWake = words.suffix(from: end).joined(separator: " ")
            Haptics.tap()
            return
        }
        if let end = wakeEnd(in: words) {
            let rest = words.suffix(from: end).joined(separator: " ")
            if rest != afterWake {
                afterWake = rest
                lastChange = Date()
            }
        }
    }

    /// After the wake phrase: wait for a short pause, then hand over what was said.
    private func check() {
        guard let wakeAt = wakeAt else { return }
        let now = Date()
        let words = afterWake.split(separator: " ").count
        let pause = now.timeIntervalSince(lastChange)
        // Nothing after the wake phrase for 0.9 s → open the assistant; a sentence → wait for 1.3 s of quiet.
        if (words == 0 && pause > 0.9) || (words > 0 && pause > 1.3) || now.timeIntervalSince(wakeAt) > 8 {
            let said = afterWake
            stop()
            resumeAfter = Date().addingTimeInterval(2)
            onWake?(said)
        }
    }
}

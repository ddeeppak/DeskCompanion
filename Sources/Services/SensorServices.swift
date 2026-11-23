import AVFoundation
import Vision
import ImageIO
import UIKit
import Combine

extension Notification.Name {
    /// Posted by SpeechService before it opens the microphone, so the noise meter lets go of it.
    static let microphoneNeeded = Notification.Name("microphoneNeeded")
}

private func deviceIsHot() -> Bool {
    let state = ProcessInfo.processInfo.thermalState
    return state == .serious || state == .critical
}

// MARK: - Presence (front camera): Away mode

/// Looks for a person about once a second with the front camera (Vision, on the iPhone only:
/// frames are never saved or sent). Nobody for `awayMinutes` → isAway. Someone appears → wakes.
final class PresenceService: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "presence.enabled")
            if enabled { start() } else { stop(); markPresent() }
        }
    }
    @Published var awayMinutes: Int {
        didSet { UserDefaults.standard.set(awayMinutes, forKey: "presence.awayMinutes") }
    }
    @Published private(set) var isAway = false
    @Published private(set) var lastSeen: Date? = nil
    @Published private(set) var cameraDenied = false
    @Published private(set) var running = false
    @Published private(set) var pausedForHeat = false

    /// Called when someone comes back while the screen was in Away mode.
    var onReturn: (() -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "presence.camera")
    private var configured = false
    private var lastAnalysis = Date.distantPast
    private var orientationIndex = 0
    private var lockedOrientation: CGImagePropertyOrientation?
    private var misses = 0
    private var timer: Timer?
    private var suspended = false

    override init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "presence.enabled") as? Bool ?? true
        awayMinutes = d.object(forKey: "presence.awayMinutes") as? Int ?? 2
        super.init()
    }

    func start() {
        guard enabled else { return }
        suspended = false
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraDenied = false
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.cameraDenied = !granted
                    if granted { self.begin() }
                }
            }
        default:
            cameraDenied = true
        }
    }

    /// App in background: release the camera.
    func suspend() {
        suspended = true
        stopCamera()
    }

    func stop() {
        stopCamera()
        timer?.invalidate()
        timer = nil
    }

    /// Any touch or detection: someone is here.
    func markPresent() {
        lastSeen = Date()
        if isAway {
            isAway = false
            onReturn?()
        }
    }

    private func begin() {
        if lastSeen == nil { lastSeen = Date() }
        startTimer()
        queue.async {
            if !self.configured { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            DispatchQueue.main.async { self.running = running }
        }
    }

    private func stopCamera() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.running = false }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .low
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        // Slow the camera down (5 fps) when the current format allows it, to save power.
        let supports5 = device.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 5 && $0.maxFrameRate >= 5 }
        if supports5, (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 5)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 5)
            device.unlockForConfiguration()
        }
        session.commitConfiguration()
        configured = true
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Every 5 s: go Away after the delay; pause the camera while the phone is hot.
    private func tick() {
        guard enabled, !suspended else { return }
        if deviceIsHot() {
            if !pausedForHeat { pausedForHeat = true; stopCamera() }
            return
        } else if pausedForHeat {
            pausedForHeat = false
            begin()
        }
        if let seen = lastSeen, !isAway, running, Date().timeIntervalSince(seen) > Double(awayMinutes * 60) {
            isAway = true
        }
    }

    // Camera frames arrive on `queue`; analyse about once a second.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= 1.0,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now
        // Landscape front camera: the image is one of these two ways up (depends on the Home button side).
        let candidates: [CGImagePropertyOrientation] = [.downMirrored, .upMirrored]
        let orientation = lockedOrientation ?? candidates[orientationIndex % 2]
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation, options: [:])
        try? handler.perform([faces, people])
        let found = !(faces.results?.isEmpty ?? true) || !(people.results?.isEmpty ?? true)
        if found {
            lockedOrientation = orientation
            misses = 0
            DispatchQueue.main.async { self.markPresent() }
        } else {
            misses += 1
            if lockedOrientation == nil || misses > 20 {     // re-check the other way up from time to time
                lockedOrientation = nil
                orientationIndex += 1
            }
        }
    }
}

// MARK: - Proximity sensor: wave to talk / brighten

/// A short cover-and-uncover of the sensor near the earpiece counts as a wave.
/// iOS turns the screen off while the sensor is covered; if it stays covered over 10 s
/// (something resting there), wave detection switches itself off for 2 minutes.
final class ProximityService: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "proximity.enabled")
            apply()
        }
    }
    /// "talk" or "brighten"
    @Published var action: String {
        didSet { UserDefaults.standard.set(action, forKey: "proximity.action") }
    }
    @Published private(set) var supported = true
    @Published private(set) var lastWave: Date? = nil
    @Published private(set) var blocked = false

    var onWave: (() -> Void)?

    private var coveredAt: Date?
    private var observer: NSObjectProtocol?
    private var blockTimer: Timer?

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "proximity.enabled") as? Bool ?? true
        action = d.string(forKey: "proximity.action") ?? "talk"
        observer = NotificationCenter.default.addObserver(forName: UIDevice.proximityStateDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.changed()
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    func apply() {
        let on = enabled && !blocked
        UIDevice.current.isProximityMonitoringEnabled = on
        if on { supported = UIDevice.current.isProximityMonitoringEnabled }
    }

    func suspend() { UIDevice.current.isProximityMonitoringEnabled = false }

    private func changed() {
        if UIDevice.current.proximityState {
            coveredAt = Date()
            let covered = coveredAt
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self = self, self.coveredAt == covered, UIDevice.current.proximityState else { return }
                self.blockForAWhile()
            }
        } else if let started = coveredAt {
            coveredAt = nil
            if Date().timeIntervalSince(started) < 2.0 {
                lastWave = Date()
                onWave?()
            }
        }
    }

    private func blockForAWhile() {
        blocked = true
        apply()
        blockTimer?.invalidate()
        blockTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            self?.blocked = false
            self?.apply()
        }
    }
}

// MARK: - Noise meter

/// Measures the room's sound level for about 1.5 s once a minute (nothing is recorded or saved).
/// Never runs while the assistant is listening.
final class NoiseMeter: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "noise.enabled")
            if enabled { start() } else { stop(); decibels = nil }
        }
    }
    @Published private(set) var decibels: Int? = nil

    weak var speech: SpeechService?

    private let engine = AVAudioEngine()
    private var timer: Timer?
    private var sampling = false
    private var observer: NSObjectProtocol?
    private let accumulator = Accumulator()

    private final class Accumulator {
        let lock = NSLock()
        var sum: Double = 0
        var count = 0
        func reset() { lock.lock(); sum = 0; count = 0; lock.unlock() }
        func add(_ s: Double, _ n: Int) { lock.lock(); sum += s; count += n; lock.unlock() }
        func meanSquare() -> Double { lock.lock(); defer { lock.unlock() }; return count > 0 ? sum / Double(count) : 0 }
    }

    init() {
        enabled = UserDefaults.standard.object(forKey: "noise.enabled") as? Bool ?? true
        observer = NotificationCenter.default.addObserver(forName: .microphoneNeeded, object: nil, queue: .main) { [weak self] _ in
            self?.abort()
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// "Quiet" / "Moderate" / "Loud" / "Very loud"
    var levelText: String {
        guard let db = decibels else { return "Noise" }
        switch db {
        case ..<45: return "Quiet"
        case ..<60: return "Moderate"
        case ..<75: return "Loud"
        default: return "Very loud"
        }
    }

    func start() {
        guard enabled, timer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.sample() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        abort()
    }

    private func sample() {
        guard enabled, !sampling, !deviceIsHot(),
              AVAudioSession.sharedInstance().recordPermission == .granted,
              !(speech?.isListening ?? false) else { return }
        AudioSessionSetup.ensure()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        accumulator.reset()
        let acc = accumulator
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var s: Double = 0
            for i in 0..<n { s += Double(data[i] * data[i]) }
            acc.add(s, n)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return
        }
        sampling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard sampling else { return }
        abort()
        let rms = sqrt(accumulator.meanSquare())
        guard rms > 0 else { return }
        // dBFS → approximate dB SPL for the iPhone microphone (rough calibration).
        let spl = 20 * log10(rms) + 95
        decibels = Int(max(20, min(110, spl)).rounded())
    }

    /// Releases the microphone immediately.
    private func abort() {
        guard sampling else { return }
        sampling = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

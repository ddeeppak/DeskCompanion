import Foundation
import Combine

/// Which focus sounds are offered, their volume, and your own imported sound files ("My sounds").
/// Files live in the app's Documents folder (also reachable from iTunes File Sharing on the PC).
final class SoundLibrary: ObservableObject {
    struct CustomSound: Identifiable, Equatable {
        let id: String        // file name, e.g. "forest.mp3"
        let name: String      // shown name, e.g. "forest"
    }

    @Published var hiddenBuiltIns: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenBuiltIns), forKey: Self.hiddenKey) }
    }
    @Published var focusVolume: Double {
        didSet {
            UserDefaults.standard.set(focusVolume, forKey: Self.volumeKey)
            SoundEngine.shared.focusVolume = Float(focusVolume)
        }
    }
    @Published private(set) var customSounds: [CustomSound] = []

    private static let hiddenKey = "sounds.hidden"
    private static let volumeKey = "sounds.focusVolume"
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "caf", "aif", "aiff"]

    init() {
        let d = UserDefaults.standard
        hiddenBuiltIns = Set(d.stringArray(forKey: Self.hiddenKey) ?? [])
        focusVolume = d.object(forKey: Self.volumeKey) as? Double ?? 0.8
        SoundEngine.shared.focusVolume = Float(focusVolume)
        rescan()
    }

    // MARK: Folders

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var soundsFolder: URL { documents.appendingPathComponent("Sounds", isDirectory: true) }

    static func url(forFile name: String) -> URL? {
        let fm = FileManager.default
        for folder in [soundsFolder, documents] {
            let url = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: Options for the Focus picker

    /// (id, label): Off, visible built-ins, then your files.
    var focusOptions: [(String, String)] {
        var options: [(String, String)] = [("off", "Off")]
        for builtin in SoundEngine.Builtin.allCases where !hiddenBuiltIns.contains(builtin.rawValue) {
            options.append((builtin.rawValue, builtin.label))
        }
        for sound in customSounds {
            options.append(("file:\(sound.id)", sound.name))
        }
        return options
    }

    func label(for id: String) -> String {
        focusOptions.first { $0.0 == id }?.1 ?? "Off"
    }

    // MARK: Files

    func rescan() {
        let fm = FileManager.default
        var found: [String: CustomSound] = [:]
        for folder in [Self.documents, Self.soundsFolder] {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where Self.audioExtensions.contains((name as NSString).pathExtension.lowercased()) {
                found[name] = CustomSound(id: name, name: (name as NSString).deletingPathExtension)
            }
        }
        customSounds = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Copies a file picked in the Files app into Documents/Sounds.
    func importFile(_ url: URL) {
        let fm = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try? fm.createDirectory(at: Self.soundsFolder, withIntermediateDirectories: true)
        var target = Self.soundsFolder.appendingPathComponent(url.lastPathComponent)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = Self.soundsFolder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        try? fm.copyItem(at: url, to: target)
        rescan()
    }

    func delete(_ sound: CustomSound) {
        if let url = Self.url(forFile: sound.id) { try? FileManager.default.removeItem(at: url) }
        rescan()
    }
}

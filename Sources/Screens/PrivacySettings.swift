import SwiftUI
import AVFoundation
import Speech
import CoreMotion
import CoreLocation
import UserNotifications

/// Settings → Privacy: permissions, what leaves the iPhone (and where to), and what is stored on it.
struct PrivacySettings: View {
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var planner: PlannerService
    @EnvironmentObject private var speech: SpeechService
    @EnvironmentObject private var ai: AIService
    @EnvironmentObject private var assistant: AssistantService
    @EnvironmentObject private var commands: CommandStore
    @Environment(\.theme) private var theme
    @State private var notifications = "…"
    @State private var confirmForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            permissionsSection
            sharingSection
                .padding(.top, 12)
            storedSection
                .padding(.top, 12)
        }
        .onAppear(perform: loadNotificationStatus)
        .alert("Forget everything the assistant remembers?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) {
                commands.clearMemory()
                ai.backupMemories([])
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes \(commands.memory.count) facts from the iPhone and the backup on your PC.")
        }
    }

    // MARK: Permissions

    private enum Status { case allowed, off, notAsked }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Permissions")
            VStack(spacing: 0) {
                row("location.fill", 0x0A84FF, "Location", "Weather and sunrise (approximate)", locationStatus)
                RowSeparator()
                row("calendar", 0xFF453A, "Calendar", "Up Next, Today, briefings", access(planner.calendarAccess))
                RowSeparator()
                row("checklist", 0xFF9F0A, "Reminders", "Tasks and voice reminders", access(planner.remindersAccess))
                RowSeparator()
                row("camera.fill", 0x8E8E93, "Camera", "Notices when you sit down (never recorded)", cameraStatus)
                RowSeparator()
                row("mic.fill", 0xFF375F, "Microphone", "Only while the assistant listens", micStatus)
                RowSeparator()
                row("waveform", 0x5E5CE6, "Speech recognition", "Turns your voice into text", speechStatus)
                RowSeparator()
                row("bell.fill", 0xFF453A, "Notifications", "Backup for alarms if the app is closed", nil, text: notifications)
                RowSeparator()
                row("barometer", 0x30D158, "Motion & Fitness", "Air pressure sensor", motionStatus)
                RowSeparator()
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    SettingsRow {
                        Text("Change in iPhone Settings").foregroundColor(theme.accent)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward.app").foregroundColor(theme.accent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .groupedBox()
        }
    }

    private func row(_ symbol: String, _ tint: UInt32, _ title: String, _ detail: String, _ status: Status?,
                     text: String? = nil) -> some View {
        SettingsRow {
            IconTile(symbol: symbol, color: Color(hex: tint))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.system(size: 13)).foregroundColor(theme.secondaryLabel).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(text ?? label(status))
                .font(.system(size: 15))
                .foregroundColor(color(status, text: text))
        }
        .padding(.vertical, 2)
    }

    private func label(_ status: Status?) -> String {
        switch status {
        case .allowed?: return "Allowed"
        case .off?: return "Off"
        case .notAsked?, nil: return "Not asked yet"
        }
    }

    private func color(_ status: Status?, text: String?) -> Color {
        if let text = text { return text == "Off" ? theme.red : (text == "Allowed" ? theme.green : theme.secondaryLabel) }
        switch status {
        case .allowed?: return theme.green
        case .off?: return theme.red
        default: return theme.secondaryLabel
        }
    }

    private func access(_ value: PlannerService.Access) -> Status {
        switch value {
        case .granted: return .allowed
        case .denied: return .off
        default: return .notAsked
        }
    }

    private var locationStatus: Status {
        switch location.authorization {
        case .authorizedWhenInUse, .authorizedAlways: return .allowed
        case .denied, .restricted: return .off
        default: return .notAsked
        }
    }

    private var cameraStatus: Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .denied, .restricted: return .off
        default: return .notAsked
        }
    }

    private var micStatus: Status {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .allowed
        case .denied: return .off
        default: return .notAsked
        }
    }

    private var speechStatus: Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .allowed
        case .denied, .restricted: return .off
        default: return .notAsked
        }
    }

    private var motionStatus: Status {
        switch CMAltimeter.authorizationStatus() {
        case .authorized: return .allowed
        case .denied, .restricted: return .off
        default: return .notAsked
        }
    }

    private func loadNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: text = "Allowed"
            case .denied: text = "Off"
            default: text = "Not asked yet"
            }
            DispatchQueue.main.async { notifications = text }
        }
    }

    // MARK: What leaves the iPhone

    private var sharingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("What leaves this iPhone")
            VStack(spacing: 0) {
                SettingsRow {
                    IconTile(symbol: "desktopcomputer", color: Color(hex: 0x0A84FF))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Share my day with the AI")
                        Text("Today's events and tasks go to your PC with each question")
                            .font(.system(size: 13)).foregroundColor(theme.secondaryLabel)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $ai.shareDay).labelsHidden().toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                }
                .padding(.vertical, 3)
                RowSeparator()
                SettingsRow {
                    IconTile(symbol: "waveform", color: Color(hex: 0x5E5CE6))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("On-device speech only")
                        Text(speech.worksOffline
                             ? "Your voice never goes to Apple's servers (less accurate)"
                             : "Not available for this language on this iPhone")
                            .font(.system(size: 13)).foregroundColor(theme.secondaryLabel)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $speech.onDeviceOnly)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: theme.toggleOn))
                        .disabled(!speech.worksOffline)
                }
                .padding(.vertical, 3)
            }
            .groupedBox()
            footnote("Your PC (Desk Bridge, home Wi-Fi only) gets your questions with the time, weather, settings, memory and your commands. Apple's speech recognition gets what you say to the assistant, unless on-device speech is on. Open-Meteo gets your approximate location for the weather. The camera and noise meter never send anything: faces are checked on the iPhone and no photo or sound is ever saved.")
        }
    }

    // MARK: Stored on the iPhone

    private var storedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Stored on this iPhone")
            VStack(spacing: 0) {
                storedRow("Today's conversation", "\(assistant.messages.count) messages", action: "Clear") {
                    assistant.clearHistory()
                }
                RowSeparator()
                storedRow("Memory", "\(commands.memory.count) facts (backed up to your PC)", action: "Forget all") {
                    confirmForget = true
                }
                RowSeparator()
                storedRow("Learned phrases", "\(commands.learned.count)", action: "Clear") { commands.clearLearned() }
                RowSeparator()
                storedRow("My commands", "\(commands.routines.count)", action: nil) {}
            }
            .groupedBox()
            footnote("Alarms, habits, focus history and settings also stay on the iPhone. Deleting the app removes everything.")
        }
    }

    private func storedRow(_ title: String, _ value: String, action: String?, run: @escaping () -> Void) -> some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(value).font(.system(size: 13)).foregroundColor(theme.secondaryLabel)
            }
            Spacer(minLength: 8)
            if let action = action {
                Button(action, action: run)
                    .foregroundColor(theme.red)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(theme.secondaryLabel)
            .padding(.leading, 14)
            .fixedSize(horizontal: false, vertical: true)
    }
}

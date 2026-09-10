//
//  SettingsView.swift
//  GlisseKit
//
//  SwiftUI is used here and only here: a form of labelled controls is genuinely
//  less code in SwiftUI, and nothing on this screen is performance sensitive.
//  The gesture path never touches SwiftUI.
//
//  Kept small on purpose. Advanced tunables are behind a disclosure so the
//  default impression is "six switches", not "a control panel".
//

import AppKit
import SwiftUI

@MainActor
final class SettingsViewModel: ObservableObject {

    @Published var settings: AppSettings
    @Published private(set) var accessibilityGranted: Bool
    @Published private(set) var loginState: LoginItemManager.State
    @Published private(set) var displays: [DisplayTarget]
    @Published private(set) var audioDeviceName: String
    @Published private(set) var volumeAvailable: Bool

    private let store: SettingsStore
    private let permissions: PermissionManager
    private let loginItems: LoginItemManager
    private let displayManager: DisplayManager
    private let volumeController: CoreAudioVolumeController
    private let onChange: () -> Void
    /// Guards against the write-back loop: applying a store change republishes.
    private var isApplyingExternalUpdate = false

    init(store: SettingsStore,
         permissions: PermissionManager,
         loginItems: LoginItemManager,
         displayManager: DisplayManager,
         volumeController: CoreAudioVolumeController,
         onChange: @escaping () -> Void) {
        self.store = store
        self.permissions = permissions
        self.loginItems = loginItems
        self.displayManager = displayManager
        self.volumeController = volumeController
        self.onChange = onChange
        self.settings = store.snapshot
        self.accessibilityGranted = permissions.accessibility.isGranted
        self.loginState = loginItems.state
        self.displays = displayManager.allDisplays
        self.audioDeviceName = volumeController.currentDeviceName
        self.volumeAvailable = volumeController.isVolumeControlAvailable
    }

    func reload() {
        isApplyingExternalUpdate = true
        settings = store.snapshot
        accessibilityGranted = permissions.accessibility.isGranted
        loginState = loginItems.state
        displays = displayManager.allDisplays
        audioDeviceName = volumeController.currentDeviceName
        volumeAvailable = volumeController.isVolumeControlAvailable
        isApplyingExternalUpdate = false
    }

    /// Called by the view on every edit.
    func commit() {
        guard !isApplyingExternalUpdate else { return }
        let updated = store.update { $0 = settings }
        if updated != settings { settings = updated }
        onChange()
    }

    func resetToDefaults() {
        store.resetToDefaults()
        reload()
        onChange()
    }

    func requestAccessibility() {
        permissions.requestAccessibility()
        permissions.openSystemSettings()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        _ = loginItems.setEnabled(enabled)
        loginState = loginItems.state
        settings.launchAtLogin = loginState.isEnabled
        commit()
        if loginState == .requiresApproval {
            loginItems.openLoginItemsSettings()
        }
    }

    func refreshDisplays() {
        displayManager.invalidateTransports()
        displayManager.scheduleRefresh(after: 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.displays = self?.displayManager.allDisplays ?? []
        }
    }
}

struct SettingsView: View {

    @ObservedObject var model: SettingsViewModel

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            gesturesTab
                .tabItem { Label("Gestures", systemImage: "hand.draw") }
            feedbackTab
                .tabItem { Label("Feedback", systemImage: "waveform") }
            displaysTab
                .tabItem { Label("Displays", systemImage: "display") }
            advancedTab
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 470, height: 430)
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Enable Glisse", isOn: binding(\.isEnabled))
                Toggle("Launch at login", isOn: Binding(
                    get: { model.loginState.isEnabled },
                    set: { model.setLaunchAtLogin($0) }))
                LabeledContent("Login item") {
                    Text(model.loginState.displayName)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack(spacing: 6) {
                        Image(systemName: model.accessibilityGranted
                              ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(model.accessibilityGranted ? Color.green : Color.orange)
                        Text(model.accessibilityGranted ? "Granted" : "Not granted")
                            .foregroundStyle(.secondary)
                    }
                }
                if !model.accessibilityGranted {
                    Text("""
                        Edge sliding works without it. Accessibility additionally \
                        enables pausing while you type, toggle-mode modifiers and the \
                        three-finger middle click.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open System Settings…") { model.requestAccessibility() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Gestures

    private var gesturesTab: some View {
        Form {
            Section("Edges") {
                Picker("Left edge", selection: binding(\.leftEdgeAction)) {
                    ForEach(EdgeAssignment.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Right edge", selection: binding(\.rightEdgeAction)) {
                    ForEach(EdgeAssignment.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Swap sides", isOn: binding(\.swapSides))
            }

            Section("Behaviour") {
                Toggle("Fine control", isOn: binding(\.fineControl))
                Toggle("Only start in the bottom quarter", isOn: binding(\.bottomQuarterOnly))
                Toggle("Freeze the pointer while adjusting", isOn: binding(\.freezeCursor))
                Toggle("Pause while typing", isOn: binding(\.smartTypingDetection))
                    .disabled(!model.accessibilityGranted)
                Toggle("Three-finger tap = middle click", isOn: binding(\.threeFingerMiddleClick))
                    .disabled(!model.accessibilityGranted)
            }

            Section("Activation") {
                Picker("Modifier", selection: modifierBinding) {
                    Text("None").tag(ModifierSelection.none)
                    ForEach(ModifierKeyChoice.allCases, id: \.self) { key in
                        Text("Hold \(key.displayName)").tag(ModifierSelection.hold(key))
                    }
                    ForEach(ModifierKeyChoice.allCases, id: \.self) { key in
                        Text("Toggle with \(key.displayName)").tag(ModifierSelection.toggle(key))
                    }
                }
            }

            Section("Sensitivity") {
                slider("Normal", binding(\.sensitivity), range: 0.2...4.0, step: 0.1)
                slider("Fine", binding(\.fineSensitivity), range: 0.05...2.0, step: 0.05)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Feedback

    private var feedbackTab: some View {
        Form {
            Section {
                Toggle("Show the macOS on-screen display", isOn: binding(\.hudEnabled))
                Picker("Menu bar icon", selection: binding(\.menuBarIcon)) {
                    ForEach(MenuBarIconStyle.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Toggle("Haptic feedback", isOn: binding(\.hapticsEnabled))
                Picker("Strength", selection: binding(\.hapticStrength)) {
                    ForEach(HapticStrength.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .disabled(!model.settings.hapticsEnabled)
            } footer: {
                Text("""
                    \(Branding.displayName) never draws its own overlay — the display shown is the one \
                    macOS owns, so it always matches your macOS version.

                    On macOS 26 and later the only way to make the system draw it is to \
                    let the system perform the change, so adjustments are delegated to \
                    the machine's own volume and brightness keys. That needs \
                    Accessibility permission, and moves in 1/64 steps. Without \
                    permission the value still changes, precisely, but no display \
                    appears.

                    macOS has no haptic intensity control, so Strength picks one of the \
                    trackpad's actuation patterns. Firmer taps are spaced further apart \
                    so they stay distinct instead of blurring into a buzz.
                    """)
                .font(.callout)
            }

            Section("Audio output") {
                LabeledContent("Device") {
                    Text(model.audioDeviceName).foregroundStyle(.secondary)
                }
                LabeledContent("Volume control") {
                    Text(model.volumeAvailable ? "Supported" : "Not supported by this device")
                        .foregroundStyle(model.volumeAvailable ? Color.secondary : Color.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Displays

    private var displaysTab: some View {
        Form {
            Section("Brightness target") {
                Picker("Adjust", selection: brightnessTargetBinding) {
                    ForEach(BrightnessTarget.allCases, id: \.self) { Text($0.displayName).tag(TargetSelection.preference($0)) }
                    ForEach(model.displays.filter { $0.capabilities.canControlBrightness }, id: \.id) { display in
                        Text(display.name).tag(TargetSelection.pinned(display.id))
                    }
                }
                Toggle("Control external monitors over DDC/CI", isOn: binding(\.externalDDCEnabled))
            }

            Section("Detected displays") {
                if model.displays.isEmpty {
                    Text("No displays detected yet.").foregroundStyle(.secondary)
                }
                ForEach(model.displays, id: \.id) { display in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(display.name)
                            if display.isBuiltIn { pill("built-in") }
                            if display.isMain { pill("main") }
                        }
                        Text(displaySubtitle(display))
                            .font(.callout)
                            .foregroundStyle(display.capabilities.canControlBrightness ? Color.secondary : Color.orange)
                    }
                }
                Button("Re-scan displays") { model.refreshDisplays() }
            }
        }
        .formStyle(.grouped)
    }

    private func displaySubtitle(_ display: DisplayTarget) -> String {
        guard display.capabilities.canControlBrightness else {
            return "Brightness not controllable"
        }
        var text = display.capabilities.backend.displayName
        if let maximum = display.capabilities.ddcMaximum {
            text += " · native max \(maximum)"
        }
        if let strategy = display.capabilities.ddcMatchStrategy {
            text += " · matched by \(strategy)"
        }
        return text
    }

    /// Named `pill`, not `tag`: `tag` collides with SwiftUI's View.tag(_:)
    /// modifier and silently breaks Picker selection.
    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }

    // MARK: Advanced

    private var advancedTab: some View {
        Form {
            Section("Edge detection") {
                slider("Edge width", binding(\.edgeWidth), range: 0.04...0.15, step: 0.005,
                       format: { String(format: "%.1f%%", $0 * 100) })
                slider("Vertical intent", binding(\.verticalActivationThreshold),
                       range: 0.002...0.08, step: 0.001,
                       format: { String(format: "%.3f", $0) })
                slider("Sideways tolerance", binding(\.horizontalRejectThreshold),
                       range: 0.01...0.5, step: 0.005,
                       format: { String(format: "%.3f", $0) })
            }

            Section("Timing") {
                slider("Typing pause", binding(\.typingSuppression), range: 0...2, step: 0.05,
                       format: { String(format: "%.0f ms", $0 * 1000) })
            }

            Section("Troubleshooting") {
                Picker("Touch source", selection: binding(\.touchSource)) {
                    ForEach(TouchSourcePreference.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Toggle("Invert vertical direction", isOn: binding(\.invertVerticalAxis))
                Toggle("Diagnostic logging", isOn: binding(\.diagnosticLogging))
                Button("Reset all settings…", role: .destructive) {
                    model.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Helpers

    private func binding<Value: Equatable>(
        _ keyPath: WritableKeyPath<AppSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                guard model.settings[keyPath: keyPath] != newValue else { return }
                model.settings[keyPath: keyPath] = newValue
                model.commit()
            })
    }

    private func slider(_ title: String,
                        _ value: Binding<Double>,
                        range: ClosedRange<Double>,
                        step: Double,
                        format: ((Double) -> String)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format?(value.wrappedValue) ?? String(format: "%.2f", value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    // Pickers cannot bind to an enum with payloads directly, so these small
    // adapters exist purely for SwiftUI's benefit.
    private enum ModifierSelection: Hashable {
        case none
        case hold(ModifierKeyChoice)
        case toggle(ModifierKeyChoice)
    }

    private var modifierBinding: Binding<ModifierSelection> {
        Binding(
            get: {
                switch model.settings.modifierMode {
                case .none: return .none
                case .hold(let key): return .hold(key)
                case .toggle(let key): return .toggle(key)
                }
            },
            set: { selection in
                let mode: ModifierMode
                switch selection {
                case .none: mode = .none
                case .hold(let key): mode = .hold(key)
                case .toggle(let key): mode = .toggle(key)
                }
                guard model.settings.modifierMode != mode else { return }
                model.settings.modifierMode = mode
                model.commit()
            })
    }

    private enum TargetSelection: Hashable {
        case preference(BrightnessTarget)
        case pinned(CGDirectDisplayID)
    }

    private var brightnessTargetBinding: Binding<TargetSelection> {
        Binding(
            get: {
                if let pinned = model.settings.pinnedDisplayID {
                    return .pinned(CGDirectDisplayID(pinned))
                }
                return .preference(model.settings.brightnessTarget)
            },
            set: { selection in
                switch selection {
                case .preference(let target):
                    model.settings.pinnedDisplayID = nil
                    model.settings.brightnessTarget = target
                case .pinned(let id):
                    model.settings.pinnedDisplayID = UInt32(id)
                }
                model.commit()
            })
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController {

    private var window: NSWindow?
    private let model: SettingsViewModel

    init(settingsStore: SettingsStore,
         permissions: PermissionManager,
         loginItems: LoginItemManager,
         displayManager: DisplayManager,
         volumeController: CoreAudioVolumeController,
         onChange: @escaping () -> Void) {
        self.model = SettingsViewModel(store: settingsStore,
                                       permissions: permissions,
                                       loginItems: loginItems,
                                       displayManager: displayManager,
                                       volumeController: volumeController,
                                       onChange: onChange)
    }

    func show() {
        model.reload()

        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let created = NSWindow(contentViewController: hosting)
            created.title = "\(Branding.displayName) Settings"
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }

        // An accessory app has to activate explicitly or the window opens behind.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func reload() {
        model.reload()
    }
}

import AgentOrbitCore
import AppKit
import Carbon
import Foundation

extension HotKeyAction {
    var preference: WritableKeyPath<KoordinatorConfig, HotKeyPreset> {
        switch self {
        case .toggleHUD: \KoordinatorConfig.hotKeyPreset
        case .cycleView: \KoordinatorConfig.viewHotKeyPreset
        case .toggleActiveProjects: \KoordinatorConfig.activeProjectsHotKeyPreset
        }
    }
}

@MainActor
final class HotKeyController: ObservableObject {
    static let shared = HotKeyController()

    enum RecordingError {
        case modifierRequired
        case conflict

        func title(in language: AppLanguage) -> String {
            switch self {
            case .modifierRequired:
                L10n.t("Use Control, Option, or Command", de: "Ctrl, Option oder Cmd verwenden", language: language)
            case .conflict:
                L10n.t("Shortcut already in use", de: "Tastenkürzel bereits belegt", language: language)
            }
        }
    }

    private struct KeySpec: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32

        init(_ keyCode: Int, _ modifiers: Int) {
            self.keyCode = UInt32(keyCode)
            self.modifiers = UInt32(modifiers)
        }
    }

    private static let modifierFlags: [(NSEvent.ModifierFlags, CustomHotKey.Modifiers, Int)] = [
        (.control, .control, controlKey),
        (.option, .option, optionKey),
        (.shift, .shift, shiftKey),
        (.command, .command, cmdKey),
    ]

    @Published private(set) var registrationFailures: Set<HotKeyAction> = []
    @Published private(set) var recordingAction: HotKeyAction?
    @Published private(set) var recordingError: RecordingError?
    private var onTrigger: ((HotKeyAction) -> Void)?

    private var hotKeyRefs: [HotKeyAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var activeShortcuts: [HotKeyAction: KeySpec] = [:]
    private var recordingMonitor: Any?
    private var recordingWindowObserver: NSObjectProtocol?

    private init() {}

    func configure(config: KoordinatorConfig, onTrigger: @escaping (HotKeyAction) -> Void) {
        self.onTrigger = onTrigger
        updateShortcuts(from: config)
    }

    func updateShortcuts(from config: KoordinatorConfig) {
        var shortcuts: [HotKeyAction: KeySpec] = [:]
        for action in HotKeyAction.allCases {
            shortcuts[action] = keySpec(for: action, in: config)
        }
        guard shortcuts != activeShortcuts else { return }
        activeShortcuts = shortcuts
        if recordingAction == nil {
            registerShortcuts()
        }
    }

    func isAssigned(_ preset: HotKeyPreset, excluding action: HotKeyAction, in config: KoordinatorConfig) -> Bool {
        guard let spec = keySpec(for: preset) else { return false }
        return HotKeyAction.allCases.contains { $0 != action && keySpec(for: $0, in: config) == spec }
    }

    func beginRecording(for action: HotKeyAction, onRecord: @escaping (CustomHotKey) -> Void) {
        cancelRecording()
        unregisterShortcuts()
        recordingAction = action
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.record(event, for: action, onRecord: onRecord)
            return nil
        }
        if recordingMonitor == nil {
            cancelRecording()
        } else if let window = NSApp.keyWindow {
            recordingWindowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelRecording() }
            }
        }
    }

    func cancelRecording() {
        guard recordingAction != nil else { return }
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
            self.recordingMonitor = nil
        }
        if let recordingWindowObserver {
            NotificationCenter.default.removeObserver(recordingWindowObserver)
            self.recordingWindowObserver = nil
        }
        recordingAction = nil
        recordingError = nil
        registerShortcuts()
    }

    private func record(_ event: NSEvent, for action: HotKeyAction, onRecord: (CustomHotKey) -> Void) {
        guard !event.isARepeat else { return }
        let modifiers = Self.modifierFlags.reduce(into: CustomHotKey.Modifiers()) { result, flag in
            if event.modifierFlags.contains(flag.0) {
                result.insert(flag.1)
            }
        }
        if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            cancelRecording()
            return
        }
        guard !modifiers.intersection([.control, .option, .command]).isEmpty else {
            recordingError = .modifierRequired
            return
        }
        let shortcut = CustomHotKey(keyCode: event.keyCode, modifiers: modifiers, keyLabel: keyLabel(for: event))
        let spec = keySpec(for: shortcut)
        installHandlerIfNeeded()
        guard !activeShortcuts.contains(where: { $0.key != action && $0.value == spec }),
              let probe = register(spec, for: action) else {
            recordingError = .conflict
            return
        }
        UnregisterEventHotKey(probe)
        cancelRecording()
        onRecord(shortcut)
    }

    private func unregisterShortcuts() {

        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func registerShortcuts() {
        unregisterShortcuts()
        if !activeShortcuts.isEmpty {
            installHandlerIfNeeded()
        }
        var registeredSpecs: Set<KeySpec> = []
        var failures: Set<HotKeyAction> = []
        for action in HotKeyAction.allCases {
            guard let spec = activeShortcuts[action] else { continue }
            if !registeredSpecs.contains(spec), let ref = register(spec, for: action) {
                hotKeyRefs[action] = ref
                registeredSpecs.insert(spec)
            } else {
                failures.insert(action)
            }
        }
        registrationFailures = failures
    }

    private func register(_ spec: KeySpec, for action: HotKeyAction) -> EventHotKeyRef? {
        guard eventHandlerRef != nil else { return nil }
        let hotKeyID = EventHotKeyID(signature: 0x414F5242, id: action.rawValue) // 'AORB'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode, spec.modifiers, hotKeyID, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &ref
        )
        return status == noErr ? ref : nil
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr, hotKeyID.signature == 0x414F5242,
                      let action = HotKeyAction(rawValue: hotKeyID.id) else {
                    return OSStatus(eventNotHandledErr)
                }
                let rawPtr = UnsafeMutableRawPointer(userData)
                let box = SendablePointerBox(rawPtr)
                DispatchQueue.main.async {
                    let controller = Unmanaged<HotKeyController>.fromOpaque(box.pointer).takeUnretainedValue()
                    guard controller.hotKeyRefs[action] != nil else { return }
                    controller.onTrigger?(action)
                }
                return noErr
            },
            1,
            &eventSpec,
            userData,
            &handler
        )
        if status == noErr {
            eventHandlerRef = handler
        }
    }

    private func keySpec(for action: HotKeyAction, in config: KoordinatorConfig) -> KeySpec? {
        if let custom = config.customHotKeys[action] {
            return keySpec(for: custom)
        }
        return keySpec(for: config[keyPath: action.preference])
    }

    private func keySpec(for custom: CustomHotKey) -> KeySpec {
        let modifiers = Self.modifierFlags.reduce(0) { result, flag in
            result | (custom.modifiers.contains(flag.1) ? flag.2 : 0)
        }
        return KeySpec(Int(custom.keyCode), modifiers)
    }

    private func keySpec(for preset: HotKeyPreset) -> KeySpec? {
        switch preset {
        case .none:
            return nil
        case .controlOptionO:
            return KeySpec(kVK_ANSI_O, controlKey | optionKey)
        case .controlOptionA:
            return KeySpec(kVK_ANSI_A, controlKey | optionKey)
        case .commandShiftO:
            return KeySpec(kVK_ANSI_O, cmdKey | shiftKey)
        case .controlOptionSpace:
            return KeySpec(kVK_Space, controlKey | optionKey)
        case .optionSpace:
            return KeySpec(kVK_Space, optionKey)
        case .controlOptionV:
            return KeySpec(kVK_ANSI_V, controlKey | optionKey)
        case .controlOptionP:
            return KeySpec(kVK_ANSI_P, controlKey | optionKey)
        }
    }

    private func keyLabel(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "␣"
        case kVK_Tab: return "⇥"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default:
            if let characters = event.charactersIgnoringModifiers, let scalar = characters.unicodeScalars.first {
                if (0xF704...0xF726).contains(scalar.value) {
                    return "F\(scalar.value - 0xF703)"
                }
                if scalar.properties.generalCategory != .privateUse, !CharacterSet.controlCharacters.contains(scalar) {
                    return characters.uppercased()
                }
            }
            return "#\(event.keyCode)"
        }
    }
}

private struct SendablePointerBox: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    init(_ pointer: UnsafeMutableRawPointer) {
        self.pointer = pointer
    }
}

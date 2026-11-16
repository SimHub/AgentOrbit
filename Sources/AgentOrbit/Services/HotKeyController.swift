import AgentOrbitCore
import Carbon
import Foundation

@MainActor
final class HotKeyController: ObservableObject {
    static let shared = HotKeyController()

    @Published private(set) var registrationFailed = false
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var activePreset: HotKeyPreset = .none

    private init() {}

    func configure(preset: HotKeyPreset, onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        updatePreset(preset)
    }

    func updatePreset(_ preset: HotKeyPreset) {
        guard preset != activePreset || (preset != .none && hotKeyRef == nil) else { return }
        activePreset = preset
        unregister()
        registrationFailed = false

        guard let spec = keySpec(for: preset) else { return }
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: 0x414F5242, id: 1) // 'AORB'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            registrationFailed = true
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
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
                guard err == noErr, hotKeyID.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                let rawPtr = UnsafeMutableRawPointer(userData)
                let box = SendablePointerBox(rawPtr)
                DispatchQueue.main.async {
                    let controller = Unmanaged<HotKeyController>.fromOpaque(box.pointer).takeUnretainedValue()
                    controller.onTrigger?()
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

    private func keySpec(for preset: HotKeyPreset) -> (keyCode: UInt32, modifiers: UInt32)? {
        switch preset {
        case .none:
            return nil
        case .controlOptionO:
            return (UInt32(kVK_ANSI_O), UInt32(controlKey | optionKey))
        case .controlOptionA:
            return (UInt32(kVK_ANSI_A), UInt32(controlKey | optionKey))
        case .commandShiftO:
            return (UInt32(kVK_ANSI_O), UInt32(cmdKey | shiftKey))
        case .controlOptionSpace:
            return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .optionSpace:
            return (UInt32(kVK_Space), UInt32(optionKey))
        }
    }
}

private struct SendablePointerBox: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    init(_ pointer: UnsafeMutableRawPointer) {
        self.pointer = pointer
    }
}

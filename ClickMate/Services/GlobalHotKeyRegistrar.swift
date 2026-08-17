import Carbon.HIToolbox

@MainActor
final class GlobalHotKeyRegistrar {
    private static let signature: OSType = 0x434D_4854

    private var nextIdentifier: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private var hotKeyReferences: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if status != noErr {
            eventHandler = nil
        }
    }

    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping () -> Void
    ) -> Bool {
        guard eventHandler != nil else { return false }
        let identifier = nextIdentifier
        nextIdentifier += 1
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            return false
        }

        hotKeyReferences[identifier] = reference
        handlers[identifier] = handler
        return true
    }

    func unregisterAll() {
        for reference in hotKeyReferences.values {
            UnregisterEventHotKey(reference)
        }
        hotKeyReferences.removeAll()
        handlers.removeAll()
    }

    func invalidate() {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else {
            return OSStatus(eventNotHandledErr)
        }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == GlobalHotKeyRegistrar.signature else {
            return OSStatus(eventNotHandledErr)
        }

        let registrar = Unmanaged<GlobalHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
        return MainActor.assumeIsolated {
            guard let handler = registrar.handlers[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            handler()
            return noErr
        }
    }
}

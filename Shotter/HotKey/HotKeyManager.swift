import AppKit
import Carbon.HIToolbox

/// ホットキーで起動できる操作。生の値がそのまま Carbon の EventHotKeyID になる。
enum HotKeyAction: UInt32, CaseIterable {
    case areaCapture = 1
    case windowCapture = 2
    case textRecognition = 3

    var title: String {
        switch self {
        case .areaCapture:     return "範囲キャプチャ"
        case .windowCapture:   return "ウィンドウキャプチャ"
        case .textRecognition: return "文字を読み取ってコピー"
        }
    }
}

/// Carbon の RegisterEventHotKey でグローバルホットキーを登録する。
///
/// NSEvent のグローバルモニタと違い**アクセシビリティ権限が不要**なので、
/// 個人利用ビルドでも余計な許可を求めずに済む。
@MainActor
final class HotKeyManager {

    static let shared = HotKeyManager()

    /// 'SHOT' を署名として使う。
    private static let signature: OSType = 0x53_48_4F_54

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandlerRef: EventHandlerRef?

    private(set) var registeredCombos: [HotKeyAction: KeyCombo] = [:]

    private init() {}

    /// - Returns: 登録できたら true。他アプリが同じキーを押さえている場合は false。
    @discardableResult
    func register(_ combo: KeyCombo, for action: HotKeyAction, handler: @escaping () -> Void) -> Bool {
        unregister(action)
        installEventHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else { return false }

        hotKeyRefs[action.rawValue] = reference
        handlers[action.rawValue] = handler
        registeredCombos[action] = combo
        return true
    }

    func unregister(_ action: HotKeyAction) {
        if let reference = hotKeyRefs.removeValue(forKey: action.rawValue) {
            UnregisterEventHotKey(reference)
        }
        handlers.removeValue(forKey: action.rawValue)
        registeredCombos.removeValue(forKey: action)
    }

    func unregisterAll() {
        for action in HotKeyAction.allCases { unregister(action) }
    }

    fileprivate func handleHotKeyPressed(id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }
}

/// Carbon から呼ばれる C コールバック。メインスレッドへ渡し直す。
private func hotKeyEventHandler(
    handlerCall: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )

    guard status == noErr else { return status }

    let id = identifier.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            HotKeyManager.shared.handleHotKeyPressed(id: id)
        }
    }
    return noErr
}

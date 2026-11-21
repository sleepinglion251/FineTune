// FineTune/Audio/Effects/EffectEditorManager.swift
import AppKit
import AudioToolbox
import CoreAudioKit
import os

/// Callbacks an effect editor uses to reach the running chains and settings.
@MainActor
struct EffectEditorActions {
    /// The instance currently processing audio for this slot, if any. The editor attaches
    /// its view to it so the effect's own meters and displays show the real signal.
    var liveEffect: () -> HostedEffect?
    /// The slot's last saved state, used when no live instance exists.
    var savedState: () -> Data?
    /// A parameter moved in the editor; forward to every running copy of the effect.
    var parameterChanged: (AudioUnitParameterID, AudioUnitScope, AudioUnitElement, AudioUnitParameterValue) -> Void
    /// A whole preset was loaded in the editor; load it into every running copy and save it.
    var stateLoaded: (Data) -> Void
    /// Persist the editor's current state (debounced while editing, and on close).
    var saveState: (Data) -> Void
}

/// Opens one editor window per effect slot.
@MainActor
final class EffectEditorManager {
    static let shared = EffectEditorManager()

    private var editors: [UUID: EffectEditorWindow] = [:]

    func open(slot: AudioEffectSlot, ownerName: String, sampleRate: Double, actions: EffectEditorActions) {
        if let existing = editors[slot.id] {
            existing.bringToFront()
            return
        }
        guard let editor = EffectEditorWindow(slot: slot, ownerName: ownerName, sampleRate: sampleRate, actions: actions, onClose: { [weak self] in
            self?.editors[slot.id] = nil
        }) else { return }
        editors[slot.id] = editor
        editor.bringToFront()
    }

    /// Closes the editor for a slot that was removed from its chain.
    func close(slotID: UUID) {
        editors[slotID]?.close()
    }
}

/// Shows an effect's editor. While audio is playing, the view is attached to the live
/// instance inside a tap (so meters move and edits are heard directly); its edits are
/// copied to any other running copies. With nothing playing, it falls back to a private
/// instance and re-attaches once a live one appears or the chain is rebuilt.
@MainActor
private final class EffectEditorWindow: NSObject, NSWindowDelegate {
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "EffectEditor")
    private let slot: AudioEffectSlot
    private let sampleRate: Double
    private let window: NSWindow
    private let actions: EffectEditorActions
    private let onClose: () -> Void

    /// Retained while attached, so the unit outlives a chain rebuild until we re-attach.
    private var boundLive: HostedEffect?
    /// Fallback instance owned by the editor; disposed when replaced or closed.
    private var privateUnit: AudioUnit?
    private var unit: AudioUnit
    private var listener: AUEventListenerRef?
    private var saveTask: Task<Void, Never>?
    private var rebindTimer: Timer?
    private var isClosed = false
    /// Last preset pushed to the running copies. Loading it into the attached unit can
    /// report another preset change; ignoring the identical state avoids a loop.
    private var lastLoadedState: Data?

    init?(slot: AudioEffectSlot, ownerName: String, sampleRate: Double, actions: EffectEditorActions, onClose: @escaping () -> Void) {
        self.slot = slot
        self.sampleRate = sampleRate
        self.actions = actions
        self.onClose = onClose

        let live = actions.liveEffect()
        if let live {
            unit = live.unit
            boundLive = live
        } else {
            guard let created = EffectUnitFactory.makeUnit(component: slot.component, sampleRate: sampleRate, state: actions.savedState() ?? slot.state, inputCallback: nil) else {
                return nil
            }
            unit = created
            privateUnit = created
        }

        let content = Self.makeView(for: unit)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: content.frame.size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(slot.name) — \(ownerName)"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        super.init()
        window.delegate = self
        startListening()
        startRebindTimer()
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        rebindTimer?.invalidate()
        rebindTimer = nil
        saveTask?.cancel()
        if let state = EffectUnitFactory.state(of: unit) {
            actions.saveState(state)
        }
        stopListening()
        window.contentView = nil
        disposePrivateUnit()
        boundLive = nil
        onClose()
    }

    // MARK: - Attaching to the live instance

    private func startRebindTimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebindIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rebindTimer = timer
    }

    /// Follows the live instance as it appears, changes (device switch, rate change,
    /// chain rebuild) or disappears (app stopped).
    private func rebindIfNeeded() {
        guard !isClosed else { return }
        let live = actions.liveEffect()
        if live === boundLive { return }
        if live == nil, boundLive == nil { return }

        // Carry the current settings across: save them now so a newly built instance
        // and the private fallback both start from what the user sees.
        saveTask?.cancel()
        let currentState = EffectUnitFactory.state(of: unit)
        if let currentState {
            actions.saveState(currentState)
        }

        let newUnit: AudioUnit
        var newPrivate: AudioUnit?
        if let live {
            newUnit = live.unit
        } else {
            guard let created = EffectUnitFactory.makeUnit(component: slot.component, sampleRate: sampleRate, state: currentState ?? actions.savedState(), inputCallback: nil) else {
                return
            }
            newUnit = created
            newPrivate = created
        }

        stopListening()
        let oldPrivate = privateUnit
        let oldLive = boundLive
        unit = newUnit
        privateUnit = newPrivate
        boundLive = live

        let content = Self.makeView(for: newUnit)
        window.contentView = content
        window.setContentSize(content.frame.size)
        startListening()

        // The old view is gone; now its unit can go.
        if let oldPrivate {
            AudioUnitUninitialize(oldPrivate)
            AudioComponentInstanceDispose(oldPrivate)
        }
        _ = oldLive
        logger.debug("Effect editor for \(self.slot.name) attached to \(live == nil ? "a private instance" : "the live instance")")
    }

    private func disposePrivateUnit() {
        guard let privateUnit else { return }
        AudioUnitUninitialize(privateUnit)
        AudioComponentInstanceDispose(privateUnit)
        self.privateUnit = nil
    }

    // MARK: - Change tracking

    private func startListening() {
        var newListener: AUEventListenerRef?
        let status = AUEventListenerCreateWithDispatchQueue(&newListener, 0.02, 0.02, .main) { [weak self] _, event, _, value in
            let event = event.pointee
            MainActor.assumeIsolated {
                self?.handle(event, value: value)
            }
        }
        guard status == noErr, let newListener else {
            logger.error("Could not listen to effect editor changes: \(status)")
            return
        }
        listener = newListener

        for scope in [kAudioUnitScope_Global, kAudioUnitScope_Input, kAudioUnitScope_Output] {
            // Meters are read-only parameters; only forward ones the user can change.
            for parameterID in Self.parameterIDs(of: unit, scope: scope) where Self.isWritable(unit, parameterID, scope: scope) {
                var event = AudioUnitEvent()
                event.mEventType = .parameterValueChange
                event.mArgument.mParameter = AudioUnitParameter(mAudioUnit: unit, mParameterID: parameterID, mScope: scope, mElement: 0)
                AUEventListenerAddEventType(newListener, nil, &event)
            }
        }
        var presetEvent = AudioUnitEvent()
        presetEvent.mEventType = .propertyChange
        presetEvent.mArgument.mProperty = AudioUnitProperty(mAudioUnit: unit, mPropertyID: kAudioUnitProperty_PresentPreset, mScope: kAudioUnitScope_Global, mElement: 0)
        AUEventListenerAddEventType(newListener, nil, &presetEvent)
    }

    private func stopListening() {
        if let listener {
            AUListenerDispose(listener)
            self.listener = nil
        }
    }

    private func handle(_ event: AudioUnitEvent, value: AudioUnitParameterValue) {
        guard !isClosed else { return }
        switch event.mEventType {
        case .parameterValueChange:
            let parameter = event.mArgument.mParameter
            guard parameter.mAudioUnit == unit else { return }
            actions.parameterChanged(parameter.mParameterID, parameter.mScope, parameter.mElement, value)
            scheduleSave()
        case .propertyChange:
            guard event.mArgument.mProperty.mAudioUnit == unit else { return }
            if let state = EffectUnitFactory.state(of: unit), state != lastLoadedState {
                lastLoadedState = state
                actions.stateLoaded(state)
            }
        default:
            break
        }
    }

    /// Persist shortly after editing pauses, so a crash or quit mid-edit keeps the change.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, !self.isClosed else { return }
            if let state = EffectUnitFactory.state(of: self.unit) {
                self.actions.saveState(state)
            }
        }
    }

    // MARK: - Views

    private static func parameterIDs(of unit: AudioUnit, scope: AudioUnitScope) -> [AudioUnitParameterID] {
        var size: UInt32 = 0
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_ParameterList, scope, 0, &size, nil) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioUnitParameterID](repeating: 0, count: Int(size) / MemoryLayout<AudioUnitParameterID>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterList, scope, 0, &ids, &size) == noErr else { return [] }
        return ids
    }

    private static func makeView(for unit: AudioUnit) -> NSView {
        customView(for: unit) ?? genericView(for: unit)
    }

    private static func isWritable(_ unit: AudioUnit, _ parameterID: AudioUnitParameterID, scope: AudioUnitScope) -> Bool {
        var info = AudioUnitParameterInfo()
        var size = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo, scope, parameterID, &info, &size) == noErr else {
            return true
        }
        return info.flags.contains(.flag_IsWritable)
    }

    private static func genericView(for unit: AudioUnit) -> NSView {
        let view = AUGenericView(audioUnit: unit)
        view.showsExpertParameters = true
        return view
    }

    /// The effect's own Cocoa editor, when it ships one (e.g. AUGraphicEQ, AUDynamicsProcessor).
    private static func customView(for unit: AudioUnit) -> NSView? {
        var size: UInt32 = 0
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, nil) == noErr,
              size >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size) else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { raw.deallocate() }
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &size) == noErr else { return nil }

        let info = raw.assumingMemoryBound(to: AudioUnitCocoaViewInfo.self).pointee
        let bundleURL = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let className = info.mCocoaAUViewClass.takeRetainedValue() as String
        // Release any further class names the unit returned (we only use the first).
        let extraCount = (Int(size) - MemoryLayout<AudioUnitCocoaViewInfo>.size) / MemoryLayout<Unmanaged<CFString>>.size
        if extraCount > 0 {
            let extras = (raw + MemoryLayout<AudioUnitCocoaViewInfo>.size).assumingMemoryBound(to: Unmanaged<CFString>.self)
            for index in 0..<extraCount { extras[index].release() }
        }

        // The factory implements AUCocoaUIBase, which isn't exposed to Swift, so call
        // -uiViewForAudioUnit:withSize: through the Objective-C runtime.
        typealias MakeView = @convention(c) (AnyObject, Selector, AudioUnit, NSSize) -> Unmanaged<NSView>?
        let selector = NSSelectorFromString("uiViewForAudioUnit:withSize:")
        guard let bundle = Bundle(url: bundleURL),
              let factoryClass = bundle.classNamed(className) as? NSObject.Type else {
            return nil
        }
        let factory = factoryClass.init()
        guard factory.responds(to: selector) else { return nil }
        let makeView = unsafeBitCast(factory.method(for: selector), to: MakeView.self)
        return makeView(factory, selector, unit, NSSize(width: 480, height: 320))?.takeUnretainedValue()
    }
}

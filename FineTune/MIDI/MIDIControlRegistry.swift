// FineTune/MIDI/MIDIControlRegistry.swift
import AudioToolbox
import Foundation
import os

/// Per-app audio operations MIDI drives. `AudioEngine` conforms; tests inject a fake.
@MainActor
protocol MIDIAppAudioControlling: AnyObject {
    var apps: [AudioApp] { get }
    func setVolume(for app: AudioApp, to volume: Float)
    func setMute(for app: AudioApp, to muted: Bool)
    func isMuted(for app: AudioApp) -> Bool
    func setVolumeForInactive(identifier: String, to volume: Float)
    func getMuteForInactive(identifier: String) -> Bool
    func setMuteForInactive(identifier: String, to muted: Bool)
}

/// Default-output-device operations MIDI drives. `DeviceVolumeMonitor` conforms.
@MainActor
protocol MIDISystemVolumeControlling: AnyObject {
    var defaultDeviceID: AudioDeviceID { get }
    var muteStates: [AudioDeviceID: Bool] { get }
    func setVolume(for deviceID: AudioDeviceID, to volume: Float)
    func setMute(for deviceID: AudioDeviceID, to muted: Bool)
    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier
}

extension AudioEngine: MIDIAppAudioControlling {}
extension DeviceVolumeMonitor: MIDISystemVolumeControlling {}

/// Routes incoming MIDI to per-app and system volume/mute, and owns "MIDI learn".
///
/// Bindings live in `AppSettings.midiMappings` (settings.json is the source of truth).
/// One physical control drives at most one slot: learning a control that's already
/// bound elsewhere moves it.
@MainActor
@Observable
final class MIDIControlRegistry {
    private static let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "MIDIControl")

    /// DDC write queues saturate at fader rate; same floor the media-key path uses.
    static let ddcMinInterval: Duration = .milliseconds(80)

    struct LearnRequest: Equatable {
        let target: MIDITarget
        let slot: MIDIControlSlot
        /// Captured at learn time so the mapping can be listed while the app isn't running.
        let displayName: String?
        let bundleID: String?
    }

    /// The slot currently waiting for a control, if any.
    private(set) var learning: LearnRequest?

    /// Most recent message, for the settings tab's activity readout.
    private(set) var lastMessage: ReceivedMIDIMessage?

    @ObservationIgnored private let settings: SettingsManager
    @ObservationIgnored private let input: any MIDIInputProviding
    @ObservationIgnored private let appAudio: any MIDIAppAudioControlling
    @ObservationIgnored private let systemVolume: any MIDISystemVolumeControlling

    @ObservationIgnored private var lastDDCWrite: ContinuousClock.Instant?
    @ObservationIgnored private var pendingDDCFraction: Double?
    @ObservationIgnored private var ddcFlushTask: Task<Void, Never>?

    init(
        settings: SettingsManager,
        input: any MIDIInputProviding,
        appAudio: any MIDIAppAudioControlling,
        systemVolume: any MIDISystemVolumeControlling
    ) {
        self.settings = settings
        self.input = input
        self.appAudio = appAudio
        self.systemVolume = systemVolume
        input.onMessages = { [weak self] batch in
            self?.handle(batch)
        }
    }

    var inputSourceNames: [String] { input.sourceNames }

    func sourceName(for message: ReceivedMIDIMessage) -> String? {
        input.sourceName(for: message.sourceID)
    }

    /// Starts or stops MIDI input to match the enabled setting. Idempotent.
    func reconcile() {
        if settings.appSettings.midiControlEnabled {
            input.start()
        } else {
            input.stop()
            learning = nil
        }
    }

    // MARK: - Mapping access

    func mapping(for target: MIDITarget) -> MIDITargetMapping? {
        settings.appSettings.midiMappings[target.storageKey]
    }

    /// Every app target that has at least one binding, with its remembered metadata.
    var mappedAppTargets: [(identifier: String, mapping: MIDITargetMapping)] {
        settings.appSettings.midiMappings.compactMap { key, mapping in
            guard case .app(let identifier)? = MIDITarget(storageKey: key) else { return nil }
            return (identifier, mapping)
        }
    }

    func clearBinding(for target: MIDITarget, slot: MIDIControlSlot) {
        updateMappings { mappings in
            guard var mapping = mappings[target.storageKey] else { return }
            mapping.setBinding(nil, for: slot)
            mappings[target.storageKey] = mapping.isEmpty ? nil : mapping
        }
    }

    func setMuteMode(_ mode: MIDIMuteMode, for target: MIDITarget) {
        updateMappings { mappings in
            guard var mapping = mappings[target.storageKey] else { return }
            mapping.muteMode = mode
            mappings[target.storageKey] = mapping
        }
    }

    // MARK: - Learn

    func beginLearning(target: MIDITarget, slot: MIDIControlSlot, displayName: String? = nil, bundleID: String? = nil) {
        learning = LearnRequest(target: target, slot: slot, displayName: displayName, bundleID: bundleID)
    }

    func cancelLearning() {
        learning = nil
    }

    func isLearning(target: MIDITarget, slot: MIDIControlSlot) -> Bool {
        learning?.target == target && learning?.slot == slot
    }

    private func completeLearning(_ request: LearnRequest, with binding: MIDIBinding) {
        updateMappings { mappings in
            // One control → one slot: strip this binding from wherever else it lives.
            for key in Array(mappings.keys) {
                guard var other = mappings[key] else { continue }
                if other.volume == binding { other.volume = nil }
                if other.mute == binding { other.mute = nil }
                mappings[key] = other.isEmpty ? nil : other
            }
            var mapping = mappings[request.target.storageKey] ?? MIDITargetMapping()
            if let name = request.displayName { mapping.displayName = name }
            if let bundleID = request.bundleID { mapping.bundleID = bundleID }
            mapping.setBinding(binding, for: request.slot)
            mappings[request.target.storageKey] = mapping
        }
        learning = nil
        Self.logger.info("Learned \(binding.displayString, privacy: .public) for \(request.target.storageKey, privacy: .public) \(request.slot.rawValue, privacy: .public)")
    }

    private func updateMappings(_ body: (inout [String: MIDITargetMapping]) -> Void) {
        var app = settings.appSettings
        body(&app.midiMappings)
        settings.appSettings = app
    }

    // MARK: - Dispatch

    /// Entry point for a batch from `MIDIInputService`. Exposed `internal` for tests.
    func handle(_ batch: [ReceivedMIDIMessage]) {
        guard let last = batch.last else { return }
        lastMessage = last

        var remaining = batch[...]
        if let request = learning {
            guard let index = remaining.firstIndex(where: { MIDIValueMapping.isLearnable($0.message, for: request.slot) }) else {
                return  // Nothing usable yet; keep listening, and don't act on stray input.
            }
            completeLearning(request, with: remaining[index].message.binding)
            // The captured message only teaches; it doesn't also fire the action.
            remaining = remaining[(index + 1)...]
        }

        guard settings.appSettings.midiControlEnabled, !remaining.isEmpty else { return }

        let mappings = settings.appSettings.midiMappings
        var volumeIndex: [MIDIBinding: MIDITarget] = [:]
        var muteIndex: [MIDIBinding: (MIDITarget, MIDIMuteMode)] = [:]
        for (key, mapping) in mappings {
            guard let target = MIDITarget(storageKey: key) else { continue }
            if let volume = mapping.volume { volumeIndex[volume] = target }
            if let mute = mapping.mute { muteIndex[mute] = (target, mapping.muteMode) }
        }

        // Faders emit bursts; within a batch only the final position per target matters.
        var pendingVolumes: [MIDITarget: Double] = [:]
        var volumeOrder: [MIDITarget] = []

        for received in remaining {
            let message = received.message
            let binding = message.binding

            if case .controlChange(_, _, let value) = message, let target = volumeIndex[binding] {
                if pendingVolumes[target] == nil { volumeOrder.append(target) }
                pendingVolumes[target] = MIDIValueMapping.sliderFraction(forCCValue: value)
            }

            // Mute toggles are edge-triggered and must not be coalesced.
            if let (target, mode) = muteIndex[binding],
               let action = MIDIValueMapping.muteAction(for: message, mode: mode) {
                applyMute(action, to: target)
            }
        }

        for target in volumeOrder {
            if let fraction = pendingVolumes[target] {
                applyVolume(sliderFraction: fraction, to: target)
            }
        }
    }

    // MARK: - Apply

    private func applyVolume(sliderFraction: Double, to target: MIDITarget) {
        switch target {
        case .app(let identifier):
            let gain = VolumeMapping.sliderToGain(sliderFraction)
            let running = appAudio.apps.filter { $0.persistenceIdentifier == identifier }
            if running.isEmpty {
                appAudio.setVolumeForInactive(identifier: identifier, to: gain)
            } else {
                for app in running { appAudio.setVolume(for: app, to: gain) }
            }

        case .systemOutput:
            let deviceID = systemVolume.defaultDeviceID
            guard deviceID.isValid else { return }
            if systemVolume.outputVolumeBackend(for: deviceID) == .ddc {
                writeDDCThrottled(sliderFraction: sliderFraction)
            } else {
                writeSystemVolume(sliderFraction: sliderFraction, deviceID: deviceID)
            }
        }
    }

    /// `muted == nil` toggles.
    private func applyMute(_ muted: Bool?, to target: MIDITarget) {
        switch target {
        case .app(let identifier):
            let running = appAudio.apps.filter { $0.persistenceIdentifier == identifier }
            if running.isEmpty {
                let next = muted ?? !appAudio.getMuteForInactive(identifier: identifier)
                appAudio.setMuteForInactive(identifier: identifier, to: next)
            } else {
                // Resolve the toggle once so multiple processes of one app stay in lockstep.
                let next = muted ?? !appAudio.isMuted(for: running[0])
                for app in running { appAudio.setMute(for: app, to: next) }
            }

        case .systemOutput:
            let deviceID = systemVolume.defaultDeviceID
            guard deviceID.isValid else { return }
            let next = muted ?? !(systemVolume.muteStates[deviceID] ?? false)
            systemVolume.setMute(for: deviceID, to: next)
        }
    }

    private func writeSystemVolume(sliderFraction: Double, deviceID: AudioDeviceID) {
        let tier = systemVolume.outputVolumeBackend(for: deviceID)
        let gain = VolumeMapping.systemGain(forSliderFraction: sliderFraction, tier: tier)
        systemVolume.setVolume(for: deviceID, to: gain)
    }

    /// Leading-edge write, then at most one trailing write per interval carrying the
    /// latest fader position, so the monitor always lands where the fader stopped.
    private func writeDDCThrottled(sliderFraction: Double) {
        let now = ContinuousClock.now
        if let last = lastDDCWrite, now - last < Self.ddcMinInterval {
            pendingDDCFraction = sliderFraction
            guard ddcFlushTask == nil else { return }
            let delay = Self.ddcMinInterval - (now - last)
            ddcFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.ddcFlushTask = nil
                if let pending = self.pendingDDCFraction {
                    self.pendingDDCFraction = nil
                    self.writeDDCThrottled(sliderFraction: pending)
                }
            }
            return
        }
        lastDDCWrite = now
        let deviceID = systemVolume.defaultDeviceID
        guard deviceID.isValid else { return }
        writeSystemVolume(sliderFraction: sliderFraction, deviceID: deviceID)
    }
}

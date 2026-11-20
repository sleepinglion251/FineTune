// FineTuneTests/AudioEngineTapInitialStateTests.swift
//
// Verifies AudioEngine derives TapInitialState from persisted settings and
// hands it to activate(initial:) before any post-activation mutation.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

// MARK: - Recording Mock

/// Records every method invocation against `ProcessTapControlling` in order.
/// Tests assert on `events` to verify the engine's apply-initial-state contract.
@MainActor
final class RecordingProcessTapController: ProcessTapControlling {
    enum Event: Equatable {
        case activate(TapInitialStateSnapshot)
        case updateEQSettings(EQSettings)
        case updateDeviceEQSettings(EQSettings)
        case updateEffectChain(stage: EffectChainStage, slotIDs: [UUID])
        case updateAutoEQProfile(profileID: String?)
        case setAutoEQPreampEnabled(Bool)
        case updateLoudnessCompensation(volume: Float, enabled: Bool)
        case updateLoudnessEqualization(LoudnessEqualizerSettings)
        case invalidate
    }

    /// Plain snapshot of `TapInitialState` so test asserts don't depend on
    /// the source-type's identity (defensive against future mutations).
    struct TapInitialStateSnapshot: Equatable {
        var eqSettings: EQSettings
        var deviceEQSettings: EQSettings
        var appEffectIDs: [UUID]
        var deviceEffectIDs: [UUID]
        var autoEQProfileID: String?
        var autoEQPreampEnabled: Bool
        var loudnessVolume: Float
        var loudnessCompensationEnabled: Bool
        var loudnessEqualizerSettings: LoudnessEqualizerSettings

        @MainActor
        init(_ s: TapInitialState) {
            self.eqSettings = s.eqSettings
            self.deviceEQSettings = s.deviceEQSettings
            self.appEffectIDs = s.appEffects.map(\.id)
            self.deviceEffectIDs = s.deviceEffects.map(\.id)
            self.autoEQProfileID = s.autoEQProfile?.id
            self.autoEQPreampEnabled = s.autoEQPreampEnabled
            self.loudnessVolume = s.loudnessVolume
            self.loudnessCompensationEnabled = s.loudnessCompensationEnabled
            self.loudnessEqualizerSettings = s.loudnessEqualizerSettings
        }
    }

    let app: AudioApp
    private(set) var events: [Event] = []

    // Mutable surface — recorded as plain property writes (not events).
    var volume: Float = 1.0
    var isMuted: Bool = false
    var currentDeviceVolume: Float = 1.0
    var isDeviceMuted: Bool = false
    var audioLevel: Float = 0.0
    private(set) var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String? = nil

    init(app: AudioApp, deviceUIDs: [String]) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
    }

    func activate(initial: TapInitialState) throws {
        events.append(.activate(TapInitialStateSnapshot(initial)))
    }

    func invalidate() {
        events.append(.invalidate)
    }

    func updateEQSettings(_ settings: EQSettings) {
        events.append(.updateEQSettings(settings))
    }

    func updateDeviceEQSettings(_ settings: EQSettings) {
        events.append(.updateDeviceEQSettings(settings))
    }

    func updateEffectChain(_ slots: [AudioEffectSlot], stage: EffectChainStage) {
        events.append(.updateEffectChain(stage: stage, slotIDs: slots.map(\.id)))
    }

    func updateAutoEQProfile(_ profile: AutoEQProfile?) {
        events.append(.updateAutoEQProfile(profileID: profile?.id))
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        events.append(.setAutoEQPreampEnabled(enabled))
    }

    func updateLoudnessCompensation(volume: Float, enabled: Bool) {
        events.append(.updateLoudnessCompensation(volume: volume, enabled: enabled))
    }

    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {
        events.append(.updateLoudnessEqualization(settings))
    }

    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = [newDeviceUID]
    }

    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = newDeviceUIDs
    }

    func hasRecentAudioCallback(within seconds: Double) -> Bool { false }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { false }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {}
}

// MARK: - Process monitor stub

@MainActor
final class StubProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?
    func start() {}
    func stop() {}
}

// MARK: - Fixture

@MainActor
private struct Fixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let deviceMonitor: MockAudioDeviceMonitor
    let deviceVolume: MockDeviceVolumeProviding
    let app: AudioApp
    let device: AudioDevice
    let lastTap: () -> RecordingProcessTapController?
}

@MainActor
private func makeFixture(
    supportsAutoEQ: Bool = true,
    deviceVolume: Float = 0.75
) -> Fixture {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(directory: tempDir)

    let deviceMonitor = MockAudioDeviceMonitor()
    let device = AudioDevice(
        id: AudioDeviceID(99),
        uid: "uid-test",
        name: "Test Output",
        icon: nil,
        supportsAutoEQ: supportsAutoEQ
    )
    deviceMonitor.addOutputDevice(device)

    let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
    mockVolume.volumes[device.id] = deviceVolume

    let app = AudioApp(
        id: 12345,
        processObjectIDs: [],
        name: "TestApp",
        icon: NSImage(),
        bundleID: "com.test.tapinitial"
    )

    let processMonitor = StubProcessMonitor()
    processMonitor.activeApps = [app]

    // Capture every tap the factory hands out so tests can read the captured
    // event log. Mutable box lets the closure write into the test scope.
    let box = TapBox()

    // ensureTapExists guards on permission.status == .authorized. The TCC SPI
    // preflight returns -1 (unknown) under xctest, so we force it to authorized
    // via the internal(set) status property exposed by @testable import.
    let permission = AudioRecordingPermission()
    permission.status = .authorized

    let engine = AudioEngine(
        permission: permission,
        settingsManager: settings,
        autoEQProfileManager: AutoEQProfileManager(),
        deviceProvider: deviceMonitor,
        processMonitor: processMonitor,
        deviceVolumeMonitor: mockVolume,
        tapFactory: { app, uids, _ in
            let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
            box.last = tap
            return tap
        },
        startMonitorsAutomatically: false
    )

    return Fixture(
        engine: engine,
        settings: settings,
        deviceMonitor: deviceMonitor,
        deviceVolume: mockVolume,
        app: app,
        device: device,
        lastTap: { box.last }
    )
}

@MainActor
private final class TapBox {
    var last: RecordingProcessTapController?
}

// MARK: - Suite

@Suite("AudioEngine.tapInitialState — first-sound fix (PR-1)")
@MainActor
struct AudioEngineTapInitialStateTests {

    // MARK: Single-knob derivation

    @Test("EQ settings persisted for this app land in TapInitialState.eqSettings")
    func eqSettingsAreCarried() throws {
        let fix = makeFixture()
        let custom = EQSettings(bandGains: [3, 0, -2, 0, 0, 0, 0, 0, 0, 4], isEnabled: true)
        fix.settings.setEQSettings(custom, for: fix.app.persistenceIdentifier)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.eqSettings == custom)
    }

    @Test("autoEQPreampEnabled mirrors settingsManager.autoEQPreampEnabled",
          arguments: [true, false])
    func autoEQPreampEnabledMirrored(value: Bool) throws {
        let fix = makeFixture()
        fix.settings.autoEQPreampEnabled = value

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQPreampEnabled == value)
    }

    @Test("loudnessCompensationEnabled mirrors appSettings.loudnessCompensationEnabled",
          arguments: [true, false])
    func loudnessCompensationFlagMirrored(value: Bool) throws {
        let fix = makeFixture()
        var s = fix.settings.appSettings
        s.loudnessCompensationEnabled = value
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.loudnessCompensationEnabled == value)
    }

    @Test("loudnessEqualizerSettings.enabled mirrors appSettings.loudnessEqualizationEnabled",
          arguments: [true, false])
    func loudnessEqualizerFlagMirrored(value: Bool) throws {
        let fix = makeFixture()
        var s = fix.settings.appSettings
        s.loudnessEqualizationEnabled = value
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.loudnessEqualizerSettings.enabled == value)
    }

    @Test("loudnessVolume = currentDeviceVolume × per-app volume")
    func loudnessVolumeIsProduct() throws {
        let fix = makeFixture(deviceVolume: 0.5)
        fix.engine.volumeState.setVolume(for: fix.app.id, to: 0.4, identifier: fix.app.persistenceIdentifier)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        // applyTapOutputState() runs before tapInitialState() is built, so
        // currentDeviceVolume is 0.5 (from MockDeviceVolumeProviding.volumes).
        // loudnessVolume should be deviceVolume (0.5) × appVolume (0.4) = 0.2.
        #expect(abs(snap.loudnessVolume - 0.2) < 1e-6)
    }

    // MARK: AutoEQ profile resolution

    @Test("autoEQProfile is nil when the device does not support AutoEQ")
    func autoEQNilForUnsupportedDevice() throws {
        let fix = makeFixture(supportsAutoEQ: false)
        // Even if a selection exists, an unsupported device must skip AutoEQ.
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "any-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when no selection is persisted for the device")
    func autoEQNilWithNoSelection() throws {
        let fix = makeFixture(supportsAutoEQ: true)
        // Don't set any selection.

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when the selection is disabled")
    func autoEQNilWhenSelectionDisabled() throws {
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "any-id", isEnabled: false)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    @Test("autoEQProfile is nil when selection is enabled but profile is not in the cache")
    func autoEQNilWhenProfileNotCached() throws {
        // Default AutoEQProfileManager has no profiles cached for "missing-id".
        // The pre-activate synchronous lookup must return nil so that
        // ensureTapExists falls through to the async resolve branch.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.autoEQProfileID == nil)
    }

    // MARK: Ordering / post-activation behaviour

    @Test("activate(initial:) is the first event the controller observes")
    func activateIsFirstEvent() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let firstEvent = try #require(tap.events.first)
        if case .activate = firstEvent {
            // ok
        } else {
            Issue.record("First event was \(firstEvent), expected .activate")
        }
    }

    @Test("No EQ/AutoEQ/Loudness mutation runs BEFORE activate(initial:) — the apply-initial-state contract")
    func noMutationBeforeActivate() throws {
        // The core PR-1 invariant: every processor-state knob the audio thread
        // can observe must be set via TapInitialState, not via post-construction
        // calls that race with AudioDeviceStart. We assert this by checking
        // that no .updateEQSettings / .updateAutoEQProfile / .setAutoEQPreampEnabled
        // / .updateLoudnessCompensation / .updateLoudnessEqualization is recorded
        // BEFORE the .activate event in the tap's event log.
        //
        // Exercises a realistic config (AutoEQ-capable device with an enabled
        // selection whose profile is uncached) so applyAutoEQToTap runs
        // post-activate — proving the engine's fallback path doesn't accidentally
        // fire before activate.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )
        let custom = EQSettings(bandGains: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1], isEnabled: true)
        fix.settings.setEQSettings(custom, for: fix.app.persistenceIdentifier)
        var s = fix.settings.appSettings
        s.loudnessCompensationEnabled = true
        s.loudnessEqualizationEnabled = true
        fix.settings.updateAppSettings(s)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        let activateIndex = try #require(tap.events.firstIndex { event in
            if case .activate = event { return true }
            return false
        })

        for event in tap.events.prefix(activateIndex) {
            switch event {
            case .updateEQSettings, .updateDeviceEQSettings, .updateEffectChain, .updateAutoEQProfile, .setAutoEQPreampEnabled,
                 .updateLoudnessCompensation, .updateLoudnessEqualization:
                Issue.record("Pre-activate mutation breaks the apply-initial-state contract: \(event)")
            case .activate, .invalidate:
                break
            }
        }
    }

    @Test("Cache-miss AutoEQ: applyAutoEQToTap fires its sync nil-set after activate")
    func cacheMissTriggersPostActivateNilSet() throws {
        // Device supports AutoEQ + selection is enabled but profile is missing
        // from cache → ensureTapExists calls applyAutoEQToTap, which sets the
        // profile to nil synchronously before kicking off async resolution.
        // Verifies the engine's fallback path is reached when (and only when)
        // the synchronous pre-activate lookup misses.
        let fix = makeFixture(supportsAutoEQ: true)
        fix.settings.setAutoEQSelection(
            for: fix.device.uid,
            to: AutoEQSelection(profileID: "missing-id", isEnabled: true)
        )

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let tap = try #require(fix.lastTap())
        // The first event must still be .activate (apply-initial-state ordering)
        if case .activate = tap.events.first {
            // ok
        } else {
            Issue.record("activate(initial:) was not first event")
        }
        // A post-activate updateAutoEQProfile(nil) must be present from
        // applyAutoEQToTap's sync nil-set on cache miss.
        let postActivateAutoEQ = tap.events.dropFirst().compactMap { event -> String?? in
            if case let .updateAutoEQProfile(id) = event { return Optional(id) }
            return nil
        }
        #expect(postActivateAutoEQ.contains(where: { $0 == nil }))
    }
}

// MARK: - Helpers

@MainActor
private func capturedInitial(_ fix: Fixture) -> RecordingProcessTapController.TapInitialStateSnapshot? {
    guard let tap = fix.lastTap() else { return nil }
    for event in tap.events {
        if case let .activate(snapshot) = event { return snapshot }
    }
    return nil
}

// MARK: - Mock contract

@Suite("RecordingProcessTapController — protocol contract")
@MainActor
struct RecordingProcessTapControllerContractTests {
    @Test("Mock records activate, then mutation events, in invocation order")
    func recordsCallOrder() throws {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        try tap.activate(initial: TapInitialState())
        tap.updateEQSettings(EQSettings.flat)
        tap.updateAutoEQProfile(nil)

        #expect(tap.events.count == 3)
        if case .activate = tap.events[0] {} else { Issue.record("expected .activate at 0") }
        if case .updateEQSettings = tap.events[1] {} else { Issue.record("expected .updateEQSettings at 1") }
        if case .updateAutoEQProfile = tap.events[2] {} else { Issue.record("expected .updateAutoEQProfile at 2") }
    }

    @Test("Default property values match real controller defaults")
    func defaultsMatchProductionController() {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        // ProcessTapController's nonisolated(unsafe) defaults from source.
        #expect(tap.volume == 1.0)
        #expect(tap.isMuted == false)
        #expect(tap.currentDeviceVolume == 1.0)
        #expect(tap.isDeviceMuted == false)
        #expect(tap.audioLevel == 0.0)
        #expect(tap.tapSourceDeviceUID == nil)
        #expect(tap.currentDeviceUID == "uid")
    }

    @Test("Backward-compatible activate() convenience routes through activate(initial:)")
    func convenienceActivateRoutesThroughInitial() throws {
        let app = AudioApp(
            id: 1,
            processObjectIDs: [],
            name: "X",
            icon: NSImage(),
            bundleID: "com.x"
        )
        let tap = RecordingProcessTapController(app: app, deviceUIDs: ["uid"])

        // Convenience extension on the protocol: should funnel through activate(initial:)
        // with a default TapInitialState — proves no caller can sneak around the
        // initial-state contract by calling the old no-arg overload.
        try tap.activate()
        if case let .activate(snap) = tap.events.first {
            #expect(snap.autoEQProfileID == nil)
            #expect(snap.loudnessCompensationEnabled == false)
            #expect(snap.loudnessEqualizerSettings.enabled == false)
            #expect(snap.autoEQPreampEnabled == false)
            #expect(snap.eqSettings == EQSettings.flat)
            #expect(snap.loudnessVolume == 1.0)
        } else {
            Issue.record("activate() did not record an .activate event")
        }
    }
}

// MARK: - Per-device EQ

@Suite("AudioEngine — per-output-device EQ")
@MainActor
struct AudioEngineDeviceEQTests {
    private let curve = EQSettings(bandGains: [6, 4, 0, 0, -2, 0, 0, 0, 3, 5], isEnabled: true)

    private func lastDeviceEQ(_ tap: RecordingProcessTapController) -> EQSettings? {
        for event in tap.events.reversed() {
            if case let .updateDeviceEQSettings(settings) = event { return settings }
        }
        return nil
    }

    @Test("a device's saved EQ lands in TapInitialState for taps on that device")
    func initialStateCarriesDeviceEQ() throws {
        let fix = makeFixture()
        fix.settings.setDeviceEQSettings(curve, for: fix.device.uid)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.deviceEQSettings == curve)
        #expect(snap.eqSettings == .flat)  // per-app EQ stays independent
    }

    @Test("changing a device's EQ persists it and updates taps playing to that device")
    func setPushesToTapsOnDevice() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())

        fix.engine.setDeviceEQSettings(curve, for: fix.device.uid)

        #expect(lastDeviceEQ(tap) == curve)
        #expect(fix.engine.getDeviceEQSettings(for: fix.device.uid) == curve)
    }

    @Test("another device's EQ doesn't touch taps on this device")
    func otherDeviceIgnored() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())

        fix.engine.setDeviceEQSettings(curve, for: "some-other-device")

        #expect(lastDeviceEQ(tap) == nil)
    }

    @Test("a tap fanned out to several devices gets a flat device EQ")
    func multiDeviceTapIsFlat() async throws {
        let fix = makeFixture()
        let second = AudioDevice(id: AudioDeviceID(100), uid: "uid-second", name: "Second", icon: nil, supportsAutoEQ: false)
        fix.deviceMonitor.addOutputDevice(second)
        fix.settings.setDeviceEQSettings(curve, for: fix.device.uid)

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        fix.engine.setSelectedDeviceUIDs(for: fix.app, to: [fix.device.uid, second.uid])
        fix.engine.setDeviceSelectionMode(for: fix.app, to: .multi)

        let deadline = ContinuousClock.now + .seconds(5)
        while fix.lastTap()?.currentDeviceUIDs.count != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let multiTap = try #require(fix.lastTap())
        try #require(multiTap.currentDeviceUIDs.count == 2)

        fix.engine.setDeviceEQSettings(curve, for: fix.device.uid)
        #expect(lastDeviceEQ(multiTap) == .flat)
        _ = tap
    }
}

// MARK: - Effect chains

@Suite("AudioEngine — Audio Unit effect chains")
@MainActor
struct AudioEngineEffectChainTests {
    private let delay = AudioEffectSlot(
        component: AudioEffectComponent(type: kAudioUnitType_Effect, subType: kAudioUnitSubType_Delay, manufacturer: kAudioUnitManufacturer_Apple),
        name: "AUDelay"
    )

    private func lastChain(_ tap: RecordingProcessTapController, stage: EffectChainStage) -> [UUID]? {
        for event in tap.events.reversed() {
            if case let .updateEffectChain(eventStage, ids) = event, eventStage == stage { return ids }
        }
        return nil
    }

    @Test("saved app and device chains land in TapInitialState")
    func initialStateCarriesChains() throws {
        let fix = makeFixture()
        let deviceSlot = AudioEffectSlot(component: delay.component, name: "Device delay")
        fix.settings.setEffectChain([delay], for: .app(identifier: fix.app.persistenceIdentifier))
        fix.settings.setEffectChain([deviceSlot], for: .device(uid: fix.device.uid))

        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)

        let snap = try #require(capturedInitial(fix))
        #expect(snap.appEffectIDs == [delay.id])
        #expect(snap.deviceEffectIDs == [deviceSlot.id])
    }

    @Test("an app chain change persists and reaches that app's tap")
    func appChainPushed() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())

        fix.engine.setEffectChain([delay], for: .app(identifier: fix.app.persistenceIdentifier))

        #expect(lastChain(tap, stage: .app) == [delay.id])
        #expect(fix.engine.getEffectChain(for: .app(identifier: fix.app.persistenceIdentifier)).map(\.id) == [delay.id])
    }

    @Test("a device chain change reaches taps on that device only")
    func deviceChainPushed() throws {
        let fix = makeFixture()
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())

        fix.engine.setEffectChain([delay], for: .device(uid: "another-device"))
        #expect(lastChain(tap, stage: .device) == nil)

        fix.engine.setEffectChain([delay], for: .device(uid: fix.device.uid))
        #expect(lastChain(tap, stage: .device) == [delay.id])
    }

    @Test("saving an effect's state updates the stored slot")
    func saveStatePersists() throws {
        let fix = makeFixture()
        let owner = EffectChainOwner.app(identifier: fix.app.persistenceIdentifier)
        fix.engine.setEffectChain([delay], for: owner)
        let state = Data([1, 2, 3])

        fix.engine.saveEffectState(state, owner: owner, slotID: delay.id, applyToRunning: false)

        #expect(fix.engine.getEffectChain(for: owner).first?.state == state)
    }
}

// FineTuneTests/AudioEngineIdleTapTests.swift
//
// Idle taps are suspended (not destroyed) while the app's process lives, resumed when it
// plays again, and destroyed only when the process exits. Destroying on idle caused a
// full-volume blip on resume while the replacement tap was being built.

import Testing
import Foundation
import AppKit
import AudioToolbox
@testable import FineTune

@MainActor
private final class SuspendableTap: ProcessTapControlling {
    enum Event: Equatable { case activate, suspend, resume, invalidate, switchDevice([String]) }

    let app: AudioApp
    private(set) var events: [Event] = []
    private(set) var isSuspended = false
    var resumeSucceeds = true

    var volume: Float = 1.0
    var isMuted: Bool = false
    var currentDeviceVolume: Float = 1.0
    var isDeviceMuted: Bool = false
    var audioLevel: Float = 0
    private(set) var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String? = nil

    init(app: AudioApp, deviceUIDs: [String]) {
        self.app = app
        self.currentDeviceUIDs = deviceUIDs
    }

    func activate(initial: TapInitialState) throws { events.append(.activate) }
    func invalidate() { events.append(.invalidate) }
    func suspend() { isSuspended = true; events.append(.suspend) }
    func resume() -> Bool {
        isSuspended = false
        events.append(.resume)
        return resumeSucceeds
    }
    func updateEQSettings(_ settings: EQSettings) {}
    func updateAutoEQProfile(_ profile: AutoEQProfile?) {}
    func setAutoEQPreampEnabled(_ enabled: Bool) {}
    func updateLoudnessCompensation(volume: Float, enabled: Bool) {}
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {}
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = [newDeviceUID]
        events.append(.switchDevice([newDeviceUID]))
    }
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws {
        currentDeviceUIDs = newDeviceUIDs
        events.append(.switchDevice(newDeviceUIDs))
    }
    func hasRecentAudioCallback(within seconds: Double) -> Bool { true }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { false }
}

@MainActor
private final class LivenessProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?
    var liveProcessObjectIDs: Set<AudioObjectID>? = []
    func start() {}
    func stop() {}

    func publish() { onAppsChanged?(activeApps) }
}

@MainActor
private final class IdleFixture {
    let engine: AudioEngine
    let settings: SettingsManager
    let monitor = LivenessProcessMonitor()
    let deviceMonitor = MockAudioDeviceMonitor()
    let volume: MockDeviceVolumeProviding
    let app = AudioApp(id: 4242, processObjectIDs: [777], name: "Player", icon: NSImage(), bundleID: "com.test.player")
    let speakers = AudioDevice(id: AudioDeviceID(10), uid: "uid-speakers", name: "Speakers", icon: nil, supportsAutoEQ: false)
    let headphones = AudioDevice(id: AudioDeviceID(11), uid: "uid-headphones", name: "Headphones", icon: nil, supportsAutoEQ: false)


    init() {
        settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        deviceMonitor.addOutputDevice(speakers)
        deviceMonitor.addOutputDevice(headphones)
        volume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        volume.defaultDeviceID = speakers.id
        volume.defaultDeviceUID = speakers.uid

        let permission = AudioRecordingPermission()
        permission.status = .authorized

        let box = Box()
        engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(),
            deviceProvider: deviceMonitor,
            processMonitor: monitor,
            deviceVolumeMonitor: volume,
            tapFactory: { app, uids, _ in
                let tap = SuspendableTap(app: app, deviceUIDs: uids)
                box.taps.append(tap)
                return tap
            },
            startMonitorsAutomatically: false
        )
        self.box = box
        engine.idleTapSuspendDelay = .milliseconds(10)
        engine.idleTapDestroyDelayWithoutLiveness = .milliseconds(10)
    }

    private let box: Box
    private final class Box { var taps: [SuspendableTap] = [] }

    var allTaps: [SuspendableTap] { box.taps }

    func play() {
        monitor.liveProcessObjectIDs?.insert(777)
        monitor.activeApps = [app]
        monitor.publish()
    }

    func pause() {
        monitor.activeApps = []
        monitor.publish()
    }

    func quit() {
        monitor.activeApps = []
        monitor.liveProcessObjectIDs?.remove(777)
        monitor.publish()
    }

    /// Covers the 350 ms stale-cleanup debounce plus the (shortened) idle delay.
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }
}

@Suite("AudioEngine idle tap suspension")
@MainActor
struct AudioEngineIdleTapTests {
    @Test("taps are created with .muted so a stopped tap still silences the app")
    func mutedBehavior() {
        #expect(ProcessTapController.tapMuteBehavior == .muted)
    }

    @Test("an idle app's tap is suspended, not destroyed")
    func idleSuspends() async throws {
        let fix = IdleFixture()
        fix.play()
        let tap = try #require(fix.allTaps.first)

        fix.pause()
        try await fix.settle()

        #expect(tap.isSuspended)
        #expect(!tap.events.contains(.invalidate))
        #expect(fix.allTaps.count == 1)
    }

    @Test("a returning app resumes its existing tap instead of building a new one")
    func returningResumes() async throws {
        let fix = IdleFixture()
        fix.play()
        fix.pause()
        try await fix.settle()

        fix.play()
        let tap = try #require(fix.allTaps.first)
        #expect(!tap.isSuspended)
        #expect(tap.events.last == .resume)
        #expect(fix.allTaps.count == 1)
    }

    @Test("resume applies volume changed while the app was idle")
    func resumeAppliesIdleVolume() async throws {
        let fix = IdleFixture()
        fix.play()
        fix.pause()
        try await fix.settle()

        fix.engine.setVolumeForInactive(identifier: fix.app.persistenceIdentifier, to: 0.25)
        fix.play()

        let tap = try #require(fix.allTaps.first)
        #expect(tap.volume == 0.25)
    }

    @Test("quitting the app destroys its idle tap")
    func exitDestroys() async throws {
        let fix = IdleFixture()
        fix.play()
        fix.pause()
        try await fix.settle()

        fix.quit()
        try await fix.settle()

        let tap = try #require(fix.allTaps.first)
        #expect(tap.events.last == .invalidate)
    }

    @Test("a quick pause/resume never suspends")
    func flickerDoesNotSuspend() async throws {
        let fix = IdleFixture()
        fix.engine.idleTapSuspendDelay = .seconds(5)
        fix.play()
        fix.pause()
        fix.play()
        try await fix.settle()

        let tap = try #require(fix.allTaps.first)
        #expect(!tap.events.contains(.suspend))
    }

    @Test("default device changed while idle: tap is moved on resume")
    func reroutesOnResume() async throws {
        let fix = IdleFixture()
        fix.play()
        fix.pause()
        try await fix.settle()

        fix.volume.defaultDeviceID = fix.headphones.id
        fix.volume.defaultDeviceUID = fix.headphones.uid
        fix.play()
        try await Task.sleep(for: .milliseconds(50))

        let tap = try #require(fix.allTaps.first)
        #expect(tap.currentDeviceUIDs == [fix.headphones.uid])
        #expect(fix.allTaps.count == 1)
    }

    @Test("without liveness info, idle taps fall back to delayed destruction")
    func legacyFallback() async throws {
        let fix = IdleFixture()
        fix.monitor.liveProcessObjectIDs = nil
        fix.play()
        fix.pause()
        try await fix.settle()

        let tap = try #require(fix.allTaps.first)
        #expect(tap.events.contains(.invalidate))
        #expect(!tap.events.contains(.suspend))
    }
}

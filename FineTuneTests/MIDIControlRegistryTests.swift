// FineTuneTests/MIDIControlRegistryTests.swift
import AppKit
import AudioToolbox
import CoreMIDI
import Testing
import Foundation
@testable import FineTune

@MainActor
private final class FakeMIDIInput: MIDIInputProviding {
    var onMessages: (([ReceivedMIDIMessage]) -> Void)?
    var sourceNames: [String] = []
    private(set) var isRunning = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
    func sourceName(for sourceID: MIDIEndpointRef) -> String? { nil }

    func send(_ messages: MIDIMessage...) {
        onMessages?(messages.map { ReceivedMIDIMessage(message: $0, sourceID: 1) })
    }
}

@MainActor
private final class FakeAppAudio: MIDIAppAudioControlling {
    var apps: [AudioApp] = []
    var volumes: [pid_t: Float] = [:]
    var mutes: [pid_t: Bool] = [:]
    var inactiveVolumes: [String: Float] = [:]
    var inactiveMutes: [String: Bool] = [:]
    var setVolumeCalls = 0

    func setVolume(for app: AudioApp, to volume: Float) { volumes[app.id] = volume; setVolumeCalls += 1 }
    func setMute(for app: AudioApp, to muted: Bool) { mutes[app.id] = muted }
    func isMuted(for app: AudioApp) -> Bool { mutes[app.id] ?? false }
    func setVolumeForInactive(identifier: String, to volume: Float) { inactiveVolumes[identifier] = volume }
    func getMuteForInactive(identifier: String) -> Bool { inactiveMutes[identifier] ?? false }
    func setMuteForInactive(identifier: String, to muted: Bool) { inactiveMutes[identifier] = muted }
}

@MainActor
private final class FakeSystemVolume: MIDISystemVolumeControlling {
    var defaultDeviceID: AudioDeviceID = 42
    var tier: VolumeControlTier = .hardware
    var volumes: [AudioDeviceID: Float] = [:]
    var muteStates: [AudioDeviceID: Bool] = [:]
    var volumeWrites: [Float] = []

    func setVolume(for deviceID: AudioDeviceID, to volume: Float) { volumes[deviceID] = volume; volumeWrites.append(volume) }
    func setMute(for deviceID: AudioDeviceID, to muted: Bool) { muteStates[deviceID] = muted }
    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier { tier }
}

@MainActor
private final class FakeHUD: MediaKeyHUDPresenting {
    struct Shown: Equatable { let sliderFraction: Double; let mute: Bool; let deviceName: String }
    var shown: [Shown] = []
    func show(sliderFraction: Double, mute: Bool, deviceName: String) {
        shown.append(Shown(sliderFraction: sliderFraction, mute: mute, deviceName: deviceName))
    }
    func swallowObserved() {}
}

@MainActor
private final class FakeAppHUD: MIDIAppHUDPresenting {
    enum Shown: Equatable {
        case volume(title: String, hasIcon: Bool, sliderFraction: Double)
        case mute(title: String, hasIcon: Bool, isMuted: Bool)
    }
    var shown: [Shown] = []
    func showMIDIAppVolumeHUD(icon: NSImage?, title: String, sliderFraction: Double) {
        shown.append(.volume(title: title, hasIcon: icon != nil, sliderFraction: sliderFraction))
    }
    func showMIDIAppMuteHUD(icon: NSImage?, title: String, isMuted: Bool) {
        shown.append(.mute(title: title, hasIcon: icon != nil, isMuted: isMuted))
    }
}

@Suite("MIDIControlRegistry")
@MainActor
struct MIDIControlRegistryTests {
    let settings: SettingsManager
    fileprivate let input = FakeMIDIInput()
    fileprivate let audio = FakeAppAudio()
    fileprivate let system = FakeSystemVolume()
    fileprivate let hud = FakeHUD()
    fileprivate let appHUD = FakeAppHUD()
    let registry: MIDIControlRegistry

    let fader = MIDIMessage.controlChange(channel: 0, controller: 7, value: 127)
    let button = MIDIMessage.noteOn(channel: 0, note: 36, velocity: 100)
    let spotify = AudioApp(id: 100, processObjectIDs: [], name: "Spotify", icon: NSImage(), bundleID: "com.spotify.client")

    init() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        settings = SettingsManager(directory: dir)
        registry = MIDIControlRegistry(settings: settings, input: input, appAudio: audio, systemVolume: system)
        registry.hud = hud
        registry.deviceNameProvider = { $0 == 42 ? "Speakers" : "" }
        registry.appHUD = appHUD
        registry.iconProvider = { $0 == "bundle" ? NSImage() : nil }
    }

    private func learn(_ target: MIDITarget, _ slot: MIDIControlSlot, with message: MIDIMessage) {
        registry.beginLearning(target: target, slot: slot, displayName: "Name", bundleID: "bundle")
        input.send(message)
    }

    @Test("reconcile follows the enabled setting")
    func reconcile() {
        registry.reconcile()
        #expect(input.isRunning)
        settings.appSettings.midiControlEnabled = false
        registry.reconcile()
        #expect(!input.isRunning)
    }

    @Test("learning captures the binding without firing it")
    func learnCaptures() {
        audio.apps = [spotify]
        learn(.app(identifier: "com.spotify.client"), .volume, with: fader)

        let mapping = registry.mapping(for: .app(identifier: "com.spotify.client"))
        #expect(mapping?.volume == fader.binding)
        #expect(mapping?.displayName == "Name")
        #expect(registry.learning == nil)
        #expect(audio.setVolumeCalls == 0)
    }

    @Test("volume learning ignores notes and keeps listening")
    func volumeLearnIgnoresNotes() {
        registry.beginLearning(target: .systemOutput, slot: .volume)
        input.send(button)
        #expect(registry.learning != nil)
        #expect(registry.mapping(for: .systemOutput) == nil)
    }

    @Test("CC maps to 0–100% on the app slider curve")
    func appVolume() {
        audio.apps = [spotify]
        learn(.app(identifier: "com.spotify.client"), .volume, with: fader)

        input.send(.controlChange(channel: 0, controller: 7, value: 127))
        #expect(audio.volumes[100] == 1.0)

        input.send(.controlChange(channel: 0, controller: 7, value: 0))
        #expect(audio.volumes[100] == 0.0)

        input.send(.controlChange(channel: 0, controller: 7, value: 64))
        let expected = VolumeMapping.sliderToGain(64.0 / 127.0)
        #expect(audio.volumes[100] == expected)
    }

    @Test("other channels and controllers don't match")
    func noCrossTalk() {
        audio.apps = [spotify]
        learn(.app(identifier: "com.spotify.client"), .volume, with: fader)
        input.send(.controlChange(channel: 1, controller: 7, value: 10))
        input.send(.controlChange(channel: 0, controller: 8, value: 10))
        #expect(audio.setVolumeCalls == 0)
    }

    @Test("a burst within one batch writes once with the final value")
    func coalescesBatch() {
        audio.apps = [spotify]
        learn(.app(identifier: "com.spotify.client"), .volume, with: fader)
        input.send(
            .controlChange(channel: 0, controller: 7, value: 10),
            .controlChange(channel: 0, controller: 7, value: 20),
            .controlChange(channel: 0, controller: 7, value: 127)
        )
        #expect(audio.setVolumeCalls == 1)
        #expect(audio.volumes[100] == 1.0)
    }

    @Test("volume for a non-running app persists via the inactive path")
    func inactiveAppVolume() {
        learn(.app(identifier: "com.spotify.client"), .volume, with: fader)
        input.send(.controlChange(channel: 0, controller: 7, value: 127))
        #expect(audio.inactiveVolumes["com.spotify.client"] == 1.0)
    }

    @Test("toggle mute flips on each press and ignores releases")
    func toggleMute() {
        audio.apps = [spotify]
        learn(.app(identifier: "com.spotify.client"), .mute, with: button)

        input.send(button)
        #expect(audio.mutes[100] == true)
        input.send(.noteOff(channel: 0, note: 36))
        #expect(audio.mutes[100] == true)
        input.send(button)
        #expect(audio.mutes[100] == false)
    }

    @Test("follow-value mute tracks a latching CC button")
    func followMute() {
        audio.apps = [spotify]
        let cc = MIDIMessage.controlChange(channel: 2, controller: 20, value: 127)
        learn(.app(identifier: "com.spotify.client"), .mute, with: cc)
        registry.setMuteMode(.followValue, for: .app(identifier: "com.spotify.client"))

        input.send(.controlChange(channel: 2, controller: 20, value: 127))
        input.send(.controlChange(channel: 2, controller: 20, value: 127))
        #expect(audio.mutes[100] == true)
        input.send(.controlChange(channel: 2, controller: 20, value: 0))
        #expect(audio.mutes[100] == false)
    }

    @Test("system volume uses the device's tier mapping and system mute toggles")
    func systemOutput() {
        system.tier = .software
        learn(.systemOutput, .volume, with: fader)
        learn(.systemOutput, .mute, with: button)

        input.send(.controlChange(channel: 0, controller: 7, value: 64))
        #expect(system.volumes[42] == VolumeMapping.systemGain(forSliderFraction: 64.0 / 127.0, tier: .software))

        input.send(button)
        #expect(system.muteStates[42] == true)
        input.send(button)
        #expect(system.muteStates[42] == false)
    }

    @Test("DDC system volume is throttled but lands on the final value")
    func ddcThrottle() async throws {
        system.tier = .ddc
        learn(.systemOutput, .volume, with: fader)

        input.send(.controlChange(channel: 0, controller: 7, value: 10))
        input.send(.controlChange(channel: 0, controller: 7, value: 50))
        input.send(.controlChange(channel: 0, controller: 7, value: 127))
        #expect(system.volumeWrites.count == 1)

        try await Task.sleep(for: .milliseconds(200))
        #expect(system.volumeWrites.count == 2)
        #expect(system.volumeWrites.last == 1.0)
    }

    @Test("learning a control already bound elsewhere moves it")
    func learnMovesBinding() {
        learn(.systemOutput, .volume, with: fader)
        learn(.app(identifier: "com.spotify.client"), .volume, with: fader)

        #expect(registry.mapping(for: .systemOutput) == nil)
        #expect(registry.mapping(for: .app(identifier: "com.spotify.client"))?.volume == fader.binding)
    }

    @Test("clearing the last binding removes the mapping")
    func clearBinding() {
        learn(.systemOutput, .volume, with: fader)
        registry.clearBinding(for: .systemOutput, slot: .volume)
        #expect(registry.mapping(for: .systemOutput) == nil)
        #expect(settings.appSettings.midiMappings.isEmpty)
    }

    @Test("disabled MIDI control ignores bound messages")
    func disabled() {
        audio.apps = [spotify]
        learn(.app(identifier: "com.spotify.client"), .volume, with: fader)
        settings.appSettings.midiControlEnabled = false
        input.send(fader)
        #expect(audio.setVolumeCalls == 0)
    }

    @Test("system volume and mute from MIDI show the HUD")
    func systemShowsHUD() {
        system.tier = .software
        learn(.systemOutput, .volume, with: fader)
        learn(.systemOutput, .mute, with: button)

        input.send(.controlChange(channel: 0, controller: 7, value: 64))
        #expect(hud.shown.last == .init(sliderFraction: 64.0 / 127.0, mute: false, deviceName: "Speakers"))

        input.send(button)
        #expect(hud.shown.count == 2)
        #expect(hud.shown.last?.mute == true)
        #expect(hud.shown.last?.deviceName == "Speakers")
    }

    @Test("a fader burst shows the system HUD once; per-app controls use the app HUD")
    func hudScope() {
        audio.apps = [spotify]
        learn(.systemOutput, .volume, with: fader)
        input.send(
            .controlChange(channel: 0, controller: 7, value: 10),
            .controlChange(channel: 0, controller: 7, value: 127)
        )
        #expect(hud.shown.count == 1)
        #expect(hud.shown.last?.sliderFraction == 1.0)

        learn(.app(identifier: "com.spotify.client"), .volume, with: fader)
        input.send(.controlChange(channel: 0, controller: 7, value: 30))
        #expect(hud.shown.count == 1)
        #expect(appHUD.shown.count == 1)
    }

    @Test("running app volume and mute show the app HUD with its name and icon")
    func runningAppHUD() {
        audio.apps = [spotify]
        learn(.app(identifier: "com.spotify.client"), .volume, with: fader)
        learn(.app(identifier: "com.spotify.client"), .mute, with: button)

        input.send(.controlChange(channel: 0, controller: 7, value: 127))
        #expect(appHUD.shown.last == .volume(title: "Spotify", hasIcon: true, sliderFraction: 1.0))

        input.send(button)
        #expect(appHUD.shown.last == .mute(title: "Spotify", hasIcon: true, isMuted: true))
        #expect(hud.shown.isEmpty)
    }

    @Test("a non-running app's HUD uses the name and icon remembered at learn time")
    func inactiveAppHUD() {
        learn(.app(identifier: "com.spotify.client"), .volume, with: fader)
        learn(.app(identifier: "com.spotify.client"), .mute, with: button)

        input.send(.controlChange(channel: 0, controller: 7, value: 0))
        #expect(appHUD.shown.last == .volume(title: "Name", hasIcon: true, sliderFraction: 0))

        input.send(button)
        #expect(appHUD.shown.last == .mute(title: "Name", hasIcon: true, isMuted: true))
    }
}

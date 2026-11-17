// FineTuneTests/MIDIMessageParserTests.swift
import Testing
import Foundation
@testable import FineTune

@Suite("MIDIMessageParser")
struct MIDIMessageParserTests {
    /// Builds a UMP MIDI 1.0 channel-voice word (message type 0x2, group 0).
    private func ump(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) -> UInt32 {
        (0x2 << 28) | (UInt32(status) << 16) | (UInt32(d1) << 8) | UInt32(d2)
    }

    @Test("decodes control change with channel")
    func controlChange() {
        #expect(MIDIMessageParser.parseMIDI1ChannelVoice(ump(0xB3, 7, 100))
                == .controlChange(channel: 3, controller: 7, value: 100))
    }

    @Test("decodes note on and note off")
    func notes() {
        #expect(MIDIMessageParser.parseMIDI1ChannelVoice(ump(0x90, 60, 127))
                == .noteOn(channel: 0, note: 60, velocity: 127))
        #expect(MIDIMessageParser.parseMIDI1ChannelVoice(ump(0x8F, 60, 64))
                == .noteOff(channel: 15, note: 60))
    }

    @Test("note on with velocity 0 is a note off")
    func noteOnZeroVelocity() {
        #expect(MIDIMessageParser.parseMIDI1ChannelVoice(ump(0x91, 36, 0))
                == .noteOff(channel: 1, note: 36))
    }

    @Test("ignores unsupported channel messages")
    func ignoresOthers() {
        #expect(MIDIMessageParser.parseMIDI1ChannelVoice(ump(0xE0, 0, 64)) == nil)  // pitch bend
        #expect(MIDIMessageParser.parseMIDI1ChannelVoice(ump(0xC0, 5, 0)) == nil)   // program change
    }

    @Test("walks mixed-size packets and skips non-channel-voice types")
    func mixedStream() {
        let words: [UInt32] = [
            0x10F8_0000,              // MT1 system real-time (clock), 1 word
            ump(0xB0, 1, 10),
            0x3000_0000, 0x0000_0000, // MT3 sysex7, 2 words
            0x4090_3C00, 0xFFFF_0000, // MT4 MIDI 2.0 note on, 2 words
            ump(0x90, 64, 90),
        ]
        #expect(MIDIMessageParser.parse(words: words) == [
            .controlChange(channel: 0, controller: 1, value: 10),
            .noteOn(channel: 0, note: 64, velocity: 90),
        ])
    }

    @Test("truncated trailing packet does not crash")
    func truncated() {
        let words: [UInt32] = [ump(0xB0, 1, 10), 0x5000_0000]  // MT5 claims 4 words
        #expect(MIDIMessageParser.parse(words: words) == [.controlChange(channel: 0, controller: 1, value: 10)])
    }
}

@Suite("MIDIValueMapping")
struct MIDIValueMappingTests {
    @Test("CC value maps endpoints to 0% and 100%")
    func ccEndpoints() {
        #expect(MIDIValueMapping.sliderFraction(forCCValue: 0) == 0)
        #expect(MIDIValueMapping.sliderFraction(forCCValue: 127) == 1)
        #expect(abs(MIDIValueMapping.sliderFraction(forCCValue: 64) - 0.5039) < 0.001)
    }

    @Test("toggle mode fires on press only")
    func toggleMode() {
        let press = MIDIValueMapping.muteAction(for: .controlChange(channel: 0, controller: 1, value: 127), mode: .toggle)
        let release = MIDIValueMapping.muteAction(for: .controlChange(channel: 0, controller: 1, value: 0), mode: .toggle)
        let noteOn = MIDIValueMapping.muteAction(for: .noteOn(channel: 0, note: 1, velocity: 1), mode: .toggle)
        let noteOff = MIDIValueMapping.muteAction(for: .noteOff(channel: 0, note: 1), mode: .toggle)
        #expect(press == .some(nil))
        #expect(release == nil)
        #expect(noteOn == .some(nil))
        #expect(noteOff == nil)
    }

    @Test("follow mode sets state from the value")
    func followMode() {
        #expect(MIDIValueMapping.muteAction(for: .controlChange(channel: 0, controller: 1, value: 127), mode: .followValue) == .some(true))
        #expect(MIDIValueMapping.muteAction(for: .controlChange(channel: 0, controller: 1, value: 63), mode: .followValue) == .some(false))
        #expect(MIDIValueMapping.muteAction(for: .noteOn(channel: 0, note: 1, velocity: 1), mode: .followValue) == .some(true))
        #expect(MIDIValueMapping.muteAction(for: .noteOff(channel: 0, note: 1), mode: .followValue) == .some(false))
    }

    @Test("volume learns only CC; mute never learns a release")
    func learnable() {
        #expect(MIDIValueMapping.isLearnable(.controlChange(channel: 0, controller: 7, value: 3), for: .volume))
        #expect(!MIDIValueMapping.isLearnable(.noteOn(channel: 0, note: 1, velocity: 1), for: .volume))
        #expect(MIDIValueMapping.isLearnable(.noteOn(channel: 0, note: 1, velocity: 1), for: .mute))
        #expect(!MIDIValueMapping.isLearnable(.noteOff(channel: 0, note: 1), for: .mute))
    }

    @Test("target storage keys round-trip")
    func targetKeys() {
        #expect(MIDITarget(storageKey: MIDITarget.systemOutput.storageKey) == .systemOutput)
        let app = MIDITarget.app(identifier: "com.spotify.client")
        #expect(MIDITarget(storageKey: app.storageKey) == app)
        #expect(MIDITarget(storageKey: "app:name:My App") == .app(identifier: "name:My App"))
        #expect(MIDITarget(storageKey: "app:") == nil)
        #expect(MIDITarget(storageKey: "bogus") == nil)
    }
}

@Suite("AppSettings MIDI")
@MainActor
struct AppSettingsMIDITests {
    @Test("round-trips mappings")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.midiControlEnabled = false
        settings.midiMappings["system"] = MIDITargetMapping(
            volume: MIDIBinding(kind: .controlChange, channel: 0, number: 7),
            mute: MIDIBinding(kind: .note, channel: 9, number: 36),
            muteMode: .followValue
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test("defaults when missing; malformed MIDI block doesn't break other settings")
    func defaultsAndMalformed() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"popupSize":"compact"}"#.utf8))
        #expect(legacy.midiControlEnabled)
        #expect(legacy.midiMappings.isEmpty)

        let malformed = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"hudStyle":"classic","midiMappings":{"system":{"volume":"nope"}}}"#.utf8)
        )
        #expect(malformed.midiMappings.isEmpty)
        #expect(malformed.hudStyle == .classic)
    }
}

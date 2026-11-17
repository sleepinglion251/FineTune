// FineTune/MIDI/MIDIBinding.swift
import Foundation

/// A decoded MIDI 1.0 channel-voice message FineTune cares about.
/// Everything else (pitch bend, aftertouch, sysex, clock…) is dropped by the parser.
nonisolated enum MIDIMessage: Equatable, Sendable {
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8)

    /// The binding a message would match, independent of its value.
    var binding: MIDIBinding {
        switch self {
        case .controlChange(let channel, let controller, _):
            MIDIBinding(kind: .controlChange, channel: channel, number: controller)
        case .noteOn(let channel, let note, _), .noteOff(let channel, let note):
            MIDIBinding(kind: .note, channel: channel, number: note)
        }
    }

    var displayString: String {
        switch self {
        case .controlChange(_, _, let value): "\(binding.displayString) = \(value)"
        case .noteOn(_, _, let velocity): "\(binding.displayString) on (\(velocity))"
        case .noteOff: "\(binding.displayString) off"
        }
    }
}

/// Identifies a physical control: message kind + channel + controller/note number.
/// Persisted in `settings.json`; field names are part of the storage contract.
nonisolated struct MIDIBinding: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case controlChange
        case note
    }

    let kind: Kind
    /// 0-based (0…15). Displayed 1-based.
    let channel: UInt8
    /// CC number or note number (0…127).
    let number: UInt8

    var displayString: String {
        switch kind {
        case .controlChange: "CC \(number) · Ch \(Int(channel) + 1)"
        case .note: "Note \(Self.noteName(number)) · Ch \(Int(channel) + 1)"
        }
    }

    /// Note name using the C3 = 60 convention most DAWs and controller editors use.
    static func noteName(_ note: UInt8) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let octave = Int(note) / 12 - 2
        return "\(names[Int(note) % 12])\(octave)"
    }
}

/// How a mute binding interprets incoming messages.
nonisolated enum MIDIMuteMode: String, Codable, CaseIterable, Sendable {
    /// Each press flips the mute state. Releases (CC < 64, note off) are ignored.
    /// Right for momentary buttons.
    case toggle
    /// Mute follows the control: CC ≥ 64 / note on → muted, CC < 64 / note off → unmuted.
    /// Right for latching buttons whose LED reflects state.
    case followValue

    var displayName: String {
        switch self {
        case .toggle: "Toggle on press"
        case .followValue: "Match button state"
        }
    }
}

/// Which slot of a target a binding drives.
nonisolated enum MIDIControlSlot: String, Codable, Sendable {
    case volume
    case mute
}

/// What a mapping controls.
nonisolated enum MIDITarget: Hashable, Sendable {
    /// The current default output device.
    case systemOutput
    /// A per-app channel, by `AudioApp.persistenceIdentifier`.
    case app(identifier: String)

    private static let systemKey = "system"
    private static let appPrefix = "app:"

    /// Key in `AppSettings.midiMappings`. Stable across releases.
    var storageKey: String {
        switch self {
        case .systemOutput: Self.systemKey
        case .app(let identifier): Self.appPrefix + identifier
        }
    }

    init?(storageKey: String) {
        if storageKey == Self.systemKey {
            self = .systemOutput
        } else if storageKey.hasPrefix(Self.appPrefix) {
            let identifier = String(storageKey.dropFirst(Self.appPrefix.count))
            guard !identifier.isEmpty else { return nil }
            self = .app(identifier: identifier)
        } else {
            return nil
        }
    }
}

/// The MIDI controls bound to one target.
nonisolated struct MIDITargetMapping: Codable, Equatable, Sendable {
    /// Remembered so the settings tab can list the app while it isn't running.
    var displayName: String?
    var bundleID: String?
    var volume: MIDIBinding?
    var mute: MIDIBinding?
    var muteMode: MIDIMuteMode = .toggle

    init(
        displayName: String? = nil,
        bundleID: String? = nil,
        volume: MIDIBinding? = nil,
        mute: MIDIBinding? = nil,
        muteMode: MIDIMuteMode = .toggle
    ) {
        self.displayName = displayName
        self.bundleID = bundleID
        self.volume = volume
        self.mute = mute
        self.muteMode = muteMode
    }

    var isEmpty: Bool { volume == nil && mute == nil }

    func binding(for slot: MIDIControlSlot) -> MIDIBinding? {
        switch slot {
        case .volume: volume
        case .mute: mute
        }
    }

    mutating func setBinding(_ binding: MIDIBinding?, for slot: MIDIControlSlot) {
        switch slot {
        case .volume: volume = binding
        case .mute: mute = binding
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        volume = try c.decodeIfPresent(MIDIBinding.self, forKey: .volume)
        mute = try c.decodeIfPresent(MIDIBinding.self, forKey: .mute)
        muteMode = (try? c.decodeIfPresent(MIDIMuteMode.self, forKey: .muteMode)) ?? .toggle
    }
}

/// Pure value-mapping rules, kept separate so they're trivially testable.
nonisolated enum MIDIValueMapping {
    /// 0…127 → 0.0…1.0 slider fraction (the same domain the popup's percentage shows).
    static func sliderFraction(forCCValue value: UInt8) -> Double {
        Double(min(value, 127)) / 127.0
    }

    /// Resolves what a mute binding should do with a message.
    /// - Returns: `nil` to ignore, `.some(nil)` to toggle, `.some(true/false)` to set.
    static func muteAction(for message: MIDIMessage, mode: MIDIMuteMode) -> Bool?? {
        switch (mode, message) {
        case (.toggle, .controlChange(_, _, let value)):
            return value >= 64 ? .some(nil) : nil
        case (.toggle, .noteOn):
            return .some(nil)
        case (.toggle, .noteOff):
            return nil
        case (.followValue, .controlChange(_, _, let value)):
            return .some(value >= 64)
        case (.followValue, .noteOn):
            return .some(true)
        case (.followValue, .noteOff):
            return .some(false)
        }
    }

    /// Whether a message may be captured while learning the given slot.
    /// Volume needs a continuous control (CC). Mute accepts a CC or a note press,
    /// but never a release, so pressing a button doesn't learn its note-off.
    static func isLearnable(_ message: MIDIMessage, for slot: MIDIControlSlot) -> Bool {
        switch (slot, message) {
        case (.volume, .controlChange): true
        case (.volume, _): false
        case (.mute, .controlChange), (.mute, .noteOn): true
        case (.mute, .noteOff): false
        }
    }
}

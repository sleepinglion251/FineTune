// FineTune/Audio/Effects/BuiltInEffectCatalog.swift
import AVFoundation
import AudioToolbox

/// Apple's built-in Audio Unit effects that can be added to an effect chain.
@MainActor
enum BuiltInEffectCatalog {
    struct Entry: Identifiable, Hashable {
        let component: AudioEffectComponent
        let name: String
        var id: AudioEffectComponent { component }
    }

    /// Effects that don't make sense in a playback chain: network streaming and
    /// codec round-trip test units.
    private static let excludedSubTypes: Set<UInt32> = [
        fourCC("nsnd"),  // AUNetSend
        fourCC("raac"),  // AURoundTripAAC
    ]

    /// Sorted by name. Cached after the first call; the system set doesn't change at runtime.
    static var entries: [Entry] {
        if let cached { return cached }
        let query = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let found = AVAudioUnitComponentManager.shared().components(matching: query)
            .filter { !excludedSubTypes.contains($0.audioComponentDescription.componentSubType) }
            .map { Entry(component: AudioEffectComponent($0.audioComponentDescription), name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cached = found
        return found
    }

    private static var cached: [Entry]?

    static func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

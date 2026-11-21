// FineTune/Models/AudioEffectSlot.swift
import AudioToolbox
import Foundation

/// Identifies an Audio Unit component. Stored instead of `AudioComponentDescription`
/// so it can be persisted and compared.
nonisolated struct AudioEffectComponent: Codable, Hashable, Sendable {
    var type: UInt32
    var subType: UInt32
    var manufacturer: UInt32

    init(type: UInt32, subType: UInt32, manufacturer: UInt32) {
        self.type = type
        self.subType = subType
        self.manufacturer = manufacturer
    }

    init(_ description: AudioComponentDescription) {
        self.init(
            type: description.componentType,
            subType: description.componentSubType,
            manufacturer: description.componentManufacturer
        )
    }

    var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: type,
            componentSubType: subType,
            componentManufacturer: manufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }
}

/// One effect in an app's or output device's effect chain.
nonisolated struct AudioEffectSlot: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var component: AudioEffectComponent
    var name: String
    var isBypassed: Bool
    /// The unit's `ClassInfo` (its full preset) as a binary property list. nil = defaults.
    var state: Data?

    init(id: UUID = UUID(), component: AudioEffectComponent, name: String, isBypassed: Bool = false, state: Data? = nil) {
        self.id = id
        self.component = component
        self.name = name
        self.isBypassed = isBypassed
        self.state = state
    }
}

/// Whose effect chain a slot belongs to.
nonisolated enum EffectChainOwner: Hashable, Sendable {
    /// Keyed by the app's persistence identifier (same key as per-app EQ).
    case app(identifier: String)
    /// Keyed by output device UID.
    case device(uid: String)
}

/// Which of a tap's two effect chains an operation targets.
nonisolated enum EffectChainStage: Sendable {
    case app
    case device
}

extension Array where Element == AudioEffectSlot {
    /// True when the chain would change the sound: at least one effect not bypassed.
    nonisolated var hasActiveEffects: Bool { contains { !$0.isBypassed } }
}

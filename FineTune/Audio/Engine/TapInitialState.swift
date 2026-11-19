// FineTune/Audio/Engine/TapInitialState.swift
import Foundation

/// Persisted settings applied to a fresh ProcessTapController before its IOProc starts.
struct TapInitialState {
    var eqSettings: EQSettings = .flat
    /// EQ for the output device the tap plays to (flat when routed to several devices).
    var deviceEQSettings: EQSettings = .flat
    var autoEQProfile: AutoEQProfile? = nil
    var autoEQPreampEnabled: Bool = false
    var loudnessVolume: Float = 1.0
    var loudnessCompensationEnabled: Bool = false
    var loudnessEqualizerSettings: LoudnessEqualizerSettings = .init()
}

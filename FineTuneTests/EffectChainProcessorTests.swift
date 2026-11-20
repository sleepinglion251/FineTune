// FineTuneTests/EffectChainProcessorTests.swift
//
// Renders real audio through Apple's built-in Audio Units via EffectChainProcessor.

import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@Suite("EffectChainProcessor")
struct EffectChainProcessorTests {
    private static let sampleRate = 48000.0
    private static let frames = 512

    private static func lowPass(bypassed: Bool = false) -> AudioEffectSlot {
        AudioEffectSlot(
            component: AudioEffectComponent(type: kAudioUnitType_Effect, subType: kAudioUnitSubType_LowPassFilter, manufacturer: kAudioUnitManufacturer_Apple),
            name: "AULowpass",
            isBypassed: bypassed
        )
    }

    /// Interleaved stereo tone at Nyquist (+1, -1, ...): a low-pass filter removes it.
    private static func nyquistTone() -> [Float] {
        (0..<frames * 2).map { index in (index / 2) % 2 == 0 ? 0.5 : -0.5 }
    }

    /// Runs several buffers so the filter settles, returning the last one's peak.
    private static func peakAfterProcessing(_ processor: EffectChainProcessor) -> Float {
        var peak: Float = 0
        for _ in 0..<8 {
            var samples = nyquistTone()
            samples.withUnsafeMutableBufferPointer { buffer in
                processor.process(buffer.baseAddress!, frameCount: frames)
            }
            peak = samples.map(abs).max() ?? 0
        }
        return peak
    }

    @Test("built-in catalog lists Apple effects and excludes NetSend")
    @MainActor
    func catalog() {
        let entries = BuiltInEffectCatalog.entries
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.component.manufacturer == kAudioUnitManufacturer_Apple })
        #expect(!entries.contains { $0.component.subType == BuiltInEffectCatalog.fourCC("nsnd") })
        #expect(entries.contains { $0.component.subType == kAudioUnitSubType_LowPassFilter })
    }

    @Test("an empty chain is inactive and leaves audio untouched")
    func emptyChain() {
        let processor = EffectChainProcessor(sampleRate: Self.sampleRate)
        #expect(!processor.isActive)
        #expect(Self.peakAfterProcessing(processor) == 0.5)
    }

    @Test("a low-pass effect removes a Nyquist tone")
    func lowPassFilters() {
        let processor = EffectChainProcessor(sampleRate: Self.sampleRate, slots: [Self.lowPass()])
        #expect(processor.isActive)
        #expect(Self.peakAfterProcessing(processor) < 0.05)
    }

    @Test("a bypassed effect passes audio through unchanged")
    func bypassPassesThrough() {
        let processor = EffectChainProcessor(sampleRate: Self.sampleRate, slots: [Self.lowPass(bypassed: true)])
        #expect(Self.peakAfterProcessing(processor) == 0.5)
    }

    @Test("toggling bypass takes effect without rebuilding the chain")
    func bypassToggle() {
        var slot = Self.lowPass()
        let processor = EffectChainProcessor(sampleRate: Self.sampleRate, slots: [slot])
        #expect(Self.peakAfterProcessing(processor) < 0.05)

        slot.isBypassed = true
        processor.update([slot])
        #expect(Self.peakAfterProcessing(processor) == 0.5)
    }

    @Test("saved state round-trips through a new instance")
    func stateRoundTrip() throws {
        let processor = EffectChainProcessor(sampleRate: Self.sampleRate, slots: [Self.lowPass()])
        let slot = try #require(processor.slots.first)
        // Fetch defaults from a fresh editor-style instance, then rebuild from them.
        let unit = try #require(EffectUnitFactory.makeUnit(component: slot.component, sampleRate: Self.sampleRate, state: nil, inputCallback: nil))
        defer {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        let state = try #require(EffectUnitFactory.state(of: unit))

        var restored = slot
        restored.state = state
        let rebuilt = EffectChainProcessor(sampleRate: Self.sampleRate, slots: [restored])
        #expect(Self.peakAfterProcessing(rebuilt) < 0.05)
    }

    @Test("buffers larger than the render limit pass through")
    func oversizedBufferPassesThrough() {
        let processor = EffectChainProcessor(sampleRate: Self.sampleRate, slots: [Self.lowPass()])
        let frameCount = Int(EffectUnitFactory.maxFrames) + 1
        var samples = (0..<frameCount * 2).map { index in Float((index / 2) % 2 == 0 ? 0.5 : -0.5) }
        samples.withUnsafeMutableBufferPointer { buffer in
            processor.process(buffer.baseAddress!, frameCount: frameCount)
        }
        #expect(samples.map(abs).max() == 0.5)
    }

    @Test("effect slots survive a settings encode/decode round trip")
    func slotCodable() throws {
        let slot = AudioEffectSlot(component: Self.lowPass().component, name: "AULowpass", isBypassed: true, state: Data([9, 8, 7]))
        let decoded = try JSONDecoder().decode(AudioEffectSlot.self, from: JSONEncoder().encode(slot))
        #expect(decoded == slot)
    }
}

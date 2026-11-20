// FineTune/Audio/Effects/EffectChainProcessor.swift
import AudioToolbox
import Foundation
import os

private nonisolated let effectLogger = Logger(subsystem: "com.finetuneapp.FineTune", category: "EffectChain")

// MARK: - Unit construction (shared by live chains and editors)

/// Builds and configures Audio Unit v2 instances for effect chains. The C API is used
/// (not AUAudioUnit) because `AudioUnitRender` with a C input callback is
/// allocation-free and lock-free on the audio thread.
nonisolated enum EffectUnitFactory {
    /// Upper bound on frames per render. Larger HAL buffers bypass the chain.
    static let maxFrames: UInt32 = 8192

    /// Stereo, non-interleaved Float32: the canonical format Apple effects expect.
    static func streamFormat(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    /// Creates, configures and initializes a unit. `inputCallback` is installed before
    /// initialization when given (live units); editors pass nil since they never render.
    static func makeUnit(
        component: AudioEffectComponent,
        sampleRate: Double,
        state: Data?,
        inputCallback: AURenderCallbackStruct?
    ) -> AudioUnit? {
        var description = component.componentDescription
        guard let audioComponent = AudioComponentFindNext(nil, &description) else {
            effectLogger.error("Effect component not found: \(component.subType)")
            return nil
        }
        var instance: AudioComponentInstance?
        guard AudioComponentInstanceNew(audioComponent, &instance) == noErr, let unit = instance else {
            effectLogger.error("Failed to instantiate effect \(component.subType)")
            return nil
        }

        var format = streamFormat(sampleRate: sampleRate)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var maxFrames = maxFrames
        var status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, formatSize)
        if status == noErr {
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, formatSize)
        }
        if status == noErr {
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        }
        if status == noErr, var callback = inputCallback {
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        }
        if status == noErr {
            status = AudioUnitInitialize(unit)
        }
        guard status == noErr else {
            effectLogger.error("Failed to configure effect \(component.subType): \(status)")
            AudioComponentInstanceDispose(unit)
            return nil
        }
        if let state {
            applyState(state, to: unit)
        }
        return unit
    }

    /// The unit's full preset (`ClassInfo`) as a binary property list.
    static func state(of unit: AudioUnit) -> Data? {
        var classInfo: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &classInfo, &size)
        guard status == noErr, let plist = classInfo?.takeRetainedValue() else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    static func applyState(_ data: Data, to unit: AudioUnit) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return }
        var classInfo: CFPropertyList = plist as CFPropertyList
        let status = AudioUnitSetProperty(unit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &classInfo, UInt32(MemoryLayout<CFPropertyList>.size))
        if status != noErr {
            effectLogger.error("Failed to restore effect state: \(status)")
        } else {
            // Tell listeners (e.g. an open generic view) that every parameter may have moved.
            var change = AudioUnitParameter(mAudioUnit: unit, mParameterID: kAUParameterListener_AnyParameter, mScope: kAudioUnitScope_Global, mElement: 0)
            AUParameterListenerNotify(nil, nil, &change)
        }
    }
}

// MARK: - Live effect

/// Raw input pointers the render callback reads. A plain struct behind a stable
/// pointer, so the C callback touches no Swift objects (no ARC on the audio thread).
private nonisolated struct EffectInputSource {
    var left: UnsafeMutablePointer<Float>?
    var right: UnsafeMutablePointer<Float>?
}

/// Supplies the effect's input: copies the current stage's L/R buffers into the
/// buffers the unit hands us. Runs on the audio thread.
private nonisolated let effectInputCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    guard let ioData else { return noErr }
    let source = refCon.assumingMemoryBound(to: EffectInputSource.self).pointee
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    let byteCount = Int(frameCount) * MemoryLayout<Float>.size
    for index in 0..<buffers.count {
        let channelSource = index == 0 ? source.left : source.right
        guard let channelSource else { continue }
        if let data = buffers[index].mData {
            memcpy(data, channelSource, byteCount)
        } else {
            buffers[index].mData = UnsafeMutableRawPointer(channelSource)
        }
        buffers[index].mDataByteSize = UInt32(byteCount)
    }
    return noErr
}

/// One running Audio Unit in a tap's chain. Owns the unit and disposes it on deinit;
/// chains are released 0.5 s after being swapped out, so the audio thread is done with it.
nonisolated final class HostedEffect: @unchecked Sendable {
    let slotID: UUID
    let component: AudioEffectComponent
    let sampleRate: Double
    let unit: AudioUnit
    /// Read on the audio thread; flipped from the main thread without rebuilding.
    nonisolated(unsafe) var isBypassed: Bool
    fileprivate let inputSource: UnsafeMutablePointer<EffectInputSource>

    init?(slot: AudioEffectSlot, sampleRate: Double) {
        let source = UnsafeMutablePointer<EffectInputSource>.allocate(capacity: 1)
        source.initialize(to: EffectInputSource())
        let callback = AURenderCallbackStruct(inputProc: effectInputCallback, inputProcRefCon: UnsafeMutableRawPointer(source))
        guard let unit = EffectUnitFactory.makeUnit(component: slot.component, sampleRate: sampleRate, state: slot.state, inputCallback: callback) else {
            source.deallocate()
            return nil
        }
        self.slotID = slot.id
        self.component = slot.component
        self.sampleRate = sampleRate
        self.unit = unit
        self.isBypassed = slot.isBypassed
        self.inputSource = source
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        inputSource.deallocate()
    }
}

// MARK: - Chain snapshot

/// Immutable list of effects plus the scratch buffers to run them. The audio thread
/// only ever sees a whole snapshot; edits build a new one and swap it in.
nonisolated final class EffectChain: @unchecked Sendable {
    let effects: ContiguousArray<HostedEffect>

    private let maxFrames: Int
    private let bufferAL: UnsafeMutablePointer<Float>
    private let bufferAR: UnsafeMutablePointer<Float>
    private let bufferBL: UnsafeMutablePointer<Float>
    private let bufferBR: UnsafeMutablePointer<Float>
    private let outputList: UnsafeMutableAudioBufferListPointer
    private nonisolated(unsafe) var sampleTime: Float64 = 0

    init(effects: ContiguousArray<HostedEffect>) {
        self.effects = effects
        maxFrames = Int(EffectUnitFactory.maxFrames)
        bufferAL = .allocate(capacity: maxFrames)
        bufferAR = .allocate(capacity: maxFrames)
        bufferBL = .allocate(capacity: maxFrames)
        bufferBR = .allocate(capacity: maxFrames)
        outputList = AudioBufferList.allocate(maximumBuffers: 2)
        outputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        outputList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
    }

    deinit {
        bufferAL.deallocate()
        bufferAR.deallocate()
        bufferBL.deallocate()
        bufferBR.deallocate()
        outputList.unsafeMutablePointer.deallocate()
    }

    // MARK: RT-safe processing

    /// Runs interleaved stereo `samples` through every non-bypassed effect in place.
    /// A unit that fails to render is skipped (its input passes through unchanged).
    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0, frameCount <= maxFrames else { return }
        var anyActive = false
        for effect in effects where !effect.isBypassed {
            anyActive = true
            break
        }
        guard anyActive else { return }

        for frame in 0..<frameCount {
            bufferAL[frame] = samples[frame * 2]
            bufferAR[frame] = samples[frame * 2 + 1]
        }

        var inL = bufferAL, inR = bufferAR
        var outL = bufferBL, outR = bufferBR
        let byteCount = UInt32(frameCount * MemoryLayout<Float>.size)
        var timeStamp = AudioTimeStamp()
        timeStamp.mSampleTime = sampleTime
        timeStamp.mFlags = .sampleTimeValid

        for effect in effects where !effect.isBypassed {
            effect.inputSource.pointee = EffectInputSource(left: inL, right: inR)
            outputList[0].mData = UnsafeMutableRawPointer(outL)
            outputList[0].mDataByteSize = byteCount
            outputList[1].mData = UnsafeMutableRawPointer(outR)
            outputList[1].mDataByteSize = byteCount
            var flags = AudioUnitRenderActionFlags()
            let status = AudioUnitRender(effect.unit, &flags, &timeStamp, 0, UInt32(frameCount), outputList.unsafeMutablePointer)
            guard status == noErr else { continue }
            // A unit may point the buffers at its own memory; copy back if so.
            if let rendered = outputList[0].mData, rendered != UnsafeMutableRawPointer(outL) {
                memcpy(outL, rendered, Int(byteCount))
            }
            if let rendered = outputList[1].mData, rendered != UnsafeMutableRawPointer(outR) {
                memcpy(outR, rendered, Int(byteCount))
            }
            swap(&inL, &outL)
            swap(&inR, &outR)
        }
        sampleTime += Float64(frameCount)

        for frame in 0..<frameCount {
            samples[frame * 2] = inL[frame]
            samples[frame * 2 + 1] = inR[frame]
        }
    }
}

// MARK: - Processor

/// One effect chain stage in a tap (the app chain or the device chain). Main-thread
/// API builds chain snapshots; `process` runs on the audio thread.
nonisolated final class EffectChainProcessor: @unchecked Sendable {
    private nonisolated(unsafe) var _chain: EffectChain?
    private(set) var slots: [AudioEffectSlot] = []
    private(set) var sampleRate: Double

    init(sampleRate: Double, slots: [AudioEffectSlot] = []) {
        self.sampleRate = sampleRate
        update(slots)
    }

    /// Whether the audio thread has any work to do (RT-safe read).
    var isActive: Bool { _chain != nil }

    /// RT-safe: processes interleaved stereo samples in place.
    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        _chain?.process(samples, frameCount: frameCount)
    }

    /// Applies a new slot list. Effects that stay in the chain keep their running
    /// instance (no state reset, reverb tails continue); only bypass flags are updated
    /// when the order and membership are unchanged.
    func update(_ newSlots: [AudioEffectSlot]) {
        let previous = slots
        slots = newSlots

        if let chain = _chain,
           chain.effects.map(\.slotID) == newSlots.map(\.id) {
            for (effect, slot) in zip(chain.effects, newSlots) {
                effect.isBypassed = slot.isBypassed
            }
            return
        }

        var existing: [UUID: HostedEffect] = [:]
        for effect in _chain?.effects ?? [] {
            existing[effect.slotID] = effect
        }
        var effects = ContiguousArray<HostedEffect>()
        for slot in newSlots {
            if let reused = existing[slot.id], reused.component == slot.component, reused.sampleRate == sampleRate {
                reused.isBypassed = slot.isBypassed
                effects.append(reused)
            } else if let created = HostedEffect(slot: slot, sampleRate: sampleRate) {
                effects.append(created)
            }
        }
        swapChain(effects.isEmpty ? nil : EffectChain(effects: effects))
        if previous.count != newSlots.count || effects.count != newSlots.count {
            effectLogger.debug("Effect chain now has \(effects.count) of \(newSlots.count) effect(s) running")
        }
    }

    /// Rebuilds every unit at the new rate (units can't change rate while initialized).
    func updateSampleRate(_ newRate: Double) {
        guard newRate != sampleRate else { return }
        sampleRate = newRate
        let current = slots
        swapChain(nil)
        update(current)
    }

    /// The running instance for a slot, if it was created successfully.
    func effect(slotID: UUID) -> HostedEffect? {
        _chain?.effects.first { $0.slotID == slotID }
    }

    /// Live parameter change from an open editor.
    func setParameter(slotID: UUID, id: AudioUnitParameterID, scope: AudioUnitScope, element: AudioUnitElement, value: AudioUnitParameterValue) {
        guard let effect = _chain?.effects.first(where: { $0.slotID == slotID }) else { return }
        AudioUnitSetParameter(effect.unit, id, scope, element, value, 0)
    }

    /// Loads a full preset into the running unit (e.g. a factory preset chosen in the editor).
    func applyState(slotID: UUID, state: Data) {
        if let index = slots.firstIndex(where: { $0.id == slotID }) {
            slots[index].state = state
        }
        guard let effect = _chain?.effects.first(where: { $0.slotID == slotID }) else { return }
        EffectUnitFactory.applyState(state, to: effect.unit)
    }

    private func swapChain(_ newChain: EffectChain?) {
        let old = _chain
        _chain = newChain
        if let old {
            // Same grace period as the EQ processors: the audio thread may still be
            // inside old.process() for the current buffer.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { _ = old }
        }
    }
}

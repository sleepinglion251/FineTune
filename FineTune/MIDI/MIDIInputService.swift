// FineTune/MIDI/MIDIInputService.swift
import CoreMIDI
import Foundation
import os

/// A message plus the endpoint it arrived from.
nonisolated struct ReceivedMIDIMessage: Sendable, Equatable {
    let message: MIDIMessage
    let sourceID: MIDIEndpointRef
}

@MainActor
protocol MIDIInputProviding: AnyObject {
    var onMessages: (([ReceivedMIDIMessage]) -> Void)? { get set }
    var sourceNames: [String] { get }
    var isRunning: Bool { get }
    func start()
    func stop()
    func sourceName(for sourceID: MIDIEndpointRef) -> String?
}

/// Listens to every MIDI source on the system (omni) and forwards decoded
/// channel-voice messages to the main actor in batches.
///
/// Sources are re-enumerated on every CoreMIDI setup change, so controllers can be
/// plugged in or unplugged while FineTune runs.
@MainActor
@Observable
final class MIDIInputService: MIDIInputProviding {
    private static let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "MIDIInput")

    @ObservationIgnored var onMessages: (([ReceivedMIDIMessage]) -> Void)?

    /// Display names of the currently connected sources, for the settings UI.
    private(set) var sourceNames: [String] = []
    private(set) var isRunning = false

    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var inputPort = MIDIPortRef()
    @ObservationIgnored private var connectedSources: [MIDIEndpointRef] = []
    @ObservationIgnored private var namesByID: [MIDIEndpointRef: String] = [:]

    init() {}

    isolated deinit {
        stop()
    }

    /// Idempotent.
    func start() {
        guard !isRunning else { return }

        let notifyBlock = Self.makeNotifyBlock { [weak self] in
            self?.reconnectSources()
        }
        var status = MIDIClientCreateWithBlock("FineTune" as CFString, &client, notifyBlock)
        guard status == noErr else {
            Self.logger.error("MIDIClientCreate failed: \(status)")
            return
        }

        let receiveBlock = Self.makeReceiveBlock { [weak self] batch in
            self?.onMessages?(batch)
        }
        status = MIDIInputPortCreateWithProtocol(
            client,
            "FineTune Input" as CFString,
            ._1_0,
            &inputPort,
            receiveBlock
        )
        guard status == noErr else {
            Self.logger.error("MIDIInputPortCreate failed: \(status)")
            MIDIClientDispose(client)
            client = 0
            return
        }

        isRunning = true
        reconnectSources()
        Self.logger.info("MIDI input started")
    }

    /// Idempotent.
    func stop() {
        guard isRunning else { return }
        for source in connectedSources {
            MIDIPortDisconnectSource(inputPort, source)
        }
        connectedSources = []
        namesByID = [:]
        sourceNames = []
        MIDIPortDispose(inputPort)
        MIDIClientDispose(client)
        inputPort = 0
        client = 0
        isRunning = false
        Self.logger.info("MIDI input stopped")
    }

    func sourceName(for sourceID: MIDIEndpointRef) -> String? {
        namesByID[sourceID]
    }

    // MARK: - Sources

    private func reconnectSources() {
        guard isRunning else { return }
        for source in connectedSources {
            MIDIPortDisconnectSource(inputPort, source)
        }
        connectedSources = []
        namesByID = [:]

        let count = MIDIGetNumberOfSources()
        for index in 0..<count {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }
            // Smuggle the endpoint ref through refCon so the receive block can tag messages.
            let refCon = UnsafeMutableRawPointer(bitPattern: UInt(source))
            let status = MIDIPortConnectSource(inputPort, source, refCon)
            guard status == noErr else {
                Self.logger.error("MIDIPortConnectSource failed: \(status)")
                continue
            }
            connectedSources.append(source)
            namesByID[source] = Self.displayName(of: source)
        }
        sourceNames = connectedSources.compactMap { namesByID[$0] }
        Self.logger.info("Connected to \(self.connectedSources.count) MIDI source(s)")
    }

    private static func displayName(of endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        guard status == noErr, let name else { return "MIDI Source" }
        return name.takeRetainedValue() as String
    }

    // MARK: - CoreMIDI callbacks (nonisolated)

    private nonisolated static let wordsOffset =
        MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) ?? 12

    /// Built outside the main actor so the closure isn't inferred `@MainActor`
    /// (CoreMIDI calls it on its own thread). Parses there, then hops to main once per packet list.
    private nonisolated static func makeReceiveBlock(
        deliver: @escaping @MainActor @Sendable ([ReceivedMIDIMessage]) -> Void
    ) -> MIDIReceiveBlock {
        return { eventList, srcConnRefCon in
            let sourceID = MIDIEndpointRef(UInt(bitPattern: srcConnRefCon))
            var batch: [ReceivedMIDIMessage] = []
            for packet in eventList.unsafeSequence() {
                // Read only `wordCount` words in place: the last packet in a list may be
                // allocated shorter than the full 64-word `words` tuple, so copying
                // `pointee.words` could read past the buffer.
                let wordCount = min(Int(packet.pointee.wordCount), 64)
                guard wordCount > 0 else { continue }
                let base = UnsafeRawPointer(packet).advanced(by: wordsOffset)
                let words = UnsafeBufferPointer(
                    start: base.assumingMemoryBound(to: UInt32.self),
                    count: wordCount
                )
                for message in MIDIMessageParser.parse(words: words) {
                    batch.append(ReceivedMIDIMessage(message: message, sourceID: sourceID))
                }
            }
            guard !batch.isEmpty else { return }
            let delivered = batch
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(delivered) }
            }
        }
    }

    private nonisolated static func makeNotifyBlock(
        onSetupChanged: @escaping @MainActor @Sendable () -> Void
    ) -> MIDINotifyBlock {
        return { notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onSetupChanged() }
            }
        }
    }
}

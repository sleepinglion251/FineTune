// FineTune/MIDI/MIDIMessageParser.swift
import Foundation

/// Decodes Universal MIDI Packet words (as delivered by a CoreMIDI input port
/// created with `MIDIProtocolID._1_0`) into `MIDIMessage`s.
///
/// Pure and allocation-light so it can run on the CoreMIDI receive thread and be
/// unit-tested without CoreMIDI.
nonisolated enum MIDIMessageParser {
    /// UMP packet size in 32-bit words, indexed by message type (high nibble of word 0).
    /// From the UMP spec, table "Message Type (MT) Allocation".
    private static let wordCounts: [Int] = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]

    /// Parses a run of UMP words that may contain several packets.
    static func parse<Words: Collection>(words: Words) -> [MIDIMessage] where Words.Element == UInt32, Words.Index == Int {
        var messages: [MIDIMessage] = []
        var index = words.startIndex
        while index < words.endIndex {
            let word = words[index]
            let type = Int(word >> 28)
            if type == 0x2, let message = parseMIDI1ChannelVoice(word) {
                messages.append(message)
            }
            index += wordCounts[type]
        }
        return messages
    }

    /// Decodes one MIDI 1.0 channel-voice UMP word (message type 0x2).
    static func parseMIDI1ChannelVoice(_ word: UInt32) -> MIDIMessage? {
        guard word >> 28 == 0x2 else { return nil }
        let status = UInt8((word >> 16) & 0xFF)
        let data1 = UInt8((word >> 8) & 0x7F)
        let data2 = UInt8(word & 0x7F)
        return parse(status: status, data1: data1, data2: data2)
    }

    /// Decodes a classic MIDI 1.0 three-byte channel message.
    static func parse(status: UInt8, data1: UInt8, data2: UInt8) -> MIDIMessage? {
        let channel = status & 0x0F
        switch status & 0xF0 {
        case 0x80:
            return .noteOff(channel: channel, note: data1)
        case 0x90:
            // Note-on with velocity 0 is a note-off by convention (running-status trick).
            return data2 == 0
                ? .noteOff(channel: channel, note: data1)
                : .noteOn(channel: channel, note: data1, velocity: data2)
        case 0xB0:
            return .controlChange(channel: channel, controller: data1, value: data2)
        default:
            return nil
        }
    }
}

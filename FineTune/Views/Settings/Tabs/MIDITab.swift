// FineTune/Views/Settings/Tabs/MIDITab.swift
import AppKit
import SwiftUI

@MainActor
struct MIDITab: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var midi: MIDIControlRegistry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                generalSection
                if settings.appSettings.midiControlEnabled {
                    systemSection
                    appsSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onChange(of: settings.appSettings.midiControlEnabled) { _, _ in
            midi.reconcile()
        }
        .onDisappear { midi.cancelLearning() }
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsSection("MIDI") {
            SettingsRow(
                "MIDI Control",
                description: "Control app and system volume from any connected MIDI controller"
            ) {
                Toggle("", isOn: $settings.appSettings.midiControlEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if settings.appSettings.midiControlEnabled {
                SettingsRowDivider()
                SettingsRow("Devices", description: devicesDescription) {
                    EmptyView()
                }

                SettingsRowDivider()
                SettingsRow("Last Message") {
                    MIDIActivityReadout(midi: midi)
                }
            }
        }
    }

    private var devicesDescription: String {
        let names = midi.inputSourceNames
        return names.isEmpty ? "No MIDI devices connected" : names.joined(separator: ", ")
    }

    // MARK: - System

    private var systemSection: some View {
        SettingsSection("System Output") {
            MIDITargetRow(
                midi: midi,
                target: .systemOutput,
                title: "System Volume",
                subtitle: "Default output device",
                icon: .symbol("speaker.wave.2.fill"),
                displayName: nil,
                bundleID: nil
            )
        }
    }

    // MARK: - Apps

    private struct AppEntry: Identifiable {
        let id: String
        let name: String
        let bundleID: String?
        let icon: NSImage
        let isRunning: Bool
    }

    /// Active + pinned apps from the engine, plus any mapped app that's no longer
    /// listed there, so existing bindings can always be inspected and cleared.
    private var appEntries: [AppEntry] {
        var entries: [String: AppEntry] = [:]
        for app in audioEngine.displayableApps {
            let bundleID: String? = switch app {
            case .active(let audioApp): audioApp.bundleID
            case .pinnedInactive(let info): info.bundleID
            }
            entries[app.id] = AppEntry(
                id: app.id,
                name: app.displayName,
                bundleID: bundleID,
                icon: app.icon,
                isRunning: app.isActive
            )
        }
        for (identifier, mapping) in midi.mappedAppTargets where entries[identifier] == nil {
            entries[identifier] = AppEntry(
                id: identifier,
                name: mapping.displayName ?? identifier,
                bundleID: mapping.bundleID,
                icon: DisplayableApp.loadIcon(bundleID: mapping.bundleID),
                isRunning: false
            )
        }
        return entries.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var appsSection: some View {
        let entries = appEntries
        return SettingsSection("Apps") {
            if entries.isEmpty {
                Text("Apps appear here once they play audio. Pin an app in the menu bar popup to map it while it isn't running.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { SettingsRowDivider() }
                    MIDITargetRow(
                        midi: midi,
                        target: .app(identifier: entry.id),
                        title: entry.name,
                        subtitle: entry.isRunning ? nil : "Not running",
                        icon: .image(entry.icon),
                        displayName: entry.name,
                        bundleID: entry.bundleID
                    )
                }
            }
        }
    }
}

// MARK: - Activity Readout

/// Isolated so per-message `lastMessage` updates re-render only this label,
/// not the whole tab, while a fader is moving.
@MainActor
private struct MIDIActivityReadout: View {
    let midi: MIDIControlRegistry

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var text: String {
        guard let last = midi.lastMessage else { return "—" }
        if let source = midi.sourceName(for: last) {
            return "\(last.message.displayString)  ·  \(source)"
        }
        return last.message.displayString
    }
}

// MARK: - Target Row

@MainActor
private struct MIDITargetRow: View {
    enum Icon {
        case symbol(String)
        case image(NSImage)
    }

    @Bindable var midi: MIDIControlRegistry
    let target: MIDITarget
    let title: String
    let subtitle: String?
    let icon: Icon
    let displayName: String?
    let bundleID: String?

    var body: some View {
        let mapping = midi.mapping(for: target)
        HStack(alignment: .center, spacing: 12) {
            iconView
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 6) {
                slotControls(.volume, label: "Volume", binding: mapping?.volume)
                HStack(spacing: 6) {
                    if mapping?.mute != nil {
                        muteModePicker(mapping?.muteMode ?? .toggle)
                    }
                    slotControls(.mute, label: "Mute", binding: mapping?.mute)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    private func slotControls(_ slot: MIDIControlSlot, label: String, binding: MIDIBinding?) -> some View {
        let isLearning = midi.isLearning(target: target, slot: slot)
        return HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            bindingChip(binding: binding, isLearning: isLearning, slot: slot)
                .frame(width: 150, alignment: .leading)

            Button(isLearning ? "Cancel" : "Learn") {
                if isLearning {
                    midi.cancelLearning()
                } else {
                    midi.beginLearning(target: target, slot: slot, displayName: displayName, bundleID: bundleID)
                }
            }
            .controlSize(.small)
            .frame(width: 64)
            .help(learnHelp(for: slot))

            Button {
                midi.clearBinding(for: target, slot: slot)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(binding == nil ? 0 : 1)
            .disabled(binding == nil)
            .help("Remove \(label.lowercased()) mapping")
        }
    }

    @ViewBuilder
    private func bindingChip(binding: MIDIBinding?, isLearning: Bool, slot: MIDIControlSlot) -> some View {
        if isLearning {
            Text(slot == .volume ? "Move a control…" : "Press a button…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
        } else if let binding {
            Text(binding.displayString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
        } else {
            Text("Not mapped")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func muteModePicker(_ mode: MIDIMuteMode) -> some View {
        Menu {
            ForEach(MIDIMuteMode.allCases, id: \.self) { option in
                Button {
                    midi.setMuteMode(option, for: target)
                } label: {
                    if option == mode {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mute behavior: \(mode.displayName)")
    }

    private func learnHelp(for slot: MIDIControlSlot) -> String {
        switch slot {
        case .volume: "Listen for a knob or fader (MIDI CC) to control volume"
        case .mute: "Listen for a button (MIDI CC or note) to control mute"
        }
    }
}

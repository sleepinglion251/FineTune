// FineTune/Views/Components/EffectChainView.swift
import SwiftUI

/// The Audio Unit effect chain shown under an app's or output device's EQ panel.
/// Effects run top to bottom. Each row toggles bypass, opens the editor, moves, or removes.
struct EffectChainView: View {
    let slots: [AudioEffectSlot]
    let onChange: ([AudioEffectSlot]) -> Void
    let onEdit: (AudioEffectSlot) -> Void
    let onRemove: (AudioEffectSlot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Effects")
                    .sectionHeaderStyle()
                Spacer()
                addEffectMenu
            }

            if slots.isEmpty {
                Text("No effects. Added effects run after the EQ.")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .padding(.vertical, 2)
            } else {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    EffectSlotRow(
                        slot: slot,
                        position: index + 1,
                        canMoveUp: index > 0,
                        canMoveDown: index < slots.count - 1,
                        onToggleBypass: { toggleBypass(at: index) },
                        onEdit: { onEdit(slot) },
                        onMoveUp: { move(from: index, to: index - 1) },
                        onMoveDown: { move(from: index, to: index + 1) },
                        onRemove: { remove(at: index) }
                    )
                }
            }
        }
        .padding(.top, DesignTokens.Spacing.sm)
    }

    private var addEffectMenu: some View {
        DropdownMenu(
            items: BuiltInEffectCatalog.entries,
            selectedItem: nil,
            maxVisibleItems: 12,
            width: 110,
            popoverWidth: 190,
            onSelect: { entry in
                var updated = slots
                updated.append(AudioEffectSlot(component: entry.component, name: entry.name))
                onChange(updated)
            }
        ) { _ in
            Label("Add Effect", systemImage: "plus")
        } itemContent: { entry, _ in
            Text(entry.name)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggleBypass(at index: Int) {
        var updated = slots
        updated[index].isBypassed.toggle()
        onChange(updated)
    }

    private func move(from source: Int, to destination: Int) {
        guard slots.indices.contains(destination) else { return }
        var updated = slots
        updated.swapAt(source, destination)
        onChange(updated)
    }

    private func remove(at index: Int) {
        var updated = slots
        let removed = updated.remove(at: index)
        onChange(updated)
        onRemove(removed)
    }
}

private struct EffectSlotRow: View {
    let slot: AudioEffectSlot
    let position: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onToggleBypass: () -> Void
    let onEdit: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button(action: onToggleBypass) {
                Image(systemName: "power")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(slot.isBypassed ? DesignTokens.Colors.interactiveDefault : DesignTokens.Colors.interactiveActive)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(slot.isBypassed ? "Turn on \(slot.name)" : "Bypass \(slot.name)")
            .accessibilityLabel(slot.isBypassed ? "Turn on \(slot.name)" : "Bypass \(slot.name)")

            Button(action: onEdit) {
                HStack(spacing: 4) {
                    Text("\(position).")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                    Text(slot.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(slot.isBypassed ? DesignTokens.Colors.textTertiary : DesignTokens.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit \(slot.name)")
            .accessibilityLabel("Edit \(slot.name)")

            rowButton("chevron.up", help: "Move up", enabled: canMoveUp, action: onMoveUp)
            rowButton("chevron.down", help: "Move down", enabled: canMoveDown, action: onMoveDown)
            rowButton("xmark", help: "Remove \(slot.name)", enabled: true, action: onRemove)
        }
        .padding(.horizontal, 4)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(isHovered ? DesignTokens.Colors.hoverSurface : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    private func rowButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(help)
        .accessibilityLabel(help)
    }
}

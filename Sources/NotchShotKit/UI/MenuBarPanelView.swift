import AppKit
import SwiftUI

/// The panel behind the menu-bar icon.
///
/// A plain `NSMenu` listed the same actions, but a list of words in a system
/// menu is not where anyone looks for "the thing that holds my screenshots".
/// This is the Control Center shape instead: labelled tiles, live counts, and
/// the shelf reachable in one click from the same strip as Wi-Fi and battery.
struct MenuBarPanelView: View {
    @Bindable var coordinator: AppCoordinator
    var onDismiss: () -> Void

    private var shelfCount: Int { coordinator.shelfItems.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            captureSection
            Divider().opacity(0.4)
            librarySection
            Divider().opacity(0.4)
            footer
        }
        .padding(16)
        .frame(width: 300)
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Capture")
            HStack(spacing: 8) {
                tile("Area", "selection.pin.in.out") {
                    coordinator.capture(.area, timer: .none)
                }
                tile("Window", "macwindow") {
                    coordinator.capture(.window, timer: .none)
                }
                tile("Screen", "display") {
                    coordinator.capture(.display, timer: .none)
                }
            }
            HStack(spacing: 8) {
                tile("Text", "text.viewfinder") {
                    coordinator.capture(.ocr, timer: .none)
                }
                tile("Record", "record.circle", tint: .red) {
                    coordinator.startRecording(mode: Preferences.shared.recordingTargetMode)
                }
                tile("Voice", "waveform.and.mic") {
                    coordinator.startVoiceNote()
                }
            }
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Library")
            HStack(spacing: 8) {
                // The count is the point: it says whether opening the shelf is
                // worth a click before the click happens.
                tile(
                    shelfCount > 0 ? "Shelf · \(shelfCount)" : "Shelf",
                    "tray.full",
                    isEnabled: coordinator.canShowShelf
                ) {
                    coordinator.showShelf()
                }
                tile("History", "clock.arrow.circlepath") {
                    onDismiss()
                    coordinator.onOpenHistory?()
                }
                tile("Clipboard", "doc.on.clipboard") {
                    onDismiss()
                    coordinator.onOpenClipboard?()
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Productivity Center") {
                coordinator.openProductivity()
                onDismiss()
            }
            .buttonStyle(.link)

            Spacer(minLength: 8)

            Button {
                coordinator.onOpenSettings?()
                onDismiss()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .font(.system(size: 11))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .kerning(0.6)
    }

    private func tile(
        _ title: String,
        _ symbol: String,
        tint: Color = .accentColor,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            // The panel closes first: a capture that starts while its own
            // popover is still on screen photographs the popover.
            onDismiss()
            action()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isEnabled ? tint : Color.secondary)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(
                cornerRadius: 10,
                style: .continuous
            ))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

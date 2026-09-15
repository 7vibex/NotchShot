import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Capture menu

struct CaptureMenuContent: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable private var recipeStore = CaptureRecipeStore.shared
    @State private var timer: CaptureTimer = .none
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let primaryIntents: [CaptureIntent] = [.area, .window, .display]
    private let secondaryIntents: [CaptureIntent] = [.scrolling, .ocr, .previousArea]

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Label("Capture", systemImage: "camera.viewfinder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()

                Menu {
                    ForEach(recipeStore.recipes) { recipe in
                        Button {
                            recipeStore.activeRecipeID = recipe.id
                        } label: {
                            if recipe.id == recipeStore.activeRecipeID {
                                Label(recipe.name, systemImage: "checkmark")
                            } else {
                                Text(recipe.name)
                            }
                        }
                    }
                } label: {
                    Label(recipeStore.activeRecipe.name, systemImage: "wand.and.stars")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 120)
                .help(recipeStore.activeRecipe.detail)

                Menu {
                    ForEach(CaptureTimer.allCases) { option in
                        Button {
                            timer = option
                        } label: {
                            if timer == option {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    Label(timer.title, systemImage: "timer")
                        .font(.system(size: 10, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 82)
                .help("Capture delay")

                // The island's corner radius curves in behind this row, so a
                // control flush against the trailing edge reads as sitting
                // outside the shell. The inset keeps the whole circle on the
                // flat part of the shape.
                NotchIconButton(
                    systemName: "xmark",
                    label: "Close",
                    visualScale: 0.8
                ) {
                    coordinator.collapse()
                }
                .padding(.trailing, NotchIsland.Spacing.snug)
            }
            .padding(.top, NotchIsland.Spacing.tight)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3),
                spacing: 7
            ) {
                ForEach(primaryIntents) { intent in
                    CaptureIntentButton(intent: intent) {
                        coordinator.capture(intent, timer: timer)
                    }
                }
            }

            HStack(spacing: 7) {
                Menu {
                    Section("More Capture Modes") {
                        ForEach(secondaryIntents) { intent in
                            Button {
                                coordinator.capture(intent, timer: timer)
                            } label: {
                                Label(intent.title, systemImage: intent.symbolName)
                            }
                        }
                    }
                    Section("Focus Timer") {
                        ForEach([5, 15, 25, 45], id: \.self) { minutes in
                            Button("\(minutes) minutes") {
                                coordinator.startFocusTimer(minutes: minutes)
                            }
                        }
                    }
                    Divider()
                    Button {
                        coordinator.startVoiceNote()
                    } label: {
                        Label("Voice Note", systemImage: "waveform.and.mic")
                    }
                    Divider()
                    Button {
                        coordinator.openProductivity()
                    } label: {
                        Label("Productivity Center", systemImage: "square.grid.2x2")
                    }
                    Divider()
                    Button {
                        coordinator.onOpenSettings?()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    commandLabel(
                        "More",
                        systemImage: "ellipsis"
                    )
                }
                .menuStyle(.borderlessButton)
                .help("More capture modes, activities, and settings")

                Menu {
                    ForEach(RecordingTargetMode.allCases) { target in
                        Button {
                            coordinator.startRecording(mode: target)
                        } label: {
                            Label(target.title, systemImage: target.symbolName)
                        }
                    }
                } label: {
                    commandLabel(
                        "Record",
                        systemImage: "record.circle",
                        iconTint: .red
                    )
                }
                .menuStyle(.borderlessButton)

                Button {
                    coordinator.onOpenHistory?()
                } label: {
                    commandLabel(
                        "History",
                        systemImage: "clock.arrow.circlepath"
                    )
                }
                .buttonStyle(NotchPressButtonStyle())

                // The shelf had no route back once it timed out or was
                // dismissed. It is the surface a capture actually lands on, so
                // it belongs in the notch's own strip and not only in the
                // menu bar.
                Button {
                    coordinator.showShelf()
                } label: {
                    commandLabel(
                        "Shelf",
                        systemImage: "tray.full"
                    )
                }
                .buttonStyle(NotchPressButtonStyle())
                .disabled(!coordinator.canShowShelf)
                .help(
                    coordinator.canShowShelf
                        ? "Show the captures parked on the shelf"
                        : "Nothing is on the shelf yet"
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// A menu or button in the command strip. Hover is not decoration here: the
    /// three tiles above it lift under the pointer, and a strip that stayed
    /// inert next to them read as disabled rather than as a different shape of
    /// control.
    private func commandLabel(
        _ title: String,
        systemImage: String,
        iconTint: Color = .white.opacity(0.88)
    ) -> some View {
        CaptureCommandLabel(
            title: title,
            systemImage: systemImage,
            iconTint: iconTint,
            reduceTransparency: reduceTransparency
        )
    }
}

/// Split out so each command owns its own hover state; a shared `@State` on the
/// menu would light all three at once.
private struct CaptureCommandLabel: View {
    var title: String
    var systemImage: String
    var iconTint: Color
    var reduceTransparency: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(iconTint)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, minHeight: 36)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .notchControlSurface(
            in: RoundedRectangle(cornerRadius: 10, style: .continuous),
            reduceTransparency: reduceTransparency,
            emphasized: isHovered
        )
        .scaleEffect(NotchShotMotion.activeScale(
            isActive: isHovered,
            reduceMotion: reduceMotion,
            activeScale: 1.03
        ))
        .offset(y: NotchShotMotion.activeOffset(
            isActive: isHovered,
            reduceMotion: reduceMotion
        ))
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .accessibilityLabel(title)
    }
}

/// Makes the entire visible capture tile clickable. With a plain macOS button,
/// relying on only the icon and text for hit testing made clicks in the empty
/// parts of Area, Window, and Screen appear to do nothing.
private struct CaptureIntentButton: View {
    var intent: CaptureIntent
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: intent.symbolName)
                    .font(.system(size: 17, weight: .medium))
                Text(intent.shortTitle)
                    .font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .notchControlSurface(
                in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                reduceTransparency: reduceTransparency,
                emphasized: isHovered
            )
            .scaleEffect(NotchShotMotion.activeScale(
                isActive: isHovered,
                reduceMotion: reduceMotion,
                activeScale: 1.03
            ))
            .offset(y: NotchShotMotion.activeOffset(
                isActive: isHovered,
                reduceMotion: reduceMotion
            ))
        }
        .buttonStyle(NotchPressButtonStyle())
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .help(intent.title)
        .accessibilityLabel(intent.title)
    }
}

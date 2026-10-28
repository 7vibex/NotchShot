import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Capture menu

struct CaptureMenuContent: View {
    @Bindable var coordinator: AppCoordinator
    var metrics: NotchMetrics
    @Bindable private var recipeStore = CaptureRecipeStore.shared
    @State private var timer: CaptureTimer = .none

    private let primaryIntents: [CaptureIntent] = [.area, .window, .display]
    private let secondaryIntents: [CaptureIntent] = [.scrolling, .ocr, .previousArea]

    var body: some View {
        VStack(spacing: 7) {
            if metrics.hasPhysicalNotch {
                // The camera band used to stay empty above a "Capture" title
                // row, so the menu opened with a 45 pt black strip before any
                // control. The preset sits in the left wing and the timer and
                // close in the right; the island itself is the title.
                HStack(spacing: 0) {
                    recipePicker
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear
                        .frame(width: metrics.notchSize.width + NotchLayout.dictationCameraClearance)
                        .accessibilityHidden(true)
                    HStack(spacing: 6) {
                        timerPicker
                        closeButton
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(height: metrics.notchSize.height)
            } else {
                HStack(spacing: 8) {
                    Label("Capture", systemImage: "camera.viewfinder")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    recipePicker
                    timerPicker
                    closeButton
                }
                .frame(height: 28)
                .padding(.top, NotchIsland.Spacing.tight)
            }

            // Everything that *starts* something sits in this one row; the
            // strip below only navigates. Record used to be a red button in
            // the strip, mixed in with three page links.
            HStack(spacing: 7) {
                ForEach(primaryIntents) { intent in
                    CaptureIntentButton(intent: intent) {
                        coordinator.capture(intent, timer: timer)
                    }
                }

                Menu {
                    ForEach(RecordingTargetMode.allCases) { target in
                        Button {
                            coordinator.startRecording(mode: target)
                        } label: {
                            Label(target.title, systemImage: target.symbolName)
                        }
                    }
                } label: {
                    CaptureTileLabel(
                        title: "Record",
                        systemImage: "record.circle",
                        tint: IslandSystemColor.red
                    )
                }
                .islandMenuStyle()
                .help("Record the screen, a window, or an area")
                .accessibilityLabel("Record")
            }

            // One shape for all three: the borderless menu style drops a
            // custom label's background on macOS, so More used to draw as
            // bare text beside boxed History and Shelf.
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
                    if ExtrasPreferences.shared.songRecognitionEnabled {
                        Button {
                            SongRecognizer.shared.toggle()
                        } label: {
                            Label("What's This Song?", systemImage: "shazam.logo")
                        }
                    }
                    if !ExtrasPreferences.shared.pinnedShortcuts.isEmpty {
                        Section("Shortcuts") {
                            ForEach(ExtrasPreferences.shared.pinnedShortcuts, id: \.self) { name in
                                Button {
                                    coordinator.runShortcut(named: name)
                                } label: {
                                    Label(name, systemImage: "square.stack.3d.up")
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        coordinator.openProductivity(tool: .today)
                    } label: {
                        Label("Today", systemImage: ProductivityTool.today.symbolName)
                    }
                    if ExtrasPreferences.shared.showsAppSwitcher {
                        Button {
                            coordinator.openProductivity(tool: .apps)
                        } label: {
                            Label("Running Apps", systemImage: ProductivityTool.apps.symbolName)
                        }
                    }
                    if ExtrasPreferences.shared.reviewQueueEnabled {
                        Button {
                            coordinator.openProductivity(tool: .reviews)
                        } label: {
                            Label("Review Queue", systemImage: ProductivityTool.reviews.symbolName)
                        }
                    }
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
                    commandLabel("More", systemImage: "ellipsis")
                }
                .islandMenuStyle()
                .help("More capture modes, activities, and settings")

                Button {
                    coordinator.onOpenHistory?()
                } label: {
                    commandLabel("History", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(NotchPressButtonStyle())

                // The shelf had no route back once it timed out or was
                // dismissed. It is the surface a capture actually lands on, so
                // it belongs in the notch's own strip and not only in the
                // menu bar.
                Button {
                    coordinator.showShelf()
                } label: {
                    commandLabel("Shelf", systemImage: "tray.full")
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
        .padding(.top, metrics.hasPhysicalNotch ? 0 : 10)
        .padding(.bottom, 10)
    }

    private var recipePicker: some View {
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
            CaptureMenuPill(
                title: recipeStore.activeRecipe.name,
                systemImage: "wand.and.stars",
                maxWidth: 112
            )
        }
        .islandMenuStyle()
        .help("Capture preset: \(recipeStore.activeRecipe.detail)")
        .accessibilityLabel("Capture preset, \(recipeStore.activeRecipe.name)")
    }

    private var timerPicker: some View {
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
            CaptureMenuPill(
                title: timer == .none ? "Off" : timer.title,
                systemImage: "timer",
                isActive: timer != .none
            )
        }
        .islandMenuStyle()
        .help("Capture delay")
        .accessibilityLabel("Capture delay, \(timer.title)")
    }

    // The island's corner radius curves in behind the top row on external
    // displays, so the close button keeps an inset to stay on the flat part.
    private var closeButton: some View {
        Button {
            coordinator.collapse()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .frame(width: 24, height: 24)
                .islandControlSurface(Circle())
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .padding(.trailing, metrics.hasPhysicalNotch ? 2 : NotchIsland.Spacing.snug)
        .help("Close")
        .accessibilityLabel("Close")
    }

    private func commandLabel(_ title: String, systemImage: String) -> some View {
        CaptureCommandLabel(title: title, systemImage: systemImage)
    }
}

/// A pill that says it opens a menu: a fill, the value, and a chevron. The
/// preset and timer used to be bare 10 pt text that read as labels.
private struct CaptureMenuPill: View {
    var title: String
    var systemImage: String
    var isActive = false
    var maxWidth: CGFloat? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.islandInk(NotchIsland.Ink.secondary))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
        }
        .padding(.leading, 8)
        .padding(.trailing, 7)
        .frame(height: 24)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: maxWidth == nil, vertical: false)
        .islandControlSurface(Capsule(), isHovered: isHovered)
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
    }
}

extension View {
    /// Keeps a custom menu label's own surface; `.borderlessButton` strips it.
    func islandMenuStyle() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Split out so each command owns its own hover state; a shared `@State` on the
/// menu would light all three at once.
private struct CaptureCommandLabel: View {
    var title: String
    var systemImage: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .frame(maxWidth: .infinity, minHeight: 32)
        // Capsules sit on the island's bottom edge, where a 10 pt corner
        // fought the shell's 32 pt one. A capsule is as close to concentric
        // as a 32 pt-tall control gets.
        .contentShape(Capsule())
        .islandControlSurface(Capsule(), isHovered: isHovered)
        .scaleEffect(NotchShotMotion.activeScale(
            isActive: isHovered,
            reduceMotion: reduceMotion,
            activeScale: 1.03
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

    var body: some View {
        Button(action: action) {
            CaptureTileLabel(title: intent.shortTitle, systemImage: intent.symbolName)
        }
        .buttonStyle(NotchPressButtonStyle())
        .help(intent.title)
        .accessibilityLabel(intent.title)
    }
}

/// One tile of the capture row. Record shares the shape and takes the
/// system's recording red on its glyph only, so the row reads as four
/// peers rather than three tiles and an alarm.
private struct CaptureTileLabel: View {
    var title: String
    var systemImage: String
    var tint: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    /// Concentric with the island: 32 pt corners less the 12 pt inset,
    /// rounded down so the tile still reads as a tile.
    static let cornerRadius: CGFloat = 16

    var body: some View {
        VStack(spacing: 5) {
            // A fixed box: each symbol has its own height, and "Screen"
            // sat 2 pt lower than "Area" and "Window" because its glyph
            // was taller.
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 22)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .background(
            Color.islandInk(isHovered ? NotchIsland.Surface.hover : NotchIsland.Surface.control),
            in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        )
        // A lit top edge so the tiles read as raised above the strip.
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.12), .white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
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
    }
}

import AVFoundation
import AppKit
@preconcurrency import ApplicationServices
import ServiceManagement
import Speech
import SwiftUI
import UniformTypeIdentifiers

struct SettingsSidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .accessibilityLabel("Search settings")

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear settings search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.075))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SettingsWorkbenchStyle.keyline, lineWidth: 0.75)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

struct SettingsSidebarIdentity: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .systemGray).gradient)
                Text(UserIdentity.initials)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text(UserIdentity.fullName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("Apple Account")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsSidebarUpdateRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.gray.gradient)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Software Update")
                        .font(.system(size: 14))
                        .lineLimit(1)
                    Text("Available")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Text("1")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background {
                        Capsule().fill(Color.primary.opacity(0.12))
                    }
                    .accessibilityLabel("One update available")
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Software update available. Check for updates.")
    }
}

struct SettingsSidebarLabel: View {
    let section: SettingsSection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(section.symbolTint.gradient)
                }

            Text(section.sidebarTitle)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

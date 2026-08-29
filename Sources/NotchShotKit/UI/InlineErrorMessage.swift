import SwiftUI

/// A compact, reusable error treatment for window toolbars and form rows.
/// The symbol communicates the state without relying on color, while the text
/// uses the current label color so captions remain readable in both appearances.
struct InlineErrorMessage: View {
    var message: String
    var lineLimit: Int = 2

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.primary)
        }
        .font(.caption)
        .lineLimit(lineLimit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}

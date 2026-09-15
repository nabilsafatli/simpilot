import SwiftUI

/// One figure on the Dashboard.
///
/// Deliberately plain: no progress rings, no percentages of an invented total, no
/// colour coding that implies urgency. A count is shown as a count, and a size as
/// a size the user can check against Finder.
struct StatTile: View {
    let title: String
    let value: String
    var caption: String?
    var symbol: String
    /// Set only where the figure genuinely is an estimate rather than a count.
    var isEstimate: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

            Text(value)
                .font(.system(.title2, design: .rounded))
                .fontWeight(.medium)
                .contentTransition(.numericText())

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)\(isEstimate ? ", estimated" : "")")
    }
}

/// A short, honest note about where a number came from.
struct EstimateFootnote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

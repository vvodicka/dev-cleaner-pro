import SwiftUI
import DevCleanerProCore

/// The capsule tag beside every row: tinted fill, hairline border, and a label that is always
/// present — the design is explicit that colour alone must never carry the meaning.
///
/// Geometry from the component spec: 10.5 pt semibold, 1.5x7 padding, radius 9.
struct RiskBadge: View {
    let risk: Risk

    var body: some View {
        Text(risk.displayLabel)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color(risk.colorAssetPrefix + "Text"))
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(risk.colorAssetPrefix + "Fill"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color(risk.colorAssetPrefix + "Border"), lineWidth: 1)
            )
            .help(risk.explanation)
            .accessibilityLabel("Risk: \(risk.displayLabel). \(risk.explanation)")
    }
}

#Preview {
    HStack(spacing: 10) {
        ForEach(Risk.allCases, id: \.self) { RiskBadge(risk: $0) }
    }
    .padding()
}

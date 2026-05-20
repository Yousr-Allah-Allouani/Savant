import SwiftUI

struct HSLCircularPickerView: View {
    @Binding var selectedLightHex: String
    @Binding var selectedDarkHex: String

    private let palette: [(name: String, light: String, dark: String)] = [
        ("Warm Tan", "#E5D4B7", "#3A2F22"),
        ("Sage", "#C8D5C0", "#2A3328"),
        ("Lavender", "#D5CCE0", "#2E2A38"),
        ("Slate", "#C5CDD3", "#293138"),
        ("Terracotta", "#D9B5A0", "#3D2820"),
        ("Olive", "#C3C19A", "#33321F"),
        ("Ink", "#B0B5C0", "#1E222B"),
        ("Fog", "#D7DCE0", "#2C3035"),
        ("Sand", "#E3D5BA", "#3B3122"),
        ("Plum", "#C7B0BC", "#322028"),
        ("Moss", "#B8C5A8", "#2B3322"),
        ("Rust", "#CC9F8A", "#3A211A")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Color")
                .font(.system(.headline, design: .rounded))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(palette, id: \.name) { swatch in
                    Button {
                        selectedLightHex = swatch.light
                        selectedDarkHex = swatch.dark
                    } label: {
                        VStack(spacing: 7) {
                            Circle()
                                .fill(Color(hex: swatch.light))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if selectedLightHex == swatch.light {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.primary)
                                    }
                                }
                            Text(swatch.name)
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                }
            }

            Text("Savant keeps spaces in a muted range so the full-screen color stays comfortable.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

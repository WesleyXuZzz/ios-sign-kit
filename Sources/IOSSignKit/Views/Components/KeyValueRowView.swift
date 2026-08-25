import SwiftUI

struct KeyValueRowView: View {
    let label: String
    let value: String
    let annotation: String?
    let detail: String?
    let emphasizeValue: Bool
    let valueTone: StatusTone?
    let annotationTone: StatusTone?
    let detailTone: StatusTone?
    let usesStrongLabel: Bool

    init(
        label: String,
        value: String,
        annotation: String? = nil,
        detail: String? = nil,
        emphasizeValue: Bool = false,
        valueTone: StatusTone? = nil,
        annotationTone: StatusTone? = nil,
        detailTone: StatusTone? = nil,
        usesStrongLabel: Bool = false
    ) {
        self.label = label
        self.value = value
        self.annotation = annotation
        self.detail = detail
        self.emphasizeValue = emphasizeValue
        self.valueTone = valueTone
        self.annotationTone = annotationTone
        self.detailTone = detailTone
        self.usesStrongLabel = usesStrongLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(labelForegroundColor)
                .tracking(0.3)

            valueText
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let detail {
                Text(detail)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(detailForegroundColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var valueText: Text {
        var text = Text(value)
            .font(emphasizeValue ? .body.weight(.semibold) : .body.weight(.medium))
            .foregroundColor(valueForegroundColor)

        if let annotation {
            text = text + Text("（\(annotation)）")
                .font(.footnote.weight(.medium))
                .foregroundColor(annotationForegroundColor)
        }

        return text
    }

    private var valueForegroundColor: Color {
        valueTone?.color ?? Color.primary.opacity(emphasizeValue ? 0.96 : 0.88)
    }

    private var labelForegroundColor: Color {
        usesStrongLabel ? Color.primary.opacity(0.62) : Color.secondary
    }

    private var annotationForegroundColor: Color {
        annotationTone?.color ?? Color.secondary.opacity(0.78)
    }

    private var detailForegroundColor: Color {
        detailTone?.color ?? Color.secondary.opacity(0.78)
    }
}

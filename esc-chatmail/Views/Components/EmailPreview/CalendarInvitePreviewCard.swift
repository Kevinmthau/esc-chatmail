import SwiftUI

struct CalendarInvitePreviewCard: View {
    let model: CalendarInvitePreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(alignment: .top, spacing: 14) {
                dateRail

                VStack(alignment: .leading, spacing: 8) {
                    Text(model.title)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    metadataRow(
                        systemName: "clock",
                        text: model.dateTimeLine,
                        color: .primary,
                        weight: .semibold
                    )

                    if let locationLine = model.locationLine, !locationLine.isEmpty {
                        metadataRow(
                            systemName: locationLine.lowercased().contains("meet") ? "video" : "mappin.and.ellipse",
                            text: locationLine,
                            color: .secondary,
                            weight: .medium
                        )
                    }

                    if let organizerLine = model.organizerLine, !organizerLine.isEmpty {
                        metadataRow(
                            systemName: "person.2",
                            text: organizerLine,
                            color: .secondary,
                            weight: .regular
                        )
                    }

                    footer
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 144, alignment: .leading)
        .emailPreviewCardChrome()
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if let sourceLabel = model.sourceLabel, !sourceLabel.isEmpty {
                Text(sourceLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.blue)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let status = model.status, !status.isEmpty {
                Text(status)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill))
                    )
                    .lineLimit(1)
            }
        }
    }

    private var dateRail: some View {
        VStack(spacing: 4) {
            Text(model.monthSymbol)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)

            Text(model.dayNumber)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if !model.weekdaySymbol.isEmpty {
                Text(model.weekdaySymbol)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
        }
        .frame(width: 70, height: 92)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.blue.gradient)
        )
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 12, weight: .semibold))
            Text(model.actionLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(Color.blue)
        .padding(.top, 2)
    }

    private func metadataRow(
        systemName: String,
        text: String,
        color: Color,
        weight: Font.Weight
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14, alignment: .center)

            Text(text)
                .font(.system(size: 13, weight: weight, design: .default))
                .foregroundStyle(color)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }
}

import SwiftUI

/// Closed-notch indicator shown when an unread WhatsApp message arrives.
/// Sits next to the notch and previews the latest message.
struct WhatsAppNudge: View {
    @ObservedObject private var manager = WhatsAppManager.shared
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                Text(manager.contactName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(width: 84, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width + 10)

            Text(previewText)
                .font(.system(size: 11))
                .foregroundStyle(.gray)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 110, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    private var previewText: String {
        guard let message = manager.latestPreview else { return "New message" }
        if message.isAudio { return "Voice message" }
        if message.text.isEmpty { return message.type == "image" ? "Photo" : "New message" }
        return message.text
    }
}

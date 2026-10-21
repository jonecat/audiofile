import SwiftUI

public struct ToastMessage: Identifiable, Equatable {
    public let id = UUID()
    public let icon: String
    public let message: String
    public let iconColor: Color?

    public init(icon: String, message: String, iconColor: Color? = nil) {
        self.icon = icon
        self.message = message
        self.iconColor = iconColor
    }
}

public struct ToastView: View {
    public let toast: ToastMessage

    public init(toast: ToastMessage) {
        self.toast = toast
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(toast.iconColor ?? .accentColor)

            Text(toast.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 5)
        )
        .contentShape(Capsule())
        .help("Dismiss notification")
    }
}

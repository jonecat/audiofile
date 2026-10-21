import SwiftUI
import AppKit

public struct DragHandleView: View {
    public let helpText: String

    public init(helpText: String = "Drag to reorder") {
        self.helpText = helpText
    }

    public var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
            .help(helpText)
            .onHover { inside in
                if inside {
                    NSCursor.openHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

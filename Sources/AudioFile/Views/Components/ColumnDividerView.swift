import SwiftUI
import AppKit

public struct ColumnDividerView: View {
    public let onDragChange: (CGFloat, Bool) -> Void
    public let onDoubleClick: (() -> Void)?

    public init(
        onDragChange: @escaping (CGFloat, Bool) -> Void,
        onDoubleClick: (() -> Void)? = nil
    ) {
        self.onDragChange = onDragChange
        self.onDoubleClick = onDoubleClick
    }

    public var body: some View {
        ZStack {
            // Subtle Hairline Divider
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)

            // Transparent hit target for easy mouse grabbing
            Rectangle()
                .fill(Color.clear)
                .frame(width: 9)
                .contentShape(Rectangle())
        }
        .frame(width: 9)
        .onHover { inside in
            if inside {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    onDragChange(value.translation.width, false)
                }
                .onEnded { value in
                    onDragChange(value.translation.width, true)
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onDoubleClick?()
            }
        )
        .help("Drag to resize columns (double-click to reset)")
    }
}

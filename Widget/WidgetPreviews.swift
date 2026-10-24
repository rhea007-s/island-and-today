import SwiftUI
import WidgetKit

// Xcode canvas renders accessory families with the real vibrant Lock Screen
// treatment, so these previews are the fastest way to judge the widget —
// no build-install-lock cycle. Open any of them and hit Resume.

#Preview("Rectangular", as: .accessoryRectangular) {
    TodayWidget()
} timeline: {
    DayEntry(date: .now, snapshot: .preview)
    DayEntry(date: .now, snapshot: .previewLongTitle)
    DayEntry(date: .now, snapshot: .previewAllDone)
    DayEntry(date: .now, snapshot: .previewEmpty)
}

#Preview("Circular", as: .accessoryCircular) {
    TodayWidget()
} timeline: {
    DayEntry(date: .now, snapshot: .previewEmpty)
    DayEntry(date: .now, snapshot: .preview)
    DayEntry(date: .now, snapshot: .previewAllDone)
}

#Preview("Inline", as: .accessoryInline) {
    TodayWidget()
} timeline: {
    DayEntry(date: .now, snapshot: .preview)
    DayEntry(date: .now, snapshot: .previewAllDone)
    DayEntry(date: .now, snapshot: .previewEmpty)
}

#Preview("Home Screen", as: .systemSmall) {
    TodayWidget()
} timeline: {
    DayEntry(date: .now, snapshot: .preview)
    DayEntry(date: .now, snapshot: .previewAllDone)
}

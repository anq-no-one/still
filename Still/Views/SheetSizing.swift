import SwiftUI

extension View {
    /// Sheets size themselves on the Mac, where a window has no width of its
    /// own. On iPhone and iPad the system already knows the width, and a fixed
    /// minimum wider than the screen only forces the content to overflow.
    func stillSheetWidth(mac width: CGFloat, minHeight: CGFloat? = nil) -> some View {
        #if os(macOS)
        return frame(minWidth: width, idealWidth: width + 60, minHeight: minHeight)
        #else
        return frame(maxWidth: .infinity)
        #endif
    }
}

extension View {
    /// A Mac Settings window names itself after the selected tab, so only the
    /// iPhone and iPad navigation stack takes the pane's own title.
    func settingsPaneTitle(_ title: LocalizedStringKey) -> some View {
        #if os(iOS)
        return navigationTitle(title)
        #else
        return self
        #endif
    }
}

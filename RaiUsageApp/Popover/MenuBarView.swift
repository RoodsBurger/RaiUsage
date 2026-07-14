import SwiftUI

/// The menu bar dropdown. Thin host around the single fixed `PopoverView`
/// layout - kept as its own type (rather than using `PopoverView` directly in
/// `StatusBarController`) so the popover's entry point stays stable if the
/// content view is ever swapped again.
struct MenuBarPopoverView: View {
    var body: some View {
        PopoverView()
    }
}

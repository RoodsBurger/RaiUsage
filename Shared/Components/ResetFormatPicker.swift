import SwiftUI

struct ResetFormatPicker: View {
    @Binding var selection: ResetDisplayFormat

    var body: some View {
        DSMenu(
            selection: $selection,
            options: ResetDisplayFormat.allCases,
            label: { $0.localizedLabel }
        )
    }
}

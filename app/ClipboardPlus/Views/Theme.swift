import SwiftUI
import UIKit

enum Theme {
    /// The app's blue, a little lighter in dark mode so it stays readable on dark cards.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.64, blue: 1.0, alpha: 1)
            : UIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1)
    })
    static let page = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let field = Color(uiColor: .tertiarySystemFill)
    static let cardRadius: CGFloat = 14
}

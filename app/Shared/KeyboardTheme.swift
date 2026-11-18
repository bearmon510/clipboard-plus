import SwiftUI
import UIKit

enum KeyboardTheme {
    static let accentUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.50, green: 0.69, blue: 1.0, alpha: 1)
            : UIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1)
    }

    /// Vivid blue background for filled keys/buttons with white text (e.g. Return, Save).
    /// Keeps >= 4.5:1 WCAG contrast with white foreground in both light and dark appearances.
    static let accentKeyUIColor = UIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1)

    static let specialKeyUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.25, alpha: 0.92)
            : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 0.55)
    }

    static let letterKeyUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.38, alpha: 0.95)
            : UIColor.white
    }

    static let accent = Color(uiColor: accentUIColor)
    static let accentKey = Color(uiColor: accentKeyUIColor)
    static let page = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let field = Color(uiColor: .tertiarySystemFill)
    static let letterKey = Color(uiColor: letterKeyUIColor)
    static let specialKey = Color(uiColor: specialKeyUIColor)
    static let cardRadius: CGFloat = 10
    static let keyRadius: CGFloat = 6
}

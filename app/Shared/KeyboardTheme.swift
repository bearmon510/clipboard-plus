import SwiftUI
import UIKit

enum KeyboardTheme {
    static let accentUIColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.64, blue: 1.0, alpha: 1)
            : UIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1)
    }

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
    static let page = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let field = Color(uiColor: .tertiarySystemFill)
    static let letterKey = Color(uiColor: letterKeyUIColor)
    static let specialKey = Color(uiColor: specialKeyUIColor)
    static let cardRadius: CGFloat = 12
    static let keyRadius: CGFloat = 6
}

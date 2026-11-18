import SwiftUI

struct KeyboardAlphanumericView: View {
    @ObservedObject var model: KeyboardViewModel
    let globeButtonSlot: AnyView?

    private static let row1Letters = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
    private static let row2Letters = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
    private static let row3Letters = ["z", "x", "c", "v", "b", "n", "m"]

    private static let row1Numbers = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    private static let row2Numbers = ["-", "/", ":", ";", "(", ")", "&", "@", "\"", "'"]
    private static let row3Numbers = [".", ",", "?", "!", "_", "#", "%"]

    private static let row1Symbols = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
    private static let row2Symbols = ["_", "\\", "|", "~", "<", ">", "$", "¥", "€", "•"]
    private static let row3Symbols = [".", ",", "?", "!", "'", "-", "/"]

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 600
            let keySpacing: CGFloat = isWide ? 7 : 4
            let rowSpacing: CGFloat = proxy.size.height < 235 ? 5 : 8
            let sidePadding: CGFloat = isWide ? 10 : 4
            let keyHeight = KeyboardLayoutMetrics.keyHeight(
                idiom: isWide ? .pad : .phone,
                availableHeight: proxy.size.height
            )
            let modifierWidth: CGFloat = isWide ? 58 : 44

            VStack(spacing: rowSpacing) {
                Spacer(minLength: 0)
                switch model.alphanumericPage {
                case .letters:
                    characterRow(
                        Self.row1Letters.map { model.shiftState.isUppercased ? $0.uppercased() : $0 },
                        spacing: keySpacing,
                        keyHeight: keyHeight
                    )
                    HStack(spacing: keySpacing) {
                        Spacer(minLength: isWide ? 24 : 12)
                        characterRow(
                            Self.row2Letters.map { model.shiftState.isUppercased ? $0.uppercased() : $0 },
                            spacing: keySpacing,
                            keyHeight: keyHeight
                        )
                        Spacer(minLength: isWide ? 24 : 12)
                    }
                    HStack(spacing: keySpacing) {
                        shiftKey(width: modifierWidth, height: keyHeight)
                        characterRow(
                            Self.row3Letters.map { model.shiftState.isUppercased ? $0.uppercased() : $0 },
                            spacing: keySpacing,
                            keyHeight: keyHeight
                        )
                        KeyboardRepeatableDeleteKey(keyHeight: keyHeight, width: modifierWidth) {
                            model.tapDelete()
                        }
                    }
                case .numbers:
                    characterRow(Self.row1Numbers, spacing: keySpacing, keyHeight: keyHeight)
                    characterRow(Self.row2Numbers, spacing: keySpacing, keyHeight: keyHeight)
                    HStack(spacing: keySpacing) {
                        specialActionKey("#+=", width: modifierWidth, height: keyHeight, labelFont: .caption.weight(.medium)) {
                            model.alphanumericPage = .symbols
                        }
                        characterRow(Self.row3Numbers, spacing: keySpacing, keyHeight: keyHeight)
                        KeyboardRepeatableDeleteKey(keyHeight: keyHeight, width: modifierWidth) {
                            model.tapDelete()
                        }
                    }
                case .symbols:
                    characterRow(Self.row1Symbols, spacing: keySpacing, keyHeight: keyHeight)
                    characterRow(Self.row2Symbols, spacing: keySpacing, keyHeight: keyHeight)
                    HStack(spacing: keySpacing) {
                        specialActionKey("123", width: modifierWidth, height: keyHeight, labelFont: .caption.weight(.medium)) {
                            model.alphanumericPage = .numbers
                        }
                        characterRow(Self.row3Symbols, spacing: keySpacing, keyHeight: keyHeight)
                        KeyboardRepeatableDeleteKey(keyHeight: keyHeight, width: modifierWidth) {
                            model.tapDelete()
                        }
                    }
                }
                bottomRow(isWide: isWide, spacing: keySpacing, keyHeight: keyHeight)
            }
            .padding(.horizontal, sidePadding)
            .padding(.vertical, proxy.size.height < 235 ? 4 : 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func characterRow(_ keys: [String], spacing: CGFloat, keyHeight: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(keys, id: \.self) { key in
                Button {
                    model.tapCharacter(key)
                } label: {
                    Text(key)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: keyHeight)
                }
                .buttonStyle(KeyboardKeyCapStyle(background: KeyboardTheme.letterKey))
            }
        }
    }

    private func shiftKey(width: CGFloat, height: CGFloat) -> some View {
        let isActive = model.shiftState.isUppercased
        let symbol = model.shiftState == .locked ? "capslock.fill" : (isActive ? "shift.fill" : "shift")
        return Button {
            model.toggleShift()
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(isActive ? KeyboardTheme.accent : Color.primary)
                .frame(width: width, height: height)
        }
        .buttonStyle(KeyboardKeyCapStyle(background: isActive ? KeyboardTheme.letterKey : KeyboardTheme.specialKey))
        .accessibilityLabel(model.shiftState == .locked ? "Caps Lock" : "シフト")
    }

    private func specialActionKey(
        _ title: String,
        width: CGFloat?,
        height: CGFloat,
        labelFont: Font = .subheadline.weight(.medium),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(labelFont)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .frame(maxWidth: width == nil ? .infinity : nil)
                .frame(width: width, height: height)
        }
        .buttonStyle(KeyboardKeyCapStyle(background: KeyboardTheme.specialKey))
    }

    private func bottomRow(isWide: Bool, spacing: CGFloat, keyHeight: CGFloat) -> some View {
        let compactWidth: CGFloat = isWide ? 60 : 44
        let backWidth: CGFloat = isWide ? 72 : 54
        let returnWidth: CGFloat = isWide ? 84 : 60

        return HStack(spacing: spacing) {
            if model.needsInputModeSwitchKey {
                KeyboardGlobeKeyContainer(keyHeight: keyHeight, width: compactWidth, slot: globeButtonSlot)
            }
            Button {
                model.switchToList()
            } label: {
                Text("履歴")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KeyboardTheme.accent)
                    .lineLimit(1)
                    .frame(width: backWidth, height: keyHeight)
            }
            .buttonStyle(KeyboardKeyCapStyle(background: KeyboardTheme.specialKey))
            .accessibilityLabel("履歴とテンプレートに戻る")

            if model.alphanumericPage == .letters {
                specialActionKey("123", width: compactWidth, height: keyHeight) {
                    model.alphanumericPage = .numbers
                }
            } else {
                specialActionKey("ABC", width: compactWidth, height: keyHeight) {
                    model.alphanumericPage = .letters
                }
            }

            Button {
                model.tapSpace()
            } label: {
                Text("空白")
                    .font(.subheadline)
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: keyHeight)
            }
            .buttonStyle(KeyboardKeyCapStyle(background: KeyboardTheme.letterKey))
            .accessibilityLabel("空白")

            Button {
                model.tapReturn()
            } label: {
                Text("改行")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: returnWidth, height: keyHeight)
            }
            .buttonStyle(KeyboardKeyCapStyle(background: KeyboardTheme.accent))
            .accessibilityLabel("改行")
        }
    }
}

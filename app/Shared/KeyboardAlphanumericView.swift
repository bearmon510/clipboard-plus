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
            let rowCount = model.alphanumericPage == .letters ? 5 : 4
            let metrics = KeyboardLayoutMetrics.alphanumericMetrics(
                width: proxy.size.width,
                availableHeight: proxy.size.height,
                rowCount: rowCount
            )

            VStack(spacing: metrics.rowSpacing) {
                Spacer(minLength: 0)
                switch model.alphanumericPage {
                case .letters:
                    characterRow(
                        Self.row1Numbers,
                        spacing: metrics.keySpacing,
                        keyHeight: metrics.keyHeight,
                        fontSize: metrics.keyFontSize
                    )
                    characterRow(
                        Self.row1Letters.map { model.shiftState.isUppercased ? $0.uppercased() : $0 },
                        spacing: metrics.keySpacing,
                        keyHeight: metrics.keyHeight,
                        fontSize: metrics.keyFontSize
                    )
                    HStack(spacing: metrics.keySpacing) {
                        Spacer(minLength: metrics.row2Indent)
                        characterRow(
                            Self.row2Letters.map { model.shiftState.isUppercased ? $0.uppercased() : $0 },
                            spacing: metrics.keySpacing,
                            keyHeight: metrics.keyHeight,
                            fontSize: metrics.keyFontSize
                        )
                        Spacer(minLength: metrics.row2Indent)
                    }
                    HStack(spacing: metrics.keySpacing) {
                        shiftKey(width: metrics.modifierWidth, height: metrics.keyHeight)
                        characterRow(
                            Self.row3Letters.map { model.shiftState.isUppercased ? $0.uppercased() : $0 },
                            spacing: metrics.keySpacing,
                            keyHeight: metrics.keyHeight,
                            fontSize: metrics.keyFontSize
                        )
                        KeyboardRepeatableDeleteKey(keyHeight: metrics.keyHeight, width: metrics.modifierWidth) {
                            model.tapDelete()
                        }
                    }
                case .numbers:
                    characterRow(
                        Self.row1Numbers,
                        spacing: metrics.keySpacing,
                        keyHeight: metrics.keyHeight,
                        fontSize: metrics.keyFontSize
                    )
                    characterRow(
                        Self.row2Numbers,
                        spacing: metrics.keySpacing,
                        keyHeight: metrics.keyHeight,
                        fontSize: metrics.keyFontSize
                    )
                    HStack(spacing: metrics.keySpacing) {
                        specialActionKey("#+=", width: metrics.modifierWidth, height: metrics.keyHeight, labelFont: .caption.weight(.medium)) {
                            model.alphanumericPage = .symbols
                        }
                        characterRow(
                            Self.row3Numbers,
                            spacing: metrics.keySpacing,
                            keyHeight: metrics.keyHeight,
                            fontSize: metrics.keyFontSize
                        )
                        KeyboardRepeatableDeleteKey(keyHeight: metrics.keyHeight, width: metrics.modifierWidth) {
                            model.tapDelete()
                        }
                    }
                case .symbols:
                    characterRow(
                        Self.row1Symbols,
                        spacing: metrics.keySpacing,
                        keyHeight: metrics.keyHeight,
                        fontSize: metrics.keyFontSize
                    )
                    characterRow(
                        Self.row2Symbols,
                        spacing: metrics.keySpacing,
                        keyHeight: metrics.keyHeight,
                        fontSize: metrics.keyFontSize
                    )
                    HStack(spacing: metrics.keySpacing) {
                        specialActionKey("123", width: metrics.modifierWidth, height: metrics.keyHeight, labelFont: .caption.weight(.medium)) {
                            model.alphanumericPage = .numbers
                        }
                        characterRow(
                            Self.row3Symbols,
                            spacing: metrics.keySpacing,
                            keyHeight: metrics.keyHeight,
                            fontSize: metrics.keyFontSize
                        )
                        KeyboardRepeatableDeleteKey(keyHeight: metrics.keyHeight, width: metrics.modifierWidth) {
                            model.tapDelete()
                        }
                    }
                }
                bottomRow(metrics: metrics)
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.top, metrics.topPadding)
            .padding(.bottom, metrics.bottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func characterRow(_ keys: [String], spacing: CGFloat, keyHeight: CGFloat, fontSize: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(keys, id: \.self) { key in
                Button {
                    model.tapCharacter(key)
                } label: {
                    Text(key)
                        .font(.system(size: fontSize, weight: .regular))
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

    private func bottomRow(metrics: KeyboardAlphanumericMetrics) -> some View {
        HStack(spacing: metrics.keySpacing) {
            if model.needsInputModeSwitchKey {
                KeyboardGlobeKeyContainer(
                    keyHeight: metrics.keyHeight,
                    width: metrics.compactBottomWidth,
                    slot: globeButtonSlot
                )
            }
            Button {
                model.switchToList()
            } label: {
                Text("履歴")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KeyboardTheme.accent)
                    .lineLimit(1)
                    .frame(width: metrics.backWidth, height: metrics.keyHeight)
            }
            .buttonStyle(KeyboardKeyCapStyle(background: KeyboardTheme.specialKey))
            .accessibilityLabel("履歴とテンプレートに戻る")

            if model.alphanumericPage == .letters {
                specialActionKey("123", width: metrics.compactBottomWidth, height: metrics.keyHeight) {
                    model.alphanumericPage = .numbers
                }
            } else {
                specialActionKey("ABC", width: metrics.compactBottomWidth, height: metrics.keyHeight) {
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
                    .frame(height: metrics.keyHeight)
            }
            .buttonStyle(KeyboardKeyCapStyle(background: KeyboardTheme.letterKey))
            .accessibilityLabel("空白")

            Button {
                model.tapReturn()
            } label: {
                Text("改行")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: metrics.returnWidth, height: metrics.keyHeight)
            }
            .buttonStyle(KeyboardKeyCapStyle(background: KeyboardTheme.accentKey))
            .accessibilityLabel("改行")
        }
    }
}

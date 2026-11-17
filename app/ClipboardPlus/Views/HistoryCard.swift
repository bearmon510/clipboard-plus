import SwiftUI

/// One history item. Tapping copies it, dragging takes it to another app, and the
/// trailing menu or a long press offers the remaining actions.
struct HistoryCard<Actions: View>: View {
    let entry: HistoryEntry
    let thumbnailURL: URL?
    let timeLabel: String
    let query: String
    let isCopied: Bool
    let onCopy: () -> Void
    let dragProvider: () -> NSItemProvider
    @ViewBuilder let actions: () -> Actions

    @State private var freshness: Double = 0
    @State private var isExpanded = false
    /// Heights of the text as shown and of the same text with no line limit, to tell whether
    /// four lines cut it off. Measured on screen, so the answer fits the card's real width.
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    /// The most text a card shows when opened in place. Longer texts open in full from the menu.
    /// (A computed value, because a generic type cannot hold a static stored property.)
    private static var expandedLimit: Int { 3_000 }

    private var flavor: EntryFlavor { EntryFlavor.detect(entry) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onCopy) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let title = entry.displayTitle {
                            // The name the user gave it, such as 署名 or 住所. No tag icon: the tag
                            // is the group the card sits in, not this name.
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                                .padding(.bottom, -4)
                        }
                        content
                        meta
                    }
                    .padding(12)
                    // The expand button sits under the meta line, outside the copy button.
                    .padding(.bottom, isExpandable ? -8 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .opacity(isCopied ? 0.25 : 1)
                }
                .buttonStyle(CardPressStyle())
                .onDrag(dragProvider)
                .accessibilityHint("タップでコピー。ドラッグでほかのアプリへ持ち出せます。")
                if isExpandable { expandButton }
            }
            menuButton
        }
        .background(Theme.card, in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 1).allowsHitTesting(false))
        .overlay(shape.strokeBorder(Theme.accent.opacity(freshness), lineWidth: 2).allowsHitTesting(false))
        .overlay { copiedBadge }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isCopied)
        .contextMenu { actions() }
        .onAppear { flashIfFresh() }
        .onChange(of: entry.lastCollectedAt) { _, _ in flashIfFresh() }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch flavor {
        case .image:
            imageContent
        case .file:
            fileContent
        case .color(let red, let green, let blue):
            colorContent(Color(red: red, green: green, blue: blue))
        case .link:
            if query.isEmpty, let link = EntryLinks.parts(entry.text) {
                linkContent(link)
            } else {
                textContent
            }
        case .text, .email, .phone:
            textContent
        }
    }

    private var textContent: some View {
        Text(highlightedText)
            .font(.body)
            .lineLimit(isExpanded ? nil : 4)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(heightReader { shownHeight = $0 })
            .background(alignment: .topLeading) {
                // The same text without a line limit, invisible, only to measure its height.
                Text(highlightedText)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .background(heightReader { fullHeight = $0 })
                    .accessibilityHidden(true)
            }
    }

    private func heightReader(_ update: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { update(proxy.size.height) }
                .onChange(of: proxy.size.height) { _, height in update(height) }
        }
    }

    /// Whether the text is likely cut off at four lines, so that an expand button is worth showing.
    private var isExpandable: Bool {
        switch flavor {
        case .image, .color, .file: return false
        case .link: if query.isEmpty && EntryLinks.parts(entry.text) != nil { return false }
        case .text, .email, .phone: break
        }
        // Texts longer than the preview are always cut, whatever the width.
        return isExpanded || entry.characterCount > EntryPreview.limit || fullHeight > shownHeight + 1
    }

    private var expandButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(isExpanded ? "たたむ" : "続きを表示")
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "たたむ" : "続きを表示")
    }

    private var highlightedText: AttributedString {
        if entry.text.isEmpty { return AttributedString("（空文字）") }
        let snippet = EntryPreview.snippet(entry.text, query: query,
                                           limit: isExpanded ? Self.expandedLimit : EntryPreview.limit)
        var result = AttributedString()
        var cursor = snippet.text.startIndex
        for match in snippet.matches {
            result += AttributedString(String(snippet.text[cursor..<match.lowerBound]))
            var piece = AttributedString(String(snippet.text[match]))
            piece.swiftUI.backgroundColor = Theme.accent.opacity(0.22)
            piece.swiftUI.font = .body.weight(.semibold)
            result += piece
            cursor = match.upperBound
        }
        result += AttributedString(String(snippet.text[cursor...]))
        if isExpanded && entry.characterCount > Self.expandedLimit {
            result += AttributedString("…（全文は「⋯」→「全文を表示」）")
        }
        return result
    }

    private func linkContent(_ link: EntryLink) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(link.host)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
            if let remainder = link.remainder {
                Text(remainder)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colorContent(_ color: Color) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color)
                .frame(width: 40, height: 40)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .accessibilityHidden(true)
            Text(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.body.monospaced())
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var imageContent: some View {
        if let thumbnailURL {
            HistoryFileImage(url: thumbnailURL, maximumPixels: 480, cornerRadius: 9)
                .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 150, alignment: .leading)
                .accessibilityLabel("画像")
        }
    }

    /// A document icon in its type's color beside the original name, like a file in the Files app.
    @ViewBuilder private var fileContent: some View {
        if let file = entry.file {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: file.symbolName)
                    .font(.title2)
                    .foregroundStyle(Color.teal)
                    .frame(width: 46, height: 54)
                    .background(Color.teal.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                Text(file.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("ファイル \(file.displayName)")
        }
    }

    // MARK: Meta line

    private var meta: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.file?.symbolName ?? flavor.symbolName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(metaText).lineLimit(1)
            // A template is not collected, so its count says nothing useful.
            if entry.collectionCount > 1 && !entry.isTemplate {
                Text("×\(entry.collectionCount)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.field, in: Capsule())
                    .accessibilityLabel("\(entry.collectionCount)回コピー")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        // Leaves room for the menu button in the corner.
        .padding(.trailing, 32)
    }

    private var metaText: String {
        var parts: [String] = []
        if let image = entry.image {
            parts.append("\(image.pixelWidth)×\(image.pixelHeight)")
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .decimal))
        } else if let file = entry.file {
            parts.append(file.typeDescription)
            parts.append(file.sizeDescription)
        } else if entry.characterCount > EntryPreview.limit {
            parts.append("\(entry.characterCount.formatted())文字")
        }
        // Templates pass no time: when they were made does not help to choose one.
        if !timeLabel.isEmpty { parts.append(timeLabel) }
        return parts.joined(separator: "・")
    }

    private var tint: Color {
        switch flavor {
        case .text: return Color.secondary
        case .link: return Theme.accent
        case .email, .phone: return Color.green
        case .color: return Color.pink
        case .image: return Color.purple
        case .file: return Color.teal
        }
    }

    private var menuButton: some View {
        Menu {
            actions()
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.semibold))
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        // The menu label takes its color from the tint, not from a foreground style.
        .tint(Color(uiColor: .secondaryLabel))
        .accessibilityLabel("この項目の操作")
    }

    // MARK: Feedback

    @ViewBuilder private var copiedBadge: some View {
        if isCopied {
            Label("コピーしました", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.accent, in: Capsule())
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    /// A short outline shows which item has just arrived or moved to the top.
    private func flashIfFresh() {
        guard Date().timeIntervalSince(entry.lastCollectedAt) < 3 else { return }
        withAnimation(.easeOut(duration: 0.15)) { freshness = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeOut(duration: 1.6)) { freshness = 0 }
        }
    }
}

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

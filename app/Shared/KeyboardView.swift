import SwiftUI
import UIKit

struct KeyboardView: View {
    @ObservedObject var model: KeyboardViewModel
    let globeButtonSlot: AnyView?
    let pasteControlSlot: AnyView?

    init(
        model: KeyboardViewModel,
        globeButtonSlot: AnyView? = nil,
        pasteControlSlot: AnyView? = nil
    ) {
        self.model = model
        self.globeButtonSlot = globeButtonSlot
        self.pasteControlSlot = pasteControlSlot
    }

    var body: some View {
        Group {
            switch model.mode {
            case .list:
                listBody
            case .alphanumeric:
                KeyboardAlphanumericView(model: model, globeButtonSlot: globeButtonSlot)
            }
        }
        .tint(KeyboardTheme.accent)
        .animation(.easeOut(duration: 0.18), value: model.flashedEntryID)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.statusMessage)
    }

    // MARK: - List Face

    private var listBody: some View {
        GeometryReader { proxy in
            let isCompactHeight = proxy.size.height > 0 && proxy.size.height < 235
            let metrics = KeyboardLayoutMetrics.listMetrics(
                width: proxy.size.width,
                availableHeight: proxy.size.height
            )

            VStack(spacing: 0) {
                if model.showsSaveClipboardButton {
                    fullAccessTopBar(metrics: metrics)
                        .layoutPriority(1)
                }
                ZStack(alignment: .bottom) {
                    listContent(
                        width: proxy.size.width,
                        isCompactHeight: isCompactHeight,
                        topPadding: model.showsSaveClipboardButton ? 2 : 6
                    )
                    statusToast
                }
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                listBottomBar(metrics: metrics)
                    .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fullAccessTopBar(metrics: KeyboardListMetrics) -> some View {
        HStack(spacing: 8) {
            Text(pasteControlSlot == nil ? "クリップボード" : "直前のコピーを保存")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let pasteControlSlot {
                pasteControlSlot
            } else {
                Button {
                    model.saveFromPasteboard()
                } label: {
                    Label("今のコピーを保存", systemImage: "doc.on.clipboard")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(KeyboardTheme.accentKey)
                .layoutPriority(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, metrics.topBarVerticalPadding)
    }

    @ViewBuilder
    private func listContent(width: CGFloat, isCompactHeight: Bool, topPadding: CGFloat) -> some View {
        switch model.loadState {
        case .loading:
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            guidanceScrollView(
                symbol: "doc.on.clipboard",
                title: "clipboard+ を一度開くと、ここに履歴が出ます",
                subtitle: "本体アプリを開くと、コピーした履歴とテンプレートが使えます。",
                isCompactHeight: isCompactHeight
            )
        case .loaded:
            let columns = KeyboardLayoutMetrics.columnCount(forWidth: width)
            GeometryReader { listProxy in
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let now = model.referenceDateOverride ?? context.date
                    ScrollView {
                        if model.selectedTab == .history {
                            if model.historyEntries.isEmpty {
                                guidanceView(
                                    symbol: "doc.on.clipboard",
                                    title: "履歴はまだありません",
                                    subtitle: "clipboard+ でコピーした文章やリンクが、ここに並びます。",
                                    isCompactHeight: isCompactHeight
                                )
                                .frame(maxWidth: .infinity, minHeight: listProxy.size.height)
                            } else {
                                historyList(now: now, columnCount: columns, topPadding: topPadding)
                            }
                        } else {
                            if model.templateGroups.isEmpty {
                                guidanceView(
                                    symbol: "square.stack",
                                    title: "テンプレートはまだありません",
                                    subtitle: "clipboard+ の「テンプレート」で作った定型文が、ここに並びます。",
                                    isCompactHeight: isCompactHeight
                                )
                                .frame(maxWidth: .infinity, minHeight: listProxy.size.height)
                            } else {
                                templateList(columnCount: columns, topPadding: topPadding)
                            }
                        }
                    }
                    .hideKeyboardScrollEdgeEffects()
                    .id(model.selectedTab)
                }
            }
        }
    }

    private func historyList(now: Date, columnCount: Int, topPadding: CGFloat) -> some View {
        entryCollection(model.historyEntries, columnCount: columnCount) { entry in
            KeyboardEntryRow(
                entry: entry,
                timeLabel: KeyboardTimeFormatter.label(for: entry.lastCollectedAt, now: now),
                isFlashed: model.flashedEntryID == entry.id
            ) {
                model.tapEntry(entry)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, topPadding)
        .padding(.bottom, 4)
    }

    private func templateList(columnCount: Int, topPadding: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(model.templateGroups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: group.tag == nil ? "tray" : "tag")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KeyboardTheme.accent)
                            .accessibilityHidden(true)
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("\(group.entries.count)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)

                    entryCollection(group.entries, columnCount: columnCount) { entry in
                        KeyboardEntryRow(
                            entry: entry,
                            timeLabel: nil,
                            isFlashed: model.flashedEntryID == entry.id
                        ) {
                            model.tapEntry(entry)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, topPadding)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func entryCollection<Row: View>(
        _ entries: [KeyboardHistoryEntry],
        columnCount: Int,
        @ViewBuilder row: @escaping (KeyboardHistoryEntry) -> Row
    ) -> some View {
        if columnCount <= 1 {
            LazyVStack(spacing: 5) {
                ForEach(entries) { entry in
                    row(entry)
                }
            }
        } else {
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 7, alignment: .top),
                count: columnCount
            )
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(entries) { entry in
                    row(entry)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private func guidanceScrollView(
        symbol: String,
        title: String,
        subtitle: String,
        isCompactHeight: Bool
    ) -> some View {
        GeometryReader { listProxy in
            ScrollView {
                guidanceView(
                    symbol: symbol,
                    title: title,
                    subtitle: subtitle,
                    isCompactHeight: isCompactHeight
                )
                .frame(maxWidth: .infinity, minHeight: listProxy.size.height)
            }
            .hideKeyboardScrollEdgeEffects()
        }
    }

    private func guidanceView(
        symbol: String,
        title: String,
        subtitle: String,
        isCompactHeight: Bool
    ) -> some View {
        let iconSize: CGFloat = isCompactHeight ? 32 : 40
        return VStack(spacing: isCompactHeight ? 5 : 8) {
            Image(systemName: symbol)
                .font((isCompactHeight ? Font.callout : Font.title3).weight(.medium))
                .foregroundStyle(KeyboardTheme.accent)
                .frame(width: iconSize, height: iconSize)
                .background(KeyboardTheme.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font((isCompactHeight ? Font.footnote : Font.subheadline).weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, isCompactHeight ? 8 : 14)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusToast: some View {
        if let status = model.statusMessage {
            Label {
                Text(status.message)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            } icon: {
                Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(status.isError ? Color.orange : KeyboardTheme.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: Color.black.opacity(0.14), radius: 6, y: 2)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }

    private func listBottomBar(metrics: KeyboardListMetrics) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: metrics.keySpacing) {
                if model.needsInputModeSwitchKey {
                    KeyboardGlobeKeyContainer(
                        keyHeight: metrics.keyHeight,
                        width: metrics.compactKeyWidth,
                        slot: globeButtonSlot
                    )
                }
                alphanumericButton(metrics: metrics)
            }

            // The switcher fills the space between the side keys, and both halves get the same width,
            // so neither label is a smaller target and there is no dead gap on either side.
            tabSwitcher(keyHeight: metrics.keyHeight, isWide: metrics.isWide)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, metrics.keySpacing)
                .layoutPriority(1)

            HStack(spacing: metrics.keySpacing) {
                KeyboardRepeatableDeleteKey(keyHeight: metrics.keyHeight, width: metrics.compactKeyWidth) {
                    model.tapDelete()
                }

                Button {
                    model.tapReturn()
                } label: {
                    Text("改行")
                        .font((metrics.isWide ? Font.subheadline : Font.footnote).weight(.semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: metrics.returnWidth, height: metrics.keyHeight)
                }
                .buttonStyle(KeyboardKeyCapStyle(background: KeyboardTheme.accentKey))
                .accessibilityLabel("改行")
            }
        }
        .padding(.horizontal, metrics.bottomBarHorizontalPadding)
        .padding(.top, metrics.bottomBarTopPadding)
        .padding(.bottom, metrics.bottomBarBottomPadding)
    }

    private func alphanumericButton(metrics: KeyboardListMetrics) -> some View {
        Button {
            model.switchToAlphanumeric()
        } label: {
            Image(systemName: "keyboard")
                .font(.subheadline.weight(.regular))
                .foregroundStyle(.secondary)
                .frame(width: metrics.alphanumericKeyWidth, height: metrics.keyHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyboardSubtleKeyStyle())
        .accessibilityLabel("英数字キーボード")
        .accessibilityHint("文字や記号の入力面に切り替えます")
    }

    private func tabSwitcher(keyHeight: CGFloat, isWide: Bool) -> some View {
        let segmentHeight = max(26, keyHeight - 4)
        let segmentRadius = max(4, KeyboardTheme.keyRadius - 1)
        return HStack(spacing: 2) {
            ForEach(KeyboardTab.allCases) { tab in
                let isSelected = model.selectedTab == tab
                Button {
                    model.selectedTab = tab
                } label: {
                    Text(tab.title)
                        .font((isWide ? Font.subheadline : Font.footnote).weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, isWide ? 14 : 9)
                        .frame(maxWidth: .infinity)
                        .frame(height: segmentHeight)
                        .background(
                            isSelected ? KeyboardTheme.letterKey : Color.clear,
                            in: RoundedRectangle(cornerRadius: segmentRadius, style: .continuous)
                        )
                        .shadow(color: Color.black.opacity(isSelected ? 0.12 : 0), radius: 0.5, y: 1)
                        .contentShape(RoundedRectangle(cornerRadius: segmentRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .frame(height: keyHeight)
        .background(
            KeyboardTheme.field,
            in: RoundedRectangle(cornerRadius: KeyboardTheme.keyRadius + 1, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("表示")
    }
}

// MARK: - Row Card

private struct KeyboardEntryRow: View {
    let entry: KeyboardHistoryEntry
    let timeLabel: String?
    let isFlashed: Bool
    let onTap: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: KeyboardTheme.cardRadius, style: .continuous)
    }

    private var hasTitle: Bool {
        guard let title = entry.title else { return false }
        return !title.isEmpty
    }

    private var showsBottomMetaRow: Bool {
        timeLabel != nil || (entry.isFromPC && !hasTitle)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                if let title = entry.title, !title.isEmpty {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KeyboardTheme.accent)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if entry.kind == .url && timeLabel == nil {
                            Image(systemName: "link")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(KeyboardTheme.accent)
                                .accessibilityHidden(true)
                        }

                        if entry.isFromPC && timeLabel == nil {
                            pcBadge
                        }
                    }
                }

                contentPreview

                if showsBottomMetaRow {
                    metaRow
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(KeyboardTheme.card, in: shape)
            .overlay(
                shape.fill(KeyboardTheme.accent.opacity(isFlashed ? 0.14 : 0))
                    .allowsHitTesting(false)
            )
            .overlay(
                shape.strokeBorder(
                    isFlashed ? KeyboardTheme.accent : Color.primary.opacity(0.06),
                    lineWidth: isFlashed ? 2 : 1
                )
                .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(KeyboardRowPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("タップでカーソル位置に挿入します")
    }

    @ViewBuilder
    private var contentPreview: some View {
        if entry.kind == .url, let link = KeyboardLinkFormatting.parts(entry.text) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if !showsBottomMetaRow && !hasTitle {
                        Image(systemName: "link")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(KeyboardTheme.accent)
                            .accessibilityHidden(true)
                    }
                    Text(link.host)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KeyboardTheme.accent)
                        .lineLimit(1)
                }
                if let remainder = link.remainder {
                    Text(remainder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Text(KeyboardEntryPreview.summary(entry.text))
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.kind == .url ? "link" : "text.alignleft")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(entry.kind == .url ? KeyboardTheme.accent : Color.secondary)
                .accessibilityHidden(true)

            if let timeLabel, !timeLabel.isEmpty {
                Text(timeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if entry.isFromPC {
                pcBadge
            }

            Spacer(minLength: 0)
        }
    }

    private var pcBadge: some View {
        Label("PC", systemImage: "laptopcomputer")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(KeyboardTheme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(KeyboardTheme.accent.opacity(0.12), in: Capsule())
            .accessibilityLabel("PCから受信")
    }
}

// MARK: - Shared Key Components

struct KeyboardGlobeKeyContainer: View {
    let keyHeight: CGFloat
    let width: CGFloat
    let slot: AnyView?

    var body: some View {
        Group {
            if let slot {
                slot
                    .frame(width: width, height: keyHeight)
            } else {
                Image(systemName: "globe")
                    .font(.body.weight(.regular))
                    .foregroundStyle(Color.primary)
                    .frame(width: width, height: keyHeight)
                    .background(
                        RoundedRectangle(cornerRadius: KeyboardTheme.keyRadius, style: .continuous)
                            .fill(KeyboardTheme.specialKey)
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 0.5, y: 1)
            }
        }
        .accessibilityLabel("次のキーボード")
    }
}

struct KeyboardRepeatableDeleteKey: View {
    let keyHeight: CGFloat
    let width: CGFloat
    let onDelete: () -> Void

    @GestureState private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "delete.left")
            .font(.body.weight(.medium))
            .foregroundStyle(Color.primary)
            .frame(width: width, height: keyHeight)
            .background(
                RoundedRectangle(cornerRadius: KeyboardTheme.keyRadius, style: .continuous)
                    .fill(isPressed ? KeyboardTheme.letterKey : KeyboardTheme.specialKey)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 0.5, y: 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in
                        state = true
                    }
            )
            .onChange(of: isPressed) { _, pressed in
                if pressed {
                    startRepeating()
                } else {
                    stopRepeating()
                }
            }
            .onDisappear { stopRepeating() }
            .accessibilityElement()
            .accessibilityLabel("削除")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onDelete() }
    }

    private func startRepeating() {
        stopRepeating()
        onDelete()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            while !Task.isCancelled {
                onDelete()
                try? await Task.sleep(nanoseconds: 85_000_000)
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

struct KeyboardKeyCapStyle: ButtonStyle {
    let background: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: KeyboardTheme.keyRadius, style: .continuous)
                    .fill(background)
                    .opacity(configuration.isPressed ? 0.72 : 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 0.5, y: 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct KeyboardSubtleKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: KeyboardTheme.keyRadius, style: .continuous)
                    .fill(KeyboardTheme.field)
                    .opacity(configuration.isPressed ? 0.65 : 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct KeyboardRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.68 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private extension View {
    /// Disables iOS 26+ automatic scroll-edge blur so the top row or tag header
    /// stays sharp when unscrolled without reserving extra vertical space.
    @ViewBuilder
    func hideKeyboardScrollEdgeEffects() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}

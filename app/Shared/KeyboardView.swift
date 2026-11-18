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
            let isWide = proxy.size.width >= 600
            let keyHeight: CGFloat = isCompactHeight ? 34 : (isWide ? 42 : 38)

            VStack(spacing: 0) {
                topBar
                ZStack(alignment: .bottom) {
                    listContent(width: proxy.size.width)
                    statusToast
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                listBottomBar(isWide: isWide, keyHeight: keyHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Picker("表示", selection: $model.selectedTab) {
                ForEach(KeyboardTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 140, maxWidth: 210)

            Spacer(minLength: 4)

            if model.showsSaveClipboardButton {
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
                            .padding(.horizontal, 10)
                            .frame(minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(KeyboardTheme.accent)
                    .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func listContent(width: CGFloat) -> some View {
        switch model.loadState {
        case .loading:
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            guidanceView(
                symbol: "doc.on.clipboard",
                title: "clipboard+ を一度開くと、ここに履歴が出ます",
                subtitle: "本体アプリを開くと、コピーした履歴とテンプレートが使えます。"
            )
        case .loaded:
            let columns = KeyboardLayoutMetrics.columnCount(forWidth: width)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = model.referenceDateOverride ?? context.date
                ScrollView {
                    if model.selectedTab == .history {
                        if model.historyEntries.isEmpty {
                            guidanceView(
                                symbol: "doc.on.clipboard",
                                title: "履歴はまだありません",
                                subtitle: "clipboard+ でコピーした文章やリンクが、ここに並びます。"
                            )
                        } else {
                            historyList(now: now, columnCount: columns)
                        }
                    } else {
                        if model.templateGroups.isEmpty {
                            guidanceView(
                                symbol: "square.stack",
                                title: "テンプレートはまだありません",
                                subtitle: "clipboard+ の「テンプレート」で作った定型文が、ここに並びます。"
                            )
                        } else {
                            templateList(columnCount: columns)
                        }
                    }
                }
                .id(model.selectedTab)
            }
        }
    }

    private func historyList(now: Date, columnCount: Int) -> some View {
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
        .padding(.vertical, 4)
    }

    private func templateList(columnCount: Int) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(model.templateGroups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
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
                            .foregroundStyle(.tertiary)
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
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func entryCollection<Row: View>(
        _ entries: [KeyboardHistoryEntry],
        columnCount: Int,
        @ViewBuilder row: @escaping (KeyboardHistoryEntry) -> Row
    ) -> some View {
        if columnCount <= 1 {
            LazyVStack(spacing: 6) {
                ForEach(entries) { entry in
                    row(entry)
                }
            }
        } else {
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                count: columnCount
            )
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(entries) { entry in
                    row(entry)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private func guidanceView(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(KeyboardTheme.accent)
                .frame(width: 40, height: 40)
                .background(KeyboardTheme.accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func listBottomBar(isWide: Bool, keyHeight: CGFloat) -> some View {
        let spacing: CGFloat = isWide ? 8 : 5
        let compactWidth: CGFloat = isWide ? 56 : 44
        let abcWidth: CGFloat = isWide ? 66 : 52
        let returnWidth: CGFloat = isWide ? 82 : 58

        return HStack(spacing: spacing) {
            if model.needsInputModeSwitchKey {
                KeyboardGlobeKeyContainer(keyHeight: keyHeight, width: compactWidth, slot: globeButtonSlot)
            }
            Button {
                model.switchToAlphanumeric()
            } label: {
                Text("ABC")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .frame(width: abcWidth, height: keyHeight)
            }
            .buttonStyle(KeyboardKeyCapStyle(background: KeyboardTheme.specialKey))
            .accessibilityLabel("英数字キーボード")

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

            KeyboardRepeatableDeleteKey(keyHeight: keyHeight, width: compactWidth) {
                model.tapDelete()
            }

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
        .padding(.horizontal, isWide ? 10 : 6)
        .padding(.top, 4)
        .padding(.bottom, 6)
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

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                if let title = entry.title, !title.isEmpty {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KeyboardTheme.accent)
                        .lineLimit(1)
                }

                contentPreview

                metaRow
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
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
                Text(link.host)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KeyboardTheme.accent)
                    .lineLimit(1)
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
                Label("PC", systemImage: "laptopcomputer")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KeyboardTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(KeyboardTheme.accent.opacity(0.12), in: Capsule())
                    .accessibilityLabel("PCから受信")
            }

            Spacer(minLength: 0)
        }
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

private struct KeyboardRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.68 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

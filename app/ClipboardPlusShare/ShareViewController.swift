import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var didStart = false
    private var didFinish = false
    private var saveTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()

        let statusLabel = UILabel()
        statusLabel.text = "clipboard+に保存しています…"
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .secondaryLabel

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("キャンセル", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel, cancelButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        saveTask = Task { [weak self] in
            await self?.saveSharedItems()
        }
    }

    @objc private func cancelShare() {
        guard !didFinish else { return }
        didFinish = true
        saveTask?.cancel()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func saveSharedItems() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var collected: [String] = []
        var seen: Set<String> = []
        for item in items {
            for provider in item.attachments ?? [] {
                if Task.isCancelled { return }
                if let text = await Self.loadText(from: provider),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   seen.insert(text).inserted {
                    collected.append(text)
                }
            }
        }
        guard !Task.isCancelled, !didFinish else { return }
        if !collected.isEmpty, let directory = SharedAppGroup.inboxDirectoryURL() {
            for text in collected {
                _ = try? SharedInbox.write(text: text, origin: .shareExtension, to: directory)
            }
        }
        didFinish = true
        extensionContext?.completeRequest(returningItems: nil)
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return nil
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let urlText = await loadURLString(from: provider) {
            return urlText
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            || provider.canLoadObject(ofClass: NSString.self) {
            return await loadPlainText(from: provider)
        }
        return nil
    }

    private static func loadURLString(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url.isFileURL ? nil : url.absoluteString)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url.isFileURL ? nil : url.absoluteString)
                } else if let text = item as? String, !text.isEmpty {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadPlainText(from provider: NSItemProvider) async -> String? {
        let objectText: String? = await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: object as? String)
            }
        }
        if let objectText { return objectText }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let attributed = item as? NSAttributedString {
                    continuation.resume(returning: attributed.string)
                } else if let data = item as? Data {
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

import SwiftUI
import UIKit

enum KeyboardPasteStrategy {
    case systemPasteControl
    case directPasteboard
}

final class KeyboardViewController: UIInputViewController {
    /// Try UIPasteControl first to avoid system paste prompts.
    /// If UIPasteControl is unusable in keyboard extensions on device, switch to `.directPasteboard`.
    private static let pasteStrategy: KeyboardPasteStrategy = .systemPasteControl

    private lazy var model = KeyboardViewModel(
        loadState: .loading,
        hasFullAccess: hasFullAccess,
        needsInputModeSwitchKey: needsInputModeSwitchKey,
        insertText: { [weak self] text in
            self?.textDocumentProxy.insertText(text)
        },
        deleteBackward: { [weak self] in
            self?.textDocumentProxy.deleteBackward()
        },
        pasteboardProvider: { UIPasteboard.general }
    )

    private var hostingController: UIHostingController<KeyboardView>?
    private var heightConstraint: NSLayoutConstraint?
    private var hasLoadedForAppearance = false

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear
        updatePasteConfiguration()

        let globeSlot = AnyView(KeyboardGlobeUIButton(controller: self))
        let pasteSlot: AnyView? = Self.pasteStrategy == .systemPasteControl
            ? AnyView(KeyboardSystemPasteControl(target: self))
            : nil

        let rootView = KeyboardView(
            model: model,
            globeButtonSlot: globeSlot,
            pasteControlSlot: pasteSlot
        )
        let host = UIHostingController(rootView: rootView)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        self.hostingController = host

        let height = view.heightAnchor.constraint(equalToConstant: preferredKeyboardHeight())
        height.priority = UILayoutPriority(999)
        self.heightConstraint = height

        NSLayoutConstraint.activate([
            height,
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        model.loadFromSharedContainer()
        hasLoadedForAppearance = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncInputTraits()
        if !hasLoadedForAppearance {
            model.loadFromSharedContainer()
            hasLoadedForAppearance = true
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        hasLoadedForAppearance = false
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        syncInputTraits()
        let desiredHeight = preferredKeyboardHeight()
        if let heightConstraint, abs(heightConstraint.constant - desiredHeight) > 0.5 {
            heightConstraint.constant = desiredHeight
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        model.handleMemoryWarning()
    }

    // MARK: - UIPasteConfigurationSupporting

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        hasFullAccess && SharedTextExtractor.canAccept(itemProviders)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard hasFullAccess else { return }
        if SharedTextExtractor.hasPrivateMarker(in: itemProviders) {
            model.showStatus("秘密の印があるため保存しませんでした", isError: false)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let text = await SharedTextExtractor.extractFirstText(from: itemProviders) {
                self.model.saveToInbox(text: text)
            } else {
                // Fallback if UIPasteControl delivers empty or unreadable providers in extension context.
                self.model.saveFromPasteboard()
            }
        }
    }

    // MARK: - Helpers

    private func syncInputTraits() {
        if model.needsInputModeSwitchKey != needsInputModeSwitchKey {
            model.needsInputModeSwitchKey = needsInputModeSwitchKey
        }
        if model.hasFullAccess != hasFullAccess {
            model.hasFullAccess = hasFullAccess
            updatePasteConfiguration()
        }
    }

    private func updatePasteConfiguration() {
        if hasFullAccess && Self.pasteStrategy == .systemPasteControl {
            pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: SharedTextExtractor.acceptedTypeIdentifiers)
        } else {
            pasteConfiguration = nil
        }
    }

    private func preferredKeyboardHeight() -> CGFloat {
        KeyboardLayoutMetrics.preferredHeight(
            idiom: traitCollection.userInterfaceIdiom,
            verticalSizeClass: traitCollection.verticalSizeClass,
            width: view.bounds.width
        )
    }
}

private struct KeyboardGlobeUIButton: UIViewRepresentable {
    final class Coordinator {
        weak var controller: UIInputViewController?
    }

    weak var controller: UIInputViewController?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        let imageConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        button.setImage(UIImage(systemName: "globe", withConfiguration: imageConfig), for: .normal)
        button.tintColor = .label
        button.backgroundColor = KeyboardTheme.specialKeyUIColor
        button.layer.cornerRadius = KeyboardTheme.keyRadius
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.18
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowRadius = 0.5
        button.accessibilityLabel = "次のキーボード"
        if let controller {
            context.coordinator.controller = controller
            button.addTarget(
                controller,
                action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                for: .allTouchEvents
            )
        }
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        if context.coordinator.controller !== controller {
            uiView.removeTarget(nil, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
            context.coordinator.controller = controller
            if let controller {
                uiView.addTarget(
                    controller,
                    action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                    for: .allTouchEvents
                )
            }
        }
    }
}

private struct KeyboardSystemPasteControl: UIViewRepresentable {
    weak var target: UIViewController?

    func makeUIView(context: Context) -> UIPasteControl {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = KeyboardTheme.accentKeyUIColor
        configuration.baseForegroundColor = .white

        let control = UIPasteControl(configuration: configuration)
        control.target = target
        control.accessibilityLabel = "今のコピーを保存"
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .vertical)
        return control
    }

    func updateUIView(_ uiView: UIPasteControl, context: Context) {
        uiView.target = target
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPasteControl, context: Context) -> CGSize? {
        let fitting = uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let width = fitting.width > 0 ? fitting.width : 96
        let height = fitting.height > 0 ? fitting.height : 32
        return CGSize(width: width, height: max(32, height))
    }
}

import UIKit

final class ShareViewController: UIViewController {
    private var didStart = false
    private var didCompleteExtension = false
    private var hasFinishedSaving = false
    private var saveTask: Task<Void, Never>?

    private let cardView = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let actionButton = UIButton(type: .system)

    deinit {
        saveTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemGroupedBackground

        cardView.backgroundColor = .secondarySystemGroupedBackground
        cardView.layer.cornerRadius = 16
        cardView.layer.cornerCurve = .continuous
        cardView.translatesAutoresizingMaskIntoConstraints = false

        spinner.startAnimating()

        statusImageView.isHidden = true
        statusImageView.contentMode = .scaleAspectFit
        statusImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 32, weight: .semibold)

        titleLabel.text = "clipboard+ に保存しています…"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        subtitleLabel.isHidden = true
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        actionButton.setTitle("キャンセル", for: .normal)
        actionButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        actionButton.addTarget(self, action: #selector(handleActionButton), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, statusImageView, titleLabel, subtitleLabel, actionButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(6, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        cardView.addSubview(stack)
        view.addSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 360),

            stack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -24),

            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        saveTask = Task { [weak self] in
            await self?.runSaveFlow()
        }
    }

    @objc private func handleActionButton() {
        guard !didCompleteExtension else { return }
        didCompleteExtension = true
        saveTask?.cancel()
        if hasFinishedSaving {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
    }

    private func runSaveFlow() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let collected = await SharedTextExtractor.extractTexts(from: items)
        guard !Task.isCancelled, !didCompleteExtension else { return }

        let outcome = ShareSaveOutcome.save(
            texts: collected,
            inboxDirectory: SharedAppGroup.inboxDirectoryURL()
        )
        presentOutcome(outcome)

        try? await Task.sleep(nanoseconds: outcome.autoDismissDelayNanoseconds)
        guard !Task.isCancelled, !didCompleteExtension else { return }
        didCompleteExtension = true
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func presentOutcome(_ outcome: ShareSaveOutcome) {
        hasFinishedSaving = true
        spinner.stopAnimating()
        spinner.isHidden = true

        statusImageView.image = UIImage(systemName: outcome.symbolName)
        switch outcome {
        case .saved:
            statusImageView.tintColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.45, green: 0.64, blue: 1.0, alpha: 1)
                    : UIColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1)
            }
        case .noSupportedContent:
            statusImageView.tintColor = .secondaryLabel
        case .storageUnavailable, .saveFailed:
            statusImageView.tintColor = .systemOrange
        }
        statusImageView.isHidden = false

        titleLabel.text = outcome.title
        subtitleLabel.text = outcome.subtitle
        subtitleLabel.isHidden = outcome.subtitle == nil
        actionButton.setTitle("閉じる", for: .normal)
    }
}

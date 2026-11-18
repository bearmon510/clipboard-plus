import UIKit

final class KeyboardViewController: UIInputViewController {
    private let nextKeyboardButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear

        let titleLabel = UILabel()
        titleLabel.text = "clipboard+"
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = .secondaryLabel

        let statusLabel = UILabel()
        statusLabel.text = "準備中"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textColor = .label

        let centerStack = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        centerStack.axis = .vertical
        centerStack.alignment = .center
        centerStack.spacing = 6
        centerStack.translatesAutoresizingMaskIntoConstraints = false

        let imageConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        nextKeyboardButton.setImage(UIImage(systemName: "globe", withConfiguration: imageConfig), for: .normal)
        nextKeyboardButton.accessibilityLabel = "次のキーボード"
        nextKeyboardButton.tintColor = .label
        nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        view.addSubview(centerStack)
        view.addSubview(nextKeyboardButton)

        let preferredHeight = view.heightAnchor.constraint(greaterThanOrEqualToConstant: 216)
        preferredHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            preferredHeight,
            centerStack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            nextKeyboardButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            nextKeyboardButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            nextKeyboardButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            nextKeyboardButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        nextKeyboardButton.isHidden = !needsInputModeSwitchKey
    }
}

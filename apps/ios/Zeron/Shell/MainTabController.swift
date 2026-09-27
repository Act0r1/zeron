import UIKit

/// Root: native tab bar (Liquid Glass comes from the system, so tab switches,
/// minimize-on-scroll and the search morph are render-server animations), with
/// the "Ask anything" composer as the tab bar's bottom accessory.
final class MainTabController: UITabBarController, UITabBarControllerDelegate, AppRouter {
    private let app: AppModel

    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        tabBar.tintColor = Palette.accent
        tabBarMinimizeBehavior = .onScrollDown

        let sessions = UITab(title: "Sessions", image: UIImage(systemName: "bubble.left.and.text.bubble.right"), identifier: "sessions") { [app] _ in
            Self.nav(SessionsViewController(app: app))
        }
        let more = UITab(title: "Settings", image: UIImage(systemName: "gearshape"), identifier: "more") { [app] _ in
            Self.nav(MoreViewController(app: app))
        }
        let search = UISearchTab { [app] _ in
            Self.nav(SearchViewController(app: app))
        }
        search.automaticallyActivatesSearch = true
        tabs = [sessions, more, search]
        selectedTab = sessions

        bottomAccessory = accessory
        delegate = self
        accessoryContent.update(app.live)
        liveToken = app.observe { [weak self] in
            guard let self else { return }
            self.accessoryContent.update(self.app.live)
        }
    }

    /// Search has its own bottom field; the composer accessory steps aside.
    func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
        setAccessoryVisible(!(selectedTab is UISearchTab), animated: true)
    }

    private lazy var accessoryContent = AskAnythingAccessory { [weak self] in self?.presentNewSession() }
    private lazy var accessory = UITabAccessory(contentView: accessoryContent)
    private var liveToken: AnyObject?

    /// Accessory state from what's on screen: hidden over a session (it has
    /// its own composer) and on the search tab.
    func syncAccessory() {
        let top = (selectedTab?.viewController as? UINavigationController)?.topViewController
        setAccessoryVisible(!(top is SessionViewController), animated: false)
    }

    /// Pushed sessions carry their own composer; the accessory steps aside.
    func setAccessoryVisible(_ visible: Bool, animated: Bool) {
        let target = visible && !(selectedTab is UISearchTab) ? accessory : nil
        guard bottomAccessory !== target else { return }
        setBottomAccessory(target, animated: animated)
    }

    static func nav(_ root: UIViewController) -> UINavigationController {
        let nav = UINavigationController(rootViewController: root)
        nav.navigationBar.prefersLargeTitles = true
        // Setting an appearance object drops iOS 26's scroll-edge effect;
        // style titles through the bar's own attributes instead.
        nav.navigationBar.largeTitleTextAttributes = [.font: Fonts.ui(.sansSemibold, 30), .foregroundColor: Palette.text]
        nav.navigationBar.titleTextAttributes = [.font: Fonts.ui(.sansSemibold, 17), .foregroundColor: Palette.text]
        nav.navigationBar.tintColor = Palette.text
        return nav
    }

    func presentNewSession(prompt: String? = nil) {
        let vc = NewSessionViewController(app: app, prompt: prompt) { [weak self] chatId in
            guard let self else { return }
            self.openSession(chatId)
        }
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    func showSettings() {
        selectedTab = tabs.first { $0.identifier == "more" }
    }

    func showSearch() {
        selectedTab = tabs.first { $0 is UISearchTab }
    }

    /// Push a session on the Sessions tab (from new-session, deep links, search).
    func openSession(_ chatId: String) {
        if presentedViewController != nil { dismiss(animated: true) }
        guard let tab = tabs.first(where: { $0.identifier == "sessions" }) else { return }
        selectedTab = tab
        guard let nav = tab.viewController as? UINavigationController else { return }
        nav.popToRootViewController(animated: false)
        nav.pushViewController(SessionViewController(app: app, chatId: chatId), animated: true)
    }
}

/// The capsule above the tab bar: a plus, "New session", and a live
/// summary of what's running ("2 working · 1 needs you"). Tapping it opens the
/// new-session composer.
final class AskAnythingAccessory: UIControl {
    private let onTap: () -> Void
    private let label = UILabel()
    private let summary = UILabel()
    private let cells = StatusGlyph()
    private let mark = UIImageView(image: UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        accessibilityIdentifier = "new-session"
        accessibilityTraits = .button

        mark.tintColor = Palette.accent
        mark.contentMode = .center
        let plate = UIView()
        plate.backgroundColor = Palette.accentSoft
        plate.layer.cornerRadius = 11
        plate.layer.cornerCurve = .continuous
        plate.isUserInteractionEnabled = false
        plate.addSubview(mark)
        label.text = "New session"
        label.font = Fonts.ui(.sansMedium, 16)
        label.textColor = Palette.text
        summary.font = Fonts.ui(.sansMedium, 13)
        summary.textColor = Palette.secondary
        summary.textAlignment = .right
        cells.isHidden = true
        for v in [plate, label, mark, summary, cells] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        for v in [plate, label, summary, cells] as [UIView] { addSubview(v) }
        summary.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            plate.centerYAnchor.constraint(equalTo: centerYAnchor),
            plate.widthAnchor.constraint(equalToConstant: 34),
            plate.heightAnchor.constraint(equalToConstant: 34),
            mark.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: plate.trailingAnchor, constant: 11),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cells.leadingAnchor, constant: -10),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            summary.centerYAnchor.constraint(equalTo: centerYAnchor),
            cells.trailingAnchor.constraint(equalTo: summary.leadingAnchor, constant: -7),
            cells.centerYAnchor.constraint(equalTo: centerYAnchor),
            cells.widthAnchor.constraint(equalToConstant: 12),
            cells.heightAnchor.constraint(equalToConstant: 12),
        ])
        addAction(UIAction { [weak self] _ in self?.onTap() }, for: .touchUpInside)
        registerForTraitChanges([UITraitTabAccessoryEnvironment.self]) { (self: AskAnythingAccessory, _) in
            // Inline (minimized tab bar): the plus and the live summary only.
            let inline = self.traitCollection.tabAccessoryEnvironment == .inline
            self.label.alpha = inline ? 0 : 1
        }
        update(AppModel.LiveCounts())
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ live: AppModel.LiveCounts) {
        var parts: [String] = []
        if live.working > 0 { parts.append("\(live.working) working") }
        if live.awaiting > 0 { parts.append("\(live.awaiting) need\(live.awaiting == 1 ? "s" : "") you") }
        summary.text = parts.joined(separator: " · ")
        cells.isHidden = parts.isEmpty
        cells.kind = live.working > 0 ? .spinner : .dot(StatusTone.input)
        accessibilityLabel = parts.isEmpty ? "New session" : "New session, " + parts.joined(separator: ", ")
    }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.15) { self.alpha = self.isHighlighted ? 0.6 : 1 } }
    }
}

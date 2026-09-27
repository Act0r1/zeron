import UIKit

/// Navigation entry points the scene and screens use without knowing which
/// shell is on screen (iPhone tabs or the iPad split).
protocol AppRouter: AnyObject {
    func openSession(_ chatId: String)
    func presentNewSession(prompt: String?)
    func showSettings()
    func showSearch()
}

/// iPad shell, laid out like t3code: a 256pt sidebar (208–320) beside the
/// session column. The sidebar is the front page — sessions in sidebar
/// sections, search, new session, settings; the main column shows the open
/// session or a new-session draft (t3 opens a draft rather than an empty
/// page). Compact widths (Slide Over, narrow Split View) collapse to the
/// iPhone tab shell.
final class SplitRootController: UISplitViewController, UISplitViewControllerDelegate, AppRouter {
    private let app: AppModel
    private let sidebar: SidebarViewController
    private let detail = UINavigationController()
    private lazy var tabs = MainTabController(app: app)
    private(set) var currentChatId: String?

    init(app: AppModel) {
        self.app = app
        self.sidebar = SidebarViewController(app: app)
        super.init(style: .doubleColumn)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        delegate = self
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        preferredPrimaryColumnWidth = 256
        minimumPrimaryColumnWidth = 208
        maximumPrimaryColumnWidth = 320
        primaryBackgroundStyle = .none
        displayModeButtonVisibility = .automatic
        let sidebarNav = UINavigationController(rootViewController: sidebar)
        sidebarNav.navigationBar.titleTextAttributes = [.font: Fonts.ui(.sansSemibold, 15), .foregroundColor: Palette.text]
        sidebarNav.navigationBar.tintColor = Palette.text
        setViewController(sidebarNav, for: .primary)
        detail.navigationBar.titleTextAttributes = [.font: Fonts.ui(.sansSemibold, 15), .foregroundColor: Palette.text]
        detail.navigationBar.tintColor = Palette.text
        setViewController(detail, for: .secondary)
        setViewController(tabs, for: .compact)
        presentNewSession(prompt: nil)
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "New Session", action: #selector(newSessionCommand), input: "n", modifierFlags: .command),
            UIKeyCommand(title: "Search", action: #selector(searchCommand), input: "f", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Toggle Sidebar", action: #selector(toggleSidebarCommand), input: "b", modifierFlags: .command),
        ]
    }

    @objc private func newSessionCommand() { presentNewSession(prompt: nil) }
    @objc private func searchCommand() { showSearch() }
    @objc private func toggleSidebarCommand() {
        UIView.animate(withDuration: 0.3) {
            self.preferredDisplayMode = self.displayMode == .secondaryOnly ? .oneBesideSecondary : .secondaryOnly
        }
    }

    // MARK: AppRouter

    func openSession(_ chatId: String) {
        if presentedViewController != nil { dismiss(animated: true) }
        guard !isCollapsed else { return tabs.openSession(chatId) }
        if currentChatId == chatId, detail.viewControllers.first is SessionViewController { return }
        currentChatId = chatId
        sidebar.currentChatId = chatId
        detail.setViewControllers([SessionViewController(app: app, chatId: chatId)], animated: false)
    }

    func presentNewSession(prompt: String?) {
        guard !isCollapsed else { return tabs.presentNewSession(prompt: prompt) }
        currentChatId = nil
        sidebar.currentChatId = nil
        let draft = NewSessionViewController(app: app, prompt: prompt, embedded: true) { [weak self] chatId, handoff in
            guard let self, let handoff, let window = self.view.window, !self.isCollapsed else {
                self?.openSession(chatId)
                return
            }
            // In place: the chat replaces the draft in the column and the
            // handoff carries the composer and message across.
            self.currentChatId = chatId
            self.sidebar.currentChatId = chatId
            let session = SessionViewController(app: self.app, chatId: chatId)
            UIView.performWithoutAnimation {
                self.detail.setViewControllers([session], animated: false)
                self.view.layoutIfNeeded()
                session.prepareArrival()
            }
            DraftHandoffAnimator.run(handoff, into: session, window: window)
        }
        detail.setViewControllers([draft], animated: false)
    }

    func showSettings() {
        guard !isCollapsed else { return tabs.showSettings() }
        let nav = MainTabController.nav(MoreViewController(app: app))
        nav.modalPresentationStyle = .formSheet
        nav.topViewController?.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in
            nav?.dismiss(animated: true)
        })
        present(nav, animated: true)
    }

    func showSearch() {
        guard !isCollapsed else { return tabs.showSearch() }
        if displayMode == .secondaryOnly { show(.primary) }
        sidebar.focusSearch()
    }

    // MARK: Collapse / expand

    /// Narrowing to compact carries the open session into the tab shell.
    func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposed: UISplitViewController.Column) -> UISplitViewController.Column {
        if let chatId = currentChatId {
            DispatchQueue.main.async { self.tabs.openSession(chatId) }
        }
        return .compact
    }
}

/// The iPad sidebar: wordmark, search + new session, the front-page
/// sections (current session highlighted), and a footer of settings /
/// archive — t3code's sidebar shape with Zeron's sections.
final class SidebarViewController: UIViewController, UISearchTextFieldDelegate {
    private let app: AppModel
    private let list: SessionsViewController
    private let search = UISearchTextField()
    private let footer = UIStackView()
    private var liveToken: AnyObject?
    private let live = UILabel()

    var currentChatId: String? {
        get { list.currentChatId }
        set { list.currentChatId = newValue }
    }

    init(app: AppModel) {
        self.app = app
        self.list = SessionsViewController(app: app)
        list.sidebarRows = true
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.sidebar
        navigationItem.largeTitleDisplayMode = .never
        let wordmark = UILabel()
        wordmark.text = "Zeron"
        wordmark.font = Fonts.ui(.sansSemibold, 15)
        wordmark.textColor = Palette.text
        navigationItem.leftBarButtonItem = UIBarButtonItem(customView: wordmark)
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), primaryAction: UIAction { [weak self] _ in
                self?.router?.presentNewSession(prompt: nil)
            }),
            UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: list.optionsMenu()),
        ]
        navigationItem.rightBarButtonItems?.first?.accessibilityIdentifier = "sidebar-new-session"
        navigationItem.rightBarButtonItems?.first?.accessibilityLabel = "New session"

        search.placeholder = "Search"
        search.font = Fonts.ui(.sansMedium, 14)
        search.backgroundColor = Palette.controlFill
        search.borderStyle = .none
        search.layer.cornerRadius = 8
        search.layer.cornerCurve = .continuous
        search.clipsToBounds = true
        search.returnKeyType = .search
        search.delegate = self
        search.accessibilityIdentifier = "sidebar-search"
        search.addAction(UIAction { [weak self] _ in
            self?.list.query = self?.search.text ?? ""
        }, for: .editingChanged)

        addChild(list)
        list.view.backgroundColor = .clear
        list.collectionView.backgroundColor = .clear

        live.font = Fonts.ui(.sansMedium, 12)
        live.textColor = Palette.secondary
        live.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.axis = .horizontal
        footer.spacing = 4
        footer.alignment = .center
        footer.addArrangedSubview(iconButton("gearshape", label: "Settings", id: "sidebar-settings") { [weak self] in self?.router?.showSettings() })
        footer.addArrangedSubview(iconButton("archivebox", label: "Archived", id: "sidebar-archived") { [weak self] in
            guard let self else { return }
            self.navigationController?.pushViewController(FolderViewController(app: self.app, folder: FolderRowVM(id: "archived", name: "Archived", count: 0, symbol: "archivebox")), animated: true)
        })
        footer.addArrangedSubview(UIView())
        footer.addArrangedSubview(live)

        for v in [search, list.view!, footer] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        list.didMove(toParent: self)
        // t3: 1px border between the sidebar and the main column.
        let edge = UIView()
        edge.backgroundColor = Palette.hairline
        edge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(edge)
        NSLayoutConstraint.activate([
            edge.topAnchor.constraint(equalTo: view.topAnchor),
            edge.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            edge.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
        ])
        let divider = UIView()
        divider.backgroundColor = Palette.hairline
        divider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(divider)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            search.heightAnchor.constraint(equalToConstant: 34),
            list.view.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            list.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            list.view.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            footer.heightAnchor.constraint(equalToConstant: 36),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -2),
            divider.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
        ])
        updateLive()
        liveToken = app.observe { [weak self] in self?.updateLive() }
    }

    private func updateLive() {
        var parts: [String] = []
        if app.live.working > 0 { parts.append("\(app.live.working) working") }
        if app.live.awaiting > 0 { parts.append("\(app.live.awaiting) need\(app.live.awaiting == 1 ? "s" : "") you") }
        live.text = parts.joined(separator: " · ")
    }

    private func iconButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> UIButton {
        var c = UIButton.Configuration.plain()
        c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        c.baseForegroundColor = Palette.secondary
        c.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        let b = UIButton(configuration: c, primaryAction: UIAction { _ in action() })
        b.accessibilityLabel = label
        b.accessibilityIdentifier = id
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return b
    }

    func focusSearch() {
        search.becomeFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

extension UIViewController {
    /// The shell's router (tabs or split), wherever this controller sits.
    var router: AppRouter? { view.window?.rootViewController as? AppRouter }
}

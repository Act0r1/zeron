import UIKit

/// Navigation entry points the scene and screens use without knowing which
/// shell is on screen (iPhone tabs or the iPad split).
protocol AppRouter: AnyObject {
    func openSession(_ chatId: String)
    func presentNewSession(prompt: String?)
    func showSettings()
    func showSearch()
}

/// iPad shell: Zeron mobile with a sidebar. The sidebar is the phone's
/// Sessions page (same rows, sections, wallpaper, "New session" capsule);
/// the main column shows the open session or the phone's new-session page.
/// Compact widths (Slide Over, narrow Split View) collapse to the iPhone tab
/// shell.
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
        // About a phone's width, so the rows read as they do on iPhone.
        preferredPrimaryColumnWidth = 360
        minimumPrimaryColumnWidth = 320
        maximumPrimaryColumnWidth = 400
        primaryBackgroundStyle = .none
        // No toggle button (the phone has none); ⌘B still hides the sidebar.
        displayModeButtonVisibility = .never
        setViewController(sidebar, for: .primary)
        detail.navigationBar.titleTextAttributes = [.font: Fonts.ui(.sansSemibold, 17), .foregroundColor: Palette.text]
        detail.navigationBar.tintColor = Palette.text
        setViewController(detail, for: .secondary)
        setViewController(tabs, for: .compact)
        showDraft(prompt: nil, focus: false)
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
        showDraft(prompt: prompt, focus: true)
    }

    /// The new-session page in the main column. Launch shows it without the
    /// keyboard (it would cover half the column); asking for one focuses it.
    func showDraft(prompt: String?, focus: Bool) {
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
        draft.focusOnAppear = focus
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

/// The iPad sidebar: the phone's Sessions page in its own navigation stack
/// (sections, folders, Archived push inside it), search in the bar, Settings
/// beside the options menu, and the "New session" capsule floating at the
/// bottom as the tab bar's accessory does on iPhone.
final class SidebarViewController: UIViewController, UISearchResultsUpdating {
    private let app: AppModel
    private let list: SessionsViewController
    private let nav: UINavigationController
    private let search = UISearchController(searchResultsController: nil)
    private let capsule = Glass.surface(interactive: true)
    private lazy var accessory = AskAnythingAccessory { [weak self] in self?.router?.presentNewSession(prompt: nil) }
    private var liveToken: AnyObject?

    var currentChatId: String? {
        get { list.currentChatId }
        set { list.currentChatId = newValue }
    }

    init(app: AppModel) {
        self.app = app
        self.list = SessionsViewController(app: app)
        self.nav = MainTabController.nav(list)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        addChild(nav)
        nav.view.frame = view.bounds
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(nav.view)
        nav.didMove(toParent: self)

        _ = list.view
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        search.searchBar.placeholder = "Search"
        search.searchBar.searchTextField.accessibilityIdentifier = "sidebar-search"
        list.navigationItem.searchController = search
        list.navigationItem.hidesSearchBarWhenScrolling = false
        list.navigationItem.preferredSearchBarPlacement = .stacked
        let settings = UIBarButtonItem(image: UIImage(named: "tab-settings"), primaryAction: UIAction { [weak self] _ in
            self?.router?.showSettings()
        })
        settings.accessibilityLabel = "Settings"
        settings.accessibilityIdentifier = "sidebar-settings"
        list.navigationItem.rightBarButtonItems = [list.navigationItem.rightBarButtonItem, settings].compactMap { $0 }

        capsule.contentView.addSubview(accessory)
        accessory.translatesAutoresizingMaskIntoConstraints = false
        capsule.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(capsule)
        NSLayoutConstraint.activate([
            accessory.topAnchor.constraint(equalTo: capsule.contentView.topAnchor),
            accessory.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor),
            accessory.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor),
            accessory.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor),
            capsule.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            capsule.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            capsule.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            capsule.heightAnchor.constraint(equalToConstant: 48),
        ])
        // The list scrolls up past the capsule.
        nav.additionalSafeAreaInsets.bottom = 48 + 16

        // A hairline between the sidebar and the main column.
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

        accessory.update(app.live)
        liveToken = app.observe { [weak self] in
            guard let self else { return }
            self.accessory.update(self.app.live)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        list.query = searchController.searchBar.text ?? ""
    }

    func focusSearch() {
        nav.popToRootViewController(animated: false)
        search.searchBar.becomeFirstResponder()
    }
}

extension UIViewController {
    /// The shell's router (tabs or split), wherever this controller sits.
    var router: AppRouter? { view.window?.rootViewController as? AppRouter }
}

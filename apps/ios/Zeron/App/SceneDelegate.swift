import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let app = AppModel()

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = UIUserInterfaceStyle(rawValue: UserDefaults.standard.integer(forKey: "appearance")) ?? .unspecified
        window.tintColor = Palette.accent
        self.window = window
        app.onSignedIn = { [weak self] in self?.showRoot(animated: true) }
        app.onSignOut = { [weak self] in
            self?.app.signOutLocally()
            self?.showRoot(animated: true)
        }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-lab") {
            window.rootViewController = MainTabController.nav(TranscriptLabViewController())
        } else {
            showRoot(animated: false)
        }
        window.makeKeyAndVisible()

        if let router = window.rootViewController as? AppRouter, let i = args.firstIndex(of: "-route"), i + 1 < args.count {
            let route = args[i + 1]
            DispatchQueue.main.async {
                if route.hasPrefix("chat:") { router.openSession(String(route.dropFirst(5))) }
                if route == "new" { router.presentNewSession(prompt: nil) }
                if route == "more" { router.showSettings() }
                if route == "search" { router.showSearch() }
            }
        }
    }

    private func showRoot(animated: Bool) {
        guard let window else { return }
        // iPad gets the t3-style split shell (it collapses to the tab shell
        // at compact widths); iPhone the tab shell directly.
        let root: UIViewController = !app.isSignedIn
            ? SignInViewController(app: app)
            : UIDevice.current.userInterfaceIdiom == .pad ? SplitRootController(app: app) : MainTabController(app: app)
        guard animated, window.rootViewController != nil else {
            window.rootViewController = root
            return
        }
        UIView.transition(with: window, duration: 0.35, options: [.transitionCrossDissolve, .allowAnimatedContent]) {
            window.rootViewController = root
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        app.didEnterBackground()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        app.willEnterForeground()
    }
}

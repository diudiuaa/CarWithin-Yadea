import UIKit

extension Notification.Name {
    /// 由 carwithin://start 触发，交给主界面自动启动 CarPlay。
    static let carwithinAutoStart = Notification.Name("CarWithinAutoStart")
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Receiver", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let navigation = UINavigationController(rootViewController: ReceiverViewController())
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        navigation.navigationBar.standardAppearance = appearance
        navigation.navigationBar.scrollEdgeAppearance = appearance
        navigation.navigationBar.tintColor = .systemBlue
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
        handle(connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handle(URLContexts)
    }

    /// carwithin://start —— 快捷指令个人自动化（例如「连上仪表 Wi-Fi」）可以直接拉起并开始投屏。
    private func handle(_ contexts: Set<UIOpenURLContext>) {
        for context in contexts where context.url.scheme?.lowercased() == "carwithin" {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .carwithinAutoStart, object: nil)
            }
        }
    }
}

import HomeRelayCore
import UIKit

// HMHomeManager only delivers callbacks inside a UIKit app lifecycle with a
// connected, active window scene. HomeRelay therefore runs as a Mac Catalyst
// app with a 1x1 hidden window (LSUIElement) rather than as a plain daemon.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private var store: HomeKitStore?
    private var serverTask: Task<Void, Never>?
    private var advertiser: BonjourAdvertiser?
    private var activity: NSObjectProtocol?
    private let events = EventHub()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let config = Config.fromEnvironment()
        Log.info("HomeRelay \(Config.version) starting; tokens at \(config.tokensFile.path)")

        // A windowless Catalyst app is a prime App Nap candidate; keep timers
        // and sockets responsive without stopping the Mac from sleeping.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Serving the HomeRelay API")

        NotificationCenter.default.addObserver(forName: .homeRelaySceneActive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.start(config) }
        }
        return true
    }

    private func start(_ config: Config) {
        guard store == nil else { return }
        let store = HomeKitStore(events: events, pollInterval: config.pollInterval)
        self.store = store

        let router = APIRouter(
            backend: store,
            tokens: TokenStore(path: config.tokensFile),
            events: events,
            version: Config.version,
            logReads: config.logReads,
            log: { Log.info($0) }
        )
        let server = HTTPServer(host: config.host, port: config.port) { await router.handle($0) }
        let port = config.port
        serverTask = Task.detached {
            do {
                try await server.run { bound in Log.info("Listening on \(config.host):\(bound)") }
            } catch {
                Log.error("HTTP server stopped: \(error)")
                exit(75) // EX_TEMPFAIL: launchd restarts us.
            }
        }
        advertiser = BonjourAdvertiser(port: port, txt: ["api": "/api/v1", "version": Config.version])
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        windowScene.sizeRestrictions?.minimumSize = CGSize(width: 1, height: 1)
        windowScene.sizeRestrictions?.maximumSize = CGSize(width: 1, height: 1)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        NotificationCenter.default.post(name: .homeRelaySceneActive, object: nil)
    }
}

extension Notification.Name {
    static let homeRelaySceneActive = Notification.Name("HomeRelaySceneActive")
}

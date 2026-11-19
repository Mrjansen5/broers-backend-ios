// Broers Backend for iPhone — a thin native shell around the web app (broersbackend.snjco.ca/cal/) whose one job
// beyond showing the page is the Radio: on iPhone the web Radio's microphone stops when the screen locks, so here
// the Radio runs natively (RadioEngine) and keeps going with the screen locked and the phone in a pocket.
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = WebViewController()
        w.backgroundColor = UIColor(red: 15 / 255, green: 13 / 255, blue: 12 / 255, alpha: 1)
        w.makeKeyAndVisible()
        window = w
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        RadioEngine.shared.leave(reason: "closed")
    }
}

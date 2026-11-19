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
        #if DEBUG
        radioSelfTest()
        #endif
        return true
    }

    #if DEBUG
    /// CI only (Debug builds): `simctl launch … -radioSelfTestToken <temp sign-in> [-radioSelfTestCallKit NO]` joins the
    /// real team channel without a tap, then presses the "headset button" twice so the mute flips can be seen on
    /// the server and by a web phone on the same channel.
    private func radioSelfTest() {
        let d = UserDefaults.standard
        guard let t = d.string(forKey: "radioSelfTestToken"), !t.isEmpty else { return }
        if d.object(forKey: "radioSelfTestCallKit") != nil { RadioEngine.shared.setUseCallKit(d.bool(forKey: "radioSelfTestCallKit")) }
        NSLog("[radio] SELFTEST start")
        let r = RadioEngine.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { r.join(token: t, myName: "iPhone self-test") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { NSLog("[radio] SELFTEST press 1"); r.headsetPress(source: "selftest") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { NSLog("[radio] SELFTEST press 2"); r.headsetPress(source: "selftest") }
    }
    #endif

    func applicationWillTerminate(_ application: UIApplication) {
        RadioEngine.shared.leave(reason: "closed")
    }
}

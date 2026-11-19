// The Radio as a CallKit call ("Broers Radio"). Why a call:
//  - iOS keeps a call's microphone running with the screen locked and the app in the background;
//  - the call routes through the Bluetooth headset's hands-free profile (HFP), mic and earpiece;
//  - the headset's main button reaches us: during a call an HFP headset's single click is a hang-up request
//    (Shokz OpenRun manual: "Click once — End call"). iOS turns that into a CXEndCallAction. Unless the person
//    tapped "Leave the radio" in the app, we FAIL that action (the call carries on) and flip the mic instead.
//  - the lock-screen call screen's Mute button arrives as CXSetMutedCallAction and mutes/unmutes too.
// Free Apple accounts can use CallKit (it needs no entitlement), so this also works on a sideloaded test build.
import Foundation
import CallKit
import AVFoundation
import WebRTC

final class CallManager: NSObject, CXProviderDelegate, CXCallObserverDelegate {
    static let shared = CallManager()

    private let provider: CXProvider
    private let controller = CXCallController()
    private(set) var callID: UUID?
    private var leaving = false
    private var reflecting = false
    private var lastRestart = Date.distantPast

    override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        cfg.includesCallsInRecents = false
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: .main)
        controller.callObserver.setDelegate(self, queue: .main)
    }

    func startCall() {
        let id = UUID()
        callID = id
        leaving = false
        let start = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "Broers Radio"))
        start.isVideo = false
        controller.request(CXTransaction(action: start)) { err in
            if let err = err { NSLog("[radio] CallKit start refused: \(err)") }
        }
    }

    func endCall() {
        guard let id = callID else { return }
        leaving = true
        controller.request(CXTransaction(action: CXEndCallAction(call: id))) { err in
            if let err = err { NSLog("[radio] CallKit end: \(err)") }
        }
    }

    /// Keep the lock-screen mute button in step when the mic is flipped some other way.
    func reflectMuted(_ m: Bool) {
        guard let id = callID, !reflecting else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: m))) { _ in }
    }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        callID = nil
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        RadioEngine.shared.configureAudioSession(activate: false)
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        action.fulfill()
        provider.reportOutgoingCall(with: action.callUUID, connectedAt: nil)
        let u = CXCallUpdate()
        u.remoteHandle = CXHandle(type: .generic, value: "Broers Radio")
        u.localizedCallerName = "Broers Radio"
        u.supportsHolding = false; u.supportsGrouping = false; u.supportsUngrouping = false; u.supportsDTMF = false
        u.hasVideo = false
        provider.reportCall(with: action.callUUID, updated: u)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if leaving || !RadioEngine.shared.on {
            callID = nil
            action.fulfill()
            return
        }
        // Not our own Leave: this is the headset's main button (or the red button on the lock screen).
        // Keep the radio on and flip the mic.
        NSLog("[radio] end-call request refused -> mute toggle")
        action.fail()
        RadioEngine.shared.headsetPress(source: "callkit-end")
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        action.fulfill()
        let eng = RadioEngine.shared
        guard eng.on, action.isMuted != eng.muted else { return }
        reflecting = true
        eng.setMuted(action.isMuted, source: "callkit-mute")
        reflecting = false
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        // A real phone call came in and the person answered it: the radio mic goes quiet meanwhile.
        action.fulfill()
        if action.isOnHold, !RadioEngine.shared.muted { RadioEngine.shared.setMuted(true, source: "held") }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RadioEngine.shared.audioActivated()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    // MARK: CXCallObserverDelegate — safety net
    // If iOS ends our call anyway (e.g. it ignored the refused end action), and the person did not leave,
    // count it as the button press and put the radio call straight back up.
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        guard call.uuid == callID, call.hasEnded, !leaving, RadioEngine.shared.on else { return }
        callID = nil
        guard Date().timeIntervalSince(lastRestart) > 3 else { return }
        lastRestart = Date()
        NSLog("[radio] call ended by the system while on the radio -> restart + mute toggle")
        RadioEngine.shared.headsetPress(source: "callkit-ended")
        startCall()
    }
}

// Native Radio — the same team channel as the web Radio tab (server/radio.js in /opt/broers-app), but running in the
// app itself so it keeps working with the iPhone locked and in a pocket.
//
// Protocol (must match server/radio.js and public/cal/radio.js exactly, so iPhone, Android and web are one channel):
//   WebSocket wss://broersbackend.snjco.ca/api/app/radio/ws
//   -> { type:'hello', token, muted, device }           first message; token = the page's localStorage 'bcal_token'
//   <- { type:'welcome', you, ice, peers:[pub] }        the JOINER sends an offer to every peer already on
//   <- { type:'join', peer } / { type:'leave', id } / { type:'state', peer }
//   <-> { type:'signal', to|from, data:{ sdp:{type,sdp} } | { candidate:{candidate,sdpMid,sdpMLineIndex} } }
//   -> { type:'state', muted, talking }   -> { type:'ping' } every 25 s
//   <- { type:'button', action:'toggle'|'mute'|'unmute', source }   (POST /api/app/radio/button relay)
//   close code 4001 / { type:'error', error:'signin' } = sign in again
//
// Staying alive when locked: UIBackgroundModes audio + voip, and the Radio is reported to iOS as a CallKit call
// ("Broers Radio"). A live call keeps the microphone running with the screen locked, routes it through the
// Bluetooth headset (HFP), and puts a call banner with a mute button on the lock screen.
//
// The headset button: during a call, one press of an HFP headset's main button (Shokz OpenRun: "click once = end
// call") arrives as CallKit's end-call action. We refuse that action (the call stays up) and flip the mic instead.
// The lock screen's own mute button arrives as CXSetMutedCallAction and also works. Without CallKit ("media" mode,
// switchable from the page for field testing) the press is looked for as a media play/pause (MPRemoteCommandCenter).
import Foundation
import AVFoundation
import WebRTC
import MediaPlayer
import UIKit

final class RadioEngine: NSObject {
    static let shared = RadioEngine()
    static let wsURL = URL(string: "wss://broersbackend.snjco.ca/api/app/radio/ws")!

    /// Called (main queue) with the state as a JSON string, to be pushed into the page.
    var onState: ((String) -> Void)?

    // State — touched only on the main queue.
    private(set) var on = false
    private(set) var muted = false
    private var talking = false
    private var you = ""
    private var token = ""
    private var myName = "You"
    private var status = ""
    private var peers: [String: [String: Any]] = [:]   // id -> pub(peer) from the server
    private var order: [String] = []                  // join order, for a stable list
    private var links: [String: Peer] = [:]           // id -> WebRTC link
    private var iceServers: [RTCIceServer] = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
    private var ws: URLSessionWebSocketTask?
    private let urlSession = URLSession(configuration: .default)
    private var pingTimer: Timer?
    private var meterTimer: Timer?
    private var reconnectWork: DispatchWorkItem?
    private var lastToggle = Date.distantPast
    private var audioUp = false
    private var loud = 0, quiet = 0

    private(set) var useCallKit: Bool = UserDefaults.standard.object(forKey: "radio.callkit") as? Bool ?? true

    private lazy var factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
    private var localTrack: RTCAudioTrack?

    static let mediaConstraints = RTCMediaConstraints(
        mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"],
        optionalConstraints: nil)

    // MARK: - public controls (from the page bridge, CallKit and the headset)

    func join(token: String, myName: String) {
        guard !on else { return pushState() }
        guard token.count >= 30 else { status = "Sign in again to use the radio."; return pushState() }
        self.token = token
        self.myName = myName
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.status = "The radio needs your microphone. Allow it for Broers Backend in Settings, then try again."
                    return self.pushState()
                }
                self.start()
            }
        }
    }

    private func start() {
        on = true; muted = false; talking = false; status = ""; audioUp = false
        let source = factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true"]))
        localTrack = factory.audioTrack(with: source, trackId: "radio-mic")
        localTrack?.isEnabled = true
        RTCAudioSession.sharedInstance().useManualAudio = useCallKit
        configureAudioSession(activate: !useCallKit)
        if useCallKit {
            CallManager.shared.startCall() // audio is switched on in CallManager's didActivate -> audioActivated()
        } else {
            audioActivated()
        }
        HeadsetButtons.shared.enable { [weak self] name in self?.headsetPress(source: name) }
        connect()
        startMeter()
        pushState()
    }

    func leave(reason: String) {
        guard on else { return }
        let wasUp = audioUp
        if wasUp { Tones.shared.off() }
        on = false; talking = false; you = ""
        reconnectWork?.cancel(); pingTimer?.invalidate(); meterTimer?.invalidate()
        ws?.cancel(with: .normalClosure, reason: reason.data(using: .utf8)); ws = nil
        for id in Array(links.keys) { dropPeer(id) }
        peers.removeAll(); order.removeAll()
        localTrack?.isEnabled = false; localTrack = nil
        HeadsetButtons.shared.disable()
        // Let the "muted" tone finish before the call (and the audio route) goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasUp ? 0.4 : 0)) {
            guard !self.on else { return }
            if self.useCallKit { CallManager.shared.endCall() } else { self.deactivateAudio() }
            self.audioUp = false
        }
        pushState()
    }

    func toggle(source: String) {
        guard on else { return }
        let now = Date()
        if now.timeIntervalSince(lastToggle) < 0.35 { return } // one press can arrive as two actions
        lastToggle = now
        setMuted(!muted, source: source)
    }

    /// A press of the headset's main button, however iOS delivered it.
    func headsetPress(source: String) { toggle(source: "headset:" + source) }

    func setMuted(_ m: Bool, source: String) {
        guard on else { return }
        muted = m
        localTrack?.isEnabled = !m
        if m { talking = false }
        m ? Tones.shared.off() : Tones.shared.on()
        if useCallKit { CallManager.shared.reflectMuted(m) }
        HeadsetButtons.shared.nowPlaying(muted: m, count: peers.count + 1)
        NSLog("[radio] muted=\(m) via \(source)")
        send(["type": "state", "muted": m, "talking": talking])
        pushState()
    }

    func setUseCallKit(_ v: Bool) {
        guard v != useCallKit else { return pushState() }
        let wasOn = on
        if wasOn { leave(reason: "mode") }
        useCallKit = v
        UserDefaults.standard.set(v, forKey: "radio.callkit")
        if wasOn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.join(token: self.token, myName: self.myName) }
        }
        pushState()
    }

    // MARK: - audio session

    func configureAudioSession(activate: Bool) {
        let rtc = RTCAudioSession.sharedInstance()
        let c = RTCAudioSessionConfiguration.webRTC()
        c.category = AVAudioSession.Category.playAndRecord.rawValue
        c.mode = AVAudioSession.Mode.voiceChat.rawValue
        // allowBluetooth = Bluetooth hands-free (HFP): the headset's microphone AND its earpiece.
        // defaultToSpeaker only matters with no headset connected: then you hear the team on the loudspeaker.
        c.categoryOptions = [.allowBluetooth, .defaultToSpeaker]
        RTCAudioSessionConfiguration.setWebRTC(c)
        rtc.lockForConfiguration()
        do {
            if activate { try rtc.setConfiguration(c, active: true) } else { try rtc.setConfiguration(c) }
        } catch { NSLog("[radio] audio session config failed: \(error)") }
        rtc.unlockForConfiguration()
    }

    private func deactivateAudio() {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        try? rtc.setActive(false)
        rtc.unlockForConfiguration()
    }

    /// The audio session is live (CallKit activated it, or we did). Sound can play now.
    func audioActivated() {
        guard on else { return }
        if useCallKit { RTCAudioSession.sharedInstance().isAudioEnabled = true }
        if !audioUp { audioUp = true; Tones.shared.on() }
    }

    // MARK: - signalling

    private func connect() {
        reconnectWork?.cancel()
        let t = urlSession.webSocketTask(with: Self.wsURL)
        ws = t
        t.resume()
        send(["type": "hello", "token": token, "muted": muted, "device": "iphone-app"], on: t)
        receive(t)
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in self?.send(["type": "ping"]) }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.ws === t else { return }
                switch result {
                case .success(let msg):
                    var data: Data?
                    switch msg {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let d = data, let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { self.onMessage(m) }
                    if self.ws === t { self.receive(t) }
                case .failure(let err):
                    self.socketClosed(t, error: err)
                }
            }
        }
    }

    private func socketClosed(_ t: URLSessionWebSocketTask, error: Error) {
        pingTimer?.invalidate()
        guard ws === t else { return }
        ws = nil
        NSLog("[radio] socket closed code=\(t.closeCode.rawValue) \(error.localizedDescription)")
        for id in Array(links.keys) { dropPeer(id) }
        peers.removeAll(); order.removeAll()
        if t.closeCode.rawValue == 4001 { status = "Sign in again to use the radio."; leave(reason: "signin"); return }
        guard on else { return }
        status = "Lost the connection — reconnecting…"
        pushState()
        let w = DispatchWorkItem { [weak self] in if self?.on == true { self?.connect() } }
        reconnectWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    private func send(_ m: [String: Any], on task: URLSessionWebSocketTask? = nil) {
        guard let t = task ?? ws, let d = try? JSONSerialization.data(withJSONObject: m),
              let s = String(data: d, encoding: .utf8) else { return }
        t.send(.string(s)) { err in if let err = err { NSLog("[radio] send failed: \(err.localizedDescription)") } }
    }

    private func onMessage(_ m: [String: Any]) {
        switch m["type"] as? String ?? "" {
        case "welcome":
            you = m["you"] as? String ?? ""
            status = ""
            if let ice = m["ice"] as? [[String: Any]] { iceServers = ice.compactMap(Self.iceServer) }
            peers.removeAll(); order.removeAll()
            for p in (m["peers"] as? [[String: Any]] ?? []) {
                guard let id = p["id"] as? String else { continue }
                peers[id] = p; order.append(id)
                call(id) // the joiner makes the offers, so the two sides never collide
            }
            send(["type": "state", "muted": muted, "talking": talking])
            HeadsetButtons.shared.nowPlaying(muted: muted, count: peers.count + 1)
            pushState()
        case "join":
            if let p = m["peer"] as? [String: Any], let id = p["id"] as? String {
                peers[id] = p; if !order.contains(id) { order.append(id) }
                Tones.shared.blip() // someone came on: one short blip, like the web
                pushState()
            }
        case "leave":
            if let id = m["id"] as? String { peers[id] = nil; order.removeAll { $0 == id }; dropPeer(id); pushState() }
        case "state":
            if let p = m["peer"] as? [String: Any], let id = p["id"] as? String, id != you, peers[id] != nil {
                peers[id] = p; pushState()
            }
        case "signal":
            if let from = m["from"] as? String, let d = m["data"] as? [String: Any] { onSignal(from: from, data: d) }
        case "button":
            let action = m["action"] as? String ?? "toggle", src = m["source"] as? String ?? "native"
            if action == "mute" { if !muted { setMuted(true, source: src) } }
            else if action == "unmute" { if muted { setMuted(false, source: src) } }
            else { toggle(source: src) }
        case "error":
            if (m["error"] as? String) == "signin" { status = "Sign in again to use the radio."; leave(reason: "signin") }
        default: break
        }
    }

    private static func iceServer(_ d: [String: Any]) -> RTCIceServer? {
        var urls: [String] = []
        if let u = d["urls"] as? String { urls = [u] } else if let u = d["urls"] as? [String] { urls = u }
        guard !urls.isEmpty else { return nil }
        if let user = d["username"] as? String, let cred = d["credential"] as? String, !user.isEmpty {
            return RTCIceServer(urlStrings: urls, username: user, credential: cred)
        }
        return RTCIceServer(urlStrings: urls)
    }

    // MARK: - WebRTC links (one per other phone — a full mesh, as on the web)

    private func peer(_ id: String) -> Peer? {
        if let p = links[id] { return p }
        let cfg = RTCConfiguration()
        cfg.iceServers = iceServers
        cfg.sdpSemantics = .unifiedPlan
        cfg.continualGatheringPolicy = .gatherContinually
        let p = Peer(id: id, engine: self)
        let made: RTCPeerConnection? = factory.peerConnection(
            with: cfg, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]),
            delegate: p)
        guard let pc = made else { return nil }
        p.pc = pc
        if let t = localTrack { pc.add(t, streamIds: ["radio"]) }
        links[id] = p
        return p
    }

    private func call(_ id: String) {
        guard let p = peer(id) else { return }
        p.pc.offer(for: Self.mediaConstraints) { [weak self] sdp, err in
            guard let sdp = sdp else { NSLog("[radio] offer failed: \(String(describing: err))"); return }
            p.pc.setLocalDescription(sdp) { _ in
                DispatchQueue.main.async { self?.send(["type": "signal", "to": id, "data": ["sdp": ["type": "offer", "sdp": sdp.sdp]]]) }
            }
        }
    }

    private func onSignal(from: String, data d: [String: Any]) {
        guard on else { return }
        if let sdp = d["sdp"] as? [String: Any], let type = sdp["type"] as? String, let text = sdp["sdp"] as? String {
            if type == "offer" {
                if links[from] != nil { dropPeer(from) } // a fresh call from that phone replaces the old link
                guard let p = peer(from) else { return }
                p.pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: text)) { [weak self] err in
                    if let err = err { NSLog("[radio] remote offer: \(err)"); return }
                    DispatchQueue.main.async { p.remoteReady() }
                    p.pc.answer(for: Self.mediaConstraints) { ans, _ in
                        guard let ans = ans else { return }
                        p.pc.setLocalDescription(ans) { _ in
                            DispatchQueue.main.async { self?.send(["type": "signal", "to": from, "data": ["sdp": ["type": "answer", "sdp": ans.sdp]]]) }
                        }
                    }
                }
            } else if type == "answer", let p = links[from] {
                p.pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: text)) { _ in
                    DispatchQueue.main.async { p.remoteReady() }
                }
            }
        } else if let c = d["candidate"] as? [String: Any], let cand = c["candidate"] as? String, let p = links[from] {
            let idx = Int32((c["sdpMLineIndex"] as? NSNumber)?.intValue ?? 0)
            p.addCandidate(RTCIceCandidate(sdp: cand, sdpMLineIndex: idx, sdpMid: c["sdpMid"] as? String))
        }
    }

    fileprivate func sendCandidate(_ c: RTCIceCandidate, to id: String) {
        var cand: [String: Any] = ["candidate": c.sdp, "sdpMLineIndex": c.sdpMLineIndex]
        if let mid = c.sdpMid { cand["sdpMid"] = mid }
        send(["type": "signal", "to": id, "data": ["candidate": cand]])
    }

    fileprivate func linkChanged(_ p: Peer) {
        guard links[p.id] === p else { return }
        // If a link breaks for good, the newer phone calls again (same rule as the web).
        if p.state == .failed, peers[p.id] != nil, you > p.id { dropPeer(p.id); call(p.id) }
        pushState()
    }

    private func dropPeer(_ id: String) {
        guard let p = links.removeValue(forKey: id) else { return }
        p.pc.close()
    }

    // MARK: - talking detection (your own mic level, read from WebRTC's stats)

    private func startMeter() {
        meterTimer?.invalidate()
        loud = 0; quiet = 0
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.meter() }
    }

    private func meter() {
        guard on, !muted, let p = links.values.first else {
            if talking { talking = false; send(["type": "state", "talking": false]); pushState() }
            return
        }
        p.pc.statistics { [weak self] report in
            var level = 0.0
            for s in report.statistics.values where s.type == "media-source" {
                if (s.values["kind"] as? String) == "audio", let l = s.values["audioLevel"] as? NSNumber { level = l.doubleValue }
            }
            DispatchQueue.main.async {
                guard let self = self, self.on else { return }
                if !self.muted && level > 0.03 { self.loud += 1; self.quiet = 0 } else { self.quiet += 1; self.loud = 0 }
                if !self.talking && self.loud >= 1 && !self.muted { self.talking = true; self.send(["type": "state", "talking": true]); self.pushState() }
                if self.talking && self.quiet >= 4 { self.talking = false; self.send(["type": "state", "talking": false]); self.pushState() }
            }
        }
    }

    // MARK: - state to the page

    func pushState() {
        var list: [[String: Any]] = []
        for id in order {
            guard var p = peers[id] else { continue }
            let st = links[id]?.state
            p["link"] = st == nil ? "" : st == .connected ? "connected" : (st == .failed || st == .disconnected) ? "bad" : "connecting"
            list.append(p)
        }
        let s: [String: Any] = ["on": on, "muted": muted, "talking": talking, "you": you, "status": status,
                                "callkit": useCallKit, "peers": list, "native": true]
        guard let d = try? JSONSerialization.data(withJSONObject: s), let j = String(data: d, encoding: .utf8) else { return }
        onState?(j)
    }
}

// One WebRTC link to one other phone.
final class Peer: NSObject, RTCPeerConnectionDelegate {
    let id: String
    weak var engine: RadioEngine?
    var pc: RTCPeerConnection!
    var state: RTCPeerConnectionState = .new
    private var remoteSet = false
    private var pending: [RTCIceCandidate] = []

    init(id: String, engine: RadioEngine) { self.id = id; self.engine = engine }

    func remoteReady() {
        remoteSet = true
        for c in pending { pc.add(c) { _ in } }
        pending.removeAll()
    }

    func addCandidate(_ c: RTCIceCandidate) {
        if remoteSet { pc.add(c) { _ in } } else { pending.append(c) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async { self.engine?.sendCandidate(candidate, to: self.id) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        DispatchQueue.main.async {
            self.state = newState
            NSLog("[radio] link \(self.id) state \(newState.rawValue)")
            self.engine?.linkChanged(self)
        }
    }
}

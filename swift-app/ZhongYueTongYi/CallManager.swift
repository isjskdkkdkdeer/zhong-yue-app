import Foundation
import UIKit
import AVFoundation
import CoreMedia
import CryptoKit
import WebRTC
import Supabase

// MARK: - 通话（第 10 步：原生语音视频通话，WebRTC）
//
// 信令走 Supabase Realtime Broadcast（VM 上实测过：原生 Phoenix 协议，
// 两个客户端加入同一个频道，A 发 broadcast、B 能收到；supabase-js 那个
// 客户端在 VM 代理下订阅超时是它自己的问题，服务器本身没问题）。
// 每人订阅自己的频道 zy-call-<我的好友号>，给对方发消息就是往对方的频道发。
// 来电只有 App 打开时能收到（锁屏来电要 APNs + CallKit，开发者账号登不进去，
// 卡住了，不做假的）。
// ICE：Google STUN ×2 + Metered Open Relay TURN（照网页版：HMAC-SHA1 现算
// 24 小时凭证，用户名是过期时间戳）。

/// 通话状态。
enum CallState: Equatable {
    case idle
    case outgoing // 我拨出，等对方接
    case incoming // 对方打来，等我接
    case active // 已接通
}

/// 对方打来的邀请（来电界面用 fullScreenCover 弹出来）。
struct CallInvitation: Identifiable, Equatable {
    var id: String { callId }
    let callId: String
    let fromNumber: String
    let fromName: String
    let isVideo: Bool
    let offerSdp: String
}

/// 通话弹框（权限没开 / 对方挂断 / 对方正忙这些要告诉用户的话）。
struct CallAlert: Identifiable {
    var id = UUID()
    var title: String
    var message: String
    var showSettings: Bool = false
}

/// 一条通话记录（本机存，最多 100 条）。
struct CallLogEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var peerNumber: String
    var peerName: String
    var isVideo: Bool
    var direction: String // "in" 进 / "out" 出
    var missed: Bool
    var startedAt: Date
    var duration: Int // 秒
}

/// 通话结束的原因（内部用）。
enum CallEndReason {
    case selfHangup
    case peerHangup
    case declined
    case busy
    case noAnswer
    case failed
    case cancelled
}

/// WebRTC 回调桥：RTCPeerConnectionDelegate 的回调不在主线程，
/// 这里只做转发，真正的状态改动都回到主线程的 CallManager 里做。
final class RTCDelegateBridge: NSObject, RTCPeerConnectionDelegate {
    weak var manager: CallManager?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor [weak manager] in manager?.didAddRemoteStream(stream) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak manager] in manager?.iceConnectionChanged(newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak manager] in manager?.didGenerateIceCandidate(candidate) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak manager] in manager?.connectionChanged(newState) }
    }

    // Unified Plan 下远端轨道从这里来（didAddStream 只在 Plan B 下触发）。
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        Task { @MainActor [weak manager] in manager?.didAddReceiver(rtpReceiver) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {}
}

// MARK: - 通话管理器（单例，全 App 共用）

@MainActor
final class CallManager: ObservableObject {
    static let shared = CallManager()

    // MARK: 界面状态

    @Published private(set) var state: CallState = .idle
    @Published private(set) var isVideoCall = false
    @Published private(set) var peerNumber = ""
    @Published private(set) var peerDisplayName = ""
    /// 通话中状态行：正在呼叫… / 正在连接… / 通话中 / 网络不太好…
    @Published private(set) var callStatusText = ""
    @Published private(set) var callDuration = 0
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeakerOn = false
    @Published private(set) var isVideoEnabled = true
    @Published private(set) var isFrontCamera = true
    /// 来电邀请：不为空时 MainTabView 弹出来电界面。
    @Published var incomingInvitation: CallInvitation?
    /// 拨出 / 通话中界面：为 true 时 MainTabView 弹通话界面。
    @Published var showActiveCall = false
    /// 需要弹框告诉用户的话（权限、对方挂断等）。
    @Published var callAlert: CallAlert?
    /// 远端 / 本机视频轨道（界面用 RTCVideoView 挂上去显示）。
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    @Published private(set) var localVideoTrack: RTCVideoTrack?
    /// 通话记录（本机）。
    @Published private(set) var callLog: [CallLogEntry] = []

    // MARK: 内部状态

    private let factory = RTCPeerConnectionFactory()
    private var peerConnection: RTCPeerConnection?
    private var bridge: RTCDelegateBridge?
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoSource: RTCVideoSource?
    private var capturer: RTCCameraVideoCapturer?

    private var myNumber = ""
    private var isFriendCheck: ((String) -> Bool)?
    private var channel: RealtimeChannelV2?
    private var broadcastSub: RealtimeSubscription?
    private var peerChannels: [String: RealtimeChannelV2] = [:]
    private var subscribedPeerTopics: Set<String> = []
    private var signalingRetryTask: Task<Void, Never>?

    private var callId = ""
    private var isCaller = false
    private var pendingInvite: CallInvitation?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var callStartDate: Date?
    private var connectedOnce = false

    private var ringLoopTask: Task<Void, Never>?
    private var ringbackLoopTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var durationTimer: Timer?

    private let logKey = "zy-call-log"
    /// 无人接听超时（秒）：拨出 / 来电 45 秒没人接就挂断。
    private let noAnswerTimeout: TimeInterval = 45

    private init() {
        loadLog()
    }

    // MARK: - 身份与信令订阅

    /// MainTabView 登录后调：记下我的好友号和“是不是好友”的判断，
    /// 然后订阅我的来电频道。
    func configure(myNumber: String, isFriend: @escaping (String) -> Bool) {
        self.myNumber = myNumber
        self.isFriendCheck = isFriend
    }

    /// 订阅我的来电频道 zy-call-<我的好友号>。没设好友号就不订阅
    /// （没号别人也打不进来）。订阅失败会每 10 秒重试一次，直到成功或停止。
    func startSignaling() {
        guard myNumber.count == 6, myNumber.allSatisfy({ $0.isNumber }) else { return }
        guard channel == nil else { return }
        signalingRetryTask?.cancel()
        signalingRetryTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                if await self.subscribeOnce() { break }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    /// 退订（切后台 / 退出登录时调；通话中的连接不受影响，信令断了对方挂断发不过来，
    /// 通话会走 ICE 失败那条路断开）。
    func stopSignaling() async {
        signalingRetryTask?.cancel()
        signalingRetryTask = nil
        broadcastSub = nil
        if let channel {
            await channel.unsubscribe()
            self.channel = nil
        }
        peerChannels.removeAll()
        subscribedPeerTopics.removeAll()
    }

    /// 订阅一次：建频道、挂收消息回调、加入频道。成功返回 true。
    private func subscribeOnce() async -> Bool {
        let client = SupabaseManager.shared.client
        let topic = "zy-call-\(myNumber)"
        let ch = client.realtimeV2.channel(topic)
        channel = ch
        broadcastSub = ch.onBroadcast(event: "call-signal") { [weak self] json in
            Task { @MainActor [weak self] in self?.handleSignal(json) }
        }
        do {
            try await ch.subscribeWithError()
            return true
        } catch {
            return false
        }
    }

    /// 给对方发一条信令（往对方的频道发）。对方频道没订阅过就先订阅再发。
    private func sendSignal(_ payload: JSONObject, to peer: String) async {
        let client = SupabaseManager.shared.client
        let topic = "zy-call-\(peer)"
        let ch: RealtimeChannelV2
        if let cached = peerChannels[topic] {
            ch = cached
        } else {
            ch = client.realtimeV2.channel(topic)
            peerChannels[topic] = ch
        }
        if !subscribedPeerTopics.contains(topic) {
            do {
                try await ch.subscribeWithError()
                subscribedPeerTopics.insert(topic)
            } catch {
                return
            }
        }
        await ch.broadcast(event: "call-signal", message: payload)
    }

    /// 发一条信令的快捷写法（kind + 对方号码 + 通话 id + 扩展字段）。
    private func sendSignal(kind: String, to peer: String, callId: String, extra: JSONObject = [:]) async {
        var payload: JSONObject = [
            "kind": .string(kind),
            "from": .string(myNumber),
            "to": .string(peer),
            "callId": .string(callId),
        ]
        for (k, v) in extra { payload[k] = v }
        await sendSignal(payload, to: peer)
    }

    // MARK: - 收信令

    /// 收到对方发来的信令（来电频道上收到的都是发给我的）。
    private func handleSignal(_ json: JSONObject) {
        guard let kind = json["kind"]?.stringValue,
              let from = json["from"]?.stringValue, !from.isEmpty,
              from != myNumber else { return }
        guard json["to"]?.stringValue == myNumber else { return }
        let cid = json["callId"]?.stringValue ?? ""
        switch kind {
        case "invite":
            handleInvite(from: from, callId: cid, json: json)
        case "accept":
            guard state == .outgoing, cid == callId,
                  let sdp = json["sdp"]?.stringValue else { return }
            stopRingback()
            timeoutTask?.cancel()
            timeoutTask = nil
            callStatusText = "正在连接…"
            state = .active
            Task { await self.setRemoteDescription(sdp: sdp, type: .answer) }
        case "decline":
            guard state == .outgoing, cid == callId else { return }
            endCall(reason: .declined, notice: "对方挂断了")
        case "busy":
            guard state == .outgoing, cid == callId else { return }
            endCall(reason: .busy, notice: "对方正在通话中")
        case "cancel":
            // 对方拨出后又取消了：来电界面直接消失，记一次未接来电。
            guard state == .incoming, cid == callId else { return }
            addLog(peerNumber: from, peerName: pendingInvite?.fromName ?? "好友 \(from)",
                   isVideo: pendingInvite?.isVideo ?? false, direction: "in", missed: true, duration: 0)
            teardown()
            state = .idle
        case "hangup":
            guard state == .active, cid == callId else { return }
            endCall(reason: .peerHangup, notice: "对方已挂断")
        case "ice":
            guard cid == callId, !cid.isEmpty,
                  let cand = json["candidate"]?.objectValue,
                  let sdp = cand["sdp"]?.stringValue,
                  let lineIndex = cand["sdpMLineIndex"]?.intValue else { return }
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(lineIndex), sdpMid: cand["sdpMid"]?.stringValue)
            if peerConnection?.remoteDescription != nil {
                peerConnection?.add(candidate, completionHandler: nil)
            } else {
                // 对方描述还没设好：先攒着，等设好再加。
                pendingCandidates.append(candidate)
            }
        default:
            break
        }
    }

    /// 对方打来电话：不是好友不接（陌生号码直接忽略，不响铃）；
    /// 我正在通话中就回“正忙”。
    private func handleInvite(from: String, callId: String, json: JSONObject) {
        guard let isVideo = json["isVideo"]?.boolValue,
              let sdp = json["sdp"]?.stringValue, !sdp.isEmpty else { return }
        if state != .idle {
            Task { await self.sendSignal(kind: "busy", to: from, callId: callId) }
            return
        }
        guard isFriendCheck?(from) == true else { return }
        let invite = CallInvitation(
            callId: callId, fromNumber: from,
            fromName: "好友 \(from)", isVideo: isVideo, offerSdp: sdp
        )
        pendingInvite = invite
        self.callId = callId
        isCaller = false
        isVideoCall = isVideo
        peerNumber = from
        peerDisplayName = invite.fromName
        state = .incoming
        incomingInvitation = invite
        startRingtoneLoop()
        // 45 秒没人接：自动挂断，记一次未接来电。
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(45 * 1_000_000_000))
            guard let self, self.state == .incoming, self.callId == callId else { return }
            await self.sendSignal(kind: "decline", to: from, callId: callId)
            self.addLog(peerNumber: from, peerName: invite.fromName, isVideo: isVideo,
                        direction: "in", missed: true, duration: 0)
            self.teardown()
            self.state = .idle
        }
    }

    // MARK: - 拨打 / 接听 / 挂断

    /// 拨打（好友聊天页和好友行的语音 / 视频按钮都调这里）。
    func startCall(to peer: String, displayName: String, isVideo: Bool) async {
        guard state == .idle else {
            callAlert = CallAlert(title: "正在通话中", message: "先挂掉当前通话，再打给别人。")
            return
        }
        guard myNumber.count == 6 else {
            callAlert = CallAlert(title: "打不了电话", message: "请先在个人资料里设置 6 位好友号再打电话。")
            return
        }
        guard peer != myNumber else {
            callAlert = CallAlert(title: "打不了电话", message: "不能给自己打电话。")
            return
        }
        if let err = await ensurePermissions(isVideo: isVideo) {
            callAlert = CallAlert(title: "打不了电话", message: err, showSettings: true)
            return
        }
        isCaller = true
        isVideoCall = isVideo
        peerNumber = peer
        peerDisplayName = displayName
        callId = UUID().uuidString
        callStatusText = "正在呼叫…"
        configureAudioSession()
        createPeerConnection()
        addLocalTracks()
        guard let offer = await createOffer() else {
            endCall(reason: .failed, notice: "通话没能发起，请检查网络再试")
            return
        }
        guard await setLocalDescription(offer) else {
            endCall(reason: .failed, notice: "通话没能发起，请检查网络再试")
            return
        }
        state = .outgoing
        showActiveCall = true
        startRingbackLoop()
        await sendSignal(kind: "invite", to: peer, callId: callId, extra: [
            "isVideo": .bool(isVideo),
            "sdp": .string(offer.sdp),
        ])
        // 45 秒对方没接：挂断，提示对方没有接听。
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(45 * 1_000_000_000))
            guard let self, self.state == .outgoing, self.isCaller else { return }
            await self.sendSignal(kind: "cancel", to: self.peerNumber, callId: self.callId)
            self.endCall(reason: .noAnswer, notice: "对方没有接听")
        }
    }

    /// 接听来电。
    func acceptIncoming() async {
        guard state == .incoming, let invite = pendingInvite else { return }
        stopRingtone()
        timeoutTask?.cancel()
        timeoutTask = nil
        configureAudioSession()
        createPeerConnection()
        addLocalTracks()
        let offer = RTCSessionDescription(type: .offer, sdp: invite.offerSdp)
        guard await setRemoteDescription(offer) else {
            endCall(reason: .failed, notice: "接通失败，请检查网络再试")
            return
        }
        drainPendingCandidates()
        guard let answer = await createAnswer() else {
            endCall(reason: .failed, notice: "接通失败，请检查网络再试")
            return
        }
        guard await setLocalDescription(answer) else {
            endCall(reason: .failed, notice: "接通失败，请检查网络再试")
            return
        }
        state = .active
        showActiveCall = true
        incomingInvitation = nil
        pendingInvite = nil
        callStatusText = "正在连接…"
        callStartDate = Date()
        await sendSignal(kind: "accept", to: peerNumber, callId: callId, extra: [
            "sdp": .string(answer.sdp),
        ])
    }

    /// 拒接来电。
    func declineIncoming() {
        guard state == .incoming, let invite = pendingInvite else { return }
        Task { await self.sendSignal(kind: "decline", to: invite.fromNumber, callId: invite.callId) }
        addLog(peerNumber: invite.fromNumber, peerName: invite.fromName, isVideo: invite.isVideo,
               direction: "in", missed: true, duration: 0)
        teardown()
        state = .idle
    }

    /// 挂断（拨出中点挂断 = 取消；通话中点挂断 = 挂断；对方会同步收到）。
    func hangup() {
        if state == .outgoing {
            Task { await self.sendSignal(kind: "cancel", to: self.peerNumber, callId: self.callId) }
            endCall(reason: .selfHangup, notice: nil)
        } else if state == .active {
            Task { await self.sendSignal(kind: "hangup", to: self.peerNumber, callId: self.callId) }
            endCall(reason: .selfHangup, notice: nil)
        }
    }

    /// 收尾：停铃声 / 停计时、记通话记录、关连接、回到闲置状态。
    /// notice 不为空时弹框告诉用户（对方挂断 / 正忙 / 没人接 / 断开了）。
    private func endCall(reason: CallEndReason, notice: String?) {
        let duration = callDuration
        let wasActive = (state == .active)
        let wasOutgoing = (state == .outgoing)
        if wasActive || wasOutgoing {
            addLog(peerNumber: peerNumber, peerName: peerDisplayName, isVideo: isVideoCall,
                   direction: isCaller ? "out" : "in", missed: false, duration: wasActive ? duration : 0)
        }
        teardown()
        state = .idle
        if let notice {
            callAlert = CallAlert(title: "通话结束", message: notice)
        }
    }

    /// 关连接、停采集、停铃声、停计时、恢复音频会话。
    private func teardown() {
        timeoutTask?.cancel()
        timeoutTask = nil
        stopRingtone()
        stopRingback()
        stopDurationTimer()
        capturer?.stopCapture()
        capturer = nil
        peerConnection?.close()
        peerConnection = nil
        bridge = nil
        localAudioTrack = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
        localVideoSource = nil
        pendingCandidates.removeAll()
        pendingInvite = nil
        incomingInvitation = nil
        showActiveCall = false
        callDuration = 0
        connectedOnce = false
        isMuted = false
        isSpeakerOn = false
        isVideoEnabled = true
        isFrontCamera = true
        callStatusText = ""
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        _ = try? session.setActive(false)
        session.unlockForConfiguration()
    }

    // MARK: - 通话中控制

    func toggleMute() {
        isMuted.toggle()
        localAudioTrack?.isEnabled = !isMuted
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        _ = try? session.overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
    }

    func toggleVideo() {
        guard isVideoCall else { return }
        isVideoEnabled.toggle()
        localVideoTrack?.isEnabled = isVideoEnabled
    }

    func switchCamera() {
        guard isVideoCall, let capturer else { return }
        isFrontCamera.toggle()
        capturer.stopCapture()
        startCapture(front: isFrontCamera)
    }

    // MARK: - WebRTC 连接

    private func createPeerConnection() {
        let config = RTCConfiguration()
        config.iceServers = Self.iceServers()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let bridge = RTCDelegateBridge()
        bridge.manager = self
        self.bridge = bridge
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: bridge)
    }

    /// 本机音视频轨道加进连接（语音一定有；视频通话再加摄像头）。
    private func addLocalTracks() {
        guard let pc = peerConnection else { return }
        let audioTrack = factory.audioTrack(withTrackId: "audio0")
        localAudioTrack = audioTrack
        pc.add(audioTrack, streamIds: ["stream0"])
        guard isVideoCall else { return }
        let videoSource = factory.videoSource()
        localVideoSource = videoSource
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
        localVideoTrack = videoTrack
        pc.add(videoTrack, streamIds: ["stream0"])
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        self.capturer = capturer
        isFrontCamera = true
        startCapture(front: true)
    }

    /// 开摄像头（前置优先；没前置就用第一个能用的）。
    private func startCapture(front: Bool) {
        guard let capturer else { return }
        let devices = RTCCameraVideoCapturer.captureDevices()
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats.first(where: {
            let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dims.width >= 640 && dims.width <= 1280
        }) ?? formats.first else { return }
        capturer.startCapture(with: device, format: format, fps: 30)
    }

    private func createOffer() async -> RTCSessionDescription? {
        guard let pc = peerConnection else { return nil }
        let constraints = RTCMediaConstraints(mandatoryConstraints: [
            "OfferToReceiveAudio": "true",
            "OfferToReceiveVideo": isVideoCall ? "true" : "false",
        ], optionalConstraints: nil)
        return await withCheckedContinuation { cont in
            pc.offer(for: constraints) { sdp, error in
                cont.resume(returning: error == nil ? sdp : nil)
            }
        }
    }

    private func createAnswer() async -> RTCSessionDescription? {
        guard let pc = peerConnection else { return nil }
        let constraints = RTCMediaConstraints(mandatoryConstraints: [
            "OfferToReceiveAudio": "true",
            "OfferToReceiveVideo": isVideoCall ? "true" : "false",
        ], optionalConstraints: nil)
        return await withCheckedContinuation { cont in
            pc.answer(for: constraints) { sdp, error in
                cont.resume(returning: error == nil ? sdp : nil)
            }
        }
    }

    private func setLocalDescription(_ sdp: RTCSessionDescription) async -> Bool {
        guard let pc = peerConnection else { return false }
        return await withCheckedContinuation { cont in
            pc.setLocalDescription(sdp) { error in
                cont.resume(returning: error == nil)
            }
        }
    }

    private func setRemoteDescription(sdp: String, type: RTCSdpType) async -> Bool {
        guard let pc = peerConnection else { return false }
        let desc = RTCSessionDescription(type: type, sdp: sdp)
        let ok = await withCheckedContinuation { cont in
            pc.setRemoteDescription(desc) { error in
                cont.resume(returning: error == nil)
            }
        }
        if ok { drainPendingCandidates() }
        return ok
    }

    /// 远端描述设好后，把之前攒着的 ICE 候选一次性加进去。
    private func drainPendingCandidates() {
        guard let pc = peerConnection, pc.remoteDescription != nil else { return }
        for candidate in pendingCandidates {
            pc.add(candidate, completionHandler: nil)
        }
        pendingCandidates.removeAll()
    }

    // MARK: - WebRTC 回调（桥接过来的，都在主线程）

    /// 远端视频轨道来了（Unified Plan 走 didAddReceiver，Plan B 走 didAddStream，
    /// 两个回调都调这里，以先到的为准）。
    func didAddReceiver(_ receiver: RTCRtpReceiver) {
        if let videoTrack = receiver.track as? RTCVideoTrack {
            remoteVideoTrack = videoTrack
        }
    }

    func didAddRemoteStream(_ stream: RTCMediaStream) {
        if remoteVideoTrack == nil, let videoTrack = stream.videoTracks.first {
            remoteVideoTrack = videoTrack
        }
    }

    /// 本机找到 ICE 候选就发给对方。
    func didGenerateIceCandidate(_ candidate: RTCIceCandidate) {
        guard state == .outgoing || state == .active, !callId.isEmpty else { return }
        let cand: JSONObject = [
            "sdp": .string(candidate.sdp),
            "sdpMLineIndex": .integer(Int(candidate.sdpMLineIndex)),
            "sdpMid": .string(candidate.sdpMid ?? ""),
        ]
        Task {
            await self.sendSignal(kind: "ice", to: self.peerNumber, callId: self.callId,
                                  extra: ["candidate": .object(cand)])
        }
    }

    func iceConnectionChanged(_ newState: RTCIceConnectionState) {
        guard state == .active else { return }
        if newState == .connected || newState == .completed {
            callStatusText = "通话中"
            startDurationTimer()
        } else if newState == .disconnected {
            callStatusText = "网络不太好…"
        } else if newState == .failed {
            endCall(reason: .failed, notice: "通话断开了，请检查网络再试")
        }
    }

    func connectionChanged(_ newState: RTCPeerConnectionState) {
        guard state == .active else { return }
        if newState == .connected {
            callStatusText = "通话中"
            startDurationTimer()
        } else if newState == .failed {
            endCall(reason: .failed, notice: "通话断开了，请检查网络再试")
        }
    }

    // MARK: - 音频会话与权限

    /// 通话用 playAndRecord + voiceChat（听筒 / 免提都走这条）。
    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        _ = try? session.setCategory(
            AVAudioSession.Category.playAndRecord.rawValue,
            mode: AVAudioSession.Mode.voiceChat.rawValue,
            options: []
        )
        _ = try? session.setActive(true)
        // 视频通话默认开免提，语音默认用听筒。
        if isVideoCall {
            _ = try? session.overrideOutputAudioPort(.speaker)
            isSpeakerOn = true
        }
    }

    /// 拨打前查权限：没给过就弹窗要；拒绝过就返回原因（界面提示去设置里开）。
    private func ensurePermissions(isVideo: Bool) async -> String? {
        let micStatus = AVAudioSession.sharedInstance().recordPermission
        switch micStatus {
        case .denied:
            return "麦克风权限没开：去手机设置里打开这个 App 的麦克风权限，才能打电话。"
        case .undetermined:
            let granted = await AVAudioSession.sharedInstance().requestRecordPermission()
            if !granted { return "没有麦克风权限打不了电话，去手机设置里打开麦克风权限再试。" }
        default:
            break
        }
        guard isVideo else { return nil }
        let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch camStatus {
        case .denied, .restricted:
            return "相机权限没开：去手机设置里打开这个 App 的相机权限，才能打视频电话（语音电话不受影响）。"
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { return "没有相机权限打不了视频电话，去手机设置里打开相机权限再试。" }
        default:
            break
        }
        return nil
    }

    // MARK: - 铃声（来电响用户选的铃声，拨出响回铃音）

    /// 来电铃声循环响（音调 2.5 秒一次，歌曲 30 秒一首播完再响）。
    private func startRingtoneLoop() {
        stopRingtone()
        let isSong = ringtoneIsSong()
        ringLoopTask = Task { @MainActor in
            while !Task.isCancelled {
                self.playSelectedRingtoneOnce()
                try? await Task.sleep(nanoseconds: UInt64((isSong ? 30 : 2.5) * 1_000_000_000))
            }
        }
    }

    private func stopRingtone() {
        ringLoopTask?.cancel()
        ringLoopTask = nil
        RingtonePlayer.shared.stop()
    }

    /// 拨出回铃音：经典电话铃，每 3 秒响一次，对方接了就停。
    private func startRingbackLoop() {
        stopRingback()
        ringbackLoopTask = Task { @MainActor in
            while !Task.isCancelled {
                RingtonePlayer.shared.play(.classic)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func stopRingback() {
        ringbackLoopTask?.cancel()
        ringbackLoopTask = nil
        RingtonePlayer.shared.stop()
    }

    /// 响一次用户选的铃声（音调 / 内置歌 / 自己选的歌，和“我的”页铃声选择同一个值）。
    private func playSelectedRingtoneOnce() {
        let stored = UserDefaults.standard.string(forKey: "zy-ringtone") ?? Ringtone.defaultTone.rawValue
        if let tone = Ringtone(rawValue: stored) {
            RingtonePlayer.shared.play(tone)
            return
        }
        if stored.hasPrefix("builtin:") {
            let asset = String(stored.dropFirst("builtin:".count))
            if let data = NSDataAsset(name: asset)?.data {
                RingtonePlayer.shared.playSong(data: data)
            }
            return
        }
        if stored.hasPrefix("user:") {
            let id = String(stored.dropFirst("user:".count))
            if let song = UserSongStore.load().first(where: { $0.id == id }) {
                RingtonePlayer.shared.playSong(url: UserSongStore.fileURL(for: song))
            }
            return
        }
        RingtonePlayer.shared.play(.xylophone)
    }

    private func ringtoneIsSong() -> Bool {
        let stored = UserDefaults.standard.string(forKey: "zy-ringtone") ?? ""
        return stored.hasPrefix("builtin:") || stored.hasPrefix("user:")
    }

    // MARK: - 通话计时与记录

    private func startDurationTimer() {
        guard !connectedOnce else { return }
        connectedOnce = true
        callStartDate = Date()
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.callDuration += 1
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func loadLog() {
        guard let data = UserDefaults.standard.data(forKey: logKey),
              let decoded = try? JSONDecoder().decode([CallLogEntry].self, from: data)
        else { return }
        callLog = decoded
    }

    private func saveLog() {
        if let data = try? JSONEncoder().encode(callLog) {
            UserDefaults.standard.set(data, forKey: logKey)
        }
    }

    private func addLog(peerNumber: String, peerName: String, isVideo: Bool,
                       direction: String, missed: Bool, duration: Int) {
        let entry = CallLogEntry(
            peerNumber: peerNumber, peerName: peerName, isVideo: isVideo,
            direction: direction, missed: missed, startedAt: Date(), duration: duration
        )
        callLog.insert(entry, at: 0)
        if callLog.count > 100 { callLog = Array(callLog.prefix(100)) }
        saveLog()
    }

    // MARK: - ICE 服务器（STUN + TURN）

    /// Google STUN 两个 + Metered Open Relay TURN（照网页版：coturn 静态验证，
    /// 用户名是过期时间戳（现在 + 24 小时），凭证是 base64(HMAC-SHA1(密钥, 用户名))，
    /// 每次建连都现算。TURN 连不上就只剩 STUN，直连不通的通话会失败，不影响直连通话）。
    /// 密钥和网页版用同一个公开共享密钥（网页版 index-redesigned.html 里本来就公开嵌着）。
    private static func iceServers() -> [RTCIceServer] {
        var servers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]),
        ]
        let expiry = Int(Date().timeIntervalSince1970) + 86400
        let username = String(expiry)
        let key = SymmetricKey(data: Data(openRelaySecret.utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(username.utf8), using: key)
        let credential = Data(mac).base64EncodedString()
        servers.append(RTCIceServer(
            urlStrings: [
                "turn:staticauth.openrelay.metered.ca:80",
                "turn:staticauth.openrelay.metered.ca:443",
                "turns:staticauth.openrelay.metered.ca:443",
            ],
            username: username,
            credential: credential
        ))
        return servers
    }

    /// Metered Open Relay 静态验证密钥（和网页版同一个；公开共享密钥，不写进任何汇报和文档）。
    private static let openRelaySecret = "openrelayprojectsecret"
}

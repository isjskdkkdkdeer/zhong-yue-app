import Foundation
import AVFoundation

// MARK: - 消息模型（照网页版聊天记录条目：方向 / 原文 / 译文 / 语言 / 时间）

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Direction: String, Codable {
        case me   // 我发的
        case peer // 对方 / 助手发的
    }

    var id: UUID
    var dir: Direction
    var orig: String
    var trans: String
    var transFail: Bool
    var from: ChatLanguage
    var ts: Date
    var isVoice: Bool

    init(id: UUID = UUID(), dir: Direction, orig: String, trans: String = "",
         transFail: Bool = false, from: ChatLanguage, ts: Date = Date(), isVoice: Bool = false) {
        self.id = id
        self.dir = dir
        self.orig = orig
        self.trans = trans
        self.transFail = transFail
        self.from = from
        self.ts = ts
        self.isVoice = isVoice
    }
}

/// 翻译助手：置顶、不能删、永远在线，id 固定 000000，头像用 App logo。
/// 网页版 BOT_USER 的 id 就是 "000000"。
enum BotAssistant {
    static let id = "000000"
    static let nameZh = "翻译助手"
    static let nameVi = "Trợ lý dịch"

    /// 助手开场白（照网页版 botIntro，按“我说的语言”取）。
    static var intro: String {
        AppLanguage.speakLang == .vi
            ? "Xin chào, tôi là Trợ lý dịch. Giờ tôi có thể trò chuyện với bạn: hỏi tôi, nhờ tôi dịch, học tiếng Trung hay tiếng Việt đều được. Nói tiếng Trung hay tiếng Việt đều được, nhấn mic để nói hoặc gõ chữ."
            : "你好，我是翻译助手。现在我能陪你聊天了：问我问题、让我翻译、教我中文或越南语都可以。说中文或越南语都行，点麦克风说话，或者直接打字。"
    }
}

// MARK: - 语音录音（AVAudioRecorder，最长 30 秒，照网页版 botRecTimer）

@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds = 0

    /// 手指是否还按着麦克风（引用类型标记，权限回调里读它才不会读到旧值）。
    var pressActive = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var finishHandler: ((URL?) -> Void)?

    private var recordingURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zy-voice.m4a")
    }

    func start(onFinish: @escaping (URL?) -> Void) {
        finishHandler = onFinish
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let url = recordingURL
            try? FileManager.default.removeItem(at: url)
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.record()
            elapsedSeconds = 0
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.elapsedSeconds += 1
                    if self.elapsedSeconds >= 30 { self.stop() }
                }
            }
        } catch {
            finishHandler?(nil)
            finishHandler = nil
        }
    }

    /// 停录并回调文件；取消时传 nil（finishHandler 收到 nil 即不发送）。
    func stop(cancelled: Bool = false) {
        timer?.invalidate()
        timer = nil
        let url = recordingURL
        if isRecording {
            recorder?.stop()
        }
        recorder = nil
        isRecording = false
        let handler = finishHandler
        finishHandler = nil
        handler?(cancelled ? nil : url)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // 正常 stop() 会走 stop(cancelled:) 的回调，这里不重复处理。
    }
}

// MARK: - 聊天状态（一个会话一个 ChatStore）

/// 聊天记录存本机（UserDefaults 里按会话存 JSON，最多 300 条，照网页版）。
/// 好友聊天目前是本机自言自语式翻译演示：发出去的话自动翻译成对方语言显示；
/// 真正的端到端消息收发要等好友连接（Supabase / WebSocket）那一步。
@MainActor
final class ChatStore: ObservableObject {
    let conversationId: String
    let isBot: Bool
    let title: String

    @Published private(set) var messages: [ChatMessage] = []
    @Published var voiceError: String?

    private let storageKey: String
    private let workerBase = URL(string: "https://zhong-yue-offline.jameswilson199079.workers.dev")!
    private let translator = TranslationService.shared
    private let speaker = CloudSpeaker.shared

    /// 助手是否开口朗读（默认开，和网页版 botSpeakOn 一致）。
    @Published var botSpeakEnabled: Bool {
        didSet { UserDefaults.standard.set(botSpeakEnabled, forKey: "zy-bot-speak") }
    }

    init(conversationId: String, isBot: Bool, title: String) {
        self.conversationId = conversationId
        self.isBot = isBot
        self.title = title
        self.storageKey = "zy-chat-\(conversationId)"
        self.botSpeakEnabled = UserDefaults.standard.object(forKey: "zy-bot-speak") as? Bool ?? true
        load()
        if isBot && messages.isEmpty {
            // 第一次打开助手：放一句开场白（照网页版 seedBotIntro）。
            let intro = ChatMessage(dir: .peer, orig: BotAssistant.intro, from: AppLanguage.speakLang)
            messages.append(intro)
            save()
        }
    }

    // MARK: 本机存储

    /// 列表页用的最后一条消息预览（不建 ChatStore，直接读本机 JSON）。
    static func lastMessagePreview(for conversationId: String) -> String? {
        guard let data = UserDefaults.standard.data(forKey: "zy-chat-\(conversationId)"),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data),
              let last = decoded.last else { return nil }
        return last.orig
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data)
        else { return }
        messages = decoded
    }

    private func save() {
        if messages.count > 300 { messages = Array(messages.suffix(300)) }
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
        save()
    }

    private func update(_ message: ChatMessage) {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[idx] = message
        save()
    }

    // MARK: 好友聊天（发消息 → 自动翻译成对方语言）

    func sendFriendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lang = detectLanguage(trimmed)
        var msg = ChatMessage(dir: .me, orig: trimmed, trans: "翻译中…", from: lang)
        append(msg)
        Task {
            do {
                let trans = try await translator.translate(text: trimmed, from: lang, to: lang.other)
                msg.trans = trans
                msg.transFail = false
            } catch {
                msg.trans = "翻译失败（上面是原话）"
                msg.transFail = true
            }
            self.update(msg)
        }
    }

    /// 单条翻译失败后点“点一下重新翻译”。
    func retryTranslation(of message: ChatMessage) {
        var msg = message
        msg.trans = "翻译中…"
        msg.transFail = false
        update(msg)
        Task {
            do {
                let trans = try await translator.translate(text: msg.orig, from: msg.from, to: msg.from.other)
                msg.trans = trans
                msg.transFail = false
            } catch {
                msg.trans = "翻译失败（上面是原话）"
                msg.transFail = true
            }
            self.update(msg)
        }
    }

    // MARK: 翻译助手（照网页版 botAnswer / botChat）

    /// 发给助手一句话：先把这句话的翻译填上，再调聊天模型回答。
    /// 助手用另一种语言回（我说中文它回越南话，我说越南话它回中文），
    /// 原文 + 译文叠着显示。聊天失败就只做翻译、不编造回答。
    func sendBotText(_ text: String, isVoice: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let uLang = detectLanguage(trimmed)
        var userMsg = ChatMessage(dir: .me, orig: trimmed, trans: "翻译中…", from: uLang, isVoice: isVoice)
        append(userMsg)
        let other = uLang.other

        // 先翻译用户这句话。
        Task {
            do {
                let trans = try await translator.translate(text: trimmed, from: uLang, to: other)
                userMsg.trans = trans
                userMsg.transFail = false
            } catch {
                userMsg.trans = "翻译失败（上面是原话）"
                userMsg.transFail = true
            }
            self.update(userMsg)
        }

        // 再调聊天模型回答。
        Task {
            do {
                let reply = try await self.botChat()
                let rLang = detectLanguage(reply)
                var replyMsg = ChatMessage(dir: .peer, orig: reply, trans: "翻译中…", from: rLang)
                self.append(replyMsg)
                do {
                    let rt = try await translator.translate(text: reply, from: rLang, to: rLang.other)
                    replyMsg.trans = rt
                    replyMsg.transFail = false
                } catch {
                    replyMsg.trans = ""
                    replyMsg.transFail = false
                }
                self.update(replyMsg)
                if self.botSpeakEnabled {
                    self.speaker.speak(reply, lang: rLang)
                }
            } catch {
                // 聊天失败：退回老办法——直接翻译用户的话当回答。
                do {
                    let trans = try await translator.translate(text: trimmed, from: uLang, to: other)
                    let fallback = ChatMessage(dir: .peer, orig: trans, trans: trimmed, from: other)
                    self.append(fallback)
                    if self.botSpeakEnabled {
                        self.speaker.speak(trans, lang: other)
                    }
                } catch {
                    let fail = ChatMessage(
                        dir: .peer,
                        orig: "翻译失败，请再试一次",
                        from: AppLanguage.speakLang
                    )
                    self.append(fail)
                }
            }
        }
    }

    /// 调云函数 POST /chat（Llama 4 Scout）：带最近 8 条消息，回答 1–3 句。
    private func botChat() async throws -> String {
        let hist = messages.suffix(8)
        var payload: [[String: String]] = []
        for m in hist {
            guard !m.orig.isEmpty else { continue }
            payload.append([
                "role": m.dir == .me ? "user" : "assistant",
                "content": String(m.orig.prefix(1000)),
            ])
        }
        guard !payload.isEmpty else { throw ChatError.noHistory }
        var req = URLRequest(url: workerBase.appendingPathComponent("chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "messages": payload,
            "lang": AppLanguage.speakLang.rawValue,
        ])
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reply = (json["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reply.isEmpty else { throw ChatError.emptyReply }
        return reply
    }

    // MARK: 助手语音（照网页版 botTranscribe）
    //
    // 录音 → 云函数 POST /transcribe（Cloudflare 语音识别，按“我说的语言”）
    // → 识别成文字 → 走 sendBotText → 助手语音回。
    // 失败分情况提示：没声音 / 网络 / 服务不可用 / 没麦克风权限。

    func sendVoiceFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            voiceError = "没听到声音，再说一遍吧"
            return
        }
        let b64 = data.base64EncodedString()
        Task {
            do {
                var req = URLRequest(url: workerBase.appendingPathComponent("transcribe"))
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: [
                    "audio": b64,
                    "lang": AppLanguage.speakLang.rawValue,
                ])
                req.timeoutInterval = 30
                let (respData, _) = try await URLSession.shared.data(for: req)
                guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
                    self.voiceError = "语音服务暂时不可用，稍后再试"
                    return
                }
                if let ok = json["ok"] as? Bool, ok == false {
                    self.voiceError = "语音服务暂时不可用，稍后再试"
                    return
                }
                guard let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else {
                    self.voiceError = "没听到声音，再说一遍吧"
                    return
                }
                self.voiceError = nil
                self.sendBotText(text, isVoice: true)
            } catch {
                if let urlError = error as? URLError,
                   [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost].contains(urlError.code) {
                    self.voiceError = "网络有问题，录音没发出去，请检查网络再试一次"
                } else {
                    self.voiceError = "语音服务暂时不可用，稍后再试"
                }
            }
        }
    }

    /// 点助手消息上的小喇叭，重听这句话（Google 云端语音，播不了退回系统语音）。
    func speakMessage(_ message: ChatMessage) {
        speaker.speak(message.orig, lang: message.from)
    }

    func stopSpeaking() {
        speaker.stop()
    }
}

enum ChatError: Error {
    case noHistory
    case emptyReply
}

import Foundation
import AVFoundation

// MARK: - 消息模型（照网页版聊天记录条目：方向 / 原文 / 译文 / 语言 / 时间）

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Direction: String, Codable {
        case me   // 我发的
        case peer // 对方 / 助手发的
    }

    var id: UUID
    /// 发给服务器用的数字消息 id（POST /send 的 id 字段）。
    /// 云函数对 (to_num, sess, msg_id) 去重：同一条消息重复发不会在对方那边重复入库，
    /// 所以这个 id 生成一次就跟着消息存下来，重发也用同一个。
    /// 注意：这两个新字段写在属性声明里带默认值，旧版本存下来的消息没有这两个键，
    /// 解码时会自动用默认值补上，不会丢旧记录。
    var msgId: Int64 = Int64.random(in: 1...Int64.max)
    /// 发给对方失败（没网 / 401）时标 true，聊天页显示“未发送，点一下重发”。
    var sendFailed: Bool = false
    var dir: Direction
    var orig: String
    var trans: String
    var transFail: Bool
    var from: ChatLanguage
    var ts: Date
    var isVoice: Bool

    init(id: UUID = UUID(), msgId: Int64 = Int64.random(in: 1...Int64.max), sendFailed: Bool = false,
         dir: Direction, orig: String, trans: String = "",
         transFail: Bool = false, from: ChatLanguage, ts: Date = Date(), isVoice: Bool = false) {
        self.id = id
        self.msgId = msgId
        self.sendFailed = sendFailed
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
/// 好友聊天（第 8 步）：发出去的话先存本机 + 立刻调云函数 POST /send 发原文，
/// 翻译在另一条任务里并行跑（第 9 步：以前是等翻译完才发，最多拖 12 秒）；
/// 对方发来的消息由 MessageSyncService 轮询调 GET /inbox 拉取（聊天页 3 秒、列表页 5 秒），
/// 按 from_num 分到对应会话，收到后调 POST /ack 确认。
@MainActor
final class ChatStore: ObservableObject {
    let conversationId: String
    let isBot: Bool
    let title: String

    @Published private(set) var messages: [ChatMessage] = []
    @Published var voiceError: String?
    /// 发消息被拦住时的提示（还不是好友时弹框说清楚原因，不悄悄失败）。
    @Published var sendNotice: String?

    /// 发好友消息用的服务器令牌和我的名字（ChatView 打开聊天页时填进来；助手聊天不用）。
    var serverToken: String?
    var myDisplayName: String = ""
    /// 还不是好友时返回提示文案，成了好友返回 nil（ChatView 打开聊天页时填进来；
    /// 里面先看本机列表，没有就从服务器同步一次再看，防本机列表过期误拦）。
    /// 没填这个闭包就不校验（直接发，别把旧流程堵死）。
    var notFriendNotice: ((String) async -> String?)?

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

    /// 最后一条消息的时间（消息列表里“非好友会话”按这个排先后）。
    static func lastMessageDate(for conversationId: String) -> Date? {
        guard let data = UserDefaults.standard.data(forKey: "zy-chat-\(conversationId)"),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data),
              let last = decoded.last else { return nil }
        return last.ts
    }

    /// 本机有聊天记录的会话号（好友 + 还没成好友就发来消息的人都包括；
    /// 云函数发消息不验好友关系，这种消息照样进收件箱，列表页不能只显示好友）。
    static func storedConversationIds() -> [String] {
        let prefix = "zy-chat-"
        return UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
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

    /// 只改某条消息的译文（发消息和翻译并行跑时用：两个任务同时改同一条消息，
    /// 整条替换会互相盖掉对方改过的字段——比如发消息的任务会把译文盖回“翻译中…”）。
    private func updateTranslationOnly(id: UUID, trans: String, failed: Bool) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].trans = trans
        messages[idx].transFail = failed
        save()
    }

    /// 只改某条消息的“未发送”标记（同上，避免盖掉译文）。
    private func markSendFailed(_ id: UUID, _ failed: Bool) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].sendFailed = failed
        save()
    }

    // MARK: 好友聊天（发消息 → 自动翻译成对方语言 → 发给对方）

    func sendFriendText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            // 还不是好友先拦住：明确告诉用户原因，不要悄悄失败。
            // （对方还没接受请求时，云函数其实照样会存这条消息，对方收件箱也能拉到——
            // 但列表页上没这行、对方那边也说不清，所以发之前先说清楚。）
            if let notice = await self.notFriendNotice?(self.conversationId) {
                self.sendNotice = notice
                return
            }
            let lang = detectLanguage(trimmed)
            let msg = ChatMessage(dir: .me, orig: trimmed, trans: "翻译中…", from: lang)
            self.append(msg)
            // 延迟修（第 9 步）：以前是串行的——先等翻译链跑完（Gemini 5 秒 → 云函数 8 秒 →
            // 谷歌 4 秒，整链最多 12 秒），翻译完才调 POST /send；对方最晚 12 秒后才能
            // 收到，再加上接收端 10 秒一轮的轮询，一条消息最慢 20 多秒才出现。
            // 现在改成并行：先发原文（不带译文，译文空着；对方收到后本机翻译链补译文，
            // pollNow 里本来就这么处理），翻译在另一条任务里跑，译完只补译文。
            Task { await self.sendToServer(msg, trans: "") }
            Task {
                do {
                    let trans = try await self.translator.translate(text: trimmed, from: lang, to: lang.other)
                    self.updateTranslationOnly(id: msg.id, trans: trans, failed: false)
                } catch {
                    self.updateTranslationOnly(id: msg.id, trans: "翻译失败（上面是原话）", failed: true)
                }
            }
        }
    }

    /// 调云函数 POST /send 把一条消息发给对方。
    /// 成功：标记正常；失败（没网 / 401）：消息留在本机并标“未发送”，不丢消息、不崩。
    /// trans 参数：发消息时传 ""（先发原文不等翻译）；重发时不传，用消息里已有的译文。
    private func sendToServer(_ message: ChatMessage, trans: String? = nil) async {
        guard !isBot else { return }
        guard let token = serverToken, !token.isEmpty else {
            markSendFailed(message.id, true)
            return
        }
        let body = WorkerAPI.jsonBody([
            "to": conversationId,
            "orig": message.orig,
            // 翻译失败时发空译文，对方收到后用本机翻译链补译文。
            "trans": trans ?? (message.transFail ? "" : message.trans),
            "lang": message.from.rawValue,
            "ts": Int64(message.ts.timeIntervalSince1970 * 1000),
            "name": myDisplayName,
            "sess": conversationId,
            "id": message.msgId,
        ])
        let result = await WorkerAPI.request(path: "send", method: "POST", token: token, body: body, as: SendResponse.self)
        // 只改 sendFailed 标记，别用整条消息替换（会把并行跑的翻译任务译好的译文盖掉）。
        markSendFailed(message.id, !(result?.status == 200 && result?.value?.ok == true))
    }

    /// “未发送”的消息点一下重发（同一个 msgId，服务器去重，不会重复入库）。
    func retrySend(of message: ChatMessage) {
        guard message.dir == .me, !isBot else { return }
        var m = message
        m.sendFailed = false
        update(m)
        Task { await self.sendToServer(m) }
    }

    /// 从本机存储重新读一次消息（收件箱拉到新消息时刷新打开着的聊天页）。
    func reload() {
        load()
    }

    /// 读某会话的全部本机消息（列表页预览和收件箱去重用）。
    static func loadMessages(for conversationId: String) -> [ChatMessage] {
        guard let data = UserDefaults.standard.data(forKey: "zy-chat-\(conversationId)"),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data)
        else { return [] }
        return decoded
    }

    /// 收到的服务器消息存进对应会话。返回存下来的那条消息的数字 id，
    /// 同一条（同一个 msgId）已存过就返回 nil、不重复存。
    /// 服务器没给 msgId（0）时按原文 + 时间去重，存的时候补一个随机 id。
    @discardableResult
    static func appendIncoming(_ incoming: IncomingMessage) -> Int64? {
        var list = loadMessages(for: incoming.fromNum)
        if incoming.msgId != 0 {
            if list.contains(where: { $0.msgId == incoming.msgId }) { return nil }
        } else if list.contains(where: { $0.orig == incoming.orig && $0.ts == incoming.ts && $0.dir == .peer }) {
            return nil
        }
        let msgId = incoming.msgId != 0 ? incoming.msgId : Int64.random(in: 1...Int64.max)
        let msg = ChatMessage(
            msgId: msgId, dir: .peer, orig: incoming.orig, trans: incoming.trans,
            from: incoming.fromLang, ts: incoming.ts
        )
        list.append(msg)
        if list.count > 300 { list = Array(list.suffix(300)) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: "zy-chat-\(incoming.fromNum)")
        }
        return msgId
    }

    /// 收到的消息本机补译完后，把译文写回本机记录（按数字 id 找那条消息）。
    static func updateTranslation(for conversationId: String, msgId: Int64, trans: String) {
        var list = loadMessages(for: conversationId)
        guard let idx = list.firstIndex(where: { $0.msgId == msgId }) else { return }
        list[idx].trans = trans
        list[idx].transFail = false
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: "zy-chat-\(conversationId)")
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

// MARK: - 云函数接口（第 8 步：好友连接 + 真消息收发）
//
// 云函数地址：https://zhong-yue-offline.jameswilson199079.workers.dev
// 所有接口都带请求头 Authorization: Bearer <Supabase 登录令牌>。
// 没令牌或网络错返回 nil（调用方静默失败，不崩、不狂刷）。
// 返回值用 Codable 结构体解析（不用 [String: Any]，Swift 6 严格并发下更稳）。
// 请求体先在调用方编成 Data 再传进来，[String: Any] 本身不跨并发边界。

enum WorkerAPI {
    static let base = URL(string: "https://zhong-yue-offline.jameswilson199079.workers.dev")!

    /// 把请求体字典编成 JSON Data（同步编，调用方现编现传）。
    static func jsonBody(_ dict: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: dict)
    }

    /// 通用请求。返回 nil = 没令牌 / 网络错；否则返回 HTTP 状态码 + 解析出的数据
    /// （解析失败时 value 为 nil，调用方按状态码和 ok 字段判断）。
    static func request<T: Decodable & Sendable>(
        path: String, method: String, token: String?,
        body: Data? = nil, as type: T.Type
    ) async -> (status: Int, value: T?)? {
        guard let token, !token.isEmpty else { return nil }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let value = try? JSONDecoder().decode(T.self, from: data)
            return (status, value)
        } catch {
            return nil
        }
    }
}

/// 通用返回：{ok, error?}（/friend-accept、/friend-reject、/friend-remove、/ack）。
struct WorkerOK: Decodable, Sendable {
    let ok: Bool?
    let error: String?
}

/// POST /friend-add 返回：{ok, status: friends|requested|already_friends, error?}。
struct FriendAddResponse: Decodable, Sendable {
    let ok: Bool?
    let status: String?
    let error: String?
}

/// GET /friends 返回：{ok, friends: [{friend_num, created_at}]}。
struct FriendsListResponse: Decodable, Sendable {
    let ok: Bool?
    let friends: [ServerFriend]?
}

struct ServerFriend: Decodable, Sendable {
    let friend_num: String
    let created_at: Int?
}

/// GET /friend-requests 返回：{ok, requests: [{from_num, created_at}]}。
struct FriendRequestsResponse: Decodable, Sendable {
    let ok: Bool?
    let requests: [ServerFriendRequest]?
}

struct ServerFriendRequest: Decodable, Sendable {
    let from_num: String
    let created_at: Int?
}

/// POST /send 返回：{ok, stored}。
struct SendResponse: Decodable, Sendable {
    let ok: Bool?
    let stored: Int?
    let error: String?
}

/// GET /inbox 返回：{ok, messages: [...]}。
struct InboxResponse: Decodable, Sendable {
    let ok: Bool?
    let messages: [ServerInboxMessage]?
}

struct ServerInboxMessage: Decodable, Sendable {
    let id: Int?
    let from_num: String?
    let orig: String?
    let trans: String?
    let from_lang: String?
    let ts: Int?
    let name: String?
    let sess: String?
    let msg_id: Int?
}

/// 待处理的好友请求（本机模型，时间是 Date）。
struct FriendRequest: Identifiable, Equatable {
    var id: String { fromNum }
    var fromNum: String
    var createdAt: Date
}

/// POST /friend-add 的三种成功结果。
enum FriendAddStatus {
    case friends        // 对方之前已加过我，现在直接互为好友
    case requested      // 请求已发出，等对方接受
    case alreadyFriends // 已经是好友
}

/// 加好友的结果：成功（带状态）或失败（带中文原因）。
enum FriendAddOutcome {
    case added(FriendAddStatus)
    case failed(String)
}

/// 从服务器收到的消息（/inbox 的一条），按 from_num 分到对应会话。
struct IncomingMessage {
    var rowId: Int
    var fromNum: String
    var orig: String
    var trans: String
    var fromLang: ChatLanguage
    var ts: Date
    var name: String
    var sess: String
    var msgId: Int64
}

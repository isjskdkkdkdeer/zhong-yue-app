import Foundation
import AVFoundation

// MARK: - 语言

/// 只支持中 / 越两种语言，和网页版一致。
enum ChatLanguage: String, Codable {
    case zh
    case vi

    var other: ChatLanguage { self == .zh ? .vi : .zh }

    /// 翻译服务器（Gemini）要的语言码。
    var serverCode: String { self == .zh ? "zh-CN" : "vi" }
    /// 云函数 /translate 要的语言码（网页版直接传 zh / vi）。
    var workerCode: String { rawValue }
    /// Google 免费翻译接口要的语言码。
    var googleCode: String { self == .zh ? "zh-CN" : "vi" }
    /// Google 云端语音（TTS）要的语言码。
    var ttsCode: String { self == .zh ? "zh-CN" : "vi-VN" }
    /// 系统语音（AVSpeechSynthesizer 兜底）要的语言标识。
    var speechLocale: String { self == .zh ? "zh-CN" : "vi-VN" }
    var displayName: String { self == .zh ? "中文" : "Tiếng Việt" }
}

/// 网页版 detectLang：含汉字就是中文，否则按越南语算。
func detectLanguage(_ text: String) -> ChatLanguage {
    for scalar in text.unicodeScalars {
        if (0x4E00...0x9FFF).contains(scalar.value) { return .zh }
    }
    return .vi
}

/// “我说的语言”：存在本机 UserDefaults（key 和网页版、我的页共用）。
/// 读不到默认中文；聊天方向、助手回答语言、识别语言都跟它走。
enum AppLanguage {
    static var speakLang: ChatLanguage {
        let saved = UserDefaults.standard.string(forKey: "zy-speak-lang")
        return saved == "vi" ? .vi : .zh
    }
}

// MARK: - 翻译链（照网页版 translateText）
//
// 链路：翻译服务器 Gemini（5 秒）→ 云函数 /translate（m2m100，8 秒）
//      → Google 免费翻译接口（4 秒）→ MyMemory（4 秒）。
// 60 秒内失败过的接口先跳过；整条链最多等 12 秒。
// 网页版 POST /translate 时不强制带 Supabase token（/translate 是公开接口），
// 这里也直接发，不带 Authorization。

actor TranslationService {
    static let shared = TranslationService()

    private let serverURL = URL(string: "https://zhong-yue-fanyi-api.vercel.app/api/translate")!
    private let workerBase = URL(string: "https://zhong-yue-offline.jameswilson199079.workers.dev")!
    private var badUntil: [String: Date] = [:]

    private func isBad(_ name: String) -> Bool {
        (badUntil[name] ?? .distantPast) > Date()
    }

    private func markBad(_ name: String) {
        badUntil[name] = Date().addingTimeInterval(60)
    }

    /// 网页版 badTranslation：空、报错字样、和原文一样（长度 > 3）都算坏翻译。
    private func isBadTranslation(_ out: String, src: String) -> Bool {
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return true }
        let lower = s.lowercased()
        if lower.contains("mymemory warning") || lower.contains("query length limit")
            || lower.contains("no query specified")
            || lower.contains("invalid email") || lower.contains("invalid target")
            || lower.contains("invalid source") { return true }
        if s.lowercased() == src.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            && s.count > 3 { return true }
        return false
    }

    private func postJSON(_ url: URL, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.badResponse
        }
        return json
    }

    private func getJSON(_ url: URL, timeout: TimeInterval) async throws -> Any {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func viaServer(text: String, from: ChatLanguage, to: ChatLanguage) async throws -> String {
        let json = try await postJSON(
            serverURL,
            body: ["text": text, "from": from.serverCode, "to": to.serverCode],
            timeout: 5
        )
        guard let out = (json["translation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !isBadTranslation(out, src: text) else { throw TranslationError.badResponse }
        return out
    }

    private func viaWorker(text: String, from: ChatLanguage, to: ChatLanguage) async throws -> String {
        let json = try await postJSON(
            workerBase.appendingPathComponent("translate"),
            body: ["text": text, "from": from.workerCode, "to": to.workerCode],
            timeout: 8
        )
        guard let out = (json["translation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !isBadTranslation(out, src: text) else { throw TranslationError.badResponse }
        return out
    }

    private func viaGoogle(text: String, from: ChatLanguage, to: ChatLanguage) async throws -> String {
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: from.googleCode),
            URLQueryItem(name: "tl", value: to.googleCode),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        let json = try await getJSON(comps.url!, timeout: 4)
        var out = ""
        if let arr = json as? [Any], let first = arr.first as? [Any] {
            for item in first {
                if let pair = item as? [Any], let piece = pair.first as? String {
                    out += piece
                }
            }
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if isBadTranslation(trimmed, src: text) { throw TranslationError.badResponse }
        return trimmed
    }

    private func viaMyMemory(text: String, from: ChatLanguage, to: ChatLanguage) async throws -> String {
        var comps = URLComponents(string: "https://api.mymemory.translated.net/get")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "\(from.serverCode)|\(to.serverCode)"),
        ]
        let json = try await getJSON(comps.url!, timeout: 4)
        guard let dict = json as? [String: Any],
              let data = dict["responseData"] as? [String: Any],
              let out = (data["translatedText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !isBadTranslation(out, src: text) else { throw TranslationError.badResponse }
        return out
    }

    /// 整条翻译链（12 秒总超时）。失败抛错，调用方按失败处理，不编造译文。
    func translate(text: String, from: ChatLanguage, to: ChatLanguage) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let steps: [(String, () async throws -> String)] = [
                    ("server", { try await self.viaServer(text: text, from: from, to: to) }),
                    ("worker", { try await self.viaWorker(text: text, from: from, to: to) }),
                    ("google", { try await self.viaGoogle(text: text, from: from, to: to) }),
                    ("mymemory", { try await self.viaMyMemory(text: text, from: from, to: to) }),
                ]
                var lastError: Error = TranslationError.allFailed
                for (name, fn) in steps {
                    if await self.isBad(name) { continue }
                    do {
                        return try await fn()
                    } catch {
                        await self.markBad(name)
                        lastError = error
                    }
                }
                throw lastError
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 12_000_000_000)
                throw TranslationError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

enum TranslationError: Error {
    case badResponse
    case timeout
    case allFailed
}

// MARK: - 云端语音（照网页版 speakCloud）
//
// 文字按 ≤150 字分段，逐段请求 Google 云端语音
// translate.google.com/translate_tts（中文 tl=zh-CN，越南话 tl=vi-VN），
// 下载 mp3 用 AVAudioPlayer 播；第一段播不了就退回系统语音。

@MainActor
final class CloudSpeaker: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = CloudSpeaker()

    @Published private(set) var isSpeaking = false

    private var player: AVAudioPlayer?
    private var synthesizer = AVSpeechSynthesizer()
    private var sequence = 0
    private var currentTask: Task<Void, Never>?

    /// 网页版 cloudTtsChunks：按句号切，超长按逗号切，再按 150 字拼。
    static func chunks(of text: String) -> [String] {
        let s = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }
        let sentencePattern = "[^。！？；.!?;]+[。！？；.!?;]*"
        let sentences = matches(pattern: sentencePattern, in: s)
        var chunks: [String] = []
        var cur = ""
        for sn in sentences {
            var pieces = [sn]
            if sn.count > 150 {
                let commaPieces = matches(pattern: "[^，,、]+[，,、]*", in: sn)
                var hard: [String] = []
                for p in commaPieces {
                    var rest = p
                    while rest.count > 150 {
                        hard.append(String(rest.prefix(150)))
                        rest = String(rest.dropFirst(150))
                    }
                    if !rest.isEmpty { hard.append(rest) }
                }
                pieces = hard.isEmpty ? [sn] : hard
            }
            for piece in pieces {
                if (cur + piece).count > 150 && !cur.isEmpty {
                    chunks.append(cur)
                    cur = ""
                }
                cur += piece
                if cur.count >= 150 {
                    chunks.append(cur)
                    cur = ""
                }
            }
        }
        if !cur.isEmpty { chunks.append(cur) }
        return chunks
    }

    private static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let range = NSRange(text.startIndex..., in: text)
        let found = regex.matches(in: text, range: range).compactMap { m -> String? in
            guard let r = Range(m.range, in: text) else { return nil }
            return String(text[r])
        }
        return found.isEmpty ? [text] : found
    }

    func speak(_ text: String, lang: ChatLanguage) {
        stop()
        let parts = Self.chunks(of: text)
        guard !parts.isEmpty else { return }
        sequence += 1
        let seq = sequence
        isSpeaking = true
        currentTask = Task { @MainActor in
            var firstFailed = false
            for (idx, part) in parts.enumerated() {
                if seq != self.sequence { return }
                let ok = await self.playOne(part: part, lang: lang, seq: seq)
                if !ok {
                    if idx == 0 && !firstFailed {
                        firstFailed = true
                        self.speakWithSystemVoice(text, lang: lang)
                    }
                    break
                }
            }
            if seq == self.sequence { self.isSpeaking = false }
        }
    }

    func stop() {
        sequence += 1
        currentTask?.cancel()
        currentTask = nil
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func playOne(part: String, lang: ChatLanguage, seq: Int) async -> Bool {
        var comps = URLComponents(string: "https://translate.google.com/translate_tts")!
        comps.queryItems = [
            URLQueryItem(name: "ie", value: "UTF-8"),
            URLQueryItem(name: "tl", value: lang.ttsCode),
            URLQueryItem(name: "client", value: "tw-ob"),
            URLQueryItem(name: "q", value: part),
        ]
        guard let url = comps.url else { return false }
        do {
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: req)
            guard seq == sequence,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count > 100 else { return false }
            return await withCheckedContinuation { continuation in
                do {
                    let audioPlayer = try AVAudioPlayer(data: data)
                    audioPlayer.delegate = self
                    audioPlayer.prepareToPlay()
                    self.player = audioPlayer
                    self.playContinuation = continuation
                    if !audioPlayer.play() {
                        self.player = nil
                        self.playContinuation = nil
                        continuation.resume(returning: false)
                    }
                } catch {
                    continuation.resume(returning: false)
                }
            }
        } catch {
            return false
        }
    }

    private var playContinuation: CheckedContinuation<Bool, Never>?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player {
                self.player = nil
                self.playContinuation?.resume(returning: flag)
                self.playContinuation = nil
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            if self.player === player {
                self.player = nil
                self.playContinuation?.resume(returning: false)
                self.playContinuation = nil
            }
        }
    }

    private func speakWithSystemVoice(_ text: String, lang: ChatLanguage) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: lang.speechLocale)
        synthesizer.speak(utterance)
    }
}

import SwiftUI
import CoreImage
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 当前头像（相册自选的照片优先，没有就用预设头像）

/// 圆形头像：有相册自选照片就显示照片，没有就显示预设资源图。
struct UserAvatarImage: View {
    @EnvironmentObject var auth: AuthViewModel
    var size: CGFloat

    var body: some View {
        Group {
            if let photo = auth.customAvatarImage {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(auth.avatarAssetName)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

import AVFoundation

// MARK: - 二维码（共用：推荐好友页和“我的二维码”页都用它）

/// 生成二维码图片（CIQRCodeGenerator）。
func makeQRImage(for string: String) -> UIImage? {
    guard let data = string.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
}

/// 推荐好友 / 我的二维码编码的内容：带好友号的邀请链接，扫一扫能直接解析出好友号。
/// 好友号没设置好就只编网址。
func appInviteURL(for friendNumber: String) -> String {
    let num = friendNumber.trimmingCharacters(in: .whitespaces)
    if num.count == 6 && num.allSatisfy({ $0.isNumber }) {
        return "https://zyty.cc.cd/?add=\(num)"
    }
    return "https://zyty.cc.cd"
}

/// 手机号打码：留前 3 位 + **** + 后 2 位（比如 +84****99）。
func maskedPhone(_ phone: String) -> String {
    let kept = phone.filter { $0.isNumber || $0 == "+" }
    guard kept.count >= 7 else { return phone }
    return String(kept.prefix(3)) + "****" + String(kept.suffix(2))
}

// MARK: - 来电铃声（7 种，照网页版第 27 轮试听页；木琴是默认选中的）

/// 铃声音符：同时响的频率组、可滑音的终点频率、时长、音后停顿、衰减系数。
struct RingtoneNote {
    var freqs: [Double]
    var endFreqs: [Double]?
    var duration: Double
    var gap: Double
    var decay: Double
}

enum Ringtone: String, CaseIterable, Identifiable {
    case doorbell = "叮咚门铃"
    case classic = "经典电话铃"
    case musicBox = "八音盒"
    case xylophone = "木琴音阶"
    case doubleChime = "柔和双响"
    case waterDrop = "水滴声"
    case bouncy = "轻快跳音"

    var id: String { rawValue }
    static let defaultTone = Ringtone.xylophone

    /// 整段音调播完要多久（试听完自动返回用）。
    var totalDuration: Double {
        notes.reduce(0) { $0 + $1.duration + $1.gap }
    }

    var notes: [RingtoneNote] {
        switch self {
        case .doorbell:
            // 叮—咚：880Hz 落到 659Hz。
            return [
                RingtoneNote(freqs: [880], duration: 0.45, gap: 0.08, decay: 6),
                RingtoneNote(freqs: [659], duration: 0.6, gap: 0, decay: 6),
            ]
        case .classic:
            // 老式电话铃：941 + 1209Hz 双音频，急促交替。
            return (0..<4).flatMap { _ in
                [
                    RingtoneNote(freqs: [1209, 941], duration: 0.12, gap: 0.05, decay: 2),
                    RingtoneNote(freqs: [1209, 941], duration: 0.12, gap: 0.18, decay: 2),
                ]
            }
        case .musicBox:
            // 八音盒：高音琶音，衰减柔和。
            return [1046, 1318, 1568, 2093].map {
                RingtoneNote(freqs: [Double($0)], duration: 0.5, gap: 0.12, decay: 3)
            }
        case .xylophone:
            // 木琴音阶：C 大调五声音阶上行 523→1046Hz（和网页版一致），每个音短促衰减。
            return [523, 587, 659, 784, 880, 1046].enumerated().map { idx, f in
                RingtoneNote(freqs: [Double(f)], duration: idx == 5 ? 0.5 : 0.28, gap: idx == 5 ? 0 : 0.08, decay: 10)
            }
        case .doubleChime:
            // 柔和双响：660Hz 轻敲，再 880Hz 轻敲。
            return [
                RingtoneNote(freqs: [660], duration: 0.7, gap: 0.25, decay: 4),
                RingtoneNote(freqs: [880], duration: 0.9, gap: 0, decay: 4),
            ]
        case .waterDrop:
            // 水滴声：高音快速滑落，两滴。
            return [
                RingtoneNote(freqs: [1200], endFreqs: [500], duration: 0.35, gap: 0.15, decay: 14),
                RingtoneNote(freqs: [1000], endFreqs: [450], duration: 0.4, gap: 0, decay: 14),
            ]
        case .bouncy:
            // 轻快跳音：短促上跳的四个音。
            return [784, 988, 1046, 784].map {
                RingtoneNote(freqs: [Double($0)], duration: 0.16, gap: 0.1, decay: 12)
            }
        }
    }
}

/// 内置免费歌曲（Kevin MacLeod，CC-BY 3.0 协议，incompetech.com）。
/// 以 Data 资产形式放进工程，每首剪成 30 秒（铃声只响 30 秒）。
struct BuiltinSong: Identifiable {
    let assetName: String  // Data 资产名
    let title: String
    let artist: String
    var id: String { "builtin:\(assetName)" }
}

let builtinSongs: [BuiltinSong] = [
    BuiltinSong(assetName: "Carefree", title: "Carefree", artist: "Kevin MacLeod"),
    BuiltinSong(assetName: "EasyLemon", title: "Easy Lemon", artist: "Kevin MacLeod"),
    BuiltinSong(assetName: "BossaAntigua", title: "Bossa Antigua", artist: "Kevin MacLeod"),
]

/// 用户自己从文件里选的歌：文件存在 Documents/zy-ringtone-songs/，列表存在 UserDefaults。
struct UserSong: Codable, Identifiable {
    let id: String        // UUID
    let fileName: String  // 存在 Documents 里的文件名（id + 后缀）
    let displayName: String  // 原文件名（去掉后缀），列表里显示
}

enum UserSongStore {
    static let listKey = "zy-ringtone-songs"

    static func songsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("zy-ringtone-songs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load() -> [UserSong] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let list = try? JSONDecoder().decode([UserSong].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [UserSong]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: listKey)
        }
    }

    /// 加一首歌：把源文件拷进 Documents，返回新建的 UserSong；不支持的格式返回 nil。
    static func add(sourceURL: URL) -> UserSong? {
        let ext = sourceURL.pathExtension.lowercased()
        guard ["mp3", "m4a", "wav", "aac", "aif", "aiff", "caf"].contains(ext) else { return nil }
        let id = UUID().uuidString
        let fileName = id + "." + ext
        let dest = songsDirectory().appendingPathComponent(fileName)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            return nil
        }
        let displayName = sourceURL.deletingPathExtension().lastPathComponent
        var list = load()
        let song = UserSong(id: id, fileName: fileName, displayName: displayName)
        list.append(song)
        save(list)
        return song
    }

    static func remove(_ song: UserSong) {
        try? FileManager.default.removeItem(at: songsDirectory().appendingPathComponent(song.fileName))
        save(load().filter { $0.id != song.id })
    }

    static func fileURL(for song: UserSong) -> URL {
        songsDirectory().appendingPathComponent(song.fileName)
    }
}

/// 铃声选择值（UserDefaults 的 zy-ringtone 键）的显示名：
/// 音调直接是名字；歌曲要解析出来显示歌名。
enum RingtoneSelection {
    static func displayName(for stored: String) -> String {
        if Ringtone(rawValue: stored) != nil { return stored }
        if stored.hasPrefix("builtin:") {
            let asset = String(stored.dropFirst("builtin:".count))
            return builtinSongs.first { $0.assetName == asset }?.title ?? stored
        }
        if stored.hasPrefix("user:") {
            let id = String(stored.dropFirst("user:".count))
            return UserSongStore.load().first { $0.id == id }?.displayName ?? "我的歌曲"
        }
        return stored
    }
}

/// 铃声试听播放器：把音符合成一段 PCM，用 AVAudioPlayerNode 播一次。
/// 不用录音文件，全部现算。
final class RingtonePlayer: ObservableObject {
    /// 共用一个播放器：试听完页面自动返回后，声音还能继续响完。
    static let shared = RingtonePlayer()

    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var audioPlayer: AVAudioPlayer?

    func play(_ tone: Ringtone) {
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 播放会话设不上就照常试播。
        }
        let sampleRate = 44100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        var samples: [Float] = []
        for note in tone.notes {
            var phases = [Double](repeating: 0, count: note.freqs.count)
            let count = Int(note.duration * sampleRate)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let frac = note.duration > 0 ? t / note.duration : 0
                var value = 0.0
                for (j, f0) in note.freqs.enumerated() {
                    let f1 = note.endFreqs?[j] ?? f0
                    let freq = f0 + (f1 - f0) * frac
                    phases[j] += 2 * .pi * freq / sampleRate
                    value += sin(phases[j]) / Double(note.freqs.count)
                }
                let envelope = exp(-note.decay * t)
                samples.append(Float(value * envelope * 0.5))
            }
            samples.append(contentsOf: [Float](repeating: 0, count: Int(note.gap * sampleRate)))
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData?[0].assign(from: samples, count: samples.count)
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            return
        }
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        node.play()
        self.engine = engine
        self.node = node
    }

    /// 播一首歌（内置歌传 Data，用户选的歌传文件 URL）。
    func playSong(data: Data) {
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 播放会话设不上就照常试播。
        }
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.prepareToPlay()
        player.play()
        audioPlayer = player
    }

    func playSong(url: URL) {
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // 播放会话设不上就照常试播。
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.prepareToPlay()
        player.play()
        audioPlayer = player
    }

    func stop() {
        node?.stop()
        engine?.stop()
        audioPlayer?.stop()
        node = nil
        engine = nil
        audioPlayer = nil
    }
}

// MARK: - 个人资料（微信式：白底整行 + 灰色值 + ›，分组之间浅灰带隔开）
// 功能和第二步的编辑器、第三步的头像/封面自选一致，只按微信截图重排版，
// 每行点开都是一个带标题和返回的子页。

/// 个人资料页内的子页（走同一层 NavigationStack，返回箭头由系统给）。
enum ProfileSubPage: Hashable {
    case avatar
    case nickname
    case gender
    case region
    case phone
    case friendNumber
    case qrCode
    case nudge
    case signature
    case ringtone
    case email
    case password
    case cover
}

struct ProfileDetailView: View {
    @EnvironmentObject var auth: AuthViewModel
    @AppStorage("zy-ringtone") private var ringtone = Ringtone.defaultTone.rawValue
    /// “我的”页 NavigationStack 的 path：行改成普通 Button，点按往这里加目标。
    @Binding var path: [MeDestination]

    private var nicknameValue: String {
        let nick = auth.metadataString("nickname")
        return nick.isEmpty ? auth.displayName : nick
    }

    private var regionValue: String? {
        let parts = [auth.regionCountry, auth.regionCity].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var phoneValue: String? {
        auth.phoneNumber.isEmpty ? nil : maskedPhone(auth.phoneNumber)
    }

    private var nudgeValue: String? {
        auth.nudgeText.isEmpty ? nil : auth.nudgeText
    }

    private var signatureValue: String? {
        auth.signature.isEmpty ? nil : auth.signature
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // 第一组：头像 / 名字 / 性别 / 地区 / 手机号 / 好友号 / 二维码 / 拍一拍 / 签名
                sectionCard {
                    avatarRow
                    Divider()
                    profileRow(title: "名字", value: nicknameValue, page: .nickname)
                    Divider()
                    profileRow(title: "性别", value: auth.gender == "female" ? "女" : "男", page: .gender)
                    Divider()
                    profileRow(title: "地区", value: regionValue, isPlaceholder: regionValue == nil, page: .region)
                    Divider()
                    profileRow(title: "手机号", value: phoneValue, isPlaceholder: phoneValue == nil, page: .phone)
                    Divider()
                    profileRow(title: "好友号", value: auth.friendNumber, page: .friendNumber)
                    Divider()
                    qrRow
                    Divider()
                    profileRow(title: "拍一拍", value: nudgeValue, isPlaceholder: nudgeValue == nil, page: .nudge)
                    Divider()
                    profileRow(title: "签名", value: signatureValue, isPlaceholder: signatureValue == nil, page: .signature)
                }
                // 第二组：来电铃声
                sectionCard {
                    profileRow(title: "来电铃声", value: RingtoneSelection.displayName(for: ringtone), page: .ringtone)
                }
                // 第三组（账号）：邮箱 / 修改密码 / 封面背景
                sectionCard {
                    profileRow(title: "邮箱", value: auth.email, page: .email)
                    Divider()
                    profileRow(title: "修改密码", value: nil, page: .password)
                    Divider()
                    profileRow(title: "封面背景", value: auth.customCoverImage == nil ? "默认" : "已更换", page: .cover)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("个人资料")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    /// 子页映射（编程式导航用，目标在“我的”页的 NavigationStack 里注册）。
    @ViewBuilder
    static func subPageView(for page: ProfileSubPage) -> some View {
        switch page {
        case .avatar: AvatarEditorView()
        case .nickname: NicknameEditorView()
        case .gender: GenderEditorView()
        case .region: RegionEditorView()
        case .phone: PhoneEditorView()
        case .friendNumber: FriendNumberEditorView()
        case .qrCode: MyQRView()
        case .nudge: NudgeEditorView()
        case .signature: SignatureEditorView()
        case .ringtone: RingtonePickerView()
        case .email: EmailEditorView()
        case .password: PasswordEditorView()
        case .cover: CoverEditorView()
        }
    }

    // MARK: - 行

    /// 白底整行：左边黑色项目名，右边灰色值 + 灰色小箭头。
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color.white)
    }

    /// 点按修：第 4 步的 13 行用的是 NavigationLink，放在 ScrollView 里——
    /// 行中间的空白区域（Spacer 的位置）没有内容，SwiftUI 点按会透过行落到 ScrollView 上，
    /// 只有文字、值、箭头这些有内容的地方才有反应，所以用户要点到手机边上才能点开。
    /// 现在改成普通 Button + 编程式导航（和“我的”页、消息列表同款做法），
    /// 再加 .frame(maxWidth: .infinity) + .contentShape(Rectangle())，
    /// 让整行从左到右、中间空白处都能点开。
    private func profileRow(title: String, value: String?, isPlaceholder: Bool = false, page: ProfileSubPage) -> some View {
        Button {
            path.append(.profileSub(page))
        } label: {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                if let value {
                    Text(value)
                        .foregroundColor(isPlaceholder ? Color(.tertiaryLabel) : .secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    /// 头像行更高（约 72pt），右边是方形小头像缩略图 + 箭头。
    private var avatarRow: some View {
        Button {
            path.append(.profileSub(.avatar))
        } label: {
            HStack {
                Text("头像")
                    .foregroundColor(.primary)
                Spacer()
                Group {
                    if let photo = auth.customAvatarImage {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(auth.avatarAssetName)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    /// 我的二维码：右边一个二维码小图标 + 箭头。
    private var qrRow: some View {
        Button {
            path.append(.profileSub(.qrCode))
        } label: {
            HStack {
                Text("我的二维码")
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "qrcode")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 子页：头像（5 张预设全显示 + 从相册选，点一下立刻生效）

struct AvatarEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false

    /// 全部预设头像，男女都显示，不再按性别筛选。
    private var maleOptions: [String] { AuthViewModel.maleAvatars }
    private var femaleOptions: [String] { AuthViewModel.femaleAvatars }

    private func avatarButton(for name: String) -> some View {
        Button {
            auth.clearCustomAvatar()
            auth.avatarAssetName = name
            auth.saveLocalProfile()
            // 选完自动回资料页。
            dismiss()
        } label: {
            Image(name)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(
                        auth.customAvatarImage == nil && auth.avatarAssetName == name ? Color(red: 0, green: 0.48, blue: 1) : Color(.systemGray4),
                        lineWidth: auth.customAvatarImage == nil && auth.avatarAssetName == name ? 3 : 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    Group {
                        if let photo = auth.customAvatarImage {
                            Image(uiImage: photo)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(auth.avatarAssetName)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .frame(width: 88, height: 88)
                    .clipShape(Circle())
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            Section("男头像") {
                HStack(spacing: 16) {
                    ForEach(maleOptions, id: \.self) { name in
                        avatarButton(for: name)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Section("女头像") {
                HStack(spacing: 16) {
                    ForEach(femaleOptions, id: \.self) { name in
                        avatarButton(for: name)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Section {
                Button {
                    showPicker = true
                } label: {
                    Label("从相册选", systemImage: "photo")
                }
            } footer: {
                Text("从相册选的头像存在本机，换了性别也不会被覆盖；点预设头像可以换回来。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("头像")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $showPicker) {
            PhotoPicker { image in
                auth.setCustomAvatar(image)
                // 相册选完也自动回资料页（等相册弹层关掉再回）。
                Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - 子页：名字

struct NicknameEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("名字", text: $nickname)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } footer: {
                Text("改完“我的”页封面立刻显示新名字。")
            }
            saveStatusSection
        }
        .navigationTitle("名字")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .onAppear { nickname = auth.metadataString("nickname") }
    }

    @ViewBuilder
    private var saveStatusSection: some View {
        if isSaving {
            Section {
                HStack {
                    ProgressView()
                    Text("正在保存…")
                        .foregroundColor(.secondary)
                }
            }
        }
        if let errorMessage {
            Section {
                Text(errorMessage)
                    .foregroundColor(.red)
            }
        }
        if let infoMessage {
            Section {
                Text(infoMessage)
                    .foregroundColor(.green)
            }
        }
    }

    private func save() async {
        errorMessage = nil
        infoMessage = nil
        let nick = nickname.trimmingCharacters(in: .whitespaces)
        if nick.isEmpty {
            errorMessage = "名字不能为空"
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await auth.updateMetadata(["nickname": .string(nick)])
            // 保存成功自动回资料页。
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 子页：性别（点一下立刻生效）

struct GenderEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach([("male", "男"), ("female", "女")], id: \.0) { code, name in
                Button {
                    // 性别只管性别，不再自动换头像——头像只由用户在头像选择器里自己选。
                    auth.gender = code
                    auth.saveLocalProfile()
                    // 选完自动回资料页。
                    dismiss()
                } label: {
                    HStack {
                        Text(name)
                            .foregroundColor(.primary)
                        Spacer()
                        if auth.gender == code {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("性别")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

// MARK: - 子页：地区（国家选 + 城市手填，存账号资料）

struct RegionEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var country = ""
    @State private var city = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    private let countries = ["中国", "越南", "美国", "新加坡", "马来西亚", "泰国", "其他"]

    var body: some View {
        Form {
            Section {
                ForEach(countries, id: \.self) { name in
                    Button {
                        country = name
                    } label: {
                        HStack {
                            Text(name)
                                .foregroundColor(.primary)
                            Spacer()
                            if country == name {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            } header: {
                Text("国家")
            }
            Section {
                TextField("城市", text: $city)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } header: {
                Text("城市")
            } footer: {
                Text("地区存在账号资料里，换手机登录也还在。")
            }
            saveStatusSection
        }
        .navigationTitle("地区")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .onAppear {
            country = auth.regionCountry
            city = auth.regionCity
        }
    }

    @ViewBuilder
    private var saveStatusSection: some View {
        if isSaving {
            Section {
                HStack {
                    ProgressView()
                    Text("正在保存…")
                        .foregroundColor(.secondary)
                }
            }
        }
        if let errorMessage {
            Section {
                Text(errorMessage)
                    .foregroundColor(.red)
            }
        }
        if let infoMessage {
            Section {
                Text(infoMessage)
                    .foregroundColor(.green)
            }
        }
    }

    private func save() async {
        errorMessage = nil
        infoMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await auth.updateMetadata([
                "region_country": .string(country.trimmingCharacters(in: .whitespaces)),
                "region_city": .string(city.trimmingCharacters(in: .whitespaces)),
            ])
            // 保存成功自动回资料页。
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 子页：手机号（可选填，显示时中间打码）

struct PhoneEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("手机号", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } footer: {
                Text("仅用于展示，不做验证；列表里中间会打码，比如 +84****99。留空就是不填。")
            }
            saveStatusSection
        }
        .navigationTitle("手机号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .onAppear { phone = auth.phoneNumber }
    }

    @ViewBuilder
    private var saveStatusSection: some View {
        if isSaving {
            Section {
                HStack {
                    ProgressView()
                    Text("正在保存…")
                        .foregroundColor(.secondary)
                }
            }
        }
        if let errorMessage {
            Section {
                Text(errorMessage)
                    .foregroundColor(.red)
            }
        }
        if let infoMessage {
            Section {
                Text(infoMessage)
                    .foregroundColor(.green)
            }
        }
    }

    private func save() async {
        errorMessage = nil
        infoMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await auth.updateMetadata(["phone": .string(phone.trimmingCharacters(in: .whitespaces))])
            // 保存成功自动回资料页。
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 子页：好友号（6 位数字，改了要提醒旧号加的好友要重加）

struct FriendNumberEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var friendNumber = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("好友号", text: $friendNumber)
                    .keyboardType(.numberPad)
                    .onChange(of: friendNumber) { _, newValue in
                        let filtered = newValue.filter { $0.isNumber }
                        friendNumber = String(filtered.prefix(6))
                    }
            } footer: {
                Text("改了好友号，别人用旧号就找不到你了，要重新加好友。")
            }
            saveStatusSection
        }
        .navigationTitle("好友号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .onAppear {
            let num = auth.friendNumber
            friendNumber = num == "—" ? "" : num
        }
    }

    @ViewBuilder
    private var saveStatusSection: some View {
        if isSaving {
            Section {
                HStack {
                    ProgressView()
                    Text("正在保存…")
                        .foregroundColor(.secondary)
                }
            }
        }
        if let errorMessage {
            Section {
                Text(errorMessage)
                    .foregroundColor(.red)
            }
        }
        if let infoMessage {
            Section {
                Text(infoMessage)
                    .foregroundColor(.green)
            }
        }
    }

    private func save() async {
        errorMessage = nil
        infoMessage = nil
        let num = friendNumber.filter { $0.isNumber }
        if num.count != 6 || !num.allSatisfy({ $0.isNumber }) {
            errorMessage = "好友号必须是 6 位数字"
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await auth.updateMetadata(["num": .string(num)])
            // 保存成功自动回资料页（改号的提醒在编辑页底部已经写了）。
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 子页：我的二维码（App 网址 + 好友号）

struct MyQRView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 24) {
            if let qr = makeQRImage(for: appInviteURL(for: auth.friendNumber)) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding()
                    .background(Color.white)
                    .cornerRadius(16)
            }
            Text("扫码打开中越通译")
                .font(.headline)
            HStack(spacing: 8) {
                Text("我的好友号：\(auth.friendNumber)")
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = auth.friendNumber
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline)
            Spacer()
        }
        .padding(.top, 40)
        .navigationTitle("我的二维码")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - 子页：拍一拍（后缀文字，存本机）

struct NudgeEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var suffix = ""
    @State private var infoMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("拍一拍后缀", text: $suffix)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } footer: {
                Text("比如填“的肩膀”，以后别人拍你，聊天里显示“\(auth.displayName)拍了拍你的肩膀”。留空就是不设置。")
            }
            if let infoMessage {
                Section {
                    Text(infoMessage)
                        .foregroundColor(.green)
                }
            }
        }
        .navigationTitle("拍一拍")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    auth.setNudgeText(suffix.trimmingCharacters(in: .whitespaces))
                    // 保存成功自动回资料页。
                    dismiss()
                }
            }
        }
        .onAppear { suffix = auth.nudgeText }
    }
}

// MARK: - 子页：签名（一句话，存账号资料）

struct SignatureEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var signature = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("签名", text: $signature, axis: .vertical)
                    .lineLimit(3)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } footer: {
                Text("一句话介绍自己，没填显示“未填写”。")
            }
            saveStatusSection
        }
        .navigationTitle("签名")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .onAppear { signature = auth.signature }
    }

    @ViewBuilder
    private var saveStatusSection: some View {
        if isSaving {
            Section {
                HStack {
                    ProgressView()
                    Text("正在保存…")
                        .foregroundColor(.secondary)
                }
            }
        }
        if let errorMessage {
            Section {
                Text(errorMessage)
                    .foregroundColor(.red)
            }
        }
        if let infoMessage {
            Section {
                Text(infoMessage)
                    .foregroundColor(.green)
            }
        }
    }

    private func save() async {
        errorMessage = nil
        infoMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await auth.updateMetadata(["signature": .string(signature.trimmingCharacters(in: .whitespaces))])
            // 保存成功自动回资料页。
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 子页：来电铃声（7 个音调 + 3 首内置歌 + 自己从文件里选的歌；点一下试听，听完自动回资料页）

struct RingtonePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("zy-ringtone") private var selected = Ringtone.defaultTone.rawValue
    @State private var userSongs: [UserSong] = UserSongStore.load()
    @State private var showDocPicker = false
    @State private var docPickerError: String?
    @State private var dismissTask: Task<Void, Never>?

    private var player: RingtonePlayer { RingtonePlayer.shared }

    var body: some View {
        List {
            Section("音调") {
                ForEach(Ringtone.allCases) { tone in
                    ringtoneRow(title: tone.rawValue, isSelected: selected == tone.rawValue) {
                        selected = tone.rawValue
                        player.play(tone)
                        // 试听完自动回资料页（音调播完 + 留 0.4 秒）。
                        scheduleDismiss(after: tone.totalDuration + 0.4)
                    }
                }
            }
            Section("歌曲") {
                ForEach(builtinSongs) { song in
                    ringtoneRow(title: "\(song.title) · \(song.artist)", isSelected: selected == song.id) {
                        selected = song.id
                        if let data = NSDataAsset(name: song.assetName)?.data {
                            player.playSong(data: data)
                        }
                        // 歌只听个开头，2 秒后自动回资料页，歌继续响完。
                        scheduleDismiss(after: 2.0)
                    }
                }
            }
            Section("我的歌曲") {
                ForEach(userSongs) { song in
                    ringtoneRow(title: song.displayName, isSelected: selected == "user:\(song.id)") {
                        selected = "user:\(song.id)"
                        player.playSong(url: UserSongStore.fileURL(for: song))
                        scheduleDismiss(after: 2.0)
                    }
                }
                .onDelete(perform: deleteUserSongs)
                Button {
                    showDocPicker = true
                } label: {
                    Label("从文件里选歌曲", systemImage: "folder")
                }
            } footer: {
                Text("从文件里选的歌只支持 mp3、m4a、wav，存在本机；左滑可以删。选中的歌以后来电就响它。")
            }
            if let docPickerError {
                Section {
                    Text(docPickerError)
                        .foregroundColor(.red)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("来电铃声")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $showDocPicker) {
            AudioDocumentPicker { url in
                if UserSongStore.add(sourceURL: url) != nil {
                    userSongs = UserSongStore.load()
                    docPickerError = nil
                } else {
                    docPickerError = "这首歌加不进来，换个 mp3、m4a 或 wav 文件试试"
                }
            }
        }
        .onDisappear {
            dismissTask?.cancel()
        }
    }

    private func ringtoneRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
                }
            }
        }
    }

    /// 试听完自动回资料页；中途点了别的铃声就取消上一次的返回、重新计时。
    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func deleteUserSongs(at offsets: IndexSet) {
        for index in offsets {
            let song = userSongs[index]
            if selected == "user:\(song.id)" {
                // 删的是正在用的铃声，换回默认木琴。
                selected = Ringtone.defaultTone.rawValue
            }
            UserSongStore.remove(song)
        }
        userSongs = UserSongStore.load()
    }
}

/// 系统文件选择器：只让选音频文件（mp3、m4a、wav），以拷贝方式打开。
struct AudioDocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.mp3, UTType.mpeg4Audio, UTType.wav],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first {
                onPick(url)
            }
        }
    }
}

// MARK: - 子页：邮箱（改完要去新邮箱点确认链接才生效）

struct EmailEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("邮箱", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            } footer: {
                Text("改了邮箱要去新邮箱点确认，确认前仍用旧邮箱登录。")
            }
            saveStatusSection
        }
        .navigationTitle("邮箱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .onAppear { email = auth.email }
    }

    @ViewBuilder
    private var saveStatusSection: some View {
        if isSaving {
            Section {
                HStack {
                    ProgressView()
                    Text("正在保存…")
                        .foregroundColor(.secondary)
                }
            }
        }
        if let errorMessage {
            Section {
                Text(errorMessage)
                    .foregroundColor(.red)
            }
        }
        if let infoMessage {
            Section {
                Text(infoMessage)
                    .foregroundColor(.green)
            }
        }
    }

    private func isValidEmail(_ value: String) -> Bool {
        value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    private func save() async {
        errorMessage = nil
        infoMessage = nil
        let newEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
        if !isValidEmail(newEmail) {
            errorMessage = "邮箱格式不对"
            return
        }
        if newEmail == auth.email {
            // 没变也直接回资料页。
            dismiss()
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await auth.updateEmail(newEmail)
            // 保存成功自动回资料页（确认邮件已发到新邮箱，点开确认后才生效）。
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 子页：修改密码（≥6 位，两次一致，空着就是不改）

struct PasswordEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        Form {
            Section {
                SecureField("新密码", text: $newPassword)
                    .textContentType(.newPassword)
                SecureField("确认密码", text: $confirmPassword)
                    .textContentType(.newPassword)
            } footer: {
                Text("不改请留空；要改的话不少于 6 位，两次要一致。")
            }
            saveStatusSection
        }
        .navigationTitle("修改密码")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(isSaving)
            }
        }
    }

    @ViewBuilder
    private var saveStatusSection: some View {
        if isSaving {
            Section {
                HStack {
                    ProgressView()
                    Text("正在保存…")
                        .foregroundColor(.secondary)
                }
            }
        }
        if let errorMessage {
            Section {
                Text(errorMessage)
                    .foregroundColor(.red)
            }
        }
        if let infoMessage {
            Section {
                Text(infoMessage)
                    .foregroundColor(.green)
            }
        }
    }

    private func save() async {
        errorMessage = nil
        infoMessage = nil
        if newPassword.isEmpty && confirmPassword.isEmpty {
            // 没改也直接回资料页。
            dismiss()
            return
        }
        if newPassword.count < 6 {
            errorMessage = "新密码至少 6 位"
            return
        }
        if newPassword != confirmPassword {
            errorMessage = "两次输入的密码不一致"
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await auth.updatePassword(newPassword)
            // 保存成功自动回资料页。
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 子页：封面背景（预览 + 从相册选 + 恢复默认）

struct CoverEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Group {
                        if let cover = auth.customCoverImage {
                            Image(uiImage: cover)
                                .resizable()
                                .scaledToFill()
                        } else if let photo = auth.customAvatarImage {
                            Image(uiImage: photo)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(auth.avatarAssetName)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .frame(width: 72, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(auth.customCoverImage == nil ? "现在是默认背景" : "已用相册照片做背景")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                HStack(spacing: 12) {
                    Button {
                        showPicker = true
                    } label: {
                        Label("从相册选", systemImage: "photo")
                    }
                    .buttonStyle(.bordered)
                    if auth.customCoverImage != nil {
                        Button("恢复默认") {
                            auth.clearCustomCover()
                            // 恢复完自动回资料页。
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } footer: {
                Text("封面背景存在本机；没选过就用默认图。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("封面背景")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $showPicker) {
            PhotoPicker { image in
                auth.setCustomCover(image)
                // 相册选完也自动回资料页（等相册弹层关掉再回）。
                Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - 推荐好友（App 网址二维码 + 好友号）

struct ReferFriendView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 24) {
            if let qr = qrImage(for: appInviteURL(for: auth.friendNumber)) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding()
                    .background(Color.white)
                    .cornerRadius(16)
            }
            Text("扫码打开中越通译")
                .font(.headline)
            HStack(spacing: 8) {
                Text("我的好友号：\(auth.friendNumber)")
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = auth.friendNumber
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline)
            Spacer()
        }
        .padding(.top, 40)
        .navigationTitle("推荐好友")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func qrImage(for string: String) -> UIImage? {
        makeQRImage(for: string)
    }
}

// MARK: - 语言选择（只存本机）

struct LanguagePickerView: View {
    enum Kind { case ui, speak }

    let kind: Kind
    @AppStorage("zy-ui-lang") private var uiLang = "zh"
    @AppStorage("zy-speak-lang") private var speakLang = "zh"

    private var selection: Binding<String> {
        kind == .ui ? $uiLang : $speakLang
    }

    var body: some View {
        List {
            Section {
                ForEach([("zh", "中文"), ("vi", "Tiếng Việt")], id: \.0) { code, name in
                    Button {
                        selection.wrappedValue = code
                    } label: {
                        HStack {
                            Text(name)
                            Spacer()
                            if selection.wrappedValue == code {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                }
            } footer: {
                Text("语言设置保存在本机。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(kind == .ui ? "界面语言" : "我说的语言")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

// MARK: - 使用帮助

struct HelpView: View {
    private let steps: [(String, String, String)] = [
        ("1", "翻译助手", "不用加好友，直接和“翻译助手”聊天，中越互翻，还能发语音让它开口回答。"),
        ("2", "加好友", "输入对方 6 位好友号就能加好友，开始聊天和通话。"),
        ("3", "语音视频通话", "点好友头像打电话，通话里有实时翻译字幕。"),
        ("4", "离线消息与推送", "对方不在线也能发消息，对方上线后收到；来电有推送提醒。"),
    ]

    var body: some View {
        List {
            ForEach(steps, id: \.0) { number, title, body in
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0, green: 0.48, blue: 1))
                            .frame(width: 26, height: 26)
                        Text(number)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.headline)
                        Text(body)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("使用帮助")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

// MARK: - 隐私说明

struct PrivacyView: View {
    private let items: [(String, String)] = [
        ("文字翻译", "会发给翻译服务（Gemini / Cloudflare / Google / MyMemory），只发要翻译的那句话。"),
        ("通话字幕", "先用系统语音识别，识别不到就用云端识别（Cloudflare 语音识别）。"),
        ("翻译助手录音", "发给 Cloudflare 语音识别，识别成文字后再翻译、回答。"),
        ("朗读", "用 Google 云端语音。"),
        ("消息", "对方离线时存在 Cloudflare 服务器，对方上线后取走；聊天记录只存在你的手机上。"),
        ("推送", "苹果推送（APNs）尚未接入，关掉 App 后暂时收不到消息和来电提醒。"),
    ]

    var body: some View {
        List {
            ForEach(items, id: \.0) { title, body in
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(body)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("隐私说明")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

// MARK: - 朋友圈（本机版：动态 / 点赞 / 评论都存本机，照微信朋友圈的样子）
// 好友还没连通（网页版好友在浏览器本地存储里，原生读不到），所以这里只有自己的动态，
// 不编假好友的动态来凑数；朋友的动态要等好友同步那步才能有。

/// 一条评论。
struct MomentComment: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var authorName: String
    var text: String
    var ts: Date = Date()
}

/// 一条动态。photos 存的是本机 Documents 里的照片文件名。
struct MomentPost: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var authorName: String
    var text: String
    var photos: [String] = []
    var ts: Date = Date()
    var liked: Bool = false
    var comments: [MomentComment] = []
}

/// 朋友圈本机存储：UserDefaults 里按邮箱存 JSON（和聊天记录一个存法），照片存 Documents。
/// 动态最多留 200 条。
@MainActor
final class MomentsStore: ObservableObject {
    @Published private(set) var posts: [MomentPost] = []

    private let storageKey: String
    private let authorName: String

    init(email: String, authorName: String) {
        self.storageKey = "zy-moments-" + email
        self.authorName = authorName
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MomentPost].self, from: data)
        else { return }
        posts = decoded
    }

    private func save() {
        if posts.count > 200 { posts = Array(posts.prefix(200)) }
        if let data = try? JSONEncoder().encode(posts) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func photoFileURL(_ filename: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    private static func downscaledJPEG(_ image: UIImage, maxDimension: CGFloat) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }

    /// 发一条动态：文字 + 照片（最多 9 张），照片存本机。
    func addPost(text: String, images: [UIImage]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        let postId = UUID()
        var filenames: [String] = []
        for (idx, image) in images.prefix(9).enumerated() {
            let filename = "zy-moment-\(postId.uuidString)-\(idx).jpg"
            if let data = Self.downscaledJPEG(image, maxDimension: 1024) {
                try? data.write(to: photoFileURL(filename), options: .atomic)
                filenames.append(filename)
            }
        }
        let post = MomentPost(authorName: authorName, text: trimmed, photos: filenames)
        posts.insert(post, at: 0)
        save()
    }

    /// 删自己的动态，照片文件一起删。
    func deletePost(_ post: MomentPost) {
        for filename in post.photos {
            try? FileManager.default.removeItem(at: photoFileURL(filename))
        }
        posts.removeAll { $0.id == post.id }
        save()
    }

    /// 点赞 / 取消赞（本机版只有自己点）。
    func toggleLike(_ post: MomentPost) {
        guard let idx = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[idx].liked.toggle()
        save()
    }

    /// 加一条评论。
    func addComment(to post: MomentPost, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = posts.firstIndex(where: { $0.id == post.id }) else { return }
        posts[idx].comments.append(MomentComment(authorName: authorName, text: trimmed))
        save()
    }

    /// 读一张动态照片。
    func photoImage(_ filename: String) -> UIImage? {
        guard let data = try? Data(contentsOf: photoFileURL(filename)) else { return nil }
        return UIImage(data: data)
    }
}

/// 相对时间：刚刚 / N 分钟前 / N 小时前 / 昨天 / M月d日。
func momentRelativeTime(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 { return "刚刚" }
    if seconds < 3600 { return "\(seconds / 60) 分钟前" }
    if seconds < 86400 { return "\(seconds / 3600) 小时前" }
    if seconds < 172800 { return "昨天" }
    let formatter = DateFormatter()
    formatter.dateFormat = "M月d日"
    return formatter.string(from: date)
}

/// 系统相册多选（最多 limit 张）。
struct MultiPhotoPicker: UIViewControllerRepresentable {
    var limit: Int
    var onPick: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = max(limit, 1)
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([UIImage]) -> Void

        init(onPick: @escaping ([UIImage]) -> Void) {
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let providers = results.map(\.itemProvider).filter { $0.canLoadObject(ofClass: UIImage.self) }
            guard !providers.isEmpty else { return }
            var loaded: [UIImage] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    if let image = object as? UIImage {
                        loaded.append(image)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [onPick] in
                onPick(loaded)
            }
        }
    }
}

/// 朋友圈页面：顶部封面横幅（用“我的”页那张封面背景图）+ 右下角圆形头像 + 昵称，
/// 下面是动态列表。右上角相机按钮发动态。
struct MomentsView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var store: MomentsStore?
    @State private var showComposer = false
    @State private var commentingPostId: UUID?
    @State private var commentText = ""
    @FocusState private var commentFocused: Bool
    @State private var deletingPost: MomentPost?

    var body: some View {
        Group {
            if let store {
                momentsContent(store)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                    .onAppear {
                        store = MomentsStore(email: auth.email, authorName: auth.displayName)
                    }
            }
        }
        .navigationTitle("朋友圈")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showComposer = true
                } label: {
                    Image(systemName: "camera")
                }
            }
        }
        .sheet(isPresented: $showComposer) {
            if let store {
                MomentComposerView(store: store)
            }
        }
        .confirmationDialog("删除这条动态？", isPresented: Binding(
            get: { deletingPost != nil },
            set: { if !$0 { deletingPost = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let post = deletingPost {
                    store?.deletePost(post)
                }
                deletingPost = nil
            }
            Button("取消", role: .cancel) {
                deletingPost = nil
            }
        }
    }

    @ViewBuilder
    private func momentsContent(_ store: MomentsStore) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                coverHeader
                if store.posts.isEmpty {
                    Text("还没有动态，点右上角相机发一条")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                } else {
                    ForEach(store.posts) { post in
                        MomentRowView(
                            post: post,
                            store: store,
                            onComment: {
                                commentingPostId = post.id
                                commentFocused = true
                            },
                            onDelete: { deletingPost = post }
                        )
                        Divider()
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            if let postId = commentingPostId,
               let post = store.posts.first(where: { $0.id == postId }) {
                HStack(spacing: 8) {
                    TextField("评论", text: $commentText)
                        .focused($commentFocused)
                        .textFieldStyle(.roundedBorder)
                    Button("发送") {
                        store.addComment(to: post, text: commentText)
                        commentText = ""
                        commentingPostId = nil
                    }
                    .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("取消") {
                        commentingPostId = nil
                        commentText = ""
                    }
                    .foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color(.systemBackground))
            }
        }
        .onChange(of: commentingPostId) { _, newValue in
            if newValue != nil {
                commentFocused = true
            }
        }
    }

    /// 封面横幅：和“我的”页同一张背景图；头像压在右下角，昵称在头像左边。
    private var coverHeader: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let cover = auth.customCoverImage {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                } else if let photo = auth.customAvatarImage {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(auth.avatarAssetName)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipped()
            LinearGradient(
                colors: [.black.opacity(0.05), .black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
            HStack(alignment: .center, spacing: 10) {
                Text(auth.displayName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(radius: 2)
                    .padding(.bottom, 10)
                UserAvatarImage(size: 64)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .offset(y: 26)
            }
            .padding(.trailing, 16)
        }
        .frame(height: 220)
        .padding(.bottom, 26)
    }
}

/// 一条动态：头像、名字、时间、正文、照片九宫格、点赞和评论、赞/评论/删除按钮。
struct MomentRowView: View {
    let post: MomentPost
    let store: MomentsStore
    let onComment: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            UserAvatarImage(size: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(post.authorName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color(red: 0.34, green: 0.42, blue: 0.58))
                Text(momentRelativeTime(post.ts))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !post.text.isEmpty {
                    Text(post.text)
                        .font(.system(size: 16))
                }
                if !post.photos.isEmpty {
                    photoGrid
                }
                if post.liked || !post.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if post.liked {
                            HStack(spacing: 4) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                                Text("我")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(red: 0.34, green: 0.42, blue: 0.58))
                            }
                        }
                        ForEach(post.comments) { comment in
                            HStack(alignment: .top, spacing: 4) {
                                Text(comment.authorName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(red: 0.34, green: 0.42, blue: 0.58))
                                Text(comment.text)
                                    .font(.system(size: 14))
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .cornerRadius(6)
                }
                HStack(spacing: 16) {
                    Spacer()
                    Button {
                        store.toggleLike(post)
                    } label: {
                        Label(post.liked ? "已赞" : "赞", systemImage: post.liked ? "heart.fill" : "heart")
                            .font(.system(size: 14))
                    }
                    .foregroundColor(post.liked ? .red : .secondary)
                    Button(action: onComment) {
                        Label("评论", systemImage: "bubble.left")
                            .font(.system(size: 14))
                    }
                    .foregroundColor(.secondary)
                    Button(action: onDelete) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14))
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 照片九宫格（最多 9 张，三列）。
    private var photoGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 4),
            GridItem(.flexible(), spacing: 4),
            GridItem(.flexible(), spacing: 4),
        ]
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(post.photos, id: \.self) { filename in
                MomentPhotoImage(filename: filename, store: store)
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
            }
        }
    }
}

/// 动态里的一张照片（从本机 Documents 读）。
struct MomentPhotoImage: View {
    let filename: String
    let store: MomentsStore
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.systemGray5)
            }
        }
        .onAppear {
            image = store.photoImage(filename)
        }
    }
}

/// 发动态：写文字 + 从相册选照片（最多 9 张）。
struct MomentComposerView: View {
    @Environment(\.dismiss) private var dismiss
    let store: MomentsStore
    @State private var text = ""
    @State private var images: [UIImage] = []
    @State private var showPicker = false
    @State private var isPublishing = false

    private var canPublish: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    )
                if !images.isEmpty {
                    let columns = [
                        GridItem(.flexible(), spacing: 4),
                        GridItem(.flexible(), spacing: 4),
                        GridItem(.flexible(), spacing: 4),
                    ]
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(Array(images.enumerated()), id: \.offset) { idx, image in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipped()
                                Button {
                                    images.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black.opacity(0.5)))
                                }
                                .padding(4)
                            }
                        }
                    }
                }
                Button {
                    showPicker = true
                } label: {
                    Label(images.isEmpty ? "从相册选照片（最多 9 张）" : "再选照片（还能选 \(9 - images.count) 张）", systemImage: "photo")
                }
                .disabled(images.count >= 9)
                Spacer()
            }
            .padding()
            .navigationTitle("发动态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发表") {
                        isPublishing = true
                        store.addPost(text: text, images: images)
                        dismiss()
                    }
                    .disabled(!canPublish || isPublishing)
                }
            }
            .sheet(isPresented: $showPicker) {
                MultiPhotoPicker(limit: 9 - images.count) { picked in
                    images.append(contentsOf: picked)
                }
            }
        }
    }
}

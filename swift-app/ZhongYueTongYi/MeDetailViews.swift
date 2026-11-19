import SwiftUI
import CoreImage
import UIKit

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

/// 铃声试听播放器：把音符合成一段 PCM，用 AVAudioPlayerNode 播一次。
/// 不用录音文件，全部现算。
final class RingtonePlayer: ObservableObject {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?

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

    func stop() {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
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
                    profileRow(title: "来电铃声", value: ringtone, page: .ringtone)
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
        .navigationDestination(for: ProfileSubPage.self) { page in
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
    }

    // MARK: - 行

    /// 白底整行：左边黑色项目名，右边灰色值 + 灰色小箭头。
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color.white)
    }

    private func profileRow(title: String, value: String?, isPlaceholder: Bool = false, page: ProfileSubPage) -> some View {
        NavigationLink(value: page) {
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
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    /// 头像行更高（约 72pt），右边是方形小头像缩略图 + 箭头。
    private var avatarRow: some View {
        NavigationLink(value: ProfileSubPage.avatar) {
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
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    /// 我的二维码：右边一个二维码小图标 + 箭头。
    private var qrRow: some View {
        NavigationLink(value: ProfileSubPage.qrCode) {
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
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 子页：头像（4 张预设 + 从相册选，点一下立刻生效）

struct AvatarEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var showPicker = false

    private var avatarOptions: [String] {
        auth.gender == "female" ? AuthViewModel.femaleAvatars : AuthViewModel.maleAvatars
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
            Section {
                HStack(spacing: 16) {
                    ForEach(avatarOptions, id: \.self) { name in
                        Button {
                            auth.clearCustomAvatar()
                            auth.avatarAssetName = name
                            auth.saveLocalProfile()
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
                    Spacer()
                }
                .padding(.vertical, 4)
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
            }
        }
    }
}

// MARK: - 子页：名字

struct NicknameEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
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
            infoMessage = "已保存"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 子页：性别（点一下立刻生效）

struct GenderEditorView: View {
    @EnvironmentObject var auth: AuthViewModel

    var body: some View {
        List {
            ForEach([("male", "男"), ("female", "女")], id: \.0) { code, name in
                Button {
                    auth.gender = code
                    // 换性别只影响预设头像：自己从相册选的照片不换。
                    if auth.customAvatarImage == nil {
                        let options = code == "female" ? AuthViewModel.femaleAvatars : AuthViewModel.maleAvatars
                        if !options.contains(auth.avatarAssetName) {
                            auth.avatarAssetName = options[0]
                        }
                    }
                    auth.saveLocalProfile()
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
            infoMessage = "已保存"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 子页：手机号（可选填，显示时中间打码）

struct PhoneEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
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
            infoMessage = "已保存"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 子页：好友号（6 位数字，改了要提醒旧号加的好友要重加）

struct FriendNumberEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
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
            let oldNum = auth.friendNumber
            try await auth.updateMetadata(["num": .string(num)])
            infoMessage = num == oldNum ? "已保存" : "已保存。好友号已改，别人用旧号找不到你，需要重新加好友"
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
            if let qr = makeQRImage(for: "https://zyty.cc.cd") {
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
                    infoMessage = "已保存"
                }
            }
        }
        .onAppear { suffix = auth.nudgeText }
    }
}

// MARK: - 子页：签名（一句话，存账号资料）

struct SignatureEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
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
            infoMessage = "已保存"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 子页：来电铃声（点一下试听，选中存本机）

struct RingtonePickerView: View {
    @AppStorage("zy-ringtone") private var selected = Ringtone.defaultTone.rawValue
    @StateObject private var player = RingtonePlayer()

    var body: some View {
        List {
            Section {
                ForEach(Ringtone.allCases) { tone in
                    Button {
                        selected = tone.rawValue
                        player.play(tone)
                    } label: {
                        HStack {
                            Text(tone.rawValue)
                                .foregroundColor(.primary)
                            Spacer()
                            if selected == tone.rawValue {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            } footer: {
                Text("点一下试听，选中后保存到来电铃声设置里；通话功能接上后，来电就响这个铃声。")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("来电铃声")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onDisappear { player.stop() }
    }
}

// MARK: - 子页：邮箱（改完要去新邮箱点确认链接才生效）

struct EmailEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
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
            infoMessage = "邮箱没变，不用保存"
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await auth.updateEmail(newEmail)
            infoMessage = "确认邮件已发到新邮箱，点开确认后才生效"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 子页：修改密码（≥6 位，两次一致，空着就是不改）

struct PasswordEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
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
            infoMessage = "密码没改"
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
            infoMessage = "密码已改"
            newPassword = ""
            confirmPassword = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 子页：封面背景（预览 + 从相册选 + 恢复默认）

struct CoverEditorView: View {
    @EnvironmentObject var auth: AuthViewModel
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
            if let qr = qrImage(for: "https://zyty.cc.cd") {
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

import SwiftUI
import UIKit
import AVFoundation

struct NativeFriend: Codable, Identifiable, Equatable, Hashable {
    /// 6 位好友号，即好友的唯一标识。
    var id: String
    var nickname: String
}

/// 好友列表存在本机（UserDefaults）。
/// 限制：网页版的好友存在各手机浏览器的 localStorage 里，原生 App 读不到，
/// 所以这里的好友列表和网页版不互通；好友连接（真实聊天/通话）后续步骤接入。
@MainActor
final class FriendStore: ObservableObject {
    @Published private(set) var friends: [NativeFriend] = []
    private let storageKey = "zy-native-friends"

    init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([NativeFriend].self, from: data)
        else {
            friends = []
            return
        }
        friends = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(friends) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// 添加好友（本机列表）。6 位数字、未重复才成功。
    @discardableResult
    func add(number: String) -> Bool {
        guard number.count == 6,
              number.allSatisfy({ $0.isNumber }),
              !friends.contains(where: { $0.id == number })
        else { return false }
        friends.append(NativeFriend(id: number, nickname: "好友 \(number)"))
        save()
        return true
    }

    func remove(at offsets: IndexSet) {
        friends.remove(atOffsets: offsets)
        save()
    }
}

struct FriendsView: View {
    /// 好友列表由 MainTabView 统一持有，和消息列表共用同一份数据。
    @EnvironmentObject var store: FriendStore
    @State private var showAddFriend = false
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            Group {
                if store.friends.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 56))
                            .foregroundColor(.secondary)
                        Text("还没有好友")
                            .font(.headline)
                        Text("好友列表暂存于本机，与网页版不互通。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button("添加好友") { showAddFriend = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
                } else {
                    List {
                        Section {
                            ForEach(store.friends) { friend in
                                NavigationLink {
                                    ChatView(conversationId: friend.id, isBot: false, title: friend.nickname)
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            Circle().fill(Color(.systemGray5))
                                            Text(String(friend.nickname.prefix(1)))
                                                .font(.headline)
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(width: 44, height: 44)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(friend.nickname)
                                            Text("好友号 \(friend.id)")
                                                .font(.footnote)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                            .onDelete(perform: store.remove)
                        } footer: {
                            Text("好友列表暂存于本机，与网页版不互通。")
                        }
                    }
                }
            }
            .navigationTitle("好友")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // 右上角 +（照微信通讯录）：弹出“添加好友 / 扫一扫”。
                    Menu {
                        Button {
                            showAddFriend = true
                        } label: {
                            Label("添加好友", systemImage: "person.badge.plus")
                        }
                        Button {
                            showScanner = true
                        } label: {
                            Label("扫一扫", systemImage: "qrcode.viewfinder")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddFriend) {
                AddFriendView(store: store)
            }
            .fullScreenCover(isPresented: $showScanner) {
                QRScannerView(store: store)
            }
        }
    }
}

/// 添加好友页：输 6 位好友号确认。
/// 反馈修（第 7 步）：以前点“添加”没反应——失败原因只写在表单下面一行红字，
/// 键盘弹着时根本看不见，用户以为按钮死了。现在改成弹框提示，
/// 成功、重复、加自己、格式不对四种结果都有明确说法；键盘先收起再弹框。
struct AddFriendView: View {
    @ObservedObject var store: FriendStore
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var number = ""
    @FocusState private var numberFocused: Bool
    @State private var alertMessage: String?
    @State private var alertIsSuccess = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("6 位好友号", text: $number)
                        .keyboardType(.numberPad)
                        .focused($numberFocused)
                        .onChange(of: number) { _, newValue in
                            let filtered = newValue.filter { $0.isNumber }
                            number = String(filtered.prefix(6))
                        }
                } footer: {
                    Text("本次仅保存到本机列表，好友连接后续步骤接入。")
                }
                Section {
                    Button(action: submit) {
                        Text("添加好友")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(number.count != 6)
                }
            }
            .navigationTitle("添加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加", action: submit)
                        .disabled(number.count != 6)
                }
            }
            .alert(alertMessage ?? "", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("确定") {
                    // 成功才关页；失败留在原页，改完号能再点。
                    if alertIsSuccess { dismiss() }
                }
            }
        }
    }

    /// 点确认：先收键盘，再按顺序校验——格式、自己、重复，最后才保存。
    /// 每种结果都弹框说清楚，不再静默。
    private func submit() {
        numberFocused = false
        let num = number
        guard num.count == 6, num.allSatisfy({ $0.isNumber }) else {
            alertMessage = "请输入 6 位数字好友号"
            alertIsSuccess = false
            return
        }
        if num == auth.friendNumber {
            alertMessage = "不能加自己为好友"
            alertIsSuccess = false
            return
        }
        if store.friends.contains(where: { $0.id == num }) {
            alertMessage = "已经是好友了"
            alertIsSuccess = false
            return
        }
        if store.add(number: num) {
            alertMessage = "已添加好友号 \(num)"
            alertIsSuccess = true
        } else {
            alertMessage = "添加失败，请再试一次"
            alertIsSuccess = false
        }
    }
}

// MARK: - 扫一扫（相机扫 QR 码加好友，照微信通讯录右上角 + 里的做法）

/// 从扫到的二维码内容里解析好友号。认这几种：
/// - 纯 6 位数字（比如 856053）
/// - 链接里的参数：?add=123456、?num=123456、?room=123456
/// - 本 App 二维码：https://zyty.cc.cd/?add=好友号
/// 解析不出来返回 nil。
func parseFriendNumber(from string: String) -> String? {
    let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.count == 6 && s.allSatisfy({ $0.isNumber }) { return s }
    var urlString = s
    if !urlString.lowercased().hasPrefix("http") {
        urlString = "https://" + urlString
    }
    guard let components = URLComponents(string: urlString),
          let items = components.queryItems else { return nil }
    for key in ["add", "num", "room"] {
        if let value = items.first(where: { $0.name == key })?.value,
           value.count == 6, value.allSatisfy({ $0.isNumber }) {
            return value
        }
    }
    return nil
}

/// 相机扫码控制器：AVCaptureSession + AVCaptureMetadataOutput，只扫 QR 码。
/// 注意：这里故意不标 @MainActor——代理回调方法是系统定的非隔离方法，
/// 标了会在 Swift 6 模式下编译不过；控制器只在主线程调用（代理队列就是主队列）。
final class QRScannerController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var isReady = false
    @Published var permissionDenied = false
    @Published var torchAvailable = false
    @Published var torchOn = false
    var onCode: ((String) -> Void)?

    private var device: AVCaptureDevice?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupIfNeeded()
            if !session.isRunning { session.startRunning() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.setupIfNeeded()
                        self.session.startRunning()
                    } else {
                        self.permissionDenied = true
                    }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    func toggleTorch() {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = device.torchMode == .on ? .off : .on
            torchOn = device.torchMode == .on
            device.unlockForConfiguration()
        } catch {
            // 手电筒打不开就保持原样。
        }
    }

    private func setupIfNeeded() {
        guard !isReady else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        self.device = device
        torchAvailable = device.hasTorch
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()
        isReady = true
    }
}

extension QRScannerController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = object.stringValue else { return }
        onCode?(code)
    }
}

/// 相机预览画面（AVCaptureVideoPreviewLayer 的 SwiftUI 包装）。
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let layer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            layer.frame = uiView.bounds
        }
    }
}

/// 扫一扫页面：全屏相机 + 中间扫码框 + 取消 / 手电筒。
/// 扫到码就停下来解析：是好友号就加到本地好友列表，不是就提示“这不是好友二维码”。
struct QRScannerView: View {
    @ObservedObject var store: FriendStore
    @EnvironmentObject var auth: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = QRScannerController()
    @State private var resultMessage: String?
    @State private var closeAfterResult = false
    @State private var handledCode: String?

    var body: some View {
        ZStack {
            if controller.isReady {
                CameraPreviewView(session: controller.session)
            } else {
                Color.black
            }
            scanOverlay
            VStack {
                HStack {
                    Button("取消") { dismiss() }
                        .foregroundColor(.white)
                        .font(.system(size: 17, weight: .semibold))
                        .padding()
                    Spacer()
                    if controller.torchAvailable {
                        Button {
                            controller.toggleTorch()
                        } label: {
                            Image(systemName: controller.torchOn ? "bolt.fill" : "bolt.slash.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .padding()
                    }
                }
                Spacer()
                if controller.permissionDenied {
                    VStack(spacing: 12) {
                        Text("没有相机权限，扫不了二维码")
                            .foregroundColor(.white)
                        Button("去设置里打开相机权限") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.bottom, 60)
                } else {
                    Text("把二维码放进框里，就能加好友")
                        .foregroundColor(.white)
                        .padding(.bottom, 48)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            controller.onCode = handleCode
            controller.start()
        }
        .onDisappear {
            controller.stop()
        }
        .alert(resultMessage ?? "", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("确定") {
                if closeAfterResult {
                    dismiss()
                } else {
                    // 不是好友二维码：继续扫（同一码不再重复弹，直到扫到别的码）。
                    controller.start()
                }
            }
        }
    }

    /// 扫码框：中间透明方框 + 四周遮黑 + 四角白框。
    private var scanOverlay: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.62
            let rect = CGRect(
                x: (geo.size.width - side) / 2,
                y: (geo.size.height - side) / 2 - 40,
                width: side,
                height: side
            )
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 16, height: 16))
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Path { path in
                    let len: CGFloat = 28
                    let r = rect
                    path.move(to: CGPoint(x: r.minX, y: r.minY + len))
                    path.addLine(to: CGPoint(x: r.minX, y: r.minY))
                    path.addLine(to: CGPoint(x: r.minX + len, y: r.minY))
                    path.move(to: CGPoint(x: r.maxX - len, y: r.minY))
                    path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                    path.addLine(to: CGPoint(x: r.maxX, y: r.minY + len))
                    path.move(to: CGPoint(x: r.maxX, y: r.maxY - len))
                    path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                    path.addLine(to: CGPoint(x: r.maxX - len, y: r.maxY))
                    path.move(to: CGPoint(x: r.minX + len, y: r.maxY))
                    path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                    path.addLine(to: CGPoint(x: r.minX, y: r.maxY - len))
                }
                .stroke(Color.white, lineWidth: 3)
            }
        }
    }

    /// 收到一个二维码：同一码只处理一次，停下相机再解析。
    private func handleCode(_ code: String) {
        guard handledCode != code else { return }
        handledCode = code
        controller.stop()
        guard let number = parseFriendNumber(from: code) else {
            resultMessage = "这不是好友二维码"
            closeAfterResult = false
            return
        }
        if store.friends.contains(where: { $0.id == number }) {
            resultMessage = "已经是好友了"
            closeAfterResult = true
        } else if number == auth.friendNumber {
            resultMessage = "不能加自己为好友"
            closeAfterResult = true
        } else if store.add(number: number) {
            resultMessage = "已添加好友号 \(number)"
            closeAfterResult = true
        } else {
            resultMessage = "这不是好友二维码"
            closeAfterResult = false
        }
    }
}

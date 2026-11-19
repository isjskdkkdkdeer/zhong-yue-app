import SwiftUI
import UIKit
import AVFoundation

struct NativeFriend: Codable, Identifiable, Equatable, Hashable {
    /// 6 位好友号，即好友的唯一标识。
    var id: String
    var nickname: String
}

/// 好友列表：服务器为准，本机 UserDefaults 做离线缓存。
/// 打开好友页时调服务器拉取（GET /friends + GET /friend-requests），
/// 拉成功用服务器列表覆盖缓存；没网或拉失败时显示缓存。
/// 网页版的好友存在各手机浏览器的 localStorage 里，原生 App 读不到，
/// 所以这里的好友列表和网页版不互通；原生两台手机之间走服务器互通。
@MainActor
final class FriendStore: ObservableObject {
    @Published private(set) var friends: [NativeFriend] = []
    /// 待处理的好友请求（对方加我，等我接受 / 拒绝）。
    @Published private(set) var pendingRequests: [FriendRequest] = []
    @Published private(set) var isSyncingFriends = false

    /// 备注名：只存本机（UserDefaults），显示时备注优先。
    private var remarks: [String: String] = [:]

    private let storageKey = "zy-native-friends"
    private let remarksKey = "zy-friend-remarks"

    init() { load() }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([NativeFriend].self, from: data) {
            friends = decoded
        }
        if let data = UserDefaults.standard.data(forKey: remarksKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            remarks = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(friends) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func saveRemarks() {
        if let data = try? JSONEncoder().encode(remarks) {
            UserDefaults.standard.set(data, forKey: remarksKey)
        }
    }

    /// 显示用的名字：备注优先，没有备注就用“好友 + 好友号”。
    /// 服务器只给好友号、查不到对方昵称，所以默认显示号码。
    func displayName(for friend: NativeFriend) -> String {
        if let remark = remarks[friend.id], !remark.isEmpty { return remark }
        return friend.nickname
    }

    /// 改备注名（只存本机）。传空字符串就是清除备注。
    func setRemark(_ remark: String, for number: String) {
        let trimmed = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            remarks.removeValue(forKey: number)
        } else {
            remarks[number] = trimmed
        }
        saveRemarks()
        objectWillChange.send()
    }

    /// 服务器好友同步：GET /friends（服务器为准，覆盖本机缓存）+
    /// GET /friend-requests（待处理请求）。没令牌或拉失败就静默用缓存。
    func sync(token: String?) async {
        guard let token, !token.isEmpty else { return }
        isSyncingFriends = true
        defer { isSyncingFriends = false }
        if let result = await WorkerAPI.request(path: "friends", method: "GET", token: token, as: FriendsListResponse.self),
           result.status == 200, result.value?.ok == true,
           let list = result.value?.friends {
            friends = list.compactMap { item -> NativeFriend? in
                guard item.friend_num.count == 6 else { return nil }
                return NativeFriend(id: item.friend_num, nickname: "好友 \(item.friend_num)")
            }
            save()
        }
        if let result = await WorkerAPI.request(path: "friend-requests", method: "GET", token: token, as: FriendRequestsResponse.self),
           result.status == 200, result.value?.ok == true,
           let list = result.value?.requests {
            pendingRequests = list.compactMap { item -> FriendRequest? in
                guard item.from_num.count == 6 else { return nil }
                let ms = item.created_at ?? 0
                return FriendRequest(fromNum: item.from_num, createdAt: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
            }
        }
    }

    /// 加好友（走服务器 POST /friend-add）。成功按 status 区分；
    /// 失败返回中文原因。friends / already_friends 时把对方写进本机列表，
    /// requested 时只发请求、不进列表（等对方接受后同步时才出现）。
    func addFriend(number: String, token: String?) async -> FriendAddOutcome {
        guard let token, !token.isEmpty else { return .failed("还没登录，请先登录再加好友") }
        guard let result = await WorkerAPI.request(
            path: "friend-add", method: "POST", token: token,
            body: WorkerAPI.jsonBody(["to_num": number]), as: FriendAddResponse.self
        ) else {
            return .failed("网络有问题，好友请求没发出去，请检查网络再试")
        }
        if result.status == 401 { return .failed("登录已过期，请重新登录再试") }
        guard result.status == 200, result.value?.ok == true,
              let status = result.value?.status else {
            switch result.value?.error {
            case "cannot add self": return .failed("不能加自己为好友")
            case "bad input": return .failed("好友号不对，请检查 6 位数字")
            case let e?: return .failed("添加失败（\(e)），请稍后再试")
            default: return .failed("添加失败，请检查网络再试")
            }
        }
        switch status {
        case "friends":
            upsertLocal(number: number)
            return .added(.friends)
        case "already_friends":
            upsertLocal(number: number)
            return .added(.alreadyFriends)
        case "requested":
            return .added(.requested)
        default:
            return .failed("添加失败，请稍后再试")
        }
    }

    /// 接受好友请求：双方互加好友，请求从待处理里去掉。
    func acceptRequest(_ request: FriendRequest, token: String?) async -> Bool {
        guard let token, !token.isEmpty else { return false }
        guard let result = await WorkerAPI.request(
            path: "friend-accept", method: "POST", token: token,
            body: WorkerAPI.jsonBody(["from_num": request.fromNum]), as: WorkerOK.self
        ), result.status == 200, result.value?.ok == true else { return false }
        upsertLocal(number: request.fromNum)
        pendingRequests.removeAll { $0.fromNum == request.fromNum }
        return true
    }

    /// 拒绝好友请求。
    func rejectRequest(_ request: FriendRequest, token: String?) async -> Bool {
        guard let token, !token.isEmpty else { return false }
        guard let result = await WorkerAPI.request(
            path: "friend-reject", method: "POST", token: token,
            body: WorkerAPI.jsonBody(["from_num": request.fromNum]), as: WorkerOK.self
        ), result.status == 200, result.value?.ok == true else { return false }
        pendingRequests.removeAll { $0.fromNum == request.fromNum }
        return true
    }

    /// 删好友（只删我这边）：先从本机列表去掉，再调服务器；
    /// 服务器失败就把人放回列表并返回失败原因，下次同步以服务器为准。
    func deleteFriend(_ friend: NativeFriend, token: String?) async -> String? {
        guard let idx = friends.firstIndex(of: friend) else { return nil }
        friends.remove(at: idx)
        save()
        guard let token, !token.isEmpty else { return nil }
        guard let result = await WorkerAPI.request(
            path: "friend-remove", method: "POST", token: token,
            body: WorkerAPI.jsonBody(["friend_num": friend.id]), as: WorkerOK.self
        ), result.status == 200, result.value?.ok == true else {
            friends.insert(friend, at: min(idx, friends.count))
            save()
            return "删除失败，请检查网络再试"
        }
        return nil
    }

    /// 本机列表里加一个好友（服务器同步 / 接受请求后用；已在列表里就不重复加）。
    func upsertLocal(number: String) {
        guard !friends.contains(where: { $0.id == number }) else { return }
        friends.append(NativeFriend(id: number, nickname: "好友 \(number)"))
        save()
    }

    /// 是不是好友：先看本机列表，没有就从服务器同步一次再看。
    /// （第 11 步：对方刚接受请求时，本机列表可能还没同步——只看本机会
    /// 把真好友判成陌生人，来电会被悄悄丢掉、发消息会被错误地拦住。）
    func isFriend(_ number: String, token: String?) async -> Bool {
        if friends.contains(where: { $0.id == number }) { return true }
        await sync(token: token)
        return friends.contains(where: { $0.id == number })
    }

    /// 添加好友（本机列表）。6 位数字、未重复才成功。
    /// 注意：现在加好友走服务器（addFriend），这个只留给本地兜底。
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
}

struct FriendsView: View {
    /// 好友列表由 MainTabView 统一持有，和消息列表共用同一份数据。
    @EnvironmentObject var store: FriendStore
    @EnvironmentObject var auth: AuthViewModel
    @State private var showAddFriend = false
    @State private var showScanner = false
    @State private var remarkFriend: NativeFriend?
    @State private var remarkText = ""
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            List {
                // 新的朋友：有待处理请求时显示红色数字角标。
                Section {
                    NavigationLink {
                        FriendRequestsView(store: store)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.badge.plus")
                                .foregroundColor(Color(red: 0, green: 0.48, blue: 1))
                                .frame(width: 28)
                            Text("新的朋友")
                            Spacer()
                            if !store.pendingRequests.isEmpty {
                                Text("\(store.pendingRequests.count)")
                                    .font(.footnote)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                Section {
                    if store.friends.isEmpty {
                        Text("还没有好友，点右上角 + 输入对方 6 位好友号添加。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(store.friends) { friend in
                            NavigationLink {
                                ChatView(conversationId: friend.id, isBot: false, title: store.displayName(for: friend))
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle().fill(Color(.systemGray5))
                                        Text(String(store.displayName(for: friend).prefix(1)))
                                            .font(.headline)
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(store.displayName(for: friend))
                                        Text("好友号 \(friend.id)")
                                            .font(.footnote)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task {
                                        if let err = await store.deleteFriend(friend, token: auth.session?.accessToken) {
                                            deleteError = err
                                        }
                                    }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            // 好友行左滑：语音 / 视频通话（第 10 步）。
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    Task {
                                        await CallManager.shared.startCall(
                                            to: friend.id,
                                            displayName: store.displayName(for: friend),
                                            isVideo: false
                                        )
                                    }
                                } label: {
                                    Label("语音", systemImage: "phone.fill")
                                }
                                .tint(Color(red: 0, green: 0.48, blue: 1))
                                Button {
                                    Task {
                                        await CallManager.shared.startCall(
                                            to: friend.id,
                                            displayName: store.displayName(for: friend),
                                            isVideo: true
                                        )
                                    }
                                } label: {
                                    Label("视频", systemImage: "video.fill")
                                }
                                .tint(.green)
                            }
                            .contextMenu {
                                Button("改备注名") {
                                    remarkText = store.displayName(for: friend)
                                    remarkFriend = friend
                                }
                            }
                        }
                    }
                } footer: {
                    Text("好友列表以服务器为准，没网时显示本机缓存；和网页版不互通，原生两台手机之间互通。")
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
            .task {
                // 打开好友页就同步一次服务器好友列表和待处理请求。
                await store.sync(token: auth.session?.accessToken)
            }
            .refreshable {
                await store.sync(token: auth.session?.accessToken)
            }
            .sheet(isPresented: $showAddFriend) {
                AddFriendView(store: store)
            }
            .fullScreenCover(isPresented: $showScanner) {
                QRScannerView(store: store)
            }
            .alert("改备注名", isPresented: Binding(
                get: { remarkFriend != nil },
                set: { if !$0 { remarkFriend = nil } }
            )) {
                TextField("备注名", text: $remarkText)
                Button("保存") {
                    if let friend = remarkFriend {
                        store.setRemark(remarkText, for: friend.id)
                    }
                    remarkFriend = nil
                }
                Button("取消", role: .cancel) { remarkFriend = nil }
            }
            .alert(deleteError ?? "", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("确定") {}
            }
        }
    }
}

/// 新的朋友：待处理的好友请求列表（GET /friend-requests）。
/// 每条显示对方好友号和时间，接受 / 拒绝后刷新列表。
struct FriendRequestsView: View {
    @ObservedObject var store: FriendStore
    @EnvironmentObject var auth: AuthViewModel
    @State private var busyNumber: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if store.pendingRequests.isEmpty {
                Text("没有新的好友请求")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.pendingRequests) { request in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color(.systemGray5))
                            Text(String(request.fromNum.prefix(1)))
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("好友号 \(request.fromNum)")
                            Text(requestTimeString(request.createdAt))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if busyNumber == request.fromNum {
                            ProgressView()
                        } else {
                            Button("接受") {
                                Task { await act(request, accept: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(busyNumber != nil)
                            Button("拒绝") {
                                Task { await act(request, accept: false) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(busyNumber != nil)
                        }
                    }
                }
            }
        }
        .navigationTitle("新的朋友")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.sync(token: auth.session?.accessToken)
        }
        .alert(errorMessage ?? "", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("确定") {}
        }
    }

    private func act(_ request: FriendRequest, accept: Bool) async {
        busyNumber = request.fromNum
        let ok = accept
            ? await store.acceptRequest(request, token: auth.session?.accessToken)
            : await store.rejectRequest(request, token: auth.session?.accessToken)
        busyNumber = nil
        if !ok {
            errorMessage = "操作失败，请检查网络再试"
        }
    }

    private func requestTimeString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
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
                    Text("发给对方一条好友请求，对方接受后双方互为好友。")
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

    /// 点确认：先收键盘，再按顺序校验——格式、自己、重复，
    /// 最后走服务器发好友请求（POST /friend-add）。
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
        Task {
            switch await store.addFriend(number: num, token: auth.session?.accessToken) {
            case .added(.friends):
                alertMessage = "已添加好友号 \(num)"
                alertIsSuccess = true
            case .added(.alreadyFriends):
                alertMessage = "已经是好友了"
                alertIsSuccess = true
            case .added(.requested):
                alertMessage = "好友请求已发送，等对方接受"
                alertIsSuccess = true
            case .failed(let reason):
                alertMessage = reason
                alertIsSuccess = false
            }
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
/// 扫到码就停下来解析：是好友号就走服务器发好友请求，不是就提示“这不是好友二维码”。
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
        } else {
            // 走服务器发好友请求（POST /friend-add）。
            Task {
                switch await store.addFriend(number: number, token: auth.session?.accessToken) {
                case .added(.friends):
                    resultMessage = "已添加好友号 \(number)"
                    closeAfterResult = true
                case .added(.alreadyFriends):
                    resultMessage = "已经是好友了"
                    closeAfterResult = true
                case .added(.requested):
                    resultMessage = "好友请求已发送，等对方接受"
                    closeAfterResult = true
                case .failed(let reason):
                    resultMessage = reason
                    closeAfterResult = false
                }
            }
        }
    }
}

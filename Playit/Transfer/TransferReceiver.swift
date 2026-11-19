import Darwin
import Foundation
import Network
import PlayitTransferCore

/// One private queue owns every mutable socket, reservation and file handle.
final class TransferReceiver: @unchecked Sendable {
    enum Event: Sendable {
        case ready(String)
        case waiting(String)
        case upload(TransferUpload)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "playit.transfer.receiver", qos: .userInitiated)
    private let rootURL: URL
    private let address: String
    private let token = TransferFilePolicy.makeSessionToken()
    private let expiresAt = Date().addingTimeInterval(60 * 60)
    private let onEvent: @Sendable (Event) -> Void
    private var listener: NWListener?
    private var monitor: NWPathMonitor?
    private var connections: [UUID: TransferConnection] = [:]
    private var authority: String?
    private var stopped = false
    private var networkContinuity = TransferNetworkContinuity()
    private let safetyMargin: Int64 = 8 * 1_024 * 1_024

    init(rootURL: URL, address: String, onEvent: @escaping @Sendable (Event) -> Void) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.address = address
        self.onEvent = onEvent
    }

    /// Partial uploads are written here and moved into the library once complete.
    private static let incomingFolderName = ".playit-incoming"

    /// An upload cut off by a crash or a forced quit leaves its partial file in a
    /// hidden folder that neither the library nor the Files app shows, so the
    /// space would never come back. Call this only while no receiver is running.
    static func removeLeftoverUploads(in rootURL: URL) {
        let incoming = rootURL.appendingPathComponent(incomingFolderName, isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            guard FileManager.default.fileExists(atPath: incoming.path) else { return }
            try? FileManager.default.removeItem(at: incoming)
        }
    }

    static func availableBytes(at rootURL: URL) -> Int64 {
        let path = FileManager.default.fileExists(atPath: rootURL.path)
            ? rootURL.path : rootURL.deletingLastPathComponent().path
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    /// A fixed port keeps the computer's address (and a browser bookmark) the
    /// same between sessions. If another app holds it, the system picks one.
    private static let preferredPort: NWEndpoint.Port = 8080

    func start() {
        queue.async { [self] in
            guard !stopped, listener == nil else { return }
            startListener(on: Self.preferredPort)
            guard !stopped else { return }
            #if !targetEnvironment(simulator)
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self, !self.stopped else { return }
                if self.networkContinuity.shouldStop(isSatisfied: path.status == .satisfied,
                                                     hasOriginalAddress: TransferLocalAddress.wifiIPv4() == self.address) {
                    self.fail("Wi-Fi 连接已改变，当前传输已停止。请连接网络后重新开启。")
                }
            }
            monitor.start(queue: queue)
            #endif
        }
    }

    /// Runs on `queue`.
    private func startListener(on requestedPort: NWEndpoint.Port) {
        guard !stopped else { return }
        do {
            let parameters = NWParameters.tcp
            // Turning the receiver off and on again may reuse the same port at once.
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: requestedPort)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, !self.stopped, let listener, listener === self.listener else { return }
                switch state {
                case .ready:
                    guard let boundPort = listener.port?.rawValue else {
                        self.fail("无法分配接收端口，请重新开启传输。")
                        return
                    }
                    self.authority = "\(self.address):\(boundPort)"
                    self.onEvent(.ready("http://\(self.address):\(boundPort)/"))
                case .failed(let error):
                    if requestedPort != .any, case .posix(let code) = error, code == .EADDRINUSE {
                        self.retryOnAnyPort(replacing: listener)
                        return
                    }
                    self.fail("无法开启本地网络接收：\(error.localizedDescription)。请在“设置 → 隐私与安全性 → 本地网络”中允许 Prism。")
                case .waiting(let error):
                    // Waiting is recoverable; cancelling here prevents the
                    // listener from becoming ready after a permission prompt.
                    self.onEvent(.waiting("正在等待局域网接收就绪：\(error.localizedDescription)。请连接 Wi-Fi，并在“设置 → 隐私与安全性 → 本地网络”中允许 Prism。"))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped, self.connections.count < 8 else {
                    connection.cancel()
                    return
                }
                let client = TransferConnection(connection: connection, owner: self, queue: self.queue)
                self.connections[client.id] = client
                client.start()
            }
            listener.start(queue: queue)
        } catch {
            if requestedPort != .any {
                startListener(on: .any)
            } else {
                fail("无法开启传输：\(error.localizedDescription)")
            }
        }
    }

    /// Runs on `queue`.
    private func retryOnAnyPort(replacing old: NWListener) {
        old.stateUpdateHandler = nil
        old.newConnectionHandler = nil
        old.cancel()
        if listener === old { listener = nil }
        startListener(on: .any)
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        monitor?.cancel()
        monitor = nil
        let clients = Array(connections.values)
        connections.removeAll()
        for client in clients { client.cancel(message: "接收已停止，请重新上传。") }
    }

    private func fail(_ message: String) {
        stopOnQueue()
        onEvent(.failed(message))
    }

    fileprivate func disconnected(_ id: UUID) { connections.removeValue(forKey: id) }
    fileprivate func publish(_ upload: TransferUpload) { onEvent(.upload(upload)) }

    fileprivate func handle(_ head: TransferRequestHead, client: TransferConnection) {
        guard let authority, head.headers["host"] == authority else {
            client.reject(403, "接收地址不匹配，请使用手机显示的完整地址。")
            return
        }
        guard Date() < expiresAt else {
            client.reject(403, "会话已过期，请在手机中重新开启 Wi-Fi 传输。")
            return
        }
        if let origin = head.headers["origin"], !TransferFilePolicy.isSameOrigin(origin, authority: authority) {
            client.reject(403, "请求来源不匹配，请直接打开手机显示的地址。")
            return
        }
        if head.method == "GET" || head.method == "HEAD" {
            guard (head.contentLength ?? 0) == 0 else {
                client.reject(400, "请求格式无效。")
                return
            }
            switch TransferFilePolicy.webRoute(target: head.target, token: token) {
            case .redirect(let path):
                client.redirect(to: path, headOnly: head.method == "HEAD")
            case .page:
                client.respond(200, body: Data(UploadPage.html.utf8), type: "text/html; charset=utf-8", headOnly: head.method == "HEAD")
            case .status:
                client.respondJSON(200, ["freeBytes": Self.availableBytes(at: rootURL), "expiresAt": expiresAt.timeIntervalSince1970], headOnly: head.method == "HEAD")
            case .font(let resourceName):
                guard let fontURL = Bundle.main.url(forResource: resourceName, withExtension: "otf"),
                      let fontData = try? Data(contentsOf: fontURL, options: .mappedIfSafe) else {
                    client.reject(404, "字体资源不可用。")
                    return
                }
                client.respond(200, body: fontData, type: "font/otf", headOnly: head.method == "HEAD")
            case .notFound:
                client.reject(404, "地址不存在或接收会话已关闭，请从手机获取新地址。")
            }
            return
        }
        guard head.method == "POST",
              TransferFilePolicy.isSameOrigin(head.headers["origin"], authority: authority),
              head.headers["x-playit-upload"] == "1" else {
            client.reject(403, "请通过当前接收页面选择文件上传。")
            return
        }
        guard head.headers["content-type"]?.lowercased() == "application/octet-stream" else {
            client.reject(415, "不支持的上传方式。")
            return
        }
        guard let length = head.contentLength else {
            client.reject(411, "上传必须包含明确的文件大小。")
            return
        }
        guard length > 0 else {
            client.reject(400, "不能上传空文件。")
            return
        }
        do {
            guard let filename = try TransferFilePolicy.uploadFilename(target: head.target, token: token) else {
                client.reject(404, "地址不存在，请使用手机当前显示的地址。")
                return
            }
            let active = connections.values.filter { $0.isUploading }
            guard active.count < 2 else {
                client.reject(429, "同时接收的文件过多，请稍后重试。")
                return
            }
            let reserved = active.reduce(Int64(0)) { $0 + $1.remainingBytes }
            let available = Self.availableBytes(at: rootURL)
            guard available > safetyMargin, length <= available - safetyMargin - reserved else {
                client.reject(507, "手机剩余空间不足，请清理空间后重试。")
                return
            }
            let temporaryDirectory = rootURL.appendingPathComponent(Self.incomingFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            let info = try temporaryDirectory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard info.isSymbolicLink != true else {
                client.reject(500, "无法安全创建接收文件，请检查媒体目录。")
                return
            }
            try client.beginUpload(filename: filename, total: length,
                                   temporaryURL: temporaryDirectory.appendingPathComponent(client.id.uuidString + ".part"))
            if let expectation = head.headers["expect"] {
                guard expectation.lowercased() == "100-continue" else {
                    client.reject(417, "不支持的请求预期。")
                    return
                }
                client.sendContinue()
            }
        } catch TransferHTTPError.invalidFilename {
            client.reject(400, "文件名称无效，请去掉路径、特殊符号或过长的名称。")
        } catch TransferHTTPError.unsupportedFile {
            client.reject(415, "暂不支持此文件类型，请选择常见视频或图片。")
        } catch {
            client.reject(500, "无法创建接收文件：\(error.localizedDescription)")
        }
    }

    fileprivate func commit(temporaryURL: URL, filename: String) throws -> String {
        let fileManager = FileManager.default
        let stem = (filename as NSString).deletingPathExtension
        let fileExtension = (filename as NSString).pathExtension
        for index in 0..<10_000 {
            let candidate = index == 0 ? filename : "\(stem) (\(index)).\(fileExtension)"
            let destination = rootURL.appendingPathComponent(candidate, isDirectory: false)
            do {
                try fileManager.moveItem(at: temporaryURL, to: destination)
                return candidate
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

fileprivate final class TransferConnection {
    let id = UUID()
    private let connection: NWConnection
    private weak var owner: TransferReceiver?
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var headerData = Data()
    private var parsedHead = false
    private var finished = false
    private var temporaryURL: URL?
    private var file: FileHandle?
    private var upload: TransferUpload?
    private var lastPublication = 0.0

    var isUploading: Bool { upload?.state == .receiving }
    var remainingBytes: Int64 {
        guard let upload, upload.state == .receiving else { return 0 }
        return max(0, upload.totalBytes - upload.receivedBytes)
    }

    init(connection: NWConnection, owner: TransferReceiver, queue: DispatchQueue) {
        self.connection = connection
        self.owner = owner
        self.queue = queue
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.setEventHandler { [weak self] in self?.cancel(message: "连接超时，请在电脑端重试。") }
        timer.schedule(deadline: .now() + 45)
        timer.resume()
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel(message: "网络连接已断开，请重试。") }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, complete, error in
            guard let self, !self.finished else { return }
            self.timer?.schedule(deadline: .now() + 45)
            if let content, !content.isEmpty { self.consume(content) }
            guard !self.finished else { return }
            if complete || error != nil {
                self.cancel(message: "上传中断，请保持同一 Wi-Fi 并重试。")
            } else {
                self.receive()
            }
        }
    }

    private func consume(_ bytes: Data) {
        if !parsedHead {
            headerData.append(bytes)
            do {
                guard let parsed = try TransferRequestHead.parse(headerData) else { return }
                parsedHead = true
                let remaining = Data(headerData.dropFirst(parsed.consumed))
                headerData.removeAll(keepingCapacity: false)
                owner?.handle(parsed.head, client: self)
                if !finished, isUploading, !remaining.isEmpty { consumeBody(remaining) }
            } catch TransferHTTPError.headersTooLarge {
                reject(431, "请求头过大。")
            } catch {
                reject(400, "请求格式无效。")
            }
        } else {
            consumeBody(bytes)
        }
    }

    func beginUpload(filename: String, total: Int64, temporaryURL: URL) throws {
        try Data().write(to: temporaryURL, options: .withoutOverwriting)
        self.temporaryURL = temporaryURL
        file = try FileHandle(forWritingTo: temporaryURL)
        let upload = TransferUpload(id: id, name: filename, receivedBytes: 0,
                                    totalBytes: total, state: .receiving)
        self.upload = upload
        owner?.publish(upload)
    }

    private func consumeBody(_ bytes: Data) {
        guard var current = upload, current.state == .receiving, let file else { return }
        guard Int64(bytes.count) <= current.totalBytes - current.receivedBytes else {
            reject(400, "上传内容超过声明的大小。")
            return
        }
        do {
            try file.write(contentsOf: bytes)
            current.receivedBytes += Int64(bytes.count)
            upload = current
            let now = Date.timeIntervalSinceReferenceDate
            if now - lastPublication >= 0.1 {
                owner?.publish(current)
                lastPublication = now
            }
            if current.receivedBytes == current.totalBytes { completeUpload() }
        } catch {
            reject(507, "写入文件失败，手机可能没有足够的空间。")
        }
    }

    private func completeUpload() {
        guard var current = upload, let temporaryURL, let owner else { return }
        do {
            try file?.synchronize()
            try file?.close()
            file = nil
            current.name = try owner.commit(temporaryURL: temporaryURL, filename: current.name)
            self.temporaryURL = nil
            current.state = .completed
            upload = current
            owner.publish(current)
            respondJSON(201, ["message": "已存入媒体库", "filename": current.name])
        } catch {
            reject(500, "无法保存文件：\(error.localizedDescription)")
        }
    }

    func sendContinue() {
        connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
    }

    func reject(_ status: Int, _ message: String) {
        markUploadFailed(message)
        cleanTemporaryFile()
        respondJSON(status, ["message": message])
    }

    func respondJSON(_ status: Int, _ value: [String: Any], headOnly: Bool = false) {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        respond(status, body: data, type: "application/json; charset=utf-8", headOnly: headOnly)
    }

    func redirect(to sessionPath: String, headOnly: Bool) {
        // Only the server-generated relative token path is passed here.
        respond(302, body: Data(), type: "text/plain; charset=utf-8", headOnly: headOnly, location: sessionPath)
    }

    func respond(_ status: Int, body: Data, type: String, headOnly: Bool = false, location: String? = nil) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        let reasons = [200: "OK", 201: "Created", 302: "Found", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 411: "Length Required", 415: "Unsupported Media Type", 417: "Expectation Failed", 429: "Too Many Requests", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 507: "Insufficient Storage"]
        let redirectHeader = location.map { "Location: \($0)\r\n" } ?? ""
        let headers = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n\(redirectHeader)Content-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n\r\n"
        var response = Data(headers.utf8)
        if !headOnly { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.finishConnection() })
    }

    func cancel(message: String) {
        markUploadFailed(message)
        cleanTemporaryFile()
        finishConnection()
    }

    private func markUploadFailed(_ message: String) {
        guard var current = upload, current.state == .receiving else { return }
        current.state = .failed
        current.errorMessage = message
        upload = current
        owner?.publish(current)
    }

    private func cleanTemporaryFile() {
        try? file?.close()
        file = nil
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        temporaryURL = nil
    }

    private func finishConnection() {
        finished = true
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        owner?.disconnected(id)
    }
}

enum TransferLocalAddress {
    static func wifiIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [(String, String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let interface = item.pointee
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard ["en0", "en1", "bridge100"].contains(name) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            candidates.append((name, String(cString: host)))
        }
        return candidates.first(where: { $0.0 == "en0" })?.1 ?? candidates.first?.1
    }
}

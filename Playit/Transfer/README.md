# Wi-Fi 接收模块

`TransferStore` 是主线程 ObservableObject，初始化时传入媒体根目录和导入完成后的刷新回调：

```swift
TransferStore(rootURL: mediaRootURL) {
    library.reload()
}
```

- `start()` / `stop()` 开关服务；`isRunning` 在启动中也为 true。
- `address: String?` 仅在监听就绪后提供 `http://IP:随机端口/`。浏览器访问后跳转到当前 8 位小写十六进制会话码（32 位随机数）的页面；复制地址时保留 `http://` 和端口。
- `statusMessage`、`errorMessage` 用于用户反馈；后者可赋值为 nil 清除。
- `uploads: [TransferUpload]` 包含 `id`、`name`、`receivedBytes`、`totalBytes`、`progress`、`state` 和 `errorMessage`。
- `TransferUpload.State` 是 `.receiving`、`.completed`、`.failed`。
- `freeBytes` 可读；`refreshCapacity()` 手动刷新可用空间。

App 需在 Info.plist 设置 `NSLocalNetworkUsageDescription`。服务只在前台运行，进入后台时停止并清理未完成文件。App 可在 `isRunning` 时设置 `UIApplication.shared.isIdleTimerDisabled`，关闭后恢复。无需后台模式或 Bonjour 服务声明。

监听进入 `.waiting` 时保留接收器，隐藏尚不可用的地址并显示网络／本地网络权限提示。网络监视器的首次不可用快照不立即取消服务；已经建立的 Wi-Fi 断开或地址改变后停止接收。接收事件由串行队列按顺序交给主线程，并使用会话代次隔离已关闭接收器的回调。

浏览器页面是内嵌 `UploadPage.html`，不依赖外部脚本、字体服务或 CDN。英文与数字使用 App 随包的 D-DIN Regular/Bold，中文回退系统无衬线字体；字体由当前接收会话的固定同源路由提供，强调色保持 `#C4F582`。每次使用原始 `File` 对象发送一个文件，通过 XHR 显示真实进度，文件串行排队，支持拖放、批量选择、取消和失败重试。

## 协议与限制

- `GET` / `HEAD /` 和 `/<token>`：302 跳转到 `/<token>/`，避免漏输会话路径或末尾斜杠导致 404；跳转仍受 Host、会话有效期及 Origin 校验。
- `GET /<token>/`：网页；`GET /<token>/status`：可用空间和会话到期时间。
- `GET` / `HEAD /<token>/fonts/D-DIN.otf` 和 `/<token>/fonts/D-DIN-Bold.otf`：仅提供这两个固定 Bundle 字体，响应类型为 `font/otf`。字体请求同样受 Host、会话有效期及 Origin 校验；CSP 仅允许同源字体，不接受任意资源路径。
- `POST /<token>/upload?name=<URL编码文件名>`：`Content-Type: application/octet-stream`、`X-Playit-Upload: 1` 和明确的 Content-Length。浏览器自动发送同源 Origin。
- 成功返回 201 JSON `{message, filename}`；同名文件自动加序号，不覆盖现有文件。
- 文件写入隐藏目录 `.playit-incoming` 的临时文件，按 64 KiB 上限的接收块流式写盘，完成后同卷原子移动到媒体根目录。中断、超时、后台和关闭均清理当前临时文件。
- 最多 8 个连接、2 个接收文件；空闲连接 45 秒超时；接收会话 1 小时到期。接收中的文件可完成，新的请求需重新开启服务。
- 限定常见视频和图片扩展名，拒绝路径、隐藏文件、控制字符、过长名称；精确匹配 Host、会话路径、Origin、自定义上传头。关闭 CORS，不提供任意文件浏览或下载。
- 预留 8 MiB 空间，并扣除其他接收任务尚未写入的预留量。写盘仍可能因系统其他活动失败，此时清理临时文件并返回可重试的错误。
- 此版本失败重试从头上传，不支持断点续传。页面中的“上传至 100%”与服务器保存完成分开显示。

## 已验证与待验证

纯 Foundation 协议核心位于 `Packages/PlayitTransferCore`。Linux Swift 6.0.3 实际运行 `swift test`：17 项测试通过，覆盖短会话码格式、精确会话匹配、根地址重定向、网页／状态／字体路径、无会话上传拒绝、启动时网络快照、已建立网络丢失、每字节拆包、header/body 边界、大小限制、重复头、长度歧义、Origin 和文件名越界。

`TransferStore.swift`、`TransferReceiver.swift` 和 `UploadPage.swift` 已通过 Swift 前端语法解析；网页内嵌 JavaScript 通过 Node 语法检查。当前环境没有 Apple SDK，Network.framework、UIKit 及 Combine 的编译与真实 Wi-Fi 大文件传输仍须在 Xcode/设备上验证。

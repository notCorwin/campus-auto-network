import AppKit
import Combine
import CoreLocation
import CoreWLAN
import CryptoKit
import Darwin
import Foundation
import Network
import ServiceManagement
import SwiftUI
import UserNotifications

private let appDisplayName = "校园网自动登录"
private let configDefaultsKey = "config.v1"
private let stateDefaultsKey = "state.v1"
private let autoStartDefaultsKey = "autoStartEnabled"

struct AppError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum ProxyMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case direct
    case proxy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动（直连失败后代理）"
        case .direct: return "仅直连"
        case .proxy: return "仅代理"
        }
    }
}

struct AppConfig: Codable, Equatable {
    var username: String
    var password: String
    var ssid: String
    var serverURL: String
    var ipPrefixes: [String]
    var autoDetectIP: Bool
    var wlanUserIP: String
    var verifySSL: Bool
    var proxyMode: ProxyMode
    var proxyURL: String
    var timeoutSecs: UInt64
    var retryAttempts: UInt32
    var retryIntervalSecs: UInt64

    static let `default` = AppConfig(
        username: "",
        password: "",
        ssid: "CSUST-Student",
        serverURL: "https://login.csust.edu.cn:802/eportal/portal/login",
        ipPrefixes: ["10.161.", "10.183."],
        autoDetectIP: true,
        wlanUserIP: "",
        verifySSL: false,
        proxyMode: .auto,
        proxyURL: "http://127.0.0.1:7890",
        timeoutSecs: 15,
        retryAttempts: 3,
        retryIntervalSecs: 5
    )

    private enum CodingKeys: String, CodingKey {
        case username, password, ssid
        case serverURL = "server_url"
        case ipPrefixes = "ip_prefixes"
        case autoDetectIP = "auto_detect_ip"
        case wlanUserIP = "wlan_user_ip"
        case verifySSL = "verify_ssl"
        case proxyMode = "proxy_mode"
        case proxyURL = "proxy_url"
        case timeoutSecs = "timeout_secs"
        case retryAttempts = "retry_attempts"
        case retryIntervalSecs = "retry_interval_secs"
    }

    init(
        username: String,
        password: String,
        ssid: String,
        serverURL: String,
        ipPrefixes: [String],
        autoDetectIP: Bool,
        wlanUserIP: String,
        verifySSL: Bool,
        proxyMode: ProxyMode,
        proxyURL: String,
        timeoutSecs: UInt64,
        retryAttempts: UInt32,
        retryIntervalSecs: UInt64
    ) {
        self.username = username
        self.password = password
        self.ssid = ssid
        self.serverURL = serverURL
        self.ipPrefixes = ipPrefixes
        self.autoDetectIP = autoDetectIP
        self.wlanUserIP = wlanUserIP
        self.verifySSL = verifySSL
        self.proxyMode = proxyMode
        self.proxyURL = proxyURL
        self.timeoutSecs = timeoutSecs
        self.retryAttempts = retryAttempts
        self.retryIntervalSecs = retryIntervalSecs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        ssid = try container.decodeIfPresent(String.self, forKey: .ssid) ?? Self.default.ssid
        serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL) ?? Self.default.serverURL
        ipPrefixes = try container.decodeIfPresent([String].self, forKey: .ipPrefixes) ?? Self.default.ipPrefixes
        autoDetectIP = try container.decodeIfPresent(Bool.self, forKey: .autoDetectIP) ?? Self.default.autoDetectIP
        wlanUserIP = try container.decodeIfPresent(String.self, forKey: .wlanUserIP) ?? ""
        verifySSL = try container.decodeIfPresent(Bool.self, forKey: .verifySSL) ?? Self.default.verifySSL
        proxyMode = try container.decodeIfPresent(ProxyMode.self, forKey: .proxyMode) ?? Self.default.proxyMode
        proxyURL = try container.decodeIfPresent(String.self, forKey: .proxyURL) ?? Self.default.proxyURL
        timeoutSecs = try container.decodeIfPresent(UInt64.self, forKey: .timeoutSecs) ?? Self.default.timeoutSecs
        retryAttempts = try container.decodeIfPresent(UInt32.self, forKey: .retryAttempts) ?? Self.default.retryAttempts
        retryIntervalSecs = try container.decodeIfPresent(UInt64.self, forKey: .retryIntervalSecs) ?? Self.default.retryIntervalSecs
    }

    func validationError() -> String? {
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty {
            return "账号或密码为空，请在设置中补充。"
        }

        guard let server = URLComponents(string: serverURL),
              let scheme = server.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = server.host, !host.isEmpty,
              server.user == nil,
              server.password == nil,
              server.query == nil,
              server.fragment == nil else {
            return "认证地址必须是完整的 HTTP/HTTPS 地址，且不含凭据、查询串或片段。"
        }

        if ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "SSID 不能为空。"
        }
        if ipPrefixes.isEmpty || ipPrefixes.contains(where: { !Self.validPrefix($0) }) {
            return "校园 IPv4 前缀必须以点结尾，例如 10.183.。"
        }
        if !autoDetectIP && !usableIPv4(wlanUserIP) {
            return "手动 IPv4 必须是有效的非虚拟地址。"
        }
        if proxyMode != .direct {
            guard let proxy = URLComponents(string: proxyURL),
                  let scheme = proxy.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  let host = proxy.host, !host.isEmpty else {
                return "代理地址必须是完整的 HTTP/HTTPS 地址。"
            }
        }
        if !(1...3600).contains(timeoutSecs) || retryAttempts == 0 || !(1...3600).contains(retryIntervalSecs) {
            return "超时和重试间隔须为 1–3600 秒，重试次数须大于 0。"
        }
        return nil
    }

    private static func validPrefix(_ prefix: String) -> Bool {
        guard prefix.hasSuffix(".") else { return false }
        let body = prefix.dropLast()
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy { UInt8($0) != nil }
    }
}

struct AppPaths {
    let data: URL
    let legacyConfig: URL
    let legacyState: URL
    let logs: URL

    init(fileManager: FileManager = .default) {
        let home = fileManager.homeDirectoryForCurrentUser
        data = home.appendingPathComponent("Library/Application Support/csust-auto-login", isDirectory: true)
        legacyConfig = data.appendingPathComponent("config.json")
        legacyState = data.appendingPathComponent("state.json")
        logs = home.appendingPathComponent("Library/Logs/csust-auto-login", isDirectory: true)
    }
}

private func ensurePrivateDirectory(_ url: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

final class AppStore {
    private let defaults: UserDefaults
    let paths: AppPaths
    private let lock = NSLock()
    private var storedConfig: AppConfig
    private var configError: String?

    init(defaults: UserDefaults = .standard, paths: AppPaths = AppPaths()) {
        self.defaults = defaults
        self.paths = paths

        if let data = defaults.data(forKey: configDefaultsKey) {
            do {
                storedConfig = try JSONDecoder().decode(AppConfig.self, from: data)
                configError = nil
            } catch {
                storedConfig = .default
                configError = "配置格式错误，无法读取已保存设置。"
            }
        } else if let data = try? Data(contentsOf: paths.legacyConfig) {
            do {
                storedConfig = try JSONDecoder().decode(AppConfig.self, from: data)
                configError = nil
                if let encoded = try? JSONEncoder().encode(storedConfig) {
                    defaults.set(encoded, forKey: configDefaultsKey)
                }
            } catch {
                storedConfig = .default
                configError = "旧配置格式错误，无法完成迁移。"
            }
        } else {
            storedConfig = .default
            configError = nil
        }
    }

    func config() -> Result<AppConfig, AppError> {
        lock.lock()
        let result: Result<AppConfig, AppError> = configError
            .map { .failure(AppError(message: $0)) } ?? .success(storedConfig)
        lock.unlock()
        return result
    }

    func effectiveConfig() -> Result<AppConfig, AppError> {
        switch config() {
        case .failure(let error): return .failure(error)
        case .success(var config):
            if let password = ProcessInfo.processInfo.environment["CSUST_PASSWORD"] {
                config.password = password
            }
            if let error = config.validationError() {
                return .failure(AppError(message: error))
            }
            return .success(config)
        }
    }

    func saveConfig(_ config: AppConfig) throws {
        guard config.validationError() == nil else {
            throw StoreError.invalidConfig
        }
        let encoded = try JSONEncoder().encode(config)
        lock.lock()
        storedConfig = config
        configError = nil
        lock.unlock()
        defaults.set(encoded, forKey: configDefaultsKey)
    }

    func loadState() -> AppState {
        if let data = defaults.data(forKey: stateDefaultsKey),
           let state = try? JSONDecoder().decode(AppState.self, from: data) {
            return state
        }
        if let data = try? Data(contentsOf: paths.legacyState),
           let state = try? JSONDecoder().decode(AppState.self, from: data) {
            saveState(state)
            return state
        }
        return AppState()
    }

    func saveState(_ state: AppState) {
        if let encoded = try? JSONEncoder().encode(state) {
            defaults.set(encoded, forKey: stateDefaultsKey)
        }
    }

    func autoStartEnabled() -> Bool {
        if defaults.object(forKey: autoStartDefaultsKey) == nil {
            defaults.set(true, forKey: autoStartDefaultsKey)
            return true
        }
        return defaults.bool(forKey: autoStartDefaultsKey)
    }

    func setAutoStartEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: autoStartDefaultsKey)
    }

    enum StoreError: LocalizedError {
        case invalidConfig

        var errorDescription: String? { "配置校验失败。" }
    }
}

struct AppState: Codable, Equatable {
    var phase = ""
    var detail = ""
    var network = ""
    var route = ""
    var checkedAt: Int64 = 0
    var checking = false
    var lastSuccess: Int64?
    var failureSince: Int64?
    var notified = false
    var credentialsBlocked = false
    var configKey = ""
    var attempt: UInt32 = 0

    private enum CodingKeys: String, CodingKey {
        case phase, detail, network, route
        case checkedAt = "checked_at"
        case checking
        case lastSuccess = "last_success"
        case failureSince = "failure_since"
        case notified
        case credentialsBlocked = "credentials_blocked"
        case configKey = "config_key"
        case attempt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? ""
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        network = try container.decodeIfPresent(String.self, forKey: .network) ?? ""
        route = try container.decodeIfPresent(String.self, forKey: .route) ?? ""
        checkedAt = try container.decodeIfPresent(Int64.self, forKey: .checkedAt) ?? 0
        checking = try container.decodeIfPresent(Bool.self, forKey: .checking) ?? false
        lastSuccess = try container.decodeIfPresent(Int64.self, forKey: .lastSuccess)
        failureSince = try container.decodeIfPresent(Int64.self, forKey: .failureSince)
        notified = try container.decodeIfPresent(Bool.self, forKey: .notified) ?? false
        credentialsBlocked = try container.decodeIfPresent(Bool.self, forKey: .credentialsBlocked) ?? false
        if let key = try? container.decode(String.self, forKey: .configKey) {
            configKey = key
        } else if let numeric = try? container.decode(UInt64.self, forKey: .configKey) {
            configKey = String(numeric)
        }
        attempt = try container.decodeIfPresent(UInt32.self, forKey: .attempt) ?? 0
    }

    mutating func transition(phase: String, detail: String, now: Int64) -> Bool {
        let changed = self.phase != phase || self.detail != detail
        let needsAction = phase == "credentials" || phase == "config_error"
        if needsAction && self.phase != phase {
            notified = false
        }
        self.phase = phase
        self.detail = detail
        checkedAt = now
        checking = false
        if phase == "online" || phase == "outside" {
            failureSince = nil
            notified = false
        }
        if phase == "online" {
            lastSuccess = now
        }
        if ["credentials", "config_error", "retry", "waiting_ip"].contains(phase) {
            let since = failureSince ?? now
            failureSince = since
            let shouldNotify = !notified && (needsAction || now - since >= 120)
            if shouldNotify {
                notified = true
            }
        }
        return changed
    }
}

struct WiFiNetwork: Equatable {
    let interfaceName: String
    let ssid: String?
    let bssid: String?
    let ip: String?

    var key: String {
        "\(interfaceName) / \(ip ?? "等待 IPv4")"
    }
}

func usableIPv4(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
    let octets = parts.compactMap { UInt8($0) }
    guard octets.count == 4 else { return false }
    if octets[0] == 0 || octets[0] >= 224 || octets[0] == 127 { return false }
    if octets[0] == 169 && octets[1] == 254 { return false }
    if octets[0] == 198 && (octets[1] == 18 || octets[1] == 19) { return false }
    return true
}

func isCampusIP(_ config: AppConfig, _ ip: String) -> Bool {
    usableIPv4(ip) && config.ipPrefixes.contains(where: { ip.hasPrefix($0) })
}

func selectNetwork(_ config: AppConfig, _ networks: [WiFiNetwork]) -> WiFiNetwork? {
    let matching = networks.filter { $0.ssid == config.ssid }
    return matching.first(where: { $0.ip.map { isCampusIP(config, $0) } ?? false })
        ?? matching.first(where: { $0.ip == nil })
}

private func interfaceIPv4Addresses() -> [String: String] {
    var result: [String: String] = [:]
    var addressPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addressPointer) == 0, let first = addressPointer else { return result }
    defer { freeifaddrs(first) }

    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let pointer = current {
        defer { current = pointer.pointee.ifa_next }
        guard let address = pointer.pointee.ifa_addr,
              address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard let text = buffer.withUnsafeMutableBufferPointer({ bufferPointer in
            inet_ntop(AF_INET, &ipv4, bufferPointer.baseAddress, socklen_t(INET_ADDRSTRLEN))
        }) else { continue }
        result[String(cString: text)] = String(cString: pointer.pointee.ifa_name)
    }
    return result.reduce(into: [:]) { output, item in
        if output[item.value] == nil, usableIPv4(item.key) {
            output[item.value] = item.key
        }
    }
}

final class WiFiMonitor: NSObject, CWEventDelegate {
    private let client = CWWiFiClient.shared()
    var onChange: (() -> Void)?

    func start() {
        client.delegate = self
        for event in [CWEventType.ssidDidChange, .bssidDidChange, .linkDidChange, .powerDidChange] {
            _ = try? client.startMonitoringEvent(with: event)
        }
        onChange?()
    }

    func stop() {
        _ = try? client.stopMonitoringAllEvents()
    }

    func networks() -> [WiFiNetwork] {
        let addresses = interfaceIPv4Addresses()
        var result: [WiFiNetwork] = []
        for interface in client.interfaces() ?? [] {
            guard let name = interface.interfaceName else { continue }
            result.append(WiFiNetwork(
                interfaceName: name,
                ssid: interface.ssid(),
                bssid: interface.bssid(),
                ip: addresses[name]
            ))
        }
        return result
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    func bssidDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { onChange?() }

    func clientConnectionInterrupted() { onChange?() }
    func clientConnectionInvalidated() { onChange?() }
}

enum AuthOutcome: Equatable {
    case online
    case credentials
    case retry(String)
    case networkChanged
}

private final class LoginSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    let verifySSL: Bool
    var redirectLocation: String?

    init(verifySSL: Bool) {
        self.verifySSL = verifySSL
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirectLocation = response.value(forHTTPHeaderField: "Location")
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge: challenge, completionHandler: completionHandler)
    }

    private func handle(
        challenge: URLAuthenticationChallenge,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if !verifySSL,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private struct HTTPResult {
    let statusCode: Int
    let body: Data
    let redirectLocation: String?
}

enum LoginService {
    static func login(
        config: AppConfig,
        ip: String,
        stillConnected: () -> Bool
    ) -> (AuthOutcome, String) {
        let account = ",0,\(config.username)"
        let parameters = [
            ("callback", "dr1003"),
            ("login_method", "1"),
            ("user_account", account),
            ("user_password", config.password),
            ("wlan_user_ip", ip),
            ("wlan_user_ipv6", ""),
            ("wlan_user_mac", "000000000000"),
            ("wlan_ac_ip", ""),
            ("wlan_ac_name", ""),
            ("jsVersion", "4.2.1"),
            ("terminal_type", "1"),
            ("lang", "zh-cn"),
            ("v", "8207")
        ]
        let routes = routeNames(for: config.proxyMode)
        let referer = originURL(config.serverURL)
        var errors: [String] = []
        var lastRoute = ""

        for route in routes {
            if !stillConnected() { return (.networkChanged, lastRoute) }
            lastRoute = route
            guard let request = makeRequest(
                urlString: config.serverURL,
                parameters: parameters,
                referer: referer
            ) else {
                errors.append("认证地址无效")
                continue
            }
            switch perform(request: request, config: config, route: route) {
            case .failure(let error):
                errors.append("\(routeLabel(route))：\(error)")
            case .success(let response):
                if !stillConnected() { return (.networkChanged, lastRoute) }
                if (300...399).contains(response.statusCode) {
                    return (parseResponse(response.redirectLocation ?? ""), lastRoute)
                }
                guard (200...299).contains(response.statusCode) else {
                    return (.retry("认证服务器返回 HTTP \(response.statusCode)，将自动重试。"), lastRoute)
                }
                if let text = String(data: response.body, encoding: .utf8) {
                    if !stillConnected() { return (.networkChanged, lastRoute) }
                    return (parseResponse(text), lastRoute)
                }
                errors.append("\(routeLabel(route))：响应读取失败")
            }
        }
        return (.retry(errors.joined(separator: "；")), lastRoute)
    }

    static func probe(config: AppConfig, route: String) -> Result<Int, AppError> {
        guard let server = URLComponents(string: config.serverURL),
              let scheme = server.scheme,
              let host = server.host else {
            return .failure(AppError(message: "认证地址无效"))
        }
        var root = URLComponents()
        root.scheme = scheme
        root.host = host
        root.port = server.port
        root.path = "/"
        guard let rootURL = root.url else { return .failure(AppError(message: "认证地址无效")) }
        let request = URLRequest(url: rootURL)
        switch perform(request: request, config: config, route: route) {
        case .success(let result): return .success(result.statusCode)
        case .failure(let error): return .failure(error)
        }
    }

    private static func routeNames(for mode: ProxyMode) -> [String] {
        switch mode {
        case .auto: return ["direct", "proxy"]
        case .direct: return ["direct"]
        case .proxy: return ["proxy"]
        }
    }

    private static func makeRequest(
        urlString: String,
        parameters: [(String, String)],
        referer: String
    ) -> URLRequest? {
        guard var components = URLComponents(string: urlString) else { return nil }
        components.queryItems = parameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func perform(
        request: URLRequest,
        config: AppConfig,
        route: String
    ) -> Result<HTTPResult, AppError> {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.timeoutIntervalForRequest = Double(config.timeoutSecs)
        sessionConfiguration.timeoutIntervalForResource = Double(config.timeoutSecs)
        sessionConfiguration.httpShouldSetCookies = false
        if route == "direct" {
            sessionConfiguration.connectionProxyDictionary = [
                "HTTPEnable": 0,
                "HTTPSEnable": 0
            ]
        } else if let proxy = URLComponents(string: config.proxyURL),
                  let host = proxy.host,
                  let scheme = proxy.scheme?.lowercased() {
            let port = proxy.port ?? (scheme == "https" ? 443 : 80)
            var settings: [AnyHashable: Any] = [
                "HTTPEnable": 1,
                "HTTPProxy": host,
                "HTTPPort": port,
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": port
            ]
            if let user = proxy.user, let password = proxy.password {
                settings["HTTPProxyUsername"] = user
                settings["HTTPProxyPassword"] = password
                settings["HTTPSProxyUsername"] = user
                settings["HTTPSProxyPassword"] = password
            }
            sessionConfiguration.connectionProxyDictionary = settings
        } else {
            return .failure(AppError(message: "代理地址无效"))
        }

        let delegate = LoginSessionDelegate(verifySSL: config.verifySSL)
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        let semaphore = DispatchSemaphore(value: 0)
        var body = Data()
        var statusCode = 0
        var requestError: Error?
        let task = session.dataTask(with: request) { data, response, error in
            body = data ?? Data()
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            requestError = error
            semaphore.signal()
        }
        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + Double(config.timeoutSecs) + 1)
        if waitResult == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            return .failure(AppError(message: "连接超时"))
        }
        session.finishTasksAndInvalidate()
        if let redirectLocation = delegate.redirectLocation {
            return .success(HTTPResult(
                statusCode: statusCode == 0 ? 302 : statusCode,
                body: body,
                redirectLocation: redirectLocation
            ))
        }
        if let requestError {
            return .failure(AppError(message: connectionError(requestError)))
        }
        if statusCode == 0 {
            return .failure(AppError(message: "连接中断"))
        }
        return .success(HTTPResult(statusCode: statusCode, body: body, redirectLocation: delegate.redirectLocation))
    }

    private static func connectionError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "连接超时"
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return "无法建立连接（请检查网络或代理是否启动）"
            default: return "连接中断"
            }
        }
        return "连接中断"
    }

    private static func originURL(_ value: String) -> String {
        guard let input = URLComponents(string: value) else { return "" }
        var origin = URLComponents()
        origin.scheme = input.scheme
        origin.host = input.host
        origin.port = input.port
        origin.path = "/"
        return origin.string ?? ""
    }
}

func parseResponse(_ text: String) -> AuthOutcome {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var jsonText = trimmed
    if let open = trimmed.firstIndex(of: "("),
       trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines) == "dr1003",
       let close = trimmed.lastIndex(of: ")"), close > open {
        jsonText = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText.hasSuffix(";") { jsonText.removeLast() }
    }

    let object: [String: Any]? = (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))) as? [String: Any]
    let message = ((object?["msg"] as? String) ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = message.lowercased()
    let credentialWords = ["密码错误", "账号错误", "帐号错误", "账号不存在", "用户不存在", "用户名或密码错误", "账号已欠费"]
    if credentialWords.contains(where: message.contains) || lower == "invalid password" || lower == "invalid credentials" {
        return .credentials
    }
    let normalized = message.trimmingCharacters(in: CharacterSet(charactersIn: "!.！"))
    let online = message.contains("已经在线") || message.contains("已在线") || [
        "already online", "user already online", "user is already online"
    ].contains(normalized.lowercased())
    let result = object?["result"]
    let success = (result as? NSNumber)?.intValue == 1 || (result as? String) == "1"
    if success || online || trimmed.contains("Dr.COMWebLoginID_3.htm") {
        return .online
    }
    if trimmed.contains("认证超时") {
        return .retry("认证超时，将自动重试。")
    }
    if trimmed.contains("Dr.COMWebLoginID_2.htm") {
        return .retry("认证被拒绝，请检查认证参数。")
    }
    return .retry("未收到可确认的认证结果，可运行 App 内诊断检查连接。")
}

private func routeLabel(_ route: String) -> String {
    switch route {
    case "direct": return "直连"
    case "proxy": return "本地代理"
    default: return "尚未选择"
    }
}

func configFingerprint(_ config: AppConfig) -> String {
    guard let data = try? JSONEncoder().encode(config) else { return "" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

final class LogStore {
    private let paths: AppPaths
    private let lock = NSLock()

    init(paths: AppPaths) { self.paths = paths }

    func append(state: AppState) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try ensurePrivateDirectory(paths.logs)
            cleanup()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let timestamp = formatter.string(from: Date())
            let file = paths.logs.appendingPathComponent("\(timestamp.prefix(10)).log")
            let line = "\(timestamp) [\(state.phase)] \(routeLabel(state.route)) / \(state.detail)\n"
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            NSLog("日志写入失败：%@", error.localizedDescription)
        }
    }

    private func cleanup() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries where entry.pathExtension == "log" {
            guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate,
                  Date().timeIntervalSince(date) > 7 * 86400 else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

final class AutoLoginEngine {
    private let store: AppStore
    private let logger: LogStore
    private let networkProvider: () -> [WiFiNetwork]
    private let permissionProvider: () -> Bool
    private let queue = DispatchQueue(label: "com.nowaywastaken.csustautologin.engine", qos: .utility)
    private var state: AppState
    private var running = false
    private var pending = false
    private var scheduled = false
    private var stopped = false
    var onUpdate: ((AppState, Bool) -> Void)?

    init(
        store: AppStore,
        networkProvider: @escaping () -> [WiFiNetwork],
        permissionProvider: @escaping () -> Bool,
        onUpdate: ((AppState, Bool) -> Void)? = nil
    ) {
        self.store = store
        self.logger = LogStore(paths: store.paths)
        self.networkProvider = networkProvider
        self.permissionProvider = permissionProvider
        self.state = store.loadState()
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.emit(shouldNotify: false)
            self.requestLocked()
        }
    }

    func request() {
        queue.async { [weak self] in self?.requestLocked() }
    }

    func checkNow() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.pending = false
            guard !self.running else { self.pending = true; return }
            self.running = true
            self.runCycle(manual: true)
            self.running = false
            self.schedulePendingIfNeeded()
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            pending = false
        }
    }

    private func requestLocked() {
        guard !stopped else { return }
        pending = true
        schedulePendingIfNeeded()
    }

    private func schedulePendingIfNeeded() {
        guard !stopped, !running, pending, !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self, !self.stopped else { return }
            self.scheduled = false
            guard self.pending, !self.running else { return }
            self.pending = false
            self.running = true
            self.runCycle(manual: false)
            self.running = false
            self.schedulePendingIfNeeded()
        }
    }

    private func runCycle(manual: Bool) {
        if manual {
            state.credentialsBlocked = false
            state.failureSince = nil
            state.notified = false
        }
        var attempt: UInt32 = 0

        while !stopped {
            let config: AppConfig
            switch store.effectiveConfig() {
            case .failure(let error):
                record(phase: "config_error", detail: error.message)
                return
            case .success(let value):
                config = value
            }

            let fingerprint = configFingerprint(config)
            if state.configKey != fingerprint {
                state.configKey = fingerprint
                state.credentialsBlocked = false
                state.failureSince = nil
                state.notified = false
            }

            guard permissionProvider() else {
                state.network = ""
                state.route = ""
                state.attempt = 0
                record(phase: "permission", detail: "需要定位权限才能读取 Wi‑Fi 名称，请在系统设置中允许本 App。")
                return
            }

            let networks = networkProvider()
            guard let network = selectNetwork(config, networks) else {
                state.network = ""
                state.route = ""
                state.attempt = 0
                record(phase: "outside", detail: "未连接校园网，等待网络变化。")
                return
            }
            let key = network.key
            if state.network != key {
                state.network = key
                state.failureSince = nil
                state.notified = false
            }
            if state.credentialsBlocked {
                record(phase: "credentials", detail: "认证信息被拒绝，请在设置中修改，或点击立即登录重试。")
                return
            }
            if attempt >= config.retryAttempts { return }
            attempt += 1
            state.attempt = attempt

            guard let detectedIP = network.ip, isCampusIP(config, detectedIP) else {
                state.route = ""
                record(phase: "waiting_ip", detail: "已连接校园 Wi‑Fi，等待系统分配 IPv4 地址。")
                if attempt >= config.retryAttempts { return }
                Thread.sleep(forTimeInterval: Double(config.retryIntervalSecs))
                continue
            }
            let loginIP = config.autoDetectIP ? detectedIP : config.wlanUserIP
            state.checkedAt = Int64(Date().timeIntervalSince1970)
            state.checking = true
            store.saveState(state)
            publish(state: state, shouldNotify: false)

            let outcome = LoginService.login(config: config, ip: loginIP) { [networkProvider] in
                selectNetwork(config, networkProvider())?.key == key
            }
            switch outcome.0 {
            case .online:
                state.route = outcome.1
                record(phase: "online", detail: "登录成功或已经在线。")
                return
            case .credentials:
                state.route = outcome.1
                state.credentialsBlocked = true
                record(phase: "credentials", detail: "认证信息被拒绝，请在设置中修改，或点击立即登录重试。")
                return
            case .retry(let detail):
                state.route = outcome.1
                record(phase: "retry", detail: detail)
            case .networkChanged:
                state.route = outcome.1
                record(phase: "retry", detail: "网络已变化，重新检查。")
                continue
            }
            if attempt >= config.retryAttempts { return }
            Thread.sleep(forTimeInterval: Double(config.retryIntervalSecs))
        }
    }

    private func record(phase: String, detail: String) {
        let oldNotified = state.notified
        let changed = state.transition(phase: phase, detail: detail, now: Int64(Date().timeIntervalSince1970))
        let shouldNotify = !oldNotified && state.notified
        if changed || phase == "retry" { logger.append(state: state) }
        store.saveState(state)
        publish(state: state, shouldNotify: shouldNotify)
    }

    private func emit(shouldNotify: Bool) {
        publish(state: state, shouldNotify: shouldNotify)
    }

    private func publish(state: AppState, shouldNotify: Bool) {
        onUpdate?(state, shouldNotify)
    }
}

final class AppModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = AppModel()

    @Published private(set) var config: AppConfig
    @Published private(set) var state: AppState
    @Published private(set) var permissionStatus: CLAuthorizationStatus
    @Published private(set) var networks: [WiFiNetwork] = []
    @Published private(set) var diagnosticText = ""
    @Published private(set) var launchStatus = ""
    @Published private(set) var autoStartEnabled: Bool

    private let store: AppStore
    private let locationManager = CLLocationManager()
    private let wifiMonitor = WiFiMonitor()
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let pathQueue = DispatchQueue(label: "com.nowaywastaken.csustautologin.path")
    private var fallbackTimer: Timer?
    private var started = false

    private lazy var engine: AutoLoginEngine = {
        AutoLoginEngine(
            store: store,
            networkProvider: { [weak self] in self?.wifiMonitor.networks() ?? [] },
            permissionProvider: { [weak self] in self?.isLocationAuthorized ?? false },
            onUpdate: { [weak self] state, shouldNotify in
                DispatchQueue.main.async {
                    self?.apply(state: state, shouldNotify: shouldNotify)
                }
            }
        )
    }()

    private var isLocationAuthorized: Bool {
        permissionStatus == .authorized
    }

    override private init() {
        store = AppStore()
        switch store.config() {
        case .success(let config): self.config = config
        case .failure: self.config = .default
        }
        state = store.loadState()
        permissionStatus = locationManager.authorizationStatus
        autoStartEnabled = store.autoStartEnabled()
        super.init()
        locationManager.delegate = self
    }

    func start() {
        guard !started else { return }
        started = true
        requestNotificationPermission()
        refreshLaunchStatus()
        if autoStartEnabled { registerLaunchAtLogin() }

        wifiMonitor.onChange = { [weak self] in self?.requestCheck() }
        wifiMonitor.start()
        pathMonitor.pathUpdateHandler = { [weak self] _ in self?.requestCheck() }
        pathMonitor.start(queue: pathQueue)
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.requestCheck()
        }
        requestLocationPermissionIfNeeded()
        engine.start()
        refreshNetworks()
        if case .failure = store.effectiveConfig() {
            // 配置缺失或无效时直接打开设置，首次安装不需要再回到终端。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                guard case .failure = self.store.effectiveConfig() else { return }
                self.openSettingsWindow()
            }
        }
    }

    func stop() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        pathMonitor.cancel()
        wifiMonitor.stop()
        engine.stop()
    }

    func requestCheck() {
        engine.request()
        refreshNetworks()
    }

    func checkNow() {
        engine.checkNow()
        refreshNetworks()
    }

    func saveConfig(_ newConfig: AppConfig) {
        guard let error = newConfig.validationError() else {
            do {
                try store.saveConfig(newConfig)
                config = newConfig
                diagnosticText = "配置已保存。"
                engine.request()
            } catch {
                diagnosticText = "保存失败：\(error.localizedDescription)"
            }
            return
        }
        diagnosticText = error
    }

    func requestLocationPermissionIfNeeded() {
        permissionStatus = locationManager.authorizationStatus
        guard permissionStatus == .notDetermined else {
            if permissionStatus == .denied || permissionStatus == .restricted {
                diagnosticText = "定位权限未允许，SSID 会被系统隐藏。请打开系统设置授权。"
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.locationManager.requestWhenInUseAuthorization()
        }
    }

    func openLocationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
        NSWorkspace.shared.open(url)
    }

    func runDoctor() {
        diagnosticText = "正在诊断…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let currentNetworks = self.wifiMonitor.networks()
            var lines = currentNetworks.map {
                "网卡 \($0.interfaceName)：IPv4=\($0.ip ?? "未分配")，SSID=\($0.ssid ?? "不可读取")，BSSID=\($0.bssid ?? "不可读取")"
            }
            switch self.store.effectiveConfig() {
            case .failure(let error):
                lines.append("配置：\(error.message)")
            case .success(let config):
                if let network = selectNetwork(config, currentNetworks) {
                    lines.append("匹配校园网络：\(network.key)")
                    for route in self.routeNames(for: config.proxyMode) {
                        switch LoginService.probe(config: config, route: route) {
                        case .success(let status): lines.append("\(routeLabel(route))：服务器可达，HTTP \(status)")
                        case .failure(let error): lines.append("\(routeLabel(route))：\(error.message)")
                        }
                    }
                } else {
                    lines.append("当前不在配置的校园网络，未发送认证请求。")
                }
            }
            DispatchQueue.main.async { self.diagnosticText = lines.joined(separator: "\n") }
        }
    }

    func setAutoStart(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            autoStartEnabled = enabled
            store.setAutoStartEnabled(enabled)
            refreshLaunchStatus()
        } catch {
            diagnosticText = "登录启动设置失败：\(error.localizedDescription)"
            refreshLaunchStatus()
        }
    }

    var statusText: String {
        if permissionStatus != .authorized {
            switch permissionStatus {
            case .notDetermined: return "等待定位权限"
            case .denied, .restricted: return "需要定位权限"
            default: return "需要定位权限"
            }
        }
        return state.detail.isEmpty ? "尚无检查记录" : state.detail
    }

    var statusSymbol: String {
        switch state.phase {
        case "online": return "checkmark.circle.fill"
        case "retry", "waiting_ip": return "exclamationmark.triangle.fill"
        case "permission", "config_error", "credentials": return "lock.trianglebadge.exclamationmark"
        default: return "wifi"
        }
    }

    private func apply(state: AppState, shouldNotify: Bool) {
        self.state = state
        if shouldNotify {
            let content = UNMutableNotificationContent()
            content.title = appDisplayName
            content.body = state.detail
            let request = UNNotificationRequest(
                identifier: "failure-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func refreshNetworks() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.networks = self.wifiMonitor.networks()
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func refreshLaunchStatus() {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled: launchStatus = "已启用"
        case .requiresApproval: launchStatus = "等待系统批准"
        case .notRegistered: launchStatus = "未启用"
        case .notFound: launchStatus = "未找到 App 服务"
        @unknown default: launchStatus = "未知状态"
        }
    }

    private func registerLaunchAtLogin() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            diagnosticText = "登录启动注册失败：\(error.localizedDescription)"
        }
        refreshLaunchStatus()
    }

    private func routeNames(for mode: ProxyMode) -> [String] {
        switch mode {
        case .auto: return ["direct", "proxy"]
        case .direct: return ["direct"]
        case .proxy: return ["proxy"]
        }
    }

    func handleAuthorizationChange() {
        permissionStatus = locationManager.authorizationStatus
        if permissionStatus == .authorized {
            NSApp.setActivationPolicy(.accessory)
            requestCheck()
        } else {
            requestCheck()
        }
    }

    func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorizationChange()
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.statusText)
            .lineLimit(3)
        if !model.state.network.isEmpty {
            Text(model.state.network)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Divider()
        Button("立即检查") { model.checkNow() }
        Button("诊断") { model.runDoctor() }
        Button("设置…") { model.openSettingsWindow() }
        if model.permissionStatus != .authorized {
            Button("申请定位权限") { model.requestLocationPermissionIfNeeded() }
            Button("打开定位设置") { model.openLocationSettings() }
        }
        Divider()
        Toggle("登录时自动启动", isOn: Binding(
            get: { model.autoStartEnabled },
            set: { model.setAutoStart($0) }
        ))
        Text("启动：\(model.launchStatus)")
            .font(.caption)
            .foregroundStyle(.secondary)
        Divider()
        Button("退出") { model.quit() }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft: AppConfig
    @State private var prefixText: String
    @State private var timeoutText: String
    @State private var retryAttemptsText: String
    @State private var retryIntervalText: String
    @State private var message = ""

    init(model: AppModel) {
        self.model = model
        let config = model.config
        _draft = State(initialValue: config)
        _prefixText = State(initialValue: config.ipPrefixes.joined(separator: ","))
        _timeoutText = State(initialValue: String(config.timeoutSecs))
        _retryAttemptsText = State(initialValue: String(config.retryAttempts))
        _retryIntervalText = State(initialValue: String(config.retryIntervalSecs))
    }

    var body: some View {
        Form {
            Section("校园网络") {
                TextField("账号", text: $draft.username)
                SecureField("密码", text: $draft.password)
                TextField("SSID（精确匹配）", text: $draft.ssid)
                TextField("认证地址", text: $draft.serverURL)
                TextField("校园 IPv4 前缀（逗号分隔）", text: $prefixText)
                Toggle("自动使用检测到的 IPv4", isOn: $draft.autoDetectIP)
                if !draft.autoDetectIP {
                    TextField("手动认证 IPv4", text: $draft.wlanUserIP)
                }
            }
            Section("连接方式") {
                Picker("代理模式", selection: $draft.proxyMode) {
                    ForEach(ProxyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if draft.proxyMode != .direct {
                    TextField("代理地址", text: $draft.proxyURL)
                }
                Toggle("验证服务器证书", isOn: $draft.verifySSL)
            }
            Section("重试") {
                TextField("单次超时（秒）", text: $timeoutText)
                TextField("重试次数", text: $retryAttemptsText)
                TextField("重试间隔（秒）", text: $retryIntervalText)
            }
            Section {
                HStack {
                    Button("保存") { save() }
                    Button("立即检查") { model.checkNow() }
                    Button("诊断") { model.runDoctor() }
                    Spacer()
                    Toggle("登录时自动启动", isOn: Binding(
                        get: { model.autoStartEnabled },
                        set: { model.setAutoStart($0) }
                    ))
                }
                if !message.isEmpty {
                    Text(message).foregroundStyle(.secondary)
                }
                if !model.diagnosticText.isEmpty {
                    Text(model.diagnosticText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .padding()
        .onAppear { reload() }
    }

    private func reload() {
        draft = model.config
        prefixText = draft.ipPrefixes.joined(separator: ",")
        timeoutText = String(draft.timeoutSecs)
        retryAttemptsText = String(draft.retryAttempts)
        retryIntervalText = String(draft.retryIntervalSecs)
    }

    private func save() {
        draft.ipPrefixes = prefixText
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let timeout = UInt64(timeoutText),
              let attempts = UInt32(retryAttemptsText),
              let interval = UInt64(retryIntervalText) else {
            message = "超时、重试次数和重试间隔必须是数字。"
            return
        }
        draft.timeoutSecs = timeout
        draft.retryAttempts = attempts
        draft.retryIntervalSecs = interval
        guard let error = draft.validationError() else {
            model.saveConfig(draft)
            message = "配置已保存。"
            return
        }
        message = error
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            SelfTest.run()
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--unregister") {
            try? SMAppService.mainApp.unregister()
            NSApp.terminate(nil)
            return
        }
        AppModel.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }
}

enum SelfTest {
    static func run() {
        precondition(!usableIPv4("127.0.0.1"))
        precondition(!usableIPv4("169.254.1.1"))
        precondition(usableIPv4("10.183.0.2"))
        let config = AppConfig(
            username: "account",
            password: "p&密+?#",
            ssid: "CSUST-Student",
            serverURL: "http://127.0.0.1/login",
            ipPrefixes: ["10.183."],
            autoDetectIP: true,
            wlanUserIP: "",
            verifySSL: false,
            proxyMode: .direct,
            proxyURL: "http://127.0.0.1:7890",
            timeoutSecs: 1,
            retryAttempts: 3,
            retryIntervalSecs: 1
        )
        precondition(selectNetwork(config, [
            WiFiNetwork(interfaceName: "en0", ssid: "other", bssid: nil, ip: "10.183.0.2"),
            WiFiNetwork(interfaceName: "en1", ssid: "CSUST-Student", bssid: nil, ip: "10.183.0.2")
        ])?.interfaceName == "en1")
        precondition(selectNetwork(config, [
            WiFiNetwork(interfaceName: "en0", ssid: "csust-student", bssid: nil, ip: nil)
        ]) == nil)
        precondition(parseResponse("dr1003({\"result\":1});") == .online)
        precondition(parseResponse("dr1003({\"msg\":\"密码错误\"});") == .credentials)
        precondition(parseResponse("dr1003({\"msg\":\"10.183.0.2 已经在线！\"});") == .online)
        precondition(config.validationError() == nil)
        httpLogin()
        print("CampusAutoLogin self-test passed")
    }

    private static func httpLogin() {
        let queue = DispatchQueue(label: "com.nowaywastaken.csustautologin.self-test-server")
        let listener = try! NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        let requestDone = DispatchSemaphore(value: 0)
        let requestLock = NSLock()
        var requestText = ""
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                if let data, let text = String(data: data, encoding: .utf8) {
                    requestLock.lock()
                    requestText = text
                    requestLock.unlock()
                }
                let body = Data(#"{"result":1}"#.utf8)
                let header = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: header + body, completion: .contentProcessed { _ in
                    requestDone.signal()
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        precondition(ready.wait(timeout: .now() + 3) == .success)
        let port = listener.port!.rawValue
        var config = AppConfig.default
        config.username = "account"
        config.password = "p&密+?#"
        config.serverURL = "http://127.0.0.1:\(port)/login"
        config.proxyMode = .direct
        let result = LoginService.login(config: config, ip: "10.183.0.2") { true }
        precondition(result.0 == .online)
        precondition(requestDone.wait(timeout: .now() + 3) == .success)
        requestLock.lock()
        let captured = requestText
        requestLock.unlock()
        precondition(captured.contains("user_password=p%26"))
        precondition(captured.contains("wlan_user_ip=10.183.0.2"))
        precondition(!captured.contains("p&密+?#"))
        listener.cancel()
    }
}

@main
struct CampusAutoLoginApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra(appDisplayName, systemImage: "wifi") {
            MenuContent(model: AppModel.shared)
                .padding(8)
        }
        Settings {
            SettingsView(model: AppModel.shared)
        }
    }
}

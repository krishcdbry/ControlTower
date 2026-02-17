import Foundation

/// Fetch Antigravity (Codeium/Windsurf) usage via local language server API.
public struct AntigravityCLIStrategy: ProviderFetchStrategy, Sendable {
    public let id = "antigravity-local"
    public let kind = ProviderFetchKind.cli

    // Process name can be language_server_macos, language_server_macos_arm, or language_server_macos_x64
    private static let processNamePrefix = "language_server_macos"
    private static let getUserStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let commandModelConfigPath = "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"
    private static let unleashPath = "/exa.language_server_pb.LanguageServerService/GetUnleashData"

    public init() {}

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Simple check: just look for the process, don't require full detection
        do {
            let env = ProcessInfo.processInfo.environment
            let result = try await CLIExecutor.run(
                executable: "/bin/ps",
                arguments: ["-ax", "-o", "command="],
                environment: env,
                timeout: 5
            )
            let lower = result.output.lowercased()
            return lower.contains(Self.processNamePrefix) && lower.contains("antigravity")
        } catch {
            return false
        }
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let processInfo = try await Self.detectProcessInfo()
        let ports = try await Self.listeningPorts(pid: processInfo.pid)
        let connectPort = try await Self.findWorkingPort(ports: ports, csrfToken: processInfo.csrfToken)

        let context = RequestContext(
            httpsPort: connectPort,
            httpPort: processInfo.extensionPort,
            csrfToken: processInfo.csrfToken
        )

        // Try GetUserStatus first, fall back to GetCommandModelConfigs
        do {
            let response = try await Self.makeRequest(
                path: Self.getUserStatusPath,
                body: Self.defaultRequestBody(),
                context: context
            )
            let snapshot = try Self.parseUserStatusResponse(response)
            return makeResult(usage: snapshot, sourceLabel: "local")
        } catch {
            let response = try await Self.makeRequest(
                path: Self.commandModelConfigPath,
                body: Self.defaultRequestBody(),
                context: context
            )
            let snapshot = try Self.parseCommandModelResponse(response)
            return makeResult(usage: snapshot, sourceLabel: "local")
        }
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        false
    }

    // MARK: - Process Detection

    private struct ProcessInfoResult: Sendable {
        let pid: Int
        let extensionPort: Int?
        let csrfToken: String
    }

    public static func isRunning() async -> Bool {
        (try? await detectProcessInfo()) != nil
    }

    private static func detectProcessInfo() async throws -> ProcessInfoResult {
        let env = ProcessInfo.processInfo.environment
        let result = try await CLIExecutor.run(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="],
            environment: env,
            timeout: 8
        )

        let lines = result.output.split(separator: "\n")
        var sawAntigravity = false

        for line in lines {
            let text = String(line)
            guard let match = matchProcessLine(text) else { continue }
            let lower = match.command.lowercased()
            guard lower.contains(processNamePrefix) else { continue }
            guard isAntigravityCommandLine(lower) else { continue }
            sawAntigravity = true
            guard let token = extractFlag("--csrf_token", from: match.command) else { continue }
            let port = extractPort("--extension_server_port", from: match.command)
            return ProcessInfoResult(pid: match.pid, extensionPort: port, csrfToken: token)
        }

        if sawAntigravity {
            throw AntigravityError.missingCSRFToken
        }
        throw AntigravityError.notRunning
    }

    private struct ProcessLineMatch {
        let pid: Int
        let command: String
    }

    private static func matchProcessLine(_ line: String) -> ProcessLineMatch? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
        return ProcessLineMatch(pid: pid, command: String(parts[1]))
    }

    private static func isAntigravityCommandLine(_ command: String) -> Bool {
        if command.contains("--app_data_dir") && command.contains("antigravity") { return true }
        if command.contains("/antigravity/") || command.contains("\\antigravity\\") { return true }
        return false
    }

    private static func extractFlag(_ flag: String, from command: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: flag))[=\\s]+([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, options: [], range: range),
              let tokenRange = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[tokenRange])
    }

    private static func extractPort(_ flag: String, from command: String) -> Int? {
        guard let raw = extractFlag(flag, from: command) else { return nil }
        return Int(raw)
    }

    // MARK: - Port Detection

    private static func listeningPorts(pid: Int) async throws -> [Int] {
        let lsofPaths = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        guard let lsof = lsofPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AntigravityError.portDetectionFailed("lsof not available")
        }

        let env = ProcessInfo.processInfo.environment
        let result = try await CLIExecutor.run(
            executable: lsof,
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)],
            environment: env,
            timeout: 8
        )

        let ports = parseListeningPorts(result.output)
        if ports.isEmpty {
            throw AntigravityError.portDetectionFailed("no listening ports found")
        }
        return ports
    }

    private static func parseListeningPorts(_ output: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #":(\d+)\s+\(LISTEN\)"#) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var ports: Set<Int> = []
        regex.enumerateMatches(in: output, options: [], range: range) { match, _, _ in
            guard let match,
                  let range = Range(match.range(at: 1), in: output),
                  let value = Int(output[range]) else { return }
            ports.insert(value)
        }
        return ports.sorted()
    }

    private static func findWorkingPort(ports: [Int], csrfToken: String) async throws -> Int {
        // Try each port with GetUserStatus to find a working one
        for port in ports {
            let ok = await testPortConnectivity(port: port, csrfToken: csrfToken)
            if ok { return port }
        }
        throw AntigravityError.portDetectionFailed("no working API port found")
    }

    private static func testPortConnectivity(port: Int, csrfToken: String) async -> Bool {
        // Test with GetUserStatus which is more reliable than GetUnleashData
        do {
            _ = try await sendRequest(
                scheme: "https",
                port: port,
                path: getUserStatusPath,
                body: defaultRequestBody(),
                csrfToken: csrfToken
            )
            return true
        } catch {
            // Also try HTTP as fallback
            do {
                _ = try await sendRequest(
                    scheme: "http",
                    port: port,
                    path: getUserStatusPath,
                    body: defaultRequestBody(),
                    csrfToken: csrfToken
                )
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - HTTP Requests

    private struct RequestContext: Sendable {
        let httpsPort: Int
        let httpPort: Int?
        let csrfToken: String
    }

    private static func defaultRequestBody() -> [String: Any] {
        [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "ideVersion": "unknown",
                "locale": "en",
            ]
        ]
    }

    private static func unleashRequestBody() -> [String: Any] {
        [
            "context": [
                "properties": [
                    "devMode": "false",
                    "extensionVersion": "unknown",
                    "hasAnthropicModelAccess": "true",
                    "ide": "antigravity",
                    "ideVersion": "unknown",
                    "installationId": "controltower",
                    "language": "UNSPECIFIED",
                    "os": "macos",
                    "requestedModelId": "MODEL_UNSPECIFIED",
                ]
            ]
        ]
    }

    private static func makeRequest(path: String, body: [String: Any], context: RequestContext) async throws -> Data {
        // Try HTTPS first
        do {
            return try await sendRequest(scheme: "https", port: context.httpsPort, path: path, body: body, csrfToken: context.csrfToken)
        } catch {
            // Fall back to HTTP if available
            guard let httpPort = context.httpPort, httpPort != context.httpsPort else { throw error }
            return try await sendRequest(scheme: "http", port: httpPort, path: path, body: body, csrfToken: context.csrfToken)
        }
    }

    private static func sendRequest(scheme: String, port: Int, path: String, body: [String: Any], csrfToken: String) async throws -> Data {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else {
            throw AntigravityError.apiError("Invalid URL")
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(bodyData.count), forHTTPHeaderField: "Content-Length")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config, delegate: InsecureSessionDelegate.shared, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityError.apiError("Invalid response")
        }
        guard http.statusCode == 200 else {
            throw AntigravityError.apiError("HTTP \(http.statusCode)")
        }
        return data
    }

    // MARK: - Response Parsing

    private static func parseUserStatusResponse(_ data: Data) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        let response = try decoder.decode(UserStatusResponse.self, from: data)

        if let code = response.code, !code.isOK {
            throw AntigravityError.apiError(code.rawValue)
        }

        guard let userStatus = response.userStatus else {
            throw AntigravityError.parseFailed("Missing userStatus")
        }

        let modelConfigs = userStatus.cascadeModelConfigData?.clientModelConfigs ?? []
        let models = modelConfigs.compactMap(quotaFromConfig)
        let email = userStatus.email
        let planName = userStatus.planStatus?.planInfo?.preferredName

        return buildSnapshot(models: models, email: email, plan: planName)
    }

    private static func parseCommandModelResponse(_ data: Data) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        let response = try decoder.decode(CommandModelConfigResponse.self, from: data)

        if let code = response.code, !code.isOK {
            throw AntigravityError.apiError(code.rawValue)
        }

        let modelConfigs = response.clientModelConfigs ?? []
        let models = modelConfigs.compactMap(quotaFromConfig)
        return buildSnapshot(models: models, email: nil, plan: nil)
    }

    private static func quotaFromConfig(_ config: ModelConfig) -> ModelQuota? {
        guard let quota = config.quotaInfo else { return nil }
        let reset = quota.resetTime.flatMap(parseDate)
        return ModelQuota(
            label: config.label,
            modelId: config.modelOrAlias.model,
            remainingFraction: quota.remainingFraction,
            resetTime: reset
        )
    }

    private static func buildSnapshot(models: [ModelQuota], email: String?, plan: String?) -> UsageSnapshot {
        let ordered = selectModels(models)

        let primary: RateWindow
        if let firstQuota = ordered.first {
            primary = RateWindow(
                usedPercent: 100 - firstQuota.remainingPercent,
                resetsAt: firstQuota.resetTime,
                label: firstQuota.label
            )
        } else {
            primary = RateWindow(usedPercent: 0, label: "No quotas")
        }

        let secondary = ordered.count > 1 ? RateWindow(
            usedPercent: 100 - ordered[1].remainingPercent,
            resetsAt: ordered[1].resetTime,
            label: ordered[1].label
        ) : nil

        let tertiary = ordered.count > 2 ? RateWindow(
            usedPercent: 100 - ordered[2].remainingPercent,
            resetsAt: ordered[2].resetTime,
            label: ordered[2].label
        ) : nil

        return UsageSnapshot(
            providerID: .antigravity,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            updatedAt: Date(),
            identity: ProviderIdentity(email: email, plan: plan, authMethod: "local")
        )
    }

    private static func selectModels(_ models: [ModelQuota]) -> [ModelQuota] {
        var ordered: [ModelQuota] = []

        // Prioritize Claude (without thinking), Gemini Pro, Gemini Flash
        if let claude = models.first(where: { isClaudeWithoutThinking($0.label) }) {
            ordered.append(claude)
        }
        if let pro = models.first(where: { isGeminiProLow($0.label) }),
           !ordered.contains(where: { $0.label == pro.label }) {
            ordered.append(pro)
        }
        if let flash = models.first(where: { isGeminiFlash($0.label) }),
           !ordered.contains(where: { $0.label == flash.label }) {
            ordered.append(flash)
        }

        if ordered.isEmpty {
            ordered.append(contentsOf: models.sorted(by: { $0.remainingPercent < $1.remainingPercent }))
        }
        return ordered
    }

    private static func isClaudeWithoutThinking(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.contains("claude") && !lower.contains("thinking")
    }

    private static func isGeminiProLow(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.contains("pro") && lower.contains("low")
    }

    private static func isGeminiFlash(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.contains("gemini") && lower.contains("flash")
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        if let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

// MARK: - Model Quota

private struct ModelQuota: Sendable {
    let label: String
    let modelId: String
    let remainingFraction: Double?
    let resetTime: Date?

    var remainingPercent: Double {
        guard let remainingFraction else { return 0 }
        return max(0, min(100, remainingFraction * 100))
    }
}

// MARK: - Errors

public enum AntigravityError: LocalizedError, Sendable {
    case notRunning
    case missingCSRFToken
    case portDetectionFailed(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Antigravity not detected. Launch Antigravity and retry."
        case .missingCSRFToken:
            return "Antigravity CSRF token not found. Restart the app and retry."
        case .portDetectionFailed(let message):
            return "Port detection failed: \(message)"
        case .apiError(let message):
            return "API error: \(message)"
        case .parseFailed(let message):
            return "Parse failed: \(message)"
        }
    }
}

// MARK: - Response Types

private struct UserStatusResponse: Decodable {
    let code: CodeValue?
    let message: String?
    let userStatus: UserStatus?
}

private struct CommandModelConfigResponse: Decodable {
    let code: CodeValue?
    let message: String?
    let clientModelConfigs: [ModelConfig]?
}

private struct UserStatus: Decodable {
    let email: String?
    let planStatus: PlanStatus?
    let cascadeModelConfigData: ModelConfigData?
}

private struct PlanStatus: Decodable {
    let planInfo: PlanInfo?
}

private struct PlanInfo: Decodable {
    let planName: String?
    let planDisplayName: String?
    let displayName: String?
    let productName: String?
    let planShortName: String?

    var preferredName: String? {
        [planDisplayName, displayName, productName, planName, planShortName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

private struct ModelConfigData: Decodable {
    let clientModelConfigs: [ModelConfig]?
}

private struct ModelConfig: Decodable {
    let label: String
    let modelOrAlias: ModelAlias
    let quotaInfo: QuotaInfo?
}

private struct ModelAlias: Decodable {
    let model: String
}

private struct QuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
}

private enum CodeValue: Decodable {
    case int(Int)
    case string(String)

    var isOK: Bool {
        switch self {
        case .int(let value): return value == 0
        case .string(let value):
            let lower = value.lowercased()
            return lower == "ok" || lower == "success" || value == "0"
        }
    }

    var rawValue: String {
        switch self {
        case .int(let value): return "\(value)"
        case .string(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported code type")
    }
}

// MARK: - Insecure Session Delegate

private final class InsecureSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = InsecureSessionDelegate()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

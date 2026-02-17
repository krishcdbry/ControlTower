import Foundation
import CommonCrypto
import Security

/// Chromium cookie extractor with proper decryption.
public final class BrowserCookieClient: @unchecked Sendable {
    public init() {}

    /// Cookie record from browser database
    public struct CookieRecord: Sendable {
        public let name: String
        public let value: String
        public let domain: String
        public let path: String
        public let expiresAt: Date?
        public let isSecure: Bool
        public let isHttpOnly: Bool
    }

    /// Source of cookies (browser + profile)
    public struct CookieSource: Sendable {
        public let label: String
        public let records: [CookieRecord]
    }

    /// Query for cookies
    public struct CookieQuery {
        public let domains: [String]
        public let names: Set<String>?

        public init(domains: [String], names: Set<String>? = nil) {
            self.domains = domains
            self.names = names
        }

        public var origin: String {
            domains.first ?? ""
        }
    }

    /// Extract cookies matching query from browser
    public func records(
        matching query: CookieQuery,
        in browser: Browser,
        logger: ((String) -> Void)? = nil
    ) throws -> [CookieSource] {
        guard browser.isChromiumBased else {
            throw CookieError.unsupportedBrowser("\(browser.displayName) is not Chromium-based")
        }

        guard let dbPath = browser.cookiePath else {
            throw CookieError.browserNotFound(browser.rawValue)
        }

        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            throw CookieError.browserNotFound(browser.rawValue)
        }

        // Get encryption key from Keychain
        let encryptionKey: Data
        do {
            encryptionKey = try getEncryptionKey(for: browser)
        } catch {
            logger?("Failed to get encryption key: \(error)")
            throw error
        }

        // Copy database to temp (browser might have it locked)
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookies_\(UUID().uuidString).db")

        defer {
            try? FileManager.default.removeItem(at: tempPath)
        }

        do {
            try FileManager.default.copyItem(at: dbPath, to: tempPath)
        } catch {
            throw CookieError.accessDenied("Cannot access cookie database. Grant Full Disk Access in System Settings.")
        }

        // Query cookies
        let records = try queryCookies(
            at: tempPath,
            domains: query.domains,
            names: query.names,
            encryptionKey: encryptionKey,
            logger: logger
        )

        return [CookieSource(label: browser.displayName, records: records)]
    }

    /// Convert records to HTTPCookie objects
    public static func makeHTTPCookies(_ records: [CookieRecord], origin: String) -> [HTTPCookie] {
        records.compactMap { record in
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: record.name,
                .value: record.value,
                .domain: record.domain,
                .path: record.path,
            ]

            if let expires = record.expiresAt {
                properties[.expires] = expires
            }
            if record.isSecure {
                properties[.secure] = true
            }

            return HTTPCookie(properties: properties)
        }
    }

    // MARK: - Private

    private func getEncryptionKey(for browser: Browser) throws -> Data {
        let service = browser.keychainService
        guard !service.isEmpty else {
            throw CookieError.unsupportedBrowser("No keychain service for \(browser.displayName)")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let passwordData = result as? Data else {
            throw CookieError.accessDenied("Cannot access \(service) in Keychain (status: \(status))")
        }

        // Derive key using PBKDF2
        // Chromium uses: password from keychain, salt "saltysalt", 1003 iterations, 16 byte key
        return try deriveKey(password: passwordData, salt: "saltysalt", iterations: 1003, keyLength: 16)
    }

    private func deriveKey(password: Data, salt: String, iterations: Int, keyLength: Int) throws -> Data {
        var derivedKey = Data(count: keyLength)
        let saltData = salt.data(using: .utf8)!

        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            saltData.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(iterations),
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }

        guard result == kCCSuccess else {
            throw CookieError.decryptionFailed("Key derivation failed")
        }

        return derivedKey
    }

    private func queryCookies(
        at dbPath: URL,
        domains: [String],
        names: Set<String>?,
        encryptionKey: Data,
        logger: ((String) -> Void)?
    ) throws -> [CookieRecord] {
        // Build domain filter
        let domainConditions = domains.map { "host_key LIKE '%\($0)%'" }.joined(separator: " OR ")

        // Query using sqlite3 - use hex() to properly read BLOB data
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            dbPath.path,
            "-separator", "|||",
            """
            SELECT name, hex(encrypted_value), host_key, path, expires_utc, is_secure, is_httponly
            FROM cookies
            WHERE (\(domainConditions))
            ORDER BY creation_utc DESC;
            """
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            logger?("Failed to read sqlite output")
            return []
        }

        var records: [CookieRecord] = []

        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "|||")
            guard parts.count >= 7 else {
                logger?("Invalid line format: \(parts.count) parts")
                continue
            }

            let name = parts[0]

            // Filter by name if specified
            if let names = names, !names.contains(name) {
                continue
            }

            // The encrypted_value is now a hex string from hex() function
            let encryptedHex = parts[1]
            let domain = parts[2]
            let path = parts[3]
            let expiresUtc = Int64(parts[4]) ?? 0
            let isSecure = parts[5] == "1"
            let isHttpOnly = parts[6] == "1"

            // Decrypt the value
            let decryptedValue: String
            if encryptedHex.isEmpty {
                decryptedValue = ""
            } else if let hexData = Data(hexString: encryptedHex) {
                do {
                    decryptedValue = try decryptCookieValue(hexData, key: encryptionKey)
                    logger?("Decrypted cookie \(name): \(decryptedValue.prefix(20))...")
                } catch {
                    logger?("Failed to decrypt cookie \(name): \(error)")
                    continue
                }
            } else {
                logger?("Failed to parse hex for cookie \(name)")
                // Maybe it's a plain value
                decryptedValue = encryptedHex
            }

            // Convert Chrome timestamp (microseconds since Jan 1, 1601) to Date
            let expiresAt: Date?
            if expiresUtc > 0 {
                // Chrome epoch is Jan 1, 1601. Unix epoch is Jan 1, 1970.
                // Difference is 11644473600 seconds
                let unixTimestamp = (Double(expiresUtc) / 1_000_000.0) - 11644473600.0
                expiresAt = Date(timeIntervalSince1970: unixTimestamp)
            } else {
                expiresAt = nil
            }

            records.append(CookieRecord(
                name: name,
                value: decryptedValue,
                domain: domain,
                path: path,
                expiresAt: expiresAt,
                isSecure: isSecure,
                isHttpOnly: isHttpOnly
            ))
        }

        logger?("Found \(records.count) cookie records")
        return records
    }

    private func decryptCookieValue(_ encryptedData: Data, key: Data) throws -> String {
        // Chromium encrypted cookies start with "v10" or "v11"
        guard encryptedData.count > 3 else {
            // Might be unencrypted
            return String(data: encryptedData, encoding: .utf8) ?? ""
        }

        let prefix = String(data: encryptedData.prefix(3), encoding: .utf8) ?? ""

        if prefix == "v10" || prefix == "v11" {
            // macOS Chrome uses AES-128-CBC but the decrypted output has some quirks
            // Format: v10/v11 + 12 byte nonce + ciphertext + 16 byte tag (for GCM)
            // OR: v10/v11 + 16 byte IV + ciphertext (for CBC)
            let payload = encryptedData.dropFirst(3)
            guard payload.count > 16 else {
                throw CookieError.decryptionFailed("Encrypted data too short")
            }

            // Try AES-128-CBC first (older Chrome)
            let iv = Data(payload.prefix(16))
            let ciphertext = Data(payload.dropFirst(16))

            let decrypted = try decryptAES128CBC(ciphertext: ciphertext, key: key, iv: iv)

            // Chrome's decrypted cookies sometimes have garbage prefix from CBC mode
            // Find the actual start of the cookie value (look for printable ASCII)
            if let cleanValue = extractCleanValue(from: decrypted) {
                return cleanValue
            }

            // Fallback: try to convert raw decrypted data to string
            return String(data: decrypted, encoding: .utf8) ?? ""
        } else {
            // Unencrypted or unknown format
            return String(data: encryptedData, encoding: .utf8) ?? ""
        }
    }

    /// Extract clean cookie value from decrypted data (handles CBC padding artifacts)
    private func extractCleanValue(from data: Data) -> String? {
        // Chrome CBC decryption has garbage in first 16 bytes (IV block artifact)
        // The actual cookie value starts at offset 16

        // Method 1: Try full data as UTF-8 (unencrypted or clean decryption)
        if let str = String(data: data, encoding: .utf8), !str.isEmpty {
            if let first = str.first, first.isLetter || first.isNumber || first == "_" {
                return str
            }
        }

        // Method 2: Skip first 16 bytes and extract printable ASCII
        // This handles the CBC garbage block at the start
        guard data.count > 16 else { return nil }

        let payload = Data(data.dropFirst(16))

        // Find contiguous printable ASCII from the start of payload
        var endIndex = 0
        for (idx, byte) in payload.enumerated() {
            if byte >= 32 && byte < 127 {
                endIndex = idx + 1
            } else {
                // Stop at first non-printable character
                break
            }
        }

        // If we found a reasonable length of printable content
        if endIndex > 10 {
            let printableSlice = payload.prefix(endIndex)
            if let str = String(data: Data(printableSlice), encoding: .utf8), !str.isEmpty {
                return str
            }
        }

        // Method 3: Fallback - extract all printable ASCII from payload (skip first 16 bytes)
        let printable = payload.filter { $0 >= 32 && $0 < 127 }
        if let str = String(data: Data(printable), encoding: .utf8), str.count > 10 {
            return str
        }

        return nil
    }

    private func decryptAES128CBC(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        let bufferSize = ciphertext.count + kCCBlockSizeAES128
        var decrypted = Data(count: bufferSize)
        var decryptedLength: size_t = 0

        let status = ciphertext.withUnsafeBytes { ciphertextBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    decrypted.withUnsafeMutableBytes { decryptedBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            ciphertextBytes.baseAddress, ciphertext.count,
                            decryptedBytes.baseAddress, bufferSize,
                            &decryptedLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw CookieError.decryptionFailed("AES decryption failed (status: \(status))")
        }

        decrypted.count = decryptedLength
        return decrypted
    }
}

/// Shorthand for queries
public struct BrowserCookieQuery {
    public let domains: [String]
    public let names: Set<String>?

    public init(domains: [String], names: Set<String>? = nil) {
        self.domains = domains
        self.names = names
    }

    public var origin: String {
        domains.first ?? ""
    }
}

// MARK: - Errors

public enum CookieError: LocalizedError, Sendable {
    case browserNotFound(String)
    case accessDenied(String)
    case unsupportedBrowser(String)
    case cookieNotFound(String)
    case decryptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .browserNotFound(let browser):
            return "\(browser) not found"
        case .accessDenied(let message):
            return "Access denied: \(message)"
        case .unsupportedBrowser(let message):
            return "Unsupported browser: \(message)"
        case .cookieNotFound(let cookie):
            return "Cookie not found: \(cookie)"
        case .decryptionFailed(let message):
            return "Decryption failed: \(message)"
        }
    }
}

// MARK: - Data Extension

private extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}

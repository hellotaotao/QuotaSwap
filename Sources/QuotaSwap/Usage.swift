import CommonCrypto
import Foundation
import Security
import SQLite3

/// Decrypts values Electron's safeStorage wrote on macOS: a "v10" prefix, then
/// AES-128-CBC with a key derived from the "Claude Safe Storage" keychain item.
enum SafeStorage {
    private static let lock = NSLock()
    private static var cachedKey: Data?

    /// Reads the keychain once per launch; macOS asks the user the first time.
    static func key() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        let key = deriveKey(password: try password())
        cachedKey = key
        return key
    }

    private static func password() throws -> Data {
        if !Env.manageApp, let fake = Env.vars["QUOTASWAP_SAFE_STORAGE_PASSWORD"] {
            return Data(fake.utf8)  // tests against a fake Claude directory
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw QSError(status == errSecUserCanceled || status == errSecAuthFailed
                ? "Keychain access to Claude Safe Storage was denied"
                : "Cannot read Claude Safe Storage from the keychain (\(status))")
        }
        return data
    }

    static func deriveKey(password: Data) -> Data {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = [UInt8]("saltysalt".utf8)
        let pass = password.map { CChar(bitPattern: $0) }
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass, pass.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        return Data(key)
    }

    static func isV10(_ blob: Data) -> Bool { blob.starts(with: Data("v10".utf8)) }

    static func decrypt(_ blob: Data, key: Data) throws -> Data {
        guard isV10(blob) else { throw QSError("Unexpected encryption format (not v10)") }
        let cipher = [UInt8](blob.dropFirst(3))
        let keyBytes = [UInt8](key)
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             keyBytes, keyBytes.count, iv, cipher, cipher.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw QSError("Decryption failed") }
        return Data(out.prefix(moved))
    }

    static func decryptCookie(_ blob: Data, host: String, key: Data) throws -> String {
        var plain = try decrypt(blob, key: key)
        // Newer Chromium prefixes cookie plaintext with sha256(host_key).
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let hostBytes = [UInt8](host.utf8)
        CC_SHA256(hostBytes, CC_LONG(hostBytes.count), &digest)
        if plain.count >= digest.count, plain.prefix(digest.count) == Data(digest) {
            plain = Data(plain.dropFirst(digest.count))
        }
        guard let value = String(data: plain, encoding: .utf8) else { throw QSError("Cookie is not text") }
        return value
    }
}

enum CookieDB {
    struct Row {
        let host: String
        let name: String
        let value: Data
    }

    private static func open(_ path: String) throws -> OpaquePointer {
        guard FS.exists(path) else { throw QSError("Cookie database not found") }
        // immutable=1: read without locks, so the running Claude app is never blocked.
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var db: OpaquePointer?
        let rc = sqlite3_open_v2("file:\(encoded)?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw QSError("Cannot open cookie database (\(rc))")
        }
        return db
    }

    private static func query(_ path: String, _ sql: String, _ row: (OpaquePointer) -> Void) throws {
        let db = try open(path)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw QSError("Cookie database query failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    static func columns(_ path: String) throws -> [String] {
        var names: [String] = []
        try query(path, "PRAGMA table_info(cookies)") { stmt in
            if let text = sqlite3_column_text(stmt, 1) { names.append(String(cString: text)) }
        }
        return names
    }

    static func claudeRows(_ path: String) throws -> [Row] {
        var rows: [Row] = []
        let sql = "SELECT host_key, name, encrypted_value FROM cookies WHERE host_key IN ('.claude.ai', 'claude.ai')"
        try query(path, sql) { stmt in
            guard let host = sqlite3_column_text(stmt, 0), let name = sqlite3_column_text(stmt, 1) else { return }
            let count = Int(sqlite3_column_bytes(stmt, 2))
            let value = count > 0 ? Data(bytes: sqlite3_column_blob(stmt, 2), count: count) : Data()
            rows.append(Row(host: String(cString: host), name: String(cString: name), value: value))
        }
        return rows
    }
}

struct UsageWindow {
    let utilization: Double?
    let resetsAt: Date?
}

struct Usage {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let fetchedAt: Date
}

/// Reads an account's 5-hour and weekly usage from claude.ai with its saved
/// sessionKey cookie. Unlike the OAuth route this never refreshes or rotates
/// any credential, so snapshots stay valid.
enum UsageClient {
    static func credentials(for profile: Profile, current: Bool) throws -> (sessionKey: String, org: String) {
        let key = try SafeStorage.key()
        let path = current ? Env.cookies : profile.dir + "/Cookies"
        var jar: [String: String] = [:]
        for row in try CookieDB.claudeRows(path) where row.name == "sessionKey" || row.name == "lastActiveOrg" {
            if let value = try? SafeStorage.decryptCookie(row.value, host: row.host, key: key) { jar[row.name] = value }
        }
        guard let sessionKey = jar["sessionKey"], !sessionKey.isEmpty else { throw QSError("No saved claude.ai session") }
        guard let org = jar["lastActiveOrg"], isUUID(org) else { throw QSError("No saved organization id") }
        return (sessionKey, org)
    }

    static func fetch(for profile: Profile, current: Bool) async throws -> Usage {
        let creds = try credentials(for: profile, current: current)
        var request = URLRequest(url: URL(string: "https://claude.ai/api/organizations/\(creds.org)/usage")!)
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("sessionKey=\(creds.sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QSError("Network error: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = String(decoding: data.prefix(2000), as: UTF8.self)
            if body.contains("Just a moment") || body.contains("cf-chl") {
                throw QSError("Blocked by Cloudflare (HTTP \(status))")
            }
            if status == 401 || status == 403 {
                throw QSError("Saved session expired (HTTP \(status)); switch to this account once to refresh it")
            }
            throw QSError("Usage request failed (HTTP \(status))")
        }
        return try parse(data)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> Usage {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QSError("Usage response format changed: not a JSON object")
        }
        func window(_ key: String) throws -> UsageWindow? {
            guard obj.keys.contains(key) else { throw QSError("Usage response format changed: no \(key)") }
            guard let value = obj[key], !(value is NSNull) else { return nil }
            guard let dict = value as? [String: Any], dict.keys.contains("utilization") else {
                throw QSError("Usage response format changed: \(key) has no utilization")
            }
            return UsageWindow(utilization: number(dict["utilization"]), resetsAt: parseDate(dict["resets_at"] as? String))
        }
        return Usage(fiveHour: try window("five_hour"), sevenDay: try window("seven_day"), fetchedAt: now)
    }

    static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}

/// "4h 52m", "2d 3h", "12m"
func shortDuration(until date: Date?, now: Date = Date()) -> String? {
    guard let date else { return nil }
    let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
    if minutes >= 24 * 60 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
    if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
    return "\(minutes)m"
}

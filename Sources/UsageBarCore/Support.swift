import Foundation

enum HTTP {
    static func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.badResponse(-1, "No HTTP response")
        }
        return (data, http)
    }

    static func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, http) = try await data(for: request)
        try throwIfFailed(http, data: data)
        return data
    }

    static func postJSON(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await data(for: request)
        try throwIfFailed(http, data: data)
        return data
    }

    static func postForm(_ url: URL, headers: [String: String], fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, http) = try await data(for: request)
        try throwIfFailed(http, data: data)
        return data
    }

    static func throwIfFailed(_ http: HTTPURLResponse, data: Data) throws {
        if http.statusCode == 401 || http.statusCode == 403 {
            throw FetchError.unauthorized
        }
        if http.statusCode == 429 {
            throw FetchError.rateLimited
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw FetchError.badResponse(http.statusCode, String(snippet.prefix(180)))
        }
    }
}

enum FetchError: LocalizedError, Equatable {
    case unauthorized
    case missingAuth(String)
    case rateLimited
    case badResponse(Int, String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Auth rejected. Re-login in the CLI."
        case .missingAuth(let message):
            return message
        case .rateLimited:
            return "Rate limited. Try again later."
        case .badResponse(let code, let body):
            if code == 429 {
                return "Rate limited. Try again later."
            }
            return body.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(body)"
        case .decodeFailed(let message):
            return message
        }
    }

    var isTransient: Bool {
        switch self {
        case .rateLimited:
            return true
        case .badResponse(let code, _):
            return code == 429 || (500...599).contains(code) || code < 0
        case .unauthorized, .missingAuth, .decodeFailed:
            return false
        }
    }
}

enum ISODates {
    static let internet: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return fractional.date(from: raw) ?? internet.date(from: raw)
    }

    static func formatFractional(_ date: Date) -> String {
        fractional.string(from: date)
    }
}

enum FileAtom {
    static func write(_ data: Data, to url: URL, mode: Int16 = 0o600) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: temp.path
        )
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
    }
}

enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        if pad > 0 { b64.append(String(repeating: "=", count: pad)) }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    static func expiresAt(_ token: String) -> Date? {
        guard let exp = payload(token)?["exp"] else { return nil }
        if let n = exp as? TimeInterval { return Date(timeIntervalSince1970: n) }
        if let n = exp as? Int { return Date(timeIntervalSince1970: TimeInterval(n)) }
        return nil
    }
}

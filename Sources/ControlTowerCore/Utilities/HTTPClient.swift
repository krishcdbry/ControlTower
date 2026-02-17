import Foundation

/// Simple HTTP client for provider API calls.
public enum HTTPClient {
    /// Perform a GET request with optional headers.
    public static func get(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = 30
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }

        return (data, httpResponse)
    }

    /// Perform a POST request with JSON body.
    public static func post(
        url: URL,
        body: [String: Any],
        headers: [String: String] = [:],
        timeout: TimeInterval = 30
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPError.invalidResponse
        }

        return (data, httpResponse)
    }
}

/// HTTP errors.
public enum HTTPError: LocalizedError, Sendable {
    case invalidResponse
    case httpError(Int, String?)
    case decodingError(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid HTTP response"
        case .httpError(let code, let message):
            return "HTTP \(code): \(message ?? "Unknown error")"
        case .decodingError(let message):
            return "Decoding error: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

import Foundation
#if os(macOS)
import AppKit
#endif

struct TokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

struct StoredTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

class OAuth2Manager {
    private let clientID: String
    private let clientSecret: String
    private let redirectURI = "http://localhost:8080/callback"
    private let scope = "https://www.googleapis.com/auth/calendar"
    private let tokenFile = "tokens.json"

    private var storedTokens: StoredTokens?
    private var httpServer: SimpleHTTPServer?

    init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        loadTokens()
    }

    // MARK: - Token Management

    func getAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
        // Check if we have valid tokens
        if let tokens = storedTokens, tokens.expiresAt > Date() {
            completion(.success(tokens.accessToken))
            return
        }

        // Check if we can refresh
        if let tokens = storedTokens {
            print("Access token expired, refreshing...")
            refreshAccessToken(refreshToken: tokens.refreshToken, completion: completion)
            return
        }

        // Need to authenticate
        print("No valid tokens found, starting OAuth flow...")
        startOAuthFlow(completion: completion)
    }

    private func startOAuthFlow(completion: @escaping (Result<String, Error>) -> Void) {
        // Start local HTTP server
        httpServer = SimpleHTTPServer(port: 8080)

        httpServer?.onCodeReceived = { [weak self] code in
            guard let self = self else { return }
            self.exchangeCodeForTokens(code: code, completion: completion)
        }

        httpServer?.onServerReady = { [weak self] in
            guard let self = self else { return }

            // Open browser for authentication after server is ready
            let authURL = self.buildAuthURL()
            print("\nOpening browser for Google authentication...")
            print("URL: \(authURL)")

            #if os(macOS)
            if let url = URL(string: authURL) {
                NSWorkspace.shared.open(url)
            }
            #endif
        }

        do {
            try httpServer?.start()
        } catch {
            completion(.failure(error))
        }
    }

    private func buildAuthURL() -> String {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components.url!.absoluteString
    }

    private func exchangeCodeForTokens(code: String, completion: @escaping (Result<String, Error>) -> Void) {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]

        request.httpBody = params.percentEncoded()

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "OAuth2Manager", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "No data received"
                ])))
                return
            }

            do {
                let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

                guard let refreshToken = tokenResponse.refreshToken else {
                    completion(.failure(NSError(domain: "OAuth2Manager", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "No refresh token received"
                    ])))
                    return
                }

                let expiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
                let tokens = StoredTokens(
                    accessToken: tokenResponse.accessToken,
                    refreshToken: refreshToken,
                    expiresAt: expiresAt
                )

                self.storedTokens = tokens
                self.saveTokens(tokens)

                print("✓ Authentication successful!")
                print("Tokens saved to \(self.tokenFile)")

                completion(.success(tokenResponse.accessToken))
            } catch {
                print("Failed to decode token response: \(error)")
                if let json = String(data: data, encoding: .utf8) {
                    print("Response: \(json)")
                }
                completion(.failure(error))
            }
        }
        task.resume()
    }

    private func refreshAccessToken(refreshToken: String, completion: @escaping (Result<String, Error>) -> Void) {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "refresh_token"
        ]

        request.httpBody = params.percentEncoded()

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "OAuth2Manager", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "No data received"
                ])))
                return
            }

            do {
                let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
                let expiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))

                var tokens = self.storedTokens!
                tokens.accessToken = tokenResponse.accessToken
                tokens.expiresAt = expiresAt

                self.storedTokens = tokens
                self.saveTokens(tokens)

                print("✓ Access token refreshed")
                completion(.success(tokenResponse.accessToken))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    // MARK: - Token Storage

    private func loadTokens() {
        let fileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(tokenFile)

        guard let data = try? Data(contentsOf: fileURL) else {
            return
        }

        storedTokens = try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    private func saveTokens(_ tokens: StoredTokens) {
        let fileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(tokenFile)

        if let data = try? JSONEncoder().encode(tokens) {
            try? data.write(to: fileURL)
        }
    }
}

// MARK: - Simple HTTP Server

class SimpleHTTPServer {
    private let port: UInt16
    private var socketFileDescriptor: Int32?
    var onCodeReceived: ((String) -> Void)?
    var onServerReady: (() -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw NSError(domain: "SimpleHTTPServer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create socket"
            ])
        }

        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, UInt32(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult >= 0 else {
            close(socket)
            throw NSError(domain: "SimpleHTTPServer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to bind socket to port \(port)"
            ])
        }

        listen(socket, 5)
        socketFileDescriptor = socket

        print("HTTP server listening on port \(port)...")

        // Notify that server is ready
        DispatchQueue.main.async { [weak self] in
            self?.onServerReady?()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptConnections()
        }
    }

    private func acceptConnections() {
        guard let socket = socketFileDescriptor else { return }

        while true {
            let clientSocket = accept(socket, nil, nil)
            guard clientSocket >= 0 else { continue }

            handleClient(socket: clientSocket)
        }
    }

    private func handleClient(socket: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(socket, &buffer, buffer.count)

        guard bytesRead > 0 else {
            close(socket)
            return
        }

        let request = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

        // Parse code from request
        if let code = extractCode(from: request) {
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html\r
            \r
            <html><body><h1>Authentication Successful!</h1><p>You can close this window.</p></body></html>
            """

            response.data(using: .utf8)?.withUnsafeBytes {
                write(socket, $0.baseAddress, response.count)
            }

            onCodeReceived?(code)

            // Stop server
            if let socketFD = socketFileDescriptor {
                close(socketFD)
                socketFileDescriptor = nil
            }
        }

        close(socket)
    }

    private func extractCode(from request: String) -> String? {
        guard let range = request.range(of: "GET /callback\\?code=([^& ]+)", options: .regularExpression) else {
            return nil
        }

        let match = String(request[range])
        if let codeRange = match.range(of: "code=([^& ]+)", options: .regularExpression) {
            let codeMatch = String(match[codeRange])
            return codeMatch.replacingOccurrences(of: "code=", with: "")
        }

        return nil
    }
}

// MARK: - Helper Extensions

extension Dictionary where Key == String, Value == String {
    func percentEncoded() -> Data? {
        return map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }
}

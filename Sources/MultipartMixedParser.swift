import Foundation

/// A lightweight parser for multipart/mixed HTTP responses
/// Supports nested HTTP responses within multipart parts
struct MultipartMixedParser {

    /// Represents a single part in a multipart/mixed response
    struct Part {
        let headers: [String: String]
        let body: Data

        /// Extract a specific header value (case-insensitive)
        func header(_ name: String) -> String? {
            let lowercaseName = name.lowercased()
            return headers.first { $0.key.lowercased() == lowercaseName }?.value
        }
    }

    /// Parse multipart/mixed data into individual parts
    /// - Parameters:
    ///   - data: The multipart/mixed response data
    ///   - boundary: The boundary string from Content-Type header
    /// - Returns: Array of parsed parts
    static func parse(data: Data, boundary: String) -> [Part] {
        guard let responseString = String(data: data, encoding: .utf8) else {
            return []
        }

        var parts: [Part] = []

        // Split by boundary (handle --boundary and --boundary--)
        let boundaryDelimiter = "--\(boundary)"
        let components = responseString.components(separatedBy: boundaryDelimiter)

        for component in components {
            // Skip empty parts and terminator
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" {
                continue
            }

            // Parse this part
            if let part = parsePart(component) {
                parts.append(part)
            }
        }

        return parts
    }

    /// Parse a single part into headers and body
    private static func parsePart(_ partString: String) -> Part? {
        // Find the separator between headers and body
        // Try both \r\n\r\n and \n\n
        let separators = ["\r\n\r\n", "\n\n"]
        var headerEndIndex: String.Index?
        var usedSeparator = ""

        for separator in separators {
            if let range = partString.range(of: separator) {
                headerEndIndex = range.upperBound
                usedSeparator = separator
                break
            }
        }

        guard let endIndex = headerEndIndex else {
            return nil
        }

        // Extract headers and body
        let headerString = String(partString[..<partString.index(endIndex, offsetBy: -usedSeparator.count)])
        let bodyString = String(partString[endIndex...])

        // Parse headers into dictionary
        let headers = parseHeaders(headerString)

        // Check if body contains nested HTTP response
        var finalBody = bodyString
        if bodyString.hasPrefix("HTTP/1.1") || bodyString.hasPrefix("HTTP/2") {
            // This is a nested HTTP response, extract the actual body
            if let nestedBody = extractHTTPBody(bodyString) {
                finalBody = nestedBody
            }
        }

        return Part(
            headers: headers,
            body: Data(finalBody.utf8)
        )
    }

    /// Parse header lines into a dictionary
    private static func parseHeaders(_ headerString: String) -> [String: String] {
        var headers: [String: String] = [:]

        // Split by newlines (handle both \r\n and \n)
        let lines = headerString.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }

            // Parse "Key: Value" format
            if let colonIndex = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        return headers
    }

    /// Extract body from nested HTTP response
    private static func extractHTTPBody(_ httpResponse: String) -> String? {
        // Find the separator between HTTP headers and body
        let separators = ["\r\n\r\n", "\n\n"]

        for separator in separators {
            if let range = httpResponse.range(of: separator) {
                return String(httpResponse[range.upperBound...])
            }
        }

        return nil
    }
}

import Foundation

/// Google Calendar API integration
class GoogleCalendarAPI {
    private let oauth2Manager: OAuth2Manager

    init(clientID: String, clientSecret: String) {
        self.oauth2Manager = OAuth2Manager(clientID: clientID, clientSecret: clientSecret)
    }

    // MARK: - Authentication

    /// Authenticate with Google using OAuth 2.0
    func authenticate(completion: @escaping (Result<String, Error>) -> Void) {
        oauth2Manager.getAccessToken(completion: completion)
    }

    // MARK: - Event Sync

    struct CalendarEvent: Codable {
        let summary: String
        let description: String?
        let location: String?
        let start: EventDateTime
        let end: EventDateTime
        let extendedProperties: ExtendedProperties?

        struct EventDateTime: Codable {
            let dateTime: String?
            let date: String?
            let timeZone: String?
        }

        struct ExtendedProperties: Codable {
            let `private`: [String: String]?
        }
    }

    struct EventListResponse: Codable {
        let items: [CalendarEventResponse]?
    }

    struct CalendarEventResponse: Codable {
        let id: String
        let summary: String?
        let description: String?
        let location: String?
        let start: EventDateTime?
        let end: EventDateTime?
        let updated: String?
        let extendedProperties: CalendarEvent.ExtendedProperties?

        struct EventDateTime: Codable {
            let dateTime: String?
            let date: String?
            let timeZone: String?
        }
    }

    /// List events from Google Calendar
    func listEvents(
        calendarID: String = "primary",
        timeMin: Date? = nil,
        timeMax: Date? = nil,
        completion: @escaping (Result<[CalendarEventResponse], Error>) -> Void
    ) {
        oauth2Manager.getAccessToken { result in
            switch result {
            case .success(let accessToken):
                self.performListEvents(
                    calendarID: calendarID,
                    timeMin: timeMin,
                    timeMax: timeMax,
                    accessToken: accessToken,
                    completion: completion
                )
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func performListEvents(
        calendarID: String,
        timeMin: Date?,
        timeMax: Date?,
        accessToken: String,
        completion: @escaping (Result<[CalendarEventResponse], Error>) -> Void
    ) {
        var urlComponents = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(calendarID)/events")!

        var queryItems: [URLQueryItem] = []

        let dateFormatter = ISO8601DateFormatter()
        if let timeMin = timeMin {
            queryItems.append(URLQueryItem(name: "timeMin", value: dateFormatter.string(from: timeMin)))
        }
        if let timeMax = timeMax {
            queryItems.append(URLQueryItem(name: "timeMax", value: dateFormatter.string(from: timeMax)))
        }
        queryItems.append(URLQueryItem(name: "singleEvents", value: "true"))
        queryItems.append(URLQueryItem(name: "orderBy", value: "startTime"))
        queryItems.append(URLQueryItem(name: "maxResults", value: "2500"))

        urlComponents.queryItems = queryItems

        guard let url = urlComponents.url else {
            completion(.failure(NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid URL"
            ])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "No data received"
                ])))
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    do {
                        let listResponse = try JSONDecoder().decode(EventListResponse.self, from: data)
                        completion(.success(listResponse.items ?? []))
                    } catch {
                        print("Failed to decode events: \(error)")
                        if let json = String(data: data, encoding: .utf8) {
                            print("Response: \(json)")
                        }
                        completion(.failure(error))
                    }
                } else {
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                    completion(.failure(NSError(domain: "GoogleCalendarAPI", code: httpResponse.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(errorMessage)"
                    ])))
                }
            }
        }
        task.resume()
    }

    /// Create an event in Google Calendar
    func createEvent(_ event: CalendarEvent, calendarID: String = "primary", completion: @escaping (Result<String, Error>) -> Void) {
        // Get access token first
        oauth2Manager.getAccessToken { result in
            switch result {
            case .success(let accessToken):
                self.performCreateEvent(event, calendarID: calendarID, accessToken: accessToken, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func performCreateEvent(_ event: CalendarEvent, calendarID: String, accessToken: String, completion: @escaping (Result<String, Error>) -> Void) {

        let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(calendarID)/events")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let jsonData = try JSONEncoder().encode(event)
            request.httpBody = jsonData

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let data = data else {
                    completion(.failure(NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "No data received"
                    ])))
                    return
                }

                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                        do {
                            let createdEvent = try JSONDecoder().decode(CalendarEventResponse.self, from: data)
                            completion(.success(createdEvent.id))
                        } catch {
                            print("Failed to decode created event: \(error)")
                            completion(.failure(error))
                        }
                    } else {
                        let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                        completion(.failure(NSError(domain: "GoogleCalendarAPI", code: httpResponse.statusCode, userInfo: [
                            NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(errorMessage)"
                        ])))
                    }
                }
            }
            task.resume()
        } catch {
            completion(.failure(error))
        }
    }

    /// Update an event in Google Calendar
    func updateEvent(_ event: CalendarEvent, eventID: String, calendarID: String = "primary", completion: @escaping (Result<Void, Error>) -> Void) {
        oauth2Manager.getAccessToken { result in
            switch result {
            case .success(let accessToken):
                self.performUpdateEvent(event, eventID: eventID, calendarID: calendarID, accessToken: accessToken, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func performUpdateEvent(_ event: CalendarEvent, eventID: String, calendarID: String, accessToken: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        let encodedEventID = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID

        guard let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events/\(encodedEventID)") else {
            completion(.failure(NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid URL"
            ])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let jsonData = try JSONEncoder().encode(event)
            request.httpBody = jsonData

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }

                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        completion(.success(()))
                    } else if httpResponse.statusCode == 404 {
                        // Event doesn't exist - this will be handled by re-creation logic
                        completion(.failure(NSError(domain: "GoogleCalendarAPI", code: 404, userInfo: [
                            NSLocalizedDescriptionKey: "Event not found (may have been deleted)"
                        ])))
                    } else {
                        let errorMessage = String(data: data ?? Data(), encoding: .utf8) ?? "Unknown error"
                        completion(.failure(NSError(domain: "GoogleCalendarAPI", code: httpResponse.statusCode, userInfo: [
                            NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(errorMessage)"
                        ])))
                    }
                }
            }
            task.resume()
        } catch {
            completion(.failure(error))
        }
    }

    /// Delete an event from Google Calendar
    func deleteEvent(eventID: String, calendarID: String = "primary", completion: @escaping (Result<Void, Error>) -> Void) {
        oauth2Manager.getAccessToken { result in
            switch result {
            case .success(let accessToken):
                self.performDeleteEvent(eventID: eventID, calendarID: calendarID, accessToken: accessToken, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Batch Operations

    struct BatchCreateRequest {
        let event: CalendarEvent
        let calendarID: String
    }

    struct BatchCreateResult {
        let success: [(Int, String)]  // (index, eventID) for successfully created events
        let failures: [(Int, Error)]  // (index, error) for failed requests
    }

    /// Create multiple events in a single batch request (max 100 events per batch)
    func batchCreateEvents(_ requests: [BatchCreateRequest], completion: @escaping (Result<BatchCreateResult, Error>) -> Void) {
        guard !requests.isEmpty else {
            completion(.success(BatchCreateResult(success: [], failures: [])))
            return
        }

        guard requests.count <= 100 else {
            completion(.failure(NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Batch requests limited to 100 items. Got \(requests.count) items."
            ])))
            return
        }

        oauth2Manager.getAccessToken { result in
            switch result {
            case .success(let accessToken):
                self.performBatchCreateEvents(requests, accessToken: accessToken, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func performDeleteEvent(eventID: String, calendarID: String, accessToken: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        let encodedEventID = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID

        guard let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events/\(encodedEventID)") else {
            completion(.failure(NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid URL"
            ])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 204 || httpResponse.statusCode == 200 {
                    // 204 No Content is the success response for DELETE
                    completion(.success(()))
                } else if httpResponse.statusCode == 404 {
                    // Event already deleted or doesn't exist - treat as success
                    completion(.success(()))
                } else if httpResponse.statusCode == 410 {
                    // 410 Gone - event was already deleted - treat as success
                    completion(.success(()))
                } else {
                    let errorMessage = String(data: data ?? Data(), encoding: .utf8) ?? "Unknown error"
                    completion(.failure(NSError(domain: "GoogleCalendarAPI", code: httpResponse.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(errorMessage)"
                    ])))
                }
            }
        }
        task.resume()
    }

    private func performBatchCreateEvents(_ requests: [BatchCreateRequest], accessToken: String, completion: @escaping (Result<BatchCreateResult, Error>) -> Void) {
        let boundary = "batch_\(UUID().uuidString)"
        let url = URL(string: "https://www.googleapis.com/batch/calendar/v3")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build multipart/mixed body
        var body = Data()

        for (index, req) in requests.enumerated() {
            // Add boundary
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/http\r\n".data(using: .utf8)!)
            body.append("Content-ID: <item\(index)>\r\n\r\n".data(using: .utf8)!)

            // Add nested HTTP request
            let calendarID = req.calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? req.calendarID
            body.append("POST /calendar/v3/calendars/\(calendarID)/events HTTP/1.1\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)

            // Add JSON body
            if let jsonData = try? JSONEncoder().encode(req.event) {
                body.append(jsonData)
            }
            body.append("\r\n".data(using: .utf8)!)
        }

        // Add final boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "No data received"
                ])))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid response"
                ])))
                return
            }

            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                completion(.failure(NSError(domain: "GoogleCalendarAPI", code: httpResponse.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(errorMessage)"
                ])))
                return
            }

            // Extract boundary from response Content-Type header
            guard let contentType = httpResponse.allHeaderFields["Content-Type"] as? String,
                  let boundaryRange = contentType.range(of: "boundary="),
                  boundaryRange.upperBound < contentType.endIndex else {
                completion(.failure(NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "No boundary found in response Content-Type"
                ])))
                return
            }

            let responseBoundary = String(contentType[boundaryRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Parse multipart response
            self.parseBatchCreateResponse(data: data, boundary: responseBoundary, completion: completion)
        }
        task.resume()
    }

    private func parseBatchCreateResponse(data: Data, boundary: String, completion: @escaping (Result<BatchCreateResult, Error>) -> Void) {
        // Use the MultipartMixedParser module
        let parts = MultipartMixedParser.parse(data: data, boundary: boundary)

        print("[DEBUG] Parsed \(parts.count) parts from batch response")

        var successIDs: [(Int, String)] = []
        var failures: [(Int, Error)] = []

        for (index, part) in parts.enumerated() {
            // Extract item index from Content-ID header
            guard let contentID = part.header("Content-ID"),
                  let itemIndex = extractItemIndex(from: contentID) else {
                print("[DEBUG] Part \(index): Could not extract item index from Content-ID")
                continue
            }

            print("[DEBUG] Part \(index): Item index=\(itemIndex), body length=\(part.body.count)")

            // Check if this is a successful response by looking at headers
            // The part body now contains clean JSON (HTTP headers already stripped by parser)
            let partString = String(data: part.body, encoding: .utf8) ?? ""

            // Note: We need to check the original part string for HTTP status
            // since the parser extracts only the JSON body
            // For now, try to decode and handle errors
            do {
                let eventResponse = try JSONDecoder().decode(CalendarEventResponse.self, from: part.body)
                print("[DEBUG] Part \(index): Successfully decoded event ID: \(eventResponse.id)")
                successIDs.append((itemIndex, eventResponse.id))
            } catch {
                print("[DEBUG] Part \(index): Failed to decode JSON: \(error.localizedDescription)")
                print("[DEBUG] Body preview: \(String(partString.prefix(200)))")

                // Treat decode failure as a failed request
                let failureError = NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to decode response for item \(itemIndex): \(error.localizedDescription)"
                ])
                failures.append((itemIndex, failureError))
            }
        }

        completion(.success(BatchCreateResult(success: successIDs, failures: failures)))
    }

    /// Extract item index from Content-ID header (e.g., "<response-item42>" -> 42)
    private func extractItemIndex(from contentID: String) -> Int? {
        // Remove angle brackets and extract number
        let cleaned = contentID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))

        // Look for "response-item" followed by digits
        if let range = cleaned.range(of: "response-item") {
            let numberPart = String(cleaned[range.upperBound...])
            let digits = numberPart.prefix(while: { $0.isNumber })
            return Int(digits)
        }

        return nil
    }

    // MARK: - Batch Delete Operations

    struct BatchDeleteResult {
        let success: [Int]      // indices of successfully deleted events
        let failures: [(Int, Error)]  // (index, error) for failed requests
    }

    /// Delete multiple events in a single batch request (max 100 events per batch)
    func batchDeleteEvents(eventIDs: [String], calendarID: String = "primary", completion: @escaping (Result<BatchDeleteResult, Error>) -> Void) {
        guard !eventIDs.isEmpty else {
            completion(.success(BatchDeleteResult(success: [], failures: [])))
            return
        }

        guard eventIDs.count <= 100 else {
            completion(.failure(NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Batch requests limited to 100 items. Got \(eventIDs.count) items."
            ])))
            return
        }

        oauth2Manager.getAccessToken { result in
            switch result {
            case .success(let accessToken):
                self.performBatchDeleteEvents(eventIDs: eventIDs, calendarID: calendarID, accessToken: accessToken, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func performBatchDeleteEvents(eventIDs: [String], calendarID: String, accessToken: String, completion: @escaping (Result<BatchDeleteResult, Error>) -> Void) {
        let boundary = "batch_\(UUID().uuidString)"
        let url = URL(string: "https://www.googleapis.com/batch/calendar/v3")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build multipart/mixed body
        var body = Data()
        let encodedCalendarID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID

        for (index, eventID) in eventIDs.enumerated() {
            let encodedEventID = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID

            // Add boundary
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/http\r\n".data(using: .utf8)!)
            body.append("Content-ID: <item\(index)>\r\n\r\n".data(using: .utf8)!)

            // Add nested HTTP DELETE request
            body.append("DELETE /calendar/v3/calendars/\(encodedCalendarID)/events/\(encodedEventID) HTTP/1.1\r\n".data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        // Add final boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "No data received"
                ])))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid response"
                ])))
                return
            }

            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                completion(.failure(NSError(domain: "GoogleCalendarAPI", code: httpResponse.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(errorMessage)"
                ])))
                return
            }

            // Extract boundary from response Content-Type header
            guard let contentType = httpResponse.allHeaderFields["Content-Type"] as? String,
                  let boundaryRange = contentType.range(of: "boundary="),
                  boundaryRange.upperBound < contentType.endIndex else {
                completion(.failure(NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "No boundary found in response Content-Type"
                ])))
                return
            }

            let responseBoundary = String(contentType[boundaryRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Parse multipart response
            self.parseBatchDeleteResponse(data: data, boundary: responseBoundary, completion: completion)
        }
        task.resume()
    }

    private func parseBatchDeleteResponse(data: Data, boundary: String, completion: @escaping (Result<BatchDeleteResult, Error>) -> Void) {
        let parts = MultipartMixedParser.parse(data: data, boundary: boundary)

        var successIndices: [Int] = []
        var failures: [(Int, Error)] = []

        for (index, part) in parts.enumerated() {
            // Extract item index from Content-ID header
            guard let contentID = part.header("Content-ID"),
                  let itemIndex = extractItemIndex(from: contentID) else {
                continue
            }

            // Check HTTP status from the part
            // The part body contains the response - for DELETE, successful responses are 204 (No Content)
            // or empty body. Error responses contain JSON error details.
            let partString = String(data: part.body, encoding: .utf8) ?? ""

            // Check if response indicates success (empty body or no error)
            // DELETE returns 204 No Content on success, which means empty or minimal body
            if partString.isEmpty || partString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                successIndices.append(itemIndex)
            } else if partString.contains("\"error\"") {
                // Parse error response
                let failureError = NSError(domain: "GoogleCalendarAPI", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Delete failed for item \(itemIndex): \(String(partString.prefix(200)))"
                ])
                failures.append((itemIndex, failureError))
            } else {
                // Treat as success if no explicit error
                successIndices.append(itemIndex)
            }
        }

        completion(.success(BatchDeleteResult(success: successIndices, failures: failures)))
    }
}

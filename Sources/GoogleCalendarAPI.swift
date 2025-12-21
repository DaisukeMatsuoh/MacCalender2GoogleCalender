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
}

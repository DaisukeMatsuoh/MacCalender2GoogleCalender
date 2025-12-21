import Foundation

struct Config: Codable {
    let google: GoogleConfig?
    let sync: SyncConfig
    let calendars: CalendarConfig
    let formatting: FormattingConfig?

    struct GoogleConfig: Codable {
        let clientID: String
        let clientSecret: String
        let calendarID: String
    }

    struct SyncConfig: Codable {
        let pastDays: Int
        let futureDays: Int
        let syncIntervalSeconds: Int
    }

    struct CalendarConfig: Codable {
        let targetCalendars: [String]  // List of calendar names to sync
        let mode: String  // "include" or "exclude"
    }

    struct FormattingConfig: Codable {
        let includeLocationInDescription: Bool?  // Add location to description field
        let locationPrefix: String?  // Prefix for location in description (default: "Location: ")

        enum CodingKeys: String, CodingKey {
            case includeLocationInDescription = "include_location_in_description"
            case locationPrefix = "location_prefix"
        }
    }

    static func load(from path: String = "config.json") -> Config? {
        let fileURL: URL

        if path.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: path)
        } else {
            fileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(path)
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            print("Config file not found at: \(fileURL.path)")
            return nil
        }

        let decoder = JSONDecoder()
        do {
            let config = try decoder.decode(Config.self, from: data)
            return config
        } catch {
            print("Failed to decode config: \(error)")
            return nil
        }
    }
}

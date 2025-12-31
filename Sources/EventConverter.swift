import Foundation
import EventKit

struct EventConverter {
    static func toGoogleCalendarEvent(_ ekEvent: EKEvent, config: Config? = nil) -> GoogleCalendarAPI.CalendarEvent {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]  // Fractional seconds not needed for calendar events

        let start: GoogleCalendarAPI.CalendarEvent.EventDateTime
        let end: GoogleCalendarAPI.CalendarEvent.EventDateTime

        if ekEvent.isAllDay {
            // For all-day events, use date format (YYYY-MM-DD)
            let dateOnlyFormatter = DateFormatter()
            dateOnlyFormatter.dateFormat = "yyyy-MM-dd"

            start = GoogleCalendarAPI.CalendarEvent.EventDateTime(
                dateTime: nil,
                date: dateOnlyFormatter.string(from: ekEvent.startDate),
                timeZone: nil
            )
            end = GoogleCalendarAPI.CalendarEvent.EventDateTime(
                dateTime: nil,
                date: dateOnlyFormatter.string(from: ekEvent.endDate),
                timeZone: nil
            )
        } else {
            // For timed events, use dateTime format with timezone
            start = GoogleCalendarAPI.CalendarEvent.EventDateTime(
                dateTime: dateFormatter.string(from: ekEvent.startDate),
                date: nil,
                timeZone: ekEvent.timeZone?.identifier ?? TimeZone.current.identifier
            )
            end = GoogleCalendarAPI.CalendarEvent.EventDateTime(
                dateTime: dateFormatter.string(from: ekEvent.endDate),
                date: nil,
                timeZone: ekEvent.timeZone?.identifier ?? TimeZone.current.identifier
            )
        }

        var description = ""

        // Add location to description if configured
        let shouldIncludeLocation = config?.formatting?.includeLocationInDescription ?? false
        if shouldIncludeLocation, let location = ekEvent.location, !location.isEmpty {
            let locationPrefix = config?.formatting?.locationPrefix ?? "Location: "
            description += "\(locationPrefix)\(location)\n\n"
        }

        // Add event notes
        if let notes = ekEvent.notes, !notes.isEmpty {
            description += notes
            description += "\n\n"
        }

        // Add sync source information
        description += "[Synced from Mac Calendar: \(ekEvent.calendar.title)]"

        // Store Mac Event ID in extended properties for tracking
        let extendedProperties = GoogleCalendarAPI.CalendarEvent.ExtendedProperties(
            private: [
                "macEventID": ekEvent.eventIdentifier,
                "sourceCalendar": ekEvent.calendar.title
            ]
        )

        return GoogleCalendarAPI.CalendarEvent(
            summary: ekEvent.title ?? "Untitled Event",
            description: description,
            location: ekEvent.location,
            start: start,
            end: end,
            extendedProperties: extendedProperties
        )
    }

    /// Calculate a stable content hash for an event
    /// This hash includes only the content that matters for sync, excluding metadata
    /// Uses a simple FNV-1a hash algorithm for stable, deterministic hashing
    static func calculateContentHash(_ ekEvent: EKEvent) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        // Normalize date strings to ensure consistent hashing
        let startDateStr: String
        let endDateStr: String

        if ekEvent.isAllDay {
            // For all-day events, use date-only format
            let dateOnlyFormatter = DateFormatter()
            dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
            dateOnlyFormatter.timeZone = TimeZone(identifier: "UTC")
            startDateStr = dateOnlyFormatter.string(from: ekEvent.startDate)
            endDateStr = dateOnlyFormatter.string(from: ekEvent.endDate)
        } else {
            // For timed events, use ISO8601 in UTC
            formatter.timeZone = TimeZone(identifier: "UTC")
            startDateStr = formatter.string(from: ekEvent.startDate)
            endDateStr = formatter.string(from: ekEvent.endDate)
        }

        // Build content string for hashing
        var components: [String] = []
        components.append("title:\(ekEvent.title ?? "Untitled")")
        components.append("start:\(startDateStr)")
        components.append("end:\(endDateStr)")
        components.append("allDay:\(ekEvent.isAllDay)")

        if let location = ekEvent.location, !location.isEmpty {
            components.append("location:\(location)")
        }

        if let notes = ekEvent.notes, !notes.isEmpty {
            components.append("notes:\(notes)")
        }

        let contentString = components.joined(separator: "|")

        // FNV-1a hash algorithm (64-bit, stable and deterministic)
        var hash: UInt64 = 14695981039346656037  // FNV offset basis
        let fnvPrime: UInt64 = 1099511628211

        for byte in contentString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }

        // Convert to hex string using Swift native method (architecture/endian independent)
        var hashString = String(hash, radix: 16, uppercase: false)
        // Pad with leading zeros to ensure 16 characters
        while hashString.count < 16 {
            hashString = "0" + hashString
        }

        return hashString
    }
}

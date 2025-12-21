import Foundation
import EventKit

struct EventConverter {
    static func toGoogleCalendarEvent(_ ekEvent: EKEvent, config: Config? = nil) -> GoogleCalendarAPI.CalendarEvent {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

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
}

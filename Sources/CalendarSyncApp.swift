import Foundation
import EventKit

class CalendarSyncApp {
    private let eventStore = EKEventStore()
    private var isAuthorized = false
    private var config: Config?
    private var googleAPI: GoogleCalendarAPI?
    private let syncDatabase = SyncDatabase()
    private var syncTimer: DispatchSourceTimer?
    private var _isSyncEnabled = true
    private var runtimeTargetCalendars: Set<String>?
    private var runtimeLocationInDescription: Bool?

    // MARK: - Public Properties for MenuBar

    var isSyncEnabled: Bool {
        return _isSyncEnabled
    }

    var isLocationInDescriptionEnabled: Bool {
        if let runtime = runtimeLocationInDescription {
            return runtime
        }
        return config?.formatting?.includeLocationInDescription ?? false
    }

    func run() {
        print("Loading configuration...")
        if let config = Config.load() {
            self.config = config
            if let googleConfig = config.google {
                self.googleAPI = GoogleCalendarAPI(
                    clientID: googleConfig.clientID,
                    clientSecret: googleConfig.clientSecret
                )
                print("Configuration loaded successfully (Google API configured)")
            } else {
                print("Configuration loaded successfully (Google API not configured)")
            }
        } else {
            print("Warning: config.json not found. Copy config.example.json to config.json")
            print("Continuing with default settings (all calendars, read-only mode)")
        }

        // Load runtime config (overrides from menu bar)
        loadRuntimeConfig()

        print("Requesting calendar access...")
        requestCalendarAccess()
    }

    private func requestCalendarAccess() {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                guard let self = self else { return }

                if let error = error {
                    print("Error requesting calendar access: \(error.localizedDescription)")
                    return
                }

                if granted {
                    print("Calendar access granted")
                    self.isAuthorized = true
                    self.startMonitoring()
                } else {
                    print("Calendar access denied")
                    print("Please grant calendar access in System Settings > Privacy & Security > Calendars")
                }
            }
        } else {
            // Fallback for macOS 13
            eventStore.requestAccess(to: .event) { [weak self] granted, error in
                guard let self = self else { return }

                if let error = error {
                    print("Error requesting calendar access: \(error.localizedDescription)")
                    return
                }

                if granted {
                    print("Calendar access granted")
                    self.isAuthorized = true
                    self.startMonitoring()
                } else {
                    print("Calendar access denied")
                    print("Please grant calendar access in System Settings > Privacy & Security > Calendars")
                }
            }
        }
    }

    private func startMonitoring() {
        print("Starting calendar monitoring...")

        // Register for calendar change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(calendarChanged),
            name: .EKEventStoreChanged,
            object: eventStore
        )

        // Start periodic sync timer
        startPeriodicSync()

        // Initial sync
        syncRecentEvents()
    }

    private func startPeriodicSync() {
        let intervalSeconds = config?.sync.syncIntervalSeconds ?? 300  // Default: 5 minutes

        print("Starting periodic sync timer (interval: \(intervalSeconds) seconds)")

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(
            deadline: .now() + .seconds(intervalSeconds),
            repeating: .seconds(intervalSeconds)
        )
        timer.setEventHandler { [weak self] in
            print("\n⏰ Periodic sync triggered")
            self?.syncRecentEvents()
        }
        timer.resume()

        self.syncTimer = timer
    }

    private func stopPeriodicSync() {
        syncTimer?.cancel()
        syncTimer = nil
        print("Periodic sync timer stopped")
    }

    @objc private func calendarChanged(notification: Notification) {
        print("Calendar changed detected")
        syncRecentEvents()
    }

    private func syncRecentEvents() {
        guard isAuthorized else {
            print("Not authorized to access calendars")
            return
        }

        print("\n--- Scanning calendars ---")

        // Get all calendars
        let calendars = eventStore.calendars(for: .event)
        print("Total calendars found: \(calendars.count)")

        // List all calendars with their source types
        for calendar in calendars {
            let sourceType = calendar.source.sourceType
            let sourceTypeName: String
            switch sourceType {
            case .local:
                sourceTypeName = "Local (マイMac)"
            case .calDAV:
                sourceTypeName = "CalDAV (iCloud/Google)"
            case .exchange:
                sourceTypeName = "Exchange"
            case .subscribed:
                sourceTypeName = "Subscribed"
            case .birthdays:
                sourceTypeName = "Birthdays"
            case .mobileMe:
                sourceTypeName = "MobileMe"
            @unknown default:
                sourceTypeName = "Unknown"
            }
            print("  - \(calendar.title) [\(sourceTypeName)]")
        }

        // Filter calendars based on config (runtime config takes precedence)
        let targetCalendars: [EKCalendar]
        let targetNames = getTargetCalendarNames()

        if !targetNames.isEmpty {
            // Include only specified calendars (from runtime or config)
            targetCalendars = calendars.filter { calendar in
                targetNames.contains(calendar.title)
            }
            print("\n✓ Filtering mode: INCLUDE only specified calendars")
        } else if let config = config, config.calendars.mode == "exclude" {
            // Exclude specified calendars (only from original config)
            let excludeNames = Set(config.calendars.targetCalendars)
            targetCalendars = calendars.filter { calendar in
                !excludeNames.contains(calendar.title)
            }
            print("\n✓ Filtering mode: EXCLUDE specified calendars")
        } else {
            // No config, use all calendars except birthdays
            targetCalendars = calendars.filter { calendar in
                calendar.source.sourceType != .birthdays
            }
            print("\n✓ No config found, using all calendars (except birthdays)")
        }

        if targetCalendars.isEmpty {
            print("\n⚠️  No target calendars found")
            if let config = config {
                print("Configured target calendars: \(config.calendars.targetCalendars.joined(separator: ", "))")
                print("Available calendars:")
                for calendar in calendars {
                    print("  - \(calendar.title)")
                }
            }
            return
        }

        print("\n✓ Found \(targetCalendars.count) calendar(s) to sync:")
        for calendar in targetCalendars {
            print("  - \(calendar.title)")
        }

        // Get events from the configured date range (default: last 7 days to future 30 days)
        let pastDays = config?.sync.pastDays ?? 7
        let futureDays = config?.sync.futureDays ?? 30
        let startDate = Calendar.current.date(byAdding: .day, value: -pastDays, to: Date())!
        let endDate = Calendar.current.date(byAdding: .day, value: futureDays, to: Date())!

        print("\n[DEBUG] Date range:")
        print("  Start: \(startDate)")
        print("  End: \(endDate)")
        print("  Current time: \(Date())")

        print("\n[DEBUG] Target calendar details:")
        for calendar in targetCalendars {
            print("  - \(calendar.title)")
            print("    Type: \(calendar.type)")
            print("    Source: \(calendar.source.title)")
            print("    Allows modification: \(calendar.allowsContentModifications)")
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: targetCalendars
        )

        print("\n[DEBUG] Fetching events with predicate...")

        // Try refreshing the source first (for CalDAV calendars)
        for calendar in targetCalendars {
            if calendar.source.sourceType == .calDAV {
                print("[DEBUG] Refreshing CalDAV source: \(calendar.source.title)")
                // Force refresh by accessing properties
                _ = calendar.source.calendars
            }
        }

        let events = eventStore.events(matching: predicate)
        print("[DEBUG] Raw event count: \(events.count)")

        // Also try a broader search to see if events exist outside expected range
        print("\n[DEBUG] Testing with broader date range (past 365 days to future 730 days)...")
        let broadStartDate = Calendar.current.date(byAdding: .day, value: -365, to: Date())!
        let broadEndDate = Calendar.current.date(byAdding: .day, value: 730, to: Date())!
        let broadPredicate = eventStore.predicateForEvents(
            withStart: broadStartDate,
            end: broadEndDate,
            calendars: targetCalendars
        )
        let broadEvents = eventStore.events(matching: broadPredicate)
        print("[DEBUG] Broader search found: \(broadEvents.count) events")

        print("\n--- Found \(events.count) event(s) in target calendars ---")

        if events.isEmpty {
            print("No events found in the date range (past \(pastDays) days to future \(futureDays) days)")
            print("Try adding an event to one of the target calendars listed above.")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        dateFormatter.locale = Locale(identifier: "ja_JP")

        // Create a set of current Mac event IDs for deletion detection
        var currentMacEventIDs = Set<String>()

        for (index, event) in events.enumerated() {
            currentMacEventIDs.insert(event.eventIdentifier)

            print("\n[\(index + 1)/\(events.count)] \(event.title ?? "Untitled")")
            print("  📅 Start: \(dateFormatter.string(from: event.startDate))")
            print("  📅 End:   \(dateFormatter.string(from: event.endDate))")
            print("  📂 Calendar: \(event.calendar.title)")
            if let location = event.location, !location.isEmpty {
                print("  📍 Location: \(location)")
            }
            if let notes = event.notes, !notes.isEmpty {
                print("  📝 Notes: \(notes)")
            }
            print("  🕐 All-day: \(event.isAllDay ? "Yes" : "No")")

            // TODO: Sync to Google Calendar
            syncEventToGoogle(event)
        }

        // Check for deleted events (in database but not in current Mac calendar)
        print("\n--- Checking for deleted events ---")
        detectAndHandleDeletedEvents(
            currentMacEventIDs: currentMacEventIDs,
            targetCalendars: targetCalendars
        )

        print("\n--- Sync complete ---\n")

        // Notify menu bar that sync completed
        NotificationCenter.default.post(name: NSNotification.Name("CalendarSyncCompleted"), object: nil)
    }

    private func syncEventToGoogle(_ event: EKEvent) {
        guard let googleAPI = googleAPI,
              let config = config,
              let googleConfig = config.google else {
            print("  -> Google API not configured, skipping sync")
            return
        }

        // Convert EKEvent to Google Calendar format
        let googleEvent = EventConverter.toGoogleCalendarEvent(event, config: config)

        // Check if already synced in database
        if let record = syncDatabase.getRecord(macEventID: event.eventIdentifier) {
            print("  -> Already synced (Google Event ID: \(record.googleEventID))")

            // Check if event has been modified since last sync
            if let eventModified = event.lastModifiedDate,
               eventModified > record.macLastModified {
                print("  -> Event has been modified since last sync")
                print("     Last synced: \(record.macLastModified)")
                print("     Last modified: \(eventModified)")
                print("  -> Updating Google Calendar event...")

                // Use semaphore for synchronous operation
                let semaphore = DispatchSemaphore(value: 0)
                var shouldRecreate = false

                googleAPI.updateEvent(googleEvent, eventID: record.googleEventID, calendarID: googleConfig.calendarID) { [weak self] result in
                    guard let self = self else {
                        semaphore.signal()
                        return
                    }

                    switch result {
                    case .success:
                        print("  -> Successfully updated in Google Calendar")
                        // Update the last modified time in database
                        self.syncDatabase.updateLastSynced(macEventID: event.eventIdentifier, macLastModified: eventModified)

                    case .failure(let error):
                        let nsError = error as NSError
                        if nsError.code == 404 {
                            // Event was deleted on Google side - need to recreate
                            print("  -> Event not found in Google Calendar (was deleted)")
                            print("  -> Will recreate the event...")
                            shouldRecreate = true
                        } else {
                            print("  -> Failed to update: \(error.localizedDescription)")
                        }
                    }
                    semaphore.signal()
                }

                semaphore.wait()

                // If event was deleted on Google side, recreate it
                if shouldRecreate {
                    recreateEventInGoogle(event: event, oldGoogleEventID: record.googleEventID)
                }
            }
            return
        }

        // New event - create in Google Calendar
        print("  -> Syncing new event to Google Calendar...")

        // Create event in Google Calendar
        googleAPI.createEvent(googleEvent, calendarID: googleConfig.calendarID) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let googleEventID):
                print("  -> Successfully synced to Google Calendar (ID: \(googleEventID))")

                // Save to sync database
                self.syncDatabase.upsertRecord(
                    macEventID: event.eventIdentifier,
                    googleEventID: googleEventID,
                    macLastModified: event.lastModifiedDate ?? Date(),
                    sourceCalendar: event.calendar.title
                )

            case .failure(let error):
                print("  -> Failed to sync: \(error.localizedDescription)")
            }
        }
    }

    private func recreateEventInGoogle(event: EKEvent, oldGoogleEventID: String) {
        guard let googleAPI = googleAPI,
              let config = config,
              let googleConfig = config.google else {
            return
        }

        let googleEvent = EventConverter.toGoogleCalendarEvent(event, config: config)

        let semaphore = DispatchSemaphore(value: 0)

        googleAPI.createEvent(googleEvent, calendarID: googleConfig.calendarID) { [weak self] result in
            guard let self = self else {
                semaphore.signal()
                return
            }

            switch result {
            case .success(let newGoogleEventID):
                print("  -> Successfully recreated in Google Calendar (new ID: \(newGoogleEventID))")

                // Update database with new Google event ID
                self.syncDatabase.upsertRecord(
                    macEventID: event.eventIdentifier,
                    googleEventID: newGoogleEventID,
                    macLastModified: event.lastModifiedDate ?? Date(),
                    sourceCalendar: event.calendar.title
                )

            case .failure(let error):
                print("  -> Failed to recreate: \(error.localizedDescription)")
            }
            semaphore.signal()
        }

        semaphore.wait()
    }

    private func detectAndHandleDeletedEvents(
        currentMacEventIDs: Set<String>,
        targetCalendars: [EKCalendar]
    ) {
        guard let googleAPI = googleAPI,
              let config = config,
              let googleConfig = config.google else {
            print("Google API not configured, skipping deletion check")
            return
        }

        // Get all synced records for target calendars
        let targetCalendarNames = Set(targetCalendars.map { $0.title })
        let allRecords = syncDatabase.getAllRecords()
        let relevantRecords = allRecords.filter { targetCalendarNames.contains($0.sourceCalendar) }

        var deletedCount = 0
        var skippedCount = 0

        for record in relevantRecords {
            // If event is in database but not in current Mac events, it was deleted
            if !currentMacEventIDs.contains(record.macEventID) {
                print("\n🗑️  Deleted event detected:")
                print("  Mac Event ID: \(record.macEventID)")
                print("  Google Event ID: \(record.googleEventID)")
                print("  Calendar: \(record.sourceCalendar)")
                print("  -> Deleting from Google Calendar...")

                // Delete from Google Calendar
                let semaphore = DispatchSemaphore(value: 0)
                var deleteSucceeded = false

                googleAPI.deleteEvent(eventID: record.googleEventID, calendarID: googleConfig.calendarID) { result in
                    switch result {
                    case .success:
                        print("  -> Successfully deleted from Google Calendar")
                        deleteSucceeded = true
                    case .failure(let error):
                        print("  -> Failed to delete from Google Calendar: \(error.localizedDescription)")
                    }
                    semaphore.signal()
                }

                semaphore.wait()

                // Remove from local database
                if deleteSucceeded {
                    syncDatabase.removeRecord(macEventID: record.macEventID)
                    print("  -> Removed from sync database")
                    deletedCount += 1
                } else {
                    skippedCount += 1
                }
            }
        }

        if deletedCount > 0 {
            print("\n✓ Deleted \(deletedCount) event(s) from Google Calendar")
        }
        if skippedCount > 0 {
            print("⚠️  Skipped \(skippedCount) event(s) due to deletion errors")
        }
        if deletedCount == 0 && skippedCount == 0 {
            print("No deleted events detected")
        }
    }

    // MARK: - Public Methods for MenuBar

    func getAvailableCalendars() -> [EKCalendar] {
        guard isAuthorized else { return [] }
        return eventStore.calendars(for: .event).filter { calendar in
            calendar.source.sourceType != .birthdays
        }
    }

    func getTargetCalendarNames() -> Set<String> {
        if let runtime = runtimeTargetCalendars {
            return runtime
        }
        return Set(config?.calendars.targetCalendars ?? [])
    }

    func getSyncIntervalSeconds() -> Int {
        return config?.sync.syncIntervalSeconds ?? 300
    }

    func startSync() {
        guard !_isSyncEnabled else { return }
        _isSyncEnabled = true
        print("Sync enabled")
        startPeriodicSync()
        syncRecentEvents()
    }

    func stopSync() {
        guard _isSyncEnabled else { return }
        _isSyncEnabled = false
        print("Sync disabled")
        stopPeriodicSync()
    }

    func syncNow() {
        guard _isSyncEnabled else {
            print("Sync is disabled")
            return
        }
        print("\n🔄 Manual sync triggered")
        syncRecentEvents()
    }

    func toggleCalendar(_ calendarName: String) {
        var currentTargets = runtimeTargetCalendars ?? Set(config?.calendars.targetCalendars ?? [])

        if currentTargets.contains(calendarName) {
            currentTargets.remove(calendarName)
            print("Removed calendar from sync: \(calendarName)")
        } else {
            currentTargets.insert(calendarName)
            print("Added calendar to sync: \(calendarName)")
        }

        runtimeTargetCalendars = currentTargets
        saveRuntimeConfig()
    }

    func toggleLocationInDescription() {
        let current = isLocationInDescriptionEnabled
        runtimeLocationInDescription = !current
        print("Location in description: \(runtimeLocationInDescription! ? "enabled" : "disabled")")
        saveRuntimeConfig()
    }

    private func saveRuntimeConfig() {
        // Save runtime settings to a separate file
        let runtimeConfig: [String: Any] = [
            "targetCalendars": Array(runtimeTargetCalendars ?? Set(config?.calendars.targetCalendars ?? [])),
            "includeLocationInDescription": runtimeLocationInDescription ?? (config?.formatting?.includeLocationInDescription ?? false)
        ]

        let fileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("runtime_config.json")

        do {
            let data = try JSONSerialization.data(withJSONObject: runtimeConfig, options: .prettyPrinted)
            try data.write(to: fileURL)
            print("Runtime config saved")
        } catch {
            print("Failed to save runtime config: \(error)")
        }
    }

    private func loadRuntimeConfig() {
        let fileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("runtime_config.json")

        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let calendars = json["targetCalendars"] as? [String] {
            runtimeTargetCalendars = Set(calendars)
        }
        if let location = json["includeLocationInDescription"] as? Bool {
            runtimeLocationInDescription = location
        }
        print("Runtime config loaded")
    }
}

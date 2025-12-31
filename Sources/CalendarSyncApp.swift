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

    /// Initialize only Google API authentication without starting sync
    /// Use this for cleanup commands that only need API access
    func initializeForCleanup() {
        print("Loading configuration for cleanup...")
        if let config = Config.load() {
            self.config = config
            if let googleConfig = config.google {
                self.googleAPI = GoogleCalendarAPI(
                    clientID: googleConfig.clientID,
                    clientSecret: googleConfig.clientSecret
                )
                print("Configuration loaded successfully (Google API configured)")
            } else {
                print("Error: Google API not configured in config.json")
            }
        } else {
            print("Error: config.json not found")
        }
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

    /// Create a unique key for an event occurrence
    /// For recurring events, each occurrence has the same eventIdentifier but different start time
    /// This function creates a unique key that combines both
    private func makeOccurrenceKey(for event: EKEvent) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let startStr = formatter.string(from: event.startDate)
        return "\(event.eventIdentifier)_\(startStr)"
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

        // Classify events into categories for batch processing
        var newEvents: [EKEvent] = []
        var updatedEvents: [EKEvent] = []
        var unchangedCount = 0

        // Track processed event occurrences to avoid duplicates
        // For recurring events, we need to distinguish each occurrence
        var processedOccurrences = Set<String>()

        for (index, event) in events.enumerated() {
            // Create unique key for this occurrence (handles recurring events)
            let occurrenceKey = makeOccurrenceKey(for: event)

            // Use occurrenceKey for deletion detection (must match what's stored in DB)
            currentMacEventIDs.insert(occurrenceKey)

            // Skip if already processed (can happen with recurring events)
            if processedOccurrences.contains(occurrenceKey) {
                print("\n[SKIP] Duplicate occurrence: \(event.title ?? "Untitled") at \(event.startDate)")
                continue
            }
            processedOccurrences.insert(occurrenceKey)

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

            // Classify event
            let currentHash = EventConverter.calculateContentHash(event)

            // Debug: Print hash for first event
            if index == 0 {
                print("  [DEBUG] First event hash: \(currentHash)")
            }

            // Use occurrence key instead of just eventIdentifier
            // This handles recurring events where each occurrence has the same ID
            if let record = syncDatabase.getRecord(macEventID: occurrenceKey) {
                // Existing event - check if modified
                let eventModified = event.lastModifiedDate
                let hasModificationDate = eventModified != nil
                let modificationDateChanged = hasModificationDate && eventModified! > record.macLastModified

                if modificationDateChanged {
                    if currentHash == record.contentHash {
                        print("  -> Modification date changed, but content identical - updating DB only")
                        syncDatabase.updateLastSynced(
                            macEventID: occurrenceKey,
                            macLastModified: eventModified!,
                            contentHash: currentHash
                        )
                        unchangedCount += 1
                    } else {
                        print("  -> Content changed - will update via API")
                        updatedEvents.append(event)
                    }
                } else if !hasModificationDate {
                    if currentHash == record.contentHash {
                        print("  -> No modification date, but hash matches - skipping")
                        unchangedCount += 1
                    } else {
                        print("  -> No modification date, but hash differs - will update")
                        updatedEvents.append(event)
                    }
                } else {
                    if currentHash == record.contentHash {
                        print("  -> No changes detected - skipping")
                        unchangedCount += 1
                    } else {
                        print("  -> Content changed without timestamp update - will update")
                        updatedEvents.append(event)
                    }
                }
            } else {
                // New event
                print("  -> New event - will create via API")
                newEvents.append(event)
            }
        }

        print("\n--- Event classification complete ---")
        print("  New events: \(newEvents.count)")
        print("  Updated events: \(updatedEvents.count)")
        print("  Unchanged events: \(unchangedCount)")

        // Process new events in batches
        if !newEvents.isEmpty {
            print("\n--- Batch creating \(newEvents.count) new event(s) ---")
            batchCreateEvents(newEvents)
        }

        // Process updated events individually (batch update is complex due to different event IDs)
        if !updatedEvents.isEmpty {
            print("\n--- Updating \(updatedEvents.count) event(s) ---")
            for event in updatedEvents {
                syncEventToGoogle(event)
            }
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

        // Use occurrence key for recurring events
        let occurrenceKey = makeOccurrenceKey(for: event)

        // Calculate current content hash
        let currentHash = EventConverter.calculateContentHash(event)

        // Check if already synced in database
        if let record = syncDatabase.getRecord(macEventID: occurrenceKey) {
            print("  -> Already synced (Google Event ID: \(record.googleEventID))")

            // Hybrid approach: Check lastModifiedDate first, then verify with content hash
            let eventModified = event.lastModifiedDate
            let hasModificationDate = eventModified != nil
            let modificationDateChanged = hasModificationDate && eventModified! > record.macLastModified

            if modificationDateChanged {
                // lastModifiedDate indicates a change - verify with content hash
                if currentHash == record.contentHash {
                    print("  -> Modification date changed, but content is identical (hash match)")
                    print("     Skipping API call - false positive from timestamp update")
                    // Update only the timestamp in database to avoid future checks
                    syncDatabase.updateLastSynced(
                        macEventID: occurrenceKey,
                        macLastModified: eventModified!,
                        contentHash: currentHash
                    )
                    return
                } else {
                    print("  -> Event content has changed (hash mismatch)")
                    print("     Last synced: \(record.macLastModified)")
                    print("     Last modified: \(eventModified!)")
                    print("     Old hash: \(record.contentHash) (len=\(record.contentHash.count))")
                    print("     New hash: \(currentHash) (len=\(currentHash.count))")
                    print("  -> Updating Google Calendar event...")
                }
            } else if !hasModificationDate {
                // No lastModifiedDate available - fallback to hash comparison only
                if currentHash == record.contentHash {
                    print("  -> No modification date, but content hash matches")
                    print("     Skipping API call - content unchanged")
                    return
                } else {
                    print("  -> No modification date, but content hash differs")
                    print("     Old hash: \(record.contentHash) (len=\(record.contentHash.count))")
                    print("     New hash: \(currentHash) (len=\(currentHash.count))")
                    print("  -> Updating Google Calendar event...")
                }
            } else {
                // Modification date exists but hasn't changed
                if currentHash == record.contentHash {
                    print("  -> No changes detected (timestamp and hash both unchanged)")
                    print("     Skipping API call")
                    return
                } else {
                    // Edge case: hash changed but timestamp didn't (rare, but possible)
                    print("  -> Content hash changed without timestamp update (rare edge case)")
                    print("     Old hash: \(record.contentHash) (len=\(record.contentHash.count))")
                    print("     New hash: \(currentHash) (len=\(currentHash.count))")
                    print("  -> Updating Google Calendar event...")
                }
            }

            // If we reach here, we need to update the event
            let googleEvent = EventConverter.toGoogleCalendarEvent(event, config: config)
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
                    // Update the database with new hash and timestamp
                    self.syncDatabase.updateLastSynced(
                        macEventID: occurrenceKey,
                        macLastModified: eventModified ?? Date(),
                        contentHash: currentHash
                    )

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
            return
        }

        // New event - create in Google Calendar
        print("  -> New event detected - syncing to Google Calendar...")
        print("     Content hash: \(currentHash.prefix(8))...")

        let googleEvent = EventConverter.toGoogleCalendarEvent(event, config: config)

        // Create event in Google Calendar
        googleAPI.createEvent(googleEvent, calendarID: googleConfig.calendarID) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let googleEventID):
                print("  -> Successfully synced to Google Calendar (ID: \(googleEventID))")

                // Save to sync database with content hash
                self.syncDatabase.upsertRecord(
                    macEventID: occurrenceKey,
                    googleEventID: googleEventID,
                    macLastModified: event.lastModifiedDate ?? Date(),
                    sourceCalendar: event.calendar.title,
                    contentHash: currentHash
                )

            case .failure(let error):
                print("  -> Failed to sync: \(error.localizedDescription)")
            }
        }
    }

    private func batchCreateEvents(_ events: [EKEvent]) {
        guard let googleAPI = googleAPI,
              let config = config,
              let googleConfig = config.google else {
            print("  -> Google API not configured, skipping batch create")
            return
        }

        // Split into batches of 100 (Google API limit per batch request)
        // Each batch counts as 1 API call, so no delay needed between batches
        let batchSize = 100
        let batches = stride(from: 0, to: events.count, by: batchSize).map {
            Array(events[$0..<min($0 + batchSize, events.count)])
        }

        print("  -> Processing \(events.count) events in \(batches.count) batch(es)")

        for (batchIndex, batch) in batches.enumerated() {
            print("\n  -> Batch \(batchIndex + 1)/\(batches.count): Creating \(batch.count) events...")

            // Prepare batch requests
            let requests = batch.map { event in
                GoogleCalendarAPI.BatchCreateRequest(
                    event: EventConverter.toGoogleCalendarEvent(event, config: config),
                    calendarID: googleConfig.calendarID
                )
            }

            // Execute batch request with retry logic for rate limit errors only
            var retryCount = 0
            let maxRetries = 3
            var batchCompleted = false

            while !batchCompleted && retryCount <= maxRetries {
                if retryCount > 0 {
                    // Exponential backoff only when rate limit is hit: 30s, 60s, 120s
                    let waitTime = 30.0 * pow(2.0, Double(retryCount - 1))
                    print("  -> Rate limit hit, waiting \(Int(waitTime)) seconds before retry \(retryCount)/\(maxRetries)...")
                    Thread.sleep(forTimeInterval: waitTime)
                }

                let semaphore = DispatchSemaphore(value: 0)
                var shouldRetry = false

                googleAPI.batchCreateEvents(requests) { [weak self] result in
                    guard let self = self else {
                        semaphore.signal()
                        return
                    }

                    switch result {
                    case .success(let batchResult):
                        // Check if all failures are rate limit errors
                        let rateLimitFailures = batchResult.failures.filter { (_, error) in
                            let desc = error.localizedDescription.lowercased()
                            return desc.contains("403") || desc.contains("quota") || desc.contains("rate")
                        }

                        if rateLimitFailures.count == batchResult.failures.count && !batchResult.failures.isEmpty && batchResult.success.isEmpty {
                            // All failures are rate limit errors, retry the whole batch
                            shouldRetry = true
                        } else {
                            print("  -> Batch \(batchIndex + 1) complete:")
                            print("     ✓ Success: \(batchResult.success.count) events")
                            if batchResult.failures.count > 0 {
                                print("     ✗ Failures: \(batchResult.failures.count) events")
                            }

                            // Save successful creates to database
                            for (itemIndex, googleEventID) in batchResult.success {
                                if itemIndex < batch.count {
                                    let event = batch[itemIndex]
                                    let occurrenceKey = self.makeOccurrenceKey(for: event)
                                    let currentHash = EventConverter.calculateContentHash(event)
                                    self.syncDatabase.upsertRecord(
                                        macEventID: occurrenceKey,
                                        googleEventID: googleEventID,
                                        macLastModified: event.lastModifiedDate ?? Date(),
                                        sourceCalendar: event.calendar.title,
                                        contentHash: currentHash
                                    )
                                }
                            }

                            // Report non-rate-limit failures
                            for (failedIndex, error) in batchResult.failures {
                                if failedIndex < batch.count {
                                    let event = batch[failedIndex]
                                    print("     ✗ Failed to create '\(event.title ?? "Untitled")': \(error.localizedDescription)")
                                }
                            }
                            batchCompleted = true
                        }

                    case .failure(let error):
                        let desc = error.localizedDescription.lowercased()
                        if desc.contains("403") || desc.contains("quota") || desc.contains("rate") {
                            shouldRetry = true
                        } else {
                            print("  -> Batch \(batchIndex + 1) failed: \(error.localizedDescription)")
                            batchCompleted = true
                        }
                    }

                    semaphore.signal()
                }

                semaphore.wait()

                if shouldRetry {
                    retryCount += 1
                    if retryCount > maxRetries {
                        print("  -> Batch \(batchIndex + 1) failed after \(maxRetries) retries due to rate limiting")
                        print("     These events will be created on the next sync cycle")
                        batchCompleted = true
                    }
                }
            }
        }

        print("\n  -> Batch creation complete")
    }

    private func recreateEventInGoogle(event: EKEvent, oldGoogleEventID: String) {
        guard let googleAPI = googleAPI,
              let config = config,
              let googleConfig = config.google else {
            return
        }

        let occurrenceKey = makeOccurrenceKey(for: event)
        let googleEvent = EventConverter.toGoogleCalendarEvent(event, config: config)
        let currentHash = EventConverter.calculateContentHash(event)

        let semaphore = DispatchSemaphore(value: 0)

        googleAPI.createEvent(googleEvent, calendarID: googleConfig.calendarID) { [weak self] result in
            guard let self = self else {
                semaphore.signal()
                return
            }

            switch result {
            case .success(let newGoogleEventID):
                print("  -> Successfully recreated in Google Calendar (new ID: \(newGoogleEventID))")

                // Update database with new Google event ID and content hash
                self.syncDatabase.upsertRecord(
                    macEventID: occurrenceKey,
                    googleEventID: newGoogleEventID,
                    macLastModified: event.lastModifiedDate ?? Date(),
                    sourceCalendar: event.calendar.title,
                    contentHash: currentHash
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

        // Find records for deleted events
        var deletedRecords: [(macEventID: String, googleEventID: String)] = []

        for record in relevantRecords {
            // If event is in database but not in current Mac events, it was deleted
            if !currentMacEventIDs.contains(record.macEventID) {
                deletedRecords.append((macEventID: record.macEventID, googleEventID: record.googleEventID))
            }
        }

        if deletedRecords.isEmpty {
            print("No deleted events detected")
            return
        }

        print("\n🗑️  Found \(deletedRecords.count) deleted event(s), removing from Google Calendar...")

        // Use batch delete for efficiency
        let batchSize = 100
        let batches = stride(from: 0, to: deletedRecords.count, by: batchSize).map {
            Array(deletedRecords[$0..<min($0 + batchSize, deletedRecords.count)])
        }

        var totalDeleted = 0
        var totalFailed = 0

        for (batchIndex, batch) in batches.enumerated() {
            let eventIDs = batch.map { $0.googleEventID }

            let semaphore = DispatchSemaphore(value: 0)

            googleAPI.batchDeleteEvents(eventIDs: eventIDs, calendarID: googleConfig.calendarID) { [weak self] result in
                guard let self = self else {
                    semaphore.signal()
                    return
                }

                switch result {
                case .success(let batchResult):
                    // Remove successfully deleted events from database
                    for successIndex in batchResult.success {
                        if successIndex < batch.count {
                            let record = batch[successIndex]
                            self.syncDatabase.removeRecord(macEventID: record.macEventID)
                            totalDeleted += 1
                        }
                    }
                    totalFailed += batchResult.failures.count

                    if batches.count > 1 {
                        print("  -> Batch \(batchIndex + 1)/\(batches.count): \(batchResult.success.count) deleted, \(batchResult.failures.count) failed")
                    }

                case .failure(let error):
                    print("  -> Batch \(batchIndex + 1) failed: \(error.localizedDescription)")
                    totalFailed += batch.count
                }

                semaphore.signal()
            }

            semaphore.wait()
        }

        if totalDeleted > 0 {
            print("\n✓ Deleted \(totalDeleted) event(s) from Google Calendar")
        }
        if totalFailed > 0 {
            print("⚠️  Failed to delete \(totalFailed) event(s)")
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

    // MARK: - Cleanup Functions

    /// Delete all events from Google Calendar that were created by this sync tool
    /// Identifies events by checking extendedProperties.private.macEventID
    /// This is safe because it only deletes events created by this tool
    func deleteAllSyncedGoogleEvents(completion: @escaping () -> Void) {
        guard let googleAPI = googleAPI,
              let config = config,
              let googleConfig = config.google else {
            print("Google API not configured")
            completion()
            return
        }

        print("\n=== Deleting all synced events from Google Calendar ===")
        print("This will delete ONLY events created by this sync tool")
        print("(Events are identified by extendedProperties.private.macEventID)")

        // Fetch all events from Google Calendar
        print("Fetching events from Google Calendar...")
        googleAPI.listEvents(calendarID: googleConfig.calendarID) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let allEvents):
                print("Found \(allEvents.count) total event(s) in Google Calendar")

                // Filter events that have macEventID (created by this tool)
                let syncedEvents = allEvents.filter { event in
                    event.extendedProperties?.private?["macEventID"] != nil
                }

                print("Found \(syncedEvents.count) event(s) created by this sync tool")

                if syncedEvents.isEmpty {
                    print("No synced events to delete")
                    completion()
                    return
                }

                // Ask for confirmation
                print("\n⚠️  WARNING: This will delete \(syncedEvents.count) event(s) from Google Calendar!")
                print("These are events that were created by this sync tool.")
                print("This action cannot be undone.")
                print("Type 'yes' to continue or anything else to cancel: ", terminator: "")

                guard let input = readLine(), input.lowercased() == "yes" else {
                    print("Deletion cancelled")
                    completion()
                    return
                }

                // Delete the synced events
                self.deleteSyncedEventsInBatches(
                    events: syncedEvents,
                    googleAPI: googleAPI,
                    calendarID: googleConfig.calendarID,
                    completion: completion
                )

            case .failure(let error):
                print("Failed to fetch events: \(error.localizedDescription)")
                completion()
            }
        }
    }

    /// Delete all events from Google Calendar that contain sync marker in description
    /// This catches older events that may not have macEventID in extendedProperties
    func deleteAllSyncedGoogleEventsByDescription(completion: @escaping () -> Void) {
        guard let googleAPI = googleAPI,
              let config = config,
              let googleConfig = config.google else {
            print("Google API not configured")
            completion()
            return
        }

        print("\n=== Deleting all synced events from Google Calendar (by description) ===")
        print("This will delete events with '[Synced from Mac Calendar' in description")

        // Fetch all events from Google Calendar with wide time range
        print("Fetching events from Google Calendar...")
        let pastDate = Calendar.current.date(byAdding: .year, value: -5, to: Date())!
        let futureDate = Calendar.current.date(byAdding: .year, value: 5, to: Date())!

        googleAPI.listEvents(calendarID: googleConfig.calendarID, timeMin: pastDate, timeMax: futureDate) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let allEvents):
                print("Found \(allEvents.count) total event(s) in Google Calendar")

                // Debug: Show sample of event descriptions
                print("\n[DEBUG] Sample of first 10 event descriptions:")
                for (index, event) in allEvents.prefix(10).enumerated() {
                    let desc = event.description ?? "(no description)"
                    let preview = String(desc.prefix(100)).replacingOccurrences(of: "\n", with: "\\n")
                    print("  [\(index)] \(event.summary ?? "Untitled"): \(preview)")
                }

                // Filter events that have sync marker in description
                let syncedEvents = allEvents.filter { event in
                    if let description = event.description {
                        return description.contains("[Synced from Mac Calendar")
                    }
                    return false
                }

                // Also include events with macEventID for completeness
                let eventsWithMacID = allEvents.filter { event in
                    event.extendedProperties?.private?["macEventID"] != nil
                }

                // Merge both sets (using Set to avoid duplicates)
                var eventIDsToDelete = Set<String>()
                for event in syncedEvents {
                    eventIDsToDelete.insert(event.id)
                }
                for event in eventsWithMacID {
                    eventIDsToDelete.insert(event.id)
                }

                let eventsToDelete = allEvents.filter { eventIDsToDelete.contains($0.id) }
                let eventsToKeep = allEvents.filter { !eventIDsToDelete.contains($0.id) }

                print("\nFound \(syncedEvents.count) event(s) with sync marker in description")
                print("Found \(eventsWithMacID.count) event(s) with macEventID")
                print("Total unique events to delete: \(eventsToDelete.count)")
                print("Events that will NOT be deleted: \(eventsToKeep.count)")

                // Show sample of events TO DELETE
                print("\n[DEBUG] Sample of events TO BE DELETED (first 5):")
                for (index, event) in eventsToDelete.prefix(5).enumerated() {
                    let desc = event.description ?? "(no description)"
                    let preview = String(desc.prefix(80)).replacingOccurrences(of: "\n", with: "\\n")
                    print("  [\(index)] \(event.summary ?? "Untitled")")
                    print("       desc: \(preview)")
                }

                // Show sample of events NOT to delete
                print("\n[DEBUG] Sample of events that will be KEPT (first 5):")
                for (index, event) in eventsToKeep.prefix(5).enumerated() {
                    let desc = event.description ?? "(no description)"
                    let preview = String(desc.prefix(80)).replacingOccurrences(of: "\n", with: "\\n")
                    print("  [\(index)] \(event.summary ?? "Untitled")")
                    print("       desc: \(preview)")
                }

                if eventsToDelete.isEmpty {
                    print("No synced events to delete")
                    completion()
                    return
                }

                // Ask for confirmation
                print("\n⚠️  WARNING: This will delete \(eventsToDelete.count) event(s) from Google Calendar!")
                print("Events that will be KEPT: \(eventsToKeep.count)")
                print("This action cannot be undone.")
                print("Type 'yes' to continue or anything else to cancel: ", terminator: "")

                guard let input = readLine(), input.lowercased() == "yes" else {
                    print("Deletion cancelled")
                    completion()
                    return
                }

                // Delete the synced events
                self.deleteSyncedEventsInBatches(
                    events: eventsToDelete,
                    googleAPI: googleAPI,
                    calendarID: googleConfig.calendarID,
                    completion: completion
                )

            case .failure(let error):
                print("Failed to fetch events: \(error.localizedDescription)")
                completion()
            }
        }
    }

    private func deleteSyncedEventsInBatches(
        events: [GoogleCalendarAPI.CalendarEventResponse],
        googleAPI: GoogleCalendarAPI,
        calendarID: String,
        completion: @escaping () -> Void
    ) {
        let eventIDs = events.map { $0.id }
        let batchSize = 100
        let batches = stride(from: 0, to: eventIDs.count, by: batchSize).map {
            Array(eventIDs[$0..<min($0 + batchSize, eventIDs.count)])
        }

        print("\nDeleting \(eventIDs.count) events in \(batches.count) batch(es)...")

        var totalDeleted = 0
        var totalFailed = 0
        var currentBatchIndex = 0

        func processNextBatch() {
            guard currentBatchIndex < batches.count else {
                // All batches complete
                print("\n=== Deletion complete ===")
                print("  Successfully deleted: \(totalDeleted)")
                print("  Failed: \(totalFailed)")

                // Clear the database
                print("\nClearing sync database...")
                self.syncDatabase.clearAll()
                print("Database cleared")

                completion()
                return
            }

            let batch = batches[currentBatchIndex]
            let batchNumber = currentBatchIndex + 1

            print("  -> Batch \(batchNumber)/\(batches.count): Deleting \(batch.count) events...")

            googleAPI.batchDeleteEvents(eventIDs: batch, calendarID: calendarID) { result in
                switch result {
                case .success(let batchResult):
                    totalDeleted += batchResult.success.count
                    totalFailed += batchResult.failures.count

                    print("  -> Batch \(batchNumber) complete: \(batchResult.success.count) deleted, \(batchResult.failures.count) failed")

                    for (index, error) in batchResult.failures {
                        if index < batch.count {
                            print("     ✗ Failed to delete \(batch[index]): \(error.localizedDescription)")
                        }
                    }

                case .failure(let error):
                    totalFailed += batch.count
                    print("  -> Batch \(batchNumber) failed: \(error.localizedDescription)")
                }

                currentBatchIndex += 1

                // Add delay between batches to be safe with rate limits
                if currentBatchIndex < batches.count {
                    Thread.sleep(forTimeInterval: 1.0)
                }

                processNextBatch()
            }
        }

        processNextBatch()
    }
}

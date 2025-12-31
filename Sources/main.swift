import AppKit
import Foundation

print("MacCalendarSync starting...")

// Check for cleanup command
if CommandLine.arguments.count > 1 {
    let arg = CommandLine.arguments[1]

    if arg == "--cleanup" {
        print("\n🧹 Cleanup mode activated (macEventID-based)")
        let syncApp = CalendarSyncApp()
        syncApp.initializeForCleanup()

        // Run cleanup
        let semaphore = DispatchSemaphore(value: 0)
        syncApp.deleteAllSyncedGoogleEvents {
            semaphore.signal()
        }
        semaphore.wait()

        print("\nCleanup complete. Exiting...")
        exit(0)
    }

    if arg == "--cleanup-all" {
        print("\n🧹 Full cleanup mode activated (description-based)")
        print("This will delete ALL events with '[Synced from Mac Calendar' in description")
        let syncApp = CalendarSyncApp()
        syncApp.initializeForCleanup()

        // Run cleanup
        let semaphore = DispatchSemaphore(value: 0)
        syncApp.deleteAllSyncedGoogleEventsByDescription {
            semaphore.signal()
        }
        semaphore.wait()

        print("\nFull cleanup complete. Exiting...")
        exit(0)
    }

    if arg == "--help" {
        print("""

        Usage: MacCalendarSync [options]

        Options:
          --cleanup      Delete events with macEventID (newer synced events)
          --cleanup-all  Delete ALL events with '[Synced from Mac Calendar' in description
                         (includes older events without macEventID)
          --help         Show this help message

        Without options: Run as menu bar app with continuous sync
        """)
        exit(0)
    }
}

// Create the application
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Menu bar only, no dock icon

// Create sync app and menu bar controller
let syncApp = CalendarSyncApp()
let menuBarController = MenuBarController(syncApp: syncApp)

// Setup menu bar
menuBarController.setup()

// Start sync
syncApp.run()

// Run the app
app.run()

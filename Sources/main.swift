import AppKit
import Foundation

print("MacCalendarSync starting...")

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

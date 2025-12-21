import AppKit
import EventKit

class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let syncApp: CalendarSyncApp
    private var lastSyncTime: Date?

    init(syncApp: CalendarSyncApp) {
        self.syncApp = syncApp
        super.init()
    }

    func setup() {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "Calendar Sync")
            button.image?.isTemplate = true
        }

        // Build menu
        updateMenu()

        // Listen for sync completion notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(syncCompleted),
            name: NSNotification.Name("CalendarSyncCompleted"),
            object: nil
        )
    }

    @objc private func syncCompleted() {
        lastSyncTime = Date()
        DispatchQueue.main.async { [weak self] in
            self?.updateMenu()
        }
    }

    private func updateMenu() {
        let menu = NSMenu()

        // Sync status
        let syncEnabled = syncApp.isSyncEnabled
        let statusTitle = syncEnabled ? "✓ 同期有効" : "○ 同期停止中"
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Sync toggle
        let toggleTitle = syncEnabled ? "同期を停止" : "同期を開始"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleSync), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        // Manual sync
        let syncNowItem = NSMenuItem(title: "今すぐ同期", action: #selector(syncNow), keyEquivalent: "s")
        syncNowItem.target = self
        syncNowItem.isEnabled = syncEnabled
        menu.addItem(syncNowItem)

        menu.addItem(NSMenuItem.separator())

        // Calendar selection submenu
        let calendarMenu = NSMenu()
        let calendars = syncApp.getAvailableCalendars()
        let targetCalendars = syncApp.getTargetCalendarNames()

        if calendars.isEmpty {
            let noCalItem = NSMenuItem(title: "(カレンダーなし)", action: nil, keyEquivalent: "")
            noCalItem.isEnabled = false
            calendarMenu.addItem(noCalItem)
        } else {
            for calendar in calendars {
                let calItem = NSMenuItem(
                    title: calendar.title,
                    action: #selector(toggleCalendar(_:)),
                    keyEquivalent: ""
                )
                calItem.target = self
                calItem.representedObject = calendar.title
                calItem.state = targetCalendars.contains(calendar.title) ? .on : .off
                calendarMenu.addItem(calItem)
            }
        }

        let calendarMenuItem = NSMenuItem(title: "同期対象カレンダー", action: nil, keyEquivalent: "")
        calendarMenuItem.submenu = calendarMenu
        menu.addItem(calendarMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Formatting options submenu
        let formatMenu = NSMenu()

        let locationItem = NSMenuItem(
            title: "場所を詳細欄に追記",
            action: #selector(toggleLocationInDescription),
            keyEquivalent: ""
        )
        locationItem.target = self
        locationItem.state = syncApp.isLocationInDescriptionEnabled ? .on : .off
        formatMenu.addItem(locationItem)

        let formatMenuItem = NSMenuItem(title: "フォーマット設定", action: nil, keyEquivalent: "")
        formatMenuItem.submenu = formatMenu
        menu.addItem(formatMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Last sync time
        let lastSyncTitle: String
        if let lastSync = lastSyncTime {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            lastSyncTitle = "最終同期: \(formatter.string(from: lastSync))"
        } else {
            lastSyncTitle = "最終同期: --"
        }
        let lastSyncItem = NSMenuItem(title: lastSyncTitle, action: nil, keyEquivalent: "")
        lastSyncItem.isEnabled = false
        menu.addItem(lastSyncItem)

        // Sync interval info
        let intervalSeconds = syncApp.getSyncIntervalSeconds()
        let intervalMinutes = intervalSeconds / 60
        let intervalTitle = "同期間隔: \(intervalMinutes)分"
        let intervalItem = NSMenuItem(title: intervalTitle, action: nil, keyEquivalent: "")
        intervalItem.isEnabled = false
        menu.addItem(intervalItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "終了", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleSync() {
        if syncApp.isSyncEnabled {
            syncApp.stopSync()
        } else {
            syncApp.startSync()
        }
        updateMenu()
    }

    @objc private func syncNow() {
        syncApp.syncNow()
    }

    @objc private func toggleCalendar(_ sender: NSMenuItem) {
        guard let calendarName = sender.representedObject as? String else { return }
        syncApp.toggleCalendar(calendarName)
        updateMenu()
    }

    @objc private func toggleLocationInDescription() {
        syncApp.toggleLocationInDescription()
        updateMenu()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

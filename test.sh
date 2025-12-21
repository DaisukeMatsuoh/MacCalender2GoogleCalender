#!/bin/bash

echo "=== MacCalendarSync Test ==="
echo ""
echo "This will run the app for 5 seconds to check if it can read your local calendars."
echo ""
echo "Prerequisites:"
echo "1. You have granted Terminal/iTerm calendar access permissions"
echo "2. You have created at least one local calendar in Calendar.app (File > New Calendar > On My Mac)"
echo "3. You have added at least one event to that local calendar"
echo ""
echo "Press Enter to continue or Ctrl+C to cancel..."
read

echo ""
echo "Starting MacCalendarSync..."
echo "----------------------------------------"

# Run the app in background
.build/debug/MacCalendarSync &
PID=$!

# Wait 5 seconds
sleep 5

# Kill the app
kill $PID 2>/dev/null

echo "----------------------------------------"
echo ""
echo "Test complete!"
echo ""
echo "If you see calendar information above, the app is working correctly."
echo "If you see 'No local calendars found', please create a local calendar in Calendar.app."

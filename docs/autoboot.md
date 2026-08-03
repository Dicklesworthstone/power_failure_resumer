# Post-boot notifications

`pfr --notify` is intentionally conservative: it discovers sessions, saves a
fresh plan only when the result qualifies, and may show a desktop notification.
It never opens Ghostty or resumes a session. A notification is sent for a
`high` confidence cluster, or for `medium` confidence with at least three
resumeable sessions. Its suggested next step is:

```bash
pfr --last-plan --pick
```

On macOS, `pfr` uses `osascript`; on Linux it uses `notify-send` when that
command is installed. If neither is usable, discovery stays silent and exits
successfully. `PFR_NOTIFY_CMD` can override the notification executable for
offline tests or local integration; it receives the title and notification body
as two arguments.

## macOS LaunchAgent example

Save this as `~/Library/LaunchAgents/com.example.pfr-notify.plist`, replacing
the `pfr` path with the path used on your machine. `RunAtLoad` runs the quiet
check when you log in; it does not open sessions.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.example.pfr-notify</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/YOUR-USER/.local/bin/pfr</string>
    <string>--notify</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
```

Load it for the current login session with:

```bash
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.example.pfr-notify.plist"
```

To test the command itself before installing the LaunchAgent, run `pfr --notify`
from a terminal after a reboot. Review the resulting plan with
`pfr --last-plan --pick`; this is always a separate, explicit action.

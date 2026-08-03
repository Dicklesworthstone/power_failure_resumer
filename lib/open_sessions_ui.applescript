#!/usr/bin/osascript
-- Open a Ghostty surface using defaults as much as possible.
--
-- Preferred path (tip Ghostty scripting dictionary):
--   new tab/window with working directory set, then `input text` the resume command.
--   No keystroke simulation, no clipboard, survives Cmd+T rebinds.
--
-- Fallback path (System Events):
--   Used only when native scripting cannot create a surface OR cannot deliver input.
--   If a surface was created but input failed, fallback pastes into the *front*
--   terminal without opening another tab (avoids double-open).
--
-- Args:
--   1: working directory
--   2: resume command (e.g. "cod resume <uuid>" or "cc --resume <uuid>")
--   3: mode — "tab" (default) or "window"
--   4: "1" reserved (ignored); always opens a dedicated surface
--   5: settle delay seconds after creating a surface (default 0.55)

on shellQuote(p)
	set s to p as text
	set oldDelims to AppleScript's text item delimiters
	set AppleScript's text item delimiters to "'"
	set parts to text items of s
	set AppleScript's text item delimiters to "'\\''"
	set s to parts as text
	set AppleScript's text item delimiters to oldDelims
	return "'" & s & "'"
end shellQuote

on run argv
	if (count of argv) < 2 then
		error "usage: open_sessions_ui.applescript <cwd> <resume_cmd> [tab|window] [is_first 0|1] [settle_secs]"
	end if

	set workDir to item 1 of argv as text
	set resumeCmd to item 2 of argv as text
	set openMode to "tab"
	set settleSecs to 0.55

	if (count of argv) ≥ 3 then set openMode to item 3 of argv as text
	-- argv 4 (is_first) ignored: always open a dedicated tab/window.
	if (count of argv) ≥ 5 then
		try
			set settleSecs to (item 5 of argv as real)
		end try
	end if

	set lineToType to "cd " & my shellQuote(workDir) & " && " & resumeCmd

	set createdSurface to false
	set nativeErrText to ""
	set termObj to missing value

	-- ---------- Preferred: Ghostty scripting (no keystrokes) ----------
	try
		tell application "Ghostty"
			activate
			delay 0.12

			set cfg to new surface configuration
			set initial working directory of cfg to workDir
			try
				set wait after command of cfg to true
			end try

			if openMode is "window" then
				set w to new window with configuration cfg
				delay settleSecs
				set termObj to focused terminal of selected tab of w
			else
				try
					set win to front window
					set t to new tab in win with configuration cfg
					delay settleSecs
					set termObj to focused terminal of t
				on error
					set w to new window with configuration cfg
					delay settleSecs
					set termObj to focused terminal of selected tab of w
				end try
			end if
		end tell

		if termObj is missing value then error "no terminal surface"
		set createdSurface to true

		tell application "Ghostty"
			-- Retry once: first attempt can race shell rc on a brand-new surface.
			try
				input text lineToType & linefeed to termObj
			on error
				delay (settleSecs + 0.25)
				input text lineToType & linefeed to termObj
			end try
		end tell
		return "native"
	on error nativeErr
		set nativeErrText to nativeErr as text
	end try

	-- ---------- Fallback: System Events ----------
	-- If we already created a surface, only re-deliver input (no new Cmd+T).
	tell application "Ghostty" to activate
	delay 0.15

	set oldClip to missing value
	try
		set oldClip to the clipboard as text
	end try
	set the clipboard to lineToType

	tell application "System Events"
		if not (exists process "Ghostty") then
			error "Ghostty process not found for UI automation (native also failed: " & nativeErrText & ")"
		end if
		tell process "Ghostty"
			set frontmost to true
			delay 0.1

			if createdSurface is false then
				if openMode is "window" then
					keystroke "n" using command down
				else
					keystroke "t" using command down
				end if
				delay settleSecs
			else
				delay 0.15
			end if

			keystroke "u" using control down
			delay 0.06
			keystroke "v" using command down
			delay 0.3
			keystroke return
		end tell
	end tell

	delay 0.12
	try
		if oldClip is missing value then
			set the clipboard to ""
		else
			set the clipboard to oldClip
		end if
	end try
	return "fallback"
end run

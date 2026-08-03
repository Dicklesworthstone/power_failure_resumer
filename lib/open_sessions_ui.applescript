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

on trimTrailingWhitespace(valueText)
	set trimmedText to valueText as text
	repeat while (length of trimmedText) > 0
		set finalChar to character -1 of trimmedText
		if finalChar is not in {space, return, linefeed, tab} then exit repeat
		if (length of trimmedText) = 1 then
			set trimmedText to ""
		else
			set trimmedText to text 1 thru -2 of trimmedText
		end if
	end repeat
	return trimmedText
end trimTrailingWhitespace

on terminalShowsPrompt(termObj)
	-- Prefer Ghostty's scripting contents when available. The current Ghostty
	-- dictionary may not expose it, so read the focused terminal's accessible
	-- text area as an equivalent contents source before conceding the fallback.
	try
		tell application "Ghostty"
			set screenText to contents of termObj as text
		end tell
	on error
		try
			tell application "System Events"
				tell process "Ghostty"
					set screenText to value of text area 1 of scroll area 1 of UI element 1 of UI element 1 of window 1 as text
				end tell
			end tell
		on error
			return missing value
		end try
	end try

	set screenText to my trimTrailingWhitespace(screenText)
	if (length of screenText) = 0 then return false
	set finalChar to character -1 of screenText
	return finalChar is in "$%#>❯❱➜"
end terminalShowsPrompt

on waitForShellPrompt(termObj, settleSecs)
	-- Poll at roughly 150 ms for no more than 4× --settle. A readable terminal
	-- without a recognized prompt simply uses the bounded timeout; an unreadable
	-- terminal preserves the former fixed-settle behavior.
	set settleMaxSecs to settleSecs * 4
	if settleMaxSecs < 0 then set settleMaxSecs to 0
	set elapsedSecs to 0
	repeat while elapsedSecs < settleMaxSecs
		set promptVisible to my terminalShowsPrompt(termObj)
		if promptVisible is missing value then
			delay settleSecs
			return false
		end if
		if promptVisible then return true
		set remainingSecs to settleMaxSecs - elapsedSecs
		set pollSecs to 0.15
		if remainingSecs < pollSecs then set pollSecs to remainingSecs
		if pollSecs > 0 then delay pollSecs
		set elapsedSecs to elapsedSecs + pollSecs
	end repeat
	return false
end waitForShellPrompt

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
	set newTab to missing value
	set newWindow to missing value

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
				set newWindow to new window with configuration cfg
				set createdSurface to true
				try
					set termObj to focused terminal of selected tab of newWindow
				on error
					delay 0.25
					set termObj to focused terminal of selected tab of newWindow
				end try
			else
				try
					set win to front window
					set newTab to new tab in win with configuration cfg
					set createdSurface to true
				on error
					set newWindow to new window with configuration cfg
					set createdSurface to true
				end try
				try
					if newTab is not missing value then
						set termObj to focused terminal of newTab
					else
						set termObj to focused terminal of selected tab of newWindow
					end if
				on error
					delay 0.25
					if newTab is not missing value then
						set termObj to focused terminal of newTab
					else
						set termObj to focused terminal of selected tab of newWindow
					end if
				end try
			end if
		end tell

		if termObj is missing value then error "no terminal surface"
		try
			tell application "Ghostty" to focus termObj
		end try
		my waitForShellPrompt(termObj, settleSecs)

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
		-- Preserve the native value. Coercing to text destroys image, file, and
		-- rich clipboard contents when the fallback path runs.
		set oldClip to the clipboard
	on error clipErr
		error "cannot preserve clipboard for UI fallback: " & (clipErr as text)
	end try
	set the clipboard to lineToType

	try
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
				-- The fallback has no stable terminal reference for the new tab/window.
				-- Keep the fixed delay here: probing window 1 could see the old surface's
				-- prompt before the Cmd+T/Cmd+N focus transition completes.
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
	on error fallbackErr number fallbackErrNum
		try
			set the clipboard to oldClip
		end try
		error fallbackErr number fallbackErrNum
	end try

	delay 0.12
	try
		set the clipboard to oldClip
	end try
	return "fallback"
end run

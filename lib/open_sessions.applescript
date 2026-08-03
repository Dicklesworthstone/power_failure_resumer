#!/usr/bin/osascript
-- Open one Ghostty tab/window via surface configuration + delayed input text.
-- Avoids `initial input` races with slow interactive zsh startup.
--
-- Args:
--   1: working directory
--   2: resume command text (NOT preformatted multi-line shell; just "cod resume …")
--   3: mode — "tab" (default) or "window"
--   4: optional settle seconds (default 0.45)

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
		error "usage: open_sessions.applescript <cwd> <resume_cmd> [tab|window] [settle_secs]"
	end if

	set workDir to item 1 of argv as text
	set resumeCmd to item 2 of argv as text
	set openMode to "tab"
	set settleSecs to 0.45
	if (count of argv) ≥ 3 then set openMode to item 3 of argv as text
	if (count of argv) ≥ 4 then
		try
			set settleSecs to (item 4 of argv as real)
		end try
	end if

	set lineToType to "cd " & my shellQuote(workDir) & " && " & resumeCmd

	tell application "Ghostty"
		activate
		delay 0.1

		set cfg to new surface configuration
		set initial working directory of cfg to workDir
		try
			set wait after command of cfg to true
		end try

		set term to missing value
		set newTab to missing value
		set newWindow to missing value
		if openMode is "window" then
			set newWindow to new window with configuration cfg
			try
				set term to focused terminal of selected tab of newWindow
			on error
				delay 0.25
				set term to focused terminal of selected tab of newWindow
			end try
		else
			try
				set win to front window
				set newTab to new tab in win with configuration cfg
			on error
				set newWindow to new window with configuration cfg
			end try
			try
				if newTab is not missing value then
					set term to focused terminal of newTab
				else
					set term to focused terminal of selected tab of newWindow
				end if
			on error
				delay 0.25
				if newTab is not missing value then
					set term to focused terminal of newTab
				else
					set term to focused terminal of selected tab of newWindow
				end if
			end try
		end if

		if term is missing value then error "no terminal surface available"
		try
			focus term
		end try
		my waitForShellPrompt(term, settleSecs)

		-- Prefer input text over initial-input (slow zsh / starship startup).
		-- Retry once: first attempt can race shell rc on a brand-new surface.
		try
			input text lineToType & linefeed to term
		on error
			delay (settleSecs + 0.25)
			input text lineToType & linefeed to term
		end try
	end tell
end run

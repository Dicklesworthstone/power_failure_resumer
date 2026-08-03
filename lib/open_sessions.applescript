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
			delay settleSecs
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
			delay settleSecs
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

		-- Prefer delayed input text over initial-input (slow zsh / starship startup).
		-- Retry once: first attempt can race shell rc on a brand-new surface.
		try
			input text lineToType & linefeed to term
		on error
			delay (settleSecs + 0.25)
			input text lineToType & linefeed to term
		end try
	end tell
end run

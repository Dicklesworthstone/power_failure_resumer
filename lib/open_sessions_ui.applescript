#!/usr/bin/osascript
-- Open Ghostty surfaces that RUN each session's command directly (ui driver).
--
-- Same native path as open_sessions.applescript: the surface configuration
-- `command` property launches the user's login shell with the resume command,
-- so nothing is typed at a prompt. The previous `input text` approach pasted
-- the line (bracketed paste), which zsh leaves sitting unsubmitted in the
-- line editor — tabs opened but nothing ran. All surfaces open in ONE
-- osascript invocation for speed.
--
-- Fallback path (System Events, per surface): used only when native surface
-- creation fails. Opens Cmd+T/Cmd+N in the default shell, pastes
-- "cd <dir> && <cmd>" and presses Return. Needs Accessibility. The clipboard
-- is preserved around the whole batch when any fallback fires.
--
-- Args:
--   1: mode — "tab" (default) or "window"
--   2: settle seconds after a fallback surface opens (default 0.55)
--   3: inter-surface delay seconds
--   4: login shell path (e.g. /bin/zsh)
--   5,6 / 7,8 / …: pairs of <working dir> <command text>
--
-- Output: one line per pair — "ok", "ok fallback", or "fail <reason>". The
-- caller maps line N to pair N; one failed surface must not abort the rest.

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

on oneLine(t)
	-- Result lines map 1:1 to pairs; an error message containing newlines
	-- would shift every later pair's result.
	set s to t as text
	set oldDelims to AppleScript's text item delimiters
	set AppleScript's text item delimiters to {return, linefeed}
	set parts to text items of s
	set AppleScript's text item delimiters to " "
	set s to parts as text
	set AppleScript's text item delimiters to oldDelims
	return s
end oneLine

on launchCommand(shellPath, payload)
	-- Run the payload in an interactive login shell (aliases/functions from rc
	-- files apply), then drop back to a fresh interactive shell so the tab
	-- stays usable after the agent exits.
	set keepAlive to payload & "; exec " & shellPath & " -il"
	return shellPath & " -il -c " & my shellQuote(keepAlive)
end launchCommand

on openOneSurface(workDir, cmdText, openMode, shellPath)
	tell application "Ghostty"
		set cfg to new surface configuration
		set initial working directory of cfg to workDir
		set command of cfg to my launchCommand(shellPath, cmdText)
		try
			set wait after command of cfg to true
		end try
		if openMode is "window" then
			set newWindow to new window with configuration cfg
		else
			try
				set win to front window
				set newTab to new tab in win with configuration cfg
			on error
				set newWindow to new window with configuration cfg
			end try
		end if
	end tell
end openOneSurface

on fallbackOneSurface(workDir, cmdText, openMode, settleSecs)
	-- Native creation failed entirely: open a default-shell surface with
	-- keystrokes and paste the command. The pasted line needs its own cd
	-- because the fallback surface cannot set a working directory.
	set lineToType to "cd " & my shellQuote(workDir) & " && " & cmdText
	set the clipboard to lineToType
	tell application "System Events"
		if not (exists process "Ghostty") then
			error "Ghostty process not found for UI automation"
		end if
		tell process "Ghostty"
			set frontmost to true
			delay 0.1
			if openMode is "window" then
				keystroke "n" using command down
			else
				keystroke "t" using command down
			end if
			-- The fallback has no terminal reference for the new surface; a
			-- fixed settle lets the default shell finish its rc files.
			delay settleSecs
			keystroke "u" using control down
			delay 0.06
			keystroke "v" using command down
			delay 0.3
			keystroke return
		end tell
	end tell
end fallbackOneSurface

on run argv
	if (count of argv) < 6 then
		error "usage: open_sessions_ui.applescript <tab|window> <settle_secs> <delay_secs> <shell> <cwd> <cmd> [<cwd> <cmd> …]"
	end if

	set openMode to item 1 of argv as text
	set settleSecs to 0.55
	try
		set settleSecs to (item 2 of argv as real)
	end try
	set delaySecs to 0.1
	try
		set delaySecs to (item 3 of argv as real)
	end try
	if delaySecs < 0 then set delaySecs to 0
	set shellPath to item 4 of argv as text

	if ((count of argv) - 4) mod 2 is not 0 then
		error "argv must contain <cwd> <cmd> pairs after the fixed arguments"
	end if

	tell application "Ghostty" to activate
	delay 0.1

	set oldClip to missing value
	set clipSaved to false
	set resultLines to {}
	set pairIndex to 5
	repeat while pairIndex < (count of argv)
		set workDir to item pairIndex of argv as text
		set cmdText to item (pairIndex + 1) of argv as text
		try
			my openOneSurface(workDir, cmdText, openMode, shellPath)
			set end of resultLines to "ok"
		on error nativeErr
			-- Preserve the native clipboard value once for the whole batch.
			-- Coercing to text destroys image/file/rich clipboard contents.
			if clipSaved is false then
				try
					set oldClip to the clipboard
					set clipSaved to true
				on error clipErr
					set end of resultLines to "fail cannot preserve clipboard for UI fallback: " & my oneLine(clipErr)
				end try
			end if
			if clipSaved then
				try
					my fallbackOneSurface(workDir, cmdText, openMode, settleSecs)
					set end of resultLines to "ok fallback"
				on error fallbackErr
					set end of resultLines to "fail native: " & my oneLine(nativeErr) & "; fallback: " & my oneLine(fallbackErr)
				end try
			end if
		end try
		set pairIndex to pairIndex + 2
		if pairIndex < (count of argv) and delaySecs > 0 then delay delaySecs
	end repeat

	if clipSaved then
		delay 0.12
		try
			set the clipboard to oldClip
		end try
	end if

	set oldDelims to AppleScript's text item delimiters
	set AppleScript's text item delimiters to linefeed
	set joined to resultLines as text
	set AppleScript's text item delimiters to oldDelims
	return joined
end run

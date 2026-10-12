-- Reference check: boot a disk in Virtual ][ and dump both hi-res pages.
-- Usage: osascript tests/tools/v2_boot_check.applescript DISK OUT_PREFIX SECONDS
--   writes OUT_PREFIX.hgr1 ($2000-$3FFF) and OUT_PREFIX.hgr2 ($4000-$5FFF)
-- Terms come from Virtual ]['s own scripting dictionary (en.lproj
-- scriptTerminology): insert ... into, restart, dump memory ... bank/into/
-- address/length. Bank 0 is assumed to be main memory.

on run argv
	set diskPath to item 1 of argv
	set outPrefix to item 2 of argv
	set bootSeconds to (item 3 of argv) as integer
	with timeout of 30 seconds
		tell application "Virtual ]["
			if (count of machines) = 0 then error "Virtual ][ has no machine window open."
			set targetMachine to front machine
			-- Drives are devices named by slot and drive, e.g. "S6D1".
			try
				eject device "S6D1" of targetMachine
			end try
			insert diskPath into device "S6D1" of targetMachine
			restart targetMachine
		end tell
	end timeout
	delay bootSeconds
	with timeout of 30 seconds
		tell application "Virtual ]["
			-- Without a ROM for the machine type, Virtual ][ shows this notice
			-- instead of booting; the caller treats "no-rom" as a skip.
			if (content of screen text of targetMachine) contains "NO SUITABLE ROM" then return "no-rom"
			dump memory targetMachine bank 0 into (outPrefix & ".hgr1") address 8192 length 8192
			dump memory targetMachine bank 0 into (outPrefix & ".hgr2") address 16384 length 8192
		end tell
	end timeout
	return "dumped"
end run

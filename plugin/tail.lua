-- plugin/tail.lua
--
-- Commands:
--   :TailEnable
--   :TailDisable
--   :TailToggle
--
--   :TailTimestampEnable
--   :TailTimestampDisable
--   :TailTimestampToggle
--
--   :TailLogLevelHlEnable
--   :TailLogLevelHlDisable
--   :TailLogLevelHlToggle
--
--   We treat files (as they may be buffered) separately from other buffers in here. As (neo)vim has problems with
--   reliable reloading buffered files, we use our own timer to watch over a files changes. The rest of this file
--   plugs that into the other code in init.lua.

local tail       = require("tail")

-- per-buffer polling / config state for FILE-tail buffers
local timers     = {} -- bufnr -> uv_timer
local file_state = {} -- bufnr -> { path, offset, partial }
local file_cfg   = {} -- bufnr -> { follow = bool, ts_enabled = bool, ts_format = string, ts_hl = string, log_level_hl = bool }

-- namespace for log level highlighting in file-tail buffers
local ns_loglevel = vim.api.nvim_create_namespace("tail-loglevel")

-- default log level highlight groups (same as init.lua)
local log_level_groups = {
	TRACE = "DiagnosticHint",
	DEBUG = "DiagnosticHint",
	INFO = "DiagnosticInfo",
	WARN = "DiagnosticWarn",
	WARNING = "DiagnosticWarn",
	ERROR = "DiagnosticError",
}

--- Highlight log level keywords in the given line range (1-based, inclusive)
---@param bufnr number
---@param start_line number 1-based start line
---@param end_line number 1-based end line (inclusive)
local function highlight_log_levels(bufnr, start_line, end_line)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

	for i, line in ipairs(lines) do
		local lnum = start_line + i - 1

		for keyword, hl_group in pairs(log_level_groups) do
			-- Use frontier pattern for word boundary matching (uppercase only)
			local pattern = "%f[%w]" .. keyword .. "%f[%W]"
			local search_start = 1

			while true do
				local match_start, match_end = line:find(pattern, search_start)
				if not match_start then
					break
				end

				vim.api.nvim_buf_set_extmark(bufnr, ns_loglevel, lnum - 1, match_start - 1, {
					end_col = match_end,
					hl_group = hl_group,
				})

				search_start = match_end + 1
			end
		end
	end
end

----------------------------------------------------------------------
-- Helper: is this buffer a regular file on disk (before tail mode)?
----------------------------------------------------------------------

local function is_regular_file_buf(bufnr)
	if vim.bo[bufnr].buftype ~= "" then
		return false
	end

	local name = vim.api.nvim_buf_get_name(bufnr)
	if not name or name == "" then
		return false
	end

	local stat = vim.loop.fs_stat(name)
	return stat ~= nil and stat.type == "file"
end

----------------------------------------------------------------------
-- Convert a real file buffer into a "tail buffer":
--   - reloads file contents from disk
--   - makes buffer 'nofile', 'tail://<path>', no swap, viewer-only
----------------------------------------------------------------------

local function make_tail_buffer_from_file(bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if not path or path == "" then
		return nil
	end

	-- reload full file from disk to avoid missing any lines
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or not lines then
		return nil
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- store original path in buffer-local var
	vim.b[bufnr].tail_file_path = path

	-- convert to scratch "tail buffer"
	vim.bo[bufnr].buftype       = "nofile"
	vim.bo[bufnr].bufhidden     = "wipe"
	vim.bo[bufnr].swapfile      = false
	vim.bo[bufnr].modifiable    = true

	-- rename so it's clearly not a real file
	vim.api.nvim_buf_set_name(bufnr, "tail://" .. path)

	-- mark as unmodified (it's just a view)
	vim.bo[bufnr].modified = false

	return path
end

----------------------------------------------------------------------
-- Follow logic for tail buffers:
--   - follow[bufnr] = true  => auto-jump to bottom on new lines
--   - follow[bufnr] = false => user scrolled up, do not jump
----------------------------------------------------------------------

local function setup_follow_autocmd(bufnr)
	local group_name = "tail_file_follow_" .. bufnr
	local group = vim.api.nvim_create_augroup(group_name, { clear = true })

	vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
		group = group,
		buffer = bufnr,
		callback = function(args)
			local b = args.buf
			local cfg = file_cfg[b]
			if not cfg then
				return
			end

			local win = vim.api.nvim_get_current_win()
			if not vim.api.nvim_win_is_valid(win) then
				return
			end
			if vim.api.nvim_win_get_buf(win) ~= b then
				return
			end

			local cur  = vim.api.nvim_win_get_cursor(win)[1]
			local last = vim.api.nvim_buf_line_count(b)

			if cur < last then
				cfg.follow = false
			else
				cfg.follow = true
			end
		end,
	})
end

local function clear_follow_autocmd(bufnr)
	local group_name = "tail_file_follow_" .. bufnr
	pcall(vim.api.nvim_del_augroup_by_name, group_name)
end

----------------------------------------------------------------------
-- Start polling a file and appending new lines into the tail buffer
----------------------------------------------------------------------

local function start_file_poller(bufnr)
	local path = vim.b[bufnr].tail_file_path
	if not path or path == "" then
		return
	end

	local stat = vim.loop.fs_stat(path)
	if not stat or not stat.size then
		return
	end

	-- initial file state: we just loaded the full file, so start at EOF
	file_state[bufnr] = {
		path    = path,
		offset  = stat.size,
		partial = "",
	}

	-- initial config for this buffer
	file_cfg[bufnr] = file_cfg[bufnr] or {
		follow       = (tail.opts and tail.opts.follow) ~= false, -- default to true
		ts_enabled   = (tail.opts and tail.opts.timestamps) == true, -- default to false
		ts_format    = (tail.opts and tail.opts.timestamp_format) or "%Y-%m-%d %H:%M:%S ",
		ts_hl        = (tail.opts and tail.opts.timestamp_highlight) or "Comment",
		log_level_hl = (tail.opts and tail.opts.log_level_hl) == true, -- default to false
	}

	-- move cursor to bottom initially
	local last = vim.api.nvim_buf_line_count(bufnr)
	if last > 0 then
		pcall(vim.api.nvim_win_set_cursor, vim.api.nvim_get_current_win(), { last, 0 })
	end

	setup_follow_autocmd(bufnr)

	if timers[bufnr] then
		return
	end

	local timer = vim.loop.new_timer()
	timers[bufnr] = timer

	timer:start(0, 1000, function()
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				if timers[bufnr] then
					timers[bufnr]:stop()
					timers[bufnr]:close()
					timers[bufnr] = nil
				end
				file_state[bufnr] = nil
				file_cfg[bufnr]   = nil
				clear_follow_autocmd(bufnr)
				return
			end

			local st  = file_state[bufnr]
			local cfg = file_cfg[bufnr]
			if not st or not cfg then
				return
			end

			local s = vim.loop.fs_stat(st.path)
			if not s or not s.size or s.size <= st.offset then
				return -- no new data
			end

			local fd = vim.loop.fs_open(st.path, "r", 438) -- 0666
			if not fd then
				return
			end

			local to_read = s.size - st.offset
			local data = vim.loop.fs_read(fd, to_read, st.offset)
			vim.loop.fs_close(fd)

			st.offset = s.size

			if not data or #data == 0 then
				return
			end

			-- prepend leftover partial from previous read
			local buf = st.partial .. data
			st.partial = ""

			local lines = {}
			local i = 1
			while true do
				local j = buf:find("\n", i, true)
				if not j then
					st.partial = buf:sub(i)
					break
				end
				table.insert(lines, buf:sub(i, j - 1))
				i = j + 1
			end

			if #lines == 0 then
				return
			end

			-- timestamps for new lines if enabled
			if cfg.ts_enabled then
				local fmt = cfg.ts_format or "%Y-%m-%d %H:%M:%S"
				local ts  = os.date(fmt)
				for idx, line in ipairs(lines) do
					-- avoid double-stamping lines that already look like timestamps
					if not line:match("^%d%d%d%d%-%d%d%-%d%d") then
						lines[idx] = ts .. " " .. line
					end
				end

				local ns_tail = vim.api.nvim_create_namespace("tail-timestamp")
				local line_offset = vim.api.nvim_buf_line_count(bufnr) - #lines

				for i = 1, #lines do
					local line = vim.api.nvim_buf_get_lines(bufnr, line_offset + i - 1,
						line_offset + i, false)[1]
					local end_col = math.min(#ts, #line)
					vim.api.nvim_buf_set_extmark(bufnr, ns_tail, line_offset + i - 1, 0, {
						end_col = end_col,
						hl_group = cfg.ts_highlight or "Comment",
					})
				end
			end

			vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
			vim.bo[bufnr].modified = false -- still just a view

			-- log level highlighting for new lines if enabled
			if cfg.log_level_hl then
				local line_count = vim.api.nvim_buf_line_count(bufnr)
				local start_line = line_count - #lines + 1
				highlight_log_levels(bufnr, start_line, line_count)
			end

			-- follow behaviour: only jump if follow=true
			if cfg.follow then
				local wins = vim.fn.win_findbuf(bufnr)
				local last_line = vim.api.nvim_buf_line_count(bufnr)
				for _, win in ipairs(wins) do
					if vim.api.nvim_win_is_valid(win) then
						pcall(vim.api.nvim_win_set_cursor, win, { last_line, 0 })
					end
				end
			end
		end)
	end)
end

local function stop_file_poller(bufnr)
	local t = timers[bufnr]
	if t then
		t:stop()
		t:close()
		timers[bufnr] = nil
	end
	file_state[bufnr] = nil
	file_cfg[bufnr]   = nil
	clear_follow_autocmd(bufnr)
end

----------------------------------------------------------------------
-- Timestamp handling for FILE-tail buffers only (text prefix)
----------------------------------------------------------------------

local function file_timestamps_enable(bufnr, opts)
	opts = opts or {}
	local cfg = file_cfg[bufnr]
	if not cfg then
		cfg = {
			follow     = true,
			ts_enabled = false,
			ts_format  = "%Y-%m-%d %H:%M:%S ",
		}
		file_cfg[bufnr] = cfg
	end

	cfg.ts_enabled = true

	if opts.backfill then
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
		for i, line in ipairs(lines) do
			if line ~= "" and not line:match("^%d%d%d%d%-%d%d%-%d%d") then
				local fmt = cfg.ts_format or "%Y-%m-%d %H:%M:%S"
				local ts  = os.date(fmt)
				lines[i]  = ts .. " " .. line
			end
		end
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.bo[bufnr].modified = false

		-- Apply highlighting after lines are written
		local ns_tail = vim.api.nvim_create_namespace("tail-timestamp")
		for i = 1, #lines do
			local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
			local ts_match = line:match("^(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d)")
			if ts_match then
				vim.api.nvim_buf_set_extmark(bufnr, ns_tail, i - 1, 0, {
					end_col = #ts_match,
					hl_group = cfg.ts_highlight or "Comment",
				})
			end
		end
	end
end

local function file_timestamps_disable(bufnr)
	local cfg = file_cfg[bufnr]
	if not cfg then
		return
	end
	cfg.ts_enabled = false
end

----------------------------------------------------------------------
-- Log level highlighting for FILE-tail buffers only
----------------------------------------------------------------------

local function file_log_level_hl_enable(bufnr, opts)
	opts = opts or {}
	local cfg = file_cfg[bufnr]
	if not cfg then
		cfg = {
			follow       = true,
			ts_enabled   = false,
			ts_format    = "%Y-%m-%d %H:%M:%S ",
			log_level_hl = false,
		}
		file_cfg[bufnr] = cfg
	end

	cfg.log_level_hl = true

	if opts.backfill then
		vim.api.nvim_buf_clear_namespace(bufnr, ns_loglevel, 0, -1)
		local line_count = vim.api.nvim_buf_line_count(bufnr)
		if line_count > 0 then
			highlight_log_levels(bufnr, 1, line_count)
		end
	end
end

local function file_log_level_hl_disable(bufnr)
	local cfg = file_cfg[bufnr]
	if not cfg then
		return
	end
	cfg.log_level_hl = false
	vim.api.nvim_buf_clear_namespace(bufnr, ns_loglevel, 0, -1)
end

----------------------------------------------------------------------
-- Core commands
----------------------------------------------------------------------

vim.api.nvim_create_user_command("TailEnable", function()
	local bufnr = vim.api.nvim_get_current_buf()

	if is_regular_file_buf(bufnr) then
		-- Real file: convert to tail buffer and start poller
		local path = make_tail_buffer_from_file(bufnr)
		if path then
			start_file_poller(bufnr)
		end
	else
		-- Non-file buffer (MQTT etc.): use original tail.nvim behaviour
		tail.enable(bufnr)
	end
end, {
	desc = "Enable tail mode (file buffers → poller; others → tail.nvim)",
})

vim.api.nvim_create_user_command("TailDisable", function()
	local bufnr = vim.api.nvim_get_current_buf()

	if vim.b[bufnr].tail_file_path then
		-- This is a tail buffer detached from a file
		stop_file_poller(bufnr)
	else
		-- Regular buffer handled by tail.nvim
		tail.disable(bufnr)
	end
end, {
	desc = "Disable tail mode (and stop poller if used)",
})

vim.api.nvim_create_user_command("TailToggle", function()
	local bufnr = vim.api.nvim_get_current_buf()

	if vim.b[bufnr].tail_file_path then
		if timers[bufnr] then
			stop_file_poller(bufnr)
		else
			start_file_poller(bufnr)
		end
	else
		tail.toggle()
	end
end, {
	desc = "Toggle tail mode (for file or non-file buffers)",
})

----------------------------------------------------------------------
-- Timestamp commands
--   - File buffers (tail mode): our own behaviour (text prefix)
--   - Other buffers: delegate to core tail.nvim
----------------------------------------------------------------------

vim.api.nvim_create_user_command("TailTimestampEnable", function()
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.b[bufnr].tail_file_path then
		file_timestamps_enable(bufnr, { backfill = true })
	else
		tail.timestamps_enable(nil, { backfill = true })
	end
end, {
	desc = "Enable timestamps (file-tail: prefix; others: tail.nvim)",
})

vim.api.nvim_create_user_command("TailTimestampDisable", function()
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.b[bufnr].tail_file_path then
		file_timestamps_disable(bufnr)
	else
		tail.timestamps_disable()
	end
end, {
	desc = "Disable timestamps",
})

vim.api.nvim_create_user_command("TailTimestampToggle", function()
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.b[bufnr].tail_file_path then
		local cfg = file_cfg[bufnr]
		if cfg and cfg.ts_enabled then
			file_timestamps_disable(bufnr)
		else
			file_timestamps_enable(bufnr, { backfill = false })
		end
	else
		tail.timestamps_toggle(nil, { backfill = false })
	end
end, {
	desc = "Toggle timestamps",
})

----------------------------------------------------------------------
-- Log level highlighting commands
--   - File buffers (tail mode): our own behaviour
--   - Other buffers: delegate to core tail.nvim
----------------------------------------------------------------------

vim.api.nvim_create_user_command("TailLogLevelHlEnable", function()
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.b[bufnr].tail_file_path then
		file_log_level_hl_enable(bufnr, { backfill = true })
	else
		tail.log_level_hl_enable(nil, { backfill = true })
	end
end, {
	desc = "Enable log level highlighting",
})

vim.api.nvim_create_user_command("TailLogLevelHlDisable", function()
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.b[bufnr].tail_file_path then
		file_log_level_hl_disable(bufnr)
	else
		tail.log_level_hl_disable()
	end
end, {
	desc = "Disable log level highlighting",
})

vim.api.nvim_create_user_command("TailLogLevelHlToggle", function()
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.b[bufnr].tail_file_path then
		local cfg = file_cfg[bufnr]
		if cfg and cfg.log_level_hl then
			file_log_level_hl_disable(bufnr)
		else
			file_log_level_hl_enable(bufnr, { backfill = true })
		end
	else
		tail.log_level_hl_toggle(nil, { backfill = true })
	end
end, {
	desc = "Toggle log level highlighting",
})

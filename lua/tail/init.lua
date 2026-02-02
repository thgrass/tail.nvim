-- tail.nvim
--
-- A minimal Neovim plugin that allows any buffer to follow appended lines—just like
-- the UNIX `tail -f` command. The optional timestamp feature is completely opt-in
-- on a per-buffer basis and does not modify the underlying buffer contents; it merely
-- displays the time alongside each line for visual reference.

-- lua/tail/init.lua

local M = {}

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

local default_config = {
	-- enable timestamps by default for new buffers?
	timestamps = false,
	-- see :help os.date
	timestamp_format = "%Y-%m-%d %H:%M:%S ",
	-- highlight group used for the timestamp virtual text
	timestamp_hl = "Comment",
	-- enable log level highlighting by default for new buffers?
	log_level_hl = false,
	-- highlight groups for each log level keyword (uppercase only)
	log_level_groups = {
		TRACE = "DiagnosticHint",
		DEBUG = "DiagnosticHint",
		INFO = "DiagnosticInfo",
		WARN = "DiagnosticWarn",
		WARNING = "DiagnosticWarn",
		ERROR = "DiagnosticError",
	},
}

local config = vim.deepcopy(default_config)

function M.setup(user_config)
	config = vim.tbl_deep_extend("force", config, user_config or {})
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("tail.nvim")

-- buf_state[bufnr] = {
--   enabled = bool,
--   timestamps = bool,
--   log_level_hl = bool,
--   attached = bool,
--   wins = {
--     [winid] = { pinned = bool },
--   },
-- }
local buf_state = {}

local function get_buf_state(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local s = buf_state[bufnr]
	if not s then
		s = {
			enabled = false,
			timestamps = config.timestamps,
			log_level_hl = config.log_level_hl,
			attached = false,
			wins = {},
		}
		buf_state[bufnr] = s
	end
	return s
end

local function get_win_state(bufnr, winid)
	local bs = get_buf_state(bufnr)
	local ws = bs.wins[winid]
	if not ws then
		ws = { pinned = true }
		bs.wins[winid] = ws
	end
	return ws
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function is_valid_buf(bufnr)
	return bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function is_valid_win(winid)
	return winid and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function is_in_tail_region(bufnr, winid)
	if not (is_valid_buf(bufnr) and is_valid_win(winid)) then
		return false
	end

	local line = vim.api.nvim_win_get_cursor(winid)[1]
	local last = vim.api.nvim_buf_line_count(bufnr)
	local height = vim.api.nvim_win_get_height(winid)

	-- treat “bottom one screenful” as the tail region
	local tail_start = math.max(1, last - height + 1)

	return line >= tail_start
end

local function jump_to_bottom(bufnr, winid)
	if not (is_valid_buf(bufnr) and is_valid_win(winid)) then
		return
	end
	if vim.api.nvim_win_get_buf(winid) ~= bufnr then
		return
	end

	local last = vim.api.nvim_buf_line_count(bufnr)
	vim.api.nvim_win_set_cursor(winid, { last, 0 })
end

local function add_timestamp(bufnr, lnum)
	if not is_valid_buf(bufnr) then
		return
	end

	local text = os.date(config.timestamp_format)
	vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
		virt_text = { { text, config.timestamp_hl } },
		virt_text_pos = "inline",
	})
end

local function backfill_timestamps(bufnr)
	if not is_valid_buf(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	for lnum = 1, line_count do
		add_timestamp(bufnr, lnum)
	end
end

-- ---------------------------------------------------------------------------
-- Log level highlighting
-- ---------------------------------------------------------------------------

local ns_loglevel = vim.api.nvim_create_namespace("tail.nvim.loglevel")

--- Highlight log level keywords in the given line range (1-based, inclusive)
---@param bufnr number
---@param start_line number 1-based start line
---@param end_line number 1-based end line (inclusive)
local function highlight_log_levels(bufnr, start_line, end_line)
	if not is_valid_buf(bufnr) then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

	for i, line in ipairs(lines) do
		local lnum = start_line + i - 1

		for keyword, hl_group in pairs(config.log_level_groups) do
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

local function backfill_log_levels(bufnr)
	if not is_valid_buf(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, ns_loglevel, 0, -1)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if line_count > 0 then
		highlight_log_levels(bufnr, 1, line_count)
	end
end

-- ---------------------------------------------------------------------------
-- Core: on_lines handler (tail + timestamps)
-- ---------------------------------------------------------------------------

local function on_lines(_, bufnr, _changedtick, firstline, lastline_old, new_lastline, _bytecount)
	local bs = buf_state[bufnr]
	if not bs or not bs.enabled then
		return
	end

	-- timestamps: only care if lines were added
	if bs.timestamps and new_lastline > lastline_old then
		local added = new_lastline - lastline_old
		local start = firstline + 1 -- convert 0-based to 1-based

		for i = 0, added - 1 do
			add_timestamp(bufnr, start + i)
		end
	end

	-- log level highlighting: only care if lines were added
	if bs.log_level_hl and new_lastline > lastline_old then
		local start = firstline + 1 -- convert 0-based to 1-based
		highlight_log_levels(bufnr, start, new_lastline)
	end

	-- tail-following: only if the window was “pinned” *before* the change
	local wins = vim.fn.win_findbuf(bufnr)
	if not wins or #wins == 0 then
		return
	end

	for _, winid in ipairs(wins) do
		local ws = bs.wins[winid]
		if ws and ws.pinned then
			-- schedule to avoid fighting with redraw / other handlers
			vim.schedule(function()
				local s = buf_state[bufnr]
				if not (s and s.enabled) then
					return
				end
				jump_to_bottom(bufnr, winid)
			end)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Autocommands: track pinned/unpinned per window
-- ---------------------------------------------------------------------------

local aug = vim.api.nvim_create_augroup("tail.nvim", { clear = true })

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled" }, {
	group = aug,
	callback = function(args)
		local bufnr = args.buf
		local winid = args.win

		local bs = buf_state[bufnr]
		if not (bs and bs.enabled) then
			return
		end
		if not is_valid_win(winid) then
			return
		end

		local ws = get_win_state(bufnr, winid)
		if is_in_tail_region(bufnr, winid) then
			ws.pinned = true
		else
			-- user scrolled/moved out of the tail region → stop following
			ws.pinned = false
		end
	end,
})

-- ---------------------------------------------------------------------------
-- Public API: tail behaviour
-- ---------------------------------------------------------------------------

function M.enable(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not is_valid_buf(bufnr) then
		return
	end

	local bs = get_buf_state(bufnr)
	bs.enabled = true

	-- attach once per buffer
	if not bs.attached then
		vim.api.nvim_buf_attach(bufnr, false, {
			on_lines = on_lines,
			on_detach = function(_, b)
				buf_state[b] = nil
			end,
		})
		bs.attached = true
	end

	-- mark all windows currently showing this buffer as pinned and move them to bottom
	local wins = vim.fn.win_findbuf(bufnr)
	for _, winid in ipairs(wins) do
		local ws = get_win_state(bufnr, winid)
		ws.pinned = true
		jump_to_bottom(bufnr, winid)
	end

	-- Turn on autoread locally
	vim.bo[bufnr].autoread = true

	-- Unique augroup per buffer so disabling doesn't affect others
	local group = vim.api.nvim_create_augroup("tail_autoread_" .. bufnr, { clear = true })

	vim.api.nvim_create_autocmd(
		{ "CursorHold", "CursorHoldI", "FocusGained", "BufEnter" },
		{
			group = group,
			buffer = bufnr,
			callback = function()
				-- Only reload if tailing is still enabled for this buffer
				local state = buf_state[bufnr]
				if state and state.enabled then
					pcall(vim.cmd, "checktime " .. bufnr)
				end
			end,
		})
end

function M.disable(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local bs = buf_state[bufnr]
	if not bs then
		return
	end
	bs.enabled = false
end

function M.toggle(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local bs = get_buf_state(bufnr)
	if bs.enabled then
		M.disable(bufnr)
	else
		M.enable(bufnr)
	end
end

-- ---------------------------------------------------------------------------
-- Public API: timestamps
-- ---------------------------------------------------------------------------

function M.timestamps_enable(bufnr, opts)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not is_valid_buf(bufnr) then
		return
	end
	local bs = get_buf_state(bufnr)
	bs.timestamps = true

	opts = opts or {}
	if opts.backfill then
		backfill_timestamps(bufnr)
	end
end

function M.timestamps_disable(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not is_valid_buf(bufnr) then
		return
	end
	local bs = get_buf_state(bufnr)
	bs.timestamps = false
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

function M.timestamps_toggle(bufnr, opts)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local bs = get_buf_state(bufnr)
	if bs.timestamps then
		M.timestamps_disable(bufnr)
	else
		M.timestamps_enable(bufnr, opts)
	end
end

-- ---------------------------------------------------------------------------
-- Public API: log level highlighting
-- ---------------------------------------------------------------------------

function M.log_level_hl_enable(bufnr, opts)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not is_valid_buf(bufnr) then
		return
	end
	local bs = get_buf_state(bufnr)
	bs.log_level_hl = true

	opts = opts or {}
	if opts.backfill then
		backfill_log_levels(bufnr)
	end
end

function M.log_level_hl_disable(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not is_valid_buf(bufnr) then
		return
	end
	local bs = get_buf_state(bufnr)
	bs.log_level_hl = false
	vim.api.nvim_buf_clear_namespace(bufnr, ns_loglevel, 0, -1)
end

function M.log_level_hl_toggle(bufnr, opts)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local bs = get_buf_state(bufnr)
	if bs.log_level_hl then
		M.log_level_hl_disable(bufnr)
	else
		M.log_level_hl_enable(bufnr, opts)
	end
end

return M

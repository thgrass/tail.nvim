-- tail.nvim
--
-- A minimal Neovim plugin that allows any buffer to follow appended lines—just like
-- the UNIX `tail -f` command. The optional timestamp feature is completely opt-in 
-- on a per-buffer basis and does not modify the underlying buffer contents; it merely
-- displays the time alongside each line for visual reference.

local M = {}

-- Default options. Override any of these via `require("tail").setup({ … })`.
--
-- threshold        – Number of lines from the bottom of the window considered “near
--                    bottom” when auto-scrolling.  When the cursor is within this
--                    threshold of the end of the buffer, the window will follow
--                    appended lines.
-- timestamps       – Whether to enable timestamp virtual text by default when
--                    calling `TailEnable`.  You can toggle timestamps per
--                    buffer using the exposed commands (`TailTimestampEnable`,
--                    `TailTimestampDisable`, `TailTimestampToggle`).
-- timestamp_format – A `strftime`/`os.date` format string used to produce the
--                    timestamp (see `:help os.date`).
-- timestamp_hl     – Highlight group used to render the timestamp.  Defaults to
--                    “Comment”.
-- timestamp_pad    – String appended after the timestamp.  Useful for adding a
--                    trailing space or other separator.
-- timestamp_backfill – When true, enabling timestamps on a buffer will annotate
--                    every existing line in the buffer with the current time.
M.opts = {
  threshold = 3,
  timestamps = false,
  timestamp_format = "%Y-%m-%d %H:%M:%S",
  timestamp_hl = "Comment",
  timestamp_pad = " ",
  timestamp_backfill = false,
}

-- Namespace used for timestamp virtual text.  All extmarks placed for
-- timestamps live in this namespace so they can be cleared en masse.
local ts_ns = vim.api.nvim_create_namespace("tail.nvim.timestamps")

-- Helper: check if tail following is enabled for a buffer.
local function is_tail_enabled(buf)
  return vim.b[buf].tail_enabled == true
end

-- Helper: set tail following enabled/disabled for a buffer.
local function set_tail_enabled(buf, val)
  vim.b[buf].tail_enabled = val and true or false
end

-- Helper: check if timestamp virtual text is enabled for a buffer.
local function is_ts_enabled(buf)
  return vim.b[buf].tail_ts_enabled == true
end

-- Helper: set timestamp virtual text enabled/disabled for a buffer.
local function set_ts_enabled(buf, val)
  vim.b[buf].tail_ts_enabled = val and true or false
end

-- Move the cursor to the beginning of the last line of a buffer.
local function move_cursor_to_end_of_buffer(bufnr)
  bufnr = bufnr or 0  -- 0 = current buffer
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)

  -- figure out last line index (1-based for win_set_cursor)
  local last_line = #lines > 0 and #lines or 1
  local last_col = 0
  if lines[last_line] ~= nil then
    last_col = #lines[last_line]  -- byte index (Neovim expects 0-based col)
  end

  -- if the buffer is visible, move the cursor in that window; else set a mark
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    vim.api.nvim_win_set_cursor(win, { last_line, last_col })
  else
    -- Buffer not shown in any window: remember the spot with a mark.
    vim.api.nvim_buf_set_mark(bufnr, "'", last_line, last_col, {})
  end
end

-- Tiny helper: perform the EOF jump *after* the buffer/window settles.
-- This handles very fast fills during load where the cursor would otherwise
-- remain on line 1.
local function kick_to_end(buf)
  -- First, wait until the current event loop tick completes.
  vim.schedule(function()
    move_cursor_to_end_of_buffer(buf)
    -- Then nudge once more on the next timer tick to beat late on_lines updates.
    vim.defer_fn(function()
      move_cursor_to_end_of_buffer(buf)
    end, 10) -- small delay; low enough to be unnoticeable, high enough to outlast initial fills
  end)
end

-- Add a timestamp extmark to a single line.  Does nothing if timestamps are
-- disabled for the buffer.
local function add_ts_extmark(buf, lnum)
  if not is_ts_enabled(buf) then return end
  -- Compose the timestamp text using the configured format.
  local text = os.date(M.opts.timestamp_format) .. (M.opts.timestamp_pad or " ")
  vim.api.nvim_buf_set_extmark(buf, ts_ns, lnum, 0, {
    virt_text = { { text, M.opts.timestamp_hl or "Comment" } },
    virt_text_pos = "inline",
  })
end

-- For a range of inserted lines, add timestamp extmarks.  The on_lines
-- callback provides the `first`, `last_old` and `last_new` positions.  We
-- compute the number of lines inserted as `last_new - last_old` and annotate
-- those newly inserted lines.  When lines are deleted, this function does
-- nothing.
local function add_ts_for_insert(buf, first, last_old, last_new)
  if not is_ts_enabled(buf) then return end
  local inserted = last_new - last_old
  if inserted <= 0 then return end
  for l = first, first + inserted - 1 do
    add_ts_extmark(buf, l)
  end
end

-- If backfill is requested when enabling timestamps, annotate every existing
-- line in the buffer with a timestamp.  Because timestamps are visual only,
-- this does not modify the buffer’s contents.
local function backfill_ts(buf)
  if not is_ts_enabled(buf) then return end
  local line_count = vim.api.nvim_buf_line_count(buf)
  for l = 0, line_count - 1 do
    add_ts_extmark(buf, l)
  end
end

-- Internal attach: set up buffer autocommands for following and timestamping.
-- Only attaches once per buffer.
local function attach(buf)
  -- Prevent attaching multiple times to the same buffer.
  if vim.b[buf].tail_attached then return end
  vim.b[buf].tail_attached = true

  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, b, _, first, last_old, last_new, _)
      -- First, handle timestamp annotations.  Annotate newly inserted lines
      -- immediately so the virtual text is visible without delay.
      add_ts_for_insert(b, first, last_old, last_new)

      -- Then, handle tail following.  Only auto-scroll if tail is enabled on
      -- this buffer.
      if not is_tail_enabled(b) then return end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(b) then return end
        local last = vim.api.nvim_buf_line_count(b)
        for _, win in ipairs(vim.fn.win_findbuf(b)) do
          if not vim.api.nvim_win_is_valid(win) then goto continue end
          local ok, cur = pcall(vim.api.nvim_win_get_cursor, win)
          if not ok then goto continue end
          local line = cur[1]
          local near_bottom = line >= last - (M.opts.threshold or 3)
          local at_eof = line == last
          if near_bottom or at_eof then
            -- Move the window’s cursor to the end of the buffer and scroll
            -- slightly so the appended line is visible.
            pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
            pcall(vim.api.nvim_win_call, win, function() vim.cmd("normal! zb") end)
          end
          ::continue::
        end
      end)
    end,
    on_detach = function() end,
  })
end

--- Enable tail following for a buffer.  If timestamps are configured to be
--- enabled by default (`M.opts.timestamps == true`), timestamps will also be
--- enabled for this buffer.  You can override timestamps per buffer using
--- `M.timestamps_enable/disable/toggle` or the associated user commands.
---@param buf number|nil Buffer handle (0 for current buffer).
function M.enable(buf)
  buf = buf or 0
  set_tail_enabled(buf, true)
  -- Respect global default for timestamps when enabling.
  if M.opts.timestamps and vim.b[buf].tail_ts_enabled == nil then
    set_ts_enabled(buf, true)
    if M.opts.timestamp_backfill then
      backfill_ts(buf)
    end
  end
  attach(buf)
  -- Move cursor to end of buffer for immediate effect (handles fast fills).
  kick_to_end(buf)
  -- If the buffer isn't visible yet, jump when it becomes visible.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    once = true,
    callback = function(args)
      if is_tail_enabled(args.buf) then
        kick_to_end(args.buf)
      end
    end,
  })
end

--- Disable tail following for a buffer.  This does not disable timestamps; to
--- stop displaying timestamps call `M.timestamps_disable()`.
---@param buf number|nil Buffer handle (0 for current buffer).
function M.disable(buf)
  buf = buf or 0
  set_tail_enabled(buf, false)
end

--- Toggle tail following for a buffer.
---@param buf number|nil Buffer handle (0 for current buffer).
function M.toggle(buf)
  buf = buf or 0
  if is_tail_enabled(buf) then
    M.disable(buf)
  else
    M.enable(buf)
  end
end

--- Enable timestamp virtual text for a buffer.  If `M.opts.timestamp_backfill`
--- is true, annotate existing lines.  This has no effect on tail following.
---@param buf number|nil Buffer handle (0 for current buffer).
function M.timestamps_enable(buf)
  buf = buf or 0
  if is_ts_enabled(buf) then return end
  set_ts_enabled(buf, true)
  if M.opts.timestamp_backfill then
    backfill_ts(buf)
  end
end

--- Disable timestamp virtual text for a buffer.  Clears all timestamp extmarks.
---@param buf number|nil Buffer handle (0 for current buffer).
function M.timestamps_disable(buf)
  buf = buf or 0
  if not is_ts_enabled(buf) then return end
  set_ts_enabled(buf, false)
  -- Remove all timestamp extmarks for this buffer.
  vim.api.nvim_buf_clear_namespace(buf, ts_ns, 0, -1)
end

--- Toggle timestamp virtual text for a buffer.  Enabling will optionally
--- annotate existing lines depending on `M.opts.timestamp_backfill`.
---@param buf number|nil Buffer handle (0 for current buffer).
function M.timestamps_toggle(buf)
  buf = buf or 0
  if is_ts_enabled(buf) then
    M.timestamps_disable(buf)
  else
    M.timestamps_enable(buf)
  end
end

--- Setup the plugin.  Accepts an optional table of options.  If called
--- multiple times, subsequent calls will merge new options over existing
--- values.
---@param opts table|nil
function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
  -- Create user commands for tail-following.
  vim.api.nvim_create_user_command("TailEnable", function() M.enable(0) end, {})
  vim.api.nvim_create_user_command("TailDisable", function() M.disable(0) end, {})
  vim.api.nvim_create_user_command("TailToggle", function() M.toggle(0) end, {})
  -- Create user commands for timestamp control.
  vim.api.nvim_create_user_command("TailTimestampEnable", function() M.timestamps_enable(0) end, {})
  vim.api.nvim_create_user_command("TailTimestampDisable", function() M.timestamps_disable(0) end, {})
  vim.api.nvim_create_user_command("TailTimestampToggle", function() M.timestamps_toggle(0) end, {})
end

return M


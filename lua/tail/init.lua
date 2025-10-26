-- tail.lua Neovim plugin for following buffers like 'tail -f'
local M = {}

local threshold = 3

local function is_enabled(buf)
  return vim.b[buf].tail_enabled == true
end

local function set_enabled(buf, val)
  vim.b[buf].tail_enabled = val and true or false
end

local function attach(buf)
  if vim.b[buf].tail_attached then return end
  vim.b[buf].tail_attached = true

  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, b, _, _, _, _, _)
      if not is_enabled(b) then return end

      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(b) then return end
        local last = vim.api.nvim_buf_line_count(b)

        for _, win in ipairs(vim.fn.win_findbuf(b)) do
          if not vim.api.nvim_win_is_valid(win) then goto continue end
          local ok, cur = pcall(vim.api.nvim_win_get_cursor, win)
          if not ok then goto continue end

          local line = cur[1]
          local near_bottom = line >= last - threshold
          local at_eof = line == last

          if near_bottom or at_eof then
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

function M.enable(buf)
  buf = buf or 0
  set_enabled(buf, true)
  attach(buf)
end

function M.disable(buf)
  buf = buf or 0
  set_enabled(buf, false)
end

function M.toggle(buf)
  buf = buf or 0
  if is_enabled(buf) then M.disable(buf) else M.enable(buf) end
end

function M.setup()
  vim.api.nvim_create_user_command("TailEnable", function() M.enable(0) end, {})
  vim.api.nvim_create_user_command("TailDisable", function() M.disable(0) end, {})
  vim.api.nvim_create_user_command("TailToggle", function() M.toggle(0) end, {})
end

return M


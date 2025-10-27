# tail.nvim

A minimal Neovim plugin that allows any buffer to follow appended lines—just like `tail -f`. It can
optionally display a timestamp before each new line using virtual text.

## Features

- Auto-scrolls to the bottom of any buffer as new lines are added (if already at bottom)
- Respects user scrolling: won't yank you back if you've moved up
- Works on any buffer type: `nofile`, plugin buffers, etc.
- Optional per-buffer timestamps: prefix newly inserted lines with the current time. The timestamp is drawn with virtual text, so it does not modify the file’s content.

## Usage

Set up the plugin in your init.lua:

```lua
require("tail").setup({
  -- uncomment the next line to enable timestamps by default
  -- timestamps = true,
  -- customise the format (see `:help os.date`)
  timestamp_format = "%Y-%m-%d %H:%M:%S",
  -- customise the highlight group used for the timestamp
  timestamp_hl = "Comment",
})
```

Then, from any buffer enable, disable or toggle tailing behaviour:

```vim
:TailEnable
:TailDisable
:TailToggle
```

Similarily the timestamps are controlled:

```vim
:TailTimestampToggle
:TailTimestampEnable
:TailTimestampDisable
```

## API

This plugin exposes the following Lua functions:

```lua
-- Lua API
-- (buffer 'bufnr' is optional; defaults to current)
require("tail").enable(bufnr)
require("tail").disable(bufnr)
require("tail").toggle(bufnr)

-- Timestamps
require("tail").timestamps_enable(bufnr, { backfill = true })
require("tail").timestamps_disable(bufnr)
require("tail").timestamps_toggle(bufnr, { backfill = false })

```

## License

MIT

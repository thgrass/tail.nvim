# tail.nvim

A minimal Neovim plugin that allows any buffer to follow appended lines—just like `tail -f`.

## Features

- Auto-scrolls to the bottom of any buffer as new lines are added (if already at bottom)
- Respects user scrolling: won't yank you back if you've moved up
- Works on any buffer type: `nofile`, plugin buffers, etc.

## Usage

```lua
require("tail").setup()
```

Then, from any buffer:

```vim
:TailEnable
```

Or programmatically:

```lua
require("tail").enable(bufnr)
```

## License

MIT

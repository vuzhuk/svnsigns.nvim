# svnsigns.nvim

Async SVN sign-column, blame, and diff plugin for Neovim — gitsigns-style
integration for SVN working copies.

## Features

- Sign-column markers for added/changed/deleted lines against the SVN base
  revision, updated asynchronously as you type (no UI blocking).
- `:SvnBlame` — inline blame in a synced vertical split.
- `:SvnLog` — SVN log for the revision at the cursor line.
- `:SvnPreview` — floating diff preview of unsaved changes.
- `:SvnResetHunk` / `:SvnRevert` — revert a single hunk or the whole buffer.
- `:SvnFiles` — browse modified SVN files via `fzf-lua`.
- `:SvnRefresh` — clear the internal repo-detection cache and re-scan the
  current buffer (useful after `svn checkout`-ing a new working copy).

## Requirements

- Neovim 0.10+ (uses `vim.system` for async shell calls)
- `svn` and `diff` available on `$PATH`
- [fzf-lua](https://github.com/ibhagwan/fzf-lua) (optional, only for `:SvnFiles`)

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "vuzhuk/svnsigns.nvim",
  event = { "BufReadPost", "BufNewFile" },
  config = function()
    require("svnsigns").setup({
      signs = {
        add = { text = "│" },
        change = { text = "│" },
        delete = { text = "_" },
        topdelete = { text = "‾" },
        changedelete = { text = "~" },
      },
    })
  end,
}
```

## Keymaps

This plugin only defines commands — bind them to whatever keys you like, e.g.:

```lua
vim.keymap.set("n", "]s", function() require("svnsigns").next_hunk() end)
vim.keymap.set("n", "[s", function() require("svnsigns").prev_hunk() end)
vim.keymap.set("n", "<leader>sp", function() require("svnsigns").preview_hunk() end)
vim.keymap.set("n", "<leader>sb", function() require("svnsigns").blame_split() end)
vim.keymap.set("n", "<leader>sl", function() require("svnsigns").show_line_log() end)
vim.keymap.set("n", "<leader>sR", function() require("svnsigns").reset_buffer() end)
vim.keymap.set("n", "<leader>sr", function() require("svnsigns").reset_hunk() end)
vim.keymap.set("n", "<leader>fs", function() require("svnsigns").fzf_modified_files() end)
```

## Contributing

PRs are welcome. Please branch off `main` (e.g. `feat/short-description`) and
open a pull request rather than pushing directly.

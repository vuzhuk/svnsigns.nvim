-- User-facing configuration and highlight groups.
local M = {}

M.defaults = {
  signs = {
    add = { text = "█" },
    change = { text = "█" },
    delete = { text = "█" },
    topdelete = { text = "█" },
    changedelete = { text = "█" },
  },
  sign_priority = 6,
  update_debounce = 100,
  -- Show a virtual-text blame annotation on the line the cursor is on
  -- (gitsigns-style). Off by default, matching gitsigns' own default.
  current_line_blame = false,
  -- blame = { rev, author, date }
  current_line_blame_formatter = function(blame)
    return string.format("  %s, %s, %s", blame.author, blame.date, blame.rev)
  end,
}

-- The live, effective config. Other modules require() this table directly
-- (M.options) so they always see whatever M.setup() last populated instead
-- of a stale copy taken at require-time.
M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
  return M.options
end

-- Define sign/blame highlight groups.
function M.setup_highlights()
  -- Make sure signcolumn has no background
  vim.api.nvim_set_hl(0, "SignColumn", { ctermbg = "NONE", bg = "NONE" })

  -- Set sign colors with bold for visibility
  vim.api.nvim_set_hl(0, "SvnSignsAdd", { ctermfg = 2, fg = "Green", bold = true })
  vim.api.nvim_set_hl(0, "SvnSignsChange", { ctermfg = 3, fg = "Yellow", bold = true })
  vim.api.nvim_set_hl(0, "SvnSignsDelete", { ctermfg = 1, fg = "Red", bold = true })
  vim.api.nvim_set_hl(0, "SvnSignsTopDelete", { link = "SvnSignsDelete", default = true })
  vim.api.nvim_set_hl(0, "SvnSignsChangeDelete", { link = "SvnSignsChange", default = true })
  vim.api.nvim_set_hl(0, "SvnSignsCurrentLineBlame", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "SvnSignsBlameRevision", { link = "Number", default = true })
  vim.api.nvim_set_hl(0, "SvnSignsBlameAuthor", { link = "String", default = true })
end

return M

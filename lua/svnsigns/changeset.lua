-- Multi-file changeset diff view: a diffview.nvim-style tab with a file
-- panel on the left (every changed path in the working copy) and a
-- synced side-by-side diff (SVN base vs. working copy) on the right,
-- updated as you move through the panel.
local svn = require("svnsigns.svn")

local M = {}

-- Single-instance state for the currently open changeset tab, or {} when
-- none is open. Only one changeset view is supported at a time (matching
-- diffview.nvim's own default), which keeps this state a plain module
-- table instead of something keyed/stacked.
local state = {}

-- Lazily create (and cache on `entry`) the pair of buffers shown for one
-- changed file: `base_buf` (read-only scratch holding the SVN base
-- revision, or a placeholder for files with no base) and `cur_buf` (the
-- real, editable file buffer, or a placeholder scratch for files no
-- longer on disk).
local function ensure_buffers(entry)
  if entry.base_buf and vim.api.nvim_buf_is_valid(entry.base_buf) then
    return
  end

  local base_content = (entry.status ~= "?" and entry.status ~= "A") and svn.get_svn_base(entry.abs_path) or nil

  local base_buf = vim.api.nvim_create_buf(false, true)
  local base_lines
  if base_content then
    base_lines = vim.split(base_content, "\n", { plain = true })
    if base_lines[#base_lines] == "" then table.remove(base_lines) end
  else
    base_lines = { "-- no base revision (added/untracked file) --" }
  end
  vim.api.nvim_buf_set_lines(base_buf, 0, -1, false, base_lines)
  vim.bo[base_buf].buftype = "nofile"
  vim.bo[base_buf].swapfile = false
  vim.bo[base_buf].bufhidden = "wipe"
  vim.bo[base_buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, base_buf, "svn-base://" .. entry.path)
  entry.base_buf = base_buf

  local cur_buf
  if entry.status == "D" or vim.fn.filereadable(entry.abs_path) == 0 then
    cur_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(cur_buf, 0, -1, false, { "-- file deleted in working copy --" })
    vim.bo[cur_buf].buftype = "nofile"
    vim.bo[cur_buf].swapfile = false
    vim.bo[cur_buf].bufhidden = "wipe"
    vim.bo[cur_buf].modifiable = false
  else
    -- A real, listed buffer for the actual file: lets you edit and save
    -- directly from the diff view, same as opening it normally.
    cur_buf = vim.fn.bufadd(entry.abs_path)
    vim.fn.bufload(cur_buf)
    vim.bo[cur_buf].buflisted = true
  end
  entry.cur_buf = cur_buf

  -- Match the base pane's filetype to the real file's for syntax
  -- highlighting, since the base buffer has no filename extension of its
  -- own to infer one from.
  local ft = vim.bo[cur_buf].filetype
  if ft == "" then
    ft = vim.filetype.match({ filename = entry.abs_path }) or ""
  end
  if ft ~= "" then
    vim.bo[base_buf].filetype = ft
  end
end

local function render_panel()
  local lines = {}
  for _, entry in ipairs(state.entries) do
    lines[#lines + 1] = string.format("%s  %s", entry.status, entry.path)
  end
  vim.bo[state.panel_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.panel_buf, 0, -1, false, lines)
  vim.bo[state.panel_buf].modifiable = false
end

-- Show the diff for panel line `idx` in the base/current windows.
local function select_index(idx)
  local entry = state.entries[idx]
  if not entry or not vim.api.nvim_win_is_valid(state.base_win) or not vim.api.nvim_win_is_valid(state.cur_win) then
    return
  end
  state.selected = idx
  ensure_buffers(entry)
  vim.api.nvim_win_set_buf(state.base_win, entry.base_buf)
  vim.api.nvim_win_set_buf(state.cur_win, entry.cur_buf)
  -- Buffers were swapped without "entering" either window, so diff mode
  -- won't have recomputed on its own; force it.
  vim.cmd("diffupdate")
end

local function close()
  if state.tabpage and vim.api.nvim_tabpage_is_valid(state.tabpage) then
    vim.cmd("tabclose")
  end
  state = {}
end

local function setup_panel_keymaps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", close, vim.tbl_extend("force", opts, { desc = "Close changeset view" }))
  vim.keymap.set("n", "<Esc>", close, vim.tbl_extend("force", opts, { desc = "Close changeset view" }))
  vim.keymap.set("n", "<CR>", function()
    if state.cur_win and vim.api.nvim_win_is_valid(state.cur_win) then
      vim.api.nvim_set_current_win(state.cur_win)
    end
  end, vim.tbl_extend("force", opts, { desc = "Jump to file for editing" }))
  vim.keymap.set("n", "R", M.refresh, vim.tbl_extend("force", opts, { desc = "Refresh changed files" }))
end

-- Open the changeset view: a new tab with the file panel on the left and
-- the base/current diff panes to its right, starting on the first entry.
function M.open()
  local entries = svn.get_changed_files()
  if #entries == 0 then
    vim.notify("No SVN changes in the working copy", vim.log.levels.INFO)
    return
  end
  for _, entry in ipairs(entries) do
    entry.abs_path = vim.fn.fnamemodify(entry.path, ":p")
  end

  close() -- only one changeset view at a time

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local panel_win = vim.api.nvim_get_current_win()

  local panel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(panel_win, panel_buf)
  vim.bo[panel_buf].buftype = "nofile"
  vim.bo[panel_buf].swapfile = false
  vim.bo[panel_buf].bufhidden = "wipe"
  vim.bo[panel_buf].filetype = "svnsigns-changeset"
  vim.wo[panel_win].number = false
  vim.wo[panel_win].relativenumber = false
  vim.wo[panel_win].signcolumn = "no"
  vim.wo[panel_win].wrap = false
  vim.wo[panel_win].cursorline = true

  local base_placeholder = vim.api.nvim_create_buf(false, true)
  local base_win = vim.api.nvim_open_win(base_placeholder, true, { win = panel_win, split = "right" })
  local cur_placeholder = vim.api.nvim_create_buf(false, true)
  local cur_win = vim.api.nvim_open_win(cur_placeholder, true, { win = base_win, split = "right" })

  vim.api.nvim_win_set_width(panel_win, 40)

  for _, win in ipairs({ base_win, cur_win }) do
    vim.api.nvim_win_call(win, function() vim.cmd("diffthis") end)
  end

  state = {
    tabpage = tabpage,
    panel_win = panel_win,
    panel_buf = panel_buf,
    base_win = base_win,
    cur_win = cur_win,
    entries = entries,
  }

  render_panel()
  setup_panel_keymaps(panel_buf)

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = panel_buf,
    callback = function()
      if not vim.api.nvim_win_is_valid(panel_win) then return end
      select_index(vim.api.nvim_win_get_cursor(panel_win)[1])
    end,
  })

  vim.api.nvim_set_current_win(panel_win)
  vim.api.nvim_win_set_cursor(panel_win, { 1, 0 })
  select_index(1)
end

-- Re-run `svn status` and rebuild the panel in place, keeping the current
-- selection on the same path if it's still present (e.g. after resolving
-- one file and moving to the next).
function M.refresh()
  if not state.entries then return end
  local selected_path = state.entries[state.selected] and state.entries[state.selected].path

  local entries = svn.get_changed_files()
  for _, entry in ipairs(entries) do
    entry.abs_path = vim.fn.fnamemodify(entry.path, ":p")
  end
  state.entries = entries

  if #entries == 0 then
    vim.notify("No more SVN changes", vim.log.levels.INFO)
    close()
    return
  end

  render_panel()

  local idx = 1
  if selected_path then
    for i, entry in ipairs(entries) do
      if entry.path == selected_path then
        idx = i
        break
      end
    end
  end
  vim.api.nvim_win_set_cursor(state.panel_win, { idx, 0 })
  select_index(idx)
end

return M

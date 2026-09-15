-- Sign-column rendering: computing signs from a buffer's diff against its
-- SVN base and placing/clearing them, plus hunk navigation.
local config = require("svnsigns.config")
local svn = require("svnsigns.svn")
local diff = require("svnsigns.diff")

local M = {}

local ns_id = vim.api.nvim_create_namespace("svnsigns")

-- Per-buffer classified changes from the last successful update, keyed by
-- bufnr. Used for hunk navigation (next_hunk/prev_hunk) and by
-- svnsigns.actions for :SvnResetHunk.
local buffers = {}

-- Per-buffer debounce timers for the TextChanged(-I) update path.
local timers = {}

-- Per-buffer update generations so stale async callbacks cannot overwrite a
-- newer diff/sign state.
local update_generations = {}

-- The last-computed changes table for bufnr (add/change/delete/topdelete/
-- changedelete line lists), or nil if none yet.
function M.get_changes(bufnr)
  return buffers[bufnr]
end

-- Clear any signs placed on bufnr (used both by update_signs itself and by
-- callers that need to blank out a buffer that shouldn't have signs at all,
-- e.g. netrw/help buffers).
function M.clear_signs(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
end

local function clear_buffer_state(bufnr)
  M.clear_signs(bufnr)
  buffers[bufnr] = nil
end

-- Place signs in buffer
local function place_signs(bufnr, changes)
  -- Clear existing signs
  M.clear_signs(bufnr)

  local opts = config.options

  local function place(lines, sign, hl_group)
    for _, lnum in ipairs(lines) do
      if lnum > 0 then
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum - 1, 0, {
          sign_text = sign.text,
          sign_hl_group = hl_group,
          priority = opts.sign_priority,
        })
      end
    end
  end

  place(changes.add, opts.signs.add, "SvnSignsAdd")
  place(changes.change, opts.signs.change, "SvnSignsChange")
  place(changes.delete, opts.signs.delete, "SvnSignsDelete")
  place(changes.topdelete, opts.signs.topdelete, "SvnSignsTopDelete")
  place(changes.changedelete, opts.signs.changedelete, "SvnSignsChangeDelete")
end

-- Update signs for buffer (async: never blocks the main thread)
function M.update_signs(bufnr)
  -- Skip non-normal buffers (netrw, help, etc.)
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })

  if buftype ~= "" or filetype == "netrw" or filetype == "help" then
    -- Clear any signs from special buffers
    clear_buffer_state(bufnr)
    return
  end

  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" or not vim.fn.filereadable(file) then
    clear_buffer_state(bufnr)
    return
  end

  update_generations[bufnr] = (update_generations[bufnr] or 0) + 1
  local generation = update_generations[bufnr]

  svn.is_svn_repo_async(file, function(is_repo)
    if update_generations[bufnr] ~= generation then return end
    if not is_repo then
      clear_buffer_state(bufnr)
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    svn.get_buffer_diff_async(bufnr, file, function(diff_output)
      if update_generations[bufnr] ~= generation then return end
      if not diff_output then
        clear_buffer_state(bufnr)
        return
      end
      if not vim.api.nvim_buf_is_valid(bufnr) then return end

      local changes = diff.parse_diff(diff_output)
      place_signs(bufnr, changes)
      buffers[bufnr] = changes
    end)
  end)
end

-- Debounced update
function M.debounced_update(bufnr)
  if timers[bufnr] then
    timers[bufnr]:stop()
  end

  timers[bufnr] = vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.update_signs(bufnr)
    end
    timers[bufnr] = nil
  end, config.options.update_debounce)
end

-- Drop all per-buffer state for bufnr (called on BufDelete).
function M.cleanup_buffer(bufnr)
  buffers[bufnr] = nil
  update_generations[bufnr] = nil
  if timers[bufnr] then
    timers[bufnr]:stop()
    timers[bufnr] = nil
  end
end

-- Navigate to next hunk
function M.next_hunk()
  local bufnr = vim.api.nvim_get_current_buf()
  local changes = buffers[bufnr]
  if not changes then return end

  local all_changes = {}
  for _, lnum in ipairs(changes.add) do table.insert(all_changes, lnum) end
  for _, lnum in ipairs(changes.change) do table.insert(all_changes, lnum) end
  for _, lnum in ipairs(changes.delete) do table.insert(all_changes, lnum) end
  for _, lnum in ipairs(changes.topdelete) do table.insert(all_changes, lnum) end
  for _, lnum in ipairs(changes.changedelete) do table.insert(all_changes, lnum) end
  table.sort(all_changes)

  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  for _, lnum in ipairs(all_changes) do
    if lnum > current_line then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      return
    end
  end
end

-- Navigate to previous hunk
function M.prev_hunk()
  local bufnr = vim.api.nvim_get_current_buf()
  local changes = buffers[bufnr]
  if not changes then return end

  local all_changes = {}
  for _, lnum in ipairs(changes.add) do table.insert(all_changes, lnum) end
  for _, lnum in ipairs(changes.change) do table.insert(all_changes, lnum) end
  for _, lnum in ipairs(changes.delete) do table.insert(all_changes, lnum) end
  for _, lnum in ipairs(changes.topdelete) do table.insert(all_changes, lnum) end
  for _, lnum in ipairs(changes.changedelete) do table.insert(all_changes, lnum) end
  table.sort(all_changes, function(a, b) return a > b end)

  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  for _, lnum in ipairs(all_changes) do
    if lnum < current_line then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      return
    end
  end
end

return M

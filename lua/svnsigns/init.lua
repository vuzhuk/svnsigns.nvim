local config = require("svnsigns.config")
local svn = require("svnsigns.svn")
local signs = require("svnsigns.signs")
local blame = require("svnsigns.blame")
local actions = require("svnsigns.actions")

local M = {}

-- Kept for backwards compatibility: previously the single source of
-- config, now a live view onto svnsigns.config's options.
M.config = config.options

-- Kept for backwards compatibility.
M.blame_split = blame.blame_split
M.show_line_log = blame.show_line_log
M.toggle_current_line_blame = blame.toggle_current_line_blame
M.next_hunk = signs.next_hunk
M.prev_hunk = signs.prev_hunk
M.preview_hunk = actions.preview_hunk
M.reset_hunk = actions.reset_hunk
M.reset_buffer = actions.reset_buffer
M.fzf_modified_files = actions.fzf_modified_files
M.get_modified_files = svn.get_modified_files

-- Setup function
function M.setup(opts)
  config.setup(opts)
  M.config = config.options

  config.setup_highlights()

  -- Update signs for current buffer if it exists
  local current_buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(current_buf) then
    signs.update_signs(current_buf)
  end

  -- All autocmds live in one augroup so re-running setup() (e.g. on a
  -- config reload) clears and re-registers them instead of stacking
  -- duplicate listeners on every buffer event.
  local augroup = vim.api.nvim_create_augroup("svnsigns", { clear = true })

  -- Attach to buffers
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "BufEnter" }, {
    group = augroup,
    callback = function(args)
      local buftype = vim.api.nvim_get_option_value("buftype", { buf = args.buf })
      local filetype = vim.api.nvim_get_option_value("filetype", { buf = args.buf })
      
      if buftype ~= "" or filetype == "netrw" or filetype == "help" then
        -- Clear any signs from non-file buffers
        signs.clear_signs(args.buf)
        return
      end

      local file = vim.api.nvim_buf_get_name(args.buf)
      -- BufEnter means we're coming back to this buffer after possibly
      -- being away for a while (e.g. running `svn update` in another
      -- window/terminal). Drop any cached base for this file so we don't
      -- keep diffing against a revision that's no longer current.
      if args.event == "BufEnter" and file ~= "" then
        svn.invalidate_base_cache_for_file(file)
      end

      signs.update_signs(args.buf)

      if file ~= "" then
        blame.refresh_blame_cache(args.buf, file)
      end
    end,
  })

  -- Current-line blame: re-render whenever the cursor moves. Cheap (reads
  -- from blame_line_cache, no shell-out) so no debounce needed.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    callback = function(args)
      blame.render_current_line_blame(vim.api.nvim_get_current_win(), args.buf)
    end,
  })

  -- Update on text changes
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    callback = function(args)
      local buftype = vim.api.nvim_get_option_value("buftype", { buf = args.buf })
      local filetype = vim.api.nvim_get_option_value("filetype", { buf = args.buf })
      
      if buftype ~= "" or filetype == "netrw" or filetype == "help" then
        return
      end
      signs.debounced_update(args.buf)
    end,
  })

  -- Clear signs when filetype changes to netrw
  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    pattern = { "netrw", "help", "qf" },
    callback = function(args)
      signs.clear_signs(args.buf)
    end,
  })

  -- Cleanup on buffer delete
  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    callback = function(args)
      signs.cleanup_buffer(args.buf)
      blame.cleanup_buffer(args.buf)

      local file = vim.api.nvim_buf_get_name(args.buf)
      if file ~= "" then
        svn.invalidate_base_cache_for_file(file)
      end
    end,
  })

  -- The svn-repo-ness of a directory can change mid-session (e.g. `svn co`,
  -- switching worktrees), and so can the SVN base content (e.g. `svn up`).
  -- Invalidate both caches when the cwd changes so we don't keep serving
  -- stale results forever.
  vim.api.nvim_create_autocmd("DirChanged", {
    group = augroup,
    callback = function()
      svn.invalidate_repo_cache()
      svn.invalidate_base_cache()
    end,
  })

  -- Regaining editor focus is the common moment an external `svn
  -- update`/`commit`/`switch` (run in another terminal/window while you
  -- stayed in the same buffer) would have happened. Drop the whole base
  -- cache so the next diff re-fetches instead of serving stale content,
  -- and refresh the current buffer's signs right away instead of waiting
  -- for the next edit, re-entry, or :SvnRefresh.
  vim.api.nvim_create_autocmd("FocusGained", {
    group = augroup,
    callback = function()
      svn.invalidate_base_cache()
      local bufnr = vim.api.nvim_get_current_buf()
      if vim.api.nvim_buf_is_valid(bufnr) then
        signs.update_signs(bufnr)
      end
    end,
  })

  -- Create commands
  vim.api.nvim_create_user_command("SvnBlame", M.blame_split, {})
  vim.api.nvim_create_user_command("SvnLog", M.show_line_log, {})
  vim.api.nvim_create_user_command("SvnPreview", M.preview_hunk, {})
  vim.api.nvim_create_user_command("SvnRevert", M.reset_buffer, {})
  vim.api.nvim_create_user_command("SvnResetHunk", M.reset_hunk, {})
  vim.api.nvim_create_user_command("SvnFiles", M.fzf_modified_files, {})
  vim.api.nvim_create_user_command("SvnRefresh", function()
    svn.invalidate_repo_cache()
    svn.invalidate_base_cache()
    local bufnr = vim.api.nvim_get_current_buf()
    signs.update_signs(bufnr)
    vim.notify("svnsigns: cache cleared, signs refreshed", vim.log.levels.INFO)
  end, { desc = "Clear svnsigns' repo-detection cache and refresh current buffer" })
  vim.api.nvim_create_user_command("SvnToggleCurrentLineBlame", M.toggle_current_line_blame,
    { desc = "Toggle the current-line SVN blame virtual text" })
end

return M

-- User-facing actions that inspect or mutate buffer/SVN state: hunk
-- preview, hunk/buffer reset, and the fzf-lua modified-files picker.
local svn = require("svnsigns.svn")
local diff = require("svnsigns.diff")
local signs = require("svnsigns.signs")

local M = {}

-- Preview the hunk under the cursor (gitsigns-style: just the relevant hunk,
-- not the whole-file diff).
function M.preview_hunk()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  local diff_text = svn.get_buffer_diff(bufnr, file)

  if not diff_text or diff_text == "" then
    vim.notify("No changes to preview", vim.log.levels.INFO)
    return
  end

  local hunks = diff.split_into_hunks(diff_text)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local hunk = diff.find_hunk_at_line(hunks, cursor_line)

  if not hunk then
    vim.notify("No hunk at cursor", vim.log.levels.INFO)
    return
  end

  local lines = hunk.lines
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("filetype", "diff", { buf = buf })

  local width = math.min(100, vim.o.columns - 4)
  local height = math.min(30, #lines)

  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = (vim.o.columns - width) / 2,
    row = (vim.o.lines - height) / 2,
    style = "minimal",
    border = "rounded",
    title = " SVN Hunk Diff ",
    title_pos = "center",
  })

  vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", { noremap = true, silent = true })
end

-- Reset current hunk (revert changes at cursor)
function M.reset_hunk()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)

  if file == "" or not vim.fn.filereadable(file) then
    vim.notify("No file in current buffer", vim.log.levels.WARN)
    return
  end

  if not svn.is_svn_repo(file) then
    vim.notify("File is not under SVN control", vim.log.levels.WARN)
    return
  end

  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  local changes = signs.get_changes(bufnr)

  if not changes then
    vim.notify("No changes detected", vim.log.levels.INFO)
    return
  end

  -- Get the base version
  local base = svn.get_svn_base(file)
  if not base then
    vim.notify("Failed to get SVN base version", vim.log.levels.ERROR)
    return
  end
  local base_lines = vim.split(base, "\n")

  -- Build a mapping from buffer line to base line using the diff
  local diff_text = svn.get_buffer_diff(bufnr, file)
  if not diff_text then
    vim.notify("Failed to get diff", vim.log.levels.ERROR)
    return
  end

  -- Parse the diff to understand line mapping
  local base_line = 0
  local buf_line = 0
  local line_map = {}  -- buffer line -> base line
  -- buffer line where a deletion run happened -> base line of the first
  -- line removed there. changes.delete/changes.topdelete attach their
  -- sign to the buf_line position that follows the run (see
  -- diff.parse_diff's current_line, which is the same new-file line count
  -- as buf_line here), so this is keyed the same way for a direct lookup.
  local delete_map = {}
  local in_delete_run = false

  -- Reuses diff.new_line_matchers()/match_hunk_header() so the "---"/"+++"
  -- header-exclusion and optional ",count" hunk-header quirks (see
  -- lua/svnsigns/diff.lua) are handled identically here as everywhere else
  -- a unified diff gets walked line by line.
  local matchers = diff.new_line_matchers()
  for line in diff_text:gmatch("[^\r\n]+") do
    local hunk = line:match("^@@ %-") and diff.match_hunk_header(line)
    if hunk then
      matchers.mark_hunk()
      base_line = hunk.base_start - 1
      buf_line = hunk.new_start - 1
      in_delete_run = false
    elseif matchers.is_add(line) then
      buf_line = buf_line + 1
      in_delete_run = false
      -- Added line, no base correspondence
    elseif matchers.is_del(line) then
      if not in_delete_run then
        -- buf_line hasn't advanced past this run yet, so it still equals
        -- the new-file position the deletion sign attaches to. Clamp to 1
        -- to match parse_diff's topdelete attach point (math.max(.., 1)):
        -- a deletion-only hunk that empties the buffer starts from
        -- "@@ -1,1 +0,0 @@", leaving buf_line at 0 here, but the sign is
        -- still attached to line 1 since there's no earlier line.
        delete_map[math.max(buf_line + 1, 1)] = base_line + 1
        in_delete_run = true
      end
      base_line = base_line + 1
      -- Deleted line, no buffer correspondence
    elseif line:match("^ ") then
      in_delete_run = false
      base_line = base_line + 1
      buf_line = buf_line + 1
      line_map[buf_line] = base_line
    end
  end

  -- Check what type of change is at current line
  local change_type = nil
  for _, lnum in ipairs(changes.add) do
    if lnum == current_line then change_type = "add" break end
  end
  for _, lnum in ipairs(changes.change) do
    if lnum == current_line then change_type = "change" break end
  end
  for _, lnum in ipairs(changes.delete) do
    if lnum == current_line then change_type = "delete" break end
  end
  for _, lnum in ipairs(changes.topdelete) do
    if lnum == current_line then change_type = "delete" break end
  end

  if not change_type then
    vim.notify("No changes at current line", vim.log.levels.INFO)
    return
  end

  local hunks = diff.split_into_hunks(diff_text)
  local current_hunk = diff.find_hunk_at_line(hunks, current_line)
  if not current_hunk and current_line == 1 then
    for _, hunk in ipairs(hunks) do
      local header = diff.match_hunk_header(hunk.lines[1])
      if header and header.new_start == 0 and header.new_count == 0 then
        current_hunk = hunk
        break
      end
    end
  end

  local hunk_header = current_hunk and diff.match_hunk_header(current_hunk.lines[1])
  if hunk_header then
    local replacement = {}
    for i = hunk_header.base_start, hunk_header.base_start + hunk_header.base_count - 1 do
      replacement[#replacement + 1] = base_lines[i]
    end

    local start_idx = math.max(hunk_header.new_start - 1, 0)
    local end_idx = math.max(hunk_header.new_start + hunk_header.new_count - 1, 0)
    vim.api.nvim_buf_set_lines(bufnr, start_idx, end_idx, false, replacement)
    vim.notify("Reverted hunk", vim.log.levels.INFO)
  elseif change_type == "add" then
    -- Remove the added line
    vim.api.nvim_buf_set_lines(bufnr, current_line - 1, current_line, false, {})
    vim.notify("Removed added line", vim.log.levels.INFO)
  elseif change_type == "change" then
    -- Find the corresponding base line
    local base_line_num = line_map[current_line]
    if not base_line_num then
      -- Try adjacent lines to find mapping
      for i = current_line - 1, math.max(1, current_line - 5), -1 do
        if line_map[i] then
          base_line_num = line_map[i] + (current_line - i)
          break
        end
      end
    end

    if base_line_num and base_line_num <= #base_lines then
      vim.api.nvim_buf_set_lines(bufnr, current_line - 1, current_line, false, { base_lines[base_line_num] })
      vim.notify("Reverted modified line", vim.log.levels.INFO)
    else
      vim.notify("Could not map to base line", vim.log.levels.ERROR)
    end
  elseif change_type == "delete" then
    -- Find which base line was deleted and restore it
    local base_line_num = delete_map[current_line]
    if not base_line_num then
      base_line_num = line_map[current_line]
    end
    if not base_line_num then
      for i = current_line - 1, math.max(1, current_line - 5), -1 do
        if line_map[i] then
          base_line_num = line_map[i] + 1
          break
        end
      end
    end

    if base_line_num and base_line_num <= #base_lines then
      vim.api.nvim_buf_set_lines(bufnr, current_line - 1, current_line - 1, false, { base_lines[base_line_num] })
      vim.notify("Restored deleted line", vim.log.levels.INFO)
    else
      vim.notify("Could not find deleted line", vim.log.levels.ERROR)
    end
  end

  -- Update signs
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      signs.update_signs(bufnr)
    end
  end, 50)
end

-- Reset hunks (revert changes)
function M.reset_buffer()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then return end

  vim.ui.input({ prompt = "Revert all changes? (y/N): " }, function(input)
    if input == "y" or input == "Y" then
      local output = vim.fn.system("svn revert " .. vim.fn.shellescape(file))
      if vim.v.shell_error ~= 0 then
        vim.notify("Failed to revert: " .. output, vim.log.levels.ERROR)
        return
      end
      vim.cmd("checktime")
      vim.notify("Reverted: " .. vim.fn.fnamemodify(file, ":t"), vim.log.levels.INFO)
    end
  end)
end

-- FzfLua integration for modified SVN files
function M.fzf_modified_files()
  local has_fzf, fzf = pcall(require, "fzf-lua")
  if not has_fzf then
    vim.notify("fzf-lua is not installed", vim.log.levels.ERROR)
    return
  end

  -- Get modified files
  local files = svn.get_modified_files()

  if #files == 0 then
    vim.notify("No modified files in SVN", vim.log.levels.INFO)
    return
  end

  -- Use fzf_exec, inheriting global FzfLua settings
  fzf.fzf_exec(files, {
    prompt = "SVN Files> ",
    previewer = "builtin",
    actions = fzf.config.globals.actions.files,
  })
end

return M

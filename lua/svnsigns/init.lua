local config = require("svnsigns.config")
local diff = require("svnsigns.diff")
local svn = require("svnsigns.svn")

local M = {}

-- Kept for backwards compatibility: previously the single source of
-- config, now a live view onto svnsigns.config's options.
M.config = config.options

-- State
local ns_id = vim.api.nvim_create_namespace("svnsigns")
local blame_ns_id = vim.api.nvim_create_namespace("svnsigns_current_line_blame")
local buffers = {}
local timers = {}
local blame_bufnr = nil
local blame_winnr = nil

-- Per-buffer cache of per-line blame metadata (see parse_blame_output),
-- used to render the current-line blame virtual text without re-shelling
-- out to `svn blame` on every cursor move. Keyed by bufnr.
local blame_line_cache = {}

local function refresh_blame_cache(bufnr, file)
  if not config.options.current_line_blame then return end

  svn.get_blame_lines_async(file, function(by_line)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    blame_line_cache[bufnr] = by_line
  end)
end

-- Render (or clear) the current-line blame virtual text for bufnr, based
-- on whatever is currently in blame_line_cache[bufnr] and the cursor's
-- line in its window.
local function render_current_line_blame(winnr, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, blame_ns_id, 0, -1)

  if not config.options.current_line_blame then return end
  local by_line = blame_line_cache[bufnr]
  if not by_line then return end

  local lnum = vim.api.nvim_win_get_cursor(winnr)[1]
  local blame = by_line[lnum]
  if not blame then return end

  local ok, text = pcall(config.options.current_line_blame_formatter, blame)
  if not ok or not text then return end

  vim.api.nvim_buf_set_extmark(bufnr, blame_ns_id, lnum - 1, 0, {
    virt_text = { { text, "SvnSignsCurrentLineBlame" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

-- Place signs in buffer
local function place_signs(bufnr, changes)
  -- Clear existing signs
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  -- Place add signs
  for _, lnum in ipairs(changes.add) do
    if lnum > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum - 1, 0, {
        sign_text = config.options.signs.add.text,
        sign_hl_group = "SvnSignsAdd",
        priority = config.options.sign_priority,
      })
    end
  end

  -- Place change signs
  for _, lnum in ipairs(changes.change) do
    if lnum > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum - 1, 0, {
        sign_text = config.options.signs.change.text,
        sign_hl_group = "SvnSignsChange",
        priority = config.options.sign_priority,
      })
    end
  end

  -- Place delete signs
  for _, lnum in ipairs(changes.delete) do
    if lnum > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum - 1, 0, {
        sign_text = config.options.signs.delete.text,
        sign_hl_group = "SvnSignsDelete",
        priority = config.options.sign_priority,
      })
    end
  end

  -- Place topdelete signs (pure deletion at the very start of the file)
  for _, lnum in ipairs(changes.topdelete) do
    if lnum > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum - 1, 0, {
        sign_text = config.options.signs.topdelete.text,
        sign_hl_group = "SvnSignsTopDelete",
        priority = config.options.sign_priority,
      })
    end
  end

  -- Place changedelete signs (a change block with leftover removals)
  for _, lnum in ipairs(changes.changedelete) do
    if lnum > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum - 1, 0, {
        sign_text = config.options.signs.changedelete.text,
        sign_hl_group = "SvnSignsChangeDelete",
        priority = config.options.sign_priority,
      })
    end
  end
end

-- Update signs for buffer (async: never blocks the main thread)
local function update_signs(bufnr)
  -- Skip non-normal buffers (netrw, help, etc.)
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
  local filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
  
  if buftype ~= "" or filetype == "netrw" or filetype == "help" then
    -- Clear any signs from special buffers
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    return
  end
  
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" or not vim.fn.filereadable(file) then
    return
  end

  svn.is_svn_repo_async(file, function(is_repo)
    if not is_repo then return end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    svn.get_buffer_diff_async(bufnr, file, function(diff_output)
      if not diff_output then return end
      if not vim.api.nvim_buf_is_valid(bufnr) then return end

      local changes = diff.parse_diff(diff_output)
      place_signs(bufnr, changes)
      buffers[bufnr] = changes
    end)
  end)
end

-- Debounced update
local function debounced_update(bufnr)
  if timers[bufnr] then
    timers[bufnr]:stop()
  end

  timers[bufnr] = vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      update_signs(bufnr)
    end
    timers[bufnr] = nil
  end, config.options.update_debounce)
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
  table.sort(all_changes, function(a, b) return a > b end)

  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  for _, lnum in ipairs(all_changes) do
    if lnum < current_line then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      return
    end
  end
end

-- Preview the hunk under the cursor (gitsigns-style: just the relevant hunk,
-- not the whole-file diff).
function M.preview_hunk()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  local diff_output = svn.get_buffer_diff(bufnr, file)
  
  if not diff_output or diff_output == "" then
    vim.notify("No changes to preview", vim.log.levels.INFO)
    return
  end

  local hunks = diff.split_into_hunks(diff_output)
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

  local win = vim.api.nvim_open_win(buf, true, {
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

-- Show SVN log for current line in hover
function M.show_line_log()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("No file in current buffer", vim.log.levels.WARN)
    return
  end

  if not svn.is_svn_repo(file) then
    vim.notify("File is not under SVN control", vim.log.levels.WARN)
    return
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local rev = svn.get_line_blame(file, lnum)
  
  if not rev then
    vim.notify("No blame information for this line", vim.log.levels.WARN)
    return
  end

  local log = svn.get_revision_log(file, rev)
  if not log or log == "" then
    vim.notify("No log information available", vim.log.levels.WARN)
    return
  end

  local lines = vim.split(log, "\n")
  
  -- Show in floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })

  local width = 80
  local height = math.min(#lines, 20)

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    width = width,
    height = height,
    row = 1,
    col = 0,
    style = "minimal",
    border = "rounded",
    title = " SVN Log (r" .. rev .. ") ",
    title_pos = "center",
  })

  -- Close on cursor move or any key
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufLeave" }, {
    buffer = vim.api.nvim_get_current_buf(),
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })
end
function M.blame_split()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("No file in current buffer", vim.log.levels.WARN)
    return
  end

  if not svn.is_svn_repo(file) then
    vim.notify("File is not under SVN control", vim.log.levels.WARN)
    return
  end

  -- Close existing blame window if open
  if blame_winnr and vim.api.nvim_win_is_valid(blame_winnr) then
    vim.api.nvim_win_close(blame_winnr, true)
    blame_winnr = nil
    blame_bufnr = nil
    return
  end

  local blame = svn.get_blame_metadata(file)
  if not blame or blame == "" then
    vim.notify("No blame information available", vim.log.levels.WARN)
    return
  end

  local lines = vim.split(blame, "\n")
  
  -- Calculate max width
  local max_width = 0
  for _, line in ipairs(lines) do
    if #line > max_width then
      max_width = #line
    end
  end
  
  -- Create blame buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  
  -- Open vertical split on the left
  vim.cmd("topleft vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, max_width)

  -- 'wrap' is window-local, not buffer-local, so it must be scoped to this
  -- specific window rather than set on the buffer.
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  
  -- Disable line numbers in blame window
  vim.api.nvim_set_option_value("number", false, { win = win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win })
  
  -- Store window and buffer numbers
  blame_winnr = win
  blame_bufnr = buf
  
  -- Setup highlighting for blame buffer
  local source_bufnr = vim.fn.bufnr("#")
  for i, line in ipairs(lines) do
    local rev = line:match("^%s*(%d+)")
    if rev then
      vim.api.nvim_buf_add_highlight(buf, -1, "SvnSignsBlameRevision", i - 1, 0, #rev + 1)
      local author_start = line:find("%S", #rev + 2)
      if author_start then
        local author_end = line:find("%s", author_start)
        if author_end then
          vim.api.nvim_buf_add_highlight(buf, -1, "SvnSignsBlameAuthor", i - 1, author_start - 1, author_end - 1)
        end
      end
    end
  end
  
  -- Setup keymaps
  vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", { noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", { noremap = true, silent = true })
  
  -- Sync scrolling with source buffer
  local augroup = vim.api.nvim_create_augroup("SvnBlameSync", { clear = true })
  
  -- Sync blame window when source moves
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    buffer = source_bufnr,
    callback = function()
      if blame_winnr and vim.api.nvim_win_is_valid(blame_winnr) then
        local line = vim.api.nvim_win_get_cursor(0)[1]
        local topline = vim.fn.line("w0")
        local blame_line_count = vim.api.nvim_buf_line_count(buf)
        
        -- Ensure line is within bounds
        if line <= blame_line_count then
          vim.api.nvim_win_set_cursor(blame_winnr, { line, 0 })
          vim.api.nvim_win_call(blame_winnr, function()
            vim.cmd("normal! " .. topline .. "zt")
            vim.api.nvim_win_set_cursor(0, { line, 0 })
          end)
        end
      end
    end,
  })
  
  -- Sync source window when blame moves
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    buffer = buf,
    callback = function()
      if vim.api.nvim_buf_is_valid(source_bufnr) then
        local source_win = vim.fn.bufwinid(source_bufnr)
        if source_win ~= -1 then
          local line = vim.api.nvim_win_get_cursor(0)[1]
          local topline = vim.fn.line("w0")
          local source_line_count = vim.api.nvim_buf_line_count(source_bufnr)
          
          -- Ensure line is within bounds
          if line <= source_line_count then
            vim.api.nvim_win_set_cursor(source_win, { line, 0 })
            vim.api.nvim_win_call(source_win, function()
              vim.cmd("normal! " .. topline .. "zt")
              vim.api.nvim_win_set_cursor(0, { line, 0 })
            end)
          end
        end
      end
    end,
  })
  
  -- Go back to source window
  vim.cmd("wincmd p")
  
  vim.notify("SVN blame opened (press q to close)", vim.log.levels.INFO)
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
  local changes = buffers[bufnr]
  
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
  
  -- Get current buffer lines
  local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  
  -- Build a mapping from buffer line to base line using the diff
  local diff = svn.get_buffer_diff(bufnr, file)
  if not diff then
    vim.notify("Failed to get diff", vim.log.levels.ERROR)
    return
  end
  
  -- Parse the diff to understand line mapping
  local base_line = 0
  local buf_line = 0
  local line_map = {}  -- buffer line -> base line
  -- buffer line where a deletion run happened -> base line of the first
  -- line removed there. changes.delete/changes.topdelete attach their
  -- sign to the buf_line position that follows the run (see parse_diff's
  -- current_line, which is the same new-file line count as buf_line
  -- here), so this is keyed the same way for a direct lookup.
  local delete_map = {}
  local in_delete_run = false
  
  -- Same hunk-aware rule as parse_diff/split_into_hunks: the literal
  -- "---"/"+++" file-header lines only ever appear before the first "@@"
  -- marker, so the exclusion below must stop applying once inside a hunk,
  -- otherwise a real deleted/added comment line throws off this line
  -- mapping and :SvnResetHunk can restore the wrong content.
  local seen_hunk = false
  for line in diff:gmatch("[^\r\n]+") do
    -- diff -u omits the ",count" suffix when a range is exactly one line
    -- (e.g. "@@ -1 +0,0 @@"), so both counts must be optional here or
    -- single-line hunks never flip seen_hunk and a deleted/added comment
    -- line right after them would still be wrongly filtered as a header.
    local base_start, buf_start = line:match("^@@ %-(%d+),?%d* %+(%d+)")
    if base_start and buf_start then
      seen_hunk = true
      base_line = tonumber(base_start) - 1
      buf_line = tonumber(buf_start) - 1
      in_delete_run = false
    elseif line:sub(1, 1) == "+" and (seen_hunk or not line:match("^%+%+%+")) then
      buf_line = buf_line + 1
      in_delete_run = false
      -- Added line, no base correspondence
    elseif line:sub(1, 1) == "-" and (seen_hunk or not line:match("^%-%-%-")) then
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

  if change_type == "add" then
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
      update_signs(bufnr)
    end
  end, 50)
end

-- Reset hunks (revert changes)
function M.reset_buffer()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then return end

  vim.ui.input({ prompt = "Revert all changes? (y/N): " }, function(input)
    if input == "y" or input == "Y" then
      vim.fn.system("svn revert " .. vim.fn.shellescape(file))
      vim.cmd("checktime")
      vim.notify("Reverted: " .. vim.fn.fnamemodify(file, ":t"), vim.log.levels.INFO)
    end
  end)
end

-- Toggle the current-line blame virtual text on/off. When turning it on,
-- immediately (re)populate the cache for the current buffer so the
-- annotation appears without waiting for the next BufReadPost/Write.
function M.toggle_current_line_blame()
  config.options.current_line_blame = not config.options.current_line_blame

  local bufnr = vim.api.nvim_get_current_buf()
  if config.options.current_line_blame then
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file ~= "" then
      refresh_blame_cache(bufnr, file)
    end
  end
  render_current_line_blame(vim.api.nvim_get_current_win(), bufnr)

  vim.notify(
    "svnsigns: current-line blame " .. (config.options.current_line_blame and "enabled" or "disabled"),
    vim.log.levels.INFO
  )
end

-- Setup function
function M.setup(opts)
  config.setup(opts)
  M.config = config.options

  config.setup_highlights()

  -- Update signs for current buffer if it exists
  local current_buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(current_buf) then
    update_signs(current_buf)
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
        vim.api.nvim_buf_clear_namespace(args.buf, ns_id, 0, -1)
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

      update_signs(args.buf)

      if file ~= "" then
        refresh_blame_cache(args.buf, file)
      end
    end,
  })

  -- Current-line blame: re-render whenever the cursor moves. Cheap (reads
  -- from blame_line_cache, no shell-out) so no debounce needed.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    callback = function(args)
      render_current_line_blame(vim.api.nvim_get_current_win(), args.buf)
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
      debounced_update(args.buf)
    end,
  })

  -- Clear signs when filetype changes to netrw
  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    pattern = { "netrw", "help", "qf" },
    callback = function(args)
      vim.api.nvim_buf_clear_namespace(args.buf, ns_id, 0, -1)
    end,
  })

  -- Cleanup on buffer delete
  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    callback = function(args)
      buffers[args.buf] = nil
      if timers[args.buf] then
        timers[args.buf]:stop()
        timers[args.buf] = nil
      end
      blame_line_cache[args.buf] = nil

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
        update_signs(bufnr)
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
    update_signs(bufnr)
    vim.notify("svnsigns: cache cleared, signs refreshed", vim.log.levels.INFO)
  end, { desc = "Clear svnsigns' repo-detection cache and refresh current buffer" })
  vim.api.nvim_create_user_command("SvnToggleCurrentLineBlame", M.toggle_current_line_blame,
    { desc = "Toggle the current-line SVN blame virtual text" })
end

-- Kept for backwards compatibility: callers used to reach this on the
-- plugin's top-level module.
M.get_modified_files = svn.get_modified_files

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

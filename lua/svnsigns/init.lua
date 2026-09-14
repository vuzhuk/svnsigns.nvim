local M = {}

-- Configuration
M.config = {
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

-- Cache of "is this directory under SVN control?" so we don't re-shell out
-- to `svn info` on every debounced update. Keyed by directory path.
local svn_repo_cache = {}

-- Whether we've already warned the user that a required binary is missing,
-- so we don't spam :notify on every keystroke/buffer event.
local warned_missing_binary = {}

-- vim.system() throws synchronously (ENOENT) if the executable isn't found,
-- unlike the old `io.popen("cmd 2>/dev/null")` approach which just returned
-- an empty result. Wrap it so a missing `svn`/`diff` binary degrades
-- gracefully (no signs) instead of erroring on every buffer/text event.
local function safe_system(cmd, opts, on_exit)
  local ok, err = pcall(vim.system, cmd, opts, function(res)
    on_exit(res)
  end)
  if not ok then
    local bin = cmd[1]
    if not warned_missing_binary[bin] then
      warned_missing_binary[bin] = true
      vim.schedule(function()
        vim.notify(
          string.format("svnsigns: '%s' not found, disabling SVN signs (%s)", bin, tostring(err)),
          vim.log.levels.WARN
        )
      end)
    end
    on_exit({ code = 127, stdout = "", stderr = tostring(err) })
  end
end

-- Define sign highlights
local function setup_highlights()
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

-- Check if file is under SVN control (synchronous; used by on-demand user
-- commands like :SvnBlame/:SvnLog/:SvnResetHunk where a brief blocking call
-- on explicit invocation is acceptable).
local function is_svn_repo(file)
  local handle = io.popen("svn info " .. vim.fn.shellescape(file) .. " 2>/dev/null")
  if not handle then return false end
  local result = handle:read("*a")
  handle:close()
  return result and result ~= ""
end

-- Async version of is_svn_repo, cached per-directory so the hot update path
-- (TextChanged/BufEnter) doesn't shell out to `svn info` on every keystroke.
-- callback(bool)
local function is_svn_repo_async(file, callback)
  local dir = vim.fn.fnamemodify(file, ":h")
  local cached = svn_repo_cache[dir]
  if cached ~= nil then
    callback(cached)
    return
  end

  safe_system({ "svn", "info", file }, { text = true }, function(res)
    local is_repo = res.code == 0 and res.stdout ~= nil and res.stdout ~= ""
    svn_repo_cache[dir] = is_repo
    vim.schedule(function() callback(is_repo) end)
  end)
end

-- Get SVN base version of file
local function get_svn_base(file)
  local handle = io.popen("svn cat " .. vim.fn.shellescape(file) .. " 2>/dev/null")
  if not handle then return nil end
  local result = handle:read("*a")
  handle:close()
  return result
end

-- Cache of the SVN base ("svn cat") content per file, so the hot update
-- path (TextChanged/BufEnter) doesn't re-shell out to `svn cat` on every
-- debounced keystroke. The base only changes on `svn update`/checkout, not
-- on local edits, so it's safe to reuse until explicitly invalidated (see
-- :SvnRefresh and the DirChanged autocmd). Wrapped in a table (instead of
-- storing the string directly) so a cached "no base" (nil) result is still
-- distinguishable from "not cached yet".
local svn_base_cache = {}

-- Bumped every time svn_base_cache is invalidated (per-file or wholesale).
-- An in-flight `svn cat` captures the generation it started with, so if a
-- cache clear happens while it's still running, its result is stale and
-- must not be written back into the cache once it lands.
local svn_base_cache_generation = 0

-- Async version of get_svn_base, backed by svn_base_cache.
-- callback(base_content_or_nil)
local function get_svn_base_async(file, callback)
  local cached = svn_base_cache[file]
  if cached ~= nil then
    vim.schedule(function() callback(cached.base) end)
    return
  end

  local generation = svn_base_cache_generation
  safe_system({ "svn", "cat", file }, { text = true }, function(res)
    -- code == 0 alone tells us the file is versioned; an empty stdout is a
    -- valid "empty file" base, not "no base". Only a failed `svn cat`
    -- (unversioned/missing file) should map to nil.
    local base = (res.code == 0) and res.stdout or nil
    if generation == svn_base_cache_generation then
      svn_base_cache[file] = { base = base }
    end
    vim.schedule(function() callback(base) end)
  end)
end

-- Get diff between buffer and SVN base
local function get_buffer_diff(bufnr, file)
  -- Get SVN base version
  local base = get_svn_base(file)
  if not base then return nil end
  
  -- Get current buffer content
  local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local buffer_content = table.concat(buffer_lines, "\n")
  
  -- Ensure both have trailing newline to match file format
  if base:sub(-1) == "\n" then
    buffer_content = buffer_content .. "\n"
  end
  
  -- Write both to temp files for diff
  local base_file = vim.fn.tempname()
  local curr_file = vim.fn.tempname()
  
  local f = io.open(base_file, "w")
  if f then
    f:write(base)
    f:close()
  end
  
  f = io.open(curr_file, "w")
  if f then
    f:write(buffer_content)
    f:close()
  end
  
  -- Run diff
  local handle = io.popen(string.format("diff -u %s %s 2>/dev/null", 
    vim.fn.shellescape(base_file), 
    vim.fn.shellescape(curr_file)))
  
  local diff = nil
  if handle then
    diff = handle:read("*a")
    handle:close()
  end
  
  -- Cleanup temp files
  os.remove(base_file)
  os.remove(curr_file)
  
  return diff
end

-- Async version of get_buffer_diff: gets the SVN base and runs `diff`
-- without blocking the main thread. callback(diff_or_nil)
local function get_buffer_diff_async(bufnr, file, callback)
  get_svn_base_async(file, function(base)
    if not base then
      callback(nil)
      return
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
      callback(nil)
      return
    end

    local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local buffer_content = table.concat(buffer_lines, "\n")
    if base:sub(-1) == "\n" then
      buffer_content = buffer_content .. "\n"
    end

    local base_file = vim.fn.tempname()
    local curr_file = vim.fn.tempname()

    local ok_base = pcall(function()
      local f = assert(io.open(base_file, "w"))
      f:write(base)
      f:close()
    end)
    local ok_curr = pcall(function()
      local f = assert(io.open(curr_file, "w"))
      f:write(buffer_content)
      f:close()
    end)

    if not ok_base or not ok_curr then
      os.remove(base_file)
      os.remove(curr_file)
      callback(nil)
      return
    end

    safe_system({ "diff", "-u", base_file, curr_file }, { text = true }, function(res)
      -- `diff` exits 1 when files differ, which is not an error for us.
      local diff = res.stdout
      os.remove(base_file)
      os.remove(curr_file)
      vim.schedule(function() callback(diff) end)
    end)
  end)
end

-- Parse unified diff to extract changes, classified the same way gitsigns
-- classifies hunks:
--   add          - pure new lines with no corresponding removal
--   change       - a removed line paired 1:1 with an added line
--   delete       - removed lines with nothing replacing them, mid-file
--   topdelete    - removed lines with nothing replacing them, at the very
--                  start of the file (nothing precedes them to attach to)
--   changedelete - a change block where more lines were removed than added;
--                  the "leftover" removals attach to the last changed line
local function parse_diff(diff_output)
  local changes = { add = {}, change = {}, delete = {}, topdelete = {}, changedelete = {} }
  if not diff_output or diff_output == "" then
    return changes
  end

  -- First, collect all lines into a table so we can look ahead
  local lines = {}
  for line in diff_output:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  local current_line = 0
  -- True until we've emitted any context/add/change line — i.e. nothing in
  -- the new file precedes the current position yet. Only while this holds
  -- can a pure-deletion block be a "topdelete" (deletion at file start).
  local at_file_start = true
  local i = 1

  local function is_del(l) return l:match("^%-") and not l:match("^%-%-%-") end
  local function is_add(l) return l:match("^%+") and not l:match("^%+%+%+") end

  while i <= #lines do
    local line = lines[i]

    if line:match("^@@ %-") then
      current_line = tonumber(line:match("^@@ %-[%d,]+ %+(%d+)")) or 0
      i = i + 1
    elseif is_del(line) then
      local was_at_file_start = at_file_start

      -- Collect the run of consecutive deletions...
      local del_count = 0
      local j = i
      while j <= #lines and is_del(lines[j]) do
        del_count = del_count + 1
        j = j + 1
      end
      -- ...and the run of consecutive additions immediately following it.
      local add_count = 0
      local k = j
      while k <= #lines and is_add(lines[k]) do
        add_count = add_count + 1
        k = k + 1
      end

      local paired = math.min(del_count, add_count)
      for _ = 1, paired do
        table.insert(changes.change, current_line)
        current_line = current_line + 1
      end
      at_file_start = false

      if del_count > add_count then
        -- Deleted lines don't exist in the new file, so however many were
        -- removed, only one sign is placed at the single attach point.
        if paired > 0 then
          -- Excess removals right after a change: changedelete, attached
          -- to the last changed line.
          local attach_line = math.max(current_line - 1, 1)
          table.insert(changes.changedelete, attach_line)
        elseif was_at_file_start and current_line <= 1 then
          -- Pure deletion with nothing before it in the file: topdelete,
          -- attached to line 1 since there's no earlier line to point to.
          table.insert(changes.topdelete, math.max(current_line, 1))
        else
          table.insert(changes.delete, current_line)
        end
      elseif add_count > del_count then
        local excess = add_count - del_count
        for _ = 1, excess do
          table.insert(changes.add, current_line)
          current_line = current_line + 1
        end
      end

      i = k
    elseif is_add(line) then
      table.insert(changes.add, current_line)
      current_line = current_line + 1
      at_file_start = false
      i = i + 1
    elseif line:match("^ ") then
      current_line = current_line + 1
      at_file_start = false
      i = i + 1
    else
      i = i + 1
    end
  end

  return changes
end

-- Split a unified diff into hunks, each covering a contiguous range of the
-- *new* (buffer) file. Used by preview_hunk to show only the hunk under the
-- cursor instead of the whole-file diff (gitsigns-style).
-- Returns: { { new_start = N, new_count = M, lines = {...} }, ... }
local function split_into_hunks(diff_output)
  local hunks = {}
  if not diff_output or diff_output == "" then
    return hunks
  end

  local lines = {}
  for line in diff_output:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  local current = nil
  for _, line in ipairs(lines) do
    local new_start, new_count = line:match("^@@ %-[%d,]+ %+(%d+),?(%d*) @@")
    if new_start then
      if current then table.insert(hunks, current) end
      current = {
        new_start = tonumber(new_start),
        new_count = tonumber(new_count) or 1,
        lines = { line },
      }
    elseif current and not line:match("^%-%-%-") and not line:match("^%+%+%+") then
      table.insert(current.lines, line)
    end
  end
  if current then table.insert(hunks, current) end

  return hunks
end

-- Find the hunk (if any) whose new-file line range contains `cursor_line`
-- (1-indexed). A hunk's range includes its surrounding unified-diff context
-- lines, matching how gitsigns scopes preview_hunk to "the hunk near you".
local function find_hunk_at_line(hunks, cursor_line)
  for _, hunk in ipairs(hunks) do
    local last = hunk.new_start + math.max(hunk.new_count, 1) - 1
    if cursor_line >= hunk.new_start and cursor_line <= last then
      return hunk
    end
  end
  return nil
end

-- Get SVN blame metadata only (no code)
local function get_blame_metadata(file)
  -- Get blame with verbose mode, extract rev (col 1), author (col 2), and date (col 3)
  -- Format: revision author date
  local cmd = string.format("svn blame -v %s 2>/dev/null | awk '{printf \"%%6s %%15s %%s\\n\", $1, $2, $3}'", vim.fn.shellescape(file))
  local handle = io.popen(cmd)
  if not handle then return nil end
  local result = handle:read("*a")
  handle:close()
  return result
end

-- Parse `svn blame -v` output into a table indexed by (1-based) line number:
-- { [lnum] = { rev = "12", author = "vuzhuk", date = "2026-09-14" }, ... }
-- Each line looks like:
--   "    12   vuzhuk 2026-09-14 13:04:42 -0700 (Mon, 14 Sep 2026) some code"
local function parse_blame_output(blame_output)
  local by_line = {}
  if not blame_output or blame_output == "" then
    return by_line
  end

  local lnum = 0
  for line in blame_output:gmatch("[^\r\n]+") do
    lnum = lnum + 1
    local rev, author, date = line:match("^%s*(%d+)%s+(%S+)%s+(%d%d%d%d%-%d%d%-%d%d)")
    if rev then
      by_line[lnum] = { rev = rev, author = author, date = date }
    end
  end

  return by_line
end

-- Async: full-file `svn blame -v`, parsed into per-line metadata.
-- callback(by_line_or_nil)
local function get_blame_lines_async(file, callback)
  safe_system({ "svn", "blame", "-v", file }, { text = true }, function(res)
    local parsed = (res.code == 0 and res.stdout ~= "") and parse_blame_output(res.stdout) or nil
    vim.schedule(function() callback(parsed) end)
  end)
end

-- Refresh blame_line_cache[bufnr] from disk (async). Used to back the
-- current-line blame virtual text; a no-op if the feature is disabled.
local function refresh_blame_cache(bufnr, file)
  if not M.config.current_line_blame then return end

  get_blame_lines_async(file, function(by_line)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    blame_line_cache[bufnr] = by_line
  end)
end

-- Render (or clear) the current-line blame virtual text for bufnr, based
-- on whatever is currently in blame_line_cache[bufnr] and the cursor's
-- line in its window.
local function render_current_line_blame(winnr, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, blame_ns_id, 0, -1)

  if not M.config.current_line_blame then return end
  local by_line = blame_line_cache[bufnr]
  if not by_line then return end

  local lnum = vim.api.nvim_win_get_cursor(winnr)[1]
  local blame = by_line[lnum]
  if not blame then return end

  local ok, text = pcall(M.config.current_line_blame_formatter, blame)
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
        sign_text = M.config.signs.add.text,
        sign_hl_group = "SvnSignsAdd",
        priority = M.config.sign_priority,
      })
    end
  end

  -- Place change signs
  for _, lnum in ipairs(changes.change) do
    if lnum > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum - 1, 0, {
        sign_text = M.config.signs.change.text,
        sign_hl_group = "SvnSignsChange",
        priority = M.config.sign_priority,
      })
    end
  end

  -- Place delete signs
  for _, lnum in ipairs(changes.delete) do
    if lnum > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum - 1, 0, {
        sign_text = M.config.signs.delete.text,
        sign_hl_group = "SvnSignsDelete",
        priority = M.config.sign_priority,
      })
    end
  end

  -- Place topdelete signs (pure deletion at the very start of the file)
  for _, lnum in ipairs(changes.topdelete) do
    if lnum > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum - 1, 0, {
        sign_text = M.config.signs.topdelete.text,
        sign_hl_group = "SvnSignsTopDelete",
        priority = M.config.sign_priority,
      })
    end
  end

  -- Place changedelete signs (a change block with leftover removals)
  for _, lnum in ipairs(changes.changedelete) do
    if lnum > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, lnum - 1, 0, {
        sign_text = M.config.signs.changedelete.text,
        sign_hl_group = "SvnSignsChangeDelete",
        priority = M.config.sign_priority,
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

  is_svn_repo_async(file, function(is_repo)
    if not is_repo then return end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end

    get_buffer_diff_async(bufnr, file, function(diff)
      if not diff then return end
      if not vim.api.nvim_buf_is_valid(bufnr) then return end

      local changes = parse_diff(diff)
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
  end, M.config.update_debounce)
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
  local diff = get_buffer_diff(bufnr, file)
  
  if not diff or diff == "" then
    vim.notify("No changes to preview", vim.log.levels.INFO)
    return
  end

  local hunks = split_into_hunks(diff)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local hunk = find_hunk_at_line(hunks, cursor_line)

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

-- Get SVN log for a specific revision
local function get_revision_log(file, revision)
  local cmd = string.format("svn log -r %s %s 2>/dev/null", revision, vim.fn.shellescape(file))
  local handle = io.popen(cmd)
  if not handle then return nil end
  local result = handle:read("*a")
  handle:close()
  return result
end

-- Get SVN blame for a specific line
local function get_line_blame(file, lnum)
  local cmd = string.format("svn blame -v %s 2>/dev/null | sed -n '%dp'", vim.fn.shellescape(file), lnum)
  local handle = io.popen(cmd)
  if not handle then return nil end
  local result = handle:read("*a")
  handle:close()
  
  if not result or result == "" then return nil end
  
  -- Parse: "   rev author date time ..."
  local rev = result:match("^%s*(%d+)")
  return rev
end

-- Show SVN log for current line in hover
function M.show_line_log()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    vim.notify("No file in current buffer", vim.log.levels.WARN)
    return
  end

  if not is_svn_repo(file) then
    vim.notify("File is not under SVN control", vim.log.levels.WARN)
    return
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local rev = get_line_blame(file, lnum)
  
  if not rev then
    vim.notify("No blame information for this line", vim.log.levels.WARN)
    return
  end

  local log = get_revision_log(file, rev)
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

  if not is_svn_repo(file) then
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

  local blame = get_blame_metadata(file)
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

  if not is_svn_repo(file) then
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
  local base = get_svn_base(file)
  if not base then
    vim.notify("Failed to get SVN base version", vim.log.levels.ERROR)
    return
  end
  local base_lines = vim.split(base, "\n")
  
  -- Get current buffer lines
  local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  
  -- Build a mapping from buffer line to base line using the diff
  local diff = get_buffer_diff(bufnr, file)
  if not diff then
    vim.notify("Failed to get diff", vim.log.levels.ERROR)
    return
  end
  
  -- Parse the diff to understand line mapping
  local base_line = 0
  local buf_line = 0
  local line_map = {}  -- buffer line -> base line
  
  for line in diff:gmatch("[^\r\n]+") do
    local base_start, buf_start = line:match("^@@ %-(%d+),[%d]+ %+(%d+)")
    if base_start and buf_start then
      base_line = tonumber(base_start) - 1
      buf_line = tonumber(buf_start) - 1
    elseif line:match("^%+") and not line:match("^%+%+%+") then
      buf_line = buf_line + 1
      -- Added line, no base correspondence
    elseif line:match("^%-") and not line:match("^%-%-%-") then
      base_line = base_line + 1
      -- Deleted line, no buffer correspondence
    elseif line:match("^ ") then
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
    local base_line_num = line_map[current_line]
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
  M.config.current_line_blame = not M.config.current_line_blame

  local bufnr = vim.api.nvim_get_current_buf()
  if M.config.current_line_blame then
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file ~= "" then
      refresh_blame_cache(bufnr, file)
    end
  end
  render_current_line_blame(vim.api.nvim_get_current_win(), bufnr)

  vim.notify(
    "svnsigns: current-line blame " .. (M.config.current_line_blame and "enabled" or "disabled"),
    vim.log.levels.INFO
  )
end

-- Setup function
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  
  setup_highlights()

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
        svn_base_cache[file] = nil
        svn_base_cache_generation = svn_base_cache_generation + 1
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
        svn_base_cache[file] = nil
        svn_base_cache_generation = svn_base_cache_generation + 1
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
      svn_repo_cache = {}
      svn_base_cache = {}
      svn_base_cache_generation = svn_base_cache_generation + 1
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
      svn_base_cache = {}
      svn_base_cache_generation = svn_base_cache_generation + 1
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
    svn_repo_cache = {}
    svn_base_cache = {}
    svn_base_cache_generation = svn_base_cache_generation + 1
    local bufnr = vim.api.nvim_get_current_buf()
    update_signs(bufnr)
    vim.notify("svnsigns: cache cleared, signs refreshed", vim.log.levels.INFO)
  end, { desc = "Clear svnsigns' repo-detection cache and refresh current buffer" })
  vim.api.nvim_create_user_command("SvnToggleCurrentLineBlame", M.toggle_current_line_blame,
    { desc = "Toggle the current-line SVN blame virtual text" })
end

-- Get list of modified/added files in SVN
function M.get_modified_files()
  local handle = io.popen("svn status 2>/dev/null")
  if not handle then return {} end
  
  local files = {}
  for line in handle:lines() do
    -- Parse svn status output: first char is status (M=modified, A=added, etc)
    local status = line:sub(1, 1)
    local file = line:sub(9)  -- File path starts at column 9
    
    if status == "M" or status == "A" or status == "?" then
      table.insert(files, file)
    end
  end
  handle:close()
  
  return files
end

-- FzfLua integration for modified SVN files
function M.fzf_modified_files()
  local has_fzf, fzf = pcall(require, "fzf-lua")
  if not has_fzf then
    vim.notify("fzf-lua is not installed", vim.log.levels.ERROR)
    return
  end
  
  -- Get modified files
  local files = M.get_modified_files()
  
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

-- All shelling-out to `svn`/`diff` binaries: repo detection, base-revision
-- content, buffer diffs, blame data, and the repo-detection/base-content
-- caches that keep the hot update path (TextChanged/BufEnter) from
-- re-shelling out on every keystroke.
local M = {}

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

-- Cache of "is this directory under SVN control?" so we don't re-shell out
-- to `svn info` on every debounced update. Keyed by directory path.
local svn_repo_cache = {}

-- Cache of the SVN base ("svn cat") content per file, so the hot update
-- path (TextChanged/BufEnter) doesn't re-shell out to `svn cat` on every
-- debounced keystroke. The base only changes on `svn update`/checkout, not
-- on local edits, so it's safe to reuse until explicitly invalidated (see
-- the M.invalidate_* functions below). Wrapped in a table (instead of
-- storing the string directly) so a cached "no base" (nil) result is still
-- distinguishable from "not cached yet".
local svn_base_cache = {}

-- Bumped every time svn_base_cache is invalidated (per-file or wholesale).
-- An in-flight `svn cat` captures the generation it started with, so if a
-- cache clear happens while it's still running, its result is stale and
-- must not be written back into the cache once it lands.
local svn_base_cache_generation = 0

-- Clear the repo-detection cache wholesale (e.g. on DirChanged/:SvnRefresh,
-- where "is this a repo?" may now have a different answer).
function M.invalidate_repo_cache()
  svn_repo_cache = {}
end

-- Clear the SVN base cache wholesale (e.g. on DirChanged/FocusGained/
-- :SvnRefresh, where an external `svn update` may have changed the base
-- revision for any number of files).
function M.invalidate_base_cache()
  svn_base_cache = {}
  svn_base_cache_generation = svn_base_cache_generation + 1
end

-- Clear the SVN base cache for a single file (e.g. on BufEnter/BufDelete).
function M.invalidate_base_cache_for_file(file)
  svn_base_cache[file] = nil
  svn_base_cache_generation = svn_base_cache_generation + 1
end

-- Check if file is under SVN control (synchronous; used by on-demand user
-- commands like :SvnBlame/:SvnLog/:SvnResetHunk where a brief blocking call
-- on explicit invocation is acceptable).
function M.is_svn_repo(file)
  local handle = io.popen("svn info " .. vim.fn.shellescape(file) .. " 2>/dev/null")
  if not handle then return false end
  local result = handle:read("*a")
  handle:close()
  return result and result ~= ""
end

-- Async version of is_svn_repo, cached per-directory so the hot update path
-- (TextChanged/BufEnter) doesn't shell out to `svn info` on every keystroke.
-- callback(bool)
function M.is_svn_repo_async(file, callback)
  local dir = vim.fn.fnamemodify(file, ":h")
  local cached = svn_repo_cache[dir]
  if cached ~= nil then
    callback(cached)
    return
  end

  safe_system({ "svn", "info", dir }, { text = true }, function(res)
    local is_repo = res.code == 0 and res.stdout ~= nil and res.stdout ~= ""
    svn_repo_cache[dir] = is_repo
    vim.schedule(function() callback(is_repo) end)
  end)
end

-- Get SVN base version of file
function M.get_svn_base(file)
  local handle = io.popen("svn cat " .. vim.fn.shellescape(file) .. " 2>/dev/null")
  if not handle then return nil end
  local result = handle:read("*a")
  handle:close()
  return result
end

-- Async version of get_svn_base, backed by svn_base_cache.
-- callback(base_content_or_nil)
function M.get_svn_base_async(file, callback)
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
      vim.schedule(function() callback(base) end)
    end
  end)
end

-- Get diff between buffer and SVN base
function M.get_buffer_diff(bufnr, file)
  -- Get SVN base version
  local base = M.get_svn_base(file)
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
function M.get_buffer_diff_async(bufnr, file, callback)
  M.get_svn_base_async(file, function(base)
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

-- Get SVN blame metadata only (no code)
function M.get_blame_metadata(file)
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
function M.parse_blame_output(blame_output)
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
function M.get_blame_lines_async(file, callback)
  safe_system({ "svn", "blame", "-v", file }, { text = true }, function(res)
    local parsed = (res.code == 0 and res.stdout ~= "") and M.parse_blame_output(res.stdout) or nil
    vim.schedule(function() callback(parsed) end)
  end)
end

-- Get SVN log for a specific revision
function M.get_revision_log(file, revision)
  local cmd = string.format("svn log -r %s %s 2>/dev/null", revision, vim.fn.shellescape(file))
  local handle = io.popen(cmd)
  if not handle then return nil end
  local result = handle:read("*a")
  handle:close()
  return result
end

-- Get SVN blame revision for a specific line
function M.get_line_blame(file, lnum)
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

return M

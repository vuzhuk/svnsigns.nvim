-- Unified-diff parsing shared by sign classification (parse_diff), hunk
-- preview (split_into_hunks/find_hunk_at_line), and hunk reset (used
-- directly by svnsigns.actions for its own base/buffer line mapping).
--
-- Centralized here because `diff -u`'s two quirks below were previously
-- reimplemented independently in three different functions, and each copy
-- got the same bug at least once:
--   1. The literal "--- a/file"/"+++ b/file" file-header lines are only
--      emitted once, before the first "@@" hunk marker. A real
--      deleted/added line whose content happens to start with "--"/"++"
--      (e.g. a Lua/SQL comment) looks identical to a header line once
--      prefixed with its diff marker, so the header exclusion must stop
--      applying as soon as a hunk marker has been seen.
--   2. A hunk header's ",count" suffix is optional and omitted whenever
--      that side's range is exactly one line (e.g. "@@ -1 +1 @@" or
--      "@@ -1 +0,0 @@").
local M = {}

-- Matches a unified-diff hunk header line ("@@ -A[,B] +C[,D] @@"),
-- returning a table with the (numeric) base/new start lines and counts, or
-- nil if `line` isn't a hunk header. Missing counts default to 1, matching
-- diff -u's own convention for a single-line range.
function M.match_hunk_header(line)
  local base_range, new_range = line:match("^@@ %-(%d+,?%d*) %+(%d+,?%d*) @@")
  if not base_range then
    return nil
  end

  local function parse_range(range)
    local start, count = range:match("^(%d+),(%d+)$")
    if start then
      return tonumber(start), tonumber(count)
    end
    return tonumber(range), 1
  end

  local base_start, base_count = parse_range(base_range)
  local new_start, new_count = parse_range(new_range)
  return {
    base_start = base_start,
    base_count = base_count,
    new_start = new_start,
    new_count = new_count,
  }
end

-- Returns a fresh, stateful { is_del, is_add, mark_hunk } set of closures
-- implementing quirk #1 above. Call mark_hunk() once a hunk header has been
-- seen; is_del/is_add stop excluding "---"/"+++"-looking lines from that
-- point on.
function M.new_line_matchers()
  local seen_hunk = false
  return {
    mark_hunk = function()
      seen_hunk = true
    end,
    is_del = function(l)
      if seen_hunk then
        return l:sub(1, 1) == "-"
      end
      return l:match("^%-") and not l:match("^%-%-%-")
    end,
    is_add = function(l)
      if seen_hunk then
        return l:sub(1, 1) == "+"
      end
      return l:match("^%+") and not l:match("^%+%+%+")
    end,
  }
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
function M.parse_diff(diff_output)
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

  local matchers = M.new_line_matchers()
  local is_del, is_add = matchers.is_del, matchers.is_add

  while i <= #lines do
    local line = lines[i]
    local hunk = line:match("^@@ %-") and M.match_hunk_header(line)

    if hunk then
      current_line = hunk.new_start
      matchers.mark_hunk()
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
function M.split_into_hunks(diff_output)
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
    local hunk = line:match("^@@ %-") and M.match_hunk_header(line)
    if hunk then
      if current then table.insert(hunks, current) end
      current = {
        base_start = hunk.base_start,
        base_count = hunk.base_count,
        new_start = hunk.new_start,
        new_count = hunk.new_count,
        lines = { line },
      }
    elseif current then
      -- The literal "--- a/file"/"+++ b/file" file-header lines only ever
      -- appear before the first "@@" marker, i.e. while current is still
      -- nil, so there's no need (and it's actively wrong) to filter lines
      -- matching that pattern here: a real deleted/added comment line
      -- (e.g. "--- some comment") inside a hunk would otherwise be dropped
      -- from the preview.
      table.insert(current.lines, line)
    end
  end
  if current then table.insert(hunks, current) end

  return hunks
end

-- Find the hunk (if any) whose new-file line range contains `cursor_line`
-- (1-indexed). A hunk's range includes its surrounding unified-diff context
-- lines, matching how gitsigns scopes preview_hunk to "the hunk near you".
function M.find_hunk_at_line(hunks, cursor_line)
  for _, hunk in ipairs(hunks) do
    local first = math.max(hunk.new_start, 1)
    local last = first + math.max(hunk.new_count, 1) - 1
    if cursor_line >= first and cursor_line <= last then
      return hunk
    end
  end
  return nil
end

return M

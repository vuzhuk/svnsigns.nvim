-- Blame features: current-line virtual-text blame, the full-buffer
-- :SvnBlame split, and :SvnLog (revision log for the line under the
-- cursor).
local config = require("svnsigns.config")
local svn = require("svnsigns.svn")

local M = {}

local blame_ns_id = vim.api.nvim_create_namespace("svnsigns_current_line_blame")
local blame_bufnr = nil
local blame_winnr = nil

-- Per-buffer cache of per-line blame metadata (see svn.parse_blame_output),
-- used to render the current-line blame virtual text without re-shelling
-- out to `svn blame` on every cursor move. Keyed by bufnr.
local blame_line_cache = {}

-- Refresh blame_line_cache[bufnr] from disk (async). Used to back the
-- current-line blame virtual text; a no-op if the feature is disabled.
function M.refresh_blame_cache(bufnr, file)
  if not config.options.current_line_blame then return end

  svn.get_blame_lines_async(file, function(by_line)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    blame_line_cache[bufnr] = by_line
    local winnr = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(winnr) and vim.api.nvim_win_get_buf(winnr) == bufnr then
      M.render_current_line_blame(winnr, bufnr)
    end
  end)
end

-- Render (or clear) the current-line blame virtual text for bufnr, based
-- on whatever is currently in blame_line_cache[bufnr] and the cursor's
-- line in its window.
function M.render_current_line_blame(winnr, bufnr)
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

-- Toggle the current-line blame virtual text on/off. When turning it on,
-- immediately (re)populate the cache for the current buffer so the
-- annotation appears without waiting for the next BufReadPost/Write.
function M.toggle_current_line_blame()
  config.options.current_line_blame = not config.options.current_line_blame

  local bufnr = vim.api.nvim_get_current_buf()
  if config.options.current_line_blame then
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file ~= "" then
      M.refresh_blame_cache(bufnr, file)
    end
  end
  M.render_current_line_blame(vim.api.nvim_get_current_win(), bufnr)

  vim.notify(
    "svnsigns: current-line blame " .. (config.options.current_line_blame and "enabled" or "disabled"),
    vim.log.levels.INFO
  )
end

-- Drop all per-buffer state for bufnr (called on BufDelete).
function M.cleanup_buffer(bufnr)
  blame_line_cache[bufnr] = nil
end

function M.blame_split()
  local source_bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(source_bufnr)
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
  for i, line in ipairs(lines) do
    local rev_start, rev_end = line:find("%d+")
    if rev_start and rev_end then
      vim.api.nvim_buf_add_highlight(buf, -1, "SvnSignsBlameRevision", i - 1, rev_start - 1, rev_end)
      local author_start = line:find("%S", rev_end + 1)
      if author_start then
        local author_end = line:find("%s", author_start)
        vim.api.nvim_buf_add_highlight(
          buf,
          -1,
          "SvnSignsBlameAuthor",
          i - 1,
          author_start - 1,
          (author_end and author_end - 1) or #line
        )
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

return M

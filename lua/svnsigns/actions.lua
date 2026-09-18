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

  -- Get the base version
  local base = svn.get_svn_base(file)
  if not base then
    vim.notify("Failed to get SVN base version", vim.log.levels.ERROR)
    return
  end
  local base_lines = vim.split(base, "\n", { plain = true })
  if base:sub(-1) == "\n" then
    table.remove(base_lines)
  end

  local diff_text = svn.get_buffer_diff(bufnr, file)
  if not diff_text or diff_text == "" then
    vim.notify("No changes detected", vim.log.levels.INFO)
    return
  end

  local hunks = diff.split_into_hunks(diff_text)
  local hunk = diff.find_hunk_at_line(hunks, current_line)
  if not hunk then
    vim.notify("No changes at current line", vim.log.levels.INFO)
    return
  end

  local replacement = {}
  for i = hunk.base_start, hunk.base_start + hunk.base_count - 1 do
    replacement[#replacement + 1] = base_lines[i]
  end

  local start_idx = math.max(hunk.new_start, 1) - 1
  local end_idx = start_idx + hunk.new_count
  vim.api.nvim_buf_set_lines(bufnr, start_idx, end_idx, false, replacement)
  vim.notify("Reverted hunk", vim.log.levels.INFO)

  -- Update signs
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      signs.update_signs(bufnr)
    end
  end, 50)
end

-- Reset hunks (revert changes)
function M.reset_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then return end

  vim.ui.input({ prompt = "Revert all changes? (y/N): " }, function(input)
    if input == "y" or input == "Y" then
      local output = vim.fn.system("svn revert " .. vim.fn.shellescape(file))
      if vim.v.shell_error ~= 0 then
        vim.notify("Failed to revert: " .. output, vim.log.levels.ERROR)
        return
      end
      vim.api.nvim_buf_call(bufnr, function()
        local view = vim.fn.winsaveview()
        vim.cmd("silent! edit!")
        vim.fn.winrestview(view)
      end)
      signs.update_signs(bufnr)
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

-- FzfLua picker for SVN branches/tags (trunk + branches/* + tags/*),
-- mirroring fzf-lua's own `git_branches`: preview shows recent log for the
-- hovered branch, <CR> switches the working copy to the selected one.
function M.fzf_branches()
  local has_fzf, fzf = pcall(require, "fzf-lua")
  if not has_fzf then
    vim.notify("fzf-lua is not installed", vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  local branches = svn.list_branches(file)

  if #branches == 0 then
    vim.notify("No SVN branches found (expects a trunk/branches/tags layout)", vim.log.levels.INFO)
    return
  end

  -- Map each displayed entry back to its branch record (name is unique per
  -- list_branches's construction, so it's a safe lookup key).
  local by_name = {}
  local entries = {}
  for _, b in ipairs(branches) do
    by_name[b.name] = b
    table.insert(entries, (b.current and "* " or "  ") .. b.name)
  end

  local function name_from_entry(entry)
    return (entry:gsub("^[%*%s]+", ""))
  end

  fzf.fzf_exec(entries, {
    prompt = "SVN Branches> ",
    preview = function(args)
      local branch = by_name[name_from_entry(args[1])]
      if not branch then return "" end
      return svn.get_branch_log(branch.url, 20) or ("No log available for " .. branch.name)
    end,
    actions = {
      ["default"] = function(selected)
        local branch = by_name[name_from_entry(selected[1])]
        if not branch then return end
        if branch.current then
          vim.notify("Already on " .. branch.name, vim.log.levels.INFO)
          return
        end
        vim.ui.input(
          { prompt = "Switch working copy to " .. branch.name .. "? (y/N): " },
          function(input)
            if input ~= "y" and input ~= "Y" then return end
            local dir = svn.get_wc_root(file) or vim.fn.fnamemodify(file, ":h")
            local ok, output = svn.switch_to_branch(dir, branch.url)
            if not ok then
              vim.notify("Failed to switch: " .. output, vim.log.levels.ERROR)
              return
            end
            vim.cmd("checktime")
            svn.invalidate_repo_cache()
            svn.invalidate_base_cache()
            signs.update_signs(bufnr)
            vim.notify("Switched to " .. branch.name, vim.log.levels.INFO)
          end
        )
      end,
    },
  })
end

return M

-- minidiff-jj.nvim: a mini.diff source that diffs buffers against the parent of jj's working-copy
-- commit (`@-`)
local M = {}

--- Resolves symlinks, to diff against the repo of the original file. A file not written yet has its
--- directory resolved.
---@param buf integer
---@return string?
local function real_path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local dir = vim.fs.dirname(name)
  return vim.uv.fs_realpath(name) or vim.fs.joinpath(vim.uv.fs_realpath(dir) or dir, vim.fs.basename(name))
end

---@param buf integer
---@return false?
local function attach(buf)
  local path = real_path(buf)
  if not path or vim.fn.executable("jj") == 0 then
    return false
  end
  local root = vim.fs.root(path, ".jj")
  if not root then
    return false
  end
  local rel_path = assert(vim.fs.relpath(root, path))

  ---@param args           string[]
  ---@param on_exit        fun(result: vim.SystemCompleted)
  ---@param expected_error string?                          Part of an error message that doesn't fail the refresh
  local function jj(args, on_exit, expected_error)
    -- `--ignore-working-copy`: reading the repo shouldn't record an operation
    local cmd = { "jj", "--ignore-working-copy", "--no-pager", "--color=never" }
    vim.list_extend(cmd, args)
    -- jj reads paths as filesets: quote them, relative to the workspace root
    vim.list_extend(cmd, { "--", ('root-file:"%s"'):format((rel_path:gsub('[\\"]', "\\%0"))) })
    vim.system(
      cmd, { cwd = root, text = true },
      vim.schedule_wrap(function(result)
        assert(
          result.code == 0 or (expected_error and result.stderr:find(expected_error, 1, true)),
          ("minidiff-jj: %s failed: %s"):format(table.concat(cmd, " "), result.stderr)
        )
        on_exit(result)
      end)
    )
  end

  jj({ "diff", "-r", "@", "-T", 'self.status() ++ "\\n"' }, function(diff)
    local status = vim.trim(diff.stdout)
    if status == "" then
      -- Unchanged in `@`, or not tracked (ignored, or new and not snapshotted yet)
      jj({ "file", "show", "-r", "@" }, function(show)
        require("mini.diff").set_ref_text(buf, show.code == 0 and show.stdout or nil)
      end, "No such path"
      )
    elseif status == "added" then
      require("mini.diff").set_ref_text(buf, "")
    elseif status == "modified" or status == "removed" then
      jj({ "file", "show", "-r", "@-" }, function(show)
        require("mini.diff").set_ref_text(buf, show.stdout)
      end)
    else
      error(("minidiff-jj: unknown jj diff status %q"):format(status))
    end
  end)
end

--- Generates the source. See `:h MiniDiff-source-specification`.
---@return table
function M.gen_source()
  return { name = "jj", attach = attach }
end

return M

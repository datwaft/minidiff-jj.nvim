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

  -- `--ignore-working-copy`: reading the repo shouldn't record an operation
  local cmd = { "jj", "--ignore-working-copy", "--no-pager", "--color=never" }
  -- jj reads paths as filesets: quote them, relative to the workspace root
  local fileset = ('root-file:"%s"'):format((vim.fs.relpath(root, path):gsub('[\\"]', "\\%0")))
  vim.list_extend(cmd, { "file", "show", "-r", "@-", "--", fileset })
  vim.system(
    cmd, { cwd = root, text = true },
    vim.schedule_wrap(function(result)
      -- Not in `@-`: a new file, or one jj doesn't track
      if result.code ~= 0 and result.stderr:find("No such path", 1, true) then
        return require("mini.diff").set_ref_text(buf, nil)
      end
      assert(result.code == 0, ("minidiff-jj: %s failed: %s"):format(table.concat(cmd, " "), result.stderr))
      require("mini.diff").set_ref_text(buf, result.stdout)
    end)
  )
end

--- Generates the source. See `:h MiniDiff-source-specification`.
---@return table
function M.gen_source()
  return { name = "jj", attach = attach }
end

return M

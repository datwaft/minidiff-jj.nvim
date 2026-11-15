-- minidiff-jj.nvim: a mini.diff source that diffs buffers against the parents of jj's working-copy
-- commit, as `jj diff` does
local M = {}

---@class minidiff_jj.Workspace
---@field root    string
---@field buffers table<integer, true> Attached buffers in the workspace
---@field watcher uv.uv_fs_event_t     Watches the repo's operation heads
---@field timer   uv.uv_timer_t        Debounces refreshes

---@class minidiff_jj.Buffer
---@field workspace minidiff_jj.Workspace
---@field job       vim.SystemObj?        The running jj command of the latest refresh

---@type table<string, minidiff_jj.Workspace>
local workspaces = {}
---@type table<integer, minidiff_jj.Buffer>
local buffers = {}

-- A diff tool that prints the left side of a file's diff: the file in the parents of `@`, merged if
-- there are several, and before its rename if it was renamed
local print_left = {
  "--config",
  'merge-tools.minidiff-jj-left.program="cat"',
  "--config",
  'merge-tools.minidiff-jj-left.diff-args=["$left"]',
  "--config",
  'merge-tools.minidiff-jj-left.diff-invocation-mode="file-by-file"',
  "--tool",
  "minidiff-jj-left",
}

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

--- Finds the repo directory, which secondary workspaces store as a path relative to their `.jj` directory
---@param root string
---@return string
local function find_repo_dir(root)
  local jj_dir = vim.fs.joinpath(root, ".jj")
  local repo = vim.fs.joinpath(jj_dir, "repo")
  local stat = assert(vim.uv.fs_stat(repo), "minidiff-jj: missing jj repo: " .. repo)
  if stat.type == "directory" then
    return repo
  end
  local target = vim.trim(vim.fn.readfile(repo)[1])
  local path = vim.startswith(target, "/") and target or vim.fs.joinpath(jj_dir, target)
  return assert(vim.uv.fs_realpath(path), "minidiff-jj: missing jj repo: " .. path)
end

---@param buf integer
local function refresh(buf)
  local state = buffers[buf]
  if state.job then
    state.job:kill("sigterm")
    state.job = nil
  end
  local root = state.workspace.root
  local rel_path = vim.fs.relpath(root, assert(real_path(buf)))
  -- The buffer was renamed out of the workspace
  if not rel_path then
    return require("mini.diff").set_ref_text(buf, nil)
  end

  ---@param args           string[]
  ---@param on_exit        fun(result: vim.SystemCompleted)
  ---@param expected_error string?                          Part of an error message that doesn't fail the refresh
  local function jj(args, on_exit, expected_error)
    -- `--ignore-working-copy`: a snapshot would record an operation, which would refresh again
    local cmd = { "jj", "--ignore-working-copy", "--no-pager", "--color=never" }
    vim.list_extend(cmd, args)
    -- jj reads paths as filesets: quote them, relative to the workspace root
    vim.list_extend(cmd, { "--", ('root-file:"%s"'):format((rel_path:gsub('[\\"]', "\\%0"))) })
    local job
    job = vim.system(
      cmd, { cwd = root, text = true },
      vim.schedule_wrap(function(result)
        -- Detached, or a newer refresh started
        if buffers[buf] ~= state or state.job ~= job then
          return
        end
        state.job = nil
        assert(
          result.code == 0 or (expected_error and result.stderr:find(expected_error, 1, true)),
          ("minidiff-jj: %s failed: %s"):format(table.concat(cmd, " "), result.stderr)
        )
        on_exit(result)
      end)
    )
    state.job = job
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
    elseif status == "modified" or status == "renamed" or status == "copied" or status == "removed" then
      jj(vim.list_extend({ "diff", "-r", "@" }, print_left), function(left)
        require("mini.diff").set_ref_text(buf, left.stdout)
      end)
    else
      error(("minidiff-jj: unknown jj diff status %q"):format(status))
    end
  end)
end

---@param root string
---@return minidiff_jj.Workspace
local function open_workspace(root)
  local workspace = {
    root = root,
    buffers = {},
    watcher = assert(vim.uv.new_fs_event()),
    timer = assert(vim.uv.new_timer()),
  }
  -- Every jj operation (commit, rebase, snapshot, ...) replaces the operation heads, which can change `@`
  local heads = vim.fs.joinpath(find_repo_dir(root), "op_heads", "heads")
  assert(
    workspace.watcher:start(heads, {}, function(err)
      assert(not err, err)
      workspace.timer:stop()
      workspace.timer:start(
        50, 0,
        vim.schedule_wrap(function()
          for buf in pairs(workspace.buffers) do
            refresh(buf)
          end
        end)
      )
    end)
  )
  return workspace
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

  workspaces[root] = workspaces[root] or open_workspace(root)
  local workspace = workspaces[root]
  workspace.buffers[buf] = true
  buffers[buf] = { workspace = workspace }
  refresh(buf)
end

---@param buf integer
local function detach(buf)
  local state = buffers[buf]
  if not state then
    return
  end
  buffers[buf] = nil
  if state.job then
    state.job:kill("sigterm")
  end

  local workspace = state.workspace
  workspace.buffers[buf] = nil
  if next(workspace.buffers) then
    return
  end
  workspaces[workspace.root] = nil
  workspace.watcher:stop()
  workspace.watcher:close()
  workspace.timer:stop()
  workspace.timer:close()
end

--- Generates the source. See `:h MiniDiff-source-specification`.
---@return table
function M.gen_source()
  return { name = "jj", attach = attach, detach = detach }
end

return M

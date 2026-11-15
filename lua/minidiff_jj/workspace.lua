-- jj workspaces with attached buffers: one watcher each, which tells the buffers about jj operations
local M = {}

---@class minidiff_jj.Workspace
---@field buffers            table<integer, fun()> What to call for each attached buffer after a jj operation
---@field watcher            uv.uv_fs_event_t      Watches the repo's operation heads
---@field timer              uv.uv_timer_t         Debounces changes
---@field snapshot_scheduled boolean

---@type table<string, minidiff_jj.Workspace>
local workspaces = {}

--- Gets the repo directory of a workspace.
---
--- In the first workspace of a repo, `.jj/repo` is the repo directory. In a workspace that `jj workspace add` made,
--- `.jj/repo` is a file. This file contains the path of the repo directory, relative to the `.jj` directory.
---
--- Causes an error if the repo directory does not exist.
---@param root string Workspace root
---@return string
local function find_repo_dir(root)
  local jj_dir = vim.fs.joinpath(root, ".jj")
  local repo = vim.fs.joinpath(jj_dir, "repo")
  local stat = assert(vim.uv.fs_stat(repo), "minidiff-jj: missing jj repo: " .. repo)
  if stat.type == "directory" then
    return repo
  end
  local target = vim.trim(vim.fn.readfile(repo)[1])
  local path = vim.fs.abspath(target, { cwd = jj_dir, plain = true })
  return assert(vim.uv.fs_realpath(path), "minidiff-jj: missing jj repo: " .. path)
end

--- Makes the state of a workspace and starts its watcher.
---
--- The watcher watches the operation heads of the repo, which jj replaces after each operation. When the changes stop
--- for 50 ms, the watcher calls `on_change` of each buffer in the workspace.
---@param root string Workspace root
---@return minidiff_jj.Workspace
local function open(root)
  local workspace = {
    buffers = {},
    watcher = assert(vim.uv.new_fs_event()),
    timer = assert(vim.uv.new_timer()),
    snapshot_scheduled = false,
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
          for _, on_change in pairs(workspace.buffers) do
            on_change()
          end
        end)
      )
    end)
  )
  return workspace
end

--- Adds a buffer to its workspace. If the buffer is the first one, this function opens the workspace.
---
--- `on_change` runs after each jj operation in the repo, also operations from other workspaces of the repo.
---@param root      string  Workspace root
---@param buf       integer
---@param on_change fun()   Called after every jj operation in the repo
function M.add(root, buf, on_change)
  workspaces[root] = workspaces[root] or open(root)
  workspaces[root].buffers[buf] = on_change
end

--- Removes a buffer from its workspace. If the buffer was the last one, this function stops the watcher of the
--- workspace.
---
--- Causes an error if the workspace is not open.
---@param root string  Workspace root
---@param buf  integer
function M.remove(root, buf)
  local workspace = assert(workspaces[root], "minidiff-jj: unknown workspace: " .. root)
  workspace.buffers[buf] = nil
  if next(workspace.buffers) then
    return
  end
  workspaces[root] = nil
  workspace.watcher:stop()
  workspace.watcher:close()
  workspace.timer:stop()
  workspace.timer:close()
end

--- Records a snapshot of the working copy with `jj util snapshot`, so that jj sees new and renamed files. The snapshot
--- is a jj operation, so the watcher then updates the buffers.
---
--- The calls in one event loop iteration (for example, from `:wall`) share one snapshot. Causes an error if jj fails.
---@param root string Workspace root
function M.snapshot(root)
  local workspace = assert(workspaces[root], "minidiff-jj: unknown workspace: " .. root)
  if workspace.snapshot_scheduled then
    return
  end
  workspace.snapshot_scheduled = true
  vim.schedule(function()
    workspace.snapshot_scheduled = false
    vim.system(
      { "jj", "--quiet", "util", "snapshot" }, { cwd = root, text = true },
      vim.schedule_wrap(function(result)
        assert(result.code == 0, ("minidiff-jj: jj util snapshot failed: %s"):format(result.stderr))
      end)
    )
  end)
end

return M

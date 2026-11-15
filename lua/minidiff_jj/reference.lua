-- The reference text of a file: the file in the parents of jj's working-copy commit, as `jj diff`
-- compares it
local M = {}

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

---@async
---@param root           string   Workspace root
---@param rel_path       string   Path relative to the workspace root
---@param args           string[]
---@param expected_error string?  Part of an error message that doesn't fail the request
---@return vim.SystemCompleted
local function jj(root, rel_path, args, expected_error)
  -- `--ignore-working-copy`: a snapshot would record an operation, which the workspace watcher
  -- would take for a change
  local cmd = { "jj", "--ignore-working-copy", "--no-pager", "--color=never" }
  vim.list_extend(cmd, args)
  -- jj reads paths as filesets: quote them, relative to the workspace root
  vim.list_extend(cmd, { "--", ('root-file:"%s"'):format((rel_path:gsub('[\\"]', "\\%0"))) })
  local result = vim.async.await(3, vim.system, cmd, { cwd = root, text = true }) --[[@as vim.SystemCompleted]]
  assert(
    result.code == 0 or (expected_error and result.stderr:find(expected_error, 1, true)),
    ("minidiff-jj: %s failed: %s"):format(table.concat(cmd, " "), result.stderr)
  )
  return result
end

--- Gets the reference text of a file, or `nil` if jj doesn't track it. Closing the task that runs
--- it kills the running jj command.
---@async
---@param root     string Workspace root
---@param rel_path string Path relative to the workspace root
---@return string?
function M.get(root, rel_path)
  local status = vim.trim(jj(root, rel_path, { "diff", "-r", "@", "-T", 'self.status() ++ "\\n"' }).stdout)
  if status == "" then
    -- Unchanged in `@`, or not tracked (ignored, or new and not snapshotted yet)
    local show = jj(root, rel_path, { "file", "show", "-r", "@" }, "No such path")
    return show.code == 0 and show.stdout or nil
  elseif status == "added" then
    return ""
  elseif status == "modified" or status == "renamed" or status == "copied" or status == "removed" then
    return jj(root, rel_path, vim.list_extend({ "diff", "-r", "@" }, print_left)).stdout
  end
  error(("minidiff-jj: unknown jj diff status %q"):format(status))
end

return M

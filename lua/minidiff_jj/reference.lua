local M = {}

-- Here we define a `diff` tool that prints the left side of a file diff: the file before the changes in `@`. If `@` is
-- a merge, the left side is the parents of `@` merged together. If `@` renamed or copied the file, the left side is the
-- file at its old path.
--
-- The tool is `cat $left`. jj runs it once for each file (`file-by-file`), and `$left` is the path of a copy of the
-- left side. The `--config` options define the tool for this command only, so the jj config of the user does not
-- change.
local print_left_tool = {
  "--config",
  'merge-tools.minidiff-jj-left.program="cat"',
  "--config",
  'merge-tools.minidiff-jj-left.diff-args=["$left"]',
  "--config",
  'merge-tools.minidiff-jj-left.diff-invocation-mode="file-by-file"',
  "--tool",
  "minidiff-jj-left",
}

--- Runs a jj command on one file, and waits for it. The command does not record a snapshot.
---
--- Causes an error if the command fails, except if its error message contains `expected_error`. Returns the result, so
--- that the caller can see if the command failed.
---@async
---@param root           string   Workspace root
---@param rel_path       string   Path relative to the workspace root
---@param args           string[]
---@param expected_error string?  Part of an error message that doesn't fail the request
---@return vim.SystemCompleted
local function run_jj_command(root, rel_path, args, expected_error)
  -- `--ignore-working-copy`: a snapshot would record an operation, which the workspace watcher would take for a change
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

--- Gets the reference text of a file: the file before the changes in `@`, as `jj diff` shows it.
---
--- Returns `""` if `@` adds the file, and `nil` if jj does not track the file.
---
--- Run this function in a task. If you close the task, the jj command that runs stops.
---@async
---@param root     string Workspace root
---@param rel_path string Path relative to the workspace root
---@return string?
function M.get(root, rel_path)
  local status = vim.trim(run_jj_command(root, rel_path, { "diff", "-r", "@", "-T", 'self.status() ++ "\\n"' }).stdout)
  if status == "" then
    -- Unchanged in `@`, or not tracked (ignored, or new and not snapshotted yet)
    local show = run_jj_command(root, rel_path, { "file", "show", "-r", "@" }, "No such path")
    return show.code == 0 and show.stdout or nil
  elseif status == "added" then
    return ""
  elseif status == "modified" or status == "renamed" or status == "copied" or status == "removed" then
    return run_jj_command(root, rel_path, vim.list_extend({ "diff", "-r", "@" }, print_left_tool)).stdout
  end
  error(("minidiff-jj: unknown jj diff status %q"):format(status))
end

return M

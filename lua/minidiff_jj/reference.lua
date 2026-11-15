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

--- Gets the reference text of a file, or `nil` if jj doesn't track it
---@param root      string             Workspace root
---@param rel_path  string             Path relative to the workspace root
---@param on_result fun(text: string?)
---@return fun() cancel Kills the running jj command. `on_result` isn't called after.
function M.get(root, rel_path, on_result)
  local cancelled = false
  local job ---@type vim.SystemObj

  ---@param args           string[]
  ---@param on_exit        fun(result: vim.SystemCompleted)
  ---@param expected_error string?                          Part of an error message that doesn't fail the request
  local function jj(args, on_exit, expected_error)
    -- `--ignore-working-copy`: a snapshot would record an operation, which the workspace watcher
    -- would take for a change
    local cmd = { "jj", "--ignore-working-copy", "--no-pager", "--color=never" }
    vim.list_extend(cmd, args)
    -- jj reads paths as filesets: quote them, relative to the workspace root
    vim.list_extend(cmd, { "--", ('root-file:"%s"'):format((rel_path:gsub('[\\"]', "\\%0"))) })
    job = vim.system(
      cmd, { cwd = root, text = true },
      vim.schedule_wrap(function(result)
        if cancelled then
          return
        end
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
        on_result(show.code == 0 and show.stdout or nil)
      end, "No such path"
      )
    elseif status == "added" then
      on_result("")
    elseif status == "modified" or status == "renamed" or status == "copied" or status == "removed" then
      jj(vim.list_extend({ "diff", "-r", "@" }, print_left), function(left)
        on_result(left.stdout)
      end)
    else
      error(("minidiff-jj: unknown jj diff status %q"):format(status))
    end
  end)

  return function()
    cancelled = true
    -- The command may have exited already, before its scheduled callback ran
    if not job:is_closing() then
      job:kill("sigterm")
    end
  end
end

return M

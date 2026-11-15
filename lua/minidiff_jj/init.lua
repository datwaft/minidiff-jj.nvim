local reference = require("minidiff_jj.reference")
local workspace = require("minidiff_jj.workspace")

local M = {}

---@class minidiff_jj.Buffer
---@field root string          Workspace root
---@field task vim.async.Task? The last `update_ref_text()` task

---@type table<integer, minidiff_jj.Buffer>
local buffers = {}

local augroup = vim.api.nvim_create_augroup("minidiff_jj", { clear = true })

--- Gets the path of the buffer's file, with its symlinks resolved. If the file is not on disk, only the symlinks of its
--- directory are resolved. Returns `nil` if the buffer has no name.
---@param buf integer
---@return string?
local function resolved_path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local file = vim.uv.fs_realpath(name)
  if file then
    return file
  end
  -- The file is not written yet, so only its directory can be resolved (if it exists)
  local dir = vim.fs.dirname(name)
  return vim.fs.joinpath(vim.uv.fs_realpath(dir) or dir, vim.fs.basename(name))
end

--- Updates the reference text of the buffer: the text that `mini.diff` compares the buffer with.
---
--- The reference text is the file before the changes in `@`, as `jj diff` shows it. If the buffer is not in the
--- workspace anymore (it was renamed), the buffer gets no reference text and shows no hunks.
---
--- jj gives the text in a task, so Neovim does not wait for jj. Each call cancels the task of the previous call, so an
--- old answer cannot replace a new one.
---
--- Called when the buffer attaches, and after each jj operation.
---@param buf integer
local function update_ref_text(buf)
  local state = buffers[buf]
  -- An older answer could replace this one
  if state.task then
    state.task:close()
  end
  local rel_path = vim.fs.relpath(state.root, assert(resolved_path(buf)))
  -- The buffer was renamed out of the workspace
  if not rel_path then
    state.task = nil
    return require("mini.diff").set_ref_text(buf, nil)
  end
  --- Gets the reference text from jj, then gives it to `mini.diff`.
  ---@async
  local function fetch_and_set()
    local text = reference.get(state.root, rel_path)
    -- Wait until we are outside a "fast" event, as `mini.diff` cannot run inside one
    vim.async.await(vim.schedule)
    require("mini.diff").set_ref_text(buf, text)
  end
  state.task = vim.async.run(fetch_and_set)
  state.task:on_complete(function(err)
    -- "closed": cancelled by a newer call or a detach
    assert(err == nil or err == "closed", err)
  end)
end

--- Starts to show the changes of the buffer. `mini.diff` calls this function when it enables the buffer.
---
--- Returns `false` if the buffer has no file, if jj is not installed, or if the file is not in a jj workspace. Then
--- `mini.diff` tries the next source.
---
--- After this function, the changes update after each jj operation. Each write of the buffer records a jj snapshot, so
--- that jj sees new and renamed files.
---@param buf integer
---@return false?
local function attach(buf)
  local path = resolved_path(buf)
  if not path or vim.fn.executable("jj") == 0 then
    return false
  end
  local root = vim.fs.root(path, ".jj")
  if not root then
    return false
  end

  buffers[buf] = { root = root }
  workspace.add(root, buf, function()
    update_ref_text(buf)
  end)
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    buffer = buf,
    callback = function()
      workspace.snapshot(root)
    end,
  })
  update_ref_text(buf)
end

--- Stops to show the changes of the buffer. `mini.diff` calls this function when it disables the buffer, or when the
--- buffer is unloaded.
---
--- Cancels the task that gets the reference text. Does nothing if the buffer is not attached.
---@param buf integer
local function detach(buf)
  local state = buffers[buf]
  if not state then
    return
  end
  buffers[buf] = nil
  -- `MiniDiff.set_ref_text()` would enable the buffer again
  if state.task then
    state.task:close()
  end
  vim.api.nvim_clear_autocmds({ group = augroup, buffer = buf })
  workspace.remove(state.root, buf)
end

--- Makes the jj source for the `source` option of `mini.diff`. Put it before the Git source, so that Git shows the
--- changes of files that are not in a jj workspace.
---
--- See `:h MiniDiff-source-specification`.
---@return table
function M.gen_source()
  return { name = "jj", attach = attach, detach = detach }
end

return M

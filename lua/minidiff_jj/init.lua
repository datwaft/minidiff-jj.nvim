-- minidiff-jj.nvim: a mini.diff source that diffs buffers against the parents of jj's working-copy
-- commit, as `jj diff` does
local reference = require("minidiff_jj.reference")
local workspace = require("minidiff_jj.workspace")

local M = {}

---@class minidiff_jj.Buffer
---@field root string          Workspace root
---@field task vim.async.Task? The last `refresh()`, which the next one or a detach closes

---@type table<integer, minidiff_jj.Buffer>
local buffers = {}

local augroup = vim.api.nvim_create_augroup("minidiff_jj", { clear = true })

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

--- Updates the buffer's reference text, the text mini.diff diffs it against: asks jj for the file
--- in the parents of `@`, then gives the answer to mini.diff. Runs on attach and after every jj
--- operation.
---@param buf integer
local function refresh(buf)
  local state = buffers[buf]
  -- An older answer could replace this one
  if state.task then
    state.task:close()
  end
  local rel_path = vim.fs.relpath(state.root, assert(real_path(buf)))
  -- The buffer was renamed out of the workspace
  if not rel_path then
    state.task = nil
    return require("mini.diff").set_ref_text(buf, nil)
  end
  ---@async
  local function update()
    local text = reference.get(state.root, rel_path)
    -- Awaiting jj resumes in a fast event, where mini.diff can't run
    vim.async.await(vim.schedule)
    require("mini.diff").set_ref_text(buf, text)
  end
  state.task = vim.async.run(update)
  state.task:on_complete(function(err)
    -- "closed": cancelled by a newer refresh or a detach
    assert(err == nil or err == "closed", err)
  end)
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

  buffers[buf] = { root = root }
  workspace.add(root, buf, function()
    refresh(buf)
  end)
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    buffer = buf,
    callback = function()
      workspace.snapshot(root)
    end,
  })
  refresh(buf)
end

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

--- Generates the source. See `:h MiniDiff-source-specification`.
---@return table
function M.gen_source()
  return { name = "jj", attach = attach, detach = detach }
end

return M

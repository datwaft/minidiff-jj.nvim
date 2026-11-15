-- Tests against real jj repos. Run from the repo root: nvim --clean -l tests/run.lua
-- Needs jj and git. Clones mini.diff into .tests/ on the first run.

local mini_diff_dir = ".tests/mini.diff"
if not vim.uv.fs_stat(mini_diff_dir) then
  local url = "https://github.com/nvim-mini/mini.diff"
  local clone = vim.system({ "git", "clone", "--depth=1", url, mini_diff_dir }):wait()
  assert(clone.code == 0, clone.stderr)
end
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(mini_diff_dir, ":p"))
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox, "p")
-- Resolved, as macOS' temporary directory is a symlink
sandbox = assert(vim.uv.fs_realpath(sandbox))
-- Keep the user's jj config (signing, hooks, ...) out of the tests
vim.env.JJ_CONFIG = sandbox .. "/jj-config.toml"
vim.fn.writefile({ "[user]", 'name = "Test"', 'email = "test@example.com"' }, vim.env.JJ_CONFIG)

-- Buffers outside jj workspaces fall back to this source
local fallback_attached = {} ---@type table<integer, true>
require("mini.diff").setup({
  source = {
    require("minidiff_jj").gen_source(),
    {
      name = "fallback",
      attach = function(buf)
        fallback_attached[buf] = true
      end,
    },
  },
})

---@param cwd string
---@param ... string
local function sh(cwd, ...)
  local result = vim.system({ ... }, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, ("%s failed: %s"):format(table.concat({ ... }, " "), result.stderr))
  return result.stdout
end

---@param path  string
---@param lines string[]
local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

--- Creates a jj repo whose `@` has the given file in its parent
---@param files table<string, string[]>
---@return string root
local function repo(files)
  local root = assert(vim.uv.fs_mkdtemp(sandbox .. "/repo-XXXXXX"))
  sh(root, "jj", "git", "init")
  for path, lines in pairs(files) do
    write(vim.fs.joinpath(root, path), lines)
  end
  sh(root, "jj", "commit", "-m", "base")
  return root
end

---@param path string
---@return integer
local function edit(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

--- Waits for the reference text of the buffer
---@param buf      integer
---@param expected string[] | false Its lines, or `false` for no reference
local function expect_ref(buf, expected)
  local text = expected and (#expected > 0 and table.concat(expected, "\n") .. "\n" or "") or nil
  local actual
  local ok = vim.wait(5000, function()
    local data = require("mini.diff").get_buf_data(buf)
    actual = data and data.ref_text
    return data ~= nil and actual == text
  end, 10
  )
  assert(ok, ("expected reference %s, got %s"):format(vim.inspect(text), vim.inspect(actual)))
end

local tests = {} ---@type { [1]: string, [2]: fun() } []
local function test(name, fn)
  tests[#tests + 1] = { name, fn }
end

test("modified file: the parent's version", function()
  local root = repo({ ["f.txt"] = { "a", "b" } })
  write(root .. "/f.txt", { "a", "B" })
  sh(root, "jj", "status")
  expect_ref(edit(root .. "/f.txt"), { "a", "b" })
end)

test("unchanged file: its own version", function()
  local root = repo({ ["f.txt"] = { "a", "b" } })
  expect_ref(edit(root .. "/f.txt"), { "a", "b" })
end)

test("new file: all lines added", function()
  local root = repo({ ["f.txt"] = { "a" } })
  write(root .. "/new.txt", { "n" })
  sh(root, "jj", "status")
  expect_ref(edit(root .. "/new.txt"), {})
end)

test("ignored file: no reference", function()
  local root = repo({ [".gitignore"] = { "*.env" } })
  write(root .. "/secret.env", { "s" })
  sh(root, "jj", "status")
  expect_ref(edit(root .. "/secret.env"), false)
end)

test("renamed file: the version before the rename", function()
  local root = repo({ ["old.txt"] = { "a", "b" } })
  assert(vim.uv.fs_rename(root .. "/old.txt", root .. "/new.txt"))
  write(root .. "/new.txt", { "a", "B" })
  sh(root, "jj", "status")
  expect_ref(edit(root .. "/new.txt"), { "a", "b" })
end)

test("merge: the parents merged", function()
  local root = repo({ ["f.txt"] = { "a", "b", "c" } })
  sh(root, "jj", "bookmark", "create", "base", "-r", "@-")
  sh(root, "jj", "new", "base")
  write(root .. "/f.txt", { "A", "b", "c" })
  sh(root, "jj", "bookmark", "create", "left", "-r", "@")
  sh(root, "jj", "new", "base")
  write(root .. "/f.txt", { "a", "b", "C" })
  sh(root, "jj", "new", "left", "@")
  write(root .. "/f.txt", { "A", "b", "C", "d" })
  sh(root, "jj", "status")
  expect_ref(edit(root .. "/f.txt"), { "A", "b", "C" })
end)

test("path with a space and quotes", function()
  local name = 'a "b" \\c.txt'
  local root = repo({ [name] = { "a" } })
  write(vim.fs.joinpath(root, name), { "A" })
  sh(root, "jj", "status")
  expect_ref(edit(vim.fs.joinpath(root, name)), { "a" })
end)

test("refreshes after a jj operation", function()
  local root = repo({ ["f.txt"] = { "a" } })
  write(root .. "/f.txt", { "b" })
  sh(root, "jj", "status")
  local buf = edit(root .. "/f.txt")
  expect_ref(buf, { "a" })
  sh(root, "jj", "commit", "-m", "b")
  expect_ref(buf, { "b" })
end)

test("outside jj: the next source", function()
  local dir = assert(vim.uv.fs_mkdtemp(sandbox .. "/plain-XXXXXX"))
  write(dir .. "/f.txt", { "a" })
  local buf = edit(dir .. "/f.txt")
  assert(
    vim.wait(5000, function()
      return fallback_attached[buf]
    end, 10
    ),
    "the fallback source didn't attach"
  )
end)

test("disabled buffers stay disabled after a jj operation", function()
  local root = repo({ ["f.txt"] = { "a" } })
  local buf = edit(root .. "/f.txt")
  expect_ref(buf, { "a" })
  require("mini.diff").disable(buf)
  sh(root, "jj", "new")
  vim.wait(500)
  assert(require("mini.diff").get_buf_data(buf) == nil, "the buffer was enabled again")
end)

local failures = 0
for _, case in ipairs(tests) do
  local ok, err = pcall(case[2])
  vim.cmd("silent! %bwipeout!")
  print(("%s %s%s"):format(ok and "ok  " or "FAIL", case[1], ok and "" or "\n     " .. tostring(err)))
  failures = failures + (ok and 0 or 1)
end
vim.fn.delete(sandbox, "rf")
print(("%d/%d passed"):format(#tests - failures, #tests))
os.exit(failures == 0 and 0 or 1)

# minidiff-jj.nvim

A [mini.diff](https://github.com/nvim-mini/mini.diff) source for
[jj](https://github.com/jj-vcs/jj) workspaces. Buffers show the changes of the
working-copy commit (`@`), the same changes `jj diff` shows:

- If `@` is a merge, the reference is its parents merged together.
- If the file was renamed or copied, the reference is the file it came from.
- If the file is new, every line is added.
- If jj doesn't track the file (it's ignored, for example), the buffer has no
  hunks.

It works in every jj workspace, colocated with Git or not, including secondary
workspaces made with `jj workspace add`. Hunks update after every jj
operation, from any workspace of the repo.

> [!NOTE]
> Early, and used by its author for now. mini.diff plans a built-in jj source;
> when it has one, use that instead.

## Requirements

- Neovim nightly
- jj (tested with 0.47) and `cat` in your `PATH`

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim), Git as a fallback for
files outside jj workspaces:

```lua
{
  "nvim-mini/mini.diff",
  dependencies = { "datwaft/minidiff-jj.nvim" },
  config = function()
    local diff = require("mini.diff")
    diff.setup({ source = { require("minidiff_jj").gen_source(), diff.gen_source.git() } })
  end,
}
```

## How it works

- Reading never snapshots the working copy (`--ignore-working-copy`), so it
  doesn't record jj operations.
- Writing a buffer runs `jj util snapshot`, so new and renamed files show their
  hunks. This records an operation, as any jj command does when the working
  copy changed.
- Each workspace has one file watcher on the repo's operation heads, which
  change after every jj operation.
- Applying hunks isn't supported: mini.diff's `apply` gives an error.

## Development

Run the tests from the repo root (they clone mini.diff into `.tests/` the
first time):

```sh
nvim --clean -l tests/run.lua
```

Format with
[luafmt](https://github.com/EmmyLuaLs/emmylua-analyzer-rust/tree/main/crates/emmylua_formatter):
`luafmt --recursive --write .`

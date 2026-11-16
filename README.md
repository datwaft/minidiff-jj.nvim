# `minidiff-jj.nvim`

> [!WARNING]
> I vibe-coded the shit out of this plugin, as it should be deprecated as soon as [`mini.diff`](https://github.com/nvim-mini/mini.diff) adds [`jj`](https://github.com/jj-vcs/jj) support.

This plugin adds support for [`jj`](https://github.com/jj-vcs/jj) in [`mini.diff`](https://github.com/nvim-mini/mini.diff).

## Installation

```lua
{
  "nvim-mini/mini.diff",
  dependencies = { "datwaft/minidiff-jj.nvim" },
  config = function()
    local diff = require("mini.diff")
    -- Here `git` is the fallback if the repo is not a jj repo.
    diff.setup({ source = { require("minidiff_jj").gen_source(), diff.gen_source.git() } })
  end,
}
```

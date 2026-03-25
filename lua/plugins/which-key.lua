-- which-key shows a popup of available keybindings when you pause mid-chord,
-- making the config self-documenting for new users and for yourself after
-- a long break. logseq.nvim registers its buffer-local bindings automatically
-- when which-key is present (see lua/logseq/init.lua activate()).
return {
  "folke/which-key.nvim",
  event = "VeryLazy",   -- loads after UI is ready, before any keypress
  opts = {},
}

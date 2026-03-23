-- =============================================================================
-- Cross-platform system clipboard for Neovim
-- =============================================================================
--
-- TESTING:
--   :checkhealth clipboard          → shows active provider and any errors
--   :echo has('win32')              → 1 on Windows native
--   :echo has('wsl')                → 1 inside WSL
--   :echo $WAYLAND_DISPLAY          → non-empty on Wayland
--   :echo $TERM_PROGRAM             → "tmux" etc.; check $TERMUX_VERSION too
--
-- Practical test:
--   1. Yank a line with  yy  in Neovim.
--   2. Switch to Notepad / another terminal and paste with Ctrl+V (or middle-click).
--   3. Confirm same text appears.
--
-- Required packages (install only what your environment needs):
--   Wayland  : sudo apt install wl-clipboard   (provides wl-copy / wl-paste)
--   X11      : sudo apt install xclip          (fallback: sudo apt install xsel)
--   Termux   : pkg install termux-api          + install "Termux:API" from F-Droid/Play
-- =============================================================================

local M = {}

-- Helper: check if an executable is on PATH
local function has_exe(name)
  return vim.fn.executable(name) == 1
end

function M.setup()
  -- ── 1. Windows native (not WSL) ──────────────────────────────────────────
  -- win32yank.exe ships with the official Windows Neovim build.
  -- `unnamedplus` is enough; Neovim's built-in win32 provider handles the rest.
  if vim.fn.has("win32") == 1 then
    vim.opt.clipboard = "unnamedplus"
    return
  end

  -- ── 2. WSL (Windows Subsystem for Linux) ─────────────────────────────────
  -- clip.exe and PowerShell are always available in WSL.
  -- We need an explicit provider because the Linux binaries are not in WSL by default.
  if vim.fn.has("wsl") == 1 then
    vim.g.clipboard = {
      name = "WSL (clip.exe / PowerShell)",
      copy = {
        ["+"] = "clip.exe",
        ["*"] = "clip.exe",
      },
      paste = {
        -- powershell trims trailing newline; `tr -d '\r'` strips Windows CR
        ["+"] = { "powershell.exe", "-NoProfile", "-c",
                  "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;" ..
                  "(Get-Clipboard) -join \"`n\"" },
        ["*"] = { "powershell.exe", "-NoProfile", "-c",
                  "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;" ..
                  "(Get-Clipboard) -join \"`n\"" },
      },
      cache_enabled = false,
    }
    vim.opt.clipboard = "unnamedplus"
    return
  end

  -- ── 3. Termux / Android ──────────────────────────────────────────────────
  -- Detected by the TERMUX_VERSION env-var (set by Termux automatically).
  -- Requires: pkg install termux-api  +  Termux:API app installed.
  if vim.env.TERMUX_VERSION ~= nil then
    if has_exe("termux-clipboard-set") and has_exe("termux-clipboard-get") then
      vim.g.clipboard = {
        name = "Termux API",
        copy = {
          ["+"] = "termux-clipboard-set",
          ["*"] = "termux-clipboard-set",
        },
        paste = {
          ["+"] = "termux-clipboard-get",
          ["*"] = "termux-clipboard-get",
        },
        cache_enabled = false,
      }
      vim.opt.clipboard = "unnamedplus"
    else
      -- termux-api not installed yet; warn without crashing
      vim.notify(
        "[clipboard] termux-clipboard-set/get not found.\n" ..
        "Run: pkg install termux-api  (and install the Termux:API app)",
        vim.log.levels.WARN
      )
    end
    return
  end

  -- ── 4. Linux – Wayland ───────────────────────────────────────────────────
  -- Prefer wl-clipboard when a Wayland display is active.
  if vim.env.WAYLAND_DISPLAY ~= nil and vim.env.WAYLAND_DISPLAY ~= "" then
    if has_exe("wl-copy") and has_exe("wl-paste") then
      vim.g.clipboard = {
        name = "Wayland (wl-clipboard)",
        copy = {
          ["+"] = { "wl-copy", "--foreground", "--type", "text/plain" },
          ["*"] = { "wl-copy", "--foreground", "--primary", "--type", "text/plain" },
        },
        paste = {
          ["+"] = { "wl-paste", "--no-newline" },
          ["*"] = { "wl-paste", "--no-newline", "--primary" },
        },
        cache_enabled = false,
      }
      vim.opt.clipboard = "unnamedplus"
      return
    else
      vim.notify(
        "[clipboard] Wayland detected but wl-copy/wl-paste missing.\n" ..
        "Install: sudo apt install wl-clipboard  (falling back to X11)",
        vim.log.levels.WARN
      )
      -- fall through to X11 fallback below
    end
  end

  -- ── 5. Linux – X11 (xclip preferred, xsel as fallback) ──────────────────
  if vim.env.DISPLAY ~= nil and vim.env.DISPLAY ~= "" then
    if has_exe("xclip") then
      -- xclip is the most common choice on X11
      vim.g.clipboard = {
        name = "X11 (xclip)",
        copy = {
          ["+"] = { "xclip", "-quiet", "-i", "-selection", "clipboard" },
          ["*"] = { "xclip", "-quiet", "-i", "-selection", "primary" },
        },
        paste = {
          ["+"] = { "xclip", "-o", "-selection", "clipboard" },
          ["*"] = { "xclip", "-o", "-selection", "primary" },
        },
        cache_enabled = false,
      }
      vim.opt.clipboard = "unnamedplus"
      return
    elseif has_exe("xsel") then
      -- xsel as fallback when xclip is absent
      vim.g.clipboard = {
        name = "X11 (xsel)",
        copy = {
          ["+"] = { "xsel", "--nodetach", "-i", "--clipboard" },
          ["*"] = { "xsel", "--nodetach", "-i", "--primary" },
        },
        paste = {
          ["+"] = { "xsel", "-o", "--clipboard" },
          ["*"] = { "xsel", "-o", "--primary" },
        },
        cache_enabled = false,
      }
      vim.opt.clipboard = "unnamedplus"
      return
    else
      vim.notify(
        "[clipboard] X11 detected but neither xclip nor xsel found.\n" ..
        "Install: sudo apt install xclip",
        vim.log.levels.WARN
      )
    end
  end

  -- ── 6. Last resort: let Neovim's autodetect handle it ───────────────────
  -- unnamedplus still set so y/p work if Neovim finds a provider itself.
  vim.opt.clipboard = "unnamedplus"
end

return M

" =============================================================================
" Cross-platform system clipboard – init.vim / vimscript variant
" =============================================================================
"
" TESTING:
"   :checkhealth clipboard        → shows active provider
"   :echo has('win32')            → 1 on Windows native
"   :echo has('wsl')              → 1 inside WSL
"   :echo $WAYLAND_DISPLAY        → non-empty on Wayland
"   :echo $TERMUX_VERSION         → non-empty in Termux
"
" Practical test: yank a line (yy), switch to another app, paste with Ctrl+V.
"
" Required packages:
"   Wayland : sudo apt install wl-clipboard
"   X11     : sudo apt install xclip   (fallback: xsel)
"   Termux  : pkg install termux-api   + Termux:API app
" =============================================================================

" ── 1. Windows native ────────────────────────────────────────────────────────
" win32yank.exe bundled with Neovim for Windows; unnamedplus is enough.
if has('win32')
  set clipboard=unnamedplus

" ── 2. WSL ───────────────────────────────────────────────────────────────────
elseif has('wsl')
  let g:clipboard = {
    \   'name': 'WSL (clip.exe / PowerShell)',
    \   'copy':  { '+': 'clip.exe', '*': 'clip.exe' },
    \   'paste': {
    \     '+': ['powershell.exe', '-NoProfile', '-c',
    \           '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;(Get-Clipboard) -join "`n"'],
    \     '*': ['powershell.exe', '-NoProfile', '-c',
    \           '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;(Get-Clipboard) -join "`n"'],
    \   },
    \   'cache_enabled': 0,
    \ }
  set clipboard=unnamedplus

" ── 3. Termux / Android ──────────────────────────────────────────────────────
elseif $TERMUX_VERSION != ''
  if executable('termux-clipboard-set') && executable('termux-clipboard-get')
    let g:clipboard = {
      \   'name': 'Termux API',
      \   'copy':  { '+': 'termux-clipboard-set', '*': 'termux-clipboard-set' },
      \   'paste': { '+': 'termux-clipboard-get', '*': 'termux-clipboard-get' },
      \   'cache_enabled': 0,
      \ }
    set clipboard=unnamedplus
  else
    echohl WarningMsg
    echo '[clipboard] termux-clipboard-set/get not found. Run: pkg install termux-api'
    echohl None
  endif

" ── 4. Linux – Wayland ───────────────────────────────────────────────────────
elseif $WAYLAND_DISPLAY != '' && executable('wl-copy') && executable('wl-paste')
  let g:clipboard = {
    \   'name': 'Wayland (wl-clipboard)',
    \   'copy':  {
    \     '+': ['wl-copy', '--foreground', '--type', 'text/plain'],
    \     '*': ['wl-copy', '--foreground', '--primary', '--type', 'text/plain'],
    \   },
    \   'paste': {
    \     '+': ['wl-paste', '--no-newline'],
    \     '*': ['wl-paste', '--no-newline', '--primary'],
    \   },
    \   'cache_enabled': 0,
    \ }
  set clipboard=unnamedplus

" ── 5. Linux – X11 (xclip preferred, xsel fallback) ─────────────────────────
elseif $DISPLAY != '' && executable('xclip')
  let g:clipboard = {
    \   'name': 'X11 (xclip)',
    \   'copy':  {
    \     '+': ['xclip', '-quiet', '-i', '-selection', 'clipboard'],
    \     '*': ['xclip', '-quiet', '-i', '-selection', 'primary'],
    \   },
    \   'paste': {
    \     '+': ['xclip', '-o', '-selection', 'clipboard'],
    \     '*': ['xclip', '-o', '-selection', 'primary'],
    \   },
    \   'cache_enabled': 0,
    \ }
  set clipboard=unnamedplus

elseif $DISPLAY != '' && executable('xsel')
  let g:clipboard = {
    \   'name': 'X11 (xsel)',
    \   'copy':  {
    \     '+': ['xsel', '--nodetach', '-i', '--clipboard'],
    \     '*': ['xsel', '--nodetach', '-i', '--primary'],
    \   },
    \   'paste': {
    \     '+': ['xsel', '-o', '--clipboard'],
    \     '*': ['xsel', '-o', '--primary'],
    \   },
    \   'cache_enabled': 0,
    \ }
  set clipboard=unnamedplus

" ── 6. Last resort ───────────────────────────────────────────────────────────
else
  set clipboard=unnamedplus
endif

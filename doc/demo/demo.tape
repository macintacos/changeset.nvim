# The README demo. From the repository root, render it with `vhs doc/demo/demo.tape`.
#
# Records your own Neovim config running this checkout's changeset, on a clone of the
# private changeset-sandbox repository that doc/demo/demo.sh stages. vhs needs ttyd and
# ffmpeg on $PATH.

Output doc/demo/demo.gif

Require nvim

Set Shell "bash"
Set FontFamily "Berkeley Mono, Symbols Nerd Font Mono"
Set FontSize 18
Set Width 1920
Set Height 1080
Set Padding 20
Set Theme { "name": "Van Helsing", "black": "#22212c", "red": "#ff9580", "green": "#8aff80", "yellow": "#ffff80", "blue": "#9580ff", "magenta": "#ff80bf", "cyan": "#80ffea", "white": "#f8f8f2", "brightBlack": "#708ca9", "brightRed": "#ffaa99", "brightGreen": "#a2ff99", "brightYellow": "#ffff99", "brightBlue": "#aa99ff", "brightMagenta": "#ff99cc", "brightCyan": "#99ffee", "brightWhite": "#ffffff", "background": "#0b0d0f", "foreground": "#f8f8f2", "selection": "#34404b", "cursor": "#f8f8f2" }
Set TypingSpeed 140ms
Set Framerate 24

# Opening the sidebar once off camera lets the language servers fill in its symbols.
Hide
Type "doc/demo/demo.sh"
Enter
Wait+Screen@30s /session\.ts/
Ctrl+G
Type "g"
Wait+Screen@60s /parseToken/
Sleep 1s
Type "q"
Sleep 1s
Show

Sleep 1.5s
Ctrl+G
Type "g"
Sleep 2.5s
Type "H"
Sleep 2s

# Marking a file viewed moves on to the next one.
Type "gg"
Sleep 400ms
Type "j"
Sleep 1.6s
Type "x"
Sleep 2.8s
Type "x"
Sleep 1.6s
Type "x"
Sleep 1s
Type "l"
Sleep 1.2s
Type@220ms "jj"
Sleep 300ms
Type "j"
Sleep 2s

Ctrl+G
Type "cc"
Sleep 900ms
Type@75ms "config.toml adds "
Type@90ms "`session_cache_size`"
Sleep 300ms
Type@65ms ", but this still hard-cod"
Type@60ms "se"
Sleep 400ms
Backspace 2
Type@80ms "es "
Type@70ms "128."
Sleep 500ms
Type@85ms " Pass it in?"
Sleep 700ms
Ctrl+S
Sleep 1.5s

Type@200ms "jjj"
Sleep 2.2s
Enter
Sleep 1.5s

Type "j"
Sleep 400ms
Type "V"
Sleep 200ms
Type@180ms "jj"
Sleep 600ms
Ctrl+G
Type "cc"
Sleep 900ms
Type@70ms "Nothing caps the lifetime: "
Sleep 400ms
Type@65ms "a client refreshing every few minutes "
Type@75ms "keeps a session forever."
Sleep 700ms
Ctrl+S
Sleep 1.8s

# The rest of the file, change by change.
Ctrl+G
Type "nn"
Sleep 1.3s
Ctrl+G
Type "nn"
Sleep 1.3s
Ctrl+G
Type "nn"
Sleep 2.5s

Ctrl+G
Type "g"
Sleep 1s
Type "]]"
Sleep 1.2s
Type@250ms "jj"
Sleep 600ms
Type "j"
Sleep 900ms
Type "l"
Sleep 2.4s
Ctrl+G
Type "cc"
Sleep 900ms
Type@75ms "Add a revoke case: "
Sleep 300ms
Type@70ms "`get` reads the cache first, "
Sleep 250ms
Type@65ms "so check a revoked session stays gone."
Sleep 700ms
Ctrl+S
Sleep 1.5s

Type "f"
Sleep 600ms
Type@150ms "toml"
Sleep 900ms
Enter
Sleep 2.5s
# The prompt opens holding the current filter; an empty one clears it.
Type "f"
Sleep 500ms
Ctrl+U
Sleep 300ms
Enter
Sleep 1.2s

Ctrl+G
Type "cq"
Sleep 2.5s
Ctrl+G
Type "y"
Sleep 3.5s

# Quit Neovim so demo.sh's cleanup runs.
Hide
Escape
Type ":qa!"
Enter
Sleep 1s

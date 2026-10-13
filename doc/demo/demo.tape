# The README demo. From the repository root, render it with `vhs doc/demo/demo.tape`.
#
# Records your own Neovim and herdr configs: a review of the private changeset-sandbox
# repository, submitted to agent.py, a scripted stand-in for Claude Code, whose edits the
# sidebar then picks up. doc/demo/demo.sh stages it. vhs needs ttyd and ffmpeg on $PATH.

Output doc/demo/demo.gif

Require nvim

Set Shell "bash"
Set FontFamily "Berkeley Mono, Symbols Nerd Font Mono"
Set FontSize 18
Set Width 1920
Set Height 1080
Set Padding 20
Set Theme { "name": "Van Helsing", "black": "#22212c", "red": "#ff9580", "green": "#8aff80", "yellow": "#ffff80", "blue": "#9580ff", "magenta": "#ff80bf", "cyan": "#80ffea", "white": "#f8f8f2", "brightBlack": "#708ca9", "brightRed": "#ffaa99", "brightGreen": "#a2ff99", "brightYellow": "#ffff99", "brightBlue": "#aa99ff", "brightMagenta": "#ff99cc", "brightCyan": "#99ffee", "brightWhite": "#ffffff", "background": "#0b0d0f", "foreground": "#f8f8f2", "selection": "#34404b", "cursor": "#f8f8f2" }
Set TypingSpeed 70ms
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

Sleep 800ms
Ctrl+G
Type "g"
Sleep 1.4s
Type "H"
Sleep 1.2s

# Marking a file viewed moves on to the next one.
Type "gg"
Sleep 200ms
Type "j"
Sleep 900ms
Type "x"
Sleep 1.7s
Type "x"
Sleep 800ms
Type "x"
Sleep 500ms
Type "l"
Sleep 450ms
Type@65ms "jjj"
Sleep 1.3s

Ctrl+G
Type "cc"
Sleep 500ms
Type@60ms "config"
Type@95ms ".toml"
Sleep 140ms
Type@50ms " adds "
Sleep 300ms
Type@110ms "`"
Type@55ms "session_cahce"
Sleep 380ms
Backspace@110ms 3
Type@75ms "che_size"
Type@130ms "`"
Sleep 200ms
Type@45ms ", but this"
Sleep 160ms
Type@60ms " still "
Sleep 240ms
Type@70ms "hard-codes "
Type@120ms "128"
Type@40ms "."
Sleep 750ms
Type@55ms " Pass it"
Sleep 120ms
Type@65ms " in?"
Sleep 450ms
Ctrl+S
Sleep 900ms

Type@60ms "jjj"
Sleep 1.1s
Enter
Sleep 800ms

Type "j"
Sleep 250ms
Type "V"
Sleep 150ms
Type@90ms "jj"
Sleep 350ms
Ctrl+G
Type "cc"
Sleep 500ms
Type@55ms "This never "
Sleep 600ms
Backspace@35ms 6
Sleep 250ms
Type@60ms "can live "
Sleep 450ms
Backspace@35ms 14
Sleep 300ms
Type@50ms "Nothing caps"
Sleep 180ms
Type@70ms " the lifetime"
Type@100ms ": "
Sleep 420ms
Type@55ms "a client"
Sleep 130ms
Type@65ms " refreshing evry"
Sleep 200ms
Backspace@90ms 2
Type@60ms "ery few minutes "
Sleep 260ms
Type@50ms "keeps a session"
Sleep 150ms
Type@75ms " forever."
Sleep 500ms
Ctrl+S
Sleep 1s

# The rest of the file, change by change.
Ctrl+G
Type "nn"
Sleep 750ms
Ctrl+G
Type "nn"
Sleep 750ms
Ctrl+G
Type "nn"
Sleep 1.7s

Ctrl+G
Type "g"
Sleep 600ms
Type "]]"
Sleep 600ms
Type@80ms "jjj"
Sleep 350ms
Type "l"
Sleep 1.4s
Ctrl+G
Type "cc"
Sleep 500ms
Type@55ms "Add a "
Sleep 150ms
Type@70ms "revoke case"
Type@90ms ": "
Sleep 380ms
Type@120ms "`get`"
Sleep 140ms
Type@50ms " reads the cache"
Type@65ms " first, "
Sleep 550ms
Type@55ms "so check a revoekd"
Sleep 300ms
Backspace@95ms 3
Type@70ms "ked session"
Sleep 140ms
Type@60ms " stays gone."
Sleep 450ms
Ctrl+S
Sleep 900ms

Type "f"
Sleep 300ms
Type@95ms "toml"
Sleep 500ms
Enter
Sleep 1.6s
# The prompt opens holding the current filter; an empty one clears it.
Type "f"
Sleep 250ms
Ctrl+U
Sleep 150ms
Enter
Sleep 800ms

# Submitting pastes the review into the agent's prompt and focuses its tab.
Ctrl+G
Type "s"
Sleep 2.2s
Enter
Sleep 6.5s

# Back in the review, the agent's edits arrive in the tree and the preview.
Ctrl+B
Type "1"
Sleep 900ms
Type "gg"
Sleep 200ms
Type@70ms "jjjj"
Sleep 10s

# Quit herdr so demo.sh's cleanup runs.
Hide
Escape
Type ":qa!"
Enter
Sleep 1s
Ctrl+B
Type "q"
Sleep 3s

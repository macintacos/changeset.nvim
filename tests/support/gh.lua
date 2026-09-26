---A fake `gh` on PATH, so no spec asks GitHub about its fixture branch: it prints
---$FAKE_GH_PR after $FAKE_GH_DELAY seconds, and fails as if there were no PR when
---that is empty. Requiring it is what installs it; PATH is never restored, since
---each spec runs in its own nvim.
local bin = vim.fn.tempname()
vim.fn.mkdir(bin, "p")
vim.fn.writefile({
  "#!/bin/sh",
  'sleep "${FAKE_GH_DELAY:-0}"',
  '[ -n "$FAKE_GH_PR" ] || exit 1',
  'printf "%s" "$FAKE_GH_PR"',
}, bin .. "/gh")
vim.fn.setfperm(bin .. "/gh", "rwxr-xr-x")
vim.env.PATH = bin .. ":" .. vim.env.PATH

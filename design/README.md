# Design direction

The visual direction of changeset.nvim: what its look is for, where each colour comes from,
and the choices that settled it. It sits at the repo root because the taste skill's
playbooks read it here.

| File | Holds |
| --- | --- |
| [`brief.md`](brief.md) | What the look is for, and the rules every surface follows |
| [`tokens.md`](tokens.md) | The colour roles, and the theme group each is borrowed from |
| [`patterns.md`](patterns.md) | The recurring devices, and the ones refused |
| [`exceptions.md`](exceptions.md) | Where the plugin departs from the shared taste, and why |
| [`decisions.md`](decisions.md) | Each settled choice with its evidence, newest first |

`doc/agents/design.md` keeps the reasoning behind each surface: why a row, a float or a
band looks and behaves as it does. These files hold the direction that reasoning follows,
and point to it rather than restating it.

## Updating it

- A change to a `Changeset*` highlight group, or to how one is derived, updates
  `tokens.md` in the same change. The values themselves live only in
  `lua/changeset/highlights.lua`.
- A new device that recurs across surfaces goes in `patterns.md`, with the
  `doc/agents/design.md` section that explains it.
- A choice made between options a user compared goes in `decisions.md`, with what
  settled it.
- A departure from the shared taste floors or proposals goes in `exceptions.md`, with
  its reason.

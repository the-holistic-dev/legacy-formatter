# Legacy Formatter

A neovim formatter for legacy files that contains a mix of php/html templating.

## Dependencies

The formatter requires pint to format the php part and prettier for the html. Both come from Mason (`~/.local/share/nvim/mason/bin`); `harness.lua` adds it to `PATH` automatically.

## Rules

- Idempotency is a hard acceptance gate: `format(format(x)) == format(x)`.
- Inline and attribute PHP must survive verbatim; fail hard rather than write partial output.
- Full invariants and pipeline details live in the skill — read it before changing formatting behavior.

## Routing

| Task                     | Go to                                         |
| ------------------------ | --------------------------------------------- |
| Understand the formatter | `.agents/skills/legacy-formatter/SKILL.md`    |
| Edit the formatter       | `formatter.lua`                               |
| Test the formatter       | `harness.lua` (exit 0 ok, 1 error, 3 timeout) |

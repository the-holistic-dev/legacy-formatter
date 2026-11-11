# legacy-formatter

A Neovim formatter for legacy template files that mix PHP and HTML. It masks inline and attribute PHP, formats the HTML with **prettier**, formats the PHP with **pint**, then restores the PHP verbatim — so template markup is cleaned up without ever touching the PHP in between.

## Dependencies

Both formatters are provided by [Mason](https://github.com/neovim/mason.nvim):

- `pint` (PHP)
- `prettier` (HTML)

Their binaries live in `~/.local/share/nvim/mason/bin`; `harness.lua` adds it to `PATH` automatically when testing.

## Usage

`formatter.lua` exposes a `format` function that takes file content (a PHP/HTML template string) and returns the formatted result. It can also be wired into [conform.nvim](https://github.com/folke/conform.nvim) as a custom formatter.

Configuration defaults (see `M.defaults` in `formatter.lua`):

| Key    | Default                                                        |
| ------ | -------------------------------------------------------------- |
| `html` | `prettier --parser html --print-width 120`                     |
| `php`  | `pint --quiet $FILENAME`                                       |
| `debug`| `false` (enable to log and dump pipeline stages via `debug_dir`) |

## Invariants

- **Idempotency:** `format(format(x)) == format(x)` is a hard acceptance gate.
- **PHP preserved verbatim:** inline and attribute PHP must survive formatting byte-for-byte; the formatter fails hard rather than write partial output.

## Testing

Run the harness (exit `0` = ok, `1` = error, `3` = timeout):

```sh
lua harness.lua
```

Full pipeline details, the scope-indent model, and testing procedures are documented in the skill: `.agents/skills/legacy-formatter/SKILL.md`.

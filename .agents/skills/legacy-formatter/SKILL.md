---
name: legacy-formatter
description: "The legacy-formatter template formatter (lua/formatters/legacy-formatter/formatter.lua): how the mask → prettier → pint → restore pipeline works, the uniform PHP scope-indent model (prettier HTML-nesting baseline + 2× open PHP scopes per line), its invariants, and how to test it headless (harness, selftest, idempotency, template-set sweep, edge cases, stage dumps). Use when editing formatter.lua, debugging unexpected template formatting (mangled inline PHP, broken tags, mis-indented nested content, non-idempotent output), verifying formatter behavior, or wiring the formatter into conform."
---

# legacy-formatter

`formatter.lua` (this directory) formats legacy PHP/HTML templating files (WordPress plugin templates like Trainrkit's): **Prettier** formats the HTML, **Pint** formats the PHP, and inline PHP is preserved verbatim. It runs as a conform `format`-function formatter (no shell wrapper).

## The pipeline (one pass)

All steps below are inside `one_pass()`; function names are from `formatter.lua`.

1. **Token choice** — `choose_token()`: default `PHPFMT`; if that string (case-insensitively) appears in the content, a random `phpf<6 digits>` is used instead, so placeholders can never collide with real content. Tokens are kept short so Prettier doesn't wrap lines that only overflow because of masked PHP.
2. **Segmentation** — `parse_segments()` splits the file into `html`/`php` segments. `find_php_close()` finds each closing `?>` while tracking single/double/backtick strings, `//`/`#` and `/* */` comments, and heredoc/nowdoc. Verified parser semantics: a `?>` inside `/* ... */` does **not** close a block; a `?>` on the same line as a `//`/`#` comment **does**.
3. **Context classification** — `segment_states()` records the markup context at each PHP segment's start (`text` / `tag` / `quote` / `comment`). The state persists _across_ PHP segments (a `?>` does not close the surrounding quote or tag), which is what makes `aria-selected="<?php ... ?>"` classify correctly. `classify_segment()` then yields:

   | kind         | when                               | masked as                  | sent to Pint |
   | ------------ | ---------------------------------- | -------------------------- | ------------ |
   | `inline`     | single line, in text or attr value | `PHPFMTI<n>` (opaque text) | no           |
   | `attr`       | single line, in a tag's attr list  | `data-phpfmt="<n>"`        | no           |
   | `block`      | alone on its line, or multi-line   | `<!-- PHPFMTB<n> -->`      | yes          |
   | `attr_block` | multi-line, in a tag's attr list   | `data-phpfmt="<n>"`        | yes          |

   `attr_spaced()` prepends a space when the placeholder would glue to a word char — `<tr<?php ... ?>>` must mask to `<tr data-phpfmt="3">`, never `<trdata-phpfmt="3">` (Prettier would read one tag name and the matching `</tr>` becomes stray → whole file fails). Pint-bound text is run through `dedent_block()` first (tag-boundary lines flattened to column 0, minimum code indent stripped) so Pint sees a zero-baseline block.

4. **HTML balancing** — `balance_html()` is the safety net for unbalanced template HTML: stray closing tags become `<phpfmt-sc data-phpfmt-tag="x" data-phpfmt-id="n"></phpfmt-sc>` elements; unclosed open tags get a `data-phpfmt-open="n"` marker. This stops Prettier's error recovery from dropping or reordering tags. `restore_virtual()` removes these markers after Prettier runs.
5. **Prettier** — default args `{ "--parser", "html", "--print-width", "120" }` (print-width 120 keeps template tags on one line — house style). Masked HTML goes in via stdin, formatted HTML comes out on stdout. Non-zero exit → hard error, and the masked input is dumped for inspection.
6. **Pint** — `build_batch()` concatenates all Pint-bound blocks **in document order** (numeric id sort — `pairs()` order is wrong: loop guards like `<?php if (...) { ?>` … `<?php } ?>` are only valid PHP when joined, and a shuffled batch fails to parse and Pint skips the whole file). Each block is wrapped in `<!-- @PHPFMTB<n>@ -->` / `<!-- @END_PHPFMTB<n>@ -->` markers. One `pint --quiet <tmpfile>` invocation; **non-zero exit is a hard error** (never silently skipped). `parse_batch()` splits Pint's output back into per-block text.
7. **PHP scope indent** — `apply_scope_indent()`. Prettier's baseline indentation is the HTML nesting only (top-level content at column 0); it is blind to the PHP control-flow scopes (`if`/`while`/`foreach`) that wrap the content. `brace_profile()` computes each PHP segment's net brace delta and shallowest running depth, ignoring braces inside strings, `//`/`#`/`/* */` comments, and heredocs, so the open-scope depth is known at every point. That depth is re-applied **additively to every line** — `line_indent = prettier_indent + 2 × scope_depth(line)` — HTML, inline-PHP spans, and spliced PHP blocks alike. Adding a constant per line preserves Prettier's relative HTML nesting while lifting a region one level per open scope, which is what stops a child from ever sitting less-indented than its parent (the nesting inversion). `depth_after[i]` (scopes open after segment i) indents the HTML/inline region that follows a segment, including a standalone `<?php } ?>` close (so the close sits at the context depth — the same indent as the body it closes, one level deeper than the open); `seg_level[i]` (the shallowest level segment i reaches) indents a pure block-placeholder line. Runs after `restore_virtual()` and **before block splicing**, so `splice_block()` drops multi-line PHP at the corrected placeholder-line indent.
8. **Restore** — all three kinds are spliced back **back-to-front** (so byte offsets stay valid):
   - blocks: `splice_block()` re-indents the block to its placeholder line's HTML indent (already lifted by the open-scope depth in step 7);
   - attr + inline: spliced back **verbatim** (never reformatted, never re-indented);
   - per-kind count check: if any placeholder is missing from Prettier's output → hard error `restore failed: N/M … were placed — refusing to write partial output`.
9. **Integrity guards** — no leftover placeholder tokens in the output; output must not be empty.
10. **Fixed-point driver** — `run_pass()` iterates the whole pipeline up to `MAX_PASSES = 3`: pass N+1 formats pass N's output, because mask→prettier→restore can shift markup shapes so a second conform run would reflow the first. A pass that changes nothing **is** the fixed point (clean files cost one pass). If a later pass fails, `last_good` (the last successful pass) is kept with a warning.
11. A trailing newline present in the input is preserved in the output.

## Invariants (why output looks the way it does)

- **Inline and attribute PHP is always verbatim.** The formatter intentionally never touches the interior of those spans — including residue from earlier broken formatter runs (e.g. an added `;` in `<?php get_header(); ?>`). Restoring "cleaner" content is out of scope by design.
- **One space may be added before PHP that is glued to a tag name**: `<tr<?php echo ... ?>>` → `<tr <?php echo ... ?>>`. That space is the HTML-side separator required to mask the segment as a _valid_ attribute (`<tr data-phpfmt="3">`); it is outside the PHP span, survives restore, and is stable (idempotent). Cosmetic only — not a bug, and not removable without changing restore behavior.
- **Block PHP is what Pint sees** and Pint may rewrite it (Laravel preset rules — see "Pint interactions" below).
- **Prettier never sees real PHP**, only opaque tokens. **Pint never sees HTML**, only a valid PHP batch.
- **Indentation is uniform across a PHP scope.** Every line inside N open PHP scopes is indented `2 × N` beyond Prettier's HTML-nesting baseline — HTML, inline-PHP spans, and spliced PHP blocks alike (model: `line_indent = prettier_indent + 2 × scope_depth(line)`). This is the invariant that eliminates nesting inversions, so a child element can never be less indented than its parent. See pipeline step 7.
- **Hard fail, never partial**: any restore mismatch, tool failure, or guard trip reports an error to conform and the buffer is left unmodified.
- Formatting is idempotent: `format(format(x)) == format(x)` is a hard acceptance criterion (see below).

## Testing

### Prerequisites

`prettier` and `pint` must be resolvable. The Mason installs live in `~/.local/share/nvim/mason/bin`; `harness.lua` (this directory) prepends it to `PATH` automatically. For manual tool runs: `export PATH="$HOME/.local/share/nvim/mason/bin:$PATH"`.

### One-shot format + idempotency

`harness.lua` (this directory) invokes the formatter exactly like conform does (buffer lines in, lines out; same callback protocol):

```sh
H=~/.config/nvim/lua/formatters/legacy-formatter/harness.lua
nvim --headless -u NONE -l "$H" in.php out.php        # OK (exit 0) | FORMAT ERROR (exit 1) | TIMEOUT (exit 3)
nvim --headless -u NONE -l "$H" out.php out2.php      # format the output again
diff out.php out2.php                                 # empty diff == IDEMPOTENT (hard requirement)
```

### Regression selftest (scope indent)

The harness ships a built-in regression test for the PHP scope-indent feature (the nesting-inversion fix) — no input file needed:

```sh
nvim --headless -u NONE -l "$H" --selftest   # PASS (exit 0) | FAIL (exit 1) | TIMEOUT (exit 3)
```

It formats a minimal flat `foreach` fixture and asserts the uniform-indent model: the body (`<li>`) is indented exactly 2 more than `<?php foreach`, the closing `<?php } ?>` sits at the context depth (the same indent as the body, one level deeper than the open), the inline PHP span is intact, and the result is idempotent. Run it after any change to the indentation logic (`apply_scope_indent`/`brace_profile`).

### Full template-set sweep

Run every template through format + idempotency in one go (copy into a scratch dir first so the working tree is untouched):

```sh
cd <plugin-root>
rm -rf /tmp/fmt-all && mkdir -p /tmp/fmt-all/in
while IFS= read -r f; do cp --parents "$f" /tmp/fmt-all/in/; done \
  < <(find templates -name '*.php' | sort)
# (pure-PHP files under src/ go through the same pipeline via the PHP-only path; add them to the find if you want them in the sweep)

H=~/.config/nvim/lua/formatters/legacy-formatter/harness.lua
cd /tmp/fmt-all
for f in $(cd in && find . -name '*.php' | sort); do
  outp="out/${f#./}"; mkdir -p "$(dirname "$outp")"
  if timeout 90 nvim --headless -u NONE -l "$H" "in/$f" "$outp" >/dev/null 2>&1; then
    timeout 90 nvim --headless -u NONE -l "$H" "$outp" pass2 >/dev/null 2>&1
    if diff -q "out/${f#./}" pass2 >/dev/null 2>&1; then
      echo "OK+IDEMPOTENT  changed=$(diff "in/$f" "out/${f#./}" | grep -c '^[<>]')  $f"
    else
      echo "OK but NOT idempotent  $f"
    fi
  else
    echo "FAILED  $f"
  fi
done
```

Baseline (last verified state, all 5 Trainrkit templates): `OK+IDEMPOTENT` for `templates/blocks/profile-hero.php`, `templates/blocks/program-table.php`, `templates/profile.php`, `templates/programs/archive.php`, `templates/programs/single.php`.

### Edge cases

Each must format `OK` **and** be `IDEMPOTENT` (loop through them with the one-shot recipe). Minimal trigger files:

```php
<?php // php-only: pint path, no HTML at all
$items = [1, 2, 3];
foreach ( $items as $i ) {
  echo $i;
}
?>
```

```php
<div class="x"><span>hi</span></div>
```

```php
<tr<?php echo $is_hidden ? ' class="d-none"' : ''; ?>>
```

```php
<li aria-selected="<?php echo $i == $cur ?>">item</li>
```

```php
<?php $s = "a ?> b"; echo $s; ?>
```

```php
<?php /* ?> */ echo 1; ?>
```

```php
<?php foreach ($items as $item) { ?>
  <li><?php echo $item; ?></li>
<?php } ?>
```

```php
<?php foreach ($items as $item): ?>
  <li><?php echo $item; ?></li>
<?php endforeach; ?>
```

Scope-indent regression (the nesting-inversion case; also covered by the harness `--selftest`). Feed this **flat** (un-indented) input:

```php
<?php foreach ($items as $it) { ?>
<li><?php echo $it; ?></li>
<?php } ?>
```

Expected output: the `<li>` (foreach body) is indented exactly 2 more than the `<?php foreach` line, and the closing `<?php } ?>` sits at the context depth — the same indent as the `<li>` body (one level deeper than the `<?php foreach` open).

Colon-syntax note: with the current `pint.json` (Laravel preset, `no_alternative_syntax` active) the last case gets **rewritten to brace syntax** by Pint — that's Pint, not the formatter. See "Pint interactions".

Error-path cases (expect `FORMAT ERROR`, exit 1 — a clean report, never a crash or partial write):

```php
<?php
$x = 1
```

(unterminated PHP block), and unbalanced HTML such as a stray `</div>` with no opener (should still format, via the balancing safety net, with the stray close preserved).

### Stage dumps (debugging)

`FMT_DEBUG_DIR` writes every pipeline stage to a directory; `FMT_DEBUG=1` also enables `vim.notify` logging:

```sh
FMT_DEBUG_DIR=/tmp/fmt-stages FMT_DEBUG=1 nvim --headless -u NONE -l "$H" in.php out.php
ls /tmp/fmt-stages
# 01_segments.txt      segmentation + first 60 chars of each segment
# 02_masked.html       exactly what Prettier receives
# 03_pint_batch.php    exactly what Pint receives
# 04_prettier_out.html Prettier's output, before restore
# 05_pint_out.php      Pint's output, before split
# 06_final.php         final output after all restores
```

Typical triage: wrong classification → `01_segments.txt`; Prettier failure → `02_masked.html`; Pint failure → `03_pint_batch.php`; missing placeholder → compare `04`/`05` against the maps.

### Syntax check (after editing the formatter)

```sh
nvim --headless -u NONE -c "luafile ~/.config/nvim/lua/formatters/legacy-formatter/formatter.lua"; echo "exit=$?"   # 0 = parses
```

Then re-run the template-set sweep — that is the acceptance gate for any change to `formatter.lua`.

## Wiring into conform

**Current state (as of this skill):** `lua/plugins/conform.lua` maps `php = { "pint" }` (the built-in command formatter) — that path reformats the whole file as plain PHP and does **not** preserve inline template PHP. `legacy_formatter` is tested via the harness, not yet wired in.

To activate it, in `lua/plugins/conform.lua`:

```lua
formatters_by_ft = {
  php = { "legacy_formatter" }, -- was { "pint" }
},
formatters = {
  -- conform's protocol: config.format(config, ctx, lines, callback)
  legacy_formatter = {
    format = function(cfg, ctx, lines, cb)
      require("formatters.legacy-formatter.formatter").format(cfg)(nil, ctx, lines, cb)
    end,
  },
},
```

`M.format(config)` deep-merges `M.defaults` (prettier/pint commands + args, `debug`) over the passed config, so extra keys (e.g. `debug_dir`) can be supplied per buffer.

## Pint interactions (verified against installed Pint 1.32.1)

- The Laravel preset includes `no_alternative_syntax`, which rewrites `foreach (): endforeach;` (and friends) to brace syntax in any block sent to Pint. There is **no inverse fixer** — nothing makes Pint _use_ colon syntax.
- Pint 1.32.1 has **no per-rule, per-path scoping**: config supports only `preset`, `rules`, `extend`, `cache-file`, and finder options (`exclude`, `in`, `notPath`, `notName`). Path rules are moot here anyway — the formatter runs Pint on a synthesized batch file in a temp dir, never on the template's real path.
- The only lever is global: `"rules": { "no_alternative_syntax": false }` in the project `pint.json` — then colon syntax survives everywhere it's written (templates and `src/` alike). Brace style is unaffected either way.

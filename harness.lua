-- Headless test harness for formatters.legacy-formatter.formatter (same directory as this file).
-- Invokes the formatter exactly like conform would: buffer lines in, lines out.
--
-- Usage:
--   nvim --headless -u NONE -l <this-dir>/harness.lua <input.php> <output.php>
--   nvim --headless -u NONE -l <this-dir>/harness.lua --selftest
--
-- Exit codes: 0 = OK/PASS, 1 = formatter error/FAIL, 2 = bad args/input, 3 = timeout.
-- Env: FMT_DEBUG=1        -> enable vim.notify logging
--      FMT_DEBUG_DIR=<d>  -> dump pipeline stages 01..06 into <d>
--
-- This file is referenced by SKILL.md in the same directory.

local is_selftest = (arg[1] == "--selftest")
local input_path = arg[1]
local output_path = arg[2]
if not is_selftest and (not input_path or not output_path) then
  io.write("usage: nvim --headless -u NONE -l harness.lua <input.php> <output.php> | --selftest\n")
  os.exit(2)
end

-- The formatter sits next to this file; load it directly by path.
local src = debug.getinfo(1, "S").source
local this_file = src:match("^@(.*)$") or src
local formatter_dir = vim.fs.dirname(vim.fs.abspath(this_file))

-- Resolve prettier/pint from Mason when they are not already on PATH.
local mason_bin = vim.fn.stdpath("data") .. "/mason/bin"
if vim.fn.isdirectory(mason_bin) then
  vim.env.PATH = mason_bin .. ":" .. (vim.env.PATH or "")
end

local php_html = dofile(formatter_dir .. "/formatter.lua")

local cfg = {}
if os.getenv("FMT_DEBUG_DIR") then cfg.debug_dir = os.getenv("FMT_DEBUG_DIR") end
if os.getenv("FMT_DEBUG") == "1" then cfg.debug = true end

local f = php_html.format(cfg)

-- Format `lines` through the formatter; returns (out_lines, err).
-- err is "TIMEOUT" on timeout, the formatter's error otherwise, or nil on success.
local function format_lines(filename, lines)
  local done = false
  local err = nil
  local out = nil
  f(nil, { filename = filename }, lines, function(e, o)
    if e then
      err = e
    else
      out = o
    end
    done = true
  end)
  local ok = vim.wait(30000, function() return done end, 100)
  if not ok then
    return nil, "TIMEOUT"
  end
  if err then
    return nil, err
  end
  return out
end

if is_selftest then
  -- Regression test for the PHP scope-indent feature (the nesting-inversion fix).
  -- Feed a flat (un-indented) foreach fixture and assert the uniform-indent model.
  local fixture = {
    "<?php foreach ($items as $it) { ?>",
    "<li><?php echo $it; ?></li>",
    "<?php } ?>",
  }

  local out, err = format_lines("selftest.php", fixture)
  if err then
    io.write((err == "TIMEOUT") and "TIMEOUT\n" or ("FAIL: " .. tostring(err) .. "\n"))
    os.exit(err == "TIMEOUT" and 3 or 1)
  end

  local failures = {}
  local function check(cond, msg)
    if not cond then
      table.insert(failures, msg)
    end
  end

  local function trimmed(line)
    return line:match("^%s*(.-)%s*$")
  end
  local function indent_of(line)
    return #(line:match("^%s*"))
  end

  local foreach_ln, li_ln, close_ln = nil, nil, nil
  for i, line in ipairs(out) do
    local t = trimmed(line)
    if t == "<?php foreach ($items as $it) { ?>" then foreach_ln = i end
    if t == "<li><?php echo $it; ?></li>" then li_ln = i end
    if t == "<?php } ?>" then close_ln = i end
  end

  check(foreach_ln ~= nil, "missing: <?php foreach ... ?> open line")
  check(li_ln ~= nil, "missing: <li> body line")
  check(close_ln ~= nil, "missing: <?php } ?> close line")

  if foreach_ln and li_ln and close_ln then
    local ind_f = indent_of(out[foreach_ln])
    local ind_l = indent_of(out[li_ln])
    local ind_c = indent_of(out[close_ln])
    check(
      ind_l == ind_f + 2,
      string.format("body <li> should be indented 2 more than foreach (body=%d, foreach=%d)", ind_l, ind_f)
    )
    check(
      ind_c == ind_l,
      string.format("close <?php } ?> should sit at the context depth, same as body (close=%d, body=%d)", ind_c, ind_l)
    )
    -- Plain-text search (3rd arg `true`): `?`/`$` are special in Lua patterns.
    local found = table.concat(out, "\n"):find("<?php echo $it; ?>", 1, true)
    check(
      found ~= nil,
      "inline PHP span <?php echo $it; ?> not preserved verbatim"
    )
  end

  -- Idempotency: formatting the output again must yield the same output.
  local out2, err2 = format_lines("selftest.php", out)
  if err2 then
    table.insert(failures, (err2 == "TIMEOUT") and "idempotency pass: TIMEOUT" or ("idempotency pass: " .. tostring(err2)))
  else
    check(vim.deep_equal(out, out2), "output not idempotent (format(format(x)) ~= format(x))")
  end

  if #failures > 0 then
    for _, msg in ipairs(failures) do
      io.write("FAIL: " .. msg .. "\n")
    end
    os.exit(1)
  end
  io.write("PASS\n")
  os.exit(0)
end

-- File-based mode.
local fh = io.open(input_path, "r")
if not fh then
  io.write("cannot open input: " .. input_path .. "\n")
  os.exit(2)
end
local content = fh:read("*a")
fh:close()

-- Conform hands the formatter buffer lines (no trailing empty string).
local lines = vim.split(content, "\n", { plain = true })
if lines[#lines] == "" then
  table.remove(lines)
end

local out, err = format_lines(input_path, lines)
if err then
  io.write((err == "TIMEOUT") and "TIMEOUT\n" or ("FORMAT ERROR: " .. tostring(err) .. "\n"))
  os.exit(err == "TIMEOUT" and 3 or 1)
end

local outfh = io.open(output_path, "w")
if not outfh then
  io.write("cannot open output: " .. output_path .. "\n")
  os.exit(1)
end
outfh:write(table.concat(out, "\n"))
if content:match("\n$") then outfh:write("\n") end
outfh:close()
io.write("OK\n")
os.exit(0)

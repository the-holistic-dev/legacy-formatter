local M = {}

M.defaults = {
  -- print-width 120: template tags are kept on one line (house style),
  -- only genuinely long attribute lists wrap — matching the committed
  -- template files.
  html = { command = "prettier", args = { "--parser", "html", "--print-width", "120" } },
  php = { command = "pint", args = { "--quiet", "$FILENAME" } },
  debug = false,
}

-- Placeholder prefix, chosen per run (see choose_token) so it can never
-- collide with user content. Kept short so prettier sees compact stand-ins
-- and does not wrap lines that only overflow because of the real (masked)
-- PHP.
local TOKEN = "PHPFMT"

local function choose_token(content)
  local function clashes(t)
    local low = t:lower()
    return content:find(t, 1, true) ~= nil
      or content:find(low, 1, true) ~= nil
      or content:find("phphtmlx", 1, true) ~= nil
  end
  local t = "PHPFMT"
  for _ = 1, 10 do
    if not clashes(t) then
      return t
    end
    t = "phpf" .. tostring(math.random(100000, 999999))
  end
  return t
end

local VOID_TAGS = {
  area = true,
  base = true,
  br = true,
  col = true,
  embed = true,
  hr = true,
  img = true,
  input = true,
  link = true,
  meta = true,
  param = true,
  source = true,
  track = true,
  wbr = true,
}

local function log(config, msg, level)
  if config.debug or level == vim.log.levels.ERROR then
    vim.notify("[php_html] " .. msg, level or vim.log.levels.INFO)
  end
end

-- Debug stage dumping: when config.debug_dir is set, every pipeline stage
-- is written there as 01_segments.txt, 02_masked.html, 03_pint_batch.php,
-- 04_prettier_out.html, 05_pint_out.php, 06_final.php.
local function stage_dump(config, name, data)
  local dir = config.debug_dir
  if not dir or not data then return end
  pcall(vim.fn.mkdir, dir, "p")
  local fh = io.open(dir .. "/" .. name, "w")
  if fh then
    fh:write(data)
    fh:close()
  end
end

----------------------------------------------------------------------
-- PHP close scanning: strings, comments, heredoc/nowdoc aware
----------------------------------------------------------------------

local function scan_heredoc(content, i, len)
  local j = i + 3
  while j <= len and (content:sub(j, j) == " " or content:sub(j, j) == "\t") do
    j = j + 1
  end
  local q = content:sub(j, j)
  local label
  if q == "'" or q == '"' then
    j = j + 1
    label = content:match("^([A-Za-z_][A-Za-z0-9_]*)", j)
    if not label then return nil end
    j = j + #label + 1
  else
    label = content:match("^([A-Za-z_][A-Za-z0-9_]*)", j)
    if not label then return nil end
    j = j + #label
  end

  local search = j
  while true do
    local nl = content:find("\n", search, true)
    if not nl then return nil end
    local line_start = nl + 1
    local k = line_start
    while k <= len and (content:sub(k, k) == " " or content:sub(k, k) == "\t") do
      k = k + 1
    end
    if content:sub(k, k + #label - 1) == label then
      local after = content:sub(k + #label, k + #label)
      if after == ";" or after == "\n" or after == "\r" or after == "" then
        local eol = content:find("\n", line_start, true)
        return eol and (eol - 1) or len
      end
    end
    search = nl + 1
  end
end

-- Find the `?>` that closes the PHP block whose code starts at `start`.
-- Returns (close_start, close_end) or nil if unterminated.
--
-- Comment semantics (verified against the PHP parser):
--   * `//` and `#` comments end at the FIRST of:
--       - a `?>` on the same line, which still closes the block
--         (e.g. `<?php $x = 1; // note ?>` ends at that `?>`), or
--       - the end of line, after which scanning continues.
--   * A `?>` inside a `/* ... */` block comment does NOT close the block.
local function find_php_close(content, start)
  local i = start
  local len = #content
  local in_single, in_double, in_backtick = false, false, false
  local in_block_comment = false

  while i <= len do
    local two = content:sub(i, i + 1)
    local three = content:sub(i, i + 2)

    if in_block_comment then
      if two == "*/" then
        in_block_comment = false
        i = i + 1
      end
    elseif in_backtick then
      if content:sub(i, i) == "`" then
        in_backtick = false
      end
    elseif in_single then
      local c = content:sub(i, i)
      if c == "'" then
        in_single = false
      elseif c == "\\" then
        i = i + 1
      end
    elseif in_double then
      local c = content:sub(i, i)
      if c == '"' then
        in_double = false
      elseif c == "\\" then
        i = i + 1
      end
    elseif three == "<<<" then
      local after = scan_heredoc(content, i, len)
      i = after or (i + 2)
    else
      local c = content:sub(i, i)
      if c == "'" then
        in_single = true
      elseif c == '"' then
        in_double = true
      elseif c == "`" then
        in_backtick = true
      elseif two == "//" or c == "#" then
        local gt = content:find("?>", i, true)
        local nl = content:find("\n", i, true)
        if gt and (not nl or gt < nl) then
          return gt, gt + 1
        end
        if not nl then
          return nil
        end
        i = nl
      elseif two == "/*" then
        in_block_comment = true
        i = i + 1
      elseif two == "?>" then
        return i, i + 1
      end
    end

    i = i + 1
  end

  return nil
end

local function parse_segments(content)
  local segments = {}
  local pos = 1
  local len = #content

  while pos <= len do
    local php_start, php_end = content:find("<%?=?%a*%s?", pos)
    if not php_start then
      table.insert(segments, { type = "html", text = content:sub(pos) })
      break
    end

    local tag = content:sub(php_start, php_end)
    if tag:match("^<%?xml") then
      pos = php_start + 1
    else
      if php_start > pos then
        table.insert(segments, { type = "html", text = content:sub(pos, php_start - 1) })
      end

      local close_start, close_end = find_php_close(content, php_end + 1)
      local seg_end = close_end or len

      table.insert(segments, {
        type = "php",
        text = content:sub(php_start, seg_end),
        start = php_start,
      })

      if close_start then
        pos = close_end + 1
      else
        break
      end
    end
  end

  return segments
end

----------------------------------------------------------------------
-- HTML balancing (stray closes / unclosed opens)
-- Safety net so prettier's error recovery cannot drop or reorder tags
-- when the template HTML is unbalanced.
----------------------------------------------------------------------

local function find_tag_end(html, s)
  local i = s
  local len = #html
  local quote = nil
  while i <= len do
    local c = html:sub(i, i)
    if quote then
      if c == quote then quote = nil end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == ">" then
      return i
    end
    i = i + 1
  end
  return nil
end

local function balance_html(html)
  local parts = {}
  local open_stack = {}
  local stray_id = 0
  local pos = 1

  while true do
    local s = html:find("<", pos, true)
    if not s then
      table.insert(parts, html:sub(pos))
      break
    end

    table.insert(parts, html:sub(pos, s - 1))

    if html:sub(s, s + 3) == "<!--" then
      local ce = html:find("-->", s + 4, true)
      if ce then
        table.insert(parts, html:sub(s, ce + 2))
        pos = ce + 3
      else
        table.insert(parts, html:sub(s))
        break
      end
    elseif html:sub(s + 1, s + 1) == "!" then
      local e = find_tag_end(html, s)
      if not e then
        table.insert(parts, html:sub(s))
        break
      end
      table.insert(parts, html:sub(s, e))
      pos = e + 1
    elseif html:sub(s + 1, s + 1) == "/" then
      local name = html:match("^</(%a[%w%-]*)", s)
      local e = find_tag_end(html, s)
      if not name or not e then
        table.insert(parts, html:sub(s))
        break
      end

      local found = nil
      for d = #open_stack, 1, -1 do
        if open_stack[d].name:lower() == name:lower() then
          found = d
          break
        end
      end

      if found then
        for _ = #open_stack, found, -1 do
          table.remove(open_stack)
        end
        table.insert(parts, html:sub(s, e))
      else
        stray_id = stray_id + 1
        local low = string.lower(TOKEN)
        table.insert(parts,
          '<' .. low .. '-sc data-' .. low .. '-tag="' .. name ..
          '" data-' .. low .. '-id="' .. stray_id .. '"></' .. low .. '-sc>')
      end
      pos = e + 1
    elseif html:sub(s + 1, s + 1):match("%a") then
      local name = html:match("^<(%a[%w%-]*)", s)
      local e = find_tag_end(html, s)
      if not name or not e then
        table.insert(parts, html:sub(s))
        break
      end

      local tag_text = html:sub(s, e)
      table.insert(parts, tag_text)

      local lower = name:lower()
      if not VOID_TAGS[lower] and not tag_text:find("/%s*>$") then
        table.insert(open_stack, { name = name, idx = #parts })
      end
      pos = e + 1
    else
      table.insert(parts, "<")
      pos = s + 1
    end
  end

  local unclosed_id = 0
  local low = string.lower(TOKEN)
  for _, entry in ipairs(open_stack) do
    unclosed_id = unclosed_id + 1
    parts[entry.idx] = parts[entry.idx]:gsub(">$", ' data-' .. low .. '-open="' .. unclosed_id .. '">', 1)
  end

  return table.concat(parts, "")
end

local function restore_virtual(html)
  local parts = {}
  local open_stack = {}
  local pos = 1

  while true do
    local s = html:find("<", pos, true)
    if not s then
      table.insert(parts, html:sub(pos))
      break
    end
    table.insert(parts, html:sub(pos, s - 1))

    if html:sub(s, s + 3) == "<!--" then
      local ce = html:find("-->", s + 4, true)
      if ce then
        table.insert(parts, html:sub(s, ce + 2))
        pos = ce + 3
      else
        table.insert(parts, html:sub(s))
        break
      end
    elseif html:sub(s + 1, s + 1) == "/" then
      local name = html:match("^</(%a[%w%-]*)", s)
      local e = find_tag_end(html, s)
      if not name or not e then
        table.insert(parts, html:sub(s))
        break
      end

      local removed = false
      for d = #open_stack, 1, -1 do
        if open_stack[d].name:lower() == name:lower() then
          removed = open_stack[d].virtual or false
          for _ = #open_stack, d, -1 do
            table.remove(open_stack)
          end
          break
        end
      end

      if not removed then
        table.insert(parts, html:sub(s, e))
      end
      pos = e + 1
    elseif html:sub(s + 1, s + 1):match("%a") then
      local name = html:match("^<(%a[%w%-]*)", s)
      local e = find_tag_end(html, s)
      if not name or not e then
        table.insert(parts, html:sub(s))
        break
      end

      local tag_text = html:sub(s, e)
      local low = string.lower(TOKEN)
      local virtual = tag_text:match("data%-" .. low .. '%-open="(%d+)"')
      if virtual then
        tag_text = tag_text:gsub("%s*data%-" .. low .. '%-open="' .. virtual .. '"', "", 1)
      end
      table.insert(parts, tag_text)

      local lower = name:lower()
      if not VOID_TAGS[lower] and not tag_text:find("/%s*>$") then
        table.insert(open_stack, { name = name, virtual = virtual ~= nil })
      end
      pos = e + 1
    else
      table.insert(parts, "<")
      pos = s + 1
    end
  end

  local result = table.concat(parts, "")

  local low = string.lower(TOKEN)
  local pat = "<" .. low .. "%-sc%s+data%-" .. low .. "%-tag=\"([^\"]+)\"%s+data%-" .. low
      .. "%-id=\"[^\"]*\"%s*>%s*</" .. low .. "%-sc>"
  result = result:gsub(pat, function(tag)
    return "</" .. tag .. ">"
  end)

  return result
end

----------------------------------------------------------------------
-- Placeholders, batching, indent
----------------------------------------------------------------------

local function block_placeholder(id)
  return "<!-- " .. TOKEN .. "B" .. id .. " -->"
end

local function inline_placeholder(id)
  return TOKEN .. "I" .. id
end

local function attr_placeholder(id)
  return 'data-' .. string.lower(TOKEN) .. '="' .. id .. '"'
end

local function find_attr_placeholders(text)
  local pattern = "data%-" .. string.lower(TOKEN) .. "=[\"'\"](%d+)[\"'\"]"
  local matches = {}
  local start_pos = 1
  while true do
    local s, e, id = text:find(pattern, start_pos)
    if not s then break end
    table.insert(matches, { s = s, e = e, id = tonumber(id) })
    start_pos = e + 1
  end
  return matches
end

-- Walk the HTML left-to-right between PHP segments, tracking where in the
-- markup each segment sits:
--   "tag"    : inside an open tag's attribute list
--   "quote"  : inside a quoted attribute value
--   "text"   : element text content (or top-level)
-- The state is preserved ACROSS a PHP segment — a `?>` does not close the
-- surrounding quote or tag — which is what makes cases like
-- `aria-selected="<?php ... ?>"` and PHP after such a value classify
-- correctly. PHP segment bodies are skipped whole (their `>`, quotes, and
-- comments must not leak into the scan).
local function segment_states(content, segments)
  local states = {}
  local at_pos = {}
  for i, seg in ipairs(segments) do
    if seg.type == "php" then
      at_pos[seg.start] = i
    end
  end

  local state = "text"
  local quote_char = nil
  local i = 1
  local n = #content
  while i <= n do
    local idx = at_pos[i]
    if idx then
      -- record the state at the segment's start, then jump past the whole
      -- PHP body (its quotes, `>`, and comments must not leak into the scan)
      states[idx] = state
      i = i + #segments[idx].text
    else
      local c = content:sub(i, i)
      if state == "text" then
        if c == "<" then
          if content:sub(i + 1, i + 3) == "!--" then
            state = "comment"
            i = i + 3
          elseif content:sub(i + 1, i + 1):match("[%a/!?]") then
            state = "tag"
          end
        end
      elseif state == "tag" then
        if c == '"' or c == "'" then
          state = "quote"
          quote_char = c
        elseif c == ">" then
          state = "text"
        end
      elseif state == "quote" then
        if c == quote_char then
          state = "tag"
        end
      elseif state == "comment" then
        if content:sub(i, i + 2) == "-->" then
          state = "text"
          i = i + 2
        end
      end
      i = i + 1
    end
  end
  return states
end

-- True when the last non-whitespace character before the segment is on the
-- segment's own line (i.e. the PHP is glued to surrounding content rather
-- than standing alone on its line).
local function same_line_before(content, seg)
  local j = seg.start - 1
  while j >= 1 and content:sub(j, j):match("[%s]") do
    j = j - 1
  end
  if j < 1 then return false end
  return not content:sub(j + 1, seg.start - 1):find("\n", 1, true)
end

-- Classify a PHP segment. Returns one of:
--   "inline"     : single-line, in text flow on the same line as the
--                  surrounding content, or inside an attribute value.
--                  Masked as an opaque text token, restored verbatim —
--                  never re-indented, never sent to pint.
--   "block"      : standing alone on its line in text flow, or multi-line.
--                  Masked as an atomic comment placeholder (block-level to
--                  prettier) and formatted by pint.
--   "attr"       : single-line, inside a tag's attribute list. Masked as a
--                  valid attribute (data-phphtmlfmt="N") that prettier
--                  keeps, restored verbatim.
--   "attr_block" : multi-line, inside a tag's attribute list. Masked as a
--                  valid attribute, formatted by pint, restored into the
--                  attribute position.
-- This matches the reference style: `<th><?php _e(...); ?></th>` stays
-- inline, while loop guards and helper blocks stay one per line.
local function classify_segment(states, content, i, seg)
  local st = states[i]
  local multiline = seg.text:find("\n") ~= nil

  if st == "tag" then
    return multiline and "attr_block" or "attr"
  end
  if st == "quote" then
    return multiline and "block" or "inline"
  end
  if multiline then
    return "block"
  end
  return same_line_before(content, seg) and "inline" or "block"
end

-- The attr placeholder is a real attribute, so it must be separated from
-- whatever precedes it. `<tr<?php ... ?>>` must mask to
-- `<tr data-pfm="N">`, not `<trdata-pfm="N">` (which prettier reads as one
-- tag name, making the matching `</tr>` stray and the whole file fail).
-- A space is only needed when the segment is glued to a tag/attribute name.
local function attr_spaced(i, seg, content)
  local prev = content:sub(seg.start - 1, seg.start - 1)
  if prev:match("[%w%-%_]") then
    return " " .. attr_placeholder(i)
  end
  return attr_placeholder(i)
end

local function find_block_placeholders(text)
  local pattern = "<!%-%-%s*" .. TOKEN .. "B(%d+)%s*%-%->"
  local matches = {}
  local start_pos = 1
  while true do
    local s, e, id = text:find(pattern, start_pos)
    if not s then break end
    table.insert(matches, { s = s, e = e, id = tonumber(id) })
    start_pos = e + 1
  end
  return matches
end

local function find_inline_placeholders(text)
  local pattern = TOKEN .. "I(%d+)"
  local matches = {}
  local start_pos = 1
  while true do
    local s, e, id = text:find(pattern, start_pos)
    if not s then break end
    table.insert(matches, { s = s, e = e, id = tonumber(id) })
    start_pos = e + 1
  end
  return matches
end

-- Normalize a PHP block so it can be formatted by pint at column 0:
--   * tag-boundary lines (the opening `<?php` line and any line that is
--     only `?>`) are flattened to column 0;
--   * every other (code) line has the MINIMUM code indent removed;
--   * whitespace-only lines become truly empty.
-- The block is re-indented to its HTML context at restore time.
--
-- Flattening tag boundaries and using the minimum code indent keeps
-- repeated saves convergent: the context indent is applied exactly once on
-- restore, and legacy drift (a `?>` indented differently from `<?php`)
-- cannot slide the baseline one level per save.
local function dedent_block(text)
  local lines = vim.split(text, "\n")

  local base = 0
  local have_code = false
  for i, line in ipairs(lines) do
    if i ~= 1 and line:find("%S") and not line:match("^%s*%?>%s*$") then
      local n = #line:match("^[ \t]*")
      if not have_code or n < base then
        base = n
        have_code = true
      end
    end
  end

  local result = {}
  for i, line in ipairs(lines) do
    if line:find("%S") then
      if i == 1 or line:match("^%s*%?>%s*$") then
        -- tag boundary: flatten to column 0, drop surrounding whitespace
        table.insert(result, line:match("^%s*(.-)%s*$"))
      else
        local n = math.min(base, #line:match("^[ \t]*"))
        table.insert(result, line:sub(n + 1))
      end
    else
      table.insert(result, "")
    end
  end
  return table.concat(result, "\n")
end

-- Net brace delta and minimum running depth within a PHP segment, ignoring
-- braces inside strings, comments, and heredocs. Used to compute the PHP
-- scope depth (if/while/foreach blocks) so that HTML content inside those
-- scopes can be indented one extra level per scope.
local function brace_profile(text)
  local i = 1
  local len = #text
  local skip = text:match("^<%?=?%a*")
  if skip then i = #skip + 1 end
  local running = 0
  local min_running = 0
  while i <= len do
    local two = text:sub(i, i + 1)
    local c = text:sub(i, i)
    if c == "'" or c == '"' or c == "`" then
      i = i + 1
      while i <= len do
        local d = text:sub(i, i)
        if d == "\\" then
          i = i + 2
        elseif d == c then
          break
        else
          i = i + 1
        end
      end
      i = i + 1
    elseif two == "//" or c == "#" then
      local nl = text:find("\n", i, true)
      i = nl or (len + 1)
    elseif two == "/*" then
      local ce = text:find("*/", i + 2, true)
      i = ce and (ce + 2) or (len + 1)
    elseif text:sub(i, i + 2) == "<<<" then
      local e = scan_heredoc(text, i, len)
      i = e and (e + 1) or (len + 1)
    elseif c == "{" then
      running = running + 1
      i = i + 1
    elseif c == "}" then
      running = running - 1
      if running < min_running then min_running = running end
      i = i + 1
    else
      i = i + 1
    end
  end
  return running, min_running
end

-- PHP scope indent. Prettier emits a clean baseline whose indentation is the
-- HTML nesting only (top-level content at column 0). The PHP control-flow
-- scopes (if/while/foreach) that wrap the content are invisible to prettier,
-- so the scope depth is re-applied here, additively, to EVERY line — HTML and
-- PHP alike. Adding a constant per line preserves prettier's relative HTML
-- nesting while lifting the whole region by one level per open scope.
--
-- `depth_after[i]`  = open PHP scopes after segment i (the region that
--                     follows it);
-- `seg_level[i]`    = scopes at segment i's own line (shallowest point it
--                     reaches, so `<?php } ?>` lands on the outer level).
-- Placeholder lines are pre-indented here so splice_block (which uses the
-- placeholder line's indent as its base) drops the block at the right depth.
local function apply_scope_indent(html, depth_after, seg_level)
  local trailing_nl = html:match("\n$") ~= nil
  local body = trailing_nl and html:sub(1, -2) or html
  local lines = vim.split(body, "\n", { plain = true })

  -- Map each line to the placeholder IDs that sit on it.
  local function line_of(pos)
    local n = 1
    local i = body:find("\n", 1, true)
    while i and i < pos do
      n = n + 1
      i = body:find("\n", i + 1, true)
    end
    return n
  end
  local ids_by_line = {}
  local function note(m, is_block)
    local ln = line_of(m.s)
    local rec = ids_by_line[ln] or { ids = {}, block_id = nil }
    table.insert(rec.ids, m.id)
    if is_block and not rec.block_id then rec.block_id = m.id end
    ids_by_line[ln] = rec
  end
  for _, m in ipairs(find_block_placeholders(body)) do note(m, true) end
  for _, m in ipairs(find_inline_placeholders(body)) do note(m, false) end
  for _, m in ipairs(find_attr_placeholders(body)) do note(m, false) end

  local pure_block = "^<!--%s*" .. TOKEN .. "B%d+%s*-->$"
  local out = {}
  local last_id = 0
  for ln, line in ipairs(lines) do
    local rec = ids_by_line[ln]
    local d
    if rec and rec.block_id
      and line:match("^%s*(.-)%s*$"):match(pure_block) then
      d = seg_level[rec.block_id] or 0
    else
      d = depth_after[last_id] or 0
    end
    if line == "" then
      table.insert(out, line) -- keep empty lines empty (no trailing ws)
    else
      local cur = line:match("^[ \t]*")
      local rest = line:sub(#cur + 1)
      local pad = d > 0 and string.rep("  ", d) or ""
      table.insert(out, cur .. pad .. rest)
    end
    if rec then
      for _, id in ipairs(rec.ids) do
        if id > last_id then last_id = id end
      end
    end
  end

  local result = table.concat(out, "\n")
  if trailing_nl then result = result .. "\n" end
  return result
end

-- Splice a (multi-line) PHP block in place of its placeholder, re-indenting
-- it to the line's HTML context:
--   * placeholder alone on its line -> block indented at that line's base;
--   * placeholder mid-line (inside a tag or an attribute value) -> block
--     indented one level deeper, the first line glued to the opening
--     fragment when it ends in a quote/tag opener, and a closing quote
--     glued back onto the last line.
local function splice_block(html, m, php_text)
  local line_start = 1
  for i = m.s - 1, 1, -1 do
    if html:sub(i, i) == "\n" then
      line_start = i + 1
      break
    end
  end
  local line_end = #html
  local nl = html:find("\n", m.e + 1, true)
  if nl then line_end = nl - 1 end

  local pre = html:sub(line_start, m.s - 1)
  local post = html:sub(m.e + 1, line_end)
  local base = pre:match("^[ \t]*")
  local pre_sig = pre:match("%S") ~= nil
  local post_sig = post:match("%S") ~= nil
  local indent = (pre_sig or post_sig) and (base .. "  ") or base
  local pre_last = (pre:match("^(.-)%s*$") or ""):sub(-1)
  local post_first = post:match("^%s*(.)")
  local lines = vim.split(php_text, "\n")

  local out = {}
  local start_i = 1
  if pre_sig then
    local gluable = pre_last == '"' or pre_last == "'" or pre_last == ">"
    if gluable and lines[1] ~= nil then
      table.insert(out, pre .. lines[1])
      start_i = 2
    else
      table.insert(out, pre)
    end
  end

  for i = start_i, #lines do
    local l = lines[i]
    table.insert(out, l == "" and "" or indent .. l)
  end

  if post_sig then
    if post_first == '"' or post_first == "'" then
      -- closing quote of an attribute value: glue it to the last line
      local glued = post:match("^%s*") .. post:match("^%s*(.-)$")
      if #out > 0 and out[#out] ~= "" then
        out[#out] = out[#out] .. glued
      else
        table.insert(out, base .. post)
      end
    else
      table.insert(out, base .. post)
    end
  end

  if #out == 0 then
    return html:sub(1, line_start - 1) .. base .. php_text .. html:sub(line_end + 1)
  end

  return html:sub(1, line_start - 1) .. table.concat(out, "\n") .. html:sub(line_end + 1)
end

local function build_batch(block_map)
  -- Blocks must keep document order: loop guards (<?php if (...) { ?> /
  -- <?php } ?>) are only valid PHP together, so a shuffled batch fails to
  -- parse and pint skips the whole file.
  local ids = {}
  for id in pairs(block_map) do
    table.insert(ids, id)
  end
  table.sort(ids)
  local parts = {}
  for _, id in ipairs(ids) do
    local info = block_map[id]
    table.insert(parts,
      "<!-- @" .. TOKEN .. "B" .. id .. "@ -->\n"
      .. info.text
      .. "\n<!-- @END_" .. TOKEN .. "B" .. id .. "@ -->")
  end
  return table.concat(parts, "\n")
end

local function parse_batch(output, block_map)
  local formatted = {}
  for id in pairs(block_map) do
    local start_pat = "<!%-%-%s*@" .. TOKEN .. "B" .. id .. "@%s*%-%->"
    local end_pat = "<!%-%-%s*@END_" .. TOKEN .. "B" .. id .. "@%s*%-%->"
    local s, e = output:find(start_pat)
    local es = output:find(end_pat, e or 1)
    if s and es then
      local content = output:sub(e + 1, es - 1)
      content = content:gsub("^%s*\n", ""):gsub("\n%s*$", "")
      formatted[id] = content
    end
  end
  return formatted
end

----------------------------------------------------------------------
-- Main entry
----------------------------------------------------------------------

function M.format(config)
  config = vim.tbl_deep_extend("force", M.defaults, config or {})

  return function(_, ctx, lines, callback)
    log(config, "formatting " .. (ctx.filename or "<unknown>"))

    -- prettier is idempotent against its own output, but the
    -- mask → prettier → restore cycle can shift markup shapes (e.g. text
    -- next to a mangled closing tag) so a second run would reflow the
    -- first run's output. Iterate the whole pipeline to a fixed point
    -- (max MAX_PASSES) so a single conform invocation converges to the
    -- shape repeated invocations would produce. A pass that changes
    -- nothing is a fixed point by definition, so clean files cost one
    -- pass.
    local MAX_PASSES = 3

    local function one_pass(input_lines, cb)
    local content = table.concat(input_lines, "\n")
    TOKEN = choose_token(content)

    ------------------------------------------------------------------
    -- Mask PHP so prettier only ever sees opaque markers:
    --   * inline PHP (same line as a tag / attribute / text) -> opaque
    --     text token: prettier keeps it glued where it is, and it is
    --     restored verbatim — never re-indented, never sent to pint — so
    --     inline PHP keeps its exact shape.
    --   * block PHP (on its own line) -> HTML comment placeholder: atomic
    --     to prettier, block-level placement, and sent to pint.
    ------------------------------------------------------------------
    local segments = parse_segments(content)

    local seg_lines = {}
    for i, seg in ipairs(segments) do
      table.insert(seg_lines, string.format("[%d] %s: %p", i, seg.type, seg.text:sub(1, 60)))
    end
    stage_dump(config, "01_segments.txt", table.concat(seg_lines, "\n"))

    local states = segment_states(content, segments)
    local block_map = {}
    local inline_map = {}
    local attr_map = {}
    local masked = {}

    -- PHP scope depth per segment: depth_after[i] = open scopes after segment
    -- i (the level of the HTML region that follows it); seg_level[i] =
    -- shallowest level reached by the segment itself (the level of its own
    -- line; for `<?php } ?>` that is the outer level).
    local depth_after = {}
    local seg_level = {}
    local scope_depth = 0
    for i, seg in ipairs(segments) do
      if seg.type == "php" then
        local delta, min_running = brace_profile(seg.text)
        depth_after[i] = math.max(0, scope_depth + delta)
        seg_level[i] = math.max(0, scope_depth + min_running)
        scope_depth = scope_depth + delta
      end
    end

    for i, seg in ipairs(segments) do
      if seg.type == "php" then
        local kind = classify_segment(states, content, i, seg)
        if kind == "inline" then
          inline_map[i] = { text = seg.text }
          table.insert(masked, inline_placeholder(i))
        elseif kind == "attr" then
          attr_map[i] = { text = seg.text }
          table.insert(masked, attr_spaced(i, seg, content))
        else
          -- "block" or "attr_block": both go through pint.
          local is_attr = kind == "attr_block"
          block_map[i] = { text = dedent_block(seg.text), attr = is_attr }
          if is_attr then
            table.insert(masked, attr_spaced(i, seg, content))
          else
            table.insert(masked, block_placeholder(i))
          end
        end
      else
        table.insert(masked, seg.text)
      end
    end

    local html_input = balance_html(table.concat(masked, ""))
    stage_dump(config, "02_masked.html", html_input)

    local function dump_masked()
      local path = (vim.fn.tempname() or "/tmp") .. "_phphtml_masked.html"
      local fh = io.open(path, "w")
      if fh then
        fh:write(html_input)
        fh:close()
        return path
      end
      return nil
    end

    if config.debug then
      local p = dump_masked()
      if p then
        log(config, "masked html dumped to " .. p)
      end
    end

    local html_output, php_output = nil, nil
    local html_err, php_err = nil, nil
    local remaining = 0

    local function finish()
      if html_err then
        return cb(html_err)
      end
      if php_err then
        return cb(php_err)
      end

      stage_dump(config, "04_prettier_out.html", html_output)
      stage_dump(config, "05_pint_out.php", php_output or "")

      html_output = restore_virtual(html_output)

      if content:match("\n$") and not html_output:match("\n$") then
        html_output = html_output .. "\n"
      end

      ------------------------------------------------------------------
      -- PHP scope indent: prettier emits a clean baseline (HTML nesting
      -- only, top-level content at column 0). Re-apply the PHP control-flow
      -- scope depth additively to every line (HTML and PHP alike) so the
      -- relative HTML nesting is preserved and the region is lifted one
      -- level per open scope. Must run before block splicing so splice_block
      -- sees the corrected placeholder-line indent as its base.
      ------------------------------------------------------------------
      html_output = apply_scope_indent(html_output, depth_after, seg_level)

      local formatted_blocks = php_output and parse_batch(php_output, block_map) or {}

      ------------------------------------------------------------------
      -- restore block PHP, back-to-front so positions stay valid.
      -- The block was dedented to a zero baseline (anchor = first line);
      -- splice_block re-applies exactly the placeholder line's indent.
      ------------------------------------------------------------------
      local block_matches = find_block_placeholders(html_output)
      -- attr_block placeholders share the block map but use the attribute
      -- form; the block phase splices them in, so include them here.
      for _, m in ipairs(find_attr_placeholders(html_output)) do
        if block_map[m.id] then
          table.insert(block_matches, m)
        end
      end
      table.sort(block_matches, function(a, b)
        return a.s > b.s
      end)

      local restored_blocks = 0
      for _, m in ipairs(block_matches) do
        local info = block_map[m.id]
        if not info then
          return cb("restore failed: unknown block placeholder " .. m.id)
        end
        local formatted_php = dedent_block(formatted_blocks[m.id] or info.text)
        html_output = splice_block(html_output, m, formatted_php)
        restored_blocks = restored_blocks + 1
      end

      local block_count = 0
      for _ in pairs(block_map) do
        block_count = block_count + 1
      end
      if restored_blocks ~= block_count then
        return cb(string.format(
          "restore failed: %d/%d php blocks were placed — refusing to write partial output",
          restored_blocks, block_count
        ))
      end

      ------------------------------------------------------------------
      -- restore attribute-area PHP verbatim, back-to-front.
      ------------------------------------------------------------------
      local attr_matches = find_attr_placeholders(html_output)
      table.sort(attr_matches, function(a, b)
        return a.s > b.s
      end)

      local restored_attr = 0
      for _, m in ipairs(attr_matches) do
        local info = attr_map[m.id]
        if not info then
          return cb("restore failed: unknown attribute placeholder " .. m.id)
        end
        html_output = html_output:sub(1, m.s - 1) .. info.text .. html_output:sub(m.e + 1)
        restored_attr = restored_attr + 1
      end

      local attr_count = 0
      for _ in pairs(attr_map) do
        attr_count = attr_count + 1
      end
      if restored_attr ~= attr_count then
        return cb(string.format(
          "restore failed: %d/%d attribute php segments were placed — refusing to write partial output",
          restored_attr, attr_count
        ))
      end

      ------------------------------------------------------------------
      -- restore inline PHP verbatim, back-to-front.
      ------------------------------------------------------------------
      local inline_matches = find_inline_placeholders(html_output)
      table.sort(inline_matches, function(a, b)
        return a.s > b.s
      end)

      local restored_inline = 0
      for _, m in ipairs(inline_matches) do
        local info = inline_map[m.id]
        if not info then
          return cb("restore failed: unknown inline placeholder " .. m.id)
        end
        html_output = html_output:sub(1, m.s - 1) .. info.text .. html_output:sub(m.e + 1)
        restored_inline = restored_inline + 1
      end

      local inline_count = 0
      for _ in pairs(inline_map) do
        inline_count = inline_count + 1
      end
      if restored_inline ~= inline_count then
        return cb(string.format(
          "restore failed: %d/%d inline php segments were placed — refusing to write partial output",
          restored_inline, inline_count
        ))
      end

      ------------------------------------------------------------------
      -- integrity guards
      ------------------------------------------------------------------
      if html_output:find(TOKEN, 1, true) or html_output:find("phphtmlx", 1, true)
        or html_output:find("data-" .. string.lower(TOKEN) .. "=", 1, true) then
        return cb("restore failed: leftover placeholder in output — refusing to write")
      end

      if #content > 0 and html_output:gsub("%s", "") == "" then
        return cb("restore failed: output emptied — refusing to write")
      end

      stage_dump(config, "06_final.php", html_output)

      cb(nil, vim.split(html_output, "\n"))
    end

    local function try_finish()
      remaining = remaining - 1
      if remaining == 0 then
        finish()
      end
    end

    -- prettier on masked html (async)
    remaining = remaining + 1
    vim.system(
      vim.list_extend({ config.html.command }, config.html.args),
      { stdin = html_input },
      vim.schedule_wrap(function(obj)
        if obj.code ~= 0 then
          local dump = dump_masked()
          html_err = "prettier failed: " .. (obj.stderr or ("code " .. obj.code))
              .. (dump and (" (masked input: " .. dump .. ")") or "")
          log(config, html_err, vim.log.levels.ERROR)
        else
          html_output = obj.stdout
        end
        try_finish()
      end)
    )

    -- pint on batched php blocks (async, single invocation)
    if vim.tbl_isempty(block_map) then
      php_output = ""
    else
      local tmp = vim.fn.tempname() .. ".php"
      local fh = io.open(tmp, "w")
      if not fh then
        php_err = "could not create temp file"
        try_finish()
      else
        remaining = remaining + 1
        local batch = build_batch(block_map)
        stage_dump(config, "03_pint_batch.php", batch)
        fh:write(batch)
        fh:close()

        local cmd = { config.php.command }
        for _, arg in ipairs(config.php.args) do
          table.insert(cmd, arg == "$FILENAME" and tmp or arg)
        end

        vim.system(
          cmd,
          {},
          vim.schedule_wrap(function(obj)
            local fh2 = io.open(tmp, "r")
            if fh2 then
              php_output = fh2:read("*a")
              fh2:close()
            end
            os.remove(tmp)

            if obj.code ~= 0 then
              -- A non-zero exit (e.g. the template PHP is not valid on its
              -- own) means the file was left unformatted: report it instead
              -- of silently skipping every block.
              php_err = "pint failed: " .. (obj.stderr or ("code " .. obj.code))
              log(config, php_err, vim.log.levels.ERROR)
            end

            try_finish()
          end)
        )
      end
    end
    end

    ------------------------------------------------------------------
    -- Fixed-point driver
    ------------------------------------------------------------------
    local last_good = nil
    local function finish_ok(out_lines)
      callback(nil, out_lines)
    end

    local function run_pass(cur_lines, cur_text, pass)
      one_pass(cur_lines, function(err, out_lines)
        if not err and out_lines then
          last_good = out_lines
        end
        if err then
          if last_good and pass > 1 then
            log(config,
              string.format(
                "php_html: pass %d failed (%s); keeping pass %d output",
                pass,
                tostring(err),
                pass - 1
              ),
              vim.log.levels.WARN)
            return finish_ok(last_good)
          end
          return callback(err)
        end
        local out = table.concat(out_lines, "\n")
        if out == cur_text or pass >= MAX_PASSES then
          return finish_ok(out_lines)
        end
        return run_pass(out_lines, out, pass + 1)
      end)
    end

    run_pass(lines, table.concat(lines, "\n"), 1)
  end
end

return M

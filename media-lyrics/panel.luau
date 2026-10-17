--!nonstrict
-- media-lyrics panel: cover art with progress line, track info + transport,
-- karaoke lyric layer. Redesign v0.2 ("quiet premium"): one hero (the cover),
-- minimal chrome, type-driven hierarchy. Layout (2 bands):
--   A. chrome header:  NOW PLAYING ......... [reload] [close]   (11px ghost)
--   B. info row:       [cover 50 + progress 2.5] [title / artist - album] | transport+time
--   hairline separator
--   C. lyrics: karaoke carousel (synced) or clipped list (plain), flexGrow
--   D. footer: provider - mode label (11px, low-contrast)
--
-- Progress: verified live on this host build —
--   * no arc primitive exists, and VERTICAL progress bars do not render at
--     all, so the v0.1 8-segment perimeter ring and the per-edge bars were
--     dropped for a single horizontal seek control under the art. It is a
--     ui.slider, not a ui.progress: the host never hands a plugin the pointer
--     coordinates of a click, and ui.progress is display-only, so a slider is
--     the only way to make the bar seekable (the same control the shell's own
--     control-center media tab uses);
--   * ui.box cannot hold children (host drops them with warnings);
--   * labels centered by default: text with maxWidth inside a stretched
--     column loses left alignment -> infoCol hugs content, springer pushes
--     transport to the right edge.
--
-- The panel is a thin client: state comes from noctalia.state("media"),
-- commands go back over noctalia.state("panel_cmd").

-- ============================= design tokens =============================
-- One table, one place. Spacing on a 4px grid; colors are palette role tokens
-- with alpha so everything tracks the active Noctalia theme.

local T = {
  -- layout
  pad = 12,              -- root padding
  gapBand = 10,          -- between chrome / playerCard / lyrics / footer
  gapInline = 14,        -- cover <-> text
  gapMicro = 6,          -- inside groups

  -- cover
  cover = 64,            -- 64px prominent cover
  coverRadius = 14,      -- smooth cover radius

  -- typography
  fsOverline = 12,       -- chrome header
  fsTitle = 18,
  fsMeta = 13,
  fsTime = 11,
  fsActiveLyric = 18,
  fsNearLyric = 15,
  fsFarLyric = 14,
  fsCountdown = 44,

  -- colors (state colors live here too)
  colOverline = "on_surface_variant",
  colTitle = "on_surface",
  colMeta = "on_surface_variant",
  colTime = "on_surface_variant",
  ringTrack = "outline/0.25",     -- cover frame border
  lyricActive = "primary",
  lyricNear = "on_surface",
  lyricFar = "on_surface_variant",
  footer = "on_surface_variant",
  hairline = "outline/0.2",
  emptyState = "on_surface_variant",
}

local snap = nil       -- latest snapshot from the service
local cursorLine = 0   -- keyboard/scroll cursor over lyric lines (0 = follow playback)
local hoveredLine = 0  -- pointer hovered lyric line (0 = none); applied on the next render

-- Seek slider state (progress bar). While the user drags, the host owns the
-- thumb and re-applies `value` only when `!slider->dragging()`. Once released,
-- the target is held live in `seekPending` until playback actually reaches it,
-- so the bar neither snaps back while the service's D-Bus SetPosition is in
-- flight nor freezes when the snapshot arrives at the OLD position (a Firefox
-- MPRIS quirk: SetPosition resumes playback and reports the old position for a
-- moment). The same hold is applied to EVERY seek route - slider, lyric-line
-- click, keyboard cursor - so clicking a lyric line no longer leaves the bar
-- stuck. A seek the player never honoured expires after SEEK_HOLD_MS.
local SEEK_HOLD_MS = 15000
local seekPending = -1        -- seconds queued for seek, -1 = none
local seekQueuedAt = 0        -- ms of the request (0 = nothing pending)

local showCandidates = false -- "choose lyrics" selector open (toggled by the header button)
local marqueePaused = false -- pointer over the title/artist block pauses marquees
local lastTrackKey = "" -- track identity for cursor reset on track change
local lastSnapMs = 0
tickMarquee = nil      -- set by buildInfoRow; advances marquee clocks

local function nowMs()
  local ok, v = pcall(function() return noctalia.nowMs() end)
  if ok and type(v) == "number" then return v end
  return os.time() * 1000
end

local function interpPos(s)
  -- interpolate position between service polls for smooth lyrics
  if not s then return 0 end
  if not s.playing then return s.posSec or 0 end
  local elapsed = (lastSnapMs > 0) and ((nowMs() - lastSnapMs) / 1000) or 0
  local p = (s.posSec or 0) + elapsed
  if s.lengthSec and s.lengthSec > 0 and p > s.lengthSec then p = s.lengthSec end
  return p
end

local function fmtTime(sec)
  sec = tonumber(sec) or 0
  if sec < 0 then sec = 0 end
  local s = math.floor(sec)
  return math.floor(s / 60) .. ":" .. string.format("%02d", s % 60)
end

local glyphFor = {
  prev = "player-skip-back-filled",
  next = "player-skip-forward-filled",
  play = "player-play-filled",
  pause = "player-pause-filled",
}

local function sendCmd(action, extra)
  local cmd = { action = action }
  if extra then
    for k, v in pairs(extra) do cmd[k] = v end
  end
  noctalia.state.set("panel_cmd", cmd)
end

-- Single entry point for every seek (slider, lyric-line click, keyboard cursor):
-- remembers the target and marks it at once. MUST be defined after sendCmd and
-- nowMs - they are `local function`s, so a definition placed earlier would
-- capture them as nil globals and every seek would fail with
-- "attempt to call a nil value". The host is NOT guaranteed to re-run the
-- slider's onChange, so the caller must not rely on that callback to set the hold.
local function queueSeek(sec)
  sec = tonumber(sec)
  if not sec then return end
  seekPending = sec
  seekQueuedAt = nowMs()
  sendCmd("seekTo", { sec = sec })
end

-- marquee phase state lives at module scope: buildInfoRow runs on EVERY
-- render, and a per-render table would reset elapsed to 0 each tick.
local marqueeState = {}   -- [key] = { text, elapsed }

-- ============================= lyrics rendering =============================

-- (visibleLines lives below the width constants: it needs LYR_WIDTH, which - as
-- a `local` - must be declared before it, or it would resolve to a nil global.)

-- Header layout per panel preset. Spacing is uniform everywhere: the
-- cover-to-text gap, the text-to-transport gap and the header's own side
-- insets all use GAP_PX (12 px - the cover-to-text gap the owner standardised
-- on in the mini panel). The cover is ONE size in every preset: compact used to
-- run a 36 px cover while medium/large ran 50/56, which read as a bug ("только
-- в режиме compact обложка меньше чем во всех остальных"). The text column is
-- computed to take ALL the width left between the cover, the two gaps and the
-- transport block - no dead slot (a flexGrow spring used to swallow ~127 px
-- while the title was still truncated).
local GAP_PX = 12
local COVER_PX = 64
local function panelLayout()
  local sz = noctalia.getConfig("panel_size")
  if sz == "compact" then
    return { cover = COVER_PX, textW = 200, sliderW = 304, ctl = 15, main = 19 }
  elseif sz == "large" then
    return { cover = COVER_PX, textW = 400, sliderW = 504, ctl = 17, main = 22 }
  end
  return { cover = COVER_PX, textW = 280, sliderW = 384, ctl = 16, main = 20 }
end

-- (the karaoke window is symmetric around the anchor line; see buildLyricsBody)

-- Long lyric lines must not spill past the panel edge: a ui.label wider
-- than the panel is clipped at the surface edge (verified live — compact
-- 440 px panel cut ~47+ char lines mid-word). ui.label DOES render "\n"
-- (verified live), so long lines are soft-wrapped into sub-lines. Glyph
-- budget: advance factor 0.62 em measured live on this host at scale 1.5
-- (mixed-case text, incl. spaces); bold/medium run wider and get a bump.
-- Width per preset measured live: the panel surface itself (compact 440 /
-- medium 520 / large 640); wrapLyric subtracts WRAP_GUTTER (root padding plus
-- a small margin so a flush-fitting line breaks instead of touching the edge).
local LYR_WIDTH = { compact = 440, medium = 520, large = 640 }
-- Wrap safety gutter: covers root padding (24px) + row padding (28px) + safety margin (12px)
local WRAP_GUTTER = 64
local LYR_AREA_PX = { compact = 216, medium = 288, large = 396 }
local LYR_ROW_PX = 36
local function visibleLines()
  local sz = noctalia.getConfig("panel_size")
  return math.floor((LYR_AREA_PX[sz] or LYR_AREA_PX.medium) / LYR_ROW_PX)
end
-- Per-character advance widths in em, MEASURED live on this host (12-char runs
-- beside a 100 px reference bar, scale 1: i/l 0.27, m 0.92, w 0.79, a 0.56,
-- A 0.64, space 0.28). A flat per-character factor cannot work here: the
-- spread between the narrowest and widest glyph is 3.4x. The old count-based
-- budget (42 chars for an active fs17 line) rejected a 51-char line that
-- actually renders at ~333 px inside the 474 px content width, so lines that
-- fit were wrapped as soon as they became active. Bold runs ~5% wider.
local function toChars(text)
  local chars = {}
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    local len = 1
    if byte >= 0xF0 then len = 4 elseif byte >= 0xE0 then len = 3
    elseif byte >= 0xC0 then len = 2 end
    chars[#chars + 1] = text:sub(i, i + len - 1)
    i = i + len
  end
  return chars
end
local function charAdv(c)
  local o = string.byte(c) or 32
  if o >= 0x80 then return 1.0 end                      -- CJK / emoji: full width
  if c == " " then return 0.28 end
  if c == "i" or c == "l" or c == "I" then return 0.27 end
  if c == "m" then return 0.92 end
  if c == "w" or c == "M" or c == "W" then return 0.80 end
  if c == "." or c == "," or c == ":" or c == ";" or c == "'" or c == "!"
     or c == "|" or c == "`" then return 0.28 end
  if c == "(" or c == ")" or c == "[" or c == "]" or c == "{" or c == "}" then return 0.35 end
  if c == "j" or c == "t" or c == "f" or c == "r" then return 0.39 end
  if string.find("ABCDGHNOQRUVXY", c, 1, true) then return 0.64 end
  return 0.56
end
local function unitEm(text)
  local u = 0
  for _, ch in ipairs(toChars(text)) do u = u + charAdv(ch) end
  return u
end
local ADV_SPACE = 0.28

-- Split a lyric line into display sub-lines that fit the panel width, measured
-- in em (unitEm) against the per-size capacity, NOT in character counts.
-- Word-aware and BALANCED: a line needing exactly two sub-lines breaks near the
-- middle; longer lines fill whole chunks. A single word wider than the whole
-- line is hard-sliced (never splitting a UTF-8 sequence). Returns the original
-- string when it already fits. `reserved` shrinks the budget (cursor chevron).
local function wrapLyric(text, fontSize, fontWeight, reserved)
  if text == nil or text == "" then return text end
  local sz = noctalia.getConfig("panel_size") or "medium"
  local maxW = (LYR_WIDTH[sz] or LYR_WIDTH.medium) - WRAP_GUTTER - (reserved or 0)
  if maxW < 10 then maxW = 10 end
  local wf = (fontWeight == "bold" and 1.062) or (fontWeight == "medium" and 1.023) or 1.0
  local capEm = maxW / (fontSize * wf)          -- line capacity in em units
  local total = unitEm(text)
  if total <= capEm then return text end
  local words = {}
  for w in (text .. " "):gmatch("(.-) ") do
    words[#words + 1] = w
  end
  -- Balanced two-line break: both halves must fit, difference minimised.
  if #words >= 2 and total <= capEm * 2 then
    local wEm = {}
    for i = 1, #words do wEm[i] = unitEm(words[i]) end
    local best, bestScore, aEm = nil, math.huge, 0
    for i = 1, #words - 1 do
      aEm = aEm + wEm[i] + (i > 1 and ADV_SPACE or 0)
      local bEm = total - aEm - ADV_SPACE
      if aEm <= capEm and bEm <= capEm then
        local score = math.abs(aEm - bEm)
        if score < bestScore then best, bestScore = i, score end
      end
    end
    if best then
      local a, b = {}, {}
      for j = 1, best do a[#a + 1] = words[j] end
      for j = best + 1, #words do b[#b + 1] = words[j] end
      return table.concat(a, " ") .. "\n" .. table.concat(b, " ")
    end
  end
  -- Three-or-more (or an unbalanced leftover): greedy word fill.
  local out, cur, curEm = {}, "", 0
  for i = 1, #words do
    local w = words[i]
    local wEm = unitEm(w)
    if wEm > capEm then
      -- hard-slice by em, never splitting a UTF-8 sequence
      if cur ~= "" then out[#out + 1] = cur; cur, curEm = "", 0 end
      local acc, accEm = "", 0
      for _, ch in ipairs(toChars(w)) do
        local ce = charAdv(ch)
        if acc ~= "" and accEm + ce > capEm then
          out[#out + 1] = acc; acc, accEm = "", 0
        end
        acc = acc .. ch
        accEm = accEm + ce
      end
      cur, curEm = acc, accEm
    elseif cur == "" then
      cur, curEm = w, wEm
    elseif curEm + ADV_SPACE + wEm <= capEm then
      cur = cur .. " " .. w
      curEm = curEm + ADV_SPACE + wEm
    else
      out[#out + 1] = cur
      cur, curEm = w, wEm
    end
  end
  if cur ~= "" then out[#out + 1] = cur end
  return table.concat(out, "\n")
end

-- Countdown state for the karaoke lead-in: a 3-2-1 shown ONLY in the last three
-- seconds before the first line. The window is capped, not just the value: a
-- long intro must show NOTHING (a bare min(3, ceil(remaining)) would clamp 38 s
-- down to "3" and pin a stale digit to the panel for the whole intro). A track
-- whose first line starts within three seconds simply enters the window at its
-- real second (2 -> 1 -> line).
local function countdownValue(s)
  local lines = s.lyrics or {}
  local first = lines[1] and lines[1].time or -1
  if not (first and first > 0) then return 0 end
  local pos = interpPos(s)
  local remaining = first - pos
  if remaining <= 0 or remaining > 3 then return 0 end
  local active = -1
  for i = 1, #lines do
    if (lines[i].time >= 0) and (lines[i].time <= pos) then active = i end
    if (lines[i].time >= 0) and (lines[i].time > pos) then break end
  end
  if active >= 1 then return 0 end
  return math.ceil(remaining)
end

-- The countdown digit is placed INSIDE the empty lyric slots above the first
-- line (pre-start only): those slots merge into one box whose height matches
-- the slots it replaces, so the block never changes and the digit reads as
-- centred between the progress bar and the first line. A row with
-- align = "center" centres the label on the cross (vertical) axis - verified
-- live; the nested-flex variant did not.
local function countdownSlotHeight(halfSlots)
  -- exactly replaces the `halfSlots` empty slot cells the digit overwrites, so
  -- the pre-start block is the same height as the plain-spacer layout. Uses the
  -- same measured row pitch as SLOT_H - the old fs*1.25 estimate (27 px) no
  -- longer matches a real row (29 px) and left the box 2 px per slot short.
  return halfSlots * LYR_ROW_PX
end

local function buildLyricsBody(s)
  local lines = s.lyrics or {}
  local n = #lines

  if s.lyricsStatus == "loading" then
    return { ui.label({ text = noctalia.tr("panel.loading-lyrics"), color = T.colMeta,
      fontSize = T.fsFarLyric, fontWeight = "medium", textAlign = "center" }) }
  end
  if s.lyricsStatus == "choose" and showCandidates then
    -- Lyrics-variant selector: a "Default" row (restore the automatic chain
    -- result, shown when any default source actually loaded) followed by the
    -- LRCLIB search candidates. The active variant is highlighted; picking a
    -- row applies it WITHOUT clearing the list, so the user can switch again
    -- immediately. Each row is a button that sends chooseLyrics with the
    -- 1-based index (0 = Default).
    local cands = s.lyricsCandidates or {}
    local rows = {}
    local vi = s.lyricsVariantIndex or 0
    -- "Default" row: shown when there is something to restore — either the
    -- automatic chain lyrics are live right now (variantIndex == 0) or a
    -- picked variant is active (variantIndex > 0): "Default" re-runs the
    -- automatic chain for this track.
    local hasDefault = (vi == 0 and (s.lyricsProvider or "") ~= "" and #(s.lyrics or {}) > 0)
      or vi > 0
    if hasDefault then
      local defLabel = noctalia.tr("panel.variant-default")
        .. (vi == 0 and s.lyricsProvider ~= "" and (" (" .. s.lyricsProvider .. ")") or "")
      rows[#rows + 1] = ui.button({
        key = "candDef",
        text = defLabel,
        fontSize = T.fsFarLyric,
        color = T.lyricActive,
        fill = "surface_variant/0.4",
        radius = 8,
        padding = 6,
        onClick = function()
          showCandidates = false
          noctalia.state.set("panel_req", { action = "chooseLyrics", index = 0 })
        end,
      })
    end
    for i, c in ipairs(cands) do
      local label = (c.title or "") .. " — " .. (c.artist or "")
      if (c.album or "") ~= "" then label = label .. " (" .. c.album .. ")" end
      local isActive = (s.lyricsVariantIndex == i)
      rows[#rows + 1] = ui.button({
        key = "cand" .. i,
        text = (isActive and "● " or "") .. label,
        fontSize = T.fsFarLyric,
        color = isActive and T.lyricActive or T.colTitle,
        fill = "surface_variant/0.4",
        radius = 8,
        padding = 6,
        onClick = function()
          showCandidates = false
          noctalia.state.set("panel_req", { action = "chooseLyrics", index = i })
        end,
      })
    end
    if #rows == 0 then
      -- No default loaded and no candidates found (e.g. network down or a
      -- genuinely unknown track): say so instead of rendering an empty list.
      return { ui.label({ text = noctalia.tr("panel.no-variants"),
        color = T.emptyState, fontSize = T.fsFarLyric, textAlign = "center" }) }
    end
    return rows
  end
  if s.lyricsStatus == "error" then
    return { ui.label({ text = noctalia.tr("panel.lyrics-error") .. (s.lyricsError or ""),
      color = "error", fontSize = T.fsFarLyric, textAlign = "center" }) }
  end
  if (s.lyricsStatus == "choose" or s.lyricsStatus == "ready") and #(s.lyrics or {}) > 0 then
    -- ready, or "choose" with the picker closed (or a picked variant live):
    -- render the karaoke/plain lyrics that are actually loaded.
    if not s.synced then
      -- unsynced: static list inside a clipping scroll (a bare column does not
      -- clip its children), dimmed, generous line spacing. The
      -- keyboard cursor still highlights a line (no seek — no timestamps).
      local rows = {}
      for i, l in ipairs(lines) do
        local isCursor = (i == cursorLine)
        local rowChildren = {}
        if isCursor then
          rowChildren[#rowChildren + 1] = ui.glyph({
            key = "cur" .. i,
            name = "chevron-right",
            size = 12,
            color = T.lyricActive,
          })
          rowChildren[#rowChildren + 1] = ui.spacer({ width = 4 })
        end
        rowChildren[#rowChildren + 1] = ui.label({
          key = "lbl" .. i,
          text = wrapLyric(l.text, T.fsNearLyric, "normal", isCursor and 18 or 0),
          fontSize = T.fsNearLyric,
          color = isCursor and T.lyricActive or T.lyricNear,
          opacity = isCursor and 1 or 0.75,
          textAlign = "start",
        })
        rows[#rows + 1] = ui.row({
          key = "lyr" .. i,
          align = "center",
          justify = "start",
          paddingH = 14,
          paddingV = 6,
          radius = 10,
          fill = isCursor and "surface_variant/0.3" or nil,
        }, rowChildren)
        rows[#rows + 1] = ui.spacer({ key = "lgap" .. i, height = 4 })
      end
      -- The unsynced list is a FILLING body: it must own the whole lyrics area
      -- and scroll inside it. It must NOT be wrapped in the balanced flexGrow
      -- centering spacers (see render): those exist to centre the fixed-height
      -- karaoke block, and with a third flexGrow on the scroll the free height
      -- split three ways - the list ended up a third of the area with big gaps
      -- above and below it. The second return value tells render not to centre.
      return { ui.scroll({ flexGrow = 1, align = "stretch" }, rows) }, true
    end

    -- synchronized: carousel around the playback line (karaoke fade ladder)
  local pos = interpPos(s)
  local active = -1
  for i = 1, n do
    if (s.lyrics[i].time >= 0) and (s.lyrics[i].time <= pos) then active = i end
    if (s.lyrics[i].time >= 0) and (s.lyrics[i].time > pos) then break end
  end

  -- Lyric class per line: font size / weight from the karaoke distance
  -- ladder, precomputed ONCE so the window budget and the render loop share
  -- the same values (they must never drift apart).
  local fsArr, wArr = {}, {}
  for i = 1, n do
    local isA = (i == active)
    local isC = (i == cursorLine)
    local d = math.abs(i - active)
    fsArr[i] = isA and T.fsActiveLyric or (d <= 2 and T.fsNearLyric or T.fsFarLyric)
    wArr[i] = (isA or isC) and "bold" or (d <= 2 and "medium" or "normal")
  end
  -- Wrapped lines consume more than one visual row. The window must fit a
  -- VERTICAL BUDGET of visibleLines() rows, so count the wrapped sub-lines
  -- a row needs and shrink the window until its total fits (wrapping long
  -- lines must never push the active line below the panel edge).
  local function sublines(i)
    return 1 + select(2, wrapLyric(s.lyrics[i].text, fsArr[i], wArr[i], i == cursorLine and 18 or 0):gsub("\n", ""))
  end
  -- Karaoke centering: the anchor line (the cursor while the user scrolls,
  -- otherwise the playing line - and before playback starts the first line) is
  -- pinned to the exact vertical CENTRE of the lyrics area. The window always
  -- carries the same number of slots above and below the anchor and the parent
  -- column centres the block, so the anchor stays on the centre line on load,
  -- through the track, and at the end (the last line returns to the centre
  -- instead of sticking to the bottom edge). Out-of-range slots become spacers
  -- of the same height, which keeps the symmetry exact.
  local anchor = cursorLine >= 1 and cursorLine or (active >= 1 and active or 1)
  if anchor < 1 then anchor = 1 end
  if anchor > n then anchor = n end
  -- the "current" line is the playing one only: before the first line starts
  -- nothing is highlighted yet (the opening line lights up exactly at its
  -- timestamp, not earlier - owner: "первая строчка не должна подсвечиваться
  -- сразу а только в положенный ей момент").
  local hl = active
  local budget = visibleLines()
  local half = math.floor((budget - 1) / 2)
  local SLOT_H = 32
  -- shrink the side slots if wrapped sub-lines would overflow the area
  while half > 0 do
    local used = 0
    for k = -half, half do
      local idx = anchor + k
      if idx >= 1 and idx <= n then used = used + sublines(idx) end
    end
    if used <= budget then break end
    half = half - 1
  end
  local rows = {}
  local countdown = countdownValue(s)
  -- slots are a plain sequence (rows must be a dense array: negative keys are
  -- invisible to ipairs/#, which silently dropped the left half of the window)
  for si = 1, (2 * half + 1) do
    local k = si - 1 - half
    local idx = anchor + k
    if idx >= 1 and idx <= n then
      local isActive = (idx == hl)
      local isCursor = (idx == cursorLine)
      local isHover = (idx == hoveredLine)
      local dist = (active >= 1) and math.abs(idx - active) or math.abs(idx - 1)
      local fontSize = (idx == active) and T.fsActiveLyric or fsArr[idx]
      local fontWeight = (idx == hl) and "bold" or wArr[idx]
      local color
      local opacity
      local fill = nil

      if isActive then
        color = T.lyricActive
        opacity = 1.0
        fill = "primary/0.12"
      elseif isCursor then
        color = T.lyricActive
        opacity = 1.0
        fill = "surface_variant/0.3"
      elseif isHover then
        color = T.lyricActive
        opacity = 0.85
      else
        color = (dist <= 2) and T.lyricNear or T.lyricFar
        if dist == 1 then
          opacity = 0.65
        elseif dist == 2 then
          opacity = 0.45
        elseif dist == 3 then
          opacity = 0.28
        else
          opacity = 0.15
        end
      end

      local lineTime = s.lyrics[idx].time
      local children = {}
      if isCursor then
        children[#children + 1] = ui.glyph({
          key = "cur" .. idx,
          name = "chevron-right",
          size = 12,
          color = T.lyricActive,
        })
        children[#children + 1] = ui.spacer({ width = 4 })
      end
      children[#children + 1] = ui.label({
        key = "lbl" .. idx,
        text = wrapLyric(s.lyrics[idx].text, fontSize, fontWeight, isCursor and 18 or 0),
        fontSize = fontSize,
        fontWeight = fontWeight,
        color = color,
        opacity = opacity,
        textAlign = "start",
      })
      local rowProps = {
        key = "lyr" .. idx,
        align = "center",
        justify = "start",
        paddingH = 14,
        paddingV = 6,
        radius = 10,
        fill = fill,
        onClick = (lineTime >= 0) and function() queueSeek(lineTime) end or nil,
        tooltip = (lineTime >= 0)
          and (noctalia.tr("panel.seek-to") .. " " .. fmtTime(lineTime)) or nil,
      }
      rowProps.onHover = function(state)
        local want = (state == "true") and idx or 0
        if want ~= hoveredLine then hoveredLine = want end
      end
      rows[si] = ui.row(rowProps, children)
    elseif countdown > 0 and k >= -half and k <= -1 then
      -- pre-start: the empty slots above the first line merge into one box
      -- carrying the 3-2-1 digit, centred on the vertical axis by align. Only
      -- the topmost carries it; the rest collapse (no height, no gap) so the
      -- block's total height stays the same as with plain spacers.
      if k == -half then
        rows[si] = ui.row({
          key = "countdown", align = "center", justify = "center",
          height = countdownSlotHeight(half),
        }, {
          ui.label({
            key = "countdownLabel", text = tostring(countdown),
            fontSize = T.fsCountdown, fontWeight = "bold",
            color = T.lyricActive, opacity = 0.95, textAlign = "center",
          }),
        })
      else
        rows[si] = ui.spacer({ key = "gap" .. si, height = 0, visible = false })
      end
    else
      -- keep the symmetry: an empty slot is the same height as a text row, so
      -- the anchor line stays exactly on the centre line at the track's start
      -- and end (the block is centred by the parent column).
      rows[si] = ui.spacer({ key = "gap" .. si, height = SLOT_H })
    end
  end
  return rows
  end
  -- No lyrics after the whole chain (and the picker shows nothing else):
  return { ui.label({ text = noctalia.tr("panel.no-lyrics"), color = T.emptyState,
    fontSize = T.fsFarLyric, fontWeight = "medium", textAlign = "center" }) }
end

-- ============================= cover: art + progress =============================

local function buildCover(s, coverSize)
  local COVER = coverSize or T.cover
  if s.artUrl and s.artUrl ~= "" then
    return ui.image({
      key = "cover", path = s.artUrl, width = COVER, height = COVER,
      fit = "cover", radius = T.coverRadius,
      border = T.ringTrack, borderWidth = 1,
      onClick = function() sendCmd("toggle") end,
    })
  else
    return ui.column({
      key = "coverbox",
      width = COVER,
      height = COVER,
      fill = "surface_variant/0.5",
      border = "outline/0.25",
      borderWidth = 1,
      radius = T.coverRadius,
      align = "center",
      justify = "center",
      onClick = function() sendCmd("toggle") end,
    }, {
      ui.glyph({ name = "disc", size = math.max(28, COVER - 16), color = "on_surface_variant" }),
    })
  end
end

local function buildProgressBar(s, sliderW)
  local total = s.lengthSec or 0
  local cur = interpPos(s)
  local frac = (total > 0) and math.min(1, cur / total) or 0

  local seekMax = (total > 0) and total or 0.001
  local queued = tonumber(seekPending) or -1
  if queued >= 0 then
    local live = tonumber(s.posSec) or 0
    if math.abs(live - queued) <= 0.5 then
      seekPending = -1
      seekQueuedAt = 0
    elseif seekQueuedAt > 0 and (nowMs() - seekQueuedAt) > SEEK_HOLD_MS then
      seekPending = -1
      seekQueuedAt = 0
    else
      cur = queued
      frac = math.min(1, cur / seekMax)
    end
  end

  local painted = frac * seekMax
  local function onScrub(v)
    local sec = tonumber(v)
    if not sec then return end
    if math.abs(sec - painted) < 0.5 then return end
    queueSeek(sec)
  end

  return ui.slider({
    key = "seek",
    width = sliderW,
    min = 0, max = seekMax, step = 1,
    value = painted,
    enabled = (s.hasPlayer == true) and (total > 0),
    controlSize = "sm",
    onChange = onScrub,
    onDragEnd = function() seekQueuedAt = nowMs() end,
  })
end

-- ============================= player card =============================

local function buildPlayerCard(s, L)
  if not s.hasPlayer then
    return ui.column({
      key = "playerCardEmpty",
      fill = "surface_variant/0.25",
      border = "outline/0.15",
      borderWidth = 1,
      radius = 16,
      padding = 16,
      align = "center",
      justify = "center",
      height = 96,
    }, {
      ui.label({
        text = noctalia.tr("panel.no-media-player"),
        color = T.emptyState,
        fontSize = T.fsMeta,
      }),
    })
  end

  local cover = buildCover(s, L.cover)

  local function ctl(glyph, action, enabled, size, tip)
    return ui.button({
      glyph = glyph,
      glyphSize = size or L.ctl,
      variant = "ghost",
      controlSize = "sm",
      enabled = enabled ~= false,
      onClick = function() sendCmd(action) end,
      tooltip = tip,
    })
  end

  local mainGlyph = s.playing and glyphFor.pause or glyphFor.play
  local cur = interpPos(s)
  local total = s.lengthSec or 0

  local transportRow = ui.row({
    key = "transportRow",
    gap = 4,
    align = "center",
    justify = "end",
  }, {
    ctl(glyphFor.prev, "prev", s.canGoPrev ~= false, L.ctl, "Previous track"),
    ui.button({
      glyph = mainGlyph,
      glyphSize = L.main,
      variant = "primary",
      enabled = s.hasPlayer == true,
      onClick = function() sendCmd("toggle") end,
      controlSize = "sm",
      tooltip = s.playing and "Pause" or "Play",
    }),
    ctl(glyphFor.next, "next", s.canGoNext ~= false, L.ctl, "Next track"),
  })

  local TEXT_W = L.textW
  local MARQUEE_HOLD = 2
  local MARQUEE_SPEED = 24

  local function singleLine(text)
    text = tostring(text or ""):gsub("[\r\n\t]+", " ")
    text = text:gsub("  +", " ")
    return text
  end
  local artistLine = singleLine(s.artist ~= "" and s.artist or noctalia.tr("common.unknown-artist"))
  if s.album ~= "" then artistLine = artistLine .. " - " .. s.album end

  local function charUnits(char)
    return charAdv(char)
  end
  local function textUnits(text)
    local u = 0
    for _, ch in ipairs(toChars(text)) do u = u + charUnits(ch) end
    return u
  end
  local function vwUnits(fs)
    return TEXT_W / fs
  end
  local function shouldMarquee(text, fs)
    return textUnits(text) > vwUnits(fs)
  end

  local function marqueeSlice(chars, offset, fs)
    local out, used, i = {}, 0, 1
    local skip = math.floor(offset)
    local index = skip + 1
    while index <= #chars and used < vwUnits(fs) do
      local w = charUnits(chars[index])
      if used + w > vwUnits(fs) then break end
      out[#out + 1] = chars[index]
      used = used + w
      index = index + 1
    end
    return table.concat(out)
  end

  local function textLine(key, text, fs, weight, colr)
    local state = marqueeState[key]
    if state == nil or state.text ~= text then
      state = { text = text, elapsed = 0, phase = 0 }
      marqueeState[key] = state
    end
    local shown = text
    if shouldMarquee(text, fs) then
      local chars = toChars(text)
      local widths = {}
      for i, ch in ipairs(chars) do widths[i] = charUnits(ch) end
      local trailing = 0
      local units = 0
      for i = #chars, 1, -1 do
        local nu = units + widths[i]
        if nu > vwUnits(fs) then break end
        units = nu
        trailing = trailing + 1
      end
      local distance = math.max(0, #chars - math.max(1, trailing))
      if distance > 0 then
        local cellsPerSec = math.max(0.5, MARQUEE_SPEED / fs)
        local travel = distance / cellsPerSec
        local cycle = MARQUEE_HOLD * 2 + travel * 2
        local phase = state.elapsed % cycle
        local off
        if phase < MARQUEE_HOLD then off = 0
        else
          phase = phase - MARQUEE_HOLD
          if phase < travel then off = distance * (phase / travel)
          else
            phase = phase - travel
            if phase < MARQUEE_HOLD then off = distance
            else
              phase = phase - MARQUEE_HOLD
              off = distance * (1 - phase / travel)
            end
          end
        end
        shown = marqueeSlice(chars, math.floor(off), fs)
      end
    end
    return ui.label({
      key = key, text = shown, fontSize = fs, fontWeight = weight,
      color = colr, textAlign = "start", maxLines = 1, width = TEXT_W,
      height = math.floor(fs * 1.35 + 0.5),
    })
  end

  tickMarquee = function(deltaSec)
    if marqueePaused then return end
    for _, st in pairs(marqueeState) do st.elapsed = st.elapsed + deltaSec end
  end

  local infoCol = ui.column({
    key = "infoCol",
    gap = 4,
    align = "start",
    justify = "center",
    width = TEXT_W,
    onHover = function(state, key)
      local want = (state == "true")
      if want ~= marqueePaused then
        marqueePaused = want
      end
    end,
  }, {
    textLine("ttl", singleLine(s.title ~= "" and s.title or noctalia.tr("common.no-title")),
      T.fsTitle, "bold", T.colTitle),
    textLine("art", artistLine, T.fsMeta, "normal", T.colMeta),
  })

  local topRow = ui.row({
    key = "cardTopRow",
    align = "center",
    justify = "space_between",
  }, {
    ui.row({ align = "center", gap = 12 }, {
      cover,
      infoCol,
    }),
    transportRow,
  })

  local progressRow = ui.row({
    key = "cardProgressRow",
    align = "center",
    justify = "space_between",
  }, {
    ui.label({
      key = "timeCur",
      text = fmtTime(cur),
      fontSize = T.fsTime,
      color = T.colTime,
      width = 36,
      textAlign = "start",
    }),
    buildProgressBar(s, L.sliderW),
    ui.label({
      key = "timeTot",
      text = fmtTime(total),
      fontSize = T.fsTime,
      color = T.colTime,
      width = 36,
      textAlign = "end",
    }),
  })

  return ui.column({
    key = "playerCard",
    fill = "surface_variant/0.3",
    border = "outline/0.15",
    borderWidth = 1,
    radius = 16,
    padding = 12,
    gap = 10,
  }, {
    topRow,
    progressRow,
  })
end

-- ============================= render =============================

local function render()
  local s = snap or {
    hasPlayer = false, title = "", artist = "", album = "", artUrl = "",
    playing = false, lengthSec = 0, posSec = 0, lyrics = {},
    lyricsStatus = "loading", lyricsProvider = "", synced = false,
  }
  local L = panelLayout()
  local playerCard = buildPlayerCard(s, L)

  -- footer: provider + mode badge
  local footerTxt = ""
  if s.lyricsStatus == "ready" or ((s.lyricsStatus == "choose") and #(s.lyrics or {}) > 0) then
    footerTxt = (s.lyricsProvider ~= "" and s.lyricsProvider or "")
      .. (s.synced and (" - " .. noctalia.tr("panel.synced"))
        or (" - " .. noctalia.tr("panel.unsynced")))
  end

  panel.render(ui.column({ flexGrow = 1, padding = T.pad, gap = T.gapBand }, {
    -- A. chrome header: icon + title left, action buttons right
    ui.row({ key = "chrome", align = "center", justify = "space_between" }, {
      ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = "music", size = 14, color = T.lyricActive }),
        ui.label({
          text = noctalia.tr("panel.now-playing"),
          fontSize = T.fsOverline,
          fontWeight = "bold",
          color = T.colOverline,
        }),
      }),
      ui.row({ gap = 4, align = "center" }, {
        ui.button({
          glyph = "list", glyphSize = 14, variant = "ghost", controlSize = "sm",
          width = 24, height = 24,
          visible = s.hasPlayer == true and (s.title or "") ~= "",
          tooltip = noctalia.tr("panel.choose-lyrics"),
          onClick = function()
            showCandidates = not showCandidates
            if showCandidates then
              noctalia.state.set("panel_req", { action = "openLyricChoices" })
            end
            render()
          end,
        }),
        ui.button({
          glyph = "refresh", glyphSize = 14, variant = "ghost", controlSize = "sm",
          width = 24, height = 24,
          tooltip = noctalia.tr("panel.reload-lyrics"),
          onClick = function() noctalia.state.set("panel_req", { action = "reloadLyrics" }) end,
        }),
        ui.button({
          glyph = "close", glyphSize = 14, variant = "ghost", controlSize = "sm",
          width = 24, height = 24,
          onClick = function() panel.close() end,
        }),
      }),
    }),

    -- B. Player Card (Cover, Info, Controls, Progress + Timestamps)
    playerCard,

    -- C. lyrics (flexGrow with centering spacers)
    (function()
      local nodes, fills = buildLyricsBody(s)
      local kids = {}
      if not fills then kids[#kids + 1] = ui.spacer({ key = "lyricsTopFlex", flexGrow = 1 }) end
      for i = 1, #nodes do kids[#kids + 1] = nodes[i] end
      if not fills then kids[#kids + 1] = ui.spacer({ key = "lyricsBotFlex", flexGrow = 1 }) end
      return ui.column({ key = "lyrics", flexGrow = 1, gap = 4 }, kids)
    end)(),

    -- D. footer: provider + mode badge
    (function()
      if footerTxt == "" then
        return ui.spacer({ key = "footerEmpty", height = 0, visible = false })
      end
      return ui.row({ key = "footerRow", justify = "center", align = "center" }, {
        ui.row({
          key = "footerBadge",
          fill = "surface_variant/0.25",
          border = "outline/0.15",
          borderWidth = 1,
          radius = 12,
          paddingH = 10,
          paddingV = 4,
          align = "center",
          gap = 6,
        }, {
          ui.glyph({ name = s.synced and "sparkles" or "file-text", size = 11, color = T.footer }),
          ui.label({ text = footerTxt, fontSize = 11, fontWeight = "medium", color = T.footer }),
        }),
      })
    end)(),
  }))
end

-- ============================= state wiring =============================

-- VERIFIED BY PROBE (this host build): the host NEVER calls update() or
-- onFrameTick for [[panel]] entries — both counters stayed 0 with
-- setWantsSecondTicks(true) + setNeedsFrameTick(true). The ONLY periodic
-- signal a panel gets is the service's media publishes (POLL_MS = 150ms):
-- the service re-sets noctalia.state("media") on every poll, and watch()
-- fires per publish. So the marquee clock MUST tick inside the media watch,
-- using the wall-clock delta between publishes.
noctalia.state.watch("media", function(value)
  local now = nowMs()
  if lastSnapMs > 0 then
    local deltaSec = (now - lastSnapMs) / 1000
    -- clamp: a long gap (panel closed / track change pause) must not
    -- fast-forward the marquee
    if deltaSec > 0 and deltaSec < 2.0 then
      if tickMarquee then tickMarquee(deltaSec) end
    end
  end
  -- track changed: drop the lyric cursor so the panel follows playback again
  local key = (value.title or "") .. "|" .. (value.artist or "") .. "|" .. tostring(value.lengthSec or 0)
  if key ~= lastTrackKey then
    lastTrackKey = key
    cursorLine = 0
    hoveredLine = 0
    -- a new track invalidates the variant picker: close it and reset local
    -- open-state (the service drops its own list in invalidateLyrics()).
    showCandidates = false
  end
  snap = value
  lastSnapMs = nowMs()
  render()
end)

-- update() is never called by the host for panels in this build (verified
-- with a live counter probe). Kept as a harmless no-op so the entry stays
-- API-correct if a future build starts ticking panels.
function update()
end

-- Lyric cursor helpers. cursorLine is 1-based over s.lyrics; 0 = follow the
-- active playback line. moveCursor starts from the active line (or line 1
-- before the first timestamp — fixes the frozen window until the first
-- words), steps by delta and re-centers the window on the cursor.
local function activeIndex(s)
  local pos = interpPos(s)
  local active = -1
  local n = #(s.lyrics or {})
  for i = 1, n do
    if (s.lyrics[i].time >= 0) and (s.lyrics[i].time <= pos) then active = i end
    if (s.lyrics[i].time >= 0) and (s.lyrics[i].time > pos) then break end
  end
  return active
end

local function moveCursor(delta)
  local s = snap
  if not s or not s.lyrics or #s.lyrics == 0 then return end
  local n = #s.lyrics
  local cur = cursorLine
  if cur < 1 or cur > n then
    cur = activeIndex(s)
    if cur < 1 then cur = 1 end
  end
  cursorLine = math.max(1, math.min(n, cur + delta))
  hoveredLine = 0
  render()
end

-- Activate the line under the cursor: seek the player to its timestamp
-- (synced lyrics only — plain lines have no timestamps).
local function seekCursor()
  local s = snap
  if not s or not s.synced or not s.lyrics then
    cursorLine = 0
    render()
    return
  end
  local cur = cursorLine
  if cur < 1 or cur > #s.lyrics then
    cur = activeIndex(s)
    if cur < 1 then
      cursorLine = 0
      render()
      return
    end
  end
  local lineTime = s.lyrics[cur].time
  if lineTime >= 0 then
    queueSeek(lineTime)
  end
  cursorLine = 0
  render()
end

function onOpen(_context)
  cursorLine = 0
  -- second ticks keep position + lyrics moving between service polls
  panel.setWantsSecondTicks(true)
  noctalia.state.set("panel_req", { action = "refresh" })
  render()
end

-- Manual lyric scroll. The host's chord validator accepts only a small set
-- of key names (Up/Down/Left/Right/Return/Space/Escape/Tab — used by
-- community plugins); PageUp/PageDown/Home/End are REJECTED by the catalog
-- scan and drop the plugin from the store, so only Up/Down/Return/Space are
-- declared. Up/Down step the cursor, Return/Space seek to the cursor line.
-- The window never leaves [1..n] (clamped in buildLyricsBody).
function onKey(chord, pressed)
  if not pressed then return end
  if chord == "Up" then
    moveCursor(-1)
  elseif chord == "Down" then
    moveCursor(1)
  elseif chord == "Return" or chord == "Space" then
    seekCursor()
  end
end

-- Docs say onScroll is a bar-widget callback, but declare it anyway: if the
-- host delivers wheel events to panels, this makes wheel scrolling step the
-- lyric cursor. Harmless no-op otherwise.
function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or startsGesture then return end
  local dir = (steps or 0) > 0 and 1 or -1
  moveCursor(dir)
end
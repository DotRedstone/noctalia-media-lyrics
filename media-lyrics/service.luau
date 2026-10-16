--!nonstrict
-- media-lyrics service: streamlined MPRIS player sync with NetEase Song ID & local lyrics.

local POLL_MS = 200
local NETEASE_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
local NETEASE_REF = "https://music.163.com/"
local COVER_TMP_PATH = "/tmp/noctalia_current_cover.jpg"

local lyrics_lib = require("./lyrics_lib.luau")

-- ============================= Utility =============================

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function nowMs()
  local ok, v = pcall(function() return noctalia.nowMs() end)
  if ok and type(v) == "number" then return v end
  return os.time() * 1000
end

local function playerAllowed(ident, busName)
  local allow = trim(noctalia.getConfig("player_allowlist") or "")
  local block = trim(noctalia.getConfig("player_blocklist") or "")
  if allow == "" and block == "" then return true end
  local hay = (ident .. " " .. busName):lower()
  if allow ~= "" then
    local matched = false
    for part in allow:gmatch("[^,]+") do
      if hay:find(trim(part):lower(), 1, true) then matched = true break end
    end
    if not matched then return false end
  end
  if block ~= "" then
    for part in block:gmatch("[^,]+") do
      if hay:find(trim(part):lower(), 1, true) then return false end
    end
  end
  return true
end

-- ============================= State =============================

local snapshot = {
  hasPlayer = false,
  playerName = "",
  title = "",
  artist = "",
  album = "",
  artUrl = "",
  playing = false,
  canSeek = false,
  canGoNext = false,
  canGoPrev = false,
  shuffle = false,
  loopStatus = "None",
  lengthSec = 0,
  posSec = 0,
  posAtMs = 0,
  -- lyrics state
  lyricsStatus = "idle", -- idle | loading | ready | empty | error
  lyricsError = "",
  lyricsProvider = "",
  synced = false,
  lyrics = {}, -- { { time = sec, text = "..." } }
}

local currentTrackKey = ""
local fetchGeneration = 0

local function publish()
  noctalia.state.set("media", snapshot)
end

local function invalidateLyrics()
  snapshot.lyrics = {}
  snapshot.lyricsStatus = "idle"
  snapshot.lyricsProvider = ""
  snapshot.lyricsError = ""
  snapshot.synced = false
end

-- ============================= Local Lyrics & Cache =============================

local function cachePath(artist, title, songId)
  local dir = noctalia.pluginDataDir()
  if not dir or dir == "" then return nil end
  if songId and songId ~= "" then
    return dir .. "/lyrics/" .. songId .. ".lrc"
  end
  return dir .. "/lyrics/" .. lyrics_lib.sanitizePart(artist) .. "__" .. lyrics_lib.sanitizePart(title) .. ".lrc"
end

local function loadCachedLyrics(artist, title, songId)
  local path = cachePath(artist, title, songId)
  if not path then return nil end
  return noctalia.readFile(path)
end

local function cacheLyrics(artist, title, songId, lrcText)
  local path = cachePath(artist, title, songId)
  if not path or trim(lrcText) == "" then return end
  noctalia.writeFile(path, lrcText)
end

local function tryLocalLyrics(artist, title, songId)
  local dirs = {
    noctalia.expandPath("~/.lyrics"),
  }
  local dirCfg = noctalia.getConfig("local_lyrics_dir")
  if dirCfg and trim(dirCfg) ~= "" then
    dirs[#dirs + 1] = noctalia.expandPath(dirCfg)
  end

  local sArtist = lyrics_lib.sanitizePart(artist)
  local sTitle = lyrics_lib.sanitizePart(title)

  for _, dir in ipairs(dirs) do
    local candidates = {}
    if songId and songId ~= "" then
      candidates[#candidates + 1] = dir .. "/" .. songId .. ".lrc"
      candidates[#candidates + 1] = dir .. "/" .. songId .. ".tlrc"
    end
    if sArtist ~= "" and sTitle ~= "" then
      candidates[#candidates + 1] = dir .. "/" .. sArtist .. " - " .. sTitle .. ".lrc"
      candidates[#candidates + 1] = dir .. "/" .. sTitle .. " - " .. sArtist .. ".lrc"
      candidates[#candidates + 1] = dir .. "/" .. sArtist .. "（" .. sTitle .. "）.lrc"
    end
    if sTitle ~= "" then
      candidates[#candidates + 1] = dir .. "/" .. sTitle .. ".lrc"
    end

    for _, path in ipairs(candidates) do
      local raw = noctalia.readFile(path)
      if raw and trim(raw) ~= "" then
        return raw, "Local"
      end
    end
  end
  return nil
end

-- ============================= Lyrics Fetch & Processing =============================

local function httpGet(url, cb)
  local argv = {
    "curl", "-sSf", "-m", "5", "-4",
    "-H", "User-Agent: " .. NETEASE_UA,
    "-H", "Referer: " .. NETEASE_REF,
    url
  }
  noctalia.runAsync(argv, function(result)
    cb(result.exitCode == 0, result.stdout or "")
  end)
end

local function applyLyricsText(rawLrc, provider, key)
  if currentTrackKey ~= key then return end

  if not rawLrc or trim(rawLrc) == "" or lyrics_lib.isPlaceholderLyrics(rawLrc) then
    snapshot.lyrics = {}
    snapshot.lyricsStatus = "empty"
    snapshot.lyricsProvider = ""
    snapshot.lyricsError = ""
    snapshot.synced = false
    publish()
    return
  end

  local stripped = lyrics_lib.stripNetEaseMeta(rawLrc)
  local offsetMs = noctalia.getConfig("offset_ms") or 0
  local lines = lyrics_lib.parseLrc(stripped, offsetMs)

  snapshot.lyrics = lines
  snapshot.lyricsStatus = "ready"
  snapshot.lyricsProvider = provider
  snapshot.synced = lyrics_lib.lrcIsSynced(stripped)
  snapshot.lyricsError = ""
  publish()
end

local function fetchNetEaseById(songId, artist, title, key, gen)
  local url = "https://music.163.com/api/song/lyric?id=" .. tostring(songId) .. "&lv=1&kv=1&tv=-1"
  httpGet(url, function(ok, body)
    if gen ~= fetchGeneration or currentTrackKey ~= key then return end
    if not ok or body == "" then
      snapshot.lyricsStatus = "empty"
      publish()
      return
    end

    local okJson, data = pcall(function() return noctalia.json.decode(body) end)
    local lrc = (okJson and data and data.lrc and type(data.lrc.lyric) == "string") and data.lrc.lyric or ""

    if trim(lrc) ~= "" and not lyrics_lib.isPlaceholderLyrics(lrc) then
      cacheLyrics(artist, title, songId, lrc)
      applyLyricsText(lrc, "NetEase", key)
    else
      snapshot.lyricsStatus = "empty"
      publish()
    end
  end)
end

local function searchNetEaseAndFetch(artist, title, durSec, key, gen)
  local cleanTitle = lyrics_lib.cleanQueryTitle(title)
  local query = (artist ~= "" and (cleanTitle .. " " .. artist) or cleanTitle)
  local searchUrl = "https://music.163.com/api/cloudsearch/pc?s=" .. noctalia.string.urlEncode(query) .. "&type=1&offset=0&limit=5"

  httpGet(searchUrl, function(ok, body)
    if gen ~= fetchGeneration or currentTrackKey ~= key then return end
    if not ok or body == "" then
      snapshot.lyricsStatus = "empty"
      publish()
      return
    end

    local okJson, data = pcall(function() return noctalia.json.decode(body) end)
    local songs = (okJson and data and data.result and type(data.result.songs) == "table") and data.result.songs or {}
    local ranked = lyrics_lib.rankNetEaseSongs(songs, artist, title, durSec)

    if #ranked > 0 and ranked[1].id then
      fetchNetEaseById(ranked[1].id, artist, title, key, gen)
    else
      snapshot.lyricsStatus = "empty"
      publish()
    end
  end)
end

local function loadLyricsForTrack(artist, title, songId, durSec, key)
  fetchGeneration = fetchGeneration + 1
  local gen = fetchGeneration

  if trim(title) == "" then
    snapshot.lyricsStatus = "empty"
    publish()
    return
  end

  snapshot.lyricsStatus = "loading"
  publish()

  -- 1. Try local ~/.lyrics directory
  local localLrc, prov = tryLocalLyrics(artist, title, songId)
  if localLrc and not lyrics_lib.isPlaceholderLyrics(localLrc) then
    applyLyricsText(localLrc, prov, key)
    return
  end

  -- 2. Try plugin cache
  local cached = loadCachedLyrics(artist, title, songId)
  if cached and not lyrics_lib.isPlaceholderLyrics(cached) then
    applyLyricsText(cached, "Cache", key)
    return
  end

  -- 3. Exact NetEase Song ID direct fetch (100% accurate, no mismatch)
  if songId and songId ~= "" then
    fetchNetEaseById(songId, artist, title, key, gen)
    return
  end

  -- 4. NetEase search fallback
  searchNetEaseAndFetch(artist, title, durSec, key, gen)
end

-- ============================= MPRIS Player Handling =============================

local GET_ACTIVE = { "busctl", "--user", "--json=short", "call", "dev.noctalia.Mpris",
  "/dev/noctalia/Mpris", "dev.noctalia.Mpris", "GetActivePlayer" }

local GET_PLAYERS = { "busctl", "--user", "--json=short", "call", "dev.noctalia.Mpris",
  "/dev/noctalia/Mpris", "dev.noctalia.Mpris", "GetPlayers" }

local function parseBusctlVariant(v)
  if type(v) ~= "table" or v.type == nil then return nil end
  local t, d = v.type, v.data
  if t == "s" then return d end
  if t == "b" then return d == true end
  if t == "x" or t == "d" or t == "i" or t == "u" then return tonumber(d) end
  if t == "as" and type(d) == "table" then return table.concat(d, ", ") end
  return d
end

local function clearPlayer()
  if snapshot.hasPlayer or snapshot.title ~= "" then
    snapshot.hasPlayer = false
    snapshot.title, snapshot.artist, snapshot.album, snapshot.artUrl = "", "", "", ""
    snapshot.playing = false
    invalidateLyrics()
    publish()
  end
end

local lastCoverUrl = ""
local function syncCover(rawUrl)
  if not rawUrl or rawUrl == "" then
    snapshot.artUrl = ""
    return
  end

  if rawUrl:match("^https?://") then
    if rawUrl == lastCoverUrl and noctalia.fileExists(COVER_TMP_PATH) then
      snapshot.artUrl = COVER_TMP_PATH
      return
    end
    lastCoverUrl = rawUrl
    noctalia.runAsync({ "curl", "-sSf", "-m", "3", rawUrl, "-o", COVER_TMP_PATH }, function(res)
      if res.exitCode == 0 and noctalia.fileExists(COVER_TMP_PATH) then
        snapshot.artUrl = COVER_TMP_PATH
        publish()
      end
    end)
  else
    local localPath = rawUrl:gsub("^file://", "")
    snapshot.artUrl = localPath
  end
end

local function applyPlayer(f)
  local title = parseBusctlVariant(f.title) or ""
  local artist = parseBusctlVariant(f.artists) or ""
  local album = parseBusctlVariant(f.album) or ""
  local rawArtUrl = parseBusctlVariant(f.art_url) or ""
  local playing = (parseBusctlVariant(f.playback_status) == "Playing")
  local lengthUs = tonumber(parseBusctlVariant(f.length_us)) or 0
  local posUs = tonumber(parseBusctlVariant(f.position_us)) or 0
  local ident = parseBusctlVariant(f.identity) or parseBusctlVariant(f.bus_name) or ""
  local rawTrackId = tostring(parseBusctlVariant(f.track_id) or "")

  -- Extract exact Song ID from track_id (e.g. /org/mpd/Tracks/167691 -> 167691)
  local songId = rawTrackId:match("(%d+)")

  local key = ident .. "|" .. (songId or "") .. "|" .. title .. "|" .. artist .. "|" .. tostring(lengthUs)
  local trackChanged = (not snapshot.hasPlayer) or (currentTrackKey ~= key)

  snapshot.hasPlayer = true
  snapshot.playerName = ident
  snapshot.title = title
  snapshot.artist = artist
  snapshot.album = album
  snapshot.playing = playing
  snapshot.canSeek = parseBusctlVariant(f.can_seek) == true
  snapshot.canGoNext = parseBusctlVariant(f.can_go_next) == true
  snapshot.canGoPrev = parseBusctlVariant(f.can_go_previous) == true
  snapshot.shuffle = parseBusctlVariant(f.shuffle) == true
  snapshot.loopStatus = parseBusctlVariant(f.loop_status) or "None"
  snapshot.lengthSec = lengthUs / 1e6
  snapshot.posSec = posUs / 1e6
  snapshot.posAtMs = nowMs()

  syncCover(rawArtUrl)

  if trackChanged then
    currentTrackKey = key
    invalidateLyrics()
    publish()
    loadLyricsForTrack(artist, title, songId, snapshot.lengthSec, key)
  else
    publish()
  end
end

local refreshInFlight = false
local function refreshPlayer()
  if refreshInFlight then return end
  refreshInFlight = true

  noctalia.runAsync(GET_ACTIVE, function(res)
    refreshInFlight = false
    if res.exitCode ~= 0 then clearPlayer() return end

    local payload = noctalia.json.decode(res.stdout or "")
    if type(payload) ~= "table" or type(payload.data) ~= "table" then clearPlayer() return end

    local okFlag = payload.data[1]
    local f = payload.data[2]
    if okFlag ~= true or type(f) ~= "table" then clearPlayer() return end

    local ident = parseBusctlVariant(f.identity) or ""
    local busName = parseBusctlVariant(f.bus_name) or ""

    if not playerAllowed(ident, busName) then
      -- Fallback to first allowed player in GetPlayers
      noctalia.runAsync(GET_PLAYERS, function(res2)
        if res2.exitCode ~= 0 then clearPlayer() return end
        local p2 = noctalia.json.decode(res2.stdout or "")
        local list = p2 and p2.data and p2.data[1]
        if type(list) ~= "table" then clearPlayer() return end
        for _, p in ipairs(list) do
          local pIdent = parseBusctlVariant(p.identity) or ""
          local pBus = parseBusctlVariant(p.bus_name) or ""
          if playerAllowed(pIdent, pBus) then
            applyPlayer(p)
            return
          end
        end
        clearPlayer()
      end)
      return
    end

    applyPlayer(f)
  end)
end

-- ============================= Remote Commands =============================

local function busctlCall(method, argType, argValue)
  local argv = { "busctl", "--user", "call", "dev.noctalia.Mpris",
    "/dev/noctalia/Mpris", "dev.noctalia.Mpris", method }
  if argType and argValue ~= nil then
    argv[#argv + 1] = argType
    argv[#argv + 1] = tostring(argValue)
  end
  noctalia.runAsync(argv, function() end)
end

noctalia.state.watch("panel_cmd", function(value)
  if type(value) ~= "table" or value.action == nil then return end
  local a = value.action
  if a == "toggle" then
    busctlCall("PlayPauseActive")
  elseif a == "next" then
    busctlCall("NextActive")
  elseif a == "prev" then
    busctlCall("PreviousActive")
  elseif a == "shuffle" then
    busctlCall("SetShuffleActive", "b", tostring(not snapshot.shuffle))
  elseif a == "loop" then
    local order = { None = "Playlist", Playlist = "Track", Track = "None" }
    local nextLoop = order[snapshot.loopStatus] or "None"
    busctlCall("SetLoopStatusActive", "s", nextLoop)
  elseif a == "seekTo" then
    local sec = tonumber(value.sec)
    if sec then
      busctlCall("SetPositionActive", "x", math.floor(sec * 1e6 + 0.5))
    end
  end

  local gen = fetchGeneration
  noctalia.runAsync({ "sleep", "0.2" }, function()
    if gen == fetchGeneration then refreshPlayer() end
  end)
end)

noctalia.state.watch("panel_req", function(value)
  if type(value) ~= "table" then return end
  if value.action == "refresh" or value.action == "reloadLyrics" then
    currentTrackKey = ""
    refreshPlayer()
  end
end)

-- ============================= Lifecycle =============================

function onConfigChanged()
  currentTrackKey = ""
  refreshPlayer()
end

function onEnable()
  publish()
  refreshPlayer()
end

function update()
  refreshPlayer()
end

noctalia.setUpdateInterval(POLL_MS)
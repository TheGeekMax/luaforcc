-- jukebox.lua - Jukebox DFPWM pour CC:Tweaked
-- Moniteur : playlist a gauche (fichiers du dossier sounds), lecture en cours + controles a droite
-- Ordinateur : colle un lien vers un .dfpwm pour le telecharger dans le dossier sounds

---------------------------------------------------------------- CONFIG
local SOUND_DIR    = "/sounds"
local MONITOR_NAME = nil      -- nil = premier moniteur trouve, sinon ex: "monitor_3" ou "top"
local SPEAKER_NAME = nil      -- nil = premier speaker trouve
local TEXT_SCALE   = 0.5
local CHUNK        = 16 * 1024
local BYTES_PER_SEC = 6000    -- DFPWM : 48 kHz, 1 bit/echantillon
local DEFAULT_VOL  = 4        -- 0..10 (10 = volume max du speaker)

---------------------------------------------------------------- INIT
local dfpwm = require("cc.audio.dfpwm")

local mon = MONITOR_NAME and peripheral.wrap(MONITOR_NAME) or peripheral.find("monitor")
local speaker = SPEAKER_NAME and peripheral.wrap(SPEAKER_NAME) or peripheral.find("speaker")
assert(mon, "Aucun moniteur trouve")
assert(speaker, "Aucun speaker trouve")
local monName = peripheral.getName(mon)

if not fs.exists(SOUND_DIR) then fs.makeDir(SOUND_DIR) end
mon.setTextScale(TEXT_SCALE)
math.randomseed(os.epoch("utc"))

local state = {
  tracks = {},        -- { name, path, size }
  current = nil,      -- index dans tracks
  playing = false,
  paused = false,
  handle = nil,
  size = 0,
  pos = 0,
  decoder = nil,
  gen = 0,            -- incremente a chaque changement de piste / seek / stop
  repeatMode = "off", -- "off" | "all" | "one"
  shuffle = false,
  vol = DEFAULT_VOL,
  scroll = 0,
  listH = 1,
  message = nil,
}

local function redraw() os.queueEvent("jukebox_redraw") end
local function wake() os.queueEvent("jukebox_wake") end
local function volume() return state.vol * 0.3 end

---------------------------------------------------------------- PISTES
local function scanTracks()
  local curPath = state.current and state.tracks[state.current] and state.tracks[state.current].path
  local list = {}
  for _, f in ipairs(fs.list(SOUND_DIR)) do
    local p = fs.combine(SOUND_DIR, f)
    if not fs.isDir(p) and f:lower():match("%.dfpwm$") then
      list[#list + 1] = { name = f:gsub("%.[dD][fF][pP][wW][mM]$", ""), path = p, size = fs.getSize(p) }
    end
  end
  table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
  state.tracks = list
  state.current = nil
  for i, t in ipairs(list) do
    if t.path == curPath then state.current = i end
  end
  if curPath and not state.current and state.handle then
    -- la piste en cours a disparu : on garde la lecture mais plus d'index
  end
end

local function closeHandle()
  if state.handle then state.handle.close() end
  state.handle = nil
end

local function keepVisible()
  if not state.current then return end
  if state.current <= state.scroll then
    state.scroll = state.current - 1
  elseif state.current > state.scroll + state.listH then
    state.scroll = state.current - state.listH
  end
end

local function openTrack(i)
  local t = state.tracks[i]
  if not t then return end
  closeHandle()
  speaker.stopAudio()
  local h = fs.open(t.path, "rb")
  if not h then
    state.message = "Impossible d'ouvrir " .. t.name
    redraw()
    return
  end
  state.handle = h
  state.size = fs.getSize(t.path)
  state.pos = 0
  state.decoder = dfpwm.make_decoder()
  state.current = i
  state.playing = true
  state.paused = false
  state.gen = state.gen + 1
  keepVisible()
  wake()
  redraw()
end

local function stop()
  closeHandle()
  speaker.stopAudio()
  state.playing = false
  state.paused = false
  state.pos = 0
  state.gen = state.gen + 1
  redraw()
end

local function togglePause()
  if not state.handle then
    if state.current then openTrack(state.current)
    elseif #state.tracks > 0 then openTrack(1) end
    return
  end
  state.paused = not state.paused
  if state.paused then
    speaker.stopAudio()
  else
    state.decoder = dfpwm.make_decoder()
    wake()
  end
  redraw()
end

local function seek(frac)
  if not state.handle or state.size == 0 then return end
  local newPos = math.floor(math.max(0, math.min(1, frac)) * state.size)
  state.handle.seek("set", newPos)
  state.pos = newPos
  state.decoder = dfpwm.make_decoder()
  state.gen = state.gen + 1
  speaker.stopAudio()
  wake()
  redraw()
end

-- auto = true quand une piste se termine toute seule
local function nextIndex(dir, auto)
  local n = #state.tracks
  if n == 0 then return nil end
  if state.shuffle and n > 1 then
    local i
    repeat i = math.random(1, n) until i ~= state.current
    return i
  end
  local i = (state.current or 0) + dir
  if i > n then
    if auto and state.repeatMode ~= "all" then return nil end
    i = 1
  elseif i < 1 then
    i = n
  end
  return i
end

local function playNext(dir, auto)
  local i = nextIndex(dir, auto)
  if i then openTrack(i) else stop() end
end

local function prev()
  if state.handle and state.pos > 3 * BYTES_PER_SEC then
    openTrack(state.current)  -- plus de 3 s : on recommence la piste
  else
    playNext(-1, false)
  end
end

local function onTrackEnd()
  if state.repeatMode == "one" and state.current then
    openTrack(state.current)
  else
    playNext(1, true)
  end
end

---------------------------------------------------------------- AUDIO
local function interrupted(g)
  return state.gen ~= g or state.paused or not state.playing
end

local function audioLoop()
  while true do
    if state.playing and not state.paused and state.handle then
      local myGen = state.gen
      local startPos = state.pos
      local chunk = state.handle.read(CHUNK)

      if not chunk then
        -- fin du fichier : on laisse le tampon du speaker se vider
        local t = os.startTimer(3)
        while true do
          local ev, p = os.pullEvent()
          if interrupted(myGen) then break end
          if ev == "speaker_audio_empty" or (ev == "timer" and p == t) then
            onTrackEnd()
            break
          end
        end
      else
        state.pos = state.pos + #chunk
        local buf = state.decoder(chunk)
        local queued = false
        while true do
          if interrupted(myGen) then break end
          if speaker.playAudio(buf, volume()) then queued = true break end
          os.pullEvent() -- attend speaker_audio_empty (ou une commande)
        end
        -- mis en pause avant d'avoir envoye le morceau : on recule pour ne rien sauter
        if not queued and state.gen == myGen and state.handle and state.paused then
          state.handle.seek("set", startPos)
          state.pos = startPos
        end
      end
    else
      os.pullEvent("jukebox_wake")
    end
  end
end

---------------------------------------------------------------- AFFICHAGE
local buttons = {}

local function fmtTime(sec)
  sec = math.floor(sec)
  return string.format("%02d:%02d", math.floor(sec / 60), sec % 60)
end

local function fmtSize(b)
  if b >= 1024 * 1024 then return string.format("%.1f Mo", b / 1024 / 1024) end
  return string.format("%.0f Ko", b / 1024)
end

-- zone de texte d'une ligne, cliquable si action ~= nil
local function area(x, y, w, text, bg, fg, action, align)
  if w <= 0 then return end
  if #text > w then text = text:sub(1, w) end
  local pad = w - #text
  local l = (align == "left") and 0 or math.floor(pad / 2)
  mon.setBackgroundColor(bg)
  mon.setTextColor(fg)
  mon.setCursorPos(x, y)
  mon.write(string.rep(" ", l) .. text .. string.rep(" ", pad - l))
  if action then
    buttons[#buttons + 1] = { x1 = x, y1 = y, x2 = x + w - 1, y2 = y, action = action }
  end
end

local function draw()
  buttons = {}
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  ---------------- gauche : playlist
  local leftW = math.max(10, math.floor(w * 0.45))
  area(1, 1, leftW, " PLAYLIST (" .. #state.tracks .. ")", colors.blue, colors.white, nil, "left")

  state.listH = math.max(1, h - 2)
  local maxScroll = math.max(0, #state.tracks - state.listH)
  state.scroll = math.max(0, math.min(state.scroll, maxScroll))

  if #state.tracks == 0 then
    area(1, 3, leftW, " Aucun .dfpwm", colors.black, colors.gray, nil, "left")
    area(1, 4, leftW, " dans " .. SOUND_DIR, colors.black, colors.gray, nil, "left")
  end

  for row = 1, state.listH do
    local i = state.scroll + row
    local t = state.tracks[i]
    if t then
      local isCur = (i == state.current)
      local marker = " "
      if isCur and state.handle then marker = state.paused and "\149" or "\16" end
      local bg = isCur and colors.lightBlue or colors.black
      local fg = isCur and colors.black or colors.white
      area(1, row + 1, leftW, marker .. string.format("%2d ", i) .. t.name, bg, fg, function()
        if i == state.current and state.handle then togglePause() else openTrack(i) end
      end, "left")
    end
  end

  local half = math.floor(leftW / 2)
  area(1, h, half, "\30", colors.gray, colors.white, function()
    state.scroll = state.scroll - (state.listH - 1)
  end)
  area(half + 1, h, leftW - half, "\31", colors.gray, colors.white, function()
    state.scroll = state.scroll + (state.listH - 1)
  end)

  -- separateur
  mon.setBackgroundColor(colors.gray)
  for y = 1, h do
    mon.setCursorPos(leftW + 1, y)
    mon.write(" ")
  end

  ---------------- droite : en cours + outils
  local rx = leftW + 2
  local rw = w - rx + 1
  local gap = (h >= 22) and 1 or 0
  local y = 1

  area(rx, y, rw, " EN COURS", colors.blue, colors.white, nil, "left")
  y = y + 2

  local t = state.current and state.tracks[state.current]
  if t then
    area(rx, y, rw, t.name:sub(1, rw), colors.black, colors.yellow, nil, "left")
    area(rx, y + 1, rw, t.name:sub(rw + 1, rw * 2), colors.black, colors.yellow, nil, "left")
  else
    area(rx, y, rw, "Aucune piste", colors.black, colors.gray, nil, "left")
  end
  y = y + 2 + gap

  local status, sCol = "Arrete", colors.red
  if state.handle and state.paused then status, sCol = "En pause", colors.orange
  elseif state.handle then status, sCol = "Lecture", colors.lime end
  area(rx, y, rw, status, colors.black, sCol, nil, "left")
  y = y + 1

  local info = ""
  if t then info = "Piste " .. state.current .. "/" .. #state.tracks .. "  " .. fmtSize(t.size) end
  area(rx, y, rw, info, colors.black, colors.lightGray, nil, "left")
  y = y + 1

  local total = t and (t.size / BYTES_PER_SEC) or 0
  local elapsed = state.handle and (state.pos / BYTES_PER_SEC) or 0
  area(rx, y, rw, fmtTime(elapsed) .. " / " .. fmtTime(total), colors.black, colors.white, nil, "left")
  y = y + 1

  -- barre de progression (toucher = se deplacer dans la piste)
  local frac = (state.handle and state.size > 0) and (state.pos / state.size) or 0
  local filled = math.floor(rw * frac + 0.5)
  mon.setCursorPos(rx, y)
  mon.setBackgroundColor(colors.green)
  mon.write(string.rep(" ", filled))
  mon.setBackgroundColor(colors.gray)
  mon.write(string.rep(" ", rw - filled))
  local barY = y
  buttons[#buttons + 1] = { x1 = rx, y1 = barY, x2 = rx + rw - 1, y2 = barY, action = function(x)
    seek((x - rx) / math.max(1, rw - 1))
  end }
  y = y + 2 + gap

  -- transport
  local bw = math.floor((rw - 3) / 4)
  local playLabel = (state.handle and not state.paused) and "||" or "\16"
  area(rx,                y, bw, "|<",      colors.lightGray, colors.black, prev)
  area(rx + (bw + 1),     y, bw, playLabel, colors.green,     colors.white, togglePause)
  area(rx + (bw + 1) * 2, y, bw, "\143",    colors.red,       colors.white, stop)
  area(rx + (bw + 1) * 3, y, bw, ">|",      colors.lightGray, colors.black, function() playNext(1, false) end)
  y = y + 2 + gap

  -- repeat / shuffle
  local hw = math.floor((rw - 1) / 2)
  local repLabel = ({ off = "Repeat: Non", all = "Repeat: Tout", one = "Repeat: 1" })[state.repeatMode]
  area(rx, y, hw, repLabel, state.repeatMode == "off" and colors.gray or colors.green, colors.white, function()
    state.repeatMode = ({ off = "all", all = "one", one = "off" })[state.repeatMode]
  end)
  area(rx + hw + 1, y, rw - hw - 1, "Aleatoire", state.shuffle and colors.green or colors.gray, colors.white, function()
    state.shuffle = not state.shuffle
  end)
  y = y + 2 + gap

  -- volume
  local vb = math.max(3, math.floor(rw / 4))
  area(rx, y, vb, "-", colors.lightGray, colors.black, function() state.vol = math.max(0, state.vol - 1) end)
  area(rx + vb, y, rw - 2 * vb, "Vol " .. state.vol .. "/10", colors.black, colors.white)
  area(rx + rw - vb, y, vb, "+", colors.lightGray, colors.black, function() state.vol = math.min(10, state.vol + 1) end)
  y = y + 2 + gap

  area(rx, y, rw, "Rafraichir la liste", colors.gray, colors.white, function()
    scanTracks()
    state.message = #state.tracks .. " piste(s) trouvee(s)"
  end)

  if state.message then
    area(rx, h, rw, state.message, colors.black, colors.lightGray, nil, "left")
  end
end

local function handleTouch(x, y)
  for _, b in ipairs(buttons) do
    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
      b.action(x, y)
      return
    end
  end
end

local function uiLoop()
  draw()
  local timer = os.startTimer(0.5)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "monitor_touch" and a == monName then
      handleTouch(b, c)
      draw()
    elseif ev == "timer" and a == timer then
      draw()
      timer = os.startTimer(0.5)
    elseif ev == "jukebox_redraw" or ev == "monitor_resize" then
      draw()
    end
  end
end

---------------------------------------------------------------- TELECHARGEMENT (terminal)
local function normalizeUrl(url)
  -- lien GitHub "blob" -> lien raw
  local repo, path = url:match("^https?://github%.com/(.-)/blob/(.+)$")
  if repo then
    return "https://raw.githubusercontent.com/" .. repo .. "/" .. path
  end
  return url
end

local function defaultName(url)
  local last = url:gsub("[?#].*$", ""):match("([^/]+)$") or "musique"
  last = last:gsub("%.[dD][fF][pP][wW][mM]$", "")
  return last
end

local function sanitize(name)
  name = name:gsub("[^%w%-_ %.]", "_"):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then name = "musique" end
  return name
end

local function download(url, path)
  if not http then return false, "API http desactivee sur ce serveur" end
  local okUrl, why = http.checkURL(url)
  if not okUrl then return false, why end
  local res, err = http.get(url, nil, true)
  if not res then return false, err or "echec de la requete" end
  local data = res.readAll()
  res.close()
  if not data or #data == 0 then return false, "fichier vide" end
  local head = data:sub(1, 200):lower()
  if head:find("<!doctype") or head:find("<html") then
    return false, "le lien renvoie une page web, pas un .dfpwm (utilise le lien direct/raw)"
  end
  local f = fs.open(path, "wb")
  f.write(data)
  f.close()
  return true, #data
end

local function termLoop()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.yellow)
  print("=== JUKEBOX ===")
  term.setTextColor(colors.lightGray)
  print("Colle un lien vers un fichier .dfpwm")
  print("Entree vide = rien, 'q' = quitter")
  print()

  while true do
    term.setTextColor(colors.white)
    write("URL > ")
    local url = read()
    if url == "q" or url == "quit" then return end
    url = url:gsub("^%s+", ""):gsub("%s+$", "")

    if url ~= "" then
      url = normalizeUrl(url)
      local def = sanitize(defaultName(url))
      write("Nom [" .. def .. "] > ")
      local name = read()
      name = sanitize(name ~= "" and name or def)
      local path = fs.combine(SOUND_DIR, name .. ".dfpwm")

      local go = true
      if fs.exists(path) then
        write("Existe deja, remplacer ? (o/n) > ")
        go = read():lower():sub(1, 1) == "o"
      end

      if go then
        term.setTextColor(colors.lightGray)
        print("Telechargement...")
        local ok, res = download(url, path)
        if ok then
          term.setTextColor(colors.lime)
          print("OK : " .. name .. " (" .. fmtSize(res) .. ", " .. fmtTime(res / BYTES_PER_SEC) .. ")")
          scanTracks()
          state.message = "Ajoute : " .. name
          redraw()
        else
          term.setTextColor(colors.red)
          print("Erreur : " .. tostring(res))
        end
      end
      print()
    end
  end
end

---------------------------------------------------------------- MAIN
scanTracks()
parallel.waitForAny(audioLoop, uiLoop, termLoop)

speaker.stopAudio()
closeHandle()
mon.setBackgroundColor(colors.black)
mon.clear()
term.setTextColor(colors.white)
print("Jukebox arrete.")
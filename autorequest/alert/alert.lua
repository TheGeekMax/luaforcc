-- Stock Alarm : surveille le reseau AE2 (ME Bridge) et joue un son DFPWM
-- quand un item atteint son seuil. Config dans /stockalarm/.

local dfpwm = require("cc.audio.dfpwm")

local CFG_DIR     = "/stockalarm"
local GLOBAL_PATH = CFG_DIR .. "/global.cfg"
local ITEMS_PATH  = CFG_DIR .. "/items.cfg"
local STATE_PATH  = CFG_DIR .. "/state.dat"
local CRASH_PATH  = CFG_DIR .. "/crash.log"

local DEFAULT_GLOBAL = {
  sound = "",        -- chemin local (/sounds/x.dfpwm) ou URL https://...
  volume = 1.0,      -- 0.0 a 3.0
  interval = 5,      -- secondes entre deux scans
  textScale = 0.5,
  monitor = "",      -- nom du peripherique, vide = auto
  speaker = "",      -- nom du peripherique, vide = auto
}

local global, entries, state
local current = {}            -- key -> quantite au dernier scan
local status = { text = "", err = false }
local soundError = nil
local playing, stopRequested, alertLabel = false, false, nil
local buttons, page = {}, 1

---------------------------------------------------------------- fichiers

local function readTable(path)
  local p = path
  if not fs.exists(p) and fs.exists(path .. ".tmp") then p = path .. ".tmp" end
  if not fs.exists(p) then return nil end
  local h = fs.open(p, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  local t = textutils.unserialize(s)
  if type(t) ~= "table" then return nil end
  return t
end

local function writeTable(path, t)
  local tmp = path .. ".tmp"
  local h = fs.open(tmp, "w")
  h.write(textutils.serialize(t))
  h.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
end

local function keyOf(e) return (e.fluid and "F:" or "I:") .. e.name end

local function saveState() writeTable(STATE_PATH, state) end
local function saveEntries() writeTable(ITEMS_PATH, entries) end

local function loadAll()
  if not fs.exists(CFG_DIR) then fs.makeDir(CFG_DIR) end

  global = readTable(GLOBAL_PATH) or {}
  local added = not fs.exists(GLOBAL_PATH)
  for k, v in pairs(DEFAULT_GLOBAL) do
    if global[k] == nil then global[k] = v; added = true end
  end
  if added then writeTable(GLOBAL_PATH, global) end

  entries = {}
  for _, e in ipairs(readTable(ITEMS_PATH) or {}) do
    if type(e) == "table" and type(e.name) == "string" and type(e.target) == "number" then
      entries[#entries + 1] = { name = e.name, target = e.target, fluid = e.fluid and true or nil }
    end
  end
  if not fs.exists(ITEMS_PATH) then saveEntries() end

  state = readTable(STATE_PATH) or {}
  state.triggered = state.triggered or {}
  state.names = state.names or {}
end

---------------------------------------------------------------- peripheriques

local function getPeriph(cfgName, ptype)
  if cfgName and cfgName ~= "" then
    if peripheral.isPresent(cfgName) then return peripheral.wrap(cfgName) end
    return nil
  end
  return peripheral.find(ptype)
end

local function findBridge()
  return peripheral.find("meBridge") or peripheral.find("me_bridge")
end

local function safeList(bridge, ...)
  for _, fn in ipairs({ ... }) do
    if type(bridge[fn]) == "function" then
      local ok, res, err = pcall(bridge[fn])
      if not ok then return nil, tostring(res) end
      if type(res) ~= "table" then return nil, tostring(err or "reponse vide") end
      return res
    end
  end
  return {}
end

local function amountOf(it) return it.amount or it.count or 0 end

local function cleanName(dn)
  dn = tostring(dn or "")
  return (dn:gsub("^%[(.*)%]$", "%1"))
end

local function displayOf(e)
  local dn = state.names[keyOf(e)]
  if dn and dn ~= "" then return dn end
  return (e.name:gsub("^[^:]*:", ""))
end

---------------------------------------------------------------- scan

local function scanOnce()
  local bridge = findBridge()
  if not bridge then return false, "ME Bridge introuvable" end

  local items, err = safeList(bridge, "listItems")
  if not items then return false, "ME: " .. err end
  local fluids = safeList(bridge, "listFluid", "listFluids") or {}

  local stock = {}
  local function add(list, prefix)
    for _, it in ipairs(list) do
      if it.name then
        local k = prefix .. it.name
        stock[k] = (stock[k] or 0) + amountOf(it)
        if it.displayName then state.names[k] = cleanName(it.displayName) end
      end
    end
  end
  add(items, "I:")
  add(fluids, "F:")

  local changed, fired = false, {}
  for _, e in ipairs(entries) do
    local k = keyOf(e)
    local cur = stock[k] or 0
    current[k] = cur
    if cur >= e.target then
      if not state.triggered[k] then
        state.triggered[k] = true
        changed = true
        fired[#fired + 1] = displayOf(e)
      end
    elseif state.triggered[k] then
      state.triggered[k] = nil
      changed = true
    end
  end

  if changed then saveState() end
  if #fired > 0 then os.queueEvent("stockalarm_play", table.concat(fired, ", ")) end
  return true
end

---------------------------------------------------------------- affichage

local function put(mon, x, y, text, fg, bg)
  local w = mon.getSize()
  if x > w or text == "" then return end
  if x < 1 then text = text:sub(2 - x); x = 1 end
  text = text:sub(1, w - x + 1)
  mon.setCursorPos(x, y)
  if fg then mon.setTextColor(fg) end
  if bg then mon.setBackgroundColor(bg) end
  mon.write(text)
end

local function fill(mon, y, bg)
  local w = mon.getSize()
  put(mon, 1, y, (" "):rep(w), nil, bg)
end

local function fmt(n)
  if n >= 1e9 then return string.format("%.1fG", n / 1e9)
  elseif n >= 1e6 then return string.format("%.1fM", n / 1e6)
  elseif n >= 1e4 then return string.format("%.1fk", n / 1e3)
  end
  return tostring(math.floor(n))
end

local function stopSound()
  if playing then
    stopRequested = true
    os.queueEvent("speaker_audio_empty")
  end
end

local function draw()
  local mon = getPeriph(global.monitor, "monitor")
  if not mon then return end
  pcall(function()
    mon.setTextScale(global.textScale)
    local w, h = mon.getSize()
    buttons = {}
    mon.setBackgroundColor(colors.black)
    mon.clear()

    -- en-tete
    fill(mon, 1, colors.blue)
    put(mon, 2, 1, "STOCK ALARM", colors.white, colors.blue)
    local st, isErr = status.text, status.err
    if soundError then st, isErr = "Son: " .. soundError, true end
    put(mon, w - #st, 1, st, isErr and colors.yellow or colors.lightBlue, colors.blue)

    -- bandeau d'alerte
    local top = 3
    if playing then
      for y = 3, 5 do fill(mon, y, colors.red) end
      local bw = 10
      local bx = w - bw
      put(mon, 2, 4, ("\14 ALERTE : " .. (alertLabel or "")):sub(1, bx - 3), colors.white, colors.red)
      for y = 3, 5 do put(mon, bx, y, (" "):rep(bw), nil, colors.white) end
      put(mon, bx + 3, 4, "STOP", colors.red, colors.white)
      buttons[#buttons + 1] = { x1 = bx, x2 = bx + bw - 1, y1 = 3, y2 = 5, action = stopSound }
      top = 7
    end

    -- liste
    local perPage = math.max(1, math.floor((h - top) / 3))
    local pages = math.max(1, math.ceil(#entries / perPage))
    if page > pages then page = pages end

    if #entries == 0 then
      put(mon, 2, top, "Aucun item suivi.", colors.lightGray, colors.black)
      put(mon, 2, top + 1, "Ajoute-en depuis l'ordinateur.", colors.lightGray, colors.black)
    end

    local first = (page - 1) * perPage
    for i = 1, perPage do
      local e = entries[first + i]
      if not e then break end
      local k = keyOf(e)
      local y = top + (i - 1) * 3
      local cur = current[k]
      local reached = state.triggered[k]

      local right = (cur and fmt(cur) or "?") .. " / " .. fmt(e.target)
      local name = (e.fluid and "~ " or "") .. displayOf(e)
      local nameMax = w - #right - 4
      if #name > nameMax then name = name:sub(1, math.max(1, nameMax - 1)) .. "." end
      put(mon, 2, y, name, reached and colors.lime or colors.white, colors.black)
      put(mon, w - #right, y, right, reached and colors.lime or colors.lightGray, colors.black)

      local barW = w - 8
      local frac = cur and math.min(cur / e.target, 1) or 0
      local filled = math.floor(frac * barW + 0.5)
      put(mon, 2, y + 1, (" "):rep(filled), nil, reached and colors.lime or colors.orange)
      put(mon, 2 + filled, y + 1, (" "):rep(barW - filled), nil, colors.gray)
      local pct = math.floor(frac * 100) .. "%"
      put(mon, w - #pct, y + 1, pct, reached and colors.lime or colors.white, colors.black)
    end

    -- pied de page
    fill(mon, h, colors.gray)
    local nOk = 0
    for _, e in ipairs(entries) do if state.triggered[keyOf(e)] then nOk = nOk + 1 end end
    local mid = nOk .. "/" .. #entries .. " atteints"
    if pages > 1 then mid = mid .. "  -  page " .. page .. "/" .. pages end
    put(mon, math.floor((w - #mid) / 2) + 1, h, mid, colors.white, colors.gray)
    if pages > 1 then
      put(mon, 1, h, "  <<  ", colors.black, colors.lightGray)
      put(mon, w - 5, h, "  >>  ", colors.black, colors.lightGray)
      buttons[#buttons + 1] = { x1 = 1, x2 = 6, y1 = h, y2 = h,
        action = function() page = page > 1 and page - 1 or pages end }
      buttons[#buttons + 1] = { x1 = w - 5, x2 = w, y1 = h, y2 = h,
        action = function() page = page < pages and page + 1 or 1 end }
    end
  end)
end

---------------------------------------------------------------- son

local function playSound()
  local spk = getPeriph(global.speaker, "speaker")
  if not spk then return false, "pas de speaker" end
  local src = global.sound or ""
  if src == "" then return false, "aucun son configure" end

  local handle, err
  if src:match("^https?://") then
    if not http then return false, "HTTP desactive" end
    handle, err = http.get(src, nil, true)
    if not handle then return false, tostring(err) end
  else
    if not fs.exists(src) then return false, "fichier introuvable" end
    handle = fs.open(src, "rb")
    if not handle then return false, "lecture impossible" end
  end

  local decoder = dfpwm.make_decoder()
  playing, stopRequested = true, false
  draw()
  while not stopRequested do
    local chunk = handle.read(16 * 1024)
    if not chunk then break end
    local buffer = decoder(chunk)
    while not spk.playAudio(buffer, global.volume) do
      os.pullEvent("speaker_audio_empty")
      if stopRequested then break end
    end
  end
  handle.close()
  if stopRequested then pcall(spk.stop) end
  playing = false
  return true
end

local function audioLoop()
  while true do
    local _, label = os.pullEvent("stockalarm_play")
    alertLabel = label
    local ok, res, err = pcall(playSound)
    playing = false
    if not ok then soundError = tostring(res)
    elseif not res then soundError = err
    else soundError = nil end
    draw()
  end
end

---------------------------------------------------------------- boucles

local function scanLoop()
  local timer = os.startTimer(global.interval)
  while true do
    local ev, p = os.pullEvent()
    if (ev == "timer" and p == timer) or ev == "stockalarm_rescan" then
      local ok, err = scanOnce()
      if ok then status = { text = os.date("%H:%M:%S"), err = false }
      else status = { text = err, err = true } end
      draw()
      timer = os.startTimer(global.interval)
    end
  end
end

local function touchLoop()
  while true do
    local ev, _, x, y = os.pullEvent()
    if ev == "monitor_touch" then
      for _, b in ipairs(buttons) do
        if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
          b.action()
          break
        end
      end
      draw()
    elseif ev == "monitor_resize" or ev == "peripheral" or ev == "peripheral_detach" then
      draw()
    end
  end
end

---------------------------------------------------------------- terminal

local function prompt(label)
  write(label)
  return read()
end

local function askNumber(label)
  while true do
    local s = prompt(label)
    if s == "" then return nil end
    local n = tonumber(s)
    if n and n >= 0 then return math.floor(n) end
    print("Nombre invalide.")
  end
end

local function upsert(name, fluid, target, display)
  local k = keyOf({ name = name, fluid = fluid })
  if display then state.names[k] = display end
  state.triggered[k] = nil
  for _, e in ipairs(entries) do
    if keyOf(e) == k then
      e.target = target
      saveEntries(); saveState()
      return "modifie"
    end
  end
  entries[#entries + 1] = { name = name, fluid = fluid or nil, target = target }
  saveEntries(); saveState()
  return "ajoute"
end

local function searchNetwork(q)
  local bridge = findBridge()
  if not bridge then return nil, "ME Bridge introuvable" end
  q = q:lower()
  local results, seen = {}, {}
  local function scan(list, fluid)
    for _, it in ipairs(list or {}) do
      if it.name then
        local k = (fluid and "F:" or "I:") .. it.name
        local dn = cleanName(it.displayName or it.name)
        if not seen[k] and (it.name:lower():find(q, 1, true) or dn:lower():find(q, 1, true)) then
          seen[k] = true
          results[#results + 1] = { name = it.name, fluid = fluid, display = dn }
        end
      end
    end
  end
  scan((safeList(bridge, "listItems")), false)
  scan((safeList(bridge, "listCraftableItems")), false)
  scan((safeList(bridge, "listFluid", "listFluids")), true)
  scan((safeList(bridge, "listCraftableFluid", "listCraftableFluids")), true)
  table.sort(results, function(a, b) return a.display < b.display end)
  return results, nil, seen
end

local function addFlow()
  local q = prompt("Recherche (vide = annuler) : ")
  if q == "" then return end
  local res, err, seen = searchNetwork(q)
  if not res then print(err) end
  res, seen = res or {}, seen or {}

  local _, th = term.getSize()
  local max = math.max(1, th - 6)
  if #res == 0 then print("Aucun resultat dans le reseau.") end
  for i = 1, math.min(#res, max) do
    local r = res[i]
    print(("%2d. %s%s"):format(i, r.fluid and "[F] " or "", r.display))
  end
  if #res > max then print(("... %d de plus, affine la recherche"):format(#res - max)) end

  local c = prompt("Numero, [m] ID manuel, vide = annuler : ")
  local name, fluid, display
  if c == "m" then
    name = prompt("ID (modid:item) : ")
    if not name:find(":") then print("ID invalide."); sleep(1.5); return end
    fluid = prompt("Fluide ? (o/N) : "):lower() == "o"
    if not seen[(fluid and "F:" or "I:") .. name] then
      print("Inconnu du reseau pour l'instant, accepte quand meme.")
    end
  else
    local n = tonumber(c)
    local r = n and res[n]
    if not r then return end
    name, fluid, display = r.name, r.fluid, r.display
  end

  local t = askNumber("Seuil : ")
  if not t or t <= 0 then return end
  print("Item " .. upsert(name, fluid, t, display) .. ".")
  os.queueEvent("stockalarm_rescan")
  sleep(1)
end

local function editFlow()
  if #entries == 0 then print("Aucun item suivi."); sleep(1.5); return end
  local lines = {}
  for i, e in ipairs(entries) do
    lines[#lines + 1] = ("%2d. %s%s  (seuil %d)"):format(i, e.fluid and "[F] " or "", displayOf(e), e.target)
  end
  textutils.pagedPrint(table.concat(lines, "\n"))
  local n = tonumber(prompt("Numero (vide = annuler) : "))
  local e = n and entries[n]
  if not e then return end
  local t = askNumber("Nouveau seuil (0 = supprimer) : ")
  if not t then return end
  if t == 0 then
    local k = keyOf(e)
    table.remove(entries, n)
    state.triggered[k] = nil
    current[k] = nil
    saveEntries(); saveState()
    print("Supprime.")
  else
    upsert(e.name, e.fluid, t)
    print("Modifie.")
  end
  os.queueEvent("stockalarm_rescan")
  sleep(1)
end

local function termLoop()
  while true do
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.yellow)
    print("== Stock Alarm ==")
    term.setTextColor(colors.white)
    print(#entries .. " item(s) suivi(s)")
    print("")
    print("[a] ajouter     [e] modifier / supprimer")
    print("[t] tester son  [s] couper le son")
    print("")
    local c = prompt("> "):lower()
    if c == "a" then addFlow()
    elseif c == "e" then editFlow()
    elseif c == "t" then if not playing then os.queueEvent("stockalarm_play", "Test") end
    elseif c == "s" then stopSound()
    end
  end
end

---------------------------------------------------------------- main

local function main()
  loadAll()
  playing, stopRequested = false, false
  status = { text = "demarrage", err = false }
  draw()
  os.queueEvent("stockalarm_rescan")
  parallel.waitForAny(scanLoop, audioLoop, touchLoop, termLoop)
end

while true do
  local ok, err = pcall(main)
  if ok then break end
  if tostring(err):find("Terminated") then break end
  pcall(function()
    local h = fs.open(CRASH_PATH, "a")
    h.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(err))
    h.close()
  end)
  term.setTextColor(colors.red)
  print("Crash : " .. tostring(err))
  print("Redemarrage dans 5 s...")
  sleep(5)
end
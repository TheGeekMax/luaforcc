-- ae_mockup.lua
-- Maquette d'affichage de l'autocraft AE2 -- DONNEES FACTICES, aucun ME Bridge requis.
-- Materiel : 1 ordinateur + 1 moniteur avance (5x4 ou 6x5) a cote ou via modem.
-- Usage : ae_mockup [echelle]   (defaut 1 ; essaie 0.5 sur un 6x5 pour plus de place)
-- Ctrl+T pour quitter.

local args = { ... }
local SCALE = tonumber(args[1]) or 1

local mon = peripheral.find("monitor")
if not mon then error("Aucun moniteur trouve", 0) end
if not mon.isColor() then error("Il faut un moniteur AVANCE (couleur)", 0) end
mon.setTextScale(SCALE)
local MW, MH = mon.getSize()
local win = window.create(mon, 1, 1, MW, MH, false)

math.randomseed(os.epoch("utc"))

---------------------------------------------------------------------------
-- Config globale simulee (config.cfg dans la vraie version)
---------------------------------------------------------------------------
local cfg = { jour = 50, nuit = 90, batch = 64, timeout = 20 }
local state = { mode = "jour" }

-- 10 CPUs dont 2 en PLAYER_ONLY (exclus du calcul)
local cpus = {}
for i = 1, 10 do
  cpus[i] = { name = "CPU-" .. i, mode = (i > 8) and "PLAYER_ONLY" or "ANY", job = nil }
end

---------------------------------------------------------------------------
-- Items suivis simules (items.cfg dans la vraie version)
---------------------------------------------------------------------------
local items = {}
local function track(id, name, kind, min, alwaysFail)
  local stock = math.floor(min * (0.4 + math.random() * 0.9))
  if alwaysFail then stock = math.floor(min * 0.1) end
  items[#items + 1] = {
    id = id, name = name, kind = kind, min = min, stock = stock,
    state = "ok", fails = 0, amount = 0, alwaysFail = alwaysFail,
  }
end
track("gtceu:steel_ingot", "Steel Ingot", "item", 512)
track("gtceu:aluminium_ingot", "Aluminium Ingot", "item", 256)
track("gtceu:stainless_steel_plate", "Stainless Steel Plate", "item", 128)
track("gtceu:copper_single_wire", "1x Copper Wire", "item", 256)
track("gtceu:basic_electronic_circuit", "Basic Electronic Circuit", "item", 64)
track("gtceu:good_electronic_circuit", "Good Electronic Circuit", "item", 32)
track("gtceu:resistor", "Resistor", "item", 128)
track("gtceu:transistor", "Transistor", "item", 64)
track("gtceu:capacitor", "Capacitor", "item", 64)
track("gtceu:diode", "Diode", "item", 64)
track("gtceu:polyethylene_plate", "Polyethylene Sheet", "item", 128)
track("gtceu:steel_rod", "Steel Rod", "item", 128)
track("gtceu:steel_bolt", "Steel Bolt", "item", 256)
track("gtceu:naquadah_ingot", "Naquadah Ingot", "item", 64, true) -- echoue toujours -> SKIP
track("gtceu:lv_machine_hull", "LV Machine Hull", "item", 16)
track("gtceu:mv_machine_hull", "MV Machine Hull", "item", 8)
track("gtceu:nitrogen", "Nitrogen", "fluid", 64000)
track("gtceu:polyethylene", "Polyethylene", "fluid", 16000)
track("gtceu:sulfuric_acid", "Sulfuric Acid", "fluid", 32000)

-- Liste des craftables (getCraftableItems + getCraftableFluids dans la vraie version)
local craftables = {}
for _, it in ipairs(items) do
  craftables[#craftables + 1] = { id = it.id, name = it.name, kind = it.kind }
end
for _, e in ipairs({
  { "minecraft:iron_ingot", "Iron Ingot" }, { "gtceu:iron_plate", "Iron Plate" },
  { "gtceu:copper_plate", "Copper Plate" }, { "gtceu:tin_ingot", "Tin Ingot" },
  { "gtceu:bronze_ingot", "Bronze Ingot" }, { "gtceu:bronze_plate", "Bronze Plate" },
  { "gtceu:steel_plate", "Steel Plate" }, { "gtceu:steel_gear", "Steel Gear" },
  { "gtceu:steel_screw", "Steel Screw" }, { "gtceu:steel_frame", "Steel Frame Box" },
  { "gtceu:stainless_steel_ingot", "Stainless Steel Ingot" },
  { "gtceu:gold_single_wire", "1x Gold Wire" }, { "gtceu:tin_single_cable", "1x Tin Cable" },
  { "gtceu:lv_electric_motor", "LV Electric Motor" }, { "gtceu:lv_conveyor_module", "LV Conveyor Module" },
  { "gtceu:lv_robot_arm", "LV Robot Arm" }, { "gtceu:mv_electric_motor", "MV Electric Motor" },
  { "gtceu:silicon_wafer", "Silicon Wafer" }, { "gtceu:glass_tube", "Glass Tube" },
  { "gtceu:vacuum_tube", "Vacuum Tube" }, { "gtceu:rubber_sheet", "Rubber Sheet" },
}) do
  craftables[#craftables + 1] = { id = e[1], name = e[2], kind = "item" }
end
for _, e in ipairs({
  { "gtceu:oxygen", "Oxygen" }, { "gtceu:hydrogen", "Hydrogen" },
  { "gtceu:styrene_butadiene_rubber", "Styrene-Butadiene Rubber" },
}) do
  craftables[#craftables + 1] = { id = e[1], name = e[2], kind = "fluid" }
end
table.sort(craftables, function(a, b) return a.name < b.name end)

---------------------------------------------------------------------------
-- UI state
---------------------------------------------------------------------------
local ui = {
  tab = "suivi", pageSuivi = 1, pageRech = 1,
  query = "", edit = nil, editBuf = "",
  log = { "Demarrage (donnees factices)", colors.lightGray },
}
local function addLog(text, color) ui.log = { text, color or colors.lightGray } end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function fmt(n)
  if n >= 1e9 then return string.format("%.1fG", n / 1e9)
  elseif n >= 1e6 then return string.format("%.1fM", n / 1e6)
  elseif n >= 1e4 then return string.format("%.1fk", n / 1e3)
  else return tostring(math.floor(n)) end
end
local function amt(it, v)
  if it.kind == "fluid" then return fmt(math.floor(v / 1000)) .. "B" end
  return fmt(v)
end
local function fit(s, w)
  if w <= 0 then return "" end
  if #s > w then return s:sub(1, math.max(1, w - 1)) .. "." end
  return s .. string.rep(" ", w - #s)
end
local function at(x, y, text, fg, bg)
  win.setCursorPos(x, y)
  if bg then win.setBackgroundColor(bg) end
  if fg then win.setTextColor(fg) end
  win.write(text)
end
local function fill(x, y, w, bg)
  if w <= 0 then return end
  win.setCursorPos(x, y); win.setBackgroundColor(bg); win.write(string.rep(" ", w))
end
local function seq(x, y, parts, bg)
  for _, p in ipairs(parts) do at(x, y, p[1], p[2], bg or colors.black); x = x + #p[1] end
  return x
end

local buttons = {}
local function button(x, y, label, fg, bg, fn, x2, y2)
  at(x, y, label, fg, bg)
  buttons[#buttons + 1] = { x1 = x, y1 = y, x2 = x2 or (x + #label - 1), y2 = y2 or y, fn = fn }
end

local function findTracked(id)
  for i, it in ipairs(items) do if it.id == id then return it, i end end
end

---------------------------------------------------------------------------
-- Simulation (remplacee par le vrai ME Bridge plus tard)
---------------------------------------------------------------------------
local now, queue = 0, {}

local function eligibleCount()
  local n = 0
  for _, c in ipairs(cpus) do if c.mode ~= "PLAYER_ONLY" then n = n + 1 end end
  return n
end
local function capCount() return math.floor(eligibleCount() * cfg[state.mode] / 100) end
local function usedCount()
  local n = 0
  for _, c in ipairs(cpus) do if c.mode ~= "PLAYER_ONLY" and c.job then n = n + 1 end end
  return n
end
local function batchFor(it) return it.kind == "fluid" and cfg.batch * 1000 or cfg.batch end

local function step()
  now = now + 1
  -- consommation factice
  for _, it in ipairs(items) do
    if it.state ~= "skip" and math.random() < 0.3 then
      it.stock = math.max(0, it.stock - math.random(1, math.max(1, math.floor(it.min * 0.08))))
    end
  end
  -- fin des jobs
  for _, c in ipairs(cpus) do
    local j = c.job
    if j and now >= j.ends then
      c.job = nil
      if j.who == "auto" and findTracked(j.item.id) then
        local it = j.item
        if j.fail then
          it.fails = it.fails + 1
          if it.fails >= 3 then
            it.state = "skip"
            addLog("SKIP " .. it.name .. " (3 echecs) - toucher pour relancer", colors.red)
          else
            it.state = "file"; queue[#queue + 1] = it
            addLog("Echec " .. it.name .. " (" .. it.fails .. "/3), fin de file", colors.orange)
          end
        else
          it.stock = it.stock + j.amount; it.fails = 0; it.state = "ok"
          addLog("Termine : " .. amt(it, j.amount) .. " " .. it.name, colors.lime)
        end
      end
    end
  end
  -- crafts manuels simules (comptes dans le load)
  if math.random() < 0.04 then
    for _, c in ipairs(cpus) do
      if c.mode ~= "PLAYER_ONLY" and not c.job then
        c.job = { who = "manuel", ends = now + math.random(6, 15) }
        addLog("Craft manuel detecte sur " .. c.name, colors.orange)
        break
      end
    end
  end
  for _, c in ipairs(cpus) do
    if c.mode == "PLAYER_ONLY" and not c.job and math.random() < 0.05 then
      c.job = { who = "joueur", ends = now + math.random(5, 12) }
    end
  end
  -- producteur
  for _, it in ipairs(items) do
    if it.state == "ok" and it.stock < it.min then it.state = "file"; queue[#queue + 1] = it end
  end
  -- consommateur
  while #queue > 0 and usedCount() < capCount() do
    local it = table.remove(queue, 1)
    local missing = it.min - it.stock
    if missing <= 0 then
      it.state = "ok"
    else
      local b = batchFor(it)
      local amount = math.ceil(missing / b) * b
      for _, c in ipairs(cpus) do
        if c.mode ~= "PLAYER_ONLY" and not c.job then
          c.job = { who = "auto", item = it, amount = amount, ends = now + math.random(4, 12),
                    fail = it.alwaysFail or math.random() < 0.04 }
          it.state = "craft"; it.amount = amount
          addLog("Requete : " .. amt(it, amount) .. " " .. it.name, colors.lightBlue)
          break
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Dessin moniteur
---------------------------------------------------------------------------
local function drawHeader()
  fill(1, 1, MW, colors.gray)
  at(2, 1, "AE2 AUTOCRAFT", colors.white, colors.gray)
  local function tab(x, name, label)
    local on = ui.tab == name
    button(x, 1, label, on and colors.black or colors.lightGray, on and colors.white or colors.gray,
      function() ui.tab = name end)
    return x + #label + 1
  end
  local x = tab(16, "suivi", " SUIVI ")
  tab(x, "recherche", " RECHERCHE ")
  local jour = state.mode == "jour"
  local label = jour and (" JOUR " .. cfg.jour .. "% ") or (" NUIT " .. cfg.nuit .. "% ")
  button(MW - #label, 1, label, jour and colors.black or colors.white, jour and colors.yellow or colors.blue,
    function()
      state.mode = jour and "nuit" or "jour"
      addLog("Mode " .. state.mode:upper() .. " -> cap " .. capCount() .. "/" .. eligibleCount() .. " CPU",
        state.mode == "jour" and colors.yellow or colors.lightBlue)
    end)
end

local function drawCpu()
  local cap, elig, used = capCount(), eligibleCount(), usedCount()
  at(2, 3, "CPU", colors.white, colors.black)
  local x, k = 6, 0
  for _, c in ipairs(cpus) do
    if c.mode ~= "PLAYER_ONLY" then
      k = k + 1
      if c.job then
        fill(x, 3, 2, c.job.who == "auto" and colors.lime or colors.orange)
      elseif k <= cap then
        fill(x, 3, 2, colors.gray)
      else
        at(x, 3, "..", colors.gray, colors.black)
      end
      if k == cap then at(x + 2, 3, "|", colors.white, colors.black) end
      x = x + 3
    end
  end
  x = x + 1
  for _, c in ipairs(cpus) do
    if c.mode == "PLAYER_ONLY" then
      at(x, 3, "P ", colors.white, c.job and colors.purple or colors.magenta)
      x = x + 3
    end
  end
  local auto, man = 0, 0
  for _, c in ipairs(cpus) do
    if c.mode ~= "PLAYER_ONLY" and c.job then
      if c.job.who == "auto" then auto = auto + 1 else man = man + 1 end
    end
  end
  local nx = seq(2, 4, {
    { "Auto " .. auto, colors.lime }, { "  Manuel " .. man, colors.orange },
    { "  Cap " .. used .. "/" .. cap, colors.white },
    { " (" .. cfg[state.mode] .. "% de " .. elig .. ")", colors.lightGray },
  })
  if used > cap then at(nx + 1, 4, "ATTENTE", colors.red, colors.black) end
end

local function segBar(x, y, w, parts)
  local total = 0
  for _, p in ipairs(parts) do total = total + p[1] end
  if total == 0 then fill(x, y, w, colors.gray) return end
  local acc, pos = 0, x
  for _, p in ipairs(parts) do
    acc = acc + p[1]
    local e = x + math.floor(acc / total * w + 0.5)
    if e > pos then fill(pos, y, e - pos, p[2]); pos = e end
  end
end

local function drawItemsGauge()
  local ok, file, retry, craft, skip = 0, 0, 0, 0, 0
  for _, it in ipairs(items) do
    if it.state == "ok" then ok = ok + 1
    elseif it.state == "file" then if it.fails > 0 then retry = retry + 1 else file = file + 1 end
    elseif it.state == "craft" then craft = craft + 1
    elseif it.state == "skip" then skip = skip + 1 end
  end
  segBar(2, 6, MW - 2, {
    { ok, colors.lime }, { craft, colors.lightBlue }, { file, colors.yellow },
    { retry, colors.orange }, { skip, colors.red },
  })
  seq(2, 7, {
    { "OK " .. ok, colors.lime }, { "  Craft " .. craft, colors.lightBlue },
    { "  File " .. (file + retry), colors.yellow }, { "  Skip " .. skip, colors.red },
    { "   Batch " .. cfg.batch, colors.lightGray },
  })
end

local function stateLabel(it)
  if it.state == "ok" then return "OK", colors.lime
  elseif it.state == "file" then
    if it.fails > 0 then return "RETRY " .. it.fails .. "/3", colors.orange end
    return "EN FILE", colors.yellow
  elseif it.state == "craft" then return "CRAFT " .. amt(it, it.amount), colors.lightBlue
  else return "SKIP>TOUCH", colors.white end
end

local function pager(y, page, pages, setPage)
  button(2, y, " \17 ", colors.white, colors.gray, function() setPage(math.max(1, page - 1)) end)
  at(6, y, fit(page .. "/" .. pages, 5), colors.white, colors.black)
  button(11, y, " \16 ", colors.white, colors.gray, function() setPage(math.min(pages, page + 1)) end)
  at(15, y, fit(ui.log[1], MW - 15), ui.log[2], colors.black)
end

local function drawSuivi()
  drawCpu()
  drawItemsGauge()
  fill(1, 8, MW, colors.black)
  at(1, 8, string.rep("\140", MW), colors.gray, colors.black)

  local barW = math.max(6, math.floor(MW * 0.15))
  local numW, stW = 13, 10
  local nameW = MW - 2 - barW - numW - stW - 3
  local bx = 2 + nameW + 1
  local nx = bx + barW + 1
  local sx = nx + numW + 1
  at(2, 9, fit("ITEM", nameW), colors.gray, colors.black)
  at(bx, 9, "STOCK", colors.gray, colors.black)
  at(nx, 9, fit("    STOCK/MIN", numW), colors.gray, colors.black)
  at(sx, 9, "ETAT", colors.gray, colors.black)

  local top, bottom = 10, MH - 1
  local per = math.max(1, bottom - top + 1)
  local pages = math.max(1, math.ceil(#items / per))
  ui.pageSuivi = math.min(ui.pageSuivi, pages)
  local first = (ui.pageSuivi - 1) * per + 1
  for row = 0, per - 1 do
    local it = items[first + row]
    if not it then break end
    local y = top + row
    local rowBg = it.state == "skip" and colors.red or colors.black
    fill(1, y, MW, rowBg)
    local nm = (it.kind == "fluid" and "~" or "") .. it.name
    at(2, y, fit(nm, nameW), it.kind == "fluid" and colors.cyan or colors.white, rowBg)
    local frac = math.min(1, it.stock / it.min)
    local n = math.floor(frac * barW + 0.5)
    local bc = frac >= 1 and colors.lime or (frac >= 0.5 and colors.yellow or colors.red)
    if it.state == "skip" then bc = colors.white end
    fill(bx, y, barW, colors.gray)
    if n > 0 then fill(bx, y, n, bc) end
    local num = amt(it, it.stock) .. "/" .. amt(it, it.min)
    at(nx, y, string.rep(" ", math.max(0, numW - #num)) .. num, colors.lightGray, rowBg)
    local label, lc = stateLabel(it)
    at(sx, y, fit(label, stW), lc, rowBg)
    if it.state == "skip" then
      buttons[#buttons + 1] = { x1 = 1, y1 = y, x2 = MW, y2 = y, fn = function()
        it.state = "ok"; it.fails = 0
        addLog("Relance : " .. it.name, colors.yellow)
      end }
    end
  end
  pager(MH, ui.pageSuivi, pages, function(p) ui.pageSuivi = p end)
end

local function filtered()
  local q, res = ui.query:lower(), {}
  for _, e in ipairs(craftables) do
    if q == "" or e.name:lower():find(q, 1, true) then res[#res + 1] = e end
  end
  return res
end

local function drawRecherche()
  at(2, 3, "Recherche (clavier de l'ordinateur) :", colors.lightGray, colors.black)
  fill(2, 4, MW - 2, colors.gray)
  at(3, 4, fit(ui.query .. "_", MW - 4), colors.white, colors.gray)
  local res = filtered()
  local hint = ui.edit and "  > saisie du min sur l'ordinateur" or "  touchez pour suivre/modifier"
  seq(2, 5, { { #res .. " craftable(s)", colors.white }, { hint, ui.edit and colors.yellow or colors.gray } })
  at(1, 6, string.rep("\140", MW), colors.gray, colors.black)

  local colW = (MW >= 80) and math.floor((MW - 2) / 2) or (MW - 2)
  local ncols = math.max(1, math.floor((MW - 2) / colW))
  local top, bottom = 7, MH - 1
  local rows = math.max(1, bottom - top + 1)
  local per = rows * ncols
  local pages = math.max(1, math.ceil(#res / per))
  ui.pageRech = math.min(ui.pageRech, pages)
  local first = (ui.pageRech - 1) * per + 1
  for i = 0, per - 1 do
    local e = res[first + i]
    if not e then break end
    local col, row = math.floor(i / rows), i % rows
    local x, y = 2 + col * colW, top + row
    local tr = findTracked(e.id)
    local tag = tr and (" [suivi " .. amt(tr, tr.min) .. "]") or ""
    local sel = ui.edit and ui.edit.id == e.id
    local bg = sel and colors.white or colors.black
    local nm = (e.kind == "fluid" and "~" or "") .. e.name
    at(x, y, fit(nm, colW - 1 - #tag), sel and colors.black or (e.kind == "fluid" and colors.cyan or colors.white), bg)
    at(x + colW - 1 - #tag, y, tag, sel and colors.green or colors.lime, bg)
    buttons[#buttons + 1] = { x1 = x, y1 = y, x2 = x + colW - 2, y2 = y, fn = function()
      ui.edit = e
      if tr then
        ui.editBuf = tostring(e.kind == "fluid" and math.floor(tr.min / 1000) or tr.min)
      else
        ui.editBuf = ""
      end
    end }
  end
  pager(MH, ui.pageRech, pages, function(p) ui.pageRech = p end)
end

---------------------------------------------------------------------------
-- Dessin terminal de l'ordinateur
---------------------------------------------------------------------------
local function tc(c) if term.isColor() then term.setTextColor(c) end end
local function drawTerm()
  term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1)
  tc(colors.yellow); print("AE2 AUTOCRAFT - maquette (donnees factices)")
  tc(colors.gray); print(string.rep("-", ({ term.getSize() })[1]))
  if ui.edit then
    local e = ui.edit
    tc(colors.white); print("Item : " .. e.name)
    tc(colors.gray); print("ID   : " .. e.id)
    print("")
    tc(colors.white)
    term.write("Stock min" .. (e.kind == "fluid" and " (seaux)" or "") .. " : ")
    tc(colors.lime); term.write(ui.editBuf .. "_"); print("")
    print("")
    tc(colors.lightGray)
    print("Entree      = valider (ecrit dans items.cfg)")
    print("0 + Entree  = retirer du suivi")
    print("Vide+Entree = annuler")
  else
    tc(colors.white); term.write("Recherche : "); tc(colors.lime); term.write(ui.query .. "_"); print("")
    print("")
    tc(colors.lightGray)
    print("Tapez pour filtrer (nom affiche).")
    print("Backspace pour effacer.")
    print("Touchez un item sur le moniteur pour")
    print("l'ajouter ou modifier son stock min.")
    print("")
    tc(colors.gray); print("Ctrl+T pour quitter la maquette.")
  end
end

local function redraw()
  buttons = {}
  win.setVisible(false)
  win.setBackgroundColor(colors.black); win.clear()
  drawHeader()
  if ui.tab == "suivi" then drawSuivi() else drawRecherche() end
  win.setVisible(true)
  drawTerm()
end

local function commitEdit()
  local e = ui.edit
  if ui.editBuf == "" then ui.edit = nil; return end
  local n = tonumber(ui.editBuf) or 0
  local tr, idx = findTracked(e.id)
  if n == 0 then
    if tr then
      table.remove(items, idx)
      for i = #queue, 1, -1 do if queue[i] == tr then table.remove(queue, i) end end
      addLog("Retire du suivi : " .. e.name, colors.lightGray)
    end
  else
    local min = e.kind == "fluid" and n * 1000 or n
    if tr then
      tr.min = min
      addLog("Modifie : " .. e.name .. " min " .. amt(tr, min), colors.white)
    else
      items[#items + 1] = { id = e.id, name = e.name, kind = e.kind, min = min,
        stock = math.random(0, min), state = "ok", fails = 0, amount = 0 }
      addLog("Ajoute : " .. e.name .. " min " .. amt(items[#items], min), colors.lime)
    end
  end
  ui.edit = nil; ui.editBuf = ""
end

---------------------------------------------------------------------------
-- Boucle principale
---------------------------------------------------------------------------
local timer = os.startTimer(1)
redraw()
while true do
  local ev = { os.pullEvent() }
  local name = ev[1]
  if name == "timer" and ev[2] == timer then
    step()
    timer = os.startTimer(1)
  elseif name == "monitor_touch" then
    local x, y = ev[3], ev[4]
    for i = #buttons, 1, -1 do
      local b = buttons[i]
      if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then b.fn(); break end
    end
  elseif name == "char" then
    if ui.edit then
      if ev[2]:match("%d") and #ui.editBuf < 9 then ui.editBuf = ui.editBuf .. ev[2] end
    else
      ui.query = ui.query .. ev[2]; ui.tab = "recherche"; ui.pageRech = 1
    end
  elseif name == "key" then
    if ev[2] == keys.backspace then
      if ui.edit then ui.editBuf = ui.editBuf:sub(1, -2)
      else ui.query = ui.query:sub(1, -2); ui.pageRech = 1 end
    elseif ev[2] == keys.enter or ev[2] == keys.numPadEnter then
      if ui.edit then commitEdit() end
    end
  elseif name == "monitor_resize" then
    MW, MH = mon.getSize()
    win.reposition(1, 1, MW, MH)
  end
  redraw()
end
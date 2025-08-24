-- zirnox.lua — keep-the-UI version, host bugs fixed
-- OpenComputers 1.7.10 (OpenOS)
-- Reads Zirnox via per-field getters; toggle works; nil-safe; no flicker.

local component = require("component")
local event     = require("event")
local term      = require("term")
local gpu       = assert(component.gpu, "GPU required.")

-- ---------- small nil-safe helpers ----------
local function N(v) return tonumber(v) or 0 end
local function B(v) return v == true end

-- ---------- resolution & colors ----------
gpu.setResolution(60, 18)            -- same footprint you liked
local W, H = gpu.getResolution()

local PAD_X, PAD_Y = 2, 2
local COL = {
  title = 0x2D7DFA,
  text  = 0xFFFFFF,
  dim   = 0x9AA0A6,
  line  = 0x777777,
  bg    = 0x000000,
  band  = 0x202020,
  red   = 0xFF0000,
  blue  = 0x0000FF,
  teal  = 0x008080,
  green = 0x00FF00,
  bad   = 0xFF0000,
  orange= 0xFF4500,
  cyan  = 0x1E90FF,
}

-- ---------- drawing helpers (reset BG after fills to avoid highlight) ----------
local function put(x, y, s, fg, bg)
  if bg then gpu.setBackground(bg) end
  if fg then gpu.setForeground(fg) end
  gpu.set(x, y, s)
  if bg then gpu.setBackground(COL.bg) end
end

local function fill(x, y, w, h, ch, bg)
  if bg then gpu.setBackground(bg) end
  gpu.fill(x, y, w, h, ch or " ")
  if bg then gpu.setBackground(COL.bg) end
end

local function clearAll()
  gpu.setBackground(COL.bg)
  gpu.setForeground(COL.text)
  term.clear()
  term.setCursor(1,1)
end

local function drawBar(x, y, w, pct, color)
  pct = math.max(0, math.min(100, N(pct)))
  local fillW = math.floor(w * pct / 100)
  fill(x, y, w, 1, " ", COL.band)
  if fillW > 0 then
    gpu.setBackground(color or COL.cyan)
    gpu.fill(x, y, fillW, 1, " ")
    gpu.setBackground(COL.bg)
  end
end

-- ---------- title / frame / buttons (your UI) ----------
local function drawTitle(role, addrStr)
  gpu.setBackground(COL.title); gpu.setForeground(COL.text)
  gpu.fill(1, 1, W, 1, " ")
  put(3, 1, "ZIRNOX REACTOR • "..role..(addrStr and (" • "..addrStr) or ""), COL.text, COL.title)
  gpu.setBackground(COL.bg); gpu.setForeground(COL.text)
end

local function drawFrame()
  gpu.setForeground(COL.line)
  for x = PAD_X, W - PAD_X do put(x, PAD_Y + 1, "─") end
  for y = PAD_Y + 2, H - 4 do
    put(PAD_X, y, "│")
    put(W - PAD_X, y, "│")
  end
  put(PAD_X, H - 3, "├" .. string.rep("─", W - 2*PAD_X - 2) .. "┤")
  for x = PAD_X + 1, W - PAD_X - 1 do put(x, H - 1, "─") end
  gpu.setForeground(COL.text)
end

local function layoutButtons()
  local toggleLabel = "[ Toggle Reactor ]"
  local exitLabel   = "[ X ]"
  local y = H - 2
  local toggleX = PAD_X + 2
  local exitX   = W - PAD_X - #exitLabel
  return y, toggleX, #toggleLabel, toggleLabel, exitX, #exitLabel, exitLabel
end

local function drawButtons()
  local y, tx, tw, tlbl, ex, ew, elbl = layoutButtons()
  put(tx - 1, y - 1, "┌" .. string.rep("─", tw) .. "┐", COL.text)
  put(tx - 1, y,     "│" .. tlbl .. "│",           COL.text)
  put(tx - 1, y + 1, "└" .. string.rep("─", tw) .. "┘", COL.text)

  put(ex - 1, y - 1, "┌" .. string.rep("─", ew) .. "┐", COL.text)
  put(ex - 1, y,     "│" .. elbl .. "│",           COL.text)
  put(ex - 1, y + 1, "└" .. string.rep("─", ew) .. "┘", COL.text)
end

-- ---------- detect reactor (host) ----------
local reactor, reactorAddr
for addr, t in component.list() do
  if t == "zirnox_reactor" then
    reactor = component.proxy(addr)
    reactorAddr = addr
    break
  end
end

-- ---------- robust reads using official getters with fallback ----------
local function readZirnox()
  if not reactor then
    return 0,0,0,0,0,false,"no reactor component found"
  end

  -- Preferred: per-field getters (per wiki)
  local okT, temp = pcall(reactor.getTemp)
  local okP, pres = pcall(reactor.getPressure)
  local okW, wat  = pcall(reactor.getWater)
  local okC, co2  = pcall(reactor.getCarbonDioxide)
  local okS, stm  = pcall(reactor.getSteam)
  local okA, act  = pcall(reactor.isActive)

  if okT and okP and okW and okC and okS and okA then
    return N(temp), N(pres), N(wat), N(co2), N(stm), B(act), nil
  end

  -- Fallback: getInfo() — handle table or multi-returns
  local okI, i1, i2, i3, i4, i5, i6 = pcall(reactor.getInfo)
  if okI then
    if type(i1) == "table" then
      local t = i1
      return N(t[1] or t.temp), N(t[2] or t.pressure), N(t[3] or t.water),
             N(t[4] or t.co2 or t.carbon or t["carbon dioxide"]),
             N(t[5] or t.steam), B(t[6] or t.active), nil
    else
      return N(i1), N(i2), N(i3), N(i4), N(i5), B(i6), nil
    end
  end

  return 0,0,0,0,0,false,"no getters/getInfo available"
end

local function setActive(on)
  if not reactor or not reactor.setActive then return "no reactor/setActive" end
  local ok, err = pcall(reactor.setActive, on and true or false)
  if not ok then return tostring(err) end
  return nil
end

-- ---------- stats drawing (same look) ----------
local lastDiag = "-"
local function drawStats()
  local temp, pres, water, co2, steam, active, err = readZirnox()
  if err then lastDiag = err end

  local x0, y0 = PAD_X, PAD_Y + 3
  local barW   = W - 2 * PAD_X

  -- temperature row
  gpu.setForeground(COL.red);   put(x0, y0 + 0, "Temp:")
  gpu.setForeground(COL.text);  put(x0 + 7, y0 + 0, string.format("%7.2f °C", temp))
  drawBar(x0, y0 + 1, barW, math.min(100, (temp / math.max(1,temp,800))*100), COL.orange)

  -- pressure row
  gpu.setForeground(COL.blue);  put(x0, y0 + 3, "Pres:")
  gpu.setForeground(COL.text);  put(x0 + 7, y0 + 3, string.format("%7.2f BAR", pres))
  drawBar(x0, y0 + 4, barW, math.min(100, (pres / math.max(1,pres,30))*100), COL.cyan)

  -- water/steam/co2
  gpu.setForeground(COL.teal);  put(x0, y0 + 6, "Water:")
  gpu.setForeground(COL.text);  put(x0 + 7, y0 + 6, string.format("%6d mB", water))

  gpu.setForeground(COL.teal);  put(x0, y0 + 7, "Steam:")
  gpu.setForeground(COL.text);  put(x0 + 7, y0 + 7, string.format("%6d mB", steam))

  gpu.setForeground(COL.teal);  put(x0, y0 + 8, "CO2:")
  gpu.setForeground(COL.text);  put(x0 + 7, y0 + 8, string.format("%6d mB", co2))

  -- status
  gpu.setForeground(COL.teal);  put(x0, y0 + 9, "Status:")
  if active then gpu.setForeground(COL.green); put(x0 + 8, y0 + 9, "ACTIVE")
  else          gpu.setForeground(COL.bad);   put(x0 + 8, y0 + 9, "INACTIVE") end

  -- tiny diagnostics (one line)
  gpu.setForeground(COL.dim)
  put(x0, H - 3, "Diag: "..(reactorAddr and reactorAddr:sub(1,8).."…" or "—").." • "..(lastDiag or "-"))
  gpu.setForeground(COL.text)
end

-- ---------- initial draw ----------
clearAll()
drawTitle(reactor and "HOST" or "VIEWER", reactorAddr and reactorAddr:sub(1,8).."…")
drawFrame()
drawButtons()

-- mode label
gpu.setForeground(COL.dim)
put(PAD_X, PAD_Y, reactor and "HOST MODE" or "VIEWER (no reactor)")
gpu.setForeground(COL.text)

-- ---------- main loop ----------
local running = true
while running do
  local ev, a,b,c = event.pull(0.25, "touch")
  if ev == "touch" then
    local _,_,x,y = a,b,c
    local by, tx, tw, _, ex, ew = layoutButtons()
    -- Exit
    if y == by and x >= ex and x < ex + ew then
      running = false
    end
    -- Toggle
    if y == by and x >= tx and x < tx + tw then
      local err = setActive(not B(select(6, readZirnox())))
      if err then lastDiag = err end
    end
  elseif ev == "interrupted" then
    running = false
  end
  drawStats()
end

clearAll()

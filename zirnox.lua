-- zirnox.lua — same UI, fixed touch + full wireless host/viewer
-- OpenComputers (1.7.10 / OpenOS)

local component = require("component")
local event     = require("event")
local term      = require("term")
local serial    = require("serialization")
local gpu       = assert(component.gpu, "GPU required.")

-- ========================= Config =========================
local CFG = {
  PORT           = 42420,
  PROTO          = "zirnox.v1",
  SHARED_KEY     = nil,      -- set same string on both if you want pairing
  WIRELESS_RANGE = 220,      -- your range
  TICK           = 0.25,     -- logic tick
  BCAST_RATE     = 0.5,      -- host broadcast cadence (s)
  DISC_RATE      = 2.5,      -- viewer discovery cadence (s)
}

-- Optional CLI: --hostaddr=xxxx-... to lock the viewer to a host
local LOCK_HOST = nil
do
  local ok, shell = pcall(require, "shell")
  if ok and shell and shell.parse then
    local _, opts = shell.parse(...)
    if opts.hostaddr then LOCK_HOST = tostring(opts.hostaddr) end
  end
end

-- ========================= Small utils ====================
local function N(v) return tonumber(v) or 0 end
local function B(v) return v == true end
local function wrap(body)
  return serial.serialize({proto=CFG.PROTO, key=CFG.SHARED_KEY, body=body})
end

-- ========================= UI helpers (keep your look) ====
gpu.setResolution(60, 18)  -- same footprint you liked
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

local function drawTitle(role, addrStr)
  gpu.setBackground(COL.title); gpu.setForeground(COL.text)
  gpu.fill(1, 1, W, 1, " ")
  local label = "ZIRNOX REACTOR • "..role..(addrStr and (" • "..addrStr) or "")
  put(3, 1, label, COL.text, COL.title)
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

-- ========================= Reactor (host) =================
local reactor, reactorAddr
for addr, t in component.list() do
  if t == "zirnox_reactor" then
    reactor = component.proxy(addr)
    reactorAddr = addr
    break
  end
end
local ROLE = reactor and "HOST" or "VIEWER"

local function readZirnox()
  if not reactor then return 0,0,0,0,0,false end
  -- Try per-field getters
  local okT, temp = pcall(reactor.getTemp)
  local okP, pres = pcall(reactor.getPressure)
  local okW, wat  = pcall(reactor.getWater)
  local okC, co2  = pcall(reactor.getCarbonDioxide)
  local okS, stm  = pcall(reactor.getSteam)
  local okA, act  = pcall(reactor.isActive)
  if okT and okP and okW and okC and okS and okA then
    return N(temp), N(pres), N(wat), N(co2), N(stm), B(act)
  end
  -- Fallback to getInfo (table or multiple returns)
  local okI, a,b,c,d,e,f = pcall(reactor.getInfo)
  if okI then
    if type(a)=="table" then
      local t=a
      return N(t[1] or t.temp), N(t[2] or t.pressure), N(t[3] or t.water),
             N(t[4] or t.co2 or t.carbon), N(t[5] or t.steam), B(t[6] or t.active)
    else
      return N(a),N(b),N(c),N(d),N(e),B(f)
    end
  end
  return 0,0,0,0,0,false
end

local function setActive(on)
  if ROLE=="HOST" and reactor and reactor.setActive then
    pcall(reactor.setActive, on and true or false)
  end
end

-- ========================= Networking =====================
local NET = { modem=nil, isWireless=false, hostAddr=nil, portOpen=false }

local function openModem()
  for addr in component.list("modem") do
    NET.modem = component.proxy(addr); break
  end
  if not NET.modem then return end
  NET.isWireless = (NET.modem.isWireless and NET.modem.isWireless()) or false
  if NET.isWireless and NET.modem.setStrength then pcall(NET.modem.setStrength, CFG.WIRELESS_RANGE) end
  if not NET.modem.isOpen(CFG.PORT) then NET.modem.open(CFG.PORT) end
  NET.portOpen = NET.modem.isOpen(CFG.PORT)
end

local function send(addr, body)
  if NET.modem and addr then NET.modem.send(addr, CFG.PORT, wrap(body)) end
end
local function bcast(body)
  if NET.modem and NET.isWireless and NET.modem.broadcast then NET.modem.broadcast(CFG.PORT, wrap(body)) end
end

local INFO = {temp=0,pres=0,water=0,co2=0,steam=0,active=false}

local function onMsg(_, localAddr, from, port, dist, payload)
  if port ~= CFG.PORT then return end
  local ok, msg = pcall(serial.unserialize, payload or "")
  if not ok or type(msg)~="table" then return end
  if msg.proto ~= CFG.PROTO then return end
  if (CFG.SHARED_KEY or false) ~= (msg.key or false) then return end
  local body = msg.body or {}
  if type(body)~="table" then return end

  if body.t=="whois" and ROLE=="HOST" then
    send(from, {t="iam"})
  elseif body.t=="iam" and ROLE=="VIEWER" then
    NET.hostAddr = NET.hostAddr or from
  elseif body.t=="state" and ROLE=="VIEWER" then
    local i = body.info or {}
    INFO.temp   = N(i.temp)
    INFO.pres   = N(i.pres)
    INFO.water  = N(i.water)
    INFO.co2    = N(i.co2)
    INFO.steam  = N(i.steam)
    INFO.active = B(i.active)
    if not NET.hostAddr then NET.hostAddr = from end
  elseif body.t=="cmd" and ROLE=="HOST" then
    if body.cmd=="setActive" then setActive(body.value==true) end
  end
end

openModem()
event.listen("modem_message", onMsg)

-- ========================= Draw (same look) ===============
local function drawStats()
  local temp, pres, water, co2, steam, active
  if ROLE=="HOST" then
    temp, pres, water, co2, steam, active = readZirnox()
    INFO.temp,INFO.pres,INFO.water,INFO.co2,INFO.steam,INFO.active =
      temp,pres,water,co2,steam,active
  else
    temp, pres, water, co2, steam, active =
      INFO.temp,INFO.pres,INFO.water,INFO.co2,INFO.steam,INFO.active
  end

  local x0, y0 = PAD_X, PAD_Y + 3
  local barW   = W - 2 * PAD_X

  gpu.setForeground(COL.red);   put(x0,     y0 + 0, "Temp:")
  gpu.setForeground(COL.text);  put(x0 + 7, y0 + 0, string.format("%7.2f °C", temp))
  drawBar(x0, y0 + 1, barW, math.min(100, (temp / math.max(1,temp,800))*100), COL.orange)

  gpu.setForeground(COL.blue);  put(x0,     y0 + 3, "Pres:")
  gpu.setForeground(COL.text);  put(x0 + 7, y0 + 3, string.format("%7.2f BAR", pres))
  drawBar(x0, y0 + 4, barW, math.min(100, (pres / math.max(1,pres,30))*100), COL.cyan)

  gpu.setForeground(COL.teal);  put(x0,     y0 + 6, "Water:")
  gpu.setForeground(COL.text);  put(x0 + 7, y0 + 6, string.format("%6d mB", water))

  gpu.setForeground(COL.teal);  put(x0,     y0 + 7, "Steam:")
  gpu.setForeground(COL.text);  put(x0 + 7, y0 + 7, string.format("%6d mB", steam))

  gpu.setForeground(COL.teal);  put(x0,     y0 + 8, "CO2:")
  gpu.setForeground(COL.text);  put(x0 + 7, y0 + 8, string.format("%6d mB", co2))

  gpu.setForeground(COL.teal);  put(x0,     y0 + 9, "Status:")
  if active then gpu.setForeground(COL.green); put(x0 + 8, y0 + 9, "ACTIVE")
  else          gpu.setForeground(COL.bad);   put(x0 + 8, y0 + 9, "INACTIVE") end

  gpu.setForeground(COL.text)
end

-- ========================= Initial draw ===================
clearAll()
drawTitle(ROLE, reactorAddr and reactorAddr:sub(1,8).."…")
drawFrame()
drawButtons()
put(PAD_X, PAD_Y, ROLE=="HOST" and "HOST MODE" or "VIEWER")

-- ========================= Main Loop ======================
local lastB, lastD = 0, 0
local running = true
while running do
  -- host periodic broadcast
  local now = os.clock()
  if ROLE=="HOST" and NET.modem and now - lastB >= CFG.BCAST_RATE then
    local pkt = {t="state", info=INFO}
    if NET.isWireless and NET.modem.broadcast then
      NET.modem.broadcast(CFG.PORT, wrap(pkt))
    end
    lastB = now
  end

  -- viewer discovery (broadcast whois or ping locked host)
  if ROLE=="VIEWER" and NET.modem and now - lastD >= CFG.DISC_RATE then
    if LOCK_HOST then
      send(LOCK_HOST, {t="whois"})
    else
      bcast({t="whois"})
    end
    lastD = now
  end

  -- draw stats
  drawStats()

  -- handle input (IMPORTANT: correct touch params)
  local ev, addr, x, y = event.pull(CFG.TICK, "touch")
  if ev == "touch" then
    -- touch params are: screenAddress, x, y, button, player
    local by, tx, tw, _, ex, ew = layoutButtons()
    if y == by and x >= ex and x < ex + ew then
      running = false
    elseif y == by and x >= tx and x < tx + tw then
      -- toggle
      if ROLE=="HOST" then
        setActive(not INFO.active)
      else
        local dest = NET.hostAddr or LOCK_HOST
        if dest then
          send(dest, {t="cmd", cmd="setActive", value=not INFO.active})
        end
      end
    end
  elseif ev == "interrupted" then
    running = false
  end
end

event.ignore("modem_message", onMsg)
gpu.setBackground(COL.bg); gpu.setForeground(COL.text); term.clear()

-- zirnox_ui.lua — OC 1.7.10 friendly, uses your simple GUI style
-- HOST (has zirnox_reactor): reads + broadcasts state over modem
-- VIEWER (no reactor): shows same GUI, listens for state; Toggle sends cmd to HOST

-------------------------------
-- deps
-------------------------------
local component = require("component")
local event     = require("event")
local term      = require("term")
local serial    = require("serialization")
local gpu       = assert(component.gpu, "No GPU found.")

-------------------------------
-- config
-------------------------------
local PORT        = 42420
local PROTOCOL    = "zirnox.v1"
local SHARED_KEY  = nil      -- set same string on both to "pair" (or keep nil)
local REFRESH     = 0.25
local RES_MIN_W   = 60       -- keep your 60x18 feel, but never shrink a larger screen
local RES_MIN_H   = 18
local PAD_X, PAD_Y= 2, 1

-- colors (RGB; DO NOT pass 'true' flag to gpu.set* on 1.7.10)
local COL = {
  bg        = 0x000000,
  panel     = 0x202020,
  white     = 0xFFFFFF,
  red       = 0xFF0000,
  green     = 0x00FF00,
  blue      = 0x1E90FF,
  orange    = 0xFF4500,
  teal      = 0x008080,
  cyan      = 0x03A9F4,
  yellow    = 0xFFC107,
  title     = 0x2D7DFA,
  border    = 0x777777,
}

-------------------------------
-- gpu/screen binding + res
-------------------------------
local function bindFirstScreen()
  local scr
  for addr in component.list("screen") do scr = scr or addr end
  assert(scr, "No screen attached/cabled.")
  local ok, err = pcall(gpu.bind, scr) -- no reset flag in 1.7.10 API; this is fine
  assert(ok, "gpu.bind failed: "..tostring(err))
  return scr
end

local function setResolutionAtLeast(wNeed, hNeed)
  local cw, ch = gpu.getResolution()
  local mw, mh = gpu.maxResolution()
  local nw = cw < wNeed and math.min(mw, wNeed) or cw
  local nh = ch < hNeed and math.min(mh, hNeed) or ch
  if nw ~= cw or nh ~= ch then pcall(gpu.setResolution, nw, nh) end
  return gpu.getResolution()
end

local function clearAll(bg)
  gpu.setBackground(bg or COL.bg)
  gpu.setForeground(COL.white)
  term.clear()
  term.setCursor(1,1)
end

-------------------------------
-- small drawing helpers
-------------------------------
local function drawText(x, y, txt, fg, bg)
  if bg then gpu.setBackground(bg) end
  if fg then gpu.setForeground(fg) end
  gpu.set(x, y, txt)
end

local function drawHLine(x1, x2, y, ch, fg)
  if fg then gpu.setForeground(fg) end
  local w = math.max(0, x2 - x1 + 1)
  if w > 0 then gpu.fill(x1, y, w, 1, ch or "-") end
end

local function drawPanel(x, y, w, h)
  gpu.setBackground(COL.panel)
  gpu.fill(x, y, w, h, " ")
  gpu.setBackground(COL.bg) -- restore for text
end

local function drawBar(x, y, w, pct, fillColor)
  pct = math.max(0, math.min(100, pct or 0))
  local fill = math.floor(w * pct / 100)
  gpu.setBackground(COL.panel)
  gpu.fill(x, y, w, 1, " ")
  if fill > 0 then
    gpu.setBackground(fillColor or COL.cyan)
    gpu.fill(x, y, fill, 1, " ")
  end
  gpu.setBackground(COL.bg)
  gpu.setForeground(COL.white)
end

-------------------------------
-- modem utils
-------------------------------
local function haveModem()
  for _ in component.list("modem") do return true end
  return false
end

local function openPort()
  local m
  for addr in component.list("modem") do
    m = component.proxy(addr); break
  end
  if not m then return nil, "no modem" end
  if not m.isOpen(PORT) then m.open(PORT) end
  return m
end

local function wrap(body)
  return serial.serialize({proto=PROTOCOL, key=SHARED_KEY, body=body})
end

-------------------------------
-- reactor detect
-------------------------------
local function findZirnox()
  for addr, t in component.list() do
    if t == "zirnox_reactor" then
      return component.proxy(addr), addr
    end
  end
  return nil, nil
end

-------------------------------
-- state
-------------------------------
local STATE = {
  role          = "VIEWER", -- or "HOST"
  reactor       = nil,
  reactorAddr   = nil,
  modem         = nil,
  hostAddr      = nil,
  info = {
    temp=0, pres=0, water=0, steam=0, co2=0, active=false
  },
  W=60, H=18,
  -- buttons (computed)
  btnY=0, btnToggleX=0, btnToggleW=0, btnExitX=0, btnExitW=0,
  diag = { last="init", portOpen=false, modemKind="none" }
}

-------------------------------
-- frame like your sample
-------------------------------
local function layout()
  local W,H = gpu.getResolution()
  STATE.W, STATE.H = W, H
  local btnToggleLabel = "[ Toggle Reactor ]"
  local btnExitLabel   = "[ X ]"
  STATE.btnToggleW = #btnToggleLabel
  STATE.btnExitW   = #btnExitLabel
  STATE.btnY       = H - PAD_Y
  STATE.btnToggleX = PAD_X
  STATE.btnExitX   = W - PAD_X - STATE.btnExitW + 1
  return btnToggleLabel, btnExitLabel
end

local function drawFrame()
  local W,H = STATE.W, STATE.H
  clearAll(COL.bg)

  -- title
  local titleRole = (STATE.role == "HOST" and ("HOST • "..(STATE.reactorAddr and STATE.reactorAddr:sub(1,8).."…" or "no-reactor")))
                 or  ("VIEWER • "..(STATE.hostAddr and ("host "..STATE.hostAddr:sub(1,8).."…") or "searching…"))
  local title = " Zirnox Reactor Monitor — "..titleRole.." "
  local titleX = math.floor((W - #title) / 2) + 1
  drawText(titleX, PAD_Y, title, COL.white)

  -- separator
  drawHLine(PAD_X, W-PAD_X, PAD_Y+1, "-", COL.border)

  -- diagnostics panel background (left block feel)
  drawPanel(PAD_X, PAD_Y+2, math.min(28, W-2*PAD_X), 12)

  -- buttons (box-like)
  local btnToggleLabel, btnExitLabel = layout()
  drawText(STATE.btnToggleX - 1, STATE.btnY - 1, "+" .. string.rep("-", STATE.btnToggleW) .. "+", COL.white)
  drawText(STATE.btnToggleX - 1, STATE.btnY,     "|" .. btnToggleLabel .. "|", COL.white)
  drawText(STATE.btnToggleX - 1, STATE.btnY + 1, "+" .. string.rep("-", STATE.btnToggleW) .. "+", COL.white)

  drawText(STATE.btnExitX   - 1, STATE.btnY - 1, "+" .. string.rep("-", STATE.btnExitW) .. "+", COL.white)
  drawText(STATE.btnExitX   - 1, STATE.btnY,     "|" .. btnExitLabel   .. "|", COL.white)
  drawText(STATE.btnExitX   - 1, STATE.btnY + 1, "+" .. string.rep("-", STATE.btnExitW) .. "+", COL.white)
end

local function drawStats()
  local W = STATE.W
  local x0, y0 = PAD_X+1, PAD_Y + 3
  local barW   = W - 2 * PAD_X

  -- extract info (already converted if host; otherwise mirrored as-is)
  local tempC     = STATE.info.temp or 0
  local pressureB = STATE.info.pres or 0
  local water     = STATE.info.water or 0
  local steam     = STATE.info.steam or 0
  local co2       = STATE.info.co2 or 0
  local active    = STATE.info.active and true or false

  -- percentages (rough scale; bars are just UI)
  local pctT = math.max(0, math.min(100, (tempC / 800)*100))
  local pctP = math.max(0, math.min(100, (pressureB / 30)*100))

  -- Temp
  drawText(x0,     y0 + 0, "Temp:", COL.red)
  drawText(x0 + 7, y0 + 0, string.format("%7.2f \194\176C (%5.1f%%)", tempC, pctT), COL.white)
  drawBar(x0,      y0 + 1, barW, pctT, COL.orange)

  -- Pressure
  drawText(x0,     y0 + 3, "Pres:", COL.blue)
  drawText(x0 + 7, y0 + 3, string.format("%7.2f BAR (%5.1f%%)", pressureB, pctP), COL.white)
  drawBar(x0,      y0 + 4, barW, pctP, COL.blue)

  -- Water
  drawText(x0,     y0 + 6, "Water:", COL.teal)
  drawText(x0 + 7, y0 + 6, string.format("%6d mB", water), COL.white)

  -- Steam
  drawText(x0,     y0 + 7, "Steam:", COL.teal)
  drawText(x0 + 7, y0 + 7, string.format("%6d mB", steam), COL.white)

  -- CO2
  drawText(x0,     y0 + 8, "CO2:", COL.teal)
  drawText(x0 + 7, y0 + 8, string.format("%6d mB", co2), COL.white)

  -- Status
  drawText(x0,     y0 + 9, "Status:", COL.yellow)
  drawText(x0 + 8, y0 + 9, active and "ACTIVE" or "INACTIVE", active and COL.green or COL.red)

  -- Diagnostics (left block area)
  local dY = y0 + 11
  drawText(x0, dY,     "Diag:", COL.yellow)
  drawText(x0+7, dY,   (STATE.diag.modemKind or "none")..", port "..(STATE.diag.portOpen and "open" or "closed")..", "..(STATE.diag.last or "-"), COL.white)
end

-------------------------------
-- read reactor (HOST)
-------------------------------
local function hostReadReactor()
  if not STATE.reactor then return end
  -- NTM returns: {Temperature, Pressure, Water, CO2, Steam, Active}
  local t,p,w,co2,s,act = STATE.reactor.getInfo()
  -- your sample did a conversion; wiki doesn’t define scaling, so treat as direct.
  -- If your reactor returns raw scalars, you can convert here. For now assume direct.
  STATE.info.temp  = tonumber(t)   or 0
  STATE.info.pres  = tonumber(p)   or 0
  STATE.info.water = tonumber(w)   or 0
  STATE.info.co2   = tonumber(co2) or 0
  STATE.info.steam = tonumber(s)   or 0
  STATE.info.active= (act == true)
end

-------------------------------
-- networking (send/recv)
-------------------------------
local function hostBroadcast()
  if not STATE.modem then return end
  local payload = wrap({t="state", info=STATE.info})
  if STATE.modem.isWireless and STATE.modem.isWireless() and STATE.modem.broadcast then
    STATE.modem.broadcast(PORT, payload)
  else
    -- wired: we can’t broadcast; nothing else to do unless we learned a hostAddr
  end
  STATE.diag.last = "broadcast state"
end

local function viewerDiscover()
  if not STATE.modem then return end
  local payload = wrap({t="whois"})
  if STATE.modem.isWireless and STATE.modem.isWireless() and STATE.modem.broadcast then
    STATE.modem.broadcast(PORT, payload)
  end
  STATE.diag.last = "sent whois"
end

local function onModemMessage(_, localAddr, from, port, distance, payload)
  if port ~= PORT then return end
  local ok, msg = pcall(serial.unserialize, payload or "")
  if not ok or type(msg)~="table" then return end
  if msg.proto ~= PROTOCOL then return end
  if (SHARED_KEY or false) ~= (msg.key or false) then return end
  local body = msg.body or {}
  if type(body) ~= "table" then return end

  if body.t == "whois" and STATE.role == "HOST" then
    STATE.modem.send(from, PORT, wrap({t="iam"}))
    STATE.diag.last = "reply iam"
  elseif body.t == "iam" and STATE.role == "VIEWER" then
    STATE.hostAddr = from
    STATE.diag.last = "found host"
  elseif body.t == "state" and STATE.role == "VIEWER" then
    if type(body.info) == "table" then
      for k,v in pairs(body.info) do STATE.info[k] = v end
      STATE.diag.last = "rx state"
    end
  elseif body.t == "cmd" and STATE.role == "HOST" then
    if body.cmd == "setActive" then
      if STATE.reactor then STATE.reactor.setActive(body.value and true or false) end
      STATE.diag.last = "rx cmd"
    end
  end
end

-------------------------------
-- toggle action
-------------------------------
local function toggleActive()
  if STATE.role == "HOST" then
    if STATE.reactor then
      local new = not STATE.info.active
      STATE.reactor.setActive(new)
      STATE.info.active = new
    end
  else
    if STATE.modem and STATE.hostAddr then
      STATE.modem.send(STATE.hostAddr, PORT, wrap({t="cmd", cmd="setActive", value=not STATE.info.active}))
      STATE.diag.last = "sent cmd"
    else
      STATE.diag.last = "no host"
    end
  end
end

-------------------------------
-- main
-------------------------------
local function main()
  -- bind & resolution
  local scr = bindFirstScreen()
  local W,H = setResolutionAtLeast(RES_MIN_W, RES_MIN_H)

  -- pick role
  local r, addr = findZirnox()
  if r then
    STATE.role = "HOST"
    STATE.reactor = r
    STATE.reactorAddr = addr
  else
    STATE.role = "VIEWER"
  end

  -- modem
  if haveModem() then
    STATE.modem = assert(openPort())
    STATE.diag.portOpen = true
    STATE.diag.modemKind = (STATE.modem.isWireless and STATE.modem.isWireless()) and "wireless" or "wired"
  else
    STATE.diag.portOpen = false
    STATE.diag.modemKind = "none"
  end

  -- draw immediately
  layout()
  drawFrame()
  drawStats()

  -- subscribe to modem messages
  event.listen("modem_message", onModemMessage)

  local tDiscover = 0
  local tBroadcast = 0
  local lastTick = os.clock()

  while true do
    local ev, _, x, y = event.pull(REFRESH, "touch")
    -- logic ticks
    local now = os.clock()
    if STATE.role == "HOST" then
      hostReadReactor()
      if STATE.modem and now - tBroadcast >= 0.5 then
        hostBroadcast()
        tBroadcast = now
      end
    else
      if STATE.modem and not STATE.hostAddr and now - tDiscover >= 3.0 then
        viewerDiscover()
        tDiscover = now
      end
    end

    -- redraw
    drawFrame()
    drawStats()

    if ev == "touch" then
      -- toggle?
      if y == STATE.btnY and x >= STATE.btnToggleX and x < STATE.btnToggleX + STATE.btnToggleW then
        toggleActive()
      end
      -- exit?
      if y == STATE.btnY and x >= STATE.btnExitX and x < STATE.btnExitX + STATE.btnExitW then
        break
      end
    end
  end

  -- cleanup
  event.ignore("modem_message", onModemMessage)
  clearAll(COL.bg)
end

local ok, err = pcall(main)
if not ok then
  io.stderr:write("Fatal error: "..tostring(err).."\n")
end

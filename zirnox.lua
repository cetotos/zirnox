--------------------------------------------------------------------------------
-- zirnox_reactor_gui.lua
-- OpenComputers (Lua 5.3) GUI for NTM 1.7.10 Zirnox Reactor stats & control
-- Resolution fixed at 60×18, .25s refresh, colored titles, white values, buttons
--------------------------------------------------------------------------------

local component = require("component")
local event     = require("event")
local term      = require("term")
local gpu       = component.gpu

-- nil-safe helpers
local function N(v) return tonumber(v) or 0 end
local function B(v) return v and true or false end

--------------------------------------------------------------------------------
-- 1) Set a coarser grid so characters render larger
--------------------------------------------------------------------------------
gpu.setResolution(60, 18)
local W, H = gpu.getResolution()

--------------------------------------------------------------------------------
-- 2) Colors and paddings
--------------------------------------------------------------------------------
local PAD_X, PAD_Y = 2, 2

local function drawText(x, y, txt)
  gpu.set(x, y, txt)
end

local function clearAll()
  term.clear()
  term.setCursor(1, 1)
end

local function drawBar(x, y, w, pct, col)
  pct = math.max(0, math.min(100, N(pct)))
  local fill = math.floor(w * pct / 100)
  gpu.setBackground(0x202020)
  gpu.fill(x, y, w, 1, " ")
  if fill > 0 then
    gpu.setBackground(col or 0x03A9F4)
    gpu.fill(x, y, fill, 1, " ")
  end
  gpu.setBackground(0x000000) -- reset BG so later text isn't highlighted
end

--------------------------------------------------------------------------------
-- 3) Title bar and separators
--------------------------------------------------------------------------------
local function drawTitle()
  gpu.setBackground(0x2D7DFA)
  gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, W, 1, " ")
  drawText(3, 1, "ZIRNOX REACTOR • OPENCOMPUTERS UI")
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
end

local function drawFrame()
  -- top separator
  for x = 1, W do drawText(x, 2, " ") end
  gpu.setForeground(0x777777)
  for x = PAD_X, W - PAD_X do drawText(x, PAD_Y + 1, "─") end

  -- left/right panels
  gpu.setForeground(0x777777)
  for y = PAD_Y + 2, H - 4 do
    drawText(PAD_X, y, "│")
    drawText(W - PAD_X, y, "│")
  end
  drawText(PAD_X, H - 3, "├" .. string.rep("─", W - 2*PAD_X - 2) .. "┤")

  -- footer row
  drawText(PAD_X, H - 1, " ")
  for x = PAD_X + 1, W - PAD_X - 1 do drawText(x, H - 1, "─") end
  drawText(W - PAD_X, H - 1, " ")
end

--------------------------------------------------------------------------------
-- 4) Buttons layout
--------------------------------------------------------------------------------
local function layoutButtons()
  local btnToggleLabel = "[ Toggle Reactor ]"
  local btnExitLabel   = "[ X ]"

  local btnToggleW = #btnToggleLabel
  local btnExitW   = #btnExitLabel

  local btnY = H - 2
  local btnToggleX = PAD_X + 2
  local btnExitX   = W - PAD_X - btnExitW

  return btnY, btnToggleX, btnToggleW, btnExitX, btnExitW, btnToggleLabel, btnExitLabel
end

local function drawButtons()
  local btnY, btnToggleX, btnToggleW, btnExitX, btnExitW, btnToggleLabel, btnExitLabel =
    layoutButtons()

  -- top divider under title
  gpu.setForeground(0x777777)
  for x = PAD_X, W - PAD_X do drawText(x, PAD_Y + 1, "─") end

  -- toggle button (all three start at btnToggleX-1)
  drawText(btnToggleX - 1, btnY - 1, "┌" .. string.rep("─", btnToggleW) .. "┐")
  drawText(btnToggleX - 1, btnY,     "│" .. btnToggleLabel .. "│")
  drawText(btnToggleX - 1, btnY + 1, "└" .. string.rep("─", btnToggleW) .. "┘")

  -- exit button (all three start at btnExitX-1)
  drawText(btnExitX   - 1, btnY - 1, "┌" .. string.rep("─", btnExitW) .. "┐")
  drawText(btnExitX   - 1, btnY,     "│" .. btnExitLabel   .. "│")
  drawText(btnExitX   - 1, btnY + 1, "└" .. string.rep("─", btnExitW) .. "┘")

end

--------------------------------------------------------------------------------
-- 6) Draw stats (colored titles, white values, colored bars)
--------------------------------------------------------------------------------
local function drawStats()
  -- NIL-SAFE read (don’t crash if getInfo is missing or transient)
  local t,p,w,co2,s,act = 0,0,0,0,0,false
  if reactor and reactor.getInfo then
    local ok,a,b,c,d,e = pcall(reactor.getInfo)
    if ok then t,p,w,co2,s,act = a,b,c,d,e end
  end
  -- convert to °C and BAR (nil-safe)
  local rawTemp, rawPressure = N(t), N(p)
  local tempC     = rawTemp     * 1e-5 * 780 + 20
  local pressureB = rawPressure * 1e-5 * 30.0
  local water     = N(w)
  local steam     = N(s)
  local co2       = N(co2)
  local active    = B(act)
  -- compute percentages
  local pctT = ((tempC - 20) / 780) * 100
  local pctP = (pressureB / 30) * 100

  local x0, y0 = PAD_X, PAD_Y + 3
  local barW   = W - 2 * PAD_X

  -- Temp (red title, white value)
  gpu.setForeground(0xFF0000)
  drawText(x0,     y0 + 0, "Temp:")
  gpu.setForeground(0xFFFFFF)
  drawText(x0 + 7, y0 + 0,
    string.format("%7.2f °C (%5.1f%%)", tempC, pctT))
  drawBar(x0,      y0 + 1, barW, pctT, 0xFF4500)

  -- Pressure (blue title, white value)
  gpu.setForeground(0x0000FF)
  drawText(x0,     y0 + 3, "Pres:")
  gpu.setForeground(0xFFFFFF)
  drawText(x0 + 7, y0 + 3,
    string.format("%7.2f BAR (%5.1f%%)", pressureB, pctP))
  drawBar(x0,      y0 + 4, barW, pctP, 0x1E90FF)

  -- Water (teal title, white value)
  gpu.setForeground(0x008080)
  drawText(x0,     y0 + 6, "Water:")
  gpu.setForeground(0xFFFFFF)
  drawText(x0 + 7, y0 + 6, string.format("%6d mB", water))

  -- Steam (teal title, white value)
  gpu.setForeground(0x008080)
  drawText(x0,     y0 + 7, "Steam:")
  gpu.setForeground(0xFFFFFF)
  drawText(x0 + 7, y0 + 7, string.format("%6d mB", steam))

  -- CO₂ (teal title, white value)
  gpu.setForeground(0x008080)
  drawText(x0,     y0 + 8, "CO₂:")
  gpu.setForeground(0xFFFFFF)
  drawText(x0 + 7, y0 + 8, string.format("%6d mB", co2))

  -- Status (yellow title, green/red value)
  gpu.setForeground(0x008080)
  drawText(x0,     y0 + 9, "Status:")
  if active then
    gpu.setForeground(0x00FF00)
    drawText(x0 + 8, y0 + 9, "ACTIVE")
  else
    gpu.setForeground(0xFF0000)
    drawText(x0 + 8, y0 + 9, "INACTIVE")
  end

  gpu.setForeground(0xFFFFFF)
end

--------------------------------------------------------------------------------
-- 7) Initial draw
--------------------------------------------------------------------------------
clearAll()
drawTitle()
drawFrame()
drawButtons()

--------------------------------------------------------------------------------
-- 8) Reactor detection (host only)
--------------------------------------------------------------------------------
local reactor
for addr, t in component.list() do
  if t == "zirnox_reactor" then
    reactor = component.proxy(addr)
    break
  end
end

--------------------------------------------------------------------------------
-- 9) Main loop (redraw stats every 0.25s)
--------------------------------------------------------------------------------
local running = true
gpu.setForeground(0x9AA0A6)
drawText(PAD_X, PAD_Y, reactor and "HOST MODE" or "VIEWER (no reactor)")
gpu.setForeground(0xFFFFFF)

while running do
  local ev, a,b,c,d,e = event.pull(0.25)
  if ev == "touch" then
    local _,_,x,y = a,b,c
    -- Exit button hitbox
    local btnY, _, _, btnExitX, btnExitW = layoutButtons()
    if y == btnY and x >= btnExitX and x < btnExitX + btnExitW then
      running = false
    end
  elseif ev == "interrupted" then
    running = false
  end

  -- Always draw stats (even as viewer, values stay zero)
  drawStats()
end

clearAll()

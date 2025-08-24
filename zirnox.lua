-- Zirnox Reactor UI (OC 1.7.10) — scalable, sleek, modem-aware (220 block default)
-- One file for both machines:
--   HOST  = has zirnox_reactor; reads & broadcasts state over wireless modem
--   VIEWER= no reactor; draws UI immediately; listens; Toggle sends cmd to Host

----------------------------- CONFIG -----------------------------
local CFG = {
  SCALE          = 1.8,      -- 1.0..3.0 (bigger = larger UI)
  PORT           = 42420,
  PROTO          = "zirnox.v1",
  SHARED_KEY     = nil,      -- optional pairing key (same on both)
  TICK           = 0.25,     -- UI + logic tick
  HOST_BCAST     = 0.5,      -- host broadcast cadence
  VIEW_DISC      = 3.0,      -- viewer discovery cadence
  MIN_W          = 72,       -- min resolution to request (won't shrink)
  MIN_H          = 24,
  WIRELESS_RANGE = 220,      -- your modem range (blocks)
  COLORS = {
    bg        = 0x0B0D10,
    panel     = 0x171B21,
    title     = 0x2D7DFA,
    text      = 0xEAECEE,
    faint     = 0x9AA0A6,
    border    = 0x3B3F46,
    good      = 0x4CAF50,
    warn      = 0xFFC107,
    bad       = 0xF44336,
    info      = 0x03A9F4,
    btnTxt    = 0xFFFFFF,
    closeBg   = 0xE53935,
    closeTxt  = 0xFFFFFF,
    barWater  = 0x4CAF50,
    barCO2    = 0xFFC107,
    barSteam  = 0x03A9F4,
  }
}

----------------------------- LIBS ------------------------------
local component = require("component")
local event     = require("event")
local term      = require("term")
local serial    = require("serialization")
local gpu       = assert(component.gpu, "GPU required.")

-- optional flags: --host / --viewer
local FORCE = nil
do
  local ok, shell = pcall(require, "shell")
  if ok and shell and shell.parse then
    local _, opts = shell.parse(...)
    if opts.host then FORCE = "HOST" end
    if opts.viewer then FORCE = "VIEWER" end
  end
end

----------------------------- UTIL ------------------------------
local COL = CFG.COLORS
local function clamp(v,a,b) if v<a then return a elseif v>b then return v end return v end
local function round(x,n) n=n or 0 local p=10^n return math.floor(x*p+0.5)/p end
local function setBG(c) gpu.setBackground(c) end
local function setFG(c) gpu.setForeground(c) end
local function fill(x,y,w,h,ch,bg) if bg then setBG(bg) end gpu.fill(x,y,w,h,ch or " ") end
local function txt(x,y,s,fg,bg) if bg then setBG(bg) end if fg then setFG(fg) end gpu.set(x,y,s) end
local function hline(x1,x2,y,ch,fg) if fg then setFG(fg) end if x2>=x1 then gpu.fill(x1,y,x2-x1+1,1,ch or " ") end end

local function bindScreen()
  local scr
  for a in component.list("screen") do scr = scr or a end
  assert(scr, "No screen attached. Place a Screen + cable.")
  assert(pcall(gpu.bind, scr))
  return scr
end

local function ensureRes(minW, minH)
  local cw,ch = gpu.getResolution()
  local mw,mh = gpu.maxResolution()
  local nw = (cw < minW) and math.min(mw, minW) or cw
  local nh = (ch < minH) and math.min(mh, minH) or ch
  if nw ~= cw or nh ~= ch then pcall(gpu.setResolution, nw, nh) end
  return gpu.getResolution()
end

---------------------------- LAYOUT -----------------------------
local L = {}
local function computeLayout()
  local W,H = gpu.getResolution()
  local S   = CFG.SCALE
  local pad = math.max(2, math.floor(2*S))
  local innerX, innerY = 2, 3
  local innerW, innerH = W-2, H-3-1
  local leftW  = clamp(math.floor(innerW * (0.40 + 0.06*(S-1))), 30, innerW-20)
  local rightW = innerW - leftW - pad
  local rightX = innerX + leftW + pad
  local btnH   = math.max(3, math.floor(3*S))
  L = {
    W=W,H=H,S=S,pad=pad,
    title   ={x=1,y=1,w=W,h=1},
    left    ={x=innerX,y=innerY,w=leftW, h=innerH-btnH-pad},
    right   ={x=rightX,y=innerY,w=rightW,h=innerH-btnH-pad},
    bottom  ={x=innerX,y=innerY+innerH-btnH,w=innerW,h=btnH},
    bars    ={x=rightX+2,y=innerY+2,w=rightW-4},
    stats   ={x=innerX+2,y=innerY+2,w=leftW-4},
  }
end

local CLOSE = {x=0,y=0,w=0,h=1}
local TOGGLE= {x=0,y=0,w=0,h=0}

local function box(x,y,w,h,bg,border)
  if bg then fill(x,y,w,h," ",bg) end
  if border then
    setFG(border)
    gpu.set(x,y,"+"); gpu.set(x+w-1,y,"+")
    gpu.set(x,y+h-1,"+"); gpu.set(x+w-1,y+h-1,"+")
    for i=x+1,x+w-2 do gpu.set(i,y,"-"); gpu.set(i,y+h-1,"-") end
    for j=y+1,y+h-2 do gpu.set(x,j,"|"); gpu.set(x+w-1,j,"|") end
  end
end

local function titleBar(roleStr)
  local t = L.title
  fill(t.x,t.y,t.w,1," ",COL.title)
  txt(t.x+2,t.y,"ZIRNOX REACTOR • "..roleStr, COL.text, COL.title)
  local label = "[  X  ]"
  local cw = #label
  local cx = t.x + t.w - cw
  fill(cx,t.y,cw,1," ",COL.closeBg)
  txt(cx+1,t.y,label, COL.closeTxt, COL.closeBg)
  CLOSE = {x=cx,y=t.y,w=cw,h=1}
end

local function button(x,y,label)
  local w = #label + 2
  txt(x,   y-1, "+"..string.rep("-", w-2).."+", COL.text)
  txt(x,   y,   "|"..label.."|",                COL.btnTxt)
  txt(x,   y+1, "+"..string.rep("-", w-2).."+", COL.text)
  return {x=x,y=y,w=w,h=3}
end

local function statLine(x,y,k,v,kv)
  kv = kv or 13
  txt(x, y, string.format("%-"..kv.."s", k), COL.faint)
  txt(x+kv+1, y, v, COL.text)
end

local function bar(x,y,w,pct,label,right,fillColor)
  pct = clamp(pct or 0,0,1)
  fill(x,y,w,1," ",COL.panel)
  if w>2 then
    local filled = math.floor((w-2) * pct + 0.5)
    setBG(fillColor or COL.info)
    if filled>0 then gpu.fill(x+1,y,filled,1," ") end
  end
  setFG(COL.border); if w>=2 then gpu.set(x,y,"["); gpu.set(x+w-1,y,"]") end
  txt(x, y-1, label, COL.faint)
  local rx = x+w-#right
  if rx>=x then txt(rx, y-1, right, COL.faint) end
  setBG(COL.bg); setFG(COL.text)
end

local function within(mx,my,r)
  return r and mx>=r.x and mx<=r.x+r.w-1 and my>=r.y and my<=r.y+r.h-1
end

---------------------------- NET -------------------------------
local NET = { modem=nil, isWireless=false, hostAddr=nil, last="init", portOpen=false, range=0 }

local function openModem()
  for addr in component.list("modem") do
    local m = component.proxy(addr)
    NET.modem = m; break
  end
  if not NET.modem then NET.last="no modem"; return end
  NET.isWireless = (NET.modem.isWireless and NET.modem.isWireless()) or false
  if NET.isWireless and NET.modem.setStrength then
    local r = tonumber(CFG.WIRELESS_RANGE) or 0
    if r>0 then pcall(NET.modem.setStrength, r); NET.range = r end
  end
  if not NET.modem.isOpen(CFG.PORT) then NET.modem.open(CFG.PORT) end
  NET.portOpen = NET.modem.isOpen(CFG.PORT)
  NET.last = (NET.isWireless and "wireless" or "wired").." port "..tostring(CFG.PORT).." open"
end

local function wrap(body)
  return serial.serialize({proto=CFG.PROTO, key=CFG.SHARED_KEY, body=body})
end

local function send(addr, body)
  if NET.modem then NET.modem.send(addr, CFG.PORT, wrap(body)) end
end

local function bcast(body)
  if not NET.modem then return end
  local pay = wrap(body)
  if NET.isWireless and NET.modem.broadcast then
    NET.modem.broadcast(CFG.PORT, pay)
  end
end

--------------------------- REACTOR ----------------------------
local function findZirnox()
  for addr, t in component.list() do
    if t == "zirnox_reactor" then
      return component.proxy(addr), addr
    end
  end
  return nil, nil
end

----------------------------- STATE ----------------------------
local ST = {
  role      = "VIEWER",     -- or "HOST"
  reactor   = nil,
  raddr     = nil,
  hostAddr  = nil,
  info      = {temp=0, pres=0, water=0, co2=0, steam=0, active=false},
  lastRX    = 0,
}

------------------------------ UI ------------------------------
local function drawAll()
  local roleStr = (ST.role=="HOST") and ("HOST • "..(ST.raddr and (ST.raddr:sub(1,8).."…") or "no-reactor"))
                                or ("VIEWER • "..(NET.hostAddr and ("host "..NET.hostAddr:sub(1,8).."…") or "searching…"))
  -- backdrop
  fill(1,1,L.W,L.H," ",COL.bg)

  -- frame
  titleBar(roleStr)
  box(L.left.x,  L.left.y,  L.left.w,  L.left.h,  COL.panel, COL.border)
  box(L.right.x, L.right.y, L.right.w, L.right.h, COL.panel, COL.border)
  box(L.bottom.x,L.bottom.y,L.bottom.w,L.bottom.h,COL.panel, COL.border)

  -- left: stats + diagnostics
  local x, y = L.stats.x, L.stats.y
  txt(x, y, "Status", COL.faint); y=y+1
  local sLabel = ST.info.active and "[ON ] ACTIVE" or "[OFF] STANDBY"
  local sColor = ST.info.active and COL.good or COL.info
  txt(x, y, sLabel, sColor); y=y+2

  txt(x, y, "Reactor Info", COL.faint); y=y+1
  statLine(x,y, "Temperature:", string.format("%s °C", round(ST.info.temp,1))); y=y+1
  statLine(x,y, "Pressure:",    string.format("%s bar", round(ST.info.pres,1))); y=y+1
  statLine(x,y, "Water:",       tostring(ST.info.water).." mB"); y=y+1
  statLine(x,y, "CO2:",         tostring(ST.info.co2).." mB"); y=y+1
  statLine(x,y, "Steam:",       tostring(ST.info.steam).." mB"); y=y+2

  txt(x, y, "Network", COL.faint); y=y+1
  statLine(x,y, "Modem:", NET.modem and ((NET.isWireless and "wireless") or "wired") or "none"); y=y+1
  statLine(x,y, "Port:",  NET.portOpen and ("open "..CFG.PORT) or "closed"); y=y+1
  if NET.isWireless then statLine(x,y, "Range:", tostring(NET.range or 0).." blocks"); y=y+1 end
  statLine(x,y, "Last:",  NET.last or "-"); y=y+1

  -- right: bars
  local bx, by, bw = L.bars.x, L.bars.y, L.bars.w
  local function pct(v,m) m=(m==0 and 1 or m); return clamp(v/m,0,1) end
  local maxT, maxP = math.max(800, ST.info.temp), math.max(30, ST.info.pres) -- auto scale
  txt(bx, by, "Live Meters", COL.faint); by=by+2
  bar(bx, by, bw, pct(ST.info.temp, maxT),   "Temperature", string.format("%d / %d °C", round(ST.info.temp), round(maxT)), COL.info);  by=by+2
  bar(bx, by, bw, pct(ST.info.pres, maxP),   "Pressure",    string.format("%d / %d bar", round(ST.info.pres), round(maxP)), COL.info); by=by+2
  bar(bx, by, bw, pct(ST.info.water, math.max(1,ST.info.water)), "Water", string.format("%d mB", ST.info.water), COL.barWater); by=by+2
  bar(bx, by, bw, pct(ST.info.co2,   math.max(1,ST.info.co2)),   "CO2",   string.format("%d mB", ST.info.co2),   COL.barCO2);   by=by+2
  bar(bx, by, bw, pct(ST.info.steam, math.max(1,ST.info.steam)), "Steam", string.format("%d mB", ST.info.steam), COL.barSteam); by=by+2

  -- bottom: buttons
  local midY = L.bottom.y + math.floor(L.bottom.h/2)
  local lbl = ST.info.active and " Stop Reactor " or " Start Reactor "
  TOGGLE = button(L.bottom.x+2, midY, lbl)
  local EXIT = button(L.bottom.x + L.bottom.w - (#"[  Exit  ]")+4, midY, "  Exit  ")
  -- store exit rect into CLOSE too (click bottom Exit also quits)
  CLOSE = {x=EXIT.x, y=EXIT.y, w=EXIT.w, h=EXIT.h}
end

-------------------------- REACTOR I/O --------------------------
local function readReactor()
  if not ST.reactor then return end
  local t,p,w,co2,s,act = ST.reactor.getInfo()
  ST.info.temp   = tonumber(t)   or 0
  ST.info.pres   = tonumber(p)   or 0
  ST.info.water  = tonumber(w)   or 0
  ST.info.co2    = tonumber(co2) or 0
  ST.info.steam  = tonumber(s)   or 0
  ST.info.active = (act == true)
end

local function setActive(on)
  if ST.role == "HOST" then
    if ST.reactor then ST.reactor.setActive(on and true or false) end
  else
    if NET.modem and NET.hostAddr then
      send(NET.hostAddr, {t="cmd", cmd="setActive", value=(on and true or false)})
      NET.last = "sent cmd toggle"
    else
      NET.last = "no host"
    end
  end
end

----------------------------- NET I/O --------------------------
local function onMsg(_, localAddr, from, port, dist, payload)
  if port ~= CFG.PORT then return end
  local ok, msg = pcall(serial.unserialize, payload or "")
  if not ok or type(msg)~="table" then return end
  if msg.proto ~= CFG.PROTO then return end
  if (CFG.SHARED_KEY or false) ~= (msg.key or false) then return end
  local body = msg.body or {}
  if type(body) ~= "table" then return end

  if body.t == "whois" and ST.role == "HOST" then
    send(from, {t="iam"})
    NET.last = "reply iam"
  elseif body.t == "iam" and ST.role == "VIEWER" then
    NET.hostAddr = from
    NET.last = "found host"
  elseif body.t == "state" and ST.role == "VIEWER" then
    if type(body.info)=="table" then for k,v in pairs(body.info) do ST.info[k]=v end end
    ST.lastRX = os.clock(); NET.last = "rx state"
  elseif body.t == "cmd" and ST.role == "HOST" then
    if body.cmd == "setActive" then setActive(body.value and true or false) ; NET.last="rx cmd" end
  end
end

local function hostBroadcast(now, lastB)
  if not NET.modem then return lastB end
  if now - lastB >= CFG.HOST_BCAST then
    bcast({t="state", info=ST.info})
    return now
  end
  return lastB
end

local function viewerDiscover(now, lastD)
  if not NET.modem then return lastD end
  if not NET.hostAddr and now - lastD >= CFG.VIEW_DISC then
    bcast({t="whois"})
    NET.last = "sent whois"
    return now
  end
  return lastD
end

------------------------------ MAIN ----------------------------
local function main()
  bindScreen()
  ensureRes(CFG.MIN_W, CFG.MIN_H)
  setBG(COL.bg); setFG(COL.text); term.clear()

  -- role
  if FORCE == "HOST" then
    ST.role = "HOST"
    local r,a = findZirnox(); ST.reactor, ST.raddr = r,a
  elseif FORCE == "VIEWER" then
    ST.role = "VIEWER"
  else
    local r,a = findZirnox()
    if r then ST.role, ST.reactor, ST.raddr = "HOST", r, a else ST.role = "VIEWER" end
  end

  openModem()
  event.listen("modem_message", onMsg)

  computeLayout()
  drawAll()

  local running = true
  local lastB, lastD = 0, 0
  while running do
    local ev, a,b,c = event.pull(CFG.TICK, "touch")
    local now = os.clock()

    if ST.role == "HOST" then
      readReactor()
      lastB = hostBroadcast(now, lastB)
    else
      lastD = viewerDiscover(now, lastD)
    end

    computeLayout()
    drawAll()

    if ev == "touch" then
      local _,_, x,y = a,b,c
      if within(x,y,TOGGLE) then setActive(not ST.info.active) end
      if within(x,y,CLOSE)  then running=false end
    elseif ev == "interrupted" then
      running=false
    end
  end

  event.ignore("modem_message", onMsg)
  setBG(COL.bg); setFG(COL.text); term.clear()
end

local ok, err = pcall(main)
if not ok then io.stderr:write("Fatal error: "..tostring(err).."\n") end

-- zirnox_fixed.lua  (OC 1.7.10) — no flicker, no highlight bugs, nil-safe, scalable
-- HOST: has zirnox_reactor; reads + broadcasts
-- VIEWER: no reactor; shows immediately; listens; can toggle via net
-- SCALE: set CFG.SCALE to 1.0..3.0

---------------- CONFIG ----------------
local CFG = {
  SCALE          = 1.8,      -- 1.0..3.0 (bigger = larger UI)
  PORT           = 42420,
  PROTO          = "zirnox.v1",
  SHARED_KEY     = nil,      -- optional pairing key (set same on both)
  TICK           = 0.25,     -- loop tick
  REFRESH        = 0.5,      -- UI update cadence (lower = faster)
  HOST_BCAST     = 0.5,      -- host broadcast cadence
  VIEW_DISC      = 2.5,      -- viewer discovery cadence
  MIN_W          = 70,       -- min resolution to request (won’t shrink)
  MIN_H          = 22,
  WIRELESS_RANGE = 220,      -- your modem range
  HOST_ADDR      = nil,      -- optional: force viewer to a specific host modem address
  COL = {
    bg      = 0x0B0D10,
    panel   = 0x171B21,
    title   = 0x2D7DFA,
    text    = 0xEAECEE,
    faint   = 0x9AA0A6,
    border  = 0x3B3F46,
    good    = 0x4CAF50,
    info    = 0x03A9F4,
    warn    = 0xFFC107,
    bad     = 0xF44336,
    btnTxt  = 0xFFFFFF,
    closeBg = 0xE53935,
    closeTx = 0xFFFFFF,
    wBar    = 0x4CAF50,
    cBar    = 0xFFC107,
    sBar    = 0x03A9F4,
  }
}

---------------- LIBS -------------------
local component = require("component")
local event     = require("event")
local term      = require("term")
local serial    = require("serialization")
local gpu       = assert(component.gpu, "GPU required.")

-- flags: --host / --viewer / --hostaddr=ADDR
local FORCE, HOSTADDR = nil, nil
do
  local ok, shell = pcall(require, "shell")
  if ok and shell and shell.parse then
    local _, opts = shell.parse(...)
    if opts.host     then FORCE = "HOST" end
    if opts.viewer   then FORCE = "VIEWER" end
    if opts.hostaddr then HOSTADDR = tostring(opts.hostaddr) end
  end
end
if HOSTADDR and #HOSTADDR>0 then CFG.HOST_ADDR = HOSTADDR end

---------------- UTIL --------------------
local COL = CFG.COL
local function N(v) return tonumber(v) or 0 end
local function B(v) return v and true or false end
local function clamp(v,a,b) if v<a then return a elseif v>b then return b else return v end end
local function round(x,n) n=n or 0 local p=10^n return math.floor(N(x)*p+0.5)/p end
local function setBG(c) gpu.setBackground(c) end
local function setFG(c) gpu.setForeground(c) end
local function fill(x,y,w,h,ch,bg) if bg then setBG(bg) end gpu.fill(x,y,w,h,ch or " ") setBG(COL.bg) end
local function put(x,y,s,fg,bg) if bg then setBG(bg) end if fg then setFG(fg) end gpu.set(x,y,s) setBG(COL.bg) end

local function bindScreen()
  local scr
  for a in component.list("screen") do scr = scr or a end
  assert(scr, "No screen attached/cabled.")
  assert(pcall(gpu.bind, scr))
end

local function ensureRes(minW,minH)
  local cw,ch = gpu.getResolution()
  local mw,mh = gpu.maxResolution()
  local nw = (cw<minW) and math.min(mw,minW) or cw
  local nh = (ch<minH) and math.min(mh,minH) or ch
  if nw~=cw or nh~=ch then pcall(gpu.setResolution,nw,nh) end
end

---------------- LAYOUT ------------------
local L = { }
local CLOSE={x=0,y=0,w=0,h=1}
local TOGGLE={x=0,y=0,w=0,h=0}

local function computeLayout()
  local W,H = gpu.getResolution()
  local S   = CFG.SCALE
  local pad = math.max(2, math.floor(2*S))
  local titleH = 1
  local innerX, innerY = 2, 2 + titleH
  local innerW, innerH = W-2, H - (1 + titleH) - 1
  local leftW  = clamp(math.floor(innerW * (0.40 + 0.05*(S-1))), 28, innerW-22)
  local rightW = innerW - leftW - pad
  local rightX = innerX + leftW + pad
  local btnH   = math.max(3, math.floor(3*S))
  L = {
    W=W,H=H,S=S,pad=pad,
    title={x=1,y=1,w=W,h=1},
    left ={x=innerX,y=innerY,w=leftW,h=innerH-btnH-pad},
    right={x=rightX,y=innerY,w=rightW,h=innerH-btnH-pad},
    bottom={x=innerX,y=innerY+innerH-btnH,w=innerW,h=btnH},
    stats={x=innerX+2,y=innerY+2,w=leftW-4},
    bars ={x=rightX+2,y=innerY+2,w=rightW-4},
  }
  if L.bottom.x+L.bottom.w-1 > W then L.bottom.w = W-L.bottom.x+1 end
  if L.right.x+L.right.w-1 > W then L.right.w = W-L.right.x+1 end
end

local function drawBox(x,y,w,h,bg,border)
  if bg then fill(x,y,w,h," ",bg) end
  if border and w>=2 and h>=2 then
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
  put(t.x+2,t.y,"ZIRNOX REACTOR • "..roleStr, COL.text, COL.title)
  local label = "[  X  ]"
  local cw = #label
  local cx = math.max(t.x+2, t.x + t.w - cw - 1)
  fill(cx,t.y,cw,1," ",COL.closeBg)
  put(cx+1,t.y,label, COL.closeTx, COL.closeBg)
  CLOSE={x=cx,y=t.y,w=cw,h=1}
end

local function button(x,y,label)
  local w = #label + 2
  if x+w-1 > L.W then x = L.W - w + 1 end
  if x < 1 then x = 1 end
  put(x,  y-1, "+"..string.rep("-",w-2).."+", COL.text)
  put(x,  y,   "|"..label.."|",               COL.btnTxt)
  put(x,  y+1, "+"..string.rep("-",w-2).."+", COL.text)
  return {x=x,y=y,w=w,h=3}
end

local function within(mx,my,r)
  return r and mx>=r.x and mx<=r.x+r.w-1 and my>=r.y and my<=r.y+r.h-1
end

---------------- NET ----------------------
local NET = { modem=nil,isWireless=false, hostAddr=nil, portOpen=false, last="init" }

local function openModem()
  for addr in component.list("modem") do
    NET.modem = component.proxy(addr); break
  end
  if not NET.modem then NET.last="no modem"; return end
  NET.isWireless = (NET.modem.isWireless and NET.modem.isWireless()) or false
  if NET.isWireless and NET.modem.setStrength then pcall(NET.modem.setStrength, N(CFG.WIRELESS_RANGE)) end
  if not NET.modem.isOpen(CFG.PORT) then NET.modem.open(CFG.PORT) end
  NET.portOpen = NET.modem.isOpen(CFG.PORT)
  NET.last = (NET.isWireless and "wireless " or "wired ").."port "..tostring(CFG.PORT).." open"
end

local function wrap(body) return serial.serialize({proto=CFG.PROTO,key=CFG.SHARED_KEY,body=body}) end
local function send(addr, body) if NET.modem then NET.modem.send(addr, CFG.PORT, wrap(body)) end end
local function bcast(body) if NET.modem and NET.isWireless and NET.modem.broadcast then NET.modem.broadcast(CFG.PORT, wrap(body)) end end

---------------- REACTOR -------------------
local function findZirnox()
  for addr,t in component.list() do
    if t=="zirnox_reactor" then return component.proxy(addr), addr end
  end
  return nil,nil
end

---------------- STATE ---------------------
local ST = {
  role="VIEWER", reactor=nil, raddr=nil,
  info={temp=0,pres=0,water=0,co2=0,steam=0,active=false},
  lastRX=0
}

---------------- STATIC FRAME --------------
local lines = { statusY=0, diagY=0, barsY=0 }
local function drawStaticFrame()
  setBG(COL.bg); setFG(COL.text); term.clear()
  local roleStr = (ST.role=="HOST") and ("HOST • "..(ST.raddr and ST.raddr:sub(1,8).."…" or "no-reactor"))
                                 or  ("VIEWER • "..(NET.hostAddr and ("host "..NET.hostAddr:sub(1,8).."…") or (CFG.HOST_ADDR and "locking…" or "searching…")))
  titleBar(roleStr)
  drawBox(L.left.x,L.left.y,L.left.w,L.left.h,  COL.panel,COL.border)
  drawBox(L.right.x,L.right.y,L.right.w,L.right.h,COL.panel,COL.border)
  drawBox(L.bottom.x,L.bottom.y,L.bottom.w,L.bottom.h, COL.panel,COL.border)

  -- labels
  local x, y = L.stats.x, L.stats.y
  put(x,y,"Status",COL.faint); y=y+2
  lines.statusY = y; y=y+1
  put(x,y,"Reactor Info",COL.faint); y=y+1
  put(x,y,"Temperature:"); y=y+1
  put(x,y,"Pressure:   "); y=y+1
  put(x,y,"Water:      "); y=y+1
  put(x,y,"CO2:        "); y=y+1
  put(x,y,"Steam:      "); y=y+2
  put(x,y,"Network",COL.faint); y=y+1
  lines.diagY = y

  local bx, by = L.bars.x, L.bars.y
  put(bx, by, "Live Meters", COL.faint); by = by + 2
  lines.barsY = by

  -- buttons
  local midY = L.bottom.y + math.floor(L.bottom.h/2)
  TOGGLE = button(L.bottom.x+2, midY, "  Toggle Reactor  ")
  local EXIT  = button(L.bottom.x + L.bottom.w - (#"   Exit   ")-4, midY, "   Exit   ")
  CLOSE = EXIT
end

---------------- DYNAMIC UPDATE ------------
local lastDraw = { }
local function updText(x,y,key,str,fg)
  if lastDraw[key] ~= str then
    -- erase to panel edge so no leftovers; keep BG default
    local safeW = math.max(0, (L.left.x+L.left.w-3) - x + 1)
    if safeW > 0 then
      local padded = tostring(str)
      if #padded < safeW then padded = padded .. string.rep(" ", safeW-#padded) end
      put(x,y,padded,fg)
    else
      put(x,y,tostring(str),fg)
    end
    lastDraw[key] = str
  end
end

local function updBar(x,y,w,key,pct,label,right,fillColor)
  pct = clamp(N(pct),0,1)
  local sig = key..":"..tostring(math.floor(pct*100))..":"..tostring(right)
  if lastDraw[key] ~= sig then
    fill(x,y,w,1," ",COL.panel)                  -- clear row
    setFG(COL.border); if w>=2 then gpu.set(x,y,"["); gpu.set(x+w-1,y,"]") end
    if w>2 then
      local filled = math.floor((w-2)*pct+0.5)
      if filled>0 then setBG(fillColor or COL.info); gpu.fill(x+1,y,filled,1," ") end
    end
    setBG(COL.bg)
    put(x, y-1, label.."        ", COL.faint)
    local rx = x+w-#tostring(right)
    if rx>=x then put(rx, y-1, tostring(right), COL.faint) end
    lastDraw[key] = sig
  end
end

local function updateUI()
  -- status
  local x = L.stats.x + 14
  local y = lines.statusY - 1
  local sLabel = ST.info.active and "[ON ] ACTIVE" or "[OFF] STANDBY"
  updText(x,y,"status", sLabel, ST.info.active and COL.good or COL.info)

  -- fields
  y = L.stats.y + 4
  updText(x,y,  "t", string.format("%s °C", round(ST.info.temp,1)));  y=y+1
  updText(x,y,  "p", string.format("%s bar", round(ST.info.pres,1))); y=y+1
  updText(x,y,  "w", tostring(N(ST.info.water)).." mB");              y=y+1
  updText(x,y, "co2", tostring(N(ST.info.co2)).." mB");               y=y+1
  updText(x,y,  "s", tostring(N(ST.info.steam)).." mB");              y=y+2

  -- diagnostics
  local dX = L.stats.x + 14
  local dY = lines.diagY
  local mstr = NET.modem and ((NET.isWireless and "wireless") or "wired") or "none"
  updText(dX,dY,   "m","Modem: "..mstr);                              dY=dY+1
  updText(dX,dY,   "po","Port: "..(NET.portOpen and ("open "..CFG.PORT) or "closed")); dY=dY+1
  if NET.isWireless then updText(dX,dY,"rg","Range: "..tostring(CFG.WIRELESS_RANGE).." blocks"); dY=dY+1 end
  updText(dX,dY,   "le","Last: "..(NET.last or "-"));                 dY=dY+1

  -- bars (auto scale to seen values, but nil-safe)
  local bx, by, bw = L.bars.x, lines.barsY, L.bars.w
  local maxT = math.max(800, N(ST.info.temp))
  local maxP = math.max(30,  N(ST.info.pres))
  updBar(bx,by,  bw,"barT", N(ST.info.temp)/maxT, "Temperature", string.format("%d / %d °C", round(ST.info.temp), round(maxT)), COL.info);  by=by+2
  updBar(bx,by,  bw,"barP", N(ST.info.pres)/maxP, "Pressure   ", string.format("%d / %d bar", round(ST.info.pres), round(maxP)), COL.info); by=by+2
  updBar(bx,by,  bw,"barW", N(ST.info.water)>0 and 1 or 0, "Water      ", tostring(N(ST.info.water)).." mB", COL.wBar);                     by=by+2
  updBar(bx,by,  bw,"barC", N(ST.info.co2)>0   and 1 or 0, "CO2        ", tostring(N(ST.info.co2)).." mB",   COL.cBar);                     by=by+2
  updBar(bx,by,  bw,"barS", N(ST.info.steam)>0 and 1 or 0, "Steam      ", tostring(N(ST.info.steam)).." mB", COL.sBar);                     by=by+2
end

---------------- REACTOR I/O ---------------
local function readReactor()
  if not ST.reactor then return end
  local t,p,w,co2,s,act = ST.reactor.getInfo()
  ST.info.temp   = N(t)
  ST.info.pres   = N(p)
  ST.info.water  = N(w)
  ST.info.co2    = N(co2)
  ST.info.steam  = N(s)
  ST.info.active = B(act)
end

local function setActive(on)
  if ST.role=="HOST" then
    if ST.reactor then pcall(ST.reactor.setActive, B(on)) end
  else
    local dest = NET.hostAddr or CFG.HOST_ADDR
    if NET.modem and dest then
      send(dest, {t="cmd", cmd="setActive", value=B(on)})
      NET.last = "sent cmd"
    else
      NET.last = "no host"
    end
  end
end

---------------- NETWORK I/O ---------------
local function onMsg(_, localAddr, from, port, dist, payload)
  if port ~= CFG.PORT then return end
  local ok, msg = pcall(serial.unserialize, payload or "")
  if not ok or type(msg)~="table" or msg.proto ~= CFG.PROTO then return end
  if (CFG.SHARED_KEY or false) ~= (msg.key or false) then return end
  local body = msg.body or {}
  if type(body)~="table" then return end

  if body.t=="whois" and ST.role=="HOST" then
    send(from, {t="iam"}); NET.last="reply iam"
  elseif body.t=="iam" and ST.role=="VIEWER" then
    NET.hostAddr = NET.hostAddr or from; NET.last="found host"
  elseif body.t=="state" and ST.role=="VIEWER" then
    local ii = body.info or {}
    ST.info.temp   = N(ii.temp)
    ST.info.pres   = N(ii.pres)
    ST.info.water  = N(ii.water)
    ST.info.co2    = N(ii.co2)
    ST.info.steam  = N(ii.steam)
    ST.info.active = B(ii.active)
    ST.lastRX = os.clock(); NET.last="rx state"
    if not NET.hostAddr then NET.hostAddr = from end
  elseif body.t=="cmd" and ST.role=="HOST" then
    if body.cmd=="setActive" then setActive(B(body.value)); NET.last="rx cmd" end
  end
end

local function hostBroadcast(now,lastB)
  if not NET.modem then return lastB end
  if now-lastB >= CFG.HOST_BCAST then
    send(NET.hostAddr or "", {t="noop"}) -- harmless; keeps channel warm if direct send needed
    bcast({t="state", info=ST.info})
    return now
  end
  return lastB
end

local function viewerDiscover(now,lastD)
  if not NET.modem then return lastD end
  if CFG.HOST_ADDR and now-lastD >= CFG.VIEW_DISC then
    send(CFG.HOST_ADDR, {t="whois"}); NET.last="whois->hostaddr"; return now
  end
  if not NET.hostAddr and now-lastD >= CFG.VIEW_DISC then
    bcast({t="whois"}); NET.last="whois broadcast"; return now
  end
  return lastD
end

---------------- MAIN ----------------------
local function findZirnox()
  for addr,t in component.list() do
    if t=="zirnox_reactor" then return component.proxy(addr), addr end
  end
  return nil,nil
end

local function main()
  bindScreen()
  ensureRes(CFG.MIN_W, CFG.MIN_H)

  if FORCE=="HOST" then
    ST.role="HOST"; local r,a=findZirnox(); ST.reactor,ST.raddr=r,a
  elseif FORCE=="VIEWER" then
    ST.role="VIEWER"
  else
    local r,a = findZirnox(); if r then ST.role="HOST"; ST.reactor,ST.raddr=r,a end
  end

  openModem()
  event.listen("modem_message", onMsg)

  computeLayout()
  drawStaticFrame()
  updateUI()

  local running = true
  local lastB, lastD, lastUI = 0, 0, 0
  while running do
    local ev, a, b, c = event.pull(CFG.TICK, "touch")
    local now = os.clock()

    if ST.role=="HOST" then
      readReactor()
      lastB = hostBroadcast(now,lastB)
    else
      lastD = viewerDiscover(now,lastD)
    end

    if now - lastUI >= CFG.REFRESH then
      updateUI()
      lastUI = now
    end

    if ev=="touch" then
      local _,_,x,y = a,b,c
      if within(x,y,TOGGLE) then setActive(not ST.info.active) end
      if within(x,y,CLOSE)  then running=false end
    elseif ev=="interrupted" then
      running=false
    end
  end

  event.ignore("modem_message", onMsg)
  setBG(COL.bg); setFG(COL.text); term.clear()
end

local ok, err = pcall(main)
if not ok then io.stderr:write("Fatal error: "..tostring(err).."\n") end

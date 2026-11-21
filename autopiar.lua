script_name('AutoPiar')
script_author('meatwiss')
script_version('1.1')
require 'lib.moonloader'
local ffi      = require 'ffi'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local okImgui, imgui = pcall(require, 'mimgui')
local okSampev, sampev = pcall(require, 'samp.events')
if not (okImgui and okSampev) then
    local libs = {}
    if not okImgui then libs[#libs + 1] = 'mimgui' end
    if not okSampev then libs[#libs + 1] = 'samp.events (SAMP.Lua)' end
    function main()
        while not isSampAvailable() do wait(100) end
        sampAddChatMessage(u8:decode('{FFB84D}[АвтоПиар] {FFFFFF}Не хватает нужных библиотек: ' .. table.concat(libs, ', ')
            .. '. Закинь их в moonloader\\lib и перезагрузи скрипт'), -1)
    end
    return
end
local BUFSZ       = 512
local MAX_LINES   = 8
local MULTI       = { ['/al'] = true, ['/fam'] = true, ['/g'] = true, radio = true }
local MIN_ALLOWED = 1
local GAP         = 3
local CMDS        = { '/vr', '/ad', '/s', '/al', '/fam', '/g', 'radio' }
local CONFIG_DIR  = getWorkingDirectory() .. '\\autopiar'
local CONFIG_PATH = CONFIG_DIR .. '\\autopiar.ini'
local CITIES      = { 'Автоматически', 'SF', 'LV', 'LS' }
local CITY_NAMES  = { nil, 'San Fierro', 'Las Venturas', 'Los Santos' }
local RADIO = { org = 'r' }
local cmdLabels, cmdItems
local function rebuildCmdItems()
    cmdLabels = {}
    for i, c in ipairs(CMDS) do
        cmdLabels[i] = (c == 'radio') and ('/' .. RADIO.org) or c
    end
    cmdItems = imgui.new['const char*'][#CMDS](cmdLabels)
end
rebuildCmdItems()
local VR   = { cd = nil, fallback = 300, readyAt = 0, lastEpoch = nil }
local MUTE = { untilAt = 0, resume = imgui.new.bool(false) }
local cityItems = imgui.new['const char*'][#CITIES](CITIES)
local win       = imgui.new.bool(false)
local saveDelay = imgui.new.bool(true)
local adCfg     = { cd = nil }
local UPD = {
    url     = 'https://raw.githubusercontent.com/meatwiss/autopiar/main/version.json',
    enabled = nil,
    skip    = '',
    view    = nil,
    shown   = nil,
    chk     = imgui.new.bool(true),
    info    = nil,
    status  = '',
    busy    = false,
}
local msgs      = {}
local target    = 1
local globalNext = 0
local pendingVr = nil
local pendingAd = nil
local emojiErr  = nil
local itemsErr  = nil
local L = {
    win_w = 818, win_h = 682, win_h_side = 400,
    pad_x = 14, pad_y = 12, spacing_x = 8, spacing_y = 6,
    add_btn_h = 30, close_size = 22,
    card_h = 100, card_gap = 8, trash_size = 22, trash_ox = 0, trash_oy = 5,
    list_h = 216, emoji_size = 24,
    side = 2, side_w = 330,
}
local function cmdIndex(name)
    for i, c in ipairs(CMDS) do if c == name then return i - 1 end end
    return 0
end
local function isUtf8(str)
    if not str:find('[\128-\255]') then return true end
    local i, n = 1, #str
    while i <= n do
        local c = str:byte(i)
        if c < 0x80 then
            i = i + 1
        else
            local len = (c >= 0xC2 and c <= 0xDF) and 2
                or (c >= 0xE0 and c <= 0xEF) and 3
                or (c >= 0xF0 and c <= 0xF4) and 4 or 0
            if len == 0 or i + len - 1 > n then return false end
            for k = 1, len - 1 do
                local b = str:byte(i + k)
                if b < 0x80 or b > 0xBF then return false end
            end
            i = i + len
        end
    end
    return true
end
local function fixUtf8(str)
    if isUtf8(str) then return str end
    return u8:encode(str)
end
local function newMsg(d)
    d = d or {}
    local defDelay = 0
    local m = {
        buf       = imgui.new.char[BUFSZ](),
        ad        = imgui.new.bool(d.ad == true),
        lim       = imgui.new.bool(d.lim == true),
        cnt       = imgui.new.int(tonumber(d.cnt) or 10),
        delay     = imgui.new.int(tonumber(d.delay) or defDelay),
        cmd       = imgui.new.int(cmdIndex(d.cmd or '/vr')),
        city      = imgui.new.int(tonumber(d.city) or 0),
        vip       = imgui.new.bool(d.vip == true),
        rs        = imgui.new.bool(d.rs == true),
        rsec      = imgui.new.int(tonumber(d.rsec) or 35),
        ooc       = imgui.new.bool(d.ooc == true),
        pause     = imgui.new.float(tonumber(d.pause) or 3),
        idx       = 1,
        checkAt   = nil,
        active    = false,
        left      = 0,
        nextAt    = 0,
        lastDelay = tonumber(d.delay) or defDelay,
    }
    local t = fixUtf8(d.text or '')
    if #t >= BUFSZ then
        local cut = BUFSZ - 1
        while cut > 0 and t:byte(cut + 1) and t:byte(cut + 1) >= 0x80 and t:byte(cut + 1) < 0xC0 do cut = cut - 1 end
        t = t:sub(1, cut)
    end
    ffi.copy(m.buf, t)
    m.lines = { { buf = m.buf, pause = m.pause } }
    if type(d.extra) == 'table' then
        local keys = {}
        for k in pairs(d.extra) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            if #m.lines >= MAX_LINES then break end
            local e = d.extra[k]
            local b = imgui.new.char[BUFSZ]()
            local tx = fixUtf8(e.text or '')
            if #tx >= BUFSZ then
                local cut = BUFSZ - 1
                while cut > 0 and tx:byte(cut + 1) and tx:byte(cut + 1) >= 0x80 and tx:byte(cut + 1) < 0xC0 do cut = cut - 1 end
                tx = tx:sub(1, cut)
            end
            ffi.copy(b, tx)
            m.lines[#m.lines + 1] = { buf = b, pause = imgui.new.float(tonumber(e.pause) or 3) }
        end
    end
    return m
end
local function msgText(m)
    return ffi.string(m.buf)
end
local function realCmd(m)
    local c = CMDS[m.cmd[0] + 1]
    if c == 'radio' then return '/' .. RADIO.org .. (m.ooc[0] and 'b' or '') end
    return c
end
local function escapeIni(s)
    return (s:gsub('\\', '\\\\'):gsub('\n', '\\n'):gsub('\r', ''))
end
local function unescapeIni(s)
    return (s:gsub('\\(.)', function(c)
        if c == 'n' then return '\n' end
        if c == '\\' then return '\\' end
        return '\\' .. c
    end))
end
local function save()
    createDirectory(CONFIG_DIR)
    local f = io.open(CONFIG_PATH, 'w')
    if not f then return end
    f:write('[main]\n')
    f:write(('saveDelay=%s\n'):format(saveDelay[0] and '1' or '0'))
    f:write(('side=%d\n'):format(L.side))
    if adCfg.cd then f:write(('adCd=%d\n'):format(adCfg.cd)) end
    f:write(('radioOrg=%s\n'):format(RADIO.org))
    f:write(('muteResume=%s\n'):format(MUTE.resume[0] and '1' or '0'))
    if VR.cd then f:write(('vrCd=%d\n'):format(VR.cd)) end
    if VR.lastEpoch then f:write(('vrLast=%d\n'):format(VR.lastEpoch)) end
    if UPD.enabled ~= nil then f:write(('updEnabled=%s\n'):format(UPD.enabled and '1' or '0')) end
    if UPD.skip ~= '' then f:write(('updSkip=%s\n'):format(UPD.skip)) end
    f:write(('count=%d\n'):format(#msgs))
    for i, m in ipairs(msgs) do
        f:write(('\n[msg%d]\n'):format(i))
        f:write(('cmd=%s\n'):format(CMDS[m.cmd[0] + 1]))
        f:write(('text=%s\n'):format(escapeIni(msgText(m))))
        f:write(('delay=%d\n'):format(m.delay[0]))
        f:write(('ad=%s\n'):format(m.ad[0] and '1' or '0'))
        f:write(('lim=%s\n'):format(m.lim[0] and '1' or '0'))
        f:write(('cnt=%d\n'):format(m.cnt[0]))
        f:write(('city=%d\n'):format(m.city[0]))
        f:write(('vip=%s\n'):format(m.vip[0] and '1' or '0'))
        f:write(('rs=%s\n'):format(m.rs[0] and '1' or '0'))
        f:write(('rsec=%d\n'):format(m.rsec[0]))
        f:write(('ooc=%s\n'):format(m.ooc[0] and '1' or '0'))
        f:write(('pause=%g\n'):format(math.max(0.1, m.pause[0])))
        for k = 2, #m.lines do
            f:write(('line%d=%s\n'):format(k, escapeIni(ffi.string(m.lines[k].buf))))
            f:write(('pause%d=%g\n'):format(k, math.max(0.1, m.lines[k].pause[0])))
        end
    end
    f:close()
end
local function loadConfig()
    local f = io.open(CONFIG_PATH, 'r')
    if not f then return end
    local content = f:read('*a')
    f:close()
    if not content or content == '' then return end
    local section = nil
    local cur = {}
    local function flush()
        if section and section:match('^msg%d+$') and (cur.text ~= nil or cur.cmd) then
            msgs[#msgs + 1] = newMsg(cur)
        end
        cur = {}
    end
    for line in (content .. '\n'):gmatch('(.-)\r?\n') do
        local sec = line:match('^%[(.-)%]$')
        if sec then
            flush()
            section = sec
        else
            local k, v = line:match('^([%w_]+)=(.*)$')
            if k and v then
                if section == 'main' then
                    if k == 'saveDelay' then saveDelay[0] = (v == '1')
                    elseif k == 'adCd' then adCfg.cd = tonumber(v)
                    elseif k == 'radioOrg' then RADIO.org = (v == 'f') and 'f' or 'r'
                    elseif k == 'muteResume' then MUTE.resume[0] = (v == '1')
                    elseif k == 'vrCd' then
                        local n = tonumber(v)
                        if n and n >= 30 and n <= 7200 then VR.cd = math.floor(n) end
                    elseif k == 'vrLast' then VR.lastEpoch = tonumber(v)
                    elseif k == 'updEnabled' then UPD.enabled = (v == '1'); UPD.chk[0] = UPD.enabled
                    elseif k == 'updSkip' then UPD.skip = v
                    elseif k == 'side' then
                        local n = tonumber(v)
                        if n and n >= 0 and n <= 2 then L.side = math.floor(n) end
                    end
                elseif section and section:match('^msg%d+$') then
                    if k == 'cmd' then cur.cmd = v
                    elseif k == 'text' then cur.text = unescapeIni(v)
                    elseif k == 'delay' then cur.delay = tonumber(v)
                    elseif k == 'ad' then cur.ad = (v == '1')
                    elseif k == 'lim' then cur.lim = (v == '1')
                    elseif k == 'cnt' then cur.cnt = tonumber(v)
                    elseif k == 'city' then cur.city = tonumber(v)
                    elseif k == 'vip' then cur.vip = (v == '1')
                    elseif k == 'rs' then cur.rs = (v == '1')
                    elseif k == 'rsec' then cur.rsec = tonumber(v)
                    elseif k == 'ooc' then cur.ooc = (v == '1')
                    elseif k == 'pause' then cur.pause = tonumber(v)
                    elseif k:match('^line%d+$') then
                        local n = tonumber(k:sub(5))
                        cur.extra = cur.extra or {}
                        cur.extra[n] = cur.extra[n] or {}
                        cur.extra[n].text = unescapeIni(v)
                    elseif k:match('^pause%d+$') then
                        local n = tonumber(k:sub(6))
                        cur.extra = cur.extra or {}
                        cur.extra[n] = cur.extra[n] or {}
                        cur.extra[n].pause = tonumber(v)
                    end
                end
            end
        end
    end
    flush()
end
local function u8lower(s)
    s = s:gsub('[\208\209][\128-\191]', function(c)
        local a, b = c:byte(1, 2)
        if a == 208 then
            if b >= 144 and b <= 159 then return '\208' .. string.char(b + 32) end
            if b >= 160 and b <= 175 then return '\209' .. string.char(b - 32) end
            if b >= 128 and b <= 143 then return '\209' .. string.char(b + 16) end
        end
        return c
    end)
    return s:lower()
end
local GAME_DIR = ''
pcall(function() GAME_DIR = getGameDirectory() end)
local function fileExists(p)
    local f = io.open(p, 'rb')
    if f then f:close() return true end
    return false
end
local function rd16(s, i) local a, b = s:byte(i, i + 1) return a + b * 256 end
local function rd32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function zipOpen(path)
    local f = io.open(path, 'rb')
    if not f then return nil, 'нет файла ' .. path end
    local size = f:seek('end')
    local tailLen = math.min(size, 65557)
    f:seek('set', size - tailLen)
    local tail = f:read(tailLen)
    local pos, from = nil, 1
    while true do
        local a = tail:find('PK\5\6', from, true)
        if not a then break end
        pos = a
        from = a + 1
    end
    if not pos then f:close() return nil, 'повреждён zip (нет оглавления)' end
    local total = rd16(tail, pos + 10)
    local cdSize = rd32(tail, pos + 12)
    local cdOff = rd32(tail, pos + 16)
    if cdOff == 0xFFFFFFFF or total == 0xFFFF then f:close() return nil, 'zip64 не поддерживается' end
    f:seek('set', cdOff)
    local cd = f:read(cdSize)
    if not cd then f:close() return nil, 'не прочитал оглавление zip' end
    local list = {}
    local p = 1
    while p + 45 <= #cd and cd:sub(p, p + 3) == 'PK\1\2' do
        local nlen = rd16(cd, p + 28)
        local elen = rd16(cd, p + 30)
        local clen = rd16(cd, p + 32)
        list[#list + 1] = {
            name = cd:sub(p + 46, p + 45 + nlen),
            method = rd16(cd, p + 10),
            csize = rd32(cd, p + 20),
            lho = rd32(cd, p + 42),
        }
        p = p + 46 + nlen + elen + clen
    end
    return { f = f, list = list }
end
local function zipDataOffset(z, ent)
    z.f:seek('set', ent.lho)
    local h = z.f:read(30)
    if not h or #h < 30 or h:sub(1, 4) ~= 'PK\3\4' then return nil end
    return ent.lho + 30 + rd16(h, 27) + rd16(h, 29)
end
local function zipRead(z, ent)
    if ent.method ~= 0 then return nil, 'файл в архиве сжат (метод ' .. ent.method .. ')' end
    local off = zipDataOffset(z, ent)
    if not off then return nil, 'повреждена запись в zip' end
    z.f:seek('set', off)
    return z.f:read(ent.csize)
end
local webp = (function()
local T_COEF0 = {
128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,
128,128,128,128,128,128,128,128,128,253,136,254,255,228,219,128,128,128,128,128,189,129,242,255,
227,213,255,219,128,128,128,106,126,227,252,214,209,255,255,128,128,128,1,98,248,255,236,226,
255,255,128,128,128,181,133,238,254,221,234,255,154,128,128,128,78,134,202,247,198,180,255,219,
128,128,128,1,185,249,255,243,255,128,128,128,128,128,184,150,247,255,236,224,128,128,128,128,
128,77,110,216,255,236,230,128,128,128,128,128,1,101,251,255,241,255,128,128,128,128,128,170,
139,241,252,236,209,255,255,128,128,128,37,116,196,243,228,255,255,255,128,128,128,1,204,254,
255,245,255,128,128,128,128,128,207,160,250,255,238,128,128,128,128,128,128,102,103,231,255,211,
171,128,128,128,128,128,1,152,252,255,240,255,128,128,128,128,128,177,135,243,255,234,225,128,
128,128,128,128,80,129,211,255,194,224,128,128,128,128,128,1,1,255,128,128,128,128,128,128,
128,128,246,1,255,128,128,128,128,128,128,128,128,255,128,128,128,128,128,128,128,128,128,128,
198,35,237,223,193,187,162,160,145,155,62,131,45,198,221,172,176,220,157,252,221,1,68,47,
146,208,149,167,221,162,255,223,128,1,149,241,255,221,224,255,255,128,128,128,184,141,234,253,
222,220,255,199,128,128,128,81,99,181,242,176,190,249,202,255,255,128,1,129,232,253,214,197,
242,196,255,255,128,99,121,210,250,201,198,255,202,128,128,128,23,91,163,242,170,187,247,210,
255,255,128,1,200,246,255,234,255,128,128,128,128,128,109,178,241,255,231,245,255,255,128,128,
128,44,130,201,253,205,192,255,255,128,128,128,1,132,239,251,219,209,255,165,128,128,128,94,
136,225,251,218,190,255,255,128,128,128,22,100,174,245,186,161,255,199,128,128,128,1,182,249,
255,232,235,128,128,128,128,128,124,143,241,255,227,234,128,128,128,128,128,35,77,181,251,193,
211,255,205,128,128,128,1,157,247,255,236,231,255,255,128,128,128,121,141,235,255,225,227,255,
255,128,128,128,45,99,188,251,195,217,255,224,128,128,128,1,1,251,255,213,255,128,128,128,
128,128,203,1,248,255,255,128,128,128,128,128,128,137,1,177,255,224,255,128,128,128,128,128,
253,9,248,251,207,208,255,192,128,128,128,175,13,224,243,193,185,249,198,255,255,128,73,17,
171,221,161,179,236,167,255,234,128,1,95,247,253,212,183,255,255,128,128,128,239,90,244,250,
211,209,255,255,128,128,128,155,77,195,248,188,195,255,255,128,128,128,1,24,239,251,218,219,
255,205,128,128,128,201,51,219,255,196,186,128,128,128,128,128,69,46,190,239,201,218,255,228,
128,128,128,1,191,251,255,255,128,128,128,128,128,128,223,165,249,255,213,255,128,128,128,128,
128,141,124,248,255,255,128,128,128,128,128,128,1,16,248,255,255,128,128,128,128,128,128,190,
36,230,255,236,255,128,128,128,128,128,149,1,255,128,128,128,128,128,128,128,128,1,226,255,
128,128,128,128,128,128,128,128,247,192,255,128,128,128,128,128,128,128,128,240,128,255,128,128,
128,128,128,128,128,128,1,134,252,255,255,128,128,128,128,128,128,213,62,250,255,255,128,128,
128,128,128,128,55,93,255,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,
128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,
202,24,213,235,186,191,220,160,240,175,255,126,38,182,232,169,184,228,174,255,187,128,61,46,
138,219,151,178,240,170,255,216,128,1,112,230,250,199,191,247,159,255,255,128,166,109,228,252,
211,215,255,174,128,128,128,39,77,162,232,172,180,245,178,255,255,128,1,52,220,246,198,199,
249,220,255,255,128,124,74,191,243,183,193,250,221,255,255,128,24,71,130,219,154,170,243,182,
255,255,128,1,182,225,249,219,240,255,224,128,128,128,149,150,226,252,216,205,255,171,128,128,
128,28,108,170,242,183,194,254,223,255,255,128,1,81,230,252,204,203,255,192,128,128,128,123,
102,209,247,188,196,255,233,128,128,128,20,95,153,243,164,173,255,203,128,128,128,1,222,248,
255,216,213,128,128,128,128,128,168,175,246,252,235,205,255,255,128,128,128,47,116,215,255,211,
212,255,255,128,128,128,1,121,236,253,212,214,255,255,128,128,128,141,84,213,252,201,202,255,
219,128,128,128,42,80,160,240,162,185,255,205,128,128,128,1,1,255,128,128,128,128,128,128,
128,128,244,1,255,128,128,128,128,128,128,128,128,238,1,255,128,128,128,128,128,128,128,128
}
local T_UPD = {
255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
255,255,255,255,255,255,255,255,255,176,246,255,255,255,255,255,255,255,255,255,223,241,252,255,
255,255,255,255,255,255,255,249,253,253,255,255,255,255,255,255,255,255,255,244,252,255,255,255,
255,255,255,255,255,234,254,254,255,255,255,255,255,255,255,255,253,255,255,255,255,255,255,255,
255,255,255,255,246,254,255,255,255,255,255,255,255,255,239,253,254,255,255,255,255,255,255,255,
255,254,255,254,255,255,255,255,255,255,255,255,255,248,254,255,255,255,255,255,255,255,255,251,
255,254,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,253,254,
255,255,255,255,255,255,255,255,251,254,254,255,255,255,255,255,255,255,255,254,255,254,255,255,
255,255,255,255,255,255,255,254,253,255,254,255,255,255,255,255,255,250,255,254,255,254,255,255,
255,255,255,255,254,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
217,255,255,255,255,255,255,255,255,255,255,225,252,241,253,255,255,254,255,255,255,255,234,250,
241,250,253,255,253,254,255,255,255,255,254,255,255,255,255,255,255,255,255,255,223,254,254,255,
255,255,255,255,255,255,255,238,253,254,254,255,255,255,255,255,255,255,255,248,254,255,255,255,
255,255,255,255,255,249,254,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
255,255,255,255,253,255,255,255,255,255,255,255,255,255,247,254,255,255,255,255,255,255,255,255,
255,255,255,255,255,255,255,255,255,255,255,255,255,253,254,255,255,255,255,255,255,255,255,252,
255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,254,254,
255,255,255,255,255,255,255,255,253,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
255,255,255,255,255,255,255,254,253,255,255,255,255,255,255,255,255,250,255,255,255,255,255,255,
255,255,255,255,254,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
186,251,250,255,255,255,255,255,255,255,255,234,251,244,254,255,255,255,255,255,255,255,251,251,
243,253,254,255,254,255,255,255,255,255,253,254,255,255,255,255,255,255,255,255,236,253,254,255,
255,255,255,255,255,255,255,251,253,253,254,254,255,255,255,255,255,255,255,254,254,255,255,255,
255,255,255,255,255,254,254,254,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
255,255,255,255,254,255,255,255,255,255,255,255,255,255,254,254,255,255,255,255,255,255,255,255,
255,254,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,254,
255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
248,255,255,255,255,255,255,255,255,255,255,250,254,252,254,255,255,255,255,255,255,255,248,254,
249,253,255,255,255,255,255,255,255,255,253,253,255,255,255,255,255,255,255,255,246,253,253,255,
255,255,255,255,255,255,255,252,254,251,254,254,255,255,255,255,255,255,255,254,252,255,255,255,
255,255,255,255,255,248,254,253,255,255,255,255,255,255,255,255,253,255,254,254,255,255,255,255,
255,255,255,255,251,254,255,255,255,255,255,255,255,255,245,251,254,255,255,255,255,255,255,255,
255,253,253,254,255,255,255,255,255,255,255,255,255,251,253,255,255,255,255,255,255,255,255,252,
253,254,255,255,255,255,255,255,255,255,255,254,255,255,255,255,255,255,255,255,255,255,252,255,
255,255,255,255,255,255,255,255,249,255,254,255,255,255,255,255,255,255,255,255,255,254,255,255,
255,255,255,255,255,255,255,255,253,255,255,255,255,255,255,255,255,250,255,255,255,255,255,255,
255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,
255,255,254,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255
}
local T_BMODES = {
231,120,48,89,115,113,120,152,112,152,179,64,126,170,118,46,70,95,175,69,143,80,85,82,
72,155,103,56,58,10,171,218,189,17,13,152,114,26,17,163,44,195,21,10,173,121,24,80,
195,26,62,44,64,85,144,71,10,38,171,213,144,34,26,170,46,55,19,136,160,33,206,71,
63,20,8,114,114,208,12,9,226,81,40,11,96,182,84,29,16,36,134,183,89,137,98,101,
106,165,148,72,187,100,130,157,111,32,75,80,66,102,167,99,74,62,40,234,128,41,53,9,
178,241,141,26,8,107,74,43,26,146,73,166,49,23,157,65,38,105,160,51,52,31,115,128,
104,79,12,27,217,255,87,17,7,87,68,71,44,114,51,15,186,23,47,41,14,110,182,183,
21,17,194,66,45,25,102,197,189,23,18,22,88,88,147,150,42,46,45,196,205,43,97,183,
117,85,38,35,179,61,39,53,200,87,26,21,43,232,171,56,34,51,104,114,102,29,93,77,
39,28,85,171,58,165,90,98,64,34,22,116,206,23,34,43,166,73,107,54,32,26,51,1,
81,43,31,68,25,106,22,64,171,36,225,114,34,19,21,102,132,188,16,76,124,62,18,78,
95,85,57,50,48,51,193,101,35,159,215,111,89,46,111,60,148,31,172,219,228,21,18,111,
112,113,77,85,179,255,38,120,114,40,42,1,196,245,209,10,25,109,88,43,29,140,166,213,
37,43,154,61,63,30,155,67,45,68,1,209,100,80,8,43,154,1,51,26,71,142,78,78,
16,255,128,34,197,171,41,40,5,102,211,183,4,1,221,51,50,17,168,209,192,23,25,82,
138,31,36,171,27,166,38,44,229,67,87,58,169,82,115,26,59,179,63,59,90,180,59,166,
93,73,154,40,40,21,116,143,209,34,39,175,47,15,16,183,34,223,49,45,183,46,17,33,
183,6,98,15,32,183,57,46,22,24,128,1,54,17,37,65,32,73,115,28,128,23,128,205,
40,3,9,115,51,192,18,6,223,87,37,9,115,59,77,64,21,47,104,55,44,218,9,54,
53,130,226,64,90,70,205,40,41,23,26,57,54,57,112,184,5,41,38,166,213,30,34,26,
133,152,116,10,32,134,39,19,53,221,26,114,32,73,255,31,9,65,234,2,15,1,118,73,
75,32,12,51,192,255,160,43,51,88,31,35,67,102,85,55,186,85,56,21,23,111,59,205,
45,37,192,55,38,70,124,73,102,1,34,98,125,98,42,88,104,85,117,175,82,95,84,53,
89,128,100,113,101,45,75,79,123,47,51,128,81,171,1,57,17,5,71,102,57,53,41,49,
38,33,13,121,57,73,26,1,85,41,10,67,138,77,110,90,47,114,115,21,2,10,102,255,
166,23,6,101,29,16,10,85,128,101,196,26,57,18,10,102,102,213,34,20,43,117,20,15,
36,163,128,68,1,26,102,61,71,37,34,53,31,243,192,69,60,71,38,73,119,28,222,37,
68,45,128,34,1,47,11,245,171,62,17,19,70,146,85,55,62,70,37,43,37,154,100,163,
85,160,1,63,9,92,136,28,64,32,201,85,75,15,9,9,64,255,184,119,16,86,6,28,
5,64,255,25,248,1,56,8,17,132,137,255,55,116,128,58,15,20,82,135,57,26,121,40,
164,50,31,137,154,133,25,35,218,51,103,44,131,131,123,31,6,158,86,40,64,135,148,224,
45,183,128,22,26,17,131,240,154,14,1,209,45,16,21,91,64,222,7,1,197,56,21,39,
155,60,138,23,102,213,83,12,13,54,192,255,68,47,28,85,26,85,85,128,128,32,146,171,
18,11,7,63,144,171,4,4,246,35,27,10,146,174,171,12,26,128,190,80,35,99,180,80,
126,54,45,85,126,47,87,176,51,41,20,32,101,75,128,139,118,146,116,128,85,56,41,15,
176,236,85,37,9,62,71,30,17,119,118,255,17,18,138,101,38,60,138,55,70,43,26,142,
146,36,19,30,171,255,97,27,20,138,45,61,62,219,1,81,188,64,32,41,20,117,151,142,
20,21,163,112,19,12,61,195,128,48,4,24
}
local T_DC = {
4,5,6,7,8,9,10,10,11,12,13,14,15,16,17,17,18,19,20,20,21,21,22,22,
23,23,24,25,25,26,27,28,29,30,31,32,33,34,35,36,37,37,38,39,40,41,42,43,
44,45,46,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,
67,68,69,70,71,72,73,74,75,76,76,77,78,79,80,81,82,83,84,85,86,87,88,89,
91,93,95,96,98,100,101,102,104,106,108,110,112,114,116,118,122,124,126,128,130,132,134,136,
138,140,143,145,148,151,154,157
}
local T_AC = {
4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,
28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,
52,53,54,55,56,57,58,60,62,64,66,68,70,72,74,76,78,80,82,84,86,88,90,92,
94,96,98,100,102,104,106,108,110,112,114,116,119,122,125,128,131,134,137,140,143,146,149,152,
155,158,161,164,167,170,173,177,181,185,189,193,197,201,205,209,213,217,221,225,229,234,239,245,
249,254,259,264,269,274,279,284
}
local T_C2P = {
24,7,23,25,40,6,39,41,22,26,38,42,56,5,55,57,21,27,54,58,37,43,72,4,
71,73,20,28,53,59,70,74,36,44,88,69,75,52,60,3,87,89,19,29,86,90,35,45,
68,76,85,91,51,61,104,2,103,105,18,30,102,106,34,46,84,92,67,77,101,107,50,62,
120,1,119,121,83,93,17,31,100,108,66,78,118,122,33,47,117,123,49,63,99,109,82,94,
0,116,124,65,79,16,32,98,110,48,115,125,81,95,64,114,126,97,111,80,113,127,96,112
}
local bit = require 'bit'
local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift
local floor, abs, min, max = math.floor, math.abs, math.min, math.max
local sbyte = string.byte
local function u16(s, i) local a, b = sbyte(s, i, i + 1) return a + b * 256 end
local function u24(s, i) local a, b, c = sbyte(s, i, i + 2) return a + b * 256 + c * 65536 end
local function u32(s, i) local a, b, c, d = sbyte(s, i, i + 3) return a + b * 256 + c * 65536 + d * 16777216 end
local function clip(v) if v < 0 then return 0 elseif v > 255 then return 255 end return v end
local BANDS = { 0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0 }
local ZIGZAG = { 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 }
local CATS = { { 173, 148, 140 }, { 176, 155, 140, 135 }, { 180, 157, 141, 134, 130 },
    { 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 } }
local KY4 = { 0, 1, -1, 2, -2, 3, 4, 6, -3, 5, -4, -5, -6, 7, -7, 8, -8, -9 }
local function newBD(s, pos, size)
    local b0, b1 = sbyte(s, pos, pos + 1)
    return { s = s, p = pos + 2, e = pos + size, value = (b0 or 0) * 256 + (b1 or 0), range = 255, bits = 0 }
end
local function getBit(bd, prob)
    local range = bd.range
    local split = 1 + floor(((range - 1) * prob) / 256)
    local SPLIT = split * 256
    local v
    local value = bd.value
    if value >= SPLIT then
        v = 1
        range = range - split
        value = value - SPLIT
    else
        v = 0
        range = split
    end
    while range < 128 do
        value = value * 2
        range = range * 2
        local nb = bd.bits + 1
        if nb == 8 then
            nb = 0
            local p = bd.p
            if p < bd.e then value = value + sbyte(bd.s, p) end
            bd.p = p + 1
        end
        bd.bits = nb
    end
    bd.range = range
    bd.value = value
    return v
end
local function getValue(bd, n)
    local v = 0
    for _ = 1, n do v = v * 2 + getBit(bd, 128) end
    return v
end
local function getSigned(bd, n)
    local v = getValue(bd, n)
    if getBit(bd, 128) == 1 then return -v end
    return v
end
local function getLarge(bd, probs, base)
    local v
    if getBit(bd, probs[base + 4]) == 0 then
        if getBit(bd, probs[base + 5]) == 0 then v = 2 else v = 3 + getBit(bd, probs[base + 6]) end
    else
        if getBit(bd, probs[base + 7]) == 0 then
            if getBit(bd, probs[base + 8]) == 0 then
                v = 5 + getBit(bd, 159)
            else
                v = 7 + 2 * getBit(bd, 165)
                v = v + getBit(bd, 145)
            end
        else
            local bit1 = getBit(bd, probs[base + 9])
            local bit0 = getBit(bd, probs[base + 10 + bit1])
            local cat = 2 * bit1 + bit0
            local tab = CATS[cat + 1]
            v = 0
            for i = 1, #tab do v = v + v + getBit(bd, tab[i]) end
            v = v + 3 + 8 * (2 ^ cat)
        end
    end
    return v
end
local function getCoeffs(bd, probs, t, ctx, dcq, acq, n, out, ob)
    local base = (t * 8 + BANDS[n + 1]) * 33 + ctx * 11
    while n < 16 do
        if getBit(bd, probs[base + 1]) == 0 then return n end
        while getBit(bd, probs[base + 2]) == 0 do
            n = n + 1
            if n == 16 then return 16 end
            base = (t * 8 + BANDS[n + 1]) * 33
        end
        local nbase = (t * 8 + BANDS[n + 2]) * 33
        local v
        if getBit(bd, probs[base + 3]) == 0 then
            v = 1
            base = nbase + 11
        else
            v = getLarge(bd, probs, base)
            base = nbase + 22
        end
        if getBit(bd, 128) == 1 then v = -v end
        out[ob + ZIGZAG[n + 1] + 1] = v * (n > 0 and acq or dcq)
        n = n + 1
    end
    return 16
end
local function wht(inp, out)
    local tmp = {}
    for i = 0, 3 do
        local a0 = inp[1 + i] + inp[13 + i]
        local a1 = inp[5 + i] + inp[9 + i]
        local a2 = inp[5 + i] - inp[9 + i]
        local a3 = inp[1 + i] - inp[13 + i]
        tmp[1 + i] = a0 + a1
        tmp[9 + i] = a0 - a1
        tmp[5 + i] = a3 + a2
        tmp[13 + i] = a3 - a2
    end
    for i = 0, 3 do
        local dc = tmp[1 + i * 4] + 3
        local a0 = dc + tmp[4 + i * 4]
        local a1 = tmp[2 + i * 4] + tmp[3 + i * 4]
        local a2 = tmp[2 + i * 4] - tmp[3 + i * 4]
        local a3 = dc - tmp[4 + i * 4]
        out[(i * 4 + 0) * 16 + 1] = floor((a0 + a1) / 8)
        out[(i * 4 + 1) * 16 + 1] = floor((a3 + a2) / 8)
        out[(i * 4 + 2) * 16 + 1] = floor((a0 - a1) / 8)
        out[(i * 4 + 3) * 16 + 1] = floor((a3 - a2) / 8)
    end
end
local function mul1(a) return floor(a * 20091 / 65536) + a end
local function mul2(a) return floor(a * 35468 / 65536) end
local function idctAdd(coef, co, W, S, px, py)
    local tmp = {}
    for i = 0, 3 do
        local i0, i4, i8, i12 = coef[co + 1 + i], coef[co + 5 + i], coef[co + 9 + i], coef[co + 13 + i]
        local a, b = i0 + i8, i0 - i8
        local c = mul2(i4) - mul1(i12)
        local d = mul1(i4) + mul2(i12)
        tmp[4 * i + 1] = a + d
        tmp[4 * i + 2] = b + c
        tmp[4 * i + 3] = b - c
        tmp[4 * i + 4] = a - d
    end
    for i = 0, 3 do
        local dc = tmp[i + 1] + 4
        local a, b = dc + tmp[i + 9], dc - tmp[i + 9]
        local c = mul2(tmp[i + 5]) - mul1(tmp[i + 13])
        local d = mul1(tmp[i + 5]) + mul2(tmp[i + 13])
        local base = (py + i + 1) * S + px + 2
        W[base] = clip(W[base] + floor((a + d) / 8))
        W[base + 1] = clip(W[base + 1] + floor((b + c) / 8))
        W[base + 2] = clip(W[base + 2] + floor((b - c) / 8))
        W[base + 3] = clip(W[base + 3] + floor((a - d) / 8))
    end
end
local function wi(S, px, py) return (py + 1) * S + px + 2 end
local function predBig(W, S, N, mode, mbx, mby)
    if mode == 0 then
        local sum, dc = 0, 128
        if mby > 0 and mbx > 0 then
            for i = 0, N - 1 do sum = sum + W[wi(S, i, -1)] + W[wi(S, -1, i)] end
            dc = floor((sum + N) / (2 * N))
        elseif mby > 0 then
            for i = 0, N - 1 do sum = sum + W[wi(S, i, -1)] end
            dc = floor((sum + N / 2) / N)
        elseif mbx > 0 then
            for i = 0, N - 1 do sum = sum + W[wi(S, -1, i)] end
            dc = floor((sum + N / 2) / N)
        end
        for y = 0, N - 1 do for x = 0, N - 1 do W[wi(S, x, y)] = dc end end
    elseif mode == 1 then
        local corner = W[wi(S, -1, -1)]
        for y = 0, N - 1 do
            local l = W[wi(S, -1, y)] - corner
            for x = 0, N - 1 do W[wi(S, x, y)] = clip(l + W[wi(S, x, -1)]) end
        end
    elseif mode == 2 then
        for y = 0, N - 1 do for x = 0, N - 1 do W[wi(S, x, y)] = W[wi(S, x, -1)] end end
    else
        for y = 0, N - 1 do
            local l = W[wi(S, -1, y)]
            for x = 0, N - 1 do W[wi(S, x, y)] = l end
        end
    end
end
local function avg3(a, b, c) return floor((a + 2 * b + c + 2) / 4) end
local function avg2(a, b) return floor((a + b + 1) / 2) end
local function pred4(W, S, px, py, mode)
    local base = (py + 1) * S + px + 2
    local top = base - S
    local A, B, C, D, E, F, G, H = W[top], W[top + 1], W[top + 2], W[top + 3], W[top + 4], W[top + 5], W[top + 6], W[top + 7]
    local I, J, K, L = W[base - 1], W[base + S - 1], W[base + 2 * S - 1], W[base + 3 * S - 1]
    local X = W[top - 1]
    local o = {}
    local function d(x, y, v) o[y * 4 + x + 1] = v end
    if mode == 0 then
        local dc = floor((A + B + C + D + I + J + K + L + 4) / 8)
        for i = 1, 16 do o[i] = dc end
    elseif mode == 1 then
        local ls = { I, J, K, L }
        local ts = { A, B, C, D }
        for y = 0, 3 do for x = 0, 3 do d(x, y, clip(ls[y + 1] + ts[x + 1] - X)) end end
    elseif mode == 2 then
        local v = { avg3(X, A, B), avg3(A, B, C), avg3(B, C, D), avg3(C, D, E) }
        for y = 0, 3 do for x = 0, 3 do d(x, y, v[x + 1]) end end
    elseif mode == 3 then
        local v = { avg3(X, I, J), avg3(I, J, K), avg3(J, K, L), avg3(K, L, L) }
        for y = 0, 3 do for x = 0, 3 do d(x, y, v[y + 1]) end end
    elseif mode == 4 then
        d(0, 3, avg3(J, K, L))
        local v = avg3(I, J, K); d(1, 3, v); d(0, 2, v)
        v = avg3(X, I, J); d(2, 3, v); d(1, 2, v); d(0, 1, v)
        v = avg3(A, X, I); d(3, 3, v); d(2, 2, v); d(1, 1, v); d(0, 0, v)
        v = avg3(B, A, X); d(3, 2, v); d(2, 1, v); d(1, 0, v)
        v = avg3(C, B, A); d(3, 1, v); d(2, 0, v)
        d(3, 0, avg3(D, C, B))
    elseif mode == 5 then
        local v = avg2(X, A); d(0, 0, v); d(1, 2, v)
        v = avg2(A, B); d(1, 0, v); d(2, 2, v)
        v = avg2(B, C); d(2, 0, v); d(3, 2, v)
        d(3, 0, avg2(C, D))
        d(0, 3, avg3(K, J, I))
        d(0, 2, avg3(J, I, X))
        v = avg3(I, X, A); d(0, 1, v); d(1, 3, v)
        v = avg3(X, A, B); d(1, 1, v); d(2, 3, v)
        v = avg3(A, B, C); d(2, 1, v); d(3, 3, v)
        d(3, 1, avg3(B, C, D))
    elseif mode == 6 then
        d(0, 0, avg3(A, B, C))
        local v = avg3(B, C, D); d(1, 0, v); d(0, 1, v)
        v = avg3(C, D, E); d(2, 0, v); d(1, 1, v); d(0, 2, v)
        v = avg3(D, E, F); d(3, 0, v); d(2, 1, v); d(1, 2, v); d(0, 3, v)
        v = avg3(E, F, G); d(3, 1, v); d(2, 2, v); d(1, 3, v)
        v = avg3(F, G, H); d(3, 2, v); d(2, 3, v)
        d(3, 3, avg3(G, H, H))
    elseif mode == 7 then
        d(0, 0, avg2(A, B))
        local v = avg2(B, C); d(1, 0, v); d(0, 2, v)
        v = avg2(C, D); d(2, 0, v); d(1, 2, v)
        v = avg2(D, E); d(3, 0, v); d(2, 2, v)
        d(0, 1, avg3(A, B, C))
        v = avg3(B, C, D); d(1, 1, v); d(0, 3, v)
        v = avg3(C, D, E); d(2, 1, v); d(1, 3, v)
        v = avg3(D, E, F); d(3, 1, v); d(2, 3, v)
        d(3, 2, avg3(E, F, G))
        d(3, 3, avg3(F, G, H))
    elseif mode == 8 then
        local v = avg2(I, X); d(0, 0, v); d(2, 1, v)
        v = avg2(J, I); d(0, 1, v); d(2, 2, v)
        v = avg2(K, J); d(0, 2, v); d(2, 3, v)
        d(0, 3, avg2(L, K))
        d(3, 0, avg3(A, B, C))
        d(2, 0, avg3(X, A, B))
        v = avg3(I, X, A); d(1, 0, v); d(3, 1, v)
        v = avg3(J, I, X); d(1, 1, v); d(3, 2, v)
        v = avg3(K, J, I); d(1, 2, v); d(3, 3, v)
        d(1, 3, avg3(L, K, J))
    else
        d(0, 0, avg2(I, J))
        local v = avg2(J, K); d(2, 0, v); d(0, 1, v)
        v = avg2(K, L); d(2, 1, v); d(0, 2, v)
        d(1, 0, avg3(I, J, K))
        v = avg3(J, K, L); d(3, 0, v); d(1, 1, v)
        v = avg3(K, L, L); d(3, 1, v); d(1, 2, v)
        d(3, 2, L); d(2, 2, L); d(0, 3, L); d(1, 3, L); d(2, 3, L); d(3, 3, L)
    end
    for y = 0, 3 do
        for x = 0, 3 do W[base + y * S + x] = o[y * 4 + x + 1] end
    end
end
local function sclip1(v) if v < -128 then return -128 elseif v > 127 then return 127 end return v end
local function sclip2(v) if v < -16 then return -16 elseif v > 15 then return 15 end return v end
local function doFilter2(P, p, st)
    local p1, p0, q0, q1 = P[p - 2 * st], P[p - st], P[p], P[p + st]
    local a = 3 * (q0 - p0) + sclip1(p1 - q1)
    local a1 = sclip2(floor((a + 4) / 8))
    local a2 = sclip2(floor((a + 3) / 8))
    P[p - st] = clip(p0 + a2)
    P[p] = clip(q0 - a1)
end
local function doFilter4(P, p, st)
    local p1, p0, q0, q1 = P[p - 2 * st], P[p - st], P[p], P[p + st]
    local a = 3 * (q0 - p0)
    local a1 = sclip2(floor((a + 4) / 8))
    local a2 = sclip2(floor((a + 3) / 8))
    local a3 = floor((a1 + 1) / 2)
    P[p - 2 * st] = clip(p1 + a3)
    P[p - st] = clip(p0 + a2)
    P[p] = clip(q0 - a1)
    P[p + st] = clip(q1 - a3)
end
local function doFilter6(P, p, st)
    local p2, p1, p0 = P[p - 3 * st], P[p - 2 * st], P[p - st]
    local q0, q1, q2 = P[p], P[p + st], P[p + 2 * st]
    local a = sclip1(3 * (q0 - p0) + sclip1(p1 - q1))
    local a1 = floor((27 * a + 63) / 128)
    local a2 = floor((18 * a + 63) / 128)
    local a3 = floor((9 * a + 63) / 128)
    P[p - 3 * st] = clip(p2 + a3)
    P[p - 2 * st] = clip(p1 + a2)
    P[p - st] = clip(p0 + a1)
    P[p] = clip(q0 - a1)
    P[p + st] = clip(q1 - a2)
    P[p + 2 * st] = clip(q2 - a3)
end
local function hev(P, p, st, th)
    return abs(P[p - 2 * st] - P[p - st]) > th or abs(P[p + st] - P[p]) > th
end
local function needs1(P, p, st, t)
    return 4 * abs(P[p - st] - P[p]) + abs(P[p - 2 * st] - P[p + st]) <= t
end
local function needs2(P, p, st, t, it)
    local p3, p2, p1, p0 = P[p - 4 * st], P[p - 3 * st], P[p - 2 * st], P[p - st]
    local q0, q1, q2, q3 = P[p], P[p + st], P[p + 2 * st], P[p + 3 * st]
    if 4 * abs(p0 - q0) + abs(p1 - q1) > t then return false end
    return abs(p3 - p2) <= it and abs(p2 - p1) <= it and abs(p1 - p0) <= it
        and abs(q3 - q2) <= it and abs(q2 - q1) <= it and abs(q1 - q0) <= it
end
local function loop26(P, p, hs, vs, size, thresh, ith, hth)
    local t2 = 2 * thresh + 1
    for _ = 1, size do
        if needs2(P, p, hs, t2, ith) then
            if hev(P, p, hs, hth) then doFilter2(P, p, hs) else doFilter6(P, p, hs) end
        end
        p = p + vs
    end
end
local function loop24(P, p, hs, vs, size, thresh, ith, hth)
    local t2 = 2 * thresh + 1
    for _ = 1, size do
        if needs2(P, p, hs, t2, ith) then
            if hev(P, p, hs, hth) then doFilter2(P, p, hs) else doFilter4(P, p, hs) end
        end
        p = p + vs
    end
end
local function simpleLoop(P, p, hs, vs, thresh)
    local t2 = 2 * thresh + 1
    for _ = 1, 16 do
        if needs1(P, p, hs, t2) then doFilter2(P, p, hs) end
        p = p + vs
    end
end
local function dqIdx(q, mx) if q < 0 then return 0 elseif q > mx then return mx end return q end
local function decodeVP8Planes(s, pos, size)
    local b0, b1, b2 = sbyte(s, pos, pos + 2)
    local tag = b0 + b1 * 256 + b2 * 65536
    if tag % 2 ~= 0 then error('VP8: не ключевой кадр') end
    local firstSize = floor(tag / 32)
    local c0, c1, c2 = sbyte(s, pos + 3, pos + 5)
    if c0 ~= 0x9d or c1 ~= 0x01 or c2 ~= 0x2a then error('VP8: нет стартового кода') end
    local w = u16(s, pos + 6) % 16384
    local h = u16(s, pos + 8) % 16384
    local bd = newBD(s, pos + 10, firstSize)
    local mbw, mbh = floor((w + 15) / 16), floor((h + 15) / 16)
    getValue(bd, 1)
    getValue(bd, 1)
    local useSeg, updateMap, absDelta = getValue(bd, 1), 0, 0
    local segQ, segF, segP = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 255, 255, 255 }
    if useSeg == 1 then
        updateMap = getValue(bd, 1)
        if getValue(bd, 1) == 1 then
            absDelta = getValue(bd, 1)
            for i = 1, 4 do segQ[i] = (getValue(bd, 1) == 1) and getSigned(bd, 7) or 0 end
            for i = 1, 4 do segF[i] = (getValue(bd, 1) == 1) and getSigned(bd, 6) or 0 end
        end
        if updateMap == 1 then
            for i = 1, 3 do segP[i] = (getValue(bd, 1) == 1) and getValue(bd, 8) or 255 end
        end
    end
    local simple = getValue(bd, 1)
    local level = getValue(bd, 6)
    local sharp = getValue(bd, 3)
    local useDelta = getValue(bd, 1)
    local refD, modeD = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
    if useDelta == 1 then
        if getValue(bd, 1) == 1 then
            for i = 1, 4 do if getValue(bd, 1) == 1 then refD[i] = getSigned(bd, 6) end end
            for i = 1, 4 do if getValue(bd, 1) == 1 then modeD[i] = getSigned(bd, 6) end end
        end
    end
    local filterType = (level == 0) and 0 or (simple == 1 and 1 or 2)
    local nparts = 2 ^ getValue(bd, 2)
    local partsStart = pos + 10 + firstSize
    local dataPos = partsStart + 3 * (nparts - 1)
    local endPos = pos + size
    local tbds = {}
    for i = 1, nparts do
        local psz
        if i < nparts then psz = u24(s, partsStart + 3 * (i - 1)) else psz = endPos - dataPos end
        if psz < 0 then psz = 0 end
        tbds[i] = newBD(s, dataPos, psz)
        dataPos = dataPos + psz
    end
    local baseQ = getValue(bd, 7)
    local function dq() if getValue(bd, 1) == 1 then return getSigned(bd, 4) end return 0 end
    local dqy1dc, dqy2dc, dqy2ac, dquvdc, dquvac = dq(), dq(), dq(), dq(), dq()
    local dqm = {}
    for i = 1, 4 do
        local q
        if useSeg == 1 then
            q = segQ[i]
            if absDelta == 0 then q = q + baseQ end
        else
            q = baseQ
        end
        local m = {}
        m.y1dc = T_DC[dqIdx(q + dqy1dc, 127) + 1]
        m.y1ac = T_AC[dqIdx(q, 127) + 1]
        m.y2dc = T_DC[dqIdx(q + dqy2dc, 127) + 1] * 2
        m.y2ac = floor(T_AC[dqIdx(q + dqy2ac, 127) + 1] * 101581 / 65536)
        if m.y2ac < 8 then m.y2ac = 8 end
        m.uvdc = T_DC[dqIdx(q + dquvdc, 117) + 1]
        m.uvac = T_AC[dqIdx(q + dquvac, 127) + 1]
        dqm[i] = m
    end
    getValue(bd, 1)
    local probs = {}
    for i = 1, 1056 do
        if getBit(bd, T_UPD[i]) == 1 then probs[i] = getValue(bd, 8) else probs[i] = T_COEF0[i] end
    end
    local useSkip, skipP = getValue(bd, 1), 0
    if useSkip == 1 then skipP = getValue(bd, 8) end
    local fstr = {}
    if filterType > 0 then
        for sgi = 1, 4 do
            fstr[sgi] = {}
            local baseLevel
            if useSeg == 1 then
                baseLevel = segF[sgi]
                if absDelta == 0 then baseLevel = baseLevel + level end
            else
                baseLevel = level
            end
            for i4 = 0, 1 do
                local lv = baseLevel
                if useDelta == 1 then
                    lv = lv + refD[1]
                    if i4 == 1 then lv = lv + modeD[1] end
                end
                if lv < 0 then lv = 0 elseif lv > 63 then lv = 63 end
                local info = { limit = 0, inner = i4 }
                if lv > 0 then
                    local il = lv
                    if sharp > 0 then
                        if sharp > 4 then il = floor(il / 4) else il = floor(il / 2) end
                        if il > 9 - sharp then il = 9 - sharp end
                    end
                    if il < 1 then il = 1 end
                    info.ilevel = il
                    info.limit = 2 * lv + il
                    info.hth = (lv >= 40) and 2 or ((lv >= 15) and 1 or 0)
                end
                fstr[sgi][i4 + 1] = info
            end
        end
    end
    local ys, uvs = mbw * 16, mbw * 8
    local Y, U, V = {}, {}, {}
    local topNz, topModes = {}, {}
    for i = 1, mbw do topNz[i] = { 0, 0, 0, 0, 0, 0, 0, 0, 0 } end
    for i = 1, 4 * mbw do topModes[i] = 0 end
    local finfo = {}
    local coeffs, y2 = {}, {}
    local WY, WU, WV = {}, {}, {}
    local SY, SU = 21, 9
    for mby = 0, mbh - 1 do
        local tbd = tbds[(mby % nparts) + 1]
        local leftNz = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
        local leftModes = { 0, 0, 0, 0 }
        for mbx = 0, mbw - 1 do
            local seg = 0
            if updateMap == 1 then
                if getBit(bd, segP[1]) == 0 then seg = getBit(bd, segP[2]) else seg = getBit(bd, segP[3]) + 2 end
            end
            local skip = 0
            if useSkip == 1 then skip = getBit(bd, skipP) end
            local isI4 = (getBit(bd, 145) == 0)
            local ymode
            local imodes = {}
            if not isI4 then
                if getBit(bd, 156) == 1 then
                    if getBit(bd, 128) == 1 then ymode = 1 else ymode = 3 end
                else
                    if getBit(bd, 163) == 1 then ymode = 2 else ymode = 0 end
                end
                for i = 1, 4 do topModes[4 * mbx + i] = ymode; leftModes[i] = ymode end
            else
                for y = 0, 3 do
                    local lm = leftModes[y + 1]
                    for x = 0, 3 do
                        local pb = (topModes[4 * mbx + x + 1] * 10 + lm) * 9
                        local i = KY4[getBit(bd, T_BMODES[pb + 1]) + 1]
                        while i > 0 do
                            i = KY4[2 * i + getBit(bd, T_BMODES[pb + i + 1]) + 1]
                        end
                        lm = -i
                        imodes[y * 4 + x + 1] = lm
                        topModes[4 * mbx + x + 1] = lm
                    end
                    leftModes[y + 1] = lm
                end
            end
            local uvmode
            if getBit(bd, 142) == 0 then uvmode = 0
            elseif getBit(bd, 114) == 0 then uvmode = 2
            elseif getBit(bd, 183) == 1 then uvmode = 1
            else uvmode = 3 end
            for i = 1, 384 do coeffs[i] = 0 end
            local tnz = topNz[mbx + 1]
            local nzAny = false
            local dqs = dqm[seg + 1]
            if skip == 0 then
                local first, tY
                if not isI4 then
                    for i = 1, 16 do y2[i] = 0 end
                    local ctx = tnz[9] + leftNz[9]
                    local nz = getCoeffs(tbd, probs, 1, ctx, dqs.y2dc, dqs.y2ac, 0, y2, 0)
                    local f = (nz > 0) and 1 or 0
                    tnz[9], leftNz[9] = f, f
                    if nz > 1 then
                        wht(y2, coeffs)
                    else
                        local dc0 = floor((y2[1] + 3) / 8)
                        for i = 0, 15 do coeffs[i * 16 + 1] = dc0 end
                    end
                    first, tY = 1, 0
                else
                    first, tY = 0, 3
                end
                for y = 0, 3 do
                    local l = leftNz[y + 1]
                    for x = 0, 3 do
                        local ctx = l + tnz[x + 1]
                        local nz = getCoeffs(tbd, probs, tY, ctx, dqs.y1dc, dqs.y1ac, first, coeffs, (y * 4 + x) * 16)
                        l = (nz > first) and 1 or 0
                        tnz[x + 1] = l
                        if nz > 1 or coeffs[(y * 4 + x) * 16 + 1] ~= 0 then nzAny = true end
                    end
                    leftNz[y + 1] = l
                end
                for ch = 0, 2, 2 do
                    for y = 0, 1 do
                        local l = leftNz[5 + ch + y]
                        for x = 0, 1 do
                            local ctx = l + tnz[5 + ch + x]
                            local nz = getCoeffs(tbd, probs, 2, ctx, dqs.uvdc, dqs.uvac, 0, coeffs, 256 + (ch * 2 + y * 2 + x) * 16)
                            l = (nz > 0) and 1 or 0
                            tnz[5 + ch + x] = l
                            if nz > 0 then nzAny = true end
                        end
                        leftNz[5 + ch + y] = l
                    end
                end
            else
                for i = 1, 8 do tnz[i] = 0; leftNz[i] = 0 end
                if not isI4 then tnz[9] = 0; leftNz[9] = 0 end
            end
            if filterType > 0 then
                local fi = fstr[seg + 1][(isI4 and 2 or 1)]
                finfo[mby * mbw + mbx + 1] = { limit = fi.limit, ilevel = fi.ilevel, hth = fi.hth,
                    inner = (fi.inner == 1 or nzAny) }
            end
            local x0, y0 = mbx * 16, mby * 16
            for i = 0, 15 do
                WY[wi(SY, i, -1)] = (mby > 0) and Y[(y0 - 1) * ys + x0 + i + 1] or 127
                WY[wi(SY, -1, i)] = (mbx > 0) and Y[(y0 + i) * ys + x0 - 1 + 1] or 129
            end
            if mby == 0 then WY[wi(SY, -1, -1)] = 127
            elseif mbx == 0 then WY[wi(SY, -1, -1)] = 129
            else WY[wi(SY, -1, -1)] = Y[(y0 - 1) * ys + x0 - 1 + 1] end
            for i = 16, 19 do
                local v
                if mby == 0 then v = 127
                elseif mbx == mbw - 1 then v = Y[(y0 - 1) * ys + x0 + 15 + 1]
                else v = Y[(y0 - 1) * ys + x0 + i + 1] end
                WY[wi(SY, i, -1)] = v
                WY[wi(SY, i, 3)] = v
                WY[wi(SY, i, 7)] = v
                WY[wi(SY, i, 11)] = v
            end
            local cx0, cy0 = mbx * 8, mby * 8
            for pl = 1, 2 do
                local W, P = (pl == 1) and WU or WV, (pl == 1) and U or V
                for i = 0, 7 do
                    W[wi(SU, i, -1)] = (mby > 0) and P[(cy0 - 1) * uvs + cx0 + i + 1] or 127
                    W[wi(SU, -1, i)] = (mbx > 0) and P[(cy0 + i) * uvs + cx0 - 1 + 1] or 129
                end
                if mby == 0 then W[wi(SU, -1, -1)] = 127
                elseif mbx == 0 then W[wi(SU, -1, -1)] = 129
                else W[wi(SU, -1, -1)] = P[(cy0 - 1) * uvs + cx0 - 1 + 1] end
            end
            if not isI4 then
                predBig(WY, SY, 16, ymode, mbx, mby)
                for by = 0, 3 do for bx = 0, 3 do
                    idctAdd(coeffs, (by * 4 + bx) * 16, WY, SY, bx * 4, by * 4)
                end end
            else
                for by = 0, 3 do for bx = 0, 3 do
                    pred4(WY, SY, bx * 4, by * 4, imodes[by * 4 + bx + 1])
                    idctAdd(coeffs, (by * 4 + bx) * 16, WY, SY, bx * 4, by * 4)
                end end
            end
            predBig(WU, SU, 8, uvmode, mbx, mby)
            predBig(WV, SU, 8, uvmode, mbx, mby)
            for by = 0, 1 do for bx = 0, 1 do
                idctAdd(coeffs, 256 + (by * 2 + bx) * 16, WU, SU, bx * 4, by * 4)
                idctAdd(coeffs, 256 + (4 + by * 2 + bx) * 16, WV, SU, bx * 4, by * 4)
            end end
            for y = 0, 15 do
                local o = (y0 + y) * ys + x0 + 1
                for x = 0, 15 do Y[o + x] = WY[wi(SY, x, y)] end
            end
            for y = 0, 7 do
                local o = (cy0 + y) * uvs + cx0 + 1
                for x = 0, 7 do
                    U[o + x] = WU[wi(SU, x, y)]
                    V[o + x] = WV[wi(SU, x, y)]
                end
            end
        end
    end
    if filterType > 0 then
        for mby = 0, mbh - 1 do
            for mbx = 0, mbw - 1 do
                local fi = finfo[mby * mbw + mbx + 1]
                if fi.limit > 0 then
                    local yp = (mby * 16) * ys + mbx * 16 + 1
                    local up = (mby * 8) * uvs + mbx * 8 + 1
                    local limit = fi.limit
                    if filterType == 1 then
                        if mbx > 0 then simpleLoop(Y, yp, 1, ys, limit + 4) end
                        if fi.inner then for k = 1, 3 do simpleLoop(Y, yp + 4 * k, 1, ys, limit) end end
                        if mby > 0 then simpleLoop(Y, yp, ys, 1, limit + 4) end
                        if fi.inner then for k = 1, 3 do simpleLoop(Y, yp + 4 * k * ys, ys, 1, limit) end end
                    else
                        local il, ht = fi.ilevel, fi.hth
                        if mbx > 0 then
                            loop26(Y, yp, 1, ys, 16, limit + 4, il, ht)
                            loop26(U, up, 1, uvs, 8, limit + 4, il, ht)
                            loop26(V, up, 1, uvs, 8, limit + 4, il, ht)
                        end
                        if fi.inner then
                            for k = 1, 3 do loop24(Y, yp + 4 * k, 1, ys, 16, limit, il, ht) end
                            loop24(U, up + 4, 1, uvs, 8, limit, il, ht)
                            loop24(V, up + 4, 1, uvs, 8, limit, il, ht)
                        end
                        if mby > 0 then
                            loop26(Y, yp, ys, 1, 16, limit + 4, il, ht)
                            loop26(U, up, uvs, 1, 8, limit + 4, il, ht)
                            loop26(V, up, uvs, 1, 8, limit + 4, il, ht)
                        end
                        if fi.inner then
                            for k = 1, 3 do loop24(Y, yp + 4 * k * ys, ys, 1, 16, limit, il, ht) end
                            loop24(U, up + 4 * uvs, uvs, 1, 8, limit, il, ht)
                            loop24(V, up + 4 * uvs, uvs, 1, 8, limit, il, ht)
                        end
                    end
                end
            end
        end
    end
    return w, h, Y, U, V, ys, uvs
end
local function multHi(v, c) return floor(v * c / 256) end
local function clip8(v)
    if v >= 0 and v < 16384 then return floor(v / 64) end
    if v < 0 then return 0 end
    return 255
end
local function yuv2rgb(y, u, v)
    local yy = multHi(y, 19077)
    return clip8(yy + multHi(v, 26149) - 14234),
        clip8(yy - multHi(u, 6419) - multHi(v, 13320) + 8708),
        clip8(yy + multHi(u, 33050) - 17685)
end
local function upsampleRows(w, h, Y, U, V, ys, uvs)
    local rgb = {}
    local cw = floor((w + 1) / 2)
    local function chroma(P, row)
        local r, o = {}, row * uvs
        for i = 1, cw do r[i] = P[o + i] end
        return r
    end
    local function pair(ytop, ybot, tu, tv, cu, cv)
        local function emit(yrow, uarr, varr)
            local yo = yrow * ys
            local ro = yrow * w * 3
            for x = 0, w - 1 do
                local r, g, b = yuv2rgb(Y[yo + x + 1], uarr[x], varr[x])
                rgb[ro + x * 3 + 1], rgb[ro + x * 3 + 2], rgb[ro + x * 3 + 3] = r, g, b
            end
        end
        local function interp(ta, ca, bottomRow)
            local out = {}
            local last = floor((w - 1) / 2)
            local tl, l = ta[1], ca[1]
            local function first(a, b) return floor((3 * a + b + 2) / 4) end
            if bottomRow then out[0] = first(l, tl) else out[0] = first(tl, l) end
            local o1 = {}
            for x = 1, last do
                local t, c = ta[x + 1], ca[x + 1]
                local avg = tl + t + l + c + 8
                local d12 = floor((avg + 2 * (t + l)) / 8)
                local d03 = floor((avg + 2 * (tl + c)) / 8)
                if not bottomRow then
                    out[2 * x - 1] = floor((d12 + tl) / 2)
                    out[2 * x] = floor((d03 + t) / 2)
                else
                    out[2 * x - 1] = floor((d03 + l) / 2)
                    out[2 * x] = floor((d12 + c) / 2)
                end
                tl, l = t, c
            end
            if w % 2 == 0 then
                if bottomRow then out[w - 1] = first(l, tl) else out[w - 1] = first(tl, l) end
            end
            return out
        end
        emit(ytop, interp(tu, cu, false), interp(tv, cv, false))
        if ybot then emit(ybot, interp(tu, cu, true), interp(tv, cv, true)) end
    end
    local c0u, c0v = chroma(U, 0), chroma(V, 0)
    pair(0, nil, c0u, c0v, c0u, c0v)
    local k = 1
    local tu, tv = c0u, c0v
    while 2 * k - 1 < h do
        local ytop = 2 * k - 1
        local ybot = 2 * k
        if ybot >= h then ybot = nil end
        local cu, cv
        if ybot then
            cu, cv = chroma(U, k), chroma(V, k)
            pair(ytop, ybot, tu, tv, cu, cv)
        else
            pair(ytop, nil, tu, tv, tu, tv)
        end
        if ybot then tu, tv = cu, cv end
        k = k + 1
    end
    return rgb
end
local POW2 = {}
for i = 0, 40 do POW2[i] = 2 ^ i end
local function newBR(s, pos, e)
    return { s = s, p = pos, e = e, val = 0, cnt = 0 }
end
local function rb(br, n)
    if n == 0 then return 0 end
    while br.cnt < n do
        local p = br.p
        local b = 0
        if p <= br.e then b = sbyte(br.s, p) or 0 end
        br.val = br.val + b * POW2[br.cnt]
        br.cnt = br.cnt + 8
        br.p = p + 1
    end
    local r = br.val % POW2[n]
    br.val = floor(br.val / POW2[n])
    br.cnt = br.cnt - n
    return r
end
local function buildHuff(lens, n)
    local count = {}
    for l = 0, 15 do count[l] = 0 end
    local nonzero, last = 0, 0
    for i = 1, n do
        local l = lens[i] or 0
        if l > 0 then count[l] = count[l] + 1; nonzero = nonzero + 1; last = i - 1 end
    end
    if nonzero == 0 then return { single = 0 } end
    if nonzero == 1 then return { single = last } end
    local offs = {}
    offs[1] = 0
    for l = 1, 15 do offs[l + 1] = offs[l] + count[l] end
    local sorted = {}
    for i = 1, n do
        local l = lens[i] or 0
        if l > 0 then
            sorted[offs[l] + 1] = i - 1
            offs[l] = offs[l] + 1
        end
    end
    return { count = count, sorted = sorted }
end
local function readSym(br, h)
    if h.single then return h.single end
    local code, first, index = 0, 0, 0
    local count = h.count
    for len = 1, 15 do
        code = code + rb(br, 1)
        local c = count[len]
        if code - c < first then return h.sorted[index + (code - first) + 1] end
        index = index + c
        first = (first + c) * 2
        code = code * 2
    end
    error('VP8L: плохой код Хаффмана')
end
local CL_ORDER = { 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }
local function readHuffCode(br, alphabet)
    local lens = {}
    if rb(br, 1) == 1 then
        local nsym = rb(br, 1) + 1
        local firstBits = rb(br, 1)
        local s0 = rb(br, firstBits == 0 and 1 or 8)
        lens[s0 + 1] = 1
        if nsym == 2 then
            local s1 = rb(br, 8)
            lens[s1 + 1] = 1
        end
        return buildHuff(lens, alphabet)
    end
    local ncodes = rb(br, 4) + 4
    local cll = {}
    for i = 1, 19 do cll[i] = 0 end
    for i = 1, ncodes do cll[CL_ORDER[i] + 1] = rb(br, 3) end
    local clh = buildHuff(cll, 19)
    local maxSym
    if rb(br, 1) == 1 then
        local lnb = 2 + 2 * rb(br, 3)
        maxSym = 2 + rb(br, lnb)
    else
        maxSym = alphabet
    end
    local sym, prev = 0, 8
    while sym < alphabet do
        if maxSym == 0 then break end
        maxSym = maxSym - 1
        local cl = readSym(br, clh)
        if cl < 16 then
            lens[sym + 1] = cl
            sym = sym + 1
            if cl ~= 0 then prev = cl end
        else
            local useprev = (cl == 16)
            local slot = cl - 16
            local extra = (slot == 0) and 2 or ((slot == 1) and 3 or 7)
            local off = (slot == 2) and 11 or 3
            local rep = rb(br, extra) + off
            if sym + rep > alphabet then error('VP8L: повтор длин за пределом') end
            local len = useprev and prev or 0
            for _ = 1, rep do lens[sym + 1] = len; sym = sym + 1 end
        end
    end
    return buildHuff(lens, alphabet)
end
local function prefixValue(br, prefix)
    if prefix < 4 then return prefix + 1 end
    local extra = floor((prefix - 2) / 2)
    local offset = (2 + (prefix % 2)) * POW2[extra]
    return offset + rb(br, extra) + 1
end
local function ch4(x)
    return floor(x / 16777216), floor(x / 65536) % 256, floor(x / 256) % 256, x % 256
end
local function pack4(a, r, g, b) return a * 16777216 + r * 65536 + g * 256 + b end
local function mul32(a, b)
    local lo = b % 65536
    local hi = floor(b / 65536)
    return ((a * lo) % 4294967296 + ((a * hi) % 65536) * 65536) % 4294967296
end
local decodeImageStream
local function applyInverse(tr, px, w, h)
    local t = tr.type
    if t == 2 then
        for i = 1, w * h do
            local a, r, g, b = ch4(px[i])
            px[i] = pack4(a, (r + g) % 256, g, (b + g) % 256)
        end
        return px, w
    elseif t == 1 then
        local bits, bw, timg = tr.bits, tr.bw, tr.img
        local function s8(v) if v > 127 then return v - 256 end return v end
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local code = timg[(floor(y / POW2[bits])) * bw + floor(x / POW2[bits]) + 1]
                local _, cr, cg, cb = ch4(code)
                local g2r, g2b, r2b = cb, cg, cr
                local i = y * w + x + 1
                local a, r, g, b = ch4(px[i])
                local sg = s8(g)
                local nr = (r + floor((s8(g2r) * sg) / 32)) % 256
                local nb = (b + floor((s8(g2b) * sg) / 32) + floor((s8(r2b) * s8(nr)) / 32)) % 256
                px[i] = pack4(a, nr, g, nb)
            end
        end
        return px, w
    elseif t == 0 then
        local bits, bw, timg = tr.bits, tr.bw, tr.img
        local function avg2(a, b)
            local aa, ar, ag, ab = ch4(a)
            local ba, br_, bg, bb = ch4(b)
            return pack4(floor((aa + ba) / 2), floor((ar + br_) / 2), floor((ag + bg) / 2), floor((ab + bb) / 2))
        end
        local function addpx(a, b)
            local aa, ar, ag, ab = ch4(a)
            local ba, br_, bg, bb = ch4(b)
            return pack4((aa + ba) % 256, (ar + br_) % 256, (ag + bg) % 256, (ab + bb) % 256)
        end
        local function pr(mode, L, T, TR, TL)
            if mode == 0 then return 0xFF000000
            elseif mode == 1 then return L
            elseif mode == 2 then return T
            elseif mode == 3 then return TR
            elseif mode == 4 then return TL
            elseif mode == 5 then return avg2(avg2(L, TR), T)
            elseif mode == 6 then return avg2(L, TL)
            elseif mode == 7 then return avg2(L, T)
            elseif mode == 8 then return avg2(TL, T)
            elseif mode == 9 then return avg2(T, TR)
            elseif mode == 10 then return avg2(avg2(L, TL), avg2(T, TR))
            elseif mode == 11 then
                local la, lr, lg, lb = ch4(L)
                local ta, tr_, tg, tb = ch4(T)
                local ca, cr, cg, cb = ch4(TL)
                local pL = abs(ta - ca) + abs(tr_ - cr) + abs(tg - cg) + abs(tb - cb)
                local pT = abs(la - ca) + abs(lr - cr) + abs(lg - cg) + abs(lb - cb)
                if pL < pT then return L else return T end
            elseif mode == 12 then
                local la, lr, lg, lb = ch4(L)
                local ta, tr_, tg, tb = ch4(T)
                local ca, cr, cg, cb = ch4(TL)
                return pack4(clip(la + ta - ca), clip(lr + tr_ - cr), clip(lg + tg - cg), clip(lb + tb - cb))
            elseif mode == 13 then
                local av = avg2(L, T)
                local aa, ar, ag, ab = ch4(av)
                local ca, cr, cg, cb = ch4(TL)
                local function hf(a, b)
                    local d = a - b
                    if d >= 0 then d = floor(d / 2) else d = -floor(-d / 2) end
                    return clip(a + d)
                end
                return pack4(hf(aa, ca), hf(ar, cr), hf(ag, cg), hf(ab, cb))
            end
            return 0xFF000000
        end
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local i = y * w + x + 1
                local pred
                if y == 0 then
                    if x == 0 then pred = 0xFF000000 else pred = px[i - 1] end
                elseif x == 0 then
                    pred = px[i - w]
                else
                    local mode = floor(timg[floor(y / POW2[bits]) * bw + floor(x / POW2[bits]) + 1] / 256) % 16
                    pred = pr(mode, px[i - 1], px[i - w], px[i - w + 1], px[i - w - 1])
                end
                px[i] = addpx(px[i], pred)
            end
        end
        return px, w
    else
        local pal, np = tr.pal, tr.ncol
        local wb = tr.bits
        local ow = tr.xsize
        local out = {}
        if wb == 0 then
            for i = 1, ow * h do
                local idx = floor(px[i] / 256) % 256
                out[i] = (idx < np) and pal[idx + 1] or 0
            end
        else
            local bpp = 8 / POW2[wb]
            local mask = POW2[bpp] - 1
            local pw = tr.pw
            for y = 0, h - 1 do
                for x = 0, ow - 1 do
                    local packed = floor(px[y * pw + floor(x / POW2[wb]) + 1] / 256) % 256
                    local idx = floor(packed / POW2[(x % POW2[wb]) * bpp]) % POW2[bpp]
                    out[y * ow + x + 1] = (idx < np) and pal[idx + 1] or 0
                end
            end
        end
        return out, ow
    end
end
local DIST_MAP = T_C2P
decodeImageStream = function(br, xsize, ysize, level0)
    local transforms = {}
    local origX = xsize
    if level0 then
        while rb(br, 1) == 1 do
            local tt = rb(br, 2)
            local tr = { type = tt, xsize = xsize }
            if tt == 0 or tt == 1 then
                tr.bits = rb(br, 3) + 2
                tr.bw = floor((xsize + POW2[tr.bits] - 1) / POW2[tr.bits])
                local bh = floor((ysize + POW2[tr.bits] - 1) / POW2[tr.bits])
                tr.img = decodeImageStream(br, tr.bw, bh, false)
            elseif tt == 3 then
                local ncol = rb(br, 8) + 1
                local bits = (ncol > 16) and 0 or ((ncol > 4) and 1 or ((ncol > 2) and 2 or 3))
                local pal = decodeImageStream(br, ncol, 1, false)
                for i = 2, ncol do
                    local pa, pr_, pg, pb = ch4(pal[i - 1])
                    local ca, cr, cg, cb = ch4(pal[i])
                    pal[i] = pack4((pa + ca) % 256, (pr_ + cr) % 256, (pg + cg) % 256, (pb + cb) % 256)
                end
                tr.pal, tr.ncol, tr.bits = pal, ncol, bits
                tr.pw = floor((xsize + POW2[bits] - 1) / POW2[bits])
                xsize = tr.pw
            end
            transforms[#transforms + 1] = tr
        end
    end
    local cacheBits = 0
    if rb(br, 1) == 1 then
        cacheBits = rb(br, 4)
        if cacheBits < 1 or cacheBits > 11 then error('VP8L: плохой размер кэша') end
    end
    local metaBits, metaW, meta, ngroups = 0, 0, nil, 1
    if level0 and rb(br, 1) == 1 then
        metaBits = rb(br, 3) + 2
        metaW = floor((xsize + POW2[metaBits] - 1) / POW2[metaBits])
        local mh = floor((ysize + POW2[metaBits] - 1) / POW2[metaBits])
        meta = decodeImageStream(br, metaW, mh, false)
        for i = 1, metaW * mh do
            local g = floor(meta[i] / 256) % 65536
            meta[i] = g
            if g + 1 > ngroups then ngroups = g + 1 end
        end
    end
    local cacheSize = (cacheBits > 0) and POW2[cacheBits] or 0
    local groups = {}
    for g = 1, ngroups do
        groups[g] = {
            readHuffCode(br, 256 + 24 + cacheSize),
            readHuffCode(br, 256),
            readHuffCode(br, 256),
            readHuffCode(br, 256),
            readHuffCode(br, 40),
        }
    end
    local total = xsize * ysize
    local px = {}
    local cache = {}
    local pos = 0
    while pos < total do
        local x, y = pos % xsize, floor(pos / xsize)
        local grp = groups[1]
        if meta then grp = groups[meta[floor(y / POW2[metaBits]) * metaW + floor(x / POW2[metaBits]) + 1] + 1] end
        local code = readSym(br, grp[1])
        if code < 256 then
            local r = readSym(br, grp[2])
            local b = readSym(br, grp[3])
            local a = readSym(br, grp[4])
            local v = a * 16777216 + r * 65536 + code * 256 + b
            pos = pos + 1
            px[pos] = v
            if cacheBits > 0 then cache[floor(mul32(0x1e35a7bd, v) / POW2[32 - cacheBits])] = v end
        elseif code < 280 then
            local len = prefixValue(br, code - 256)
            local dsym = readSym(br, grp[5])
            local dcode = prefixValue(br, dsym)
            local dist
            if dcode > 120 then
                dist = dcode - 120
            else
                local dc = DIST_MAP[dcode]
                local yoff = floor(dc / 16)
                local xoff = 8 - (dc % 16)
                dist = yoff * xsize + xoff
                if dist < 1 then dist = 1 end
            end
            if dist > pos or pos + len > total then error('VP8L: плохая ссылка назад') end
            for _ = 1, len do
                pos = pos + 1
                local v = px[pos - dist]
                px[pos] = v
                if cacheBits > 0 then cache[floor(mul32(0x1e35a7bd, v) / POW2[32 - cacheBits])] = v end
            end
        else
            local v = cache[code - 280] or 0
            pos = pos + 1
            px[pos] = v
            if cacheBits > 0 then cache[floor(mul32(0x1e35a7bd, v) / POW2[32 - cacheBits])] = v end
        end
    end
    if not level0 then return px end
    local curW = xsize
    for i = #transforms, 1, -1 do
        local tr = transforms[i]
        px, curW = applyInverse(tr, px, (tr.type == 3) and tr.pw or tr.xsize, ysize)
    end
    return px, curW
end
local function decodeVP8L(s, pos, size)
    if sbyte(s, pos) ~= 0x2f then error('VP8L: нет сигнатуры') end
    local br = newBR(s, pos + 1, pos + size - 1)
    local w = rb(br, 14) + 1
    local h = rb(br, 14) + 1
    rb(br, 1)
    rb(br, 3)
    local px = decodeImageStream(br, w, h, true)
    return w, h, px
end
local function decodeAlpha(s, pos, size, w, h)
    local hdr = sbyte(s, pos)
    local comp = hdr % 4
    local filter = floor(hdr / 4) % 4
    local a = {}
    if comp == 0 then
        for i = 1, w * h do a[i] = sbyte(s, pos + i) or 255 end
    else
        local br = newBR(s, pos + 1, pos + size - 1)
        local px = decodeImageStream(br, w, h, true)
        for i = 1, w * h do a[i] = floor(px[i] / 256) % 256 end
    end
    if filter > 0 then
        local out = {}
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                local i = y * w + x + 1
                local v = a[i]
                local pred
                if y == 0 then
                    pred = (x == 0) and 0 or out[i - 1]
                elseif x == 0 then
                    pred = out[i - w]
                elseif filter == 1 then
                    pred = out[i - 1]
                elseif filter == 2 then
                    pred = out[i - w]
                else
                    pred = clip(out[i - 1] + out[i - w] - out[i - w - 1])
                end
                out[i] = (v + pred) % 256
            end
        end
        a = out
    end
    return a
end
local M = {}
function M.decode(s)
    if s:sub(1, 4) ~= 'RIFF' or s:sub(9, 12) ~= 'WEBP' then error('это не WebP') end
    local p = 13
    local alph, vp8, vp8l
    while p + 8 <= #s + 1 do
        local tag = s:sub(p, p + 3)
        local sz = u32(s, p + 4)
        local dp = p + 8
        if tag == 'ALPH' then alph = { dp, sz }
        elseif tag == 'VP8 ' then vp8 = { dp, sz }
        elseif tag == 'VP8L' then vp8l = { dp, sz } end
        p = dp + sz + (sz % 2)
    end
    local rgba = {}
    if vp8 then
        local w, h, Y, U, V, ys, uvs = decodeVP8Planes(s, vp8[1], vp8[2])
        local rgb = upsampleRows(w, h, Y, U, V, ys, uvs)
        local al
        if alph then
            local ok, r = pcall(decodeAlpha, s, alph[1], alph[2], w, h)
            if ok then al = r end
        end
        for i = 1, w * h do
            rgba[(i - 1) * 4 + 1] = rgb[(i - 1) * 3 + 1]
            rgba[(i - 1) * 4 + 2] = rgb[(i - 1) * 3 + 2]
            rgba[(i - 1) * 4 + 3] = rgb[(i - 1) * 3 + 3]
            rgba[(i - 1) * 4 + 4] = al and al[i] or 255
        end
        return w, h, rgba
    elseif vp8l then
        local w, h, px = decodeVP8L(s, vp8l[1], vp8l[2])
        for i = 1, w * h do
            local a, r, g, b = ch4(px[i])
            rgba[(i - 1) * 4 + 1], rgba[(i - 1) * 4 + 2], rgba[(i - 1) * 4 + 3], rgba[(i - 1) * 4 + 4] = r, g, b, a
        end
        return w, h, rgba
    end
    error('WebP: нет данных изображения')
end
return M
end)()
local function parseItemsBin(s)
    local n = #s
    if s:sub(1, 4) ~= 'ITM2' then return nil, 'неизвестный формат items.bin' end
    local byte, sub, find = string.byte, string.sub, string.find
    local function u16(p)
        local a, b = byte(s, p, p + 1)
        if not b then return nil end
        return a + b * 256
    end
    local function goodName(nm)
        if find(nm, '\0', 1, true) then return false end
        if find(nm, '[\1-\8\11\12\14-\31]') then return false end
        return isUtf8(nm)
    end
    local function readRec(p, prev)
        local id, nl = u16(p), u16(p + 4)
        if not id or not nl or nl > 300 then return nil end
        if id <= prev or id > prev + 4000 then return nil end
        local name = sub(s, p + 6, p + 5 + nl)
        if #name ~= nl or not goodName(name) then return nil end
        local q = p + 6 + nl
        local dl = u16(q)
        if not dl or dl > 8000 then return nil end
        q = q + 2 + dl + 13
        local sl = u16(q)
        if not sl or sl > 3000 then return nil end
        local xp = q + 2
        q = q + 2 + sl + 3 + 1
        for _ = 1, 3 do
            local c = byte(s, q)
            if not c then return nil end
            q = q + 1 + 2 * c
        end
        if q > n + 1 then return nil end
        return id, name, q, p + 8 + nl, dl, xp, sl
    end
    local function confirmed(q, id)
        if q == n + 1 then return true end
        local id2, nl = u16(q), u16(q + 4)
        if not id2 or not nl or id2 <= id or id2 > id + 4000 or nl > 300 then return false end
        local nm = sub(s, q + 6, q + 5 + nl)
        return #nm == nl and goodName(nm)
    end
    local p = 6
    for _ = 1, byte(s, 5) do p = p + 1 + (byte(s, p) or 0) end
    local first
    for off = 0, 16 do
        local id, _, q = readRec(p + off, 0)
        if id and id < 50 and confirmed(q, id) then first = p + off break end
    end
    if not first then return nil, 'не нашёл первую запись в items.bin' end
    local list, prev = {}, 0
    p = first
    while p <= n do
        local id, name, q, dp, dl, xp, xl = readRec(p, prev)
        if id and confirmed(q, id) then
            if name ~= '' then list[#list + 1] = { id = id, name = name, dp = dp, dl = dl, xp = xp, xl = xl } end
            prev, p = id, q
        else
            local from = id and (p + 8) or p
            local nextP
            for r = from, math.min(n, from + 20000) do
                local rid, _, rq = readRec(r, prev)
                if rid and confirmed(rq, rid) then
                    local rid2, _, rq2 = readRec(rq, rid)
                    if rq == n + 1 or (rid2 and confirmed(rq2, rid2)) then nextP = r break end
                end
            end
            if not nextP then break end
            p = nextP
        end
    end
    if #list == 0 then return nil, 'список предметов пустой' end
    return list
end
local items, itemById = {}, {}
local itemsZip, iconEnt, iconEnt48, iconAlias = nil, {}, {}, {}
local AP = {
    extraEmoji = {}, descCache = {}, escSwallow = false,
    inv = { [1] = {} },
    invMeta = { [1] = { last = -100, full = false } },
    invVer = 0, invCache = nil,
    tokItem = {},
    invGroup = imgui.new.bool(true), invSearch = imgui.new.char[64](),
}
do
    local ok, err = pcall(function()
        local zpath
        for _, p in ipairs({ GAME_DIR .. '\\arizona\\items.zip', GAME_DIR .. '\\items.zip' }) do
            if fileExists(p) then zpath = p break end
        end
        if not zpath then error('не найден items.zip в папке игры', 0) end
        local z, zerr = zipOpen(zpath)
        if not z then error(zerr, 0) end
        local ent
        for _, e in ipairs(z.list) do
            if e.name == 'items.bin' or e.name:sub(-10) == '/items.bin' then ent = e break end
        end
        if not ent then z.f:close() error('в items.zip нет items.bin', 0) end
        local data, derr = zipRead(z, ent)
        if not data then z.f:close() error(derr or 'не прочитал items.bin', 0) end
        local list, perr = parseItemsBin(data)
        if not list then z.f:close() error(perr, 0) end
        AP.binOff = zipDataOffset(z, ent)
        data = nil
        local aliasEnt
        for _, e in ipairs(z.list) do
            local n = e.name:match('^icons/24/(%d+)%.webp$')
            if n then iconEnt[tonumber(n)] = e
            elseif e.name == 'icons/aliases.json' then aliasEnt = e
            else
                local n48 = e.name:match('^icons/48/(%d+)%.webp$')
                if n48 then iconEnt48[tonumber(n48)] = e end
            end
        end
        if aliasEnt then
            local aj = zipRead(z, aliasEnt)
            if aj then
                for k, v in aj:gmatch('"(%d+)"%s*:%s*(%d+)') do iconAlias[tonumber(k)] = tonumber(v) end
            end
        end
        z.list = nil
        itemsZip = z
        for _, it in ipairs(list) do
            it.low = u8lower(it.name)
            items[#items + 1] = it
            itemById[it.id] = it
        end
        if #items == 0 then error('список предметов пустой', 0) end
    end)
    if not ok then itemsErr = tostring(err) end
end
AP.now = 0
AP.emojiLive = {}
AP.VR, AP.MUTE, AP.RADIO = VR, MUTE, RADIO
AP.MULTI, AP.MAX_LINES = MULTI, MAX_LINES
local EMOJI_DATA_FN
local EMOJI_CATS = {
    'Смайлы и животные',
    'Люди и жесты',
    'Праздники и предметы',
    'Еда и растения',
    'Транспорт и места',
    'Символы',
    'Буквы и логотипы',
    'Скрытые: интерфейс',
    'Скрытые: ленты и флаги',
    'Скрытые: VIP и уровни',
    'Скрытые: значки сервера',
    'Скрытые: цифры и метки',
    'Скрытые: оружие',
    'Скрытые: недвижимость и чат',
    'Скрытые: интерфейс (big_icons)',
    'Плашки чата (VIP, админ, реклама)'
}
local emojiCats, emojiByToken, emojiMaxTok, emojiBuilt = {}, {}, 3, false
local function ensureEmojiTables()
    if emojiBuilt then return end
    emojiBuilt = true
    local catIndex, seen, idx = {}, {}, 0
    for line in EMOJI_DATA_FN():gmatch('[^\r\n]+') do
        local nm, hx, ci, cl = line:match('^(.-)\t(%x+)\t(%d+)\t(%d+)$')
        if nm and not seen[nm] then
            seen[nm] = true
            local wide = tonumber(cl) >= 3
            if (ci == '9' or ci == '14') and wide then ci = '16' end
            idx = idx + 1
            local e = { idx = idx, name = nm, cp = tonumber(hx, 16), cells = tonumber(cl) }
            local c = catIndex[ci]
            if not c then
                c = { name = EMOJI_CATS[tonumber(ci)] or '?', items = {} }
                catIndex[ci] = c
                emojiCats[#emojiCats + 1] = c
            end
            c.items[#c.items + 1] = e
            local tok = ':' .. nm .. ':'
            emojiByToken[tok] = e
            if #tok > emojiMaxTok then emojiMaxTok = #tok end
        end
    end
end
local CELL, RENDER_PX, TEX_PER_FRAME = 48, 42, 12
local okCdef, cdefErr = pcall(ffi.cdef, [[
typedef struct { long x, y; } ap_ftvec;
typedef struct { unsigned int rows, width; int pitch; unsigned char* buffer; unsigned short num_grays; unsigned char pixel_mode; unsigned char palette_mode; void* palette; } ap_ftbitmap;
typedef struct { long width, height, horiBearingX, horiBearingY, horiAdvance, vertBearingX, vertBearingY, vertAdvance; } ap_ftmetrics;
typedef struct { void* data; void* finalizer; } ap_ftgeneric;
typedef struct ap_ftslot {
    void* library; void* face; struct ap_ftslot* next; unsigned int glyph_index;
    ap_ftgeneric generic; ap_ftmetrics metrics;
    long linearHoriAdvance, linearVertAdvance; ap_ftvec advance;
    int format; ap_ftbitmap bitmap; int bitmap_left, bitmap_top;
} ap_ftslot;
typedef struct {
    long num_faces, face_index, face_flags, style_flags, num_glyphs;
    char* family_name; char* style_name;
    int num_fixed_sizes; void* available_sizes;
    int num_charmaps; void* charmaps;
    ap_ftgeneric generic;
    long bbox_x0, bbox_y0, bbox_x1, bbox_y1;
    unsigned short units_per_EM;
    short ascender, descender, height, max_advance_width, max_advance_height, underline_position, underline_thickness;
    ap_ftslot* glyph;
} ap_ftface;
int ap_FT_Init(void** lib) __asm__("FT_Init_FreeType");
int ap_FT_NewFace(void* lib, const char* path, long idx, ap_ftface** face) __asm__("FT_New_Face");
int ap_FT_NewMem(void* lib, const unsigned char* base, long size, long idx, ap_ftface** face) __asm__("FT_New_Memory_Face");
int ap_FT_Pix(ap_ftface* face, unsigned int w, unsigned int h) __asm__("FT_Set_Pixel_Sizes");
unsigned int ap_FT_Idx(ap_ftface* face, unsigned long code) __asm__("FT_Get_Char_Index");
int ap_FT_Load(ap_ftface* face, unsigned int idx, int flags) __asm__("FT_Load_Glyph");
int ap_FT_Pal(ap_ftface* face, unsigned short idx, void** pal) __asm__("FT_Palette_Select");
int ap_FT_Done(ap_ftface* face) __asm__("FT_Done_Face");
unsigned long ap_FT_First(ap_ftface* face, unsigned int* gi) __asm__("FT_Get_First_Char");
unsigned long ap_FT_Next(ap_ftface* face, unsigned long ch, unsigned int* gi) __asm__("FT_Get_Next_Char");
typedef struct { int Pitch; void* pBits; } ap_lockrect;
typedef long (__stdcall *ap_fnCreateTex)(void*, unsigned int, unsigned int, unsigned int, unsigned long, unsigned int, unsigned int, void**, void*);
typedef long (__stdcall *ap_fnLock)(void*, ap_lockrect*, const void*, unsigned long);
typedef long (__stdcall *ap_fnUnlock)(void*);
typedef unsigned long (__stdcall *ap_fnRelease)(void*);
]])
local ft = { lib = nil, ctx = ffi.new('void*[1]'), emoji = nil, icons = nil, iconMem = nil, extra = {}, extraMem = {}, tried = false, ready = false, warn = '' }
local function ttfHasColor(z, ent)
    local off = zipDataOffset(z, ent)
    if not off then return false end
    z.f:seek('set', off)
    local h = z.f:read(12)
    if not h or #h < 12 then return false end
    local nt = h:byte(5) * 256 + h:byte(6)
    if nt == 0 or nt > 64 then return false end
    local dir = z.f:read(nt * 16)
    if not dir or #dir < nt * 16 then return false end
    local hasC, hasP = false, false
    for i = 0, nt - 1 do
        local tag = dir:sub(i * 16 + 1, i * 16 + 4)
        if tag == 'COLR' then hasC = true elseif tag == 'CPAL' then hasP = true end
    end
    return hasC and hasP
end
local function setupFace(face)
    ft.lib.ap_FT_Pix(face, 0, RENDER_PX)
    pcall(function() ft.lib.ap_FT_Pal(face, 0, nil) end)
end
function AP.addAutoEmoji()
    if not ft.icons or not ft.lib.ap_FT_First then return end
    ensureEmojiTables()
    local known, maxIdx = {}, 0
    for _, c in ipairs(emojiCats) do
        for _, e in ipairs(c.items) do
            known[e.cp] = true
            if e.idx and e.idx > maxIdx then maxIdx = e.idx end
        end
    end
    local gi = ffi.new('unsigned int[1]')
    local cp = tonumber(ft.lib.ap_FT_First(ft.icons, gi))
    local list, guard = {}, 0
    while gi[0] ~= 0 and guard < 30000 do
        guard = guard + 1
        if not known[cp] and ((cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0x1FC00 and cp <= 0x1FCFF)) then
            list[#list + 1] = cp
        end
        cp = tonumber(ft.lib.ap_FT_Next(ft.icons, cp, gi))
    end
    if #list == 0 then return end
    table.sort(list)
    local cat = { name = 'Бренды и соцсети (новые)', items = {} }
    for i = 1, math.min(#list, 500) do
        local c = list[i]
        local cells = 1
        local okw, w = pcall(function()
            local g = ft.lib.ap_FT_Idx(ft.icons, c)
            if ft.lib.ap_FT_Load(ft.icons, g, 0) ~= 0 then return 0 end
            return tonumber(ft.icons.glyph.metrics.width) / 64
        end)
        if okw and w and w > 0 then cells = math.max(1, math.min(4, math.ceil(w / 44))) end
        maxIdx = maxIdx + 1
        local nm = ('u%x'):format(c)
        local e = { idx = maxIdx, name = nm, cp = c, cells = cells }
        cat.items[#cat.items + 1] = e
        local tok = ':' .. nm .. ':'
        emojiByToken[tok] = e
        if #tok > emojiMaxTok then emojiMaxTok = #tok end
    end
    emojiCats[#emojiCats + 1] = cat
end
local function ftSetup()
    if ft.tried then return ft.ready end
    ft.tried = true
    local warns = {}
    if not okCdef and not tostring(cdefErr):find('redefine') then
        emojiErr = 'ошибка описания FreeType: ' .. tostring(cdefErr)
        return false
    end
    local ok, lib = pcall(ffi.load, GAME_DIR .. '\\freetype.dll')
    if not ok then ok, lib = pcall(ffi.load, 'freetype') end
    if not ok then emojiErr = 'не найден freetype.dll в папке игры' return false end
    ft.lib = lib
    local okI, rc = pcall(function() return lib.ap_FT_Init(ft.ctx) end)
    if not okI or rc ~= 0 then emojiErr = 'FreeType не запустился' return false end
    local fp = ffi.new('ap_ftface*[1]')
    local winDir = os.getenv('WINDIR') or 'C:\\Windows'
    for _, p in ipairs({ GAME_DIR .. '\\fontcustom\\seguiemj_1.45.ttf', winDir .. '\\Fonts\\seguiemj.ttf' }) do
        if fileExists(p) and lib.ap_FT_NewFace(ft.ctx[0], p, 0, fp) == 0 then
            ft.emoji = fp[0]
            setupFace(ft.emoji)
            break
        end
    end
    if not ft.emoji then warns[#warns + 1] = 'не найден шрифт Segoe UI Emoji (обычные смайлы не покажутся)' end
    local okZ, errZ = pcall(function()
        local z = zipOpen(GAME_DIR .. '\\frontend.zip')
        if not z then error('нет frontend.zip', 0) end
        local found
        for _, ent in ipairs(z.list) do
            if not found and ent.method == 0 and ent.csize > 20000 then
                local nm = ent.name:lower()
                if nm:sub(-4) == '.ttf' and ttfHasColor(z, ent) then
                    local data = zipRead(z, ent)
                    if data then
                        local mem = ffi.new('uint8_t[?]', #data)
                        ffi.copy(mem, data, #data)
                        if lib.ap_FT_NewMem(ft.ctx[0], mem, #data, 0, fp) == 0 then
                            local face = fp[0]
                            if lib.ap_FT_Idx(face, 0xF259) ~= 0 or lib.ap_FT_Idx(face, 0x1FC08) ~= 0 then
                                ft.icons, ft.iconMem = face, mem
                                ft.iconsName = ent.name
                                setupFace(face)
                                found = true
                            else
                                lib.ap_FT_Done(face)
                            end
                        end
                    end
                end
            end
        end
        z.f:close()
        if not found then error('шрифт значков не найден', 0) end
    end)
    if not okZ then warns[#warns + 1] = 'значки Аризоны недоступны: ' .. tostring(errZ) end
    ft.warn = table.concat(warns, '; ')
    ft.ready = (ft.emoji ~= nil) or (ft.icons ~= nil)
    if not ft.ready then emojiErr = ft.warn end
    pcall(AP.addAutoEmoji)
    return ft.ready
end
local function ftGlyph(face, cp)
    local lib = ft.lib
    local gi = lib.ap_FT_Idx(face, cp)
    if gi == 0 then return nil end
    if lib.ap_FT_Load(face, gi, 0x100004) ~= 0 then return nil end
    local bm = face.glyph.bitmap
    local w, h = tonumber(bm.width), tonumber(bm.rows)
    local mode = bm.pixel_mode
    if w == 0 or h == 0 or bm.buffer == nil or (mode ~= 7 and mode ~= 2) then return nil end
    local pitch = bm.pitch
    local px = ffi.new('uint8_t[?]', w * h * 4)
    for y = 0, h - 1 do
        local src = bm.buffer + y * pitch
        for x = 0, w - 1 do
            local d = (y * w + x) * 4
            if mode == 7 then
                local b, g, r, a = src[x * 4], src[x * 4 + 1], src[x * 4 + 2], src[x * 4 + 3]
                if a > 0 and a < 255 then
                    b = math.min(255, math.floor(b * 255 / a + 0.5))
                    g = math.min(255, math.floor(g * 255 / a + 0.5))
                    r = math.min(255, math.floor(r * 255 / a + 0.5))
                end
                px[d], px[d + 1], px[d + 2], px[d + 3] = b, g, r, a
            else
                px[d], px[d + 1], px[d + 2], px[d + 3] = 255, 255, 255, src[x]
            end
        end
    end
    return w, h, px
end
local function buildEmojiPixels(e)
    local cw, ch = CELL * e.cells, CELL
    local pua = (e.cp >= 0xE000 and e.cp <= 0xF8FF) or (e.cp >= 0x1FC00 and e.cp <= 0x1FCFF)
    local order = {}
    local first, second = ft.emoji, ft.icons
    if pua then first, second = ft.icons, ft.emoji end
    if first then order[#order + 1] = first end
    if second then order[#order + 1] = second end
    for _, f in ipairs(ft.extra) do order[#order + 1] = f end
    local gw, gh, gp
    for _, face in ipairs(order) do
        gw, gh, gp = ftGlyph(face, e.cp)
        if gw then break end
    end
    if not gw then return nil end
    local scale = 1
    if gw > cw or gh > ch then scale = math.min(cw / gw, ch / gh) end
    local dw = math.max(1, math.floor(gw * scale))
    local dh = math.max(1, math.floor(gh * scale))
    local ox, oy = math.floor((cw - dw) / 2), math.floor((ch - dh) / 2)
    local out = ffi.new('uint8_t[?]', cw * ch * 4)
    for y = 0, dh - 1 do
        local sy = (scale == 1) and y or math.min(gh - 1, math.floor(y / scale))
        for x = 0, dw - 1 do
            local sx = (scale == 1) and x or math.min(gw - 1, math.floor(x / scale))
            local s = (sy * gw + sx) * 4
            local d = ((oy + y) * cw + ox + x) * 4
            out[d], out[d + 1], out[d + 2], out[d + 3] = gp[s], gp[s + 1], gp[s + 2], gp[s + 3]
        end
    end
    return cw, ch, out
end
local function d3dTexture(w, h, px)
    local dev = ffi.cast('void**', 0xC97C28)[0]
    if dev == nil then return nil end
    local vt = ffi.cast('void***', dev)[0]
    local create = ffi.cast('ap_fnCreateTex', vt[23])
    local pp = ffi.new('void*[1]')
    if create(dev, w, h, 1, 0, 21, 1, pp, nil) ~= 0 then return nil end
    local tex = pp[0]
    local tvt = ffi.cast('void***', tex)[0]
    local lr = ffi.new('ap_lockrect[1]')
    if ffi.cast('ap_fnLock', tvt[19])(tex, lr, nil, 0) ~= 0 then
        ffi.cast('ap_fnRelease', tvt[2])(tex)
        return nil
    end
    local dst = ffi.cast('uint8_t*', lr[0].pBits)
    for y = 0, h - 1 do
        ffi.copy(dst + y * lr[0].Pitch, px + y * w * 4, w * 4)
    end
    ffi.cast('ap_fnUnlock', tvt[20])(tex)
    return tex
end
local function mimTexture(w, h, px)
    if not imgui.CreateTextureFromFileInMemory then return nil end
    local hdr = string.char(0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        w % 256, math.floor(w / 256), h % 256, math.floor(h / 256), 32, 0x28)
    local s = hdr .. ffi.string(px, w * h * 4)
    return imgui.CreateTextureFromFileInMemory(ffi.cast('const char*', s), #s)
end
local texBudget, d3dBroken, mimBroken = 0, false, false
local function emojiTex(e)
    if e.tex then e.used = AP.now return e.tex end
    if e.fail or texBudget <= 0 then return nil end
    local okS, rS = pcall(ftSetup)
    if not okS then emojiErr = 'FreeType: ' .. tostring(rS) end
    if not okS or not rS then e.fail = true return nil end
    texBudget = texBudget - 1
    local ok, w, h, px = pcall(buildEmojiPixels, e)
    if not ok or not w then e.fail = true return nil end
    local t, mode
    if not d3dBroken then
        local ok2, r = pcall(d3dTexture, w, h, px)
        if ok2 and r then t, mode = r, 'd3d' else d3dBroken = true end
    end
    if not t and not mimBroken then
        local ok3, r = pcall(mimTexture, w, h, px)
        if ok3 and r then t, mode = r, 'mim' else mimBroken = true end
    end
    if not t then
        e.fail = true
        if d3dBroken and mimBroken then emojiErr = 'не удалось создать текстуры смайлов' end
        return nil
    end
    e.tex, e.texMode = t, mode
    e.used = AP.now
    AP.emojiLive[#AP.emojiLive + 1] = e
    AP.texDirty = true
    return t
end
local function emojiUnload(quit)
    if not emojiBuilt then return end
    if not quit then
        for _, c in ipairs(emojiCats) do
            for _, e in ipairs(c.items) do
                if e.tex then
                    pcall(function()
                        if e.texMode == 'd3d' then
                            local vt = ffi.cast('void***', e.tex)[0]
                            ffi.cast('ap_fnRelease', vt[2])(e.tex)
                        elseif imgui.ReleaseTexture then
                            imgui.ReleaseTexture(e.tex)
                        end
                    end)
                end
                e.tex = nil
            end
        end
        for _, e in pairs(AP.extraEmoji) do
            if e.tex then
                pcall(function()
                    if e.texMode == 'd3d' then
                        local vt = ffi.cast('void***', e.tex)[0]
                        ffi.cast('ap_fnRelease', vt[2])(e.tex)
                    elseif imgui.ReleaseTexture then
                        imgui.ReleaseTexture(e.tex)
                    end
                end)
            end
            e.tex = nil
        end
        pcall(function()
            if ft.emoji then ft.lib.ap_FT_Done(ft.emoji) end
            if ft.icons then ft.lib.ap_FT_Done(ft.icons) end
            for _, f in ipairs(ft.extra) do ft.lib.ap_FT_Done(f) end
        end)
    end
end
local ICON_PER_FRAME = 3
local iconBudget = 0
local iconCache, iconModes = {}, {}
local iconUsed, iconLive = {}, 0
local function itemIconId(id, big)
    local ents = big and iconEnt48 or iconEnt
    if ents[id] then return id end
    local a = iconAlias[id]
    if a and ents[a] then return a end
    return nil
end
local function itemIcon(id, big)
    local iid = itemIconId(id, big)
    if not iid then return nil end
    local key = big and (iid + 1000000) or iid
    local ent = (big and iconEnt48 or iconEnt)[iid]
    local c = iconCache[key]
    if c ~= nil then
        if c then iconUsed[key] = AP.now end
        return c or nil
    end
    if iconBudget <= 0 or not itemsZip then return nil end
    iconBudget = iconBudget - 1
    local ok, res = pcall(function()
        local data = zipRead(itemsZip, ent)
        if not data then error('нет данных иконки', 0) end
        local w, h, rgba = webp.decode(data)
        local buf = ffi.new('uint8_t[?]', w * h * 4)
        for i = 0, w * h - 1 do
            buf[i * 4] = rgba[i * 4 + 3]
            buf[i * 4 + 1] = rgba[i * 4 + 2]
            buf[i * 4 + 2] = rgba[i * 4 + 1]
            buf[i * 4 + 3] = rgba[i * 4 + 4]
        end
        local t, mode
        if not d3dBroken then
            local ok2, r = pcall(d3dTexture, w, h, buf)
            if ok2 and r then t, mode = r, 'd3d' else d3dBroken = true end
        end
        if not t and not mimBroken then
            local ok3, r = pcall(mimTexture, w, h, buf)
            if ok3 and r then t, mode = r, 'mim' else mimBroken = true end
        end
        if not t then error('не создалась текстура', 0) end
        return { t, mode }
    end)
    if ok and res then
        iconCache[key] = res[1]
        iconModes[key] = res[2]
        iconUsed[key] = AP.now
        iconLive = iconLive + 1
        AP.texDirty = true
        return res[1]
    end
    iconCache[key] = false
    return nil
end
local function iconUnload(quit)
    if not quit then
        for iid, t in pairs(iconCache) do
            if t then
                pcall(function()
                    if iconModes[iid] == 'd3d' then
                        local vt = ffi.cast('void***', t)[0]
                        ffi.cast('ap_fnRelease', vt[2])(t)
                    elseif imgui.ReleaseTexture then
                        imgui.ReleaseTexture(t)
                    end
                end)
            end
        end
    end
    iconCache = {}
    iconUsed, iconLive = {}, 0
    if itemsZip and itemsZip.f then pcall(function() itemsZip.f:close() end) end
    itemsZip = nil
end
local function releaseTex(t, mode)
    pcall(function()
        if mode == 'd3d' then
            local vt = ffi.cast('void***', t)[0]
            ffi.cast('ap_fnRelease', vt[2])(t)
        elseif imgui.ReleaseTexture then
            imgui.ReleaseTexture(t)
        end
    end)
end
function AP.releaseTextures(maxAge)
    local clock = os.clock()
    local keep = {}
    for _, e in ipairs(AP.emojiLive) do
        if e.tex then
            if maxAge and clock - (e.used or 0) < maxAge then
                keep[#keep + 1] = e
            else
                releaseTex(e.tex, e.texMode)
                e.tex = nil
            end
        end
    end
    AP.emojiLive = keep
    for key, t in pairs(iconCache) do
        if t and not (maxAge and clock - (iconUsed[key] or 0) < maxAge) then
            releaseTex(t, iconModes[key])
            iconCache[key] = nil
            iconModes[key] = nil
            iconUsed[key] = nil
            iconLive = iconLive - 1
        end
    end
    if not maxAge then AP.texDirty = false end
end
function AP.texStats()
    return iconLive, #AP.emojiLive
end
local function appendToken(tok)
    local m = msgs[target]
    if not m then return end
    local buf = m.lines[AP.curLine(m)].buf
    local s = ffi.string(buf)
    if #s + #tok + 2 >= BUFSZ then return end
    if s ~= '' and not s:match('%s$') then s = s .. ' ' end
    ffi.copy(buf, s .. tok .. ' ')
end
local UV0, UV1 = imgui.ImVec2(0, 0), imgui.ImVec2(1, 1)
local function drawInlineEmoji(e, size)
    local w, h = size * e.cells, size
    local p = imgui.GetCursorScreenPos()
    imgui.Dummy(imgui.ImVec2(w, h))
    local tex = emojiTex(e)
    if tex then
        imgui.GetWindowDrawList():AddImage(tex, p, imgui.ImVec2(p.x + w, p.y + h), UV0, UV1, 0xFFFFFFFF)
    end
end
local function drawInlineItem(id, size)
    local tex = itemIcon(id)
    if not tex then return end
    local p = imgui.GetCursorScreenPos()
    imgui.Dummy(imgui.ImVec2(size, size))
    imgui.GetWindowDrawList():AddImage(tex, p, imgui.ImVec2(p.x + size, p.y + size), UV0, UV1, 0xFFFFFFFF)
end
function AP.slotInfo(slot, ty)
    local store = AP.inv[ty]
    if not store then return end
    local want = AP.tokItem['slot' .. slot .. '_' .. ty]
    local e = store[slot]
    if want then
        if not (e and e.item == want) then
            e = nil
            local best
            for sl, x in pairs(store) do
                if x.item == want and (not best or sl < best) then best, e = sl, x end
            end
        end
        return want, e
    end
    return e and e.item, e
end
local function drawPreview(s, size)
    ensureEmojiTables()
    texBudget = TEX_PER_FRAME
    iconBudget = ICON_PER_FRAME
    local pv = s
    local n, i, buf, first = #pv, 1, {}, true
    local function put(fn)
        if not first then imgui.SameLine(0, 0) end
        first = false
        fn()
    end
    local function flush()
        if #buf > 0 then
            local t = table.concat(buf)
            buf = {}
            put(function() imgui.TextUnformatted(t) end)
        end
    end
    while i <= n do
        local hit
        local itn, iend, slN, slT
        if pv:sub(i, i) == ':' then
            itn, iend = pv:match('^:item(%d+):()', i)
            if not itn then slN, slT, iend = pv:match('^:slot(%d+)_(%d+):()', i) end
            for len = math.min(emojiMaxTok, n - i + 1), 3, -1 do
                local e = emojiByToken[pv:sub(i, i + len - 1)]
                if e then hit = { e = e, len = len } break end
            end
        end
        if itn then
            flush()
            local it = itemById[tonumber(itn)]
            if it then
                put(function() drawInlineItem(it.id, size) end)
                buf[#buf + 1] = ' ' .. it.name
            else
                buf[#buf + 1] = ':item' .. itn .. ':'
            end
            i = iend
        elseif slN then
            flush()
            local id, e = AP.slotInfo(tonumber(slN), tonumber(slT))
            local it = id and itemById[id]
            if it then
                put(function() drawInlineItem(it.id, size) end)
                local qty = e and tonumber(e.amount)
                buf[#buf + 1] = ' ' .. it.name .. ((qty and qty > 1) and (' x' .. qty) or '')
            else
                buf[#buf + 1] = ':slot' .. slN .. '_' .. slT .. ':'
            end
            i = iend
        elseif hit then
            flush()
            put(function() drawInlineEmoji(hit.e, size) end)
            i = i + hit.len
        else
            buf[#buf + 1] = pv:sub(i, i)
            i = i + 1
        end
    end
    flush()
end
local function drawEmojiGrid(panelH, size)
    ensureEmojiTables()
    texBudget = TEX_PER_FRAME
    imgui.BeginChild('##emojigrid', imgui.ImVec2(0, panelH), true)
    if emojiErr then
        imgui.TextColored(imgui.ImVec4(1, 0.4, 0.4, 1), 'Смайлы: ' .. tostring(emojiErr))
    elseif ft.warn ~= '' then
        imgui.TextDisabled(ft.warn)
    end
    local spacing = imgui.GetStyle().ItemSpacing.x
    local avail = imgui.GetContentRegionAvail().x
    local scrollY = imgui.GetScrollY()
    local dl = imgui.GetWindowDrawList()
    local hoverCol = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.80, 0.52, 0.16, 0.45))
    local pad = 2
    for _, cat in ipairs(emojiCats) do
        imgui.TextDisabled(cat.name)
        local x = 0
        for _, e in ipairs(cat.items) do
            local w = size * e.cells + pad * 2
            if x > 0 then
                if x + spacing + w <= avail then
                    imgui.SameLine()
                    x = x + spacing
                else
                    x = 0
                end
            end
            local cy = imgui.GetCursorPosY() - scrollY
            local visible = cy > -(size + 8) and cy < panelH + 8
            local p = imgui.GetCursorScreenPos()
            local clicked = imgui.InvisibleButton('##e' .. e.idx, imgui.ImVec2(w, size + pad * 2))
            local hovered = imgui.IsItemHovered()
            if visible then
                if hovered then
                    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + size + pad * 2), hoverCol, 4)
                end
                local tex = emojiTex(e)
                if tex then
                    dl:AddImage(tex, imgui.ImVec2(p.x + pad, p.y + pad),
                        imgui.ImVec2(p.x + pad + size * e.cells, p.y + pad + size), UV0, UV1, 0xFFFFFFFF)
                end
            end
            if clicked then appendToken(':' .. e.name .. ':') end
            x = x + w
        end
        imgui.Spacing()
    end
    imgui.Dummy(imgui.ImVec2(0, 8))
    imgui.EndChild()
end
local function notify(s)
    sampAddChatMessage(u8:decode('{FFB84D}[АвтоПиар] {FFFFFF}' .. s), -1)
end
local function canSend()
    return isSampAvailable() and sampIsLocalPlayerSpawned()
        and not sampIsChatInputActive() and not sampIsDialogActive()
end
local function schedule(m)
    m.waitSince = nil
    local delay = math.max(MIN_ALLOWED, m.delay[0])
    m.nextAt = os.clock() + delay
    m.total = delay
    m.lastDelay = m.delay[0]
end
AP.adMin, AP.adMax = 20, 80
AP.adReadyAt = 0
function AP.charCount(s)
    local _, n = s:gsub('[^\128-\191]', '')
    return n
end
function AP.adCheck(text)
    text = text:gsub('^%s+', '')
    if text == '' then return 'текст объявления пустой, нужен хотя бы один видимый символ' end
    local n = AP.charCount(text)
    if n < AP.adMin then return ('текст слишком короткий для /ad (минимум %d символов, сейчас %d)'):format(AP.adMin, n) end
    if n > AP.adMax then return ('текст слишком длинный для /ad (максимум %d символов, сейчас %d)'):format(AP.adMax, n) end
end
function AP.lineCount(m)
    if MULTI[CMDS[m.cmd[0] + 1]] then return #m.lines end
    return 1
end
function AP.lineText(m, k)
    local l = m.lines[k]
    if not l then return '' end
    return (ffi.string(l.buf):gsub('^%s+', ''):gsub('%s+$', ''))
end
function AP.curLine(m)
    local li = AP.tline or 1
    if li < 1 or li > AP.lineCount(m) or not m.lines[li] then li = 1 end
    return li
end
function AP.curText(m)
    return ffi.string(m.lines[AP.curLine(m)].buf)
end
function AP.addLine(m)
    if #m.lines >= MAX_LINES then return end
    m.lines[#m.lines + 1] = { buf = imgui.new.char[BUFSZ](), pause = imgui.new.float(3) }
end
function AP.muteLeft()
    if MUTE.untilAt <= 0 then return 0 end
    return math.max(0, MUTE.untilAt - os.clock())
end
function AP.fmtTime(s)
    s = math.max(0, math.ceil(s))
    if s >= 60 then return ('%d:%02d'):format(math.floor(s / 60), s % 60) end
    return ('%d сек'):format(s)
end
function AP.muteText(s)
    if s >= 60 then return ('%d мин'):format(math.ceil(s / 60)) end
    return ('%d сек'):format(math.ceil(s))
end
function AP.startCheck(m)
    if m.delay[0] < MIN_ALLOWED then return 'укажи задержку больше 0 сек' end
    local c = CMDS[m.cmd[0] + 1]
    if c == '/ad' then return AP.adCheck(msgText(m)) end
    local left = AP.muteLeft()
    if left > 0 then return 'активен мут чата (осталось ' .. AP.muteText(left) .. ')' end
end
function AP.money(n)
    local s = tostring(math.floor(n)):reverse()
    s = (s:gsub('(%d%d%d)', '%1.')):reverse()
    return (s:gsub('^%.', ''))
end
function AP.cardKey(m)
    local s = ffi.string(m.buf) .. '|' .. m.delay[0] .. '|' .. m.cmd[0]
    for k = 2, #m.lines do s = s .. '|' .. ffi.string(m.lines[k].buf) end
    return s
end
function AP.fail(m, msg, runtime)
    if not msg:find('%.$') then msg = msg .. '.' end
    m.active = false
    m.checkAt = nil
    m.waitSince = nil
    m.errMute = nil
    m.err = msg
    m.errKey = AP.cardKey(m)
    if runtime and not win[0] then notify(msg) end
end
function AP.fitStr(s, maxW)
    if imgui.CalcTextSize(s).x <= maxW then return s end
    local chars = {}
    for ch in s:gmatch('[\1-\127\194-\244][\128-\191]*') do chars[#chars + 1] = ch end
    local k = #chars
    while k > 1 do
        k = k - 1
        local t = table.concat(chars, '', 1, k) .. '...'
        if imgui.CalcTextSize(t).x <= maxW then return t end
    end
    return '...'
end
local function setActive(m, v, keep)
    m.mutePaused = nil
    m.waitSince = nil
    if v then
        local err = AP.startCheck(m)
        if err then
            AP.fail(m, 'Не запущено: ' .. err)
            m.errMute = err:find('^активен мут') ~= nil
            return
        end
        m.err = nil
    end
    m.active = v
    if v then
        m.nextAt = os.clock() + 1
        m.total = 1
        if not keep then
            m.left = m.lim[0] and m.cnt[0] or 0
            m.idx = 1
        end
    end
end
local function sendMsg(m, k, done)
    local text = AP.lineText(m, k or 1)
    if text == '' then return false end
    if CMDS[m.cmd[0] + 1] == '/ad' then text = (ffi.string(m.buf):gsub('^%s+', '')) end
    local fixed, why = AP.resolveSlots(text)
    if not fixed then
        AP.fail(m, 'Остановлено: ' .. why, true)
        return false
    end
    text = fixed
    local cmd = CMDS[m.cmd[0] + 1]
    if cmd == '/ad' then
        local err = AP.adCheck(text)
        if err then
            AP.fail(m, 'Остановлено: ' .. err, true)
            return false
        end
    end
    local clock = os.clock()
    AP.lastSend = { m = m, cmd = cmd, at = clock, prevReady = VR.readyAt, text = text,
        idx = k or 1, done = (done ~= false) }
    if cmd == '/vr' then
        pendingVr = { ad = m.ad[0], till = clock + 6 }
        if m.ad[0] then
            VR.readyAt = clock + (VR.cd or VR.fallback) + 1
            VR.lastEpoch = os.time()
        end
    elseif cmd == '/ad' then
        pendingAd = { m = m, mode = 'new', till = clock + 20 }
    end
    sampSendChat(u8:decode(realCmd(m) .. ' ' .. text))
    if cmd ~= '/ad' then
        m.sent = (m.sent or 0) + 1
        m.sentAt = os.date('%H:%M')
    end
    if m.lim[0] and done ~= false then
        m.left = m.left - 1
        if m.left <= 0 then
            m.active = false
            AP.lastSend.limEnd = true
            notify('Лимит отправок исчерпан, пиар отключён.')
        end
    end
    return true
end
function AP.fire(m, now)
    local n = AP.lineCount(m)
    local seq = {}
    for k = 1, n do
        if AP.lineText(m, k) ~= '' then seq[#seq + 1] = k end
    end
    if #seq == 0 then
        sendMsg(m, 1, true)
        schedule(m)
        return
    end
    local want, pos = m.idx or 1, nil
    for p, k in ipairs(seq) do
        if k >= want then pos = p break end
    end
    pos = pos or 1
    local k = seq[pos]
    local last = (pos == #seq)
    local ok = sendMsg(m, k, last)
    if not ok then return end
    if last then
        m.idx = 1
        schedule(m)
    else
        m.idx = seq[pos + 1]
        local pause = math.max(0.1, m.lines[k].pause[0])
        m.nextAt = now + pause
        m.total = pause
        m.lastDelay = m.delay[0]
        m.waitSince = nil
    end
end
local function activeCount()
    local n = 0
    for _, m in ipairs(msgs) do if m.active then n = n + 1 end end
    return n
end
local function plain(t) return (t:gsub('{%x%x%x%x%x%x}', '')) end
local function has(text, russian)
    return text:find(u8:decode(russian), 1, true) ~= nil
end
local function parseAgo(s)
    s = plain(s or '')
    if not s:find('%d') then return nil end
    local function num(unit) return tonumber(s:match('(%d+)%s*' .. u8:decode(unit))) or 0 end
    return num('д') * 86400 + num('ч') * 3600 + num('мин') * 60 + num('сек')
end
local function pickStation(text, city)
    local rows = {}
    for line in (text .. '\n'):gmatch('(.-)\n') do
        if line:find('%[%d+%]') then
            local f = {}
            for part in (plain(line) .. '\t'):gmatch('(.-)\t') do f[#f + 1] = part end
            local name = (f[1] or ''):gsub('^%s*%[%d+%]%s*', '')
            local online = tonumber((f[2] or ''):match('(%d+)')) or 0
            local cost = tonumber((((f[3] or ''):match(':CASH:([%d%.]+)') or ''):gsub('%.', ''))) or 0
            rows[#rows + 1] = { name = name, online = online, cost = cost, ago = parseAgo(f[4]) }
        end
    end
    if #rows == 0 then return 0 end
    local wanted = CITY_NAMES[city + 1]
    if wanted then
        for i, r in ipairs(rows) do
            if r.name:find(wanted, 1, true) then return i - 1, r.name, r.cost end
        end
    end
    local fresh
    for i, r in ipairs(rows) do
        if r.online > 0 and r.ago then
            local b = fresh and rows[fresh]
            if not b or r.ago < b.ago
                or (r.ago == b.ago and (r.online > b.online or (r.online == b.online and r.cost < b.cost))) then
                fresh = i
            end
        end
    end
    if fresh then return fresh - 1, rows[fresh].name, rows[fresh].cost end
    local best
    for i, r in ipairs(rows) do
        if r.online > 0 then
            if not best or r.cost < rows[best].cost
                or (r.cost == rows[best].cost and r.online > rows[best].online) then
                best = i
            end
        end
    end
    if not best then
        best = 1
        for i, r in ipairs(rows) do if r.cost < rows[best].cost then best = i end end
    end
    return best - 1, rows[best].name, rows[best].cost
end
local function resendLater(m, delaySec)
    lua_thread.create(function()
        wait(delaySec * 1000)
        if m.active and canSend() then
            local t = (msgText(m):gsub('^%s+', ''))
            local lenErr = AP.adCheck(t)
            if lenErr then
                AP.fail(m, 'Остановлено: ' .. lenErr, true)
            else
                pendingAd = { m = m, mode = 'new', till = os.clock() + 20 }
                AP.lastSend = { m = m, cmd = '/ad', at = os.clock(), prevReady = VR.readyAt, text = t }
                sampSendChat(u8:decode('/ad ' .. t))
            end
        end
    end)
end
function AP.stripName(s)
    s = u8lower((s:gsub('%s*%b()%s*$', '')))
    return s
end
function AP.nameIndex()
    if AP.nameIdx then return AP.nameIdx end
    local idx = {}
    for _, it in ipairs(items) do
        local k = u8lower(it.name)
        idx[k] = idx[k] or {}
        table.insert(idx[k], it.id)
    end
    AP.nameIdx = idx
    return idx
end
function AP.syncStart()
    if AP.sync then return end
    if not canSend() then
        notify('Нельзя обновить инвентарь: сначала закрой открытые диалоги и чат.')
        return
    end
    AP.sync = { state = 'stats', till = os.clock() + 10, rows = {}, pages = 0 }
    sampSendChat('/stats')
end
function AP.syncFinish()
    local rows = AP.sync.rows
    AP.sync = nil
    local idx = AP.nameIndex()
    local old, new = AP.inv[1], {}
    local ok, amb, unk = 0, 0, 0
    for _, r in ipairs(rows) do
        local cur = old[r.slot]
        local key, skey = u8lower(r.name), AP.stripName(r.name)
        local curIt = cur and itemById[cur.item]
        if curIt and (u8lower(curIt.name) == key or AP.stripName(curIt.name) == skey) then
            local e = {}
            for k, v in pairs(cur) do e[k] = v end
            if r.amount then e.amount = r.amount end
            new[r.slot] = e
            ok = ok + 1
        else
            local ids = idx[key] or idx[skey]
            if ids and #ids == 1 then
                new[r.slot] = { item = ids[1], amount = r.amount, text = '' }
                ok = ok + 1
            elseif ids then
                amb = amb + 1
            else
                unk = unk + 1
            end
        end
    end
    for k in pairs(old) do old[k] = nil end
    for k, v in pairs(new) do old[k] = v end
    AP.invMeta[1].full = true
    AP.invVer = AP.invVer + 1
    AP.invSaved = nil
    local msg = ('Инвентарь обновлён (загружено предметов: %d).'):format(ok)
    if amb + unk > 0 then
        msg = msg .. (' Не опознано: %d, у них одинаковые или неизвестные названия.'):format(amb + unk)
    end
    notify(msg)
end
function AP.syncDialog(id, title, text)
    local s = AP.sync
    if s.state == 'stats' then
        if has(title, 'Основная статистика') then
            sampSendDialogResponse(id, 1, 0, '')
            s.state = 'list'
            return false
        end
    elseif s.state == 'list' and has(text, '[слот] Название') then
        s.pages = s.pages + 1
        local nextIdx, nextText
        local n = -1
        for line in (u8(text) .. '\n'):gmatch('(.-)\n') do
            if line ~= '' then
                local plainLine = line:gsub('{%x%x%x%x%x%x}', '')
                if n >= 0 then
                    local cell = plainLine:match('^([^\t]*)') or plainLine
                    if cell:find('^>>') then
                        nextIdx, nextText = n, u8:decode(cell)
                    else
                        local slot, name = cell:match('^%[(%d+)%]%s*(.+)$')
                        if slot then
                            local qty = plainLine:match('\t%[(%d+)%s*шт')
                            s.rows[#s.rows + 1] = { slot = tonumber(slot), name = name, amount = tonumber(qty) }
                        end
                    end
                end
                n = n + 1
            end
        end
        if nextIdx and s.pages < 60 then
            sampSendDialogResponse(id, 1, nextIdx, nextText)
        else
            sampSendDialogResponse(id, 0, 0, '')
            AP.syncFinish()
        end
        return false
    end
end
function AP.stopAll()
    for _, m in ipairs(msgs) do
        m.active = false
        m.checkAt = nil
        m.waitSince = nil
        m.mutePaused = nil
    end
    pendingAd, pendingVr = nil, nil
end
function AP.muteStop()
    local n = 0
    for _, m in ipairs(msgs) do
        if m.active and CMDS[m.cmd[0] + 1] ~= '/ad' then
            m.active = false
            m.checkAt = nil
            m.waitSince = nil
            m.mutePaused = true
            n = n + 1
        end
    end
    return n
end
function AP.onMute(secs)
    local now = os.clock()
    local first = AP.muteLeft() <= 0
    MUTE.untilAt = now + secs
    pendingVr = nil
    local ls = AP.lastSend
    if ls and now - ls.at < 4 then
        local m = ls.m
        if ls.cmd == '/ad' then
            pendingAd = nil
            if m.active then AP.fail(m, 'Остановлено: ты получил мут чата', true) end
        else
            if m.sent and m.sent > 0 then m.sent = m.sent - 1 end
            if ls.idx then m.idx = ls.idx end
            if m.lim[0] and ls.done then
                m.left = m.left + 1
                if not m.active and ls.limEnd then m.mutePaused = true end
            end
            if ls.cmd == '/vr' and ls.prevReady then VR.readyAt = ls.prevReady end
        end
    end
    AP.lastSend = nil
    local n = AP.muteStop()
    if first or n > 0 then
        notify(('Получен мут (осталось %s). Рассылка в чаты временно остановлена.'):format(AP.muteText(secs)))
    end
end
function AP.parseVrCd(text)
    local t = plain(text)
    if t:find('%[%d+%]') then return nil end
    local ls = AP.lastSend
    if ls and ls.text and #ls.text >= 8 and t:find(ls.text:sub(1, 8), 1, true) then return nil end
    local stems = { 'раз в', 'одожд', 'талось', 'жидай', 'еклам', 'vr', 'VR', 'КД' }
    local hit = false
    for _, s in ipairs(stems) do
        if t:find(u8:decode(s), 1, true) then hit = true break end
    end
    if not hit then return nil end
    local mi = tonumber(t:match('(%d+)%s*' .. u8:decode('мин')))
    local se = tonumber(t:match('(%d+)%s*' .. u8:decode('сек')))
    if not mi and not se then return nil end
    local total = (mi or 0) * 60 + (se or 0)
    if total <= 0 then return nil end
    return total, t:find(u8:decode('раз в') .. '%s*%d') ~= nil
end
function AP.onVrCd(sec, interval)
    local ls = AP.lastSend
    local now = os.clock()
    if interval then
        VR.cd = math.max(30, math.min(7200, math.floor(sec)))
        VR.readyAt = ls.at + VR.cd + 1
    else
        VR.readyAt = now + sec + 1
    end
    local m = ls.m
    if m.sent and m.sent > 0 then m.sent = m.sent - 1 end
    if m.lim[0] and m.active then m.left = m.left + 1 end
    pendingVr = nil
    AP.lastSend = nil
end
function sampev.onServerMessage(color, text)
    local pt = plain(text)
    if pt:find('^%s*' .. u8:decode('Вы заглушены')) then
        local secs = tonumber(pt:match(u8:decode('заглушки') .. '%s*(%d+)'))
        if secs and secs > 0 then pcall(AP.onMute, secs) end
        return
    end
    local ls = AP.lastSend
    if ls and ls.cmd == '/vr' and ls.m.ad[0] and os.clock() - ls.at < 5 then
        local okp, sec, interval = pcall(AP.parseVrCd, text)
        if okp and sec then
            pcall(AP.onVrCd, sec, interval)
            return
        end
    end
    if not has(text, 'Отправлять объявления можно') then return end
    local now = os.clock()
    local n = tonumber(plain(text):match(u8:decode('раз в (%d+)')))
    if n and n > 0 then
        adCfg.cd = n
        local ready = AP.lastAdAt and (AP.lastAdAt + n + 1) or 0
        if ready <= now then ready = now + n + 1 end
        AP.adReadyAt = ready
    else
        AP.adReadyAt = now + (adCfg.cd or 30) + 1
    end
    pendingAd = nil
end
function sampev.onShowDialog(id, style, title, button1, button2, text)
    if AP.sync then
        local r = AP.syncDialog(id, title, text)
        if r ~= nil then return r end
    end
    local now = os.clock()
    if pendingVr and now < pendingVr.till and has(text, 'является рекламой') then
        sampSendDialogResponse(id, pendingVr.ad and 1 or 0, -1, '')
        pendingVr = nil
        return false
    end
    if pendingAd and now < pendingAd.till then
        local m = pendingAd.m
        if has(title, 'радиостанцию') then
            if pendingAd.mode == 'check' then
                sampSendDialogResponse(id, 0, -1, '')
                pendingAd = nil
                return false
            end
            local sidx, sname, scost = pickStation(text, m.city[0])
            pendingAd.smi = sname and u8(sname)
            pendingAd.cost = scost
            sampSendDialogResponse(id, 1, sidx, '')
            return false
        elseif has(title, 'тип объявления') then
            sampSendDialogResponse(id, 1, m.vip[0] and 1 or 0, '')
            return false
        elseif has(title, 'Подтверждение') then
            sampSendDialogResponse(id, 1, -1, '')
            m.checkAt = m.rs[0] and (now + math.max(10, m.rsec[0])) or nil
            AP.lastAdAt = now
            if adCfg.cd then AP.adReadyAt = now + adCfg.cd + 1 end
            if pendingAd.smi then m.smi = pendingAd.smi end
            local costStr = plain(text):match(u8:decode('Стоимость объявления:%s*:CASH:([%d%.]+)'))
            local realCost = costStr and tonumber((costStr:gsub('%.', '')))
            if realCost and realCost > 0 then pendingAd.cost = realCost end
            if pendingAd.cost and pendingAd.cost > 0 then m.cost = pendingAd.cost end
            m.sent = (m.sent or 0) + 1
            m.sentAt = os.date('%H:%M')
            pendingAd = nil
            return false
        elseif has(text, 'еще не рассмотрено') then
            if pendingAd.mode == 'check' then
                sampSendDialogResponse(id, 1, -1, '')
                pendingAd = nil
                resendLater(m, 2)
            else
                sampSendDialogResponse(id, 0, -1, '')
                pendingAd = nil
            end
            return false
        end
    end
end
local function tooltip(text)
    if imgui.IsItemHovered() then
        imgui.BeginTooltip()
        imgui.PushTextWrapPos(300)
        imgui.TextUnformatted(text)
        imgui.PopTextWrapPos()
        imgui.EndTooltip()
    end
end
local function toU32(r, g, b, a)
    return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, a or 1))
end
local function iconClose(id, size)
    size = size or 22
    local p = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton(id, imgui.ImVec2(size, size))
    local dl = imgui.GetWindowDrawList()
    local hovered = imgui.IsItemHovered()
    local inset = 2
    if hovered then
        dl:AddRectFilled(
            imgui.ImVec2(p.x + inset, p.y + inset),
            imgui.ImVec2(p.x + size - inset, p.y + size - inset),
            toU32(0.75, 0.18, 0.18, 0.7), 3)
    end
    local col = hovered and toU32(1, 1, 1, 1) or toU32(0.85, 0.87, 0.95, 1)
    local pad = size * 0.30
    dl:AddLine(imgui.ImVec2(p.x + pad, p.y + pad), imgui.ImVec2(p.x + size - pad, p.y + size - pad), col, 1.8)
    dl:AddLine(imgui.ImVec2(p.x + size - pad, p.y + pad), imgui.ImVec2(p.x + pad, p.y + size - pad), col, 1.8)
    return clicked
end
local function iconTrash(id, size)
    size = size or 22
    local p = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton(id, imgui.ImVec2(size, size))
    local dl = imgui.GetWindowDrawList()
    local hovered = imgui.IsItemHovered()
    local inset = 2
    if hovered then
        dl:AddRectFilled(
            imgui.ImVec2(p.x + inset, p.y + inset),
            imgui.ImVec2(p.x + size - inset, p.y + size - inset),
            toU32(0.70, 0.18, 0.18, 0.55), 3)
    end
    local col = hovered and toU32(1, 0.45, 0.45, 1) or toU32(0.70, 0.72, 0.85, 1)
    local x, y, s = p.x, p.y, size
    dl:AddLine(imgui.ImVec2(x + s * 0.22, y + s * 0.30), imgui.ImVec2(x + s * 0.78, y + s * 0.30), col, 1.5)
    dl:AddLine(imgui.ImVec2(x + s * 0.38, y + s * 0.22), imgui.ImVec2(x + s * 0.62, y + s * 0.22), col, 1.5)
    dl:AddLine(imgui.ImVec2(x + s * 0.38, y + s * 0.22), imgui.ImVec2(x + s * 0.38, y + s * 0.30), col, 1.5)
    dl:AddLine(imgui.ImVec2(x + s * 0.62, y + s * 0.22), imgui.ImVec2(x + s * 0.62, y + s * 0.30), col, 1.5)
    dl:AddLine(imgui.ImVec2(x + s * 0.28, y + s * 0.30), imgui.ImVec2(x + s * 0.32, y + s * 0.78), col, 1.5)
    dl:AddLine(imgui.ImVec2(x + s * 0.72, y + s * 0.30), imgui.ImVec2(x + s * 0.68, y + s * 0.78), col, 1.5)
    dl:AddLine(imgui.ImVec2(x + s * 0.32, y + s * 0.78), imgui.ImVec2(x + s * 0.68, y + s * 0.78), col, 1.5)
    dl:AddLine(imgui.ImVec2(x + s * 0.42, y + s * 0.38), imgui.ImVec2(x + s * 0.42, y + s * 0.70), col, 1.2)
    dl:AddLine(imgui.ImVec2(x + s * 0.50, y + s * 0.38), imgui.ImVec2(x + s * 0.50, y + s * 0.70), col, 1.2)
    dl:AddLine(imgui.ImVec2(x + s * 0.58, y + s * 0.38), imgui.ImVec2(x + s * 0.58, y + s * 0.70), col, 1.2)
    return clicked
end
local function iconCopy(id, size)
    size = size or 22
    local p = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton(id, imgui.ImVec2(size, size))
    local dl = imgui.GetWindowDrawList()
    local hovered = imgui.IsItemHovered()
    local inset = 2
    if hovered then
        dl:AddRectFilled(
            imgui.ImVec2(p.x + inset, p.y + inset),
            imgui.ImVec2(p.x + size - inset, p.y + size - inset),
            toU32(0.20, 0.50, 0.80, 0.55), 3)
    end
    local col = hovered and toU32(0.60, 0.85, 1, 1) or toU32(0.70, 0.72, 0.85, 1)
    local x, y, s = p.x, p.y, size
    dl:AddRect(imgui.ImVec2(x + s * 0.34, y + s * 0.24), imgui.ImVec2(x + s * 0.76, y + s * 0.68), col, 2, 15, 1.5)
    dl:AddLine(imgui.ImVec2(x + s * 0.24, y + s * 0.34), imgui.ImVec2(x + s * 0.24, y + s * 0.80), col, 1.5)
    dl:AddLine(imgui.ImVec2(x + s * 0.24, y + s * 0.80), imgui.ImVec2(x + s * 0.64, y + s * 0.80), col, 1.5)
    return clicked
end
local function toggleSwitch(id, on)
    local w, h = 30, 16
    local p = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton(id, imgui.ImVec2(w, h))
    local dl = imgui.GetWindowDrawList()
    local bg = on and toU32(0.20, 0.72, 0.52, 1) or toU32(0.28, 0.30, 0.38, 1)
    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), bg, h / 2)
    local kx = on and (p.x + w - h / 2) or (p.x + h / 2)
    dl:AddCircleFilled(imgui.ImVec2(kx, p.y + h / 2), h / 2 - 2.5, toU32(1, 1, 1, 1), 16)
    return clicked
end
local bitlib = require 'bit'
UPD.self = thisScript()
UPD.ver  = tostring(thisScript().version)
UPD.path = tostring(thisScript().path)
local dlOk, dlstatus = pcall(function() return require('moonloader').download_status end)
UPD.tmp = CONFIG_DIR .. '\\update.tmp'
function UPD.startDownload(url)
    if not dlOk or not dlstatus or not downloadUrlToFile then
        error('эта версия MoonLoader не умеет скачивать файлы', 0)
    end
    createDirectory(CONFIG_DIR)
    os.remove(UPD.tmp)
    local sep = url:find('?', 1, true) and '&' or '?'
    local dl = { done = false, t0 = os.clock() }
    UPD.dl = dl
    downloadUrlToFile(url .. sep .. 't=' .. os.time(), UPD.tmp, function(id, status)
        if status == dlstatus.STATUSEX_ENDDOWNLOAD then dl.done = true end
    end)
end
function UPD.waitDownload(onDone)
    local dl = UPD.dl
    if dl.done then
        if not doesFileExist(UPD.tmp) then error('GitHub не отдал файл: нет связи или файла нет в репозитории', 0) end
        onDone()
    elseif os.clock() - dl.t0 > 20 then
        error('GitHub не ответил за 20 секунд', 0)
    end
end
function UPD.readFile(p)
    local f = io.open(p, 'rb')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return s
end
local SHA_K = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
}
function UPD.sha256(s)
    local band, bxor, bnot, rshift, lshift, ror, tobit, bor =
        bitlib.band, bitlib.bxor, bitlib.bnot, bitlib.rshift, bitlib.lshift, bitlib.ror, bitlib.tobit, bitlib.bor
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    local bits = #s * 8
    local hi, lo = math.floor(bits / 4294967296), bits % 4294967296
    local function be32(n)
        return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
    end
    local msg = s .. '\128' .. string.rep('\0', (55 - #s) % 64) .. be32(hi) .. be32(lo)
    local w = {}
    local blocks = #msg / 64
    for b = 0, blocks - 1 do
        local base = b * 64
        for i = 0, 15 do
            local x, y, z, t = msg:byte(base + i * 4 + 1, base + i * 4 + 4)
            w[i] = bor(lshift(x, 24), lshift(y, 16), lshift(z, 8), t)
        end
        for i = 16, 63 do
            local w15, w2 = w[i - 15], w[i - 2]
            local s0 = bxor(ror(w15, 7), ror(w15, 18), rshift(w15, 3))
            local s1 = bxor(ror(w2, 17), ror(w2, 19), rshift(w2, 10))
            w[i] = tobit(w[i - 16] + s0 + w[i - 7] + s1)
        end
        local a, bb, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for i = 0, 63 do
            local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = tobit(h + S1 + ch + SHA_K[i + 1] + w[i])
            local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
            local maj = bxor(band(a, bb), band(a, c), band(bb, c))
            local t2 = tobit(S0 + maj)
            h, g, f, e, d, c, bb, a = g, f, e, tobit(d + t1), c, bb, a, tobit(t1 + t2)
        end
        h0, h1, h2, h3 = tobit(h0 + a), tobit(h1 + bb), tobit(h2 + c), tobit(h3 + d)
        h4, h5, h6, h7 = tobit(h4 + e), tobit(h5 + f), tobit(h6 + g), tobit(h7 + h)
    end
    local hex = bitlib.tohex
    return hex(h0) .. hex(h1) .. hex(h2) .. hex(h3) .. hex(h4) .. hex(h5) .. hex(h6) .. hex(h7)
end
function UPD.isNewer(a, b)
    local pa, pb = {}, {}
    for n in tostring(a):gmatch('%d+') do pa[#pa + 1] = tonumber(n) end
    for n in tostring(b):gmatch('%d+') do pb[#pb + 1] = tonumber(n) end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end
function UPD.parseInfo(text)
    text = tostring(text or ''):gsub('^\239\187\191', '')
    local function readStr(s, i)
        local out, j = {}, i + 1
        while j <= #s do
            local c = s:sub(j, j)
            if c == '\\' then
                local n = s:sub(j + 1, j + 1)
                out[#out + 1] = (n == 'n') and '\n' or n
                j = j + 2
            elseif c == '"' then
                return table.concat(out), j + 1
            else
                out[#out + 1] = c
                j = j + 1
            end
        end
    end
    local function field(name)
        local _, b = text:find('"' .. name .. '"%s*:%s*"')
        if not b then return nil end
        return (readStr(text, b))
    end
    local d = {
        version = field('version'),
        url = field('url'),
        sha256 = field('sha256'),
        date = field('date') or field('release_date'),
        changes = {},
    }
    local _, lb = text:find('"changes"%s*:%s*%[')
    if lb then
        local i = lb + 1
        while i <= #text do
            local c = text:sub(i, i)
            if c == ']' then break end
            if c == '"' then
                local s, nxt = readStr(text, i)
                if not s then break end
                d.changes[#d.changes + 1] = s
                i = nxt
            else
                i = i + 1
            end
        end
    else
        local one = field('changes')
        if one then d.changes[1] = one end
    end
    return d
end
function UPD.handleInfo(text)
    local d = UPD.parseInfo(text)
    if not d.version or not d.url then
        error('version.json пустой или повреждён', 0)
    end
    if UPD.isNewer(d.version, UPD.ver) then
        if UPD.manual or d.version ~= UPD.skip then
            UPD.info = d
            UPD.status = 'Доступна новая версия'
        else
            UPD.status = 'Версия ' .. d.version .. ' пропущена'
        end
    else
        UPD.info = nil
        UPD.status = 'Установлена последняя версия'
    end
end
UPD.every = 3 * 3600
function UPD.check(manual)
    if UPD.busy then return end
    UPD.nextAt = os.clock() + UPD.every
    UPD.errDetail = nil
    UPD.busy = true
    UPD.manual = manual and true or false
    UPD.state = 'check_start'
    UPD.status = 'Проверяю...'
end
function UPD.apply()
    if UPD.busy or not UPD.info then return end
    UPD.busy = true
    UPD.target = UPD.info
    UPD.state = 'apply_start'
    UPD.status = 'Скачиваю...'
end
function UPD.jsonDecode(str)
    str = tostring(str or ''):gsub('^\239\187\191', '')
    local pos = 1
    local function skip() pos = str:find('[^ \t\r\n]', pos) or (#str + 1) end
    local function utf8char(cp)
        if cp < 0x80 then return string.char(cp)
        elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
        elseif cp < 0x10000 then
            return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
        end
        return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
            0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    local function parseString()
        local out = {}
        pos = pos + 1
        while true do
            local a = str:find('["\\]', pos)
            if not a then error('json: строка не закрыта', 0) end
            out[#out + 1] = str:sub(pos, a - 1)
            pos = a
            if str:sub(pos, pos) == '"' then
                pos = pos + 1
                break
            end
            local n = str:sub(pos + 1, pos + 1)
            if n == 'u' then
                local hex = str:match('^%x%x%x%x', pos + 2)
                if not hex then error('json: плохой код \\u', 0) end
                local cp = tonumber(hex, 16)
                pos = pos + 6
                if cp >= 0xD800 and cp <= 0xDBFF then
                    local lo = str:match('^\\u(%x%x%x%x)', pos)
                    if lo then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (tonumber(lo, 16) - 0xDC00)
                        pos = pos + 6
                    end
                end
                out[#out + 1] = utf8char(cp)
            else
                local map = { n = '\n', t = '\t', r = '\r', b = '\b', f = '\f' }
                out[#out + 1] = map[n] or n
                pos = pos + 2
            end
        end
        return table.concat(out)
    end
    local parseValue
    parseValue = function()
        skip()
        local c = str:sub(pos, pos)
        if c == '{' then
            pos = pos + 1
            local t = {}
            skip()
            if str:sub(pos, pos) == '}' then pos = pos + 1 return t end
            while true do
                skip()
                if str:sub(pos, pos) ~= '"' then error('json: ожидалось имя поля', 0) end
                local k = parseString()
                skip()
                if str:sub(pos, pos) ~= ':' then error('json: ожидалось двоеточие', 0) end
                pos = pos + 1
                t[k] = parseValue()
                skip()
                local d = str:sub(pos, pos)
                pos = pos + 1
                if d == '}' then return t end
                if d ~= ',' then error('json: ожидалась запятая', 0) end
            end
        elseif c == '[' then
            pos = pos + 1
            local t = {}
            skip()
            if str:sub(pos, pos) == ']' then pos = pos + 1 return t end
            while true do
                t[#t + 1] = parseValue()
                skip()
                local d = str:sub(pos, pos)
                pos = pos + 1
                if d == ']' then return t end
                if d ~= ',' then error('json: ожидалась запятая', 0) end
            end
        elseif c == '"' then
            return parseString()
        end
        local num = str:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
        if num and num ~= '' then
            pos = pos + #num
            return tonumber(num)
        end
        if str:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true end
        if str:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false end
        if str:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil end
        error('json: непонятный символ', 0)
    end
    return parseValue()
end
function UPD.histUrl()
    return (UPD.url:gsub('[^/]+$', 'changelog.json'))
end
function UPD.fetchHist()
    if UPD.busy then return end
    UPD.busy = true
    UPD.histErr = nil
    UPD.state = 'hist_start'
end
function UPD.step(st)
    if st == 'check_start' then
        if UPD.url:find('USER/REPO', 1, true) then
            error('Адрес обновлений не указан в скрипте', 0)
        end
        UPD.startDownload(UPD.url)
        UPD.state = 'check_wait'
    elseif st == 'check_wait' then
        UPD.waitDownload(function()
            local text = UPD.readFile(UPD.tmp)
            os.remove(UPD.tmp)
            if text and text:find('^%s*404') then
                error('репозиторий закрыт или файла там нет (GitHub ответил 404)', 0)
            end
            UPD.handleInfo(text)
            UPD.lastCheck = os.date('%H:%M')
            UPD.state = nil
            UPD.busy = false
        end)
    elseif st == 'hist_start' then
        if UPD.url:find('USER/REPO', 1, true) then
            error('адрес обновлений не указан в скрипте', 0)
        end
        UPD.startDownload(UPD.histUrl())
        UPD.state = 'hist_wait'
    elseif st == 'hist_wait' then
        UPD.waitDownload(function()
            local text = UPD.readFile(UPD.tmp)
            os.remove(UPD.tmp)
            if text and text:find('^%s*404') then
                error('файла с историей нет в репозитории (GitHub ответил 404)', 0)
            end
            local ok, d = pcall(UPD.jsonDecode, text)
            if not ok or type(d) ~= 'table' or type(d.versions) ~= 'table' then
                error('файл истории пустой или повреждён', 0)
            end
            AP.hist = d.versions
            UPD.state = nil
            UPD.busy = false
        end)
    elseif st == 'apply_start' then
        local info = UPD.target
        if not tostring(info.url):find('^https://raw%.githubusercontent%.com/') then
            error('ссылка ведёт не на GitHub, обновление остановлено', 0)
        end
        UPD.startDownload(info.url)
        UPD.state = 'apply_wait'
    elseif st == 'apply_wait' then
        UPD.waitDownload(function()
            local info = UPD.target
            local data = UPD.readFile(UPD.tmp)
            os.remove(UPD.tmp)
            if data and data:find('^%s*404') then
                error('репозиторий закрыт или файла там нет (GitHub ответил 404)', 0)
            end
            if not data or #data < 1000 or not data:find("script_name('AutoPiar')", 1, true) then
                error('скачался не тот файл, обновление отменено', 0)
            end
            if info.sha256 and tostring(info.sha256) ~= '' then
                UPD.status = 'Проверяю файл...'
                if UPD.sha256(data) ~= tostring(info.sha256):lower() then
                    error('файл скачался с ошибкой (не совпала контрольная сумма), обновление отменено', 0)
                end
            end
            local f = io.open(UPD.path, 'wb')
            if not f then error('не получилось записать файл скрипта', 0) end
            f:write(data)
            f:close()
            UPD.status = 'Готово, перезапускаю скрипт'
            notify('Скрипт обновлён до v' .. tostring(info.version) .. ' и перезапускается. Если буквы в окне станут квадратами, перезайди в игру.')
            UPD.reloadAt = os.clock() + 0.7
            UPD.state = 'reload'
        end)
    elseif st == 'reload' then
        if os.clock() >= UPD.reloadAt then
            UPD.state = nil
            UPD.self:reload()
        end
    end
end
function UPD.tick()
    local st = UPD.state
    if not st then return end
    local ok, err = pcall(UPD.step, st)
    if not ok then
        if st:find('^hist') then
            UPD.histErr = tostring(err)
        else
            if st:find('^check') then
                UPD.status = 'Не удалось проверить: нет связи с сервером или репозиторий недоступен.'
                UPD.errDetail = tostring(err)
            else
                UPD.status = 'Ошибка: ' .. tostring(err)
                UPD.errDetail = nil
            end
        end
        UPD.state = nil
        UPD.busy = false
    end
end
UPD.ids = { ask = '##updask', info = '##appanel', settings = '##appanel' }
local AMBER = imgui.ImVec4(1.0, 0.74, 0.28, 1)
local GREEN = imgui.ImVec4(0.30, 0.85, 0.62, 1)
local GRAY  = imgui.ImVec4(0.70, 0.71, 0.77, 1)
local RED   = imgui.ImVec4(1.0, 0.45, 0.40, 1)
function UPD.btn(label, w, h, kind)
    local c = (kind == 'primary')
        and { { 0.12, 0.55, 0.38 }, { 0.16, 0.68, 0.46 }, { 0.10, 0.45, 0.31 } }
        or  { { 0.17, 0.18, 0.23 }, { 0.24, 0.25, 0.31 }, { 0.29, 0.30, 0.37 } }
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(c[1][1], c[1][2], c[1][3], 1))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(c[2][1], c[2][2], c[2][3], 1))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(c[3][1], c[3][2], c[3][3], 1))
    local r = imgui.Button(label, imgui.ImVec2(w, h))
    imgui.PopStyleColor(3)
    return r
end
function UPD.close()
    UPD.view = nil
    imgui.CloseCurrentPopup()
end
function UPD.title(text, withClose)
    AP.bigText(text, AMBER)
    if withClose then
        imgui.SameLine(imgui.GetWindowContentRegionMax().x - (L.close_size + 2))
        if iconClose('##updx', L.close_size) then UPD.close() end
    end
end
function UPD.grayText(text)
    imgui.PushStyleColor(imgui.Col.Text, GRAY)
    imgui.TextWrapped(text)
    imgui.PopStyleColor()
end
function UPD.pill(cur, new)
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local a, b = tostring(cur), tostring(new)
    local wa, wb = imgui.CalcTextSize(a).x, imgui.CalcTextSize(b).x
    local h, padX, arrow = 30, 14, 28
    local w = padX * 2 + wa + arrow + wb
    dl:AddRectFilled(imgui.ImVec2(p.x, p.y), imgui.ImVec2(p.x + w, p.y + h), toU32(0.13, 0.14, 0.18, 1), 15)
    local ty = p.y + (h - imgui.GetTextLineHeight()) / 2
    dl:AddText(imgui.ImVec2(p.x + padX, ty), toU32(0.60, 0.61, 0.66, 1), a)
    local ax, ay = p.x + padX + wa + 6, p.y + h / 2
    local ac = toU32(0.55, 0.56, 0.62, 1)
    dl:AddLine(imgui.ImVec2(ax, ay), imgui.ImVec2(ax + 16, ay), ac, 1.5)
    dl:AddLine(imgui.ImVec2(ax + 11, ay - 4), imgui.ImVec2(ax + 16, ay), ac, 1.5)
    dl:AddLine(imgui.ImVec2(ax + 11, ay + 4), imgui.ImVec2(ax + 16, ay), ac, 1.5)
    dl:AddText(imgui.ImVec2(p.x + padX + wa + arrow, ty), toU32(0.30, 0.85, 0.62, 1), b)
    imgui.Dummy(imgui.ImVec2(w, h))
end
function UPD.progress()
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local h = 6
    dl:AddRectFilled(imgui.ImVec2(p.x, p.y), imgui.ImVec2(p.x + w, p.y + h), toU32(0.13, 0.14, 0.18, 1), 3)
    local seg = w * 0.3
    local t = (os.clock() * 0.9) % 1
    local x0 = p.x + (w + seg) * t - seg
    local xa, xb = math.max(p.x, x0), math.min(p.x + w, x0 + seg)
    if xb > xa then
        dl:AddRectFilled(imgui.ImVec2(xa, p.y), imgui.ImVec2(xb, p.y + h), toU32(0.30, 0.85, 0.62, 1), 3)
    end
    imgui.Dummy(imgui.ImVec2(w, h))
end
function UPD.statusLine()
    if UPD.status == '' then return end
    local bad = UPD.status:find('^Ошибка') or UPD.status:find('^Не удалось') or UPD.status:find('^Адрес')
    imgui.PushStyleColor(imgui.Col.Text, bad and RED or GRAY)
    imgui.TextWrapped(UPD.status)
    imgui.PopStyleColor()
end
function UPD.footer()
    if toggleSwitch('##updautosw', UPD.enabled == true) then
        UPD.enabled = not UPD.enabled
        UPD.chk[0] = UPD.enabled
        save()
        if UPD.enabled then UPD.check(false) end
    end
    imgui.SameLine(0, 10)
    imgui.Text('Проверять обновления автоматически')
    tooltip('Скрипт смотрит, не вышла ли новая версия, при запуске игры и потом каждые 3 часа. Сам он ничего не ставит: обновление только по твоей кнопке.')
end
UPD.askT1 = 'Скрипт может сам проверять, не вышла ли новая версия.'
UPD.askT2 = 'Файл сам не меняется. Когда выйдет новая версия, в шапке окна появится кнопка «Обновление!». Нажмёшь её, только если захочешь.'
UPD.askT3 = 'Передумать можно позже: «Настройки» -> «Обновления».'
function UPD.drawAsk(w)
    UPD.title('Проверять обновления?', false)
    imgui.Spacing()
    imgui.TextWrapped(UPD.askT1)
    imgui.Spacing()
    UPD.grayText(UPD.askT2)
    imgui.Spacing()
    UPD.grayText(UPD.askT3)
    imgui.SetCursorPosY(imgui.GetWindowHeight() - 18 - 38)
    local bw = (imgui.GetContentRegionAvail().x - 10) / 2
    local function answer(v)
        UPD.enabled = v
        UPD.chk[0] = v
        save()
        UPD.close()
        if v then UPD.check(false) end
    end
    if UPD.btn('Да, проверять', bw, 38, 'primary') then answer(true) end
    imgui.SameLine(0, 10)
    if UPD.btn('Не нужно', bw, 38, 'ghost') then answer(false) end
end
function UPD.drawInfo(w)
    local info = UPD.info
    UPD.title(info and 'Доступно обновление' or 'Обновления', true)
    imgui.Spacing()
    if info then
        UPD.pill(UPD.ver, info.version)
        local date = info.date or info.release_date
        if date then
            imgui.SameLine(0, 10)
            imgui.AlignTextToFramePadding()
            UPD.grayText('от ' .. tostring(date))
        end
        imgui.Spacing()
        imgui.PushStyleColor(imgui.Col.Text, GRAY)
        imgui.Text('Что нового')
        imgui.PopStyleColor()
        local bottomH = UPD.busy and 96 or 168
        local childH = math.max(60, imgui.GetContentRegionAvail().y - bottomH)
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.05, 0.055, 0.07, 1))
        imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 8)
        imgui.PushStyleVarFloat(imgui.StyleVar.ChildBorderSize, 0)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(12, 10))
        imgui.BeginChild('##updchanges', imgui.ImVec2(0, childH), true)
        if #info.changes == 0 then
            imgui.TextDisabled('Автор не описал изменения')
        end
        for _, c in ipairs(info.changes) do
            imgui.Bullet()
            imgui.SameLine(0, 6)
            imgui.TextWrapped(tostring(c))
        end
        imgui.EndChild()
        imgui.PopStyleVar(3)
        imgui.PopStyleColor()
        imgui.Spacing()
        if UPD.busy then
            UPD.statusLine()
            imgui.Spacing()
            UPD.progress()
            return
        end
        UPD.statusLine()
        local full = imgui.GetContentRegionAvail().x
        if UPD.btn('Обновить', full, 38, 'primary') then UPD.apply() end
        local bw = (full - 10) / 2
        if UPD.btn('Позже', bw, 30, 'ghost') then UPD.close() end
        imgui.SameLine(0, 10)
        if UPD.btn('Пропустить версию', bw, 30, 'ghost') then
            UPD.skip = tostring(info.version)
            UPD.info = nil
            UPD.status = ''
            save()
            UPD.close()
        end
        tooltip('Эту версию скрипт больше не предлагает. О следующей напомнит.')
        imgui.Spacing()
        UPD.footer()
    else
        imgui.Text('Установлена версия: ' .. UPD.ver)
        imgui.Spacing()
        UPD.statusLine()
        imgui.SetCursorPosY(imgui.GetWindowHeight() - 18 - 74)
        local bw = (imgui.GetContentRegionAvail().x - 10) / 2
        if UPD.busy then
            imgui.AlignTextToFramePadding()
            imgui.PushStyleColor(imgui.Col.Text, GRAY)
            imgui.Text('Проверяю...')
            imgui.PopStyleColor()
            imgui.Dummy(imgui.ImVec2(1, 8))
            UPD.progress()
        else
            if UPD.btn('Проверить сейчас', bw, 36, 'primary') then UPD.check(true) end
            imgui.SameLine(0, 10)
            if UPD.btn('Закрыть', bw, 36, 'ghost') then UPD.close() end
            imgui.Spacing()
            UPD.footer()
        end
    end
end
function AP.setOrg(o)
    if RADIO.org == o then return end
    RADIO.org = o
    rebuildCmdItems()
    save()
end
function AP.drawChips()
    local ml = AP.muteLeft()
    if ml > 0 then
        imgui.SameLine(0, 16)
        imgui.TextColored(RED, 'Мут: осталось ' .. AP.muteText(ml))
        tooltip('Сервер выдал мут: отправка сообщений временно остановлена. Осталось: ' .. AP.fmtTime(ml)
            .. '.\nАвтовозобновление настраивается во вкладке «Мут».')
    end
    local vl = VR.readyAt - os.clock()
    if vl > 0 then
        imgui.SameLine(0, 16)
        imgui.TextColored(AMBER, 'КД /vr: ' .. AP.fmtTime(vl))
        tooltip('Общая задержка платной рекламы в /vr для всех твоих пиаров. Следующая отправка идёт по очереди после неё.')
    end
end
function AP.box(id, w, h, fn)
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.095, 0.105, 0.135, 1))
    imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 10)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(14, 10))
    imgui.BeginChild(id, imgui.ImVec2(w, h), true,
        bit.bor(imgui.WindowFlags.NoScrollbar, imgui.WindowFlags.NoScrollWithMouse))
    imgui.PopStyleVar()
    fn()
    imgui.EndChild()
    imgui.PopStyleVar()
    imgui.PopStyleColor()
end
function AP.sub(text)
    imgui.PushStyleColor(imgui.Col.Text, GRAY)
    imgui.Text(text)
    imgui.PopStyleColor()
    imgui.Spacing()
end
function AP.bullets(list)
    for _, t in ipairs(list) do
        imgui.PushStyleColor(imgui.Col.Text, GRAY)
        imgui.Bullet()
        imgui.SameLine(0, 8)
        imgui.TextWrapped(t)
        imgui.PopStyleColor()
        imgui.Dummy(imgui.ImVec2(0, 2))
    end
end
function AP.centerX(w)
    imgui.SetCursorPosX(math.floor(imgui.GetCursorPosX() + math.max(0, (imgui.GetContentRegionAvail().x - w) / 2)))
end
function AP.centerText(text, color)
    AP.centerX(imgui.CalcTextSize(text).x)
    if color then imgui.TextColored(color, text) else imgui.Text(text) end
end
function AP.bigText(text, color, centered)
    if AP.fontBold then imgui.PushFont(AP.fontBold) end
    if centered then AP.centerX(imgui.CalcTextSize(text).x) end
    if color then imgui.TextColored(color, text) else imgui.Text(text) end
    if AP.fontBold then imgui.PopFont() end
end
function AP.tabBtn(id, label, active, w, h, dot)
    local p = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton(id, imgui.ImVec2(w, h))
    local hovered = imgui.IsItemHovered()
    local dl = imgui.GetWindowDrawList()
    if active then
        dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), toU32(0.17, 0.18, 0.24, 1), 8)
        dl:AddRectFilled(imgui.ImVec2(p.x, p.y + 9), imgui.ImVec2(p.x + 3, p.y + h - 9), toU32(1.0, 0.74, 0.28, 1), 2)
    elseif hovered then
        dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), toU32(0.13, 0.14, 0.19, 1), 8)
    end
    local ty = p.y + (h - imgui.GetTextLineHeight()) / 2
    dl:AddText(imgui.ImVec2(math.floor(p.x + 16), math.floor(ty)), active and toU32(1, 1, 1, 1) or toU32(0.70, 0.72, 0.80, 1), label)
    if dot then
        dl:AddCircleFilled(imgui.ImVec2(p.x + w - 16, p.y + h / 2), 4, toU32(0.30, 0.85, 0.62, 1), 12)
    end
    return clicked
end
function AP.tile(id, w, h, l1, l2, selected)
    local p = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton(id, imgui.ImVec2(w, h))
    local hovered = imgui.IsItemHovered()
    local dl = imgui.GetWindowDrawList()
    local bg = selected and toU32(0.10, 0.27, 0.21, 1) or (hovered and toU32(0.14, 0.15, 0.20, 1) or toU32(0.11, 0.12, 0.16, 1))
    local br = selected and toU32(0.30, 0.85, 0.62, 1) or toU32(0.24, 0.25, 0.30, 1)
    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), bg, 10)
    dl:AddRect(p, imgui.ImVec2(p.x + w, p.y + h), br, 10, 15, selected and 2 or 1)
    dl:AddText(imgui.ImVec2(math.floor(p.x + 16), math.floor(p.y + 15)), selected and toU32(1, 1, 1, 1) or toU32(0.85, 0.87, 0.95, 1), l1)
    dl:AddText(imgui.ImVec2(math.floor(p.x + 16), math.floor(p.y + 47)), toU32(0.70, 0.71, 0.77, 1), l2)
    if selected then
        local cx, cy = p.x + w - 20, p.y + 20
        dl:AddCircleFilled(imgui.ImVec2(cx, cy), 9, toU32(0.30, 0.85, 0.62, 1), 16)
        dl:AddLine(imgui.ImVec2(cx - 4, cy), imgui.ImVec2(cx - 1, cy + 3), toU32(0.05, 0.12, 0.09, 1), 2)
        dl:AddLine(imgui.ImVec2(cx - 1, cy + 3), imgui.ImVec2(cx + 4, cy - 3), toU32(0.05, 0.12, 0.09, 1), 2)
    end
    return clicked
end
function AP.statusColored()
    if UPD.status == '' then return end
    local bad = UPD.status:find('^Ошибка') or UPD.status:find('^Не удалось') or UPD.status:find('^Адрес')
    local good = UPD.status:find('^Установлена')
    imgui.PushStyleColor(imgui.Col.Text, bad and RED or good and GREEN or GRAY)
    imgui.TextWrapped(UPD.status)
    imgui.PopStyleColor()
end
function AP.wrapH(text, wrap)
    local ok, sz = pcall(imgui.CalcTextSize, text, nil, false, wrap)
    if ok and sz and sz.y then return sz.y end
    return math.max(1, math.ceil(imgui.CalcTextSize(text).x / wrap)) * imgui.GetTextLineHeight()
end
function AP.tabUpd()
    local info = UPD.info
    local cw = imgui.GetContentRegionAvail().x
    if info then
        UPD.pill(UPD.ver, info.version)
        local date = info.date or info.release_date
        if date then
            imgui.SameLine(0, 12)
            imgui.AlignTextToFramePadding()
            UPD.grayText('от ' .. tostring(date))
        end
        imgui.Spacing()
        AP.sub('Что нового')
        local bottom = UPD.busy and 76 or 160
        local chH = math.max(110, imgui.GetContentRegionAvail().y - bottom)
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.05, 0.055, 0.07, 1))
        imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 10)
        imgui.PushStyleVarFloat(imgui.StyleVar.ChildBorderSize, 0)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(16, 12))
        imgui.BeginChild('##updchanges', imgui.ImVec2(0, chH), true)
        if #info.changes == 0 then imgui.TextDisabled('Автор не описал изменения') end
        for _, c in ipairs(info.changes) do
            imgui.Bullet()
            imgui.SameLine(0, 8)
            imgui.TextWrapped(tostring(c))
            imgui.Dummy(imgui.ImVec2(0, 5))
        end
        imgui.EndChild()
        imgui.PopStyleVar(3)
        imgui.PopStyleColor()
        imgui.Spacing()
        AP.statusColored()
        local full = imgui.GetContentRegionAvail().x
        if UPD.busy then
            imgui.Spacing()
            UPD.progress()
        else
            if UPD.btn('Обновить до ' .. tostring(info.version) .. '##updgo', full, 38, 'primary') then UPD.apply() end
            local bw = (full - 8) / 2
            if UPD.btn('Позже##updlater', bw, 28, 'ghost') then UPD.view = nil end
            imgui.SameLine(0, 8)
            if UPD.btn('Пропустить версию##updskip', bw, 28, 'ghost') then
                UPD.skip = tostring(info.version)
                UPD.info = nil
                UPD.status = ''
                save()
            end
            tooltip('Эту версию скрипт больше не предлагает. О следующей напомнит.')
            imgui.Spacing()
            UPD.footer()
        end
        return
    end
    local bad = UPD.status:find('^Ошибка') or UPD.status:find('^Не удалось') or UPD.status:find('^Адрес')
    AP.sub('Версия')
    local inner = cw - 34
    local lh = imgui.GetTextLineHeight()
    local showStatus = UPD.status ~= '' and not UPD.busy
    local detail = (showStatus and bad and UPD.errDetail) or nil
    local boxH = 22 + lh * 2 + 6 + 8
    if showStatus then boxH = boxH + 6 + AP.wrapH(UPD.status, inner) end
    if detail then boxH = boxH + 6 + AP.wrapH(tostring(detail), inner) end
    boxH = boxH + 6 + (UPD.busy and 6 or 32)
    AP.box('##updver', cw, boxH, function()
        AP.bigText('Версия ' .. UPD.ver)
        if UPD.busy then
            UPD.grayText('Проверяю...')
        elseif UPD.lastCheck then
            UPD.grayText('Последняя проверка: ' .. UPD.lastCheck)
        else
            UPD.grayText('Пока не проверялось')
        end
        if showStatus then
            AP.statusColored()
            if detail then UPD.grayText(tostring(detail)) end
        end
        imgui.Spacing()
        if UPD.busy then
            UPD.progress()
        elseif UPD.btn('Проверить сейчас##updchk', 170, 32, 'primary') then
            UPD.check(true)
        end
    end)
    imgui.Dummy(imgui.ImVec2(0, 8))
    AP.sub('Автопроверка')
    AP.box('##updauto', cw, 84, function()
        if toggleSwitch('##updautosw', UPD.enabled == true) then
            UPD.enabled = not UPD.enabled
            UPD.chk[0] = UPD.enabled
            save()
            if UPD.enabled then UPD.check(false) end
        end
        imgui.SameLine(0, 10)
        imgui.Text('Проверять обновления автоматически')
        UPD.grayText('Проверять наличие обновлений при запуске и раз в несколько часов.')
    end)
end
function AP.tabRadio()
    local cw = imgui.GetContentRegionAvail().x
    AP.sub('Основная рация фракции')
    local tw = math.floor((cw - 10) / 2)
    if AP.tile('##tiler', tw, 80, '/r Гос. структуры', 'ООС чат: /rb', RADIO.org == 'r') then AP.setOrg('r') end
    imgui.SameLine(0, 10)
    if AP.tile('##tilef', tw, 80, '/f Банды и мафии', 'ООС чат: /fb', RADIO.org == 'f') then AP.setOrg('f') end
    imgui.Dummy(imgui.ImVec2(0, 12))
    AP.sub('Как это работает:')
    AP.bullets({
        'В карточках сообщений будет отображаться выбранная тобой рация.',
        'Чекбокс «ООС» переключает отправку на /rb или /fb.',
        'Рацию можно быстро переключить прямо в карточке, заходить сюда каждый раз не нужно.',
        'Для раций можно настраивать отправку нескольких строк подряд.',
    })
end
function AP.tabMute()
    local cw = imgui.GetContentRegionAvail().x
    AP.sub('Статус')
    local ml = AP.muteLeft()
    AP.box('##mutestat', cw, 76, function()
        imgui.AlignTextToFramePadding()
        if ml > 0 then
            imgui.TextColored(RED, 'Активен мут (осталось: ' .. AP.fmtTime(ml) .. ')')
            local bw = imgui.CalcTextSize('Сбросить статус').x + 26
            imgui.SameLine(imgui.GetWindowContentRegionMax().x - bw)
            if UPD.btn('Сбросить статус##mutereset', bw, 26, 'ghost') then MUTE.untilAt = 0 end
            tooltip('Нажми, если администрация сняла мут раньше срока. Если ты всё ещё заглушён, скрипт узнает об этом при следующей отправке.')
        else
            imgui.TextColored(GREEN, 'Заглушки нет')
        end
        UPD.grayText('Статус отслеживается автоматически')
    end)
    imgui.Dummy(imgui.ImVec2(0, 8))
    AP.sub('После мута')
    AP.box('##muteopt', cw, 84, function()
        if toggleSwitch('##muteres', MUTE.resume[0]) then
            MUTE.resume[0] = not MUTE.resume[0]
            save()
        end
        imgui.SameLine(0, 10)
        imgui.Text('Возобновлять рассылку автоматически')
        UPD.grayText(MUTE.resume[0]
            and 'Когда заглушка спадёт, скрипт сам продолжит отправку сообщений.'
            or 'Пиары останутся на паузе, включишь их сам.')
    end)
    imgui.Dummy(imgui.ImVec2(0, 8))
    AP.bullets({
        'Пока ты в муте, отправка сообщений в чаты ставится на паузу.',
        'Объявления /ad на паузу не ставятся.',
        'Оставшееся время заглушки всегда видно в шапке главного окна.',
    })
end
function AP.tabHist()
    if not AP.hist and not UPD.histErr and not UPD.busy and not UPD.state then UPD.fetchHist() end
    if not AP.hist then
        imgui.Dummy(imgui.ImVec2(0, 4))
        if UPD.histErr then
            imgui.PushStyleColor(imgui.Col.Text, RED)
            imgui.TextWrapped('Не получилось загрузить историю изменений. Попробуй позже.')
            imgui.PopStyleColor()
            UPD.grayText(tostring(UPD.histErr))
            imgui.Spacing()
            if UPD.btn('Повторить попытку##histretry', 170, 30, 'primary') then UPD.histErr = nil end
        else
            UPD.grayText('Загружаю историю версий...')
            imgui.Spacing()
            UPD.progress()
        end
        return
    end
    imgui.BeginChild('##histlist', imgui.ImVec2(0, 0), false)
    local shown = 0
    for i, v in ipairs(AP.hist) do
        if type(v) == 'table' and v.version then
            shown = shown + 1
            AP.bigText('Версия ' .. tostring(v.version), i == 1 and AMBER or nil)
            if type(v.date) == 'string' and v.date ~= '' then
                imgui.SameLine(0, 10)
                imgui.TextDisabled(v.date)
            end
            imgui.Spacing()
            if type(v.changes) == 'table' then
                for _, c in ipairs(v.changes) do
                    imgui.Bullet()
                    imgui.SameLine(0, 8)
                    imgui.TextWrapped(tostring(c))
                    imgui.Dummy(imgui.ImVec2(0, 3))
                end
            end
            imgui.Dummy(imgui.ImVec2(0, 12))
        end
    end
    if shown == 0 then imgui.TextDisabled('История пока пуста') end
    imgui.EndChild()
end
AP.TABS = {
    { 'upd', 'Обновления', 'Обновления' },
    { 'hist', 'История', 'История версий' },
    { 'radio', 'Рация', 'Рация' },
    { 'mute', 'Мут', 'Мут' },
}
function AP.drawPanel(w, h)
    AP.tab = AP.tab or 'upd'
    local avail = imgui.GetContentRegionAvail()
    local sideW = 168
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.075, 0.08, 0.10, 1))
    imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 10)
    imgui.BeginChild('##apside', imgui.ImVec2(sideW, avail.y), false,
        bit.bor(imgui.WindowFlags.NoScrollbar, imgui.WindowFlags.NoScrollWithMouse))
    imgui.Dummy(imgui.ImVec2(0, 30))
    AP.bigText('АвтоПиар', AMBER, true)
    imgui.Dummy(imgui.ImVec2(0, 2))
    local verTxt = 'версия ' .. UPD.ver
    AP.centerX(imgui.CalcTextSize(verTxt).x)
    imgui.TextDisabled(verTxt)
    imgui.Dummy(imgui.ImVec2(0, 20))
    for _, t in ipairs(AP.TABS) do
        imgui.SetCursorPosX(14)
        local dot = (t[1] == 'upd' and UPD.info ~= nil) or (t[1] == 'mute' and AP.muteLeft() > 0)
        if AP.tabBtn('##tab' .. t[1], t[2], AP.tab == t[1], sideW - 28, 36, dot and t[1] == 'upd') then
            AP.tab = t[1]
        end
        imgui.Dummy(imgui.ImVec2(0, 2))
    end
    imgui.EndChild()
    imgui.PopStyleVar()
    imgui.PopStyleColor()
    imgui.SameLine(0, 14)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(4, 2))
    imgui.BeginChild('##apmain', imgui.ImVec2(0, avail.y), false)
    imgui.PopStyleVar()
    local title = ''
    for _, t in ipairs(AP.TABS) do if t[1] == AP.tab then title = t[3] end end
    AP.bigText(title, AMBER)
    imgui.SameLine(imgui.GetWindowContentRegionMax().x - (L.close_size + 2))
    if iconClose('##updx', L.close_size) then UPD.view = nil end
    imgui.Separator()
    imgui.Spacing()
    if AP.tab == 'radio' then AP.tabRadio()
    elseif AP.tab == 'mute' then AP.tabMute()
    elseif AP.tab == 'hist' then AP.tabHist()
    else AP.tabUpd() end
    imgui.EndChild()
end
function AP.tick(now)
    if AP.MUTE.untilAt > 0 and now >= AP.MUTE.untilAt then
        MUTE.untilAt = 0
        local n, resumed = 0, 0
        for _, m in ipairs(msgs) do
            if m.mutePaused then
                m.mutePaused = nil
                n = n + 1
                if MUTE.resume[0] then
                    setActive(m, true, true)
                    if m.active then resumed = resumed + 1 end
                end
            end
        end
        if n > 0 then
            if MUTE.resume[0] then
                notify(('Мут закончился, рассылка возобновлена (пиаров: %d).'):format(resumed))
            else
                notify('Мут закончился. Пиары остались на паузе, включи нужные вручную.')
            end
        end
    end
    if now - (AP.trimAt or 0) > 2 then
        AP.trimAt = now
        if not win[0] and now - AP.now > 5 then
            if AP.texDirty then AP.releaseTextures(nil) end
        else
            local ic, em = AP.texStats()
            if ic > 300 or em > 500 then AP.releaseTextures(8) end
        end
    end
end
function AP.queuePos(m)
    local k = 1
    for _, o in ipairs(msgs) do
        if o ~= m and o.active and o.waitSince and o.waitSince < m.waitSince then k = k + 1 end
    end
    return k
end
function AP.msgData(m)
    local extra = {}
    for k = 2, #m.lines do
        extra[k] = { text = ffi.string(m.lines[k].buf), pause = m.lines[k].pause[0] }
    end
    return { extra = extra, pause = m.pause[0], text = msgText(m), cmd = CMDS[m.cmd[0] + 1], delay = m.delay[0], ad = m.ad[0], lim = m.lim[0],
        cnt = m.cnt[0], city = m.city[0], vip = m.vip[0], rs = m.rs[0], rsec = m.rsec[0], ooc = m.ooc[0] }
end
function UPD.drawOverlay(wp, wsz)
    if UPD.view and UPD.shown ~= UPD.view then
        imgui.OpenPopup(UPD.ids[UPD.view])
        UPD.shown = UPD.view
    end
    if not UPD.shown then return end
    local sw, sh = getScreenResolution()
    local isAsk = (UPD.shown == 'ask')
    local w, h
    if isAsk then
        w = math.min(440, sw - 40)
        local iw = w - 40
        h = 16 + imgui.GetTextLineHeight() + 12 + AP.wrapH(UPD.askT1, iw) + 12
            + AP.wrapH(UPD.askT2, iw) + 12 + AP.wrapH(UPD.askT3, iw) + 16 + 38 + 18
    else
        w, h = math.min(720, sw - 40), 440
    end
    h = math.min(h, sh - 40)
    w, h = w - w % 2, h - h % 2
    imgui.SetNextWindowPos(imgui.ImVec2(math.floor(sw / 2), math.floor(sh / 2)), imgui.Cond.Appearing, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(w, h), imgui.Cond.Always)
    local flags = bit.bor(
        imgui.WindowFlags.NoTitleBar,
        imgui.WindowFlags.NoResize,
        imgui.WindowFlags.NoSavedSettings,
        imgui.WindowFlags.NoScrollWithMouse
    )
    flags = bit.bor(flags, imgui.WindowFlags.NoScrollbar)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 12)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(20, 16))
    local open = imgui.BeginPopupModal(UPD.ids[UPD.shown], nil, flags)
    imgui.PopStyleVar(2)
    if not open then
        UPD.shown = nil
        UPD.view = nil
        return
    end
    if UPD.view ~= UPD.shown then
        imgui.CloseCurrentPopup()
        UPD.shown = nil
    elseif isAsk then
        UPD.drawAsk(w)
    else
        AP.drawPanel(w)
    end
    imgui.EndPopup()
end
imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    local fonts = imgui.GetIO().Fonts
    fonts:AddFontFromFileTTF(getFolderPath(0x14) .. '\\arial.ttf', 15, nil, fonts:GetGlyphRangesCyrillic())
    local boldPath = getFolderPath(0x14) .. '\\arialbd.ttf'
    if fileExists(boldPath) then
        AP.fontBold = fonts:AddFontFromFileTTF(boldPath, 15, nil, fonts:GetGlyphRangesCyrillic())
    end
    local st = imgui.GetStyle()
    st.WindowRounding, st.ChildRounding, st.FrameRounding = 10, 8, 6
    st.PopupRounding, st.GrabRounding, st.TabRounding, st.ScrollbarRounding = 6, 6, 6, 8
    st.WindowPadding = imgui.ImVec2(L.pad_x, L.pad_y)
    st.FramePadding  = imgui.ImVec2(8, 5)
    st.ItemSpacing   = imgui.ImVec2(L.spacing_x, L.spacing_y)
    st.WindowBorderSize, st.ChildBorderSize, st.FrameBorderSize = 1, 1, 1
    local function col(name, r, g, b, a)
        pcall(function() st.Colors[imgui.Col[name]] = imgui.ImVec4(r, g, b, a or 1) end)
    end
    col('WindowBg', 0.065, 0.070, 0.085, 0.97)
    col('ChildBg', 0.090, 0.100, 0.125, 0.95)
    col('PopupBg', 0.090, 0.100, 0.125, 1)
    col('Border', 0.24, 0.25, 0.30, 1)
    col('FrameBg', 0.13, 0.14, 0.18, 1)
    col('FrameBgHovered', 0.18, 0.19, 0.24, 1)
    col('FrameBgActive', 0.22, 0.23, 0.29, 1)
    col('TitleBg', 0.065, 0.070, 0.085, 1)
    col('TitleBgActive', 0.13, 0.14, 0.18, 1)
    col('CheckMark', 1.00, 0.74, 0.28, 1)
    col('Button', 0.50, 0.33, 0.11, 1)
    col('ButtonHovered', 0.68, 0.45, 0.15, 1)
    col('ButtonActive', 0.82, 0.55, 0.19, 1)
    col('Header', 0.50, 0.33, 0.11, 1)
    col('HeaderHovered', 0.68, 0.45, 0.15, 1)
    col('HeaderActive', 0.82, 0.55, 0.19, 1)
    col('Separator', 0.24, 0.25, 0.30, 1)
    col('Tab', 0.13, 0.14, 0.18, 1)
    col('TabHovered', 0.68, 0.45, 0.15, 1)
    col('TabActive', 0.45, 0.30, 0.11, 1)
    col('ScrollbarBg', 0.065, 0.070, 0.085, 1)
    col('ScrollbarGrab', 0.30, 0.31, 0.38, 1)
    col('Text', 0.93, 0.93, 0.92, 1)
    col('TextDisabled', 0.67, 0.68, 0.74, 1)
    col('ModalWindowDimBg', 0, 0, 0, 0.55)
end)
local itemSearch = imgui.new.char[64]()
local lastQuery, itemResults = nil, {}
local itemScrollTop = false
local function refreshItems(query)
    lastQuery = query
    itemScrollTop = true
    itemResults = {}
    local q = u8lower(query)
    local isNum = q:match('^%d+$')
    for _, it in ipairs(items) do
        local hit
        if q == '' then hit = true
        elseif isNum then hit = tostring(it.id):find(q, 1, true) ~= nil
        else hit = it.low:find(q, 1, true) ~= nil end
        if hit then
            if isNum and tostring(it.id) == q then
                table.insert(itemResults, 1, it)
            else
                itemResults[#itemResults + 1] = it
            end
        end
    end
end
local function drawCard(i, m)
    if not m then return false end
    local cmd = CMDS[m.cmd[0] + 1]
    local now = os.clock()
    local wantDelete, wantDup = false, false
    local nl = AP.lineCount(m)
    for k = 1, #m.lines do
        local lb = m.lines[k].buf
        local cur = ffi.string(lb)
        if not isUtf8(cur) then
            local fixed = u8:encode(cur)
            if #fixed < BUFSZ then ffi.copy(lb, fixed) end
        end
    end
    if m.err and m.errKey ~= AP.cardKey(m) then m.err = nil end
    if m.errMute and AP.muteLeft() <= 0 then m.err, m.errMute = nil, nil end
    if m.active and m.delay[0] ~= m.lastDelay then
        if not saveDelay[0] then
            local d = math.max(MIN_ALLOWED, m.delay[0])
            m.nextAt = now + d
            m.total = d
        end
        m.lastDelay = m.delay[0]
    end
    imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 8)
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.095, 0.105, 0.135, 0.95))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(16, 8))
    imgui.BeginChild('##card' .. i, imgui.ImVec2(0, L.card_h + (nl - 1) * (imgui.GetFrameHeight() + L.spacing_y)), true,
        bit.bor(imgui.WindowFlags.NoScrollbar, imgui.WindowFlags.NoScrollWithMouse))
    imgui.PopStyleVar()
    local wp, wsz = imgui.GetWindowPos(), imgui.GetWindowSize()
    local accent = m.err and toU32(0.90, 0.32, 0.32, 1)
        or (m.active and toU32(0.20, 0.72, 0.52, 1) or toU32(0.30, 0.32, 0.40, 1))
    imgui.GetWindowDrawList():AddRectFilled(
        imgui.ImVec2(wp.x + 1, wp.y + 8), imgui.ImVec2(wp.x + 5, wp.y + wsz.y - 8), accent, 2)
    local cw = imgui.GetWindowContentRegionMax().x
    local trashX = math.max(0, cw - L.trash_size - L.trash_ox)
    local copyX = trashX - L.trash_size - 4
    local rem = m.active and math.max(0, m.nextAt - now) or 0
    if toggleSwitch('##on' .. i, m.active) then setActive(m, not m.active) end
    tooltip(m.active and 'Поставить на паузу' or 'Запустить рассылку')
    imgui.SameLine(0, 8)
    if m.err then
        imgui.TextColored(imgui.ImVec4(1.0, 0.45, 0.45, 1),
            AP.fitStr(m.err, copyX - imgui.GetCursorPosX() - 10))
        tooltip(m.err)
    else
        local queued = m.active and m.waitSince ~= nil
        if m.active then
            if queued then
                imgui.TextColored(imgui.ImVec4(1.0, 0.78, 0.40, 1), 'В очереди')
            else
                imgui.TextColored(imgui.ImVec4(0.30, 0.85, 0.62, 1), 'Работает')
            end
        elseif m.mutePaused then
            imgui.TextColored(imgui.ImVec4(1.0, 0.45, 0.45, 1), 'Пауза: мут')
        else
            imgui.TextDisabled('Пауза')
        end
        imgui.SameLine(0, 12)
        local timeStr = m.active and (('%d сек'):format(math.ceil(rem))) or '--'
        if queued then
            timeStr = ('Очередь: %s, №%d'):format(AP.fmtTime(VR.readyAt - now), AP.queuePos(m))
        end
        local tw = imgui.CalcTextSize(timeStr).x
        local smiStr
        if cmd == '/ad' and m.smi then smiStr = AP.fitStr('СМИ: ' .. m.smi, copyX * 0.4) end
        local smiW = smiStr and (imgui.CalcTextSize(smiStr).x + 14) or 0
        local barW = math.max(20, copyX - imgui.GetCursorPosX() - tw - 18 - smiW)
        local ps = imgui.GetCursorScreenPos()
        imgui.Dummy(imgui.ImVec2(barW, 16))
        local dl = imgui.GetWindowDrawList()
        dl:AddRectFilled(imgui.ImVec2(ps.x, ps.y + 5), imgui.ImVec2(ps.x + barW, ps.y + 11),
            toU32(0.17, 0.18, 0.23, 1), 3)
        if m.active then
            local tot = math.max(1, m.total or m.delay[0])
            local frac = math.min(1, math.max(0, 1 - rem / tot))
            if frac > 0 then
                dl:AddRectFilled(imgui.ImVec2(ps.x, ps.y + 5), imgui.ImVec2(ps.x + barW * frac, ps.y + 11),
                    toU32(0.20, 0.72, 0.52, 1), 3)
            end
        end
        imgui.SameLine(0, 8)
        imgui.TextDisabled(timeStr)
        if smiStr then
            imgui.SameLine(0, 14)
            imgui.TextColored(imgui.ImVec4(1.0, 0.78, 0.40, 1), smiStr)
            tooltip('Куда ушло последнее объявление: ' .. m.smi)
        end
    end
    imgui.PushItemWidth(48)
    imgui.InputInt('##dl' .. i, m.delay, 0, 0)
    imgui.PopItemWidth()
    tooltip((nl > 1 and 'Пауза после последней строки, до начала нового круга, в секундах.' or 'Пауза между отправками, в секундах.') ..
        ((cmd == '/ad' and adCfg.cd) and ('\nСервер принимает объявления не чаще раза в ' .. adCfg.cd .. ' сек, чаще скрипт слать не будет.') or ''))
    imgui.SameLine(0, 4)
    imgui.AlignTextToFramePadding()
    imgui.TextDisabled('сек')
    imgui.SameLine(0, 8)
    local isAd = (cmd == '/ad')
    imgui.PushItemWidth(isAd and -60 or -1)
    imgui.InputTextWithHint('##txt' .. i, 'текст сообщения...', m.buf, ffi.sizeof(m.buf))
    imgui.PopItemWidth()
    if imgui.IsItemActive() then target = i AP.tline = 1 end
    tooltip('Текст сообщения. Смайлы и предметы вставляются из панели.')
    if isAd then
        local n = AP.charCount((msgText(m):gsub('^%s+', '')))
        local good = n >= AP.adMin and n <= AP.adMax
        imgui.SameLine(0, 8)
        imgui.AlignTextToFramePadding()
        imgui.TextColored(good and imgui.ImVec4(0.67, 0.68, 0.74, 1) or imgui.ImVec4(1.0, 0.42, 0.42, 1),
            ('%d/%d'):format(n, AP.adMax))
        tooltip(('Длина объявления: от %d до %d символов. Вне этих рамок пиар не запустится.'):format(AP.adMin, AP.adMax))
    end
    local delLine
    for k = 2, nl do
        local ln = m.lines[k]
        local th = math.floor(imgui.GetFrameHeight())
        if iconTrash('##dln' .. i .. '_' .. k, th) then delLine = k end
        tooltip('Убрать эту строку.')
        imgui.SameLine(0, 6)
        imgui.PushItemWidth(-132)
        imgui.InputTextWithHint('##txt' .. i .. '_' .. k, 'Строка ' .. k, ln.buf, ffi.sizeof(ln.buf))
        imgui.PopItemWidth()
        if imgui.IsItemActive() then target = i AP.tline = k end
        tooltip('Текст строки ' .. k .. '. Строки уходят по порядку.')
        imgui.SameLine(0, 6)
        imgui.AlignTextToFramePadding()
        imgui.TextDisabled('через')
        imgui.SameLine(0, 4)
        imgui.PushItemWidth(52)
        imgui.InputFloat('##pz' .. i .. '_' .. k, m.lines[k - 1].pause, 0, 0, '%g')
        if not imgui.IsItemActive() and m.lines[k - 1].pause[0] < 0.1 then m.lines[k - 1].pause[0] = 0.1 end
        imgui.PopItemWidth()
        tooltip('Через сколько секунд после предыдущей строки уйдёт эта (минимум 0.1).')
        imgui.SameLine(0, 4)
        imgui.TextDisabled('сек')
    end
    if delLine then table.remove(m.lines, delLine) end
    imgui.PushItemWidth(70)
    imgui.Combo('##cmd' .. i, m.cmd, cmdItems, #CMDS)
    imgui.PopItemWidth()
    tooltip('Куда отправлять сообщение.')
    imgui.SameLine(0, 10)
    if cmd == 'radio' then
        for k, o in ipairs({ 'r', 'f' }) do
            if k > 1 then imgui.SameLine(0, 2) end
            local on = (RADIO.org == o)
            if UPD.btn('/' .. o .. '##org' .. o .. i, 30, 0, on and 'primary' or 'ghost') and not on then
                AP.setOrg(o)
            end
            tooltip('Рация организации: /r для госструктур, /f для банд и мафий. Переключается во всех карточках рации.')
        end
        imgui.SameLine(0, 10)
    end
    if cmd == '/ad' then
        imgui.PushItemWidth(128)
        imgui.Combo('##city' .. i, m.city, cityItems, #CITIES)
        imgui.PopItemWidth()
        tooltip('Радиостанция для объявления.\n«Автоматически»: берётся станция, где объявление редактировали совсем недавно и есть сотрудники онлайн. Если у всех время не указано, берётся самая дешёвая из тех, где кто-то онлайн.')
        imgui.SameLine()
        imgui.Checkbox('VIP-объявление##vip' .. i, m.vip)
        tooltip('Подавать как VIP-объявление.')
        imgui.SameLine()
        imgui.Checkbox('переподать через##rs' .. i, m.rs)
        tooltip('Если объявление долго не рассматривают, скрипт подаст его заново. Число справа: через сколько секунд проверить.')
        if m.rs[0] then
            imgui.SameLine()
            imgui.PushItemWidth(44)
            imgui.InputInt('##rsec' .. i, m.rsec, 0, 0)
            imgui.PopItemWidth()
            local nextRs = m.checkAt and math.max(0, math.ceil(m.checkAt - now)) or 0
            tooltip(('Через сколько секунд проверить и переподать.\nСледующая проверка через: %d сек'):format(nextRs))
            imgui.SameLine(0, 4)
            imgui.AlignTextToFramePadding()
            imgui.TextDisabled('сек')
        end
    else
        if cmd == '/vr' then
            imgui.Checkbox('реклама##ad' .. i, m.ad)
            tooltip('Что отвечать на вопрос сервера, реклама ли это. Включено: подтверждать. Выключено: отказываться.')
            imgui.SameLine()
        elseif cmd == 'radio' then
            imgui.Checkbox('ООС##ooc' .. i, m.ooc)
            tooltip('Отправлять в нонРП-чат рации: /rb для госструктур, /fb для банд и мафий.')
            imgui.SameLine()
        end
        imgui.Checkbox((m.lim[0] and 'лимит:' or 'лимит') .. '##lim' .. i, m.lim)
        tooltip(nl > 1 and 'Остановить рассылку после указанного числа полных кругов (все строки по порядку — один круг).'
            or 'Остановить рассылку после указанного числа отправок.')
        if m.lim[0] then
            imgui.SameLine()
            imgui.PushItemWidth(44)
            imgui.InputInt('##cnt' .. i, m.cnt, 0, 0)
            imgui.PopItemWidth()
            tooltip('Сколько раз отправить, потом рассылка сама остановится.')
            imgui.SameLine(0, 4)
            imgui.AlignTextToFramePadding()
            imgui.TextDisabled('раз')
        end
    end
    if MULTI[cmd] and nl < MAX_LINES then
        imgui.SameLine(0, 10)
        if UPD.btn('+ строка##addl' .. i, 78, 0, 'ghost') then AP.addLine(m) end
        tooltip('Добавить ещё одну строку: строки уходят по порядку, у каждой своя пауза.')
    end
    if m.sent and m.sent > 0 then
        local at = m.sentAt or '--:--'
        local costStr = (cmd == '/ad' and m.cost) and (' | $' .. AP.money(m.cost)) or ''
        local rx = imgui.GetItemRectMax().x - imgui.GetWindowPos().x
        local info, ix
        for _, f in ipairs({ 'Отправлено: %d | Последний раз: %s', 'Отправлено: %d | %s', '%d | %s' }) do
            for _, extra in ipairs({ costStr, '' }) do
                local t = f:format(m.sent, at) .. extra
                local x = cw - imgui.CalcTextSize(t).x
                if x >= rx + 14 then info, ix = t, x break end
            end
            if info then break end
        end
        if info then
            imgui.SameLine(ix)
            imgui.AlignTextToFramePadding()
            imgui.TextDisabled(info)
            tooltip(('Отправлено с запуска скрипта: %d раз.\nПоследний раз: %s.'):format(m.sent, at)
                .. ((cmd == '/ad' and m.cost) and ('\nСписано за последнее объявление: $' .. AP.money(m.cost)) or ''))
        end
    end
    imgui.SetCursorPos(imgui.ImVec2(copyX, L.trash_oy))
    if iconCopy('##dup' .. i, L.trash_size) then
        wantDup = true
    end
    tooltip('Создать копию этой карточки (она будет на паузе).')
    imgui.SetCursorPos(imgui.ImVec2(trashX, L.trash_oy))
    if iconTrash('##del' .. i, L.trash_size) then
        wantDelete = true
    end
    tooltip('Удалить этот пиар.')
    imgui.EndChild()
    imgui.PopStyleColor()
    imgui.PopStyleVar()
    return wantDelete, wantDup
end
local fitCache = {}
local function fitText(it, maxW)
    local c = fitCache[it.id]
    if c and c.w == maxW then return c.text, c.cut end
    local text, cut = it.name, false
    if imgui.CalcTextSize(text).x > maxW then
        cut = true
        local chars = {}
        for ch in it.name:gmatch('[\1-\127\194-\244][\128-\191]*') do chars[#chars + 1] = ch end
        local k = #chars
        while k > 1 do
            k = k - 1
            text = table.concat(chars, '', 1, k) .. '...'
            if imgui.CalcTextSize(text).x <= maxW then break end
        end
    end
    fitCache[it.id] = { w = maxW, text = text, cut = cut }
    return text, cut
end
AP.descCol = imgui.ImVec4(0.93, 0.93, 0.97, 1)
function AP.cleanDesc(str)
    str = str:gsub('\r', ''):gsub('\t', '    ')
    str = str:gsub('—', '-'):gsub('–', '-'):gsub('№', 'No'):gsub('•', '*')
    str = str:gsub('“', '"'):gsub('”', '"'):gsub('«', '"'):gsub('»', '"')
    return str
end
function AP.descText(it)
    if not it.dp or not AP.binOff or not itemsZip or not itemsZip.f then return '' end
    itemsZip.f:seek('set', AP.binOff + it.dp - 1)
    return itemsZip.f:read(it.dl) or ''
end
function AP.extraText(it)
    if not it.xp or (it.xl or 0) <= 0 or not AP.binOff or not itemsZip or not itemsZip.f then return '' end
    itemsZip.f:seek('set', AP.binOff + it.xp - 1)
    local t = itemsZip.f:read(it.xl) or ''
    t = AP.cleanDesc(t):gsub('{%x%x%x%x%x%x}', ''):gsub('{}', '')
    return t
end
function AP.buildDescLines(it, maxW)
    local c = AP.descCache[it.id]
    if c and c.w == maxW then return c.lines end
    ensureEmojiTables()
    local text = AP.cleanDesc(AP.descText(it))
    local EMO = 18
    local lines, cur, curW = {}, {}, 0
    local color = AP.descCol
    local spaceW = imgui.CalcTextSize(' ').x
    local function newline()
        lines[#lines + 1] = cur
        cur, curW = {}, 0
    end
    local function put(str, w)
        local last = cur[#cur]
        if last and last.col == color then
            last.text = last.text .. str
        else
            cur[#cur + 1] = { text = str, col = color }
        end
        curW = curW + w
    end
    local function emojiAt(pos)
        local hx = text:match('^:u(%x+):', pos)
        if hx then
            local tok = text:match('^(:u%x+:)', pos)
            local e = emojiByToken[tok] or emojiByToken[tok:lower()]
            if not e then
                local cp = tonumber(hx, 16)
                if not cp or cp > 0x10FFFF then return nil end
                e = AP.extraEmoji[cp]
                if not e then
                    e = { name = 'u' .. hx, cp = cp, cells = 1 }
                    AP.extraEmoji[cp] = e
                end
            end
            return e, #tok
        end
        for len = math.min(emojiMaxTok, #text - pos + 1), 3, -1 do
            local e = emojiByToken[text:sub(pos, pos + len - 1)]
            if e then return e, len end
        end
    end
    local i, n = 1, #text
    while i <= n do
        local ch = text:sub(i, i)
        local hex, e = text:match('^{(%x%x%x%x%x%x)}()', i)
        local emo, elen
        if ch == ':' then emo, elen = emojiAt(i) end
        if emo then
            local w = EMO * emo.cells
            if curW > 0 and curW + w > maxW then newline() end
            cur[#cur + 1] = { emoji = emo, size = EMO }
            curW = curW + w
            i = i + elen
        elseif hex then
            color = imgui.ImVec4(
                tonumber(hex:sub(1, 2), 16) / 255,
                tonumber(hex:sub(3, 4), 16) / 255,
                tonumber(hex:sub(5, 6), 16) / 255, 1)
            i = e
        elseif text:sub(i, i + 1) == '{}' then
            color = AP.descCol
            i = i + 2
        elseif ch == '\n' then
            newline()
            i = i + 1
        elseif ch == ' ' then
            local sp = text:match('^ +', i)
            if curW > 0 or #sp > 1 then put(sp, spaceW * #sp) end
            i = i + #sp
        else
            local word = text:match('^[^ \n{:]+', i) or ch
            local ww = imgui.CalcTextSize(word).x
            if curW > 0 and curW + ww > maxW then newline() end
            put(word, ww)
            i = i + #word
        end
    end
    if #cur > 0 then newline() end
    local out, prevEmpty = {}, true
    for _, ln in ipairs(lines) do
        local empty = (#ln == 0)
        if not (empty and prevEmpty) then out[#out + 1] = ln end
        prevEmpty = empty
    end
    while #out > 0 and #out[#out] == 0 do out[#out] = nil end
    AP.descN = (AP.descN or 0) + 1
    if AP.descN > 40 then AP.descCache = {} AP.descN = 0 end
    AP.descCache[it.id] = { w = maxW, lines = out }
    return out
end
function AP.drawItemTooltip(it, e)
    local _, sh = getScreenResolution()
    local maxW, ICON = 380, 64
    local lines = AP.buildDescLines(it, maxW)
    local lineH = imgui.GetTextLineHeight() + 2
    local maxLines = math.max(8, math.floor((sh - 100) / lineH))
    texBudget = TEX_PER_FRAME
    iconBudget = math.max(iconBudget, 1)
    local tex = itemIcon(it.id, true)
    if not tex then
        iconBudget = math.max(iconBudget, 1)
        tex = itemIcon(it.id)
    end
    imgui.BeginTooltip()
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, 2))
    local p = imgui.GetCursorScreenPos()
    imgui.Dummy(imgui.ImVec2(ICON, ICON))
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(p, imgui.ImVec2(p.x + ICON, p.y + ICON),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.30, 0.31, 0.38, 1)), 4)
    if tex then
        dl:AddImage(tex, p, imgui.ImVec2(p.x + ICON, p.y + ICON), UV0, UV1, 0xFFFFFFFF)
    end
    imgui.SameLine(0, 12)
    imgui.BeginGroup()
    if #lines == 0 then
        imgui.TextDisabled('Описания нет')
    end
    local shown = math.min(#lines, maxLines)
    for li = 1, shown do
        local ln = lines[li]
        if #ln == 0 then
            imgui.TextUnformatted(' ')
        else
            for ci, ch in ipairs(ln) do
                if ci > 1 then imgui.SameLine(0, 0) end
                if ch.emoji then
                    if ch.emoji.fail then
                        imgui.TextDisabled(':' .. ch.emoji.name .. ':')
                    else
                        drawInlineEmoji(ch.emoji, ch.size)
                    end
                else
                    imgui.PushStyleColor(imgui.Col.Text, ch.col)
                    imgui.TextUnformatted(ch.text)
                    imgui.PopStyleColor()
                end
            end
        end
    end
    if #lines > shown then
        imgui.TextDisabled(('... ещё строк: %d'):format(#lines - shown))
    end
    local extra = AP.extraText(it)
    if extra ~= '' then
        imgui.Spacing()
        imgui.PushTextWrapPos(imgui.GetCursorPosX() + maxW)
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.82, 0.16, 1))
        imgui.TextUnformatted(extra)
        imgui.PopStyleColor()
        imgui.PopTextWrapPos()
    end
    if e then
        imgui.Spacing()
        if (e.enchant or 0) > 0 then
            imgui.TextColored(imgui.ImVec4(1.0, 0.78, 0.40, 1), ('Заточка: +%d'):format(e.enchant))
        end
        local a, b = e.unic_id_2, e.unic_id_3
        local function nm(id)
            local r = itemById[id]
            return r and r.name or ('#' .. id)
        end
        local tc = imgui.ImVec4(0.75, 0.80, 0.95, 1)
        if a and b and a == b then
            imgui.TextColored(tc, 'Перенос всех характеристик с: ' .. nm(a))
        else
            if a then imgui.TextColored(tc, 'Перенос характеристик с: ' .. nm(a)) end
            if b then imgui.TextColored(tc, 'Перенос жёлтых характеристик и активных свойств с: ' .. nm(b)) end
        end
    end
    imgui.EndGroup()
    imgui.PopStyleVar()
    imgui.EndTooltip()
end
function AP.onDisplay(packet)
    local acef = AP.acef
    if packet.id == 17 and type(packet.text) == 'string' and not packet.text:find('playerInventory', 1, true) then return end
    local okd, dec = pcall(acef.decode, packet)
    if not okd or not dec then return end
    if packet.event ~= 'event.inventory.playerInventory' then return end
    local p = type(packet.json) == 'table' and packet.json[1]
    if type(p) ~= 'table' or type(p.data) ~= 'table' then return end
    local ty, items = p.data.type, p.data.items
    local store, meta = AP.inv[ty], AP.invMeta[ty]
    if not store or type(items) ~= 'table' then return end
    local now = os.clock()
    if p.action == 0 then
        if now - meta.last > 1.5 then
            for k in pairs(store) do store[k] = nil end
        end
        meta.last, meta.full = now, true
        for _, it in ipairs(items) do
            if it.slot then store[it.slot] = it.item and it or nil end
        end
    elseif p.action == 2 then
        for _, it in ipairs(items) do
            local slot = it.slot
            if slot then
                if it.amount ~= nil then
                    store[slot] = it
                elseif it.item == nil then
                    store[slot] = nil
                else
                    local cur = store[slot]
                    if not cur or cur.item ~= it.item then store[slot] = it end
                end
            end
        end
    else
        return
    end
    AP.invVer = AP.invVer + 1
    AP.invSaved = nil
end
AP.invFile = CONFIG_DIR .. '\\autopiar_inv.lua'
function AP.invWho()
    local ok, nick = pcall(function()
        local _, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
        return sampGetPlayerNickname(id)
    end)
    local ok2, ip, port = pcall(sampGetCurrentServerAddress)
    if not ok or not nick or not ok2 then return nil end
    return nick .. '@' .. tostring(ip) .. ':' .. tostring(port)
end
function AP.invSave()
    local who = AP.invWho()
    if not who then return end
    local out = { ('return { who = %q, time = %d, inv = {'):format(who, os.time()), '[1] = {' }
    for slot, e in pairs(AP.inv[1]) do
        out[#out + 1] = ('[%d]={item=%d,amount=%s,text=%q,enchant=%s,strength=%s,uid=%s,uid2=%s,uid3=%s},'):format(
            slot, e.item, tostring(e.amount or 'nil'), tostring(e.text or ''),
            tostring(e.enchant or 'nil'), tostring(e.strength or 'nil'),
            tostring(e.unic_id or 'nil'), tostring(e.unic_id_2 or 'nil'), tostring(e.unic_id_3 or 'nil'))
    end
    out[#out + 1] = '},'
    out[#out + 1] = '}, tok = {'
    for k, v in pairs(AP.tokItem) do out[#out + 1] = ('[%q]=%d,'):format(k, v) end
    out[#out + 1] = '} }'
    local f = io.open(AP.invFile, 'w')
    if f then f:write(table.concat(out, '\n')) f:close() end
    AP.invSavedVer = AP.invVer
end
function AP.invLoad()
    local who = AP.invWho()
    if not who then return end
    local fn = loadfile(AP.invFile)
    if not fn then return end
    local ok, d = pcall(fn)
    if not ok or type(d) ~= 'table' or d.who ~= who or type(d.inv) ~= 'table' then return end
    local any = false
    if type(d.tok) == 'table' then
        for k, v in pairs(d.tok) do
            if AP.tokItem[k] == nil and type(v) == 'number' then AP.tokItem[k] = v end
        end
    end
    if not AP.invMeta[1].full and type(d.inv[1]) == 'table' then
        for slot, e in pairs(d.inv[1]) do
            if type(e) == 'table' and e.item then
                AP.inv[1][slot] = { item = e.item, amount = e.amount, text = e.text, enchant = e.enchant,
                                    strength = e.strength, unic_id = e.uid, unic_id_2 = e.uid2, unic_id_3 = e.uid3 }
                any = true
            end
        end
        AP.invMeta[1].full = true
    end
    if any then
        AP.invVer = AP.invVer + 1
        AP.invSaved = d.time
        AP.invSavedVer = AP.invVer
    end
end
function AP.resolveSlots(text)
    local bad
    local out = text:gsub(':slot(%d+)_(%d+):', function(s, t)
        if bad then return end
        local slot, ty = tonumber(s), tonumber(t)
        local store, meta = AP.inv[ty], AP.invMeta[ty]
        if not store then
            bad = 'надетые на персонажа вещи не поддерживаются, выбери предмет из инвентаря'
            return
        end
        if not meta.full then
            bad = 'нет данных инвентаря (нажми «Обновить» в панели инвентаря)'
            return
        end
        local key = 'slot' .. s .. '_' .. t
        local want = AP.tokItem[key]
        local e = store[slot]
        if e and (want == nil or e.item == want) then return end
        if want then
            local best
            for sl, x in pairs(store) do
                if x.item == want and (not best or sl < best) then best = sl end
            end
            if best then
                local nk = 'slot' .. best .. '_' .. t
                AP.tokItem[nk] = want
                return ':' .. nk .. ':'
            end
            local it = itemById[want]
            bad = 'предмет «' .. (it and it.name or ('#' .. want)) .. '» не найден в твоём инвентаре'
        else
            bad = 'выбранная ячейка инвентаря (' .. slot .. ') пуста'
        end
    end)
    if bad then return nil, bad end
    return out
end
do
    local ok, lib = pcall(require, 'arizona-events')
    if ok and type(lib) == 'table' then
        AP.acef = lib
        local prev = lib.onArizonaDisplay
        if prev ~= nil and prev == lib.__ap_wrapper then prev = lib.__ap_prev end
        AP.prevHandler = prev
        AP.wrapper = function(packet)
            local r
            if prev then
                local okp, rp = pcall(prev, packet)
                if okp then r = rp end
            end
            pcall(AP.onDisplay, packet)
            return r
        end
        lib.__ap_wrapper, lib.__ap_prev = AP.wrapper, prev
        lib.onArizonaDisplay = AP.wrapper
    else
        AP.acefErr = tostring(lib)
    end
end
function AP.invRows()
    local grp = AP.invGroup[0]
    local q = u8lower(ffi.string(AP.invSearch))
    local c = AP.invCache
    if c and c.ver == AP.invVer and c.grp == grp and c.q == q then return c.rows end
    local function nameOf(id)
        local it = itemById[id]
        return it and it.name or ('Предмет #' .. id)
    end
    local rows = {}
    if grp then
        local by = {}
        for slot, e in pairs(AP.inv[1]) do
            local r = by[e.item]
            if not r then
                r = { item = e.item, amount = 0, slots = 0, slot = slot }
                by[e.item] = r
                rows[#rows + 1] = r
            end
            if slot < r.slot then r.slot = slot end
            r.slots = r.slots + 1
            if e.amount then r.amount = r.amount + e.amount else r.unknown = true end
        end
        for _, r in ipairs(rows) do r.name = nameOf(r.item) r.low = u8lower(r.name) end
    else
        for slot, e in pairs(AP.inv[1]) do
            local nm = nameOf(e.item)
            rows[#rows + 1] = { item = e.item, amount = e.amount, slot = slot, text = e.text,
                                name = nm, low = u8lower(nm) }
        end
    end
    table.sort(rows, function(a, b) return a.slot < b.slot end)
    if q ~= '' then
        local isNum = q:match('^%d+$')
        local out = {}
        for _, r in ipairs(rows) do
            local hit
            if isNum then hit = tostring(r.item):find(q, 1, true) ~= nil
            else hit = r.low:find(q, 1, true) ~= nil end
            if hit then out[#out + 1] = r end
        end
        rows = out
    end
    AP.invCache = { ver = AP.invVer, grp = grp, q = q, rows = rows }
    return rows
end
function AP.plural(n, one, few, many)
    local a, b = n % 10, n % 100
    if a == 1 and b ~= 11 then return one end
    if a >= 2 and a <= 4 and (b < 12 or b > 14) then return few end
    return many
end
function AP.drawInvTab()
    if AP.acefErr then
        imgui.TextColored(imgui.ImVec4(1, 0.4, 0.4, 1), 'Нужна библиотека arizona-events: папку arizona-events положи в moonloader\\lib')
        imgui.TextDisabled('github.com/wojciech941/arizona-events (после этого перезагрузи скрипт)')
        return
    end
    if AP.sync then
        imgui.AlignTextToFramePadding()
        imgui.TextDisabled('Считываю инвентарь...')
    elseif imgui.Button('Обновить', imgui.ImVec2(imgui.CalcTextSize('Обновить').x + 26, 24)) then
        AP.syncStart()
    end
    tooltip('Считывает инвентарь в фоне через /stats. Окна на экране не появятся.')
    imgui.SameLine()
    imgui.Checkbox('Группировать одинаковые', AP.invGroup)
    local meta = AP.invMeta[1]
    imgui.PushItemWidth(-1)
    imgui.InputTextWithHint('##invsearch', 'Поиск по названию или ID...', AP.invSearch, ffi.sizeof(AP.invSearch))
    imgui.PopItemWidth()
    local rows = AP.invRows()
    local cnt = 0
    for _ in pairs(AP.inv[1]) do cnt = cnt + 1 end
    imgui.PushTextWrapPos(0)
    if not meta.full then
        imgui.TextDisabled('Нет данных. Нажми «Обновить» или перезайди на сервер.')
    else
        imgui.TextDisabled(('Показано: %d %s  |  Занято слотов: %d  |  Ctrl + наведение: описание')
            :format(#rows, AP.plural(#rows, 'предмет', 'предмета', 'предметов'), cnt))
        if AP.invSaved then
            imgui.TextDisabled('Данные сохранены в ' .. os.date('%H:%M', AP.invSaved) .. ' (обновятся сами при следующем заходе на сервер).')
        end
    end
    imgui.PopTextWrapPos()
    imgui.BeginChild('##invlist', imgui.ImVec2(0, math.max(60, imgui.GetContentRegionAvail().y - 2)), true)
    iconBudget = ICON_PER_FRAME
    local ROWH, ICON = 24, 20
    local spY = imgui.GetStyle().ItemSpacing.y
    local step = ROWH + spY
    local scrollY = imgui.GetScrollY()
    local total = #rows
    local first = math.max(1, math.floor(scrollY / step))
    local last = math.min(total, math.ceil((scrollY + imgui.GetWindowHeight()) / step) + 1)
    local availW = imgui.GetContentRegionAvail().x
    local dl = imgui.GetWindowDrawList()
    local colText = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.93, 0.93, 0.97, 1))
    local colDim = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.69, 0.71, 0.77, 1))
    local colPlate = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.17, 0.18, 0.22, 1))
    local fontH = imgui.GetTextLineHeight()
    if total == 0 and meta.full then imgui.TextDisabled('Ничего не найдено') end
    if first > 1 then imgui.Dummy(imgui.ImVec2(0, (first - 1) * step - spY)) end
    for i = first, last do
        local r = rows[i]
        local p = imgui.GetCursorScreenPos()
        if imgui.Selectable('##inv' .. i, false, 0, imgui.ImVec2(0, ROWH)) then
            AP.tokItem[('slot%d_1'):format(r.slot)] = r.item
            AP.invVer = AP.invVer + 1
            appendToken((':slot%d_1:'):format(r.slot))
        end
        local hovered = imgui.IsItemHovered()
        local iy = p.y + (ROWH - ICON) / 2
        dl:AddRectFilled(imgui.ImVec2(p.x + 3, iy - 2), imgui.ImVec2(p.x + 5 + ICON, iy + ICON + 2), colPlate, 4)
        local tex = itemIcon(r.item)
        if tex then
            dl:AddImage(tex, imgui.ImVec2(p.x + 4, iy), imgui.ImVec2(p.x + 4 + ICON, iy + ICON), UV0, UV1, 0xFFFFFFFF)
        end
        local ty = p.y + (ROWH - fontH) / 2
        local right
        if r.amount == nil or r.unknown then right = 'x?' else right = 'x' .. r.amount end
        local rw = imgui.CalcTextSize(right).x
        local nameOff = 4 + ICON + 10
        local label = r.name
        if r.text and r.text ~= '' and r.text ~= 'KD' then label = label .. '  ' .. r.text end
        local shown = label
        local maxW = availW - nameOff - rw - 14
        if imgui.CalcTextSize(shown).x > maxW then
            local chars = {}
            for ch in label:gmatch('[\1-\127\194-\244][\128-\191]*') do chars[#chars + 1] = ch end
            local k = #chars
            while k > 1 do
                k = k - 1
                shown = table.concat(chars, '', 1, k) .. '...'
                if imgui.CalcTextSize(shown).x <= maxW then break end
            end
        end
        dl:AddText(imgui.ImVec2(p.x + nameOff, ty), colText, shown)
        dl:AddText(imgui.ImVec2(p.x + availW - rw - 6, ty), colDim, right)
        if hovered then
            local io = imgui.GetIO()
            local it = itemById[r.item]
            if it and (io.KeyCtrl or isKeyDown(0x11)) then
                AP.drawItemTooltip(it, (not r.slots or r.slots == 1) and AP.inv[1][r.slot] or nil)
            elseif shown ~= label then
                imgui.SetTooltip(label)
            end
        end
    end
    if last < total then imgui.Dummy(imgui.ImVec2(0, math.max(0, (total - last) * step - spY))) end
    imgui.EndChild()
end
local function drawBottomPanel()
    if imgui.BeginTabBar('##sidetabs') then
        if imgui.BeginTabItem('Смайлы') then
            drawEmojiGrid(math.max(60, imgui.GetContentRegionAvail().y - 2), L.emoji_size)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Предметы') then
            if itemsErr then
                imgui.TextColored(imgui.ImVec4(1, 0.4, 0.4, 1), 'Список предметов не загрузился: ' .. itemsErr)
            end
            imgui.PushItemWidth(-1)
            imgui.InputTextWithHint('##isearch', 'Поиск по названию или ID...', itemSearch, ffi.sizeof(itemSearch))
            imgui.PopItemWidth()
            local q = ffi.string(itemSearch)
            if q ~= lastQuery then refreshItems(q) end
            imgui.TextDisabled(('Найдено: %d из %d'):format(#itemResults, #items))
            imgui.SameLine()
            imgui.TextDisabled('  |  Ctrl + наведение: описание')
            imgui.BeginChild('##itemlist', imgui.ImVec2(0, math.max(60, imgui.GetContentRegionAvail().y - 2)), true)
            iconBudget = ICON_PER_FRAME
            local total = #itemResults
            local ROWH, ICON = 24, 20
            local spY = imgui.GetStyle().ItemSpacing.y
            local step = ROWH + spY
            local scrollY = imgui.GetScrollY()
            if itemScrollTop then
                imgui.SetScrollY(0)
                scrollY = 0
                itemScrollTop = false
            end
            local first = math.max(1, math.floor(scrollY / step))
            local last = math.min(total, math.ceil((scrollY + imgui.GetWindowHeight()) / step) + 1)
            local availW = imgui.GetContentRegionAvail().x
            local dl = imgui.GetWindowDrawList()
            local colText = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.93, 0.93, 0.97, 1))
            local colDim = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.69, 0.71, 0.77, 1))
            local colPlate = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.17, 0.18, 0.22, 1))
            local fontH = imgui.GetTextLineHeight()
            if total == 0 then imgui.TextDisabled('Ничего не найдено') end
            if first > 1 then imgui.Dummy(imgui.ImVec2(0, (first - 1) * step - spY)) end
            for i = first, last do
                local it = itemResults[i]
                local p = imgui.GetCursorScreenPos()
                if imgui.Selectable('##it' .. it.id, false, 0, imgui.ImVec2(0, ROWH)) then
                    appendToken((':item%d:'):format(it.id))
                end
                local hovered = imgui.IsItemHovered()
                local iy = p.y + (ROWH - ICON) / 2
                dl:AddRectFilled(imgui.ImVec2(p.x + 3, iy - 2), imgui.ImVec2(p.x + 5 + ICON, iy + ICON + 2), colPlate, 4)
                local tex = itemIcon(it.id)
                if tex then
                    dl:AddImage(tex, imgui.ImVec2(p.x + 4, iy), imgui.ImVec2(p.x + 4 + ICON, iy + ICON), UV0, UV1, 0xFFFFFFFF)
                end
                local ty = p.y + (ROWH - fontH) / 2
                local ids = tostring(it.id)
                local tw = imgui.CalcTextSize(ids).x
                local nameOff = 4 + ICON + 10
                local shown, cut = fitText(it, availW - nameOff - tw - 14)
                dl:AddText(imgui.ImVec2(p.x + nameOff, ty), colText, shown)
                dl:AddText(imgui.ImVec2(p.x + availW - tw - 6, ty), colDim, ids)
                if hovered then
                    local io = imgui.GetIO()
                    if io.KeyCtrl or isKeyDown(0x11) then
                        AP.drawItemTooltip(it)
                    elseif cut then
                        imgui.SetTooltip(it.name)
                    end
                end
            end
            if last < total then imgui.Dummy(imgui.ImVec2(0, math.max(0, (total - last) * step - spY))) end
            imgui.EndChild()
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Инвентарь') then
            AP.drawInvTab()
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    end
end
function AP.drawSidePanel(mx, my, mw, mh)
    local sw = getScreenResolution()
    local gap = 6
    local fitsRight = mx + mw + gap + L.side_w <= sw
    local fitsLeft = mx - gap - L.side_w >= 0
    local right = (L.side == 0)
    if right and not fitsRight and fitsLeft then right = false
    elseif not right and not fitsLeft and fitsRight then right = true end
    local x = right and (mx + mw + gap) or (mx - gap - L.side_w)
    imgui.SetNextWindowPos(imgui.ImVec2(x, my), imgui.Cond.Always)
    imgui.SetNextWindowSize(imgui.ImVec2(L.side_w, mh), imgui.Cond.Always)
    local flags = bit.bor(
        imgui.WindowFlags.NoResize,
        imgui.WindowFlags.NoCollapse,
        imgui.WindowFlags.NoScrollbar,
        imgui.WindowFlags.NoScrollWithMouse,
        imgui.WindowFlags.NoTitleBar,
        imgui.WindowFlags.NoMove
    )
    if not imgui.Begin('##AutoPiarSide', nil, flags) then
        imgui.End()
        return
    end
    drawBottomPanel()
    imgui.End()
end
function AP.resetIO()
    local io = imgui.GetIO()
    for i = 0, 511 do io.KeysDown[i] = false end
    for i = 0, 4 do io.MouseDown[i] = false end
    io.KeyCtrl, io.KeyShift, io.KeyAlt, io.KeySuper = false, false, false, false
end
function AP.unstick()
    local io = imgui.GetIO()
    for i = 1, 255 do
        if io.KeysDown[i] and not isKeyDown(i) then io.KeysDown[i] = false end
    end
end
function AP.inputGuard()
    if imgui.IsMouseClicked(0) and sampIsChatInputActive() then
        sampSetChatInputEnabled(false)
    end
end
imgui.OnFrame(function() return win[0] end, function()
    AP.now = os.clock()
    pcall(AP.inputGuard)
    if AP.needReset then AP.needReset = false pcall(AP.resetIO) end
    pcall(AP.unstick)
    local st = imgui.GetStyle()
    st.WindowPadding = imgui.ImVec2(L.pad_x, L.pad_y)
    st.ItemSpacing   = imgui.ImVec2(L.spacing_x, L.spacing_y)
    local sw, sh = getScreenResolution()
    local bottom = (L.side == 2)
    local winH = bottom and L.win_h or L.win_h_side
    local px = (sw - L.win_w) / 2
    if not bottom then
        px = (sw - (L.win_w + 6 + L.side_w)) / 2
        if L.side == 1 then px = px + L.side_w + 6 end
    end
    imgui.SetNextWindowPos(imgui.ImVec2(math.floor(px), math.floor((sh - winH) / 2)), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowSize(imgui.ImVec2(L.win_w, winH), imgui.Cond.Always)
    local flags = bit.bor(
        imgui.WindowFlags.NoResize,
        imgui.WindowFlags.NoCollapse,
        imgui.WindowFlags.NoScrollbar,
        imgui.WindowFlags.NoScrollWithMouse,
        imgui.WindowFlags.NoTitleBar
    )
    if not imgui.Begin('##AutoPiarMain', win, flags) then
        imgui.End()
        return
    end
    imgui.AlignTextToFramePadding()
    imgui.TextColored(imgui.ImVec4(1.0, 0.74, 0.28, 1), 'АвтоПиар')
    AP.drawChips()
    local closeX = imgui.GetWindowContentRegionMax().x - (L.close_size + 2)
    local sideLabel = (L.side == 0) and 'Панель: справа' or (L.side == 1) and 'Панель: слева' or 'Панель: снизу'
    local sideW = imgui.CalcTextSize(sideLabel).x + 26
    local updW = UPD.info and (imgui.CalcTextSize('Обновление!').x + 26) or 0
    local setW = imgui.CalcTextSize('Настройки').x + 26
    local setX = closeX - sideW - 8 - (UPD.info and (updW + 8) or 0) - setW - 8
    imgui.SameLine(setX)
    if imgui.Button('Настройки##setbtn', imgui.ImVec2(setW, 24)) then UPD.view = 'settings' end
    tooltip('Настройки рации, мута, автопроверки обновлений и истории версий.')
    if UPD.info then
        imgui.SameLine(closeX - sideW - 8 - updW - 8)
        local a = 0.55 + 0.45 * math.abs(math.sin(os.clock() * 3))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.12, 0.55, 0.38, a))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.16, 0.68, 0.46, 1))
        if imgui.Button('Обновление!##updbtn', imgui.ImVec2(updW, 24)) then UPD.view = 'info' AP.tab = 'upd' end
        imgui.PopStyleColor(2)
        tooltip('Вышла новая версия. Нажми, чтобы посмотреть, что изменилось.')
    end
    imgui.SameLine(closeX - sideW - 8)
    if imgui.Button(sideLabel, imgui.ImVec2(sideW, 24)) then
        L.side = (L.side + 1) % 3
        save()
    end
    tooltip('Нажми, чтобы переставить панель смайлов и предметов: снизу, справа или слева')
    imgui.SameLine(closeX)
    if iconClose('##close', L.close_size) then
        win[0] = false
        save()
    end
    tooltip('Закрыть окно (настройки сохраняются автоматически).')
    imgui.Separator()
    local rightEdge = imgui.GetWindowContentRegionMax().x
    local act = activeCount()
    local sp = imgui.GetCursorScreenPos()
    local rowH = imgui.GetFrameHeight()
    imgui.Dummy(imgui.ImVec2(14, rowH))
    imgui.GetWindowDrawList():AddCircleFilled(imgui.ImVec2(sp.x + 5, sp.y + rowH / 2), 4,
        act > 0 and toU32(0.30, 0.85, 0.62, 1) or toU32(0.40, 0.42, 0.50, 1), 12)
    imgui.SameLine(0, 2)
    imgui.AlignTextToFramePadding()
    imgui.Text(('Работает: %d из %d'):format(act, #msgs))
    if act > 0 then
        imgui.SameLine(0, 12)
        local stopW = imgui.CalcTextSize('Остановить всё').x + 22
        if UPD.btn('Остановить всё##stopall', stopW, 24, 'ghost') then AP.stopAll() end
        tooltip('Выключить все работающие пиары в один клик.')
    end
    local cbLabel = 'Смена таймера со след. круга'
    local addW = 130
    imgui.SameLine(rightEdge - addW - 16 - imgui.CalcTextSize(cbLabel).x - 30)
    imgui.Checkbox(cbLabel, saveDelay)
    tooltip(
        'Включено: если изменить задержку на ходу, старый таймер дотикает до конца, а новое время применится со следующего круга.\n' ..
        'Выключено: таймер сбросится сразу и пойдёт заново.'
    )
    imgui.SameLine(rightEdge - addW)
    if imgui.Button('+ Новый пиар', imgui.ImVec2(addW, math.max(24, L.add_btn_h - 5))) then
        msgs[#msgs + 1] = newMsg({})
        target = #msgs
    end
    local pm = msgs[target]
    if #msgs == 0 then
        imgui.Dummy(imgui.ImVec2(0, 2))
    elseif pm then
        imgui.TextDisabled('Предпросмотр:')
        imgui.SameLine()
        local ptxt = AP.curText(pm)
        if ptxt:match('^%s*$') then
            imgui.TextDisabled('(пусто)')
        else
            drawPreview(ptxt, 18)
        end
        imgui.SameLine(0, 6)
        imgui.TextDisabled(('| Вставка в № %d'):format(target)
            .. (AP.lineCount(pm) > 1 and (', строка ' .. AP.curLine(pm)) or ''))
    else
        imgui.TextDisabled('Предпросмотр: —')
    end
    if #msgs > 0 then
        imgui.Spacing()
        imgui.TextDisabled('Мои пиары')
    end
    local listH = bottom and math.max(80, L.list_h) or math.max(80, imgui.GetContentRegionAvail().y)
    imgui.PushStyleVarFloat(imgui.StyleVar.ScrollbarSize, 0)
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.ScrollbarBg, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.ScrollbarGrab, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.ScrollbarGrabHovered, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.ScrollbarGrabActive, imgui.ImVec4(0, 0, 0, 0))
    imgui.BeginChild('##msglist', imgui.ImVec2(0, listH), false,
        bit.bor(imgui.WindowFlags.NoScrollbar, imgui.WindowFlags.NoScrollWithMouse))
    if #msgs == 0 then
        local avail = imgui.GetContentRegionAvail()
        local t1 = 'У тебя пока нет пиаров'
        local t2 = 'Нажми «+ Новый пиар», чтобы добавить первое сообщение.'
        local function big(fn)
            pcall(imgui.SetWindowFontScale, 1.45)
            if AP.fontBold then imgui.PushFont(AP.fontBold) end
            local a, b = fn()
            if AP.fontBold then imgui.PopFont() end
            pcall(imgui.SetWindowFontScale, 1.0)
            return a, b
        end
        local w1, h1 = big(function() return imgui.CalcTextSize(t1).x, imgui.GetTextLineHeight() end)
        local w2 = imgui.CalcTextSize(t2).x
        local blockH = h1 + 8 + imgui.GetTextLineHeight()
        imgui.Dummy(imgui.ImVec2(0, math.max(0, (avail.y - blockH) * 0.38)))
        imgui.SetCursorPosX(math.max(0, (avail.x - w1) * 0.5))
        big(function() imgui.TextColored(AMBER, t1) end)
        imgui.Dummy(imgui.ImVec2(0, 4))
        imgui.SetCursorPosX(math.max(0, (avail.x - w2) * 0.5))
        imgui.TextColored(GRAY, t2)
    else
        local toRemove, toDup = nil, nil
        for i, m in ipairs(msgs) do
            local del, dup = drawCard(i, m)
            if del then toRemove = i end
            if dup then toDup = i end
            if i < #msgs then imgui.Dummy(imgui.ImVec2(0, L.card_gap)) end
        end
        if toRemove then
            table.remove(msgs, toRemove)
            if target > #msgs then target = math.max(1, #msgs) end
            if #msgs == 0 then target = 1 end
        elseif toDup then
            table.insert(msgs, toDup + 1, newMsg(AP.msgData(msgs[toDup])))
            target = toDup + 1
        end
    end
    local step = L.card_h + L.card_gap + 2 * L.spacing_y
    local hoverFlags = 0
    pcall(function() hoverFlags = imgui.HoveredFlags.ChildWindows end)
    if step > 0 and (imgui.IsWindowHovered(hoverFlags) or imgui.IsWindowHovered()) then
        local wheel = imgui.GetIO().MouseWheel
        if wheel ~= 0 then
            local sy = imgui.GetScrollY()
            local maxY = imgui.GetScrollMaxY()
            local idx = math.floor(sy / step + 0.5)
            local dir = wheel > 0 and -1 or 1
            local nextY = (idx + dir) * step
            for _, mm in ipairs(msgs) do
                if AP.lineCount(mm) > 1 then nextY = sy + dir * 80 break end
            end
            if nextY < 0 then nextY = 0 end
            if nextY > maxY then nextY = maxY end
            imgui.SetScrollY(nextY)
        end
    end
    imgui.EndChild()
    imgui.PopStyleColor(5)
    imgui.PopStyleVar()
    if bottom then
        imgui.Spacing()
        imgui.Separator()
        drawBottomPanel()
    end
    local wp, wsz = imgui.GetWindowPos(), imgui.GetWindowSize()
    UPD.drawOverlay(wp, wsz)
    imgui.End()
    if not bottom then AP.drawSidePanel(wp.x, wp.y, wsz.x, wsz.y) end
end)
function main()
    while not isSampAvailable() do wait(100) end
    loadConfig()
    rebuildCmdItems()
    pcall(os.remove, UPD.path .. '.bak')
    pcall(os.remove, CONFIG_DIR .. '\\update.log')
    if VR.lastEpoch then
        local rem = VR.lastEpoch + (VR.cd or VR.fallback) + 1 - os.time()
        if rem > 0 and rem <= 7200 then VR.readyAt = os.clock() + rem end
    end
    math.randomseed(os.time())
    sampRegisterChatCommand('ap', function()
        if UPD.view then UPD.view = nil return end
        win[0] = not win[0]
        if win[0] then
            AP.needReset = true
            if UPD.enabled == nil then UPD.view = 'ask' end
        else
            save()
        end
    end)
    sampAddChatMessage(u8:decode('{FFB84D}[АвтоПиар] {FFFFFF}Скрипт запущен v' .. UPD.ver .. '. Открыть меню: {FFB84D}/ap'), -1)
    if AP.acefErr then
        notify('Не установлена библиотека arizona-events, без неё вкладка «Инвентарь» работать не будет. '
            .. 'Положи папку arizona-events в moonloader\\lib и перезагрузи скрипт.')
    end
    collectgarbage('collect')
    collectgarbage('setpause', 110)
    collectgarbage('setstepmul', 300)
    pcall(AP.invLoad)
    local invSaveAt = 0
    while true do
        wait(0)
        local now = os.clock()
        UPD.tick()
        AP.tick(now)
        if UPD.enabled and not UPD.started and sampIsLocalPlayerSpawned() then
            UPD.started = true
            UPD.startAt = now + 3
        end
        if UPD.startAt and now >= UPD.startAt then
            UPD.startAt = nil
            UPD.check(false)
        end
        if UPD.enabled and UPD.started and not UPD.startAt and not UPD.busy and not UPD.info
            and now >= (UPD.nextAt or 0) then
            UPD.check(false)
        end
        if AP.sync and now > AP.sync.till then
            AP.sync = nil
            notify('Не удалось обновить инвентарь: сервер не ответил.')
        end
        if AP.invVer ~= AP.invSavedVer and now - invSaveAt > 3 and AP.invVer > 0 then
            invSaveAt = now
            pcall(AP.invSave)
        end
        for _, m in ipairs(msgs) do
            if m.active and m.rs[0] and m.checkAt and now >= m.checkAt and now >= globalNext then
                if now < AP.adReadyAt then
                    m.checkAt = AP.adReadyAt + 0.5
                elseif canSend() then
                    m.checkAt = nil
                    local ctext = (msgText(m):gsub('^%s+', ''))
                    local cfixed, cwhy = AP.resolveSlots(ctext)
                    local lenErr = cfixed and AP.adCheck(cfixed)
                    if lenErr then
                        AP.fail(m, 'Остановлено: ' .. lenErr, true)
                    elseif cfixed then
                        pendingAd = { m = m, mode = 'check', till = now + 6 }
                        AP.lastSend = { m = m, cmd = '/ad', at = now, prevReady = VR.readyAt, text = cfixed }
                        sampSendChat(u8:decode('/ad ' .. cfixed))
                    else
                        AP.fail(m, 'Остановлено: ' .. cwhy, true)
                    end
                    globalNext = now + GAP
                else
                    m.checkAt = now + 1
                end
                break
            end
        end
        if now >= globalNext then
            local vrBest, sentOther = nil, false
            for _, m in ipairs(msgs) do
                if m.active and now >= m.nextAt then
                    local c = CMDS[m.cmd[0] + 1]
                    if c == '/ad' and now < AP.adReadyAt then
                        m.nextAt = AP.adReadyAt
                    elseif c == '/vr' and m.ad[0] then
                        m.waitSince = m.waitSince or now
                        if not vrBest or m.waitSince < vrBest.waitSince then vrBest = m end
                    else
                        if canSend() then
                            AP.fire(m, now)
                            globalNext = now + ((m.idx or 1) > 1 and math.min(GAP, m.total or GAP) or GAP)
                        else
                            m.nextAt = now + 1
                        end
                        sentOther = true
                        break
                    end
                end
            end
            if vrBest and not sentOther and now >= AP.VR.readyAt and canSend() then
                vrBest.waitSince = nil
                AP.fire(vrBest, now)
                globalNext = now + GAP
            end
        end
    end
end
function onWindowMessage(msg, wparam, lparam)
    if wparam ~= 0x1B then return end
    local down = (msg == 0x100 or msg == 0x104)
    local up = (msg == 0x101 or msg == 0x105)
    if not (down or up) then return end
    local function eat()
        pcall(consumeWindowMessage, true, true)
        return false
    end
    if down and UPD.view then
        UPD.view = nil
        AP.escSwallow = true
        return eat()
    end
    if down and win[0] then
        win[0] = false
        save()
        AP.escSwallow = true
        AP.needReset = true
        return eat()
    end
    if AP.escSwallow then
        if up then AP.escSwallow = false end
        return eat()
    end
end
function onScriptTerminate(s, quit)
    if s == thisScript() then
        pcall(function()
            if AP.acef and AP.acef.onArizonaDisplay == AP.wrapper then
                AP.acef.onArizonaDisplay = AP.prevHandler
            end
        end)
        save()
        if AP.invVer > 0 and AP.invVer ~= AP.invSavedVer then pcall(AP.invSave) end
        emojiUnload(quit)
        iconUnload(quit)
    end
end
EMOJI_DATA_FN = function() return [==[
:d	1F600	1	1
u1f601	1F601	1	1
joy	1F602	1	1
rofl	1F923	1	1
smiley	1F603	1	1
smile	1F604	1	1
sweat	1F605	1	1
xd	1F606	1	1
;)	1F609	1	1
^_^	1F60A	1	1
yum	1F60B	1	1
u1f60e	1F60E	1	1
heart_eyes	1F60D	1	1
:*	1F618	1	1
love	1F970	1	1
kissing	1F617	1	1
u1f619	1F619	1	1
:')	1F972	1	1
u1f61a	1F61A	1	1
u263a	263A	1	1
:)	1F642	1	1
hugging	1F917	1	1
starstruck	1F929	1	1
thinking	1F914	1	1
salut	1FAE1	1	1
what	1F928	1	1
:|	1F610	1	1
-_-	1F611	1	1
muted	1F636	1	1
dotted	1FAE5	1	1
rolleye	1F644	1	1
smirk	1F60F	1	1
>_<	1F623	1	1
sad	1F625	1	1
:o	1F62E	1	1
zipper	1F910	1	1
hushed	1F62F	1	1
sleepy	1F62A	1	1
tired	1F62B	1	1
yawn	1F971	1	1
zzz	1F634	1	1
relieved	1F60C	1	1
:p	1F61B	1	1
;p	1F61C	1	1
u1f61d	1F61D	1	1
drooling	1F924	1	1
bruh	1F612	1	1
u1f613	1F613	1	1
pensive	1F614	1	1
:\	1F615	1	1
u1fae4	1FAE4	1	1
u1f643	1F643	1	1
melt	1FAE0	1	1
money	1F911	1	1
astonished	1F632	1	1
u2639	2639	1	1
:(	1F641	1	1
>~<	1F616	1	1
pained	1F61E	1	1
worried	1F61F	1	1
triumph	1F624	1	1
:'(	1F622	1	1
sob	1F62D	1	1
frowning	1F626	1	1
anguished	1F627	1	1
fearful	1F628	1	1
weary	1F629	1	1
fyp	1F92F	1	1
grimacing	1F62C	1	1
anxious	1F630	1	1
scream	1F631	1	1
hot	1F975	1	1
cold	1F976	1	1
0_0	1F633	1	1
zany	1F92A	1	1
dizzy	1F635	1	1
woozy	1F974	1	1
angry	1F620	1	1
rage	1F621	1	1
swear	1F92C	1	1
mask	1F637	1	1
u1f912	1F912	1	1
bandage	1F915	1	1
nauseated	1F922	1	1
vomit	1F92E	1	1
tissue	1F927	1	1
halo	1F607	1	1
party	1F973	1	1
albert	1F978	1	1
u1f97a	1F97A	1	1
u1f979	1F979	1	1
cowboy	1F920	1	1
clown	1F921	1	1
lying	1F925	1	1
u1fae8	1FAE8	1	1
shush	1F92B	1	1
u1f92d	1F92D	1	1
u1fae2	1FAE2	1	1
u1fae3	1FAE3	1	1
monocle	1F9D0	1	1
nerd	1F913	1	1
horns	1F608	1	1
imp	1F47F	1	1
ogre	1F479	1	1
goblin	1F47A	1	1
skull	1F480	1	1
u2620	2620	1	1
ghost	1F47B	1	1
alien	1F47D	1	1
alienm	1F47E	1	1
robot	1F916	1	1
poo	1F4A9	1	1
cat	1F63A	1	1
smile_cat	1F638	1	1
joy_cat	1F639	1	1
u1f63b	1F63B	1	1
smirk_cat	1F63C	1	1
u1f63d	1F63D	1	1
scream_cat	1F640	1	1
u1f63f	1F63F	1	1
u1f63e	1F63E	1	1
u1f648	1F648	1	1
u1f649	1F649	1	1
u1f64a	1F64A	1	1
monkey	1F435	1	1
dog	1F436	1	1
wolf	1F43A	1	1
lion	1F981	1	1
tiger	1F42F	1	1
giraffe	1F992	1	1
fox	1F98A	1	1
raccoon	1F99D	1	1
cow	1F42E	1	1
pig	1F437	1	1
boar	1F417	1	1
mouse	1F42D	1	1
hamster	1F439	1	1
rabbit	1F430	1	1
bear	1F43B	1	1
koala	1F428	1	1
panda	1F43C	1	1
frog	1F438	1	1
zebra	1F993	1	1
horse	1F434	1	1
u1face	1FACE	1	1
u1facf	1FACF	1	1
unicorn	1F984	1	1
chicken	1F414	1	1
u1f432	1F432	1	1
pig_nose	1F43D	1	1
feet	1F43E	1	1
monkey2	1F412	1	1
gorilla	1F98D	1	1
orangutan	1F9A7	1	1
guide_dog	1F9AE	1	1
poodle	1F429	1	1
dog2	1F415	1	1
cat2	1F408	1	1
tiger2	1F405	1	1
leopard	1F406	1	1
racehorse	1F40E	1	1
deer	1F98C	1	1
u1f9ac	1F9AC	1	1
rhinoceros	1F98F	1	1
u1f99b	1F99B	1	1
ox	1F402	1	1
u1f403	1F403	1	1
cow2	1F404	1	1
pig2	1F416	1	1
ram	1F40F	1	1
sheep	1F411	1	1
goat	1F410	1	1
u1f42a	1F42A	1	1
camel	1F42B	1	1
llama	1F999	1	1
kangaroo	1F998	1	1
sloth	1F9A5	1	1
skunk	1F9A8	1	1
badger	1F9A1	1	1
elephant	1F418	1	1
u1f9a3	1F9A3	1	1
mouse2	1F401	1	1
rat	1F400	1	1
hedgehog	1F994	1	1
rabbit2	1F407	1	1
chipmunk	1F43F	1	1
u1f9ab	1F9AB	1	1
lizard	1F98E	1	1
crocodile	1F40A	1	1
turtle	1F422	1	1
snake	1F40D	1	1
dragon	1F409	1	1
sauropod	1F995	1	1
trex	1F996	1	1
otter	1F9A6	1	1
shark	1F988	1	1
dolphin	1F42C	1	1
u1f9ad	1F9AD	1	1
whale	1F433	1	1
whale2	1F40B	1	1
fish	1F41F	1	1
u1f420	1F420	1	1
blowfish	1F421	1	1
shrimp	1F990	1	1
squid	1F991	1	1
octopus	1F419	1	1
lobster	1F99E	1	1
crab	1F980	1	1
shell	1F41A	1	1
u1fab8	1FAB8	1	1
u1fabc	1FABC	1	1
duck	1F986	1	1
cock	1F413	1	1
turkey	1F983	1	1
eagle	1F985	1	1
dove	1F54A	1	1
swan	1F9A2	1	1
parrot	1F99C	1	1
u1fabd	1FABD	1	1
u1fabf	1FABF	1	1
flamingo	1F9A9	1	1
peacock	1F99A	1	1
owl	1F989	1	1
u1f9a4	1F9A4	1	1
u1fab6	1FAB6	1	1
bird	1F426	1	1
penguin	1F427	1	1
u1f425	1F425	1	1
chick	1F424	1	1
u1f423	1F423	1	1
bat	1F987	1	1
butterfly	1F98B	1	1
snail	1F40C	1	1
u1f41b	1F41B	1	1
mosquito	1F99F	1	1
fly	1FAB0	1	1
worm	1FAB1	1	1
cricket	1F997	1	1
ant	1F41C	1	1
u1fab3	1FAB3	1	1
bee	1F41D	1	1
beetle	1FAB2	1	1
bug	1F41E	1	1
scorpion	1F982	1	1
spider	1F577	1	1
spider_web	1F578	1	1
microbe	1F9A0	1	1
genie	1F9DE	1	1
zombie	1F9DF	1	1
u1f9cc	1F9CC	1	1
u1f5e3	1F5E3	1	1
u1f464	1F464	1	1
u1f465	1F465	1	1
u1fac2	1FAC2	1	1
eye	1F441	1	1
eyes	1F440	1	1
bone	1F9B4	1	1
tooth	1F9B7	1	1
tongue	1F445	1	1
lips	1F444	1	1
u1fae6	1FAE6	1	1
brain	1F9E0	1	1
u1fac0	1FAC0	1	1
u1fac1	1FAC1	1	1
u1f9be	1F9BE	1	1
u1f9bf	1F9BF	1	1
footprints	1F463	1	1
u1f93a	1F93A	1	1
skier	26F7	1	1
woman	1F469	2	1
man	1F468	2	1
person	1F9D1	2	1
girl	1F467	2	1
boy	1F466	2	1
child	1F9D2	2	1
baby	1F476	2	1
older_woman	1F475	2	1
older_man	1F474	2	1
u1f9d3	1F9D3	2	1
princess	1F478	2	1
prince	1F934	2	1
u1fac5	1FAC5	2	1
turban	1F473	2	1
u1f472	1F472	2	1
beard	1F9D4	2	1
angel	1F47C	2	1
u1f936	1F936	2	1
santa	1F385	2	1
cop	1F46E	2	1
detective	1F575	2	1
guardsman	1F482	2	1
u1f977	1F977	2	1
u1f477	1F477	2	1
u1f9d5	1F9D5	2	1
u1f470	1F470	2	1
u1f935	1F935	2	1
u1f931	1F931	2	1
u1f930	1F930	2	1
u1fac3	1FAC3	2	1
u1fac4	1FAC4	2	1
superhero	1F9B8	2	1
u1f9b9	1F9B9	2	1
mage	1F9D9	2	1
fairy	1F9DA	2	1
vampire	1F9DB	2	1
merperson	1F9DC	2	1
elf	1F9DD	2	1
u1f64d	1F64D	2	1
u1f64e	1F64E	2	1
no_good	1F645	2	1
ok1	1F646	2	1
u1f9cf	1F9CF	2	1
u1f481	1F481	2	1
u1f64b	1F64B	2	1
bow	1F647	2	1
u1f926	1F926	2	1
u1f937	1F937	2	1
massage	1F486	2	1
haircut	1F487	2	1
u1f9d6	1F9D6	2	1
u1f939	1F939	2	1
u1f9ce	1F9CE	2	1
u1f9cd	1F9CD	2	1
walking	1F6B6	2	1
runner	1F3C3	2	1
dancer	1F483	2	1
u1f57a	1F57A	2	1
u1f9d7	1F9D7	2	1
u1f9d8	1F9D8	2	1
bath	1F6C0	2	1
u1f6cc	1F6CC	2	1
u1f574	1F574	2	1
u1f3c7	1F3C7	2	1
u1f3c2	1F3C2	2	1
golfer	1F3CC	2	1
surfer	1F3C4	2	1
rowboat	1F6A3	2	1
swimmer	1F3CA	2	1
u1f93d	1F93D	2	1
u1f93e	1F93E	2	1
u26f9	26F9	2	1
u1f3cb	1F3CB	2	1
bicyclist	1F6B4	2	1
u1f6b5	1F6B5	2	1
u1f938	1F938	2	1
selfie	1F933	2	1
muscle	1F4AA	2	1
leg	1F9B5	2	1
foot	1F9B6	2	1
ear	1F442	2	1
u1f9bb	1F9BB	2	1
nose	1F443	2	1
u1f90f	1F90F	2	1
left	1F448	2	1
right	1F449	2	1
up1	261D	2	1
u1faf5	1FAF5	2	1
up	1F446	2	1
down	1F447	2	1
v	270C	2	1
u1f91e	1F91E	2	1
u1faf0	1FAF0	2	1
u1f596	1F596	2	1
u1faf1	1FAF1	2	1
u1faf2	1FAF2	2	1
u1faf3	1FAF3	2	1
u1faf4	1FAF4	2	1
u1faf7	1FAF7	2	1
u1faf8	1FAF8	2	1
fuck	1F595	2	1
rock	1F918	2	1
call	1F919	2	1
u1f590	1F590	2	1
u270b	270B	2	1
ok	1F44C	2	1
u1f90c	1F90C	2	1
+	1F44D	2	1
-	1F44E	2	1
fist	270A	2	1
u1f44a	1F44A	2	1
u1f91b	1F91B	2	1
u1f91c	1F91C	2	1
u1f91a	1F91A	2	1
wave	1F44B	2	1
u1f91f	1F91F	2	1
u270d	270D	2	1
clap	1F44F	2	1
open_hands	1F450	2	1
u1f64c	1F64C	2	1
hheart	1FAF6	2	1
u1f932	1F932	2	1
pray	1F64F	2	1
handshake	1F91D	2	1
nails	1F485	2	1
u1f93c	1F93C	2	1
dancers	1F46F	2	1
u1f491	1F491	2	1
u1f48f	1F48F	2	1
u1f46a	1F46A	2	1
balloon	1F388	3	1
fireworks	1F386	3	1
sparkler	1F387	3	1
u1f9e8	1F9E8	3	1
sparkles	2728	3	1
tada	1F389	3	1
u1f38a	1F38A	3	1
u1f383	1F383	3	1
u1f384	1F384	3	1
u1f38b	1F38B	3	1
bamboo	1F38D	3	1
dolls	1F38E	3	1
flags	1F38F	3	1
wind_chime	1F390	3	1
rice_scene	1F391	3	1
u1f9e7	1F9E7	3	1
ribbon	1F380	3	1
gift	1F381	3	1
u1f397	1F397	3	1
u1f39e	1F39E	3	1
u1f39f	1F39F	3	1
ticket	1F3AB	3	1
u1f3a0	1F3A0	3	1
u1f6dd	1F6DD	3	1
u1f3a1	1F3A1	3	1
u1f3a2	1F3A2	3	1
u1f3aa	1F3AA	3	1
u1f3ad	1F3AD	3	1
u1f5bc	1F5BC	3	1
u1f3a8	1F3A8	3	1
thread	1F9F5	3	1
u1faa1	1FAA1	3	1
yarn	1F9F6	3	1
u1faa2	1FAA2	3	1
u1f6d2	1F6D2	3	1
eyeglasses	1F453	3	1
u1f576	1F576	3	1
u1f9ba	1F9BA	3	1
goggles	1F97D	3	1
lab_coat	1F97C	3	1
coat	1F9E5	3	1
necktie	1F454	3	1
shirt	1F455	3	1
jeans	1F456	3	1
shorts	1FA73	3	1
scarf	1F9E3	3	1
gloves	1F9E4	3	1
socks	1F9E6	3	1
dress	1F457	3	1
sari	1F97B	3	1
kimono	1F458	3	1
u1f45a	1F45A	3	1
u1faad	1FAAD	3	1
briefs	1FA72	3	1
u1fa71	1FA71	3	1
bikini	1F459	3	1
purse	1F45B	3	1
handbag	1F45C	3	1
pouch	1F45D	3	1
u1f6cd	1F6CD	3	1
u1f392	1F392	3	1
u1fa74	1FA74	3	1
mans_shoe	1F45E	3	1
u1f45f	1F45F	3	1
u1f97e	1F97E	3	1
flat_shoe	1F97F	3	1
high_heel	1F460	3	1
sandal	1F461	3	1
boot	1F462	3	1
u1faae	1FAAE	3	1
u1fa70	1FA70	3	1
crown	1F451	3	1
billed_cap	1F9E2	3	1
u1fa96	1FA96	3	1
u26d1	26D1	3	1
womans_hat	1F452	3	1
tophat	1F3A9	3	1
u1f393	1F393	3	1
kiss	1F48B	3	1
lipstick	1F484	3	1
ring	1F48D	3	1
gem	1F48E	3	1
soccer	26BD	3	1
baseball	26BE	3	1
softball	1F94E	3	1
basketball	1F3C0	3	1
volleyball	1F3D0	3	1
football	1F3C8	3	1
u1f3c9	1F3C9	3	1
8ball	1F3B1	3	1
bowling	1F3B3	3	1
u1f94c	1F94C	3	1
golf	26F3	3	1
ice_skate	26F8	3	1
u1f3a3	1F3A3	3	1
u1f93f	1F93F	3	1
u1f3bd	1F3BD	3	1
canoe	1F6F6	3	1
ski	1F3BF	3	1
sled	1F6F7	3	1
goal_net	1F945	3	1
ice_hockey	1F3D2	3	1
lacrosse	1F94D	3	1
u1f3cf	1F3CF	3	1
u1f3d1	1F3D1	3	1
ping_pong	1F3D3	3	1
badminton	1F3F8	3	1
tennis	1F3BE	3	1
u1f94f	1F94F	3	1
kite	1FA81	3	1
dart	1F3AF	3	1
u1f94a	1F94A	3	1
u1f94b	1F94B	3	1
u1f947	1F947	3	1
u1f948	1F948	3	1
u1f949	1F949	3	1
medal	1F3C5	3	1
u1f396	1F396	3	1
trophy	1F3C6	3	1
video_game	1F3AE	3	1
joystick	1F579	3	1
u1f3b0	1F3B0	3	1
game_die	1F3B2	3	1
u1f52e	1F52E	3	1
u1fa84	1FA84	3	1
u1f9ff	1F9FF	3	1
u1faac	1FAAC	3	1
u1f9e9	1F9E9	3	1
teddy_bear	1F9F8	3	1
u1fa85	1FA85	3	1
u1faa9	1FAA9	3	1
u1fa86	1FA86	3	1
yoyo	1FA80	3	1
u1f3b4	1F3B4	3	1
u1f0cf	1F0CF	3	1
mahjong	1F004	3	1
chess_pawn	265F	3	1
spades	2660	3	1
clubs	2663	3	1
hearts	2665	3	1
diamonds	2666	3	1
speaker	1F508	3	1
sound	1F509	3	1
loud_sound	1F50A	3	1
u1f4e2	1F4E2	3	1
mega	1F4E3	3	1
bell	1F514	3	1
u1f3bc	1F3BC	3	1
u1f3b5	1F3B5	3	1
notes	1F3B6	3	1
u1f399	1F399	3	1
microphone	1F3A4	3	1
u1f39a	1F39A	3	1
u1f39b	1F39B	3	1
headphones	1F3A7	3	1
u1f4ef	1F4EF	3	1
drum	1F941	3	1
u1fa98	1FA98	3	1
u1fa87	1FA87	3	1
u1fa88	1FA88	3	1
saxophone	1F3B7	3	1
u1fa97	1FA97	3	1
trumpet	1F3BA	3	1
guitar	1F3B8	3	1
banjo	1FA95	3	1
violin	1F3BB	3	1
u1f3b9	1F3B9	3	1
radio	1F4FB	3	1
lock	1F512	3	1
unlock	1F513	3	1
u1f50f	1F50F	3	1
u1f510	1F510	3	1
key	1F511	3	1
old_key	1F5DD	3	1
axe	1FA93	3	1
hammer	1F528	3	1
pick	26CF	3	1
u2692	2692	3	1
u1f6e0	1F6E0	3	1
wrench	1F527	3	1
u1fa9b	1FA9B	3	1
u1f529	1F529	3	1
brick	1F9F1	3	1
u1faa8	1FAA8	3	1
u1fab5	1FAB5	3	1
u1f6d6	1F6D6	3	1
gear	2699	3	1
u1f5dc	1F5DC	3	1
oil_drum	1F6E2	3	1
alembic	2697	3	1
test_tube	1F9EA	3	1
petri_dish	1F9EB	3	1
dna	1F9EC	3	1
u1fa7a	1FA7A	3	1
u1fa7b	1FA7B	3	1
syringe	1F489	3	1
u1fa78	1FA78	3	1
u1fa79	1FA79	3	1
u1fa7c	1FA7C	3	1
pill	1F48A	3	1
microscope	1F52C	3	1
telescope	1F52D	3	1
scales	2696	3	1
u1f4ff	1F4FF	3	1
link	1F517	3	1
chains	26D3	3	1
u1fa9d	1FA9D	3	1
toolbox	1F9F0	3	1
magnet	1F9F2	3	1
u1fa9c	1FA9C	3	1
u1f9af	1F9AF	3	1
shield	1F6E1	3	1
u1fa9a	1FA9A	3	1
u1f3f9	1F3F9	3	1
dagger	1F5E1	3	1
u2694	2694	3	1
u1f52a	1F52A	3	1
u1fad9	1FAD9	3	1
bomb	1F4A3	3	1
gun	1F52B	3	1
u1fa83	1FA83	3	1
telephone	260E	3	1
u1f4de	1F4DE	3	1
pager	1F4DF	3	1
fax	1F4E0	3	1
phone	1F4F1	3	1
calling	1F4F2	3	1
u1f4f3	1F4F3	3	1
u1f4f4	1F4F4	3	1
female	2640	3	1
male	2642	3	1
u26a7	26A7	3	1
smoking	1F6AC	3	1
coffin	26B0	3	1
cleo	1FAA6	3	1
u26b1	26B1	3	1
moai	1F5FF	3	1
u1faa7	1FAA7	3	1
u1faaa	1FAAA	3	1
battery	1F50B	3	1
u1faab	1FAAB	3	1
u1f50c	1F50C	3	1
computer	1F4BB	3	1
u1f5a5	1F5A5	3	1
printer	1F5A8	3	1
keyboard	2328	3	1
u1f5b1	1F5B1	3	1
trackball	1F5B2	3	1
minidisc	1F4BD	3	1
u1f4be	1F4BE	3	1
cd	1F4BF	3	1
dvd	1F4C0	3	1
abacus	1F9EE	3	1
u1f3a5	1F3A5	3	1
clapper	1F3AC	3	1
u1f4fd	1F4FD	3	1
satellite	1F4E1	3	1
tv	1F4FA	3	1
camera	1F4F7	3	1
u1f4f8	1F4F8	3	1
u1f4f9	1F4F9	3	1
vhs	1F4FC	3	1
mag	1F50D	3	1
mag_right	1F50E	3	1
candle	1F56F	3	1
diya_lamp	1FA94	3	1
bulb	1F4A1	3	1
flashlight	1F526	3	1
u1f3ee	1F3EE	3	1
u1f4d4	1F4D4	3	1
u1f4d5	1F4D5	3	1
book	1F4D6	3	1
green_book	1F4D7	3	1
blue_book	1F4D8	3	1
u1f4d9	1F4D9	3	1
books	1F4DA	3	1
notebook	1F4D3	3	1
ledger	1F4D2	3	1
u1f4c3	1F4C3	3	1
scroll	1F4DC	3	1
u1f4c4	1F4C4	3	1
u1f4d1	1F4D1	3	1
newspaper	1F4F0	3	1
u1f5de	1F5DE	3	1
bookmark	1F516	3	1
label	1F3F7	3	1
moneybag	1F4B0	3	1
coin	1FA99	3	1
yen	1F4B4	3	1
dollar	1F4B5	3	1
u1f4b6	1F4B6	3	1
pound	1F4B7	3	1
u1f4b8	1F4B8	3	1
u1f4b3	1F4B3	3	1
receipt	1F9FE	3	1
atm	1F3E7	3	1
envelope	2709	3	1
email	1F4E7	3	1
u1f4e8	1F4E8	3	1
u1f4e9	1F4E9	3	1
u1f4e4	1F4E4	3	1
inbox_tray	1F4E5	3	1
package	1F4E6	3	1
mailbox	1F4EB	3	1
u1f4ea	1F4EA	3	1
u1f4ec	1F4EC	3	1
u1f4ed	1F4ED	3	1
postbox	1F4EE	3	1
ballot_box	1F5F3	3	1
pencil2	270F	3	1
black_nib	2712	3	1
u1f58b	1F58B	3	1
pen	1F58A	3	1
paintbrush	1F58C	3	1
crayon	1F58D	3	1
memo	1F4DD	3	1
u1f5d2	1F5D2	3	1
briefcase	1F4BC	3	1
u1f4c1	1F4C1	3	1
u1f4c2	1F4C2	3	1
u1f5c2	1F5C2	3	1
date	1F4C5	3	1
calendar	1F4C6	3	1
u1f5d3	1F5D3	3	1
card_index	1F4C7	3	1
u1f4c8	1F4C8	3	1
u1f4c9	1F4C9	3	1
bar_chart	1F4CA	3	1
clipboard	1F4CB	3	1
pushpin	1F4CC	3	1
u1f4cd	1F4CD	3	1
paperclip	1F4CE	3	1
u1f587	1F587	3	1
u1f4cf	1F4CF	3	1
u1f4d0	1F4D0	3	1
scissors	2702	3	1
u1f5c3	1F5C3	3	1
u1f5c4	1F5C4	3	1
u1f5d1	1F5D1	3	1
hourglass	231B	3	1
u23f3	23F3	3	1
watch	231A	3	1
u23f0	23F0	3	1
stopwatch	23F1	3	1
u23f2	23F2	3	1
u1f570	1F570	3	1
pizza	1F355	4	1
hamburger	1F354	4	1
fries	1F35F	4	1
hotdog	1F32D	4	1
popcorn	1F37F	4	1
salt	1F9C2	4	1
bacon	1F953	4	1
egg	1F95A	4	1
cooking	1F373	4	1
waffle	1F9C7	4	1
pancakes	1F95E	4	1
butter	1F9C8	4	1
bread	1F35E	4	1
croissant	1F950	4	1
pretzel	1F968	4	1
bagel	1F96F	4	1
u1f956	1F956	4	1
u1fad3	1FAD3	4	1
u1f9c0	1F9C0	4	1
u1f957	1F957	4	1
u1f959	1F959	4	1
sandwich	1F96A	4	1
taco	1F32E	4	1
burrito	1F32F	4	1
u1fad4	1FAD4	4	1
u1f96b	1F96B	4	1
u1f356	1F356	4	1
u1f357	1F357	4	1
u1f969	1F969	4	1
u1f360	1F360	4	1
dumpling	1F95F	4	1
u1f960	1F960	4	1
u1f961	1F961	4	1
bento	1F371	4	1
u1f358	1F358	4	1
rice_ball	1F359	4	1
rice	1F35A	4	1
curry	1F35B	4	1
ramen	1F35C	4	1
oyster	1F9AA	4	1
sushi	1F363	4	1
u1f364	1F364	4	1
fish_cake	1F365	4	1
moon_cake	1F96E	4	1
oden	1F362	4	1
falafel	1F9C6	4	1
u1f958	1F958	4	1
stew	1F372	4	1
u1fad5	1FAD5	4	1
spaghetti	1F35D	4	1
u1f963	1F963	4	1
pie	1F967	4	1
icecream	1F366	4	1
shaved_ice	1F367	4	1
ice_cream	1F368	4	1
doughnut	1F369	4	1
cookie	1F36A	4	1
birthday	1F382	4	1
cake	1F370	4	1
cupcake	1F9C1	4	1
u1f36b	1F36B	4	1
candy	1F36C	4	1
lollipop	1F36D	4	1
dango	1F361	4	1
custard	1F36E	4	1
honey_pot	1F36F	4	1
u1f37c	1F37C	4	1
u1f95b	1F95B	4	1
u1f9c3	1F9C3	4	1
coffee	2615	4	1
u1fad6	1FAD6	4	1
tea	1F375	4	1
mate	1F9C9	4	1
sake	1F376	4	1
champagne	1F37E	4	1
wine_glass	1F377	4	1
cocktail	1F378	4	1
u1f379	1F379	4	1
beer	1F37A	4	1
beers	1F37B	4	1
u1f942	1F942	4	1
u1f943	1F943	4	1
u1fad7	1FAD7	4	1
ice	1F9CA	4	1
u1f964	1F964	4	1
u1f9cb	1F9CB	4	1
chopsticks	1F962	4	1
u1f37d	1F37D	4	1
u1f374	1F374	4	1
spoon	1F944	4	1
amphora	1F3FA	4	1
kiwi	1F95D	4	1
coconut	1F965	4	1
grapes	1F347	4	1
melon	1F348	4	1
watermelon	1F349	4	1
tangerine	1F34A	4	1
lemon	1F34B	4	1
banana	1F34C	4	1
pineapple	1F34D	4	1
mango	1F96D	4	1
apple	1F34E	4	1
u1f34f	1F34F	4	1
pear	1F350	4	1
peach	1F351	4	1
cherries	1F352	4	1
strawberry	1F353	4	1
u1fad0	1FAD0	4	1
tomato	1F345	4	1
u1fad2	1FAD2	4	1
eggplant	1F346	4	1
corn	1F33D	4	1
pepper	1F336	4	1
u1fad1	1FAD1	4	1
mushroom	1F344	4	1
avocado	1F951	4	1
cucumber	1F952	4	1
u1f96c	1F96C	4	1
broccoli	1F966	4	1
potato	1F954	4	1
garlic	1F9C4	4	1
onion	1F9C5	4	1
carrot	1F955	4	1
chestnut	1F330	4	1
u1fada	1FADA	4	1
u1fadb	1FADB	4	1
peanuts	1F95C	4	1
u1fad8	1FAD8	4	1
bouquet	1F490	4	1
u1f338	1F338	4	1
rosette	1F3F5	4	1
rose	1F339	4	1
hibiscus	1F33A	4	1
sunflower	1F33B	4	1
blossom	1F33C	4	1
tulip	1F337	4	1
u1fabb	1FABB	4	1
u1f940	1F940	4	1
shamrock	2618	4	1
seedling	1F331	4	1
u1fab4	1FAB4	4	1
u1f332	1F332	4	1
u1f333	1F333	4	1
palm_tree	1F334	4	1
cactus	1F335	4	1
u1f33e	1F33E	4	1
herb	1F33F	4	1
u1f340	1F340	4	1
maple_leaf	1F341	4	1
u1f342	1F342	4	1
leaves	1F343	4	1
u1fab9	1FAB9	4	1
u1faba	1FABA	4	1
automobile	1F697	5	1
police_car	1F693	5	1
taxi	1F695	5	1
u1f6fa	1F6FA	5	1
blue_car	1F699	5	1
u1f6fb	1F6FB	5	1
bus	1F68C	5	1
minibus	1F690	5	1
trolleybus	1F68E	5	1
ambulance	1F691	5	1
u1f692	1F692	5	1
truck	1F69A	5	1
u1f69b	1F69B	5	1
tractor	1F69C	5	1
u1f698	1F698	5	1
u1f694	1F694	5	1
u1f696	1F696	5	1
u1f68d	1F68D	5	1
u1f9bd	1F9BD	5	1
u1f9bc	1F9BC	5	1
skateboard	1F6F9	5	1
u1f6fc	1F6FC	5	1
bike	1F6B2	5	1
u1f6f4	1F6F4	5	1
u1f6f5	1F6F5	5	1
motorcycle	1F3CD	5	1
racing_car	1F3CE	5	1
u1f684	1F684	5	1
u1f685	1F685	5	1
light_rail	1F688	5	1
monorail	1F69D	5	1
u1f69e	1F69E	5	1
u1f683	1F683	5	1
train	1F68B	5	1
train2	1F686	5	1
station	1F689	5	1
tram	1F68A	5	1
metro	1F687	5	1
u1f69f	1F69F	5	1
u1f6a0	1F6A0	5	1
u1f6a1	1F6A1	5	1
u1f682	1F682	5	1
u1f6e9	1F6E9	5	1
parachute	1FA82	5	1
airplane	2708	5	1
u1f6eb	1F6EB	5	1
u1f6ec	1F6EC	5	1
seat	1F4BA	5	1
helicopter	1F681	5	1
rocket	1F680	5	1
u1f6f8	1F6F8	5	1
u1f6f0	1F6F0	5	1
sailboat	26F5	5	1
speedboat	1F6A4	5	1
motor_boat	1F6E5	5	1
ferry	26F4	5	1
u1f6f3	1F6F3	5	1
ship	1F6A2	5	1
anchor	2693	5	1
u1f6df	1F6DF	5	1
busstop	1F68F	5	1
fuelpump	26FD	5	1
u1f6de	1F6DE	5	1
u1f6a8	1F6A8	5	1
u1f6a5	1F6A5	5	1
u1f6a6	1F6A6	5	1
u1f6a7	1F6A7	5	1
u1f3c1	1F3C1	5	1
u1fc05	1FC05	5	1
u1fc06	1FC06	5	1
flag_white	1F3F3	5	1
flag_black	1F3F4	5	1
u1fc04	1FC04	5	1
red_flag	1F6A9	5	1
milky_way	1F30C	5	1
u1fa90	1FA90	5	1
u1f30d	1F30D	5	1
u1f30e	1F30E	5	1
earth_asia	1F30F	5	1
world_map	1F5FA	5	1
compass	1F9ED	5	1
u1f3d4	1F3D4	5	1
mountain	26F0	5	1
volcano	1F30B	5	1
fuji	1F5FB	5	1
u1f6e4	1F6E4	5	1
camping	1F3D5	5	1
u1f3de	1F3DE	5	1
motorway	1F6E3	5	1
u1f3d6	1F3D6	5	1
desert	1F3DC	5	1
u1f3dd	1F3DD	5	1
stadium	1F3DF	5	1
u1f3db	1F3DB	5	1
u1f3d7	1F3D7	5	1
houses	1F3D8	5	1
cityscape	1F3D9	5	1
u1f3da	1F3DA	5	1
house	1F3E0	5	1
u1f3e1	1F3E1	5	1
church	26EA	5	1
kaaba	1F54B	5	1
mosque	1F54C	5	1
u1f6d5	1F6D5	5	1
synagogue	1F54D	5	1
u26e9	26E9	5	1
office	1F3E2	5	1
u1f3e3	1F3E3	5	1
u1f3e4	1F3E4	5	1
hospital	1F3E5	5	1
bank	1F3E6	5	1
hotel	1F3E8	5	1
u1f3e9	1F3E9	5	1
u1f3ea	1F3EA	5	1
school	1F3EB	5	1
u1f3ec	1F3EC	5	1
factory	1F3ED	5	1
u1f3ef	1F3EF	5	1
u1f3f0	1F3F0	5	1
wedding	1F492	5	1
u1f5fc	1F5FC	5	1
u1f309	1F309	5	1
u1f5fd	1F5FD	5	1
japan	1F5FE	5	1
u1f38c	1F38C	5	1
fountain	26F2	5	1
tent	26FA	5	1
foggy	1F301	5	1
u1f303	1F303	5	1
u1f304	1F304	5	1
sunrise	1F305	5	1
u1f306	1F306	5	1
u1f307	1F307	5	1
hotsprings	2668	5	1
barber	1F488	5	1
u1f6ce	1F6CE	5	1
luggage	1F9F3	5	1
chair	1FA91	5	1
door	1F6AA	5	1
u1f6d7	1F6D7	5	1
u1fa9e	1FA9E	5	1
u1fa9f	1FA9F	5	1
bed	1F6CF	5	1
u1f6cb	1F6CB	5	1
toilet	1F6BD	5	1
u1faa0	1FAA0	5	1
u1f9fb	1F9FB	5	1
u1faa3	1FAA3	5	1
shower	1F6BF	5	1
bathtub	1F6C1	5	1
u1faa4	1FAA4	5	1
soap	1F9FC	5	1
u1fae7	1FAE7	5	1
u1faa5	1FAA5	5	1
sponge	1F9FD	5	1
u1f9f4	1F9F4	5	1
razor	1FA92	5	1
safety_pin	1F9F7	5	1
broom	1F9F9	5	1
basket	1F9FA	5	1
u1f9ef	1F9EF	5	1
cloud	2601	5	1
u26c5	26C5	5	1
u26c8	26C8	5	1
u1f324	1F324	5	1
u1f325	1F325	5	1
u1f326	1F326	5	1
u1f327	1F327	5	1
u1f328	1F328	5	1
u1f329	1F329	5	1
tornado	1F32A	5	1
fog	1F32B	5	1
u1f31d	1F31D	5	1
new_moon	1F311	5	1
u1f312	1F312	5	1
u1f313	1F313	5	1
u1f314	1F314	5	1
full_moon	1F315	5	1
u1f316	1F316	5	1
u1f317	1F317	5	1
u1f318	1F318	5	1
u1f319	1F319	5	1
moon_face	1F31A	5	1
u1f31b	1F31B	5	1
u1f31c	1F31C	5	1
sun	2600	5	1
sun_face	1F31E	5	1
star2	1F31F	5	1
stars	1F320	5	1
comet	2604	5	1
u1f321	1F321	5	1
u1f32c	1F32C	5	1
cyclone	1F300	5	1
rainbow	1F308	5	1
u1f302	1F302	5	1
u2602	2602	5	1
umbrella	2614	5	1
u26f1	26F1	5	1
zap	26A1	5	1
snowflake	2744	5	1
u2603	2603	5	1
snowman	26C4	5	1
fire	1F525	5	1
droplet	1F4A7	5	1
ocean	1F30A	5	1
<3	2764	6	1
u1fa77	1FA77	6	1
u1f9e1	1F9E1	6	1
u1f49b	1F49B	6	1
u1f49a	1F49A	6	1
u1f499	1F499	6	1
u1fa75	1FA75	6	1
u1f49c	1F49C	6	1
u1f90e	1F90E	6	1
u1f5a4	1F5A4	6	1
u1fa76	1FA76	6	1
u1f90d	1F90D	6	1
u1f494	1F494	6	1
u1fc02	1FC02	6	1
u1fc03	1FC03	6	1
u2763	2763	6	1
two_hearts	1F495	6	1
u1f49e	1F49E	6	1
heartbeat	1F493	6	1
heartpulse	1F497	6	1
u1f496	1F496	6	1
cupid	1F498	6	1
gift_heart	1F49D	6	1
u1f49f	1F49F	6	1
u1f48c	1F48C	6	1
anger	1F4A2	6	1
boom	1F4A5	6	1
afk	1F4A4	6	1
u1f4a6	1F4A6	6	1
dash	1F4A8	6	1
u1f4ab	1F4AB	6	1
hole	1F573	6	1
peace	262E	6	1
cross	271D	6	1
u262a	262A	6	1
om	1F549	6	1
u2638	2638	6	1
u2721	2721	6	1
u1f52f	1F52F	6	1
u1faaf	1FAAF	6	1
menorah	1F54E	6	1
yin_yang	262F	6	1
u2626	2626	6	1
u1f6d0	1F6D0	6	1
ophiuchus	26CE	6	1
aries	2648	6	1
taurus	2649	6	1
gemini	264A	6	1
cancer	264B	6	1
leo	264C	6	1
virgo	264D	6	1
libra	264E	6	1
scorpius	264F	6	1
u2650	2650	6	1
capricorn	2651	6	1
aquarius	2652	6	1
pisces	2653	6	1
id	1F194	6	1
u2695	2695	6	1
infinity	267E	6	1
atom	269B	6	1
u2734	2734	6	1
vs	1F19A	6	1
u1f4ae	1F4AE	6	1
u1fab7	1FAB7	6	1
u1f6bc	1F6BC	6	1
cl	1F191	6	1
sos	1F198	6	1
no_entry	26D4	6	1
u1f6d1	1F6D1	6	1
name_badge	1F4DB	6	1
x	274C	6	1
u1f6ab	1F6AB	6	1
mute	1F507	6	1
no_bell	1F515	6	1
u1f6ad	1F6AD	6	1
u1f6b7	1F6B7	6	1
u1f6af	1F6AF	6	1
u1f6b3	1F6B3	6	1
u1f6b1	1F6B1	6	1
u1f51e	1F51E	6	1
u1f4f5	1F4F5	6	1
u2757	2757	6	1
u2755	2755	6	1
u2753	2753	6	1
u2754	2754	6	1
u203c	203C	6	1
u2049	2049	6	1
u1f4af	1F4AF	6	1
u1f505	1F505	6	1
u1f506	1F506	6	1
trident	1F531	6	1
u269c	269C	6	1
u2622	2622	6	1
biohazard	2623	6	1
warning	26A0	6	1
u1f6b8	1F6B8	6	1
beginner	1F530	6	1
recycle	267B	6	1
chart	1F4B9	6	1
u2733	2733	6	1
u274e	274E	6	1
true	2705	6	1
u1f4a0	1F4A0	6	1
u1f310	1F310	6	1
u1f6c2	1F6C2	6	1
customs	1F6C3	6	1
u1f6c4	1F6C4	6	1
u1f6c5	1F6C5	6	1
lua	267F	6	1
wc	1F6BE	6	1
u1f6b0	1F6B0	6	1
mens	1F6B9	6	1
restroom	1F6BB	6	1
u1f6ae	1F6AE	6	1
u1f4f6	1F4F6	6	1
u1f6dc	1F6DC	6	1
u1f196	1F196	6	1
ok2	1F197	6	1
up2	1F199	6	1
cool	1F192	6	1
new	1F195	6	1
free	1F193	6	1
u1f522	1F522	6	1
u23f8	23F8	6	1
play_pause	23EF	6	1
u23f9	23F9	6	1
u23fa	23FA	6	1
track_next	23ED	6	1
u23ee	23EE	6	1
u23e9	23E9	6	1
rewind	23EA	6	1
u1f500	1F500	6	1
repeat	1F501	6	1
repeat_one	1F502	6	1
u1f53c	1F53C	6	1
u23eb	23EB	6	1
u1f53d	1F53D	6	1
u23ec	23EC	6	1
u23cf	23CF	6	1
cinema	1F3A6	6	1
u1f504	1F504	6	1
abc	1F524	6	1
abcd	1F521	6	1
u1f520	1F520	6	1
symbols	1F523	6	1
u1f503	1F503	6	1
on	1F51B	6	1
top	1F51D	6	1
soon	1F51C	6	1
end	1F51A	6	1
back	1F519	6	1
u2714	2714	6	1
u1f4b2	1F4B2	6	1
u1f4b1	1F4B1	6	1
u2716	2716	6	1
u1f7f0	1F7F0	6	1
u1f518	1F518	6	1
u1f534	1F534	6	1
u1f7e0	1F7E0	6	1
u1f7e1	1F7E1	6	1
u1f7e2	1F7E2	6	1
u1f535	1F535	6	1
u1f7e3	1F7E3	6	1
u1f7e4	1F7E4	6	1
u26ab	26AB	6	1
u26aa	26AA	6	1
u1f7e5	1F7E5	6	1
u1f7e7	1F7E7	6	1
u1f7e8	1F7E8	6	1
u1f7e9	1F7E9	6	1
u1f7e6	1F7E6	6	1
u1f7ea	1F7EA	6	1
u1f7eb	1F7EB	6	1
u1f536	1F536	6	1
u1f538	1F538	6	1
u1f537	1F537	6	1
u1f539	1F539	6	1
u1f53a	1F53A	6	1
u1f53b	1F53B	6	1
u1f532	1F532	6	1
u1f533	1F533	6	1
u1f4ad	1F4AD	6	1
u1f5ef	1F5EF	6	1
u1f4ac	1F4AC	6	1
u1f5e8	1F5E8	6	1
u1f550	1F550	6	1
u1f551	1F551	6	1
u1f552	1F552	6	1
u1f553	1F553	6	1
u1f554	1F554	6	1
u1f555	1F555	6	1
u1f556	1F556	6	1
u1f557	1F557	6	1
u1f558	1F558	6	1
u1f559	1F559	6	1
u1f55a	1F55A	6	1
u1f55b	1F55B	6	1
u1f55c	1F55C	6	1
u1f55d	1F55D	6	1
u1f55e	1F55E	6	1
u1f55f	1F55F	6	1
u1f560	1F560	6	1
u1f561	1F561	6	1
u1f562	1F562	6	1
u1f563	1F563	6	1
u1f564	1F564	6	1
u1f565	1F565	6	1
u1f566	1F566	6	1
u1f567	1F567	6	1
la	1F1E6	7	1
lb	1F1E7	7	1
lc	1F1E8	7	1
ld	1F1E9	7	1
le	1F1EA	7	1
lf	1F1EB	7	1
lg	1F1EC	7	1
lh	1F1ED	7	1
li	1F1EE	7	1
lj	1F1EF	7	1
lk	1F1F0	7	1
ll	1F1F1	7	1
lm	1F1F2	7	1
ln	1F1F3	7	1
lo	1F1F4	7	1
lp	1F1F5	7	1
lq	1F1F6	7	1
lr	1F1F7	7	1
ls	1F1F8	7	1
lt	1F1F9	7	1
lu	1F1FA	7	1
lv	1F1FB	7	1
lw	1F1FC	7	1
lx	1F1FD	7	1
ly	1F1FE	7	1
lz	1F1FF	7	1
na	1FC10	7	1
nb	1FC11	7	1
nc	1FC12	7	1
nd	1FC13	7	1
ne	1FC14	7	1
nf	1FC15	7	1
ng	1FC16	7	1
nh	1FC17	7	1
ni	1FC18	7	1
nj	1FC19	7	1
rc	1FC01	7	1
arz	1FC08	7	1
az	1FC09	7	1
ag	1FC0A	7	1
rodina	1FC0B	7	1
uf003	F003	8	1
uf004	F004	8	1
uf005	F005	8	1
uf006	F006	8	1
uf007	F007	8	1
uf008	F008	8	1
uf009	F009	8	1
uf00a	F00A	8	1
uf013	F013	8	1
uf030	F030	8	1
uf118	F118	8	1
uf11a	F11A	8	1
uf200	F200	9	2
uf201	F201	9	2
uf202	F202	9	2
uf203	F203	9	2
uf204	F204	9	2
uf205	F205	9	2
uf206	F206	9	2
uf207	F207	9	2
uf208	F208	9	2
uf209	F209	9	2
uf20a	F20A	9	2
uf20b	F20B	9	2
uf20c	F20C	9	2
uf20d	F20D	9	2
uf20e	F20E	9	2
uf20f	F20F	9	2
uf210	F210	9	2
uf211	F211	9	2
uf212	F212	9	2
uf213	F213	9	2
uf214	F214	9	2
uf215	F215	9	2
uf216	F216	9	2
uf217	F217	9	2
uf218	F218	9	2
uf219	F219	9	2
uf21a	F21A	9	2
uf21b	F21B	9	2
uf21c	F21C	9	2
uf21d	F21D	9	2
uf21e	F21E	9	2
uf21f	F21F	9	2
uf220	F220	9	2
uf221	F221	9	2
uf222	F222	9	2
uf223	F223	9	2
uf224	F224	9	2
uf225	F225	9	2
uf226	F226	9	2
uf227	F227	9	2
uf230	F230	9	3
uf231	F231	9	3
uf232	F232	9	3
uf233	F233	9	3
uf234	F234	9	3
uf235	F235	9	3
uf236	F236	9	3
uf237	F237	9	3
uf238	F238	9	3
uf239	F239	9	3
uf23a	F23A	9	3
uf23b	F23B	9	3
uf23c	F23C	9	4
uf240	F240	10	1
uf241	F241	10	1
uf242	F242	10	1
uf243	F243	10	1
uf244	F244	10	1
uf245	F245	10	1
uf246	F246	10	1
uf247	F247	10	1
uf248	F248	10	1
uf249	F249	10	1
uf24a	F24A	10	1
uf24b	F24B	10	1
uf24c	F24C	10	1
uf24d	F24D	10	1
uf24e	F24E	10	1
uf250	F250	10	2
uf251	F251	10	2
uf252	F252	10	2
uf253	F253	10	2
uf254	F254	10	2
uf255	F255	10	2
uf256	F256	10	2
uf257	F257	10	2
uf258	F258	10	2
uf259	F259	10	2
uf25a	F25A	10	1
uf25b	F25B	10	1
uf25d	F25D	11	1
uf25e	F25E	11	1
uf25f	F25F	11	1
uf260	F260	11	1
uf261	F261	11	2
vc	F264	11	1
k	F265	11	1
kk	F266	11	2
kkk	F267	11	1
kv	F268	11	1
kkv	F269	11	2
kkkv	F26A	11	1
uf26b	F26B	11	2
uf26c	F26C	11	1
uf270	F270	12	1
uf271	F271	12	1
uf272	F272	12	1
uf273	F273	12	1
uf274	F274	12	1
uf275	F275	12	1
uf276	F276	12	1
uf277	F277	12	1
uf278	F278	12	1
uf279	F279	12	1
uf27a	F27A	12	1
uf27b	F27B	12	1
uf27c	F27C	12	1
uf27d	F27D	12	1
uf27e	F27E	12	1
uf2fe	F2FE	12	1
uf2ff	F2FF	12	1
uf300	F300	13	1
uf301	F301	13	1
uf302	F302	13	1
uf303	F303	13	1
uf304	F304	13	1
uf305	F305	13	1
uf306	F306	13	1
uf307	F307	13	1
uf308	F308	13	1
uf309	F309	13	1
uf30a	F30A	13	1
uf30b	F30B	13	1
uf30c	F30C	13	1
uf30d	F30D	13	1
uf30e	F30E	13	1
uf30f	F30F	13	1
uf310	F310	13	1
uf311	F311	13	1
uf312	F312	13	1
uf313	F313	13	1
uf314	F314	13	1
uf315	F315	13	1
uf316	F316	13	1
uf317	F317	13	1
uf318	F318	13	1
uf319	F319	13	1
uf31a	F31A	13	1
uf31b	F31B	13	1
uf31c	F31C	13	1
uf31d	F31D	13	1
uf31e	F31E	13	1
uf31f	F31F	13	1
uf320	F320	13	1
uf321	F321	13	1
uf322	F322	13	1
uf323	F323	13	1
uf324	F324	13	1
uf325	F325	13	1
uf326	F326	13	1
uf327	F327	13	1
uf329	F329	13	1
uf32a	F32A	13	1
uf32b	F32B	13	1
uf32c	F32C	13	1
uf32d	F32D	13	1
uf32e	F32E	13	1
uf32f	F32F	13	1
uf330	F330	13	1
uf331	F331	13	1
uf332	F332	13	1
uf333	F333	13	1
uf334	F334	13	1
uf335	F335	13	1
uf336	F336	13	1
uf337	F337	13	1
uf338	F338	13	1
uf339	F339	13	1
uf33a	F33A	13	1
uf33b	F33B	13	1
uf33c	F33C	13	1
uf33d	F33D	13	1
uf33e	F33E	13	1
uf33f	F33F	13	1
uf340	F340	13	1
uf341	F341	13	1
redcode	1FC00	14	1
buy	1FC1A	14	2
sell	1FC1B	14	2
rent	1FC1C	14	2
trade	1FC1D	14	2
u1fc1e	1FC1E	14	1
u1fc1f	1FC1F	14	1
u1fc20	1FC20	14	1
u1fc21	1FC21	14	1
cash	1FC22	14	1
cashv	1FC23	14	2
asc	1FC24	14	1
btc	1FC25	14	1
euro	1FC26	14	1
info	1FC27	14	1
u1fc28	1FC28	14	4
u1fc29	1FC29	14	3
u1fc2a	1FC2A	14	3
u1fc2b	1FC2B	14	3
u1fc2c	1FC2C	14	3
u1fc2d	1FC2D	14	3
u1fc2e	1FC2E	14	2
u1fc2f	1FC2F	14	3
u1fc30	1FC30	14	3
u1fc31	1FC31	14	3
u1fc32	1FC32	14	3
u1fc33	1FC33	14	3
yt	1FC34	14	2
u1fc35	1FC35	14	2
u1fc36	1FC36	14	3
u1fc37	1FC37	14	3
u1fc38	1FC38	14	3
]==] end

-- Help_for_Job.lua
-- MonetLoader 3.8.x / MoonLoader
-- Help for Job (HfJ) - автоловля заказов + учёт зарплаты по работам + автообновление
-- v29.3.1 (HfJ Automotive Dashboard)

script_name('HfJ')
script_version('29.3.1')

local imgui    = require 'mimgui'
local new      = imgui.new
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local sampev = require 'samp.events'

local VERSION       = '29.3.1'
local LOCAL_VERSION = VERSION

-- ============================================================
--  АВТООПРЕДЕЛЕНИЕ КОДИРОВКИ ФАЙЛА
-- ============================================================
local CANARY = 'Такси'
local FILE_IS_UTF8 = (#CANARY > 5)

local function utf8ToCp1251(s)
    if not s or s == '' then return s end
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local b1 = s:byte(i)
        if (b1 == 0xD0 or b1 == 0xD1) and i < n then
            local b2 = s:byte(i + 1)
            if b1 == 0xD0 and b2 >= 0x90 and b2 <= 0xBF then
                out[#out + 1] = string.char(0xC0 + (b2 - 0x90)); i = i + 2
            elseif b1 == 0xD0 and b2 == 0x81 then
                out[#out + 1] = string.char(0xA8); i = i + 2
            elseif b1 == 0xD1 and b2 >= 0x80 and b2 <= 0x8F then
                out[#out + 1] = string.char(0xF0 + (b2 - 0x80)); i = i + 2
            elseif b1 == 0xD1 and b2 == 0x91 then
                out[#out + 1] = string.char(0xB8); i = i + 2
            else
                out[#out + 1] = string.char(b1); i = i + 1
            end
        else
            out[#out + 1] = string.char(b1); i = i + 1
        end
    end
    return table.concat(out)
end

local function L(s)
    if FILE_IS_UTF8 then return utf8ToCp1251(s) end
    return s
end

-- ============================================================
--  КОНСТАНТЫ
-- ============================================================
local MAX_TAPS              = 15
local TAP_STEP_MS           = 55
local ACCEPT_DELAY_MIN      = 40
local ACCEPT_DELAY_MAX      = 90
local TAP_COOLDOWN          = 400
local PENDING_TIMEOUT       = 15.0

local ORDER_PATTERNS = {
    L'поступил новый заказ',
    L'новый заказ',
    L'новый вызов',
    L'вам поступил заказ',
    L'поступил вызов',
    L'клиент ищет такси',
    L'вызывается такси',
    L'ищется такси',
}

-- ============================================================
--  ЛОКАЛЬНЫЕ ГЛОБАЛЬНЫЕ
-- ============================================================
local cfgDirty     = false
local lastAutoSave = 0
local FONT_LOGO    = nil
local FONT_SUB     = nil
local FONT_BIG     = nil
local FONT_HERO    = nil
local window       = new.bool(false)

local winPosInit = false

local windowAlpha     = 0
local tabFade         = 1
local tabSlide        = 0
local activeTab       = 1
local lastSelectedTab = 1
local navAnim         = { 1, 0, 0 }
local tileHover       = {}
local catchBtnAnim    = 0
local statDispOrders  = 0
local statDispMoney   = 0
local statDispTotal   = 0
local statInit        = false
local resetConfirmZp  = 0
local resetConfirmAll = 0

-- ============================================================
--  НОРМАЛИЗАЦИЯ СТРОК
-- ============================================================
local UPPER_CLASS  = '[' .. string.char(0xC0) .. '-' .. string.char(0xDE) .. ']'
local CP_YO_UPPER  = string.char(0xA8)
local CP_YO_LOWER  = string.char(0xB8)

local function normalize(s)
    if not s or s == '' then return '' end
    s = s:lower()
    s = s:gsub(UPPER_CLASS, function(c)
        return string.char(c:byte() + 0x20)
    end)
    s = s:gsub(CP_YO_UPPER, CP_YO_LOWER)
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    return s
end

-- ============================================================
--  ПУТИ И ЛОГ (С ОБРАБОТЧИКОМ ОШИБОК И ВРЕМЕНЕМ)
-- ============================================================
local WORK_DIR    = getWorkingDirectory()
local CONFIG_DIR  = WORK_DIR .. '/config'
local LOG_DIR     = WORK_DIR .. '/logs'
local CONFIG_FILE = CONFIG_DIR .. '/hfj.cfg'
local LEGACY_CONFIG_FILE = CONFIG_DIR .. '/taxord.cfg'
local LOG_FILE    = LOG_DIR .. '/hfj.log'

if not doesDirectoryExist(CONFIG_DIR) then pcall(createDirectory, CONFIG_DIR) end
if not doesDirectoryExist(LOG_DIR)    then pcall(createDirectory, LOG_DIR)    end

local function logRaw(tag, msg)
    local ms = 0
    if type(getTickCount) == 'function' then
        ms = getTickCount() % 1000
    else
        ms = math.floor((os.clock() % 1) * 1000)
    end
    local timeStr = os.date('%H:%M:%S.') .. string.format('%03d', ms)
    local line
    if msg == nil then
        line = string.format('%s | %s', timeStr, tostring(tag or ''))
    else
        line = string.format('%s | %-5s | %s', timeStr, tostring(tag or 'INFO'), tostring(msg))
    end

    print('[HfJ] ' .. line)

    local f = io.open(LOG_FILE, 'a')
    if f then
        f:write(u8(line) .. '\n')
        f:close()
    end
end

-- Очистка файла лога при первом запуске и дописывание при реконнекте
local function logInit(reason)
    local isInitial = (reason == nil)
    local mode = isInitial and 'w' or 'a'
    local f = io.open(LOG_FILE, mode)
    if f then
        if not isInitial then f:write('\n') end
        f:write('============================================================\n')
        f:write('=== Help for Job v' .. VERSION .. ' | ' .. os.date('%d.%m.%Y %H:%M:%S') .. ' ===\n')
        f:write('=== Сессия: ' .. tostring(reason or 'Запуск скрипта') .. '\n')
        f:write('============================================================\n')
        f:close()
    end
end

local function logChat(t) logRaw('CHAT',  t) end
local function logAct(t)  logRaw('ACT',   t) end
local function logDlg(t)  logRaw('DLG',   t) end
local function logErr(t)  logRaw('ERROR', t) end

-- ============================================================
--  КОНФИГ И СТАТИСТИКА
-- ============================================================
local CFG = {
    catchEnabled = true,
    autoAccept   = true,
    turboCatch   = false, -- Турбо-ловля (0 мс)
    ordersDone   = 0,
    moneyEarned  = 0,
}

local ZP = { taxi = 0, trucker = 0, collector = 0, deliverer = 0, mechanic = 0, bus = 0, garbage = 0 }
local zpLastX, zpLastY, zpLastZ = nil, nil, nil
local zpMovedDist = 0.0

local function markDirty() cfgDirty = true end

local function saveCfg()
    local f = io.open(CONFIG_FILE, 'w')
    if not f then return false end
    f:write('catchEnabled=' .. tostring(CFG.catchEnabled) .. '\n')
    f:write('autoAccept='   .. tostring(CFG.autoAccept)   .. '\n')
    f:write('turboCatch='   .. tostring(CFG.turboCatch)   .. '\n')
    f:write('ordersDone='   .. tostring(CFG.ordersDone)   .. '\n')
    f:write('moneyEarned='  .. tostring(CFG.moneyEarned)  .. '\n')
    f:write('zpTaxi='       .. tostring(math.floor(ZP.taxi))      .. '\n')
    f:write('zpTrucker='    .. tostring(math.floor(ZP.trucker))   .. '\n')
    f:write('zpCollector='  .. tostring(math.floor(ZP.collector)) .. '\n')
    f:write('zpDeliverer='  .. tostring(math.floor(ZP.deliverer)) .. '\n')
    f:write('zpMechanic='   .. tostring(math.floor(ZP.mechanic))  .. '\n')
    f:write('zpBus='        .. tostring(math.floor(ZP.bus))       .. '\n')
    f:write('zpGarbage='    .. tostring(math.floor(ZP.garbage))   .. '\n')
    f:close()
    cfgDirty = false
    return true
end

local function loadCfg()
    local f = io.open(CONFIG_FILE, 'r')
    if not f then f = io.open(LEGACY_CONFIG_FILE, 'r') end   -- стата из TaxOrd
    if not f then return end
    for line in f:lines() do
        local k, v = line:match('^([^=]+)=(.*)$')
        if k and v then
            local n = tonumber(v)
            if k == 'catchEnabled' then CFG.catchEnabled = (v == 'true') end
            if k == 'autoAccept'   then CFG.autoAccept   = (v == 'true') end
            if k == 'turboCatch'   then CFG.turboCatch   = (v == 'true') end
            if k == 'ordersDone'   and n then CFG.ordersDone  = n end
            if k == 'moneyEarned'  and n then CFG.moneyEarned = n end
            if k == 'zpTaxi'       and n then ZP.taxi         = n end
            if k == 'zpTrucker'    and n then ZP.trucker      = n end
            if k == 'zpCollector'  and n then ZP.collector    = n end
            if k == 'zpDeliverer'  and n then ZP.deliverer    = n end
            if k == 'zpMechanic'   and n then ZP.mechanic     = n end
            if k == 'zpBus'        and n then ZP.bus          = n end
            if k == 'zpGarbage'    and n then ZP.garbage      = n end
        end
    end
    f:close()
end

local function zpFormatMoney(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(n)
    local sign = ''
    if s:sub(1, 1) == '-' then
        sign = '-'
        s = s:sub(2)
    end
    local out = s:reverse():gsub('(%d%d%d)', '%1.'):reverse()
    if out:sub(1, 1) == '.' then out = out:sub(2) end
    return sign .. out
end

local function zpExtractMoney(text)
    if not text or text == '' then return nil end
    local raw = text:match('%$(%d[%d%.,]*)') or text:match('(%d[%d%.,]*)%$')
    if raw then
        local n = tonumber((raw:gsub('[%.,]', '')))
        if n and n > 0 then return n end
    end
    local maxVal = 0
    for match in text:gmatch('(%d[%d%.,]*)') do
        local cleaned = match:gsub('[%.,]', '')
        local n = tonumber(cleaned)
        if n and n > maxVal then maxVal = n end
    end
    return maxVal > 0 and maxVal or nil
end

local function zpDetectJob(textN)
    if textN:find(L'инкассатор', 1, true) then return 'collector' end
    if textN:find(L'развозчик', 1, true) then return 'deliverer' end

    -- Мусорщик (проверяем ДО дальнобойщика, чтобы "разгруженные" не совпало с "груз")
    if textN:find(L'мусор', 1, true)
       or textN:find(L'свалка', 1, true)
       or textN:find(L'контейнер', 1, true)
       or textN:find(L'разгружен', 1, true) then return 'garbage' end

    -- Водитель автобуса
    if textN:find(L'автобус', 1, true)
       or textN:find(L'водитель автобуса', 1, true)
       or textN:find(L'рабочий день завершен', 1, true) then return 'bus' end

    -- Механик
    if textN:find(L'механик', 1, true)
       or textN:find(L'автомастерская', 1, true)
       or textN:find(L'автосервис', 1, true)
       or textN:find(L'ремонт автомобил', 1, true)
       or textN:find(L'починил', 1, true)
       or textN:find(L'за ремонт', 1, true)
       or textN:find(L'выполненную работу', 1, true)
       or textN:find(L'масло', 1, true) then return 'mechanic' end

    -- Дальнобойщик
    if textN:find(L'дальнобой', 1, true)
       or textN:find(L'грузовик', 1, true)
       or textN:find(L'грузоперевоз', 1, true)
       or textN:find(L'гауз', 1, true)
       or textN:find(L'груз', 1, true)
       or textN:find(L'рейс', 1, true) then return 'trucker' end

    if textN:find(L'такси', 1, true)
       or textN:find(L'клиент оплатил', 1, true)
       or textN:find(L'проезд', 1, true) then return 'taxi' end
    return nil
end

local function zpIsPayout(textN)
    if textN:find(L'вы оплатили', 1, true)
       or textN:find(L'вы заплатили', 1, true)
       or textN:find(L'вы потратили', 1, true)
       or textN:find(L'списано', 1, true)
       or textN:find(L'снято', 1, true)
       or textN:find(L'починил ваш', 1, true)
       or textN:find(L'починила ваш', 1, true) then
        return false
    end

    if textN:find(L'клиент оплатил', 1, true) then return true end
    if textN:find(L'зарплата за рейс', 1, true) then return true end
    if textN:find(L'получено за обслуживание', 1, true) then return true end
    if textN:find(L'за обслуживание банкомата', 1, true) then return true end
    if textN:find(L'премия за доставку', 1, true) then return true end
    if textN:find(L'за ремонт', 1, true) then return true end
    if textN:find(L'починил', 1, true) then return true end
    if textN:find(L'оплата за ремонт', 1, true) then return true end
    if textN:find(L'груз успешно доставлен', 1, true) then return true end

    -- Для механика
    if textN:find(L'заработали', 1, true) and textN:find(L'за выполненную работу', 1, true) then return true end

    -- Для водителя автобуса
    if textN:find(L'рабочий день завершен', 1, true) then return true end
    if textN:find(L'вами заработано', 1, true) then return true end

    -- Для мусорщика
    if textN:find(L'за разгруженные контейнера', 1, true) then return true end
    if textN:find(L'выгрузил мусор', 1, true) then return true end

    return false
end

-- ============================================================
--  УВЕДОМЛЕНИЯ (БЫСТРЫЙ HUD-БАННЕР + АНТИ-СПАМ)
-- ============================================================
local NOTIFY_DURATION = 2.0
local NOTIFY_ANIM_IN  = 0.22
local NOTIFY_ANIM_OUT = 0.18

local function canShowNotify()
    local lock = _G.__notify_lock
    if not lock then return true end
    if lock.owner == 'hfj' then return true end
    if lock.expire <= os.clock() then return true end
    return false
end

local function acquireNotifyLock(dur)
    _G.__notify_lock = { owner = 'hfj',
        expire = os.clock() + (dur or NOTIFY_DURATION) + NOTIFY_ANIM_IN + NOTIFY_ANIM_OUT }
end

local sn = {
    queue   = {},
    message = '',
    icon    = 'info',
    timer   = 0,
    dur     = NOTIFY_DURATION,
    anim    = 0,
    state   = 'idle',
    version = 0,
}

local Easing = {
    outQuart = function(x) return 1 - (1 - x)^4 end,
    inBack   = function(x)
        local c1, c3 = 1.70158, 2.70158
        return c3 * x^3 - c1 * x^2
    end,
}

local function bringFloatTo(from, dest, t0, dur, ease, cb)
    local f = Easing[ease] or function(x) return x end
    local start = t0 or os.clock()
    if type(cb) == 'function' then
        lua_thread.create(function()
            while true do
                local t = os.clock() - start
                if t < 0 or t > dur then cb(dest); break end
                cb(from + (dest - from) * f(t / dur))
                wait(0)
            end
        end)
    end
end

local function iconFromColor(color)
    if color == 0x00FF00 or color == 0x00E5A3 or color == 0x00CCB3 then return 'success' end
    if color == 0xFFFF00 or color == 0xFFAA00 or color == 0xFF9F43 then return 'warn'    end
    if color == 0xFF0000 or color == 0xFF4757 then return 'error'   end
    return 'info'
end

local function notify(text, color)
    local msg = tostring(text)
    local ico = iconFromColor(color)
    logAct('NOTIFY: ' .. msg)
    sampAddChatMessage('{00CCB3}[HfJ] {FFFFFF}' .. msg, color or -1)

    -- Если уведомление активное и нажатия идут серией — мгновенно обновляем текущий баннер без очереди
    local now = os.clock()
    if sn.state == 'showing' and (now - sn.timer) < 1.0 then
        sn.message = msg
        sn.icon    = ico
        sn.timer   = now
        sn.dur     = NOTIFY_DURATION
        sn.queue   = {}
        acquireNotifyLock(NOTIFY_DURATION)
        return
    elseif sn.state == 'hiding' then
        sn.message = msg
        sn.icon    = ico
        sn.timer   = now
        sn.dur     = NOTIFY_DURATION
        sn.state   = 'showing'
        sn.version = sn.version + 1
        sn.queue   = {}
        acquireNotifyLock(NOTIFY_DURATION)
        local myv = sn.version
        bringFloatTo(sn.anim, 1, now, NOTIFY_ANIM_IN, 'outQuart', function(f)
            if sn.version == myv then sn.anim = f end
        end)
        return
    end

    -- Ограничиваем очередь до 2 актуальных сообщений, чтобы ничего не висело подолгу
    while #sn.queue >= 2 do table.remove(sn.queue, 1) end
    table.insert(sn.queue, { text = msg, icon = ico })
end

-- ============================================================
--  UPDATER
-- ============================================================
-- Имя файла ИМЕННО В РЕПОЗИТОРИИ (локально файл может называться иначе)
local SCRIPT_FILENAME = 'Help_for_Job.lua'
local GH_USER, GH_REPO, GH_BRANCH = 'hshajqk710-glitch', 'Help-for-Job', 'main'

local UPDATE_URL_VERSION = ('https://raw.githubusercontent.com/%s/%s/%s/version.txt')
    :format(GH_USER, GH_REPO, GH_BRANCH)
local UPDATE_URL_SCRIPT = ('https://raw.githubusercontent.com/%s/%s/%s/%s')
    :format(GH_USER, GH_REPO, GH_BRANCH, SCRIPT_FILENAME)

local UPDATE_DIALOG_ID   = 8889
local AUTO_CHECK_DELAY   = 12          -- сек после загрузки скрипта
local AUTO_CHECK_EVERY   = 30 * 60     -- сек между тихими проверками
local DOWNLOAD_TIMEOUT   = 25          -- сек на одну попытку загрузки
local MIN_SCRIPT_SIZE    = 20000       -- байт: защита от HTML/обрезки

local updateAvailable     = false
local updateDownloading   = false
local remoteVersion       = ''
local updaterStatus       = L'не проверялось'
local lastAutoCheck       = 0
local pendingUpdatePrompt = false
local promptRetryAt       = 0
local promptedVersion     = nil

local okMoon, moonlib = pcall(require, 'moonloader')
local DS_END = 6
if okMoon and moonlib and moonlib.download_status then
    DS_END = moonlib.download_status.STATUS_ENDDOWNLOADDATA
end

local okRequests, requestsLib = pcall(require, 'requests')
local okHttp,  http  = pcall(require, 'socket.http')
local okHttps, https = pcall(require, 'ssl.https')

local hasRawDownload = (downloadUrlToFile ~= nil)
local hasRequests    = (okRequests and requestsLib ~= nil)
local hasSecureHttp  = (okHttps and https ~= nil)

local canDownload = hasRawDownload or hasRequests or hasSecureHttp

local function updaterTransportsText()
    local list = {}
    if hasRawDownload then list[#list + 1] = 'downloadUrlToFile' end
    if hasRequests    then list[#list + 1] = 'requests' end
    if hasSecureHttp  then list[#list + 1] = 'ssl.https' end
    if okHttp and http then list[#list + 1] = 'socket.http' end
    if #list == 0 then return 'нет' end
    return table.concat(list, ', ')
end

local function urlNoCache(url)
    return url .. (url:find('?', 1, true) and '&' or '?') .. 'nocache=' .. tostring(os.time())
end

-- Сравнение версий по частям: "28.0.10" больше, чем "28.0.9"
local function verParts(s)
    local t = {}
    for p in tostring(s or ''):gmatch('%d+') do t[#t + 1] = tonumber(p) end
    return t
end

local function verLt(a, b)
    local pa, pb = verParts(a), verParts(b)
    if #pa == 0 or #pb == 0 then return false end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x < y then return true end
        if x > y then return false end
    end
    return false
end

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local content = f:read('*a')
    f:close()
    return content
end

local function writeFile(path, content)
    local f = io.open(path, 'wb')
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

local function socketRequestOnce(url)
    local body = {}
    local sink = function(chunk)
        if chunk then body[#body + 1] = chunk end
        return 1
    end

    local isHttps = url:match('^https') ~= nil
    local lib = isHttps and https or http
    if not lib then
        return nil, nil, isHttps and 'нет ssl.https' or 'нет socket.http'
    end

    local opts = { url = url, sink = sink, method = 'GET' }
    local ok, res, code, headers = pcall(lib.request, opts)

    if not ok then return nil, nil, tostring(res) end
    if res ~= 1 then return nil, nil, tostring(code or res or 'request failed') end

    if code == 200 then
        return table.concat(body), 200
    end

    local location = type(headers) == 'table' and headers.location or nil
    return nil, code, nil, location
end

local function socketFetch(url)
    local current = urlNoCache(url)
    for attempt = 1, 4 do
        local text, code, err, location = socketRequestOnce(current)
        if text then
            if text == '' then return nil, 'пустой ответ' end
            return text
        end
        if location and (code == 301 or code == 302 or code == 303 or code == 307) then
            if location:sub(1, 1) == '/' then
                local schemeHost = current:match('^(https?://[^/]+)')
                location = schemeHost and (schemeHost .. location) or location
            end
            current = location
        else
            return nil, err or ('HTTP ' .. tostring(code))
        end
    end
    return nil, 'слишком много редиректов'
end

local function rawFetch(url, timeout)
    local tmp = WORK_DIR .. '/hfj_upd_tmp.txt'
    os.remove(tmp)
    local finished = false
    local ok = pcall(downloadUrlToFile, urlNoCache(url), tmp, function(id, status)
        if status == DS_END then finished = true end
    end)
    if not ok then return nil, 'downloadUrlToFile недоступен' end
    local t0 = os.time()
    while not finished and (os.time() - t0) < (timeout or DOWNLOAD_TIMEOUT) do wait(0) end
    local content = finished and readFile(tmp) or nil
    os.remove(tmp)
    if not content or content == '' then return nil, 'таймаут downloadUrlToFile' end
    return content
end

local function requestsFetch(url)
    if not hasRequests then return nil, 'нет requests' end
    local ok, resp = pcall(requestsLib.request, 'GET', urlNoCache(url))
    if not ok or not resp then return nil, 'requests: ' .. tostring(resp) end
    local code = tonumber(resp.status_code) or 0
    if code ~= 200 then return nil, 'requests HTTP ' .. tostring(code) end
    local body = resp.text or resp.content
    if not body or body == '' then return nil, 'requests: пустой ответ' end
    return body
end

local function fetchText(url, timeout)
    local errors = {}

    if hasRawDownload then
        local body, err = rawFetch(url, timeout)
        if body then return body end
        errors[#errors + 1] = 'raw: ' .. tostring(err)
        logAct('Fetch fail (downloadUrlToFile): ' .. tostring(err))
    end
    if hasRequests then
        local body, err = requestsFetch(url)
        if body then return body end
        errors[#errors + 1] = 'requests: ' .. tostring(err)
        logAct('Fetch fail (requests): ' .. tostring(err))
    end
    if hasSecureHttp or (okHttp and http) then
        local body, err = socketFetch(url)
        if body then return body end
        errors[#errors + 1] = 'socket: ' .. tostring(err)
        logAct('Fetch fail (socket): ' .. tostring(err))
    end

    if #errors == 0 then return nil, 'нет транспорта' end
    return nil, table.concat(errors, ' | ')
end

local function applyVersionText(text)
    local raw = tostring(text or ''):gsub('^\239\187\191', '')
    if #raw > 200 then return 'err' end
    local cleaned = raw:gsub('%s+', '')
    local ver = cleaned:match('^v?(%d+%.%d+%.%d+)$')
    if not ver then return 'err' end
    remoteVersion = ver
    updateAvailable = verLt(LOCAL_VERSION, ver)
    return updateAvailable and 'new' or 'same'
end

local function scriptPath()
    local ok, info = pcall(thisScript)
    if ok and info then
        local okPath, path = pcall(function() return info.path end)
        if okPath and type(path) == 'string' and path ~= '' then return path end
    end
    return nil
end

local doCheck, doUpdate

-- Ставим флаг, а сам диалог показываем из главного цикла (безопасно для mimgui/samp)
local function promptUpdate()
    if not updateAvailable then return end
    if promptedVersion == remoteVersion then return end
    promptedVersion = remoteVersion
    pendingUpdatePrompt = true
end

doCheck = function(silent, thenDownload)
    if updateDownloading then return end
    if not canDownload then
        updaterStatus = L'нет http-транспорта'
        logAct('Updater: no transport')
        if not silent then
            notify(L'Скачивание недоступно на этой сборке', 0xFF0000)
        end
        return
    end

    updateDownloading = true
    updaterStatus = L'проверяю...'
    if not silent then notify(L'Проверяю наличие обновлений...', 0x00CCB3) end

    lua_thread.create(function()
        local ok, body, err = pcall(fetchText, UPDATE_URL_VERSION, 15)
        updateDownloading = false
        if not ok then body, err = nil, tostring(body) end

        if not body then
            updaterStatus = L'ошибка проверки'
            logErr('Update check failed: ' .. tostring(err))
            if not silent then notify(L'Не удалось проверить обновление', 0xFF0000) end
            return
        end

        local st = applyVersionText(body)
        if st == 'new' then
            updaterStatus = L'доступно v' .. remoteVersion
            logAct('Update available: v' .. remoteVersion .. ' (local v' .. LOCAL_VERSION .. ')')
            if not silent or promptedVersion ~= remoteVersion then
                notify(L'Доступно обновление: v' .. remoteVersion, 0xFFAA00)
            end
            if thenDownload then doUpdate() else promptUpdate() end
        elseif st == 'same' then
            updaterStatus = L'последняя версия'
            logAct('Check ok: up to date (v' .. LOCAL_VERSION .. ')')
            if not silent then notify(L'У вас последняя версия: v' .. LOCAL_VERSION, 0x00FF00) end
        else
            updaterStatus = L'неверный ответ'
            logAct('Check failed: version.txt = ' .. tostring(body):sub(1, 120))
            if not silent then notify(L'Не удалось проверить обновление', 0xFF0000) end
        end
    end)
end

doUpdate = function()
    if updateDownloading then
        notify(L'Уже идёт проверка или загрузка', 0x00CCB3)
        return
    end
    if not canDownload then
        notify(L'Скачивание недоступно на этой сборке', 0xFF0000)
        return
    end

    local dest = scriptPath()
    if not dest then
        updaterStatus = L'путь неизвестен'
        notify(L'Не удалось определить путь к скрипту', 0xFF0000)
        return
    end

    updateDownloading = true
    updaterStatus = L'скачиваю v' .. remoteVersion
    notify(L'Скачиваю обновление v' .. remoteVersion .. '...', 0x00CCB3)

    lua_thread.create(function()
        local ok, body, err = pcall(fetchText, UPDATE_URL_SCRIPT, DOWNLOAD_TIMEOUT)
        updateDownloading = false
        if not ok then body, err = nil, tostring(body) end

        if not body or body == '' then
            updaterStatus = L'ошибка загрузки'
            logErr('Update download failed: ' .. tostring(err))
            notify(L'Ошибка скачивания обновления', 0xFF0000)
            return
        end

        if #body < MIN_SCRIPT_SIZE then
            updaterStatus = L'файл повреждён'
            logAct('Download rejected: too small (' .. #body .. ' b)')
            notify(L'Скачался битый файл (' .. #body .. L' байт)', 0xFF0000)
            return
        end

        if not body:find('script_name', 1, true) then
            updaterStatus = L'это не скрипт'
            logAct('Download rejected: no script_name')
            notify(L'На GitHub лежит не скрипт', 0xFF0000)
            return
        end

        local dlVer = body:match("script_version%s*%(%s*['\"](%d+%.%d+%.%d+)['\"]")
        if dlVer and remoteVersion ~= '' and dlVer ~= remoteVersion then
            logAct('Warning: version.txt = ' .. remoteVersion .. ', file = ' .. dlVer)
        end

        local tmp = WORK_DIR .. '/hfj_update.lua'
        if not writeFile(tmp, body) then
            updaterStatus = L'ошибка записи'
            notify(L'Не удалось записать обновление', 0xFF0000)
            return
        end

        local backup = dest .. '.bak'
        local installed = false

        -- 1) штатная замена через rename (с бэкапом)
        os.remove(backup)
        if os.rename(dest, backup) then
            if os.rename(tmp, dest) then
                installed = true
            else
                os.rename(backup, dest)
                os.remove(tmp)
            end
        end

        -- 2) если rename не дал (Android/лок файла) - пробуем перезаписать напрямую
        if not installed then
            if writeFile(dest, body) then
                installed = true
            end
            os.remove(tmp)
        end

        -- 3) совсем не вышло - кладём рядом и просим заменить вручную
        if not installed then
            local alt = dest:gsub('%.lua$', '') .. '_new.lua'
            if writeFile(alt, body) then
                updaterStatus = L'нужна ручная замена'
                logAct('Install failed, saved to ' .. alt)
                notify(L'Файл занят. Новый сохранён: ' .. alt, 0xFFAA00)
            else
                updaterStatus = L'нет доступа к файлу'
                logAct('Install failed: cannot write ' .. tostring(dest))
                notify(L'Нет доступа к файлу скрипта', 0xFF0000)
            end
            return
        end

        updateAvailable   = false
        promptedVersion   = nil
        updaterStatus     = L'установлено v' .. (dlVer or remoteVersion)
        logAct('Update installed: v' .. tostring(dlVer or remoteVersion) .. ' -> ' .. tostring(dest))
        notify(L'Обновление установлено - перезапуск...', 0x00FF00)
        wait(1200)

        local okInfo, info = pcall(thisScript)
        if okInfo and info then
            local okReload = pcall(function() info:reload() end)
            if okReload then logAct('Script reloaded') end
        end
    end)
end

local function startUpdateCheck()
    logAct('Updater: transports = ' .. updaterTransportsText()
        .. ', local v' .. LOCAL_VERSION)
    if not canDownload then
        updaterStatus = L'нет http-транспорта'
        logAct('Updater: no transport, auto-check skipped')
        return
    end
    lastAutoCheck = os.time()
    lua_thread.create(function()
        wait(AUTO_CHECK_DELAY * 1000)
        if isSampAvailable() then doCheck(true) end
    end)
end

-- ============================================================
--  ТАП-ПАКЕТ
-- ============================================================
local function sendTapPacketWithIndex(index)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 0xDC)
    raknetBitStreamWriteInt8(bs, 0x3F)
    raknetBitStreamWriteInt8(bs, 0x2F)
    raknetBitStreamWriteInt8(bs, index)
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteInt8(bs, 0x10)
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteInt8(bs, 0)
    raknetSendBitStream(bs)
    raknetDeleteBitStream(bs)
end

-- ============================================================
--  УТИЛИТЫ И ОТЧЁТЫ
-- ============================================================
local function parseMoney(s)
    if not s then return 0 end
    local raw = s:match('%$(%d[%d%.,]*)') or s:match('(%d[%d%.,]*)%$')
    if not raw then return 0 end
    raw = raw:gsub('[%.,]', '')
    return tonumber(raw) or 0
end

local function stripColors(t)
    if not t then return '' end
    return (t:gsub('{%x%x%x%x%x%x}', ''):gsub('{%x%x%x%x%x%x%x%x}', ''))
end

local ZP_JOB_LIST = {
    { key = 'taxi',      label = L'Такси',               icon = 'taxi'      },
    { key = 'trucker',   label = L'Дальнобойщик',        icon = 'trucker'   },
    { key = 'collector', label = L'Инкассатор',          icon = 'collector' },
    { key = 'deliverer', label = L'Развозчик продуктов', icon = 'deliverer' },
    { key = 'mechanic',  label = L'Механик',             icon = 'mechanic'  },
    { key = 'bus',       label = L'Водитель автобуса',   icon = 'bus'       },
    { key = 'garbage',   label = L'Мусорщик',            icon = 'garbage'   },
}
local ZP_LABEL = {}
for _, j in ipairs(ZP_JOB_LIST) do ZP_LABEL[j.key] = j.label end
local ZP_DIALOG_ID = 8888

local function zpTotal()
    return ZP.taxi + ZP.trucker + ZP.collector + ZP.deliverer + ZP.mechanic + ZP.bus + ZP.garbage
end

local function zpReportText()
    local lines = {
        L'Автоловля заказов:',
        string.format(L'  Заказов выполнено: %d', CFG.ordersDone),
        string.format(L'  Заработано: $%s', zpFormatMoney(CFG.moneyEarned)),
        '',
        L'Выплаты по работам:',
        L'  Такси:             $' .. zpFormatMoney(ZP.taxi),
        L'  Дальнобойщик:      $' .. zpFormatMoney(ZP.trucker),
        L'  Инкассатор:        $' .. zpFormatMoney(ZP.collector),
        L'  Развозчик:         $' .. zpFormatMoney(ZP.deliverer),
        L'  Механик:           $' .. zpFormatMoney(ZP.mechanic),
        L'  Водитель автобуса: $' .. zpFormatMoney(ZP.bus),
        L'  Мусорщик:          $' .. zpFormatMoney(ZP.garbage),
        '',
        L'Всего по работам: $' .. zpFormatMoney(zpTotal()),
        '',
        L'/resetstat - сброс статистики',
    }
    return table.concat(lines, '\n')
end

local function resetAllStats()
    CFG.ordersDone  = 0
    CFG.moneyEarned = 0
    ZP.taxi, ZP.trucker, ZP.collector, ZP.deliverer, ZP.mechanic, ZP.bus, ZP.garbage = 0, 0, 0, 0, 0, 0, 0
    statDispOrders  = 0
    statDispMoney   = 0
    statDispTotal   = 0
    zpMovedDist     = 0.0
    zpLastX, zpLastY, zpLastZ = nil, nil, nil
    markDirty()
    saveCfg()
end

-- ============================================================
--  СОСТОЯНИЕ
-- ============================================================
local awaitingDialog        = false
local awaitingExpire        = 0
local lastTapTime           = -TAP_COOLDOWN * 1000
local hasActiveOrder        = false
local pendingAccept         = nil
local tapSequenceActive     = false
local tapSeqIndex           = 0
local tapSeqNextSend        = 0
local orderConfirmedByServer = false
local lastAcceptedDialogId   = nil
local lastAcceptedDialogStyle = nil
local lastAcceptAt           = 0

local function finishOrder(reason, count)
    if count == false then
        if not hasActiveOrder and not pendingAccept and not awaitingDialog and not tapSequenceActive then
            if reason == 'manual' then
                notify(L'Активный заказ или поиск отсутствует', 0xFFAA00)
            end
            return
        end
        hasActiveOrder         = false
        pendingAccept          = nil
        awaitingDialog         = false
        tapSequenceActive      = false
        orderConfirmedByServer = false
        lastAcceptedDialogId   = nil
        lastAcceptedDialogStyle = nil
        lastAcceptAt           = 0
        logAct('Order reset (not counted): ' .. tostring(reason))
        notify(L'Заказ сброшен: ' .. tostring(reason), 0xFFAA00)
    else
        if not hasActiveOrder then return end
        hasActiveOrder         = false
        pendingAccept          = nil
        awaitingDialog         = false
        tapSequenceActive      = false
        orderConfirmedByServer = false
        lastAcceptedDialogId   = nil
        lastAcceptedDialogStyle = nil
        lastAcceptAt           = 0
        CFG.ordersDone = CFG.ordersDone + 1
        markDirty()
        logAct('Order done: ' .. tostring(reason))
        notify(L'Заказ завершён. Счёт: ' .. CFG.ordersDone, 0x00FF00)
    end
end

local function resetCatchCycle(reason)
    tapSequenceActive = false
    awaitingDialog    = false
    logAct('Reset cycle: ' .. tostring(reason))
end

-- ============================================================
--  СОБЫТИЯ ЧАТА
-- ============================================================
local SERVER_TAG_PREFIXES = {
    'system', 'server', 'admin', 'event', 'info',
    'vote', 'bonus', 'helper', 'moder', 'log',
    'ahelp', 'report', 'pm', 'sms', 'radio',
}

local function isServerTag(prefix)
    prefix = prefix:lower()
    for _, tag in ipairs(SERVER_TAG_PREFIXES) do
        if prefix == tag then return true end
    end
    return false
end

local function isPlayerMessage(text)
    if not text or text == '' then return false end
    local clean = stripColors(text)
    if clean:find(L'говорит:', 1, true) then return true end
    if clean:find(L'шепчет:', 1, true) then return true end
    if clean:find(L'кричит:', 1, true) then return true end

    local prefix = clean:match('^%s*(%a+)_%a+:')
    if prefix and not isServerTag(prefix) then return true end

    local nick = clean:match('(%a+_%a+)%[%d+%]%s*:')
    if nick then
        local p = nick:match('^(%a+)_')
        if p and not isServerTag(p) then return true end
    end

    if clean:match('[%w_]+%[%d+%]%s*:') or clean:match('^%s*%[%d+%]%s*:') then
        return true
    end
    return false
end

function sampev.onServerMessage(color, text)
    local isPlayer = isPlayerMessage(text)
    local cleanRaw = stripColors(text)
    if not isPlayer then logChat(cleanRaw) end

    local cleanN = normalize(cleanRaw)

    -- При перезаходе / спавне добавляем новую секцию в лог
    if not isPlayer and (cleanN:find(L'добро пожаловать на arizona', 1, true)
       or cleanN:find(L'вы выбрали местом спавна', 1, true)) then
        logInit('Реконнект / Вход в игру')
    end

    if not isPlayer and zpIsPayout(cleanN) then
        local amount = zpExtractMoney(stripColors(text))
        local job    = zpDetectJob(cleanN)
        if amount and job then
            ZP[job] = ZP[job] + amount
            zpMovedDist = 0.0
            markDirty()
            logAct(string.format('Payout %s +%d (total %d)', job, amount, ZP[job]))
            notify(L'ЗП ' .. ZP_LABEL[job] .. ': +$' .. zpFormatMoney(amount) ..
                L' | Всего: $' .. zpFormatMoney(ZP[job]), 0x00FF00)
        end
    end

    if not isPlayer and cleanN:find(L'клиент оплатил', 1, true) then
        local cash = parseMoney(stripColors(text))
        if cash > 0 then
            CFG.moneyEarned = CFG.moneyEarned + cash
            markDirty()
            logAct('Money +' .. cash .. ' (total ' .. CFG.moneyEarned .. ')')
        end
    end

    -- Если заказ отменили или забрали до того, как мы доехали
    if not isPlayer and (cleanN:find(L'клиент отменил заказ', 1, true)
        or cleanN:find(L'заказ уже принят', 1, true)
        or cleanN:find(L'заказ недоступен', 1, true)
        or cleanN:find(L'заказ отмен', 1, true)) then
        if pendingAccept or hasActiveOrder or awaitingDialog then
            logAct('Order cancelled or taken by another player')
            hasActiveOrder         = false
            pendingAccept          = nil
            orderConfirmedByServer = false
            lastAcceptedDialogId   = nil
            lastAcceptedDialogStyle = nil
            lastAcceptAt           = 0
            resetCatchCycle('cancelled/taken')
            notify(L'Заказ отменен/перехвачен, жду новый...', 0xFFAA00)
            if type(sampSetCurrentDialogId) == 'function' then sampSetCurrentDialogId(-1) end
            return
        end
    end

    if not isPlayer and (cleanN:find(L'бонус таксиста', 1, true)
       or cleanN:find(L'метка на карте', 1, true)
       or cleanN:find(L'отправился к клиенту', 1, true)
       or cleanN:find(L'вы приняли заказ', 1, true)
       or cleanN:find(L'вы приняли вызов', 1, true)) then
        hasActiveOrder         = true
        orderConfirmedByServer = true
        pendingAccept          = nil
        awaitingDialog         = false
        tapSequenceActive      = false
        logAct('Order confirmed by server message')
        notify(L'Заказ принят! Метка на карте', 0x00FF00)
        return
    end

    if hasActiveOrder and not isPlayer then
        if cleanN:find(L'вы доставили клиента', 1, true)
           or cleanN:find(L'вы доставили клиента по имени', 1, true) then
            finishOrder(L'доставлен'); return
        end
        if cleanN:find(L'спасибо', 1, true) and cleanN:find(L'подкинул', 1, true) then
            finishOrder(L'спасибо'); return
        end
        if cleanN:find(L'клиент вышел', 1, true)
           or cleanN:find(L'вышел из такси', 1, true)
           or cleanN:find(L'поездка завершена', 1, true) then
            finishOrder(L'клиент вышел'); return
        end
        local cashRaw = cleanRaw:match('%+%s*(%d[%d%.,]*)%$') or cleanRaw:match('%+%s*%$(%d[%d%.,]*)')
        if cashRaw then
            local cash = tonumber((cashRaw:gsub('[%.,]', ''))) or 0
            finishOrder('+' .. cash .. '$'); return
        end
        if cleanN:find(L'вы прервали заказ', 1, true)
           or cleanN:find(L'вы закончили работу', 1, true) then
            finishOrder(L'прерван/закончен', false); return
        end
    end

    if CFG.catchEnabled
       and not isPlayer
       and not hasActiveOrder
       and not tapSequenceActive
       and not awaitingDialog
       and not pendingAccept then
        local matched = false
        for _, pat in ipairs(ORDER_PATTERNS) do
            if cleanN:find(pat, 1, true) then matched = true; break end
        end
        if matched then
            if (os.clock() * 1000) < lastTapTime + TAP_COOLDOWN then return end
            lastTapTime            = os.clock() * 1000
            awaitingDialog         = true
            awaitingExpire         = os.clock() + 6
            tapSequenceActive      = true
            tapSeqIndex            = 1
            pendingAccept          = os.clock()
            orderConfirmedByServer = false
            lastAcceptedDialogId   = nil
            lastAcceptedDialogStyle = nil
            lastAcceptAt           = 0
            sendTapPacketWithIndex(0)
            local stepMs = CFG.turboCatch and 0 or math.max(10, TAP_STEP_MS + math.random(-5, 15))
            tapSeqNextSend         = os.clock() + (stepMs / 1000)
            logAct('New order (chat) - queue scanning')
            notify(L'Новый заказ, ловлю (чат)...', 0x00CCB3)
        end
    end
end

-- ============================================================
--  СОБЫТИЯ ДИАЛОГОВ
-- ============================================================
local function sendAcceptDialogNow(id, style, isTwoStepConfirm)
    local delayMs = CFG.turboCatch and 0 or math.random(ACCEPT_DELAY_MIN, ACCEPT_DELAY_MAX)
    local function execute()
        sampSendDialogResponse(id, 1, 0, '')
        if type(sampGetCurrentDialogId) == 'function' and type(sampSetCurrentDialogId) == 'function' then
            local okId, curId = pcall(sampGetCurrentDialogId)
            if okId and curId == id then sampSetCurrentDialogId(-1) end
        end
        notify(L'Авто-приём заказа', 0x00FF00)
        logAct(string.format('Auto-accept id=%s style=%s delay=%dms (%s)',
            tostring(id), tostring(style), delayMs,
            isTwoStepConfirm and 'confirm-step' or 'instant'))
    end

    if delayMs > 0 then
        lua_thread.create(function()
            wait(delayMs)
            if not hasActiveOrder or not CFG.catchEnabled then
                logAct('Auto-accept aborted (cancelled during delay)')
                return
            end
            execute()
        end)
    else
        execute()
    end
end

function sampev.onShowDialog(id, style, title, b1, b2, text)
    logDlg(string.format('id=%s title=%q b1=%q b2=%q',
        tostring(id), tostring(title), tostring(b1), tostring(b2)))

    if tonumber(id) == ZP_DIALOG_ID then return end
    if tonumber(id) == UPDATE_DIALOG_ID then return end

    local titleN = normalize(stripColors(title or ''))
    local bodyN  = normalize(stripColors(text or ''))
    local b1N    = normalize(b1 or '')

    local isPayment = bodyN:find(':cash:', 1, true)
                   or bodyN:find(L'вознаграждение', 1, true)
    if isPayment then
        logAct('Payment dialog - NOT touched')
        return
    end

    local hasOrderBody = bodyN:find(L'заказ', 1, true)
                      or bodyN:find(L'вызов', 1, true)
                      or bodyN:find(L'такс', 1, true)
                      or bodyN:find(L'клиент', 1, true)
                      or bodyN:find(L'пассажир', 1, true)
                      or bodyN:find(L'маршрут', 1, true)
                      or bodyN:find(L'дистанц', 1, true)
                      or bodyN:find(L'расстоян', 1, true)
                      or bodyN:find(normalize(L'имя:'), 1, true)
                      or bodyN:find(normalize(L'класс авто:'), 1, true)
                      or bodyN:find(normalize(L'пункт назначения:'), 1, true)

    local isConfirmTitle = titleN:find(L'подтверждение', 1, true)
    local isPendingCatch = pendingAccept and (os.clock() - pendingAccept) < PENDING_TIMEOUT
    local isTwoStepConfirm = hasActiveOrder and not orderConfirmedByServer and isConfirmTitle
        and (os.clock() - lastAcceptAt) < 3.5
        and (id ~= lastAcceptedDialogId or lastAcceptedDialogStyle == 2 or lastAcceptedDialogStyle == 4 or lastAcceptedDialogStyle == 5)

    local isOrderDialog = (isConfirmTitle and (hasOrderBody or isPendingCatch or isTwoStepConfirm))
                       or (b1N:find(L'принять', 1, true) and hasOrderBody)

    if isOrderDialog and CFG.catchEnabled then
        if CFG.autoAccept and (isPendingCatch or isTwoStepConfirm) then
            hasActiveOrder         = true
            pendingAccept          = nil
            awaitingDialog         = false
            tapSequenceActive      = false
            lastAcceptedDialogId   = id
            lastAcceptedDialogStyle = style
            lastAcceptAt           = os.clock()

            sendAcceptDialogNow(id, style, isTwoStepConfirm)
            return false
        elseif CFG.autoAccept and (hasActiveOrder or ((os.clock() * 1000) - lastTapTime) < (PENDING_TIMEOUT * 1000 + 3000)) then
            logAct('Late order dialog - force closing...')
            sampSendDialogResponse(id, 0, 0, '')
            if type(sampGetCurrentDialogId) == 'function' and type(sampSetCurrentDialogId) == 'function' then
                local okId, curId = pcall(sampGetCurrentDialogId)
                if okId and curId == id then sampSetCurrentDialogId(-1) end
            end
            return false
        elseif not CFG.autoAccept and pendingAccept then
            awaitingDialog    = false
            tapSequenceActive = false
            logAct('Order dialog shown (manual accept)')
        end
    end

    local isOrderCancelled =
        bodyN:find(L'заказ уже принят', 1, true)
        or bodyN:find(L'заказ отмен', 1, true)
        or bodyN:find(L'клиент отменил', 1, true)

    local isAlreadyInOrder =
        bodyN:find(L'нельзя принять заказ', 1, true)
        or bodyN:find(L'уже выполняете', 1, true)

    if (isOrderCancelled or isAlreadyInOrder)
       and CFG.catchEnabled
       and (pendingAccept or tapSequenceActive or awaitingDialog or hasActiveOrder or ((os.clock() * 1000) - lastTapTime) < 6000) then
        if isOrderCancelled then
            hasActiveOrder         = false
            pendingAccept          = nil
            orderConfirmedByServer = false
            lastAcceptedDialogId   = nil
            lastAcceptedDialogStyle = nil
            resetCatchCycle('dialog error cancel')
        else
            hasActiveOrder         = true
            orderConfirmedByServer = true
            pendingAccept          = nil
            resetCatchCycle('already has order')
        end

        sampSendDialogResponse(id, 1, 0, '')
        if type(sampGetCurrentDialogId) == 'function' and type(sampSetCurrentDialogId) == 'function' then
            local okId, curId = pcall(sampGetCurrentDialogId)
            if okId and curId == id then sampSetCurrentDialogId(-1) end
        end
        return false
    end
end

-- ============================================================
--  UI: HFJ AUTOMOTIVE DASHBOARD (ПАЛИТРА, НЕОМОРФИЗМ, ИКОНКИ)
-- ============================================================
local UI_SCALE = 1.0
local function SC(v) return math.floor(v * UI_SCALE + 0.5) end

local THEME = {
    bg          = imgui.ImVec4(0.10, 0.11, 0.13, 1.00),   -- Глубокий графит (матовый, без стекла)
    barBg       = imgui.ImVec4(0.082, 0.090, 0.108, 1.00),-- Верхняя и нижняя панель
    card        = imgui.ImVec4(0.132, 0.145, 0.172, 1.00),-- Плотная матовая карточка
    cardDark    = imgui.ImVec4(0.088, 0.096, 0.116, 1.00),-- Вдавленный блок / трек
    tile        = imgui.ImVec4(0.150, 0.165, 0.195, 1.00),-- Интерактивная плитка
    tileHover   = imgui.ImVec4(0.178, 0.196, 0.232, 1.00),
    shadowDark  = imgui.ImVec4(0.032, 0.036, 0.046, 0.78),-- Неоморфная тень снизу-справа
    shadowLight = imgui.ImVec4(1.00, 1.00, 1.00, 0.048),  -- Мягкий верхний блик-грань
    accent      = imgui.ImVec4(0.00, 0.80, 0.70, 1.00),   -- Неоново-бирюзовый (Teal)
    accentBright= imgui.ImVec4(0.14, 0.92, 0.82, 1.00),
    accentDark  = imgui.ImVec4(0.00, 0.56, 0.50, 1.00),
    emerald     = imgui.ImVec4(0.12, 0.86, 0.54, 1.00),   -- Изумрудный статус
    text        = imgui.ImVec4(0.94, 0.96, 0.98, 1.00),
    dim         = imgui.ImVec4(0.55, 0.61, 0.69, 1.00),
    danger      = imgui.ImVec4(0.94, 0.34, 0.36, 1.00),
    warn        = imgui.ImVec4(0.98, 0.58, 0.22, 1.00),
}

local function C(v) return imgui.ColorConvertFloat4ToU32(v) end

local function CA(v, alphaMul)
    return imgui.ColorConvertFloat4ToU32(
        imgui.ImVec4(v.x, v.y, v.z, math.max(0, math.min(1, v.w * (alphaMul or 1.0)))))
end

local function LerpVec4(a, b, t)
    return imgui.ImVec4(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t,
        a.w + (b.w - a.w) * t
    )
end

-- Матовая неоморфная карточка с мягкой тенью и скруглением (без прозрачности)
local function DrawNeuBox(DL, x1, y1, x2, y2, r, bgCol, a, borderCol)
    -- Внешняя мягкая тень (2 слоя для плавности)
    DL:AddRectFilled(
        imgui.ImVec2(x1 + SC(4), y1 + SC(5)),
        imgui.ImVec2(x2 + SC(4), y2 + SC(6)),
        CA(THEME.shadowDark, 0.55 * a), r)
    DL:AddRectFilled(
        imgui.ImVec2(x1 + SC(2), y1 + SC(3)),
        imgui.ImVec2(x2 + SC(2), y2 + SC(3)),
        CA(THEME.shadowDark, 0.85 * a), r)
    -- Мягкий верхний левый неоморфный отсвет
    DL:AddRectFilled(
        imgui.ImVec2(x1 - SC(1), y1 - SC(1)),
        imgui.ImVec2(x2 - SC(1), y2 - SC(1)),
        CA(THEME.shadowLight, a), r)
    -- Основная матовая поверхность
    DL:AddRectFilled(
        imgui.ImVec2(x1, y1),
        imgui.ImVec2(x2, y2),
        CA(bgCol or THEME.card, a), r)
    -- Тонкий контур
    if borderCol then
        DL:AddRect(
            imgui.ImVec2(x1, y1),
            imgui.ImVec2(x2, y2),
            CA(borderCol, a), r, 0, SC(1.2))
    else
        DL:AddRect(
            imgui.ImVec2(x1, y1),
            imgui.ImVec2(x2, y2),
            C(imgui.ImVec4(1, 1, 1, 0.04 * a)), r, 0, SC(1))
    end
end

-- Векторные иконки (100% работают на любом Android/Windows шрифте без квадратов)
local function DrawVectorIcon(DL, kind, cx, cy, sz, col)
    local u32 = C(col)
    local lw  = math.max(SC(1.8), sz * 0.13)

    if kind == 'home' then
        local w = sz * 0.52
        local h = sz * 0.44
        DL:AddLine(imgui.ImVec2(cx - w * 1.05, cy - h * 0.05), imgui.ImVec2(cx, cy - h * 0.95), u32, lw)
        DL:AddLine(imgui.ImVec2(cx, cy - h * 0.95), imgui.ImVec2(cx + w * 1.05, cy - h * 0.05), u32, lw)
        DL:AddRect(imgui.ImVec2(cx - w * 0.72, cy - h * 0.15), imgui.ImVec2(cx + w * 0.72, cy + h * 0.85), u32, SC(2), 0, lw)
        DL:AddRectFilled(imgui.ImVec2(cx - w * 0.20, cy + h * 0.25), imgui.ImVec2(cx + w * 0.20, cy + h * 0.85), u32, SC(1))

    elseif kind == 'stats' then
        local bw = math.max(SC(3), sz * 0.20)
        local gap = sz * 0.14
        local base = cy + sz * 0.45
        DL:AddRectFilled(imgui.ImVec2(cx - bw * 1.5 - gap, base - sz * 0.46),
            imgui.ImVec2(cx - bw * 0.5 - gap, base), u32, SC(2))
        DL:AddRectFilled(imgui.ImVec2(cx - bw * 0.5, base - sz * 0.92),
            imgui.ImVec2(cx + bw * 0.5, base), u32, SC(2))
        DL:AddRectFilled(imgui.ImVec2(cx + bw * 0.5 + gap, base - sz * 0.66),
            imgui.ImVec2(cx + bw * 1.5 + gap, base), u32, SC(2))

    elseif kind == 'settings' then
        local rOut = sz * 0.38
        local rIn  = sz * 0.16
        DL:AddCircle(imgui.ImVec2(cx, cy), rOut, u32, 20, lw)
        DL:AddCircle(imgui.ImVec2(cx, cy), rIn, u32, 16, lw * 0.85)
        for i = 0, 5 do
            local ang = i * (math.pi / 3)
            local x1 = cx + math.cos(ang) * (rOut - SC(1))
            local y1 = cy + math.sin(ang) * (rOut - SC(1))
            local x2 = cx + math.cos(ang) * (rOut + sz * 0.15)
            local y2 = cy + math.sin(ang) * (rOut + sz * 0.15)
            DL:AddLine(imgui.ImVec2(x1, y1), imgui.ImVec2(x2, y2), u32, lw)
        end

    elseif kind == 'power' then
        local r = sz * 0.42
        DL:PathClear()
        DL:PathArcTo(imgui.ImVec2(cx, cy + sz * 0.04), r, math.rad(-52), math.rad(232), 28)
        DL:PathStroke(u32, false, lw * 1.25)
        DL:AddLine(imgui.ImVec2(cx, cy - r * 1.08), imgui.ImVec2(cx, cy + r * 0.05), u32, lw * 1.25)

    elseif kind == 'check' then
        DL:AddLine(imgui.ImVec2(cx - sz * 0.36, cy + sz * 0.02),
            imgui.ImVec2(cx - sz * 0.06, cy + sz * 0.32), u32, lw * 1.15)
        DL:AddLine(imgui.ImVec2(cx - sz * 0.06, cy + sz * 0.32),
            imgui.ImVec2(cx + sz * 0.40, cy - sz * 0.28), u32, lw * 1.15)

    elseif kind == 'bolt' then
        DL:AddTriangleFilled(
            imgui.ImVec2(cx + sz * 0.14, cy - sz * 0.48),
            imgui.ImVec2(cx - sz * 0.34, cy + sz * 0.06),
            imgui.ImVec2(cx + sz * 0.04, cy + sz * 0.06), u32)
        DL:AddTriangleFilled(
            imgui.ImVec2(cx - sz * 0.04, cy - sz * 0.04),
            imgui.ImVec2(cx + sz * 0.34, cy - sz * 0.04),
            imgui.ImVec2(cx - sz * 0.14, cy + sz * 0.48), u32)

    elseif kind == 'reset' then
        local r = sz * 0.34
        DL:PathClear()
        DL:PathArcTo(imgui.ImVec2(cx, cy), r, math.rad(-30), math.rad(250), 22)
        DL:PathStroke(u32, false, lw)
        DL:AddTriangleFilled(
            imgui.ImVec2(cx + r * 0.95, cy - r * 0.48),
            imgui.ImVec2(cx + r * 0.45, cy - r * 0.18),
            imgui.ImVec2(cx + r * 1.12, cy + r * 0.05), u32)

    elseif kind == 'spinner' then
        local r = sz * 0.38
        local t = os.clock() * 6.0
        DL:PathClear()
        DL:PathArcTo(imgui.ImVec2(cx, cy), r, t, t + math.rad(240), 24)
        DL:PathStroke(u32, false, lw * 1.1)

    elseif kind == 'taxi' then
        DL:AddRectFilled(imgui.ImVec2(cx - sz * 0.42, cy - sz * 0.05), imgui.ImVec2(cx + sz * 0.42, cy + sz * 0.28), u32, SC(3))
        DL:AddRectFilled(imgui.ImVec2(cx - sz * 0.26, cy - sz * 0.30), imgui.ImVec2(cx + sz * 0.26, cy - sz * 0.03), u32, SC(3))
        DL:AddCircleFilled(imgui.ImVec2(cx - sz * 0.24, cy + sz * 0.30), sz * 0.11, u32)
        DL:AddCircleFilled(imgui.ImVec2(cx + sz * 0.24, cy + sz * 0.30), sz * 0.11, u32)

    elseif kind == 'trucker' then
        DL:AddRectFilled(imgui.ImVec2(cx - sz * 0.45, cy - sz * 0.26), imgui.ImVec2(cx + sz * 0.12, cy + sz * 0.24), u32, SC(2))
        DL:AddRectFilled(imgui.ImVec2(cx + sz * 0.15, cy - sz * 0.14), imgui.ImVec2(cx + sz * 0.45, cy + sz * 0.24), u32, SC(2))
        DL:AddCircleFilled(imgui.ImVec2(cx - sz * 0.26, cy + sz * 0.28), sz * 0.10, u32)
        DL:AddCircleFilled(imgui.ImVec2(cx + sz * 0.28, cy + sz * 0.28), sz * 0.10, u32)

    elseif kind == 'collector' then
        DL:AddRect(imgui.ImVec2(cx - sz * 0.38, cy - sz * 0.22), imgui.ImVec2(cx + sz * 0.38, cy + sz * 0.32), u32, SC(3), 0, lw)
        DL:AddRect(imgui.ImVec2(cx - sz * 0.16, cy - sz * 0.38), imgui.ImVec2(cx + sz * 0.16, cy - sz * 0.22), u32, SC(2), 0, lw * 0.9)
        DL:AddCircleFilled(imgui.ImVec2(cx, cy + sz * 0.05), sz * 0.09, u32)

    elseif kind == 'deliverer' then
        DL:AddRect(imgui.ImVec2(cx - sz * 0.34, cy - sz * 0.32), imgui.ImVec2(cx + sz * 0.34, cy + sz * 0.34), u32, SC(2), 0, lw)
        DL:AddLine(imgui.ImVec2(cx - sz * 0.34, cy - sz * 0.06), imgui.ImVec2(cx + sz * 0.34, cy - sz * 0.06), u32, lw * 0.85)
        DL:AddLine(imgui.ImVec2(cx, cy - sz * 0.32), imgui.ImVec2(cx, cy - sz * 0.06), u32, lw * 0.85)

    elseif kind == 'mechanic' then
        DL:AddLine(imgui.ImVec2(cx - sz * 0.30, cy + sz * 0.30), imgui.ImVec2(cx + sz * 0.22, cy - sz * 0.22), u32, lw * 1.2)
        DL:AddCircle(imgui.ImVec2(cx + sz * 0.26, cy - sz * 0.26), sz * 0.16, u32, 12, lw)

    elseif kind == 'bus' then
        DL:AddRect(imgui.ImVec2(cx - sz * 0.32, cy - sz * 0.36), imgui.ImVec2(cx + sz * 0.32, cy + sz * 0.28), u32, SC(3), 0, lw)
        DL:AddLine(imgui.ImVec2(cx - sz * 0.32, cy + sz * 0.04), imgui.ImVec2(cx + sz * 0.32, cy + sz * 0.04), u32, lw * 0.85)
        DL:AddCircleFilled(imgui.ImVec2(cx - sz * 0.18, cy + sz * 0.32), sz * 0.08, u32)
        DL:AddCircleFilled(imgui.ImVec2(cx + sz * 0.18, cy + sz * 0.32), sz * 0.08, u32)

    elseif kind == 'garbage' then
        DL:AddRect(imgui.ImVec2(cx - sz * 0.28, cy - sz * 0.18), imgui.ImVec2(cx + sz * 0.28, cy + sz * 0.36), u32, SC(2), 0, lw)
        DL:AddLine(imgui.ImVec2(cx - sz * 0.36, cy - sz * 0.24), imgui.ImVec2(cx + sz * 0.36, cy - sz * 0.24), u32, lw)
        DL:AddLine(imgui.ImVec2(cx - sz * 0.10, cy - sz * 0.34), imgui.ImVec2(cx + sz * 0.10, cy - sz * 0.34), u32, lw)

    elseif kind == 'warn' then
        DL:AddLine(imgui.ImVec2(cx, cy - sz * 0.34), imgui.ImVec2(cx, cy + sz * 0.10), u32, lw * 1.15)
        DL:AddCircleFilled(imgui.ImVec2(cx, cy + sz * 0.30), math.max(SC(1.6), lw * 0.72), u32, 12)

    elseif kind == 'error' then
        local d = sz * 0.28
        DL:AddLine(imgui.ImVec2(cx - d, cy - d), imgui.ImVec2(cx + d, cy + d), u32, lw * 1.15)
        DL:AddLine(imgui.ImVec2(cx - d, cy + d), imgui.ImVec2(cx + d, cy - d), u32, lw * 1.15)

    elseif kind == 'info' then
        DL:AddCircleFilled(imgui.ImVec2(cx, cy - sz * 0.28), math.max(SC(1.6), lw * 0.72), u32, 12)
        DL:AddLine(imgui.ImVec2(cx, cy - sz * 0.06), imgui.ImVec2(cx, cy + sz * 0.34), u32, lw * 1.15)
    end
end

-- ============================================================
--  ЛОГОТИП В ШАПКЕ (ФИРМЕННЫЙ ГРАДИЕНТНЫЙ ЗНАЧОК + БРЕНД)
-- ============================================================
local function DrawHeaderLogo(DL, x, y, a)
    local badgeW, badgeH = SC(44), SC(40)
    local r = SC(12)
    local shimmer = 0.5 + 0.5 * math.sin(os.clock() * 2.1)

    -- Внешнее мягкое свечение и тень под значком
    DL:AddRectFilled(
        imgui.ImVec2(x + SC(2), y + SC(3)),
        imgui.ImVec2(x + badgeW + SC(2), y + badgeH + SC(3)),
        CA(THEME.shadowDark, 0.85 * a), r)
    DL:AddRectFilled(
        imgui.ImVec2(x - SC(2), y - SC(2)),
        imgui.ImVec2(x + badgeW + SC(2), y + badgeH + SC(2)),
        C(imgui.ImVec4(THEME.accent.x, THEME.accent.y, THEME.accent.z, (0.12 + 0.08 * shimmer) * a)), r + SC(2))

    -- Многослойный бирюзово-изумрудный градиент
    local botCol = LerpVec4(THEME.accentDark, imgui.ImVec4(0.05, 0.58, 0.44, 1.0), shimmer)
    local topCol = LerpVec4(THEME.accent, THEME.emerald, shimmer * 0.45)
    DL:AddRectFilled(
        imgui.ImVec2(x, y),
        imgui.ImVec2(x + badgeW, y + badgeH),
        CA(botCol, a), r)
    DL:AddRectFilled(
        imgui.ImVec2(x, y),
        imgui.ImVec2(x + badgeW, y + badgeH * 0.62),
        CA(topCol, a), r, 3)
    -- Верхний глянцевый отблик внутри рамки
    DL:AddRectFilled(
        imgui.ImVec2(x + SC(3), y + SC(2)),
        imgui.ImVec2(x + badgeW - SC(3), y + badgeH * 0.28),
        C(imgui.ImVec4(0.55, 1.00, 0.92, 0.34 * a)), r - SC(2), 3)
    -- Аккуратный внутренний светлый кант
    DL:AddRect(
        imgui.ImVec2(x, y),
        imgui.ImVec2(x + badgeW, y + badgeH),
        C(imgui.ImVec4(0.45, 1.00, 0.92, 0.48 * a)), r, 0, SC(1.2))

    -- Жирная монограмма HfJ по центру значка
    if FONT_BIG then imgui.PushFont(FONT_BIG) end
    local mark = 'HfJ'
    local ms = imgui.CalcTextSize(mark)
    DL:AddText(
        imgui.ImVec2(x + (badgeW - ms.x) / 2, y + (badgeH - ms.y) / 2),
        C(imgui.ImVec4(0.04, 0.07, 0.08, a)), mark)
    if FONT_BIG then imgui.PopFont() end

    -- Двухстрочное название бренда справа от эмблемы
    local tx = x + badgeW + SC(10)
    if FONT_SUB then imgui.PushFont(FONT_SUB) end
    local l1 = 'HELP FOR'
    local s1 = imgui.CalcTextSize(l1)
    DL:AddText(imgui.ImVec2(tx, y + SC(3)), CA(THEME.text, a), l1)
    DL:AddText(imgui.ImVec2(tx, y + SC(4) + s1.y), CA(THEME.accentBright, a), 'JOB')
    local jw = imgui.CalcTextSize('JOB').x
    DL:AddText(imgui.ImVec2(tx + jw + SC(6), y + SC(4) + s1.y),
        CA(THEME.dim, 0.75 * a), 'v' .. LOCAL_VERSION)
    if FONT_SUB then imgui.PopFont() end
end

-- ============================================================
--  ВКЛАДКА 1: ГЛАВНАЯ (ПЛАШКА АВТОЛОВЛИ + СТАТУС, ТУМБЛЕРЫ, СБРОС)
-- ============================================================
local function HomeTabFrame()
    local a     = imgui.GetStyle().Alpha
    local avail = imgui.GetContentRegionAvail()
    local w     = math.max(SC(220), avail.x)
    local DL    = imgui.GetWindowDrawList()

    -- Хелпер отрисовки понятного свитча-тумблера (ползунок слева/справа)
    local function DrawSwitchControl(id, x, y, swW, swH, state, onCol)
        local target = state and 1.0 or 0.0
        local cur = tileHover[id]
        if cur == nil then cur = target end
        cur = cur + (target - cur) * 0.25
        if math.abs(target - cur) < 0.005 then cur = target end
        tileHover[id] = cur

        local r = swH / 2
        local trackCol = LerpVec4(THEME.cardDark, onCol or THEME.accent, cur)
        DL:AddRectFilled(imgui.ImVec2(x, y + SC(1.5)), imgui.ImVec2(x + swW, y + swH + SC(1.5)),
            CA(THEME.shadowDark, 0.7 * a), r)
        DL:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + swW, y + swH), CA(trackCol, a), r)
        if cur < 0.5 then
            DL:AddRect(imgui.ImVec2(x, y), imgui.ImVec2(x + swW, y + swH),
                C(imgui.ImVec4(1, 1, 1, 0.10 * a)), r, 0, SC(1))
        end

        local knobR = r - SC(3.5)
        local knobX = x + r + cur * (swW - swH)
        local knobY = y + r
        DL:AddCircleFilled(imgui.ImVec2(knobX, knobY + SC(1.5)), knobR, CA(THEME.shadowDark, 0.65 * a), 24)
        DL:AddCircleFilled(imgui.ImVec2(knobX, knobY), knobR,
            C(imgui.ImVec4(0.96, 0.98, 0.99, a)), 24)
    end

    -- Текущее состояние ловли
    local stxt, scol
    if pendingAccept then
        stxt, scol = L'Ожидаем метку', THEME.accentBright
    elseif tapSequenceActive then
        stxt, scol = L'Перебор #' .. tapSeqIndex, THEME.accent
    elseif hasActiveOrder then
        stxt, scol = L'В заказе', THEME.emerald
    elseif awaitingDialog then
        stxt, scol = L'Ждём диалог', THEME.accent
    elseif CFG.catchEnabled then
        stxt, scol = L'Ожидание заказа', THEME.emerald
    else
        stxt, scol = L'Отключена', THEME.dim
    end

    -- 1) Главная горизонтальная плашка "Автоловля заказов" с живым зелёным переливом (или серая когда выкл)
    do
        local barH = SC(106)
        local p = imgui.GetCursorScreenPos()

        imgui.InvisibleButton('##hfj_main_catch_bar', imgui.ImVec2(w, barH))
        local clicked = imgui.IsItemClicked()
        local hovered = imgui.IsItemHovered()
        if clicked then
            CFG.catchEnabled = not CFG.catchEnabled
            markDirty()
            saveCfg()
            notify(CFG.catchEnabled and L'Автоловля включена' or L'Автоловля выключена',
                CFG.catchEnabled and 0x00FF00 or 0xFFAA00)
        end

        local targetAnim = CFG.catchEnabled and 1.0 or 0.0
        catchBtnAnim = catchBtnAnim + (targetAnim - catchBtnAnim) * 0.20
        if math.abs(targetAnim - catchBtnAnim) < 0.005 then catchBtnAnim = targetAnim end
        local on = catchBtnAnim

        local hv = tileHover['catch_bar'] or 0
        hv = hv + ((hovered and 1 or 0) - hv) * 0.24
        tileHover['catch_bar'] = hv

        local wave = 0.5 + 0.5 * math.sin(os.clock() * 2.3)

        -- Цвет выключенной плашки: нейтральный серый графит
        local offBg = LerpVec4(imgui.ImVec4(0.145, 0.155, 0.175, 1.0), imgui.ImVec4(0.175, 0.188, 0.210, 1.0), hv)
        -- Цвет включённой плашки: глубокий изумрудно-зелёный с плавным переливом
        local onBgBase = LerpVec4(
            imgui.ImVec4(0.065, 0.245, 0.175, 1.0),
            imgui.ImVec4(0.090, 0.320, 0.225, 1.0),
            wave * 0.75 + hv * 0.25)

        local bgCol = LerpVec4(offBg, onBgBase, on)
        local borderCol = LerpVec4(
            imgui.ImVec4(0.50, 0.54, 0.60, (0.20 + hv * 0.12)),
            LerpVec4(THEME.emerald, THEME.accentBright, wave * 0.55),
            on)
        borderCol.w = (0.25 + 0.55 * on)

        DrawNeuBox(DL, p.x, p.y, p.x + w, p.y + barH, SC(16), bgCol, a, borderCol)

        -- Плавный градиентный перелив внутри включённой плашки (со скруглением)
        if on > 0.02 then
            local topGrad = LerpVec4(
                imgui.ImVec4(0.10, 0.42, 0.28, 0.55),
                imgui.ImVec4(0.08, 0.48, 0.36, 0.65),
                wave)
            DL:AddRectFilled(
                imgui.ImVec2(p.x + SC(1), p.y + SC(1)),
                imgui.ImVec2(p.x + w - SC(1), p.y + barH * 0.56),
                CA(topGrad, on * a), SC(15), 3)

            -- Плывущая мягкая волна зелёного свечения слева направо
            local glowW = w * 0.52
            local gx = p.x + SC(8) + (w - glowW - SC(16)) * wave
            DL:AddRectFilled(
                imgui.ImVec2(gx, p.y + SC(4)),
                imgui.ImVec2(gx + glowW, p.y + barH - SC(4)),
                C(imgui.ImVec4(0.14, 0.88, 0.56, 0.13 * on * a)), SC(14))
        end

        -- Левая иконка питания
        local iconR = SC(24)
        local icx = p.x + SC(42)
        local icy = p.y + barH / 2
        local emeraldGlow = LerpVec4(THEME.emerald, THEME.accentBright, wave * 0.4)
        local iconBg = LerpVec4(imgui.ImVec4(0.20, 0.22, 0.25, 1.0), emeraldGlow, on)
        local iconFg = LerpVec4(THEME.dim, imgui.ImVec4(0.04, 0.09, 0.07, 1.0), on)
        if on > 0.05 then
            DL:AddCircleFilled(imgui.ImVec2(icx, icy), iconR + SC(5),
                C(imgui.ImVec4(THEME.emerald.x, THEME.emerald.y, THEME.emerald.z, 0.20 * on * a)), 32)
        end
        DL:AddCircleFilled(imgui.ImVec2(icx, icy), iconR, CA(iconBg, a), 32)
        DrawVectorIcon(DL, 'power', icx, icy, SC(24), imgui.ImVec4(iconFg.x, iconFg.y, iconFg.z, a))

        -- Текст слева: Заголовок и состояние ВКЛ / ВЫКЛ
        local tx = icx + iconR + SC(16)
        if FONT_BIG then imgui.PushFont(FONT_BIG) end
        DL:AddText(imgui.ImVec2(tx, p.y + SC(22)), CA(THEME.text, a), u8(L'Автоловля заказов'))
        if FONT_BIG then imgui.PopFont() end

        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        local stateLine = CFG.catchEnabled
            and u8(L'ВКЛЮЧЕНА  •  Нажмите, чтобы остановить')
            or  u8(L'ВЫКЛЮЧЕНА  •  Нажмите, чтобы запустить')
        local stateLineCol = LerpVec4(THEME.dim, imgui.ImVec4(0.55, 0.96, 0.76, 1.0), on)
        DL:AddText(imgui.ImVec2(tx, p.y + SC(58)), CA(stateLineCol, a), stateLine)

        -- Правая часть плашки: Тумблер ВКЛ/ВЫКЛ сверху (с зелёным переливом) + статус снизу
        local swW, swH = SC(58), SC(30)
        local swX = p.x + w - swW - SC(20)
        local swY = p.y + SC(18)
        DrawSwitchControl('sw_catch', swX, swY, swW, swH, CFG.catchEnabled, emeraldGlow)

        -- Чип текущего статуса под тумблером (внутри той же плашки справа)
        local pulse = (CFG.catchEnabled or hasActiveOrder) and (0.50 + 0.50 * math.sin(os.clock() * 4.0)) or 1.0
        local stU8 = u8(stxt)
        local sts = imgui.CalcTextSize(stU8)
        local chipH = SC(30)
        local chipW = sts.x + SC(34)
        local chipX = p.x + w - chipW - SC(20)
        local chipY = p.y + barH - chipH - SC(16)

        DL:AddRectFilled(imgui.ImVec2(chipX, chipY), imgui.ImVec2(chipX + chipW, chipY + chipH),
            CA(THEME.cardDark, 0.92 * a), chipH / 2)
        DL:AddRect(imgui.ImVec2(chipX, chipY), imgui.ImVec2(chipX + chipW, chipY + chipH),
            C(imgui.ImVec4(scol.x, scol.y, scol.z, 0.50 * a)), chipH / 2, 0, SC(1))
        DL:AddCircleFilled(imgui.ImVec2(chipX + SC(14), chipY + chipH / 2), SC(4.5),
            C(imgui.ImVec4(scol.x, scol.y, scol.z, pulse * a)), 16)
        DL:AddText(imgui.ImVec2(chipX + SC(25), chipY + (chipH - sts.y) / 2),
            CA(THEME.text, a), stU8)

        if FONT_SUB then imgui.PopFont() end

        imgui.Dummy(imgui.ImVec2(0, SC(10)))
    end

    -- 2) Настоящие переключатели-тумблеры (строки с визуальным свитчем справа)
    local function DrawSwitchCard(id, iconKind, title, subtitle, state, onCol)
        local rowH = SC(76)
        local p = imgui.GetCursorScreenPos()

        imgui.InvisibleButton('##hfj_swcard_' .. id, imgui.ImVec2(w, rowH))
        local clicked = imgui.IsItemClicked()
        local hovered = imgui.IsItemHovered()

        local hv = tileHover['hov_' .. id] or 0
        hv = hv + ((hovered and 1 or 0) - hv) * 0.24
        tileHover['hov_' .. id] = hv

        local ac = onCol or THEME.accent
        local bg = state
            and LerpVec4(THEME.card, THEME.tileHover, hv * 0.5)
            or  LerpVec4(THEME.card, THEME.tile, hv)
        local border = state
            and imgui.ImVec4(ac.x, ac.y, ac.z, 0.42)
            or  imgui.ImVec4(1, 1, 1, 0.05 + hv * 0.05)

        DrawNeuBox(DL, p.x, p.y, p.x + w, p.y + rowH, SC(15), bg, a, border)

        local icx = p.x + SC(34)
        local icy = p.y + rowH / 2
        local iconCol = state and ac or THEME.dim
        DL:AddCircleFilled(imgui.ImVec2(icx, icy), SC(18),
            C(imgui.ImVec4(iconCol.x, iconCol.y, iconCol.z, (state and 0.16 or 0.08) * a)), 24)
        DrawVectorIcon(DL, iconKind, icx, icy, SC(18),
            imgui.ImVec4(iconCol.x, iconCol.y, iconCol.z, a))

        local tx = icx + SC(30)
        DL:AddText(imgui.ImVec2(tx, p.y + SC(16)), CA(THEME.text, a), title)
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        DL:AddText(imgui.ImVec2(tx, p.y + SC(42)), CA(THEME.dim, a), subtitle)

        -- Справа: свитч-тумблер и подпись ВКЛ/ВЫКЛ
        local swW, swH = SC(52), SC(28)
        local swX = p.x + w - swW - SC(18)
        local swY = p.y + (rowH - swH) / 2
        DrawSwitchControl('sw_' .. id, swX, swY, swW, swH, state, ac)

        local stTxt = state and u8(L'ВКЛ') or u8(L'ВЫКЛ')
        local sts = imgui.CalcTextSize(stTxt)
        DL:AddText(imgui.ImVec2(swX - sts.x - SC(12), p.y + (rowH - sts.y) / 2),
            CA(state and ac or THEME.dim, a), stTxt)
        if FONT_SUB then imgui.PopFont() end

        return clicked
    end

    local acceptSub = CFG.turboCatch
        and u8(L'Подтверждает диалог мгновенно (0 мс — активен Турбо)')
        or  u8(L'Автоматически подтверждает заказ (пауза 40-90 мс)')
    if DrawSwitchCard('accept', 'check', u8(L'Авто-принять заказ'), acceptSub, CFG.autoAccept, THEME.accent) then
        CFG.autoAccept = not CFG.autoAccept
        markDirty()
    end
    imgui.Dummy(imgui.ImVec2(0, SC(8)))

    if DrawSwitchCard('turbo', 'bolt', u8(L'Турбо-режим (0 мс)'),
        u8(L'Отключает анти-бот задержки для максимальной скорости'), CFG.turboCatch, THEME.warn) then
        CFG.turboCatch = not CFG.turboCatch
        markDirty()
        if CFG.turboCatch then
            notify(L'Внимание: Турбо-ловля включена (0 мс)!', 0xFF0000)
        end
    end
    imgui.Dummy(imgui.ImVec2(0, SC(8)))

    -- Предупреждение о Турбо-режиме (если включён)
    if CFG.turboCatch then
        local warnH = SC(38)
        local p = imgui.GetCursorScreenPos()
        DrawNeuBox(DL, p.x, p.y, p.x + w, p.y + warnH, SC(12),
            imgui.ImVec4(0.19, 0.12, 0.13, 1.0), a,
            imgui.ImVec4(THEME.danger.x, THEME.danger.y, THEME.danger.z, 0.45))
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        local wt = u8(L'Задержка 0 мс активна: мгновенный ответ повышает риск бана!')
        local wts = imgui.CalcTextSize(wt)
        DL:AddText(imgui.ImVec2(p.x + SC(16), p.y + (warnH - wts.y) / 2), CA(THEME.danger, a), wt)
        if FONT_SUB then imgui.PopFont() end
        imgui.Dummy(imgui.ImVec2(w, warnH))
        imgui.Dummy(imgui.ImVec2(0, SC(8)))
    end

    -- 3) Нижний блок: Сводка заказов + отдельная чёткая кнопка "Сбросить заказ"
    do
        local rowH = SC(66)
        local gap  = SC(12)
        local leftW = math.floor((w - gap) * 0.56)
        local rightW = w - gap - leftW
        local p = imgui.GetCursorScreenPos()

        -- Левая карточка: быстрая сводка
        DrawNeuBox(DL, p.x, p.y, p.x + leftW, p.y + rowH, SC(14), THEME.card, a)
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        DL:AddText(imgui.ImVec2(p.x + SC(16), p.y + SC(13)), CA(THEME.dim, a), u8(L'Выполнено заказов'))
        DL:AddText(imgui.ImVec2(p.x + SC(16), p.y + SC(37)), CA(THEME.dim, a), u8(L'Оплата такси (чат)'))

        local ordVal = tostring(CFG.ordersDone)
        local ovs = imgui.CalcTextSize(ordVal)
        DL:AddText(imgui.ImVec2(p.x + leftW - ovs.x - SC(16), p.y + SC(13)), CA(THEME.accentBright, a), ordVal)

        local mVal = '$' .. zpFormatMoney(CFG.moneyEarned)
        local mvs = imgui.CalcTextSize(mVal)
        DL:AddText(imgui.ImVec2(p.x + leftW - mvs.x - SC(16), p.y + SC(37)), CA(THEME.text, a), mVal)
        if FONT_SUB then imgui.PopFont() end

        -- Правая кнопка действия: Сбросить заказ (без тумблера!)
        local bx = p.x + leftW + gap
        imgui.SetCursorScreenPos(imgui.ImVec2(bx, p.y))
        imgui.InvisibleButton('##hfj_reset_order_btn', imgui.ImVec2(rightW, rowH))
        local clicked = imgui.IsItemClicked()
        local hovered = imgui.IsItemHovered()
        if clicked then finishOrder('manual', false) end

        local hv = tileHover['reset_btn'] or 0
        hv = hv + ((hovered and 1 or 0) - hv) * 0.24
        tileHover['reset_btn'] = hv

        local hasAnyOrder = (hasActiveOrder or pendingAccept ~= nil or awaitingDialog or tapSequenceActive)
        local btnBg = hasAnyOrder
            and LerpVec4(imgui.ImVec4(0.24, 0.13, 0.15, 1.0), imgui.ImVec4(0.32, 0.15, 0.17, 1.0), hv)
            or  LerpVec4(THEME.tile, THEME.tileHover, hv)
        local btnBorder = hasAnyOrder
            and imgui.ImVec4(THEME.danger.x, THEME.danger.y, THEME.danger.z, 0.55)
            or  imgui.ImVec4(1, 1, 1, 0.06 + hv * 0.06)

        DrawNeuBox(DL, bx, p.y, bx + rightW, p.y + rowH, SC(14), btnBg, a, btnBorder)

        local btnTxt = u8(L'Сбросить заказ')
        local bts = imgui.CalcTextSize(btnTxt)
        local totalBtnW = SC(22) + SC(8) + bts.x
        local startX = bx + (rightW - totalBtnW) / 2
        local btnCol = hasAnyOrder and THEME.danger or THEME.text
        DrawVectorIcon(DL, 'reset', startX + SC(10), p.y + rowH / 2, SC(18),
            imgui.ImVec4(btnCol.x, btnCol.y, btnCol.z, a))
        DL:AddText(imgui.ImVec2(startX + SC(26), p.y + (rowH - bts.y) / 2), CA(btnCol, a), btnTxt)
    end

    imgui.Dummy(imgui.ImVec2(0, SC(10)))
end

-- ============================================================
--  ВКЛАДКА 2: СТАТИСТИКА (КРУПНЫЙ ИТОГ + ПРОГРЕСС-БАРЫ + СБРОС ВНИЗУ)
-- ============================================================
local function StatsTabFrame()
    local a     = imgui.GetStyle().Alpha
    local avail = imgui.GetContentRegionAvail()
    local w     = math.max(SC(220), avail.x)
    local totalZp = zpTotal()

    if not statInit then
        statDispOrders = CFG.ordersDone
        statDispMoney  = CFG.moneyEarned
        statDispTotal  = totalZp
        statInit = true
    end
    statDispOrders = statDispOrders + (CFG.ordersDone - statDispOrders) * 0.16
    statDispMoney  = statDispMoney  + (CFG.moneyEarned - statDispMoney)  * 0.16
    statDispTotal  = statDispTotal  + (totalZp - statDispTotal)          * 0.16
    if math.abs(statDispOrders - CFG.ordersDone) < 0.01 then statDispOrders = CFG.ordersDone end
    if math.abs(statDispMoney  - CFG.moneyEarned) < 0.5 then statDispMoney  = CFG.moneyEarned end
    if math.abs(statDispTotal  - totalZp) < 0.5 then statDispTotal = totalZp end

    -- 1) Крупная цифра заработанного
    do
        local cardH = SC(116)
        local p = imgui.GetCursorScreenPos()
        local DL = imgui.GetWindowDrawList()

        DrawNeuBox(DL, p.x, p.y, p.x + w, p.y + cardH, SC(16), THEME.card, a,
            imgui.ImVec4(THEME.accent.x, THEME.accent.y, THEME.accent.z, 0.25))

        -- Левая половина: крупная цифра заработка по работам
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        DL:AddText(imgui.ImVec2(p.x + SC(20), p.y + SC(16)), CA(THEME.dim, a), u8(L'Заработано по работам'))
        if FONT_SUB then imgui.PopFont() end

        if FONT_HERO then imgui.PushFont(FONT_HERO) elseif FONT_BIG then imgui.PushFont(FONT_BIG) end
        DL:AddText(imgui.ImVec2(p.x + SC(20), p.y + SC(42)), CA(THEME.accentBright, a),
            '$' .. zpFormatMoney(statDispTotal + 0.5))
        if FONT_HERO or FONT_BIG then imgui.PopFont() end

        -- Правая сторона: заказы и оплата такси
        local rx = p.x + w - SC(18)
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        local tOrd = u8(L'Заказов: ') .. tostring(math.floor(statDispOrders + 0.5))
        local ots = imgui.CalcTextSize(tOrd)
        DL:AddText(imgui.ImVec2(rx - ots.x, p.y + SC(26)), CA(THEME.text, a), tOrd)

        local tTax = u8(L'Такси (чат): $') .. zpFormatMoney(statDispMoney + 0.5)
        local tts = imgui.CalcTextSize(tTax)
        DL:AddText(imgui.ImVec2(rx - tts.x, p.y + SC(56)), CA(THEME.dim, a), tTax)
        if FONT_SUB then imgui.PopFont() end

        imgui.Dummy(imgui.ImVec2(w, cardH))
        imgui.Dummy(imgui.ImVec2(0, SC(12)))
    end

    -- 2) Крупный заработок по каждой профессии (без прогресс-баров и процентов)
    do
        local rowH = SC(58)
        for i, job in ipairs(ZP_JOB_LIST) do
            local val = ZP[job.key] or 0
            local p = imgui.GetCursorScreenPos()
            local DL = imgui.GetWindowDrawList()

            DrawNeuBox(DL, p.x, p.y, p.x + w, p.y + rowH, SC(14), THEME.card, a)

            -- Иконка профессии в круглом неоморфном значке
            local iconCol = val > 0 and THEME.accentBright or THEME.dim
            local icx, icy = p.x + SC(30), p.y + rowH / 2
            DL:AddCircleFilled(imgui.ImVec2(icx, icy), SC(16),
                C(imgui.ImVec4(iconCol.x, iconCol.y, iconCol.z, (val > 0 and 0.14 or 0.06) * a)), 22)
            DrawVectorIcon(DL, job.icon, icx, icy, SC(18),
                imgui.ImVec4(iconCol.x, iconCol.y, iconCol.z, a))

            -- Название работы слева
            local nameTxt = u8(job.label)
            local nts = imgui.CalcTextSize(nameTxt)
            DL:AddText(imgui.ImVec2(p.x + SC(58), p.y + (rowH - nts.y) / 2),
                CA(THEME.text, a), nameTxt)

            -- Крупная цифра заработка справа
            local valTxt = '$' .. zpFormatMoney(val)
            if FONT_BIG then imgui.PushFont(FONT_BIG) end
            local vts = imgui.CalcTextSize(valTxt)
            DL:AddText(imgui.ImVec2(p.x + w - vts.x - SC(18), p.y + (rowH - vts.y) / 2),
                CA(val > 0 and THEME.accentBright or THEME.dim, a), valTxt)
            if FONT_BIG then imgui.PopFont() end

            imgui.Dummy(imgui.ImVec2(w, rowH))
            if i < #ZP_JOB_LIST then imgui.Dummy(imgui.ImVec2(0, SC(8))) end
        end
    end

    -- 3) Кнопка сброса статистики спрятана в самый низ (с защитным подтверждением)
    imgui.Dummy(imgui.ImVec2(0, SC(24)))
    do
        local now = os.clock()
        if resetConfirmZp > 0 and now > resetConfirmZp then resetConfirmZp = 0 end
        if resetConfirmAll > 0 and now > resetConfirmAll then resetConfirmAll = 0 end

        local gap = SC(12)
        local halfW = (w - gap) / 2
        local p = imgui.GetCursorScreenPos()

        imgui.SetCursorScreenPos(p)
        imgui.BeginGroup()
        imgui.PushItemWidth(halfW)
        local lblZp = resetConfirmZp > 0 and u8(L'Подтвердить сброс ЗП?') or u8(L'Сбросить только ЗП')
        local pBtn1 = imgui.GetCursorScreenPos()
        local DL = imgui.GetWindowDrawList()
        imgui.InvisibleButton('##hfj_reset_zp', imgui.ImVec2(halfW, SC(44)))
        if imgui.IsItemClicked() then
            if resetConfirmZp > 0 then
                ZP.taxi, ZP.trucker, ZP.collector, ZP.deliverer, ZP.mechanic, ZP.bus, ZP.garbage = 0, 0, 0, 0, 0, 0, 0
                statDispTotal = 0
                resetConfirmZp = 0
                markDirty(); saveCfg()
                notify(L'Счётчик ЗП сброшен')
            else
                resetConfirmZp = now + 4.0
            end
        end
        local hov1 = imgui.IsItemHovered()
        DrawNeuBox(DL, pBtn1.x, pBtn1.y, pBtn1.x + halfW, pBtn1.y + SC(44), SC(12),
            resetConfirmZp > 0 and imgui.ImVec4(0.26, 0.14, 0.16, 1.0) or (hov1 and THEME.tileHover or THEME.cardDark),
            a, resetConfirmZp > 0 and THEME.danger or nil)
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        local ts1 = imgui.CalcTextSize(lblZp)
        DL:AddText(imgui.ImVec2(pBtn1.x + (halfW - ts1.x) / 2, pBtn1.y + (SC(44) - ts1.y) / 2),
            CA(resetConfirmZp > 0 and THEME.danger or THEME.dim, a), lblZp)
        if FONT_SUB then imgui.PopFont() end
        imgui.PopItemWidth()
        imgui.EndGroup()

        imgui.SetCursorScreenPos(imgui.ImVec2(p.x + halfW + gap, p.y))
        local lblAll = resetConfirmAll > 0 and u8(L'Нажмите снова для сброса!') or u8(L'Сбросить всю статистику')
        local pBtn2 = imgui.GetCursorScreenPos()
        imgui.InvisibleButton('##hfj_reset_all', imgui.ImVec2(halfW, SC(44)))
        if imgui.IsItemClicked() then
            if resetConfirmAll > 0 then
                resetAllStats()
                resetConfirmAll = 0
                notify(L'Вся статистика сброшена')
            else
                resetConfirmAll = now + 4.0
            end
        end
        local hov2 = imgui.IsItemHovered()
        DrawNeuBox(DL, pBtn2.x, pBtn2.y, pBtn2.x + halfW, pBtn2.y + SC(44), SC(12),
            resetConfirmAll > 0 and imgui.ImVec4(0.28, 0.12, 0.14, 1.0) or (hov2 and THEME.tileHover or THEME.cardDark),
            a, resetConfirmAll > 0 and THEME.danger or nil)
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        local ts2 = imgui.CalcTextSize(lblAll)
        DL:AddText(imgui.ImVec2(pBtn2.x + (halfW - ts2.x) / 2, pBtn2.y + (SC(44) - ts2.y) / 2),
            CA(resetConfirmAll > 0 and THEME.danger or THEME.dim, a), lblAll)
        if FONT_SUB then imgui.PopFont() end
    end

    imgui.Dummy(imgui.ImVec2(0, SC(14)))
end

-- ============================================================
--  ВКЛАДКА 3: НАСТРОЙКИ (2 БЛОКА: ОБНОВЛЕНИЯ/ВЕРСИЯ + КОМАНДЫ/БЕЗОПАСНОСТЬ)
-- ============================================================
local function SettingsTabFrame()
    local a     = imgui.GetStyle().Alpha
    local avail = imgui.GetContentRegionAvail()
    local w     = math.max(SC(220), avail.x)

    -- 1) БЛОК 1 (ОСНОВНОЙ): Профиль скрипта, установленная версия и обновления
    do
        local cardH = SC(156)
        local p = imgui.GetCursorScreenPos()
        local DL = imgui.GetWindowDrawList()

        -- Выделенная карточка с бирюзовой рамкой и верхним акцентом
        DrawNeuBox(DL, p.x, p.y, p.x + w, p.y + cardH, SC(16), THEME.card, a,
            imgui.ImVec4(THEME.accent.x, THEME.accent.y, THEME.accent.z, updateAvailable and 0.65 or 0.35))
        DL:AddRectFilled(
            imgui.ImVec2(p.x + SC(18), p.y + SC(1)),
            imgui.ImVec2(p.x + w - SC(18), p.y + SC(4)),
            C(imgui.ImVec4(THEME.accent.x, THEME.accent.y, THEME.accent.z, 0.80 * a)), SC(2))

        -- Заголовок скрипта слева
        if FONT_BIG then imgui.PushFont(FONT_BIG) end
        DL:AddText(imgui.ImVec2(p.x + SC(20), p.y + SC(18)), CA(THEME.text, a), 'Help for Job (HfJ)')
        if FONT_BIG then imgui.PopFont() end

        -- Выделенный бейдж текущей скачанной версии справа вверху
        local verBadge = u8(L'Версия: v') .. LOCAL_VERSION
        if FONT_BIG then imgui.PushFont(FONT_BIG) end
        local vbs = imgui.CalcTextSize(verBadge)
        local vbW = vbs.x + SC(24)
        local vbH = SC(34)
        local vbX = p.x + w - vbW - SC(18)
        local vbY = p.y + SC(14)
        DL:AddRectFilled(imgui.ImVec2(vbX, vbY), imgui.ImVec2(vbX + vbW, vbY + vbH),
            C(imgui.ImVec4(THEME.accent.x, THEME.accent.y, THEME.accent.z, 0.16 * a)), SC(10))
        DL:AddRect(imgui.ImVec2(vbX, vbY), imgui.ImVec2(vbX + vbW, vbY + vbH),
            C(imgui.ImVec4(THEME.accentBright.x, THEME.accentBright.y, THEME.accentBright.z, 0.65 * a)), SC(10), 0, SC(1.2))
        DL:AddText(imgui.ImVec2(vbX + (vbW - vbs.x) / 2, vbY + (vbH - vbs.y) / 2),
            CA(THEME.accentBright, a), verBadge)
        if FONT_BIG then imgui.PopFont() end

        -- Крупная строка статуса обновления (шрифт по умолчанию 19px)
        local statusTxt = u8(L'Статус обновлений: ') .. u8(updaterStatus)
        local statusCol = updateAvailable and THEME.accentBright or THEME.dim
        DL:AddText(imgui.ImVec2(p.x + SC(20), p.y + SC(54)), CA(statusCol, a), statusTxt)

        -- Главная кнопка проверки / установки обновления
        imgui.SetCursorScreenPos(imgui.ImVec2(p.x + SC(18), p.y + SC(90)))
        imgui.PushItemWidth(w - SC(36))
        local btnW = w - SC(36)
        local btnH = SC(48)
        local bp = imgui.GetCursorScreenPos()
        imgui.InvisibleButton('##hfj_upd_btn', imgui.ImVec2(btnW, btnH))
        local clicked = imgui.IsItemClicked()
        local hovered = imgui.IsItemHovered()
        if clicked and not updateDownloading then
            if updateAvailable then doUpdate() else doCheck(false) end
        end

        local btnCol = updateAvailable
            and (hovered and THEME.accentBright or THEME.accent)
            or  (hovered and THEME.tileHover or THEME.tile)
        local txtCol = updateAvailable and imgui.ImVec4(0.05, 0.08, 0.09, 1.0) or THEME.text
        DrawNeuBox(DL, bp.x, bp.y, bp.x + btnW, bp.y + btnH, SC(12), btnCol, a,
            updateAvailable and THEME.accentBright or imgui.ImVec4(THEME.accent.x, THEME.accent.y, THEME.accent.z, 0.28))

        local updText
        if updateDownloading then
            updText = u8(L'Проверка / загрузка...')
        elseif updateAvailable then
            updText = u8(L'Установить обновление v') .. u8(remoteVersion)
        else
            updText = u8(L'Проверить обновления')
        end
        if FONT_BIG then imgui.PushFont(FONT_BIG) end
        local uts = imgui.CalcTextSize(updText)
        local spinOffset = updateDownloading and SC(16) or 0
        local textX = bp.x + (btnW - uts.x) / 2 + spinOffset
        if updateDownloading then
            DrawVectorIcon(DL, 'spinner', textX - SC(22), bp.y + btnH / 2, SC(20),
                imgui.ImVec4(THEME.accentBright.x, THEME.accentBright.y, THEME.accentBright.z, a))
        end
        DL:AddText(imgui.ImVec2(textX, bp.y + (btnH - uts.y) / 2), CA(txtCol, a), updText)
        if FONT_BIG then imgui.PopFont() end

        imgui.PopItemWidth()
        imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + cardH))
        imgui.Dummy(imgui.ImVec2(w, SC(14)))
    end

    -- 2) БЛОК 2: Инструкция по работе, команды и безопасность (увеличенный шрифт)
    do
        local cmds = {
            { '/hfj',       L'открыть / закрыть меню' },
            { '/zarabotok', L'сводка заработка в диалоге' },
            { '/resetstat', L'сброс всей статистики' },
            { '/checkupd',  L'проверить обновления' },
            { '/update',    L'скачать обновление' },
            { '/updinfo',   L'диагностика апдейтера' },
            { '/takecargo', L'взять заказ (клавиша 2)' },
            { '/taxord',    L'совместимый алиас меню' },
        }
        local rowH   = SC(32)
        local infoH  = SC(72)
        local topPad = SC(54)
        local cardH  = topPad + infoH + SC(16) + #cmds * rowH + SC(16)
        local p = imgui.GetCursorScreenPos()
        local DL = imgui.GetWindowDrawList()
        DrawNeuBox(DL, p.x, p.y, p.x + w, p.y + cardH, SC(16), THEME.card, a)

        -- Заголовок второго блока крупным шрифтом
        if FONT_BIG then imgui.PushFont(FONT_BIG) end
        DL:AddText(imgui.ImVec2(p.x + SC(20), p.y + SC(16)), CA(THEME.accentBright, a), u8(L'Команды и безопасность'))
        if FONT_BIG then imgui.PopFont() end

        -- Памятка по безопасности и задержкам (основной читаемый шрифт 19px)
        local ix1, iy1, ix2, iy2 = p.x + SC(16), p.y + topPad, p.x + w - SC(16), p.y + topPad + infoH
        DL:AddRectFilled(imgui.ImVec2(ix1, iy1), imgui.ImVec2(ix2, iy2), CA(THEME.cardDark, a), SC(12))
        DL:AddRect(imgui.ImVec2(ix1, iy1), imgui.ImVec2(ix2, iy2),
            C(imgui.ImVec4(1, 1, 1, 0.05 * a)), SC(12), 0, SC(1))

        DL:AddCircleFilled(imgui.ImVec2(ix1 + SC(16), iy1 + SC(21)), SC(4), CA(THEME.emerald, a), 14)
        DL:AddText(imgui.ImVec2(ix1 + SC(28), iy1 + SC(10)), CA(THEME.text, a),
            u8(L'Телефон и оплата (:CASH:) защищены'))

        local modeLine = CFG.turboCatch
            and u8(L'Режим: Турбо (0 мс)  •  Обычный: 50-70 / 40-90 мс')
            or  u8(L'Режим: Обычный (50-70 мс / 40-90 мс)  •  Турбо: 0 мс')
        DL:AddCircleFilled(imgui.ImVec2(ix1 + SC(16), iy1 + SC(50)), SC(4),
            CA(CFG.turboCatch and THEME.warn or THEME.accentBright, a), 14)
        DL:AddText(imgui.ImVec2(ix1 + SC(28), iy1 + SC(39)),
            CA(CFG.turboCatch and THEME.warn or THEME.dim, a), modeLine)

        -- Список команд крупным читаемым шрифтом (19px)
        local listTop = iy2 + SC(16)
        for idx, cm in ipairs(cmds) do
            local ry = listTop + (idx - 1) * rowH
            if idx % 2 == 1 then
                DL:AddRectFilled(
                    imgui.ImVec2(p.x + SC(14), ry - SC(3)),
                    imgui.ImVec2(p.x + w - SC(14), ry + rowH - SC(5)),
                    C(imgui.ImVec4(1, 1, 1, 0.025 * a)), SC(8))
            end
            DL:AddText(imgui.ImVec2(p.x + SC(22), ry), CA(THEME.accentBright, a), cm[1])
            DL:AddText(imgui.ImVec2(p.x + SC(148), ry), CA(THEME.text, 0.88 * a), u8(cm[2]))
        end

        imgui.Dummy(imgui.ImVec2(w, cardH))
    end

    imgui.Dummy(imgui.ImVec2(0, SC(12)))
end

-- ============================================================
--  ОКНО: HFJ AUTOMOTIVE DASHBOARD (HEADER + CONTENT + BOTTOM BAR)
-- ============================================================
local TABS = {
    { id = 1, name = u8(L'Главная'),    header = u8(L'Панель управления'), icon = 'home',     frame = HomeTabFrame     },
    { id = 2, name = u8(L'Статистика'), header = u8(L'Статистика'),        icon = 'stats',    frame = StatsTabFrame    },
    { id = 3, name = u8(L'Настройки'),  header = u8(L'Настройки'),         icon = 'settings', frame = SettingsTabFrame },
}

local dragActive = false
local dragOffset = imgui.ImVec2(0, 0)

local function DashboardWindow(var)
    local sw, sh = getScreenResolution()
    if not sw or sw <= 0 then sw, sh = 1280, 720 end

    if not winPosInit then
        imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        winPosInit = true
    end

    local edge = math.max(SC(10), math.min(SC(32), sw * 0.025))
    local defW = math.min(SC(740), sw - edge * 2)
    local defH = math.min(SC(620), sh - edge * 2)
    local minW = math.min(SC(520), sw - edge * 2)
    local minH = math.min(SC(440), sh - edge * 2)

    imgui.SetNextWindowSize(imgui.ImVec2(defW, defH), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowSizeConstraints(
        imgui.ImVec2(minW, minH),
        imgui.ImVec2(math.max(minW, sw - edge), math.max(minH, sh - edge)))

    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, math.max(0.01, windowAlpha))

    local visible = imgui.Begin('##HfJDashboard', nil,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoBackground
        + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoCollapse)

    if visible then
        local pos, wsize = imgui.GetWindowPos(), imgui.GetWindowSize()
        local DL = imgui.GetWindowDrawList()
        local R  = SC(18)
        local a  = windowAlpha
        local headerH = SC(62)
        local bottomH = SC(68)

        -- Мягкая неоморфная тень и плотный матовый графитовый фон (никакого стекла!)
        DL:AddRectFilled(
            imgui.ImVec2(pos.x + SC(5), pos.y + SC(7)),
            imgui.ImVec2(pos.x + wsize.x + SC(7), pos.y + wsize.y + SC(10)),
            CA(THEME.shadowDark, 0.80 * a), R + SC(4))
        DL:AddRectFilled(pos, imgui.ImVec2(pos.x + wsize.x, pos.y + wsize.y),
            CA(THEME.bg, a), R)
        DL:AddRect(pos, imgui.ImVec2(pos.x + wsize.x, pos.y + wsize.y),
            C(imgui.ImVec4(1, 1, 1, 0.06 * a)), R, 0, SC(1.5))

        -- Верхняя шапка (Header)
        DL:AddRectFilled(pos, imgui.ImVec2(pos.x + wsize.x, pos.y + headerH),
            CA(THEME.barBg, a), R, 3)
        DL:AddLine(
            imgui.ImVec2(pos.x + SC(16), pos.y + headerH),
            imgui.ImVec2(pos.x + wsize.x - SC(16), pos.y + headerH),
            C(imgui.ImVec4(1, 1, 1, 0.06 * a)), SC(1))

        -- Перетаскивание окна за шапку
        imgui.SetCursorPos(imgui.ImVec2(SC(164), 0))
        imgui.InvisibleButton('##hfj_window_drag',
            imgui.ImVec2(math.max(SC(40), wsize.x - SC(340)), headerH))
        if imgui.IsItemHovered() and imgui.IsMouseClicked(0) then
            local mp = imgui.GetMousePos()
            dragOffset = imgui.ImVec2(mp.x - pos.x, mp.y - pos.y)
            dragActive = true
        end
        if dragActive then
            if imgui.IsMouseDown(0) then
                local mp = imgui.GetMousePos()
                imgui.SetWindowPosVec2(imgui.ImVec2(mp.x - dragOffset.x, mp.y - dragOffset.y))
            else
                dragActive = false
            end
        end

        -- Слева: Логотип HfJ (градиентная эмблема)
        DrawHeaderLogo(DL, pos.x + SC(16), pos.y + (headerH - SC(40)) / 2, a)

        -- По центру: Название вкладки
        local curTab = TABS[activeTab] or TABS[1]
        if FONT_BIG then imgui.PushFont(FONT_BIG) end
        local hts = imgui.CalcTextSize(curTab.header)
        DL:AddText(
            imgui.ImVec2(pos.x + (wsize.x - hts.x) / 2, pos.y + (headerH - hts.y) / 2),
            CA(THEME.text, a), curTab.header)
        if FONT_BIG then imgui.PopFont() end

        -- Справа: Пульсирующий индикатор состояния сети/заказа + кнопка закрытия
        do
            local closeSz = SC(30)
            local closeX  = pos.x + wsize.x - closeSz - SC(14)
            local closeY  = pos.y + (headerH - closeSz) / 2

            imgui.SetCursorScreenPos(imgui.ImVec2(closeX, closeY))
            imgui.InvisibleButton('##CLOSEBUTTON', imgui.ImVec2(closeSz, closeSz))
            if imgui.IsItemClicked() then var[0] = false end
            local hovClose = imgui.IsItemHovered()

            local ccx, ccy = closeX + closeSz / 2, closeY + closeSz / 2
            local cbg = hovClose and THEME.danger or THEME.card
            DL:AddCircleFilled(imgui.ImVec2(ccx, ccy), closeSz / 2, CA(cbg, a), 24)
            DL:AddCircle(imgui.ImVec2(ccx, ccy), closeSz / 2,
                C(imgui.ImVec4(1, 1, 1, (hovClose and 0.35 or 0.08) * a)), 24, SC(1))
            local d = SC(5)
            local xu32 = hovClose and C(imgui.ImVec4(1, 1, 1, a)) or CA(THEME.dim, a)
            DL:AddLine(imgui.ImVec2(ccx - d, ccy - d), imgui.ImVec2(ccx + d, ccy + d), xu32, SC(1.8))
            DL:AddLine(imgui.ImVec2(ccx - d, ccy + d), imgui.ImVec2(ccx + d, ccy - d), xu32, SC(1.8))

            -- Индикатор статуса (синхронизирован по цветам с кнопкой автоловли заказов)
            local wave = 0.5 + 0.5 * math.sin(os.clock() * 2.3)
            local isActive = CFG.catchEnabled or hasActiveOrder
            local pulse = isActive and (0.45 + 0.55 * math.sin(os.clock() * 3.6)) or 0.75
            local dotCol = isActive
                and LerpVec4(THEME.emerald, THEME.accentBright, wave * 0.4)
                or  THEME.dim
            local chipBg = isActive
                and LerpVec4(imgui.ImVec4(0.07, 0.24, 0.17, 1.0), imgui.ImVec4(0.09, 0.30, 0.21, 1.0), wave)
                or  THEME.card
            local stTxt = hasActiveOrder and u8(L'В заказе')
                or (CFG.catchEnabled and u8(L'Активна') or u8(L'Выкл'))

            if FONT_SUB then imgui.PushFont(FONT_SUB) end
            local sts = imgui.CalcTextSize(stTxt)
            local pillW = sts.x + SC(32)
            local pillH = SC(28)
            local px = closeX - pillW - SC(10)
            local py = pos.y + (headerH - pillH) / 2

            DL:AddRectFilled(imgui.ImVec2(px, py), imgui.ImVec2(px + pillW, py + pillH),
                CA(chipBg, a), pillH / 2)
            DL:AddRect(imgui.ImVec2(px, py), imgui.ImVec2(px + pillW, py + pillH),
                C(imgui.ImVec4(dotCol.x, dotCol.y, dotCol.z, (isActive and 0.65 or 0.28) * a)), pillH / 2, 0, SC(1.2))
            if isActive then
                DL:AddCircleFilled(imgui.ImVec2(px + SC(13), py + pillH / 2), SC(7),
                    C(imgui.ImVec4(dotCol.x, dotCol.y, dotCol.z, 0.24 * pulse * a)), 16)
            end
            DL:AddCircleFilled(imgui.ImVec2(px + SC(13), py + pillH / 2), SC(4),
                C(imgui.ImVec4(dotCol.x, dotCol.y, dotCol.z, pulse * a)), 16)
            DL:AddText(imgui.ImVec2(px + SC(24), py + (pillH - sts.y) / 2),
                CA(isActive and THEME.text or THEME.dim, a), stTxt)
            if FONT_SUB then imgui.PopFont() end
        end

        -- Центральный экран (Контент)
        local padX = SC(18)
        local padY = SC(12)
        local contentW = math.max(SC(120), wsize.x - padX * 2)
        local contentH = math.max(SC(120), wsize.y - headerH - bottomH - padY * 2)

        imgui.SetCursorPos(imgui.ImVec2(padX, headerH + padY))
        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, math.max(0.01, windowAlpha * tabFade))
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(SC(4), SC(4)))
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
        if imgui.BeginChild('##hfj_dash_content', imgui.ImVec2(contentW, contentH), false) then
            if tabSlide > 0 then imgui.SetCursorPosX(imgui.GetCursorPosX() + tabSlide) end
            curTab.frame()
        end
        imgui.EndChild()
        imgui.PopStyleColor()
        imgui.PopStyleVar(2)

        -- Нижняя панель (Bottom Navigation)
        imgui.SetCursorPos(imgui.ImVec2(0, wsize.y - bottomH))
        local bp = imgui.GetCursorScreenPos()
        DL:AddRectFilled(bp, imgui.ImVec2(bp.x + wsize.x, bp.y + bottomH),
            CA(THEME.barBg, a), R, 12)
        DL:AddLine(
            imgui.ImVec2(bp.x + SC(16), bp.y),
            imgui.ImVec2(bp.x + wsize.x - SC(16), bp.y),
            C(imgui.ImVec4(1, 1, 1, 0.06 * a)), SC(1))

        local navCount = #TABS
        local itemW = (wsize.x - SC(32)) / navCount
        for idx, tab in ipairs(TABS) do
            local isSel = (activeTab == idx)
            local target = isSel and 1.0 or 0.0
            navAnim[idx] = (navAnim[idx] or 0) + (target - (navAnim[idx] or 0)) * 0.24
            local na = navAnim[idx]

            local ix = bp.x + SC(16) + (idx - 1) * itemW
            local iy = bp.y + SC(6)
            local ih = bottomH - SC(12)

            imgui.SetCursorScreenPos(imgui.ImVec2(ix, iy))
            imgui.InvisibleButton('##hfj_nav_' .. idx, imgui.ImVec2(itemW, ih))
            if imgui.IsItemClicked() then activeTab = idx end
            local hov = imgui.IsItemHovered()

            if na > 0.02 or hov then
                local pillCol = LerpVec4(
                    imgui.ImVec4(THEME.card.x, THEME.card.y, THEME.card.z, hov and 0.65 or 0),
                    imgui.ImVec4(0.11, 0.21, 0.21, 1.0), na)
                DL:AddRectFilled(
                    imgui.ImVec2(ix + SC(8), iy + SC(2)),
                    imgui.ImVec2(ix + itemW - SC(8), iy + ih - SC(2)),
                    CA(pillCol, a), SC(14))
                if na > 0.05 then
                    DL:AddRectFilled(
                        imgui.ImVec2(ix + itemW * 0.30, iy + ih - SC(3)),
                        imgui.ImVec2(ix + itemW * 0.70, iy + ih),
                        CA(THEME.accent, na * a), SC(2))
                end
            end

            local col = LerpVec4(THEME.dim, THEME.accentBright, na)
            local iconScale = 1.0 + 0.16 * na
            local icx = ix + itemW / 2
            local icy = iy + SC(19) - SC(1.5) * na
            DrawVectorIcon(DL, tab.icon, icx, icy, SC(20) * iconScale,
                imgui.ImVec4(col.x, col.y, col.z, a))

            if FONT_SUB then imgui.PushFont(FONT_SUB) end
            local nts = imgui.CalcTextSize(tab.name)
            DL:AddText(imgui.ImVec2(ix + (itemW - nts.x) / 2, iy + ih - nts.y - SC(5)),
                CA(col, a), tab.name)
            if FONT_SUB then imgui.PopFont() end
        end

        -- Индикатор ресайза в правом нижнем углу
        do
            local rc = C(imgui.ImVec4(THEME.accent.x, THEME.accent.y, THEME.accent.z, 0.45 * a))
            for i = 1, 2 do
                DL:AddLine(
                    imgui.ImVec2(pos.x + wsize.x - SC(5), pos.y + wsize.y - SC(5) - i * SC(5)),
                    imgui.ImVec2(pos.x + wsize.x - SC(5) - i * SC(5), pos.y + wsize.y - SC(5)),
                    rc, SC(1.5))
            end
        end
    end
    imgui.End()
    imgui.PopStyleVar()
end

-- ============================================================
--  ШРИФТЫ И СТИЛЬ
-- ============================================================
imgui.OnInitialize(function()
    local imio = imgui.GetIO()
    pcall(function() imio.Fonts:Clear() end)
    local cyr_ranges = imio.Fonts:GetGlyphRangesCyrillic()

    -- Масштаб интерфейса под разрешение экрана телефона
    local sw, sh = 1280, 720
    pcall(function()
        local w, h = getScreenResolution()
        if w and w > 0 then sw = w end
        if h and h > 0 then sh = h end
    end)
    UI_SCALE = math.max(1.0, math.min(2.0, math.min(sw / 1280, sh / 720)))

    local regular_paths = {
        'C:/Windows/Fonts/segoeui.ttf',
        'C:/Windows/Fonts/arial.ttf',
        'C:/Windows/Fonts/tahoma.ttf',
        '/system/fonts/Roboto-Regular.ttf',
        '/system/fonts/RobotoCondensed-Regular.ttf',
        '/system/fonts/NotoSans-Regular.ttf',
        '/system/fonts/DroidSans.ttf',
    }
    local bold_paths = {
        'C:/Windows/Fonts/segoeuib.ttf',
        'C:/Windows/Fonts/arialbd.ttf',
        'C:/Windows/Fonts/tahomabd.ttf',
        '/system/fonts/Roboto-Bold.ttf',
        '/system/fonts/DroidSans-Bold.ttf',
        '/system/fonts/NotoSans-Bold.ttf',
        '/system/fonts/Roboto-Black.ttf',
    }

    local function loadFont(paths, size)
        for _, path in ipairs(paths) do
            local fh = io.open(path, 'r')
            if fh then
                fh:close()
                local ok, font = pcall(function()
                    return imio.Fonts:AddFontFromFileTTF(path, size, nil, cyr_ranges)
                end)
                if ok and font then return font end
            end
        end
        return nil
    end

    local def = loadFont(regular_paths, SC(19))
    if not def then
        local ok, font = pcall(function() return imio.Fonts:AddFontDefault() end)
        if ok and font then def = font end
    end
    if def then imio.FontDefault = def end

    FONT_LOGO = loadFont(bold_paths, SC(24)) or def
    FONT_SUB  = loadFont(regular_paths, SC(15)) or def
    FONT_BIG  = loadFont(bold_paths, SC(22)) or FONT_LOGO
    FONT_HERO = loadFont(bold_paths, SC(36)) or FONT_BIG

    local style = imgui.GetStyle()
    style.WindowPadding     = imgui.ImVec2(0, 0)
    style.WindowRounding    = SC(16)
    style.ChildRounding     = SC(16)
    style.FrameRounding     = SC(14)
    style.PopupRounding     = SC(14)
    style.ScrollbarRounding = SC(12)
    style.GrabRounding      = SC(12)
    style.ItemSpacing       = imgui.ImVec2(SC(10), SC(10))
    style.ItemInnerSpacing  = imgui.ImVec2(SC(8), SC(8))
    style.FramePadding      = imgui.ImVec2(SC(10), SC(8))
    style.ScrollbarSize     = SC(8)
    style.WindowBorderSize  = 0

    local col = style.Colors
    col[imgui.Col.WindowBg]         = THEME.bg
    col[imgui.Col.Border]           = imgui.ImVec4(0, 0, 0, 0)
    col[imgui.Col.Text]             = THEME.text
    col[imgui.Col.TextDisabled]     = THEME.dim
    col[imgui.Col.FrameBg]          = THEME.cardDark
    col[imgui.Col.FrameBgHovered]   = THEME.tile
    col[imgui.Col.FrameBgActive]    = THEME.tileHover
    col[imgui.Col.Button]           = THEME.tile
    col[imgui.Col.ButtonHovered]    = THEME.tileHover
    col[imgui.Col.ButtonActive]     = THEME.accentDark
    col[imgui.Col.Header]           = THEME.tile
    col[imgui.Col.HeaderHovered]    = THEME.tileHover
    col[imgui.Col.HeaderActive]     = THEME.accentDark
    col[imgui.Col.SliderGrab]       = THEME.accent
    col[imgui.Col.SliderGrabActive] = THEME.accentBright
    col[imgui.Col.CheckMark]        = THEME.accent
    col[imgui.Col.ScrollbarBg]      = imgui.ImVec4(0.07, 0.08, 0.10, 1.0)
    col[imgui.Col.ScrollbarGrab]    = imgui.ImVec4(0.20, 0.23, 0.28, 1.0)
    col[imgui.Col.ScrollbarGrabHovered] = THEME.accentDark
    col[imgui.Col.ScrollbarGrabActive]  = THEME.accent
end)

-- ============================================================
--  РЕНДЕР ОКНА
-- ============================================================
imgui.OnFrame(
    function() return (window[0] or windowAlpha > 0.005) and isSampAvailable() and not isPauseMenuActive() end,
    function(this)
        this.ShowCursor = (window[0] or windowAlpha > 0.35)
        local target = window[0] and 1.0 or 0.0
        windowAlpha = windowAlpha + (target - windowAlpha) * 0.30
        if math.abs(target - windowAlpha) < 0.01 then windowAlpha = target end

        if windowAlpha <= 0.005 and not window[0] then
            windowAlpha = 0
            return
        end

        if activeTab ~= lastSelectedTab then
            tabFade = 0; tabSlide = SC(40); lastSelectedTab = activeTab
        end
        if tabFade < 1 then tabFade = math.min(1, tabFade + 0.09) end
        if tabSlide > 0 then
            tabSlide = tabSlide - SC(5)
            if tabSlide < 0 then tabSlide = 0 end
        end

        DashboardWindow(window)
    end
)

-- ============================================================
--  ТОСТЫ (КОМПАКТНЫЙ AUTOMOTIVE HUD-БАННЕР ВНИЗУ ЭКРАНА)
-- ============================================================
imgui.OnFrame(
    function() return (sn.state ~= 'idle' or #sn.queue > 0) and not isPauseMenuActive() end,
    function(self)
        self.HideCursor = true

        if sn.state == 'idle' and #sn.queue > 0 and canShowNotify() then
            local item = table.remove(sn.queue, 1)
            sn.message = item.text
            sn.icon    = item.icon
            sn.timer   = os.clock()
            sn.dur     = (#sn.queue > 0) and 1.2 or NOTIFY_DURATION
            sn.state   = 'showing'
            sn.version = sn.version + 1
            sn.anim    = 0
            acquireNotifyLock(sn.dur)
            local myv = sn.version

            bringFloatTo(0, 1, sn.timer, NOTIFY_ANIM_IN, 'outQuart', function(f)
                if sn.version == myv then sn.anim = f end
            end)
        elseif sn.state == 'showing' then
            local effDur = (#sn.queue > 0) and math.min(sn.dur, 1.1) or sn.dur
            if (os.clock() - sn.timer) >= effDur then
                sn.state = 'hiding'
                sn.timer = os.clock()
                local myv = sn.version
                bringFloatTo(1, 0, sn.timer, NOTIFY_ANIM_OUT, 'inBack', function(f)
                    if sn.version == myv then
                        sn.anim = f
                        if f <= 0.02 then sn.state = 'idle' end
                    end
                end)
            end
        end

        if sn.state == 'idle' then return end

        local sw, sh = getScreenResolution()
        if not sw or sw <= 0 then return end

        local text = u8(sn.message)
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        local ts   = imgui.CalcTextSize(text)
        if FONT_SUB then imgui.PopFont() end

        local leftPad  = SC(50)
        local rightPad = SC(18)
        local w_px = math.min(sw - SC(36), math.max(SC(190), ts.x + leftPad + rightPad))
        local h_px = math.max(SC(44), ts.y + SC(22))

        local w_pos = imgui.ImVec2(sw / 2, sh - sn.anim * (h_px + SC(18)) - SC(6))

        imgui.SetNextWindowPos(w_pos, imgui.Cond.Always, imgui.ImVec2(0.5, 0.0))
        imgui.SetNextWindowSize(imgui.ImVec2(w_px, h_px), imgui.Cond.Always)

        local ta = math.max(0, math.min(1, sn.anim))
        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, math.max(0.01, ta))
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0))

        imgui.Begin('##HfJToast', nil, imgui.WindowFlags.NoMove + imgui.WindowFlags.NoDecoration + imgui.WindowFlags.NoInputs)

        local p  = imgui.GetCursorScreenPos()
        local DL = imgui.GetWindowDrawList()
        local r  = SC(14)
        local A  = imgui.ImVec2(p.x, p.y)
        local B  = imgui.ImVec2(p.x + w_px, p.y + h_px)

        local accentCol = THEME.accent
        local vecKind   = 'info'
        if sn.icon == 'success' then
            accentCol = THEME.emerald; vecKind = 'check'
        elseif sn.icon == 'warn' then
            accentCol = THEME.warn;    vecKind = 'warn'
        elseif sn.icon == 'error' then
            accentCol = THEME.danger;  vecKind = 'error'
        end

        -- Компактная матовая графитовая капсула с мягкой тенью и цветным контуром
        DL:AddRectFilled(imgui.ImVec2(A.x + SC(2), A.y + SC(3)), imgui.ImVec2(B.x + SC(2), B.y + SC(5)),
            CA(THEME.shadowDark, 0.80 * ta), r)
        DL:AddRectFilled(A, B, CA(THEME.cardDark, 0.98 * ta), r)
        DL:AddRect(A, B, C(imgui.ImVec4(accentCol.x, accentCol.y, accentCol.z, 0.45 * ta)), r, 0, SC(1.2))

        -- Компактная векторная иконка слева без плюсиков
        do
            local icx = A.x + SC(25)
            local icy = A.y + h_px / 2
            local ir  = SC(13)
            local g   = 0.5 + 0.5 * math.sin(os.clock() * 6.0)

            DL:AddCircleFilled(imgui.ImVec2(icx, icy), ir + SC(3) * g,
                C(imgui.ImVec4(accentCol.x, accentCol.y, accentCol.z, 0.16 * ta)), 22)
            DL:AddCircleFilled(imgui.ImVec2(icx, icy), ir,
                C(imgui.ImVec4(accentCol.x, accentCol.y, accentCol.z, 0.22 * ta)), 22)
            DL:AddCircle(imgui.ImVec2(icx, icy), ir,
                C(imgui.ImVec4(accentCol.x, accentCol.y, accentCol.z, 0.70 * ta)), 22, SC(1.1))
            DrawVectorIcon(DL, vecKind, icx, icy, SC(14),
                imgui.ImVec4(accentCol.x, accentCol.y, accentCol.z, ta))
        end

        -- Текст сообщения
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        DL:AddText(imgui.ImVec2(A.x + leftPad, A.y + (h_px - ts.y) / 2 - SC(0.5)),
            CA(THEME.text, ta), text)
        if FONT_SUB then imgui.PopFont() end

        -- Тонкий плавный индикатор таймера вдоль нижнего края
        if sn.state == 'showing' then
            local effDur = (#sn.queue > 0) and math.min(sn.dur, 1.1) or sn.dur
            local ratio = math.max(0, 1 - math.min(1, (os.clock() - sn.timer) / math.max(0.1, effDur)))
            local barMaxW = (B.x - A.x - SC(28))
            local barW = barMaxW * ratio
            if barW > SC(2) then
                DL:AddRectFilled(
                    imgui.ImVec2(A.x + SC(14), B.y - SC(3)),
                    imgui.ImVec2(A.x + SC(14) + barW, B.y - SC(1.2)),
                    C(imgui.ImVec4(accentCol.x, accentCol.y, accentCol.z, 0.78 * ta)), SC(1))
            end
        end

        imgui.End()
        imgui.PopStyleColor()
        imgui.PopStyleVar(3)
    end
)

-- ============================================================
--  MAIN
-- ============================================================
function main()
    while not isSampAvailable() do wait(200) end

    math.randomseed(os.time())

    logInit()
    loadCfg()
    logAct('Script loaded. v' .. VERSION .. ' (utf8_file=' .. tostring(FILE_IS_UTF8) .. ')')

    local function toggleMenu()
        if window[0] then
            window[0] = false
        else
            window[0] = true; windowAlpha = 0
            tabFade = 1; tabSlide = 0; lastSelectedTab = activeTab
        end
        logAct('Menu: ' .. tostring(window[0]))
    end

    sampRegisterChatCommand('hfj', toggleMenu)
    sampRegisterChatCommand('taxord', toggleMenu)

    sampRegisterChatCommand('zarabotok', function()
        sampShowDialog(ZP_DIALOG_ID, L'Заработок на работах', zpReportText(), L'ОК', L'Закрыть', 0)
    end)

    sampRegisterChatCommand('resetstat', function()
        resetAllStats()
        notify(L'Статистика сброшена', 0xFFAA00)
    end)

    sampRegisterChatCommand('takecargo', function()
        lua_thread.create(function()
            if type(setVirtualKeyDown) == 'function' then
                pcall(setVirtualKeyDown, 0x32, true)
                wait(100)
                pcall(setVirtualKeyDown, 0x32, false)
            elseif type(setGameKeyState) == 'function' then
                pcall(setGameKeyState, 0x32, 255)
                wait(100)
                pcall(setGameKeyState, 0x32, 0)
            end
            notify(L'Нажата клавиша 2 (взаимодействие)', 0x00CCB3)
        end)
    end)

    sampRegisterChatCommand('checkupd', function() doCheck(false) end)
    sampRegisterChatCommand('update', function() doUpdate() end)
    sampRegisterChatCommand('updinfo', function()
        notify(L'Версия: v' .. LOCAL_VERSION ..
            ' | GitHub: v' .. (remoteVersion ~= '' and remoteVersion or '?'), 0x00CCB3)
        notify(L'Транспорты: ' .. updaterTransportsText(), 0x00CCB3)
        notify(L'Статус: ' .. updaterStatus, 0x00CCB3)
    end)

    notify(L'Help for Job ' .. VERSION .. L' загружен, /hfj - меню', 0x00FF00)
    startUpdateCheck()

    lua_thread.create(function()
        while true do
            wait(500)
            if isSampAvailable() and type(doesCharExist) == 'function' and doesCharExist(PLAYER_PED) then
                local ok, x, y, z = pcall(getCharCoordinates, PLAYER_PED)
                if ok and x and y and z then
                    if zpLastX then
                        local dx, dy, dz = x - zpLastX, y - zpLastY, z - zpLastZ
                        zpMovedDist = zpMovedDist + math.sqrt(dx*dx + dy*dy + dz*dz)
                    end
                    zpLastX, zpLastY, zpLastZ = x, y, z
                end
            end
        end
    end)

    lastAutoSave = os.clock()

    while true do
        wait(0)
        local now = os.clock()

        -- ОБРАБОТКА НАЖАТИЙ В НАШЕМ ЛОКАЛЬНОМ ДИАЛОГЕ ОБНОВЛЕНИЯ
        local result, button, list, input = sampHasDialogRespond(UPDATE_DIALOG_ID)
        if result then
            logAct('Update dialog: button=' .. tostring(button))
            pendingUpdatePrompt = false
            promptedVersion = remoteVersion

            if button == 1 then
                updateAvailable = true
                doUpdate()
            else
                notify(L'Обновление отложено. Команда: /update', 0xFFAA00)
            end
        end

        -- Диалог "Доступно обновление?" показываем из главного потока
        if pendingUpdatePrompt and now >= promptRetryAt then
            local busy = false
            if type(sampIsDialogActive) == 'function' then
                local okBusy, v = pcall(sampIsDialogActive)
                busy = (okBusy and v) and true or false
            end

            if not busy then
                sampShowDialog(UPDATE_DIALOG_ID,
                    L'Обновление Help for Job',
                    string.format(L'Доступна версия: %s\nУ вас установлена: %s\n\nОбновить скрипт сейчас?',
                        remoteVersion, LOCAL_VERSION),
                    L'Обновить', L'Позже', 0)

                pendingUpdatePrompt = false
                logAct('Update prompt shown for v' .. remoteVersion)
            else
                promptRetryAt = now + 3
            end
        end

        -- Тихая проверка обновлений раз в 30 минут
        if canDownload and not updateDownloading
           and (os.time() - lastAutoCheck) >= AUTO_CHECK_EVERY then
            lastAutoCheck = os.time()
            doCheck(true)
        end

        if cfgDirty and (now - lastAutoSave) > 1.5 then
            lastAutoSave = now; saveCfg()
        end

        if pendingAccept and (now - pendingAccept) > PENDING_TIMEOUT then
            logAct('Accept timeout: pendingAccept expired')
            pendingAccept = nil
            hasActiveOrder = false
            resetCatchCycle('accept timeout')
        end

        if awaitingDialog and now > awaitingExpire then
            awaitingDialog = false
            tapSequenceActive = false
        end

        if tapSequenceActive then
            if now >= tapSeqNextSend then
                if tapSeqIndex <= MAX_TAPS then
                    sendTapPacketWithIndex(tapSeqIndex)
                    tapSeqIndex = tapSeqIndex + 1

                    local randomOffset = math.random(-5, 15)
                    local currentStepMs = math.max(10, TAP_STEP_MS + randomOffset)
                    if CFG.turboCatch then
                        currentStepMs = 0
                    end
                    tapSeqNextSend = now + currentStepMs / 1000
                else
                    tapSequenceActive = false
                end
            end
        end
    end
end

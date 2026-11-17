-- Help_for_Job.lua
-- MonetLoader 3.8.x / Neom Loader / MoonLoader
-- Help for Job (HfJ) - автоловля заказов такси + учёт заработка по работам
-- c1.7 (HfJ Automotive Dashboard)

script_name('HfJ')
script_version('c1.7')

local imgui    = require 'mimgui'
local new      = imgui.new
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local sampev = require 'samp.events'

local VERSION       = 'c1.7'
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
        elseif b1 == 0xE2 and i + 2 <= n then
            local b2, b3 = s:byte(i + 1), s:byte(i + 2)
            if b2 == 0x80 and b3 == 0x94 then
                out[#out + 1] = '-'; i = i + 3
            elseif b2 == 0x80 and b3 == 0x93 then
                out[#out + 1] = '-'; i = i + 3
            elseif b2 == 0x80 and b3 == 0xA2 then
                out[#out + 1] = '|'; i = i + 3
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
local CATCH = {
    MAX_TAPS_NORMAL  = 1,    -- 1-2 точных тапа (0 + резерв 1 при отсутствии ответа)
    MAX_TAPS_TURBO   = 1,    -- 1-2 точных тапа без спама 15 диалогами подряд
    REACT_DELAY_MIN  = 30,   -- быстрая живая реакция перед 1-м тапом (мс)
    REACT_DELAY_MAX  = 60,
    TAP_STEP_MIN     = 220,  -- пауза до резервного 2-го тапа в обычном режиме (мс)
    TAP_STEP_MAX     = 320,
    TAP_STEP_TURBO   = 180,  -- пауза до резервного 2-го тапа в Турбо (мс)
    ACCEPT_DELAY_MIN = 35,   -- быстрое живое подтверждение «Принять» (мс)
    ACCEPT_DELAY_MAX = 70,
    TAP_COOLDOWN     = 250,
    PENDING_TIMEOUT  = 15.0,
}

local function humanDelayMs(minMs, maxMs)
    local mid = math.floor((minMs + maxMs) / 2)
    local r1 = math.random(minMs, mid)
    local r2 = math.random(mid, maxMs)
    local jitter = math.random(-5, 5)
    return math.max(minMs, math.min(maxMs, math.floor((r1 + r2) / 2) + jitter))
end

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
local FONT_SUB     = nil
local FONT_BIG     = nil
local FONT_HERO    = nil
local window           = new.bool(false)
local updateModal      = new.bool(false)

local winPosInit = false

local windowAlpha      = 0
local updateModalAlpha = 0
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

local LOG_BUF = {}
local LOG_LAST_FLUSH = 0

local function flushLogBuffer(force)
    if #LOG_BUF == 0 then return end
    local now = os.clock()
    if not force and #LOG_BUF < 20 and (now - LOG_LAST_FLUSH) < 2.0 then return end
    local f = io.open(LOG_FILE, 'a')
    if f then
        f:write(table.concat(LOG_BUF))
        f:close()
    end
    LOG_BUF = {}
    LOG_LAST_FLUSH = now
end

local function logRaw(tag, msg)
    local tagStr = tostring(tag or 'INFO')
    -- Пропускаем пустые строки чата, чтобы не нагружать память и диск
    if tagStr == 'CHAT' and (msg == nil or tostring(msg):match('^%s*$')) then return end

    local ms = 0
    if type(getTickCount) == 'function' then
        ms = getTickCount() % 1000
    else
        ms = math.floor((os.clock() % 1) * 1000)
    end
    local timeStr = os.date('%H:%M:%S.') .. string.format('%03d', ms)
    local line
    if msg == nil then
        line = string.format('%s | %s', timeStr, tagStr)
    else
        line = string.format('%s | %-5s | %s', timeStr, tagStr, tostring(msg))
    end

    -- В консоль/neomloader пишем только важные действия и ошибки (без флуда чата/диалогов)
    if tagStr == 'ACT' or tagStr == 'ERROR' then
        print('[HfJ] ' .. line)
    end

    LOG_BUF[#LOG_BUF + 1] = u8(line) .. '\n'
    if tagStr == 'ERROR' or #LOG_BUF >= 20 then
        flushLogBuffer(true)
    end
end

-- Очистка файла лога при первом запуске и дописывание при реконнекте
local function logInit(reason)
    flushLogBuffer(true)
    local isInitial = (reason == nil)
    local mode = isInitial and 'w' or 'a'
    local f = io.open(LOG_FILE, mode)
    if f then
        if not isInitial then f:write('\n') end
        f:write('============================================================\n')
        f:write('=== Help for Job ' .. VERSION .. ' | ' .. os.date('%d.%m.%Y %H:%M:%S') .. ' ===\n')
        f:write(u8(L'=== Сессия: ' .. tostring(reason or L'Запуск скрипта')) .. '\n')
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
    catchEnabled  = true,
    autoAccept    = true,
    turboCatch    = false, -- Турбо-ловля (0 мс)
    useLogTracker = true,  -- Учёт через neomloader.log (Packet 220 HUD balance)
    ordersDone    = 0,
    moneyEarned   = 0,
}

local ZP = {
    taxi = 0, roadworker = 0, trucker = 0, collector = 0,
    deliverer = 0, mechanic = 0, bus = 0, garbage = 0,
}

local function markDirty() cfgDirty = true end

local function saveCfg()
    local f = io.open(CONFIG_FILE, 'w')
    if not f then return false end
    f:write('catchEnabled='  .. tostring(CFG.catchEnabled)  .. '\n')
    f:write('autoAccept='    .. tostring(CFG.autoAccept)    .. '\n')
    f:write('turboCatch='    .. tostring(CFG.turboCatch)    .. '\n')
    f:write('useLogTracker=' .. tostring(CFG.useLogTracker) .. '\n')
    f:write('ordersDone='    .. tostring(CFG.ordersDone)    .. '\n')
    f:write('moneyEarned='   .. tostring(CFG.moneyEarned)   .. '\n')
    f:write('zpTaxi='        .. tostring(math.floor(ZP.taxi))       .. '\n')
    f:write('zpRoadworker='  .. tostring(math.floor(ZP.roadworker)) .. '\n')
    f:write('zpTrucker='     .. tostring(math.floor(ZP.trucker))    .. '\n')
    f:write('zpCollector='   .. tostring(math.floor(ZP.collector))  .. '\n')
    f:write('zpDeliverer='   .. tostring(math.floor(ZP.deliverer))  .. '\n')
    f:write('zpMechanic='    .. tostring(math.floor(ZP.mechanic))   .. '\n')
    f:write('zpBus='         .. tostring(math.floor(ZP.bus))        .. '\n')
    f:write('zpGarbage='     .. tostring(math.floor(ZP.garbage))    .. '\n')
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
            if k == 'catchEnabled'  then CFG.catchEnabled  = (v == 'true') end
            if k == 'autoAccept'    then CFG.autoAccept    = (v == 'true') end
            if k == 'turboCatch'    then CFG.turboCatch    = (v == 'true') end
            if k == 'useLogTracker' then CFG.useLogTracker = (v == 'true') end
            if k == 'ordersDone'    and n then CFG.ordersDone  = n end
            if k == 'moneyEarned'   and n then CFG.moneyEarned = n end
            if k == 'zpTaxi'        and n then ZP.taxi         = n end
            if k == 'zpRoadworker'  and n then ZP.roadworker   = n end
            if k == 'zpTrucker'     and n then ZP.trucker      = n end
            if k == 'zpCollector'   and n then ZP.collector    = n end
            if k == 'zpDeliverer'   and n then ZP.deliverer    = n end
            if k == 'zpMechanic'    and n then ZP.mechanic     = n end
            if k == 'zpBus'         and n then ZP.bus          = n end
            if k == 'zpGarbage'     and n then ZP.garbage      = n end
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
    return nil
end

local function zpDetectJob(textN)
    if textN:find(L'инкассатор', 1, true) then return 'collector' end
    if textN:find(L'развозчик', 1, true) then return 'deliverer' end

    -- Ремонтник дорог
    if textN:find(L'ремонтник', 1, true)
       or textN:find(L'дорожного ремонта', 1, true)
       or textN:find(L'дорожных ям', 1, true) then return 'roadworker' end

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
       or textN:find(L'доставили авто', 1, true)
       or textN:find(L'за ремонт', 1, true)
       or textN:find(L'выполненную работу', 1, true) then return 'mechanic' end

    -- Дальнобойщик
    if textN:find(L'дальнобой', 1, true)
       or textN:find(L'грузовик', 1, true)
       or textN:find(L'грузоперевоз', 1, true)
       or textN:find(L'груз', 1, true)
       or textN:find(L'рейс', 1, true) then return 'trucker' end

    if textN:find(L'такси', 1, true)
       or textN:find(L'клиент оплатил', 1, true) then return 'taxi' end
    return nil
end

local function zpIsPayout(textN)
    if textN:find(L'вы оплатили', 1, true)
       or textN:find(L'вы заплатили', 1, true)
       or textN:find(L'вы потратили', 1, true)
       or textN:find(L'списано', 1, true)
       or textN:find(L'снято', 1, true)
       or textN:find(L'арендовали', 1, true)
       or textN:find(L'починил ваш', 1, true)
       or textN:find(L'починила ваш', 1, true)
       or textN:find(L'[подсказка]', 1, true)
       or textN:find(L'текущая сумма в банке', 1, true)
       or textN:find(L'текущая сумма на депозите', 1, true)
       or textN:find(L'общая заработная плата', 1, true)
       or textN:find(L'чаевых', 1, true)
       or textN:find(L'премия за работу таксистом', 1, true) then
        return false
    end

    if textN:find(L'клиент оплатил', 1, true) then return true end
    if textN:find(L'зарплата за рейс', 1, true) then return true end
    if textN:find(L'получено за обслуживание', 1, true) then return true end
    if textN:find(L'за обслуживание банкомата', 1, true) then return true end
    if textN:find(L'премия за доставку', 1, true) then return true end
    if textN:find(L'вы успешно доставили авто', 1, true) then return true end
    if textN:find(L'оплата за ремонт', 1, true) then return true end
    if textN:find(L'за ремонт', 1, true) and textN:find(L'получили', 1, true) then return true end
    if textN:find(L'груз успешно доставлен', 1, true) then return true end
    if textN:find(L'завершили работу ремонтника дорог', 1, true) then return true end

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
    queue     = {},
    message   = '',
    icon      = 'info',
    timer     = 0,
    dur       = NOTIFY_DURATION,
    anim      = 0,
    animStart = 0,
    animFrom  = 0,
    animTo    = 0,
    animDur   = 0,
    animEase  = 'outQuart',
    state     = 'idle',
    version   = 0,
}

local Easing = {
    outQuart = function(x) return 1 - (1 - x)^4 end,
    inBack   = function(x)
        local c1, c3 = 1.70158, 2.70158
        return c3 * x^3 - c1 * x^2
    end,
}

local function startToastAnim(from, dest, dur, ease)
    sn.animFrom  = from
    sn.animTo    = dest
    sn.animStart = os.clock()
    sn.animDur   = dur or 0.20
    sn.animEase  = ease or 'outQuart'
    sn.anim      = from
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
        startToastAnim(sn.anim, 1, NOTIFY_ANIM_IN, 'outQuart')
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

local AUTO_CHECK_DELAY   = 6           -- сек после загрузки скрипта
local AUTO_CHECK_EVERY   = 30 * 60     -- сек между тихими проверками
local DOWNLOAD_TIMEOUT   = 25          -- сек на одну попытку загрузки
local MIN_SCRIPT_SIZE    = 20000       -- байт: защита от HTML/обрезки

local updateAvailable     = false
local updateDownloading   = false
local remoteVersion       = ''
local updaterStatus       = L'не проверялось'
local lastAutoCheck       = 0
local promptedVersion     = nil
local updProg             = { pct = 0, disp = 0, bytes = 0, total = 0, stage = '', startedAt = 0 }

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
    if #list == 0 then return L'нет' end
    return table.concat(list, ', ')
end

local function urlNoCache(url)
    return url .. (url:find('?', 1, true) and '&' or '?') .. 'nocache=' .. tostring(os.time())
end

-- Сравнение версий формата a1.0 / a1.0.1 / c1.10 > c1.9 (и совместимость со старыми 30.1.0)
local function parseVer(s)
    local clean = tostring(s or ''):gsub('%s+', ''):gsub('^[vV]', '')
    local gen, maj, min, hot = clean:match('^([a-zA-Z]?)(%d+)%.(%d+)%.?(%d*)$')
    if not maj then return nil end
    local genNum = (gen and gen ~= '') and gen:lower():byte() or 0
    return { genNum, tonumber(maj) or 0, tonumber(min) or 0, tonumber(hot) or 0 }
end

local function verLt(a, b)
    local pa, pb = parseVer(a), parseVer(b)
    if not pa or not pb then return false end
    for i = 1, 4 do
        if pa[i] < pb[i] then return true end
        if pa[i] > pb[i] then return false end
    end
    return false
end

local function fmtVer(v)
    v = tostring(v or '')
    if v == '' then return '?' end
    if v:match('^[a-zA-Z]') then return v end
    return 'v' .. v
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

local function socketRequestOnce(url, onProgress)
    local body = {}
    local received = 0
    local sink = function(chunk)
        if chunk then
            body[#body + 1] = chunk
            received = received + #chunk
            if type(onProgress) == 'function' then
                onProgress(5, received, 0)
            end
        end
        return 1
    end

    local isHttps = url:match('^https') ~= nil
    local lib = isHttps and https or http
    if not lib then
        return nil, nil, isHttps and L'нет ssl.https' or L'нет socket.http'
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

local function socketFetch(url, onProgress)
    local current = urlNoCache(url)
    for attempt = 1, 4 do
        local text, code, err, location = socketRequestOnce(current, onProgress)
        if text then
            if text == '' then return nil, L'пустой ответ' end
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
    return nil, L'слишком много редиректов'
end

local function rawFetch(url, timeout, onProgress)
    local tmp = WORK_DIR .. '/hfj_upd_tmp.txt'
    os.remove(tmp)
    local finished = false
    local gotCbBytes = false
    local ok = pcall(downloadUrlToFile, urlNoCache(url), tmp, function(id, status, p1, p2)
        local n1, n2 = tonumber(p1) or 0, tonumber(p2) or 0
        if n1 > 0 then gotCbBytes = true end
        if type(onProgress) == 'function' then
            onProgress(status, n1, n2)
        end
        if status == DS_END then finished = true end
    end)
    if not ok then return nil, L'downloadUrlToFile недоступен' end
    local t0 = os.time()
    local nextPoll = os.clock() + 0.10
    while not finished and (os.time() - t0) < (timeout or DOWNLOAD_TIMEOUT) do
        wait(0)
        if type(onProgress) == 'function' and not gotCbBytes and os.clock() >= nextPoll then
            nextPoll = os.clock() + 0.10
            local f = io.open(tmp, 'rb')
            if f then
                local sz = f:seek('end') or 0
                f:close()
                if sz > 0 then onProgress(5, sz, 0) end
            end
        end
    end
    local content = finished and readFile(tmp) or nil
    os.remove(tmp)
    if not content or content == '' then return nil, L'таймаут downloadUrlToFile' end
    return content
end

local function requestsFetch(url, onProgress)
    if not hasRequests then return nil, L'нет requests' end
    if type(onProgress) == 'function' then onProgress(2, 0, 0) end
    local ok, resp = pcall(requestsLib.request, 'GET', urlNoCache(url))
    if not ok or not resp then return nil, 'requests: ' .. tostring(resp) end
    local code = tonumber(resp.status_code) or 0
    if code ~= 200 then return nil, 'requests HTTP ' .. tostring(code) end
    local body = resp.text or resp.content
    if not body or body == '' then return nil, L'requests: пустой ответ' end
    if type(onProgress) == 'function' then onProgress(DS_END, #body, #body) end
    return body
end

local function fetchText(url, timeout, onProgress)
    local errors = {}

    if hasRequests then
        local body, err = requestsFetch(url, onProgress)
        if body then return body end
        errors[#errors + 1] = 'requests: ' .. tostring(err)
        logAct('Fetch fail (requests): ' .. tostring(err))
    end
    if hasSecureHttp or (okHttp and http) then
        local body, err = socketFetch(url, onProgress)
        if body then return body end
        errors[#errors + 1] = 'socket: ' .. tostring(err)
        logAct('Fetch fail (socket): ' .. tostring(err))
    end
    if hasRawDownload then
        local body, err = rawFetch(url, timeout, onProgress)
        if body then return body end
        errors[#errors + 1] = 'raw: ' .. tostring(err)
        logAct('Fetch fail (downloadUrlToFile): ' .. tostring(err))
    end

    if #errors == 0 then return nil, L'нет транспорта' end
    return nil, table.concat(errors, ' | ')
end

local function applyVersionText(text)
    local raw = tostring(text or ''):gsub('^\239\187\191', '')
    if #raw > 200 then return 'err' end
    local cleaned = raw:gsub('%s+', '')
    local ver = cleaned:match('^v?([a-zA-Z]?%d+%.%d+%.?%d*)$')
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

-- Открываем фирменное стилизованное окно обновления
local function promptUpdate()
    if not updateAvailable then return end
    if promptedVersion == remoteVersion then return end
    promptedVersion = remoteVersion
    updateModal[0] = true
    updateModalAlpha = 0
    logAct('Update modal opened for ' .. fmtVer(remoteVersion))
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
            updaterStatus = L'доступно ' .. fmtVer(remoteVersion)
            logAct('Update available: ' .. fmtVer(remoteVersion) .. ' (local ' .. fmtVer(LOCAL_VERSION) .. ')')
            if not silent or promptedVersion ~= remoteVersion then
                notify(L'Доступно обновление: ' .. fmtVer(remoteVersion), 0xFFAA00)
            end
            if thenDownload then doUpdate() else promptUpdate() end
        elseif st == 'same' then
            updaterStatus = L'последняя версия'
            logAct('Check ok: up to date (' .. fmtVer(LOCAL_VERSION) .. ')')
            if not silent then notify(L'У вас последняя версия: ' .. fmtVer(LOCAL_VERSION), 0x00FF00) end
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
    updaterStatus = L'скачиваю ' .. fmtVer(remoteVersion)
    updProg.pct       = 0.05
    updProg.disp      = 0.02
    updProg.bytes     = 0
    updProg.total     = 0
    updProg.stage     = L'Подключаемся к серверу...'
    updProg.startedAt = os.clock()
    if not updateModal[0] then
        updateModal[0] = true
        updateModalAlpha = 0
    end
    notify(L'Скачиваю обновление ' .. fmtVer(remoteVersion) .. '...', 0x00CCB3)

    lua_thread.create(function()
        local function onDlProgress(status, p1, p2)
            if status == DS_END then
                updProg.pct = math.max(updProg.pct, 0.88)
                updProg.stage = L'Файл скачан, проверяем...'
            elseif p2 > 0 and p1 > 0 then
                updProg.bytes = p1
                updProg.total = p2
                updProg.pct = math.max(updProg.pct, math.min(0.88, (p1 / p2) * 0.88))
                updProg.stage = L'Загрузка файла обновления...'
            elseif p1 > 0 then
                updProg.bytes = p1
                updProg.pct = math.max(updProg.pct, math.min(0.84, (p1 / 145000) * 0.84))
                updProg.stage = L'Загрузка файла обновления...'
            else
                updProg.pct = math.max(updProg.pct, 0.14)
            end
        end

        local ok, body, err = pcall(fetchText, UPDATE_URL_SCRIPT, DOWNLOAD_TIMEOUT, onDlProgress)
        if not ok then body, err = nil, tostring(body) end

        if not body or body == '' then
            updateDownloading = false
            updProg.pct = 0; updProg.disp = 0
            updaterStatus = L'ошибка загрузки'
            updProg.stage = updaterStatus
            logErr('Update download failed: ' .. tostring(err))
            notify(L'Ошибка скачивания обновления', 0xFF0000)
            return
        end

        updProg.bytes = #body
        updProg.total = #body
        updProg.pct   = 0.91
        updProg.stage = L'Проверяем целостность файла...'
        wait(120)

        if #body < MIN_SCRIPT_SIZE then
            updateDownloading = false
            updProg.pct = 0; updProg.disp = 0
            updaterStatus = L'файл повреждён'
            updProg.stage = updaterStatus
            logAct('Download rejected: too small (' .. #body .. ' b)')
            notify(L'Скачался битый файл (' .. #body .. L' байт)', 0xFF0000)
            return
        end

        if not body:find('script_name', 1, true) then
            updateDownloading = false
            updProg.pct = 0; updProg.disp = 0
            updaterStatus = L'это не скрипт'
            updProg.stage = updaterStatus
            logAct('Download rejected: no script_name')
            notify(L'На сервере лежит не скрипт', 0xFF0000)
            return
        end

        local dlVer = body:match("script_version%s*%(%s*['\"](v?[a-zA-Z]?%d+%.%d+%.?%d*)['\"]")
        if dlVer and remoteVersion ~= '' and dlVer ~= remoteVersion then
            logAct('Warning: version.txt = ' .. remoteVersion .. ', file = ' .. dlVer)
        end

        updProg.pct   = 0.95
        updProg.stage = L'Устанавливаем обновление...'
        wait(120)

        local tmp = WORK_DIR .. '/hfj_update.lua'
        if not writeFile(tmp, body) then
            updateDownloading = false
            updProg.pct = 0; updProg.disp = 0
            updaterStatus = L'ошибка записи'
            updProg.stage = updaterStatus
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
            updateDownloading = false
            updProg.pct = 0; updProg.disp = 0
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

        updProg.pct   = 1.0
        updProg.stage = L'Готово! Перезапускаем скрипт :D'
        updateAvailable   = false
        promptedVersion   = nil
        updaterStatus     = L'установлено ' .. fmtVer(dlVer or remoteVersion)
        logAct('Update installed: ' .. fmtVer(dlVer or remoteVersion) .. ' -> ' .. tostring(dest))
        notify(L'Обновление установлено - перезапуск...', 0x00FF00)
        wait(950)

        updateDownloading = false
        updateModal[0]    = false
        wait(200)

        local okInfo, info = pcall(thisScript)
        if okInfo and info then
            local okReload = pcall(function() info:reload() end)
            if okReload then logAct('Script reloaded') end
        end
    end)
end

local function startUpdateCheck()
    logAct('Updater: transports = ' .. updaterTransportsText()
        .. ', local ' .. fmtVer(LOCAL_VERSION))
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
local function stripColors(t)
    if not t then return '' end
    return (t:gsub('{%x%x%x%x%x%x}', ''):gsub('{%x%x%x%x%x%x%x%x}', ''))
end

local ZP_JOB_LIST = {
    { key = 'taxi',       label = L'Такси',               icon = 'taxi'       },
    { key = 'roadworker', label = L'Ремонтник дорог',     icon = 'roadworker' },
    { key = 'trucker',    label = L'Дальнобойщик',        icon = 'trucker'    },
    { key = 'collector',  label = L'Инкассатор',          icon = 'collector'  },
    { key = 'deliverer',  label = L'Развозчик продуктов', icon = 'deliverer'  },
    { key = 'mechanic',   label = L'Механик',             icon = 'mechanic'   },
    { key = 'bus',        label = L'Водитель автобуса',   icon = 'bus'        },
    { key = 'garbage',    label = L'Мусорщик',            icon = 'garbage'    },
}
local ZP_LABEL = {}
for _, j in ipairs(ZP_JOB_LIST) do ZP_LABEL[j.key] = j.label end
local ZP_DIALOG_ID = 8888

local function zpTotal()
    return ZP.taxi + ZP.roadworker + ZP.trucker + ZP.collector
         + ZP.deliverer + ZP.mechanic + ZP.bus + ZP.garbage
end

local function zpReportText()
    local lines = {
        L'Автоловля заказов:',
        string.format(L'  Заказов выполнено: %d', CFG.ordersDone),
        '',
        L'Выплаты по работам:',
        L'  Такси:             $' .. zpFormatMoney(ZP.taxi),
        L'  Ремонтник дорог:   $' .. zpFormatMoney(ZP.roadworker),
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
    ZP.taxi, ZP.roadworker, ZP.trucker, ZP.collector = 0, 0, 0, 0
    ZP.deliverer, ZP.mechanic, ZP.bus, ZP.garbage    = 0, 0, 0, 0
    statDispOrders  = 0
    statDispMoney   = 0
    statDispTotal   = 0
    markDirty()
    saveCfg()
end

-- ============================================================
--  СОСТОЯНИЕ АВТОЛОВЛИ И СМЕН (ACTIVE JOB STATE MACHINE)
-- ============================================================
local awaitingDialog          = false
local awaitingExpire          = 0
local lastTapTime             = -CATCH.TAP_COOLDOWN * 1000
local hasActiveOrder          = false
local pendingAccept           = nil
local pendingDialogReply      = nil
local tapSequenceActive       = false
local tapSeqIndex             = 0
local tapSeqNextSend          = 0
local orderConfirmedByServer  = false
local lastAcceptedDialogId    = nil
local lastAcceptedDialogStyle = nil
local lastAcceptAt            = 0
local acceptConfirmExpire     = 0

local JOB_STATE = {
    activeJob           = nil,
    jobStartedAt        = 0,
    lastJobEventAt      = 0,
    nonJobBlockUntil    = 0,
    taxiErrorBlockUntil = 0,
    lastOrderConfirmAt  = 0,
    lastOrderCancelAt   = 0,
    lastOrderErrorAt    = 0,
    orderBurstAt        = 0,
    orderBurstCount     = 0,
    burstRetryUsed      = false,
    firstCatchWarnShown = false,
    taxiHudPayPendingAt = nil,
    busShiftAccum       = 0,
    roadShiftAccum      = 0,
    lastJobHudPayAt     = {},
    lastJobChatPayAt    = {},
    pendingChatPayouts  = {},
}

local function setActiveJob(job, reason)
    if job ~= 'taxi' and (hasActiveOrder or pendingAccept or tapSequenceActive or awaitingDialog or pendingDialogReply) then
        hasActiveOrder          = false
        pendingAccept           = nil
        pendingDialogReply      = nil
        awaitingDialog          = false
        tapSequenceActive       = false
        orderConfirmedByServer  = false
        lastAcceptedDialogId    = nil
        lastAcceptedDialogStyle = nil
        lastAcceptAt            = 0
        acceptConfirmExpire     = 0
        JOB_STATE.taxiHudPayPendingAt = nil
        logAct('Order state cleared on job change -> ' .. tostring(job or 'none') .. ' (' .. tostring(reason or '') .. ')')
    end
    if JOB_STATE.activeJob ~= job then
        if job == 'bus' then JOB_STATE.busShiftAccum = 0 end
        if job == 'roadworker' then JOB_STATE.roadShiftAccum = 0 end
        JOB_STATE.activeJob = job
        JOB_STATE.jobStartedAt = os.clock()
        logAct('ActiveJob -> ' .. tostring(job or 'none') .. ' (' .. tostring(reason or '') .. ')')
    end
    JOB_STATE.lastJobEventAt = os.clock()
end

local function blockNonJob(seconds, reason)
    local untilT = os.clock() + (seconds or 2.5)
    if untilT > JOB_STATE.nonJobBlockUntil then
        JOB_STATE.nonJobBlockUntil = untilT
        logAct('NonJob guard ' .. string.format('%.1fs', seconds or 2.5) .. ': ' .. tostring(reason))
    end
end

local function creditJobPayout(job, amount, sourceTag, silentToast)
    if not job or not ZP[job] or not amount or amount <= 0 then return end
    ZP[job] = ZP[job] + amount
    if job == 'taxi' then
        CFG.moneyEarned = CFG.moneyEarned + amount
    elseif job == 'bus' then
        JOB_STATE.busShiftAccum = JOB_STATE.busShiftAccum + amount
    elseif job == 'roadworker' then
        JOB_STATE.roadShiftAccum = JOB_STATE.roadShiftAccum + amount
    end
    markDirty()
    logAct(string.format('Payout[%s] %s +%d (total %d)',
        tostring(sourceTag or 'log'), job, math.floor(amount), math.floor(ZP[job])))
    if not silentToast then
        notify(L'ЗП ' .. ZP_LABEL[job] .. ': +$' .. zpFormatMoney(amount) ..
            L' | Всего: $' .. zpFormatMoney(ZP[job]), 0x00FF00)
    end
end

-- ============================================================
--  NEOMLOADER LOG TAILER (ОБЛЕГЧЁННЫЙ PACKET 220 + DIALOGTRACKER)
-- ============================================================
local NEOM_POLL_INTERVAL = 0.45   -- бережный опрос (~2 раза/сек, без фризов на Android)
local NEOM_CHUNK_BYTES   = 49152  -- ограниченный размер чтения за кадр (48 КБ)
local MAX_SINGLE_JOB_PAY = 50000000

local NEOM = {
    path           = nil,
    found          = false,
    offset         = 0,
    partial        = '',
    lastPoll       = 0,
    lastHudBalance = nil,
    hasInitBalance = false,
    lastDelta      = 0,
    lastDeltaAt    = 0,
    packetsRead    = 0,
    nextRescanAt   = 0,
    warnedMissing  = false,
}

local function findNeomLogPath()
    local workClean = tostring(WORK_DIR or ''):gsub('/+$', '')
    local parentDir = workClean:match('^(.+)/[^/]+$')
    local candidates = {
        workClean .. '/neomloader.log',
        workClean .. '/logs/neomloader.log',
        parentDir and (parentDir .. '/neomloader.log') or nil,
        workClean .. '/monetloader.log',
        parentDir and (parentDir .. '/monetloader.log') or nil,
        '/sdcard/Android/media/com.arizona21.game.web/neomloader/neomloader.log',
        '/storage/emulated/0/Android/media/com.arizona21.game.web/neomloader/neomloader.log',
        '/sdcard/Android/media/com.arizona.game/neomloader/neomloader.log',
        '/sdcard/Android/media/com.arizona21.game/neomloader/neomloader.log',
        '/sdcard/Android/media/com.arizona21.game.web/monetloader/monetloader.log',
        '/sdcard/Android/media/com.arizona.game/monetloader/monetloader.log',
    }
    for _, p in ipairs(candidates) do
        if p then
            local f = io.open(p, 'rb')
            if f then
                f:close()
                return p
            end
        end
    end
    return nil
end

local function initNeomTailer()
    local p = findNeomLogPath()
    if not p then
        NEOM.path  = nil
        NEOM.found = false
        if not NEOM.warnedMissing then
            NEOM.warnedMissing = true
            logAct('NeomLog not found (WORK_DIR=' .. tostring(WORK_DIR) .. ')')
        end
        return false
    end
    NEOM.path  = p
    NEOM.found = true

    local f = io.open(p, 'rb')
    if not f then
        NEOM.found = false
        return false
    end
    local size = f:seek('end') or 0
    if size > 0 then
        local tailStart = math.max(0, size - 32768)
        f:seek('set', tailStart)
        local tailChunk = f:read('*a') or ''
        local lastRaw = nil
        for rawStr in tailChunk:gmatch("%[Money%] Intercepted Packet 220 HUD balance: %$%-?%d+ %(raw='(%-?%d+)'%)") do
            lastRaw = rawStr
        end
        if lastRaw then
            local b = tonumber(lastRaw)
            if b then
                NEOM.lastHudBalance = b
                NEOM.hasInitBalance = true
            end
        end
    end
    f:close()

    NEOM.offset  = size
    NEOM.partial = ''
    logAct('NeomLog connected: ' .. p .. ' (offset=' .. size
        .. ', initBal=' .. tostring(NEOM.lastHudBalance or 'wait') .. ')')
    return true
end

local function onHudBalanceIncrease(delta)
    local now = os.clock()
    NEOM.lastDelta   = delta
    NEOM.lastDeltaAt = now

    if delta > MAX_SINGLE_JOB_PAY then
        logAct(string.format('Packet220 +%d skipped (>MAX_SINGLE_JOB_PAY)', delta))
        return
    end

    if now < JOB_STATE.nonJobBlockUntil then
        logAct(string.format('Packet220 +%d blocked by NonJob guard', delta))
        return
    end

    local job = JOB_STATE.activeJob
    if not job then
        logAct(string.format('Packet220 +%d ignored (no activeJob)', delta))
        return
    end

    -- Защита от дублирования: если этот платёж только что засчитан chat-fallback
    local chatAt = JOB_STATE.lastJobChatPayAt[job] or 0
    if (now - chatAt) < 4.0 then
        logAct(string.format('Packet220 +%d skipped for %s (already counted by chat)', delta, job))
        return
    end

    -- Если в очереди есть отложенный chat-fallback для этой работы — отменяем его (Packet 220 точнее)
    for i = #JOB_STATE.pendingChatPayouts, 1, -1 do
        if JOB_STATE.pendingChatPayouts[i].job == job then
            table.remove(JOB_STATE.pendingChatPayouts, i)
        end
    end

    JOB_STATE.lastJobHudPayAt[job] = now

    if job == 'taxi' and hasActiveOrder and orderConfirmedByServer
       and (now - JOB_STATE.lastOrderConfirmAt) > 3.0 and delta >= 1000 then
        if not JOB_STATE.taxiHudPayPendingAt then
            JOB_STATE.taxiHudPayPendingAt = now
        end
    end

    local isFrequentTick = ((job == 'bus' or job == 'roadworker') and delta < 100000)
    creditJobPayout(job, delta, 'Packet220', isFrequentTick)
end

local function processNeomLogLine(line)
    if not line or line == '' then return end
    -- Быстрая фильтрация: отсекаем 99% строк BulletTracer/скриптов без тяжёлых regex
    local hasMoney = line:find('[Money]', 1, true) ~= nil
    local hasDlg   = not hasMoney and (line:find('[DialogTracker]', 1, true) ~= nil)
    if not hasMoney and not hasDlg then return end
    if line:find('(script)', 1, true) then return end

    if hasMoney then
        local rawStr = line:match("%[Money%] Intercepted Packet 220 HUD balance: %$%-?%d+ %(raw='(%-?%d+)'%)")
        if rawStr then
            local val = tonumber(rawStr)
            if val then
                if not NEOM.hasInitBalance then
                    NEOM.lastHudBalance = val
                    NEOM.hasInitBalance = true
                    logAct('Packet220 baseline set: $' .. zpFormatMoney(val))
                else
                    local delta = val - NEOM.lastHudBalance
                    NEOM.lastHudBalance = val
                    NEOM.packetsRead = NEOM.packetsRead + 1
                    if delta > 0 then
                        onHudBalanceIncrease(delta)
                    elseif delta < 0 then
                        logAct(string.format('Packet220 expense: %d', delta))
                    end
                end
            end
        end
        return
    end

    local dlgId = line:match("%[DialogTracker%] Incoming ShowDialog RPC: id=(%d+)")
    if dlgId then
        local idNum = tonumber(dlgId)
        if idNum == 27650 then setActiveJob('roadworker', 'DialogTracker#27650')
        elseif idNum == 26920 or idNum == 15324 then setActiveJob('taxi', 'DialogTracker#' .. idNum)
        elseif idNum == 15558 or idNum == 15507 then setActiveJob('trucker', 'DialogTracker#' .. idNum)
        elseif idNum == 282 or idNum == 283 then setActiveJob('bus', 'DialogTracker#' .. idNum)
        elseif idNum == 27384 or idNum == 27379 then setActiveJob('deliverer', 'DialogTracker#' .. idNum)
        elseif idNum == 26815 or idNum == 26237 or idNum == 661 then setActiveJob('mechanic', 'DialogTracker#' .. idNum)
        end
    end
end

local function pollNeomLog(now)
    if not CFG.useLogTracker then return end
    if (now - NEOM.lastPoll) < NEOM_POLL_INTERVAL then return end
    NEOM.lastPoll = now

    if not NEOM.found or not NEOM.path then
        if now >= NEOM.nextRescanAt then
            NEOM.nextRescanAt = now + 5.0
            initNeomTailer()
        end
        return
    end

    local f = io.open(NEOM.path, 'rb')
    if not f then
        NEOM.found = false
        NEOM.nextRescanAt = now + 5.0
        return
    end

    local size = f:seek('end') or 0
    if size < NEOM.offset then
        NEOM.offset  = 0
        NEOM.partial = ''
        NEOM.hasInitBalance = false
        logAct('NeomLog truncated/rotated, offset reset to 0')
    end

    if size == NEOM.offset then
        f:close()
        return
    end

    -- Если накопилось > 512 КБ (например, из-за спама пакетов в фоне), перескакиваем ближе к хвосту чтобы не вешать FPS
    local backlog = size - NEOM.offset
    if backlog > 524288 then
        NEOM.offset  = size - 65536
        NEOM.partial = ''
        logAct(string.format('NeomLog fast-forward (%d bytes backlog)', backlog))
    end

    f:seek('set', NEOM.offset)
    local toRead = math.min(NEOM_CHUNK_BYTES, size - NEOM.offset)
    local chunk = f:read(toRead) or ''
    NEOM.offset = NEOM.offset + #chunk
    f:close()

    if chunk == '' then return end
    local buf = NEOM.partial .. chunk
    local pos = 1
    while true do
        local nl = buf:find('\n', pos, true)
        if not nl then break end
        local line = buf:sub(pos, nl - 1):gsub('\r$', '')
        processNeomLogLine(line)
        pos = nl + 1
    end
    NEOM.partial = buf:sub(pos)
end

local function finishOrder(reason, count)
    pendingDialogReply = nil
    JOB_STATE.taxiHudPayPendingAt = nil
    if count == false then
        if not hasActiveOrder and not pendingAccept and not awaitingDialog and not tapSequenceActive then
            if reason == 'manual' then
                notify(L'Активный заказ или поиск отсутствует', 0xFFAA00)
            end
            return
        end
        hasActiveOrder          = false
        pendingAccept           = nil
        awaitingDialog          = false
        tapSequenceActive       = false
        orderConfirmedByServer  = false
        lastAcceptedDialogId    = nil
        lastAcceptedDialogStyle = nil
        lastAcceptAt            = 0
        acceptConfirmExpire     = 0
        logAct('Order reset (not counted): ' .. tostring(reason))
        notify(L'Заказ сброшен: ' .. tostring(reason), 0xFFAA00)
    else
        if not hasActiveOrder then return end
        hasActiveOrder          = false
        pendingAccept           = nil
        awaitingDialog          = false
        tapSequenceActive       = false
        orderConfirmedByServer  = false
        lastAcceptedDialogId    = nil
        lastAcceptedDialogStyle = nil
        lastAcceptAt            = 0
        acceptConfirmExpire     = 0
        CFG.ordersDone = CFG.ordersDone + 1
        markDirty()
        logAct('Order done: ' .. tostring(reason))
        notify(L'Заказ завершён. Счёт: ' .. CFG.ordersDone, 0x00FF00)
    end
end

local function resetCatchCycle(reason)
    tapSequenceActive = false
    awaitingDialog    = false
    if reason == 'cancelled/taken' or reason == 'dialog error cancel' then
        lastTapTime = (os.clock() * 1000) - CATCH.TAP_COOLDOWN
    end
    logAct('Reset cycle: ' .. tostring(reason))
end

-- ============================================================
--  СОБЫТИЯ ЧАТА (КОНТЕКСТ СМЕН + PAYDAY + FALLBACK)
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

local function isPayDayLine(cleanN)
    return cleanN:find(L'банковский чек', 1, true)
        or cleanN:find(L'текущая сумма в банке', 1, true)
        or cleanN:find(L'текущая сумма на депозите', 1, true)
        or cleanN:find(L'общая заработная плата', 1, true)
        or cleanN:find(L'дивидентный договор', 1, true)
        or cleanN:find(L'баланс на донат-счет', 1, true)
        or cleanN:find(L'премия за работу таксистом', 1, true)
        or cleanN:find(L'чаевых таксиста', 1, true)
end

local function updateJobContextFromChat(cleanN)
    -- Переключение активной работы по явным системным сообщениям
    if cleanN:find(L'вы начали работу таксистом', 1, true) then
        setActiveJob('taxi', 'chat-start'); return
    end
    if cleanN:find(L'вы начали работу ремонтника дорог', 1, true) then
        setActiveJob('roadworker', 'chat-start'); return
    end
    if cleanN:find(L'база дальнобойщиков', 1, true)
       or cleanN:find(L'вы получили транспорт на базе', 1, true)
       or cleanN:find(L'вы подцепили груз', 1, true) then
        setActiveJob('trucker', 'chat-start'); return
    end
    if cleanN:find(L'вы начали работу инкассатором', 1, true)
       or cleanN:find(L'назначенный для разгрузки', 1, true) then
        setActiveJob('collector', 'chat-start'); return
    end
    if cleanN:find(L'работа водителя автобуса', 1, true)
       or cleanN:find(L'водитель автобуса', 1, true) and cleanN:find(L'начал', 1, true) then
        setActiveJob('bus', 'chat-start'); return
    end
    if cleanN:find(L'[развозчик продуктов]', 1, true) then
        setActiveJob('deliverer', 'chat-msg'); return
    end
    if cleanN:find(L'наполненой мусорки', 1, true)
       or cleanN:find(L'наполненной мусорки', 1, true)
       or cleanN:find(L'установите мусорный бак', 1, true)
       or cleanN:find(L'мусоровоз', 1, true)
       or cleanN:find(L'всего мусора:', 1, true) then
        setActiveJob('garbage', 'chat-start'); return
    end
    if cleanN:find(L'прицепили автомобиль к эвакуатору', 1, true)
       or (cleanN:find(L'[диспетчер]', 1, true) and cleanN:find(L'механик', 1, true)) then
        setActiveJob('mechanic', 'chat-start'); return
    end

    -- Защита от нерабочих денежных событий (банк, трейд, рынок, рулетка, PayDay)
    if cleanN:find(L'вы сняли со счета', 1, true)
       or cleanN:find(L'сняли с банковского счета', 1, true)
       or cleanN:find(L'перевел вам', 1, true)
       or cleanN:find(L'перевод от', 1, true)
       or cleanN:find(L'вы продали', 1, true)
       or cleanN:find(L'купил у вас', 1, true)
       or cleanN:find(L'трейд успешно', 1, true)
       or cleanN:find(L'обмен завершен', 1, true)
       or cleanN:find(L'ваш приз:', 1, true)
       or cleanN:find(L'вы выиграли', 1, true)
       or cleanN:find(L'промокод', 1, true)
       or isPayDayLine(cleanN) then
        blockNonJob(isPayDayLine(cleanN) and 3.5 or 2.5, 'chat-nonjob')
    end
end

function sampev.onServerMessage(color, text)
    local isPlayer = isPlayerMessage(text)
    local cleanRaw = stripColors(text)
    if not isPlayer then logChat(cleanRaw) end

    local cleanN = normalize(cleanRaw)

    -- При перезаходе / спавне добавляем новую секцию в лог
    if not isPlayer and (cleanN:find(L'добро пожаловать на arizona', 1, true)
       or cleanN:find(L'вы выбрали местом спавна', 1, true)) then
        logInit(L'Реконнект / Вход в игру')
        setActiveJob(nil, 'reconnect')
    end

    if not isPlayer then
        updateJobContextFromChat(cleanN)
    end

    local neomActive = CFG.useLogTracker and NEOM.found and NEOM.hasInitBalance
    local now = os.clock()

    -- Сводки конца смены автобусника / ремонтника (включая $0)
    if not isPlayer and cleanN:find(L'рабочий день завершен', 1, true) then
        local amount = zpExtractMoney(cleanRaw)
        local hudAt = JOB_STATE.lastJobHudPayAt['bus'] or 0
        local recentlyCountedByLog = neomActive and ((now - hudAt) < 8.0)
        if neomActive and JOB_STATE.busShiftAccum > 0 then
            notify(L'Смена автобуса завершена: +$' .. zpFormatMoney(JOB_STATE.busShiftAccum)
                .. L' | Всего: $' .. zpFormatMoney(ZP.bus), 0x00FF00)
        elseif amount and amount > 0 and not recentlyCountedByLog then
            creditJobPayout('bus', amount, 'chat-fallback', false)
            JOB_STATE.lastJobChatPayAt['bus'] = now
        end
        JOB_STATE.busShiftAccum = 0
        setActiveJob(nil, 'bus-shift-end')
    elseif not isPlayer and cleanN:find(L'завершили работу ремонтника дорог', 1, true) then
        local amount = zpExtractMoney(cleanRaw)
        local hudAt = JOB_STATE.lastJobHudPayAt['roadworker'] or 0
        local recentlyCountedByLog = neomActive and ((now - hudAt) < 8.0)
        if neomActive and JOB_STATE.roadShiftAccum > 0 then
            notify(L'Смена ремонтника дорог: +$' .. zpFormatMoney(JOB_STATE.roadShiftAccum)
                .. L' | Всего: $' .. zpFormatMoney(ZP.roadworker), 0x00FF00)
        elseif amount and amount > 0 and not recentlyCountedByLog then
            creditJobPayout('roadworker', amount, 'chat-fallback', false)
            JOB_STATE.lastJobChatPayAt['roadworker'] = now
        end
        JOB_STATE.roadShiftAccum = 0
        setActiveJob(nil, 'roadworker-shift-end')
    elseif not isPlayer and not isPayDayLine(cleanN) and zpIsPayout(cleanN) then
        -- Разовые выплаты всех работ (без PayDay и чаевых; без дублирования Packet 220)
        local amount = zpExtractMoney(cleanRaw)
        local job    = zpDetectJob(cleanN) or JOB_STATE.activeJob
        if amount and job then
            local hudAt = JOB_STATE.lastJobHudPayAt[job] or 0
            local recentlyCountedByLog = neomActive and ((now - hudAt) < 8.0)
            if recentlyCountedByLog then
                logAct(string.format('Chat payout skipped (already counted via Packet220): %s +%d', job, amount))
            elseif neomActive then
                -- Packet 220 часто приходит в neomloader.log на 0.4с позже чата; ждём до 1.8с перед fallback
                JOB_STATE.pendingChatPayouts[#JOB_STATE.pendingChatPayouts + 1] = {
                    job = job,
                    amount = amount,
                    fireAt = now + 1.8,
                }
            else
                creditJobPayout(job, amount, 'chat-fallback', false)
                JOB_STATE.lastJobChatPayAt[job] = now
            end
        end
    end

    -- Завершение смены / увольнение
    if not isPlayer and (cleanN:find(L'работа водителя мусорщика завершена', 1, true)
        or cleanN:find(L'вы закончили работу', 1, true)
        or cleanN:find(L'вы завершили работу', 1, true)
        or cleanN:find(L'рабочий день окончен', 1, true)
        or cleanN:find(L'рабочий день завершен', 1, true)
        or cleanN:find(L'смена завершена', 1, true)
        or cleanN:find(L'вы уволились', 1, true)) then
        setActiveJob(nil, 'chat-work-end')
    end

    -- Мгновенная остановка автоловли при ошибках такси (виртуальный мир, вне авто, не на смене и т.д.)
    if not isPlayer and (cleanN:find(L'находясь в виртуальном мире', 1, true)
        or cleanN:find(L'не можете работать в такси', 1, true)
        or cleanN:find(L'вы не работаете таксистом', 1, true)
        or cleanN:find(L'должны находиться в такси', 1, true)) then
        JOB_STATE.taxiErrorBlockUntil = os.clock() + 5.0
        if cleanN:find(L'вы не работаете таксистом', 1, true) then
            setActiveJob(nil, 'not-taxi-driver')
        end
        if tapSequenceActive or awaitingDialog or pendingAccept or pendingDialogReply then
            pendingAccept           = nil
            pendingDialogReply      = nil
            awaitingDialog          = false
            tapSequenceActive       = false
            orderConfirmedByServer  = false
            acceptConfirmExpire     = 0
            logAct('Taxi catch aborted by server error: ' .. cleanRaw)
            notify(L'Ловля остановлена: недоступно в текущей зоне', 0xFFAA00)
        end
        return
    end

    if not isPlayer and (cleanN:find(L'у вас уже принят заказ', 1, true)
        or cleanN:find(L'у вас уже есть активный заказ', 1, true)
        or cleanN:find(L'уже выполняете заказ', 1, true)) then
        if tapSequenceActive or awaitingDialog or pendingAccept then
            tapSequenceActive = false
            awaitingDialog    = false
            pendingAccept     = nil
            if JOB_STATE.activeJob == 'taxi' then
                hasActiveOrder         = true
                orderConfirmedByServer = true
            end
            logAct('Taxi catch stopped: order already active')
        end
        return
    end

    -- Если заказ такси отменили или забрали до того, как мы доехали
    local isChatOrderCancel = (cleanN:find(L'клиент', 1, true) ~= nil and cleanN:find(L'отменил', 1, true) ~= nil and cleanN:find(L'заказ', 1, true) ~= nil)
        or cleanN:find(L'отменил заказ', 1, true) ~= nil
        or cleanN:find(L'заказ уже принят', 1, true) ~= nil
        or cleanN:find(L'заказ недоступен', 1, true) ~= nil
        or cleanN:find(L'заказ не найден', 1, true) ~= nil
        or cleanN:find(L'заказ отмен', 1, true) ~= nil
        or cleanN:find(L'заказ больше не', 1, true) ~= nil
    if not isPlayer and isChatOrderCancel then
        if pendingAccept or hasActiveOrder or awaitingDialog or tapSequenceActive or pendingDialogReply then
            local wasConfirmed = orderConfirmedByServer
            hasActiveOrder          = false
            pendingAccept           = nil
            pendingDialogReply      = nil
            orderConfirmedByServer  = false
            lastAcceptedDialogId    = nil
            lastAcceptedDialogStyle = nil
            lastAcceptAt            = 0
            acceptConfirmExpire     = 0
            JOB_STATE.taxiHudPayPendingAt = nil

            local canBurstRetry = CFG.catchEnabled and (not wasConfirmed)
                and (not JOB_STATE.burstRetryUsed)
                and (JOB_STATE.orderBurstCount > 1)
                and ((now - JOB_STATE.orderBurstAt) <= 2.5)
                and (now >= JOB_STATE.taxiErrorBlockUntil)

            if canBurstRetry then
                JOB_STATE.burstRetryUsed   = true
                JOB_STATE.lastOrderErrorAt = now
                lastTapTime             = now * 1000
                awaitingDialog          = true
                awaitingExpire          = now + 5.0
                tapSequenceActive       = true
                pendingAccept           = now
                if CFG.turboCatch then
                    sendTapPacketWithIndex(0)
                    tapSeqIndex    = 1
                    tapSeqNextSend = now + (CATCH.TAP_STEP_TURBO / 1000)
                    logAct('Burst retry (TURBO 0ms) on next order in batch')
                else
                    local reactMs = humanDelayMs(CATCH.REACT_DELAY_MIN, CATCH.REACT_DELAY_MAX)
                    tapSeqIndex    = 0
                    tapSeqNextSend = now + (reactMs / 1000)
                    logAct(string.format('Burst retry (#2 of %d, react=%dms)', JOB_STATE.orderBurstCount, reactMs))
                end
                if type(sampSetCurrentDialogId) == 'function' then sampSetCurrentDialogId(-1) end
                return
            end

            logAct('Order cancelled or taken by another player')
            JOB_STATE.lastOrderCancelAt = now
            if not wasConfirmed then JOB_STATE.lastOrderErrorAt = now end
            resetCatchCycle('cancelled/taken')
            notify(L'Заказ отменен/перехвачен, жду новый...', 0xFFAA00)
            if type(sampSetCurrentDialogId) == 'function' then sampSetCurrentDialogId(-1) end
            return
        end
    end

    -- Подтверждение заказа ТАКСИ (изолировано от вызовов механика!)
    local isTaxiContext = (JOB_STATE.activeJob == 'taxi' or JOB_STATE.activeJob == nil
        or pendingAccept ~= nil or tapSequenceActive or awaitingDialog)
    if not isPlayer and isTaxiContext and (
          cleanN:find(L'бонус таксиста', 1, true)
       or cleanN:find(L'отправился к клиенту', 1, true)
       or cleanN:find(L'вы приняли заказ', 1, true)
       or (cleanN:find(L'вы приняли вызов', 1, true) and JOB_STATE.activeJob ~= 'mechanic')) then
        setActiveJob('taxi', 'order-confirmed')
        hasActiveOrder                = true
        orderConfirmedByServer        = true
        JOB_STATE.lastOrderConfirmAt  = os.clock()
        JOB_STATE.taxiHudPayPendingAt = nil
        pendingAccept                 = nil
        awaitingDialog                = false
        tapSequenceActive             = false
        acceptConfirmExpire           = 0
        logAct('Order confirmed by server message')
        notify(L'Заказ принят! Метка на карте', 0x00FF00)
        return
    end

    if hasActiveOrder and not isPlayer and not isPayDayLine(cleanN) then
        if cleanN:find(L'вы доставили клиента', 1, true)
           or cleanN:find(L'вы доставили клиента по имени', 1, true)
           or (cleanN:find(L'[такси]', 1, true) and cleanN:find(L'клиент оплатил', 1, true)) then
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
        if cleanN:find(L'вы прервали заказ', 1, true)
           or cleanN:find(L'вы закончили работу', 1, true) then
            finishOrder(L'прерван/закончен', false); return
        end
    end

    local isExplicitTaxiMsg = cleanN:find(L'[такси]', 1, true) ~= nil
    local isOrderChatLine = false
    if CFG.catchEnabled and not isPlayer and not hasActiveOrder
       and (isExplicitTaxiMsg or JOB_STATE.activeJob == 'taxi') then
        for _, pat in ipairs(ORDER_PATTERNS) do
            if cleanN:find(pat, 1, true) then isOrderChatLine = true; break end
        end
        if isOrderChatLine then
            if (now - JOB_STATE.orderBurstAt) <= 1.2 then
                JOB_STATE.orderBurstCount = JOB_STATE.orderBurstCount + 1
            else
                JOB_STATE.orderBurstCount = 1
                JOB_STATE.orderBurstAt    = now
                JOB_STATE.burstRetryUsed  = false
            end
        end
    end

    if CFG.catchEnabled
       and not isPlayer
       and not hasActiveOrder
       and not tapSequenceActive
       and not awaitingDialog
       and not pendingAccept
       and os.clock() >= JOB_STATE.taxiErrorBlockUntil
       and (isExplicitTaxiMsg or JOB_STATE.activeJob == nil or JOB_STATE.activeJob == 'taxi') then
        local matched = isOrderChatLine
        if not matched and (isExplicitTaxiMsg or JOB_STATE.activeJob == 'taxi') then
            for _, pat in ipairs(ORDER_PATTERNS) do
                if cleanN:find(pat, 1, true) then matched = true; break end
            end
        end
        if matched then
            local inInterior = (type(getActiveInterior) == 'function') and (getActiveInterior() ~= 0)
            if inInterior then
                logAct('New order skipped: player in interior')
                return
            end
            if (os.clock() * 1000) < lastTapTime + CATCH.TAP_COOLDOWN then return end
            lastTapTime             = os.clock() * 1000
            awaitingDialog          = true
            awaitingExpire          = os.clock() + 7.5
            tapSequenceActive       = true
            pendingAccept           = os.clock()
            orderConfirmedByServer  = false
            lastAcceptedDialogId    = nil
            lastAcceptedDialogStyle = nil
            lastAcceptAt            = 0
            acceptConfirmExpire     = 0
            if isExplicitTaxiMsg then setActiveJob('taxi', 'taxi-order-msg') end

            if CFG.turboCatch then
                sendTapPacketWithIndex(0)
                tapSeqIndex    = 1
                tapSeqNextSend = os.clock() + (CATCH.TAP_STEP_TURBO / 1000)
                logAct('New order (TURBO 0ms) - targeted tap #1')
                notify(L'Новый заказ, ловлю (Турбо 0мс)...', 0x00CCB3)
            else
                -- В обычном режиме делаем быструю живую паузу реакции перед 1-м тапом
                local reactMs = humanDelayMs(CATCH.REACT_DELAY_MIN, CATCH.REACT_DELAY_MAX)
                tapSeqIndex    = 0
                tapSeqNextSend = os.clock() + (reactMs / 1000)
                logAct(string.format('New order (human react=%dms) - waiting', reactMs))
                notify(L'Новый заказ, ловлю (' .. reactMs .. L' мс)...', 0x00CCB3)
            end
        end
    end
end

-- ============================================================
--  СОБЫТИЯ ДИАЛОГОВ
-- ============================================================
local function executeDialogAcceptNow(id, style, delayMs, isTwoStepConfirm)
    sampSendDialogResponse(id, 1, 0, '')
    if type(sampGetCurrentDialogId) == 'function' and type(sampSetCurrentDialogId) == 'function' then
        local okId, curId = pcall(sampGetCurrentDialogId)
        if okId and curId == id then sampSetCurrentDialogId(-1) end
    end
    notify(CFG.turboCatch and L'Авто-приём (Турбо)' or (L'Авто-приём (' .. delayMs .. L' мс)'), 0x00FF00)
    logAct(string.format('Auto-accept id=%s style=%s delay=%dms (%s)',
        tostring(id), tostring(style), delayMs,
        CFG.turboCatch and 'turbo-0ms' or (isTwoStepConfirm and 'human-confirm' or 'human-staggered')))
end

local function sendAcceptDialogNow(id, style, isTwoStepConfirm)
    local delayMs = CFG.turboCatch and 0 or humanDelayMs(CATCH.ACCEPT_DELAY_MIN, CATCH.ACCEPT_DELAY_MAX)
    if delayMs > 0 then
        pendingDialogReply = {
            id = id,
            style = style,
            delayMs = delayMs,
            isTwoStepConfirm = isTwoStepConfirm,
            sendAt = os.clock() + (delayMs / 1000),
        }
    else
        pendingDialogReply = nil
        executeDialogAcceptNow(id, style, 0, isTwoStepConfirm)
    end
end

function sampev.onShowDialog(id, style, title, b1, b2, text)
    logDlg(string.format('id=%s title=%q b1=%q b2=%q',
        tostring(id), tostring(title), tostring(b1), tostring(b2)))

    if tonumber(id) == ZP_DIALOG_ID then return end

    local titleN = normalize(stripColors(title or ''))
    local bodyN  = normalize(stripColors(text or ''))
    local b1N    = normalize(b1 or '')

    -- Отслеживание контекста смены и нерабочих денежных диалогов
    local idNum = tonumber(id)
    if idNum == 27650 or titleN:find(L'ремонт дорог', 1, true) then
        setActiveJob('roadworker', 'dialog-road')
    elseif idNum == 26920 or idNum == 15324 then
        setActiveJob('taxi', 'dialog-taxi#' .. tostring(idNum))
    elseif idNum == 15558 or idNum == 15507 or titleN:find(L'выбор груза', 1, true) then
        setActiveJob('trucker', 'dialog-trucker')
    elseif idNum == 282 or idNum == 283 or titleN:find(L'автобус', 1, true) then
        setActiveJob('bus', 'dialog-bus')
    elseif idNum == 27384 or idNum == 27379 or titleN:find(L'развозчик продуктов', 1, true) then
        setActiveJob('deliverer', 'dialog-deliverer')
    elseif idNum == 26815 or idNum == 26237 or idNum == 661 or titleN:find(L'механик', 1, true) then
        setActiveJob('mechanic', 'dialog-mechanic')
    end

    if titleN:find(L'банк', 1, true)
       or titleN:find(L'банкомат', 1, true)
       or titleN:find(L'перевод', 1, true)
       or titleN:find(L'лавка', 1, true)
       or titleN:find(L'продаж', 1, true)
       or titleN:find(L'рынок', 1, true)
       or titleN:find(L'аукцион', 1, true)
       or titleN:find(L'обмен', 1, true)
       or titleN:find(L'донат', 1, true)
       or titleN:find(L'трейд', 1, true) then
        blockNonJob(4.0, 'dialog:' .. tostring(id))
    end

    local isPayment = (idNum ~= 15324) and (
        bodyN:find(':cash:', 1, true)
        or bodyN:find(L'вознаграждение', 1, true)
    )
    if isPayment then
        logAct('Payment dialog - NOT touched')
        return
    end

    local isOtherJobDlgId = (
        idNum == 27650 or idNum == 15558 or idNum == 15507
        or idNum == 282 or idNum == 283 or idNum == 285
        or idNum == 27384 or idNum == 27379
        or idNum == 26815 or idNum == 26237 or idNum == 661
        or idNum == 26593 or idNum == 26594 or idNum == 26254
        or idNum == 26243 or idNum == 26244 or idNum == 26245 or idNum == 26246
        or idNum == 27903 or idNum == 27252 or idNum == 26838 or idNum == 28276
    )

    local isOtherJobDlg = isOtherJobDlgId
        or titleN:find(L'аренд', 1, true)
        or titleN:find(L'груз', 1, true)
        or titleN:find(L'дальнобой', 1, true)
        or titleN:find(L'механик', 1, true)
        or titleN:find(L'развозчик', 1, true)
        or titleN:find(L'ремонт дорог', 1, true)
        or titleN:find(L'автобус', 1, true)
        or (titleN:find(L'подтверждение заказа', 1, true) and JOB_STATE.activeJob ~= 'taxi')
        or bodyN:find(L'грузовик', 1, true)
        or bodyN:find(L'арендовать', 1, true)
        or bodyN:find(L'развозчик', 1, true)

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
    local isPendingCatch = pendingAccept and (os.clock() - pendingAccept) < CATCH.PENDING_TIMEOUT
    local isTwoStepConfirm = hasActiveOrder and not orderConfirmedByServer and isConfirmTitle
        and hasOrderBody
        and (os.clock() - lastAcceptAt) < 3.5
        and (id ~= lastAcceptedDialogId or lastAcceptedDialogStyle == 2 or lastAcceptedDialogStyle == 4 or lastAcceptedDialogStyle == 5)

    local allowGenericTaxiDlg = (JOB_STATE.activeJob == nil or JOB_STATE.activeJob == 'taxi')
    local isOrderDialog = (not isOtherJobDlg) and (
        idNum == 15324
        or (allowGenericTaxiDlg and isConfirmTitle and hasOrderBody)
        or (allowGenericTaxiDlg and b1N:find(L'принять', 1, true) and hasOrderBody)
    )

    if isOrderDialog and CFG.catchEnabled then
        if CFG.autoAccept and (((isPendingCatch or idNum == 15324) and not hasActiveOrder) or isTwoStepConfirm) then
            setActiveJob('taxi', 'taxi-auto-accept')
            hasActiveOrder                = true
            pendingAccept                 = nil
            awaitingDialog                = false
            tapSequenceActive             = false
            lastAcceptedDialogId          = id
            lastAcceptedDialogStyle       = style
            lastAcceptAt                  = os.clock()
            JOB_STATE.lastOrderConfirmAt  = os.clock()
            JOB_STATE.taxiHudPayPendingAt = nil
            acceptConfirmExpire           = os.clock() + 6.5

            sendAcceptDialogNow(id, style, isTwoStepConfirm)
            return false
        elseif CFG.autoAccept and (pendingDialogReply ~= nil or (hasActiveOrder and not orderConfirmedByServer and (os.clock() - lastAcceptAt) < 2.5)) then
            -- Повторный пакет ShowDialog#15324 от 2-го тапа в очереди: не шлём Закрыть(0), чтобы не убить текущий Принять(1)
            logAct('Duplicate order dialog suppressed (accept pending)')
            return false
        elseif CFG.autoAccept and (hasActiveOrder or ((os.clock() * 1000) - lastTapTime) < (CATCH.PENDING_TIMEOUT * 1000 + 3000)) then
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

    if idNum == 0 and CFG.catchEnabled and JOB_STATE.lastOrderCancelAt > 0
       and (os.clock() - JOB_STATE.lastOrderCancelAt) < 2.5
       and titleN:find(L'информация', 1, true) then
        JOB_STATE.lastOrderCancelAt = 0
        sampSendDialogResponse(id, 1, 0, '')
        if type(sampGetCurrentDialogId) == 'function' and type(sampSetCurrentDialogId) == 'function' then
            local okId, curId = pcall(sampGetCurrentDialogId)
            if okId and curId == id then sampSetCurrentDialogId(-1) end
        end
        logAct('Closed post-cancel info dialog')
        return false
    end

    local isOrderCancelled =
        bodyN:find(L'заказ уже принят', 1, true)
        or bodyN:find(L'заказ отмен', 1, true)
        or bodyN:find(L'отменил заказ', 1, true)
        or bodyN:find(L'заказ недоступен', 1, true)
        or bodyN:find(L'заказ не найден', 1, true)
        or (bodyN:find(L'клиент', 1, true) and bodyN:find(L'отменил', 1, true))

    local isAlreadyInOrder =
        bodyN:find(L'нельзя принять заказ', 1, true)
        or bodyN:find(L'уже выполняете', 1, true)

    if idNum == 0 and CFG.catchEnabled and JOB_STATE.lastOrderErrorAt > 0
       and (os.clock() - JOB_STATE.lastOrderErrorAt) < 0.8
       and (titleN:find(L'ошибка', 1, true) or bodyN:find(L'заказ', 1, true)) then
        JOB_STATE.lastOrderErrorAt = 0
        sampSendDialogResponse(id, 1, 0, '')
        if type(sampGetCurrentDialogId) == 'function' and type(sampSetCurrentDialogId) == 'function' then
            local okId, curId = pcall(sampGetCurrentDialogId)
            if okId and curId == id then sampSetCurrentDialogId(-1) end
        end
        return false
    end

    if (isOrderCancelled or isAlreadyInOrder)
       and CFG.catchEnabled
       and (pendingAccept or tapSequenceActive or awaitingDialog or hasActiveOrder or pendingDialogReply or ((os.clock() * 1000) - lastTapTime) < 6000) then
        if isOrderCancelled then
            pendingDialogReply      = nil
            hasActiveOrder          = false
            orderConfirmedByServer  = false
            lastAcceptedDialogId    = nil
            lastAcceptedDialogStyle = nil
            -- Если перебор очереди ещё идёт по первым слотам, даём шанс следующим индексам
            if tapSequenceActive and tapSeqIndex <= 4 then
                pendingAccept  = os.clock()
                awaitingDialog = true
                logAct('Order slot already taken, scanning next queue index...')
            else
                pendingAccept = nil
                resetCatchCycle('dialog error cancel')
            end
        else
            pendingDialogReply     = nil
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

    elseif kind == 'roadworker' then
        -- Дорожный конус с полосами
        DL:AddTriangleFilled(
            imgui.ImVec2(cx, cy - sz * 0.42),
            imgui.ImVec2(cx - sz * 0.28, cy + sz * 0.30),
            imgui.ImVec2(cx + sz * 0.28, cy + sz * 0.30), u32)
        DL:AddRectFilled(imgui.ImVec2(cx - sz * 0.38, cy + sz * 0.28), imgui.ImVec2(cx + sz * 0.38, cy + sz * 0.40), u32, SC(2))

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
        CA(THEME.dim, 0.75 * a), fmtVer(LOCAL_VERSION))
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
            if CFG.catchEnabled and not JOB_STATE.firstCatchWarnShown then
                JOB_STATE.firstCatchWarnShown = true
                sampAddChatMessage('{00CCB3}[HfJ] {FFAA00}' .. L'Важно: 1-й заказ за сессию может отмениться с ошибкой, дальше ловит стабильно.', -1)
            end
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
            and u8(L'ВКЛЮЧЕНА  |  Нажмите, чтобы остановить')
            or  u8(L'ВЫКЛЮЧЕНА  |  Нажмите, чтобы запустить')
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
        and u8(L'Подтверждает диалог мгновенно (0 мс - активен Турбо)')
        or  u8(L'Плавающая маскировка под игрока (реакция 30-60, приём 35-70 мс)')
    if DrawSwitchCard('accept', 'check', u8(L'Авто-принять заказ'), acceptSub, CFG.autoAccept, THEME.accent) then
        CFG.autoAccept = not CFG.autoAccept
        markDirty()
    end
    imgui.Dummy(imgui.ImVec2(0, SC(8)))

    if DrawSwitchCard('turbo', 'bolt', u8(L'Турбо-режим (0 мс)'),
        u8(L'Отключает человеческие задержки для максимальной скорости'), CFG.turboCatch, THEME.warn) then
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

    -- 3) Нижний блок: Сводка заработка и текущей смены + кнопка "Сбросить заказ"
    do
        local rowH = SC(66)
        local gap  = SC(12)
        local leftW = math.floor((w - gap) * 0.56)
        local rightW = w - gap - leftW
        local p = imgui.GetCursorScreenPos()

        -- Левая карточка: быстрая сводка
        DrawNeuBox(DL, p.x, p.y, p.x + leftW, p.y + rowH, SC(14), THEME.card, a)
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        local jobName = JOB_STATE.activeJob and ZP_LABEL[JOB_STATE.activeJob] or L'Вне смены'
        DL:AddText(imgui.ImVec2(p.x + SC(16), p.y + SC(13)), CA(THEME.dim, a), u8(L'Смена: ') .. u8(jobName))
        DL:AddText(imgui.ImVec2(p.x + SC(16), p.y + SC(37)), CA(THEME.dim, a), u8(L'Всего по работам'))

        local ordVal = u8(L'Заказов: ') .. tostring(CFG.ordersDone)
        local ovs = imgui.CalcTextSize(ordVal)
        DL:AddText(imgui.ImVec2(p.x + leftW - ovs.x - SC(16), p.y + SC(13)),
            CA(JOB_STATE.activeJob and THEME.emerald or THEME.accentBright, a), ordVal)

        local mVal = '$' .. zpFormatMoney(zpTotal())
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

    imgui.Dummy(imgui.ImVec2(0, SC(8)))
    do
        local noteH = SC(52)
        local p = imgui.GetCursorScreenPos()
        DrawNeuBox(DL, p.x, p.y, p.x + w, p.y + noteH, SC(12), THEME.cardDark, a,
            imgui.ImVec4(THEME.warn.x, THEME.warn.y, THEME.warn.z, 0.30))
        DrawVectorIcon(DL, 'info', p.x + SC(22), p.y + noteH / 2, SC(16),
            imgui.ImVec4(THEME.warn.x, THEME.warn.y, THEME.warn.z, a))
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        DL:AddText(imgui.ImVec2(p.x + SC(40), p.y + SC(9)), CA(THEME.warn, 0.95 * a),
            u8(L'Примечание (1-й заказ за сессию):'))
        DL:AddText(imgui.ImVec2(p.x + SC(40), p.y + SC(28)), CA(THEME.dim, a),
            u8(L'Первый заказ может отмениться с ошибкой, далее ловит стабильно.'))
        if FONT_SUB then imgui.PopFont() end
        imgui.Dummy(imgui.ImVec2(w, noteH))
    end

    imgui.Dummy(imgui.ImVec2(0, SC(10)))
end

-- ============================================================
--  ВКЛАДКА 2: СТАТИСТИКА (ВСЕ РАБОТЫ БЕЗ PAYDAY/ЧАЕВЫХ)
-- ============================================================
local function StatsTabFrame()
    local a     = imgui.GetStyle().Alpha
    local avail = imgui.GetContentRegionAvail()
    local w     = math.max(SC(220), avail.x)
    local totalZp = zpTotal()

    if not statInit then
        statDispOrders = CFG.ordersDone
        statDispMoney  = ZP.taxi
        statDispTotal  = totalZp
        statInit = true
    end
    statDispOrders = statDispOrders + (CFG.ordersDone - statDispOrders) * 0.16
    statDispMoney  = statDispMoney  + (ZP.taxi - statDispMoney)         * 0.16
    statDispTotal  = statDispTotal  + (totalZp - statDispTotal)         * 0.16
    if math.abs(statDispOrders - CFG.ordersDone) < 0.01 then statDispOrders = CFG.ordersDone end
    if math.abs(statDispMoney  - ZP.taxi) < 0.5         then statDispMoney  = ZP.taxi end
    if math.abs(statDispTotal  - totalZp) < 0.5         then statDispTotal  = totalZp end

    -- 1) Крупная цифра заработанного
    do
        local cardH = SC(116)
        local p = imgui.GetCursorScreenPos()
        local DL = imgui.GetWindowDrawList()

        DrawNeuBox(DL, p.x, p.y, p.x + w, p.y + cardH, SC(16), THEME.card, a,
            imgui.ImVec4(THEME.accent.x, THEME.accent.y, THEME.accent.z, 0.25))

        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        DL:AddText(imgui.ImVec2(p.x + SC(20), p.y + SC(16)), CA(THEME.dim, a), u8(L'Заработано по работам'))
        if FONT_SUB then imgui.PopFont() end

        if FONT_HERO then imgui.PushFont(FONT_HERO) elseif FONT_BIG then imgui.PushFont(FONT_BIG) end
        DL:AddText(imgui.ImVec2(p.x + SC(20), p.y + SC(42)), CA(THEME.accentBright, a),
            '$' .. zpFormatMoney(statDispTotal + 0.5))
        if FONT_HERO or FONT_BIG then imgui.PopFont() end

        local rx = p.x + w - SC(18)
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        local tOrd = u8(L'Заказов такси: ') .. tostring(math.floor(statDispOrders + 0.5))
        local ots = imgui.CalcTextSize(tOrd)
        DL:AddText(imgui.ImVec2(rx - ots.x, p.y + SC(26)), CA(THEME.text, a), tOrd)

        local modeLbl = (CFG.useLogTracker and NEOM.found)
            and (L'Учёт: NeomLog (' .. (JOB_STATE.activeJob and ZP_LABEL[JOB_STATE.activeJob] or L'ожидание') .. ')')
            or  L'Учёт: Чат (fallback)'
        local tTax = u8(modeLbl)
        local tts = imgui.CalcTextSize(tTax)
        DL:AddText(imgui.ImVec2(rx - tts.x, p.y + SC(56)),
            CA((CFG.useLogTracker and NEOM.found) and THEME.emerald or THEME.dim, a), tTax)
        if FONT_SUB then imgui.PopFont() end

        imgui.Dummy(imgui.ImVec2(w, cardH))
        imgui.Dummy(imgui.ImVec2(0, SC(12)))
    end

    -- 2) Крупный заработок по каждой профессии
    do
        local rowH = SC(58)
        for i, job in ipairs(ZP_JOB_LIST) do
            local val = ZP[job.key] or 0
            local p = imgui.GetCursorScreenPos()
            local DL = imgui.GetWindowDrawList()

            DrawNeuBox(DL, p.x, p.y, p.x + w, p.y + rowH, SC(14), THEME.card, a)

            local iconCol = val > 0 and THEME.accentBright or THEME.dim
            local icx, icy = p.x + SC(30), p.y + rowH / 2
            DL:AddCircleFilled(imgui.ImVec2(icx, icy), SC(16),
                C(imgui.ImVec4(iconCol.x, iconCol.y, iconCol.z, (val > 0 and 0.14 or 0.06) * a)), 22)
            DrawVectorIcon(DL, job.icon, icx, icy, SC(18),
                imgui.ImVec4(iconCol.x, iconCol.y, iconCol.z, a))

            local nameTxt = u8(job.label)
            local nts = imgui.CalcTextSize(nameTxt)
            DL:AddText(imgui.ImVec2(p.x + SC(58), p.y + (rowH - nts.y) / 2),
                CA(THEME.text, a), nameTxt)

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

    -- 3) Сброс статистики внизу (с защитным подтверждением)
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
                ZP.taxi, ZP.roadworker, ZP.trucker, ZP.collector = 0, 0, 0, 0
                ZP.deliverer, ZP.mechanic, ZP.bus, ZP.garbage    = 0, 0, 0, 0
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

    -- 1) БЛОК 1 (ОСНОВНОЙ): Профиль скрипта, автор, версия и обновления
    do
        local cardH = SC(168)
        local p = imgui.GetCursorScreenPos()
        local DL = imgui.GetWindowDrawList()
        local updPulse = updateAvailable and (0.55 + 0.45 * math.sin(os.clock() * 3.5)) or 0.35

        -- Выделенная карточка с бирюзовой / изумрудной рамкой (пульсирует если доступно обновление)
        local cardBg = updateAvailable
            and LerpVec4(THEME.card, imgui.ImVec4(0.08, 0.21, 0.19, 1.0), 0.35 + 0.25 * updPulse)
            or  THEME.card
        local borderCol = updateAvailable
            and LerpVec4(THEME.accent, THEME.emerald, updPulse)
            or  THEME.accent
        DrawNeuBox(DL, p.x, p.y, p.x + w, p.y + cardH, SC(16), cardBg, a,
            imgui.ImVec4(borderCol.x, borderCol.y, borderCol.z, updateAvailable and (0.55 + 0.35 * updPulse) or 0.35))
        DL:AddRectFilled(
            imgui.ImVec2(p.x + SC(18), p.y + SC(1)),
            imgui.ImVec2(p.x + w - SC(18), p.y + SC(4)),
            C(imgui.ImVec4(borderCol.x, borderCol.y, borderCol.z, (updateAvailable and 0.95 or 0.75) * a)), SC(2))

        -- Заголовок скрипта слева + автор
        if FONT_BIG then imgui.PushFont(FONT_BIG) end
        DL:AddText(imgui.ImVec2(p.x + SC(20), p.y + SC(15)), CA(THEME.text, a), 'Help for Job (HfJ)')
        if FONT_BIG then imgui.PopFont() end

        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        local authLbl = u8(L'Автор скрипта: ')
        local als = imgui.CalcTextSize(authLbl)
        DL:AddText(imgui.ImVec2(p.x + SC(20), p.y + SC(43)), CA(THEME.dim, a), authLbl)
        DL:AddText(imgui.ImVec2(p.x + SC(20) + als.x, p.y + SC(43)), CA(THEME.accentBright, a), 'mugruk')
        if FONT_SUB then imgui.PopFont() end

        -- Выделенный бейдж справа вверху (при наличии обновления подсвечивается новая версия)
        local verBadge = updateAvailable
            and (u8(L'Доступно: ') .. u8(fmtVer(remoteVersion)))
            or  (u8(L'Версия: ') .. fmtVer(LOCAL_VERSION))
        local badgeAccent = updateAvailable and THEME.emerald or THEME.accentBright
        if FONT_BIG then imgui.PushFont(FONT_BIG) end
        local vbs = imgui.CalcTextSize(verBadge)
        local vbW = vbs.x + SC(24)
        local vbH = SC(34)
        local vbX = p.x + w - vbW - SC(18)
        local vbY = p.y + SC(14)
        DL:AddRectFilled(imgui.ImVec2(vbX, vbY), imgui.ImVec2(vbX + vbW, vbY + vbH),
            C(imgui.ImVec4(badgeAccent.x, badgeAccent.y, badgeAccent.z, (updateAvailable and 0.24 or 0.16) * a)), SC(10))
        DL:AddRect(imgui.ImVec2(vbX, vbY), imgui.ImVec2(vbX + vbW, vbY + vbH),
            C(imgui.ImVec4(badgeAccent.x, badgeAccent.y, badgeAccent.z, (updateAvailable and 0.85 or 0.65) * a)), SC(10), 0, SC(1.2))
        DL:AddText(imgui.ImVec2(vbX + (vbW - vbs.x) / 2, vbY + (vbH - vbs.y) / 2),
            CA(badgeAccent, a), verBadge)
        if FONT_BIG then imgui.PopFont() end

        -- Крупная строка статуса обновления (шрифт по умолчанию 19px)
        local statusTxt = updateAvailable
            and (u8(L'Установлена ') .. fmtVer(LOCAL_VERSION) .. u8(L'  |  Требуется обновление!'))
            or  (u8(L'Статус обновлений: ') .. u8(updaterStatus))
        local statusCol = updateAvailable and THEME.emerald or THEME.dim
        DL:AddText(imgui.ImVec2(p.x + SC(20), p.y + SC(66)), CA(statusCol, a), statusTxt)

        -- Главная кнопка проверки / установки обновления
        imgui.SetCursorScreenPos(imgui.ImVec2(p.x + SC(18), p.y + SC(102)))
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
            and (hovered and THEME.emerald or LerpVec4(THEME.accent, THEME.emerald, 0.45))
            or  (hovered and THEME.tileHover or THEME.tile)
        local txtCol = updateAvailable and imgui.ImVec4(0.04, 0.08, 0.07, 1.0) or THEME.text
        DrawNeuBox(DL, bp.x, bp.y, bp.x + btnW, bp.y + btnH, SC(12), btnCol, a,
            updateAvailable and THEME.emerald or imgui.ImVec4(THEME.accent.x, THEME.accent.y, THEME.accent.z, 0.28))

        local updText
        if updateDownloading then
            updText = u8(L'Проверка / загрузка...')
        elseif updateAvailable then
            updText = u8(L'Обновить сейчас до ') .. u8(fmtVer(remoteVersion))
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

    -- 2) БЛОК 2: Учёт заработка по работам (NeomLog Packet 220, без PayDay и чаевых)
    do
        local cardH = SC(140)
        local p = imgui.GetCursorScreenPos()
        local DL = imgui.GetWindowDrawList()
        DrawNeuBox(DL, p.x, p.y, p.x + w, p.y + cardH, SC(16), THEME.card, a)

        if FONT_BIG then imgui.PushFont(FONT_BIG) end
        DL:AddText(imgui.ImVec2(p.x + SC(20), p.y + SC(14)), CA(THEME.accentBright, a), u8(L'Источник учёта ЗП'))
        if FONT_BIG then imgui.PopFont() end

        local logStatusTxt = not CFG.useLogTracker and u8(L'Режим: Только чат')
            or (NEOM.found
                and (u8(L'NeomLog: подключён  |  HUD: $') .. (NEOM.lastHudBalance and zpFormatMoney(NEOM.lastHudBalance) or '...'))
                or  u8(L'NeomLog: файл не найден (работает чат)'))
        local logStatusCol = (CFG.useLogTracker and NEOM.found) and THEME.emerald or THEME.dim
        DL:AddText(imgui.ImVec2(p.x + SC(20), p.y + SC(46)), CA(logStatusCol, a), logStatusTxt)

        -- Одна широкая кнопка переключения режима NeomLog
        local btnY = p.y + SC(80)
        local btnH = SC(44)
        local bx1  = p.x + SC(18)
        local bw   = w - SC(36)

        imgui.SetCursorScreenPos(imgui.ImVec2(bx1, btnY))
        imgui.InvisibleButton('##hfj_toggle_neomlog', imgui.ImVec2(bw, btnH))
        if imgui.IsItemClicked() then
            CFG.useLogTracker = not CFG.useLogTracker
            markDirty(); saveCfg()
            if CFG.useLogTracker then initNeomTailer() end
            notify(CFG.useLogTracker and L'Учёт через NeomLog включён' or L'Режим: только чат',
                CFG.useLogTracker and 0x00FF00 or 0xFFAA00)
        end
        local hovL = imgui.IsItemHovered()
        DrawNeuBox(DL, bx1, btnY, bx1 + bw, btnY + btnH, SC(12),
            hovL and THEME.tileHover or THEME.cardDark, a,
            CFG.useLogTracker and THEME.emerald or nil)
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        local l1 = CFG.useLogTracker
            and u8(L'NeomLog (Packet 220): ВКЛ  |  PayDay и чаевые отключены')
            or  u8(L'NeomLog (Packet 220): ВЫКЛ (только чат)')
        local s1 = imgui.CalcTextSize(l1)
        DL:AddText(imgui.ImVec2(bx1 + (bw - s1.x) / 2, btnY + (btnH - s1.y) / 2),
            CA(CFG.useLogTracker and THEME.emerald or THEME.dim, a), l1)
        if FONT_SUB then imgui.PopFont() end

        imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + cardH))
        imgui.Dummy(imgui.ImVec2(w, SC(14)))
    end

    -- 3) БЛОК 3: Инструкция по работе, команды и безопасность (увеличенный шрифт)
    do
        local cmds = {
            { '/hfj',       L'открыть / закрыть меню' },
            { '/zarabotok', L'сводка заработка в диалоге' },
            { '/resetstat', L'сброс всей статистики' },
            { '/checkupd',  L'проверить обновления' },
            { '/update',    L'скачать обновление' },
            { '/updinfo',   L'диагностика апдейтера и лога' },
            { '/takecargo', L'взять заказ (клавиша 2)' },
        }
        local rowH   = SC(32)
        local infoH  = SC(100)
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
            and u8(L'Режим: Турбо (0 мс)  |  Обычный: живые задержки 30-70 мс')
            or  u8(L'Режим: Живые задержки (30-60 / 35-70 мс)  |  Турбо: 0 мс')
        DL:AddCircleFilled(imgui.ImVec2(ix1 + SC(16), iy1 + SC(50)), SC(4),
            CA(CFG.turboCatch and THEME.warn or THEME.accentBright, a), 14)
        DL:AddText(imgui.ImVec2(ix1 + SC(28), iy1 + SC(39)),
            CA(CFG.turboCatch and THEME.warn or THEME.dim, a), modeLine)

        DL:AddCircleFilled(imgui.ImVec2(ix1 + SC(16), iy1 + SC(79)), SC(4), CA(THEME.warn, a), 14)
        DL:AddText(imgui.ImVec2(ix1 + SC(28), iy1 + SC(68)), CA(THEME.warn, 0.92 * a),
            u8(L'1-й заказ за сессию может отмениться с ошибкой (норма)'))

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
        local padX = SC(14)
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

            -- Точка-бейдж на вкладке «Настройки», если доступно обновление
            if tab.id == 3 and updateAvailable then
                local bpulse = 0.55 + 0.45 * math.sin(os.clock() * 4.5)
                local dx, dy = icx + SC(14), icy - SC(9)
                DL:AddCircleFilled(imgui.ImVec2(dx, dy), SC(6.5),
                    C(imgui.ImVec4(THEME.emerald.x, THEME.emerald.y, THEME.emerald.z, 0.25 * bpulse * a)), 14)
                DL:AddCircleFilled(imgui.ImVec2(dx, dy), SC(4),
                    CA(THEME.emerald, a), 14)
            end

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

    FONT_SUB  = loadFont(regular_paths, SC(15)) or def
    FONT_BIG  = loadFont(bold_paths, SC(22)) or def
    FONT_HERO = loadFont(bold_paths, SC(36)) or FONT_BIG

    local style = imgui.GetStyle()
    style.WindowPadding     = imgui.ImVec2(0, 0)
    style.WindowRounding    = SC(16)
    style.ChildRounding     = SC(16)
    style.FrameRounding     = SC(14)
    style.PopupRounding     = SC(14)
    style.ScrollbarRounding = SC(14)
    style.GrabRounding      = SC(12)
    style.GrabMinSize       = SC(34)
    style.ItemSpacing       = imgui.ImVec2(SC(10), SC(10))
    style.ItemInnerSpacing  = imgui.ImVec2(SC(8), SC(8))
    style.FramePadding      = imgui.ImVec2(SC(10), SC(8))
    style.ScrollbarSize     = SC(24)
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
    col[imgui.Col.ScrollbarBg]      = imgui.ImVec4(0.075, 0.084, 0.102, 1.0)
    col[imgui.Col.ScrollbarGrab]    = imgui.ImVec4(0.28, 0.34, 0.42, 1.0)
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
--  ОКНО АВТООБНОВЛЕНИЯ (СТИЛЬ HFJ AUTOMOTIVE DASHBOARD)
-- ============================================================
imgui.OnFrame(
    function() return (updateModal[0] or updateModalAlpha > 0.005) and isSampAvailable() and not isPauseMenuActive() end,
    function(this)
        this.ShowCursor = (updateModal[0] or updateModalAlpha > 0.35)
        local target = updateModal[0] and 1.0 or 0.0
        updateModalAlpha = updateModalAlpha + (target - updateModalAlpha) * 0.28
        if math.abs(target - updateModalAlpha) < 0.01 then updateModalAlpha = target end

        if updateModalAlpha <= 0.005 and not updateModal[0] then
            updateModalAlpha = 0
            return
        end

        local sw, sh = getScreenResolution()
        if not sw or sw <= 0 then sw, sh = 1280, 720 end

        local mw = math.min(SC(460), sw - SC(32))
        local mh = SC(292)
        local a  = updateModalAlpha

        imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(mw, mh), imgui.Cond.Always)
        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, math.max(0.01, a))

        local visible = imgui.Begin('##HfJUpdateModal', nil,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoBackground
            + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoResize
            + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoCollapse)

        if visible then
            local pos = imgui.GetWindowPos()
            local DL  = imgui.GetWindowDrawList()
            local R   = SC(18)

            -- Матовый графитовый фон с мягкой тенью и бирюзовой рамкой
            DL:AddRectFilled(
                imgui.ImVec2(pos.x + SC(5), pos.y + SC(7)),
                imgui.ImVec2(pos.x + mw + SC(7), pos.y + mh + SC(10)),
                CA(THEME.shadowDark, 0.85 * a), R + SC(4))
            DL:AddRectFilled(pos, imgui.ImVec2(pos.x + mw, pos.y + mh), CA(THEME.bg, a), R)
            DL:AddRect(pos, imgui.ImVec2(pos.x + mw, pos.y + mh),
                C(imgui.ImVec4(THEME.accent.x, THEME.accent.y, THEME.accent.z, 0.55 * a)), R, 0, SC(1.5))

            -- Верхняя акцентная полоска
            DL:AddRectFilled(
                imgui.ImVec2(pos.x + SC(20), pos.y + SC(1)),
                imgui.ImVec2(pos.x + mw - SC(20), pos.y + SC(4)),
                CA(THEME.emerald, a), SC(2))

            -- Шапка окна обновления: эмблема HfJ + заголовок
            local bx, by = pos.x + SC(20), pos.y + SC(18)
            DL:AddRectFilled(imgui.ImVec2(bx, by), imgui.ImVec2(bx + SC(42), by + SC(36)),
                CA(THEME.accentDark, a), SC(10))
            DL:AddRectFilled(imgui.ImVec2(bx, by), imgui.ImVec2(bx + SC(42), by + SC(22)),
                CA(THEME.emerald, 0.85 * a), SC(10), 3)
            if FONT_BIG then imgui.PushFont(FONT_BIG) end
            local ms = imgui.CalcTextSize('HfJ')
            DL:AddText(imgui.ImVec2(bx + (SC(42) - ms.x) / 2, by + (SC(36) - ms.y) / 2),
                C(imgui.ImVec4(0.04, 0.08, 0.07, a)), 'HfJ')
            local modalTitle = updateDownloading
                and u8(L'Обновление скрипта')
                or  u8(L'Доступно обновление')
            DL:AddText(imgui.ImVec2(bx + SC(54), by + SC(6)), CA(THEME.text, a), modalTitle)
            if FONT_BIG then imgui.PopFont() end

            -- Внутренняя карточка: либо предложение обновиться, либо живой прогресс загрузки 0-100%
            local cx1, cy1 = pos.x + SC(20), pos.y + SC(68)
            local cx2, cy2 = pos.x + mw - SC(20), pos.y + SC(210)
            DrawNeuBox(DL, cx1, cy1, cx2, cy2, SC(14), THEME.card, a)

            -- Верхняя строка карточки: сравнение версий
            local verCur = u8(L'Установлена: ') .. fmtVer(LOCAL_VERSION)
            local verNew = u8(L'Новая: ') .. u8(fmtVer(remoteVersion))
            DL:AddText(imgui.ImVec2(cx1 + SC(16), cy1 + SC(15)), CA(THEME.dim, a), verCur)
            if FONT_BIG then imgui.PushFont(FONT_BIG) end
            local vns = imgui.CalcTextSize(verNew)
            DL:AddText(imgui.ImVec2(cx2 - vns.x - SC(16), cy1 + SC(13)), CA(THEME.emerald, a), verNew)
            if FONT_BIG then imgui.PopFont() end

            DL:AddLine(
                imgui.ImVec2(cx1 + SC(16), cy1 + SC(46)),
                imgui.ImVec2(cx2 - SC(16), cy1 + SC(46)),
                C(imgui.ImVec4(1, 1, 1, 0.06 * a)), SC(1))

            if updateDownloading then
                -- Плавная анимация процента к реальному значению
                updProg.disp = updProg.disp + (updProg.pct - updProg.disp) * 0.22
                if math.abs(updProg.pct - updProg.disp) < 0.004 then updProg.disp = updProg.pct end
                local pctVal = math.max(0, math.min(100, math.floor(updProg.disp * 100 + 0.5)))

                -- Весёлые, безопасные для Android шрифтов фразы со смайликами по этапам
                local funCaption
                local tick = math.floor((os.clock() - updProg.startedAt) / 1.0)
                if pctVal >= 100 then
                    funCaption = L'Готово! Перезапускаем скрипт :D'
                elseif pctVal >= 88 then
                    local pool = {
                        L'Ставим свежую обнову ;)',
                        L'Переписываем скрипт... =)',
                        L'Почти на финише! ^_^',
                        L'Финальная полировка! :D',
                    }
                    funCaption = pool[(tick % #pool) + 1]
                elseif pctVal >= 48 then
                    local pool = {
                        L'Меняем версию на новую :D',
                        L'Прокачиваем тачку HfJ! ;)',
                        L'Подкручиваем гайки... =)',
                        L'Тюнингуем автоловлю ^_^',
                    }
                    funCaption = pool[(tick % #pool) + 1]
                elseif pctVal >= 16 then
                    local pool = {
                        L'Качаем новый код... ^_^',
                        L'Забираем свежую версию ;)',
                        L'Заливаем новые фишки :D',
                        L'Чистим старые файлы...',
                    }
                    funCaption = pool[(tick % #pool) + 1]
                else
                    local pool = {
                        L'Стучимся на сервер... ;)',
                        L'Ищем свежий релиз... ^_^',
                        L'Разогреваем движок... =)',
                    }
                    funCaption = pool[(tick % #pool) + 1]
                end

                -- Спиннер + фраза слева, крупный процент справа
                DrawVectorIcon(DL, 'spinner', cx1 + SC(26), cy1 + SC(69), SC(18),
                    imgui.ImVec4(THEME.emerald.x, THEME.emerald.y, THEME.emerald.z, a))
                DL:AddText(imgui.ImVec2(cx1 + SC(44), cy1 + SC(59)), CA(THEME.text, a), u8(funCaption))

                local pctTxt = tostring(pctVal) .. '%'
                if FONT_BIG then imgui.PushFont(FONT_BIG) end
                local pts = imgui.CalcTextSize(pctTxt)
                DL:AddText(imgui.ImVec2(cx2 - pts.x - SC(16), cy1 + SC(56)), CA(THEME.emerald, a), pctTxt)
                if FONT_BIG then imgui.PopFont() end

                -- Прогресс-бар от 0 до 100%
                local barX1 = cx1 + SC(16)
                local barX2 = cx2 - SC(16)
                local barY1 = cy1 + SC(90)
                local barY2 = cy1 + SC(104)
                local barR  = SC(7)
                local trackW = barX2 - barX1
                local fillW  = trackW * math.max(0.03, math.min(1, updProg.disp))

                DL:AddRectFilled(imgui.ImVec2(barX1, barY1), imgui.ImVec2(barX2, barY2),
                    CA(THEME.cardDark, a), barR)
                DL:AddRect(imgui.ImVec2(barX1, barY1), imgui.ImVec2(barX2, barY2),
                    C(imgui.ImVec4(1, 1, 1, 0.08 * a)), barR, 0, SC(1))

                local wave = 0.5 + 0.5 * math.sin(os.clock() * 4.5)
                local fillCol = LerpVec4(THEME.accent, THEME.emerald, 0.45 + 0.45 * wave)
                DL:AddRectFilled(imgui.ImVec2(barX1, barY1), imgui.ImVec2(barX1 + fillW, barY2),
                    CA(fillCol, a), barR)
                -- Бегущий светлый блик внутри заполненной полоски
                if fillW > SC(28) and pctVal < 100 then
                    local shineW = math.min(SC(38), fillW * 0.4)
                    local shineX = barX1 + (fillW - shineW) * ((os.clock() * 1.1) % 1.0)
                    DL:AddRectFilled(
                        imgui.ImVec2(shineX, barY1 + SC(2)),
                        imgui.ImVec2(shineX + shineW, barY2 - SC(2)),
                        C(imgui.ImVec4(0.85, 1.0, 0.95, 0.35 * a)), SC(5))
                end

                -- Подпись под прогресс-баром: реальные КБ + бодрый хинт
                if FONT_SUB then imgui.PushFont(FONT_SUB) end
                local kbTxt
                if updProg.total > 0 then
                    kbTxt = string.format('%.1f / %.1f %s', updProg.bytes / 1024, updProg.total / 1024, u8(L'КБ'))
                elseif updProg.bytes > 0 then
                    kbTxt = string.format('%.1f %s', updProg.bytes / 1024, u8(L'КБ загружено'))
                else
                    kbTxt = u8(updProg.stage)
                end
                DL:AddText(imgui.ImVec2(barX1, cy1 + SC(114)), CA(THEME.dim, a), kbTxt)

                local subPool = {
                    L'Не сворачивайте игру ^_^',
                    L'Статистика сохранится ;)',
                    L'Автоловля уже на старте :D',
                    L'Скоро полетим по заказам =)',
                    L'Ничего не пропадёт :P',
                    L'Настраиваем всё за вас ;)',
                }
                local rightHint = u8(subPool[(tick % #subPool) + 1])
                local rhs = imgui.CalcTextSize(rightHint)
                DL:AddText(imgui.ImVec2(barX2 - rhs.x, cy1 + SC(114)), CA(THEME.accentBright, 0.85 * a), rightHint)
                if FONT_SUB then imgui.PopFont() end
            else
                DL:AddText(imgui.ImVec2(cx1 + SC(16), cy1 + SC(62)), CA(THEME.text, a),
                    u8(L'Вышла новая версия Help for Job.'))
                DL:AddText(imgui.ImVec2(cx1 + SC(16), cy1 + SC(90)), CA(THEME.dim, a),
                    u8(L'Советуем обновить скрипт прямо сейчас!'))
            end

            -- Нижние кнопки: Обновить (главная) и Отложить (вторичная)
            local gap = SC(12)
            local btnW = (mw - SC(40) - gap) / 2
            local btnH = SC(48)
            local btnY = pos.y + mh - btnH - SC(18)

            -- Кнопка 1: Обновить
            imgui.SetCursorScreenPos(imgui.ImVec2(pos.x + SC(20), btnY))
            imgui.InvisibleButton('##hfj_modal_upd_now', imgui.ImVec2(btnW, btnH))
            local clkUpd = imgui.IsItemClicked()
            local hovUpd = imgui.IsItemHovered()
            if clkUpd and not updateDownloading then
                doUpdate()
            end
            local updBg = updateDownloading
                and THEME.tile
                or  (hovUpd and THEME.emerald or LerpVec4(THEME.accent, THEME.emerald, 0.45))
            DrawNeuBox(DL, pos.x + SC(20), btnY, pos.x + SC(20) + btnW, btnY + btnH, SC(12),
                updBg, a, THEME.emerald)
            local updLbl = updateDownloading
                and (tostring(math.max(0, math.min(100, math.floor(updProg.disp * 100 + 0.5)))) .. '%')
                or  u8(L'Обновить')
            if FONT_BIG then imgui.PushFont(FONT_BIG) end
            local uls = imgui.CalcTextSize(updLbl)
            DL:AddText(
                imgui.ImVec2(pos.x + SC(20) + (btnW - uls.x) / 2, btnY + (btnH - uls.y) / 2),
                CA(updateDownloading and THEME.emerald or imgui.ImVec4(0.04, 0.08, 0.07, 1.0), a),
                updLbl)
            if FONT_BIG then imgui.PopFont() end

            -- Кнопка 2: Отложить
            local bx2 = pos.x + SC(20) + btnW + gap
            imgui.SetCursorScreenPos(imgui.ImVec2(bx2, btnY))
            imgui.InvisibleButton('##hfj_modal_upd_later', imgui.ImVec2(btnW, btnH))
            local clkLater = imgui.IsItemClicked()
            local hovLater = imgui.IsItemHovered()
            if clkLater then
                updateModal[0] = false
                if not updateDownloading then
                    notify(L'Обновление отложено. Доступно в Настройках', 0xFFAA00)
                end
            end
            DrawNeuBox(DL, bx2, btnY, bx2 + btnW, btnY + btnH, SC(12),
                hovLater and THEME.tileHover or THEME.tile, a,
                imgui.ImVec4(1, 1, 1, 0.08))
            local laterLbl = updateDownloading and u8(L'Свернуть') or u8(L'Отложить')
            if FONT_BIG then imgui.PushFont(FONT_BIG) end
            local lls = imgui.CalcTextSize(laterLbl)
            DL:AddText(
                imgui.ImVec2(bx2 + (btnW - lls.x) / 2, btnY + (btnH - lls.y) / 2),
                CA(THEME.text, a), laterLbl)
            if FONT_BIG then imgui.PopFont() end
        end
        imgui.End()
        imgui.PopStyleVar()
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
            acquireNotifyLock(sn.dur)
            startToastAnim(0, 1, NOTIFY_ANIM_IN, 'outQuart')
        elseif sn.state == 'showing' then
            local effDur = (#sn.queue > 0) and math.min(sn.dur, 1.1) or sn.dur
            if (os.clock() - sn.timer) >= effDur then
                sn.state = 'hiding'
                sn.timer = os.clock()
                startToastAnim(sn.anim, 0, NOTIFY_ANIM_OUT, 'inBack')
            end
        end

        if sn.state == 'idle' then return end

        -- Плавная анимация тоста без создания лишних lua_thread корутин
        if sn.animDur > 0 then
            local elapsed = os.clock() - sn.animStart
            if elapsed >= sn.animDur then
                sn.anim = sn.animTo
                sn.animDur = 0
                if sn.state == 'hiding' and sn.anim <= 0.02 then
                    sn.state = 'idle'
                end
            else
                local ef = Easing[sn.animEase] or function(x) return x end
                local progress = math.max(0, math.min(1, elapsed / sn.animDur))
                sn.anim = sn.animFrom + (sn.animTo - sn.animFrom) * ef(progress)
            end
        elseif sn.state == 'hiding' and sn.anim <= 0.02 then
            sn.state = 'idle'
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
--  MAIN & ХЕЛПЕРЫ ЦИКЛА (РАЗГРУЗКА UPVALUES ДЛЯ LUAJIT)
-- ============================================================
local function registerChatCommands()
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

    sampRegisterChatCommand('checkupd', function()
        if not window[0] then promptedVersion = nil end
        doCheck(false)
    end)
    sampRegisterChatCommand('update', function() doUpdate() end)
    sampRegisterChatCommand('updinfo', function()
        notify(L'Версия: ' .. fmtVer(LOCAL_VERSION) ..
            L' | Сервер: ' .. fmtVer(remoteVersion), 0x00CCB3)
        notify(L'Транспорты: ' .. updaterTransportsText(), 0x00CCB3)
        notify(L'NeomLog: ' .. (NEOM.found and (L'OK, пакетов: ' .. NEOM.packetsRead) or L'не найден')
            .. L' | Смена: ' .. (JOB_STATE.activeJob or 'none'), 0x00CCB3)
    end)
end

local function tickBackgroundTasks(now)
    pcall(pollNeomLog, now)
    flushLogBuffer(false)

    -- Отложенный chat-fallback (если Packet 220 не поступил в neomloader.log за 1.8с)
    if #JOB_STATE.pendingChatPayouts > 0 then
        for i = #JOB_STATE.pendingChatPayouts, 1, -1 do
            local item = JOB_STATE.pendingChatPayouts[i]
            if now >= item.fireAt then
                table.remove(JOB_STATE.pendingChatPayouts, i)
                local hudAt = JOB_STATE.lastJobHudPayAt[item.job] or 0
                if (now - hudAt) >= 8.0 then
                    creditJobPayout(item.job, item.amount, 'chat-fallback', false)
                    JOB_STATE.lastJobChatPayAt[item.job] = now
                end
            end
        end
    end

    -- Резервное авто-завершение заказа такси по Packet 220 (если чат не прислал строку доставки)
    if JOB_STATE.taxiHudPayPendingAt and (now - JOB_STATE.taxiHudPayPendingAt) >= 2.0 then
        JOB_STATE.taxiHudPayPendingAt = nil
        if hasActiveOrder and JOB_STATE.activeJob == 'taxi' then
            finishOrder(L'Packet220 оплата')
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
end

local function tickAutoCatch(now)
    -- Отложенный человеческий ответ на диалог подтверждения заказа (без лишней корутины)
    if pendingDialogReply and now >= pendingDialogReply.sendAt then
        local rep = pendingDialogReply
        pendingDialogReply = nil
        if hasActiveOrder and CFG.catchEnabled
           and JOB_STATE.activeJob == 'taxi'
           and now >= JOB_STATE.taxiErrorBlockUntil then
            executeDialogAcceptNow(rep.id, rep.style, rep.delayMs, rep.isTwoStepConfirm)
        else
            logAct('Auto-accept aborted (cancelled/changed during delay)')
        end
    end

    if pendingAccept and (now - pendingAccept) > CATCH.PENDING_TIMEOUT then
        logAct('Accept timeout: pendingAccept expired')
        pendingAccept = nil
        hasActiveOrder = false
        acceptConfirmExpire = 0
        resetCatchCycle('accept timeout')
    end

    -- Тайм-аут неподтверждённого авто-приёма (если сервер не прислал подтверждение или отказ)
    if hasActiveOrder and not orderConfirmedByServer and acceptConfirmExpire > 0 and now > acceptConfirmExpire then
        logAct('Order confirm timeout: resetting hasActiveOrder')
        hasActiveOrder          = false
        pendingAccept           = nil
        acceptConfirmExpire     = 0
        lastAcceptedDialogId    = nil
        lastAcceptedDialogStyle = nil
        resetCatchCycle('confirm timeout')
    end

    if awaitingDialog and now > awaitingExpire then
        awaitingDialog = false
        tapSequenceActive = false
        if not hasActiveOrder and pendingAccept then
            pendingAccept = nil
            resetCatchCycle('awaiting timeout')
        end
    end

    if tapSequenceActive and now >= tapSeqNextSend then
        local maxTaps = CFG.turboCatch and CATCH.MAX_TAPS_TURBO or CATCH.MAX_TAPS_NORMAL
        if tapSeqIndex <= maxTaps then
            sendTapPacketWithIndex(tapSeqIndex)
            tapSeqIndex = tapSeqIndex + 1

            if tapSeqIndex > maxTaps then
                tapSequenceActive = false
            else
                local currentStepMs = CFG.turboCatch and CATCH.TAP_STEP_TURBO or humanDelayMs(CATCH.TAP_STEP_MIN, CATCH.TAP_STEP_MAX)
                tapSeqNextSend = now + currentStepMs / 1000
            end
        else
            tapSequenceActive = false
        end
    end
end

function main()
    while not isSampAvailable() do wait(200) end

    math.randomseed(os.time())

    logInit()
    loadCfg()
    logAct('Script loaded. ' .. fmtVer(VERSION) .. ' (utf8_file=' .. tostring(FILE_IS_UTF8) .. ')')

    registerChatCommands()

    pcall(initNeomTailer)
    notify(L'Help for Job ' .. fmtVer(VERSION) .. L' загружен, /hfj - меню', 0x00FF00)
    if CFG.catchEnabled and not JOB_STATE.firstCatchWarnShown then
        JOB_STATE.firstCatchWarnShown = true
        sampAddChatMessage('{00CCB3}[HfJ] {FFAA00}' .. L'Важно: 1-й заказ за сессию может отмениться с ошибкой, дальше ловит стабильно.', -1)
    end
    startUpdateCheck()

    lastAutoSave = os.clock()

    while true do
        wait(0)
        local now = os.clock()
        tickBackgroundTasks(now)
        tickAutoCatch(now)
    end
end

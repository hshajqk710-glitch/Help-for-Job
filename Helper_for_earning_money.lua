-- taxord.lua
-- MonetLoader 3.8.x
-- v28.0.8 - ловля заказов через диалоги + чат, автоопределение кодировки,
--           обновлятор: кнопка проверки версии + загрузка обновления
-- СОХРАНЯЙ В ЛЮБОЙ КОДИРОВКЕ - скрипт сам определит

script_name('TaxOrd')
script_version('28.0.8')

local imgui    = require 'mimgui'
local new      = imgui.new
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local sampev = require 'samp.events'

-- ============================================================
--  АВТООПРЕДЕЛЕНИЕ КОДИРОВКИ ФАЙЛА
-- ============================================================
local CANARY = 'Такси' -- длина этой строки зависит от кодировки файла
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

-- L() приводит любую русскую строку к CP1251 независимо от кодировки файла
local function L(s)
    if FILE_IS_UTF8 then return utf8ToCp1251(s) end
    return s
end

-- ============================================================
--  КОНСТАНТЫ
-- ============================================================
local MAX_TAPS              = 30
local TAP_STEP_MS           = 30
local TAP_COOLDOWN          = 300
local DIALOG_RESPONSE_WAIT  = 30
local PENDING_TIMEOUT       = 6.0

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
local window       = new.bool(false)

local windowAlpha     = 0
local windowRendering = false
local tabFade         = 1
local tabSlide        = 0
local lastSelectedTab = '1:1'
local tabHover        = {}
local togglePulse     = {}
local statDispOrders  = 0
local statDispMoney   = 0
local statInit        = false

-- ============================================================
--  НОРМАЛИЗАЦИЯ СТРОК (CP1251, байтовые классы)
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
--  ПУТИ
-- ============================================================
local WORK_DIR    = getWorkingDirectory()
local CONFIG_DIR  = WORK_DIR .. '/config'
local LOG_DIR     = WORK_DIR .. '/logs'
local CONFIG_FILE = CONFIG_DIR .. '/taxord.cfg'
local LOG_FILE    = LOG_DIR .. '/taxord.log'

if not doesDirectoryExist(CONFIG_DIR) then pcall(createDirectory, CONFIG_DIR) end
if not doesDirectoryExist(LOG_DIR)    then pcall(createDirectory, LOG_DIR)    end

-- ============================================================
--  ЛОГ (всё пишется в UTF-8, чтобы читался нормально)
-- ============================================================
local function logRaw(msg)
    print('[TaxOrd] ' .. msg)
    local f = io.open(LOG_FILE, 'a')
    if f then
        f:write(os.date('%H:%M:%S.') ..
            string.format('%03d', math.floor((os.clock() % 1) * 1000)) ..
            ' | ' .. u8(tostring(msg)) .. '\n')
        f:close()
    end
end
local function logInit()
    local f = io.open(LOG_FILE, 'w')
    if f then f:write('=== TaxOrd v28.0.8 ' .. os.date() .. ' ===\n'); f:close() end
end
local function logChat(t) logRaw('CHAT  | ' .. tostring(t)) end
local function logAct(t)  logRaw('ACT   | ' .. tostring(t)) end
local function logDlg(t)  logRaw('DLG   | ' .. tostring(t)) end

-- ============================================================
--  КОНФИГ
-- ============================================================
local CFG = {
    catchEnabled = true,
    autoAccept   = true,
    ordersDone   = 0,
    moneyEarned  = 0,
}

local buf = {
    catchEnabled = new.bool(true),
    autoAccept   = new.bool(true),
}

local function markDirty() cfgDirty = true end

local function cfgToBuf()
    buf.catchEnabled[0] = CFG.catchEnabled
    buf.autoAccept[0]   = CFG.autoAccept
end

local function bufToCfg()
    CFG.catchEnabled = buf.catchEnabled[0]
    CFG.autoAccept   = buf.autoAccept[0]
end

cfgToBuf()

local function saveCfg()
    bufToCfg()
    local f = io.open(CONFIG_FILE, 'w')
    if not f then return false end
    f:write('catchEnabled=' .. tostring(CFG.catchEnabled) .. '\n')
    f:write('autoAccept='   .. tostring(CFG.autoAccept)   .. '\n')
    f:write('ordersDone='   .. tostring(CFG.ordersDone)   .. '\n')
    f:write('moneyEarned='  .. tostring(CFG.moneyEarned)  .. '\n')
    f:close()
    cfgDirty = false
    return true
end

local function loadCfg()
    local f = io.open(CONFIG_FILE, 'r')
    if not f then return end
    for line in f:lines() do
        local k, v = line:match('^([^=]+)=(.*)$')
        if k and v then
            local n = tonumber(v)
            if k == 'catchEnabled' then CFG.catchEnabled = (v == 'true') end
            if k == 'autoAccept'   then CFG.autoAccept   = (v == 'true') end
            if k == 'ordersDone'  and n then CFG.ordersDone  = n end
            if k == 'moneyEarned' and n then CFG.moneyEarned = n end
        end
    end
    f:close()
    cfgToBuf()
end

-- ============================================================
--  УВЕДОМЛЕНИЯ
-- ============================================================
local NOTIFY_DURATION = 9.0
local NOTIFY_ANIM_IN  = 0.45
local NOTIFY_ANIM_OUT = 0.4

local function canShowNotify()
    local lock = _G.__notify_lock
    if not lock then return true end
    if lock.expire <= os.clock() then return true end
    return false
end

local function acquireNotifyLock()
    _G.__notify_lock = { owner = 'taxord',
        expire = os.clock() + NOTIFY_DURATION + NOTIFY_ANIM_IN + NOTIFY_ANIM_OUT }
end

local sn = {
    queue   = {},
    message = '',
    icon    = 'info',
    timer   = 0,
    anim    = 0,
    glow    = 0,
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
    if color == 0x00FF00 then return 'success' end
    if color == 0xFFFF00 then return 'warn'    end
    if color == 0xFFAA00 then return 'warn'    end
    if color == 0xFF0000 then return 'error'   end
    return 'info'
end

local function notify(text, color)
    logAct('NOTIFY: ' .. tostring(text))
    sampAddChatMessage('{FFCC00}[TaxOrd] {FFFFFF}' .. tostring(text), color or -1)
    table.insert(sn.queue, { text = tostring(text), icon = iconFromColor(color) })
end

-- ============================================================
--  UPDATER
-- ============================================================
local SCRIPT_FILENAME = 'Helper_for_earning_money.lua'
local LOCAL_VERSION   = '28.0.8'

local UPDATE_URL_VERSION = 'https://raw.githubusercontent.com/hshajqk710-glitch/taxord/main/version.txt'
local UPDATE_URL_SCRIPT  = 'https://raw.githubusercontent.com/hshajqk710-glitch/taxord/main/' .. SCRIPT_FILENAME

local updateAvailable   = false
local updateDownloading = false
local remoteVersion     = ''

-- MoonLoader (PC) умеет downloadUrlToFile, MonetLoader (Android) - только socket/ssl.
local okMoon, moonlib = pcall(require, 'moonloader')
local DS_END = 6
if okMoon and moonlib and moonlib.download_status then
    DS_END = moonlib.download_status.STATUS_ENDDOWNLOADDATA
end

local okHttp,  http  = pcall(require, 'socket.http')
if not okHttp then http = nil end

local okHttps, https = pcall(require, 'ssl.https')
if not okHttps then https = nil end

local hasRawDownload = (downloadUrlToFile ~= nil)
local hasHttpFetch   = (http ~= nil)
local canDownload    = hasRawDownload or hasHttpFetch

local function parseVer(s)
    local a, b, c = tostring(s):match('(%d+)%.(%d+)%.(%d+)')
    if not a then return nil end
    return tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)
end

local function readFile(path)
    local f = io.open(path, 'r')
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

-- Загрузка через socket.http / ssl.https (MonetLoader)
-- ВАЖНО: ssl.https (LuaSec) не принимает поле redirect и сам редиректы не умеет,
-- поэтому redirect не передаём, а 3xx обрабатываем вручную.
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
    local current = url

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

-- Загрузка через downloadUrlToFile (PC MoonLoader)
local function rawFetch(url)
    local tmp = WORK_DIR .. '/update_tmp_version.txt'
    os.remove(tmp)

    local finished = false
    local ok = pcall(downloadUrlToFile, url, tmp, function(id, status)
        if status == DS_END then finished = true end
    end)
    if not ok then return nil, 'downloadUrlToFile' end

    local t0 = os.clock()
    while not finished and (os.clock() - t0) < 15 do wait(0) end

    local content = readFile(tmp)
    os.remove(tmp)
    if not content or content == '' then return nil, 'пустой ответ' end
    return content
end

local function fetchText(url)
    if hasRawDownload then
        local body, err = rawFetch(url)
        if body then return body end
    end
    if hasHttpFetch then
        return socketFetch(url)
    end
    return nil, 'нет транспорта'
end

local function applyVersionText(text)
    local ver = tostring(text or ''):match('%d+%.%d+%.%d+')
    if not ver then return 'err' end
    local r, l = parseVer(ver), parseVer(LOCAL_VERSION)
    if not r or not l then return 'err' end
    if r > l then
        remoteVersion = ver
        updateAvailable = true
        return 'new'
    end
    remoteVersion = ver
    updateAvailable = false
    return 'same'
end

local function scriptPath()
    local ok, info = pcall(thisScript)
    if ok and info then
        local okPath, path = pcall(function() return info.path end)
        if okPath and type(path) == 'string' and path ~= '' then return path end
    end
    return WORK_DIR .. '/' .. SCRIPT_FILENAME
end

local function doCheck()
    if not canDownload then
        notify(L'Скачивание недоступно на этой сборке', 0xFF0000)
        return
    end
    if updateDownloading then return end
    updateDownloading = true
    notify(L'Проверяю обновление...', 0xFFFF00)

    lua_thread.create(function()
        local body, err = fetchText(UPDATE_URL_VERSION)
        updateDownloading = false

        if not body then
            logAct('Check failed: ' .. tostring(err))
            notify(L'Не удалось проверить обновление', 0xFF0000)
            return
        end

        local st = applyVersionText(body)
        if st == 'new' then
            notify(L'Доступна новая версия: ' .. remoteVersion, 0xFFAA00)
            logAct('Update available: ' .. remoteVersion)
        elseif st == 'same' then
            notify(L'У вас последняя версия', 0x00FF00)
        else
            notify(L'Не удалось проверить обновление', 0xFF0000)
        end
    end)
end

local function doUpdate()
    if not canDownload then
        notify(L'Скачивание недоступно на этой сборке', 0xFF0000)
        return
    end
    if not updateAvailable then
        notify(L'Обновление не найдено - сначала /checkupd', 0xFFAA00)
        return
    end
    if updateDownloading then return end
    updateDownloading = true
    notify(L'Идет скачивание обновления...', 0xFFFF00)

    lua_thread.create(function()
        local body, err = fetchText(UPDATE_URL_SCRIPT)
        updateDownloading = false

        if not body or body == '' then
            logAct('Download failed: ' .. tostring(err))
            notify(L'Ошибка скачивания обновления', 0xFF0000)
            return
        end

        -- защита от «обновления» на страницу-ошибку вместо скрипта
        if not body:find('script_name', 1, true) then
            logAct('Download failed: not a script')
            notify(L'Ошибка скачивания обновления', 0xFF0000)
            return
        end

        local tmp = WORK_DIR .. '/update_tmp.tmp'
        if not writeFile(tmp, body) then
            notify(L'Ошибка записи обновления', 0xFF0000)
            return
        end

        local dest = scriptPath()
        local backup = dest .. '.bak'

        -- сначала бэкап: если подмена не удастся, скрипт останется рабочим
        os.remove(backup)
        if not os.rename(dest, backup) then
            -- файл только для чтения (частая ситуация на Android)
            os.remove(tmp)
            logAct('Rename failed: dest is read-only')
            notify(L'Нет доступа к файлу скрипта', 0xFF0000)
            return
        end

        if not os.rename(tmp, dest) then
            os.rename(backup, dest)
            os.remove(tmp)
            logAct('Rename failed, backup restored')
            notify(L'Ошибка установки обновления', 0xFF0000)
            return
        end

        os.remove(backup)
        updateAvailable = false
        logAct('Update installed: ' .. tostring(remoteVersion))
        notify(L'Обновление скачано. Перезапустите игру.', 0x00FF00)

        -- если загрузчик умеет перезагружать скрипт - делаем это сами
        wait(800)
        local okInfo, info = pcall(thisScript)
        if okInfo and info then
            local okReload = pcall(function() info:reload() end)
            if okReload then
                logAct('Script reloaded')
            end
        end
    end)
end

local function startUpdateCheck()
    if not canDownload then return end
    lua_thread.create(function()
        wait(10000)
        doCheck()
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
--  УТИЛИТЫ
-- ============================================================
local function parseMoney(s)
    if not s then return 0 end
    local raw = s:match('%$(%d[%d%.,]*)')
    if not raw then return 0 end
    raw = raw:gsub('[%.,]', '')
    return tonumber(raw) or 0
end

local function stripColors(t)
    return (t:gsub('{%x%x%x%x%x%x}', ''):gsub('{%x%x%x%x%x%x%x%x}', ''))
end

-- ============================================================
--  СОСТОЯНИЕ
-- ============================================================
local active         = true
local awaitingDialog = false
local awaitingExpire = 0
local lastTapTime    = 0
local hasActiveOrder = false

local pendingAccept       = nil
local pendingAcceptNotif  = false

local tapSequenceActive = false
local tapSeqIndex       = 0
local tapSeqNextSend    = 0
local tapSeqRejected    = {}

-- ============================================================
--  ЗАВЕРШЕНИЕ ЗАКАЗА
-- ============================================================
local function finishOrder(reason)
    if not hasActiveOrder then return end
    hasActiveOrder = false
    pendingAccept = nil
    pendingAcceptNotif = false
    CFG.ordersDone = CFG.ordersDone + 1
    markDirty()
    logAct('Order done: ' .. tostring(reason))
    notify(L'Заказ завершён. Счёт: ' .. CFG.ordersDone, 0x00FF00)
end

local function resetCatchCycle(reason)
    tapSequenceActive = false
    awaitingDialog    = false
    tapSeqRejected    = {}
    logAct('Reset cycle: ' .. tostring(reason))
end

-- ============================================================
--  ЧАТ
-- ============================================================
local function isPlayerMessage(text)
    if text:find(L'говорит:', 1, true) then return true end
    if text:find(L'шепчет:', 1, true) then return true end
    if text:find(L'кричит:', 1, true) then return true end
    return false
end

function sampev.onServerMessage(color, text)
    if not isPlayerMessage(text) then logChat(stripColors(text)) end
    if not active then return end

    local cleanN = normalize(stripColors(text))

    if cleanN:find(L'клиент оплатил', 1, true) then
        local cash = parseMoney(stripColors(text))
        if cash > 0 then
            CFG.moneyEarned = CFG.moneyEarned + cash
            markDirty()
            logAct('Money +' .. cash .. ' (total ' .. CFG.moneyEarned .. ')')
        end
    end

    if pendingAccept and (cleanN:find(L'заказ уже принят', 1, true)
                       or cleanN:find(L'заказ недоступен', 1, true)) then
        logAct('Server rejected our accept')
        hasActiveOrder = false
        pendingAccept = nil
        pendingAcceptNotif = false
        resetCatchCycle('accept rejected')
        return
    end

    if cleanN:find(L'нельзя принять заказ', 1, true)
       or cleanN:find(L'уже выполняете заказ', 1, true) then
        hasActiveOrder = true
        pendingAccept = nil
        resetCatchCycle('already has order')
        return
    end

    if hasActiveOrder then
        if cleanN:find(L'вы доставили клиента', 1, true) then
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
        if text:find('%+%d+%$') then
            local cash = tonumber(text:match('%+(%d+)%$')) or 0
            finishOrder('+' .. cash .. '$'); return
        end
        if cleanN:find(L'вы прервали заказ', 1, true)
           or cleanN:find(L'вы закончили работу', 1, true) then
            finishOrder(L'прерван/закончен'); return
        end
    end

    -- НОВЫЙ ЗАКАЗ в чате
    if CFG.catchEnabled
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
            lastTapTime = os.clock() * 1000
            awaitingDialog = true
            awaitingExpire = os.clock() + 6
            tapSequenceActive = true
            tapSeqIndex = 1
            tapSeqRejected = {}

            sendTapPacketWithIndex(0)
            logAct('Tap sent: index=0 (instant)')

            tapSeqNextSend = os.clock() + TAP_STEP_MS / 1000
            logAct('New order (chat) - start scanning')
            notify(L'Новый заказ, ищу...', 0xFFFF00)
        end
    end
end

-- ============================================================
--  ДИАЛОГИ
-- ============================================================
local function respondSoon(id, button, why)
    lua_thread.create(function()
        wait(DIALOG_RESPONSE_WAIT)
        sampSendDialogResponse(id, button, 0, '')
        logAct(string.format('SEND resp id=%s btn=%d (%s)',
            tostring(id), button, tostring(why or '-')))
    end)
end

function sampev.onShowDialog(id, style, title, b1, b2, text)
    logDlg(string.format('id=%s title=%q b1=%q b2=%q',
        tostring(id), tostring(title), tostring(b1), tostring(b2)))
    if text and text ~= '' then logRaw('      TEXT | ' .. tostring(text):sub(1, 200)) end
    if not active then return end

    local titleN = normalize(stripColors(title or ''))
    local bodyN  = normalize(stripColors(text or ''))
    local b1N    = normalize(b1 or '')
    local b2N    = normalize(b2 or '')

    -- ЗАЩИТА: платёжные/договорные окна не трогаем никогда
    local isPayment = bodyN:find(':cash:', 1, true)
                   or bodyN:find(L'вознаграждение', 1, true)
    if isPayment then
        logAct('Payment dialog - NOT touched')
        return
    end

    local isConfirm = titleN:find(L'подтверждение', 1, true)
                  or b1N == L'принять'
                  or (b1N:find(L'принять', 1, true) and b2N:find(L'закрыть', 1, true))

    if awaitingDialog and os.clock() < awaitingExpire and isConfirm then
        awaitingDialog = false
        tapSequenceActive = false
        hasActiveOrder = true
        pendingAccept = os.clock()
        pendingAcceptNotif = false
        logAct('Order dialog accepted (tap scan)')
        notify(L'Диалог найден, принимаю заказ', 0xFFFF00)
        if CFG.autoAccept then
            respondSoon(id, 1, 'accept')
        end
        return
    end

    if not awaitingDialog and isConfirm and b1N == L'принять' then
        logAct('Repeat confirm - accept')
        respondSoon(id, 1, 'accept-repeat')
        return
    end

    -- Заказ приходит ДИАЛОГОМ: упоминается заказ/такси, кнопка 1 = Взять/Принять/Да
    local isOrderLike = titleN:find(L'заказ', 1, true)
                     or titleN:find(L'такс', 1, true)
                     or bodyN:find(L'заказ', 1, true)
                     or bodyN:find(L'такс', 1, true)
    local isYesBtn = b1N == L'взять' or b1N == L'принять' or b1N == L'да'

    if CFG.catchEnabled and CFG.autoAccept
       and not hasActiveOrder
       and isOrderLike and isYesBtn then
        hasActiveOrder = true
        pendingAccept = os.clock()
        pendingAcceptNotif = false
        logAct('Order via dialog - accepting')
        notify(L'Принимаю заказ (диалог)', 0xFFFF00)
        respondSoon(id, 1, 'order-dialog')
        return
    end

    local is_error = titleN:find(L'ошибка', 1, true)
                  or bodyN:find(L'ошибка', 1, true)

    if is_error then
        if bodyN:find(L'заказ уже принят', 1, true)
           or bodyN:find(L'заказ отмен', 1, true) then
            logAct('Error: order already taken/cancelled')
            hasActiveOrder = false
            pendingAccept = nil
            pendingAcceptNotif = false
            respondSoon(id, 1, 'close-error')
            return
        end
        if bodyN:find(L'нельзя принять заказ', 1, true)
           or bodyN:find(L'уже выполняете', 1, true) then
            hasActiveOrder = true
            pendingAccept = nil
            resetCatchCycle('already has order')
            respondSoon(id, 1, 'close-error')
            return
        end
        logAct('Closing error dialog')
        respondSoon(id, 1, 'close-error')
        return
    end

    logAct(string.format('Dialog id=%s ignored (b1=%s, b2=%s)',
        tostring(id), tostring(b1), tostring(b2)))
end

-- ============================================================
--  UI
-- ============================================================
local LastTime   = {}
local LastActive = {}

function ToggleButton(label, bool, a_speed)
    local p  = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()
    local result = false
    local h = imgui.GetTextLineHeightWithSpacing()
    local w = h * 1.7
    local r = h / 2
    local s = a_speed or 0.2

    local function ImSaturate(f)
        return f < 0.0 and 0.0 or (f > 1.0 and 1.0 or f)
    end

    local x_begin = bool[0] and 1.0 or 0.0
    local t_begin = bool[0] and 0.0 or 1.0

    if imgui.InvisibleButton(label, imgui.ImVec2(w, h)) then
        bool[0] = not bool[0]
        LastTime[label] = os.clock()
        LastActive[label] = true
        togglePulse[label] = 1
        result = true
    end

    if LastActive[label] then
        local time = os.clock() - LastTime[label]
        if time <= s then
            local anim = ImSaturate(time / s)
            x_begin = bool[0] and anim or 1.0 - anim
            t_begin = bool[0] and 1.0 - anim or anim
        else
            LastActive[label] = false
        end
    end

    if togglePulse[label] and togglePulse[label] > 0 then
        togglePulse[label] = math.max(0, togglePulse[label] - 0.08)
    end
    local pulse = togglePulse[label] or 0

    local bg_color = imgui.ImVec4(x_begin * 0.13, x_begin * 0.9, x_begin * 0.13,
        imgui.IsItemHovered(0) and 0.7 or 0.9)
    local t_color  = imgui.ImVec4(1, 1, 1, x_begin)

    if pulse > 0 then
        dl:AddCircleFilled(
            imgui.ImVec2(p.x + r + x_begin * (w - r * 2), p.y + r),
            r + 4 + pulse * 6,
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 0.78, 0.05, pulse * 0.4)),
            r + 8)
    end

    dl:AddRectFilled(imgui.ImVec2(p.x, p.y), imgui.ImVec2(p.x + w, p.y + h),
        imgui.ColorConvertFloat4ToU32(bg_color), r)
    dl:AddCircleFilled(
        imgui.ImVec2(p.x + r + x_begin * (w - r * 2), p.y + r),
        t_begin < 0.5 and x_begin * r or t_begin * r,
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.9, 0.9, 0.9, 1.0)), r + 5)
    dl:AddText(
        imgui.ImVec2(p.x + w + r, p.y + r - (r / 2) - (imgui.CalcTextSize(label).y / 4)),
        imgui.ColorConvertFloat4ToU32(t_color), label)
    return result
end

function GlassChild(name, size, fun)
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(1, 1, 1, 0.08))
    imgui.BeginChild(name, size, false)
    imgui.SetCursorPos(imgui.ImVec2(10, 10))
    imgui.Text(name)
    imgui.Separator()
    imgui.SetCursorPosY(48)
    fun()
    imgui.EndChild()
    imgui.PopStyleColor()
end

-- ============================================================
--  ЛОГОТИП
-- ============================================================
local function DrawLogo(x, y)
    local DL = imgui.GetWindowDrawList()
    local p  = imgui.ImVec2(x, y)

    local panelW, panelH = 175, 56

    DL:AddRectFilled(
        imgui.ImVec2(p.x + 3, p.y + 4),
        imgui.ImVec2(p.x + panelW + 3, p.y + panelH + 4),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.55)),
        11)

    DL:AddRectFilled(
        imgui.ImVec2(p.x, p.y),
        imgui.ImVec2(p.x + panelW, p.y + panelH),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.78, 0.05, 1.0)),
        11)

    local t = (os.clock() % 4.0) / 4.0
    if t < 0.35 then
        local sx = p.x - 40 + (panelW + 80) * (t / 0.35)
        DL:PushClipRect(
            imgui.ImVec2(p.x, p.y),
            imgui.ImVec2(p.x + panelW, p.y + panelH), true)
        DL:AddRectFilled(
            imgui.ImVec2(sx - 20, p.y - 5),
            imgui.ImVec2(sx + 20, p.y + panelH + 5),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.28)),
            10)
        DL:PopClipRect()
    end

    DL:AddRect(
        imgui.ImVec2(p.x, p.y),
        imgui.ImVec2(p.x + panelW, p.y + panelH),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.05, 0.05, 1.0)),
        11, 0, 2)

    local stripes = 6
    local stripeH = panelH / stripes
    for i = 0, stripes - 1 do
        if i % 2 == 0 then
            DL:AddRectFilled(
                imgui.ImVec2(p.x + 1, p.y + i * stripeH + 1),
                imgui.ImVec2(p.x + 9, p.y + (i + 1) * stripeH - 1),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.05, 0.05, 1.0)),
                0)
            DL:AddRectFilled(
                imgui.ImVec2(p.x + panelW - 9, p.y + i * stripeH + 1),
                imgui.ImVec2(p.x + panelW - 1, p.y + (i + 1) * stripeH - 1),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.05, 0.05, 1.0)),
                0)
        end
    end

    local pulse = 0.5 + 0.5 * math.sin(os.clock() * 2.5)
    DL:AddCircleFilled(imgui.ImVec2(p.x + 30, p.y + panelH / 2), 16,
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.05, 0.05, 1.0)))
    DL:AddCircle(imgui.ImVec2(p.x + 30, p.y + panelH / 2), 16,
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.78, 0.05, 0.4 + pulse * 0.6)),
        24, 2)

    if FONT_LOGO then imgui.PushFont(FONT_LOGO) end
    DL:AddText(
        imgui.ImVec2(p.x + 23, p.y + panelH / 2 - 12),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.78, 0.05, 1.0)),
        'T')
    if FONT_LOGO then imgui.PopFont() end

    if FONT_LOGO then imgui.PushFont(FONT_LOGO) end
    DL:AddText(
        imgui.ImVec2(p.x + 56, p.y + 12),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.05, 0.05, 1.0)),
        'TAXORD')
    if FONT_LOGO then imgui.PopFont() end
end

-- ============================================================
--  ОКНО
-- ============================================================
local tabsList = { selected = '1:1', tabs = {} }

local function GlassWindow(title, var, closeButton, leftSize, tabs, flags)
    local size = imgui.ImVec2(800, 470)
    local res  = imgui.ImVec2(getScreenResolution())

    imgui.SetNextWindowPos(imgui.ImVec2(res.x / 2, res.y / 2),
        imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(size, imgui.Cond.FirstUseEver)

    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, windowAlpha)

    if imgui.Begin('glassmorphism', var,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoBackground
        + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar + (flags or 0)) then

        local pos, wsize = imgui.GetWindowPos(), imgui.GetWindowSize()
        local FGDL = imgui.GetForegroundDrawList()
        local DL   = imgui.GetWindowDrawList()

        DL:AddRectFilled(
            imgui.ImVec2(pos.x + leftSize, pos.y),
            imgui.ImVec2(pos.x + wsize.x, pos.y + wsize.y),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.05, 0.05, 0.72)),
            11, 2 + 8)
        DL:AddRectFilled(
            pos,
            imgui.ImVec2(pos.x + leftSize, pos.y + wsize.y),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.05, 0.05, 0.55)),
            11, 1 + 4)

        do
            local pulse = 0.55 + 0.45 * math.sin(os.clock() * 2.5)
            local dotColor = hasActiveOrder
                and imgui.ImVec4(0.2, 1.0, 0.3, pulse)
                or  imgui.ImVec4(1.0, 0.8, 0.2, pulse)
            DL:AddCircleFilled(
                imgui.ImVec2(pos.x + wsize.x - 22, pos.y + 22), 5,
                imgui.ColorConvertFloat4ToU32(dotColor))
            DL:AddCircle(
                imgui.ImVec2(pos.x + wsize.x - 22, pos.y + 22), 9,
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(dotColor.x, dotColor.y, dotColor.z, pulse * 0.4)),
                20, 1.5)
        end

        imgui.SetCursorPos(imgui.ImVec2(15, 15))
        local cp = imgui.GetCursorScreenPos()
        imgui.InvisibleButton('##CLOSEBUTTON', imgui.ImVec2(18, 18))
        if imgui.IsItemClicked() then var[0] = false end
        local hover = imgui.IsItemHovered()
        FGDL:AddCircleFilled(
            imgui.ImVec2(cp.x + 9, cp.y + 9), 8,
            imgui.ColorConvertFloat4ToU32(hover
                and imgui.ImVec4(0.9, 0.28, 0.28, 1)
                or  imgui.ImVec4(1, 0.32, 0.31, 1)))
        if hover then
            FGDL:AddCircle(
                imgui.ImVec2(cp.x + 9, cp.y + 9), 10,
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 0.32, 0.31, 0.4)),
                20, 1.5)
        end

        DrawLogo(pos.x + 20, pos.y + 44)

        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        imgui.SetCursorPos(imgui.ImVec2(24, 110))
        imgui.TextColored(imgui.ImVec4(0.85, 0.85, 0.85, 1.0), u8(L'Автоловля заказов'))
        if FONT_SUB then imgui.PopFont() end

        imgui.SetCursorPos(imgui.ImVec2(15, 150))
        for categoryIndex, category in pairs(tabs.tabs) do
            for tabIndex, tab in pairs(category.list) do
                local key  = ('%s:%s'):format(categoryIndex, tabIndex)
                local isSel = tabs.selected == key

                if tabHover[key] == nil then tabHover[key] = isSel and 1 or 0 end

                local tpos = imgui.GetCursorScreenPos()
                local th = 34
                local tw = leftSize - 30

                imgui.SetCursorPosX(20)
                imgui.InvisibleButton('##TAB_' .. key, imgui.ImVec2(tw, th))
                local hovered = imgui.IsItemHovered()

                local target = (hovered or isSel) and 1 or 0
                tabHover[key] = tabHover[key] + (target - tabHover[key]) * 0.22

                local hv = tabHover[key]
                local bgCol
                if isSel then
                    bgCol = imgui.ImVec4(1.0, 0.78, 0.05, 0.95)
                else
                    bgCol = imgui.ImVec4(
                        0.13 + hv * 0.06,
                        0.13 + hv * 0.06,
                        0.13 + hv * 0.06,
                        0.85)
                end

                if isSel then
                    DL:AddRectFilled(
                        imgui.ImVec2(tpos.x - 3, tpos.y - 3),
                        imgui.ImVec2(tpos.x + tw + 3, tpos.y + th + 3),
                        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.78, 0.05, 0.18)),
                        10)
                end

                DL:AddRectFilled(
                    tpos,
                    imgui.ImVec2(tpos.x + tw, tpos.y + th),
                    imgui.ColorConvertFloat4ToU32(bgCol),
                    8)

                if isSel then
                    DL:AddRect(
                        tpos,
                        imgui.ImVec2(tpos.x + tw, tpos.y + th),
                        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.05, 0.05, 1.0)),
                        8, 0, 2)
                end

                local ts = imgui.CalcTextSize(tab.name)
                local tx = tpos.x + tw / 2 - ts.x / 2
                local ty = tpos.y + th / 2 - ts.y / 2
                local textCol = isSel
                    and imgui.ImVec4(0.05, 0.05, 0.05, 1.0)
                    or  imgui.ImVec4(0.9, 0.9, 0.9, 1.0)

                DL:AddText(imgui.ImVec2(tx, ty),
                    imgui.ColorConvertFloat4ToU32(textCol), tab.name)

                if imgui.IsItemClicked() then
                    tabs.selected = key
                end

                imgui.SetCursorPosY(imgui.GetCursorPosY() + 4)
            end
        end

        imgui.SetCursorPos(imgui.ImVec2(leftSize + 15, 15))

        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, windowAlpha * tabFade)

        if imgui.BeginChild('content',
            imgui.ImVec2(wsize.x - leftSize - 30, wsize.y - 30), true) then

            if tabSlide > 0 then
                imgui.SetCursorPosX(imgui.GetCursorPosX() + tabSlide)
            end

            local section, tabIdx = tabs.selected:match('(%d+):(%d+)')
            local sIdx, tIdx = tonumber(section), tonumber(tabIdx)
            local cat = tabs.tabs[sIdx]
            if cat and cat.list and cat.list[tIdx] and type(cat.list[tIdx].frame) == 'function' then
                cat.list[tIdx].frame()
            else
                imgui.Text('UI error: tab not found')
            end
        end
        imgui.EndChild()

        imgui.PopStyleVar()

        imgui.End()
    end

    imgui.PopStyleVar()
end

-- ============================================================
--  ШРИФТЫ И СТИЛЬ
-- ============================================================
imgui.OnInitialize(function()
    local imio = imgui.GetIO()
    pcall(function() imio.Fonts:Clear() end)
    local cyr_ranges = imio.Fonts:GetGlyphRangesCyrillic()

    local regular_paths = {
        '/system/fonts/Roboto-Regular.ttf',
        '/system/fonts/RobotoCondensed-Regular.ttf',
        '/system/fonts/NotoSans-Regular.ttf',
        '/system/fonts/DroidSans.ttf',
    }
    local bold_paths = {
        '/system/fonts/Roboto-Bold.ttf',
        '/system/fonts/DroidSans-Bold.ttf',
        '/system/fonts/NotoSans-Bold.ttf',
        '/system/fonts/Roboto-Black.ttf',
    }

    local loaded = false
    for _, path in ipairs(regular_paths) do
        local fh = io.open(path, 'r')
        if fh then
            fh:close()
            local ok, font = pcall(function()
                return imio.Fonts:AddFontFromFileTTF(path, 16, nil, cyr_ranges)
            end)
            if ok and font then
                imio.FontDefault = font
                loaded = true
                break
            end
        end
    end
    if not loaded then
        pcall(function() imio.Fonts:AddFontDefault() end)
    end

    for _, path in ipairs(bold_paths) do
        local fh = io.open(path, 'r')
        if fh then
            fh:close()
            local ok, font = pcall(function()
                return imio.Fonts:AddFontFromFileTTF(path, 26, nil, cyr_ranges)
            end)
            if ok and font then
                FONT_LOGO = font
                break
            end
        end
    end
    if not FONT_LOGO then FONT_LOGO = imio.FontDefault end

    for _, path in ipairs(regular_paths) do
        local fh = io.open(path, 'r')
        if fh then
            fh:close()
            local ok, font = pcall(function()
                return imio.Fonts:AddFontFromFileTTF(path, 14, nil, cyr_ranges)
            end)
            if ok and font then
                FONT_SUB = font
                break
            end
        end
    end
    if not FONT_SUB then FONT_SUB = imio.FontDefault end

    for _, path in ipairs(bold_paths) do
        local fh = io.open(path, 'r')
        if fh then
            fh:close()
            local ok, font = pcall(function()
                return imio.Fonts:AddFontFromFileTTF(path, 22, nil, cyr_ranges)
            end)
            if ok and font then
                FONT_BIG = font
                break
            end
        end
    end
    if not FONT_BIG then FONT_BIG = FONT_LOGO end

    local style = imgui.GetStyle()
    style.WindowPadding     = imgui.ImVec2(0, 0)
    style.WindowRounding    = 12
    style.ChildRounding     = 10
    style.FrameRounding     = 5
    style.PopupRounding     = 8
    style.ScrollbarRounding = 8
    style.GrabRounding      = 5
    style.ItemSpacing       = imgui.ImVec2(8, 8)
    style.ItemInnerSpacing  = imgui.ImVec2(6, 6)
    style.FramePadding      = imgui.ImVec2(8, 6)
    style.WindowBorderSize  = 0

    local col = style.Colors
    col[imgui.Col.WindowBg]         = imgui.ImVec4(0, 0, 0, 0.5)
    col[imgui.Col.Border]           = imgui.ImVec4(0, 0, 0, 0)
    col[imgui.Col.Text]             = imgui.ImVec4(0.95, 0.96, 0.98, 1.00)
    col[imgui.Col.TextDisabled]     = imgui.ImVec4(0.36, 0.42, 0.47, 1.00)
    col[imgui.Col.FrameBg]          = imgui.ImVec4(0.10, 0.12, 0.15, 1)
    col[imgui.Col.FrameBgHovered]   = imgui.ImVec4(0.12, 0.16, 0.20, 1)
    col[imgui.Col.FrameBgActive]    = imgui.ImVec4(0.13, 0.19, 0.24, 1)
    col[imgui.Col.Button]           = imgui.ImVec4(0.08, 0.11, 0.15, 1)
    col[imgui.Col.ButtonHovered]    = imgui.ImVec4(0.10, 0.17, 0.23, 1)
    col[imgui.Col.ButtonActive]     = imgui.ImVec4(0.00, 0.40, 0.72, 1)
    col[imgui.Col.Header]           = imgui.ImVec4(0.07, 0.12, 0.17, 1)
    col[imgui.Col.HeaderHovered]    = imgui.ImVec4(0.08, 0.18, 0.25, 1)
    col[imgui.Col.HeaderActive]     = imgui.ImVec4(0.00, 0.40, 0.72, 1)
    col[imgui.Col.SliderGrab]       = imgui.ImVec4(1.00, 0.78, 0.05, 1.00)
    col[imgui.Col.SliderGrabActive] = imgui.ImVec4(1.00, 0.85, 0.15, 1.00)
    col[imgui.Col.CheckMark]        = imgui.ImVec4(1.00, 0.78, 0.05, 1.00)
end)

-- ============================================================
--  ТАБ: ЗАКАЗЫ
-- ============================================================
local function OrdersTabFrame()
    if not statInit then
        statDispOrders = CFG.ordersDone
        statDispMoney  = CFG.moneyEarned
        statInit = true
    end
    statDispOrders = statDispOrders + (CFG.ordersDone - statDispOrders) * 0.15
    statDispMoney  = statDispMoney  + (CFG.moneyEarned - statDispMoney)  * 0.15
    if math.abs(statDispOrders - CFG.ordersDone) < 0.01 then statDispOrders = CFG.ordersDone end
    if math.abs(statDispMoney  - CFG.moneyEarned) < 0.5 then statDispMoney  = CFG.moneyEarned end

    imgui.SetCursorPos(imgui.ImVec2(0, 10))
    GlassChild(u8(L'Автоловля'), imgui.ImVec2(270, 390), function()
        local c = new.bool(CFG.catchEnabled)
        if ToggleButton(u8(L'Ловить заказы'), c, 0.2) then
            CFG.catchEnabled = c[0]; buf.catchEnabled[0] = c[0]; markDirty()
        end
        imgui.Spacing(); imgui.Spacing()
        local a = new.bool(CFG.autoAccept)
        if ToggleButton(u8(L'Авто-принять заказ'), a, 0.2) then
            CFG.autoAccept = a[0]; buf.autoAccept[0] = a[0]; markDirty()
        end

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        imgui.TextColored(imgui.ImVec4(0.65, 0.72, 0.80, 1),
            u8(L'Ловля через диалоги и чат.'))
        imgui.TextWrapped(u8(L'Платёжные окна не трогаются автоматически.'))
        if FONT_SUB then imgui.PopFont() end
    end)

    imgui.SetCursorPos(imgui.ImVec2(290, 10))
    GlassChild(u8(L'Статистика'), imgui.ImVec2(250, 390), function()
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        imgui.TextColored(imgui.ImVec4(0.65, 0.72, 0.80, 1), u8(L'Заказов выполнено'))
        if FONT_SUB then imgui.PopFont() end

        if FONT_BIG then imgui.PushFont(FONT_BIG) end
        imgui.TextColored(imgui.ImVec4(1.0, 0.78, 0.05, 1), tostring(math.floor(statDispOrders + 0.5)))
        if FONT_BIG then imgui.PopFont() end

        imgui.Spacing()
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        imgui.TextColored(imgui.ImVec4(0.65, 0.72, 0.80, 1), u8(L'Заработано'))
        if FONT_SUB then imgui.PopFont() end

        if FONT_BIG then imgui.PushFont(FONT_BIG) end
        imgui.TextColored(imgui.ImVec4(1.0, 0.78, 0.05, 1), '$' .. tostring(math.floor(statDispMoney + 0.5)))
        if FONT_BIG then imgui.PopFont() end

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        imgui.TextColored(imgui.ImVec4(0.65, 0.72, 0.80, 1), u8(L'Статус:'))
        if FONT_SUB then imgui.PopFont() end

        if pendingAccept then
            imgui.TextColored(imgui.ImVec4(1, 0.7, 0.2, 1), u8(L'Ожидаем метку'))
        elseif tapSequenceActive then
            imgui.TextColored(imgui.ImVec4(1, 0.7, 0.2, 1), u8(L'Перебор: #') .. tapSeqIndex)
        elseif hasActiveOrder then
            imgui.TextColored(imgui.ImVec4(1, 0.7, 0.2, 1), u8(L'В заказе'))
        elseif awaitingDialog then
            imgui.TextColored(imgui.ImVec4(1, 0.7, 0.2, 1), u8(L'Ждём диалог'))
        else
            imgui.TextColored(imgui.ImVec4(0.55, 0.62, 0.70, 1), u8(L'Ожидание'))
        end

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        if imgui.Button(u8(L'Сбросить статистику'), imgui.ImVec2(-1, 30)) then
            CFG.ordersDone = 0; CFG.moneyEarned = 0
            statDispOrders = 0; statDispMoney = 0
            markDirty()
            notify(L'Статистика сброшена')
        end
        imgui.Spacing()
        if imgui.Button(u8(L'Сброс заказа'), imgui.ImVec2(-1, 30)) then
            finishOrder('manual')
        end
        imgui.Spacing()
        if updateDownloading then
            imgui.TextColored(imgui.ImVec4(1, 0.7, 0.2, 1), u8(L'Идёт проверка/скачивание...'))
            imgui.Spacing()
        end
        if updateAvailable then
            if imgui.Button(u8(L'Обновить до ') .. u8(remoteVersion), imgui.ImVec2(-1, 30)) then
                doUpdate()
            end
        else
            if imgui.Button(u8(L'Проверить обновления'), imgui.ImVec2(-1, 30)) then
                doCheck()
            end
        end
        imgui.Spacing()
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        imgui.TextColored(imgui.ImVec4(0.55, 0.62, 0.70, 1),
            u8(L'Версия: ') .. LOCAL_VERSION)
        if FONT_SUB then imgui.PopFont() end
    end)
end

-- ============================================================
--  ТАБ: ИНФО
-- ============================================================
local function InfoTabFrame()
    imgui.SetCursorPos(imgui.ImVec2(0, 10))
    GlassChild(u8(L'О программе'), imgui.ImVec2(540, 390), function()
        if FONT_BIG then imgui.PushFont(FONT_BIG) end
        imgui.TextColored(imgui.ImVec4(1.0, 0.78, 0.05, 1), 'TAXORD 28.0.8')
        if FONT_BIG then imgui.PopFont() end

        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        imgui.TextColored(imgui.ImVec4(0.65, 0.72, 0.80, 1), u8(L'Автоловля заказов такси'))
        if FONT_SUB then imgui.PopFont() end

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        imgui.PushTextWrapPos(imgui.GetCursorPos().x + 510)
        imgui.TextWrapped(u8(L'Ловит заказы двумя способами: через диалоги сервера и через чат.'))
        imgui.Spacing()
        imgui.TextWrapped(u8(L'Диалоги с оплатой (:CASH:) не нажимает автоматически.'))
        imgui.Spacing()
        imgui.TextWrapped(u8(L'Обновление: проверка версии с GitHub, загрузка новой версии одной кнопкой.'))
        imgui.PopTextWrapPos()

        imgui.Spacing(); imgui.Spacing()
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        imgui.TextColored(imgui.ImVec4(0.65, 0.72, 0.80, 1), u8(L'Команды:'))
        imgui.TextColored(imgui.ImVec4(0.85, 0.85, 0.85, 1), u8(L'/taxord    - меню'))
        imgui.TextColored(imgui.ImVec4(0.85, 0.85, 0.85, 1), u8(L'/zarabotok - статистика в чат'))
        imgui.TextColored(imgui.ImVec4(0.85, 0.85, 0.85, 1), u8(L'/resetstat - сброс статистики'))
        imgui.TextColored(imgui.ImVec4(0.85, 0.85, 0.85, 1), u8(L'/checkupd  - проверить обновление'))
        imgui.TextColored(imgui.ImVec4(0.85, 0.85, 0.85, 1), u8(L'/update    - скачать обновление'))
        if FONT_SUB then imgui.PopFont() end
    end)
end

tabsList.tabs = {
    {
        name = 'TAXORD',
        list = {
            { name = u8(L'Заказы'), icon = '', frame = OrdersTabFrame },
            { name = u8(L'Инфо'),   icon = '', frame = InfoTabFrame   },
        }
    }
}

-- ============================================================
--  ОКНО: рендер
-- ============================================================
imgui.OnFrame(
    function()
        return windowRendering and isSampAvailable() and not isPauseMenuActive()
    end,
    function(this)
        -- ФИКС: пока меню открыто - захватываем тапы, чтобы они
        -- не проходили в игру (не закрывалось и не писалось /help)
        this.ShowCursor = window[0]

        local target = window[0] and 1.0 or 0.0
        windowAlpha = windowAlpha + (target - windowAlpha) * 0.24

        if windowAlpha < 0.015 and not window[0] then
            windowRendering = false
            windowAlpha = 0
            return
        end

        if tabsList.selected ~= lastSelectedTab then
            tabFade = 0
            tabSlide = 50
            lastSelectedTab = tabsList.selected
        end
        if tabFade < 1 then tabFade = math.min(1, tabFade + 0.075) end
        if tabSlide > 0 then
            tabSlide = tabSlide - 4.5
            if tabSlide < 0 then tabSlide = 0 end
        end

        GlassWindow('TaxordMenu', window, true, 200, tabsList,
            imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)
    end
)

-- ============================================================
--  ТОСТЫ
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
            sn.state   = 'showing'
            sn.version = sn.version + 1
            sn.anim    = 0
            sn.glow    = 0
            acquireNotifyLock()
            local myv = sn.version

            bringFloatTo(0, 1, sn.timer, NOTIFY_ANIM_IN, 'outQuart', function(f)
                if sn.version == myv then sn.anim = f end
            end)

            lua_thread.create(function()
                local t0 = os.clock()
                while sn.version == myv and (os.clock() - t0) < (NOTIFY_DURATION + 1.5) do
                    sn.glow = 0.5 + 0.5 * math.sin((os.clock() - t0) * 5)
                    wait(0)
                end
            end)
        elseif sn.state == 'showing'
            and (os.clock() - sn.timer) >= NOTIFY_DURATION then
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

        if sn.state == 'idle' then return end

        local sw, sh = getScreenResolution()
        if not sw or sw <= 0 then return end

        local text = u8(sn.message)
        local ts   = imgui.CalcTextSize(text)
        local pad_x = 70
        local pad_y = 20
        local iconSize = 40
        local w_px = math.min(sw - 40, ts.x + pad_x * 2 + iconSize)
        local h_px = math.max(64, ts.y + pad_y * 2)

        local w_pos = imgui.ImVec2(sw / 2, sh - sn.anim * (h_px + 20) - 10)

        imgui.SetNextWindowPos(w_pos, imgui.Cond.Always, imgui.ImVec2(0.5, 0.0))
        imgui.SetNextWindowSize(imgui.ImVec2(w_px, h_px), imgui.Cond.Always)

        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, sn.anim)
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0))

        imgui.Begin('##TaxordToast', nil,
            imgui.WindowFlags.NoMove +
            imgui.WindowFlags.NoDecoration +
            imgui.WindowFlags.NoInputs)

        local p  = imgui.GetCursorScreenPos()
        local DL = imgui.GetWindowDrawList()
        local r  = h_px / 2
        local A  = imgui.ImVec2(p.x, p.y)
        local B  = imgui.ImVec2(p.x + w_px, p.y + h_px)

        do
            local g = sn.glow * sn.anim
            DL:AddRectFilled(
                imgui.ImVec2(A.x - 4, A.y - 4),
                imgui.ImVec2(B.x + 4, B.y + 4),
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.78, 0.05, 0.25 * g)),
                18)
        end

        local bg = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.09, 0.08, 0.05, 0.95))
        DL:PathClear()
        DL:PathArcTo(imgui.ImVec2(A.x + r, A.y + r), r, math.rad(90),  math.rad(270), 50)
        DL:PathArcTo(imgui.ImVec2(B.x - r, B.y - r), r, math.rad(-90), math.rad(90),  50)
        DL:PathFillConvex(bg)

        local ac = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.78, 0.05, 1.0))
        DL:AddRectFilled(imgui.ImVec2(A.x + 10, A.y + 12),
            imgui.ImVec2(A.x + 14, B.y - 12), ac, 2)

        do
            local icx = A.x + 42
            local icy = A.y + h_px / 2
            local ir  = 14

            local iconColor = imgui.ImVec4(0.15, 0.15, 0.15, 1)
            local iconBg    = imgui.ImVec4(1.0, 0.78, 0.05, 1)
            local iconChar  = 'i'

            if sn.icon == 'success' then
                iconBg   = imgui.ImVec4(0.20, 0.85, 0.35, 1)
                iconChar = '+'
            elseif sn.icon == 'warn' then
                iconBg   = imgui.ImVec4(1.0, 0.78, 0.05, 1)
                iconChar = '!'
            elseif sn.icon == 'error' then
                iconBg   = imgui.ImVec4(0.95, 0.30, 0.30, 1)
                iconChar = 'x'
            end

            local g = sn.glow
            DL:AddCircleFilled(imgui.ImVec2(icx, icy), ir + 6 + g * 3,
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(iconBg.x, iconBg.y, iconBg.z, 0.25 * g)))
            DL:AddCircleFilled(imgui.ImVec2(icx, icy), ir,
                imgui.ColorConvertFloat4ToU32(iconBg))

            if FONT_BIG then imgui.PushFont(FONT_BIG) end
            local its = imgui.CalcTextSize(iconChar)
            DL:AddText(
                imgui.ImVec2(icx - its.x / 2, icy - its.y / 2 - 2),
                imgui.ColorConvertFloat4ToU32(iconColor),
                iconChar)
            if FONT_BIG then imgui.PopFont() end
        end

        imgui.SetCursorPos(imgui.ImVec2(pad_x + 20, (h_px - ts.y) / 2))
        imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), text)

        do
            local progressW = (B.x - A.x - 20) * (1 - math.min(1, (os.clock() - sn.timer) / NOTIFY_DURATION))
            if progressW > 0 then
                DL:AddRectFilled(
                    imgui.ImVec2(A.x + 10, B.y - 4),
                    imgui.ImVec2(A.x + 10 + progressW, B.y - 2),
                    imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.78, 0.05, 0.7)),
                    1)
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

    logInit()
    loadCfg()
    logAct('Script loaded. v28.0.8 (utf8_file=' .. tostring(FILE_IS_UTF8) .. ')')

    -- /taxord — открыть/закрыть меню
    sampRegisterChatCommand('taxord', function()
        if window[0] then
            window[0] = false
        else
            window[0] = true
            windowRendering = true
            windowAlpha = 0
            tabFade = 1
            tabSlide = 0
            lastSelectedTab = tabsList.selected
        end
        logAct('Menu: ' .. tostring(window[0]))
    end)

    -- /zarabotok — статистика в чат
    sampRegisterChatCommand('zarabotok', function()
        local total  = CFG.moneyEarned
        local orders = CFG.ordersDone
        sampAddChatMessage(
            string.format('{FFCC00}[TaxOrd] {FFFFFF}' .. L'Заказов: {00FF00}%d {FFFFFF}| ' .. L'Заработано: {00FF00}$%d',
                orders, total),
            -1)
        notify(string.format(L'Заказов: %d | Заработано: $%d', orders, total), 0x00FF00)
        logAct(string.format('/zarabotok -> orders=%d money=%d', orders, total))
    end)

    -- /resetstat — сброс статистики
    sampRegisterChatCommand('resetstat', function()
        CFG.ordersDone  = 0
        CFG.moneyEarned = 0
        statDispOrders  = 0
        statDispMoney   = 0
        markDirty()
        saveCfg()
        notify(L'Статистика сброшена', 0xFFAA00)
        logAct('/resetstat -> stats cleared')
    end)

    -- /checkupd — проверить обновление
    sampRegisterChatCommand('checkupd', doCheck)

    -- /update — скачать обновление
    sampRegisterChatCommand('update', doUpdate)

    notify(L'TaxOrd 28.0.8 загружен, /taxord - меню', 0x00FF00)

    -- автопроверка обновления через 10 секунд после загрузки
    startUpdateCheck()

    lastAutoSave = os.clock()

    while true do
        wait(0)
        local now = os.clock()

        if cfgDirty and (now - lastAutoSave) > 1.5 then
            lastAutoSave = now
            saveCfg()
        end

        if pendingAccept and (now - pendingAccept) > PENDING_TIMEOUT and not pendingAcceptNotif then
            logAct('Pending accept timeout')
            hasActiveOrder = false
            pendingAccept = nil
            resetCatchCycle('accept timeout')
        end

        if tapSequenceActive then
            if now >= tapSeqNextSend then
                local found = false
                while tapSeqIndex <= MAX_TAPS do
                    if not tapSeqRejected[tapSeqIndex] then
                        sendTapPacketWithIndex(tapSeqIndex)
                        logAct('Tap sent: index=' .. tapSeqIndex)
                        tapSeqIndex = tapSeqIndex + 1
                        found = true
                        break
                    end
                    tapSeqIndex = tapSeqIndex + 1
                end

                if not found then
                    tapSequenceActive = false
                    logAct('All indexes scanned - no dialog')
                else
                    tapSeqNextSend = now + TAP_STEP_MS / 1000
                end
            end

            if awaitingDialog and now > awaitingExpire then
                awaitingDialog = false
                tapSequenceActive = false
                logAct('Dialog timeout')
            end
        end
    end
end

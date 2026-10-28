-- Help_for_Job.lua
-- MonetLoader 3.8.x / MoonLoader
-- Help for Job (HfJ) - автоловля заказов + учёт зарплаты по работам
-- v29.0.1

script_name('HfJ')
script_version('29.0.1')

local imgui    = require 'mimgui'
local new      = imgui.new
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local sampev = require 'samp.events'

local VERSION       = '29.0.1'
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

-- Переменные для перетаскивания окна без вылетов
local winPos     = nil
local winPosInit = false

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

-- Тумблеры создаём один раз: new.bool каждый кадр = мусор и утечки
local tgCatch  = new.bool(false)
local tgAccept = new.bool(false)

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
--  ПУТИ И ЛОГ
-- ============================================================
local WORK_DIR    = getWorkingDirectory()
local CONFIG_DIR  = WORK_DIR .. '/config'
local LOG_DIR     = WORK_DIR .. '/logs'
local CONFIG_FILE = CONFIG_DIR .. '/hfj.cfg'
local LEGACY_CONFIG_FILE = CONFIG_DIR .. '/taxord.cfg'
local LOG_FILE    = LOG_DIR .. '/hfj.log'

if not doesDirectoryExist(CONFIG_DIR) then pcall(createDirectory, CONFIG_DIR) end
if not doesDirectoryExist(LOG_DIR)    then pcall(createDirectory, LOG_DIR)    end

local function logRaw(msg)
    print('[HfJ] ' .. msg)
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
    if f then f:write('=== Help for Job v' .. VERSION .. ' ' .. os.date() .. ' ===\n'); f:close() end
end
local function logChat(t) logRaw('CHAT  | ' .. tostring(t)) end
local function logAct(t)  logRaw('ACT   | ' .. tostring(t)) end
local function logDlg(t)  logRaw('DLG   | ' .. tostring(t)) end

-- ============================================================
--  КОНФИГ И СТАТИСТИКА
-- ============================================================
local CFG = {
    catchEnabled = true,
    autoAccept   = true,
    ordersDone   = 0,
    moneyEarned  = 0,
}

local ZP = { taxi = 0, trucker = 0, collector = 0 }
local zpLastX, zpLastY, zpLastZ = nil, nil, nil
local zpMovedDist = 0.0
local ZP_MOVE_THRESHOLD = 50.0

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
    f:write('zpTaxi='       .. tostring(math.floor(ZP.taxi))      .. '\n')
    f:write('zpTrucker='    .. tostring(math.floor(ZP.trucker))   .. '\n')
    f:write('zpCollector='  .. tostring(math.floor(ZP.collector)) .. '\n')
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
            if k == 'ordersDone'   and n then CFG.ordersDone  = n end
            if k == 'moneyEarned'  and n then CFG.moneyEarned = n end
            if k == 'zpTaxi'       and n then ZP.taxi         = n end
            if k == 'zpTrucker'    and n then ZP.trucker      = n end
            if k == 'zpCollector'  and n then ZP.collector    = n end
        end
    end
    f:close()
    cfgToBuf()
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
    local raw = text:match('%$(%d[%d%.,]*)')
    if raw then
        local n = tonumber((raw:gsub('[%.,]', '')))
        if n and n > 0 then return n end
    end
    local maxVal, cur, hasDigits = 0, 0, false
    for i = 1, #text do
        local b = string.byte(text, i)
        if b and b >= 48 and b <= 57 then
            cur = cur * 10 + (b - 48)
            hasDigits = true
        elseif b == 46 then
        else
            if hasDigits and cur > maxVal then maxVal = cur end
            cur, hasDigits = 0, false
        end
    end
    if hasDigits and cur > maxVal then maxVal = cur end
    return maxVal > 0 and maxVal or nil
end

local function zpDetectJob(textN)
    if textN:find(L'инкассатор', 1, true) then return 'collector' end
    if textN:find(L'дальнобой', 1, true)
       or textN:find(L'груз', 1, true)
       or textN:find(L'гауз', 1, true) then return 'trucker' end
    if textN:find(L'такси', 1, true) then return 'taxi' end
    return nil
end

local function zpIsPayout(textN)
    if textN:find(L'клиент оплатил', 1, true) then return true end
    if textN:find(L'зарплата за рейс', 1, true) then return true end
    if textN:find(L'получено за обслуживание', 1, true) then return true end
    return false
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
    _G.__notify_lock = { owner = 'hfj',
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
    sampAddChatMessage('{FFCC00}[HfJ] {FFFFFF}' .. tostring(text), color or -1)
    table.insert(sn.queue, { text = tostring(text), icon = iconFromColor(color) })
end

-- ============================================================
--  UPDATER
-- ============================================================
-- Имя файла ИМЕННО В РЕПОЗИТОРИИ (локально файл может называться иначе)
local SCRIPT_FILENAME = 'Help_for_Job.lua'
local GH_USER, GH_REPO, GH_BRANCH = 'hshajqk710-glitch', 'taxord', 'main'

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
    local t0 = os.clock()
    while not finished and (os.clock() - t0) < (timeout or DOWNLOAD_TIMEOUT) do wait(0) end
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
    local ver = tostring(text or ''):match('%d+%.%d+%.%d+')
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
    return WORK_DIR .. '/' .. SCRIPT_FILENAME
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
    if not silent then notify(L'Проверяю обновление на GitHub...', 0xFFFF00) end

    lua_thread.create(function()
        local ok, body, err = pcall(fetchText, UPDATE_URL_VERSION, 15)
        updateDownloading = false
        if not ok then body, err = nil, tostring(body) end

        if not body then
            updaterStatus = L'ошибка проверки'
            logAct('Check failed: ' .. tostring(err))
            if not silent then notify(L'Не удалось проверить обновление', 0xFF0000) end
            return
        end

        local st = applyVersionText(body)
        if st == 'new' then
            updaterStatus = L'доступно v' .. remoteVersion
            logAct('Update available: v' .. remoteVersion .. ' (local v' .. LOCAL_VERSION .. ')')
            -- не спамим одним и тем же предложением при тихих проверках
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
        notify(L'Уже идёт проверка или загрузка', 0xFFFF00)
        return
    end
    if not canDownload then
        notify(L'Скачивание недоступно на этой сборке', 0xFF0000)
        return
    end
    if not updateAvailable then
        notify(L'Обновлений нет - проверяю заново...', 0xFFFF00)
        doCheck(true, true)
        return
    end

    updateDownloading = true
    updaterStatus = L'скачиваю v' .. remoteVersion
    notify(L'Скачиваю обновление v' .. remoteVersion .. '...', 0xFFFF00)

    lua_thread.create(function()
        local ok, body, err = pcall(fetchText, UPDATE_URL_SCRIPT, DOWNLOAD_TIMEOUT)
        updateDownloading = false
        if not ok then body, err = nil, tostring(body) end

        if not body or body == '' then
            updaterStatus = L'ошибка загрузки'
            logAct('Download failed: ' .. tostring(err))
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

        -- Защита от отката: не ставим версию старше текущей
        local dlVer = body:match("script_version%s*%(%s*['\"]([%d%.]+)['\"]")
        if dlVer and verLt(dlVer, LOCAL_VERSION) then
            updaterStatus = L'на GitHub старее'
            logAct('Download aborted: remote v' .. dlVer .. ' < local v' .. LOCAL_VERSION)
            notify(L'На GitHub версия старее (v' .. dlVer .. ') - отмена', 0xFF0000)
            return
        end
        if dlVer and remoteVersion ~= '' and dlVer ~= remoteVersion then
            logAct('Warning: version.txt = ' .. remoteVersion .. ', file = ' .. dlVer)
        end

        local tmp = WORK_DIR .. '/hfj_update.lua'
        if not writeFile(tmp, body) then
            updaterStatus = L'ошибка записи'
            notify(L'Не удалось записать обновление', 0xFF0000)
            return
        end

        local dest   = scriptPath()
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
        notify(L'Обновление установлено - перезапуск скрипта...', 0x00FF00)
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
        doCheck(true)
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
    local raw = s:match('%$(%d[%d%.,]*)')
    if not raw then return 0 end
    raw = raw:gsub('[%.,]', '')
    return tonumber(raw) or 0
end

local function stripColors(t)
    return (t:gsub('{%x%x%x%x%x%x}', ''):gsub('{%x%x%x%x%x%x%x%x}', ''))
end

local ZP_LABEL = { taxi = L'Такси', trucker = L'Дальнобойщик', collector = L'Инкассатор' }
local ZP_DIALOG_ID = 8888

local function zpTotal() return ZP.taxi + ZP.trucker + ZP.collector end

local function zpReportText()
    local lines = {
        L'Автоловля заказов:',
        string.format(L'  Заказов выполнено: %d', CFG.ordersDone),
        string.format(L'  Заработано: $%s', zpFormatMoney(CFG.moneyEarned)),
        '',
        L'Выплаты по работам:',
        L'  Такси:          $' .. zpFormatMoney(ZP.taxi),
        L'  Дальнобойщик:   $' .. zpFormatMoney(ZP.trucker),
        L'  Инкассатор:     $' .. zpFormatMoney(ZP.collector),
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
    ZP.taxi, ZP.trucker, ZP.collector = 0, 0, 0
    statDispOrders  = 0
    statDispMoney   = 0
    markDirty()
    saveCfg()
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
--  СОБЫТИЯ ЧАТА
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

    if zpIsPayout(cleanN) then
        local amount = zpExtractMoney(stripColors(text))
        local job    = zpDetectJob(cleanN)
        if amount and job then
            if zpMovedDist < ZP_MOVE_THRESHOLD then
                logAct(string.format('Payout ignored (%s %d): moved %.1f < %.0f',
                    job, amount, zpMovedDist, ZP_MOVE_THRESHOLD))
            else
                ZP[job] = ZP[job] + amount
                zpMovedDist = 0.0
                markDirty()
                logAct(string.format('Payout %s +%d (total %d)', job, amount, ZP[job]))
                notify(L'ЗП ' .. ZP_LABEL[job] .. ': +$' .. zpFormatMoney(amount) ..
                    L' | Всего: $' .. zpFormatMoney(ZP[job]), 0x00FF00)
            end
        end
    end

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
--  СОБЫТИЯ ДИАЛОГОВ
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

    if tonumber(id) == ZP_DIALOG_ID then return end
    if tonumber(id) == UPDATE_DIALOG_ID then return end
    if not active then return end

    local titleN = normalize(stripColors(title or ''))
    local bodyN  = normalize(stripColors(text or ''))
    local b1N    = normalize(b1 or '')
    local b2N    = normalize(b2 or '')

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

-- Ответ на диалог "Обновить сейчас / Позже"
function sampev.onDialogResponse(id, button, list, input)
    if tonumber(id) ~= UPDATE_DIALOG_ID then return end
    logAct('Update dialog: button=' .. tostring(button))
    if button == 1 then
        doUpdate()
    else
        notify(L'Обновление отложено. Команда: /update', 0xFFAA00)
    end
    return false
end

-- ============================================================
--  UI: МАСШТАБ, ЦВЕТА, ХЕЛПЕРЫ
-- ============================================================
local UI_SCALE = 1.0
local function SC(v) return math.floor(v * UI_SCALE + 0.5) end

local COL = {
    accent    = imgui.ImVec4(1.00, 0.78, 0.05, 1.00),
    accentSoft= imgui.ImVec4(1.00, 0.78, 0.05, 0.45),
    orange    = imgui.ImVec4(1.00, 0.52, 0.10, 1.00),
    text      = imgui.ImVec4(0.95, 0.96, 0.98, 1.00),
    dim       = imgui.ImVec4(0.62, 0.68, 0.76, 1.00),
    green     = imgui.ImVec4(0.25, 0.85, 0.40, 1.00),
    red       = imgui.ImVec4(0.95, 0.32, 0.32, 1.00),
}
local function C(v) return imgui.ColorConvertFloat4ToU32(v) end

local LastTime   = {}
local LastActive = {}

-- Тумблер: крупный, «пилюля» + подпись, работает и по тапу на подпись
function ToggleButton(label, bool, a_speed)
    local dt = 0.016
    pcall(function()
        local d = imgui.GetIO().DeltaTime
        if d and d > 0 then dt = math.min(0.1, d) end
    end)

    local h     = SC(30)
    local w     = SC(58)
    local r     = h / 2
    local gap   = SC(14)
    local tw    = imgui.CalcTextSize(label).x
    local total = w + gap + tw

    local p  = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()

    local result = false
    if imgui.InvisibleButton('##tg_' .. label, imgui.ImVec2(total, h)) then
        bool[0] = not bool[0]
        LastTime[label] = os.clock()
        LastActive[label] = true
        togglePulse[label] = 1
        result = true
    end
    local hovered = imgui.IsItemHovered()

    local s = a_speed or 0.18
    local x_begin = bool[0] and 1.0 or 0.0
    if LastActive[label] then
        local time = os.clock() - LastTime[label]
        if time <= s then
            local anim = time / s
            if anim < 0 then anim = 0 elseif anim > 1 then anim = 1 end
            x_begin = bool[0] and anim or 1.0 - anim
        else
            LastActive[label] = false
        end
    end

    togglePulse[label] = math.max(0, (togglePulse[label] or 0) - dt * 3.2)
    local pulse = togglePulse[label] or 0

    local on = x_begin
    local bg = imgui.ImVec4(
        0.16 + (1.00 - 0.16) * on,
        0.17 + (0.78 - 0.17) * on,
        0.20 + (0.05 - 0.20) * on,
        hovered and 1.0 or 0.92)
    local knobX = p.x + r + on * (w - r * 2)

    dl:AddRectFilled(imgui.ImVec2(p.x, p.y + SC(2)),
        imgui.ImVec2(p.x + w, p.y + h + SC(2)),
        C(imgui.ImVec4(0, 0, 0, 0.35)), r)

    if pulse > 0 then
        dl:AddRectFilled(imgui.ImVec2(p.x - SC(2), p.y - SC(2)),
            imgui.ImVec2(p.x + w + SC(2), p.y + h + SC(2)),
            C(imgui.ImVec4(1.0, 0.78, 0.05, pulse * 0.30)), r + SC(2))
    end

    dl:AddRectFilled(imgui.ImVec2(p.x, p.y), imgui.ImVec2(p.x + w, p.y + h), C(bg), r)
    dl:AddCircleFilled(imgui.ImVec2(knobX, p.y + r), r - SC(3),
        C(imgui.ImVec4(0.97, 0.97, 0.98, 1)), 28)
    dl:AddCircle(imgui.ImVec2(knobX, p.y + r), r - SC(3),
        C(imgui.ImVec4(0, 0, 0, 0.16)), 28, 1)

    dl:AddText(imgui.ImVec2(p.x + w + gap, p.y + (h - imgui.CalcTextSize(label).y) / 2),
        C(imgui.ImVec4(0.93, 0.95, 0.98, 1)), label)
    return result
end

-- Карточка с золотой полоской и заголовком
function GlassChild(name, size, fun)
    local pad = SC(16)
    local r   = SC(14)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(1, 1, 1, 0.045))
    local visible = imgui.BeginChild(name, size, false)
    if visible then
        local DL = imgui.GetWindowDrawList()
        local wp, ws = imgui.GetWindowPos(), imgui.GetWindowSize()
        local origin = imgui.GetCursorScreenPos()

        DL:AddRect(
            imgui.ImVec2(wp.x + 1, wp.y + 1),
            imgui.ImVec2(wp.x + ws.x - 1, wp.y + ws.y - 1),
            C(imgui.ImVec4(1, 1, 1, 0.08)), r, 0, 1)

        DL:AddRectFilled(
            imgui.ImVec2(origin.x + SC(7), origin.y + SC(7)),
            imgui.ImVec2(origin.x + SC(11), origin.y + SC(27)),
            C(COL.accent), SC(2))

        imgui.SetCursorPos(imgui.ImVec2(pad + SC(8), pad - SC(2)))
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        imgui.TextColored(imgui.ImVec4(1.00, 0.88, 0.42, 1.00), name)
        if FONT_SUB then imgui.PopFont() end

        local lineY = imgui.GetCursorScreenPos().y + SC(6)
        DL:AddLine(imgui.ImVec2(origin.x + pad, lineY),
            imgui.ImVec2(origin.x + size.x - pad, lineY),
            C(imgui.ImVec4(1, 1, 1, 0.10)), 1)

        imgui.SetCursorPos(imgui.ImVec2(pad, pad + SC(38)))
        fun()
    end
    imgui.EndChild()
    imgui.PopStyleColor()
    imgui.PopStyleVar()
end

-- Крупная кнопка на всю ширину карточки
local btnHover = {}
local function AccentButton(label, height, primary)
    local w = math.max(SC(80), imgui.GetContentRegionAvail().x - SC(14))
    local h = height or SC(50)
    local p = imgui.GetCursorScreenPos()
    local DL = imgui.GetWindowDrawList()
    local r = SC(12)

    imgui.InvisibleButton('##hfj_btn_' .. label, imgui.ImVec2(w, h))
    local clicked = imgui.IsItemClicked()
    local hovered = imgui.IsItemHovered()
    local active  = imgui.IsItemActive()

    local hv = btnHover[label] or 0
    hv = hv + ((hovered and 1 or 0) - hv) * 0.25
    btnHover[label] = hv

    local bg, border, tc
    if primary then
        bg = imgui.ImVec4(1.00, 0.78 - hv * 0.10, 0.05 + hv * 0.12, active and 1.0 or 0.95)
        border = imgui.ImVec4(1.0, 0.90, 0.45, 0.45)
        tc = imgui.ImVec4(0.06, 0.06, 0.06, 1.0)
    else
        bg = imgui.ImVec4(0.13 + hv * 0.05, 0.15 + hv * 0.06, 0.19 + hv * 0.07, 0.95)
        border = imgui.ImVec4(1, 1, 1, 0.10 + hv * 0.10)
        tc = imgui.ImVec4(0.92, 0.94, 0.97, 1.0)
    end

    DL:AddRectFilled(imgui.ImVec2(p.x, p.y + SC(2)), imgui.ImVec2(p.x + w, p.y + h + SC(2)),
        C(imgui.ImVec4(0, 0, 0, 0.30)), r)
    DL:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), C(bg), r)
    DL:AddRect(p, imgui.ImVec2(p.x + w, p.y + h), C(border), r, 0, 1.5)

    local ts = imgui.CalcTextSize(label)
    DL:AddText(imgui.ImVec2(p.x + (w - ts.x) / 2, p.y + (h - ts.y) / 2), C(tc), label)
    return clicked
end

-- Мелкая подпись
local function Label(text)
    if FONT_SUB then imgui.PushFont(FONT_SUB) end
    imgui.TextColored(COL.dim, text)
    if FONT_SUB then imgui.PopFont() end
end

-- Крупное значение
local function BigValue(text, col)
    if FONT_BIG then imgui.PushFont(FONT_BIG) end
    imgui.TextColored(col or COL.accent, text)
    if FONT_BIG then imgui.PopFont() end
end

-- Разделитель
local function Divider(alpha)
    local DL = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = math.max(10, imgui.GetContentRegionAvail().x - SC(14))
    DL:AddLine(p, imgui.ImVec2(p.x + w, p.y), C(imgui.ImVec4(1, 1, 1, alpha or 0.10)), 1)
    imgui.SetCursorPosY(imgui.GetCursorPosY() + SC(10))
end

-- Плашка-статус
local function Pill(text, col)
    local p = imgui.GetCursorScreenPos()
    local DL = imgui.GetWindowDrawList()
    local ts = imgui.CalcTextSize(text)
    local h = ts.y + SC(10)
    local w = ts.x + SC(26)

    DL:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h),
        C(imgui.ImVec4(col.x, col.y, col.z, 0.15)), h / 2)
    DL:AddRect(p, imgui.ImVec2(p.x + w, p.y + h),
        C(imgui.ImVec4(col.x, col.y, col.z, 0.45)), h / 2, 0, 1)
    DL:AddText(imgui.ImVec2(p.x + SC(13), p.y + SC(5)), C(col), text)
    imgui.SetCursorPosY(imgui.GetCursorPosY() + h + SC(4))
end

-- Полоса прогресса
local function ProgressBar(frac, height, col)
    local p = imgui.GetCursorScreenPos()
    local w = math.max(10, imgui.GetContentRegionAvail().x - SC(14))
    local h = height or SC(12)
    local DL = imgui.GetWindowDrawList()
    frac = math.max(0, math.min(1, frac or 0))

    DL:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h),
        C(imgui.ImVec4(1, 1, 1, 0.10)), h / 2)
    if frac > 0 then
        DL:AddRectFilled(p, imgui.ImVec2(p.x + w * frac, p.y + h), C(col or COL.accent), h / 2)
    end
    imgui.SetCursorPosY(imgui.GetCursorPosY() + h + SC(6))
end

-- ============================================================
--  ЛОГОТИП
-- ============================================================
local function DrawLogo(x, y)
    local DL = imgui.GetWindowDrawList()
    local p  = imgui.ImVec2(x, y)

    local cardW, cardH = SC(238), SC(82)
    local r            = SC(15)
    local badge        = SC(56)

    -- тень карточки
    DL:AddRectFilled(
        imgui.ImVec2(p.x + SC(3), p.y + SC(4)),
        imgui.ImVec2(p.x + cardW + SC(3), p.y + cardH + SC(4)),
        C(imgui.ImVec4(0, 0, 0, 0.45)), r)

    -- сама карточка
    DL:AddRectFilled(p, imgui.ImVec2(p.x + cardW, p.y + cardH),
        C(imgui.ImVec4(0.09, 0.10, 0.13, 0.97)), r)
    DL:AddRect(p, imgui.ImVec2(p.x + cardW, p.y + cardH),
        C(imgui.ImVec4(1.0, 0.78, 0.05, 0.22)), r, 0, 1.5)

    -- блик по карточке
    local t = (os.clock() % 5.0) / 5.0
    if t < 0.30 then
        local sx = p.x - SC(40) + (cardW + SC(80)) * (t / 0.30)
        DL:PushClipRect(p, imgui.ImVec2(p.x + cardW, p.y + cardH), true)
        DL:AddRectFilled(
            imgui.ImVec2(sx - SC(20), p.y - SC(4)),
            imgui.ImVec2(sx + SC(20), p.y + cardH + SC(4)),
            C(imgui.ImVec4(1, 1, 1, 0.10)), SC(10))
        DL:PopClipRect()
    end

    -- золотой бейдж HfJ
    local bx, by = p.x + SC(13), p.y + (cardH - badge) / 2
    DL:AddRectFilled(imgui.ImVec2(bx, by + SC(2)),
        imgui.ImVec2(bx + badge, by + badge + SC(2)),
        C(imgui.ImVec4(0, 0, 0, 0.35)), SC(14))
    DL:AddRectFilled(imgui.ImVec2(bx, by),
        imgui.ImVec2(bx + badge, by + badge),
        C(imgui.ImVec4(1.00, 0.78, 0.05, 1.0)), SC(14))
    DL:AddRectFilled(imgui.ImVec2(bx, by),
        imgui.ImVec2(bx + badge, by + badge * 0.45),
        C(imgui.ImVec4(1.0, 0.90, 0.45, 0.35)), SC(14), 1 + 2)

    if FONT_LOGO then imgui.PushFont(FONT_LOGO) end
    local mark = 'HfJ'
    local ms   = imgui.CalcTextSize(mark)
    DL:AddText(imgui.ImVec2(bx + (badge - ms.x) / 2, by + (badge - ms.y) / 2),
        C(imgui.ImVec4(0.07, 0.07, 0.08, 1.0)), mark)
    if FONT_LOGO then imgui.PopFont() end

    -- название в две строки
    local tx = bx + badge + SC(13)
    if FONT_BIG then imgui.PushFont(FONT_BIG) end
    local t1 = 'HELP FOR'
    local s1 = imgui.CalcTextSize(t1)
    DL:AddText(imgui.ImVec2(tx, p.y + SC(12)),
        C(imgui.ImVec4(0.96, 0.97, 0.99, 1.0)), t1)
    DL:AddText(imgui.ImVec2(tx, p.y + SC(12) + s1.y),
        C(imgui.ImVec4(1.00, 0.78, 0.05, 1.0)), 'JOB')
    if FONT_BIG then imgui.PopFont() end
end

-- ============================================================
--  ОКНО
-- ============================================================
local tabsList = { selected = '1:1', tabs = {} }

local function GlassWindow(title, var, closeButton, leftSize, tabs, flags)
    local sw, sh = getScreenResolution()
    local res    = imgui.ImVec2(sw, sh)

    -- Инициализация позиции окна
    if not winPosInit then
        winPos = imgui.ImVec2(res.x / 2, res.y / 2)
        winPosInit = true
    end

    local edge = math.max(SC(12), math.min(SC(40), sw * 0.03))
    local defW = math.min(SC(1180), sw - edge * 2)
    local defH = math.min(SC(780),  sh - edge * 2)
    local minW = math.min(SC(720),  sw - edge * 2)
    local minH = math.min(SC(520),  sh - edge * 2)

    -- Вместо SetWindowPos используем SetNextWindowPos, он безопасен
    imgui.SetNextWindowPos(winPos, imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(defW, defH), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowSizeConstraints(
        imgui.ImVec2(minW, minH),
        imgui.ImVec2(math.max(minW, sw - edge), math.max(minH, sh - edge)))

    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, windowAlpha)

    if imgui.Begin('##' .. title, var,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoBackground
        + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar + (flags or 0)) then

        local pos, wsize = imgui.GetWindowPos(), imgui.GetWindowSize()
        local FGDL = imgui.GetForegroundDrawList()
        local DL   = imgui.GetWindowDrawList()
        local BGDL = imgui.GetBackgroundDrawList()
        local R    = SC(18)
        local a    = windowAlpha

        -- Мягкая тень под окном
        BGDL:AddRectFilled(
            imgui.ImVec2(pos.x - SC(6), pos.y - SC(6)),
            imgui.ImVec2(pos.x + wsize.x + SC(6), pos.y + wsize.y + SC(10)),
            C(imgui.ImVec4(0, 0, 0, 0.45 * a)), R + SC(6))

        -- Фон окна
        DL:AddRectFilled(pos, imgui.ImVec2(pos.x + wsize.x, pos.y + wsize.y),
            C(imgui.ImVec4(0.055, 0.062, 0.078, 0.96 * a)), R)

        -- Сайдбар
        DL:AddRectFilled(pos, imgui.ImVec2(pos.x + leftSize, pos.y + wsize.y),
            C(imgui.ImVec4(0.032, 0.037, 0.048, 0.96 * a)), R, 1 + 4)

        -- Разделитель сайдбар / контент
        DL:AddLine(imgui.ImVec2(pos.x + leftSize, pos.y + SC(12)),
            imgui.ImVec2(pos.x + leftSize, pos.y + wsize.y - SC(12)),
            C(imgui.ImVec4(1, 1, 1, 0.07 * a)), SC(1))

        -- Внешняя рамка
        DL:AddRect(pos, imgui.ImVec2(pos.x + wsize.x, pos.y + wsize.y),
            C(imgui.ImVec4(1.0, 0.78, 0.05, 0.20 * a)), R, 0, SC(1))

        -- Перетаскивание (шапка)
        imgui.SetCursorPos(imgui.ImVec2(SC(52), 0))
        imgui.InvisibleButton('##window_drag',
            imgui.ImVec2(math.max(SC(10), wsize.x - SC(52) - SC(150)), SC(52)))
        if imgui.IsItemActive() and imgui.IsMouseDragging(0) then
            local d = imgui.GetIO().MouseDelta
            winPos.x = winPos.x + d.x
            winPos.y = winPos.y + d.y
        end

        -- Индикатор ресайза
        do
            local c = C(imgui.ImVec4(1.0, 0.78, 0.05, 0.55 * a))
            for i = 1, 3 do
                DL:AddLine(
                    imgui.ImVec2(pos.x + wsize.x - SC(4),        pos.y + wsize.y - SC(4) - i * SC(5)),
                    imgui.ImVec2(pos.x + wsize.x - SC(4) - i * SC(5), pos.y + wsize.y - SC(4)),
                    c, SC(1.5))
            end
        end

        -- Статус-пилюля в шапке
        do
            local pulse = 0.55 + 0.45 * math.sin(os.clock() * 3.0)
            local stxt  = hasActiveOrder and u8(L'В заказе') or u8(L'Свободен')
            local scol  = hasActiveOrder and COL.green or COL.dim

            if FONT_SUB then imgui.PushFont(FONT_SUB) end
            local sts = imgui.CalcTextSize(stxt)
            local ph  = sts.y + SC(12)
            local pw  = sts.x + SC(42)
            local px  = pos.x + wsize.x - pw - SC(18)
            local py  = pos.y + SC(16)

            DL:AddRectFilled(imgui.ImVec2(px, py), imgui.ImVec2(px + pw, py + ph),
                C(imgui.ImVec4(scol.x, scol.y, scol.z, 0.13 * a)), ph / 2)
            DL:AddRect(imgui.ImVec2(px, py), imgui.ImVec2(px + pw, py + ph),
                C(imgui.ImVec4(scol.x, scol.y, scol.z, 0.40 * a)), ph / 2, 0, SC(1))
            DL:AddCircleFilled(imgui.ImVec2(px + SC(16), py + ph / 2), SC(4),
                C(imgui.ImVec4(scol.x, scol.y, scol.z, pulse)))
            DL:AddText(imgui.ImVec2(px + SC(28), py + (ph - sts.y) / 2),
                C(imgui.ImVec4(0.84, 0.88, 0.93, 1.0)), stxt)

            -- Версия слева от статуса: видна всегда
            local vtxt = 'v' .. LOCAL_VERSION
            local vts  = imgui.CalcTextSize(vtxt)
            local vw   = vts.x + SC(26)
            local vh   = vts.y + SC(12)
            local vx   = px - vw - SC(16)
            local vy   = py

            DL:AddRectFilled(imgui.ImVec2(vx, vy), imgui.ImVec2(vx + vw, vy + vh),
                C(imgui.ImVec4(1.0, 0.78, 0.05, 0.10 * a)), vh / 2)
            DL:AddRect(imgui.ImVec2(vx, vy), imgui.ImVec2(vx + vw, vy + vh),
                C(imgui.ImVec4(1.0, 0.78, 0.05, 0.35 * a)), vh / 2, 0, SC(1))
            DL:AddText(imgui.ImVec2(vx + SC(13), vy + (vh - vts.y) / 2),
                C(imgui.ImVec4(1.00, 0.88, 0.42, 1.0)), vtxt)
            if FONT_SUB then imgui.PopFont() end
        end

        -- Кнопка закрытия
        do
            local cs = SC(30)
            imgui.SetCursorPos(imgui.ImVec2(SC(14), SC(14)))
            local cp = imgui.GetCursorScreenPos()
            imgui.InvisibleButton('##CLOSEBUTTON', imgui.ImVec2(cs, cs))
            if imgui.IsItemClicked() then var[0] = false end
            local hover = imgui.IsItemHovered()

            local cx, cy = cp.x + cs / 2, cp.y + cs / 2
            local bg = hover and imgui.ImVec4(0.95, 0.32, 0.32, 1.0)
                             or  imgui.ImVec4(0.16, 0.11, 0.12, 1.0)
            FGDL:AddCircleFilled(imgui.ImVec2(cx, cy), cs / 2, C(bg))
            FGDL:AddCircle(imgui.ImVec2(cx, cy), cs / 2,
                C(hover and imgui.ImVec4(1, 0.42, 0.42, 0.55)
                           or imgui.ImVec4(1, 0.32, 0.31, 0.30)), 24, SC(1))

            local d = SC(6)
            local xc = hover and imgui.ImVec4(1, 1, 1, 1) or imgui.ImVec4(0.92, 0.55, 0.55, 1)
            FGDL:AddLine(imgui.ImVec2(cx - d, cy - d), imgui.ImVec2(cx + d, cy + d), C(xc), SC(2))
            FGDL:AddLine(imgui.ImVec2(cx - d, cy + d), imgui.ImVec2(cx + d, cy - d), C(xc), SC(2))
        end

        -- Логотип HfJ
        DrawLogo(pos.x + SC(15), pos.y + SC(56))

        -- Подпись под логотипом
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        DL:AddText(imgui.ImVec2(pos.x + SC(18), pos.y + SC(150)),
            C(imgui.ImVec4(0.55, 0.61, 0.70, 1.0)), u8(L'помощник по работе'))
        if FONT_SUB then imgui.PopFont() end

        -- Табы сайдбара
        local th = SC(54)
        local tw = leftSize - SC(30)
        imgui.SetCursorPos(imgui.ImVec2(SC(15), SC(186)))
        for categoryIndex, category in pairs(tabs.tabs) do
            for tabIndex, tab in pairs(category.list) do
                local key   = ('%s:%s'):format(categoryIndex, tabIndex)
                local isSel = tabs.selected == key
                if tabHover[key] == nil then tabHover[key] = isSel and 1 or 0 end

                local tpos = imgui.GetCursorScreenPos()
                imgui.SetCursorPosX(SC(15))
                imgui.InvisibleButton('##TAB_' .. key, imgui.ImVec2(tw, th))
                local hovered = imgui.IsItemHovered()
                local target  = (hovered or isSel) and 1 or 0
                tabHover[key] = tabHover[key] + (target - tabHover[key]) * 0.22

                local hv = tabHover[key]
                if isSel then
                    DL:AddRectFilled(
                        imgui.ImVec2(tpos.x - SC(2), tpos.y - SC(2)),
                        imgui.ImVec2(tpos.x + tw + SC(2), tpos.y + th + SC(2)),
                        C(imgui.ImVec4(1.0, 0.78, 0.05, 0.15 * a)), SC(13))
                end

                local bgCol = isSel
                    and imgui.ImVec4(1.00, 0.78, 0.05, 0.97 * a)
                    or  imgui.ImVec4(0.10 + hv * 0.05, 0.11 + hv * 0.05, 0.13 + hv * 0.06, 0.88 * a)
                DL:AddRectFilled(tpos, imgui.ImVec2(tpos.x + tw, tpos.y + th),
                    C(bgCol), SC(12))
                if not isSel then
                    DL:AddRect(tpos, imgui.ImVec2(tpos.x + tw, tpos.y + th),
                        C(imgui.ImVec4(1, 1, 1, (0.05 + hv * 0.07) * a)), SC(12), 0, SC(1))
                end

                local ts = imgui.CalcTextSize(tab.name)
                local textCol = isSel
                    and imgui.ImVec4(0.07, 0.07, 0.08, 1.0)
                    or  imgui.ImVec4(0.88, 0.91, 0.95, 1.0)
                DL:AddText(imgui.ImVec2(tpos.x + tw / 2 - ts.x / 2, tpos.y + th / 2 - ts.y / 2),
                    C(textCol), tab.name)

                if imgui.IsItemClicked() then tabs.selected = key end
                imgui.SetCursorPosY(imgui.GetCursorPosY() + SC(8))
            end
        end

        -- Версия внизу сайдбара
        if FONT_SUB then
            imgui.PushFont(FONT_SUB)
            local vtxt = 'v' .. LOCAL_VERSION
            local vts  = imgui.CalcTextSize(vtxt)
            DL:AddText(imgui.ImVec2(pos.x + (leftSize - vts.x) / 2, pos.y + wsize.y - SC(30)),
                C(imgui.ImVec4(0.40, 0.45, 0.53, a)), vtxt)
            imgui.PopFont()
        end

        -- Контент
        imgui.SetCursorPos(imgui.ImVec2(leftSize + SC(18), SC(16)))
        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, windowAlpha * tabFade)

        local contentW = math.max(SC(100), wsize.x - leftSize - SC(36))
        local contentH = math.max(SC(100), wsize.y - SC(32))

        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(SC(18), SC(14)))
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(1, 1, 1, 0.02))
        if imgui.BeginChild('##hfj_content', imgui.ImVec2(contentW, contentH), false) then
            if tabSlide > 0 then imgui.SetCursorPosX(imgui.GetCursorPosX() + tabSlide) end

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
        imgui.PopStyleColor()
        imgui.PopStyleVar()
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

    -- Масштаб интерфейса под разрешение экрана телефона (база - 1280 px)
    local sw = 1280
    pcall(function()
        local w = getScreenResolution()
        if w and w > 0 then sw = w end
    end)
    UI_SCALE = math.max(1.0, math.min(2.2, sw / 1280))

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

    local def = loadFont(regular_paths, SC(20))
    if not def then
        local ok, font = pcall(function() return imio.Fonts:AddFontDefault() end)
        if ok and font then def = font end
    end
    if def then imio.FontDefault = def end

    FONT_LOGO = loadFont(bold_paths, SC(30)) or def
    FONT_SUB  = loadFont(regular_paths, SC(16)) or def
    FONT_BIG  = loadFont(bold_paths, SC(28)) or FONT_LOGO

    local style = imgui.GetStyle()
    style.WindowPadding     = imgui.ImVec2(0, 0)
    style.WindowRounding    = SC(18)
    style.ChildRounding     = SC(14)
    style.FrameRounding     = SC(10)
    style.PopupRounding     = SC(10)
    style.ScrollbarRounding = SC(10)
    style.GrabRounding      = SC(8)
    style.ItemSpacing       = imgui.ImVec2(SC(10), SC(10))
    style.ItemInnerSpacing  = imgui.ImVec2(SC(8), SC(8))
    style.FramePadding      = imgui.ImVec2(SC(10), SC(8))
    style.ScrollbarSize     = SC(12)
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

    -- Сдвиг контента при переключении таба (анимация)
    local slide = imgui.GetCursorPosX()
    imgui.SetCursorPos(imgui.ImVec2(0, SC(6)))
    local avail  = imgui.GetContentRegionAvail()
    local panelH = math.max(SC(380), avail.y)
    local w1     = math.min(SC(370), avail.x * 0.44)
    local w2     = math.max(SC(180), avail.x - w1 - SC(16))

    -- Текущее состояние ловли
    local stxt, scol
    if pendingAccept then
        stxt, scol = L'Ожидаем метку', COL.accent
    elseif tapSequenceActive then
        stxt, scol = L'Перебор #' .. tapSeqIndex, COL.orange
    elseif hasActiveOrder then
        stxt, scol = L'В заказе', COL.green
    elseif awaitingDialog then
        stxt, scol = L'Ждём диалог', COL.accent
    else
        stxt, scol = L'Ожидание', COL.dim
    end

    imgui.SetCursorPos(imgui.ImVec2(slide, SC(6)))
    GlassChild(u8(L'Автоловля'), imgui.ImVec2(w1, panelH), function()
        tgCatch[0] = CFG.catchEnabled
        if ToggleButton(u8(L'Ловить заказы'), tgCatch, 0.18) then
            CFG.catchEnabled = tgCatch[0]; buf.catchEnabled[0] = CFG.catchEnabled; markDirty()
        end
        imgui.Spacing()
        tgAccept[0] = CFG.autoAccept
        if ToggleButton(u8(L'Авто-принять заказ'), tgAccept, 0.18) then
            CFG.autoAccept = tgAccept[0]; buf.autoAccept[0] = CFG.autoAccept; markDirty()
        end

        imgui.Spacing(); Divider(); imgui.Spacing()

        Label(u8(L'Состояние'))
        Pill(u8(stxt), scol)

        imgui.Spacing()
        Label(u8(L'Ловля через диалоги и чат.'))
        Label(u8(L'Платёжные окна не трогаются.'))
    end)

    imgui.SetCursorPos(imgui.ImVec2(slide + w1 + SC(16), SC(6)))
    GlassChild(u8(L'Статистика'), imgui.ImVec2(w2, panelH), function()
        Label(u8(L'Заказов выполнено'))
        BigValue(tostring(math.floor(statDispOrders + 0.5)))

        imgui.Spacing()
        Label(u8(L'Заработано'))
        BigValue('$' .. zpFormatMoney(statDispMoney + 0.5))

        imgui.Spacing(); Divider(); imgui.Spacing()

        Label(u8(L'Статус'))
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        imgui.TextColored(scol, u8(stxt))
        if FONT_SUB then imgui.PopFont() end

        imgui.Spacing(); Divider(); imgui.Spacing()

        if updateDownloading then
            Label(u8(L'Идёт проверка/скачивание...'))
            imgui.Spacing()
        end

        local updLabel = updateAvailable
            and (u8(L'Обновить до ') .. u8(remoteVersion))
            or  u8(L'Проверить обновления')
        if AccentButton(updLabel, SC(50), updateAvailable) then
            if updateAvailable then doUpdate() else doCheck() end
        end

        imgui.Spacing()
        if AccentButton(u8(L'Сбросить статистику'), SC(46)) then
            resetAllStats(); notify(L'Статистика сброшена')
        end
        imgui.Spacing()
        if AccentButton(u8(L'Сброс заказа'), SC(46)) then
            finishOrder('manual')
        end

        imgui.Spacing()
        Label(u8(L'Версия: ') .. LOCAL_VERSION)
        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        imgui.TextColored(updateAvailable and COL.accent or COL.dim, u8(updaterStatus))
        if FONT_SUB then imgui.PopFont() end
    end)
end

-- ============================================================
--  ТАБ: ЗП
-- ============================================================
local ZP_JOB_LIST = {
    { key = 'taxi',      label = L'Такси'        },
    { key = 'trucker',   label = L'Дальнобойщик' },
    { key = 'collector', label = L'Инкассатор'   },
}

local function ZpTabFrame()
    local slide = imgui.GetCursorPosX()
    imgui.SetCursorPos(imgui.ImVec2(0, SC(6)))
    local avail  = imgui.GetContentRegionAvail()
    local panelH = math.max(SC(380), avail.y)
    local w1     = math.min(SC(400), avail.x * 0.5)
    local w2     = math.max(SC(180), avail.x - w1 - SC(16))

    imgui.SetCursorPos(imgui.ImVec2(slide, SC(6)))
    GlassChild(u8(L'Выплаты по работам'), imgui.ImVec2(w1, panelH), function()
        for i, job in ipairs(ZP_JOB_LIST) do
            Label(u8(job.label))
            BigValue('$' .. zpFormatMoney(ZP[job.key]))
            if i < #ZP_JOB_LIST then imgui.Spacing(); Divider(); imgui.Spacing() end
        end
    end)

    imgui.SetCursorPos(imgui.ImVec2(slide + w1 + SC(16), SC(6)))
    GlassChild(u8(L'Итого и дистанция'), imgui.ImVec2(w2, panelH), function()
        Label(u8(L'Всего по работам'))
        BigValue('$' .. zpFormatMoney(zpTotal()))

        imgui.Spacing(); Divider(); imgui.Spacing()

        Label(u8(L'Проехано от выплаты'))
        local frac = ZP_MOVE_THRESHOLD > 0 and (zpMovedDist / ZP_MOVE_THRESHOLD) or 0
        ProgressBar(frac, SC(12), COL.accent)

        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        imgui.TextColored(COL.text, string.format(u8(L'%d / %d м'),
            math.floor(zpMovedDist), math.floor(ZP_MOVE_THRESHOLD)))
        imgui.TextWrapped(u8(L'Выплата засчитывается только после реального проезда.'))
        if FONT_SUB then imgui.PopFont() end

        imgui.Spacing(); Divider(); imgui.Spacing()

        if AccentButton(u8(L'Сбросить ЗП'), SC(46)) then
            ZP.taxi, ZP.trucker, ZP.collector = 0, 0, 0
            markDirty(); saveCfg(); notify(L'Счётчик ЗП сброшен')
        end
        imgui.Spacing()
        if AccentButton(u8(L'Сбросить всё'), SC(46)) then
            resetAllStats(); notify(L'Вся статистика сброшена')
        end
    end)
end

-- ============================================================
--  ТАБ: ИНФО
-- ============================================================
local function InfoTabFrame()
    local slide = imgui.GetCursorPosX()
    imgui.SetCursorPos(imgui.ImVec2(0, SC(6)))
    local avail  = imgui.GetContentRegionAvail()
    local panelH = math.max(SC(380), avail.y)
    local w1     = math.min(SC(430), avail.x * 0.5)
    local w2     = math.max(SC(220), avail.x - w1 - SC(16))

    imgui.SetCursorPos(imgui.ImVec2(slide, SC(6)))
    GlassChild(u8(L'О программе'), imgui.ImVec2(w1, panelH), function()
        BigValue('Help for Job')
        Label('HfJ  ·  v' .. VERSION)

        imgui.Spacing(); Divider(); imgui.Spacing()

        if FONT_SUB then imgui.PushFont(FONT_SUB) end
        imgui.TextWrapped(u8(L'Автоловля заказов + счётчик зарплаты по работам.'))
        imgui.Spacing()
        imgui.TextWrapped(u8(L'Ловит заказы двумя способами: через диалоги сервера и через чат. Диалоги с оплатой (:CASH:) не нажимает автоматически.'))
        imgui.Spacing()
        imgui.TextWrapped(u8(L'Счётчик ЗП учитывает выплаты по работам (такси, дальнобойщик, инкассатор) только после реального проезда.'))
        imgui.Spacing()
        imgui.TextWrapped(u8(L'Обновление: проверка версии с GitHub и установка одной кнопкой.'))
        if FONT_SUB then imgui.PopFont() end
    end)

    imgui.SetCursorPos(imgui.ImVec2(slide + w1 + SC(16), SC(6)))
    GlassChild(u8(L'Команды'), imgui.ImVec2(w2, panelH), function()
        local cmds = {
            { '/hfj',       L'меню' },
            { '/zarabotok', L'статистика (окно)' },
            { '/resetstat', L'сброс статистики' },
            { '/checkupd',  L'проверить обновление' },
            { '/update',    L'скачать обновление' },
            { '/updinfo',   L'диагностика обновления' },
        }
        for i, cm in ipairs(cmds) do
            if FONT_SUB then imgui.PushFont(FONT_SUB) end
            imgui.TextColored(COL.accent, u8(cm[1]))
            imgui.TextColored(COL.dim, u8(cm[2]))
            if FONT_SUB then imgui.PopFont() end
            if i < #cmds then imgui.Spacing() end
        end

        imgui.Spacing(); Divider(); imgui.Spacing()
        Label(u8(L'Старый алиас: /taxord'))
    end)
end

tabsList.tabs = {
    {
        name = 'HfJ',
        list = {
            { name = u8(L'Заказы'), icon = '', frame = OrdersTabFrame },
            { name = u8(L'ЗП'),     icon = '', frame = ZpTabFrame     },
            { name = u8(L'Инфо'),   icon = '', frame = InfoTabFrame   },
        }
    }
}

-- ============================================================
--  РЕНДЕР ОКНА
-- ============================================================
imgui.OnFrame(
    function() return windowRendering and isSampAvailable() and not isPauseMenuActive() end,
    function(this)
        this.ShowCursor = window[0]
        local target = window[0] and 1.0 or 0.0
        windowAlpha = windowAlpha + (target - windowAlpha) * 0.24

        if windowAlpha < 0.015 and not window[0] then
            windowRendering = false
            windowAlpha = 0
            return
        end

        if tabsList.selected ~= lastSelectedTab then
            tabFade = 0; tabSlide = SC(60); lastSelectedTab = tabsList.selected
        end
        if tabFade < 1 then tabFade = math.min(1, tabFade + 0.075) end
        if tabSlide > 0 then
            tabSlide = tabSlide - SC(5)
            if tabSlide < 0 then tabSlide = 0 end
        end

        GlassWindow('HfJMenu', window, true, SC(268), tabsList, imgui.WindowFlags.NoCollapse)
    end
)

-- ============================================================
--  ТОСТЫ (Уведомления)
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
        elseif sn.state == 'showing' and (os.clock() - sn.timer) >= NOTIFY_DURATION then
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
        local pad_x = SC(66)
        local pad_y = SC(20)
        local iconSize = SC(44)
        local w_px = math.min(sw - SC(40), ts.x + pad_x * 2 + iconSize)
        local h_px = math.max(SC(74), ts.y + pad_y * 2)

        local w_pos = imgui.ImVec2(sw / 2, sh - sn.anim * (h_px + SC(20)) - SC(10))

        imgui.SetNextWindowPos(w_pos, imgui.Cond.Always, imgui.ImVec2(0.5, 0.0))
        imgui.SetNextWindowSize(imgui.ImVec2(w_px, h_px), imgui.Cond.Always)

        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, sn.anim)
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0))

        imgui.Begin('##HfJToast', nil, imgui.WindowFlags.NoMove + imgui.WindowFlags.NoDecoration + imgui.WindowFlags.NoInputs)

        local p  = imgui.GetCursorScreenPos()
        local DL = imgui.GetWindowDrawList()
        local r  = h_px / 2
        local A  = imgui.ImVec2(p.x, p.y)
        local B  = imgui.ImVec2(p.x + w_px, p.y + h_px)

        do
            local g = sn.glow * sn.anim
            DL:AddRectFilled(imgui.ImVec2(A.x - SC(4), A.y - SC(4)), imgui.ImVec2(B.x + SC(4), B.y + SC(4)),
                C(imgui.ImVec4(1.0, 0.78, 0.05, 0.25 * g)), SC(20))
        end

        local bg = C(imgui.ImVec4(0.09, 0.08, 0.05, 0.95))
        DL:PathClear()
        DL:PathArcTo(imgui.ImVec2(A.x + r, A.y + r), r, math.rad(90),  math.rad(270), 50)
        DL:PathArcTo(imgui.ImVec2(B.x - r, B.y - r), r, math.rad(-90), math.rad(90),  50)
        DL:PathFillConvex(bg)

        local ac = C(imgui.ImVec4(1.0, 0.78, 0.05, 1.0))
        DL:AddRectFilled(imgui.ImVec2(A.x + SC(12), A.y + SC(14)), imgui.ImVec2(A.x + SC(18), B.y - SC(14)), ac, SC(2))

        do
            local icx = A.x + SC(44)
            local icy = A.y + h_px / 2
            local ir  = SC(17)

            local iconColor = imgui.ImVec4(0.15, 0.15, 0.15, 1)
            local iconBg    = imgui.ImVec4(1.0, 0.78, 0.05, 1)
            local iconChar  = 'i'

            if sn.icon == 'success' then
                iconBg   = imgui.ImVec4(0.20, 0.85, 0.35, 1); iconChar = '+'
            elseif sn.icon == 'warn' then
                iconBg   = imgui.ImVec4(1.0, 0.78, 0.05, 1); iconChar = '!'
            elseif sn.icon == 'error' then
                iconBg   = imgui.ImVec4(0.95, 0.30, 0.30, 1); iconChar = 'x'
            end

            local g = sn.glow
            DL:AddCircleFilled(imgui.ImVec2(icx, icy), ir + SC(6) + g * SC(3),
                C(imgui.ImVec4(iconBg.x, iconBg.y, iconBg.z, 0.25 * g)))
            DL:AddCircleFilled(imgui.ImVec2(icx, icy), ir, C(iconBg))

            if FONT_BIG then imgui.PushFont(FONT_BIG) end
            local its = imgui.CalcTextSize(iconChar)
            DL:AddText(imgui.ImVec2(icx - its.x / 2, icy - its.y / 2 - SC(2)), C(iconColor), iconChar)
            if FONT_BIG then imgui.PopFont() end
        end

        imgui.SetCursorPos(imgui.ImVec2(pad_x + SC(18), (h_px - ts.y) / 2))
        imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), text)

        do
            local progressW = (B.x - A.x - SC(20)) * (1 - math.min(1, (os.clock() - sn.timer) / NOTIFY_DURATION))
            if progressW > 0 then
                DL:AddRectFilled(imgui.ImVec2(A.x + SC(12), B.y - SC(4)), imgui.ImVec2(A.x + SC(12) + progressW, B.y - SC(2)),
                    C(imgui.ImVec4(1.0, 0.78, 0.05, 0.7)), SC(1))
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
    logAct('Script loaded. v' .. VERSION .. ' (utf8_file=' .. tostring(FILE_IS_UTF8) .. ')')

    sampRegisterChatCommand('hfj', function()
        if window[0] then
            window[0] = false
        else
            window[0] = true; windowRendering = true; windowAlpha = 0
            tabFade = 1; tabSlide = 0; lastSelectedTab = tabsList.selected
        end
        logAct('Menu: ' .. tostring(window[0]))
    end)
    sampRegisterChatCommand('taxord', function()   -- старый алиас
        if window[0] then
            window[0] = false
        else
            window[0] = true; windowRendering = true; windowAlpha = 0
            tabFade = 1; tabSlide = 0; lastSelectedTab = tabsList.selected
        end
        logAct('Menu: ' .. tostring(window[0]))
    end)

    sampRegisterChatCommand('zarabotok', function()
        sampShowDialog(ZP_DIALOG_ID, L'Заработок на работах', zpReportText(), L'ОК', L'Закрыть', 0)
    end)

    sampRegisterChatCommand('resetstat', function()
        resetAllStats()
        notify(L'Статистика сброшена', 0xFFAA00)
    end)

    sampRegisterChatCommand('checkupd', function() doCheck(false) end)
    sampRegisterChatCommand('update', function() doUpdate() end)
    sampRegisterChatCommand('updinfo', function()
        notify(L'Версия: v' .. LOCAL_VERSION ..
            ' | GitHub: v' .. (remoteVersion ~= '' and remoteVersion or '?'), 0xFFFF00)
        notify(L'Транспорты: ' .. updaterTransportsText(), 0xFFFF00)
        notify(L'Статус: ' .. updaterStatus, 0xFFFF00)
    end)

    notify(L'Help for Job ' .. VERSION .. L' загружен, /hfj - меню', 0x00FF00)
    startUpdateCheck()

    lua_thread.create(function()
        while true do
            wait(500)
            local x, y, z = getCharCoordinates(PLAYER_PED)
            if x and y and z then
                if zpLastX then
                    local dx, dy, dz = x - zpLastX, y - zpLastY, z - zpLastZ
                    zpMovedDist = zpMovedDist + math.sqrt(dx*dx + dy*dy + dz*dz)
                end
                zpLastX, zpLastY, zpLastZ = x, y, z
            end
        end
    end)

    lastAutoSave = os.clock()

    while true do
        wait(0)
        local now = os.clock()

        -- Диалог "Доступно обновление?" показываем из главного потока
        if pendingUpdatePrompt and now >= promptRetryAt then
            local busy = false
            if type(sampIsDialogActive) == 'function' then
                local okBusy, v = pcall(sampIsDialogActive)
                busy = (okBusy and v) and true or false
            end
            if not busy then
                local shown = sampShowDialog(UPDATE_DIALOG_ID,
                    L'Обновление Help for Job',
                    string.format(L'Доступна версия: %s\nУ вас установлена: %s\n\nОбновить скрипт сейчас?',
                        remoteVersion, LOCAL_VERSION),
                    L'Обновить', L'Позже', 0)
                if shown then
                    pendingUpdatePrompt = false
                    logAct('Update prompt shown for v' .. remoteVersion)
                else
                    promptRetryAt = now + 3
                end
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

        if pendingAccept and (now - pendingAccept) > PENDING_TIMEOUT and not pendingAcceptNotif then
            hasActiveOrder = false; pendingAccept = nil; resetCatchCycle('accept timeout')
        end

        if tapSequenceActive then
            if now >= tapSeqNextSend then
                local found = false
                while tapSeqIndex <= MAX_TAPS do
                    if not tapSeqRejected[tapSeqIndex] then
                        sendTapPacketWithIndex(tapSeqIndex)
                        tapSeqIndex = tapSeqIndex + 1
                        found = true
                        break
                    end
                    tapSeqIndex = tapSeqIndex + 1
                end
                if not found then
                    tapSequenceActive = false
                else
                    tapSeqNextSend = now + TAP_STEP_MS / 1000
                end
            end
            if awaitingDialog and now > awaitingExpire then
                awaitingDialog = false; tapSequenceActive = false
            end
        end
    end
end
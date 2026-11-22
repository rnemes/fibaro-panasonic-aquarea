-- Panasonic Comfort Cloud QuickApp for Fibaro HC3
-- Originally by @zadow28 (https://github.com/techbliss/HC3_Quickapp_Panasonic_cloud)
-- Maintained by @rnemes: https://github.com/rnemes/fibaro-panasonic-aquarea
-- Free to use and adjust for personal use, as in the original.
-- Issues and questions: https://github.com/rnemes/fibaro-panasonic-aquarea/issues

--------------------------------------------------------------------------------
-- Panasonic comfort cloud for fibaro home center 3
-- version 2.6.2
--
-- 2.6.2: security: login redirects only to Panasonic over https, stronger random values for the
--        login, login code masked in the log. Code cleanup (no globals, lint and format checks).
-- 2.6.1: energy meters start from past use (from the energyStart date, default: when the
--        adapter was registered), so the totals match the Panasonic app.
-- 2.6.0: Aquarea energy use (heating, hot water, cooling) as energy meter child devices.
-- 2.5.0: raw data log switch (TRACE, debugRaw variable); on commands start with format 2.
-- 2.4.1: fix crash on zone buttons (storage key), app version looked up only when Panasonic asks.
-- 2.4.0: zone/tank/mode/power changes try several request formats until the unit acts, and remember it.
-- 2.3.2: raw status dump at start, on Refresh and after commands (diagnostics).
-- 2.3.1: log shows zone/hot water on-off, the command sent, Panasonic's reply, and whether the unit followed.
-- 2.3.0: readings as temperature sensor child devices (outdoor, zone water, hot water tank).
-- 2.2.2: app version comes from Google Play / AppBrain (Android) before the App Store.
-- 2.2.1: Aquarea on/off status also follows the zones and the tank.
-- 2.2.0: Aquarea air-to-water heat pumps (zones, hot water tank, mode, quiet, powerful).
-- 2.1.0: if the automatic login is refused, log in once in a browser (see the loginUrl and
--        authCode variables); the refresh token keeps the app logged in after that.
-- 2.0.1: works when the HC3 follows http redirects itself (login code comes back via form_post).
-- 2.0.0: Panasonic retired the old /auth/login/ endpoint (412 Precondition Failed).
--        Login now uses the Panasonic ID (Auth0) OAuth flow with PKCE, the same flow
--        as the pcomfortcloud Python library and the Home Assistant integration:
--          1. authglb.digital.panasonic.com/authorize          -> login page + _csrf
--          2. /usernamepassword/login, /login/callback, resume -> authorization code
--          3. /oauth/token                                     -> access + refresh token
--          4. accsmart.panasonic.com/auth/v2/login             -> clientId
--        Every API call is signed with x-cfc-api-key (sha256 of a fixed salt,
--        a timestamp and the access token).
--        Tokens are kept in internal storage and refreshed, so a restart does not log in
--        again. All callbacks are protected so a bad answer is logged, not a crash.
--
-- QuickApp variables:
--   Username, password   Panasonic ID login (the same as in the Comfort Cloud app)
--   deviceName           optional, name of the unit to control (default: first unit)
--   pollSeconds          optional, status refresh interval in seconds (default 300)
--   appVersion           optional, force the X-APP-VERSION header (default: App Store lookup)
--   energyStart          optional, YYYYMMDD: energy meters count from this day (default: the day
--                        the adapter was registered). Change it to recount once.
--------------------------------------------------------------------------------

local AUTH_BASE = "https://authglb.digital.panasonic.com"
local ACC_BASE = "https://accsmart.panasonic.com"
local APP_CLIENT_ID = "Xmy6xIYIitMxngjB2rHvlm6HSDNnaMJx"
local AUTH0_CLIENT = "eyJuYW1lIjoiQXV0aDAuQW5kcm9pZCIsImVudiI6eyJhbmRyb2lkIjoiMzAifSwidmVyc2lvbiI6IjIuOS4zIn0="
local REDIRECT_URI = "panasonic-iot-cfc://authglb.digital.panasonic.com/android/com.panasonic.ACCsmart/callback"
local AUDIENCE = "https://digital.panasonic.com/" .. APP_CLIENT_ID .. "/api/v1/"
local SCOPE = "openid offline_access comfortcloud.control a2w.control"
local API_KEY_SALT = "521325fb2dd486bf4831b47644317fca"
local DEFAULT_APP_VERSION = "5.1.0"
local AUTH_UA = "okhttp/4.10.0"
local BROWSER_UA =
    "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/113.0.0.0 Mobile Safari/537.36"
local HTTP_TIMEOUT = 20000
local TWO_FACTOR_ERROR = "this Panasonic ID has two-factor authentication on. Turn 2FA off for this account "
    .. "(or use a second account without 2FA, shared from the Comfort Cloud app)"

-- Login, unit and air conditioner state. File-level locals (not globals), shared by the
-- functions below.
local APPversion = DEFAULT_APP_VERSION -- X-APP-VERSION header, updated from the app stores
local user, pass -- Panasonic ID login, from the QuickApp variables
local guid, modulenu -- the controlled unit's id and model
-- air conditioner status, as last read from Comfort Cloud (see readParameters)
local operate, operationM, tempe, fanS, ecoM, nano

--------------------------------------------------------------------------------
-- helpers: sha256, base64url, url encoding, html, cookies
--------------------------------------------------------------------------------

local K256 = {
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
}

local function rrot(x, n) return ((x >> n) | (x << (32 - n))) & 0xffffffff end

-- returns the 32 byte binary digest
local function sha256(msg)
    local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    local bitLen = #msg * 8
    msg = msg .. "\128" .. string.rep("\0", (55 - #msg) % 64)
    for i = 7, 0, -1 do
        msg = msg .. string.char((bitLen >> (i * 8)) & 0xff)
    end

    local w = {}
    for chunk = 1, #msg, 64 do
        for j = 0, 15 do
            local b1, b2, b3, b4 = msg:byte(chunk + j * 4, chunk + j * 4 + 3)
            w[j + 1] = (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
        end
        for j = 17, 64 do
            local a, b = w[j - 15], w[j - 2]
            local s0 = rrot(a, 7) ~ rrot(a, 18) ~ (a >> 3)
            local s1 = rrot(b, 17) ~ rrot(b, 19) ~ (b >> 10)
            w[j] = (w[j - 16] + s0 + w[j - 7] + s1) & 0xffffffff
        end
        local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
        for j = 1, 64 do
            local S1 = rrot(e, 6) ~ rrot(e, 11) ~ rrot(e, 25)
            local ch = (e & f) ~ (~e & g)
            local t1 = (h + S1 + ch + K256[j] + w[j]) & 0xffffffff
            local S0 = rrot(a, 2) ~ rrot(a, 13) ~ rrot(a, 22)
            local maj = (a & b) ~ (a & c) ~ (b & c)
            local t2 = (S0 + maj) & 0xffffffff
            h, g, f, e, d, c, b, a = g, f, e, (d + t1) & 0xffffffff, c, b, a, (t1 + t2) & 0xffffffff
        end
        H[1] = (H[1] + a) & 0xffffffff
        H[2] = (H[2] + b) & 0xffffffff
        H[3] = (H[3] + c) & 0xffffffff
        H[4] = (H[4] + d) & 0xffffffff
        H[5] = (H[5] + e) & 0xffffffff
        H[6] = (H[6] + f) & 0xffffffff
        H[7] = (H[7] + g) & 0xffffffff
        H[8] = (H[8] + h) & 0xffffffff
    end

    local out = {}
    for i = 1, 8 do
        out[i] = string.char((H[i] >> 24) & 0xff, (H[i] >> 16) & 0xff, (H[i] >> 8) & 0xff, H[i] & 0xff)
    end
    return table.concat(out)
end

local function toHex(bin)
    return (bin:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local function base64url(bin)
    local out = {}
    for i = 1, #bin, 3 do
        local b1, b2, b3 = bin:byte(i, i + 2)
        local n = (b1 << 16) | ((b2 or 0) << 8) | (b3 or 0)
        out[#out + 1] = B64:sub((n >> 18) + 1, (n >> 18) + 1) .. B64:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
        if b2 then out[#out + 1] = B64:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) end
        if b3 then out[#out + 1] = B64:sub((n & 63) + 1, (n & 63) + 1) end
    end
    return table.concat(out)
end

local function base64urlDecode(s)
    s = s:gsub("%+", "-"):gsub("/", "_"):gsub("[^%w%-_]", "")
    local out, bits, nbits = {}, 0, 0
    for i = 1, #s do
        local v = B64:find(s:sub(i, i), 1, true) - 1
        bits = (bits << 6) | v
        nbits = nbits + 6
        if nbits >= 8 then
            nbits = nbits - 8
            out[#out + 1] = string.char((bits >> nbits) & 0xff)
        end
    end
    return table.concat(out)
end

-- The HC3 has no secure random number source, so random values for the login (PKCE
-- verifier, state) mix several hard to guess inputs through SHA-256: the time, the
-- process clock, memory addresses, math.random, a counter and a seed that is kept in
-- internal storage and changes on every start (see seedEntropy).
local entropySeed, entropyCounter = "", 0

local function entropyPool()
    local function try(fn, ...)
        local ok, v = pcall(fn, ...)
        return ok and tostring(v) or ""
    end
    entropyCounter = entropyCounter + 1
    return table.concat({
        entropySeed,
        tostring(entropyCounter),
        tostring(os.time()),
        try(os.clock),
        tostring({}),
        tostring(function() end),
        tostring(math.random()),
        tostring(math.random()),
        try(collectgarbage, "count"),
    }, "|")
end

-- random string of base64url characters (A-Z a-z 0-9 - _)
local function randomString(len)
    local out = ""
    while #out < len do
        out = out .. base64url(sha256(entropyPool()))
    end
    return out:sub(1, len)
end

local function urlEncode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function urlDecode(s)
    return (s:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function formEncode(params)
    local parts = {}
    for k, v in pairs(params) do
        parts[#parts + 1] = urlEncode(k) .. "=" .. urlEncode(v)
    end
    return table.concat(parts, "&")
end

local function queryParam(url, name)
    if not url then return nil end
    local query = url:match("%?(.*)$")
    if not query then return nil end
    for k, v in query:gmatch("([^&=]+)=([^&]*)") do
        if urlDecode(k) == name then return urlDecode(v) end
    end
    return nil
end

local function htmlDecode(s)
    s = s:gsub("&#[xX](%x+);", function(h) return utf8.char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8.char(tonumber(d)) end)
    s = s:gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
    return (s:gsub("&amp;", "&"))
end

local function htmlAttr(tag, name)
    local v = tag:match("%s" .. name .. '%s*=%s*"([^"]*)"') or tag:match("%s" .. name .. "%s*=%s*'([^']*)'")
    return v and htmlDecode(v)
end

-- all <input type="hidden"> fields of a html page as a name -> value table
local function hiddenInputs(html)
    local fields = {}
    for tag in tostring(html):gmatch("<input[^>]*>") do
        local name = htmlAttr(tag, "name")
        if name and (htmlAttr(tag, "type") or ""):lower() == "hidden" then
            fields[name] = htmlAttr(tag, "value") or ""
        end
    end
    return fields
end

local function getHeader(headers, name)
    if type(headers) ~= "table" then return nil end
    name = name:lower()
    for k, v in pairs(headers) do
        if type(k) == "string" and k:lower() == name then return v end
    end
    return nil
end

-- Set-Cookie can arrive as a list or as one comma joined string
local function storeCookies(jar, headers)
    local raw = getHeader(headers, "set-cookie")
    if not raw then return end
    if type(raw) == "table" then raw = table.concat(raw, "\n") end
    raw = raw:gsub(",%s*([%w_%-%.]+=)", "\n%1")
    for line in raw:gmatch("[^\n]+") do
        local name, value = line:match("^%s*([^=;%s]+)=([^;]*)")
        if name then jar[name] = value end
    end
end

local function cookieHeader(jar)
    local parts = {}
    for k, v in pairs(jar) do
        parts[#parts + 1] = k .. "=" .. v
    end
    return table.concat(parts, "; ")
end

-- the Auth0 login page carries its settings (state, _csrf) as base64 json in window.atob('...')
local function loginPageConfig(html)
    html = tostring(html)
    local found = {}
    for b64 in html:gmatch("atob%(%s*['\"]([%w%+/=_%-]+)['\"]%s*%)") do
        local ok, cfg = pcall(function() return json.decode(base64urlDecode(b64)) end)
        if ok and type(cfg) == "table" then
            for _, t in ipairs({ cfg.internalOptions or {}, cfg.extraParams or {}, cfg }) do
                found.state = found.state or t.state
                found.csrf = found.csrf or t._csrf
            end
        end
    end
    found.state = found.state
        or html:match('"state"%s*:%s*"([^"]+)"')
        or htmlAttr(html:match("<input[^>]-name=[\"']state[\"'][^>]*>") or "", "value")
    found.csrf = found.csrf
        or html:match('"_csrf"%s*:%s*"([^"]+)"')
        or htmlAttr(html:match("<input[^>]-name=[\"']_csrf[\"'][^>]*>") or "", "value")
    return found
end

local function headerNames(headers)
    local names = {}
    for k in pairs(type(headers) == "table" and headers or {}) do
        names[#names + 1] = tostring(k)
    end
    table.sort(names)
    return table.concat(names, ",")
end

-- Turns a redirect address from the login server into a full url. Only addresses on the
-- Panasonic login server over https are followed, because the login cookies are sent
-- along. Returns nil for anything else.
local function absoluteAuthUrl(location)
    location = tostring(location or "")
    if location:match("^%a[%w+.-]*:") then
        local prefix = AUTH_BASE .. "/"
        if location:sub(1, #prefix) == prefix then return location end
        return nil
    end
    if location:sub(1, 2) == "//" then return nil end
    if location:sub(1, 1) ~= "/" then location = "/" .. location end
    return AUTH_BASE .. location
end

-- hides the one-time login code when a redirect address is logged
local function maskCode(url) return (tostring(url):gsub("([%?&#]code=)[^&]+", "%1***")) end

local function cfcApiKey(timestampMs, accessToken)
    local hash = toHex(sha256("Comfort Cloud" .. API_KEY_SALT .. timestampMs .. "Bearer " .. accessToken))
    return hash:sub(1, 9) .. "cfc" .. hash:sub(10)
end

local function jwtExpiry(token)
    local ok, claims = pcall(function() return json.decode(base64urlDecode(token:match("^[^%.]+%.([^%.]+)"))) end)
    if ok and type(claims) == "table" then return tonumber(claims.exp) end
    return nil
end

-- the HC3 console renders html, so show tags as [tag] to keep them readable
local function shorten(s, max)
    s = tostring(s):gsub("<", "["):gsub(">", "]"):gsub("%s+", " ")
    max = max or 300
    if #s > max then return s:sub(1, max) .. "..." end
    return s
end

--------------------------------------------------------------------------------
-- http wrapper: callbacks are protected so an unexpected answer never crashes the app
--------------------------------------------------------------------------------

--- Wraps a callback in pcall, so an error inside it is logged instead of stopping the QuickApp.
---@param fn function
---@return function
function QuickApp:safe(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then self:error("Unexpected error: " .. tostring(err)) end
    end
end

--- HTTP request with a timeout and protected callbacks.
---@param method string "GET" or "POST"
---@param url string
---@param headers table|nil
---@param body string|nil
---@param cb fun(status: integer|nil, body: string, headers: table) cb(nil, errorText) when the request failed
function QuickApp:http(method, url, headers, body, cb)
    net.HTTPClient({ timeout = HTTP_TIMEOUT }):request(url, {
        options = {
            method = method,
            headers = headers,
            data = body,
            timeout = HTTP_TIMEOUT,
        },
        success = self:safe(function(response) cb(response.status, response.data or "", response.headers or {}) end),
        error = self:safe(function(err) cb(nil, tostring(err)) end),
    })
end

--------------------------------------------------------------------------------
-- Panasonic change app version often so we check for new version
--------------------------------------------------------------------------------

-- Comfort Cloud checks x-app-version against the Android app (x-app-type 1), so ask
-- Google Play first, then AppBrain (an Android app index), and the App Store last
local VERSION_SOURCES = {
    {
        name = "Google Play",
        url = "https://play.google.com/store/apps/details?id=com.panasonic.ACCsmart&hl=en",
        read = function(data) return data:match('%[%"(%d+%.%d+%.%d+)%"%]') end,
    },
    {
        name = "AppBrain",
        url = "https://www.appbrain.com/app/panasonic-comfort-cloud/com.panasonic.ACCsmart",
        read = function(data)
            return data:match('itemprop="softwareVersion"[^>]-content="(%d+%.%d+%.?%d*)"')
                or data:match('content="(%d+%.%d+%.?%d*)"[^>]-itemprop="softwareVersion"')
        end,
    },
    {
        name = "App Store",
        url = "https://itunes.apple.com/lookup?id=1348640525&country=us",
        read = function(data)
            local ok, obj = pcall(json.decode, data)
            return ok
                    and type(obj) == "table"
                    and type(obj.results) == "table"
                    and obj.results[1]
                    and obj.results[1].version
                or nil
        end,
    },
}

-- cb(changed) is called with true when a different version was found
-- The store pages are big; on some HC3 firmware a large chunked answer can crash the http
-- client, so the version is only looked up when Panasonic asks for it (error 4106) and kept.
function QuickApp:getpresentversion(cb, refresh)
    cb = cb or function() end
    local forced = self:getVariable("appVersion")
    if forced and forced ~= "" then
        APPversion = forced
        return cb(false)
    end
    local cached = self:internalStorageGet("pccAppVersion")
    if not refresh and type(cached) == "string" and cached:match("^%d+%.%d+") then
        APPversion = cached
        self:debug("App version: " .. APPversion .. " (saved)")
        return cb(false)
    end
    local before = APPversion
    local function try(i)
        local src = VERSION_SOURCES[i]
        if not src then
            self:warning(
                "Could not read the app version, using "
                    .. APPversion
                    .. ". You can set it by hand in the appVersion variable "
                    .. "(Android app, Google Play > About this app)."
            )
            return cb(false)
        end
        self:http("GET", src.url, { ["accept"] = "text/html,application/json" }, nil, function(status, data)
            local ok, version = pcall(src.read, tostring(data or ""))
            if status == 200 and ok and version then
                APPversion = version
                self:internalStorageSet("pccAppVersion", version)
                self:debug("App version: " .. APPversion .. " (" .. src.name .. ")")
                return cb(APPversion ~= before)
            end
            self:trace("No app version from " .. src.name .. " (HTTP " .. tostring(status) .. ")")
            try(i + 1)
        end)
    end
    try(1)
end

--------------------------------------------------------------------------------
-- startup
--------------------------------------------------------------------------------

function QuickApp:onInit()
    self:debug("onInit")
    self:seedEntropy()
    -- the air conditioner layout has a "slider" element, the Aquarea layout does not
    local hasAcUi = false
    for _, cb in ipairs(type(self.properties) == "table" and self.properties.uiCallbacks or {}) do
        if cb.name == "slider" then hasAcUi = true end
    end
    if hasAcUi then
        ------------------------------------------------------------------------------------------
        --slider settings
        --------------------------------------------------------------------------------------------
        self:updateView("slider", "min", "16")
        self:updateView("slider", "max", "30")
        self:updateView("slider", "value", "21")
        self:updateView("slider", "step", "0.5")
        ------------------------------------------------------------------------------------------
        --hide debug buttons
        --------------------------------------------------------------------------------------------
        self:updateView("bntindebugU", "visible", false)
        self:updateView("btnnow", "visible", false)
        self:updateView("btnhis", "visible", false)
    end

    user = self:getVariable("Username")
    pass = self:getVariable("password")
    self.waiting = {}
    self.loginBackoff = 0
    self:loadToken()
    self:updateView("aqDebug", "value", self:rawDebugOn() and "true" or "false")
    self:updateView("aqDebug", "text", "Raw data log: " .. (self:rawDebugOn() and "ON" or "off"))
    pcall(
        function()
            self:initChildDevices({
                ["com.fibaro.temperatureSensor"] = PanasonicTempSensor,
                ["com.fibaro.energyMeter"] = PanasonicTempSensor,
            })
        end
    )
    local pendingVerifier = self:internalStorageGet("pccVerifier")
    if
        not self.token.refreshToken
        and pendingVerifier
        and pendingVerifier ~= ""
        and (self:getVariable("loginUrl") or "") ~= ""
    then
        self.browserLoginPending = true
        self:browserLoginHelp()
    end
    setInterval(function() self:checkAuthCode() end, 5000)

    if not user or user == "" or not pass or pass == "" then
        self:error("Set the QuickApp variables Username and password (your Panasonic ID login)")
        return
    end

    self:getpresentversion(function() self:turn2() end)

    local poll = tonumber(self:getVariable("pollSeconds")) or 300
    if poll < 60 then poll = 60 end
    setInterval(function()
        if guid then self:getNow() end
    end, poll * 1000)
    -- Panasonic updates consumption about once an hour, so every 30 minutes is plenty
    setInterval(function()
        if guid and self.isAquarea then self:aqEnergy() end
    end, 30 * 60 * 1000)
end

--------------------------------------------------------------------------------
-- token storage
--------------------------------------------------------------------------------

-- mixes the stored seed with this start's values and stores a new seed for the next start
function QuickApp:seedEntropy()
    local ok, stored = pcall(self.internalStorageGet, self, "pccSeed")
    entropySeed = (ok and type(stored) == "string") and stored or ""
    local mixed = sha256(entropyPool())
    pcall(function() math.randomseed(string.unpack("<i8", mixed)) end)
    entropySeed = toHex(mixed)
    pcall(self.internalStorageSet, self, "pccSeed", toHex(sha256(entropyPool())))
end

function QuickApp:loadToken()
    local stored = self:internalStorageGet("pccToken")
    local ok, token = pcall(json.decode, stored or "")
    self.token = (ok and type(token) == "table") and token or {}
end

function QuickApp:saveToken() self:internalStorageSet("pccToken", json.encode(self.token)) end

function QuickApp:tokenValid()
    local t = self.token
    return t.accessToken and t.clientId and t.expiresAt and os.time() < t.expiresAt - 300
end

function QuickApp:setTokens(tokenResponse)
    self.token.accessToken = tokenResponse.access_token
    if tokenResponse.refresh_token then self.token.refreshToken = tokenResponse.refresh_token end
    if tokenResponse.scope then self.token.scope = tokenResponse.scope end
    local expiresAt = os.time() + (tonumber(tokenResponse.expires_in) or 3600)
    local jwtExp = jwtExpiry(tokenResponse.access_token or "")
    if jwtExp and jwtExp < expiresAt then expiresAt = jwtExp end
    self.token.expiresAt = expiresAt
    self:saveToken()
end

--- Makes sure there is a valid access token: uses the stored one, refreshes it, or logs in.
--- Concurrent callers wait for the same login instead of starting their own.
---@param cb fun(ok: boolean, reason: string|nil)
function QuickApp:ensureToken(cb)
    if self:tokenValid() then return cb(true) end
    table.insert(self.waiting, cb)
    if #self.waiting > 1 then return end

    local function finish(ok, err)
        local waiting = self.waiting
        self.waiting = {}
        if ok then
            self.loginBackoff = 0
        elseif self.browserLoginPending then
            self:debug("Not logged in yet: " .. tostring(err))
        else
            self:error("Login failed: " .. tostring(err))
        end
        for _, w in ipairs(waiting) do
            w(ok, err)
        end
    end

    -- automatic login first; if Panasonic refuses it, fall back to a one time login in a browser
    local function fullLogin()
        if self.browserLoginPending then
            return finish(false, "waiting for the browser login, see the loginUrl and authCode variables")
        end
        self:turn1(function(ok, err)
            if not ok then self:startBrowserLogin() end
            finish(ok, err)
        end)
    end

    if self.token.refreshToken then
        self:refreshToken(function(ok)
            if ok and self.token.clientId then return finish(true) end
            if ok then return self:retrieveClientId(finish) end
            fullLogin()
        end)
    else
        fullLogin()
    end
end

--------------------------------------------------------------------------------
-- browser login: the HC3 http client follows redirects and drops Panasonic's login
-- cookies on the way, so the automatic login can fail. Then you log in once in a
-- browser and paste the result into the authCode variable. After that the app keeps
-- itself logged in with the refresh token (one plain request, no redirects).
--------------------------------------------------------------------------------

function QuickApp:browserLoginHelp()
    self:warning(
        "ONE TIME LOGIN NEEDED. 1) Copy the loginUrl variable from this QuickApp's Variables tab "
            .. "(not from this log, which breaks the & characters in it) and open it "
            .. "in Chrome or Edge on a computer. 2) Press F12 and open the Console tab. "
            .. "3) Log in with your Panasonic ID. "
            .. "4) The console then shows: Failed to launch 'panasonic-iot-cfc://...callback?code=...'. Copy that "
            .. "panasonic-iot-cfc://... address (or only the code value) into the authCode variable and save. "
            .. "The code is only valid for a few minutes. Firefox steps are in the README on GitHub."
    )
    self:debug("The loginUrl variable is ready. Copy it from the Variables tab, not from this log.")
end

function QuickApp:startBrowserLogin()
    local verifier = randomString(43)
    local url = AUTH_BASE
        .. "/authorize?"
        .. formEncode({
            scope = SCOPE,
            audience = AUDIENCE,
            protocol = "oauth2",
            response_type = "code",
            code_challenge = base64url(sha256(verifier)),
            code_challenge_method = "S256",
            auth0Client = AUTH0_CLIENT,
            client_id = APP_CLIENT_ID,
            redirect_uri = REDIRECT_URI,
            state = randomString(20),
        })
    self:internalStorageSet("pccVerifier", verifier)
    self:setVariable("loginUrl", url)
    self:setVariable("authCode", "")
    self.browserLoginPending = true
    self:browserLoginHelp()
end

-- called every few seconds, picks up what was pasted into the authCode variable
function QuickApp:checkAuthCode()
    if not self.browserLoginPending or self.exchangingCode then return end
    local value = self:getVariable("authCode")
    if not value or value:match("^%s*$") then return end
    local code = value:match("[%?&]code=([^&%s'\"]+)") or value:match("^%s*([^%s'\"]+)%s*$")
    local verifier = self:internalStorageGet("pccVerifier")
    if not code or not verifier then return end
    self.exchangingCode = true
    self:setVariable("authCode", "")
    self:debug("Login code received, getting tokens")
    self:exchangeCode(code, verifier, function(ok, err)
        self.exchangingCode = false
        if not ok then
            self:error("Browser login failed: " .. tostring(err) .. ". A new loginUrl was made, please try again.")
            return self:startBrowserLogin()
        end
        self.browserLoginPending = false
        self.loginBackoff = 0
        self.loginBlockedUntil = nil
        self:internalStorageSet("pccVerifier", "")
        self:setVariable("loginUrl", "")
        self:debug("Logged in")
        self:turn2()
    end)
end

--- Authorization code + PKCE verifier -> tokens -> Comfort Cloud clientId.
---@param code string the authorization code from the login redirect
---@param verifier string the PKCE verifier the login was started with
---@param cb fun(ok: boolean, err: string|nil)
function QuickApp:exchangeCode(code, verifier, cb)
    self:http(
        "POST",
        AUTH_BASE .. "/oauth/token",
        { ["Auth0-Client"] = AUTH0_CLIENT, ["user-agent"] = AUTH_UA, ["content-type"] = "application/json" },
        json.encode({
            scope = "openid",
            client_id = APP_CLIENT_ID,
            grant_type = "authorization_code",
            code = code,
            redirect_uri = REDIRECT_URI,
            code_verifier = verifier,
        }),
        function(status, data)
            if status ~= 200 then return cb(false, "token: HTTP " .. tostring(status) .. " " .. shorten(data)) end
            local ok, tokens = pcall(json.decode, data)
            if not ok or type(tokens) ~= "table" or not tokens.access_token then
                return cb(false, "token: unexpected answer " .. shorten(data))
            end
            self.token = {}
            self:setTokens(tokens)
            self:retrieveClientId(cb)
        end
    )
end

--------------------------------------------------------------------------------
-- login
--------------------------------------------------------------------------------

--- Full Panasonic ID login with username and password (OAuth with PKCE, see the steps below).
--- After a failure the next attempt waits longer (5 to 60 minutes), so the account is not locked.
---@param cb fun(ok: boolean, err: string|nil)|nil
function QuickApp:turn1(cb)
    cb = cb or function() end
    if self.loginBlockedUntil and os.time() < self.loginBlockedUntil then
        return cb(false, "waiting before the next login attempt (" .. (self.loginBlockedUntil - os.time()) .. " s)")
    end
    local function fail(err)
        -- back off so a wrong password does not get the account locked
        self.loginBackoff = math.min(math.max(self.loginBackoff * 2, 300), 3600)
        self.loginBlockedUntil = os.time() + self.loginBackoff
        cb(false, err)
    end

    -- the HC3 http client follows redirects by itself. Then the code comes back in a
    -- html form (response_mode=form_post) instead of in a Location header.
    local formPost = self.followsRedirects == true
    self:debug("Logging in to Panasonic ID" .. (formPost and " (form_post mode)" or ""))
    local jar = {}
    local function trace(step, status, data, headers)
        local cookies = {}
        for k in pairs(jar) do
            cookies[#cookies + 1] = k
        end
        self:trace(
            step
                .. ": HTTP "
                .. tostring(status)
                .. ", "
                .. #tostring(data or "")
                .. " bytes, headers ["
                .. headerNames(headers)
                .. "], location "
                .. maskCode(getHeader(headers, "location"))
                .. ", cookies ["
                .. table.concat(cookies, ",")
                .. "]"
        )
    end
    local function codeFromAnswer(status, data)
        local fields = hiddenInputs(data)
        if fields.code then return fields.code end
        -- a failed jump to panasonic-iot-cfc://...?code=... may still name the url in the error
        if status == nil then return tostring(data):match("[%?&]code=([%w%-_%.~]+)") end
        return nil
    end
    local codeVerifier = randomString(43)
    local codeChallenge = base64url(sha256(codeVerifier))
    local authorizeUrl = AUTH_BASE
        .. "/authorize?"
        .. formEncode({
            scope = SCOPE,
            audience = AUDIENCE,
            protocol = "oauth2",
            response_type = "code",
            code_challenge = codeChallenge,
            code_challenge_method = "S256",
            auth0Client = AUTH0_CLIENT,
            client_id = APP_CLIENT_ID,
            redirect_uri = REDIRECT_URI,
            state = randomString(20),
            response_mode = formPost and "form_post" or nil,
        })

    local function authHeaders(extra)
        local h = { ["user-agent"] = AUTH_UA, ["Cookie"] = cookieHeader(jar) }
        for k, v in pairs(extra or {}) do
            h[k] = v
        end
        if h["Cookie"] == "" then h["Cookie"] = nil end
        return h
    end

    -- step 6: authorization code -> tokens
    local function exchangeCode(code)
        self:exchangeCode(code, codeVerifier, function(ok, err)
            if ok then
                self:debug("Token retrieved")
                cb(true)
            else
                fail(err)
            end
        end)
    end

    -- step 5: follow /authorize/resume to the app redirect that carries the code
    local function resume(location, hops)
        if location:sub(1, #REDIRECT_URI) == REDIRECT_URI then
            local code = queryParam(location, "code")
            if code then return exchangeCode(code) end
            return fail("login finished without a code: " .. shorten(maskCode(location)))
        end
        if hops > 5 then return fail("too many redirects") end
        local url = absoluteAuthUrl(location)
        if not url then
            return fail("refusing to follow a redirect away from the Panasonic login: " .. shorten(maskCode(location)))
        end
        self:http("GET", url, authHeaders({ ["user-agent"] = BROWSER_UA }), nil, function(status, data, headers)
            storeCookies(jar, headers or {})
            trace("resume", status, data, headers)
            local nextLocation = getHeader(headers, "location")
            if status and status >= 300 and status < 400 and nextLocation then return resume(nextLocation, hops + 1) end
            local code = codeFromAnswer(status, data)
            if code then return exchangeCode(code) end
            local fields = hiddenInputs(data)
            if fields.mfa_token or tostring(data):find("guardian", 1, true) then return fail(TWO_FACTOR_ERROR) end
            fail("login redirect: HTTP " .. tostring(status) .. " " .. shorten(data))
        end)
    end

    -- step 4: post the hidden form back to /login/callback
    local function callback(fields)
        self:http(
            "POST",
            AUTH_BASE .. "/login/callback",
            authHeaders({ ["user-agent"] = BROWSER_UA, ["content-type"] = "application/x-www-form-urlencoded" }),
            formEncode(fields),
            function(status, data, headers)
                storeCookies(jar, headers or {})
                trace("callback", status, data, headers)
                local location = getHeader(headers, "location")
                if status == 302 and location then return resume(location, 0) end
                local code = codeFromAnswer(status, data)
                if code then return exchangeCode(code) end
                local form = hiddenInputs(data)
                if form.mfa_token or tostring(data):find("guardian", 1, true) then return fail(TWO_FACTOR_ERROR) end
                fail("login callback: HTTP " .. tostring(status) .. " " .. shorten(data))
            end
        )
    end

    -- step 3: username and password
    local function login(state, csrf)
        self:http(
            "POST",
            AUTH_BASE .. "/usernamepassword/login",
            authHeaders({ ["Auth0-Client"] = AUTH0_CLIENT, ["content-type"] = "application/json" }),
            json.encode({
                client_id = APP_CLIENT_ID,
                redirect_uri = REDIRECT_URI,
                tenant = "pdpauthglb-a1",
                response_type = "code",
                scope = SCOPE,
                audience = AUDIENCE,
                _csrf = csrf,
                state = state,
                _intstate = "deprecated",
                username = user,
                password = pass,
                lang = "en",
                connection = "PanasonicID-Authentication",
            }),
            function(status, data, headers)
                storeCookies(jar, headers or {})
                trace("usernamepassword", status, nil, headers)
                if status ~= 200 then
                    local ok, body = pcall(json.decode, data)
                    local reason = ok and type(body) == "table" and (body.description or body.message) or shorten(data)
                    return fail("username/password rejected (HTTP " .. tostring(status) .. "): " .. tostring(reason))
                end
                local fields = hiddenInputs(data)
                if fields.mfa_token or tostring(data):find("guardian", 1, true) then return fail(TWO_FACTOR_ERROR) end
                if not fields.wresult then return fail("login: no callback form in the answer " .. shorten(data)) end
                callback(fields)
            end
        )
    end

    -- step 1 and 2: authorize, then open the login page to get the _csrf cookie
    self:http("GET", authorizeUrl, authHeaders(), nil, function(status, data, headers)
        storeCookies(jar, headers or {})
        trace("authorize", status, data, headers)
        local location = getHeader(headers, "location")
        if status == 200 and #tostring(data) > 0 then
            -- the HC3 already followed the redirect to the login page
            if not formPost then
                self:debug("The HC3 follows redirects itself, switching to form_post mode")
                self.followsRedirects = true
                return self:turn1(cb)
            end
            local page = loginPageConfig(data)
            local csrf = jar["_csrf"] or page.csrf
            if not page.state or not csrf then
                return fail(
                    "login page: no "
                        .. (page.state and "_csrf" or "state")
                        .. " found. Page: "
                        .. shorten(data:match('class="title"[^>]*>([^<]*)') or data, 300)
                )
            end
            return login(page.state, csrf)
        end
        if status ~= 302 or not location then
            return fail(
                "authorize: expected a redirect, got HTTP "
                    .. tostring(status)
                    .. " ("
                    .. #tostring(data or "")
                    .. " bytes, headers "
                    .. headerNames(headers)
                    .. ") "
                    .. shorten(data)
            )
        end
        if location:sub(1, #REDIRECT_URI) == REDIRECT_URI then return resume(location, 0) end
        local state = queryParam(location, "state")
        local url = absoluteAuthUrl(location)
        if not url then
            return fail("refusing to follow a redirect away from the Panasonic login: " .. shorten(maskCode(location)))
        end
        self:http("GET", url, authHeaders({ ["user-agent"] = BROWSER_UA }), nil, function(status2, data2, headers2)
            storeCookies(jar, headers2 or {})
            trace("login page", status2, data2, headers2)
            local csrf = jar["_csrf"] or loginPageConfig(data2).csrf
            if status2 ~= 200 or not csrf then
                return fail("login page: HTTP " .. tostring(status2) .. ", no _csrf " .. shorten(data2))
            end
            login(state, csrf)
        end)
    end)
end

--- Gets a new access token with the stored refresh token.
---@param cb fun(ok: boolean)
function QuickApp:refreshToken(cb)
    self:http(
        "POST",
        AUTH_BASE .. "/oauth/token",
        { ["Auth0-Client"] = AUTH0_CLIENT, ["user-agent"] = AUTH_UA, ["content-type"] = "application/json" },
        json.encode({
            scope = self.token.scope or SCOPE,
            client_id = APP_CLIENT_ID,
            refresh_token = self.token.refreshToken,
            grant_type = "refresh_token",
        }),
        function(status, data)
            local ok, tokens = pcall(json.decode, data or "")
            if status == 200 and ok and type(tokens) == "table" and tokens.access_token then
                self:setTokens(tokens)
                self:debug("Token refreshed")
                return cb(true)
            end
            self:warning("Token refresh failed (HTTP " .. tostring(status) .. "), logging in again")
            self.token = {}
            self:saveToken()
            cb(false)
        end
    )
end

--- Headers for a Comfort Cloud API call, signed with x-cfc-api-key.
---@param withClientId boolean add the x-client-id header
---@return table
function QuickApp:accHeaders(withClientId)
    local now = os.time()
    local headers = {
        ["accept"] = "application/json; charset=utf-8",
        ["content-type"] = "application/json",
        ["user-agent"] = "G-RAC",
        ["x-app-name"] = "Comfort Cloud",
        ["x-app-timestamp"] = os.date("!%Y-%m-%d %H:%M:%S", now),
        ["x-app-type"] = "1",
        ["x-app-version"] = APPversion,
        ["x-cfc-api-key"] = cfcApiKey(tostring(now) .. "000", self.token.accessToken),
        ["x-user-authorization-v2"] = "Bearer " .. self.token.accessToken,
    }
    if withClientId and self.token.clientId then headers["x-client-id"] = self.token.clientId end
    return headers
end

-- the Comfort Cloud clientId that goes with the token, cb(ok, err)
function QuickApp:retrieveClientId(cb, retried)
    self:http(
        "POST",
        ACC_BASE .. "/auth/v2/login",
        self:accHeaders(false),
        json.encode({ language = 0 }),
        function(status, data)
            local ok, body = pcall(json.decode, data or "")
            if status == 200 and ok and type(body) == "table" and body.clientId then
                self.token.clientId = body.clientId
                self:saveToken()
                return cb(true)
            end
            if status == 401 and tostring(data):find("4106", 1, true) and not retried then
                self:warning("Panasonic wants a newer app version, checking the App Store")
                return self:getpresentversion(function() self:retrieveClientId(cb, true) end, true)
            end
            cb(false, "auth/v2/login: HTTP " .. tostring(status) .. " " .. shorten(data))
        end
    )
end

--- Signed call to the Comfort Cloud API. Gets a token first, and retries once after an
--- expired token or an outdated app version.
---@param method string "GET" or "POST"
---@param path string e.g. "/device/group"
---@param body table|nil sent as JSON
---@param cb fun(result: table|nil, err: string|nil)
---@param retried boolean|nil internal, true on the retry
function QuickApp:api(method, path, body, cb, retried)
    cb = cb or function() end
    self:ensureToken(function(ok, err)
        if not ok then return cb(nil, err) end
        self:http(
            method,
            ACC_BASE .. path,
            self:accHeaders(true),
            body and json.encode(body) or nil,
            function(status, data)
                if status == 200 then
                    local ok2, obj = pcall(json.decode, data or "")
                    return cb(ok2 and obj or {}, nil)
                end
                if status == 401 and not retried then
                    if tostring(data):find("4106", 1, true) then
                        self:warning("Panasonic wants a newer app version, checking the App Store")
                        return self:getpresentversion(function() self:api(method, path, body, cb, true) end, true)
                    end
                    self.token.expiresAt = 0 -- force a token refresh, then try once more
                    return self:api(method, path, body, cb, true)
                end
                local hint = ""
                if tostring(data):find("4106", 1, true) then
                    hint = ". Panasonic does not accept app version "
                        .. APPversion
                        .. ": put the current Android app version "
                        .. "(Google Play > Panasonic Comfort Cloud > About this app) in the appVersion variable"
                end
                cb(nil, path .. ": HTTP " .. tostring(status) .. " " .. shorten(data) .. hint)
            end
        )
    end)
end

local function encodeGuid(g)
    -- same encoding as pcomfortcloud: quote_plus, then %2F -> f
    return (urlEncode(g):gsub("%%20", "+"):gsub("%%2[Ff]", "f"))
end

--------------------------------------------------------------------------------
-- get devices and status
--------------------------------------------------------------------------------

--- Reads the units in the account, picks the one named in deviceName (or the first one),
--- detects whether it is an Aquarea heat pump or an air conditioner and reads its status.
function QuickApp:turn2()
    self:api("GET", "/device/group", nil, function(groups, err)
        if not groups then
            self:error("Could not read devices: " .. tostring(err))
            setTimeout(function() self:turn2() end, 5 * 60 * 1000)
            return
        end
        self:debug("get devices ok")
        local wanted = self:getVariable("deviceName")
        local found
        for _, group in ipairs(type(groups.groupList) == "table" and groups.groupList or {}) do
            for _, device in ipairs(group.deviceList or group.deviceIdList or {}) do
                local keys = {}
                for k in pairs(type(device) == "table" and device or {}) do
                    keys[#keys + 1] = tostring(k)
                end
                table.sort(keys)
                self:debug(
                    "Found unit: "
                        .. tostring(device.deviceName)
                        .. " model "
                        .. tostring(device.deviceModuleNumber)
                        .. ", type "
                        .. tostring(device.deviceType)
                        .. ", fields ["
                        .. table.concat(keys, ",")
                        .. "]"
                )
                if not found and (wanted == nil or wanted == "" or device.deviceName == wanted) then found = device end
            end
        end
        if not found then
            self:error(
                "No unit found in Comfort Cloud" .. ((wanted and wanted ~= "") and (" named '" .. wanted .. "'") or "")
            )
            return
        end
        guid = found.deviceGuid
        self.unitName = found.deviceName
        modulenu = found.deviceModuleNumber
        -- Aquarea air-to-water heat pumps are deviceType "2" and have no AC "parameters"
        self.isAquarea = tostring(found.deviceType) == "2" or type(found.parameters) ~= "table"
        self:debug(
            "Using unit: "
                .. tostring(found.deviceName)
                .. " "
                .. tostring(modulenu)
                .. (self.isAquarea and " (Aquarea heat pump)" or " (air conditioner)")
        )
        if not self.isAquarea then self:readParameters(found.parameters) end
        self:getNow()
        if self.isAquarea then setTimeout(function() self:aqEnergy() end, 15000) end
    end)
end

--------------------------------------------------------------------------------
-- parameters
--------------------------------------------------------------------------------
function QuickApp:readParameters(p)
    operate = p.operate
    operationM = p.operationMode
    tempe = p.temperatureSet
    fanS = p.fanSpeed
    ecoM = p.ecoMode
    nano = p.nanoe
    self:updateLabels()
end

local MODE_NAMES = { [0] = "Auto", [1] = "Dry", [2] = "Cool", [3] = "Heat", [4] = "Fan" }
local ECO_NAMES = { [0] = "Auto", [1] = "powefull", [2] = "quiet" }

function QuickApp:updateLabels()
    if operate ~= nil then
        self:updateProperty("value", tonumber(operate) == 1)
        self:updateView("labeltemp", "text", tonumber(operate) == 1 and tostring(tempe) or "OFF")
    end
    if tonumber(tempe) then self:updateView("slider", "value", tostring(tempe)) end
    if operationM ~= nil then
        self:updateView("labelmode", "text", "Mode " .. (MODE_NAMES[tonumber(operationM)] or tostring(operationM)))
    end
    if fanS ~= nil then self:updateView("labelfan", "text", "Fan speed " .. tostring(fanS)) end
    if ecoM ~= nil then
        self:updateView("labeleco", "text", "Eco mode " .. (ECO_NAMES[tonumber(ecoM)] or tostring(ecoM)))
    end
    if nano ~= nil then self:updateView("labelx", "text", "Nanoe X  " .. tostring(nano)) end
end

-- only send what changed, like the Panasonic app does
function QuickApp:sendcommand(params)
    if not guid then
        self:warning("No unit yet, command ignored")
        return
    end
    self:api("POST", "/deviceStatus/control", { deviceGuid = guid, parameters = params }, function(result, err)
        if not result then
            self:error("Command failed: " .. tostring(err))
            return
        end
        self:debug("everything okay")
        setTimeout(function() self:getNow() end, 5000)
    end)
end

--------------------------------------------------------------------------------
-- get status now temperute inside etc
--------------------------------------------------------------------------------

local function setGlobalIfExists(name, value)
    local existing = api.get("/globalVariables/" .. urlEncode(name))
    if existing then fibaro.setGlobalVariable(name, tostring(value)) end
end

function QuickApp:getNow()
    if not guid then return end
    if self.isAquarea then return self:aqRefresh(true) end
    self:api("GET", "/deviceStatus/" .. encodeGuid(guid), nil, function(status, err)
        if not status or type(status.parameters) ~= "table" then
            self:warning("Could not read unit status: " .. tostring(err))
            return
        end
        self:readParameters(status.parameters)
        local inside, outside = status.parameters.insideTemperature, status.parameters.outTemperature
        -- 126 and -255 mean the unit does not report this sensor
        if inside and inside ~= 126 and inside ~= -255 then setGlobalIfExists("inside heatpump temperature", inside) end
        if outside and outside ~= 126 and outside ~= -255 then setGlobalIfExists("Outside heatpump", outside) end
        self:tempSensor("inside", "inside", inside)
        self:tempSensor("outdoor", "outdoor", outside)
        self:debug(
            "Setpoint " .. tostring(tempe) .. ", inside " .. tostring(inside) .. ", outside " .. tostring(outside)
        )
    end)
end

--------------------------------------------------------------------------------
-- for future apps History data cost energi etc
--------------------------------------------------------------------------------
function QuickApp:getHis()
    if not guid then return end
    self:api("POST", "/deviceHistoryData", {
        dataMode = 0,
        date = os.date("%Y%m%d"),
        deviceGuid = guid,
        osTimezone = os.date("%z"):gsub("^([%+%-]%d%d)(%d%d)$", "%1:%2"),
    }, function(result, err)
        if result then
            self:debug(json.encode(result))
        else
            self:warning(tostring(err))
        end
    end)
end

function QuickApp:gettemp() self:getNow() end

function QuickApp:updatelabel() self:updateLabels() end

--------------------------------------------------------------------------------
-- On / OFF
--------------------------------------------------------------------------------

function QuickApp:offpressed() self:turnOff() end

function QuickApp:Onpressed() self:turnOn() end

function QuickApp:turnOn()
    if self.isAquarea then return self:aqPower(1) end
    operate = 1
    self:sendcommand({ operate = 1 })
    self:updateView("labeltemp", "text", tostring(tempe))
    self:updateProperty("value", true)
end

function QuickApp:turnOff()
    if self.isAquarea then return self:aqPower(0) end
    operate = 0
    self:sendcommand({ operate = 0 })
    self:updateView("labeltemp", "text", "OFF")
    self:updateProperty("value", false)
end

--------------------------------------------------------------------------------
-- FanSpeed
--------------------------------------------------------------------------------
function QuickApp:setFanSpeed(speed)
    fanS = speed
    ecoM = 0
    self:sendcommand({ fanSpeed = speed, ecoMode = 0 })
    self:updateView("labelfan", "text", "Fan speed " .. tostring(fanS))
    self:updateView("labeleco", "text", "Eco mode off")
end

function QuickApp:press1() self:setFanSpeed(1) end
function QuickApp:presstwo() self:setFanSpeed(2) end
function QuickApp:presstree() self:setFanSpeed(3) end
function QuickApp:pressfour() self:setFanSpeed(4) end
function QuickApp:pressfive() self:setFanSpeed(5) end

--------------------------------------------------------------------------------
-- AUTOFAN MODES
--------------------------------------------------------------------------------
function QuickApp:setSwing(mode, text)
    self:sendcommand({ fanAutoMode = mode })
    self:updateView("labelfanu", "text", text .. tostring(mode))
end

function QuickApp:onfanspeed() self:setSwing(1, "Swing mode off ") end
function QuickApp:pressedswingau() self:setSwing(0, "Swing mode  auto ") end
function QuickApp:pressedfantauleftright() self:setSwing(3, "Swing mode left - right ") end
function QuickApp:pressedswingupdao() self:setSwing(2, "Swing mode up - down ") end

--------------------------------------------------------------------------------
-- eco modes
--------------------------------------------------------------------------------
function QuickApp:setEco(mode)
    ecoM = mode
    self:sendcommand({ ecoMode = mode })
    self:updateView("labeleco", "text", "Eco mode " .. ECO_NAMES[mode])
    self:updateView("labelfan", "text", "Fan speed " .. tostring(fanS))
end

function QuickApp:pressqui() self:setEco(2) end
function QuickApp:Presspowf() self:setEco(1) end
function QuickApp:pressauf() self:setEco(0) end

--------------------------------------------------------------------------------
-- Mode modes
--------------------------------------------------------------------------------
function QuickApp:setMode(mode, tempVariable)
    operationM = mode
    local params = { operationMode = mode }
    local t = tempVariable and tonumber(self:getVariable(tempVariable))
    if t then
        tempe = t
        params.temperatureSet = t
    end
    self:sendcommand(params)
    self:updateView("labelmode", "text", "Mode " .. MODE_NAMES[mode])
    self:updateView("labeltemp", "text", tostring(tempe))
    self:updateView("labelfan", "text", "Fan speed " .. tostring(fanS))
end

function QuickApp:heatpressed() self:setMode(3, "Heat start temp") end
function QuickApp:coolpressed() self:setMode(2, "Cool start temp") end
function QuickApp:drypressed() self:setMode(1, "dry start temp") end
function QuickApp:fanpressed() self:setMode(4, nil) end
function QuickApp:aupressed() self:setMode(0, "Auto start temp") end

--------------------------------------------------------------------------------
-- Nanoe X
--------------------------------------------------------------------------------
function QuickApp:pressedonnano()
    nano = 2
    self:sendcommand({ nanoe = 2 })
    self:updateView("labelx", "text", "Nanoe X  " .. tostring(nano))
end

function QuickApp:pressesoffnano()
    nano = 1
    self:sendcommand({ nanoe = 1 })
    self:updateView("labelx", "text", "Nanoe X  " .. tostring(nano))
end

--------------------------------------------------------------------------------
-- slider
--------------------------------------------------------------------------------

function QuickApp:SetVol(value)
    local t = tonumber(value)
    if not t then return end
    tempe = t
    self:sendcommand({ temperatureSet = t })
    self:updateView("labeltemp", "text", tostring(tempe))
end

function QuickApp:onSliderChanged(event) self:SetVol(event.values[1]) end

-- lets the scene/API action setTemperature work too
function QuickApp:setTemperature(value) self:SetVol(value) end

--------------------------------------------------------------------------------
-- Aquarea air-to-water heat pump
-- Same calls as the Home Assistant integration (aio-panasonic-comfort-cloud):
-- everything goes through /remote/v1/app/common/transfer, which forwards
-- apiName/requestMethod/bodyParam to the Aquarea service.
--------------------------------------------------------------------------------

local AQ_MODE_NAMES = { [0] = "Off", [1] = "Heat", [2] = "Cool", [3] = "Auto (heat)", [4] = "Auto (cool)" }
local AQ_DIRECTION = { [0] = "idle", [1] = "heating/cooling", [2] = "hot water" }
local AQ_POWERFUL = { [0] = "off", [1] = "30 min", [2] = "60 min", [3] = "90 min" }

local function isOn(v) return tonumber(v) == 1 end
local function fmt(v) return v == nil and "-" or tostring(v) end

-- live = ask the unit itself (slower), otherwise the cloud's last known status
function QuickApp:aqRefresh(live)
    if not guid then return end
    self:api("POST", "/remote/v1/app/common/transfer", {
        apiName = "/remote/v1/api/devices?gwid=" .. guid .. "&deviceDirect=" .. (live and "1" or "0"),
        requestMethod = "GET",
    }, function(result, err)
        local status = type(result) == "table" and result.status
        if type(status) == "table" and status[1] then status = status[1] end
        if type(status) ~= "table" then
            if live then
                self:warning(
                    "Live status failed ("
                        .. tostring(err or shorten(json.encode(result or {})))
                        .. "), using cached status"
                )
                return self:aqRefresh(false)
            end
            self:warning("Could not read heat pump status: " .. tostring(err or shorten(json.encode(result or {}))))
            return
        end
        self:rawTrace("received status (" .. (live and "live" or "cached") .. ")", result)
        self.aq = status
        self:aqUpdateView()
    end)
end

function QuickApp:aqZones()
    local zones = {}
    for _, z in ipairs(type(self.aq) == "table" and type(self.aq.zoneStatus) == "table" and self.aq.zoneStatus or {}) do
        if type(z) == "table" and z.zoneId then zones[#zones + 1] = z end
    end
    return zones
end

function QuickApp:aqTank()
    local t = type(self.aq) == "table" and self.aq.tankStatus
    return type(t) == "table" and next(t) and t or nil
end

function QuickApp:aqUpdateView()
    local aq = self.aq
    local mode = tonumber(aq.operationMode)
    local cooling = mode == 2 or mode == 4
    -- some units leave the top level operationStatus at 0, so a running zone or tank also counts as on
    local running = isOn(aq.operationStatus)
    for _, z in ipairs(self:aqZones()) do
        running = running or isOn(z.operationStatus)
    end
    local tankNow = self:aqTank()
    running = running or (tankNow ~= nil and isOn(tankNow.operationStatus))
    local state = running and "On" or "Off"
    local extra = {}
    if tonumber(aq.deiceStatus) == 1 then extra[#extra + 1] = "defrosting" end
    if AQ_DIRECTION[tonumber(aq.direction)] then extra[#extra + 1] = AQ_DIRECTION[tonumber(aq.direction)] end
    if type(aq.faultStatus) == "table" and #aq.faultStatus > 0 then
        local codes = {}
        for _, f in ipairs(aq.faultStatus) do
            codes[#codes + 1] = type(f) == "table" and tostring(f.errorCode or f.errorMessage or json.encode(f))
                or tostring(f)
        end
        extra[#extra + 1] = "ERROR " .. table.concat(codes, ",")
    end
    self:updateProperty("value", running)
    self:updateView(
        "aqStatus",
        "text",
        state
            .. " - "
            .. (AQ_MODE_NAMES[mode] or fmt(mode))
            .. (#extra > 0 and (" - " .. table.concat(extra, ", ")) or "")
    )
    self:updateView("aqOutdoor", "text", "Outdoor " .. fmt(aq.outdoorNow) .. " °C")
    self:updateView(
        "aqExtras",
        "text",
        "Quiet "
            .. (tonumber(aq.quietMode) == 0 and "off" or ("level " .. fmt(aq.quietMode)))
            .. " - Powerful "
            .. (AQ_POWERFUL[tonumber(aq.powerful)] or fmt(aq.powerful))
            .. " - Force hot water "
            .. (isOn(aq.forceDHW) and "on" or "off")
    )

    local zones = self:aqZones()
    for i = 1, 2 do
        local z = zones[i]
        local p = "aqZone" .. i
        if z then
            local setKey, minKey, maxKey = "heatSet", "heatMin", "heatMax"
            if cooling then
                setKey, minKey, maxKey = "coolSet", "coolMin", "coolMax"
            end
            -- with a heating curve the setpoint is a shift (e.g. -5..+5) instead of a temperature
            local shift = tonumber(z[minKey]) and tonumber(z[minKey]) < 0
            self:updateView(
                p,
                "text",
                (z.zoneName or ("Zone " .. z.zoneId))
                    .. ": "
                    .. (isOn(z.operationStatus) and "on" or "off")
                    .. ", now "
                    .. fmt(z.temperatureNow)
                    .. " °C, "
                    .. (shift and "curve shift " or "set ")
                    .. fmt(z[setKey])
                    .. (shift and "" or " °C")
            )
            if tonumber(z[minKey]) and tonumber(z[maxKey]) then
                self:updateView(p .. "Slider", "min", tostring(z[minKey]))
                self:updateView(p .. "Slider", "max", tostring(z[maxKey]))
            end
            if tonumber(z[setKey]) then self:updateView(p .. "Slider", "value", tostring(z[setKey])) end
            if i == 1 then setGlobalIfExists("inside heatpump temperature", z.temperatureNow) end
            self:tempSensor("zone" .. i, (z.zoneName or ("zone " .. i)) .. " water", z.temperatureNow)
        end
        if i == 2 then
            for _, el in ipairs({ p, p .. "Slider", p .. "On", p .. "Off" }) do
                self:updateView(el, "visible", z ~= nil)
            end
        end
    end

    local tank = self:aqTank()
    if tank then
        self:updateView(
            "aqTank",
            "text",
            "Hot water: "
                .. (isOn(tank.operationStatus) and "on" or "off")
                .. ", now "
                .. fmt(tank.temperatureNow)
                .. " °C, set "
                .. fmt(tank.heatSet)
                .. " °C"
        )
        if tonumber(tank.heatMin) and tonumber(tank.heatMax) then
            self:updateView("aqTankSlider", "min", tostring(tank.heatMin))
            self:updateView("aqTankSlider", "max", tostring(tank.heatMax))
        end
        if tonumber(tank.heatSet) then self:updateView("aqTankSlider", "value", tostring(tank.heatSet)) end
        setGlobalIfExists("heatpump tank temperature", tank.temperatureNow)
        self:tempSensor("tank", "hot water tank", tank.temperatureNow)
    else
        self:updateView("aqTank", "text", "No hot water tank")
    end
    setGlobalIfExists("Outside heatpump", aq.outdoorNow)
    self:tempSensor("outdoor", "outdoor", aq.outdoorNow)
    local parts = {
        "Heat pump: " .. state .. " (unit flag " .. fmt(aq.operationStatus) .. "), " .. (AQ_MODE_NAMES[mode] or fmt(
            mode
        )) .. ", outdoor " .. fmt(aq.outdoorNow) .. ", working on " .. (AQ_DIRECTION[tonumber(aq.direction)] or fmt(
            aq.direction
        )),
    }
    for _, z in ipairs(zones) do
        local setKey = cooling and "coolSet" or "heatSet"
        parts[#parts + 1] = (z.zoneName or ("zone " .. z.zoneId))
            .. " "
            .. (isOn(z.operationStatus) and "ON" or "OFF")
            .. "("
            .. fmt(z.operationStatus)
            .. ") "
            .. fmt(z.temperatureNow)
            .. " °C set "
            .. fmt(z[setKey])
    end
    if tank then
        parts[#parts + 1] = "hot water "
            .. (isOn(tank.operationStatus) and "ON" or "OFF")
            .. "("
            .. fmt(tank.operationStatus)
            .. ") "
            .. fmt(tank.temperatureNow)
            .. " °C set "
            .. fmt(tank.heatSet)
    end
    self:debug(table.concat(parts, " | "))
    self:aqCheckPending()
end

-- after a command, check over the next refreshes that the unit really changed
function QuickApp:aqCheckPending()
    local p = self.aqPending
    if not p then return end
    local ok, msg = pcall(p.check)
    if ok and msg == true then
        self:debug(p.what .. " confirmed by the unit")
        if p.onConfirm then p.onConfirm() end
        self.aqPending = nil
    elseif os.time() >= p.deadline then
        self.aqPending = nil
        if p.onTimeout then
            self:warning(p.what .. ": the unit ignored this command format, trying the next one")
            return p.onTimeout()
        end
        self:warning(
            p.what
                .. " was sent and accepted by Panasonic, but the unit still does not report it after "
                .. (os.time() - p.sent)
                .. " s. Panasonic's reply was: "
                .. p.reply
        )
    end
end

--- Sends a command to the Aquarea unit, then refreshes the status a few times.
---@param body table the command (gwid is added here)
---@param what string|nil name of the command for the log
---@param check fun(status: table): boolean|nil returns true once the unit shows the change
---@param onTimeout function|nil called when check is still false after 75 seconds
---@param onConfirm function|nil called when check becomes true
function QuickApp:aqSet(body, what, check, onTimeout, onConfirm)
    if not guid or not self.aq then
        self:warning("No heat pump status yet, command ignored")
        return
    end
    body.gwid = guid
    what = what or "Command"
    self:rawTrace(what .. " sending", body)
    self:api("POST", "/remote/v1/app/common/transfer", {
        apiName = "/remote/v1/api/devices",
        requestMethod = "POST",
        bodyParam = body,
    }, function(result, err)
        if not result then
            self:error(what .. " failed: " .. tostring(err))
            return
        end
        local reply = shorten(json.encode(result), 500)
        self:debug(what .. " sent")
        self:rawTrace(what .. " Panasonic replied", result)
        if check then
            self.aqPending = {
                what = what,
                check = check,
                sent = os.time(),
                deadline = os.time() + 75,
                reply = reply,
                onTimeout = onTimeout,
                onConfirm = onConfirm,
            }
        end
        -- the unit needs a moment before the new state shows up
        for _, delay in ipairs({ 10, 30, 60, 90 }) do
            setTimeout(function() self:aqRefresh(true) end, delay * 1000)
        end
    end)
end

-- zones and tank are replaced, not merged, so always send the full on/off state
-- (same as set_aquarea_operation_state in the Home Assistant library)
-- reported operationMode -> value to send when changing it (Heat 2, Cool 3, Auto 8)
local AQ_MODE_TO_SET = { [1] = 2, [2] = 3, [3] = 8, [4] = 8 }

-- Units differ in which request format they act on, and Panasonic answers result 0 either way.
-- So try the formats in turn until the unit reports the change, and remember the one that worked.
function QuickApp:aqState(mode, zoneId, zoneStatus, tankStatus, what)
    if not self.aq then return self:warning("No heat pump status yet, command ignored") end
    local zones, changedZones = {}, {}
    local anyOn = false
    for _, z in ipairs(self:aqZones()) do
        local st = tonumber(z.operationStatus) or 0
        if zoneId == "all" or zoneId == z.zoneId then
            st = zoneStatus
            changedZones[#changedZones + 1] = { zoneId = z.zoneId, operationStatus = st }
        end
        zones[#zones + 1] = { zoneId = z.zoneId, operationStatus = st }
        anyOn = anyOn or st == 1
    end
    local tank = self:aqTank()
    local tankSt = tank and (tonumber(tank.operationStatus) or 0) or 0
    local tankChanged = tankStatus ~= nil and tank ~= nil
    if tankChanged then tankSt = tankStatus end
    anyOn = anyOn or tankSt == 1
    local currentMode = AQ_MODE_TO_SET[tonumber(self.aq.operationMode)]

    local variants = {
        -- 1: only what changed (like the single setters of the Home Assistant library)
        function()
            local body = {}
            if #changedZones > 0 then body.zoneStatus = changedZones end
            if tankChanged then body.tankStatus = { operationStatus = tankSt } end
            if mode ~= nil then body.operationMode = mode end
            return body
        end,
        -- 2: full state with the operation mode, like the Panasonic app sends when switching on
        function()
            local body = { operationStatus = anyOn and 1 or 0, zoneStatus = zones, operationMode = mode or currentMode }
            if tank then body.tankStatus = { operationStatus = tankSt } end
            return body
        end,
        -- 3: full state without the mode (the format of version 2.2 to 2.3.2)
        function()
            local body = { operationStatus = anyOn and 1 or 0, zoneStatus = zones }
            if tank then body.tankStatus = { operationStatus = tankSt } end
            if mode ~= nil then body.operationMode = mode end
            return body
        end,
    }

    local function check()
        for _, want in ipairs(zones) do
            for _, z in ipairs(self:aqZones()) do
                if z.zoneId == want.zoneId and (tonumber(z.operationStatus) or 0) ~= want.operationStatus then
                    return false
                end
            end
        end
        local t = self:aqTank()
        if t and (tonumber(t.operationStatus) or 0) ~= tankSt then return false end
        if
            mode ~= nil
            and AQ_MODE_TO_SET[tonumber(self.aq.operationMode)] ~= mode
            and not (mode == 8 and tonumber(self.aq.operationMode) >= 3)
        then
            return false
        end
        return true
    end

    -- remembered per command, because a unit can act on one format for "off" and another for "on".
    -- Switching off works with the old format 3 and switching on needs format 2 (with the mode),
    -- so those are tried first; the others stay as fallbacks for other units.
    local key = "aqFormat_" .. what:gsub("[^%w]", "_")
    local turningOff = (zoneStatus == 0 or tankStatus == 0) and zoneStatus ~= 1 and tankStatus ~= 1
    local okGet, saved = pcall(self.internalStorageGet, self, key)
    local first = tonumber(okGet and saved or nil) or (turningOff and 3 or 2)
    local order = { first }
    for i = 1, #variants do
        if i ~= first then order[#order + 1] = i end
    end

    local function send(n)
        local v = order[n]
        if not v then
            self:warning(
                what
                    .. ": the unit did not act on any command format. "
                    .. "Please check that the same change works in the Panasonic Comfort Cloud app."
            )
            return
        end
        local body = variants[v]()
        body.gwid = nil
        self:aqSet(body, what .. " (format " .. v .. ")", check, function() send(n + 1) end, function()
            if v ~= first then
                pcall(self.internalStorageSet, self, key, tostring(v))
                self:debug("Format " .. v .. " works for this unit, using it from now on")
            end
        end)
    end
    send(1)
end

function QuickApp:aqPower(on) self:aqState(nil, "all", on, on, on == 1 and "Turn on" or "Turn off") end

function QuickApp:aqOn() self:aqPower(1) end
function QuickApp:aqOff() self:aqPower(0) end
function QuickApp:aqZone1On()
    local z = self:aqZones()[1]
    if z then self:aqState(nil, z.zoneId, 1, nil, "Zone 1 on") end
end
function QuickApp:aqZone1Off()
    local z = self:aqZones()[1]
    if z then self:aqState(nil, z.zoneId, 0, nil, "Zone 1 off") end
end
function QuickApp:aqZone2On()
    local z = self:aqZones()[2]
    if z then self:aqState(nil, z.zoneId, 1, nil, "Zone 2 on") end
end
function QuickApp:aqZone2Off()
    local z = self:aqZones()[2]
    if z then self:aqState(nil, z.zoneId, 0, nil, "Zone 2 off") end
end
function QuickApp:aqTankOn() self:aqState(nil, nil, nil, 1, "Hot water on") end
function QuickApp:aqTankOff() self:aqState(nil, nil, nil, 0, "Hot water off") end

-- operationMode values for changes: Heat 2, Cool 3, Auto 8
function QuickApp:aqHeat() self:aqState(2, nil, nil, nil, "Mode heat") end
function QuickApp:aqCool() self:aqState(3, nil, nil, nil, "Mode cool") end
function QuickApp:aqAuto() self:aqState(8, nil, nil, nil, "Mode auto") end

function QuickApp:aqZoneTemp(index, value)
    local z = self:aqZones()[index]
    local t = tonumber(value)
    if not z or not t then return end
    local mode = tonumber(self.aq.operationMode)
    local key = (mode == 2 or mode == 4) and "coolSet" or "heatSet"
    t = math.floor(t + 0.5)
    self:aqSet({ zoneStatus = { { zoneId = z.zoneId, [key] = t } } }, "Zone " .. index .. " set " .. t)
end

function QuickApp:aqZone1Slider(event) self:aqZoneTemp(1, event.values[1]) end
function QuickApp:aqZone2Slider(event) self:aqZoneTemp(2, event.values[1]) end

function QuickApp:aqTankSlider(event)
    local t = tonumber(event.values[1])
    if not t or not self:aqTank() then return end
    t = math.floor(t + 0.5)
    self:aqSet({ tankStatus = { heatSet = t } }, "Hot water set " .. t)
end

function QuickApp:aqForceDhwOn() self:aqSet({ forceDHW = 1 }, "Force hot water on") end
function QuickApp:aqForceDhwOff() self:aqSet({ forceDHW = 0 }, "Force hot water off") end
function QuickApp:aqQuietOff() self:aqSet({ quietMode = 0 }, "Quiet off") end
function QuickApp:aqQuiet1() self:aqSet({ quietMode = 1 }, "Quiet 1") end
function QuickApp:aqQuiet2() self:aqSet({ quietMode = 2 }, "Quiet 2") end
function QuickApp:aqQuiet3() self:aqSet({ quietMode = 3 }, "Quiet 3") end
function QuickApp:aqPowerfulOff() self:aqSet({ powerful = 0 }, "Powerful off") end
function QuickApp:aqPowerful30() self:aqSet({ powerful = 1 }, "Powerful 30 min") end
function QuickApp:aqPowerful60() self:aqSet({ powerful = 2 }, "Powerful 60 min") end
function QuickApp:aqRefreshPressed() self:aqRefresh(true) end

--------------------------------------------------------------------------------
-- raw data debug switch
-- Off by default. When on, everything sent to and received from Panasonic is
-- logged as TRACE. Kept in the debugRaw variable, so it survives a restart.
--------------------------------------------------------------------------------

function QuickApp:rawDebugOn() return self:getVariable("debugRaw") == "1" end

function QuickApp:setRawDebug(on)
    self:setVariable("debugRaw", on and "1" or "0")
    self:updateView("aqDebug", "value", on and "true" or "false")
    self:updateView("aqDebug", "text", "Raw data log: " .. (on and "ON" or "off"))
    self:debug("Raw data log " .. (on and "on (TRACE messages)" or "off"))
end

-- for a switch element (onToggled) and for a plain button (onReleased): a button just flips it
function QuickApp:aqDebugToggle(event)
    local v = type(event) == "table" and type(event.values) == "table" and event.values[1]
    if v == true or v == "true" then return self:setRawDebug(true) end
    if v == false or v == "false" then return self:setRawDebug(false) end
    self:setRawDebug(not self:rawDebugOn())
end

function QuickApp:rawTrace(title, data)
    if not self:rawDebugOn() then return end
    -- in pieces so the HC3 console does not cut long answers off
    local raw = shorten(type(data) == "string" and data or json.encode(data), 20000)
    local parts = math.max(1, (#raw + 1499) // 1500)
    for i = 1, parts do
        self:trace(
            "Raw "
                .. title
                .. (parts > 1 and (" " .. i .. "/" .. parts) or "")
                .. ": "
                .. raw:sub((i - 1) * 1500 + 1, i * 1500)
        )
    end
end

--------------------------------------------------------------------------------
-- temperature sensors as child devices
-- Each reading becomes its own temperature sensor, so Yubii shows it on the
-- dashboard, keeps its history and block scenes can use it.
--------------------------------------------------------------------------------

class("PanasonicTempSensor")(QuickAppChild)

function PanasonicTempSensor:__init(device) QuickAppChild.__init(self, device) end

function QuickApp:findTempSensors()
    local found = {}
    for _, child in pairs(self.childDevices or {}) do
        local ok, key = pcall(function() return child:getVariable("pccSensor") end)
        if ok and key and key ~= "" then found[key] = child end
    end
    return found
end

-- key identifies the reading, label is added to the unit name for a new sensor
function QuickApp:tempSensor(key, label, value)
    local t = tonumber(value)
    -- 126 and -255 mean the unit does not report this sensor
    if not t or t == 126 or t == -255 then return end
    self.sensors = self.sensors or self:findTempSensors()
    local child = self.sensors[key]
    if not child then
        local ok, created = pcall(
            function()
                return self:createChildDevice({
                    name = (self.unitName or "Panasonic") .. " " .. label,
                    type = "com.fibaro.temperatureSensor",
                    initialProperties = { quickAppVariables = { { name = "pccSensor", value = key } } },
                    initialInterfaces = {},
                }, PanasonicTempSensor)
            end
        )
        if not ok or not created then
            self:warning("Could not create the " .. label .. " sensor: " .. tostring(created))
            return
        end
        child = created
        self.sensors[key] = child
        child:updateProperty("unit", "C")
        self:debug("Created temperature sensor: " .. (self.unitName or "Panasonic") .. " " .. label)
    end
    child:updateProperty("value", t)
end

--------------------------------------------------------------------------------
-- Aquarea energy consumption
-- /remote/v1/api/consumption (same call as the Home Assistant library) gives the kWh
-- per hour of a day, split into heating, cooling and hot water. Yubii wants an
-- ever-growing energy total per meter, so the daily figures are added up here:
-- the running total is kept in internal storage and yesterday's last hours are
-- added when the day changes.
--------------------------------------------------------------------------------

local ENERGY_KINDS = {
    { key = "heat", field = "heatConsumption", label = "energy heating" },
    { key = "tank", field = "tankConsumption", label = "energy hot water" },
    { key = "cool", field = "coolConsumption", label = "energy cooling" },
}

local function timezoneOffset()
    local now = os.time()
    local utc = os.date("!*t", now)
    utc.isdst = os.date("*t", now).isdst
    local offset = os.difftime(now, os.time(utc))
    local sign = offset < 0 and "-" or "+"
    offset = math.abs(offset)
    return string.format("%s%02d:%02d", sign, offset // 3600, (offset % 3600) // 60)
end

-- dataMode 0 = the hours of one day, 1 = the days of a month, 2 = the months of a year
-- cb(totals) with totals.heat/.tank/.cool in kWh (nil when the unit reports nothing)
function QuickApp:aqConsumption(dataMode, date, cb)
    self:api("POST", "/remote/v1/app/common/transfer", {
        apiName = "/remote/v1/api/consumption",
        requestMethod = "POST",
        bodyParam = { gwid = guid, dataMode = dataMode, date = date, osTimezone = timezoneOffset() },
    }, function(result, err)
        if type(result) ~= "table" or type(result.historyDataList) ~= "table" then
            self:warning("Could not read energy use: " .. tostring(err or shorten(json.encode(result or {}))))
            return cb(nil)
        end
        self:rawTrace("received consumption (mode " .. dataMode .. ", " .. date .. ")", result)
        local totals = {}
        for _, item in ipairs(result.historyDataList) do
            for _, kind in ipairs(ENERGY_KINDS) do
                local v = type(item) == "table" and tonumber(item[kind.field])
                -- hours that have not happened yet come back as null or -255
                if v and v >= 0 then totals[kind.key] = (totals[kind.key] or 0) + v end
            end
        end
        cb(totals, result)
    end)
end

function QuickApp:loadEnergyState()
    local ok, st = pcall(function() return json.decode(self:internalStorageGet("pccEnergy") or "") end)
    return (ok and type(st) == "table") and st or {}
end

-- one-time start of the meters from past use: days of the first month one by one,
-- then whole months, up to and including today. Runs again if energyStart changes.
local function daysInMonth(y, m) return os.date("*t", os.time({ year = y, month = m + 1, day = 0, hour = 12 })).day end

function QuickApp:aqEnergyBackfill(st, today, done)
    local wanted = self:getVariable("energyStart") or ""
    local function run(start)
        local requested = start
        if not start:match("^%d%d%d%d%d%d%d%d$") or start > today then
            self:warning("energyStart '" .. start .. "' is not a date (YYYYMMDD) up to today, counting from today")
            start = today
        end
        local requests = {}
        local y, m, d = tonumber(start:sub(1, 4)), tonumber(start:sub(5, 6)), tonumber(start:sub(7, 8))
        local ty, tm = tonumber(today:sub(1, 4)), tonumber(today:sub(5, 6))
        if d > 1 then
            local last = (y == ty and m == tm) and tonumber(today:sub(7, 8)) or daysInMonth(y, m)
            for day = d, last do
                requests[#requests + 1] = { 0, string.format("%04d%02d%02d", y, m, day) }
            end
            m = m + 1
            if m > 12 then
                y, m = y + 1, 1
            end
        end
        while y < ty or (y == ty and m <= tm) do
            requests[#requests + 1] = { 1, string.format("%04d%02d01", y, m) }
            m = m + 1
            if m > 12 then
                y, m = y + 1, 1
            end
        end
        self:debug("Counting past energy use from " .. start .. " (" .. #requests .. " requests)")
        local total, i = {}, 0
        local function nextRequest()
            i = i + 1
            if i > #requests then
                -- today's hours so far, so the normal counting continues from here
                return self:aqConsumption(0, today, function(todayTotals)
                    if not todayTotals then return done(false) end
                    st.total, st.today, st.date, st.backfill = {}, {}, today, requested
                    for _, kind in ipairs(ENERGY_KINDS) do
                        st.total[kind.key] = total[kind.key] or 0
                        st.today[kind.key] = todayTotals[kind.key]
                    end
                    self:debug(
                        string.format(
                            "Past energy use since %s: heating %.1f kWh, hot water %.1f kWh, cooling %.1f kWh",
                            start,
                            st.total.heat,
                            st.total.tank,
                            st.total.cool
                        )
                    )
                    done(true)
                end)
            end
            local r = requests[i]
            self:aqConsumption(r[1], r[2], function(t)
                if not t then
                    self:warning("Counting past energy use stopped at " .. r[2] .. ", will try again in 30 minutes")
                    return done(false)
                end
                for k, v in pairs(t) do
                    total[k] = (total[k] or 0) + v
                end
                nextRequest()
            end)
        end
        nextRequest()
    end
    if wanted ~= "" then return run(wanted) end
    -- no date given: ask Panasonic when the adapter was registered
    self:aqConsumption(0, today, function(t, result)
        if not t then return done(false) end
        local reg = type(result) == "table" and tostring(result.deviceRegisterTime or "") or ""
        if not reg:match("^%d%d%d%d%d%d%d%d$") then reg = today:sub(1, 6) .. "01" end
        run(reg)
    end)
end

--- Updates the energy meters (heating, hot water, cooling) from Panasonic's consumption data.
--- The first time, and when energyStart changes, it first adds up the past use (backfill).
---@param counted table|nil the energy state, when called again after the backfill
function QuickApp:aqEnergy(counted)
    if not guid then return end
    local today = os.date("%Y%m%d")
    local st = counted or self:loadEnergyState()
    local wantedStart = self:getVariable("energyStart") or ""
    if not counted and (not st.backfill or (wantedStart ~= "" and wantedStart ~= st.backfill)) then
        if self.energyBackfillRunning then return end
        self.energyBackfillRunning = true
        return self:aqEnergyBackfill(st, today, function(ok)
            self.energyBackfillRunning = false
            if ok then
                self:internalStorageSet("pccEnergy", json.encode(st))
                self:aqEnergy(st)
            end
        end)
    end
    st.total = st.total or {}
    st.today = st.today or {}

    local function apply(todayTotals, monthTotals)
        for _, kind in ipairs(ENERGY_KINDS) do
            local now = todayTotals[kind.key]
            if now then
                local before = st.today[kind.key] or 0
                st.total[kind.key] = st.total[kind.key] or 0
                if now > before then st.total[kind.key] = (st.total[kind.key] or 0) + (now - before) end
                st.today[kind.key] = now
                if st.total[kind.key] > 0 or kind.key ~= "cool" then
                    self:energyMeter(kind.key, kind.label, st.total[kind.key])
                end
            end
        end
        st.date = today
        self:internalStorageSet("pccEnergy", json.encode(st))
        local function f(v) return v and string.format("%.1f", v) or "-" end
        local line = "Energy today: heating "
            .. f(todayTotals.heat)
            .. " kWh, hot water "
            .. f(todayTotals.tank)
            .. " kWh, cooling "
            .. f(todayTotals.cool)
            .. " kWh"
        if monthTotals then
            line = line
                .. " | this month: heating "
                .. f(monthTotals.heat)
                .. ", hot water "
                .. f(monthTotals.tank)
                .. ", cooling "
                .. f(monthTotals.cool)
                .. " kWh"
        end
        self:updateView("aqEnergy", "text", line)
        self:debug(line)
    end

    local function readToday()
        self:aqConsumption(0, today, function(todayTotals)
            if not todayTotals then return end
            self:aqConsumption(1, today, function(monthTotals) apply(todayTotals, monthTotals) end)
        end)
    end

    if st.date and st.date ~= today then
        -- new day: add what yesterday used after our last reading, then start today from zero
        local lastDay = st.date
        self:aqConsumption(0, lastDay, function(dayTotals)
            if dayTotals then
                for _, kind in ipairs(ENERGY_KINDS) do
                    local final, seen = dayTotals[kind.key], st.today[kind.key] or 0
                    if final and final > seen then st.total[kind.key] = (st.total[kind.key] or 0) + (final - seen) end
                end
            end
            st.today = {}
            readToday()
        end)
    else
        readToday()
    end
end

-- an energy meter child device; Yubii's energy panel uses its "energy" property (kWh, ever growing)
function QuickApp:energyMeter(key, label, total)
    self.sensors = self.sensors or self:findTempSensors()
    local id = "energy_" .. key
    local child = self.sensors[id]
    if not child then
        local ok, created = pcall(
            function()
                return self:createChildDevice({
                    name = (self.unitName or "Panasonic") .. " " .. label,
                    type = "com.fibaro.energyMeter",
                    initialProperties = { quickAppVariables = { { name = "pccSensor", value = id } } },
                    initialInterfaces = { "energy" },
                }, PanasonicTempSensor)
            end
        )
        if not ok or not created then
            self:warning("Could not create the " .. label .. " meter: " .. tostring(created))
            return
        end
        child = created
        self.sensors[id] = child
        child:updateProperty("unit", "kWh")
        self:debug("Created energy meter: " .. (self.unitName or "Panasonic") .. " " .. label)
    end
    local value = math.floor(total * 100 + 0.5) / 100
    child:updateProperty("value", value)
    child:updateProperty("energy", value)
end

--!nonstrict
-- Shared Tibber model for the tibber plugin: GraphQL query, response parsing,
-- statistics (cheapest / most expensive slot of the day) and formatting.
-- The data logic is ported from duxtibber's Tibber.js
-- (https://github.com/antonjah/duxtibber), restricted to demo-token mode.

local API_URL = "https://api.tibber.com/v1-beta/gql"

-- Public demo token from Tibber's API explorer (developer.tibber.com). It
-- only grants access to auto-generated demo data, no personal account.
local DEMO_TOKEN = "3A77EECF61BD445F47241A5A36202185C35AF3AF58609E19B53F3A8872AD7BE1-1"

local PRICE_FIELDS = "total energy tax startsAt level currency"

local QUERY = "query { viewer { homes { id appNickname currentSubscription {"
  .. " priceInfo(resolution: QUARTER_HOURLY) { today { " .. PRICE_FIELDS
  .. " } tomorrow { " .. PRICE_FIELDS .. " } } } } }"

-- Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm), so
-- timestamps parse as UTC without depending on the machine's timezone.
local function daysFromCivil(y, m, d)
  if m <= 2 then
    y = y - 1
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- ISO-8601 timestamp ("2026-11-12T14:00:00.000+01:00" or "...Z") -> epoch ms
local function parseISOms(s)
  local y, mo, d, h, mi, sec = string.match(s, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  local off = 0
  local sign, oh, om = string.match(s, "([%+%-])(%d%d):?(%d%d)%s*$")
  if sign then
    off = (tonumber(oh) or 0) * 3600 + (tonumber(om) or 0) * 60
    if sign == "-" then
      off = -off
    end
  end
  local days = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d))
  local secs = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec) - off
  return secs * 1000
end

-- GraphQL response body -> flat model, or { error = <reason> }.
local function parse(body)
  local json, err = noctalia.json.decode(body)
  if not json then
    return { error = tostring(err or "invalid JSON") }
  end
  if type(json.errors) == "table" and #json.errors > 0 then
    return { error = tostring(json.errors[1].message or "API error") }
  end
  local viewer = type(json.data) == "table" and json.data.viewer or nil
  local homes = viewer and type(viewer.homes) == "table" and viewer.homes or {}
  local home = nil
  for _, h in ipairs(homes) do
    if type(h) == "table" and h.currentSubscription then
      home = h
      break
    end
  end
  if not home then
    return { error = "no home with a subscription" }
  end
  local info = home.currentSubscription.priceInfo
  if type(info) ~= "table" then
    return { error = "no price info" }
  end
  local prices = {}
  local currency = nil
  local function add(list, day)
    if type(list) ~= "table" then
      return
    end
    for _, p in ipairs(list) do
      if type(p) == "table" and p.startsAt then
        local t = parseISOms(tostring(p.startsAt))
        if t then
          table.insert(prices, {
            t = t,
            total = tonumber(p.total) or 0,
            level = tostring(p.level or "NORMAL"),
            day = day,
          })
          if not currency and p.currency then
            currency = tostring(p.currency)
          end
        end
      end
    end
  end
  add(info.today, "today")
  add(info.tomorrow, "tomorrow")
  if #prices == 0 then
    return { error = "no prices" }
  end
  table.sort(prices, function(a, b)
    return a.t < b.t
  end)
  return {
    home = tostring(home.appNickname or home.id or "home"),
    currency = currency or "EUR",
    prices = prices,
    tomorrowReady = type(info.tomorrow) == "table" and #info.tomorrow > 0,
  }
end

-- Slot length in ms, inferred from the data (quarter-hourly or hourly).
local function slotMs(prices)
  if #prices > 1 then
    return prices[2].t - prices[1].t
  end
  return 3600000
end

local function current(prices, now)
  local len = slotMs(prices)
  for _, p in ipairs(prices) do
    if p.t <= now and now < p.t + len then
      return p
    end
  end
  return nil
end

-- min/max/avg over today's slots plus the cheapest slot still ahead.
local function stats(prices, now)
  local len = slotMs(prices)
  local today = {}
  local upcoming = {}
  for _, p in ipairs(prices) do
    if p.day == "today" then
      table.insert(today, p)
    end
    if p.t + len > now then
      table.insert(upcoming, p)
    end
  end
  local function minOf(list)
    local m = nil
    for _, p in ipairs(list) do
      if not m or p.total < m.total then
        m = p
      end
    end
    return m
  end
  local function maxOf(list)
    local m = nil
    for _, p in ipairs(list) do
      if not m or p.total > m.total then
        m = p
      end
    end
    return m
  end
  local sum = 0
  for _, p in ipairs(today) do
    sum = sum + p.total
  end
  return {
    min = minOf(today),
    max = maxOf(today),
    avg = #today > 0 and sum / #today or 0,
    next = minOf(upcoming),
  }
end

-- Chart bounds; negative prices extend the range below zero.
local function range(prices)
  local lo, hi = 0, 0
  for _, p in ipairs(prices) do
    if p.total < lo then
      lo = p.total
    end
    if p.total > hi then
      hi = p.total
    end
  end
  if hi <= lo then
    hi = lo + 1
  end
  return { lo = lo, hi = hi }
end

-- X-axis labels every 6 h on the hour: { i = 1-based slot index, label = "00" }.
local function hourTicks(prices)
  local out = {}
  for i, p in ipairs(prices) do
    local d = os.date("*t", math.floor(p.t / 1000))
    if d.min == 0 and d.hour % 6 == 0 then
      table.insert(out, { i = i, label = string.format("%02d", d.hour) })
    end
  end
  return out
end

-- Y gridline values at 1/2/5 x 10^n in the displayed unit, covering lo..hi.
-- Values are in major units; labels are already formatted for display.
local function yTicks(lo, hi, minor)
  local k = minor and 100 or 1
  local a, b = lo * k, hi * k
  local raw = (b - a) / 4
  local mag = 10 ^ math.floor(math.log(raw, 10))
  local f = raw / mag
  local best = 1
  for _, c in ipairs({ 1, 2, 5, 10 }) do
    if math.abs(math.log(f / c, 10)) < math.abs(math.log(f / best, 10)) then
      best = c
    end
  end
  local step = best * mag
  local dec = step >= 1 and 0 or (step >= 0.1 and 1 or 2)
  local out = {}
  local i = math.floor(a / step + 1e-9)
  local last = math.ceil(b / step - 1e-9)
  while i <= last do
    table.insert(out, { v = i * step / k, label = string.format("%." .. dec .. "f", i * step) })
    i = i + 1
  end
  return out
end

-- Prices normalized to 0..1 for ui.graph.
local function normValues(prices)
  local r = range(prices)
  local span = r.hi - r.lo
  local out = {}
  for _, p in ipairs(prices) do
    local v = span > 0 and (p.total - r.lo) / span or 0.5
    table.insert(out, math.min(1, math.max(0, v)))
  end
  return out
end

local MINOR_UNIT = { SEK = "öre", NOK = "øre", DKK = "øre", EUR = "ct" }

local function unitShort(currency, unit)
  if unit == "minor" then
    return MINOR_UNIT[currency] or currency
  end
  return currency
end

local function fmtPrice(total, unit)
  if unit == "minor" then
    return string.format("%.0f", math.floor(total * 100 + 0.5))
  end
  return string.format("%.2f", total)
end

-- Full display string, e.g. "23 ct" or "0.23 EUR".
local function formatPrice(total, currency, unit, showUnit)
  local v = fmtPrice(total, unit)
  if showUnit then
    return v .. " " .. unitShort(currency, unit)
  end
  return v
end

-- Tibber level -> palette role or fixed hex, as in duxtibber (success /
-- warning / error). Green and amber are semantic price levels, so they stay
-- fixed across themes; very expensive uses the palette's error role.
local LEVEL_COLOR = {
  VERY_CHEAP = "#43A047",
  CHEAP = "#66BB6A",
  NORMAL = "on_surface_variant",
  EXPENSIVE = "#FFB300",
  VERY_EXPENSIVE = "error",
}

local function levelColor(level)
  return LEVEL_COLOR[level] or LEVEL_COLOR.NORMAL
end

-- "14:00–15:00" for a slot.
local function rangeLabel(slot, prices)
  local len = slotMs(prices)
  return os.date("%H:%M", math.floor(slot.t / 1000))
    .. "–"
    .. os.date("%H:%M", math.floor((slot.t + len) / 1000))
end

return {
  API_URL = API_URL,
  DEMO_TOKEN = DEMO_TOKEN,
  QUERY = QUERY,
  parse = parse,
  slotMs = slotMs,
  current = current,
  stats = stats,
  range = range,
  hourTicks = hourTicks,
  yTicks = yTicks,
  normValues = normValues,
  fmtPrice = fmtPrice,
  unitShort = unitShort,
  formatPrice = formatPrice,
  levelColor = levelColor,
  rangeLabel = rangeLabel,
}

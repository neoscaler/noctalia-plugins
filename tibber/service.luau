--!nonstrict
-- Headless [[service]] entry: polls the Tibber demo API on an interval and
-- publishes the parsed price model to the plugin's shared state, where the
-- bar widget, panel and desktop widget watch it.
--
--   noctalia.http(...)            POST the GraphQL query (honors offline mode)
--   noctalia.state.set(key, val)   publish "tibber.prices" / "tibber.meta"
--   noctalia.state.watch(...)      "tibber.refresh" forces an immediate fetch
--
-- Failed requests are retried after 60 s (as in duxtibber) instead of waiting
-- for the full refresh interval, so a not-yet-up network recovers quickly.

local model = require("./model.luau")

local TICK_MS = 30 * 1000
local RETRY_MS = 60 * 1000

noctalia.setUpdateInterval(TICK_MS)

local nextFetch = 0
local fetching = false

local function refreshMs()
  local v = tonumber(noctalia.getConfig("refresh_minutes")) or 15
  return v * 60 * 1000
end

local function publishMeta(meta)
  noctalia.state.set("tibber.meta", meta)
end

local function fetch()
  if fetching then
    return
  end
  fetching = true
  local now = noctalia.nowMs()
  local body = noctalia.json.encode({ query = model.QUERY })
  local accepted = noctalia.http({
    url = model.API_URL,
    method = "POST",
    headers = {
      "Content-Type: application/json",
      "Authorization: Bearer " .. model.DEMO_TOKEN,
    },
    body = body or "",
  }, function(response)
    fetching = false
    local at = noctalia.nowMs()
    if response.ok and response.status == 200 then
      local parsed = model.parse(response.body)
      if parsed.error then
        nextFetch = at + RETRY_MS
        publishMeta({ ok = false, fetchedAt = at, error = parsed.error })
      else
        nextFetch = at + refreshMs()
        noctalia.state.set("tibber.prices", parsed)
        publishMeta({ ok = true, fetchedAt = at })
      end
    else
      nextFetch = at + RETRY_MS
      publishMeta({
        ok = false,
        fetchedAt = at,
        error = response.ok and ("HTTP " .. response.status) or "request failed",
      })
    end
  end)
  if not accepted then
    fetching = false
    nextFetch = now + RETRY_MS
    publishMeta({ ok = false, fetchedAt = now, error = "request rejected (offline mode?)" })
  end
end

function update()
  if noctalia.nowMs() >= nextFetch then
    fetch()
  end
end

-- UI entries set this to force a refetch (panel refresh button).
noctalia.state.watch("tibber.refresh", function()
  nextFetch = 0
end)

-- Settings changed: refetch on the next tick with the new interval.
function onConfigChanged()
  nextFetch = 0
end

publishMeta({ ok = false, fetchedAt = 0, error = "loading" })
nextFetch = 0

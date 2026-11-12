--!nonstrict
-- Price [[panel]] entry, styled after duxtibber's popout
-- (https://github.com/antonjah/duxtibber): current price on top, stat tiles
-- for the cheapest / most expensive slot of the day, and a bar chart of
-- today's (and, once published, tomorrow's) prices with a divider between
-- the days. Hovering a bar shows that slot's time, price and level.
--
--   panel.render(tree)          declarative ui.* tree
--   noctalia.state.watch(...)   live updates from the price service

local model = require("./model.luau")

local BAR_HEIGHT = 140

local prices = noctalia.state.get("tibber.prices")
local meta = noctalia.state.get("tibber.meta")
local hovered = nil -- 1-based slot index under the pointer

local function unit()
  return noctalia.getConfig("price_unit") or "minor"
end

local function showUnit()
  return noctalia.getConfig("show_unit") ~= false
end

local function priceText(total)
  return model.formatPrice(total, prices and prices.currency or "EUR", unit(), showUnit())
end

local function levelName(level)
  return noctalia.tr("ui.level." .. level)
end

local function slotRange(s)
  local len = model.slotMs(prices.prices)
  return os.date("%H:%M", math.floor(s.t / 1000)) .. "–" .. os.date("%H:%M", math.floor((s.t + len) / 1000))
end

-- Stat tile in the style of duxtibber's StatTile.qml: caption + glyph on top,
-- big value, sub line.
local function tile(label, icon, value, sub, accent)
  return ui.column({ flexGrow = 1, fill = "surface_container", radius = 10, padding = 10, gap = 2 }, {
    ui.row({ align = "center", gap = 6 }, {
      ui.label({ text = label, fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
      ui.glyph({ name = icon, size = 14, color = accent }),
    }),
    ui.label({ text = value, fontSize = 15, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
    ui.label({ text = sub, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
  })
end

local function infoText()
  if hovered and prices and prices.prices[hovered] then
    local s = prices.prices[hovered]
    return noctalia.tr("ui.slot_info", {
      day = s.day == "tomorrow" and noctalia.tr("ui.tomorrow") or noctalia.tr("ui.today"),
      from = os.date("%H:%M", math.floor(s.t / 1000)),
      to = os.date("%H:%M", math.floor((s.t + model.slotMs(prices.prices)) / 1000)),
      price = priceText(s.total) .. "/kWh",
      level = levelName(s.level),
    })
  end
  return noctalia.tr("ui.hover_hint")
end

local function bar(i, s, r, cur, st)
  local span = r.hi - r.lo
  local frac = span > 0 and (s.total - r.lo) / span or 0.5
  local props = {
    key = "slot-" .. i,
    flexGrow = 1,
    height = math.max(4, math.floor(6 + frac * (BAR_HEIGHT - 10))),
    fill = model.levelColor(s.level),
    radius = 1,
    onHover = "onSlotHover",
  }
  if cur and s.t == cur.t then
    props.border = "on_surface"
    props.borderWidth = 1.5
  elseif st.min and s.t == st.min.t then
    props.border = "#43A047"
    props.borderWidth = 1.5
  elseif st.max and s.t == st.max.t then
    props.border = "error"
    props.borderWidth = 1.5
  end
  return ui.box(props)
end

local function chart(st, cur)
  local slots = prices.prices
  local r = model.range(slots)
  local bars = {}
  for i, s in ipairs(slots) do
    table.insert(bars, bar(i, s, r, cur, st))
    if i < #slots and slots[i + 1].day ~= s.day then
      -- divider between today and tomorrow
      table.insert(bars, ui.box({ width = 2, height = BAR_HEIGHT - 6, fill = "outline_variant" }))
    end
  end
  -- hour labels aligned with the bars: one label per 6 h block, its width
  -- proportional to the number of slots in the block
  local ticks = model.hourTicks(slots)
  local labels = {}
  for k, tick in ipairs(ticks) do
    local nextI = ticks[k + 1] and ticks[k + 1].i or (#slots + 1)
    table.insert(labels, ui.label({
      text = tick.label,
      flexGrow = nextI - tick.i,
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 1,
    }))
  end
  return ui.column({ gap = 4 }, {
    ui.label({ text = infoText(), fontSize = 11, color = "on_surface_variant", height = 14, maxLines = 1 }),
    ui.row({ align = "end", gap = 1, height = BAR_HEIGHT }, bars),
    ui.row({ gap = 1 }, labels),
  })
end

local function footerText()
  if meta and meta.ok then
    return noctalia.tr("ui.demo") .. " · " .. noctalia.tr("ui.updated", {
      time = os.date("%H:%M", math.floor((meta.fetchedAt or 0) / 1000)),
    })
  end
  return noctalia.tr("ui.demo")
end

local function render()
  local now = noctalia.nowMs()
  local cur = prices and model.current(prices.prices, now) or nil
  local st = prices and model.stats(prices.prices, now) or nil
  local priceColor = cur and model.levelColor(cur.level) or "on_surface_variant"

  local headerRight = {
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("ui.refresh"),
      onClick = "onRefresh",
    }),
  }
  if noctalia.getSetting("shell.show_close_buttons") ~= false then
    table.insert(headerRight, ui.button({
      glyph = "close",
      variant = "ghost",
      controlSize = "sm",
      tooltip = noctalia.tr("ui.close"),
      onClick = "onClose",
    }))
  end

  local children = {
    ui.row({ justify = "space_between", align = "center" }, {
      ui.column({ gap = 2 }, {
        ui.label({ text = noctalia.tr("ui.title"), fontSize = 11, color = "on_surface_variant" }),
        ui.row({ gap = 8, align = "center" }, {
          ui.label({
            text = cur and priceText(cur.total) or "--",
            fontSize = 26,
            fontWeight = "bold",
            color = priceColor,
          }),
          ui.glyph({ name = "bolt", size = 18, color = priceColor }),
          ui.label({
            text = cur and levelName(cur.level) or "",
            fontSize = 12,
            color = priceColor,
          }),
        }),
      }),
      ui.row({ gap = 4, align = "center" }, headerRight),
    }),
    ui.separator({}),
  }

  if prices and st then
    local tiles = {}
    if st.min then
      table.insert(tiles, tile(
        noctalia.tr("ui.cheapest_today"),
        "trending-down",
        priceText(st.min.total),
        model.rangeLabel(st.min, prices.prices),
        model.levelColor(st.min.level)
      ))
    end
    if st.max then
      table.insert(tiles, tile(
        noctalia.tr("ui.priciest_today"),
        "trending-up",
        priceText(st.max.total),
        model.rangeLabel(st.max, prices.prices),
        model.levelColor(st.max.level)
      ))
    end
    table.insert(tiles, tile(
      noctalia.tr("ui.average_today"),
      "chart-line",
      priceText(st.avg),
      model.unitShort(prices.currency, unit()) .. "/kWh",
      "on_surface_variant"
    ))
    if st.next then
      table.insert(tiles, tile(
        noctalia.tr("ui.cheapest_next"),
        "bolt",
        priceText(st.next.total),
        model.rangeLabel(st.next, prices.prices),
        model.levelColor(st.next.level)
      ))
    end
    table.insert(children, ui.row({ gap = 8 }, tiles))
    table.insert(children, chart(st, cur))
  else
    local failed = meta and meta.ok == false and meta.fetchedAt ~= 0
    table.insert(children, ui.label({
      text = failed and noctalia.tr("ui.error", { error = tostring(meta.error or "") }) or noctalia.tr("ui.loading"),
      color = failed and "error" or "on_surface_variant",
    }))
  end

  table.insert(children, ui.row({ align = "center" }, {
    ui.label({ text = footerText(), fontSize = 10, color = "on_surface_variant", flexGrow = 1 }),
  }))

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, children))
end

function onSlotHover(state, key)
  if state == "true" then
    hovered = tonumber(string.sub(key, 6)) -- "slot-12" -> 12
  else
    hovered = nil
  end
  render()
end

function onRefresh()
  noctalia.state.set("tibber.refresh", noctalia.nowMs())
end

function onClose()
  panel.close()
end

noctalia.state.watch("tibber.prices", function(value)
  prices = value
  render()
end)

noctalia.state.watch("tibber.meta", function(value)
  meta = value
  render()
end)

function onOpen(_context)
  render()
end

function update()
  -- re-render as time moves into the next price slot
  noctalia.setUpdateInterval(30 * 1000)
  render()
end

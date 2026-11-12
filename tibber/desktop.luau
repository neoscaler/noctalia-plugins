--!nonstrict
-- Desktop [[desktop_widget]] entry: compact current price with a sparkline of
-- the day's prices and the cheapest / most expensive slot of the day. All data
-- comes from the shared price service via noctalia.state.
--
--   desktopWidget.render(tree)  declarative ui.* tree
--   noctalia.getConfig(key)     per-widget settings (color, show_chart, ...)

local model = require("./model.luau")

local prices = noctalia.state.get("tibber.prices")

local function unit()
  return noctalia.getConfig("price_unit") or "minor"
end

local function showUnit()
  return noctalia.getConfig("show_unit") ~= false
end

local function priceText(total)
  return model.formatPrice(total, prices and prices.currency or "EUR", unit(), showUnit())
end

local function render()
  local color = noctalia.getConfig("color") or "primary"
  local showChart = noctalia.getConfig("show_chart") ~= false
  local showMinMax = noctalia.getConfig("show_minmax") ~= false
  local now = noctalia.nowMs()
  local cur = prices and model.current(prices.prices, now) or nil
  local st = prices and model.stats(prices.prices, now) or nil
  local lvl = cur and model.levelColor(cur.level) or "on_surface_variant"

  local kids = {
    ui.row({ gap = 6, align = "center", justify = "center" }, {
      ui.glyph({ name = "bolt", size = 18, color = lvl }),
      ui.label({
        text = cur and priceText(cur.total) or "--",
        fontSize = 24,
        fontWeight = "bold",
        color = lvl,
      }),
    }),
  }

  if showChart and prices then
    table.insert(kids, ui.graph({
      values = model.normValues(prices.prices),
      color = color,
      fillOpacity = 0.25,
      lineWidth = 2,
      width = 180,
      height = 44,
    }))
  end

  if showMinMax and st and st.min and st.max then
    table.insert(kids, ui.label({
      text = noctalia.tr("ui.minmax", {
        min = priceText(st.min.total),
        minTime = model.rangeLabel(st.min, prices.prices),
        max = priceText(st.max.total),
        maxTime = model.rangeLabel(st.max, prices.prices),
      }),
      fontSize = 10,
      color = "on_surface_variant",
      textAlign = "center",
      maxLines = 1,
    }))
  end

  desktopWidget.render(ui.column({ gap = 6, align = "center", padding = 6 }, kids))
end

noctalia.state.watch("tibber.prices", function(value)
  prices = value
  render()
end)

function update()
  -- re-render as time moves into the next price slot
  noctalia.setUpdateInterval(60 * 1000)
  render()
end

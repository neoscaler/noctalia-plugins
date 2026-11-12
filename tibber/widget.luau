--!nonstrict
-- Bar widget [[widget]] entry: the current demo price, colored by Tibber's
-- price level. Click opens the price panel.
--
--   barWidget.render(tree)      declarative row (column on a vertical bar)
--   noctalia.togglePanel(id)    open/close the panel
--   noctalia.state.watch(...)   live updates from the price service

local model = require("./model.luau")

local PANEL_ID = "neoscaler/tibber:panel"

local prices = noctalia.state.get("tibber.prices")
local tooltipSet = false

local function unit()
  return noctalia.getConfig("price_unit") or "minor"
end

local function showUnit()
  return noctalia.getConfig("show_unit") ~= false
end

local function priceText(total)
  return model.formatPrice(total, prices and prices.currency or "EUR", unit(), showUnit())
end

local function setTooltip(text)
  barWidget.setTooltip(text)
  tooltipSet = true
end

local function clearTooltip()
  -- clearing a tooltip when there is none crashes the plugin
  if tooltipSet then
    barWidget.clearTooltip()
    tooltipSet = false
  end
end

local function render()
  local container = barWidget.isVertical() and ui.column or ui.row
  local glyph = noctalia.getConfig("glyph") or "bolt"
  local cur = prices and model.current(prices.prices, noctalia.nowMs()) or nil
  if cur then
    local color = model.levelColor(cur.level)
    local len = model.slotMs(prices.prices)
    barWidget.render(container({ gap = 6, align = "center" }, {
      ui.glyph({ name = glyph, size = 14, color = color }),
      ui.label({ text = priceText(cur.total), fontWeight = "bold", color = color }),
    }))
    setTooltip(noctalia.tr("ui.bar_tooltip", {
      price = priceText(cur.total) .. "/kWh",
      from = os.date("%H:%M", math.floor(cur.t / 1000)),
      to = os.date("%H:%M", math.floor((cur.t + len) / 1000)),
    }))
  else
    barWidget.render(container({ gap = 6, align = "center" }, {
      ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }),
      ui.label({ text = "--", color = "on_surface_variant" }),
    }))
    clearTooltip()
  end
end

noctalia.state.watch("tibber.prices", function(value)
  prices = value
  render()
end)

function update()
  -- re-render as time moves into the next price slot
  noctalia.setUpdateInterval(30 * 1000)
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

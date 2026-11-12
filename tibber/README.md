# Tibber

**Tibber** is a [Noctalia](https://docs.noctalia.dev) (v5) plugin that shows Tibber electricity
prices, styled after [duxtibber](https://github.com/antonjah/duxtibber). It uses Tibber's public
**demo data** (the demo token from the [API explorer](https://developer.tibber.com)), so no
account or token is needed.

It ships four entries driven by one headless service:

| Entry | What it does |
| --- | --- |
| Bar widget `neoscaler/tibber:bar` | Current price in the bar, colored by Tibber's price level. Click opens the panel. |
| Panel `neoscaler/tibber:panel` | Current price, stat tiles for the **cheapest** and **most expensive time of the day** (plus average and cheapest upcoming slot), and a bar chart with price axis, day filter and hover details. |
| Desktop widget `neoscaler/tibber:desktop` | Compact price tile with a sparkline and the min/max of the day. Add it from the desktop-widgets editor. |
| Service `neoscaler/tibber:prices` | Polls the API and publishes the parsed model to the plugin's shared state. |

## Usage

```sh
noctalia msg plugins source add neoscaler git https://github.com/neoscaler/noctalia-plugins
noctalia msg plugins enable neoscaler/tibber
```

Then add the bar widget from the bar's Add-widget picker (type `neoscaler/tibber:bar`), and the
desktop widget from the desktop-widgets editor (type `neoscaler/tibber:desktop`). The panel opens
on click, or via `noctalia msg panel-toggle neoscaler/tibber:panel`.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| `refresh_minutes` | `15` | Refetch interval (5 / 15 / 30 / 60). Failed requests retry after 60 s. |
| `price_unit` | `minor` | `minor` = ct/kWh (EUR) etc., `major` = EUR/kWh. |
| `show_unit` | `true` | Append the unit to prices. |
| Bar widget `glyph` | `bolt` | Glyph next to the price in the bar. |
| Desktop widget `color`, `show_chart`, `show_minmax` | `primary`, `true`, `true` | Sparkline color and which parts the tile shows. |

## Data & privacy

- The only network call is a GraphQL POST to `https://api.tibber.com/v1-beta/gql` with Tibber's
  public demo token (`3A77EE…AD7BE1-1`, from the API explorer). It returns auto-generated demo
  data only; no personal data is read or sent. Requests honor `shell.offline_mode`.
- Prices are quarter-hourly slots for today and (once published, usually after 13:00) tomorrow.
  The demo data's currency is returned by the API (SEK in the explorer's demo home) and shown
  with a matching unit.
- Price levels and colors follow Tibber's definition relative to the day's average
  (very cheap / cheap / normal / expensive / very expensive), mapped to green / amber / the
  palette's error color as in duxtibber.

## Files

```
tibber/
├── plugin.toml            # manifest: settings + service/widget/panel/desktop_widget entries
├── model.luau             # query, parsing, stats, formatting (ported from duxtibber's Tibber.js)
├── service.luau           # polls the API, publishes noctalia.state
├── widget.luau            # bar widget
├── panel.luau             # price panel (chart + min/max tiles)
├── desktop.luau           # desktop widget
└── translations/          # en, de
```

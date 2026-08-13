---
name: run-app
description: Launch Estoque OS locally, log in, and screenshot a real screen. Use when asked to run or start the app, to see a change working in the browser, or to check how a page actually looks.
---

# Running Estoque OS

A Phoenix LiveView app behind email+password auth, with Postgres in Docker on a
**non-default port**. Both of those bite if you assume the usual setup.

## Start it

```bash
docker compose ps                 # postgres must be "Up (healthy)" — port 5433, NOT 5432
docker compose up -d postgres     # if it is not
mix ecto.migrate                  # cheap, and the schema moves often
mix phx.server                    # http://localhost:4000
```

`:eaddrinuse` means a server is already running — use it rather than starting a
second one. `curl -s -o /dev/null -w "%{http_code}" http://localhost:4000/users/log-in`
returning 200 confirms it is alive.

## Get an account

There is no sign-up. Accounts are provisioned:

```bash
mix estoque.user you@example.org --role admin --password "SomePass123!"
```

Roles are `admin`, `manager`, `logistics`, `auditor` — and they see genuinely
different screens. `logistics` cannot see prices anywhere; `auditor` can see
money but cannot write. When checking a permissions change, make one account per
role rather than trusting the "view as" picker, which is read-only by design.

## Seeing a screen without a browser session

Logging in over `curl` fights LiveView's CSRF and is not worth the time. To look
at a page, render it through the app's own test stack and screenshot the HTML.
This is the real template and the real compiled CSS — only the transport differs.

1. Write a throwaway test that dumps the page:

```elixir
# test/screenshot_dump_test.exs — delete it when done
defmodule EstoqueOSWeb.ScreenshotDumpTest do
  use EstoqueOSWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import EstoqueOS.CatalogFixtures
  import EstoqueOS.InventoryFixtures

  @out System.get_env("DUMP_DIR") || "/tmp"

  setup :register_and_log_in_operator

  test "dump", %{conn: conn} do
    # ...set up whatever the screen needs to be worth looking at...
    {:ok, _view, html} = live(conn, ~p"/boxes")
    File.write!(Path.join(@out, "page.html"), html)
  end
end
```

2. Point the stylesheet at the built CSS on disk and force a theme. **The dev
   server may be down, so an `http://localhost:4000/assets/...` link silently
   loads nothing** — the giveaway is a screenshot showing one enormous SVG logo,
   which is the unstyled page.

```bash
mix assets.build   # priv/static/assets/css/app.css must be current

CSS=$PWD/priv/static/assets/css/app.css
python3 - <<PY
body = open("/tmp/page.html", encoding="utf-8").read()
body = body.replace('href="/assets/css/app.css"', 'href="file://$CSS"')
body = body.replace("<html ", '<html data-theme="light" ', 1)
open("/tmp/page_light.html", "w", encoding="utf-8").write(body)
PY
```

3. Screenshot with the Playwright chromium already on this machine:

```bash
~/.cache/ms-playwright/chromium-*/chrome-linux64/chrome \
  --headless --disable-gpu --no-sandbox --allow-file-access-from-files \
  --hide-scrollbars --force-device-scale-factor=2 --window-size=1280,900 \
  --screenshot=/tmp/page.png "file:///tmp/page_light.html"
```

Then **Read the PNG and actually look at it.** Check the phone width too —
`--window-size=390,1500`. This app is used one-handed in a warehouse, and the
data table renders as a completely different shape below `md`.

`light` is the default theme (bright office, daylit warehouse); `dark` exists
for badly lit mission storage rooms. Headless chromium picks dark on its own, so
set `data-theme` explicitly or you will review the wrong one.

## Resetting

```bash
mix ecto.reset      # drop + create + migrate + seeds.exs (322 products, 3 locations, 5 kits)
mix dev.seeds       # optional: the fuller scenario with boxes, stock and a mission
```

`ecto.reset` drops **all users** — recreate an account afterwards or you cannot
log in. Stop `mix phx.server` first or the drop blocks on its connections.

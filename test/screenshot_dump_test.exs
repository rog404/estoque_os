defmodule EstoqueOSWeb.ScreenshotDumpTest do
  use EstoqueOSWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @out System.get_env("DUMP_DIR") || "/tmp"

  setup :register_and_log_in_operator

  test "dump", %{conn: conn} do
    EstoqueOS.Seeds.run()
    EstoqueOS.DemoData.run()

    for {name, path} <- [
          {"home", ~p"/"},
          {"stock", ~p"/stock"},
          {"boxes", ~p"/boxes"},
          {"locations", ~p"/locations"},
          {"issue", ~p"/issue"},
          {"invoices", ~p"/invoices"}
        ] do
      {:ok, _view, html} = live(conn, path)
      File.write!(Path.join(@out, "#{name}.html"), html)
    end
  end
end

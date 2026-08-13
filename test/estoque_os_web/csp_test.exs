defmodule EstoqueOSWeb.CSPTest do
  @moduledoc """
  The theme script in the root layout has to run before first paint, or the page
  flashes light before going dark. It cannot move into `app.js`, so the policy
  cannot forbid inline scripts outright — it carries a per-request nonce instead
  of `unsafe-inline`, which would have permitted every injected script equally.

  The nonce is only worth anything if the header and the tag agree, which is what
  these check.
  """

  use EstoqueOSWeb.ConnCase, async: true

  test "every page declares a policy", %{conn: conn} do
    conn = get(conn, ~p"/users/log-in")

    assert [policy] = get_resp_header(conn, "content-security-policy")

    assert policy =~ "default-src 'self'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "frame-ancestors 'none'"
  end

  test "the inline theme script carries the nonce the header allows", %{conn: conn} do
    conn = get(conn, ~p"/users/log-in")

    [policy] = get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, policy)

    assert html_response(conn, 200) =~ ~s(<script nonce="#{nonce}">)
  end

  test "the nonce is not reused between requests", %{conn: conn} do
    nonce = fn ->
      [policy] = conn |> get(~p"/users/log-in") |> get_resp_header("content-security-policy")
      Regex.run(~r/'nonce-([^']+)'/, policy) |> List.last()
    end

    # A nonce that repeats is a nonce an attacker can guess from a previous page.
    refute nonce.() == nonce.()
  end
end

defmodule EstoqueOSWeb.CSPTest do
  @moduledoc """
  The inline theme script must run before first paint, so the policy carries a
  per-request nonce instead of `unsafe-inline`. The nonce only works if the
  header and the tag agree.
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

    refute nonce.() == nonce.()
  end
end

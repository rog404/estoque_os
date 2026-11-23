defmodule EstoqueOS.DatabaseSSLTest do
  @moduledoc """
  What the production database connection demands of the certificate.
  `config/runtime.exs` only runs at release boot, so `Config.Reader` evaluates
  the real file here in each of its four modes.
  """

  # Reads and writes real environment variables.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO, only: [with_io: 1, with_io: 2]

  @vars ~w(DATABASE_URL SECRET_KEY_BASE PHX_HOST DATABASE_SSL DATABASE_SSL_VERIFY
           DATABASE_CA_CERT_FILE)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  # Everything a release needs to boot, minus the one variable under test.
  defp repo_config(env) do
    Enum.each(@vars, &System.delete_env/1)

    System.put_env(
      Map.merge(
        %{
          "DATABASE_URL" => "ecto://user:pass@dpg-abc-a/estoque_os",
          "SECRET_KEY_BASE" => String.duplicate("x", 64),
          "PHX_HOST" => "example.com"
        },
        env
      )
    )

    config = Config.Reader.read!("config/runtime.exs", env: :prod)
    config[:estoque_os][EstoqueOS.Repo]
  end

  test "by default the certificate must be real and must name the host we dialled" do
    ssl = quietly(%{"DATABASE_URL" => "ecto://u:p@db.example.com/x"})[:ssl]

    assert ssl[:verify] == :verify_peer
    assert ssl[:cacerts] != nil
    assert ssl[:server_name_indication] == ~c"db.example.com"

    assert ssl[:customize_hostname_check][:match_fun] ==
             :public_key.pkix_verify_hostname_match_fun(:https)
  end

  describe "DATABASE_SSL_VERIFY=ca" do
    test "keeps the chain check and drops only the hostname" do
      ssl = quietly(%{"DATABASE_SSL_VERIFY" => "ca"})[:ssl]

      assert ssl[:verify] == :verify_peer
      assert ssl[:cacerts] != nil

      # Render's internal `dpg-…-a` endpoint answers with a certificate issued
      # for `*.virginia-postgres.render.com`, so any name must be accepted.
      assert ssl[:customize_hostname_check][:match_fun].(:anything, :at_all)
    end

    test "says so once, without pretending to be a crash" do
      {out, err} = say(%{"DATABASE_SSL_VERIFY" => "ca"})

      assert out =~ "DATABASE_SSL_VERIFY=ca"
      assert out =~ "hostname is not"

      # Not `IO.warn`: its stacktrace reads as a boot exception in the deploy log.
      assert err == ""
    end

    test "prefers a CA file when one is given, over the system store" do
      ssl =
        quietly(%{
          "DATABASE_SSL_VERIFY" => "ca",
          "DATABASE_CA_CERT_FILE" => "/etc/secrets/ca.crt"
        })[:ssl]

      assert ssl[:cacertfile] == "/etc/secrets/ca.crt"
      assert ssl[:cacerts] == nil
    end
  end

  test "DATABASE_SSL_VERIFY=none checks nothing, and shouts" do
    assert quietly(%{"DATABASE_SSL_VERIFY" => "none"})[:ssl][:verify] == :verify_none

    {_out, err} = say(%{"DATABASE_SSL_VERIFY" => "none"})

    # A warning on stderr, but one line and no `IO.warn` stacktrace: this is the
    # standing configuration on Render, and a fake exception every boot hides a real one.
    assert err =~ "not being checked at all"
    refute err =~ "erl_eval"
    assert length(String.split(String.trim(err), "\n")) == 1
  end

  test "DATABASE_SSL=false turns it off entirely, and shouts" do
    assert quietly(%{"DATABASE_SSL" => "false"})[:ssl] == false

    {_out, err} = say(%{"DATABASE_SSL" => "false"})
    assert err =~ "in the clear"
  end

  # Postgrex logs a deprecation on every boot for `ssl: true` beside `:ssl_opts`.
  test "never uses the deprecated :ssl_opts" do
    for env <- [%{}, %{"DATABASE_SSL_VERIFY" => "ca"}, %{"DATABASE_SSL_VERIFY" => "none"}] do
      refute Keyword.has_key?(quietly(env), :ssl_opts)
    end
  end

  defp quietly(env) do
    {{config, _out}, _err} = with_io(:stderr, fn -> with_io(fn -> repo_config(env) end) end)
    config
  end

  defp say(env) do
    {{_config, out}, err} = with_io(:stderr, fn -> with_io(fn -> repo_config(env) end) end)
    {out, err}
  end
end

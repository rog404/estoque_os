defmodule EstoqueOS.DatabaseSSLTest do
  @moduledoc """
  What the production database connection demands of the certificate on the
  other end.

  `config/runtime.exs` is the only place in this repository that decides it, it
  runs nowhere but a release boot, and getting it wrong fails in two directions
  that both cost a deploy: too strict and the app cannot reach its database at
  all, too loose and the connection is an encrypted conversation with whoever
  answered.

  So the file is read here, in each of its four modes, and asked what it
  produced. Not a mock — `Config.Reader` evaluates the real file.
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

    # The real check, not a stand-in that says yes.
    assert ssl[:customize_hostname_check][:match_fun] ==
             :public_key.pkix_verify_hostname_match_fun(:https)
  end

  describe "DATABASE_SSL_VERIFY=ca" do
    test "keeps the chain check and drops only the hostname" do
      ssl = quietly(%{"DATABASE_SSL_VERIFY" => "ca"})[:ssl]

      assert ssl[:verify] == :verify_peer
      assert ssl[:cacerts] != nil

      # This is the whole of verify-ca: any name the certificate carries is
      # accepted, because Render's internal `dpg-…-a` endpoint answers with a
      # certificate issued for `*.virginia-postgres.render.com`.
      assert ssl[:customize_hostname_check][:match_fun].(:anything, :at_all)
    end

    test "says so once, without pretending to be a crash" do
      {out, err} = say(%{"DATABASE_SSL_VERIFY" => "ca"})

      assert out =~ "DATABASE_SSL_VERIFY=ca"
      assert out =~ "hostname is not"

      # Nothing on stderr, which is where `IO.warn` writes — and `IO.warn`
      # prints a stacktrace under the message, so in a deploy log it reads as an
      # exception during boot. A setting somebody chose is not a fault.
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

    # On stderr every boot, because it is a warning. But one line and no
    # stacktrace: `IO.warn` prints one, and this is the standing configuration
    # on Render rather than a lapse somebody is about to correct — a line that
    # reads as an exception on every boot is how a real crash goes unnoticed.
    assert err =~ "not being checked at all"
    refute err =~ "erl_eval"
    assert length(String.split(String.trim(err), "\n")) == 1
  end

  test "DATABASE_SSL=false turns it off entirely, and shouts" do
    assert quietly(%{"DATABASE_SSL" => "false"})[:ssl] == false

    {_out, err} = say(%{"DATABASE_SSL" => "false"})
    assert err =~ "in the clear"
  end

  # The options belong in `:ssl`. `ssl: true` beside a separate `:ssl_opts` is
  # the older spelling, and Postgrex logged a deprecation for it twice on every
  # boot — two lines of noise in the log a real error has to be found in.
  test "never uses the deprecated :ssl_opts" do
    for env <- [%{}, %{"DATABASE_SSL_VERIFY" => "ca"}, %{"DATABASE_SSL_VERIFY" => "none"}] do
      refute Keyword.has_key?(quietly(env), :ssl_opts)
    end
  end

  # The config, with whatever the file says on its way out swallowed.
  defp quietly(env) do
    {{config, _out}, _err} = with_io(:stderr, fn -> with_io(fn -> repo_config(env) end) end)
    config
  end

  # The other half: what it said, on each device, and nothing about the config.
  defp say(env) do
    {{_config, out}, err} = with_io(:stderr, fn -> with_io(fn -> repo_config(env) end) end)
    {out, err}
  end
end

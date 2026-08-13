defmodule EstoqueOS.Accounts.LoginThrottle do
  @moduledoc """
  Makes repeated failed logins progressively slower.

  Sign-up is closed and roles are granted deliberately, so the only way into this
  system is a password on an account somebody created by hand. That makes the
  login form the entire attack surface, and until now it answered as fast as the
  network allowed, forever.

  The delay grows with the failures rather than locking an account outright.
  Locking is what an attacker wants when the goal is to keep the coordinator out
  on the morning a mission ships — a growing wait costs a guesser everything and
  costs somebody who mistyped their password fifteen seconds.

  Two counters, and both must clear, but they are not equally strict. By email,
  because that is the account being guessed at. By address as a backstop, and
  much looser: this operation has a handful of accounts behind one office
  connection, so a strict address counter means whoever mistypes first locks out
  everybody else. With three accounts in existence, spraying across emails is not
  an attack worth optimising against — the email counter already catches it.

  Held in ETS rather than in the database: this is a single machine with two
  users, and a failed password should not cost a write. It resets on restart,
  which an attacker cannot cause.
  """

  use GenServer

  @table :login_throttle
  # Failures, and how long the next attempt has to wait. Under three, nothing:
  # people mistype.
  @email_steps [{3, 15}, {5, 60}, {7, 300}, {10, 1_800}]

  # An address is a whole office. It only speaks up for volume no human produces.
  @address_steps [{30, 60}, {60, 900}]
  @forget_after_seconds 3_600

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  `:ok`, or `{:error, seconds}` telling the caller how long is left to wait.
  """
  def check(keys) when is_list(keys) do
    keys
    |> Enum.map(&remaining/1)
    |> Enum.max(fn -> 0 end)
    |> case do
      0 -> :ok
      seconds -> {:error, seconds}
    end
  end

  @doc "Counts a failure against every key it was tried under."
  def record_failure(keys) when is_list(keys) do
    now = System.system_time(:second)

    Enum.each(keys, fn key ->
      failures = failures_for(key, now) + 1
      :ets.insert(@table, {normalize(key), failures, now})
    end)

    :ok
  end

  @doc "Forgets a key, which is what a successful login should do."
  def clear(keys) when is_list(keys) do
    Enum.each(keys, &:ets.delete(@table, normalize(&1)))
    :ok
  end

  defp remaining(key) do
    now = System.system_time(:second)

    case :ets.lookup(@table, normalize(key)) do
      [] ->
        0

      [{_key, failures, last_failure_at}] ->
        wait = wait_for(elem(key, 0), failures)
        elapsed = now - last_failure_at

        if elapsed >= wait, do: 0, else: wait - elapsed
    end
  end

  defp failures_for(key, now) do
    case :ets.lookup(@table, normalize(key)) do
      # An hour of quiet wipes the slate: somebody who got it wrong this morning
      # is not a suspect this afternoon.
      [{_key, _failures, last}] when now - last > @forget_after_seconds -> 0
      [{_key, failures, _last}] -> failures
      [] -> 0
    end
  end

  defp wait_for(kind, failures) do
    steps(kind)
    |> Enum.filter(fn {threshold, _seconds} -> failures >= threshold end)
    |> Enum.map(fn {_threshold, seconds} -> seconds end)
    |> Enum.max(fn -> 0 end)
  end

  defp steps(:address), do: @address_steps
  defp steps(_email), do: @email_steps

  defp normalize({kind, value}),
    do: {kind, value |> to_string() |> String.downcase() |> String.trim()}

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.system_time(:second) - @forget_after_seconds
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @forget_after_seconds * 1_000)
end

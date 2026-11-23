defmodule EstoqueOS.Accounts.LoginThrottleTest do
  @moduledoc """
  Sign-up is closed, so the login form is the whole attack surface. The delay
  grows rather than locking the account, because locking is what an attacker wants.
  """

  use ExUnit.Case, async: false

  alias EstoqueOS.Accounts.LoginThrottle

  setup do
    keys = [{:email, "someone-#{System.unique_integer([:positive])}@example.com"}]
    on_exit(fn -> LoginThrottle.clear(keys) end)
    %{keys: keys}
  end

  test "says nothing about the first couple of mistakes", %{keys: keys} do
    assert LoginThrottle.check(keys) == :ok

    LoginThrottle.record_failure(keys)
    LoginThrottle.record_failure(keys)

    assert LoginThrottle.check(keys) == :ok
  end

  test "starts waiting at the third", %{keys: keys} do
    Enum.each(1..3, fn _ -> LoginThrottle.record_failure(keys) end)

    assert {:error, seconds} = LoginThrottle.check(keys)
    assert seconds > 0 and seconds <= 15
  end

  test "the wait grows with the guessing", %{keys: keys} do
    Enum.each(1..3, fn _ -> LoginThrottle.record_failure(keys) end)
    {:error, first} = LoginThrottle.check(keys)

    Enum.each(1..4, fn _ -> LoginThrottle.record_failure(keys) end)
    {:error, later} = LoginThrottle.check(keys)

    assert later > first
  end

  test "getting in clears the slate", %{keys: keys} do
    Enum.each(1..5, fn _ -> LoginThrottle.record_failure(keys) end)
    assert {:error, _} = LoginThrottle.check(keys)

    LoginThrottle.clear(keys)

    assert LoginThrottle.check(keys) == :ok
  end

  test "either key can hold the door", %{keys: [email_key]} do
    address = {:address, "203.0.113.#{System.unique_integer([:positive])}"}
    on_exit(fn -> LoginThrottle.clear([address]) end)

    # A guesser walking a list of emails never trips the email counter, so the
    # address counts too, loosely: it is a whole office.
    Enum.each(1..30, fn _ -> LoginThrottle.record_failure([address]) end)

    assert {:error, _} = LoginThrottle.check([email_key, address])
  end

  test "the email is matched however it was typed", %{keys: [{:email, email}] = keys} do
    Enum.each(1..3, fn _ -> LoginThrottle.record_failure(keys) end)

    assert {:error, _} = LoginThrottle.check([{:email, "  #{String.upcase(email)} "}])
  end
end

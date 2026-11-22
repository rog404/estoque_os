defmodule EstoqueOS.Accounts.Scope do
  @moduledoc """
  The caller of a public interface: the user, plus an optional borrowed role
  (`view_as`) for admins.
  """

  alias EstoqueOS.Accounts.User
  alias EstoqueOS.Catalog.Product

  defstruct user: nil, view_as: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  An admin looking at the app the way another role sees it.

  Deliberately a *role*, not a person: borrowing an identity would misattribute
  ledger transactions, which record who did them.

  Only an admin may take one on, and never a role above their own.
  """
  def viewing_as(%__MODULE__{user: %User{role: "admin"}} = scope, role) do
    if role in User.roles() and role != "admin" do
      %{scope | view_as: role}
    else
      scope
    end
  end

  def viewing_as(scope, _role), do: scope

  @doc "Drops the borrowed role and goes back to being yourself."
  def as_self(%__MODULE__{} = scope), do: %{scope | view_as: nil}

  @doc """
  The role that decides what this scope may see.

  Writing is a separate question: while `view_as` is set, nothing may be
  written at all, whatever the borrowed role would allow.
  """
  def effective_role(%__MODULE__{view_as: role}) when is_binary(role), do: role
  def effective_role(%__MODULE__{user: %User{role: role}}), do: role
  def effective_role(_scope), do: nil

  @doc """
  The stock this scope's screens open on.

  Read from the *effective* role. A default, not a fence: see
  `EstoqueOS.Accounts.User.default_segment/1`.
  """
  def default_segment(%__MODULE__{} = scope) do
    scope |> effective_role() |> User.default_segment()
  end

  def default_segment(_scope), do: nil

  @doc """
  The stock a page is about: what it asked for, or the role's own when it asked
  for nothing.

  `"all"` means both stocks; without it there is no way back to the whole
  operation once a default is in place.
  """
  def segment(%__MODULE__{} = scope, asked) do
    cond do
      asked in Product.segments() -> asked
      asked == "all" -> nil
      true -> default_segment(scope)
    end
  end

  def segment(_scope, _asked), do: nil

  @doc "Whether this scope is standing in somebody else's shoes."
  def viewing_as?(%__MODULE__{view_as: role}) when is_binary(role), do: true
  def viewing_as?(_scope), do: false
end

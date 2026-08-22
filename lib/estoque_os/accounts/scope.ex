defmodule EstoqueOS.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `EstoqueOS.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
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

  Deliberately a *role*, not a person. Borrowing somebody's identity would put
  their name on whatever happened next, and every transaction here records who
  did it — the ledger is the product, and a ledger that misattributes is worse
  than no ledger. Standing in a role answers the question that was actually
  asked ("what does the auditor see?") without ever needing an identity to
  borrow.

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

  Read from the *effective* role, so an admin standing in the marketing role's
  shoes lands where that role lands — which is the point of being able to stand
  in it.

  A default and not a fence: see `EstoqueOS.Accounts.User.default_segment/1`.
  Everybody may look at either stock; this is which one is already ticked when
  the screen opens.
  """
  def default_segment(%__MODULE__{} = scope) do
    scope |> effective_role() |> User.default_segment()
  end

  def default_segment(_scope), do: nil

  @doc """
  The stock a page is about: what it asked for, or the role's own when it asked
  for nothing.

  `"all"` is a real answer and means both stocks — the tab that says "Tudo".
  Without it there would be no way back to the whole operation once a default
  is in place, and a coordinator reading one stock's numbers as if they were
  the operation's is the mistake this screen exists to prevent.
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

defmodule EstoqueOSWeb.ViewAsController do
  @moduledoc """
  An admin standing in another role's shoes, to see what that person sees.

  Roles decide two different things now — what may be changed and what may be
  seen — and the second is invisible from the inside. An admin cannot tell by
  looking whether the logistics operator's stock screen still shows a price, and
  the honest ways to find out are keeping four accounts and a private window, or
  this.

  Three properties make it safe to have:

    * **A role, never a person.** Nobody's identity is borrowed, so nothing can
      be written under somebody else's name.
    * **Read-only, whatever the role allows.** `UserAuth.operator?/1` returns
      false the whole time. Every transaction in this system records who made
      it, and a ledger that misattributes is worse than no ledger.
    * **Never upward.** Only an admin may start, and `admin` is not one of the
      roles that can be borrowed, so this can only ever reduce what is visible.

  Kept in the session rather than on the user, so it dies with the browser and
  can never be left switched on for somebody else to find.
  """

  use EstoqueOSWeb, :controller

  alias EstoqueOS.Accounts.{Scope, User}

  def create(conn, %{"role" => role}) do
    scope = conn.assigns[:current_scope]

    cond do
      !admin?(scope) ->
        conn
        |> put_flash(:error, gettext("You don't have permission to do that."))
        |> redirect(to: ~p"/")

      role not in User.roles() or role == "admin" ->
        conn
        |> put_flash(:error, gettext("That is not a role you can view as."))
        |> redirect(to: ~p"/")

      true ->
        conn
        |> put_session(:view_as, role)
        |> put_flash(:info, gettext("You are now seeing the app as %{role}.", role: label(role)))
        |> redirect(to: ~p"/")
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:view_as)
    |> put_flash(:info, gettext("Back to your own account."))
    |> redirect(to: ~p"/")
  end

  defp admin?(%Scope{user: %User{role: "admin"}}), do: true
  defp admin?(_scope), do: false

  @doc """
  The role's name, in the words the operation uses for these people.

  A role names a job, not a person, so the Portuguese stays in the unmarked
  form: whoever holds it may be a man or a woman, and the label outlives
  whoever holds it today.
  """
  def label("manager"), do: gettext("stock manager")
  def label("logistics"), do: gettext("logistics operator")
  def label("auditor"), do: gettext("auditor")
  def label("admin"), do: gettext("administrator")
  def label(role), do: role
end

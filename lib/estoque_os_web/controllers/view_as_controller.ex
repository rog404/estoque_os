defmodule EstoqueOSWeb.ViewAsController do
  @moduledoc """
  An admin views the app as another role, to check what that role sees.

    * **A role, never a person**: nothing is written under someone else's name.
    * **Read-only**: `UserAuth.operator?/1` is false throughout, since every
      transaction records who made it.
    * **Never upward**: only an admin may start, and `admin` cannot be borrowed.

  Kept in the session, not on the user, so it dies with the browser.
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
  The role's name, in the operation's words. Names a job, not a person, so the
  Portuguese stays in the unmarked form.
  """
  def label("manager"), do: gettext("stock manager")
  def label("marketing"), do: gettext("marketing manager")
  def label("logistics"), do: gettext("logistics operator")
  def label("auditor"), do: gettext("auditor")
  def label("admin"), do: gettext("administrator")
  def label(role), do: role
end

defmodule EstoqueOSWeb.UserLive.Index do
  @moduledoc """
  Who has an account, and the only door through which a new one opens: an
  admin vouches for an email and a role, and hands over a password that
  works exactly once before it must be replaced.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Accounts
  alias EstoqueOS.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Users"))
     |> assign(:error, nil)
     |> assign(:created, nil)
     |> load_users()}
  end

  defp load_users(socket), do: assign(socket, :users, Accounts.list_users())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <.header>
        {gettext("Users")}
        <:subtitle>{gettext("Who has an account, and what they may do with it.")}</:subtitle>
      </.header>

      <div :if={@created} class="alert alert-success mt-4 flex-col items-start gap-2">
        <p class="font-semibold">
          {gettext("Temporary password for %{email}", email: @created.email)}
        </p>
        <p class="text-sm">
          {gettext(
            "Shown once — pass it on yourself (WhatsApp, in person). It will not be shown again, and it must be replaced on first login."
          )}
        </p>
        <code class="select-all bg-base-100 text-base-content rounded px-2 py-1 text-sm">
          {@created.password}
        </code>
      </div>

      <form id="new-user" phx-submit="create" class="field-row mt-4">
        <label class="fieldset grow min-w-64">
          <span class="label">{gettext("Email")}</span>
          <input
            type="email"
            name="email"
            placeholder="nome@exemplo.org"
            class="input input-bordered w-full"
            required
          />
        </label>
        <label class="fieldset">
          <span class="label">{gettext("Role")}</span>
          <select name="role" class="select select-bordered">
            <option :for={role <- User.roles()} value={role}>{role_label(role)}</option>
          </select>
        </label>
        <.button variant="primary">{gettext("Create user")}</.button>
      </form>

      <p :if={@error} class="alert alert-error mt-3">{@error}</p>

      <.data_table rows={@users} row_id={&"user-#{&1.id}"} class="mt-6">
        <:col :let={user} label={gettext("Email")} emphasis={:identity}>
          {user.email}
        </:col>
        <:col :let={user} label={gettext("Role")}>{role_label(user.role)}</:col>
        <:col :let={user} label={gettext("Status")}>
          <.status
            :if={user.must_reset_password}
            kind={:pending}
            detail={gettext("Awaiting first password")}
          />
          <.status :if={!user.must_reset_password} kind={:complete} detail={gettext("Active")} />
        </:col>
        <:col :let={user} label={gettext("Created")} align={:right}>
          {Calendar.strftime(user.inserted_at, "%d/%m/%Y")}
        </:col>
        <:empty>
          <.empty
            title={gettext("No user registered yet.")}
            note={gettext("Create the first one above.")}
          />
        </:empty>
      </.data_table>
    </Layouts.app>
    """
  end

  # The labels already spoken elsewhere (the "view as" menu) — reused rather
  # than retranslated under a second msgid that could drift from this one.
  defp role_label(role), do: EstoqueOSWeb.ViewAsController.label(role)

  @impl true
  def handle_event("create", %{"email" => email, "role" => role}, socket) do
    case Accounts.create_user_with_temporary_password(String.trim(email), role) do
      {:ok, {user, password}} ->
        {:noreply,
         socket
         |> assign(:error, nil)
         |> assign(:created, %{email: user.email, password: password})
         |> load_users()}

      {:error, changeset} ->
        {:noreply, assign(socket, :error, first_error(changeset))}
    end
  end

  defp first_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
    |> List.first()
    |> Kernel.||(gettext("That user could not be created."))
  end
end

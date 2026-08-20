defmodule EstoqueOSWeb.UserLive.Settings do
  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Your own account is yours to change whatever your role is. These write, and
  are meant to.
  """
  def viewer_events, do: ~w(validate_email update_email validate_password update_password)

  on_mount {EstoqueOSWeb.UserAuth, :require_sudo_mode}

  alias EstoqueOS.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div class="text-center">
        <.header>
          {gettext("Account Settings")}
          <:subtitle>
            <%= if @email_enabled? do %>
              {gettext("Manage your account email address and password settings")}
            <% else %>
              {gettext("Change your password. Ask an administrator to change your email.")}
            <% end %>
          </:subtitle>
        </.header>
      </div>

      <.form
        :if={@email_enabled?}
        for={@email_form}
        id="email_form"
        phx-submit="update_email"
        phx-change="validate_email"
      >
        <.input
          field={@email_form[:email]}
          type="email"
          label={gettext("Email")}
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with={gettext("Changing...")}>
          {gettext("Change Email")}
        </.button>
      </.form>

      <div :if={@email_enabled?} class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label={gettext("New password")}
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label={gettext("Confirm new password")}
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with={gettext("Saving...")}>
          {gettext("Save Password")}
        </.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  # Confirming an address change. Lives in the settings live_session rather
  # than the gated `:email_flows` one because it needs sudo mode, so the
  # no-mailer case is checked here instead of in the router.
  def mount(%{"token" => token}, _session, socket) when is_binary(token) do
    if Accounts.email_enabled?() do
      confirm_email_change(token, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, email_disabled_message())
       |> push_navigate(to: ~p"/users/settings")}
    end
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:email_enabled?, Accounts.email_enabled?())
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  defp confirm_email_change(token, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, gettext("Email changed successfully."))

        {:error, _} ->
          put_flash(socket, :error, gettext("Email change link is invalid or it has expired."))
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    # The form is not rendered when there is no mailer, but a socket can still
    # be sent the event. Confirming an address by emailing it is the whole
    # mechanism here, so with no mailer there is nothing to fall back to.
    if Accounts.email_enabled?() do
      case Accounts.change_user_email(user, user_params) do
        %{valid?: true} = changeset ->
          Accounts.deliver_user_update_email_instructions(
            Ecto.Changeset.apply_action!(changeset, :insert),
            user.email,
            &url(~p"/users/settings/confirm-email/#{&1}")
          )

          info =
            gettext("A link to confirm your email change has been sent to the new address.")

          {:noreply, put_flash(socket, :info, info)}

        changeset ->
          {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
      end
    else
      {:noreply, put_flash(socket, :error, email_disabled_message())}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  defp email_disabled_message do
    gettext("This installation does not send email. Ask an administrator to change your address.")
  end
end

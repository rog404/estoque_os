defmodule EstoqueOSWeb.UserLive.Settings do
  use EstoqueOSWeb, :live_view

  @doc """
  Events a viewer may send. Everything else on this screen is refused.

  Your own account is yours to change whatever your role is. These write, and
  are meant to.
  """
  def viewer_events, do: ~w(validate_email update_email validate_password update_password)

  # No `:require_sudo_mode` on the screen, deliberately, and this is a bug fix
  # rather than a relaxation.
  #
  # It was gated at ten minutes, so ten minutes after signing in, clicking
  # "Configurações" answered with the login page. Reported as a bug, and read as
  # one: you were still signed in everywhere else, so the app looked like it had
  # forgotten you at random. Nothing on this screen is secret — it is your own
  # address and two empty forms.
  #
  # What *is* sensitive is submitting one, and that is still checked, at the
  # twenty minutes the account code has always used. The difference is that a
  # lapsed window now disables the button and says why, which is the pattern
  # every other guarded control in this app already follows.

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
        <.button
          variant="primary"
          disabled={not @confirmed_recently?}
          title={sudo_block(assigns)}
          phx-disable-with={gettext("Changing...")}
        >
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
        <.button
          variant="primary"
          disabled={not @confirmed_recently?}
          title={sudo_block(assigns)}
          phx-disable-with={gettext("Saving...")}
        >
          {gettext("Save Password")}
        </.button>
      </.form>

      <!-- Said once, above the forms it applies to, rather than discovered by
           pressing a dead button. There is no mailer here — accounts are handed
           out by an administrator — so "sign in again" is the whole of the
           remedy and the message says exactly that. -->
      <p :if={not @confirmed_recently?} class="alert alert-warning mt-6">
        {gettext(
          "For your own security, changing your email or password needs a fresh sign-in. Log out and in again, and come back here."
        )}
      </p>
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
      # Twenty minutes, the window the account code has always used for a
      # sensitive change. Read once on mount and again when a submission is
      # refused, which is the only moment it can have lapsed while somebody was
      # looking at the screen.
      |> assign(:confirmed_recently?, Accounts.sudo_mode?(user))

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

    # `true = Accounts.sudo_mode?(user)` was here, and it was the second half of
    # the same bug: the window could lapse between opening the screen and
    # pressing the button, and then this raised a MatchError. A crashed
    # LiveView explains nothing to the person who just typed a password.

    # The form is not rendered when there is no mailer, but a socket can still
    # be sent the event. Confirming an address by emailing it is the whole
    # mechanism here, so with no mailer there is nothing to fall back to.
    cond do
      not Accounts.sudo_mode?(user) ->
        {:noreply,
         socket |> assign(:confirmed_recently?, false) |> put_flash(:error, sudo_message())}

      not Accounts.email_enabled?() ->
        {:noreply, put_flash(socket, :error, email_disabled_message())}

      true ->
        change_email(socket, user, user_params)
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

    if Accounts.sudo_mode?(user) do
      update_password(socket, user, user_params)
    else
      {:noreply,
       socket |> assign(:confirmed_recently?, false) |> put_flash(:error, sudo_message())}
    end
  end

  defp update_password(socket, user, user_params) do
    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  defp change_email(socket, user, user_params) do
    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = gettext("A link to confirm your email change has been sent to the new address.")

        {:noreply, put_flash(socket, :info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  # Why the two buttons are disabled, or nil when they are not — the same shape
  # `write_block/1` has for every other guarded control in the app.
  defp sudo_block(%{confirmed_recently?: true}), do: nil
  defp sudo_block(_assigns), do: sudo_message()

  defp sudo_message do
    gettext("Log out and in again to change your email or password.")
  end

  defp email_disabled_message do
    gettext("This installation does not send email. Ask an administrator to change your address.")
  end
end

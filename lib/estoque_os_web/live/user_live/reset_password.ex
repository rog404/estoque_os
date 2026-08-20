defmodule EstoqueOSWeb.UserLive.ResetPassword do
  @moduledoc """
  The only door left for setting a password: request a link by email, follow
  it, choose a new one. Also where a temporary password gets replaced on
  first login — same form, no token in the URL, because the session already
  proves who this is.
  """

  use EstoqueOSWeb, :live_view

  alias EstoqueOS.Accounts

  @impl true
  def render(%{live_action: :new} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>{gettext("Forgot your password?")}</p>
            <:subtitle>
              {gettext("Tell us your email and we'll send a link to set a new one.")}
            </:subtitle>
          </.header>
        </div>

        <.form :let={f} for={@form} id="reset_password_form" phx-submit="send_instructions">
          <.input
            field={f[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button variant="primary" class="w-full" phx-disable-with={gettext("Sending...")}>
            {gettext("Send instructions")}
          </.button>
        </.form>

        <div class="text-center">
          <.link navigate={~p"/users/log-in"} class="link link-hover text-sm">
            {gettext("Back to log in")}
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def render(%{live_action: :edit} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>{gettext("Set a new password")}</.header>
        </div>

        <.form
          :let={f}
          for={@form}
          id="reset_password_edit_form"
          action={~p"/users/reset-password/#{@token}"}
          method="post"
          phx-change="validate"
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={f[:password]}
            type="password"
            label={gettext("New password")}
            autocomplete="new-password"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={f[:password_confirmation]}
            type="password"
            label={gettext("Confirm new password")}
            autocomplete="new-password"
            spellcheck="false"
          />
          <.button variant="primary" class="w-full" phx-disable-with={gettext("Saving...")}>
            {gettext("Save password")}
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  def render(%{live_action: :required} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={assigns[:current_path]}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>{gettext("Set a new password")}</p>
            <:subtitle>
              {gettext(
                "This account was created with a temporary password. Choose one only you know before continuing."
              )}
            </:subtitle>
          </.header>
        </div>

        <.form
          :let={f}
          for={@form}
          id="reset_password_required_form"
          action={~p"/users/update-password"}
          method="post"
          phx-change="validate"
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={f[:password]}
            type="password"
            label={gettext("New password")}
            autocomplete="new-password"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={f[:password_confirmation]}
            type="password"
            label={gettext("Confirm new password")}
            autocomplete="new-password"
            spellcheck="false"
          />
          <.button variant="primary" class="w-full" phx-disable-with={gettext("Saving...")}>
            {gettext("Save password")}
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{live_action: :new}} = socket) do
    {:ok, assign(socket, form: to_form(%{"email" => nil}, as: "user"))}
  end

  def mount(%{"token" => token}, _session, %{assigns: %{live_action: :edit}} = socket) do
    if Accounts.get_user_by_reset_password_token(token) do
      {:ok,
       socket
       |> assign(:token, token)
       |> assign(:trigger_submit, false)
       |> assign(:form, to_form(%{"password" => nil, "password_confirmation" => nil}, as: "user"))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("The link is invalid or it has expired."))
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  def mount(_params, _session, %{assigns: %{live_action: :required}} = socket) do
    {:ok,
     socket
     |> assign(:trigger_submit, false)
     |> assign(:form, to_form(%{"password" => nil, "password_confirmation" => nil}, as: "user"))}
  end

  @impl true
  def handle_event("send_instructions", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_reset_password_instructions(
        user,
        &url(~p"/users/reset-password/#{&1}")
      )
    end

    info =
      gettext(
        "If your email is in our system, you will receive instructions to reset your password shortly."
      )

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    form =
      %Accounts.User{}
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("submit", %{"user" => user_params}, socket) do
    {:noreply, assign(socket, form: to_form(user_params, as: "user"), trigger_submit: true)}
  end
end

defmodule EstoqueOSWeb.ErrorJSON do
  @moduledoc """
  Error responses for JSON requests (see config/config.exs).
  """

  # Status message from the template name: "404.json" becomes "Not Found".
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end

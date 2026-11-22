defmodule EstoqueOSWeb.ErrorHTML do
  @moduledoc """
  Error pages for HTML requests (see config/config.exs).
  """
  use EstoqueOSWeb, :html

  # Plain text from the template name: "404.html" becomes "Not Found".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end

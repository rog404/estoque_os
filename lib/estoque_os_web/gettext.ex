defmodule EstoqueOSWeb.Gettext do
  @moduledoc """
  Gettext backend: `use Gettext, backend: EstoqueOSWeb.Gettext`.
  """
  use Gettext.Backend, otp_app: :estoque_os
end

defmodule EstoqueOS.Repo do
  use Ecto.Repo,
    otp_app: :estoque_os,
    adapter: Ecto.Adapters.Postgres
end

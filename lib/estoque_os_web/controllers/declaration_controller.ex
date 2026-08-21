defmodule EstoqueOSWeb.DeclarationController do
  @moduledoc """
  Prints the declaração de conteúdo that travels with a load.

  A4-styled HTML rather than a generated PDF, for the same reason as the
  donation certificates: the warehouse notebook has a browser and no guarantee
  of anything else, and Ctrl+P → "Salvar como PDF" produces the same file with
  no second binary to install or keep patched.

  Only a load whose declaration has been written gets one. A blank paper with
  the ONG's letterhead on it is a document waiting to say something untrue.
  """

  use EstoqueOSWeb, :controller

  alias EstoqueOS.Outbound

  plug :put_layout, false

  def print(conn, %{"id" => id}) do
    shipment = Outbound.get_shipment!(id)

    case Outbound.get_declaration(shipment) do
      nil ->
        conn
        |> put_flash(:error, gettext("Fill the declaration in before printing it."))
        |> redirect(to: ~p"/shipments/#{shipment.id}/declaracao")

      declaration ->
        contents = Outbound.shipment_contents(shipment)

        render(conn, :declaration,
          shipment: shipment,
          declaration: declaration,
          contents: contents,
          totals: Outbound.contents_total(contents),
          organization: Application.get_env(:estoque_os, :organization, []),
          page_title: gettext("Content declaration")
        )
    end
  end
end

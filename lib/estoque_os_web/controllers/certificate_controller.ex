defmodule EstoqueOSWeb.CertificateController do
  @moduledoc """
  Prints the two certificates a donation needs: the termo de doação the ONG
  signs, and the termo de recebimento the hospital signs back.

  A4-styled HTML, not generated PDFs: a mission notebook has only a browser, and
  Ctrl+P produces the PDF.

  Only an issue that actually went to a donation gets one; anything else would
  certify something that never happened.
  """

  use EstoqueOSWeb, :controller

  alias EstoqueOS.Inventory

  plug :put_layout, false

  def certificate(conn, %{"id" => id, "kind" => kind}) when kind in ~w(doacao recebimento) do
    case Inventory.get_donation_issue(id) do
      nil ->
        conn
        |> put_flash(:error, gettext("That movement is not a donation."))
        |> redirect(to: ~p"/issues")

      transaction ->
        render(conn, :certificate,
          transaction: transaction,
          totals: Inventory.issue_totals(transaction),
          organization: Application.get_env(:estoque_os, :organization, []),
          kind: kind,
          page_title: title_for(kind)
        )
    end
  end

  def certificate(conn, _params), do: redirect(conn, to: ~p"/issues")

  defp title_for("doacao"), do: gettext("Donation certificate")
  defp title_for("recebimento"), do: gettext("Receipt certificate")
end

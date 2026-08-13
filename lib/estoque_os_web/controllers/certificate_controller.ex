defmodule EstoqueOSWeb.CertificateController do
  @moduledoc """
  Prints the two certificates a donation needs: the termo de doação the ONG
  signs, and the termo de recebimento the hospital signs back.

  They are A4-styled HTML rather than generated PDFs on purpose: a mission
  notebook has a browser and no guarantee of anything else, and Ctrl+P →
  "Salvar como PDF" produces the same file without another binary to install.

  Built from the movement itself, now that a donation is an ordinary manual
  issue rather than its own record. Only an issue that actually went to a
  donation gets one — a certificate for goods that went to the PACU would be a
  document claiming something that never happened.
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

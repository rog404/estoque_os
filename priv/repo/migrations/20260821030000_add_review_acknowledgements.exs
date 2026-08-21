defmodule EstoqueOS.Repo.Migrations.AddReviewAcknowledgements do
  @moduledoc """
  Somebody looked, and said it is fine.

  Two things in this system raise a flag and then have nowhere to go: a count
  that disagreed twice, and a lot that arrived with no lot number. Both are
  correct to raise, and both are sometimes the answer — the box really did have
  27, the volunteer's blanket really has no lot printed on it. Without a way to
  close them, the list only ever grows, and a list that only grows stops being
  read, which costs exactly the alarms that mattered.

  Closing one is not deleting it. The flag stays on the row and the
  acknowledgement is recorded beside it: who said it was fine and when. That is
  the whole point — the alert leaves the screen and the fact that somebody
  accepted a divergence stays in the ledger, where an auditor asking "who
  signed off on this" gets a name.
  """

  use Ecto.Migration

  def change do
    alter table(:transactions) do
      add :review_acknowledged_at, :utc_datetime
      add :review_acknowledged_by_id, references(:users, on_delete: :nilify_all)
      add :review_acknowledgement, :text
    end

    alter table(:lots) do
      add :review_acknowledged_at, :utc_datetime
      add :review_acknowledged_by_id, references(:users, on_delete: :nilify_all)
    end

    # The two lists these feed are "what is still open", so the index is on the
    # open ones. A partial index stays small however many acknowledgements pile
    # up behind it.
    create index(:transactions, [:review_acknowledged_at],
             where: "review_reason IS NOT NULL AND review_acknowledged_at IS NULL",
             name: :transactions_open_reviews
           )

    create index(:lots, [:review_acknowledged_at],
             where: "needs_review AND review_acknowledged_at IS NULL",
             name: :lots_open_reviews
           )
  end
end

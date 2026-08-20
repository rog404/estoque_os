defmodule EstoqueOS.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(admin manager marketing logistics auditor)

  @doc """
  Known user roles, from most to least privileged.

  Five, because this operation has five kinds of person and they need different
  answers to three different questions — what may I change, what may I see, and
  *which stock is mine*.

    * `admin` — everything, plus who else gets an account.
    * `manager` — the supplies coordinator. The whole operation, money included.
    * `marketing` — looks after the marketing stock and nothing else. Writes
      and sees money, both only about products in their own segment: they sell
      what they hold, so a price is the point rather than a leak.
    * `logistics` — the third-party operator who handles the boxes: counts,
      load-outs, returns. Never a price: they are a partner outside the ONG and
      the spreadsheet they return has always carried quantity and box and never
      what anything cost.
    * `auditor` — reads everything, money and ledger included, and writes
      nothing.

  The order is a rough privilege ranking and nothing reads it as one, because
  no ranking works: `roles_that_write/0`, `roles_that_see_money/0` and
  `segment/1` cut the list three different ways. Logistics writes and does not
  see; auditor sees and does not write; marketing does both and only within
  one segment. A single ladder cannot express that.
  """
  def roles, do: @roles

  @doc """
  The stock a role is allowed to see, or `nil` for all of it.

  The whole of the marketing role's confinement is this function plus the
  callers that pass it into a query. It is deliberately *not* expressed as
  "hide the rows in the template": a filter in a query cannot be undone by an
  event nobody rendered a button for.
  """
  def segment("marketing"), do: "marketing"
  def segment(_role), do: nil

  @doc "Roles allowed to change stock."
  def roles_that_write, do: ~w(admin manager marketing logistics)

  @doc """
  Roles allowed to change what the catalog *says*, as opposed to what the
  shelves hold.

  A third question, and not a rung above the other two. The logistics operator
  records what physically happened and may not touch the minimum a mission is
  expected to carry — that is a planning decision, argued with the ONG team,
  and a number the dashboard raises alarms from. The auditor is the mirror
  image: they read everything, including prices, and change nothing.

  Marketing is out too, and for a plainer reason: what this gate protects — kit
  recipes and the minimum a mission carries — is surgical planning, and none of
  it is about their stock.
  """
  def roles_that_plan, do: ~w(admin manager)

  @doc """
  Roles allowed to see what anything cost.

  Marketing is here and logistics is not, which looks inconsistent until you
  read what each of them is: the logistics partner is outside the ONG and the
  prices are the ONG's, while marketing *sells* the goods they hold — the price
  on the way out is the thing they are accountable for. And they only ever see
  their own segment.
  """
  def roles_that_see_money, do: ~w(admin manager marketing auditor)

  schema "users" do
    field :email, :string
    field :role, :string, default: "auditor"
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true
    field :must_reset_password, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, EstoqueOS.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # If using Bcrypt, then further validate it is at most 72 bytes long
      |> validate_length(:password, max: 72, count: :bytes)
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
      # A password set anywhere — the forced first-login change, or "esqueci
      # minha senha" — is exactly the event that clears the requirement.
      # Placed in this branch, not in `password_changeset/3` itself, so a live
      # "validate as you type" call (`hash_password: false`) or a failed
      # submission never touches the flag.
      |> put_change(:must_reset_password, false)
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the role. Only admins may apply it.
  """
  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
    |> check_constraint(:role, name: :users_role_must_be_known)
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%EstoqueOS.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end

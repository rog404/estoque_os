defmodule EstoqueOS.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(admin manager marketing logistics auditor)

  @doc """
  Known user roles, from most to least privileged.

    * `admin` — everything, plus who gets an account.
    * `manager` — the supplies coordinator; money included.
    * `marketing` — the marketing stock; writes and sees money, they sell what they hold.
    * `logistics` — third-party box operator (counts, load-outs, returns); never a price.
    * `auditor` — reads everything, writes nothing.

  The order is not a privilege ladder: `roles_that_write/0`,
  `roles_that_see_money/0` and `default_segment/1` cut the list differently.
  """
  def roles, do: @roles

  @doc """
  The stock a role works in, or `nil` for a role with no particular one.

  A **default**, not a fence: everybody may look at either stock; the role
  decides which one the screen opens on. What a role may *do* is still a fence
  (`roles_that_write/0`, `roles_that_plan/0`, `roles_that_see_money/0`).
  """
  def default_segment("marketing"), do: "marketing"
  def default_segment(role) when is_binary(role), do: "medical"
  def default_segment(_role), do: nil

  @doc "Roles allowed to change stock."
  def roles_that_write, do: ~w(admin manager marketing logistics)

  @doc """
  Roles allowed to change what the catalog *says*, as opposed to what the
  shelves hold.

  Logistics records what physically happened but may not change kit recipes or
  the minimum a mission carries (a planning decision the dashboard alarms from).
  Marketing is out too: that planning is surgical, not about their stock.
  """
  def roles_that_plan, do: ~w(admin manager)

  @doc """
  Roles that handle the boxes: putting stock into one, moving one, counting one.

  Marketing is not here: boxes are the surgical operation's. Exists for screens
  shared with marketing (a product's own page).
  """
  def roles_that_box, do: ~w(admin manager logistics)

  @doc """
  Roles allowed to see what anything cost.

  Marketing sees prices (they sell what they hold); logistics is outside the
  ONG and does not.
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
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # Bcrypt truncates past 72 bytes.
      |> validate_length(:password, max: 72, count: :bytes)
      # Not in prepare_changes/2: that would hold the transaction open while hashing.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
      # Any real password set clears the requirement. Only in this branch, so
      # live validation (`hash_password: false`) or a failed submit never touches it.
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

defmodule Consigliere.SqliteConstraints do
  @moduledoc false

  # SQLite reports a foreign-key violation as a bare "FOREIGN KEY constraint
  # failed" with no constraint/column name at all (unlike Postgres), so
  # ecto_sqlite3's adapter can only ever return {:foreign_key, nil}.
  # Ecto.Changeset.foreign_key_constraint/3 always compares against a
  # non-nil string name and can never match that, so it would raise
  # Ecto.ConstraintError instead of returning {:error, changeset}. This
  # replicates Ecto's own constraint-registration shape with the
  # constraint value forced to nil so the exact-match succeeds.
  def foreign_key_constraint(changeset, field, opts \\ []) do
    if Ecto.Changeset.get_field(changeset, field) do
      message = Keyword.get(opts, :message, "does not exist")

      constraint = %{
        constraint: nil,
        error_message: message,
        error_type: :foreign,
        field: field,
        match: :exact,
        type: :foreign_key
      }

      %{changeset | constraints: [constraint | changeset.constraints]}
    else
      changeset
    end
  end
end

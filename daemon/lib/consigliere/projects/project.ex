defmodule Consigliere.Projects.Project do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "projects" do
    field(:name, :string)
    field(:repository_path, :string)
    field(:repository_url, :string)
    field(:default_branch, :string, default: "main")
    field(:trusted_mirror_path, :string)
    field(:dispatch_policy, :map, default: %{})
    field(:validation_policy, :map, default: %{})
    field(:integration_policy, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @required [:name, :repository_url, :default_branch, :trusted_mirror_path]
  @optional [:repository_path, :dispatch_policy, :validation_policy, :integration_policy]

  def changeset(project, attrs) do
    project
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:repository_url)
  end
end

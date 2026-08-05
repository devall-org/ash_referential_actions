defmodule AshBorrow.Borrowable do
  @moduledoc """
  Marker extension for resources that can be borrowed.

  Provides the `borrowed_by` relationship entity: the reverse side of a
  `borrows` edge. The compiled relationship is a regular
  `Ash.Resource.Relationships.HasMany` carrying a `:__borrowed_by__` marker.

  `borrowed_by` intentionally supports no `filter` entity: the archive guard
  relies on it to enumerate every borrower, which a filtered relationship
  could not guarantee.
  """

  @borrowed_by %Spark.Dsl.Entity{
    name: :borrowed_by,
    describe: """
    Declares the reverse side of a `borrows` edge: the resources that borrow
    this resource.

    Compiles to a `has_many`. The destination must have a matching `borrows`
    relationship pointing back at this resource.
    """,
    examples: [
      """
      borrowed_by :documents, Document
      """
    ],
    no_depend_modules: [:destination],
    target: Ash.Resource.Relationships.HasMany,
    schema: Ash.Resource.Relationships.HasMany.opt_schema(),
    transform: {__MODULE__, :transform, []},
    args: [:name, :destination]
  }

  use Spark.Dsl.Extension,
    dsl_patches: [
      %Spark.Dsl.Patch.AddEntity{section_path: [:relationships], entity: @borrowed_by}
    ],
    transformers: [AshBorrow.Borrowable.AddGuard]

  @doc false
  def transform(has_many) do
    with {:ok, has_many} <- Ash.Resource.Relationships.HasMany.transform(has_many) do
      {:ok, Map.put(has_many, :__borrowed_by__, true)}
    end
  end
end

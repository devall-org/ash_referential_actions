defmodule AshReferentialActions.Postgres do
  @moduledoc """
  Applies AshReferentialActions semantics to PostgreSQL foreign keys.
  """

  use Spark.Dsl.Extension,
    add_extensions: [AshReferentialActions],
    transformers: [AshReferentialActions.Transformers.ConfigurePostgresReferences],
    verifiers: [AshReferentialActions.Verifiers.PostgresReferences]
end

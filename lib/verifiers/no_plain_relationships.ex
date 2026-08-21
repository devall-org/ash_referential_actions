defmodule AshReferentialActions.Verifiers.NoPlainRelationships do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Ash.Resource.Relationships.{BelongsTo, HasMany, HasOne}
  alias Spark.Dsl.Verifier

  @relationship_types [BelongsTo, HasMany, HasOne]

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.find_value(&error(module, &1))
    |> case do
      nil -> :ok
      error -> {:error, error}
    end
  end

  defp error(module, %kind{} = rel) when kind in @relationship_types do
    action = AshReferentialActions.Info.action(rel)

    cond do
      is_nil(action) ->
        dsl_error(module, rel, """
        Plain #{relationship_type(rel)} is forbidden on resources using AshReferentialActions.
        Declare `cascade_#{relationship_type(rel)}`, `restrict_#{relationship_type(rel)}`, \
        `nilify_#{relationship_type(rel)}`, or `view_#{relationship_type(rel)}`.
        """)

      action == :nilify and match?(%BelongsTo{allow_nil?: false}, rel) ->
        dsl_error(module, rel, "nilify_belongs_to must allow nil")

      action != :view and reverse?(rel) and not clean_reverse?(rel) ->
        dsl_error(
          module,
          rel,
          "#{action}_#{relationship_type(rel)} must be unfiltered and attributable"
        )

      true ->
        nil
    end
  end

  defp error(_module, _rel), do: nil

  defp reverse?(%kind{}) when kind in [HasMany, HasOne], do: true
  defp reverse?(_), do: false

  defp clean_reverse?(rel) do
    not Map.get(rel, :no_attributes?, false) and is_nil(Map.get(rel, :manual)) and
      Map.get(rel, :filters, []) == []
  end

  defp relationship_type(%BelongsTo{}), do: "belongs_to"
  defp relationship_type(%HasMany{}), do: "has_many"
  defp relationship_type(%HasOne{}), do: "has_one"

  defp dsl_error(module, rel, message) do
    Spark.Error.DslError.exception(
      module: module,
      path: [:relationships, rel.name],
      message: message
    )
  end
end

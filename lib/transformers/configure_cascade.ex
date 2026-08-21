defmodule AshReferentialActions.Transformers.ConfigureCascade do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.Relationships.{HasMany, HasOne}
  alias Spark.Dsl.Transformer

  @setup_archival AshArchival.Resource.Transformers.SetupArchival

  @impl true
  def before?(@setup_archival), do: true
  def before?(_), do: false

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    explicit = AshArchival.Resource.Info.archive_archive_related!(dsl_state)

    if explicit != [] do
      {:error,
       "AshReferentialActions generates archive_related; remove the explicit value #{inspect(explicit)}"}
    else
      cascade =
        dsl_state
        |> Ash.Resource.Info.relationships()
        |> Enum.filter(&cascade_reverse?/1)
        |> Enum.map(& &1.name)
        |> apply_archive_last(archive_last(dsl_state))

      {:ok, Transformer.set_option(dsl_state, [:archive], :archive_related, cascade)}
    end
  end

  defp cascade_reverse?(%kind{} = rel) when kind in [HasMany, HasOne],
    do: AshReferentialActions.Info.cascade?(rel)

  defp cascade_reverse?(_rel), do: false

  defp archive_last(dsl_state) do
    Spark.Dsl.Extension.get_opt(
      dsl_state,
      [:referential_actions],
      :archive_last,
      [],
      true
    )
  end

  defp apply_archive_last(names, []), do: names

  defp apply_archive_last(names, last) do
    case last -- names do
      [] -> Enum.reject(names, &(&1 in last)) ++ last
      unknown -> raise "archive_last contains non-cascade relationships: #{inspect(unknown)}"
    end
  end
end

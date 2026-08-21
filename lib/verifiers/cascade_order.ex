defmodule AshReferentialActions.Verifiers.CascadeOrder do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    archive_related = AshArchival.Resource.Info.archive_archive_related!(dsl_state)
    edges = restrict_edges(dsl_state, archive_related)

    if violated?(edges, archive_related) do
      module = Verifier.get_persisted(dsl_state, :module)

      {:error,
       Spark.Error.DslError.exception(
         module: module,
         path: [:referential_actions, :archive_last],
         message: """
         Cascade order archives restricted resources before their referrers.
         Set `referential_actions.archive_last` to:

           archive_last [#{Enum.map_join(suggestion(edges, archive_related), ", ", &":#{&1}")}]
         """
       )}
    else
      :ok
    end
  end

  defp restrict_edges(dsl_state, archive_related) do
    subtrees =
      Map.new(archive_related, fn name ->
        destinations =
          case relationship(dsl_state, name) do
            nil -> MapSet.new()
            relationship -> cascade_subtree(relationship.destination)
          end

        {name, destinations}
      end)

    for {referrer_name, referrer_resources} <- subtrees,
        {restricted_name, restricted_resources} <- subtrees,
        restricted_name != referrer_name,
        restricts_any?(referrer_resources, restricted_resources),
        uniq: true do
      {referrer_name, restricted_name}
    end
  end

  defp cascade_subtree(resource, seen \\ MapSet.new()) do
    if MapSet.member?(seen, resource) do
      seen
    else
      seen = MapSet.put(seen, resource)

      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(fn relationship ->
        reverse?(relationship) and AshReferentialActions.Info.cascade?(relationship)
      end)
      |> Enum.reduce(seen, fn relationship, seen ->
        cascade_subtree(relationship.destination, seen)
      end)
    end
  end

  defp restricts_any?(referrer_resources, restricted_resources) do
    Enum.any?(referrer_resources, fn resource ->
      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.any?(fn relationship ->
        match?(%Ash.Resource.Relationships.BelongsTo{}, relationship) and
          AshReferentialActions.Info.restrict?(relationship) and
          MapSet.member?(restricted_resources, relationship.destination)
      end)
    end)
  end

  defp reverse?(%kind{})
       when kind in [Ash.Resource.Relationships.HasMany, Ash.Resource.Relationships.HasOne],
       do: true

  defp reverse?(_relationship), do: false

  defp violated?(edges, names) do
    position = names |> Enum.with_index() |> Map.new()
    Enum.any?(edges, fn {before, after_} -> position[before] > position[after_] end)
  end

  defp suggestion(edges, names) do
    nodes = edges |> Enum.flat_map(&Tuple.to_list/1) |> Enum.uniq()

    predecessors =
      Enum.reduce(edges, Map.new(nodes, &{&1, MapSet.new()}), fn {before, after_}, acc ->
        Map.update!(acc, after_, &MapSet.put(&1, before))
      end)

    nodes
    |> Enum.sort_by(&Enum.find_index(names, fn name -> name == &1 end))
    |> topo_sort(predecessors, [])
  end

  defp topo_sort([], _predecessors, acc), do: Enum.reverse(acc)

  defp topo_sort(remaining, predecessors, acc) do
    set = MapSet.new(remaining)

    case Enum.find(remaining, &MapSet.disjoint?(predecessors[&1], set)) do
      nil -> Enum.reverse(acc) ++ remaining
      name -> topo_sort(remaining -- [name], predecessors, [name | acc])
    end
  end

  defp relationship(dsl_state, name) do
    dsl_state
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == name))
  end
end

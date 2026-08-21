defmodule AshReferentialActions.Archival do
  @moduledoc """
  Applies AshReferentialActions semantics to soft destroys implemented by AshArchival.
  """

  @referential_actions %Spark.Dsl.Section{
    name: :referential_actions,
    describe: "Configures ordering for generated archival cascades.",
    schema: [
      archive_last: [
        type: {:wrap_list, :atom},
        required: false,
        default: [],
        doc: "Cascade relationships to archive last, in the given order."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@referential_actions],
    add_extensions: [AshReferentialActions, AshArchival.Resource],
    transformers: [
      AshReferentialActions.Transformers.AddNilifyActions,
      AshReferentialActions.Transformers.AddSourceGuard,
      AshReferentialActions.Transformers.AddDestroyChanges,
      AshReferentialActions.Transformers.ConfigureCascade
    ],
    verifiers: [
      AshReferentialActions.Verifiers.ArchivalGuardChannels,
      AshReferentialActions.Verifiers.CascadeDestinations,
      AshReferentialActions.Verifiers.CascadeOrder
    ]
end

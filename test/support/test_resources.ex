defmodule AshOwnership.Test.Support.TestResources do
  @moduledoc false

  alias AshOwnership.Test.Support.TestResources

  defmodule Snapshot do
    @moduledoc false
    use Ash.Resource, domain: nil, extensions: [AshOwnership]

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults [:read]
    end

    relationships do
      used_by(:docs, TestResources.Doc)
    end
  end

  defmodule Doc do
    @moduledoc false
    use Ash.Resource, domain: nil, extensions: [AshOwnership]

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults [:read]
    end

    relationships do
      uses(:snapshot, TestResources.Snapshot)
    end
  end
end

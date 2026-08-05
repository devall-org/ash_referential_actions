defmodule AshBorrow.Test.Support.TestResources do
  @moduledoc false

  alias AshBorrow.Test.Support.TestResources

  defmodule Snapshot do
    @moduledoc false
    use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrowable]

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults [:read]
    end

    relationships do
      borrowed_by(:docs, TestResources.Doc)
    end
  end

  defmodule Doc do
    @moduledoc false
    use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults [:read]
    end

    relationships do
      borrows(:snapshot, TestResources.Snapshot)
    end
  end
end

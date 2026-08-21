defmodule AshReferentialActions.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshReferentialActions.Test.Resources.CascadeParent
    resource AshReferentialActions.Test.Resources.CascadeChild
    resource AshReferentialActions.Test.Resources.RestrictTarget
    resource AshReferentialActions.Test.Resources.RestrictLocker
    resource AshReferentialActions.Test.Resources.NilifyTarget
    resource AshReferentialActions.Test.Resources.NilifyReferrer
  end
end

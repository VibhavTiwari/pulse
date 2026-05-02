defmodule Pulse.Repo do
  use Ecto.Repo,
    otp_app: :pulse,
    adapter: Ecto.Adapters.Postgres
end

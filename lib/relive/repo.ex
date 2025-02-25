defmodule Relive.Repo do
  use Ecto.Repo,
    otp_app: :relive,
    adapter: Ecto.Adapters.Postgres
end

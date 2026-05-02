defmodule Pulse.ChangesetHelpers do
  import Ecto.Changeset

  @record_states ~w(suggested accepted rejected)

  def validate_record_state(changeset) do
    validate_inclusion(changeset, :record_state, @record_states)
  end

  def validate_trimmed_required(changeset, fields) do
    changeset
    |> validate_required(fields)
    |> then(fn changeset ->
      Enum.reduce(fields, changeset, fn field, acc ->
        validate_change(acc, field, fn ^field, value ->
          if is_binary(value) and String.trim(value) == "" do
            [{field, "can't be blank"}]
          else
            []
          end
        end)
      end)
    end)
  end
end

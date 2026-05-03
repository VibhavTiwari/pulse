defmodule Pulse.Briefs.Brief do
  use Pulse.Schema
  import Ecto.Changeset
  import Pulse.ChangesetHelpers

  @types ~w(daily)
  @required_sections ~w(what_changed needs_attention)
  @evidence_states ~w(strong weak none mixed)

  schema "briefs" do
    belongs_to :workspace, Pulse.Workspaces.Workspace
    field :title, :string
    field :brief_date, :date
    field :brief_type, :string, default: "daily"
    field :summary, :string
    field :sections, :map, default: %{}

    many_to_many :decisions, Pulse.Decisions.Decision, join_through: "brief_decisions"
    many_to_many :commitments, Pulse.Commitments.Commitment, join_through: "brief_commitments"
    many_to_many :risks, Pulse.Risks.Risk, join_through: "brief_risks"
    many_to_many :meetings, Pulse.Meetings.Meeting, join_through: "brief_meetings"

    timestamps()
  end

  def changeset(brief, attrs) do
    brief
    |> cast(attrs, [:workspace_id, :title, :brief_date, :brief_type, :summary, :sections])
    |> validate_trimmed_required([:workspace_id, :title, :brief_date, :brief_type, :summary])
    |> validate_inclusion(:brief_type, @types)
    |> validate_required_sections()
    |> validate_section_items()
  end

  defp validate_required_sections(changeset) do
    sections = get_field(changeset, :sections) || %{}

    if Enum.all?(@required_sections, &Map.has_key?(sections, &1)) do
      changeset
    else
      add_error(changeset, :sections, "must include what_changed and needs_attention")
    end
  end

  defp validate_section_items(changeset) do
    sections = get_field(changeset, :sections) || %{}

    errors =
      sections
      |> Map.take(@required_sections)
      |> Enum.flat_map(fn {section, items} -> invalid_items(section, items) end)

    if errors == [] do
      changeset
    else
      Enum.reduce(errors, changeset, fn message, acc -> add_error(acc, :sections, message) end)
    end
  end

  defp invalid_items(section, items) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      cond do
        not is_map(item) ->
          ["#{section}[#{index}] must be an object"]

        blank?(item["title"]) or blank?(item["body"]) or blank?(item["item_type"]) ->
          ["#{section}[#{index}] must include title, body, and item_type"]

        item["section"] != section ->
          ["#{section}[#{index}] has an invalid section"]

        item["evidence_state"] not in @evidence_states ->
          ["#{section}[#{index}] has an invalid evidence_state"]

        true ->
          []
      end
    end)
  end

  defp invalid_items(section, _items), do: ["#{section} must be a list"]

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")
end

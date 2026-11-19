defmodule Xitdb.Features.CompressionSpec do
  use Xitdb.FeatureCase, async: true

  @long_body String.duplicate(
               "Dear CAASA Partner, please review your quarterly holdings report. ",
               25
             )
  @template_head "<!DOCTYPE html><html><head><style>.mail{font-family:sans-serif;}</style></head><body><div class=\"mail\">"
  @template_tail "</div><footer>Confidentiality Notice: Internal Compliance Communication.</footer></body></html>"
  @dict_body @template_head <> "Portfolio rebalance notice for Account #4021." <> @template_tail
  @dict_samples Enum.map(1..20, fn i ->
                  @template_head <>
                    "Portfolio rebalance notice for Account ##{i}." <> @template_tail
                end)

  scenario "transparent :zlib and :zstd compression round-trip across Access, select, pull, and materialize" do
    @given memory_database()
    @given committed_moment(%{
             "emails" => %{
               "e1" => %{
                 "subject" => "Q4 Statement",
                 "body" => {:compressed, @long_body, codec: :zlib},
                 "html" => {:compressed, @long_body, codec: :zstd}
               }
             }
           })

    @upon navigating_access_path(:body_via_access, ["emails", "e1", "body"])
    @upon navigating_access_path(:html_via_access, ["emails", "e1", "html"])
    @upon selecting_path(:body_via_select, ".emails.e1.body")
    @upon selecting_path(:body_raw_tag, ".emails.e1.body", raw_tagged: true)
    @upon selecting_path(:html_raw_tag, ".emails.e1.html", raw_tagged: true)
    @upon pulling_projection(:pulled_email, ["emails", "e1"], "{subject, body, html}")
    @upon pulling_projection(:pulled_raw, ["emails", "e1"], "{body, html}", raw_tagged: true)
    @upon materializing_path(:mat_email, ["emails", "e1"])

    @then resolved_value_is(:body_via_access, @long_body)
    @then resolved_value_is(:html_via_access, @long_body)
    @then resolved_value_is(:body_via_select, @long_body)
    @then resolved_tag_is(:body_raw_tag, "cz")
    @then resolved_tag_is(:html_raw_tag, "zs")
    @then resolved_value_is(
            :pulled_email,
            %{"subject" => "Q4 Statement", "body" => @long_body, "html" => @long_body}
          )
    @then resolved_value_is(:mat_email, %{
            "subject" => "Q4 Statement",
            "body" => @long_body,
            "html" => @long_body
          })
    @then access_path_equals(["emails", "e1", "body"], @long_body)
  end

  scenario "trained shared dictionary and content-addressed __blobs interning preserve historical snapshots" do
    @given memory_database()
    @given trained_compression_dictionary(:email_html, @dict_samples, target_size: 4_096)
    @given committed_moment(%{
             "emails" => %{
               "m1" => {:compressed, @dict_body, dictionary: :email_html},
               "m2" => {:compressed, @long_body, intern: true, codec: :zstd},
               "m3" => {:compressed, @long_body, intern: true, codec: :zstd}
             }
           })
    @given pinned_snapshot(:v1, 1)
    @given committed_moment(%{
             "emails" => %{
               "m1" => "Short manual override"
             }
           })

    @upon selecting_path(:m1_raw_v1, "@1.emails.m1", raw_tagged: true)
    @upon selecting_path(:m2_raw, ".emails.m2", raw_tagged: true)
    @upon navigating_access_path(:m2_body, ["emails", "m2"])
    @upon navigating_access_path(:m3_body, ["emails", "m3"])

    @then snapshot_access_path_equals(:v1, ["emails", "m1"], @dict_body)
    @then access_path_equals(["emails", "m1"], "Short manual override")
    @then resolved_tag_is(:m1_raw_v1, "zd")
    @then resolved_tag_is(:m2_raw, "bp")
    @then resolved_value_is(:m2_body, @long_body)
    @then resolved_value_is(:m3_body, @long_body)
    @then enumerable_count_is(["__blobs"], 1)
  end

  scenario "parquet-style row-group pages support single-page random lookup, zero-decompression pull, and immutable updates" do
    @given memory_database()
    @given columnar_rows_committed(
             "activities",
             Enum.map(1..160, fn i ->
               {Integer.to_string(i),
                %{
                  "id" => i,
                  "title" => "Activity ##{i}",
                  "header_properties" => "X-Source=Creatio; X-Folder=Inbox",
                  "body" => @template_head <> "Email payload ##{i}" <> @template_tail
                }}
             end),
             columns: [:body, :header_properties],
             row_group_size: 64,
             codec: :zstd
           )
    @given pinned_snapshot(:before_edit, 0)

    @upon resetting_columnar_probe()
    @upon pulling_projection(:meta_only, ["activities", "10"], "{id, title}")
    @then resolved_value_is(:meta_only, %{"id" => 10, "title" => "Activity #10"})
    @then columnar_page_reads_are(0)

    @upon navigating_access_path(:body_row_70, ["activities", "70", "body"])
    @then resolved_value_is(:body_row_70, @template_head <> "Email payload #70" <> @template_tail)
    @then columnar_page_reads_are(1)

    @upon selecting_path(:raw_pointer, ~s(.activities["70"].body), raw_tagged: true)
    @then resolved_tag_is(:raw_pointer, "pg")

    @upon transacting_with_cursor(fn root ->
            put_in(
              root["activities"]["70"]["body"],
              {:compressed, @template_head <> "Edited #70" <> @template_tail,
               codec: :zlib, min_bytes: 0}
            )
          end)
    @then access_path_equals(
            ["activities", "70", "body"],
            @template_head <> "Edited #70" <> @template_tail
          )
    @then snapshot_access_path_equals(
            :before_edit,
            ["activities", "70", "body"],
            @template_head <> "Email payload #70" <> @template_tail
          )
  end

  scenario "diff_moments compares decoded values across compressed moments while hiding internal storage roots" do
    @given memory_database()
    @given trained_compression_dictionary(:email_html, @dict_samples, target_size: 4_096)
    @given committed_moment(%{
             "emails" => %{
               "a" => {:compressed, @long_body, codec: :zlib},
               "b" => {:compressed, @dict_body, dictionary: :email_html},
               "c" => {:compressed, @long_body, intern: true, codec: :zstd}
             }
           })
    @given committed_moment(%{
             "emails" => %{
               "a" => {:compressed, @long_body <> " [v2]", codec: :zstd},
               "c" => {:compressed, @long_body, intern: true, codec: :zstd},
               "d" => {:compressed, @dict_body, dictionary: :email_html}
             }
           })

    @upon diffing_moments(:compressed_diff, 1, 2)
    @upon inspecting_history_of(:a_history, ".emails.a")

    @then diff_changes_are(:compressed_diff, [
            {:put, ".emails.a", @long_body <> " [v2]"},
            {:put, ".emails.d", @dict_body}
          ])
    @then history_lineage_is(:a_history, [
            %{moment: 1, value: @long_body, doc: ""},
            %{moment: 2, value: @long_body <> " [v2]", doc: ""}
          ])
  end
end

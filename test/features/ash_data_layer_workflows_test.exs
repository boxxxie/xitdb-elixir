if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Features.AshDataLayerWorkflowsTest do
    use Xitdb.AshCase
    import Xitdb.TestDSL.WorkspaceDSL

    scenario "row-level read filters, field policies, and atomic write authorization enforce member privacy" do
      @given member("Alice Chen",
               headline: "CIO",
               visibility: :public,
               compensation_band: "$500k+"
             )
      @given member("Bob Patel",
               headline: "Managing Director",
               visibility: :private,
               compensation_band: "$400k-$500k"
             )
      @given member("Dana Steward",
               headline: "CAASA Steward",
               role: :steward,
               visibility: :public
             )

      @upon updating_profile_headline("Alice Chen", as: "Bob Patel", to: "Tampered Bio")

      @then action_is_forbidden()
      @then directory_visible_to("Alice Chen", ["Alice Chen", "Dana Steward"])
      @then directory_visible_to("Bob Patel", ["Alice Chen", "Bob Patel", "Dana Steward"])
      @then directory_visible_to("Dana Steward", ["Alice Chen", "Bob Patel", "Dana Steward"])
      @then compensation_band_for("Alice Chen", viewed_by: "Bob Patel", is: :redacted)
      @then compensation_band_for("Alice Chen", viewed_by: "Dana Steward", is: "$500k+")
    end

    scenario "cross-store exists(...) filters, calculations, atomic counters, and bulk inbox pruning" do
      @given member("Elena Rostova", headline: "Head of Private Credit")
      @given member("Marcus Vance", headline: "Pension Allocator")
      @given member("Sofia Laurent", headline: "Endowment Director")
      @given direct_message(
               from: "Elena Rostova",
               to: "Marcus Vance",
               body: "Co-invest deck attached"
             )
      @given direct_message(
               from: "Elena Rostova",
               to: "Marcus Vance",
               body: "Follow-up on Q4 terms"
             )
      @given direct_message(
               from: "Marcus Vance",
               to: "Sofia Laurent",
               body: "Endowment co-invest invite"
             )

      @upon viewing_profile_counter("Elena Rostova", as: "Elena Rostova")

      @then profile_summary_matches("Elena Rostova",
              badge: "Elena Rostova (Head of Private Credit)",
              sent_messages: 2,
              views: 1
            )
      @then directory_visible_to("Marcus Vance", ["Elena Rostova"], who_messaged: "Marcus Vance")
      @then directory_visible_to("Sofia Laurent", ["Marcus Vance"], who_messaged: "Sofia Laurent")

      @upon archiving_and_pruning_inbox("Marcus Vance")

      @then profile_summary_matches("Elena Rostova",
              badge: "Elena Rostova (Head of Private Credit)",
              sent_messages: 0,
              views: 1
            )
      @then inbox_prune_counts(archived: 2, destroyed: 2)
      @then directory_visible_to("Marcus Vance", [], who_messaged: "Marcus Vance")
      @then directory_visible_to("Sofia Laurent", ["Marcus Vance"], who_messaged: "Sofia Laurent")
    end

    scenario "nested sessions, portable expression calculations, partial seat identities, and savepoint rollbacks" do
      @given firm("Polar Asset Management", domain: "polar.ca")
      @given conference_event("CAASA Annual Summit",
               organizer: "Polar Asset Management",
               city: nil,
               venue: "Le Westin Montreal",
               sessions: [
                 %{title: "Global Macro Roundtable", capacity: 12},
                 %{title: "Digital Assets Custody", capacity: 28}
               ]
             )
      @given member("Liam O'Connor", firm: "Polar Asset Management")
      @given member("Nadia Al-Mansoor", firm: "Polar Asset Management")
      @given confirmed_seat(session: "Global Macro Roundtable", member: "Liam O'Connor", seat: 1)

      @upon attempting_duplicate_seat(
              session: "Global Macro Roundtable",
              member: "Nadia Al-Mansoor",
              seat: 1
            )
      @then action_fails_with_invalid_field(:seat_number, "has already been taken")

      @upon cancelling_and_reassigning_seat(
              session: "Global Macro Roundtable",
              seat: 1,
              from: "Liam O'Connor",
              to: "Nadia Al-Mansoor"
            )
      @upon reserving_with_aborted_nested_savepoint(
              session: "Global Macro Roundtable",
              keep_member: "Liam O'Connor",
              keep_seat: 2,
              rollback_member: "Nadia Al-Mansoor",
              rollback_seat: 3
            )

      @then event_rollup_matches("CAASA Annual Summit",
              location: "Le Westin Montreal",
              sessions: 2,
              total_capacity: 40
            )
      @then confirmed_seats_for_session("Global Macro Roundtable", [1, 2])
    end

    scenario "in-Xitdb BM25 + prefix search resolves firm mandates onto profiles without denormalized columns" do
      @given firm("Northleaf Capital",
               domain: "northleaf.ca",
               mandate: "Mid-market infrastructure and private credit secondaries"
             )
      @given firm("Boreal Quant Partners",
               domain: "borealquant.ca",
               mandate: "Systematic statistical arbitrage"
             )
      @given member("Claire Tremblay",
               firm: "Northleaf Capital",
               headline: "Infrastructure Principal"
             )
      @given member("Victor Leung",
               firm: "Boreal Quant Partners",
               headline: "Portfolio Manager"
             )

      @upon searching_directory("infrastr secondar", as: "Claire Tremblay")
      @then search_results_ordered(["Claire Tremblay"])

      @upon renaming_firm("Boreal Quant Partners",
              name: "Boreal Credit Partners",
              mandate: "Senior infrastructure debt and secondaries"
            )
      @upon searching_directory("infrastr secondar", as: "Claire Tremblay")
      @then search_results_ordered(["Claire Tremblay", "Victor Leung"])
    end

    scenario "AshPhoenix.Form and atomic updates enforce corporate-domain validation and persist valid emails" do
      @upon submitting_membership_form(%{
              email: "applicant@gmail.com",
              full_name: "Jordan Lee",
              headline: "Family Office CIO"
            })
      @then form_rejected_field(:email, "must use a corporate domain")

      @upon submitting_membership_form(%{
              email: "jordan@maplefamilyoffice.ca",
              full_name: "Jordan Lee",
              headline: "Family Office CIO"
            })
      @then form_created_member("Jordan Lee")

      @upon changing_member_email("Jordan Lee", as: "Jordan Lee", to: "jordan.personal@gmail.com")
      @then action_fails_with_invalid_field(:email, "must use a corporate domain")
      @then member_email_has_domain("Jordan Lee", "maplefamilyoffice.ca")

      @upon changing_member_email("Jordan Lee", as: "Jordan Lee", to: "j.lee@maplecapital.ca")
      @then member_email_has_domain("Jordan Lee", "maplecapital.ca")
    end
  end
end

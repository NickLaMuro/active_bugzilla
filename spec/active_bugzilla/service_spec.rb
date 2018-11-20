require 'spec_helper'

describe ActiveBugzilla::Service, :include_bugzilla_server_helper do
  let(:host) { "http://#{FakeBugzillaServer.server_host}" }
  let(:port) { FakeBugzillaServer.server_port }
  let(:bz)   { described_class.new(host, "calvin", "hobbes", :port => port) }

  context "#new" do
    it 'normal case' do
      expect { bz }.to_not raise_error
    end

    it "uses xmlparser's more performant stream parser" do
      expect(bz.send(:xmlrpc_client).send(:parser).class.name).to eq "XMLRPC::XMLParser::XMLStreamParser"
    end

    it "when bugzilla_uri is invalid" do
      expect { described_class.new("lalala", "", "") }.to raise_error(URI::BadURIError)
    end

    it "when username and password are not set" do
      expect { described_class.new("http://uri.to/bugzilla", nil, nil) }.to raise_error(ArgumentError)
    end
  end

  context "#get" do
    it "when no argument is specified" do
      expect { bz.get }.to raise_error(ArgumentError)
    end

    it "when an invalid argument is specified" do
      expect { bz.get("not a Fixnum") }.to raise_error(ArgumentError)
    end

    it "when the specified bug does not exist" do
      with_a_bz_server_definition do
        action("Bug.get") do
          assert_bugzilla_auth "calvin", "hobbes"
          assert_params        "ids" => [94897099]
          {}
        end
      end
      matches = bz.get(94897099)
      stop_bz_server

      expect(matches).to be_kind_of(Array)
      expect(matches).to be_empty
    end

    it "when producing valid output" do
      with_a_bz_server_definition do
        action "Bug.get" do
          assert_bugzilla_auth "calvin", "hobbes"
          assert_params        "ids" => ["948972"]

          {
            'bugs' => [
              {
                "priority" => "unspecified",
                "keywords" => ["ZStream"],
                "cc"       => ["calvin@redhat.com", "hobbes@RedHat.com"],
              },
            ]
          }
        end
      end

      existing_bz = bz.get("948972").first

      stop_bz_server

      expect(bz.last_command).to include("Bug.get")

      expect(existing_bz["priority"]).to eq("unspecified")
      expect(existing_bz["keywords"]).to eq(["ZStream"])
      expect(existing_bz["cc"]).to eq(["calvin@redhat.com", "hobbes@RedHat.com"])
    end
  end

  context "#clone" do
    let(:commenter_1)      { "Calvin@redhat.com" }
    let(:commenter_2)      { "Hobbes@redhat.com" }
    let(:overwrite_params) { {} }
    let(:existing_bz) do
      {
        "id"             => 948972,
        "description"    => "Description of problem:\n\nIt's Broken",
        "priority"       => "unspecified",
        "assigned_to"    => "calvin@redhat.com",
        "target_release" => ["---"],
        "keywords"       => ["ZStream"],
        "cc"             => ["calvin@redhat.com", "hobbes@RedHat.com"],
        "comments"       => [
          {
            "is_private"    => false,
            "count"         => 0,
            "time"          => XMLRPC::DateTime.new(1969, 7, 20, 16, 18, 30),
            "bug_id"        => 948970,
            "author"        => commenter_1,
            "text"          => "It's Broken and impossible to reproduce",
            "creation_time" => XMLRPC::DateTime.new(1969, 7, 20, 16, 18, 30),
            "id"            => 5777871,
            "creator_id"    => 349490
          },
          {
            "is_private"    => false,
            "count"         => 1,
            "time"          => XMLRPC::DateTime.new(1970, 11, 10, 16, 18, 30),
            "bug_id"        => 948970,
            "author"        => commenter_2,
            "text"          => "Fix Me Now!",
            "creation_time" => XMLRPC::DateTime.new(1972, 2, 14, 0, 0, 0),
            "id"            => 5782170,
            "creator_id"    => 349490
          },
        ]
      }
    end

    # Note:  For the first comment's `:creation_time`, this ends up being `nil`
    # on older versions of ruby do to the fact that the `to_time` method used to
    # call out to `Time.gm(XMLRPC::DateTime#to_a)`, and in pre Ruby 2.0, this
    # would return `nil` if the year was less than 1970 (epoch):
    #
    #   https://github.com/ruby/ruby/blob/23ccbdf5/lib/xmlrpc/datetime.rb#L113-L119
    #
    # This has since changed:
    #
    #   https://github.com/ruby/xmlrpc/commit/7a7a3afc
    #
    # But for ruby version compatibility, this is calculated again here so it can
    # be conditionally defined based on Ruby version.
    let(:comment_1_time) do
      existing_bz["comments"].first["creation_time"].to_time
    end

    let(:clone_description) do
      <<-BZ_DESCRIPTION.gsub(/^ {8}/, '').chomp
         +++ This bug was initially created as a clone of Bug ##{existing_bz["id"]} +++ 
        Description of problem:

        It's Broken

        **********************************************************************
        Following comment by #{commenter_1} on #{comment_1_time}



        It's Broken and impossible to reproduce

        **********************************************************************
        Following comment by #{commenter_2} on 1972-02-14 00:00:00 UTC



        Fix Me Now!
      BZ_DESCRIPTION
    end

    before do
      fake_bz_server_vars = {
        :existing_bz       => existing_bz,
        :overwrite_params  => overwrite_params,
        :clone_description => clone_description
      }
      with_a_bz_server_definition fake_bz_server_vars do
        action "Bug.get" do
          if params["ids"] == [94897099]
            # non-existant BZ
            #
            # FIXME:  We probably should re-write this spec, since bugzilla's
            # xmlrpc seems to throw an error when the BZ doesn't exist, and not
            # just an empty XML struct.
            {}
          else
            extra_fields = ActiveBugzilla::Service::CLONE_FIELDS.map(&:to_s)

            assert_bugzilla_auth "calvin", "hobbes"
            assert_params        "ids"            => [948972],
                                 "include_fields" => extra_fields

            { "bugs" => [existing_bz] }
          end
        end

        action "Bug.create" do
          expected_params = existing_bz.merge({
            "cf_clone_of"        => existing_bz["id"],
            "description"        => clone_description,
            "comment_is_private" => false
          }.merge(overwrite_params))
          expected_params.delete("comments")
          expected_params.delete("id")

          assert_bugzilla_auth "calvin", "hobbes"
          assert_params        expected_params

          { "id" => 948992 }
        end
      end
    end

    after { stop_bz_server }

    it "when no argument is specified" do
      expect { bz.clone }.to raise_error(ArgumentError)
    end

    it "when an invalid argument is specified" do
      expect { bz.clone("not a Fixnum") }.to raise_error(ArgumentError)
    end

    it "when the specified bug to clone does not exist" do
      expect { bz.clone(94897099) }.to raise_error ActiveBugzilla::Bug::NotFound
    end

    context "when producing valid output" do

      it "creates the new BZ and returns the new BZ ID" do
        new_bz_id = bz.clone(existing_bz["id"])
        expect(bz.last_command).to include("Bug.create")

        expect(new_bz_id).to eq(948992)
      end
    end

    context "when providing override values" do
      let(:commenter_1) { "Buzz.Aldrin@redhat.com" }
      let(:commenter_2) { "Neil.Armstrong@redhat.com" }

      let(:overwrite_params) do
        {
          "assigned_to"    => "Ham@NASA.gov",
          "target_release" => ["2.2.0"]
        }
      end

      it "creates the new BZ with the updated params and returns the new ID" do
        new_bz_id = bz.clone(948972, overwrite_params)

        expect(bz.last_command).to include("Bug.create")

        expect(new_bz_id).to eq(948992)
      end
    end
  end

end

require "active_bugzilla/testing/fake_bugzilla_server"

FAKE_BZ_DATA_DIR = File.expand_path("../fake_bugzilla_data", __FILE__)

shared_context "with fake bugzilla server", :with_bugzilla_server do
    before(:all) { FakeBugzillaServer.start(FAKE_BZ_DATA_DIR) }
      after(:all)  { FakeBugzillaServer.stop }
end

shared_context "bugzilla server helper methods", :include_bugzilla_server_helper do
  def with_a_bz_server_definition *options, &block
    FakeBugzillaServer.start_with *options, &block
  end

  def stop_bz_server
    FakeBugzillaServer.stop
  end
end

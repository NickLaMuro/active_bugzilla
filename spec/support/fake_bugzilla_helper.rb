require "active_bugzilla/testing/fake_bugzilla_server"

shared_context "bugzilla server helper methods", :include_bugzilla_server_helper do
  def with_a_bz_server_definition(*options, &block)
    FakeBugzillaServer.start_with(*options, &block)
  end

  def stop_bz_server
    FakeBugzillaServer.stop
  end
end

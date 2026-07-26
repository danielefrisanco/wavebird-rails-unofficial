# frozen_string_literal: true

RSpec.describe Wavebird::SessionId do
  # A bare controller that mixes in the concern; the session is a plain hash,
  # which is all the concern touches.
  let(:controller_class) do
    Class.new(ActionController::Base) do
      include Wavebird::SessionId
    end
  end
  let(:controller) { controller_class.new }
  let(:store) { {} }

  before { allow(controller).to receive(:session).and_return(store) }

  it "generates an anonymous sess_ token on first use" do
    id = controller.wavebird_session_id

    expect(id).to match(/\Asess_[0-9a-f-]{36}\z/)
  end

  it "persists the id in the session" do
    id = controller.wavebird_session_id

    expect(store[:wavebird_session_id]).to eq(id)
  end

  it "returns the same id on repeated calls (stable per browser)" do
    controller.wavebird_session_id

    expect(controller.wavebird_session_id).to eq(store[:wavebird_session_id])
  end

  it "reuses an id already present in the session" do
    store[:wavebird_session_id] = "sess_existing"

    expect(controller.wavebird_session_id).to eq("sess_existing")
  end

  it "exposes the method to views as a helper" do
    expect(controller_class._helper_methods).to include(:wavebird_session_id)
  end

  it "is includable in a plain object that has no helper_method DSL" do
    plain = Class.new do
      include Wavebird::SessionId

      def session = @session ||= {}
    end.new

    expect(plain.wavebird_session_id).to match(/\Asess_/)
  end
end

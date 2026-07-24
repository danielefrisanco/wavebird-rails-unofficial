# frozen_string_literal: true

RSpec.describe Wavebird::Client, "jobs and generation" do
  include_context "with a configured client"

  describe "#create_job" do
    let(:jobs_url) { "#{api_base}/v1/jobs" }
    let(:accepted) { { "job_id" => "job_1", "slot_ids" => %w[slot_1], "status" => "accepted" } }

    it "posts the canonical job body and returns the accepted job" do
      stub = stub_request(:post, jobs_url)
             .with(body: { client_id: "wbproj_spec", session_id: "sess_1", job_type: "chat", locale: "en-US",
                           slots_requested: 2, prompt: { topic: "travel" }, slot_hint: { position: "below" } })
             .to_return(status: 200, body: JSON.generate(accepted))

      job = client.create_job(job_type: "chat", session_id: "sess_1", locale: "en-US", slots_requested: 2,
                              topic: "travel", slot_hint: { position: "below" })

      expect(stub).to have_been_requested
      expect(job.job_id).to eq("job_1")
      expect(job.slot_ids).to eq(%w[slot_1])
      expect(job.status).to eq("accepted")
    end

    it "omits optional fields from the body" do
      stub = stub_request(:post, jobs_url)
             .with(body: { client_id: "wbproj_spec", job_type: "code", slots_requested: 1 })
             .to_return(status: 200, body: JSON.generate(accepted))

      client.create_job(job_type: "code")

      expect(stub).to have_been_requested
    end

    it "merges the default publisher into overrides" do
      config.default_publisher = { app_name: "SpecApp" }
      stub = stub_request(:post, jobs_url)
             .with(body: hash_including("overrides" => { "publisher" => { "app_name" => "SpecApp" } }))
             .to_return(status: 200, body: JSON.generate(accepted))

      client.create_job(job_type: "chat")

      expect(stub).to have_been_requested
    end

    {
      "a non-object body" => %w[nope],
      "a missing job_id" => { "slot_ids" => %w[slot_1], "status" => "accepted" },
      "non-array slot_ids" => { "job_id" => "job_1", "slot_ids" => "slot_1", "status" => "accepted" },
      "empty slot_ids" => { "job_id" => "job_1", "slot_ids" => [], "status" => "accepted" },
      "blank slot id entries" => { "job_id" => "job_1", "slot_ids" => ["slot_1", " "], "status" => "accepted" },
      "a non-accepted status" => { "job_id" => "job_1", "slot_ids" => %w[slot_1], "status" => "queued" }
    }.each do |label, body|
      it "rejects #{label} (upstream normalizeV1JobResponse rules)" do
        stub_request(:post, jobs_url).to_return(status: 200, body: JSON.generate(body))

        expect { client.create_job(job_type: "chat") }.to raise_error(Wavebird::InvalidResponseError, /job/)
      end
    end
  end

  describe "#report_generation" do
    it "posts the generation body to the event path" do
      stub = stub_request(:post, "#{api_base}/v1/jobs/job_1/generation/finished")
             .with(body: { generation_id: "gen_1", model_id: "m_1", usage_json: { "tokens" => 42 } })
             .to_return(status: 204, body: "")

      expect(client.report_generation("job_1", :finished, generation_id: "gen_1", model_id: "m_1",
                                                          usage_json: { "tokens" => 42 })).to be(true)
      expect(stub).to have_been_requested
    end

    it "sends an empty object body when no metadata is given (upstream default)" do
      stub = stub_request(:post, "#{api_base}/v1/jobs/job_1/generation/failed")
             .with(body: "{}").to_return(status: 204, body: "")

      client.report_generation("job_1", "failed", error: nil)

      expect(stub).to have_been_requested
    end

    it "URL-encodes the job id" do
      stub = stub_request(:post, "#{api_base}/v1/jobs/job%2F1/generation/started")
             .to_return(status: 204, body: "")

      client.report_generation("job/1", "started")

      expect(stub).to have_been_requested
    end

    it "rejects unknown events before touching the network (they form the URL path)" do
      expect { client.report_generation("job_1", "exploded") }
        .to raise_error(ArgumentError, /started\|finished\|failed/)
    end
  end
end

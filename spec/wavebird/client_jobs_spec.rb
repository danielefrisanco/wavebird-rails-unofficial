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

    # Port of upstream createV1JobRequest: the canonical jobs route expresses
    # consent as overrides.gdpr_applies and nothing else. Upstream reaches the
    # legacy wrapper ingress for the richer flags; this canonical-only client
    # says so out loud instead of dropping them quietly.
    describe "consent on the canonical jobs route" do
      it "folds gdpr_applies into overrides" do
        stub = stub_request(:post, jobs_url)
               .with(body: hash_including("overrides" => { "gdpr_applies" => true }))
               .to_return(status: 200, body: JSON.generate(accepted))

        client.create_job(job_type: "chat", consent: { gdpr_applies: true })

        expect(stub).to have_been_requested
      end

      it "reads gdpr_applies from string keys too (controller params arrive that way)" do
        stub = stub_request(:post, jobs_url)
               .with(body: hash_including("overrides" => { "gdpr_applies" => false }))
               .to_return(status: 200, body: JSON.generate(accepted))

        client.create_job(job_type: "chat", consent: { "gdpr_applies" => false })

        expect(stub).to have_been_requested
      end

      it "keeps gdpr_applies alongside other overrides" do
        config.default_publisher = { app_name: "SpecApp" }
        stub = stub_request(:post, jobs_url)
               .with(body: hash_including("overrides" => { "publisher" => { "app_name" => "SpecApp" },
                                                           "gdpr_applies" => true }))
               .to_return(status: 200, body: JSON.generate(accepted))

        client.create_job(job_type: "chat", consent: { gdpr_applies: true })

        expect(stub).to have_been_requested
      end

      it "warns about flags the canonical route cannot carry, and omits them" do
        logger = instance_double(Logger, warn: nil)
        config.logger = logger
        stub_request(:post, jobs_url).to_return(status: 200, body: JSON.generate(accepted))

        client.create_job(job_type: "chat",
                          consent: { gdpr_applies: true, semantic_targeting: false, prompt_shared: false })

        expect(logger).to have_received(:warn).with(/ignoring prompt_shared, semantic_targeting/)
        expect(a_request(:post, jobs_url)
          .with(body: hash_including("overrides" => { "gdpr_applies" => true }))).to have_been_made
      end

      it "sends no overrides when consent carries nothing the route accepts" do
        stub = stub_request(:post, jobs_url)
               .with(body: { client_id: "wbproj_spec", job_type: "chat", slots_requested: 1 })
               .to_return(status: 200, body: JSON.generate(accepted))

        client.create_job(job_type: "chat", consent: { semantic_targeting: false })

        expect(stub).to have_been_requested
      end

      it "does not warn when consent carries only gdpr_applies" do
        logger = instance_double(Logger, warn: nil)
        config.logger = logger
        stub_request(:post, jobs_url).to_return(status: 200, body: JSON.generate(accepted))

        client.create_job(job_type: "chat", consent: { gdpr_applies: true })

        expect(logger).not_to have_received(:warn)
      end
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

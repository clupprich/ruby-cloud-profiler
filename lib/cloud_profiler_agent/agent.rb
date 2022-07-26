# frozen_string_literal: true

require 'google/cloud/profiler'
require 'stackprof'

module CloudProfilerAgent
  PROFILE_TYPES = {
    'CPU' => :cpu,
    'WALL' => :wall,
    'HEAP_ALLOC' => :object
  }.freeze
  SERVICE_REGEXP = /^[a-z]([-a-z0-9_.]{0,253}[a-z0-9])?$/.freeze

  # Agent interfaces with the CloudProfiler API.
  class Agent
    def initialize(service:, project_id:, service_version: nil, debug_logging: false, instance: nil, zone: nil)
      raise ArgumentError, "service must match #{SERVICE_REGEXP}" unless SERVICE_REGEXP =~ service

      @service = service
      @project_id = project_id
      @debug_logging = debug_logging

      @profiler = Google::Cloud::Profiler.profiler_service

      @labels = { language: 'ruby' }
      @labels[:version] = service_version unless service_version.nil?
      @labels[:zone] = zone unless zone.nil?

      @deployment = Google::Cloud::Profiler::V2::Deployment.new(project_id: project_id, target: service, labels: @labels)

      @profile_labels = {}
      @profile_labels[:instance] = instance unless instance.nil?
    end

    attr_reader :service, :project_id, :labels, :deployment, :profile_labels

    def create_profile
      req = Google::Cloud::Profiler::V2::CreateProfileRequest.new(deployment: deployment, profile_type: PROFILE_TYPES.keys)
      debug_log('creating profile')
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      profile = @profiler.create_profile(req)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      debug_log("got profile after #{elapsed} seconds")
      profile
    end

    def update_profile(profile)
      debug_log('updating profile')
      req = Google::Cloud::Profiler::V2::UpdateProfileRequest.new(profile: profile)
      @profiler.update_profile(req)
      debug_log('profile updated')
    end

    # parse_duration converts duration-as-a-string, as returned by the Profiler
    # API, to a duration in seconds. Can't find any documentation on the format,
    # and only have the single example "10s" to go on. If the duration can't be
    # parsed then it returns 10.
    def parse_duration(duration)
      m = /^(\d+)s$/.match(duration)
      return 10 if m.nil?

      Integer(m[1])
    end

    # start will begin creating profiles in a background thread, looping
    # forever. Exceptions are rescued and logged, and retries are made with
    # exponential backoff.
    def start
      return if !@thread.nil? && @thread.alive?

      @thread = Thread.new do
        Looper.new(debug_logging: @debug_logging).run do
          profile = create_profile
          profile_and_upload(profile)
        end
      end
    end

    private

    def profile(duration, mode)
      start_time = Time.now
      # interval is in microseconds for :cpu and :wall, number of allocations for :object
      stackprof = StackProf.run(mode: mode, raw: true, interval: 1000) do
        sleep(duration)
      end

      CloudProfilerAgent::PprofBuilder.convert_stackprof(stackprof, start_time, Time.now)
    end

    def profile_and_upload(profile)
      debug_log("profiling #{profile.profile_type} for #{profile.duration}")
      profile.profile_bytes = profile(parse_duration(profile.duration.to_s), PROFILE_TYPES.fetch(profile.profile_type.to_s))
      update_profile(profile)
    end

    def debug_log(message)
      puts(message) if @debug_logging
    end
  end
end

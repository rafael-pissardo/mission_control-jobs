#!/usr/bin/env ruby
# frozen_string_literal: true

require "capybara"
require "capybara/dsl"
require "selenium-webdriver"
require "fileutils"
require "net/http"

DUMMY_ROOT = File.expand_path("../test/dummy", __dir__)
SCREENSHOT_DIR = File.expand_path("../docs/images", __dir__)
VIEWPORT = [ 1200, 1000 ].freeze

def capture_host
  ENV.fetch("CAPTURE_HOST", "host.docker.internal")
end

def prepare_database!
  system("bin/rails db:prepare", chdir: DUMMY_ROOT, exception: true)
end

def within_job_server(app_id, server: nil)
  application = MissionControl::Jobs.applications[app_id]
  server = (server && application.servers[server]) || application.servers.first
  server.activating { yield }
end

def clean_redis!
  all_keys = Resque.redis.keys("*")
  Resque.redis.del all_keys if all_keys.any?
end

def clean_database!
  SolidQueue::Job.find_each(&:destroy)
  SolidQueue::Process.find_each(&:destroy)
  SolidQueue::RecurringTask.find_each(&:destroy)
end

def perform_resque_jobs!
  worker = Resque::Worker.new("*")
  worker.work(0.0)
end

def seed_screenshot_data!
  clean_redis!
  clean_database!

  Post.find_or_create_by!(title: "Hello World!", body: "This is my first post.")

  within_job_server("bc4", server: "resque_ashburn") do
    DummyJob.queue_as :default
    3.times { |index| FailingJob.perform_later(index) }
    perform_resque_jobs!

    4.times { |index| DummyJob.perform_later(index) }

    DummyJob.queue_as :reports
    2.times { |index| DummyJob.perform_later(index) }
  end

  within_job_server("bc4", server: "resque_chicago") do
    DummyJob.queue_as :default
    6.times { |index| DummyJob.perform_later(index) }
  end

  within_job_server("hey", server: "resque") do
    DummyJob.queue_as :hey_queue
    3.times { |index| DummyJob.perform_later(index) }
  end

  @in_progress_worker = nil
  within_job_server("hey", server: "solid_queue") do
    PauseJob.set(queue: :default).perform_later(120)
    PauseJob.set(queue: :default).perform_later(120)

    @in_progress_worker = SolidQueue::Worker.new(queues: "*", threads: 2, polling_interval: 0.05)
    @in_progress_worker.start
    sleep 1.5
  end
end

def stop_in_progress_worker!
  return unless @in_progress_worker

  @in_progress_worker.stop
  @in_progress_worker = nil
end

def first_failed_job_id
  within_job_server("bc4", server: "resque_ashburn") do
    ActiveJob.jobs.failed.first&.job_id
  end
end

def first_worker_id
  application = MissionControl::Jobs.applications["hey"]
  server = application.servers["solid_queue"]
  server.activating do
    server.workers_relation.to_a.first&.id
  end
end

ENV["RAILS_ENV"] = "development"
Dir.chdir(DUMMY_ROOT)
require File.join(DUMMY_ROOT, "config/environment")

MissionControl::Jobs.http_basic_auth_enabled = false

class ScreenshotCapturer
  include Capybara::DSL
  include MissionControl::Jobs::Engine.routes.url_helpers

  def initialize(host:)
    @host = host
    configure_capybara!
    wait_for_server!
  end

  def capture(name, path)
    visit path
    sleep 0.75
    page.save_screenshot(File.join(SCREENSHOT_DIR, "#{name}.png"))
    puts "Saved #{name}.png"
  end

  def capture_queues_multiple(bc4, hey)
    visit application_queues_path(bc4, server_id: "resque_ashburn")
    sleep 0.5
    page.save_screenshot(File.join(SCREENSHOT_DIR, "queues-multiple.png"))
    puts "Saved queues-multiple.png (BC4 multi-server)"

    visit application_queues_path(hey, server_id: "resque")
    sleep 0.5
    # overwrite only if we want HEY variant — keep BC4 multi-server as primary
  end

  def quit
    Capybara.current_session.driver.quit if Capybara.current_session.driver
  end

  private
    def wait_for_server!
      url = "http://127.0.0.1:#{Capybara.server_port}/jobs"
      deadline = Time.now + 30

      loop do
        begin
          Net::HTTP.get(URI(url))
          return
        rescue Errno::ECONNREFUSED, SocketError
          raise "Server did not start at #{url}" if Time.now > deadline
          sleep 0.5
        end
      end
    end

    def configure_capybara!
      ActiveRecord::Base.connection_handler.clear_all_connections!(:all)

      Capybara.app = Rails.application
      Capybara.server = :puma, { Silent: true, Host: "0.0.0.0", Threads: "1:4" }
      Capybara.server_port = 3001
      Capybara.app_host = "http://#{@host}:#{Capybara.server_port}"
      Capybara.default_max_wait_time = 10

      Capybara.register_driver :selenium_chrome_remote do |app|
        options = Selenium::WebDriver::Chrome::Options.new
        options.add_argument("--window-size=#{VIEWPORT.join(',')}")
        options.add_argument("--force-device-scale-factor=1")

        Capybara::Selenium::Driver.new(
          app,
          browser: :remote,
          url: ENV.fetch("SELENIUM_URL", "http://localhost:4444/wd/hub"),
          options: options
        )
      end

      Capybara.current_driver = :selenium_chrome_remote
      Capybara.current_session.driver.browser.manage.window.resize_to(*VIEWPORT)
    end
end

prepare_database!
seed_screenshot_data!

bc4 = MissionControl::Jobs.applications["bc4"]
hey = MissionControl::Jobs.applications["hey"]
capturer = ScreenshotCapturer.new(host: capture_host)

begin
  capturer.capture "queues-simple", capturer.application_queues_path(bc4, server_id: "resque_ashburn")
  capturer.capture "failed-jobs-simple", capturer.application_jobs_path(bc4, :failed, server_id: "resque_ashburn")
  capturer.capture_queues_multiple(bc4, hey)
  capturer.capture "default-queue", capturer.application_queue_path(bc4, "default", server_id: "resque_ashburn")
  capturer.capture "in-progress-jobs", capturer.application_jobs_path(hey, :in_progress, server_id: "solid_queue")
  capturer.capture "workers", capturer.application_workers_path(hey, server_id: "solid_queue")

  if (failed_job_id = first_failed_job_id)
    capturer.capture "single-job", capturer.application_job_path(bc4, failed_job_id, server_id: "resque_ashburn")
  end

  if (worker_id = first_worker_id)
    capturer.capture "single-worker", capturer.application_worker_path(hey, worker_id, server_id: "solid_queue")
  end
ensure
  stop_in_progress_worker!
  capturer.quit
end

puts "Done. Screenshots saved to #{SCREENSHOT_DIR}"

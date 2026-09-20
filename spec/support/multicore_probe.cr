require "file_utils"
require "../../src/tinrelay/client/runtime"
require "../../src/tinrelay/server/server"

class ProbeMetrics
  @mutex = Mutex.new
  @threads = {} of String => Bool
  @inflight = 0
  @max_inflight = 0

  def enter : Nil
    @mutex.synchronize do
      @threads[Thread.current.object_id.to_s] = true
      @inflight += 1
      @max_inflight = {@max_inflight, @inflight}.max
    end
  end

  def leave : Nil
    @mutex.synchronize { @inflight -= 1 }
  end

  def reset : Nil
    @mutex.synchronize do
      @threads.clear
      @inflight = 0
      @max_inflight = 0
    end
  end

  def snapshot
    @mutex.synchronize { {threads: @threads.size, max_inflight: @max_inflight} }
  end
end

class ProbeCaptureRemote < Tinrelay::Remote
  getter captured = [] of Tinrelay::SignedRelayEnvelope

  def post(path : String, body : String) : String
    if path == "/v1/transmissions"
      @captured << Tinrelay::SignedRelayEnvelope.from_json(body)
      %({"state":"accepted"})
    else
      super
    end
  end
end

def burst(count : Int32, concurrency : Int32, &request : -> Nil)
  jobs = Channel(Nil).new(count)
  count.times { jobs.send(nil) }
  jobs.close
  results = Channel({Float64, String?}).new(count)
  concurrency.times do
    spawn do
      jobs.each do
        started = Time.instant
        error = nil.as(String?)
        begin
          request.call
        rescue ex
          error = ex.class.name
        end
        results.send({(Time.instant - started).total_milliseconds, error})
      end
    end
  end
  values = Array({Float64, String?}).new(count) { results.receive }
  latencies = values.map(&.[0]).sort
  errors = values.compact_map(&.[1])
  {
    aggregate_latency_ms: latencies.sum,
    p50_ms:               latencies[(latencies.size * 0.50).floor.to_i],
    p95_ms:               latencies[{(latencies.size * 0.95).floor.to_i, latencies.size - 1}.min],
    max_ms:               latencies.last,
    errors:               errors.tally,
  }
end

def admit_ship(root : String, origin : String, ship : String) : Tinrelay::Client
  Tinrelay::Client.join(File.join(root, "#{ship}.keyring"), origin, ship)
end

def connect_ships(root : String, first : Tinrelay::Client,
                  second : Tinrelay::Client) : Nil
  first_spool = Tinrelay::Spool.new(File.join(root, "#{first.keyring.data.ship}-contact"))
  second_spool = Tinrelay::Spool.new(File.join(root, "#{second.keyring.data.ship}-contact"))
  first.hail(second.keyring.data.ship)
  event = second.radio_wait(second_spool, hold_seconds: 0)
  second_spool.routed(event.local_id)
  second.allow_contact(event.local_id, second_spool)
  second.hail(first.keyring.data.ship)
  return_event = first.radio_wait(first_spool, hold_seconds: 0)
  first_spool.routed(return_event.local_id)
  first.allow_contact(return_event.local_id, first_spool)
end

threads = 4
reads = 1_000
writes = 60
concurrency = 32
args = ARGV.dup
while flag = args.shift?
  value = args.shift? || raise "#{flag} requires a value"
  case flag
  when "--threads"     then threads = value.to_i
  when "--reads"       then reads = value.to_i
  when "--writes"      then writes = value.to_i
  when "--concurrency" then concurrency = value.to_i
  else                      raise "unknown option #{flag}"
  end
end
threads = Tinrelay::ServerRuntime.thread_count(threads.to_s)
Tinrelay::ServerRuntime.enable_multicore(threads)

root = File.join(Dir.tempdir, "tinrelay-multicore-#{Process.pid}")
FileUtils.rm_r(root) if Dir.exists?(root)
Dir.mkdir_p(root)
begin
  config = Tinrelay::ServerConfig.new(
    "127.0.0.1", 0, File.join(root, "service.db"), threads
  )
  api = Tinrelay::API.new(config)
  metrics = ProbeMetrics.new
  inner = api.handler
  handler = HTTP::Handler::HandlerProc.new do |context|
    metrics.enter
    begin
      inner.call(context)
    ensure
      metrics.leave
    end
  end
  server = HTTP::Server.new(handler)
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  Fiber.yield
  origin = "http://127.0.0.1:#{address.port}"
  alpha = Tinrelay::Client.join(
    File.join(root, "alpha.keyring"), origin, "alpha")
  beta = admit_ship(root, origin, "beta")
  connect_ships(root, alpha, beta)
  gamma = admit_ship(root, origin, "gamma")
  connect_ships(root, alpha, gamma)
  capture = ProbeCaptureRemote.new(origin)
  composer = Tinrelay::Client.new(beta.keyring, capture)
  writes.times { |index| composer.send("steward@alpha", "probe #{index}", "caller") }
  direct_capture = ProbeCaptureRemote.new(origin)
  Tinrelay::Client.new(gamma.keyring, direct_capture)
    .send("steward@alpha", "direct probe", "caller")

  spool = Tinrelay::Spool.new(File.join(root, "inbox"))
  direct_event = Channel(Tinrelay::RadioEvent).new(1)
  spawn { direct_event.send(alpha.radio_wait(spool, hold_seconds: 5)) }
  deadline = Time.instant + 3.seconds
  until api.handoffs.waiting?("alpha")
    raise "radio waiter did not park" if Time.instant >= deadline
    Fiber.yield
  end
  direct_envelope = direct_capture.captured.first
  direct_started = Time.instant
  Tinrelay::Remote.new(origin).post("/v1/transmissions", direct_envelope.to_json)
  direct_ms = (Time.instant - direct_started).total_milliseconds
  select
  when direct_event.receive
  when timeout(3.seconds)
    raise "direct radio event did not return"
  end
  direct_rows = api.database.db.scalar(
    "SELECT COUNT(*) FROM transmissions WHERE id = ?", direct_envelope.transmission_id
  ).as(Int64)

  metrics.reset
  read_started = Time.instant
  read_result = burst(reads, concurrency) do
    response = HTTP::Client.get("#{origin}/line")
    raise "read status #{response.status_code}" unless response.status_code == 200
  end
  read_wall = (Time.instant - read_started).total_milliseconds
  read_metrics = metrics.snapshot

  metrics.reset
  write_started = Time.instant
  index = Atomic(Int32).new(0)
  write_result = burst(writes, concurrency) do
    envelope = capture.captured[index.add(1)]
    Tinrelay::Remote.new(origin).post("/v1/transmissions", envelope.to_json)
  end
  write_wall = (Time.instant - write_started).total_milliseconds
  write_metrics = metrics.snapshot

  raise "direct handoff wrote relay payload state" unless direct_rows == 0
  raise "public reads stayed on one runtime thread" unless read_metrics[:threads] > 1
  raise "public read burst failed" unless read_result[:errors].empty?
  raise "SQLite fallback burst failed" unless write_result[:errors].empty?

  puts({
    threads:        threads,
    direct_handoff: {wall_ms: direct_ms, relay_transmission_rows: direct_rows},
    reads:          read_result.merge({wall_ms: read_wall, requests: reads}).merge(read_metrics),
    sqlite_writes:  write_result.merge(
      {wall_ms: write_wall, requests: writes}
    ).merge(write_metrics),
  }.to_json)
ensure
  server.try(&.close)
  api.try(&.close)
  FileUtils.rm_r(root) if Dir.exists?(root)
end

require "json"

if ENV["TINRELAY_CODEX_BRIDGE_PIPE_HOLDER"]? == "1"
  sleep 3.seconds
  exit
end

root = ENV["BRIDGE_TEST_ROOT"]
args = ARGV.dup
File.open(File.join(root, "child_calls.jsonl"), "a") do |log|
  log.puts({args: args, pid: Process.pid}.to_json)
end
config = JSON.parse(File.read(File.join(root, "fixture.json")))

case
when args == ["version"]
  puts "tinrelay fixture"
when args[0, 2]? == ["radio", "wait"]
  Signal::TERM.ignore if config["ignore_term"]?.try(&.as_bool?)
  if error = config["child_error"]?
    STDERR.puts error.to_json
    exit 2
  end
  if raw = config["raw_output"]?.try(&.as_s?)
    puts raw
    exit
  end
  if config["huge_output"]?.try(&.as_bool?)
    STDOUT << "x" * 100_000
    STDOUT.flush
    sleep 20.seconds
    exit
  end
  if config["hold_pipe"]?.try(&.as_bool?)
    Process.new(
      Process.executable_path.not_nil!,
      env: {"TINRELAY_CODEX_BRIDGE_PIPE_HOLDER" => "1"},
      output: STDOUT,
      error: STDERR
    )
    exit
  end
  config["events"]?.try(&.as_a).try &.each do |event|
    id = event["source_id"].as_s
    unless File.exists?(File.join(root, "#{id}.routed"))
      puts event.to_json
      exit
    end
  end
  loop { sleep 100.milliseconds }
when args[0, 2]? == ["radio", "status"]
  kind = args[2]
  id = args[3]
  event = config["events"].as_a.find do |candidate|
    candidate["kind"].as_s == kind && candidate["source_id"].as_s == id
  end.not_nil!
  routed = File.exists?(File.join(root, "#{id}.routed"))
  result = {
    "state"     => JSON::Any.new(routed ? "routed" : "pending"),
    "source_id" => JSON::Any.new(id),
    "kind"      => JSON::Any.new(event["kind"].as_s),
  }
  config["status_override"]?.try(&.as_h).try &.each do |key, value|
    result[key] = value
  end
  puts result.to_json
  if config["route_after_status"]?.try(&.as_s?) == id
    File.touch(File.join(root, "#{id}.routed"))
  end
when args[0, 2]? == ["inbox", "show"]
  id = args[3]
  records = config["inbox_records"]?.try(&.as_h)
  record = records.try(&.[id]?)
  exit 3 unless record
  puts record.to_json
when args[0, 2]? == ["radio", "routed"]
  exit 3 if config["routed_failure"]?.try(&.as_bool?)
  kind = args[2]
  id = args[3]
  File.touch(File.join(root, "#{id}.routed"))
  puts({state: "routed", kind: kind, source_id: id}.to_json)
else
  exit 3
end

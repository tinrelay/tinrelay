require "./spec_helper"

describe "the client compilation boundary" do
  it "compiles without loading server or SQLite source" do
    root = File.expand_path("..", __DIR__)
    output = IO::Memory.new
    error = IO::Memory.new
    result = Process.run(
      "crystal", ["tool", "dependencies", "src/tinrelay_cli.cr"],
      chdir: root, output: output, error: error
    )
    result.success?.should be_true, error.to_s
    dependencies = output.to_s.each_line.map do |line|
      Path.new(line.strip).to_posix.to_s
    end
    dependencies.should contain("src/tinrelay/client.cr")
    dependencies.should_not contain("src/tinrelay/database.cr")
    dependencies.should_not contain("src/tinrelay/store.cr")
    dependencies.should_not contain("src/tinrelay/api.cr")
    dependencies.should_not contain("src/tinrelay/direct_handoff.cr")
  end
end

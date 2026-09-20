require "../../src/tinrelay/client/runtime"

spool = Tinrelay::Spool.new(ARGV[0])
spool.with_radio_lock do
  Tinrelay::AtomicPrivateFile.write(ARGV[1], "ready\n")
  Channel(Nil).new.receive
end

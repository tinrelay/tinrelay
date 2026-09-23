require "../spec_helper"

describe Tinrelay::PrivateStorage do
  it "does not mistake a protected operation failure for lock contention" do
    root = TinrelaySpec.temporary_root
    lock_path = File.join(root, "operation.lock")
    conflict = Tinrelay::Conflict.new("lock is busy")
    begin
      expect_raises(IO::Error, /protected operation failed/) do
        Tinrelay::PrivateStorage.with_lock(lock_path, "a", false, conflict) do |_file|
          raise IO::Error.new("protected operation failed")
        end
      end
      Tinrelay::PrivateStorage.with_lock(lock_path, "a", false, conflict) do |_file|
        Tinrelay::PrivateStorage.private?(lock_path).should be_true
      end
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end
end

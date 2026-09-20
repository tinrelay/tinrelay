require "../spec_helper"

class Tinrelay::SubmissionWindow
  def retained_ship_count_for_spec : Int32
    @mutex.synchronize { @attempts.size }
  end
end

class Tinrelay::TransmissionTokenBuckets
  def retained_source_count_for_spec : Int32
    @mutex.synchronize { @buckets.size }
  end
end

describe Tinrelay::ServerRuntime do
  it "uses detected processors by default and bounds an explicit thread count" do
    Tinrelay::ServerRuntime.thread_count(nil).should eq(System.cpu_count)
    Tinrelay::ServerRuntime.thread_count("1").should eq(1)
    expect_raises(Tinrelay::Invalid, /between 1/) do
      Tinrelay::ServerRuntime.thread_count("0")
    end
    expect_raises(Tinrelay::Invalid, /between 1/) do
      Tinrelay::ServerRuntime.thread_count((System.cpu_count + 1).to_s)
    end
  end
end

describe Tinrelay::TransmissionTokenBuckets do
  it "requires byte and message credit and returns the largest refill wait" do
    buckets = Tinrelay::TransmissionTokenBuckets.new
    source = "192.0.2.1/32"
    started = Time.instant

    32.times do
      buckets.admit(source, 4 * 1024, started).should be_nil
    end
    buckets.admit(source, 8 * 1024, started).should eq(4)
    buckets.admit(source, 8 * 1024, started + 3.seconds).should eq(1)
    buckets.admit(source, 8 * 1024, started + 4.seconds).should be_nil
  end

  it "keeps a source until full refill cannot mint credit" do
    source = "2001:db8:1:2::/64"
    started = Time.instant
    retained = Tinrelay::TransmissionTokenBuckets.new
    retained.admit(
      source, Tinrelay::TransmissionTokenBuckets::BYTE_CAPACITY, started
    ).should be_nil
    retained.admit(
      source, Tinrelay::TransmissionTokenBuckets::BYTE_CAPACITY,
      started + 63.seconds
    ).should eq(1)

    reclaimed = Tinrelay::TransmissionTokenBuckets.new
    reclaimed.admit(
      source, Tinrelay::TransmissionTokenBuckets::BYTE_CAPACITY, started
    ).should be_nil
    reclaimed.admit(
      "2001:db8:2:2::/64", 1, started + 64.seconds
    ).should be_nil
    reclaimed.retained_source_count_for_spec.should eq(1)
  end
end

describe Tinrelay::SubmissionWindow do
  it "removes an inactive identity exactly when its final attempt expires" do
    window = Tinrelay::SubmissionWindow.new(1, 10_i64)
    window.allow?("expired", 0_i64).should be_true

    window.allow?("trigger", 10_i64).should be_true

    window.retained_ship_count_for_spec.should eq(1)
  end

  it "expires inactive identities without resetting an active hail quota" do
    limit = Tinrelay::Store::MAX_HAILS_PER_DAY
    period = 24_i64 * 60 * 60
    window = Tinrelay::SubmissionWindow.new(limit, period)
    1_000.times do |index|
      window.allow?("expired-#{index}", 0_i64).should be_true
    end
    window.allow?("active", period).should be_true

    window.allow?("trigger", period + 1).should be_true

    window.retained_ship_count_for_spec.should eq(2)
    (limit - 1).times do
      window.allow?("active", period + 1).should be_true
    end
    window.allow?("active", period + 1).should be_false
  end
end

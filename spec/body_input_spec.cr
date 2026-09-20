require "./spec_helper"
require "../src/tinrelay/client/body_input"

describe Tinrelay::BodyInput do
  it "reads exact body bytes from stdin" do
    body = "first line\nsecond line\n"

    Tinrelay::BodyInput.read(IO::Memory.new(body)).should eq(body)
  end

  it "rejects oversized input at the bounded reader" do
    oversized = "x" * (Tinrelay::BodyInput::MAX_BYTES + 1)

    expect_raises(Tinrelay::Invalid, /transmission body exceeds/) do
      Tinrelay::BodyInput.read(IO::Memory.new(oversized))
    end
  end

  it "translates body read failures into a TinRelay error" do
    input = IO::Memory.new
    input.close

    expect_raises(Tinrelay::Invalid, /transmission body cannot be read/) do
      Tinrelay::BodyInput.read(input)
    end
  end
end

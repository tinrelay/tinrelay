require "../spec_helper"

describe Tinrelay::BoundedIO do
  it "reads the exact limit and only one extra byte to detect oversize input" do
    Tinrelay::BoundedIO.read(IO::Memory.new("abc"), 3).should eq("abc")

    input = IO::Memory.new("abcdef")
    Tinrelay::BoundedIO.read(input, 3).should be_nil
    input.pos.should eq(4)
  end
end

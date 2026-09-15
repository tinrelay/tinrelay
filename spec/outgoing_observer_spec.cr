require "./spec_helper"

class ObserverUnavailableRemote < Tinrelay::Remote
  def post(path : String, body : String) : String
    raise Tinrelay::TransportUnavailable.new
  end
end

module OutgoingObserverSpec
  def self.with_listener(&)
    root = File.join(
      Dir.tempdir, "tinrelay-observer-#{Process.pid}-#{Tinrelay::Ids.uuid[0, 8]}"
    )
    Dir.mkdir(root, mode: 0o700)
    path = File.join(root, "observer.sock")
    listener = UNIXServer.new(path)
    begin
      yield root, path, listener
    ensure
      listener.close
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  def self.signed_plaintext_size(sender_ship : String, recipient_ship : String,
                                 to_label : String, from_label : String,
                                 body : String) : Int32
    transmission = Tinrelay::SignedTransmission.new(
      "0" * 36, sender_ship, 1, recipient_ship, 1, 2_000_000_000_i64,
      to_label, body, from_label,
      Tinrelay::Crypto.b64(Bytes.new(Tinrelay::Crypto::SIGNATURE_BYTES))
    )
    transmission.to_json.bytesize
  end

  def self.largest_json_hostile_body(sender_ship : String, recipient_ship : String,
                                     to_label : String, from_label : String) : String
    low = 0
    high = Tinrelay::Client::MAX_PLAINTEXT_BYTES
    while low < high
      count = (low + high + 1) // 2
      size = signed_plaintext_size(
        sender_ship, recipient_ship, to_label, from_label, "\u0001" * count
      )
      if size <= Tinrelay::Client::MAX_PLAINTEXT_BYTES
        low = count
      else
        high = count - 1
      end
    end
    body = "\u0001" * low
    while signed_plaintext_size(
            sender_ship, recipient_ship, to_label, from_label, body + "x"
          ) <= Tinrelay::Client::MAX_PLAINTEXT_BYTES
      body += "x"
    end
    body
  end
end

describe Tinrelay::OutgoingObserver do
  it "emits one bounded plaintext event after an accepted send" do
    TinrelaySpec.with_server do |root, origin, _api|
      recipient_ship = "a" * 63
      sender_ship = "b" * 63
      attention_label = "c" * 63
      author_label = "d" * 63
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, recipient_ship)
      beta = TinrelaySpec.admit_contact(root, origin, sender_ship, alpha)
      body = OutgoingObserverSpec.largest_json_hostile_body(
        sender_ship, recipient_ship, attention_label, author_label
      )
      OutgoingObserverSpec.signed_plaintext_size(
        sender_ship, recipient_ship, attention_label, author_label, body
      ).should be <= Tinrelay::Client::MAX_PLAINTEXT_BYTES
      OutgoingObserverSpec.signed_plaintext_size(
        sender_ship, recipient_ship, attention_label, author_label, body + "x"
      ).should be > Tinrelay::Client::MAX_PLAINTEXT_BYTES
      OutgoingObserverSpec.with_listener do |_private_root, socket_path, listener|
        received = Channel(String).new
        spawn do
          socket = listener.accept
          received.send(socket.gets_to_end)
          socket.close
        end
        config_path = File.join(root, "outgoing-observer.json")
        File.write(
          config_path,
          Tinrelay::OutgoingObserver::Config.new(socket_path).to_json
        )
        observer = Tinrelay::OutgoingObserver.from_config(config_path).not_nil!

        envelope = beta.send(
          "#{attention_label}@#{recipient_ship}", body, author_label,
          observer: observer
        )
        raw = TinrelaySpec.receive(received)
        raw.ends_with?('\n').should be_true
        event = JSON.parse(raw).as_h
        event.should eq({
          "contract"        => JSON::Any.new("tinrelay-outgoing-observer-v1"),
          "kind"            => JSON::Any.new("transmission"),
          "transmission_id" => JSON::Any.new(envelope.transmission_id),
          "sender_ship"     => JSON::Any.new(sender_ship),
          "recipient_ship"  => JSON::Any.new(recipient_ship),
          "attention_label" => JSON::Any.new(attention_label),
          "author_label"    => JSON::Any.new(author_label),
          "body"            => JSON::Any.new(body),
        })
        raw.bytesize.should be <= Tinrelay::OutgoingObserver::MAX_EVENT_BYTES
      end
    end
  end

  it "does not observe a transmission whose acceptance is unknown" do
    TinrelaySpec.with_server do |root, origin, _api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      OutgoingObserverSpec.with_listener do |_private_root, socket_path, listener|
        arrived = Channel(Bool).new
        spawn do
          begin
            socket = listener.accept
            socket.close
            arrived.send(true)
          rescue IO::Error
          end
        end
        config_path = File.join(root, "outgoing-observer.json")
        File.write(
          config_path,
          Tinrelay::OutgoingObserver::Config.new(socket_path).to_json
        )
        observer = Tinrelay::OutgoingObserver.from_config(config_path).not_nil!
        unavailable = Tinrelay::Client.new(
          beta.keyring, ObserverUnavailableRemote.new(origin)
        )

        expect_raises(Tinrelay::AcceptanceUnknown) do
          unavailable.send("steward@alpha", "not accepted", observer: observer)
        end
        select
        when arrived.receive
          fail "observer received a transmission before definitive acceptance"
        when timeout(100.milliseconds)
        end
      end
    end
  end

  it "cannot change an accepted send when its socket is unavailable" do
    TinrelaySpec.with_server do |root, origin, _api|
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha")
      beta = TinrelaySpec.admit_contact(root, origin, "beta", alpha)
      private_root = File.join(root, "observer")
      Dir.mkdir(private_root, mode: 0o700)
      config_path = File.join(root, "outgoing-observer.json")
      File.write(
        config_path,
        Tinrelay::OutgoingObserver::Config.new(
          File.join(private_root, "missing.sock")
        ).to_json
      )
      observer = Tinrelay::OutgoingObserver.from_config(config_path).not_nil!

      sent = beta.send("steward@alpha", "still accepted", observer: observer)
      sent.submission_evidence[:state].should eq("accepted")
      event = alpha.radio_wait(
        Tinrelay::Spool.new(File.join(root, "alpha-inbox")), hold_seconds: 0
      )
      event.kind.should eq("transmission")
    end
  end

  it "ignores absent, relative, and non-private observer configuration" do
    root = TinrelaySpec.temporary_root
    begin
      missing = File.join(root, "missing.json")
      Tinrelay::OutgoingObserver.from_config(missing).should be_nil

      relative = File.join(root, "relative.json")
      File.write(relative, %({"socket_path":"observer.sock"}))
      Tinrelay::OutgoingObserver.from_config(relative).should be_nil

      public_root = File.join(root, "public")
      Dir.mkdir(public_root, mode: 0o755)
      public_config = File.join(root, "public.json")
      File.write(
        public_config,
        Tinrelay::OutgoingObserver::Config.new(
          File.join(public_root, "observer.sock")
        ).to_json
      )
      Tinrelay::OutgoingObserver.from_config(public_config).should be_nil

      oversized = File.join(root, "oversized.json")
      File.write(oversized, " " * (Tinrelay::OutgoingObserver::MAX_CONFIG_BYTES + 1))
      Tinrelay::OutgoingObserver.from_config(oversized).should be_nil
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end
end

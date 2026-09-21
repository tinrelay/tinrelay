CREATE TABLE transmissions_v4 (
  id TEXT PRIMARY KEY,
  sender_ship TEXT NOT NULL,
  sender_signing_generation INTEGER NOT NULL,
  recipient_ship TEXT NOT NULL,
  recipient_encryption_generation INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  accepted_at INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'collected', 'expired', 'withdrawn')),
  ciphertext BLOB,
  signature BLOB,
  envelope_digest BLOB NOT NULL,
  FOREIGN KEY (sender_ship, sender_signing_generation)
    REFERENCES ship_radio_keys(ship, generation),
  FOREIGN KEY (recipient_ship, recipient_encryption_generation)
    REFERENCES ship_radio_keys(ship, generation)
) STRICT;

INSERT INTO transmissions_v4(
  id, sender_ship, sender_signing_generation,
  recipient_ship, recipient_encryption_generation,
  created_at, expires_at, accepted_at, state,
  ciphertext, signature, envelope_digest
)
SELECT
  id, sender_ship, sender_signing_generation,
  recipient_ship, recipient_encryption_generation,
  created_at, expires_at, accepted_at, state,
  ciphertext, signature, envelope_digest
FROM transmissions;

DROP TABLE transmissions;

ALTER TABLE transmissions_v4 RENAME TO transmissions;

CREATE INDEX pending_delivery
  ON transmissions(recipient_ship, state, accepted_at);

CREATE INDEX transmissions_cleanup
  ON transmissions(state, expires_at);

CREATE INDEX pending_ciphertext_bytes
  ON transmissions(state, LENGTH(ciphertext))
  WHERE state = 'pending';

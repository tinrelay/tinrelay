module Tinrelay
  module Ids
    SOURCE_KINDS  = {"transmission", "hail", "rejected_transmission"}
    PROTOCOL_UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    TASK_UUID     = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/
    REJECTION_ID  = /\Atr_[0-9a-f]{32}\z/

    def self.source?(kind : String, id : String) : Bool
      return false unless SOURCE_KINDS.includes?(kind)
      kind == "rejected_transmission" ? REJECTION_ID.matches?(id) : PROTOCOL_UUID.matches?(id)
    end
  end
end

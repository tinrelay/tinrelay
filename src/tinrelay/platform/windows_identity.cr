require "c/handleapi"
require "c/processthreadsapi"

@[Link("advapi32")]
lib LibTinrelayToken
  fun OpenProcessToken(
    process : LibC::HANDLE,
    desired_access : LibC::DWORD,
    token : LibC::HANDLE*,
  ) : LibC::BOOL

  fun GetTokenInformation(
    token : LibC::HANDLE,
    information_class : LibC::DWORD,
    information : Void*,
    information_length : LibC::DWORD,
    return_length : LibC::DWORD*,
  ) : LibC::BOOL
end

module Tinrelay
  module WindowsIdentity
    TOKEN_QUERY                       = 0x0008_u32
    TOKEN_USER                        =      1_u32
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000_u32

    def self.current_user_sid : String
      sid_for_process(LibC.GetCurrentProcess) ||
        raise IO::Error.new("could not identify current Windows user")
    end

    def self.same_user_process?(pid : UInt32) : Bool
      process = LibC.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
      return false if process.null?
      begin
        sid_for_process(process) == current_user_sid
      ensure
        LibC.CloseHandle(process)
      end
    rescue
      false
    end

    private def self.sid_for_process(process : LibC::HANDLE) : String?
      token = LibC::HANDLE.null
      return unless LibTinrelayToken.OpenProcessToken(
                      process, TOKEN_QUERY, pointerof(token)
                    ) != 0
      begin
        sid_for_token(token)
      ensure
        LibC.CloseHandle(token)
      end
    end

    private def self.sid_for_token(token : LibC::HANDLE) : String
      needed = 0_u32
      LibTinrelayToken.GetTokenInformation(
        token, TOKEN_USER, Pointer(Void).null, 0, pointerof(needed)
      )
      raise IO::Error.new("could not read Windows user token") if needed == 0

      buffer = Bytes.new(needed)
      unless LibTinrelayToken.GetTokenInformation(
               token, TOKEN_USER, buffer.to_unsafe.as(Void*), needed,
               pointerof(needed)
             ) != 0
        raise RuntimeError.from_winerror("GetTokenInformation")
      end
      sid_to_string(buffer.to_unsafe.as(Pointer(Void*)).value)
    end

    def self.sid_to_string(sid : Void*) : String
      Crystal::System.sid_to_s(sid.as(LibC::SID*))
    end
  end
end

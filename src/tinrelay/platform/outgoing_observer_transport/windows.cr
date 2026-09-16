require "c/fileapi"
require "c/handleapi"
require "c/winbase"
require "crystal/system/windows"

require "../windows_identity"

lib LibTinrelayPipe
  fun GetNamedPipeServerProcessId(pipe : LibC::HANDLE, pid : LibC::DWORD*) : LibC::BOOL
end

module Tinrelay
  module OutgoingObserverTransport
    PIPE_PREFIX = "\\\\.\\pipe\\"

    def self.valid_endpoint?(path : String) : Bool
      return false unless path.starts_with?(PIPE_PREFIX)
      name = path.byte_slice(PIPE_PREFIX.bytesize)
      !name.empty? && !name.includes?('\\') && !name.includes?('/')
    end

    def self.notify(path : String, encoded : String, timeout : Time::Span) : Nil
      handle = LibC.CreateFileW(
        Crystal::System.to_wstr(path),
        LibC::GENERIC_WRITE,
        0,
        nil,
        LibC::OPEN_EXISTING,
        LibC::FILE_FLAG_OVERLAPPED,
        LibC::HANDLE.null
      )
      if handle == LibC::INVALID_HANDLE_VALUE
        raise IO::Error.from_winerror("CreateFileW")
      end

      adopted = false
      io = nil.as(IO::FileDescriptor?)
      begin
        io = IO::FileDescriptor.new(handle.address, close_on_finalize: false)
        adopted = true
        pid = uninitialized LibC::DWORD
        unless LibTinrelayPipe.GetNamedPipeServerProcessId(handle, pointerof(pid)) != 0 &&
               WindowsIdentity.same_user_process?(pid)
          raise IO::Error.new("observer pipe is not owned by the current user")
        end
        io.not_nil!.write_timeout = timeout
        io.not_nil!.puts(encoded)
        io.not_nil!.flush
      ensure
        if adopted
          io.not_nil!.close
        else
          LibC.CloseHandle(handle)
        end
      end
    end
  end
end

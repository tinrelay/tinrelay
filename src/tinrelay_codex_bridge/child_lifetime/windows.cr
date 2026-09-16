require "c/handleapi"
require "c/jobapi2"
require "c/processthreadsapi"

module TinrelayCodexBridge
  class ChildLifetime
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000_u32

    @job = LibC::HANDLE.null

    def initialize
      @job = LibC.CreateJobObjectW(nil, nil)
      if @job.null?
        raise RuntimeError.from_winerror("CreateJobObjectW")
      end

      information = LibC::JOBOBJECT_EXTENDED_LIMIT_INFORMATION.new
      information.basicLimitInformation.limitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
      unless LibC.SetInformationJobObject(
               @job,
               LibC::JOBOBJECTINFOCLASS::ExtendedLimitInformation,
               pointerof(information).as(Void*),
               sizeof(LibC::JOBOBJECT_EXTENDED_LIMIT_INFORMATION).to_u32
             ) != 0
        LibC.CloseHandle(@job)
        @job = LibC::HANDLE.null
        raise RuntimeError.from_winerror("SetInformationJobObject")
      end
      unless LibC.AssignProcessToJobObject(@job, LibC.GetCurrentProcess) != 0
        LibC.CloseHandle(@job)
        @job = LibC::HANDLE.null
        raise RuntimeError.from_winerror("AssignProcessToJobObject")
      end

      # The bridge itself owns this kill-on-close Job for its complete lifetime.
      # Crystal children inherit membership because they do not request
      # CREATE_BREAKAWAY_FROM_JOB. The operating system closes the handle when
      # the bridge exits; a finalizer here could kill a still-running bridge.
    end
  end
end

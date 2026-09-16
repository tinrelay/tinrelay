module TinrelaySpec
  module WindowsAcl
    def self.current_user_only(path : String) : Nil
      set(path, "D:P(A;;FA;;;#{Tinrelay::WindowsIdentity.current_user_sid})")
    end

    def self.permissive(path : String) : Nil
      sid = Tinrelay::WindowsIdentity.current_user_sid
      set(path, "D:P(A;;FA;;;#{sid})(A;;GR;;;WD)")
    end

    def self.foreign_owner(path : String) : Nil
      sid = Tinrelay::WindowsIdentity.current_user_sid
      set(
        path,
        "O:BAD:P(A;;FA;;;#{sid})(A;;FA;;;SY)",
        Tinrelay::WindowsPrivateFile::OWNER_SECURITY_INFORMATION |
        Tinrelay::WindowsPrivateFile::DACL_SECURITY_INFORMATION |
        Tinrelay::WindowsPrivateFile::PROTECTED_DACL_SECURITY_INFORMATION
      )
    end

    private def self.set(
      path : String,
      sddl : String,
      information = Tinrelay::WindowsPrivateFile::DACL_SECURITY_INFORMATION |
        Tinrelay::WindowsPrivateFile::PROTECTED_DACL_SECURITY_INFORMATION,
    ) : Nil
      descriptor = Pointer(Void).null
      unless LibTinrelaySecurity.ConvertStringSecurityDescriptorToSecurityDescriptorW(
               Crystal::System.to_wstr(sddl),
               Tinrelay::WindowsPrivateFile::SDDL_REVISION,
               pointerof(descriptor),
               nil
             ) != 0
        raise RuntimeError.from_winerror(
          "ConvertStringSecurityDescriptorToSecurityDescriptorW"
        )
      end
      begin
        unless LibTinrelaySecurity.SetFileSecurityW(
                 Crystal::System.to_wstr(path), information, descriptor
               ) != 0
          raise RuntimeError.from_winerror("SetFileSecurityW")
        end
      ensure
        LibC.LocalFree(descriptor)
      end
    end
  end
end

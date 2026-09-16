require "crystal/system/windows"

require "./windows_identity"

@[Link("advapi32")]
lib LibTinrelaySecurity
  fun ConvertStringSecurityDescriptorToSecurityDescriptorW(
    descriptor : UInt16*, revision : UInt32, security_descriptor : Void**,
    descriptor_size : UInt32*,
  ) : Int32

  fun GetFileSecurityW(
    path : UInt16*, requested_information : UInt32, security_descriptor : Void*,
    descriptor_size : UInt32, needed_size : UInt32*,
  ) : Int32

  fun SetFileSecurityW(
    path : UInt16*, security_information : UInt32, security_descriptor : Void*,
  ) : Int32

  fun GetSecurityDescriptorDacl(
    security_descriptor : Void*, dacl_present : Int32*, dacl : Void**,
    dacl_defaulted : Int32*,
  ) : Int32

  fun GetSecurityDescriptorOwner(
    security_descriptor : Void*, owner : Void**, owner_defaulted : Int32*,
  ) : Int32

  fun GetAclInformation(
    acl : Void*, information : Void*, information_length : UInt32,
    information_class : UInt32,
  ) : Int32

  fun GetAce(acl : Void*, index : UInt32, ace : Void**) : Int32
end

module Tinrelay
  module WindowsPrivateFile
    OWNER_SECURITY_INFORMATION          = 0x00000001_u32
    DACL_SECURITY_INFORMATION           = 0x00000004_u32
    PROTECTED_DACL_SECURITY_INFORMATION = 0x80000000_u32
    SDDL_REVISION                       =          1_u32
    ACL_SIZE_INFORMATION_CLASS          =          2_u32
    ACCESS_ALLOWED_ACE_TYPE             =           0_u8
    ACCESS_DENIED_ACE_TYPE              =           1_u8
    ACCESS_ACE_SID_OFFSET               =              8
    LOCAL_SYSTEM_SID                    = "S-1-5-18"

    private struct AclSizeInformation
      property ace_count = 0_u32
      property bytes_in_use = 0_u32
      property bytes_free = 0_u32
    end

    def self.secure(path : String) : Nil
      descriptor = Pointer(Void).null
      sddl = expected_sddl(path)
      unless LibTinrelaySecurity.ConvertStringSecurityDescriptorToSecurityDescriptorW(
               Crystal::System.to_wstr(sddl), SDDL_REVISION, pointerof(descriptor), nil
             ) != 0
        raise RuntimeError.from_winerror(
          "ConvertStringSecurityDescriptorToSecurityDescriptorW"
        )
      end

      begin
        information = OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION |
                      PROTECTED_DACL_SECURITY_INFORMATION
        unless LibTinrelaySecurity.SetFileSecurityW(
                 Crystal::System.to_wstr(path), information, descriptor
               ) != 0
          raise RuntimeError.from_winerror("SetFileSecurityW")
        end
      ensure
        LibC.LocalFree(descriptor)
      end
    end

    def self.private?(path : String) : Bool
      descriptor = read_descriptor(path)
      begin
        current_user_owner?(descriptor) && private_dacl?(descriptor)
      ensure
        LibC.free(descriptor)
      end
    rescue
      false
    end

    private def self.current_user_sid : String
      WindowsIdentity.current_user_sid
    end

    private def self.expected_sddl(path : String) : String
      inheritance = File.directory?(path) ? "OICI" : ""
      sid = current_user_sid
      "O:#{sid}D:P(A;#{inheritance};FA;;;#{sid})(A;#{inheritance};FA;;;SY)"
    end

    private def self.read_descriptor(path : String) : Pointer(Void)
      needed = 0_u32
      wide_path = Crystal::System.to_wstr(path)
      LibTinrelaySecurity.GetFileSecurityW(
        wide_path, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
        Pointer(Void).null, 0_u32,
        pointerof(needed)
      )
      raise IO::Error.new("could not read private-file ACL") if needed == 0

      descriptor = LibC.malloc(needed).as(Pointer(Void))
      unless LibTinrelaySecurity.GetFileSecurityW(
               wide_path,
               OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
               descriptor, needed,
               pointerof(needed)
             ) != 0
        LibC.free(descriptor)
        raise RuntimeError.from_winerror("GetFileSecurityW")
      end
      descriptor
    end

    private def self.current_user_owner?(descriptor : Pointer(Void)) : Bool
      owner = Pointer(Void).null
      defaulted = 0
      return false unless LibTinrelaySecurity.GetSecurityDescriptorOwner(
                            descriptor, pointerof(owner), pointerof(defaulted)
                          ) != 0
      !owner.null? && WindowsIdentity.sid_to_string(owner) == current_user_sid
    end

    private def self.private_dacl?(descriptor : Pointer(Void)) : Bool
      present = 0
      defaulted = 0
      acl = Pointer(Void).null
      return false unless LibTinrelaySecurity.GetSecurityDescriptorDacl(
                            descriptor, pointerof(present), pointerof(acl),
                            pointerof(defaulted)
                          ) != 0
      return false if present == 0 || acl.null?

      information = AclSizeInformation.new
      return false unless LibTinrelaySecurity.GetAclInformation(
                            acl, pointerof(information).as(Void*),
                            sizeof(AclSizeInformation).to_u32,
                            ACL_SIZE_INFORMATION_CLASS
                          ) != 0

      current = current_user_sid
      current_allowed = false
      information.ace_count.times do |index|
        ace = Pointer(Void).null
        return false unless LibTinrelaySecurity.GetAce(
                              acl, index, pointerof(ace)
                            ) != 0
        case ace.as(UInt8*)[0]
        when ACCESS_ALLOWED_ACE_TYPE
          sid = WindowsIdentity.sid_to_string(
            (ace.as(UInt8*) + ACCESS_ACE_SID_OFFSET).as(Void*)
          )
          return false unless sid == current || sid == LOCAL_SYSTEM_SID
          current_allowed = true if sid == current
        when ACCESS_DENIED_ACE_TYPE
          # Deny entries grant no access and therefore do not weaken privacy.
        else
          return false
        end
      end
      current_allowed
    end
  end
end

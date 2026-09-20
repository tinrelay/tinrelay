require "../spec_helper"

{% if flag?(:win32) %}
  describe Tinrelay::WindowsPrivateFile do
    it "distinguishes the current process token from LocalSystem" do
      Tinrelay::WindowsIdentity.same_user_process?(Process.pid.to_u32).should be_true
      Tinrelay::WindowsIdentity.same_user_process?(4_u32).should be_false
    end

    it "replaces an inherited ACL with the current user and LocalSystem only" do
      root = TinrelaySpec.temporary_root
      path = File.join(root, "private")
      begin
        File.write(path, "private")
        Tinrelay::WindowsPrivateFile.private?(path).should be_false

        Tinrelay::WindowsPrivateFile.secure(path)
        Tinrelay::WindowsPrivateFile.private?(path).should be_true
      ensure
        FileUtils.rm_r(root) if Dir.exists?(root)
      end
    end

    it "derives identity from the process token when USERNAME is absent or spoofed" do
      original = ENV["USERNAME"]?
      root = TinrelaySpec.temporary_root
      begin
        [nil, "definitely-not-the-current-account"].each do |value|
          if value
            ENV["USERNAME"] = value
          else
            ENV.delete("USERNAME")
          end
          path = File.join(root, Random::Secure.hex(4))
          File.write(path, "private")
          Tinrelay::WindowsPrivateFile.secure(path)
          Tinrelay::WindowsPrivateFile.private?(path).should be_true
        end
      ensure
        if original
          ENV["USERNAME"] = original
        else
          ENV.delete("USERNAME")
        end
        FileUtils.rm_r(root) if Dir.exists?(root)
      end
    end

    it "accepts current-user-only access and rejects another allowed principal" do
      root = TinrelaySpec.temporary_root
      path = File.join(root, "private")
      begin
        File.write(path, "private")
        TinrelaySpec::WindowsAcl.current_user_only(path)
        Tinrelay::WindowsPrivateFile.private?(path).should be_true

        TinrelaySpec::WindowsAcl.permissive(path)
        Tinrelay::WindowsPrivateFile.private?(path).should be_false
      ensure
        FileUtils.rm_r(root) if Dir.exists?(root)
      end
    end

    it "rejects a foreign owner even when only the current user can access the file" do
      root = TinrelaySpec.temporary_root
      path = File.join(root, "foreign-owner")
      begin
        File.write(path, "private")
        TinrelaySpec::WindowsAcl.foreign_owner(path)
        Tinrelay::WindowsPrivateFile.private?(path).should be_false

        Tinrelay::WindowsPrivateFile.secure(path)
        Tinrelay::WindowsPrivateFile.private?(path).should be_true
      ensure
        FileUtils.rm_r(root) if Dir.exists?(root)
      end
    end

    it "makes new descendants private through directory inheritance" do
      root = TinrelaySpec.temporary_root
      child_directory = File.join(root, "child")
      grandchild = File.join(child_directory, "grandchild")
      begin
        Tinrelay::WindowsPrivateFile.secure(root)
        Dir.mkdir(child_directory)
        File.write(grandchild, "private before an explicit child secure")
        Tinrelay::WindowsPrivateFile.private?(child_directory).should be_true
        Tinrelay::WindowsPrivateFile.private?(grandchild).should be_true
      ensure
        FileUtils.rm_r(root) if Dir.exists?(root)
      end
    end

    it "replaces a private file through the write-through storage boundary" do
      root = TinrelaySpec.temporary_root
      source = File.join(root, "source")
      destination = File.join(root, "destination")
      begin
        File.write(source, "new")
        File.write(destination, "old")
        Tinrelay::PrivateStorage.replace(source, destination)
        File.read(destination).should eq("new")
        File.exists?(source).should be_false
      ensure
        FileUtils.rm_r(root) if Dir.exists?(root)
      end
    end

    it "maps a missing replacement source to File::NotFoundError" do
      root = TinrelaySpec.temporary_root
      source = File.join(root, "missing")
      destination = File.join(root, "destination")
      begin
        error = expect_raises(File::NotFoundError) do
          Tinrelay::PrivateStorage.replace(source, destination)
        end
        error.file.should eq(source)
        error.other.should eq(destination)
      ensure
        FileUtils.rm_r(root) if Dir.exists?(root)
      end
    end
  end
{% end %}

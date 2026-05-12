class Autofuse < Formula
  desc "SSHFS mount manager with auto-discovery, WoL, auto-heal, and agent-friendly CLI"
  homepage "https://github.com/Fasen24-AI/autofuse"
  version "4.1"
  url "https://github.com/Fasen24-AI/autofuse/archive/refs/tags/v4.1.tar.gz"
  sha256 "021408166d59e6ba9d7e831985c90daae3462d63ff752ce0ed77c1ad8a4255fd"

  depends_on "sshfs"
  # macFUSE or FUSE-T required but handled at runtime

  def install
    bin.install "cli/autofuse"
    libexec.install "mount.sh", "discover.sh", "config.json"
    # Patch autofuse to find scripts in libexec
    inreplace bin/"autofuse", "SCRIPT_DIR_PLACEHOLDER", libexec.to_s
  end

  def caveats
    <<~EOS
      AutoFuse requires macFUSE or FUSE-T:
        brew install macfuse    # OR
        brew install fuse-t fuse-t-sshfs

      After installation, configure your workstations:
        autofuse add            # Interactive wizard
        autofuse config         # Edit config directly

      For the GUI menu bar app, download AutoFuse.app from:
        https://github.com/Fasen24-AI/autofuse/releases
    EOS
  end

  test do
    assert_match "AutoFuse CLI v#{version}", shell_output("#{bin}/autofuse version")
  end
end

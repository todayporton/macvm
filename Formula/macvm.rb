# Template for a Homebrew tap. Set `url` and `sha256` for each release.
class Macvm < Formula
  desc "Run macOS GUI tests in a shared headless Tart VM, leaving the host GUI alone"
  homepage "https://github.com/poTKC/macvm"
  url "https://github.com/poTKC/macvm/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_AT_RELEASE"
  license "MIT"

  depends_on :macos
  depends_on arch: :arm64
  depends_on xcode: :build

  def install
    system "make", "install", "PREFIX=#{prefix}"
  end

  def caveats
    <<~EOS
      Run `macvm setup` to install Tart if needed and create the VM (about 26 GB download).
      Before `brew uninstall macvm`, run `macvm teardown --yes` to remove user data,
      adding --delete-vm to delete the VM as well.
    EOS
  end

  test do
    assert_match "macvm", shell_output("#{bin}/macvm version")
  end
end

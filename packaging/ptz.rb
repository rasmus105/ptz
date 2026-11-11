# Homebrew formula template; the release workflow fills in the @...@ fields
# and pushes the result to rasmus105/homebrew-tap.
class Ptz < Formula
  desc "Render PDFs in the terminal"
  homepage "https://github.com/rasmus105/ptz"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/rasmus105/ptz/releases/download/v@VERSION@/ptz-@VERSION@-aarch64-macos.tar.gz"
      sha256 "@SHA256_AARCH64_MACOS@"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/rasmus105/ptz/releases/download/v@VERSION@/ptz-@VERSION@-x86_64-linux.tar.gz"
      sha256 "@SHA256_X86_64_LINUX@"
    end
  end

  def install
    # ptz finds PDFium in ../lib relative to itself; libexec keeps PDFium out
    # of the shared Homebrew lib/ directory.
    libexec.install "bin", "lib"
    bin.install_symlink libexec/"bin/ptz"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/ptz --version")
  end
end

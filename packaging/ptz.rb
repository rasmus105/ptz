# Homebrew formula template; the release workflow fills in the @...@ fields
# and pushes the result to rasmus105/homebrew-tap.
class Ptz < Formula
  desc "View documents and images in the terminal"
  homepage "https://github.com/rasmus105/ptz"
  license "AGPL-3.0-or-later"

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
    bin.install "bin/ptz"
    bash_completion.install "completions/ptz.bash" => "ptz"
    zsh_completion.install "completions/_ptz"
    fish_completion.install "completions/ptz.fish"
    pkgshare.install Dir["share/ptz/*"]
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/ptz --version")
  end
end

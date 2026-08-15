class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.208"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.208/nb-arm64-apple-darwin.tar.gz"
      sha256 "3fd66ad2d2fbec5a3d75aca02e6f7a0d0793a4a21f16b1ece3baf5203ee610dd"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.208/nb-x86_64-apple-darwin.tar.gz"
      sha256 "67949717a600102302bd0cefe3f79351a3ca7631798a4ce475c4fcb005b6ef9d"
    end
  end


  def install
    bin.install "nb"
  end

  def post_install
    ohai "Run 'nb init' to create the nanobrew directory tree"
  end

  test do
    assert_match "nanobrew", shell_output("#{bin}/nb help")
  end
end

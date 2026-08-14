class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.206"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.206/nb-arm64-apple-darwin.tar.gz"
      sha256 "2b99242232a7442ff8013f46eb44452d807f7b2fb073ea4f7147d35c90d85b17"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.206/nb-x86_64-apple-darwin.tar.gz"
      sha256 "8ff33d557c6ea946b0db47d4f047331da3ff78e25e946e27483d27f8efca4726"
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

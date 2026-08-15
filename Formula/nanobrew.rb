class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.207"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.207/nb-arm64-apple-darwin.tar.gz"
      sha256 "0efab604af5d0e2fa18bbbcfe34e4f09cf9dd866b061288f6139f65248195ba7"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.207/nb-x86_64-apple-darwin.tar.gz"
      sha256 "3d3be86c9eaa05751f03326c65f4f4be8e3202d229933a7ec7d6fe70fa3f1e14"
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

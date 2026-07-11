class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.201"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.201/nb-arm64-apple-darwin.tar.gz"
      sha256 "6e00f459718951d7a6d17e27ce99e4c7e769d79ef5bd46a514186b325172c8ab"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.201/nb-x86_64-apple-darwin.tar.gz"
      sha256 "c71123cf9dd718ed0f20b459be4107f48895d5c627f339ef38e734befff1fce8"
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

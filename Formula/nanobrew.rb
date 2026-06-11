class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.195"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.195/nb-arm64-apple-darwin.tar.gz"
      sha256 "3122b6209899b416aba771dba362e841432ec42b7bbe5bd9dcbe24eae5bb3958"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.195/nb-x86_64-apple-darwin.tar.gz"
      sha256 "ce16959a67f9d6e9ea22613ae19cd566633568b0534e26930ee93fb484cb434f"
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

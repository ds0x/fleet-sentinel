# Homebrew formula for fleet-sentinel.
#
# This file lives in a tap repo:  github.com/ds0x/homebrew-tap
# (Homebrew's convention: a tap named "ds0x/tap" must live in a GitHub
#  repo literally named "homebrew-tap" under that account.)
#
# After publishing a release tarball at
#   https://github.com/ds0x/fleet-sentinel/archive/refs/tags/v0.1.0.tar.gz
# update `url` and `sha256` below, commit, push the tap repo.
#
# End user installs:
#   brew install ds0x/tap/fleet-sentinel
class FleetSentinel < Formula
  desc "Fleet-enrolled, GUI-ready Debian VM on Apple Silicon, in one command"
  homepage "https://github.com/ds0x/fleet-sentinel"
  url "https://github.com/ds0x/fleet-sentinel/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_SHA256_OF_TARBALL"
  license "MIT"
  version "0.1.0"

  # Runtime dependencies. Homebrew will pull these automatically.
  depends_on "cirruslabs/cli/tart"
  depends_on "fleetdm/fleet/fleetctl"
  depends_on "hudochenkov/sshpass/sshpass"

  def install
    bin.install "bin/fleet-sentinel"
  end

  test do
    assert_match "fleet-sentinel #{version}", shell_output("#{bin}/fleet-sentinel --version")
  end

  def caveats
    <<~EOS
      fleet-sentinel needs Apple Silicon (M-series) to run Tart VMs.

      First use will pull the Debian image (~1.5 GB) from ghcr.io:
        ghcr.io/ds0x/fleet-sentinel-debian:latest

      Usage:
        fleet-sentinel https://fleet.example.com  YOUR_ENROLL_SECRET

      Each invocation tears down the previous VM and creates a fresh one,
      so the same hostname enrolls as a NEW host in Fleet every time.
    EOS
  end
end

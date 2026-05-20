# Homebrew formula for fleet-sentinel.
#
# This file lives in a tap repo:  github.com/ds0x/homebrew-tap
# (Homebrew's convention: a tap named "ds0x/tap" must live in a GitHub
#  repo literally named "homebrew-tap" under that account.)
#
# After publishing a release tarball at
#   https://github.com/ds0x/fleet-sentinel/archive/refs/tags/v0.1.2.tar.gz
# update `url` and `sha256` below, commit, push the tap repo.
#
# End user installs:
#   brew install ds0x/tap/fleet-sentinel
class FleetSentinel < Formula
  desc "Fleet-enrolled, GUI-ready Debian VM on Apple Silicon, in one command"
  homepage "https://github.com/ds0x/fleet-sentinel"
  url "https://github.com/ds0x/fleet-sentinel/archive/refs/tags/v0.1.2.tar.gz"
  sha256 "c67751ed5cd25f9e96cbee7479c9cbc8a3a7e99572fadfeddd1b69a6e3f928f1"
  license "MIT"
  version "0.1.2"

  # Runtime dependencies. Homebrew pulls all three automatically.
  # NOTE: fleetctl isn't in homebrew-core (the `fleet-cli` formula in core is
  # Rancher's Kubernetes Fleet — a different product). The dependency below
  # uses ds0x's own tap. Requires the tap repo to be named `homebrew-fleetctl`.
  depends_on "cirruslabs/cli/tart"
  depends_on "ds0x/fleetctl/fleetctl"
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

      Dependency taps (one-time consent, required by Homebrew):
        brew tap cirruslabs/cli     # provides tart
        brew tap ds0x/fleetctl      # provides fleetctl

      First use will pull the Ubuntu image (~1.8 GB) from ghcr.io:
        ghcr.io/ds0x/fleet-sentinel-ubuntu:latest

      Usage:
        fleet-sentinel https://fleet.example.com  YOUR_ENROLL_SECRET

      Each invocation tears down the previous VM and creates a fresh one,
      so the same hostname enrolls as a NEW host in Fleet every time.
    EOS
  end
end

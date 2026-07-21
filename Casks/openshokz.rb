# Homebrew cask for OpenShokz.
#
# Publish this file to the DanielSinclair/homebrew-tap repo (Casks/openshokz.rb)
# as part of each release so `brew install --cask danielsinclair/tap/openshokz`
# works, and update `sha256` per release (shasum -a 256 dist/OpenShokz.dmg).
cask "openshokz" do
  version "1.0.0"
  sha256 "91f80790b37e3302dcd7f1d74f21310602aca40da309dbd8be6527af7be9aff1"

  url "https://github.com/DanielSinclair/openshokz/releases/download/v#{version}/OpenShokz.dmg"
  name "OpenShokz"
  desc "Download YouTube videos and podcasts to Shokz"
  homepage "https://danielsinclair.github.io/openshokz/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "OpenShokz.app"

  zap trash: [
    "~/Library/Application Support/OpenShokz",
    "~/Library/Caches/app.openshokz.OpenShokz",
    "~/Library/HTTPStorages/app.openshokz.OpenShokz",
    "~/Library/Preferences/app.openshokz.OpenShokz.plist",
    "~/Library/Saved Application State/app.openshokz.OpenShokz.savedState",
  ]
end

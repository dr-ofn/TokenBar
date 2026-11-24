# Homebrew cask template for TokenBar, to be placed in your own tap.
#
# Tap repository: dr-ofn/homebrew-tap  ->  Casks/tokenbar.rb
# Install:        brew install --cask dr-ofn/tap/tokenbar
#
# Per release: set `version` and `sha256`. scripts/release.sh prints both
# (the sha256 is also in dist/TokenBar-VERSION.zip.sha256).
#
# This cask is for a third-party tap only. Homebrew's official cask repository
# (homebrew/cask) disables casks that fail Gatekeeper checks, and TokenBar is
# not signed with a Developer ID or notarized.
cask "tokenbar" do
  version "9.0.6"
  sha256 "REPLACE_WITH_SHA256_OF_TokenBar-9.0.6.zip"

  url "https://github.com/dr-ofn/TokenBar/releases/download/v#{version}/TokenBar-#{version}.zip"
  name "TokenBar"
  desc "Menu bar app that counts AI coding tool token usage from local logs"
  homepage "https://github.com/dr-ofn/TokenBar"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma
  # Releases are universal (scripts/release.sh VERSION --universal): arm64 and x86_64.

  app "TokenBar.app"

  zap trash: [
    "~/Library/Application Support/TokenBar",
    "~/Library/Caches/TokenBar",
    "~/Library/Preferences/io.github.tokenbar.plist",
  ]

  caveats <<~EOS
    TokenBar is not signed with an Apple Developer ID and is not notarized, so
    macOS Gatekeeper blocks it the first time you open it. Homebrew no longer
    offers a flag to skip this (--no-quarantine was deprecated in 5.0.0).

    To open it once:
      1. Open TokenBar and dismiss the warning.
      2. System Settings > Privacy & Security, scroll down, click "Open Anyway",
         then confirm with "Open".

    Or, if you trust the source, clear the download flag from Terminal:
      xattr -dr com.apple.quarantine /Applications/TokenBar.app

    More: https://support.apple.com/en-us/102445
  EOS
end

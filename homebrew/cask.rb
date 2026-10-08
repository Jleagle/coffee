# coffee shipped as a cask of a prebuilt Coffee.app up to 0.0.10 and is now a
# formula compiled on install. This cask stays in the tap, disabled, so that
# `brew upgrade` tells existing cask installs how to move to the formula. The
# release workflow copies it to the Jleagle/homebrew-coffee tap as
# Casks/coffee.rb unchanged.
cask "coffee" do
  version "0.0.10"
  sha256 "3e18f636c310ffc6efd658aedc16d1ad21fdad18878b2a4b5a85eebec641182e"

  url "https://github.com/Jleagle/coffee/releases/download/v#{version}/coffee_#{version}_darwin_all.tar.gz"
  name "Coffee"
  desc "Menu bar app for ordering from the coffee shop"
  homepage "https://github.com/Jleagle/coffee"

  # Installing the formula then prints how to run it: `brew services start coffee`.
  disable! date:                "2026-10-08",
           because:             "is now a formula; uninstall this cask, then install the replacement below",
           replacement_formula: "jleagle/coffee/coffee"

  depends_on macos: :ventura

  app "Coffee.app"

  # Quit the running app before `brew uninstall --cask coffee` removes it.
  uninstall quit: "com.jleagle.coffee"
end

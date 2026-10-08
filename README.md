# coffee

### Install

```
brew install Jleagle/coffee/coffee
brew services start coffee
```

Homebrew compiles Coffee.app from source on your machine, and `brew services`
runs it now and at every login. After `brew upgrade coffee`, run
`brew services restart coffee` to pick up the new version.

### Upgrading from the cask

Up to 0.0.10 coffee was a cask of a prebuilt Coffee.app in /Applications.
`brew upgrade` now reports that cask as disabled; swap to the formula with

```
brew uninstall --cask coffee
brew install Jleagle/coffee/coffee
brew services start coffee
```

Uninstalling the cask quits Coffee and removes /Applications/Coffee.app, so
also remove Coffee from System Settings > General > Login Items if you added it
there.

### Install from code

```
./run.sh
```

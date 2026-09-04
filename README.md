# coffee

```
brew install Jleagle/coffee/coffee
brew services start coffee # menu bar app, now + at every login
```

Requires the `COFFEE_PROJECT_ID` and `COFFEE_API_KEY` environment variables,
and a session created with `coffee set-token --token <refresh-token>`.

### Develop:

```
cd macos
swift run coffee-menubar
```

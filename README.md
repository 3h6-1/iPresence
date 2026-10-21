<p align="center">
  <img src="assets/ipresence-icon.png" width="128px" height="128px">
</p>
<h1 align="center">iPresence — rootless port</h1>

Original project by [kainograze](https://github.com/kainograze/iPresence).
Rootless port and updates by [3h6_1](https://github.com/3h6-1). See [AUTHORS](AUTHORS).

iPresence shares the iPhone's current listening activity in Apple Music with Discord. This fork
updates the original 32-bit project for arm64 and arm64e rootless jailbreaks.
Version 2.1 uses the official Discord Social SDK and OAuth2 with PKCE. Sign in
through Discord's consent screen; iPresence never asks for your personal
Discord account/session token. It works entirely on the iPhone.

## Build
   
```sh
brew install ldid dpkg
make test
make package
```

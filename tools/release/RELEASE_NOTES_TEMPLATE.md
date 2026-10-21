SIMbiogenesis {version} (commit {commit})

## Install

1. Download the game for your computer:
   - **Windows:** `SIMbiogenesis-{version}-windows.zip`. Unzip it anywhere and run `SIMbiogenesis.exe`.
   - **macOS:** `SIMbiogenesis-{version}-macos.zip`. Unzip it, move `SIMbiogenesis.app` where you like,
     then **right-click → Open** the first time. The build is not notarized, so macOS warns about it once.
     If macOS says the app "is damaged", run `xattr -cr SIMbiogenesis.app` in Terminal and open it again.
   - **Linux:** `SIMbiogenesis-{version}-linux.zip`. Unzip it and run `./SIMbiogenesis.x86_64`.
2. **Optional: the art add-on.** Download the `simbiogenesis-art-*.pck` files and put them in the
   **same folder as the game** (on macOS: next to `SIMbiogenesis.app`). They add the built-in SOAK
   festival and Mars maps, the detailed models, the Starshade and the animated people. The same
   files work on every OS. Without them the game still runs; anything that needs the art uses a
   simple stand-in.
3. **Optional: a friend's worlds.** Drop their `.simpack.zip` onto the game window (or press
   **Share… → Install a pack** in the launch hub). Their worlds arrive with the map data they need,
   so they open looking the way they did on your friend's computer.

You need a GPU with Vulkan (on macOS, Metal). The first visit to a new place downloads its map
data; after that the place loads offline.

## Checksums

`SHA256SUMS.txt` lists the SHA-256 of every file in this release.

# Portable library and app copy

How to carry Miles on an external drive (ADR 0012). Everything here is already enforced by the code; this page is the user-facing procedure.

## Set up
1. Format the drive APFS or HFS+ (exFAT and network shares are refused as library locations).
2. In Miles, **New Library…** and choose a folder on the drive, for example `/Volumes/Travel/Miles`. The library folder then holds the database, thumbnails, backups and the lock file.
3. Add the drive's folders as roots. Roots are stored as drive identity plus relative path, so they keep working when the drive mounts under another name or on another Mac.
4. Copy `Miles.app` to the drive, next to the library folder (for example `/Volumes/Travel/Miles.app`). Update the copy whenever you update the app on your main Mac (see Versions).

Image holdbacks (ADR 0006) live in a `Miles` folder at the top of the volume of the file they came from, not always inside the library folder.

## Using it on another Mac
1. Connect the drive and open `Miles.app` from it. Run the copy only on a Mac whose macOS meets the minimum.
2. The registry of libraries is per Mac, and there is no UI yet to register an existing library on a second Mac. Until there is, use the CLI with the folder directly (`miles-cli --library /Volumes/Travel/Miles <command>`).
3. Quit Miles before unplugging. Closing the app, or ejecting the drive while it is open, closes the library first so the lock is released and the database is left consistent.

## Drive not connected
- The library menu shows the library, and the window says the drive is not connected. Nothing is created in its place.
- Connecting the drive reopens the library automatically. If a root's drive is missing, its files stay in the index and search; they are never marked missing, and the root is rescanned when the drive returns.
- `miles-cli library status` and `miles-cli root list` report the same thing.

## Stale lock
A crash, a pulled cable or a forced quit leaves `lock.json` behind.
- Same Mac, process gone: cleared automatically.
- Another Mac, or a process that still looks alive: Miles asks. Take over only if you are sure nothing else has the library open. CLI: `miles-cli --take-over-lock <command>`.
- Takeover never overrides the version gate below.

## Versions
- The database records its schema version. A copy of Miles older than the library refuses to open it ("update Miles") and changes nothing.
- A newer copy takes a backup into `backups/` first, then migrates. After that, older copies, including an older app copy on the drive, are refused.
- Keep the copy on the drive at least as new as the app on your main Mac.

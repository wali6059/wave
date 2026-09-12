# Screenshots

Empty on purpose.

The interface in this repository has never been rendered — it was written in a
Linux container with no macOS and no Swift toolchain (see
[`../docs/VERIFICATION.md`](../docs/VERIFICATION.md)). Putting mockups here and
calling them screenshots of the finished app would be exactly the thing the
brief asked not to do.

To produce the real set once you have Wave running:

```sh
./Scripts/capture-screenshots.sh
```

It walks through each required state — first-run permission, multiple active
applications, output picker open, disconnected-device recovery, and the empty
state — in both light and dark appearance, and writes them here.

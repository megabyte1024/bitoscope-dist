# Bitoscope distributions

Ready-to-install packages of [Bitoscope](https://github.com/megabyte1024/bitoscope), an open-source
logic analyzer application.

Each package contains:

- the Bitoscope application with all its protocol decoders and the demo driver
- the FNIRSI DLA-16 driver ([bitoscope-fnirsi-dla](https://github.com/megabyte1024/bitoscope-fnirsi-dla))
- the sigrok bridge driver for USB logic analyzers supported by libsigrok
  ([bitoscope-sigrok-bridge](https://github.com/megabyte1024/bitoscope-sigrok-bridge))

## Download

Packages are on the [Releases](../../releases) page:

| File | System |
|---|---|
| `bitoscope-<version>-windows-x64-setup.exe` | Windows 10 and 11, 64-bit: setup program |
| `bitoscope-<version>-windows-x64.msi` | Windows 10 and 11, 64-bit: Windows Installer package |
| `bitoscope-<version>-windows-x64.zip` | Windows 10 and 11, 64-bit: portable folder |
| `bitoscope-<version>-linux-x86_64.AppImage` | Linux, x86-64 |

The Windows setup program and the msi installer let you choose between installing for all users
(needs administrator rights) and only for yourself (no administrator rights needed), and the folder.

Nightly builds of the newest sources are on the pre-release "nightly", with `nightly` in place of
the version in each file name. On Windows they install as a separate program, "Bitoscope Nightly",
beside a release.

## Licence

MIT, see `LICENSE`. The packages contain programs under several licences, among them
GPL-3.0-or-later; each package carries all of them in its `licenses` folder.

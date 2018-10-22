# Resolving dependencies

`machinery` has few dependencies and tries to be self-contained as
much as possible.

## Web Server

To benefit from the web API, you will need to arrange for the `til` to be
accessible from this directory.  Just issue the following command in this
directory is enough:

    git clone https://github.com/efrecon/til

The web server in the `til` relies on the logger module from `tcllib`,
meaning that you will also need `tcllib` installed on your system.
But this is anyhow already needed for YAML parsing.

## Mounting

`machinery` is able to mount in-process and out-process. When mounting out of
the process, the preferred behaviour, `machinery` relies on a number of FUSE
helpers (see below). In addition, `machinery` will only cleanup on when
interrupted with `CTRL+C` if `Tclx` is present (e.g. `tclx` package on Ubuntu).
When mounting inside the process, `machinery` requires the TclVFS package (e.g.
`tcl-vfs` on Ubuntu). All mounting happens on a best-effort basis, based on the
presence of these binaries or packages in the respective paths. Mounting
in-process implies copying to temporary files and directories for each operation
that `machinery` will delegate to external tools such as `docker-machine` or
`docker-compose`.

By default, the following FUSE helpers are:

* `fuse-zip` or `archivemount` are used for ZIP files
* `archivemount` is used for all types of compressed or uncompressed TAR files.
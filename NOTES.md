# Internal Notes and TODOs

## Making a Release

To make a release, you should do the following:

1. Make sure all changes are documented in the [Release Notes](RELEASENOTES.md).
2. Bump up the version number that is initialised in the main script as part of
   the `CRT` array.
3. Make binaries using the script in the `make` sub-directory.
4. Tag the release in git using: `git tag -a -m "Version vX.Y" vX.Y`.
5. Push the tag to the main repository: `git push --tags`.

## TODO

* Use docker save (locally on the host), scp and docker load on the
  guest to skip slow downloads and use the local cache of docker
  images whenever possible.

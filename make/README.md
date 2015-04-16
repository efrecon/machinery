# Creating binaries

This directory contains all the necessary files to generate self-contained
binaries that will can be installed on any system, without any dependency on a
local Tcl installation.  Running the main script as follows will create binaries
for each of the currently supported platform, with a snapshot of the current
code and at the version reported by the main `machinery` script:

    make.tcl

The script can also take arguments, which are the names of the platforms to
build for, e.g.:

    make.tcl linux-x86_64

The whole binary creation process is made possible through these
[basekits](http://kitcreator.rkeene.org/kitcreator) and the
[starkit](http://www.tcl.tk/starkits/) techniques.  This also means that it is
possible to "cross-compile" (no compilation actually occurs!) for several
platforms, as long as there is a working kit available under the directory
`bin`.

The main script `make.tcl` supposes that `machinery` is placed in its parent
directory.  It also requires the following directory structure:

* `bin` is the directory where all basekits should be placed.  There should be
  one for each platform that you want to support, and there should be at lease
  one for the platform that you run the script on.  Basekits should be named
  `tclkit` and placed under a directory that contains an identifier for the
  platform.  This identifier should match the result of the command
  `::platform::generic` on that platform.

* `kits` should contain kits that are necessary for the building process.
  Currently, this only contains a copy of [sdx](http://wiki.tcl.tk/3411).

* `distro` is the directory where the final binaries will be placed.  Binaries
  are automatically tagged with the name of the platform and the version number.

Note that `make.tcl` should be able to create a number of files and directories
in the directory where it is started from.  These files and directories are
automatically cleaned up once the build process has finished.

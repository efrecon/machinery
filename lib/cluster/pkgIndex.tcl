# Tcl package index file, version 1.1
# This file is generated by the "pkg_mkIndex" command
# and sourced either when an application starts up or
# by a "package unknown" script.  It invokes the
# "package ifneeded" command to set up package-related
# information so that packages will be loaded automatically
# in response to "package require" commands.  When this
# script is sourced, the variable $dir must contain the
# full path name of this file's directory.

package ifneeded cluster 0.4 [list source [file join $dir cluster.tcl]]
package ifneeded cluster::swarm 0.3 [list source [file join $dir swarm.tcl]]
package ifneeded cluster::swarmmode 0.3 [list source [file join $dir swarmmode.tcl]]
package ifneeded cluster::vcompare 0.1 [list source [file join $dir vcompare.tcl]]
package ifneeded cluster::virtualbox 0.1 [list source [file join $dir virtualbox.tcl]]
package ifneeded cluster::unix 0.3 [list source [file join $dir unix.tcl]]
package ifneeded cluster::environment 0.2 [list source [file join $dir environment.tcl]]
package ifneeded cluster::tooling 0.2 [list source [file join $dir tooling.tcl]]
package ifneeded cluster::extend 0.1 [list source [file join $dir extend.tcl]]
package ifneeded cluster::utils 0.1 [list source [file join $dir utils.tcl]]
package ifneeded cluster::mount 0.1 [list source [file join $dir mount.tcl]]
package ifneeded proctrace 0.2 [list source [file join $dir proctrace.tcl]]
package ifneeded zipper 0.12 [list source [file join $dir zipper.tcl]]

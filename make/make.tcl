#! /usr/bin/env tclsh

package require platform

set dirname [file dirname [file normalize [info script]]]
set kitdir [file join $dirname kits]
set bindir [file join $dirname bin]
set dstdir [file join $dirname distro]

lappend auto_path [file join $dirname .. lib]
package require cluster;    # So we can call Run...

# Build for all platforms
if { [llength $argv] == 0 } {
    set argv [glob -directory $bindir -nocomplain -tails -- *]
}

cluster log NOTICE "Getting version"
set version [lindex [::cluster::Run -return -- ../machinery version] 0]

cluster log NOTICE "Creating skeleton and filling VFS"
set tclkit [file join $bindir [::platform::generic] tclkit]
set sdx [file join $kitdir sdx.kit]
::cluster::Run $tclkit $sdx qwrap ../machinery
::cluster::Run $tclkit $sdx unwrap machinery.kit
foreach fname [glob -directory [file join $dirname .. lib] -nocomplain -- *] {
    file copy -force -- $fname machinery.vfs/lib
}

foreach platform $argv {
    set binkit [file join $bindir $platform tclkit]
    if { [file exists $binkit] } {
	cluster log INFO "Final wrapping of binary for $platform"
	::cluster::Run $tclkit $sdx wrap machinery.kit
	# Copy runtime to temporary because won't work if same as the
	# one we are starting from.
	file copy $binkit ${binkit}.temp
	::cluster::Run $tclkit $sdx wrap machinery -runtime ${binkit}.temp
	file delete ${binkit}.temp
    } else {
	cluster log ERROR "Cannot build for $platform, no main kit available"
    }
    file rename -force -- machinery \
	[file join $dstdir machinery-$version-$platform]
}
file delete -force -- machinery.vfs
file delete -force -- machinery.kit
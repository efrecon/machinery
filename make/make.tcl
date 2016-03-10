#! /usr/bin/env tclsh

package require platform
package require http
package require tls

set tcllib_ver 1.17

set dirname [file dirname [file normalize [info script]]]
set kitdir [file join $dirname kits]
set bindir [file join $dirname bin]
set dstdir [file join $dirname distro]

lappend auto_path [file join $dirname .. lib]
package require cluster;    # So we can call Run...
cluster defaults -verbose INFO

# Build for all platforms
if { [llength $argv] == 0 } {
    set argv [glob -directory $bindir -nocomplain -tails -- *]
}

# The missing procedure of the http package
proc ::http::geturl_followRedirects {url args} {
    while {1} {
        set token [eval [list http::geturl $url] $args]
        switch -glob -- [http::ncode $token] {
            30[1237] {
            }
            default  { return $token }
        }
        upvar #0 $token state
        array set meta [set ${token}(meta)]
        if {![info exist meta(Location)]} {
            return $token
        }
        set url $meta(Location)
        unset meta
    }
}

# Arrange for https to work properly
::http::register https 443 [list ::tls::socket -tls1 1]

# Run machinery and ask it for its current version number.
cluster log NOTICE "Getting version"
set version [lindex [::cluster::Run2 -return -- [info nameofexecutable] ../machinery version] 0]

# Get the tcllib, this is a complete overkill, but is generic and
# might help us in the future.  We get it from the github mirror as
# the main fossil source is protected by a captcha.
cluster log NOTICE "Getting tcllib v$tcllib_ver from github mirror"
set gver [string map [list . _] $tcllib_ver]
set url https://github.com/tcltk/tcllib/archive/tcllib_$gver.tar.gz
set tok [::http::geturl_followRedirects $url -binary on]
set tcllib_path [::cluster::Temporary tcllib].tar.gz
if { [::http::ncode $tok] == 200 } {
    # Copy content of file to file, we can't use -channel as the
    # procedure to follow redirects cannot rewind on file descriptor
    # content.
    set fd [open $tcllib_path "w"]
    fconfigure $fd -encoding binary -translation binary
    puts -nonewline $fd [::http::data $tok]
    close $fd
} else {
    cluster log ERROR "Could not download from $url!"
    exit
}
::http::cleanup $tok

# Start creating an application directory structure using qwrap (from
# sdx).
cluster log NOTICE "Creating skeleton and filling VFS"
set tclkit [file join $bindir [::platform::generic] tclkit]
set sdx [file join $kitdir sdx.kit]
::cluster::Run2 $tclkit $sdx qwrap ../machinery
::cluster::Run2 $tclkit $sdx unwrap machinery.kit
foreach fname [glob -directory [file join $dirname .. lib] -nocomplain -- *] {
    set r_fname [file dirname [file normalize ${fname}/___]]
    cluster log DEBUG "Copying $r_fname -> machinery.vfs/lib"
    file copy -force -- $r_fname machinery.vfs/lib
}

# Install the modules of tcllib into the lib directory of the VFS
# directory.  We really could cleanup as we only need yaml and cmdline
# really...
cluster log NOTICE "Extracting tcllib"
::cluster::Run2 -- tar zxf $tcllib_path
set xdir [lindex [glob -nocomplain -- *tcllib*$gver] 0]
if { $xdir eq "" } {
    cluster log ERROR "Could not find where tcllib was extracted!"
    file delete -force -- $tcllib_path
    file delete -force -- machinery.vfs
    file delete -force -- machinery.kit
    exit
} else {
    cluster log NOTICE "Installing tcllib into VFS"
    set installer [file join $xdir installer.tcl]
    ::cluster::Run2 -- [info nameofexecutable] $installer -no-html -no-nroff -no-examples \
        -no-gui -no-apps -no-wait -pkg-path machinery.vfs/lib
}

# And now, for each of the platforms requested at the command line,
# build a platform dependent binary out of the kit.
foreach platform $argv {
    set binkit [file join $bindir $platform tclkit]
    if { [file exists $binkit] } {
	cluster log INFO "Final wrapping of binary for $platform"
	::cluster::Run2 $tclkit $sdx wrap machinery.kit
	# Copy runtime to temporary because won't work if same as the
	# one we are starting from.
	cluster log DEBUG "Creating temporary kit for final wrapping: ${binkit}.temp"
	file copy $binkit ${binkit}.temp
	::cluster::Run2 $tclkit $sdx wrap machinery -runtime ${binkit}.temp
	file delete -force -- ${binkit}.temp
    } else {
	cluster log ERROR "Cannot build for $platform, no main kit available"
    }
    file rename -force -- machinery \
	[file join $dstdir machinery-$version-$platform]
}

# Big cleanup
file delete -force -- $tcllib_path
file delete -force -- $xdir
file delete -force -- machinery.vfs
file delete -force -- machinery.kit
file delete -force -- machinery.bat

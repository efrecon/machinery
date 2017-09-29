#! /usr/bin/env tclsh

package require platform
package require http
package require tls

set tcllib_ver 1.18

set dirname [file dirname [file normalize [info script]]]
set kitdir [file join $dirname kits]
set bindir [file join $dirname bin]
set dstdir [file join $dirname distro]
set rootdir [file join $dirname ..]

lappend auto_path [file join $rootdir lib]
package require cluster;    # So we can call Run...
cluster defaults -verbose INFO

# Quick options parsing, accepting several times -target
set targets [list]; set version ""
for { set i 0 } { $i < [llength $argv] } { incr i } {
    set opt [lindex $argv $i]
    switch -glob -- $opt {
        "-t*" {
            incr i
            lappend targets [lindex $argv $i]
        }
        "-d*" {
            incr i
            cluster defaults -verbose [lindex $argv $i]
        }
        "-v*" {
            incr i
            set version [lindex $argv $i]
        }
        "--" {
            incr i
            break
        }
        default {
            break
        }
    }
}
set argv [lrange $argv $i end]
if { ![llength $targets] } {
    set targets [list "machinery" "baclin"]
}
cluster log NOTICE "Building targets: $targets"

# Build for all platforms
if { [llength $argv] == 0 } {
    set argv [glob -directory $bindir -nocomplain -tails -- *]
}
cluster log NOTICE "Building for platforms: $argv"

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


# Protect wrapping through temporary directory
set origdir [pwd]
set wrapdir [file normalize [file join $origdir wrapper-[pid]-[expr {int(rand()*1000)}]]]
cluster log NOTICE "Wrapping inside $wrapdir"
file mkdir $wrapdir
cd $wrapdir

proc cleanup { { target "" } } {
    cd $::origdir

    set toremove [list]
    if { [info exists ::xdir] } { lappend toremove $::xdir }
    if { [info exists ::tcllib_path] } { lappend toremove $::tcllib_path }
    if { $target ne "" } {
        lappend toremove ${target}.vfs ${target}.kit
    }
    lappend toremove $::wrapdir

    foreach fname $toremove {
        if { [file exists $fname] } {
            file delete -force -- $fname
        }
    }
}
    
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
    cleanup
    exit
}
::http::cleanup $tok

# Extract the content of tcllib to disk for a while
cluster log NOTICE "Extracting tcllib"
tooling run -- tar zxf $tcllib_path
set xdir [lindex [glob -nocomplain -- *tcllib*$gver] 0]
if { $xdir eq "" } {
    cluster log ERROR "Could not find where tcllib was extracted!"
    cleanup
    exit
}

foreach target $targets {
    # Handle versioning for some of the targets
    if { $version eq "" && $target eq "machinery" } {
        # Run machinery and ask it for its current version number.
        cluster log NOTICE "Getting version"
        set version [lindex [tooling run -return -- [info nameofexecutable] [file join $dirname .. $target] version] 0]
    }
    
    # Start creating an application directory structure using qwrap (from
    # sdx).
    cluster log NOTICE "Creating skeleton and filling VFS"
    set tclkit [file join $bindir [::platform::generic] tclkit]
    set sdx [file join $kitdir sdx.kit]
    tooling run $tclkit $sdx qwrap [file join $rootdir $target]
    tooling run $tclkit $sdx unwrap ${target}.kit
    
    # Install the modules of tcllib into the lib directory of the VFS
    # directory.
    cluster log NOTICE "Installing tcllib into VFS"
    set installer [file join $xdir installer.tcl]
    tooling run -- [info nameofexecutable] $installer -no-html -no-nroff -no-examples \
        -no-gui -no-apps -no-wait -pkg-path ${target}.vfs/lib
    foreach subdir [glob -directory ${target}.vfs/lib -types d -nocomplain -tails *] {
        set match 0
        foreach ptn [list *${target}* yaml json cmdline] {
            if { [string match $ptn $subdir] } {
                set match 1
                break
            }
        }
        if { ! $match } {
            cluster log DEBUG "Cleaning away directory $subdir"
            file delete -force -- [file join ${target}.vfs lib $subdir]
        }
    }
    
    # Install application libraries into VFS    
    foreach fname [glob -directory [file join $rootdir lib] -nocomplain -- *] {
        set r_fname [file dirname [file normalize ${fname}/___]]
        cluster log DEBUG "Copying $r_fname -> ${target}.vfs/lib"
        file copy -force -- $r_fname ${target}.vfs/lib
    }
    
    # And now, for each of the platforms requested at the command line,
    # build a platform dependent binary out of the kit.
    foreach platform $argv {
        set binkit [file join $bindir $platform tclkit]
        if { [file exists $binkit] } {
            cluster log INFO "Final wrapping of binary for $platform"
            tooling run $tclkit $sdx wrap ${target}.kit
            # Copy runtime to temporary because won't work if same as the
            # one we are starting from.
            set tmpkit [file join $wrapdir [file tail ${binkit}].temp]
            cluster log DEBUG "Creating temporary kit for final wrapping: $tmpkit"
            file copy $binkit $tmpkit
            tooling run $tclkit $sdx wrap ${target} -runtime $tmpkit
            file delete -force -- $tmpkit
        } else {
            cluster log ERROR "Cannot build for $platform, no main kit available"
        }
        
        # Move created binary to directory for official distributions
        if { $version eq "" } {
            set dstbin ${target}-$platform
        } else {
            set dstbin ${target}-$version-$platform            
        }
        if { [string match -nocase "win*" $platform] } {
            file rename -force -- ${target} [file join $dstdir $dstbin].exe
        } else {
            file rename -force -- ${target} [file join $dstdir $dstbin]
            file attributes [file join $dstdir $dstbin] -permissions a+x
        }
    }
    
    # Big cleanup
    file delete -force -- ${target}.vfs
    file delete -force -- ${target}.kit
    file delete -force -- ${target}.bat
}

cleanup

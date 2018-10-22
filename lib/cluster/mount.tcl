##################
## Module Name     --  cluster::vfs
## Original Author --  Emmanuel Frecon - emmanuel@sics.se
## Description:
##
##      This module provides mounting helpers.
##
##################

package require Tcl 8.6

package require cluster::environment
package require cluster::tooling
package require cluster::utils
package require cluster::unix
package require atExit

namespace eval ::cluster::mount {
    namespace eval vars {
        # binary of FUSE zip mounter
        variable -mount     {zip {{fuse-zip -r} archivemount} tar archivemount}
        # binary to unmount
        variable -umount    "fusermount"
        # Cache for abs location for above
        variable umount     ""
    }
    namespace export {[a-z]*}
    namespace path [namespace parent]
    namespace ensemble create -command ::mount
    namespace import [namespace parent]::utils::log
}

proc ::cluster::mount::add { src dst args } {
    # Extract the order to see how we prefer to mount the source URL/file onto
    # the destination, all other arguments will be passed to the internal or
    # external implementations.
    utils getopt args -order order {extern intern}

    # Pass further mounting to internal or external, i.e. in process using
    # TclVFS or system-wide out of process using FUSE.
    foreach o $order {
        set o [string tolower $o]
        switch -glob --  $o {
            "i*" {
                if { [AddInternal $src $dst {*}$args] } {
                    return $o
                }
            }
            "e*" {
                if { [AddExternal $src $dst {*}$args] } {
                    return $o
                }
            }
        }
    }
    return ""
}


proc ::cluster::mount::origin { fname {type_ ""} } {
    # The type of the origin FS, if found will be contained here.
    if { $type_ ne "" } {
        upvar $type_ type
    }

    # Try to find the file under an internally mounted FS, if possible
    if { [catch {package require vfs} ver] == 0 } {
        # Normalize incoming file path
        set src [::vfs::filesystem fullynormalize $fname]

        # Try to see if the file/dir is part of a mounted filesystem, if so we'll be
        # copying it.
        foreach fs [::vfs::filesystem info] {
            if { [string first $fs $src] == 0 } {
                # Force leading :: namespace marker on handler for matching
                # filesystem and assume the namespace right after ::vfs:: in the
                # handler name provides the type of the VFS used
                set handler ::[string trimleft [lindex [::vfs::filesystem info $fs] 0] :]
                set type [lindex [split [string map [list "::" ":"] $handler] :] 2]
                return "internal"
            }
        }
    }

    # Try to find the file under an externally mounted FS, if possible
    if { [lsearch [split [::platform::generic] -] "win32"] < 0 } {
        set src [file normalize $fname]
        foreach {dev fs t opts } {
            if { [string first $fs $src] == 0 && [string match -nocase *fuse* $t] } {
                set type $t
                return "external"
            }
        }
    }

    return ""
}


proc ::cluster::mount::cache { fname { tmpdir "" } { force 0 }} {
    # If the file is placed under an internally mounted VFS, we force caching so
    # that it can be made available to other processes.
    if { [origin $fname] eq "internal" } {
        log INFO "Temporarily caching $fname since mounted as $type VFS"
        set force 1
    }

    # Recursively copy file/dir into a good candidate temporary directory.
    if { $force } {
        log DEBUG "(Recursively) copying from $fname to $dst"
        set dst [utils tmpfile [file rootname [file tail $fname]] [file extension $fname] $tmpdir]
        file copy -force -- $fname $dst
    
        return $dst
    } else {
        return $fname
    }
}


proc ::cluster::mount::AddInternal { src dst args } {
    if { [catch {package require vfs} ver] == 0 } {
        set i [string first "://" $src]
        if { $i >= 0 } {
            incr i -1
            set proto [string range $src 0 $i]
            switch -- $proto {
                "http" -
                "https" {
                    if { [catch {package require vfs::http} ver] == 0 } {
                        log NOTICE "Mounting $src onto $dst"
                        ::vfs::http::Mount $src $dst
                    } else {
                        log WARN "Cannot mount from $src, don't know about http!"
                        return 0
                    }
                }
                "file" {
                    return [AddInternal [string range $src [expr {$i+3}] end] $dst {*}$args]
                }
                default {
                    if { [catch {package require vfs::$proto} ver] == 0 } {
                        log NOTICE "Mounting $src onto $dst"
                        ::vfs::${proto}::Mount $src $dst
                    } else {
                        log WARN "Cannot mount from $src, don't know about $proto!"
                        return 0
                    }
                }
            }
        } else {
            set ext [string trimleft [file extension $src] .]
            if { [catch {package require vfs::$ext} ver] == 0 } {
                log NOTICE "Mounting $src onto $dst"
                ::vfs::${ext}::Mount $src $dst
            } else {
                log WARN "Cannot mount from $src, don't know about $ext!"
                return 0
            }
        }
        return 1
    } else {
        log ERROR "No VFS support, will not be able to mount in process!"
        return 0
    }
}


proc ::cluster::mount::AddExternal { src dst args } {
    if { [lsearch [split [::platform::generic] -] "win32"] >= 0 } {
        log NOTICE "No FUSE support on Windows!"
        return 0
    }

    set i [string first "://" $src]
    if { $i >= 0 } {
        incr i -1
        set proto [string range $src 0 $i]
        switch -- $proto {
            "file" {
                return [AddExternal [string range $src [expr {$i+3}] end] $dst {*}$args]
            }
        }
        return 0
    } else {
        set type [FileType $src]
        foreach {t mounters} ${vars::-mount} {
            if { $t eq $type } {
                foreach cmd $mounters {
                    set bin [lindex $cmd 0]
                    set opts [lrange $cmd 1 end]
                    set mounter [auto_execok $bin]
                    if { $mounter ne "" } {
                        if { ![file isdirectory $dst] } {
                            file mkdir $dst
                        }
                        log NOTICE "Externally mounting $src as $t file onto $dst with $cmd"
                        tooling run -- $mounter {*}$opts {*}$args $src $dst
                        atExit [list [namespace current]::RemoveExternal $dst]
                        return 1; # ASAP
                    }
                }
            }
        }
        log WARN "Cannot mount from $src, don't know how to mount!"
        return 0
    }
    return 1
}

proc ::cluster::mount::RemoveExternal { dst { rmdir 1 } } {
    if { $vars::umount eq "" } {
        set vars::umount [auto_execok ${vars::-umount}]
    }

    if { $vars::umount ne "" } {
        log NOTICE "Unmounting $dst, this might take time..."
        tooling run -- $vars::umount -qu $dst;   # quiet and unmount, synchronously to make sure we finish
    }

    if { [llength [glob -nocomplain -directory $dst -tails -- *]] } {
        log WARN "Directory at $dst not empty, cannot cleanup properly"
    } elseif { $rmdir } {
        log INFO "Removing dangling directory $dst"
        if { [catch {file delete -force -- $dst} err] } {
            log WARN "Cannot remove dangling directory: $err"
        }
    }
}


proc ::cluster::mount::FileType { fpath } {
    switch -glob -nocase -- $fpath {
        "*.zip" {
            return "zip"
        }
        "*.tar" -
        "*.tgz" -
        "*.tar.gz" -
        "*.tar.Z" -
        "*.tar.bz2" {
            return "tar"
        }
    }
}


package provide cluster::mount 0.1

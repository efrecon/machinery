##################
## Module Name     --  cluster::vfs
## Original Author --  Emmanuel Frecon - emmanuel@sics.se
## Description:
##
##      This module provides mounting helpers.
##
##################

package require cluster::environment
package require cluster::tooling
package require cluster::utils

namespace eval ::cluster::mount {
    namespace eval vars {
        # Path of docker daemon init script
        variable -zip       "fuse-zip"
        # Path where PID files are stored
        variable -umount    "fusermount"
    }
    namespace export {[a-z]*}
    namespace path [namespace parent]
    namespace ensemble create -command ::mount
    namespace import [namespace parent]::utils::log
}

proc ::cluster::mount::add { src dst args } {
    utils getopt args -order order {extern intern}
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

proc ::cluster::mount::AddInternal { src dst args } {
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
        }
        return 0
    } else {
        set ext [string tolower [string trimleft [file extension $src] .]]
        switch -- $ext {
            "zip" {

            }
            default {
                log WARN "Cannot mount from $src, don't know about $ext!"
                return 0
            }
        }
    }
    return 1
}


package provide cluster::mount 0.1

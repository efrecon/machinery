##################
## Module Name     --  cluster::mount
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


# ::cluster::mount::add -- Mount external source
#
#      This procedure will arrange for mounting a source onto a destination.
#      Mounting is done to the best of our capability and behaviour can be
#      adapted through the -order option. This option takes a list of methods
#      for mounting and these will be proven in turns. Allows techniques are the
#      keywords internal and external. External mounting uses FUSE and is only
#      available on UNIX-like system, internal mounting uses Tcl VFS
#      capabilities, when present. All other options are given further to the
#      internal or external mounting implementations. 
#
# Arguments:
#      src      Source of information, a remote URL or a local (archive) file
#      dst      Where to mount, this can be an internal to process path
#      args     Dash-led options and their values, only -order understood here.
#
# Results:
#      Return how the mount was performed, or an empty string when mounting was
#      not possible.
#
# Side Effects:
#      External mounting will make available the content of the remote resouce
#      or file to other processes own by the user for the life-time of the
#      operation. 
proc ::cluster::mount::add { src dst args } {
    # Extract the order to see how we prefer to mount the source URL/file onto
    # the destination, all other arguments will be passed to the internal or
    # external implementations. On windows, no point trying with external
    # mounting...
    if { [lsearch [split [::platform::generic] -] "win32"] >= 0 } {
        utils getopt args -order order internal
    } else {
        utils getopt args -order order {external internal}
    }

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


# ::cluster::mount::origin -- Where does a file/dir come from
#
#      Look for existing internal to process and fuse-based external mounts and
#      return either the string internal, the string external or the empty
#      string.
#
# Arguments:
#      fname    Path to file to detect origin of
#      type_    Will contain some description of the mount type (impl. dependant)
#
# Results:
#      One of the string internal, external or empty string
#
# Side Effects:
#      None.
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


# ::cluster::mount::access -- Cache in file/dir
#
#      The base logic is to arrange for caching a copy of a file or directory in
#      a locally accessible temporary location so that external processes will
#      be able to use the file(s).  In short, this procedure arranges for files
#      that are internally mounted within this process to become accessible to
#      external processes that are spawn.
#
# Arguments:
#      fname    Name of file/dir to make accessible.
#      tmpdir   Temporary directory to store at, good default if empty
#      force    Force copy
#
# Results:
#      Return a path location that will be accessible to external processes,
#      this might be the same location as the original file path when it is
#      mounted externally (and not forced to caching)
#
# Side Effects:
#      None.
proc ::cluster::mount::access { fname { tmpdir "" } { force 0 } { gc 1 } } {
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
        if { $gc } {
            atExit [list file delete -force -- $dst]
        }
    
        return $dst
    } else {
        return $fname
    }
}


####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################


# ::cluster::mount::AddInternal -- Inter-process mount
#
#      Mount a remote location or file onto a local destination. This uses the
#      TclVFS services, ensuring that files and directories that are mounted
#      this way are available to this process and implementation, but not to
#      external processes.
#
# Arguments:
#      src      Source of information, a remote URL or a local (archive) file
#      dst      Where to mount, this can be an internal to process path
#      args     Dash-led options and their values, but none supported yet.
#
# Results:
#      1 on mount success, 0 otherwise
#
# Side Effects:
#      None.
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
                        log WARN "Cannot mount from $src internally, don't know about http!"
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
                        log WARN "Cannot mount from $src internally, don't know about $proto!"
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
                log WARN "Cannot mount from $src internally, don't know about $ext!"
                return 0
            }
        }
        return 1
    } else {
        log ERROR "No VFS support, will not be able to mount in process!"
        return 0
    }
}


# ::cluster::mount::AddExternal -- OS-based mount
#
#      This arranges for a remote location or a file to be mounted onto a
#      destination using various FUSE-based helpers. External mounting enables
#      external processes that are spawn from here to access the mounted files
#      directly. The destination mountpoiint will be created if necessary and
#      automatically unmounted and cleaned away on exit.
#
# Arguments:
#      src      Source of information, a remote URL or a local (archive) file
#      dst      Where to mount, this can be an internal to process path
#      args     Dash-led options and their values, passed further to mounter
#
# Results:
#      1 on mount success, 0 otherwise
#
# Side Effects:
#      FUSE mounting makes the content of the mounted resources available to all
#      processes that are run by the user under the lifetime of the machinery
#      session.
proc ::cluster::mount::AddExternal { src dst args } {
    # No FUSE on windows, don't even try
    if { [lsearch [split [::platform::generic] -] "win32"] >= 0 } {
        log NOTICE "No FUSE support on Windows!"
        return 0
    }

    # Isolate by scheme so the source can be a remote location (but no support
    # yet). Otherwise, for typically archives, use the known FUSE helpers
    # implementations pointed at by the -mount global to mount the archive onto
    # a directory.
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
        # Guess the type of the file
        set type [FileType $src]

        # Look for a working mounter for the type of the file and try using it.
        # Mounters can have options in addition to the binary that needs to be
        # found in the path. This set of pre-defined options is appended to the
        # command formed for mounting, in addition to the arguments coming from
        # outside callers.
        foreach {t mounters} ${vars::-mount} {
            # Found matching type, try all possible mounters and return ASAP
            if { $t eq $type } {
                # Go through all commands, these are list with a mounter binary
                # and options
                foreach cmd $mounters {
                    # Extract mounter binary and look for it in path
                    set bin [lindex $cmd 0]
                    set mounter [auto_execok $bin]
                    # Extract options if present.
                    set opts [lrange $cmd 1 end]
                    # If the mounter was found in path, create directory and
                    # mount. Make sure we cleanup on exit.
                    if { $mounter ne "" } {
                        if { ![file isdirectory $dst] } {
                            file mkdir $dst
                        }
                        log NOTICE "Externally mounting $src as $t file onto $dst with $cmd"
                        tooling run -- $mounter {*}$opts {*}$args $src $dst
                        atExit [list [namespace current]::RemoveExternal $dst]
                        return 1; # ASAP
                    } else {
                        log WARN "$bin not found to mount $src onto $dst"
                    }
                }
            }
        }

        log WARN "Cannot mount from $src externally, don't know how to mount!"
        return 0
    }
    return 1
}


# ::cluster::mount::RemoveExternal -- Remove external mount
#
#      Unmount an existing mount, and cleanup the directory on which the
#      resource was mounted once it is empty.
#
# Arguments:
#      dst      Mountpoint to unmount from
#      rmdir    Should we clean away directory mountpoint (default to yes)
#
# Results:
#      None.
#
# Side Effects:
#      Will call FUSE unmount
proc ::cluster::mount::RemoveExternal { dst { rmdir 1 } } {
    # Cache FUSE unmounter
    if { $vars::umount eq "" } {
        set vars::umount [auto_execok ${vars::-umount}]
    }

    # Unmount if we can
    if { $vars::umount ne "" } {
        # XX: Should we check this is an external mount?
        log NOTICE "Unmounting $dst, this might take time..."
        tooling run -- $vars::umount -qu $dst;   # quiet and unmount, synchronously to make sure we finish
    }

    # Test emptiness of directory and remove if we are asked to. Generate a
    # warning in all cases so we can warn about not being able to find and
    # successfully unmount.
    if { [llength [glob -nocomplain -directory $dst -tails -- *]] } {
        log WARN "Directory at $dst not empty, cannot cleanup properly"
    } elseif { $rmdir } {
        log INFO "Removing dangling directory $dst"
        if { [catch {file delete -force -- $dst} err] } {
            log WARN "Cannot remove dangling directory: $err"
        }
    }
}


# ::cluster::mount::FileType -- Guess file type
#
#      Crudly guess the type of the file based on the extension. There are
#      implementation in the tcllib, but we want to keep the dependencies to a
#      minimum and this will do for our purpose.
#
# Arguments:
#      fpath    Path to file
#
# Results:
#      Type of file, right now only archives are recognised, e.g. tar and zip.
#
# Side Effects:
#      None.
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

    return "";  # Catch all
}


package provide cluster::mount 0.1

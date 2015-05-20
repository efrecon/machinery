##################
## Module Name     --  cluster::virtualbox
## Original Author --  Emmanuel Frecon - emmanuel@sics.se
## Description:
##
##      This module provides a (restricted) set of operations to
##      modify, create and operate on virtual machines locally
##      accessible.
##
##################

namespace eval ::cluster::virtualbox {
    # Encapsulates variables global to this namespace under their own
    # namespace, an idea originating from http://wiki.tcl.tk/1489.
    # Variables which name start with a dash are options and which
    # values can be changed to influence the behaviour of this
    # implementation.
    namespace eval vars {
        variable -manage    VBoxManage
    }
    namespace export {[a-z]*}
    namespace path [namespace parent]
}


# ::cluster::virtualbox::info -- VM info
#
#       Return a dictionary describing a complete description of a
#       given virtual machine.  The output will be a dictionary, more
#       or less a straightforward translation of the output of
#       VBoxManage showvminfo.  However, "arrays" in the output
#       (i.e. keys with indices in-between parenthesis) will be
#       translated to a proper list in order to ease parsing.
#
# Arguments:
#        vm        Name or identifier of virtualbox guest machine.
#
# Results:
#       Return a dictionary describing the machine
#
# Side Effects:
#       None.
proc ::cluster::virtualbox::info { vm } {
    log DEBUG "Getting info for guest $vm"
    foreach l [Manage -return -- showvminfo $vm --machinereadable --details] {
        set eq [string first "=" $l]
        if { $eq >= 0 } {
            set k [string trim [string range $l 0 [expr {$eq-1}]]]
            set v [string trim [string range $l [expr {$eq+1}] end]]
            set k [string trim [string trim $k \"]]
            set v [string trim [string trim $v \"]]
            # Convert arrays into list in the dictionary, otherwise
            # just create a key/value in the dictionary.
            if { [regexp {(.*)\([0-9]+\)} $k - mk] } {
                dict lappend nfo $mk $v
            } else {
                dict set nfo $k $v
            }
        }
    }
    return $nfo
}


# ::cluster::virtualbox::forward -- Establish port-forwarding
#
#       Arrange for a number of NAT port forwardings to be applied
#       between the host and a guest machine.
#
# Arguments:
#        vm        Name or identifier of virtualbox guest machine.
#        args        Repeatedly host port, guest port, protocol in a list.
#
# Results:
#       None.
#
# Side Effects:
#       Perform port forwarding on the guest machine
proc ::cluster::virtualbox::forward { vm args } {
    # TODO: Don't redo if forwarding already exists...
    set running [expr {[Running $vm] ne ""}]
    foreach {host mchn proto} $args {
        set proto [string tolower $proto]
        if { $proto eq "tcp" || $proto eq "udp" } {
            log INFO "[string toupper $proto] port forwarding\
                      localhost:$host -> ${vm}:$mchn"
            if { $running } {
                Manage controlvm $vm natpf1 \
                    "${proto}-$host,$proto,,$host,,$mchn"
            } else {
                Manage modifyvm $vm --natpf1 \
                    "${proto}-${host},$proto,,$host,,$mchn"
            }
        }
    }
}


# ::cluster::virtualbox::addshare -- Add a mountable share
#
#       Arrange for a local directory path to be mountable from within
#       a guest virtual machine.  This will generate a unique
#       identifier for the share.
#
# Arguments:
#        vm        Name or identifier of virtualbox guest machine.
#        path        Path to EXISTING directory
#
# Results:
#       Return the identifier for the share, or an empty string on
#       errors.
#
# Side Effects:
#       Will turn off the machine if it is running as it is not
#       possible to add shares to live machines.
proc ::cluster::virtualbox::addshare { vm path } {
    # Refuse to add directories that do not exist (and anything else
    # that would not be a directory).
    if { ![file isdirectory $path] } {
        log WARN "$path is not a host directory!"
        return ""
    }

    # Lookup the share so we'll only add once.
    set nm [share $vm $path]

    # If if it did not exist, add the shared folder definition to the
    # virtual machine.  Generate a unique name that has some
    # connection to the path requested.
    if { $nm eq "" } {
        # Halt the machine if it is running, since we cannot add
        # shared folders to running machines.
        if { [Running $vm] ne "" } {
            halt $vm
        }
        # Generate a unique name and add the share
        set nm [[namespace parent]::Temporary [file tail $path]]
        log INFO "Adding share ${vm}:${nm} for localhost:$path"
        Manage sharedfolder add $vm \
            --name $nm \
            --hostpath $path
    }
    return $nm
}


# ::cluster::virtualbox::halt -- Halt a machine
#
#       Halt a virtual machine by simulating first a press on the
#       power button and then by powering it off completely if it had
#       not shutdown properly after a respit period.
#
# Arguments:
#        vm        Name or identifier of virtualbox guest machine.
#        respit    Respit period, in seconds.
#
# Results:
#       1 if machine was halted, 0 otherwise
#
# Side Effects:
#       Will block while waiting for the machine to gently shutdown.
proc ::cluster::virtualbox::halt { vm { respit 15 } } {
    # Do a nice shutdown and wait for end of machine
    Manage controlvm $vm acpipowerbutton

    # Wait for VM to shutdown
    log NOTICE "Waiting for $vm to shutdown..."
    if { ![Wait $vm $respit] } {
        log NOTICE "Forcing powering off of $vm"
        Manage controlvm $vm poweroff
        return [Wait $vm $respit]
    }
    return 1
}


# ::cluster::virtualbox::share -- Find a share
#
#       Given a local host path, find if there is an existing share
#       declared within a guest and return its identifier.
#
# Arguments:
#        vm        Name or identifier of virtualbox guest machine.
#        path      Local host path
#
# Results:
#       Return the identifier of the share if it existed, an empty
#       string otherwise
#
# Side Effects:
#       None.
proc ::cluster::virtualbox::share { vm path } {
    set nfo [info $vm]
    foreach k [dict keys $nfo SharedFolderPathMachineMapping*] {
        if { [dict get $nfo $k] eq $path } {
            return [dict get $nfo [string map [list Path Name] $k]]
        }
    }
    return ""
}

####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################

# ::cluster::virtualbox::Running -- Is a machine running?
#
#       Check if a virtual machine is running and returns its identifier.
#
# Arguments:
#       vm        Name or identifier of virtualbox guest machine.
#
# Results:
#       Return the identifier of the machine if it is running,
#       otherwise an empty string.
#
# Side Effects:
#       None.
proc ::cluster::virtualbox::Running { vm } {
    # Detect if machine is currently running.
    log DEBUG "Detecting running state of $vm"
    foreach l [Manage -return -- list runningvms] {
        foreach {nm id} $l {
            set id [string trim $id "\{\}"]
            if { [string equal $nm $vm] || [string equal $id $vm] } {
                log DEBUG "$vm is running, id: $id"
                return $id
            }
        }
    }
    return ""
}


proc ::cluster::virtualbox::Wait { vm { respit 15 } } {
    while {$respit >= 0} {
        set nfo [info $vm]
        if { [dict exists $nfo VMState] \
            && [string equal -nocase [dict get $nfo VMState] "poweroff"] } {
            return 1
        } else {
            log DEBUG "$vm still running, keep waiting"
            after 1000
            incr respit -1
        }
    }
    return 0
}

proc ::cluster::virtualbox::Manage { args } {
    # Isolate -- that will separate options to procedure from options
    # that would be for command.  Using -- is MANDATORY if you want to
    # specify options to the procedure.
    set sep [lsearch $args "--"]
    if { $sep >= 0 } {
        set opts [lrange $args 0 [expr {$sep-1}]]
        set args [lrange $args [expr {$sep+1}] end]
    } else {
        set opts [list]
    }

    return [eval [namespace parent]::Run2 $opts -- ${vars::-manage} $args]
}



package provide cluster::virtualbox 0.1

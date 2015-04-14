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
}

# ::cluster::virtualbox::log -- Log output
#
#       Log message if current level is higher that the level of the
#       message.  Currently, this simply bridges the logging facility
#       available as part of the cluster module.
#
# Arguments:
#	lvl	Logging level of the message
#	msg	String content of the message.
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::virtualbox::log { lvl msg } {
    [namespace parent]::log $lvl $msg
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
#	vm	Name or identifier of virtualbox guest machine.
#
# Results:
#       Return a dictionary describing the machine
#
# Side Effects:
#       None.
proc ::cluster::virtualbox::info { vm } {
    log INFO "Getting info for guest $vm"
    foreach l [[namespace parent]::Run -return -- \
		   ${vars::-manage} showvminfo $vm --machinereadable --details] {
	set eq [string first "=" $l]
	if { $eq >= 0 } {
	    set k [string trim [string range $l 0 [expr {$eq-1}]]]
	    set v [string trim [string range $l [expr {$eq+1}] end]]
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
#       Description
#
# Arguments:
#	arg1	descr
#	arg2	descr
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::virtualbox::forward { vm args } {
    # TODO: Don't redo if forwarding already exists...
    set running [expr {[Running $vm] ne ""}]
    foreach {host mchn proto} $args {
	set proto [string tolower $proto]
	if { $proto eq "tcp" || $proto eq "udp" } {
	    log DEBUG "Forwarding host port $host onto guest $mchn for $proto"
	    if { $running } {
		[namespace parent]::Run VBoxManage controlvm $vm natpf1 \
		    "${proto}-$host,$proto,,$host,,$mchn"
	    } else {
		[namespace parent]::Run VBoxManage modifyvm $vm --natpf1 \
		    "${proto}-${host},$proto,,$host,,$mchn"
	    }
	}	
    }
}


proc ::cluster::virtualbox::Running { vm } {
    # Detect if machine is currently running.
    log DEBUG "Detecting running state of $vm"
    foreach l [[namespace parent]::Run -return -- ${vars::-manage} list \
		   runningvms] {
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


proc ::cluster::virtualbox::addshare { vm path } {
    # Refuse to add directories that do not exist (and anything else
    # that would not be a directory).
    if { ![file isdirectory $path] } {
	log WARN "$path is not a host directory!"
	return ""
    }

    # Lookup the share so we'll only add once.
    set nm [FindShare $vm $path]

    # If if it did not exist, add the shared folder definition to the
    # virtual machine.  Generate a unique name that has some
    # connection to the path requested.
    if { $nm eq "" } {
	# Halt the machine if it is running, since we cannot add
	# shared folders to running machines.
	if { [Running $vm] ne "" } {
	    Halt $vm
	}
	# Generate a unique name and add the share
	set nm [[namespace parent]::Temporary [file tail $path]]
	[namespace parent]::Run ${vars::-manage} sharedfolder add $vm \
	    --name $nm \
	    --hostpath $path \
	    --automount
    }
    return $nm
}


proc ::cluster::virtualbox::Halt { vm { respit 15 } } {
    # Do a nice shutdown and wait for end of machine
    [namespace parent]::Run ${vars::-manage} controlvm $vm acpipowerbutton

    # Wait for VM to shutdown
    log NOTICE "Waiting for $vm to shutdown..."
    while {$respit >= 0} {
	set id [Running $vm]
	if { $id eq "" } {
	    break
	} else {
	    after 1000
	}
    }

    # Power it off if it was still on.
    if { $id ne "" } {
	log NOTICE "Forcing powering off for $vm"
	[namespace parent]::Run ${vars::-manage} controlvm $vm poweroff
    }
}


proc ::cluster::virtualbox::FindShare { vm path } {
    set nfo [info $vm]
    foreach k [dict keys $nfo SharedFolderPathMachineMapping*] {
	if { [dict get $nfo $k] eq $path } {
	    return [dict get $nfo [string map [list Path Name] $k]]
	}
    }
    return ""
}


package provide cluster::virtualbox 0.1

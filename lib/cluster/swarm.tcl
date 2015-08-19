namespace eval ::cluster::swarm {
    # Encapsulates variables global to this namespace under their own
    # namespace, an idea originating from http://wiki.tcl.tk/1489.
    # Variables which name start with a dash are options and which
    # values can be changed to influence the behaviour of this
    # implementation.
    namespace eval vars {
        # Extension for token storage files
        variable -ext       .tkn
	# Name of master agent and agents
	variable -agent     "swarm-agent"
	variable -master    "swarm-agent-master"
    }
    # Export all lower case procedure, arrange to be able to access
    # commands from the parent (cluster) namespace from here and
    # create an ensemble command called swarm (note the leading :: to
    # make this a top-level command!) to ease API calls.
    namespace export {[a-z]*}
    namespace path [namespace parent]
    namespace ensemble create -command ::swarm
}


# ::cluster::swarm::master -- Master description
#
#       This procedure looks up the swarm master out of a cluster
#       description and returns its vm description.
#
# Arguments:
#        cluster        List of machine description dictionaries.
#
# Results:
#       Virtual machine description of swarm master, empty if none.
#
# Side Effects:
#       None.
proc ::cluster::swarm::master { cluster } {
    foreach vm $cluster {
        if { [dict exists $vm -master] } {
            if { [string is true [dict get $vm -master]] } {
                return $vm
            }
        }
    }
    return {}
}


proc ::cluster::swarm::info { cluster } {
    # Dump out swarm master information
    set master [master $cluster]
    if { $master ne "" } {
	if { [dict exists $master state] \
		 && [string match -nocase "running" [dict get $master state]] } {
	    log NOTICE "Getting cluster info via\
                        [dict get $master -name]"
	    [namespace parent]::Attach $master 1
	    [namespace parent]::Docker info
	} else {
	    log WARN "Cluster not bound or master not running"
	}
    } else {
	log WARN "Cluster has no swarm master"
    }
}

proc ::cluster::swarm::recapture { cluster } {
    set master [master $cluster]
    if { $master ne "" } {
	if { [dict exists $master state] \
		 && [string match -nocase "running" [dict get $master state]] } {
	    log NOTICE "Capturing current list of live machines in swarm"
	    [namespace parent]::Attach $master
	    [namespace parent]::Docker restart ${vars::-master}
	} else {
	    log WARN "Cluster not bound or master not running"
	}
    } else {
	log WARN "Cluster has no swarm master"
    }
}


# ::cluster::swarm::token -- Generate a token
#
#       This procedure will generate a swarm token cluster if
#       necessary and return it.  The token is stored in a hidden file
#       under the same directory as the YAML description file, and
#       with the .tkn extension.  When the token needs to be
#       generated, this is done through the creation of a temporary
#       virtual machine.
#
# Arguments:
#        yaml      Path to YAML description for cluster
#        force     Force token (re)generation
#        driver    Driver to use for token generation
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::swarm::token { yaml { force 0 } { driver virtualbox } } {
    set token ""

    # Generate file name for token caching out of yaml path.
    set tkn_path [[namespace parent]::CacheFile $yaml ${vars::-ext}]

    # Read from cache if we have a cache and force is not on.
    # Otherwise, generate a new token and cache it.
    if { [file exists $tkn_path] && [string is false $force] } {
        log NOTICE "Reading token from $tkn_path"
        set fd [open $tkn_path]
        set token [string trim [read $fd]]
        close $fd
    } else {
        # Generate and cache.
        log NOTICE "Generating new token"
        set token [Token $driver]
        if { $token ne "" } {
            log DEBUG "Storing new generated token in $tkn_path"
            set fd [open $tkn_path "w"]
            puts -nonewline $fd $token
            close $fd
        }
    }
    log INFO "Token for cluster definition at $yaml is $token"
    return $token
}


####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################


# ::cluster::swarm::Token -- Generate token
#
#       Generate a new swarm token through creating a temporary
#       virtual machine in which we will run "docker-machine run swarm
#       create".  The temporary machine is removed once the token has
#       been generated.  When the driver is empty, this will create
#       the swarm token using a local component, thus leaving an extra
#       image on the local machine.
#
# Arguments:
#        driver        Default driver to use for (temporary) VM creation.
#
# Results:
#       Generated token
#
# Side Effects:
#       Create a (temporary) virtual machine and component for swarm
#       token creation.
proc ::cluster::swarm::Token { {driver none} } {
    set token ""
    if { $driver eq "none" || $driver eq "" } {
        [namespace parent]::Detach;   # Ensure we are running locally...
        log INFO "Creating swarm token..."
        set token [[namespace parent]::Docker -return -- run --rm swarm create]
        log NOTICE "Created cluster token $token"
    } else {
        set nm [Temporary "tokeniser"]
        log NOTICE "Creating machine $nm for token creation"
        set vm [dict create -name $nm -driver $driver]
        if { [[namespace parent]::Create $vm] ne "" } {
            [namespace parent]::Attach $vm
            log INFO "Creating swarm token..."
            set token [[namespace parent]::Docker -return -- run --rm swarm create]
            log NOTICE "Created cluster token $token"
            [namespace parent]::Machine kill $nm;   # We want to make this quick!
            [namespace parent]::Machine rm $nm
        }
    }
    return $token
}


package provide cluster::swarm 0.2

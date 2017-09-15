##################
## Module Name     --  swarmmode.tcl
## Original Author --  Emmanuel Frécon - emmanuel.frecon@ri.se
## Description:
##
##  This module focuses on the new Swarm Mode available as part of the Docker
##  Engine. The main procedure is called 'join': given a set of (declared
##  masters/managers) it will arrange for a node to join the Swarm cluster,
##  which inclused initialisation of the Swarm.
##
##################

namespace eval ::cluster::swarmmode {
    # Encapsulates variables global to this namespace under their own
    # namespace, an idea originating from http://wiki.tcl.tk/1489.
    # Variables which name start with a dash are options and which
    # values can be changed to influence the behaviour of this
    # implementation.
    namespace eval vars {
        # Extension for token cache file
        variable -ext       .swt
    }
    # Export all lower case procedure, arrange to be able to access
    # commands from the parent (cluster) namespace from here and
    # create an ensemble command called swarmmode (note the leading :: to make
    # this a top-level command!) to ease API calls.
    namespace export {[a-z]*}
    namespace path [namespace parent]
    namespace ensemble create -command ::swarmmode
    namespace import [namespace parent]::Machine \
                        [namespace parent]::Machines \
                        [namespace parent]::IsRunning \
                        [namespace parent]::CacheFile \
                        [namespace parent]::ListParser
}


# ::cluster::swarmmode::masters -- Masters description
#
#       This procedure looks up the swarm masters out of a cluster
#       description and returns their vm description.
#
# Arguments:
#        cluster        List of machine description dictionaries.
#        alive          Only return machines that are running.
#
# Results:
#       List of virtual machine description of swarm masters, empty if none.
#
# Side Effects:
#       None.
proc ::cluster::swarmmode::masters { cluster { alive 0 } } {
    set masters [list]
    foreach vm [Machines $cluster] {
        if { [mode $vm] eq "manager" } {
            if { ($alive && [IsRunning $vm]) || !$alive} {
                lappend masters $vm
            }
        }
    }
    return $masters
}


# ::cluster::swarmmode::mode -- Node mode
#
#   Return the mode of the node as of the Swarm Mode terminology. This respects
#   the clustering mode (as we still support the old Docker Swarm), and the
#   ability to turn off swarming for machines (including the ability to specify
#   swarming options).
#
# Arguments:
#	vm	Virtual machine description dictionary.
#
# Results:
#	manager, worker or empty string
#
# Side Effects:
#	None
proc ::cluster::swarmmode::mode { vm } {
    # Check if running new swarm mode
    if { [string match -nocase "swarm*mode" \
                [dict get $vm cluster -clustering]] } {
        # Check if we haven't turned off swarming for that node, this is
        # convoluted because we both access swarm as a boolean, but also as a
        # dictionary containing swarming options.
        if { ([dict exists $vm -swarm] \
                    && (([string is boolean -strict [dict get $vm -swarm]] \
                            && ![string is false [dict get $vm -swarm]])
                        || ![string is boolean -strict [dict get $vm -swarm]])) \
                || ![dict exists $vm -swarm] } {
            # Check node mode, master or not
            if { [dict exists $vm -master] && [dict get $vm -master] } {
                return "manager"
            } else {
                return "worker"
            }
        }
    }
    return "";   # Catch all for all non-cases
}


# ::cluster::swarmmode::join -- join/initiate swarm
#
#   Provided a number of possible masters (marked with the master key in the
#   YAML description), this procedure will arrange for the machine which
#   description is passed as a parameter to join the swarm. If the maching
#   should be a manager and no masters are alive, then the swarm is deemed
#   non-initiated and will be iniitiated on that machine.
#
# Arguments:
#	vm	Virtual machine description dictionary.
#	masters	List of possible masters (dictionaries themselves)
#
# Results:
#   Return the node ID inside the Swarm of the machine that was attached to the
#   swarm, or an empty string.
#
# Side Effects:
#	None
proc ::cluster::swarmmode::join { vm masters } {
    # Construct a list of the running managers that are not the machine that we
    # want to make part of the cluster
    set managers [Managers $masters $vm]
    
    # Now initialise or join (in most cases) the cluster
    if { [llength $managers] == 0 } {
        # No running managers and the machine we are "joining" is a manager
        # itself, then we deem the cluster to be uninitialise and initialise it.
        if { [mode $vm] eq "manager" } {
            log INFO "No running managers, initialising cluster"
            return [Init $vm]
        } else {
            log WARN "Cannot join a non-running cluster!"
        }
    } else {
        # Pick a manager to use when joining the cluster
        set mgr [PickManager $managers]
        if { [dict exists $mgr -name] } {
            # Get the (cached?) tokens for joining the cluster
            lassign [Tokens $mgr] tkn_mngr tkn_wrkr

            if { $tkn_mngr eq "" || $tkn_wrkr eq "" } {
                log WARN "Cannot join swarm without available tokens!"
            } else {
                # Get the swarm address to use for the manager
                set mnm [dict get $mgr -name]
                set addr [Machine -return -- \
                            -s [storage $vm] ssh $mnm \
                                "docker node inspect --format '{{ .ManagerStatus.Addr }}' self"]
                set addr [string trim $addr]
    
                if { $addr ne "" } {
                    set nm [dict get $vm -name]
                    # Construct joining command
                    set cmd [list docker swarm join]
                    Options cmd join $vm
                    # Add token and ip address of master that we communicate with
                    set mode [mode $vm]
                    if { $mode eq "manager" } {
                        lappend cmd --token $tkn_mngr $addr
                    } else {
                        lappend cmd --token $tkn_wrkr $addr          
                    }
                    
                    # Join and check result
                    set res [Machine -return -- -s [storage $vm] ssh $nm $cmd]
                    if { [string match "*swarm*${mode}*" $res] } {
                        # Ask manager about whole swarm state and find out the
                        # identifier of the newly created node.
                        set state [Machine -return -- -s [storage $vm] ssh $mnm "docker node ls"]
                        foreach m [ListParser $state [list "MANAGER STATUS" "MANAGER_STATUS"]] {
                            if { [dict exists $m id] && [dict exists $m hostname] } {
                                if { [dict get $m hostname] eq $nm } {
                                    set id [string trim [dict get $m id] " *"]
                                    log NOTICE "Machine $nm joined swarm as $mode as node $id"                        
                                    return $id
                                }
                            }
                        }
                        log WARN "Machine $nm not visible in swarm (yet?)"
                    } else {
                        log WARN "Machine $nm could not join swarm as $mode: $res"
                    }
                } else {
                    log WARN "Cannot find swarm address of manager: [dict get $mgr -name]"
                }
            }
        } else {
            log WARN "No running manager available to join swarm cluster!"
        }
    }
    return "";   # Catch all for errors
}


# ::cluster::swarmmode::leave -- Leave swarm
#
#   Arrange for the machine passed as a parameter to leave the swarm. Leaving is
#   done in gentle form, i.e. managers are first demoted and are only forced out
#   whenever Docker says so. This leaves a chance to other managers to pick up
#   the state and for other workers to pick up the tasks.
#
# Arguments:
#	vm	Virtual machine description dictionary.
#
# Results:
#	None
#
# Side Effects:
#	None
proc ::cluster::swarmmode::leave { vm } {
    set nm [dict get $vm -name]    
    switch -- [mode $vm] {
        "manager" {
            # Demote the manager from the swarm so it can gracefully handover state
            # to other managers.
            Machine -- -s [storage $vm] ssh $nm "docker node demote $nm"
            set response [Machine -return -stderr \
                            -- -s [storage $vm] ssh $nm "docker swarm leave"]
            if { [string match "*`--force`*" $response] } {
                log NOTICE "Forcing node $nm out of swarm!"
                Machine -- -s [storage $vm] ssh $nm "docker swarm leave --force"
            }
        }
        "worker" {
            Machine -- -s [storage $vm] ssh $nm "docker swarm leave"        
        }
    }
}


# ::cluster::swarmmode::procname -- create/destroy networks
#
#   This procedure will arrange for the creation/deletion of cluster-wide
#   networks. These are usually overlay networks that can be declared as
#   external in stack definition files so that several stacks can exchange
#   information. Creation and deletion occurs via a randomly chosen running
#   managers among the possible masters.
#
# Arguments:
#	cmd	command: create or delete (aliases are available.)
#	net	Dictionary describing the network, mostly options to docker
#	masters	List of possible masters (dictionaries themselves)
#
# Results:
#	None
#
# Side Effects:
#	None
proc ::cluster::swarmmode::network { cmd net masters } {
    switch -nocase -- $cmd {
        "up" -
        "create" {
            set managers [Managers $masters]
            set mgr [PickManager $managers]
            if { [dict exists $mgr -name] } {
                set nm [dict get $mgr -name]
                set id [NetworkID $mgr [dict get $net -name]]
                if { $id eq "" } {
                    # Construct network creation command out of network definition
                    set cmd [list docker network create]
                    dict for {k v} $net {
                        if { $k ne "-name" && [string match -* $k] } {
                            lappend cmd --[string trimleft $k -]=$v
                        }
                    }
                    lappend cmd [dict get $net -name]
                    set id [Machine -return -- -s [storage $mgr] ssh $nm $cmd]
                    log NOTICE "Created swarm-wide network $id"
                }
                return $id
            } else {
                log WARN "No running manager to pick"
            }
        }
        "destroy" -
        "delete" -
        "rm" -
        "remove" -
        "down" {
            set managers [Managers $masters]
            set mgr [PickManager $managers]
            if { [dict exists $mgr -name] } {
                set nm [dict get $mgr -name]
                Machine -- -s [storage $mgr] ssh $nm "docker network rm $net"
            }
        }
    }
    return 0
}



####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################


# ::cluster::swarmmode::Init -- Initialise first node of swarm
#
#   Initialise the swarm, arranging for the virtual machine passed as an
#   argument to be the (first) manager in the swarm.
#
# Arguments:
#	vm	Virtual machine description dictionary.
#
# Results:
#	Return the swarm node identifier of the (first) manager.
#
# Side Effects:
#	None
proc ::cluster::swarmmode::Init { vm } {
    if { [mode $vm] eq "manager" } {    
        set nm [dict get $vm -name]    
    
        set cmd [list docker swarm init]
        Options cmd init $vm
        set res [Machine -return -- -s [storage $vm] ssh $nm $cmd]
        if { [regexp {.*\(([a-z0-9]+)\).*manager.*} $res mtch id] } {
            log NOTICE "Initialised machine $nm as node $id in swarm"

            # Arrange to cache information abount manager and swarm
            if { [TokenStore $vm] } {
                lassign [TokenCache $vm] mngr wrkr
                log INFO "Generated swarm tokens -- Managers: $mngr, Workers: $wrkr"
            }
            
            return $res
        } else {
            log WARN "Could not initialise swarm on $nm: $res"
        }
    }
    
    return "";   # Catch all errors
}


# ::cluster::swarmmode::NetworkID -- Get Swarm network ID
#
#   Actively ask a manager for the node identifier of a machine in the cluster.
#
# Arguments:
#	mgr	Virtual machine description dictionary of a manager.
#	name	Name of the machine to query
#
# Results:
#   Return the complete node identifier of the machine within the swarm, or an
#   empty string.
#
# Side Effects:
#	None
proc ::cluster::swarmmode::NetworkID { mgr name } {
    set nm [dict get $mgr -name]
    set networks [Machine -return -- -s [storage $mgr] ssh $nm "docker network ls --no-trunc=true"]
    foreach n [ListParser $networks [list "NETWORK ID" NETWORK_ID]] {
        if { [dict exists $n name] && [dict get $n name] eq $name } {
            return [dict get $n network_id]
        }
    }
    return ""
}

# ::cluster::swarmmode::Options -- Append command with swarm options.
#
#   Pick swarm specific options for join/initialisation from virtual machine and
#   append these to a command (being constructed).
#
# Arguments:
#	cmd_	"POinter" to command to modify
#	mode	Mode: join or init supported in YAML right now.
#	vm	Virtual machine description dictionary, containing swarm-specific options..
#
# Results:
#	None
#
# Side Effects:
#	Modifies the command!
proc ::cluster::swarmmode::Options { cmd_ mode vm } {
    upvar $cmd_ cmd
    # Pick init options if there are some from swarm
    if { [dict exists $vm -swarm] \
            && ![string is boolean -strict [dict get $vm -swarm]] } {
        if { [dict exists $vm -swarm $mode] } {
            dict for {o v} [dict get $vm -swarm $mode] {
                lappend cmd --[string trimleft $o -] $v
            }
        }
    }
}


# ::cluster::swarmmode::PickManager -- Pick a manager
#
#	Pick a manager at random
#
# Arguments:
#	managers	List of managers to pick from
#	ptn	Pattern to match on names to restrict set of candidates.
#
# Results:
#	The dictionary representing the managers that was chosen.
#
# Side Effects:
#	None
proc ::cluster::swarmmode::PickManager { managers { ptn * } } {
    # Build a list of possible candidates based on the name pattern
    set candidates {}
    foreach vm $managers {
        if { [string match $ptn [dict get $vm -name]] } {
            lappend candidates $vm
        }
    }
    
    # Choose one!
    set len [llength $candidates]
    if { $len > 0 } {
        set vm [lindex $candidates [expr {int(rand()*$len)}]]
        log INFO "Picked manager [dict get $vm -name] to operate on swarm"
        return $vm
    } else {
        log WARN "Cannot find any manager matching $ptn!"
    }
    return [list]
}


# ::cluster::swarmmode::Managers -- Running managers
#
#   Return the list of possible managers out of a number of declared masters.
#   Managers need to be running and this procedure will check their status.This
#   procedure is also able to avoid a virtual machine from the set of returned
#   managers.
#
# Arguments:
#	masters	List of possible managers.
#	vm	Virtual machine to exclude from the list.
#
# Results:
#	List of running managers that are candidates for swarm mode operations.
#
# Side Effects:
#	None
proc ::cluster::swarmmode::Managers { masters {vm {}}} {
    # Construct a list of the running managers that are not the machine that we
    # want to make part of the cluster
    set managers [list]
    foreach mch $masters {
        if { (![dict exists $vm -name] \
                    || [dict get $mch -name] ne [dict get $vm -name]) \
                && [IsRunning $mch] } {
            lappend managers $mch
        }
    }
    return $managers
}


# ::cluster::swarmmode::Tokens -- Get swarm tokens
#
#   Get the swarm tokens to use for a given machine. Tokens are cached and this
#   procedure will actively request the tokens from the virtual machine whenever
#   it is forced to do so or the cache is empty. This can only happen when the
#   machine passed as a parameter is a (running) manager.
#
# Arguments:
#	vm	Virtual machine description dictionary
#	force	Force active collection of tokens from a manager.
#
# Results:
#   List of two tokens: token for joining managers and token for joining
#   workers.
#
# Side Effects:
#	None
proc ::cluster::swarmmode::Tokens { vm { force 0 } } {
    if { $force } {
        if { [mode $vm] ne "manager" } {
            log WARN "Cannot only force active collection of tokens via manager node!"
        } else {
            TokenStore $vm
        }
    }

    set tkn_path [CacheFile [dict get $vm origin] ${vars::-ext}]
    if { ![file exists $tkn_path] && [mode $vm] eq "manager" } {
        TokenStore $vm
    }
    return [TokenCache $vm]
}


# ::cluster::swarmmode::TokenStore -- Request swarm tokens and store them
#
#   Request the machine passed as an argument (a manager!) for the swarm tokens
#   and store these in the cache so callers will more easily access them later
#   on.
#
# Arguments:
#	vm	Virtual machine description dictionary
#
# Results:
#	1 on storage success, 0 otherwise
#
# Side Effects:
#	None
proc ::cluster::swarmmode::TokenStore { vm } {
    # Generate file name for token caching out of yaml path.
    set tkn_path [CacheFile [dict get $vm origin] ${vars::-ext}]

    # Actively get tokens from virtual machine, which must be one of the managers.
    set manager [TokenGet $vm manager]
    set worker [TokenGet $vm worker]

    if { $manager ne "" && $worker ne "" } {
        log DEBUG "Caching swarm mode tokens at $tkn_path"
        if { [catch {open $tkn_path w} fd] == 0 } {
            puts $fd "$manager $worker"
            close $fd

            return 1
        } else {
            log WARN "Cannot store swarm mode tokens at $tkn_path: $fd"
        }
    }
    return 0;   # Catch all errors.
}


# ::cluster::swarmmode::TokenCache -- Get swarm tokens from cache
#
#	Return the swarm tokens from the cache, if any
#
# Arguments:
#	vm	Virtual machine description dictionary
#
# Results:
#   List of two tokens: token for joining managers and token for joining
#   workers, or an empty list.
#
# Side Effects:
#	None
proc ::cluster::swarmmode::TokenCache { vm } {
    # Generate file name for token caching out of yaml path.
    set tkn_path [CacheFile [dict get $vm origin] ${vars::-ext}]

    if { [catch {open $tkn_path} fd] == 0 } {
        lassign [read $fd] manager worker
        close $fd

        return [list $manager $worker]
    } else {
        log WARN "Cannot read swarm mode tokens from $tkn_path: $fd"
    }
    return [list]
}

# ::cluster::swarmmode::TokenGet -- Get Token
#
#       Actively request a virtual machine for one of its swarm mode tokens.
#
# Arguments:
#       vm      Virtual machine descrition
#       mode    One of: manager or worker
#
# Results:
#       The current relevant token, empty string on errors
#
# Side Effects:
#       None
proc ::cluster::swarmmode::TokenGet { vm mode } {
    set nm [dict get $vm -name]    
    set response [Machine -return -stderr -- \
            -s [storage $vm] ssh $nm "docker swarm join-token -q $mode"]
    if { [string match -nocase "*not*swarm manager*" $response] } {
        log WARN "Machine $nm is not a swarm manager!"
        return ""
    }
    return $response
}


package provide cluster::swarmmode 0.2

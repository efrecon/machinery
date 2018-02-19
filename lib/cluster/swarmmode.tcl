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

package require cluster::tooling
package require cluster::extend
package require cluster::utils
package require cluster::unix
package require cluster::environment
package require huddle;           # To parse and operate on stack files

namespace eval ::cluster::swarmmode {
    # Encapsulates variables global to this namespace under their own
    # namespace, an idea originating from http://wiki.tcl.tk/1489.
    # Variables which name start with a dash are options and which
    # values can be changed to influence the behaviour of this
    # implementation.
    namespace eval vars {
        # Extension for token cache file
        variable -ext       .swt
        # Prefix for labels
        variable -prefix    "com.docker-machinery"
        # Auto-labels sections
        variable -autolabel "os cpu storage"
        # Characters to keep
        variable keepCharacters "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"        
    }
    # Export all lower case procedure, arrange to be able to access
    # commands from the parent (cluster) namespace from here and
    # create an ensemble command called swarmmode (note the leading :: to make
    # this a top-level command!) to ease API calls.
    namespace export {[a-z]*}
    namespace path [namespace parent]
    namespace ensemble create -command ::swarmmode
    namespace import [namespace parent]::Machines \
                        [namespace parent]::IsRunning \
                        [namespace parent]::CacheFile \
                        [namespace parent]::AbsolutePath
    namespace import [namespace parent]::utils::log
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
                set addr [tooling machine -return -- \
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
                    set res [tooling machine -return -- -s [storage $vm] ssh $nm $cmd]
                    if { [string match "*swarm*${mode}*" $res] } {
                        # Ask manager about whole swarm state and find out the
                        # identifier of the newly created node.
                        set state [tooling machine -return -- -s [storage $vm] ssh $mnm "docker node ls"]
                        foreach m [tooling parser $state [list "MANAGER STATUS" "MANAGER_STATUS"]] {
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


proc ::cluster::swarmmode::autolabel { vm masters } {
    set nm [dict get $vm -name]    
    set labelling {}

    foreach s ${vars::-autolabel} {
        set s [string tolower [string trim $s .]]
        switch -- $s {
            "os" {
                log INFO "Collecting OS information for $nm"
                # OS Information
                dict for {k v} [unix release $vm] {
                    lappend labelling \
                        --label-add \
                            [string trimright ${vars::-prefix} .].$s.$k=\"[environment quote $v]\"
                }
            }
            "cpu" {
                log INFO "Collecting CPU information for $nm"
                set cpuinfo [tooling machine -return -stderr \
                                -- -s [storage $vm] ssh $nm "lscpu"]
                foreach line $cpuinfo {
                    set colon [string first ":" $line]
                    if { $colon >= 0 } {
                        set k [string trim [string range $line 0 [expr {$colon-1}]]]
                        set v [string trim [string range $line [expr {$colon+1}] end]]
                        lappend labelling \
                            --label-add \
                                [string trimright ${vars::-prefix} .].$s.[CleanString $k]=\"[environment quote $v]\"

                    }
                }
            }
            "storage" {
                log INFO "Collecting storage information for $nm"
                set blkinfo [tooling machine -return -stderr \
                                -- -s [storage $vm] ssh $nm "lsblk -d -o name,hotplug,rm,rota,size"]
                set header [lindex $blkinfo 0]
                foreach line [lrange $blkinfo 1 end] {
                    set d [MakeDict $header $line {RM removable ROTA rotational}]
                    dict for {k v} $d {
                        if { $k ne "name" } {
                            lappend labelling \
                                --label-add \
                                    [string trimright ${vars::-prefix} .].$s.[dict get $d name].[CleanString $k]=\"[environment quote $v]\"
                        }
                    }
                }
            }
        }
    }

    if { [llength $labelling] } {
        log NOTICE "Automatically labelling $nm within ${vars::-autolabel} namespace"
        node $masters update {*}$labelling $nm
    }
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
proc ::cluster::swarmmode::leave { vm masters } {
    set nm [dict get $vm -name]    
    switch -- [mode $vm] {
        "manager" {
            # Demote the manager from the swarm so it can gracefully handover state
            # to other managers.
            tooling machine -- -s [storage $vm] ssh $nm "docker node demote $nm"
            set response [tooling machine -return -stderr \
                            -- -s [storage $vm] ssh $nm "docker swarm leave"]
            if { [string match "*`--force`*" $response] } {
                log NOTICE "Forcing node $nm out of swarm!"
                tooling machine -- -s [storage $vm] ssh $nm "docker swarm leave --force"
            }
        }
        "worker" {
            tooling machine -- -s [storage $vm] ssh $nm "docker swarm leave"        
        }
    }
}


# ::cluster::swarmmode::network -- create/destroy networks
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
proc ::cluster::swarmmode::network { masters cmd net } {
    # Pick a manager to use for network operations
    set managers [Managers $masters]
    set mgr [PickManager $managers]
    if { [dict exists $mgr -name] } {
        set nm [dict get $mgr -name]
        switch -nocase -- $cmd {
            "up" -
            "create" {
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
                    set id [tooling machine -return -- -s [storage $mgr] ssh $nm $cmd]
                    log NOTICE "Created swarm-wide network $id"
                }
                return $id
            }
            "destroy" -
            "delete" -
            "rm" -
            "remove" -
            "down" {
                tooling machine -- -s [storage $mgr] ssh $nm "docker network rm $net"
            }
        }
    } else {
        log WARN "No running manager to pick for network operation: $cmd"
    }

    return 0
}


# ::cluster::swarmmode::node -- pure docker node relay
#
#      Relays docker node command randomly to one of the masters.
#
# Arguments:
#      masters  List of masters
#      cmd      docker node sub-command to relay
#      args     Arguments to sub-command
#
# Results:
#      None.
#
# Side Effects:
#      Calls docker node on one of the masters and relays its output.
proc ::cluster::swarmmode::node { masters cmd args } {
    # Pick a manager to use for stack operations
    set managers [Managers $masters]
    set mgr [PickManager $managers]
    if { [dict exists $mgr -name] } {
        set nm [dict get $mgr -name]
        tooling machine -- -s [storage $mgr] ssh $nm \
                docker node $cmd {*}$args
    } else {
        log WARN "No running manager to pick for node operation: $cmd"
    }    
}


# ::cluster::swarmmode::stack -- docker stack relay
#
#      Relays docker stack command randomly to one of the masters. Most
#      sub-commands are blindly relayed to the elected master for execution, but
#      deploy goes through some extra processing. First, this implementatio will
#      linearise the YAML content so that it is still possible to use 'extends'
#      constructs (from v2 format) in v3 format. Secondly all files that are
#      pointed at by the compose file will be copied to the manager. Finally,
#      the YAML file for deployment is sent over, but modified in order to point
#      at the local copies of the depending files.
#
# Arguments:
#      masters  List of masters
#      cmd      docker stack sub-command to relay
#      args     Arguments to sub-command
#
# Results:
#      None.
#
# Side Effects:
#      Calls docker stack on one of the masters and relays its output.
proc ::cluster::swarmmode::stack { masters cmd args } {
    # Pick a manager to use for stack operations
    set managers [Managers $masters]
    set mgr [PickManager $managers]
    if { [dict exists $mgr -name] } {
        set nm [dict get $mgr -name]

        # Recognise dot-led commands as commands that we should execute and
        # return results for (instead of regular terminal output). This is 
        # a bit of a hack...
        set return 0
        if { [string match .* $cmd] } {
            set return 1
            set cmd [string range $cmd 1 end]
        }

        switch -nocase -- $cmd {
            "up" -
            "deploy" {
                # Capture up and deploy (they are aliases within the set of
                # docker stack commands). This is in order to benefit from some
                # of the compose v2 features in v3 formatted files, but also to
                # be able to forward all underlying files to the manager
                # (temporarily) before deployment.
                
                # Immediate bypassed if we hade requested for return
                if { $return } {
                    return [tooling machine -return -- -s [storage $mgr] ssh $nm \
                                docker stack $cmd {*}$args]
                }

                # Start by detecting the compose file that is used for
                # deployment.
                set fname ""
                if { ![utils getopt args -c fname] } {
                    utils getopt args --compose-file fname
                }
                
                if { $fname ne "" } {
                    # Resolve file to absolute location
                    set c_fname [AbsolutePath $mgr $fname]
                    
                    if { [catch {open $c_fname} fd] } {
                        log WARN "Cannot open stack description file: $fd"
                    } else {
                        # Prepare a directory for (temporary) storage of related
                        # files at the manager. We use the name of the directory
                        # holding the compose file together with the name of the
                        # compose file to make this something we can easily
                        # understand and debug in.
                        set dirbase [file tail [file dirname $c_fname]]-[file rootname [file tail $c_fname]]
                        set tmp_dirname [utils temporary [file join [utils tmpdir] $dirbase]]
                        log INFO "Temporarily copying all files included by $c_fname to $nm in $tmp_dirname"
                        tooling machine -stderr -- -s [storage $mgr] ssh $nm mkdir -p $tmp_dirname
                        
                        # Linearise content of compose file into a huddle
                        # representation that does not contain any 'extends'
                        # references (this is what our friend-tool baclin does)
                        set hdl [extend linearise2huddle [read $fd] [file dirname $c_fname]]
                        close $fd
                        
                        # Now detects all files that are pointed at by the
                        # compose file and collect then so we will be copying
                        # them.
                        set copies [list]
                        set services [huddle get $hdl "services"]
                        foreach name [huddle keys $services] {
                            set service [huddle get $services $name]
                            foreach k [huddle keys $service] {
                                switch -- $k {
                                    "env_file" {
                                        set v [huddle get $service $k]
                                        if { [string match "str*" [huddle type $v]] } {
                                            set fname [huddle get_stripped $service $k]
                                            set dst_fname [SCopy $mgr [file dirname $c_fname] $fname $tmp_dirname]
                                            huddle set service $k $dst_fname
                                        } else {
                                            # Empty v (which will keep its type)
                                            while {[huddle llength $v]} {
                                                huddle remove $v 0
                                            }
                                            # Copy files to destination and
                                            # account for location in v
                                            # again.
                                            foreach fname [huddle get stripped $service $k] {
                                                huddle append v [SCopy $mgr [file dirname $c_fname] $fname $tmp_dirname]
                                            }
                                            # Set back into service.
                                            huddle set service $k $v
                                        }
                                    }
                                }
                            }
                            huddle set services $name $service
                        }
                        huddle set hdl services $services
                        Inline $mgr hdl "configs" [file dirname $c_fname] $fname $tmp_dirname
                        Inline $mgr hdl "secrets" [file dirname $c_fname] $fname $tmp_dirname

                        # Now create local temporary file to host manipulated
                        # content in and copy it to the remote host.
                        set tmp_fname [utils temporary [file join [utils tmpdir] [file rootname [file tail $c_fname]].yml]]
                        log INFO "Linearising content into $tmp_fname"                        
                        set yaml [extend huddle2yaml $hdl]                        
                        if { [catch {open $tmp_fname w} ofd] } {
                            log WARN "Cannot create temporary file for linearised content: $fd"
                        } else {
                            puts $ofd $yaml
                            close $ofd
                            
                            log NOTICE "Deploying stack [lindex $args end] from files at $tmp_dirname"
                            set dst_fname [file join $tmp_dirname [file tail $tmp_fname]]
                            tooling machine -stderr -- -s [storage $mgr] scp $tmp_fname ${nm}:$dst_fname
                            tooling machine -- -s [storage $mgr] ssh $nm \
                                    docker stack deploy --compose-file $dst_fname {*}$args
                            tooling machine -stderr -- -s [storage $mgr] ssh $nm rm -rf $tmp_dirname
                            file delete -force -- $tmp_fname
                        }
                    }
                } else {
                    log WARN "No compose file specified!"
                    tooling machine -- -s [storage $mgr] ssh $nm \
                            docker stack $cmd --help                
                }
            }
            "__truename" {
                set truenames [list]
                # This is an internal command!
                set stacks [tooling parser [stack $masters .ls]]
                foreach name $args {
                    lappend truenames $name
                    foreach running $stacks {
                        if { [dict exists $running name] \
                                && [NameCmp [dict get $running name] $name] } {
                            set truenames [lreplace $truenames end end [dict get $running name]]
                            break
                        }
                    }
                }
                return $truenames                
            }
            "ps" -
            "services" {
                # Trying resolving last argument (the stack name) to something
                # that really runs.
                set stack [stack $masters __truename [lindex $args end]]
                set args [lreplace $args end end $stack]
                # In all other cases, we simply forward everything to docker
                # stack, which allows us to be forward compatible with any
                # command that it provides now and might provide in the future.
                if { $return } {
                    return [tooling machine -return -- -s [storage $mgr] ssh $nm \
                                docker stack $cmd {*}$args]
                } else {
                    tooling machine -- -s [storage $mgr] ssh $nm \
                            docker stack $cmd {*}$args                
                }
            }
            "remove" -
            "down" -
            "rm" {
                # All arguments are stack names, trying resolving all of them
                set args [stack $masters __truename {*}$args]
                # In all other cases, we simply forward everything to docker
                # stack, which allows us to be forward compatible with any
                # command that it provides now and might provide in the future.
                if { $return } {
                    return [tooling machine -return -- -s [storage $mgr] ssh $nm \
                                docker stack $cmd {*}$args]
                } else {
                    tooling machine -- -s [storage $mgr] ssh $nm \
                            docker stack $cmd {*}$args                
                }
            }
            default {
                # In all other cases, we simply forward everything to docker
                # stack, which allows us to be forward compatible with any
                # command that it provides now and might provide in the future.
                if { $return } {
                    return [tooling machine -return -- -s [storage $mgr] ssh $nm \
                                docker stack $cmd {*}$args]
                } else {
                    tooling machine -- -s [storage $mgr] ssh $nm \
                            docker stack $cmd {*}$args                
                }
            }
        }
    } else {
        log WARN "No running manager to pick for stack operation: $cmd"
    }    
}



####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################


# ::cluster::swarmmode::Inline -- Huddle inlining
#
#      Detects if a main key in the huddle representation of a YAML file
#      contains a specific subkey (defaults to 'file'). Whenver that sub-key
#      exists, the file that it points at is copied to a swarm manager and the
#      huddle representation is modified so as to point at the path to the copy
#      at the manager.
#
# Arguments:
#      mgr         Representation of the manager machine
#      hdl_        Huddle representation to look into and possibly modify
#      mainkey     Main key to address
#      dir         Local directory hosting the file
#      fname       Name of file source of the huddle representation
#      tmp_dirname Name of the remote directory at the manager where to copy files to
#      subkey      Children key to enquire and possibly modify in huddle representation
#
# Results:
#      None.
#
# Side Effects:
#      Modifies the huddle representation so that it points at the remote file instead
proc ::cluster::swarmmode::Inline { mgr hdl_ mainkey dir fname tmp_dirname { subkey "file" } } {
    upvar $hdl_ hdl

    if { $mainkey in [huddle keys $hdl] } {
        set configs [huddle get $hdl $mainkey]
        foreach name [huddle keys $configs] {
            set config [huddle get $configs $name]
            if { "$subkey" in [huddle keys $config] } {
                set v [huddle get $config $subkey]
                set fname [huddle get_stripped $config $subkey]
                set dst_fname [SCopy $mgr $dir $fname $tmp_dirname]
                set config [string map [list [huddle get_stripped $config $subkey] $dst_fname] $config]
                #huddle set config $subkey $dst_fname
            }
            huddle set configs $name $config
        }
        huddle set hdl $mainkey $configs
    } else {
        log DEBUG "No key $mainkey found, but this is ok!"
    }
}


# ::cluster::swarmmode::SCopy -- Temporary manager file copy
#
#      Copy a file to a manager within a dedicated directory. A temporary name
#      for the destination file will be generated in a way that makes it easy to
#      detect the name of the source file.
#
# Arguments:
#      mgr         Representation of the manager machine
#      dir         Local directory hosting the file
#      fname       Name of file to copy
#      tmp_dirname Name of the remote directory at the manager where to copy files to
#
# Results:
#      The full path to the remote copy or an empty string on errors.
#
# Side Effects:
#      None.
proc ::cluster::swarmmode::SCopy { mgr dir fname tmp_dirname } {
    set nm [dict get $mgr -name]
    set src_fname [file join $dir $fname]
    if { [file exists $src_fname] } {
        set dst_fname [utils temporary [file join $tmp_dirname [file rootname [file tail $fname]]]]
        tooling machine -stderr -- -s [storage $mgr] scp $src_fname ${nm}:$dst_fname
        return $dst_fname
    } else {
        log WARN "Cannot access file at $src_fname!"
    }
    return ""    
}


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
        set res [tooling machine -return -- -s [storage $vm] ssh $nm $cmd]
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
    set networks [tooling machine -return -- -s [storage $mgr] ssh $nm "docker network ls --no-trunc=true"]
    foreach n [tooling parser $networks [list "NETWORK ID" NETWORK_ID]] {
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
    set response [tooling machine -return -stderr -- \
            -s [storage $vm] ssh $nm "docker swarm join-token -q $mode"]
    if { [string match -nocase "*not*swarm manager*" $response] } {
        log WARN "Machine $nm is not a swarm manager!"
        return ""
    }
    return $response
}

proc ::cluster::swarmmode::CleanString { str { replace "" } } {
    set retstr ""
    set allowed [split $vars::keepCharacters ""]
    foreach c [split $str ""] {
        if { $c in $allowed } {
            append retstr $c
        } else {
            append retstr $replace
        }
    }

    return $retstr
}

proc ::cluster::swarmmode::MakeDict { header values { replacements {} }} {
    for { set i 0 } { $i < [llength $header] } { incr i } {
        set k [lindex $header $i]
        if { [dict exists $replacements $k] } {
            set k [dict get $replacements $k]
        }
        dict set d [string tolower $k] [lindex $values $i]
    }
    return [dict get $d]
}

package provide cluster::swarmmode 0.3

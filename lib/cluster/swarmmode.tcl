namespace eval ::cluster::swarmmode {
    # Encapsulates variables global to this namespace under their own
    # namespace, an idea originating from http://wiki.tcl.tk/1489.
    # Variables which name start with a dash are options and which
    # values can be changed to influence the behaviour of this
    # implementation.
    namespace eval vars {
        # Extension for managers info storage
        variable -manager   .mgr
        # Extension for token cache file
        variable -token     .swt
        # List of "on" state
        variable -running   {running timeout}
    }
    # Export all lower case procedure, arrange to be able to access
    # commands from the parent (cluster) namespace from here and
    # create an ensemble command called swarmmode (note the leading :: to make
    # this a top-level command!) to ease API calls.
    namespace export {[a-z]*}
    namespace path [namespace parent]
    namespace ensemble create -command ::swarmmode
    namespace import [namespace parent]::Machine \
                        [namespace parent]::CacheFile \
                        [namespace parent]::ListParser
}


proc ::cluster::swarmmode::join { vm } {
    ManagerSync $vm
    set manager [ManagerGet $vm]
    if { [llength $manager] } {
        lassign $manager mgr addr        
        set nm [dict get $vm -name]
        lassign [Tokens $vm] tkn_mngr tkn_wrkr
    
        set cmd [list docker swarm join]
        Options cmd join $vm
        # Add token and ip address of master that we communicate with
        if { [dict exists $vm -master] && [dict get $vm -master] } {
            set mode manager
            lappend cmd --token $tkn_mngr $addr
        } else {
            set mode worker
            lappend cmd --token $tkn_wrkr $addr          
        }
        set res [Machine -return -- -s [storage $vm] ssh $nm $cmd]
        if { [string match "*swarm*${mode}*" $res] } {
            set id [string trim \
                        [Machine -return -- -s [storage $vm] ssh $mgr \
                            "docker node inspect --format '{{ .ID }}' $nm"]]
            log NOTICE "Machine $nm joined swarm as $mode as node $id"

            # Arrange to cache information abount manager
            if { $mode eq "manager" } {
                ManagerPut $vm
            }

            return $id
        } else {
            log WARN "Machine $nm could not join swarm as $mode: $res"
            return ""
        }
        return $res
    } else {
        return [Init $vm]
    }
    return ""; # Never reached
}


proc ::cluster::swarmmode::mode { vm } {
    # Check if running new swarm mode
    if { [string match -nocase "swarm*mode" \
                [dict get $vm cluster -clustering]] } {
        # Check if we haven't turned off swarming for that node
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


proc ::cluster::swarmmode::leave { vm } {
    ManagerSync $vm
    set nm [dict get $vm -name]    
    switch -- [mode $vm] {
        "manager" {
            # Demote the manager from the swarm so it can gracefully handover state
            # to other managers.
            ManagerDel $vm        
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



# Actively initiate the (firt) node of a swarm
proc ::cluster::swarmmode::Init { vm } {
    if { [mode $vm] eq "manager" } {    
        set nm [dict get $vm -name]    
    
        set cmd [list docker swarm init]
        Options cmd init $vm
        set res [Machine -return -- -s [storage $vm] ssh $nm $cmd]
        if { [regexp {.*\(([a-z0-9]+)\).*manager.*} $res mtch id] } {
            log NOTICE "Initialised machine $nm as node $id in swarm"

            # Arrange to cache information abount manager and swarm
            ManagerPut $vm
            TokenStore $vm
            
            return $res
        } else {
            log WARN "Could not initialise swarm on $nm: $res"
        }
    }
    
    return "";   # Catch all errors
}


# Pick init/join options if there are some from swarm
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


# Synchronise cached status with current swarm status, as long as we can find an
# available manager
proc ::cluster::swarmmode::ManagerSync { vm } {
    lassign [ManagerGet $vm] mgr addr
    if { $mgr ne "" && $addr ne "" } {
        set state [Machine -return -- -s [storage $vm] ssh $mgr "docker node ls"]
        foreach m [ListParser $state [list "MANAGER STATUS" "MANAGER_STATUS"]] {
            if { [dict exists $m manager_status] && [dict exists $m hostname] } {
                switch -nocase -- [dict get $mgr manager_status] {
                    "leader" -
                    "reachable" {
                        set addr [Machine -return -- \
                                    -s [storage $vm] ssh $mgr \
                                        "docker node inspect --format '{{ .ManagerStatus.Addr }}' [dict get $m hostname]"]
                        set addr [string trim $addr]
                        if { $addr ne "" } {
                            set MGRS([dict get $m hostname]) $addr
                        }
                    }
                }
            }
        }
        set mgr_path [CacheFile [dict get $vm origin] ${vars::-manager}]
        ManagerCache $mgr_path MGRS write
    }
}


proc ::cluster::swarmmode::ManagerGet { vm { ptn * } } {
    # Generate file name for managers caching out of yaml path.
    set mgr_path [CacheFile [dict get $vm origin] ${vars::-manager}]
    
    # Read current state
    ManagerCache $mgr_path MGRS read

    # Pick up a manager at random out of the known managers from the cache.
    set len [llength [array names MGRS $ptn]]
    if { $len > 0 } {
        set i [expr {int(rand()*$len)}]
        set mch [lindex [array names MGRS $ptn] $i]
        return [list $mch $MGRS($mch)]
    }
    
    return [list]
}


proc ::cluster::swarmmode::ManagerPut { vm } {
    if { [dict exists $vm -master] && [dict get $vm -master] } {
        # Generate file name for managers caching out of yaml path.
        set mgr_path [CacheFile [dict get $vm origin] ${vars::-manager}]
        
        set nm [dict get $vm -name]    
        ManagerCache $mgr_path MGRS read
        set addr [Machine -return -- \
                    -s [storage $vm] ssh $nm "docker node inspect --format '{{ .ManagerStatus.Addr }}' self"]
        set MGRS($nm) [string trim $addr]
        ManagerCache $mgr_path MGRS write
    }
}


proc ::cluster::swarmmode::ManagerDel { vm } {
    if { [mode $vm] eq "manager" } {
        # Generate file name for managers caching out of yaml path.
        set mgr_path [CacheFile [dict get $vm origin] ${vars::-manager}]
        
        ManagerCache $mgr_path MGRS read
        set nm [dict get $vm -name]
        catch {unset MGRS($nm)}
        ManagerCache $mgr_path MGRS write
    }
}


proc ::cluster::swarmmode::ManagerCache { mgr_path mgrs_ mode } {
    upvar $mgrs_ MGRS
    
    switch -nocase -- $mode {
        "read" {
            # Read current state
            if { [file exists $mgr_path] } {
                log DEBUG "Reading current manager state from $mgr_path"
                set fd [open $mgr_path]
                array set MGRS [read $fd]
                close $fd
                return 1
            }            
        }
        "write" {
            log DEBUG "Caching swarm mode tokens at $mgr_path"
            if { [catch {open $mgr_path w} fd] == 0 } {
                puts $fd [array get MGRS]
                close $fd
                return 1
            } else {
                log WARN "Cannot store swarm managers at $mgr_path: $fd"
            }            
        }
    }
    return 0; # Catch all errors
}


# This should be the only proc to use.
proc ::cluster::swarmmode::Tokens { vm { force 0 } } {
    if { $force } {
        if { [mode $vm] ne "manager" } {
            log WARN "Cannot only force active collection of tokens via manager node!"
        } else {
            TokenStore $vm
        }
    }

    set tkn_path [CacheFile [dict get $vm origin] ${vars::-token}]
    if { ![file exists $tkn_path] && [mode $vm] eq "manager" } {
        TokenStore $vm
    }
    return [TokenCache $vm]
}


proc ::cluster::swarmmode::TokenStore { vm } {
    # Generate file name for token caching out of yaml path.
    set tkn_path [CacheFile [dict get $vm origin] ${vars::-token}]

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


proc ::cluster::swarmmode::TokenCache { vm } {
    # Generate file name for token caching out of yaml path.
    set tkn_path [CacheFile [dict get $vm origin] ${vars::-token}]

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


package provide cluster::swarmmode 0.1

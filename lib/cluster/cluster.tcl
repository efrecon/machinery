##################
## Module Name     --  cluster
## Original Author --  Emmanuel Frecon - emmanuel@sics.se
## Description:
##
##    This library provides a high-level interface to handling a
##    cluster of machines under the control of docker-machine.  It is
##    able to read the cluster definition from a yaml file,
##    synchronise with the current state of accessible machines and
##    then create, restart, etc machines as necessary.
##
##    In the following procedures, a cluster is represented by a list
##    of virtual machines, and each machine is represented by a
##    dictionary.  In the dictionaries, the keys issued from YAML
##    parsing are all preceeded with the - (dash) sign, while keys
##    that come from the dynamic state of the cluster (as of
##    docker-machine ls) will not have any leading dash.
##
##################
package require Tcl 8.6;  # We require chan pipe
package require platform
package require yaml;     # This is found in tcllib
package require cluster::virtualbox
package require cluster::vcompare
package require cluster::unix
package require cluster::swarmmode
package require cluster::environment
package require cluster::tooling


# Hard sourcing of the local json package to avoid using the one from
# tcllib.
source [file join [file dirname [file normalize [info script]]] json.tcl]

namespace eval ::cluster {
    # Encapsulates variables global to this namespace under their own
    # namespace, an idea originating from http://wiki.tcl.tk/1489.
    # Variables which name start with a dash are options and which
    # values can be changed to influence the behaviour of this
    # implementation.
    namespace eval vars {
        # String separting prefix (if any) from machine name.
        variable -separator "-"
        # Allowed VM keys
        variable -keys      {cpu size memory master labels driver options \
                             ports shares images compose registries aliases \
                             addendum files swarm prelude}
        # Current verbosity level
        variable -verbose   NOTICE
        # Locally cache images?
        variable -cache     on
        # Caching rules. First match (glob-style) will prevail. These are only
        # hints for how -cache will perform.
        variable -caching   "*/*/* on * off"
        # Path to storage directory for docker machine cache, empty string will
        # default to a directory co-located with the cluster YAML file.
        variable -storage   ""
        # Location of boot2docker profile
        variable -profile   /var/lib/boot2docker/profile
        # Location of boot2docker bootlocal
        variable -bootlocal /var/lib/boot2docker/bootlocal.sh
        # Marker in bootlocal
        variable -marker    "#### A U T O M A T E D  ## S/E/C/T/I/O/N ####"
        # Mapping from integer to string representation of verbosity levels
        variable verboseTags {1 FATAL 2 ERROR 3 WARN 4 NOTICE 5 INFO 6 DEBUG 7 TRACE}
        # Extension for machine storage cache directory
        variable -ext       .mch
        # File descriptor to dump log messages to
        variable -log       stderr
        # Date log output
        variable -date      "%Y%m%d %H%M%S"
        # Temporary directory, empty for good platform guess
        variable -tmp       ""
        # Default number of retries when polling
        variable -retries   3
        # Environement variable prefix
        variable -prefix    "MACHINERY_"
        # Sharing mapping between drivers (pattern matching) and types
        variable -sharing   "virtualbox vboxsf * rsync"
        # ssh command to use towards host
        variable -ssh       ""
        # List of "on" state
        variable -running   {running timeout}
        # Cluster state caching retention (in ms, negative for off)
        variable -retention 10000
        # Defaults for networks (see: https://github.com/moby/moby/issues/32957)
        variable -networks  {-driver overlay -attachable true -scope swarm}
        # Supported sharing types.
        variable sharing    {vboxsf rsync}
        # name of VM that we are attached to
        variable attached   ""
        # Size converters
        variable converters [list \
                {^b$} 1 \
                {^k(?!i)(b|)$} 1000.0 \
                {^ki(b|)$}     1024.0 \
                {^m(?!i)(b|)$} [expr {pow(1000,2)}] \
                {^mi(b|)$}     [expr {pow(1024,2)}] \
                {^g(?!i)(b|)$} [expr {pow(1000,3)}] \
                {^gi(b|)$}     [expr {pow(1024,3)}] \
                {^t(?!i)(b|)$} [expr {pow(1000,4)}] \
                {^ti(b|)$}     [expr {pow(1024,4)}] \
                {^p(?!i)(b|)$} [expr {pow(1000,5)}] \
                {^pi(b|)$}     [expr {pow(1024,5)}] \
                {^e(?!i)(b|)$} [expr {pow(1000,6)}] \
                {^ei(b|)$}     [expr {pow(1024,6)}] \
                {^z(?!i)(b|)$} [expr {pow(1000,7)}] \
                {^zi(b|)$}     [expr {pow(1024,7)}] \
                {^y(?!i)(b|)$} [expr {pow(1000,8)}] \
                {^yi(b|)$}     [expr {pow(1024,8)}]]
        # Dynamically discovered list of machine create options
        variable machopts {}
        # List of additional driver specific options that should be
        # resolved into absolute path.
        variable absPaths {azure-publish-settings-file azure-subscription-cert hyper-v-boot2docker-location generic-ssh-key}
        # Finding good file candidates
        variable lookup "*.yml";    # Which files to consider for YAML parsing
        variable marker {^#\s*docker\-machinery}
        # Good default machine for local storage of images (for -cache)
        variable defaultMachine ""
        # Characters to keep in temporary filepath
        variable fpathCharacters "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/-.,=_"
        # Local volume mounts on windows
        variable volMounts {}
        # Cluster status cache
        variable cluster   { last 0 cluster {}}
    }
    # Automatically export all procedures starting with lower case and
    # create an ensemble for an easier API.
    namespace export {[a-z]*}
    namespace ensemble create
}



# ::cluster::defaults -- Set/get default parameters
#
#       This procedure takes an even list of keys and values used to
#       set the values of the options supported by the library.  The
#       list of options is composed of all variables starting with a
#       dash in the vars sub-namespace.  In the list, the dash
#       preceding the key is optional.
#
# Arguments:
#        args        List of key and values to set for module options.
#
# Results:
#       A dictionary with all current keys and their values
#
# Side Effects:
#       None.
proc ::cluster::defaults { {args {}}} {
    foreach {k v} $args {
        set k -[string trimleft $k -]
        if { [info exists vars::$k] } {
            set vars::$k $v
        }
    }
    
    if { "win32" in [split [::platform::generic] -] \
                && $vars::defaultMachine eq "" } {
        set vars::defaultMachine [DefaultMachine]
        log NOTICE "Will use '$vars::defaultMachine' as the default machine"
    }
    
    set state {}
    foreach v [info vars vars::-*] {
        lappend state [lindex [split $v ":"] end] [set $v]
    }
    return $state
}

# ::cluster::getopt -- Quick and Dirty Options Parser
#
#       Parses options, code comes from wiki.  Once parsed, an option
#       (and its argument) are removed from the argument list.
#
# Arguments:
#        _argv        List of arguments to parse
#        name        Name of option to look for.
#        _var        Pointer to variable in which to store value
#        dft        Default value if not found
#
# Results:
#       1 if option was found, 0 otherwise.
#
# Side Effects:
#       Modifies the incoming arguments list.
proc ::cluster::getopt {_argv name {_var ""} {dft ""}} {
    upvar $_argv argv $_var var
    set pos [lsearch -regexp $argv ^$name]
    if {$pos>=0} {
        set to $pos
        if {$_var ne ""} {
            set var [lindex $argv [incr to]]
        }
        set argv [lreplace $argv $pos $to]
        return 1
    } else {
        # Did we provide a value to default?
        if {[llength [info level 0]] == 5} {set var $dft}
        return 0
    }
}


# ::cluster::log -- Conditional logging
#
#       Conditionally output the message passed as an argument
#       depending on the current module debug level.  The level can
#       either be an integer or one of FATAL ERROR WARN NOTICE INFO
#       DEBUG, where FATAL corresponds to level 1 and DEBUG to
#       level 6.  Level 0 will therefor turn off ALL debugging.
#       Logging happens on the standard error, but this can be changed
#       through the -log option to the module.  Logging is pretty
#       printed using ANSI codes when the destination channel is a
#       terminal.
#
# Arguments:
#        lvl        Logging level of the message
#        msg        String content of the message.
#
# Results:
#       None.
#
# Side Effects:
#       Output message to logging channel whenever at the proper level.
proc ::cluster::log { lvl msg } {
    # If we should output (i.e. level of message is below the global
    # module level), pretty print and output.
    if { [Log? $lvl l] } {
        set toTTY [dict exists [fconfigure ${vars::-log}] -mode]
        # Output the whole line.
        if { $toTTY } {
            puts ${vars::-log} [LogTerminal $l $msg]
        } else {
            puts ${vars::-log} [LogStandard $l $msg]
        }
    }
}


# ::cluster::ls -- Return dynamic state of cluster
#
#       This will return the dynamic state of the cluster as returned
#       by docker-machine ls.  Only the machines which names match the
#       incoming parameter will be returned.  A list of dictionaries
#       will be returned.  The implementation uses the header or the
#       docker-machine ls output to become the list of keys
#       (transformed to all lower case).  Values are transmitted to
#       the dictionary as is.
#
# Arguments:
#        yaml        Path to YAML description of cluster
#        machines    glob-style pattern to match on machine names
#
# Results:
#       Return a list of dictionaries, one dictionary for the state of
#       each machine which name matches the argument.
#
# Side Effects:
#       None.
proc ::cluster::ls { yaml {machines *} { force 0 } } {
    # Decide if we really should capture
    set now [clock milliseconds]
    if { ${vars::-retention} < 0 } {
        set capture 1
    } elseif { $force } {
        set capture 1
    } else {
        set capture [expr {$now - [dict get $vars::cluster last] > ${vars::-retention}}]
        if { !$capture } {
            log DEBUG "Skipping active capture of cluster overview, taking from cache instead"
        }
    }
    
    # Get current state of cluster and arrange for cols to be the list
    # of keys (this is the first line of docker-machine ls output,
    # meaning the header).
    if { $capture } {
        log NOTICE "Capturing current overview of cluster"
        set state [tooling machine -return -- -s [StorageDir $yaml] ls]
        dict set vars::cluster cluster [tooling parser $state]
        dict set vars::cluster last $now
    }
    
    set cluster {};   # The list of dictionaries we will return
    foreach nfo [dict get $vars::cluster cluster] {
        # Add only machines which name matches the incoming pattern.
        if { [dict exists $nfo name] \
                    && [string match $machines [dict get $nfo name]] } {
            lappend cluster $nfo
        }
    }
    return $cluster
}


# ::cluster::names -- Return the names of the machines in a cluster
#
#       Return the list of machines names declared in a cluster
#       (result of YAML parsing).
#
# Arguments:
#        cluster        List of machine description dictionaries.
#
# Results:
#       List of names
#
# Side Effects:
#       None.
proc ::cluster::names { cluster } {
    set names {}
    foreach vm [Machines $cluster] {
        lappend names [dict get $vm -name]
    }
    return $names
}


# ::cluster::find -- Find a machine by its name
#
#       Return the machine dictionary for a name within a given
#       cluster.  Lookup is aware of the prefix that can automatically
#       be added to each machine name, but the fullname will be
#       preferred.  As long as names are unique within a cluster,
#       looking up without the prefix is guaranteed to work.
#
# Arguments:
#        cluster     List of machine description dictionaries.
#        name        Name of machine to look for.
#        truename    Set to 1 to ignore aliases
#
# Results:
#       Full dictionary description of machine.
#
# Side Effects:
#       None.
proc ::cluster::find { cluster name { truename 0 } } {
    foreach vm [Machines $cluster] {
        if { [NameCmp [dict get $vm -name] $name] } {
            return $vm
        }
        
        # Lookup by the aliases for a VM
        if { [string is false $truename] } {
            if { [dict exists $vm -aliases] } {
                foreach nm [dict get $vm -aliases] {
                    if { [NameCmp $nm $name] } {
                        return $vm
                    }
                }
            }
        }
    }
    
    return {}
}


proc ::cluster::findAll { cluster {ptn *}} {
    # Fill selection with all the true names of the machines that
    # match the pattern.
    set selection {}
    foreach vm [Machines $cluster] {
        if { [NameCmp [dict get $vm -name] $ptn match] } {
            lappend selection [dict get $vm -name]
        }
        
        # Lookup by the aliases for a VM
        if { [dict exists $vm -aliases] } {
            foreach nm [dict get $vm -aliases] {
                if { [NameCmp $nm $ptn match] } {
                    lappend selection [dict get $vm -name]
                }
            }
        }
    }
    
    # Now sort away duplicates and return the unique list of cluster
    # machines representations
    set vms {}
    foreach nm [lsort -unique $selection] {
        lappend vms [find $cluster $nm 1]
    }
    
    return $vms
}


# ::cluster::bind -- Bind machine description to live status
#
#       This procedure will synchronise the description of a machine
#       issued from YAML parsing to its live status within the
#       cluster.  It will copy the keys issued from the live status
#       into the machine description, with slight modifications to
#       make those accessible to Tcl (e.g. active will become a
#       boolean, true for the machine that is active).
#
# Arguments:
#        vm        Virtual machine description
#        ls        Live cluster description. If -, will be actualised.
#
# Results:
#       A new virtual machine description dictionary.
#
# Side Effects:
#       None.
proc ::cluster::bind { vm {ls -} {options {}} } {
    # Get current status of cluster.
    if { $ls eq "-" } {
        set ls [ls [storage $vm]]
    }
    
    # Traverse current cluster state and stop as soon as we have found
    # a machine which name is the same as the one given as an input
    # parameter.
    foreach m $ls {
        if { [dict exists $m name] } {
            if { [dict get $m name] eq [dict get $vm -name] } {
                # Convert active (which is marked as a "start",
                # *-sign) to a boolean.
                if { [dict exists $m active] } {
                    if { [dict get $m active] eq "" \
                                || [dict get $m active] eq "-" } {
                        dict set vm active off
                    } else {
                        dict set vm active on
                    }
                }
                # Copy the driver, should we?
                if { [dict exists $m driver] } {
                    dict set vm -driver [dict get $m driver]
                }
                # Copy all other keys.
                foreach k [list state url swarm] {
                    if { [dict exists $m $k] } {
                        dict set vm $k [dict get $m $k]
                    }
                }
                break
            }
        }
    }
    
    # Copy options if non empty
    if { [llength $options] } {
        dict set vm cluster $options
    }

    # Return the new modified dictionary.
    return $vm
}


# ::cluster::create -- Create a machine
#
#       Create, tag (if necessary) and verify a virtual machine.
#
# Arguments:
#        vm        Dictionary description of machine (as of YAML parsing)
#        token     Swarm token to use.
#
# Results:
#       The name of the machine on success, empty string otherwise.
#
# Side Effects:
#       None.
proc ::cluster::create { vm token masters networks} {
    set nm [Create $vm $token $masters]
    
    if { $nm ne "" } {
        set vm [Running $vm]
        if { $vm ne {} } {
            # Now that the machine is running, setup all swarm-wide networks if
            # relevant.
            if { [swarmmode mode $vm] eq "manager" && [llength $networks] } {
                log INFO "Creating swarm-wide networks"
                foreach net $networks {
                    swarmmode network $masters create $net
                }
            }

            # Tag virtual machine with labels the hard-way, on older
            # versions.
            if { [vcompare lt [tooling version machine] 0.4] } {
                set vm [tag $vm]
            }
            
            if { $vm ne {} } {
                # Open the ports and creates the shares
                ports $vm
                
                # Test that machine is properly working by echoing its
                # name using a busybox component and checking we get that
                # name back.
                if { [unix daemon $vm docker up] } {
                    log DEBUG "Testing that machine $nm has a working docker\
                               via busybox"
                    Attach $vm
                    if { [tooling docker -return -- run --rm busybox echo $nm] eq "$nm" } {
                        log INFO "Docker setup properly on $nm"
                    } else {
                        log ERROR "Cannot test docker for $nm, check manually!"
                    }
                    
                    init $vm
                } else {
                    log WARN "No docker daemon running on $nm!"
                }
            } else {
                log ERROR "Could not create VM $nm properly"
            }
        } else {
            log ERROR "Could not create VM $nm properly"
        }
    }
    
    return $nm
}


# ::cluster::storage -- Path to machine storage cache
#
#       Return the path to the machine storage cache directory.
#
# Arguments:
#	yaml	Path to YAML description of cluster
#
# Results:
#       Full path to directory for storage
#
# Side Effects:
#       Create the directory if it did not exist prior to this call.
proc ::cluster::storage { vm } {
    if { [dict exists $vm origin] } {
        return [StorageDir [dict get $vm origin]]
    }
    # XXX: We should perhaps look for the environment variable
    # MACHINE_STORAGE_PATH, return that one. And if not present, parse the
    # output of machine help and look for the default value of -s global option.
    return -code error "Cannot find storage directory for [dict get $vm -name]"
}


proc ::cluster::init { vm {steps {shares registries files images prelude compose addendum}} } {
    # Poor man's discovery: write down a description of all the
    # network interfaces existing on the virtual machines,
    # including the most important one (e.g. the one returned by
    # docker-machine ip) as environment variable declaration in a
    # file.
    set vm [bind $vm]
    Discovery $vm
    
    set nm [dict get $vm -name]
    if { [lsearch -nocase $steps shares] >= 0 } {
        shares $vm
    }
    if { [unix daemon $vm docker up] } {
        # Now pull images if any
        if { [lsearch -nocase $steps registries] >= 0 } {
            login $vm
        }
        if { [lsearch -nocase $steps images] >= 0 } {
            pull $vm
        }
        
        if { [lsearch -nocase $steps files] >= 0 } {
            mcopy $vm
        }
        
        if { [lsearch -nocase $steps prelude] >= 0 } {
            prelude $vm
        }
        
        # And iteratively run compose.  Compose will get the complete
        # description of the discovery status in the form of
        # environment variables.
        if { [lsearch -nocase $steps compose] >= 0 } {
            compose $vm UP
        }
        
        if { [lsearch -nocase $steps addendum] >= 0 } {
            addendum $vm
        }
    } else {
        log WARN "No docker daemon running on $nm!"
    }
}

proc ::cluster::tempfile { pfx ext } {
    return [Temporary [file join [TempDir] $pfx].[string trimleft $ext .]]
}


proc ::cluster::ps { vm { swarm 0 } {direct 1}} {
    set vm [bind $vm]
    set nm [dict get $vm -name]
    if { $swarm } {
        log NOTICE "Getting components of cluster"
        Attach $vm -swarm
    } else {
        log NOTICE "Getting components of $nm"
        Attach $vm
    }
    if { $direct } {
        tooling docker -raw -- ps
    } else {
        set state [tooling docker -return -- ps -a]
        return [tooling parser $state [list "CONTAINER ID" "CONTAINER_ID"]]
    }
}

proc ::cluster::search { cluster ptn } {
    set locations {}
    foreach vm $cluster {
        log NOTICE "Searching for $ptn in [dict get $vm -name]"
        foreach c [ps $vm 0 0] {
            if { [dict exists $c names] && [dict exists $c container_id] } {
                foreach nm [split [dict get $c names] ","] {
                    if { [string match $ptn $nm] } {
                        # Append the name of the VM, the name we found
                        # and the container ID (to make sure callers
                        # can pinpoint containers uniquely).
                        lappend locations [dict get $vm -name] \
                                $nm [dict get $c container_id]
                    }
                }
            }
        }
    }
    
    return $locations
}


proc ::cluster::forall { cluster ptn cmd args } {
    set locations {}
    foreach vm $cluster {
        if { $ptn eq "" } {
            log NOTICE "Executing on [dict get $vm -name]: $cmd $args"
            Attach $vm
            tooling docker -- $cmd {*}$args
        } else {
            foreach c [ps $vm 0 0] {
                if { [dict exists $c names] && [dict exists $c container_id] } {
                    foreach nm [split [dict get $c names] ","] {
                        if { [string match $ptn $nm] } {
                            set id [dict get $c container_id]
                            log NOTICE "Executing on $nm: $cmd $args $id"
                            Attach $vm;   # We should really already be attached!
                            tooling docker -- $cmd {*}$args $id
                        }
                    }
                }
            }
        }
    }
}


proc ::cluster::swarm { master op fpath {opts {}}} {
    # Make sure we resolve in proper directory.
    set fpath [AbsolutePath $master $fpath]
    
    environment set $master;    # Pass environment to composition.
    if { [file exists $fpath] } {
        log NOTICE "Reading projects from $fpath"
        set pinfo [::yaml::yaml2dict -file $fpath]
        
        # Detect type of YAML project file and schedule
        set first [lindex $pinfo 0]
        if { [dict exists $first file] } {
            log INFO "Scheduling compose projects pointed by $fpath in cluster"
            compose $master $op 1 $pinfo
        } else {
            log INFO "Scheduling compose project $fpath in cluster"
            set substitution 1
            set projname ""
            set options {}
            foreach {k v} $opts {
                switch -nocase -- $k {
                    "substitution" {
                        set substitution [string is true $v]
                    }
                    "project" {
                        set projname $v
                    }
                    "options" {
                        set options $v
                    }
                    "keep" {
                        if { [string is true $v] } {
                            set substitution 2
                        }
                    }
                }
            }
            Attach $master -swarm
            Project $fpath $op $substitution $projname $options
        }
    } else {
        log WARN "Project file at $fpath does not exist!"
    }
}


# ::cluster::compose -- Run compose for a machine
#
#       Automatically start up one or several compose project within a
#       virtual machine.  Note that the implementation is able to
#       substitute the value of local environment variables before
#       running compose, which binds nicely to the discovery
#       mechanisms implemented as part of machinery.  However, as this
#       is not standard, you will have to explicitely set a flag to
#       true to perform substitution.
#
# Arguments:
#        vm        Dictionary description of machine (must be bound to
#                  live state)
#        projects  List of projects, empty to take from vm.
#
# Results:
#       Return the list of compose files that were effectively run and
#       brought up
#
# Side Effects:
#       None.
proc ::cluster::compose { vm op {swarm 0} { projects {} } } {
    # Get projects, either from parameters (overriding the VM object) or
    # from vm object.
    if { [string length $projects] == 0 } {
        if { ![dict exists $vm -compose] } {
            return {}
        }
        set projects [dict get $vm -compose]
    }
    
    # Pass the discovery variables to compose in case they were needed
    # there...
    environment set $vm
    
    set nm [dict get $vm -name]
    if { $swarm } {
        Attach $vm -swarm
    } else {
        Attach $vm
    }
    set composed {}
    set maindir [pwd]
    foreach project $projects {
        if { [dict exists $project file] } {
            set fpath [dict get $project file]
            # Resolve with initial location of YAML description to
            # make sure we can have relative paths.
            set fpath [AbsolutePath $vm $fpath]
            if { [file exists $fpath] } {
                set descr [string map \
                        [list "UP" "Creating and starting up" \
                        "KILL" "Killing" \
                        "STOP" "Stopping" \
                        "START" "Starting" \
                        "RM" "Removing"] [string toupper $op]]
                log NOTICE "$descr components from $fpath in $nm"
                set substitution 0
                if { [dict exists $project substitution] } {
                    set substitution \
                            [string is true [dict get $project substitution]]
                }
                set options {}
                if { [dict exists $project options] } {
                    set options [dict get $project options]
                }
                set projname ""
                if { [dict exists $project project] } {
                    set projname [dict get $project project]
                }
                set parsed [Project $fpath $op $substitution $projname $options]
                if { $parsed ne "" } {
                    lappend composed $parsed
                }
            } else {
                log WARN "Cannot find compose file at $fpath"
            }
        }
    }
    
    # Clean up environment to avoid pollution.
    log DEBUG "Cleaning environment from ${vars::-prefix} prefixed variables"
    foreach k [array names ::env [string trimright ${vars::-prefix} "_"]_*] {
        unset ::env($k)
    }
    
    if { [llength $composed] > 0 } {
        log INFO "Machine $nm now running the following components"
        tooling docker ps
    }
    
    return $composed
}


proc ::cluster::mcopy { vm { fspecs {}} } {
    # Get list of files to copy from parameters of from VM object
    if { [llength $fspecs] == 0 } {
        if { ![dict exists $vm -files] } {
            return {}
        }
        set fspecs [dict get $vm -files]
    }
    
    set nm [dict get $vm -name]
    foreach fspec $fspecs {
        # Transform old-style, colon separated format into new-style dictionary
        # file copy specification.
        if { [string first ":" $fspec] >= 0 } {
            lassign [split $fspec ":"] src dst hint
            set cpy [dict create source $src destination $dst]
            if { [lsearch -nocase [split $hint ","] "norecurse"] >= 0 } {
                dict set cpy recurse off
            } else {
                dict set cpy recurse auto
            }
        } else {
            set cpy $fspec
        }
        
        # When here cpy is a variable that host a dictionary in the new style
        # specification able to handle more copying options.
        if { [dict exists $cpy source] && [dict get $cpy source] ne "" } {
            set src [AbsolutePath $vm [dict get $cpy source]]
            dict unset cpy source;   # Remove source from dict, mandatory for SCopy below
            if { [file exists $src] } {
                if { [dict exists $cpy destination] && [dict get $cpy destination] ne "" } {
                    set dst [dict get $cpy destination]
                    dict unset cpy destination;  # Same as above for source!
                } else {
                    log DEBUG "Using source $src as the destination for copy"
                    set dst $src
                }
                
                # Once here we src and dst hold the source and destination paths
                # and cpy is a dictionary full of options ready to further
                # specify the copy operation. We have taken care of removing the
                # keys named source and destination from the dictionary in the
                # analysis process above. We pass all this to SCopy which will
                # perform the real job.
                SCopy $vm $src $dst {*}$cpy
            } else {
                log WARN "Source path $src does not exist!"
            }
        } else {
            log WARN "You need at least to specify a non-empty source!"
        }
    }
}


proc ::cluster::prelude { vm { execs {} }} {
    # Get scripts/programs to execute from parameters of from VM object
    if { [string length $execs] == 0 } {
        if { ![dict exists $vm -prelude] } {
            return {}
        }
        set execs [dict get $vm -prelude]
    }
    
    # Pass the environment variables in case they were needed
    environment set $vm
    
    set nm [dict get $vm -name]
    foreach exe $execs {
        Exec $vm {*}$exe
    }
}


proc ::cluster::addendum { vm { execs {} } } {
    # Get scripts/programs to execute from parameters of from VM object
    if { [string length $execs] == 0 } {
        if { ![dict exists $vm -addendum] } {
            return {}
        }
        set execs [dict get $vm -addendum]
    }
    
    # Pass the environment variables in case they were needed
    environment set $vm
    
    set nm [dict get $vm -name]
    foreach exe $execs {
        Exec $vm {*}$exe
    }
}


# ::cluster::tag -- Tag a machine
#
#       This procedure will ensure that the tags passed as arguments
#       are set for the virtual machine.  These tags should be formed
#       as an even long list of keys followed by their values.  The
#       implementation ensures that the tags are given to the docker
#       daemon running as part of the machine, assuming that it runs
#       boot2docker.
#
# Arguments:
#        vm     Virtual machine description dictionary
#        lbls   Even long list of keys and values: the labels to set.
#               Empty list means taking the labels from the VM description.
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::tag { vm { lbls {}}} {
    # Get labels, either from parameters (overriding the VM object) or
    # from vm object.
    if { [string length $lbls] == 0 } {
        if { ![dict exists $vm -labels] } {
            return $vm
        }
        set lbls [dict get $vm -labels]
    }
    
    # Some nic'ish ouput of the tags and what we do.
    set nm [dict get $vm -name]
    foreach {k v} $lbls {
        append tags "${k}=${v} "
    }
    log NOTICE "Tagging $nm with [string trim $tags]"
    
    # Get current set of arguments, this assumes a boot2docker image!
    # We do some quick and dirty parsing of this UNIX defaults file,
    # trimming away leading and ending quotes, skipping comments and
    # empty lines.  The algorithm is able to handle quoted strings
    # that span several lines, but not the subtilities of bash
    # quoting.
    log DEBUG "Getting current boot2docker profile"
    set k ""
    foreach l [tooling machine -return -- -s [storage $vm] ssh $nm cat ${vars::-profile}] {
        if { $k eq "" } {
            set l [string trim $l]
            if { $l ne "" && [string index $l 0] ne "\#" } {
                set equal [string first "=" $l]
                set k [string trim [string range $l 0 [expr {$equal-1}]]]
                set v [string trimleft [string range $l [expr {$equal+1}] end]]
                set unquoted [string map {"\"" "" "'" ""} $v]
                set nq [expr {[string length $v]-[string length $unquoted]}]
                if { $nq%2==0 } {
                    set DARGS($k) \
                            [string trim [string trim [string trim $v] "\"'"]]
                    set k ""
                }
            }
        } else {
            append v \n
            append v $l
            set unquoted [string map {"\"" "" "'" ""} $v]
            set nq [expr {[string length $v]-[string length $unquoted]}]
            if { $nq%2==0 } {
                set DARGS($k) [string trim [string trim [string trim $v] "\"'"]]
                set k ""
            }
        }
    }
    
    # Append labels to EXTRA_ARGS index in the array.  Maybe should we
    # parse for their existence before?
    foreach {k v} $lbls {
        append DARGS(EXTRA_ARGS) " --label ${k}=${v}"
    }
    
    # Create a local temporary file with the new content.  This is far
    # from perfect, but should do as we are only creating one file and
    # will be removing it soon.
    set fname [Temporary [file join [TempDir] profile]]
    environment write $fname [array get DARGS] "'"
    
    # Copy new file to same place (assuming /tmp is a good place!) and
    # install it for reboot.
    SCopy $vm $fname ""
    tooling machine -- -s [storage $vm] ssh $nm sudo mv $fname ${vars::-profile}
    
    # Cleanup and restart machine to make sure the labels get live.
    file delete -force -- $fname;        # Remove local file, not needed anymore
    tooling machine -- -s [storage $vm] restart $nm;# Restart machine to activate tags
    
    return [Running $vm]
}


# ::cluster::ports -- Port forwarding
#
#       This procedure will arrange for port forwarding to be
#       established so specific port on the host will be forwarded to
#       ports within the virtual machines.  This is only implemented
#       on top of the virtualbox driver at present.
#
#       The format of the list of ports forwarding is understood as
#       follows.  Single ports (an integer) will be forwarded onto the
#       same guest port and forwarding will be for tcp.  A forwarding
#       specification can also be a triplet (i.e. a list itself!)
#       composed of a host port, a guest port and a default protocol.
#       The default protocol is tcp, and the only recognised protocols
#       are tcp and udp.  Finally, a forwarding specification can also
#       have the form host:guest/proto where host and guest should be
#       two integer ports and the protocol (and the slash) are
#       optional and default to tcp.
#
# Arguments:
#        vm        Virtual machine description dictionary
#        ports     List of port forwardings, empty to use the list from the
#                  VM description
#
# Results:
#       None.
#
# Side Effects:
#       Will use the Virtual box commands to request for port
#       forwarding.
proc ::cluster::ports { vm { ports {}} } {
    # Get ports, either from parameters (overriding the VM object) or
    # from vm object.
    if { [string length $ports] == 0 } {
        if { ![dict exists $vm -ports] } {
            return
        }
        set ports [dict get $vm -ports]
    }
    
    # Convert xx:yy/proto constructs to pairs of ports, convert single
    # ports to two ports (the same, on tcp) and append all these pairs
    # to the list called opening.  Arrange for the list to only
    # contain integers.
    set opening {}
    foreach pspec $ports {
        set pspec [Ports $pspec];   # Extraction and syntax check
        if { [llength $pspec] > 0 } {
            foreach {host mchn proto} $pspec break
            lappend opening $host $mchn $proto
        }
    }
    
    # Some nic'ish ouput of the ports and what we do.
    set nm [dict get $vm -name]
    log NOTICE "Forwarding [expr {[llength $opening]/3}] port(s) for $nm..."
    
    switch [dict get $vm -driver] {
        "virtualbox" {
            eval [linsert $opening 0 virtualbox::forward $nm]
        }
        default {
            log WARN "Cannot port forward with driver [dict get $vm -driver]"
        }
    }
}


# ::cluster::shares -- Shares mounting
#
#       This procedure will arrange for shares to be mounted or
#       prepared for synchronisation between the host machine and the
#       guest machine.  On top of the virtualbox driver, and when the
#       shares are marked with the type vboxsf, this will implement a
#       proper (and persistent) mount.  On top of all other drivers,
#       and/or when the type is rsync, the content of the directory on
#       the host machine will be copied to the guest VM at
#       initialisation time using rsync.  Synchronising the other way
#       around during the life of the VM can be achieved using the
#       procedure called sync.
#
#       The format of the list of shares is understood as follows.  A
#       single path will be shared at the same location than the host
#       within the guest.  A share specification can also be a list of
#       two or more items composed of a host path and a guest path and
#       possibly a type.  When the type is missing, it will default to
#       a good default depending on the driver.  Finally, a share
#       specification can also have the form host:guest:type where
#       host and guest should the path on the local host and where to
#       mount it on the guest.  In that case, the type is optional and
#       will properly default as explained above.  If the guest
#       directory is empty, it is understood as the same as the host
#       directory.
#
# Arguments:
#        vm        Virtual machine description dictionary
#        shares    List of share mounts, empty to use the list from the
#                  VM description
#
# Results:
#       The list of directories that were successfully mounted.
#
# Side Effects:
#       Plenty as it performs mounts and/or rsync synchronisation
proc ::cluster::shares { vm { shares {}} } {
    set mounted {}
    set opening [Mounting $vm $shares]
    
    # Some nic'ish ouput of the shares and what we do.
    set nm [dict get $vm -name]
    log NOTICE "Sharing [expr {[llength $opening]/3}] volume(s) for $nm..."
    
    # Add shares as necessary.  This might halt the virtual machine if
    # they do not exist yet, so we collect their names together with
    # host and guest path information in a new list called sharing.
    # This allows us to halt the machine as little as possible.
    array set SHARINFO {}
    foreach {host mchn type} $opening {
        switch -glob -- $type {
            "v*box*" {
                if { [dict get $vm -driver] ne "virtualbox" } {
                    log WARN "Cannot use $type sharing on other drivers than\
                            virtualbox!"
                } else {
                    set share [virtualbox::addshare $nm $host]
                    if { $share ne "" } {
                        lappend SHARINFO(vboxsf) $host $mchn $share
                    }
                }
            }
            "rsync" {
                lappend SHARINFO(rsync) $host $mchn
            }
        }
    }
    
    # Now start virtual machine as we will be manipulating the runtime
    # state of the machine.  This should only starts the machines if
    # it is not running already.
    if { [llength [array names SHARINFO]] > 0 } {
        if { ![start $vm 0] } {
            log WARN "Could not start machine to perform mounts!"
            return $mounted
        }
    }
    
    # If we have some rsync-based shares, then we need to make sure
    # we'll have rsync on the machine!  The following code only works
    # on the Tinycore linux-based boot2docker.
    if { [info exists SHARINFO(rsync)] } {
        InstallRSync $vm
    }
    
    # Find out id of main user on virtual machine to be able to mount
    # shares and/or create directories under that UID.
    set idinfo [unix id $vm id]
    if { [dict exists $idinfo uid] } {
        set uid [dict get $idinfo uid]
        log DEBUG "User identifier in machine $nm is $uid"
    } else {
        set uid ""
    }
    
    foreach type [array names SHARINFO] {
        switch $type {
            "vboxsf" {
                # And arrange for the destination directories to exist
                # within the guest and perform the mount.
                foreach {host mchn share} $SHARINFO(vboxsf) {
                    if { [unix mount $vm $share $mchn $uid] } {
                        lappend mounted $mchn
                    }
                }
                
                # Finally arrange for the mounts to persist over time.
                # This is overly complex, but the code below is both able
                # to create the file and/or to amend it with our mounting
                # information.  We also add machine-parseable comments so
                # recreation of data would be possible.
                set b2d_dir [file dirname ${vars::-bootlocal}]
                set bootlocal {}
                foreach f [tooling machine -return -- \
                        -s [storage $vm] ssh $nm "ls -1 $b2d_dir"] {
                    if { $f eq [file tail ${vars::-bootlocal}] } {
                        set bootlocal [tooling machine -return -- \
                                -s [storage $vm] \
                                ssh $nm "cat ${vars::bootlocal}"]
                    }
                }
                
                # Generate a new section, i.e. a series of bash commands
                # that will (re)creates the mounts.  Make sure each series
                # of commands is led by a machine parseable comment.
                set section {}
                foreach {host mchn share} $SHARINFO(vboxsf) {
                    lappend section "## $share : \"$mchn\" : $uid"
                    foreach cmd [unix mnt.sh $share $mchn $uid] {
                        lappend section "sudo $cmd"
                    }
                }
                
                # We had no content for bootlocal at all, make sure we
                # have a shebang for a shell...
                if { [llength $bootlocal] == 0 } {
                    lappend bootlocal "#!/bin/sh"
                    lappend bootlocal ""
                }
                
                # Look for section start and end markers and either add at
                # end of file or replace the section.
                set start [lsearch $bootlocal ${vars::-marker}]
                if { $start >= 0 } {
                    incr start
                    set end [lsearch $bootlocal ${vars::-marker} $start]
                    incr end -1
                    log DEBUG "Replacing existing persistent mounting section"
                    set bootlocal [lreplace $bootlocal $start $end {*}$section]
                } else {
                    log DEBUG "Adding new persistent mounting section"
                    lappend bootlocal ${vars::-marker}
                    foreach l $section {
                        lappend bootlocal $l
                    }
                    lappend bootlocal ${vars::-marker}
                }
                
                # Now create a temporary file with the new content
                set fname [Temporary [file join [TempDir] bootlocal]]
                set fd [open $fname w]
                foreach l $bootlocal {
                    puts $fd $l
                }
                close $fd
                log DEBUG "Created temporary file with new bootlocal content at\
                        $fname"
                
                # Copy new file to same temp location, make sure it is
                # executable and install it.
                log INFO "Persisting shares at reboot through\
                        ${vars::-bootlocal}"
                SCopy $vm $fname ""
                tooling machine -- -s [storage $vm] ssh $nm "chmod a+x $fname"
                tooling machine -- -s [storage $vm] ssh $nm "sudo mv $fname ${vars::-bootlocal}"
            }
            "rsync" {
                # Detect SSH command
                set ssh [SCommand $vm]
                set hname [lindex $ssh end]
                set ssh [lrange $ssh 0 end-1]
                
                # rsync for each
                foreach {host mchn} $SHARINFO(rsync) {
                    # Create directory on remote VM and arrange for
                    # the UID to match (should we?)
                    tooling machine -- -s [storage $vm] ssh $nm "sudo mkdir -p $mchn"
                    if { $uid ne "" } {
                        tooling machine -- -s [storage $vm] ssh $nm "sudo chown $uid $mchn"
                    }
                    # Synchronise the content of the local host
                    # directory onto the remote VM directory.  Arrange
                    # for rsync to understand those properly as
                    # directories and not only files.
                    tooling run -- [auto_execok ${vars::-rsync}] -az -e $ssh \
                            [string trimright $host "/"]/ \
                            $hname:[string trimright $mchn "/"]/
                    lappend mounted $mchn
                }
            }
        }
    }
    
    if { [info exists SHARINFO(rsync)] } {
        log INFO "Consider running a cron job to synchronise back changes\
                that would occur in $nm onto the host!"
    }
    
    return $mounted
}


# ::cluster::sync -- Shares synchronisation
#
#       This procedure will arrange for rsync shares to be
#       synchronised from the guest VM back to the host machine (get
#       operation) or the other way around (put operation).
#
#       The format of the list of shares is understood as follows.  A
#       single path will be shared at the same location than the host
#       within the guest.  A share specification can also be a list of
#       two or more items composed of a host path and a guest path and
#       possibly a type.  When the type is missing, it will default to
#       a good default depending on the driver.  Finally, a share
#       specification can also have the form host:guest:type where
#       host and guest should the path on the local host and where to
#       mount it on the guest.  In that case, the type is optional and
#       will properly default as explained above.  If the guest
#       directory is empty, it is understood as the same as the host
#       directory.
#
# Arguments:
#        vm        Virtual machine description dictionary
#        op        Operation to execute (get or put)
#        shares    List of share mounts, empty to use the list from the
#                  VM description
#
# Results:
#       The list of directories that were successfully synchronised
#
# Side Effects:
#       Uses rsync on remote and locally to synchronise
proc ::cluster::sync { vm {op get} {shares {}} } {
    set synchronised {}
    set nm [dict get $vm -name]
    if { ! [IsRunning $vm] } {
        log WARN "Machine $nm not running, cannot sync"
        return $synchronised
    }
    
    # Consider rsync shares and forget about all the other ones...
    set sharing [Mounting $vm $shares rsync]
    log NOTICE "Synchronising [expr {[llength $sharing]/3}] share(s) for $nm..."
    
    # Detect SSH command
    set ssh [SCommand $vm]
    set hname [lindex $ssh end]
    set ssh [lrange $ssh 0 end-1]
    
    # rsync back from the guest machine onto the host machine.  This
    # forces rsync to properly understand those locations as
    # directories.
    switch -nocase -glob -- $op {
        "g*" {
            foreach {host mchn type} $sharing {
                tooling run -- [auto_execok ${vars::-rsync}] -auz --delete -e $ssh \
                        $hname:[string trimright $mchn "/"]/ \
                        [string trimright $host "/"]/
                lappend synchronised $mchn
            }
        }
        "p*" {
            foreach {host mchn type} $sharing {
                tooling run -- [auto_execok ${vars::-rsync}] -auz --delete -e $ssh \
                        [string trimright $host "/"]/ \
                        $hname:[string trimright $mchn "/"]/
                lappend synchronised $mchn
            }
        }
    }
    
    return $synchronised
}


# ::cluster::halt -- Halt a virtual machine
#
#       Halt a virtual machine by first trying to stop it gently, and
#       then killing it entirely if the shutdown operation had not
#       worked properly.
#
# Arguments:
#        vm        Virtual machine description
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::halt { vm {masters {}} } {
    # Gracefully leave cluster
    if { [swarmmode mode $vm] ne "" } {
        swarmmode leave $vm $masters
    }
    
    # Start by getting back all changes that might have occured on the
    # the VM, if relevant...
    sync $vm get
    
    set nm [dict get $vm -name]
    log NOTICE "Bringing down machine $nm..."
    # First attempt to be gentle against the machine, i.e. using the
    # stop command of docker-machine.
    if { [IsRunning $vm] } {
        log INFO "Attempting graceful shutdown of $nm"
        tooling machine -- -s [storage $vm] stop $nm
    }
    # Ask state of cluster again and if the machine still isn't
    # stopped, force a kill.
    set state [ls [storage $vm] $nm]
    if { [dict exists $state state] \
                && ![string equal -nocase [dict get $vm state] "stopped"] } {
        log NOTICE "Forcing stop of $nm"
        tooling machine -- -s [storage $vm] kill $nm
    }
    
    Discovery [bind $vm]
}


# ::cluster::ssh -- Execute command in machine
#
#       This procedure will print out the result of a command executed
#       in the VM on the standard output or provide an interactive
#       prompt to the machine.
#
# Arguments:
#        vm        Virtual machine description
#        args      Command to execute, empty for interactive prompt
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::ssh { vm args } {
    set nm [dict get $vm -name]
    log NOTICE "Entering machine $nm..."
    if { [llength $args] > 0 } {
        set res [eval [linsert $args 0 tooling machine -raw -stderr -- -s [storage $vm] ssh $nm]]
    } else {
        foreach fd {stdout stderr stdin} {
            fconfigure $fd -buffering none -translation binary
        }
        set mchn [auto_execok ${vars::-machine}]
        if { ![file exists $mchn] } {
            set mchn ${vars::-machine}
        }
        if { $mchn eq "" } {
            log ERROR "Cannot find machine at ${vars::-machine}!"
            return
        }
        
        set cmd [list $mchn -s [storage $vm]]
        if { [lsearch [split [::platform::generic] -] "win32"] >= 0 } {
            lappend cmd --native-ssh
        }
        lappend cmd ssh $nm
        
        if { [catch {exec {*}$cmd >@ stdout 2>@ stderr <@ stdin} err] } {
            log WARN "Child returned: $err"
        }
    }
}

proc ::cluster::login { vm {regs {}} } {
    # Get login information, either from parameters (overriding the VM
    # object) or from the VM object.
    if { [string length $regs] == 0 } {
        if { ![dict exists $vm -registries] } {
            return
        }
        set regs [dict get $vm -registries]
    }
    
    set nm [dict get $vm -name]
    log NOTICE "Logging in within $nm"
    foreach reg $regs {
        if { [dict exists $reg server] && [dict exists $reg username] } {
            log INFO "Logging in as [dict get $reg username]\
                    at [dict get $reg server]"
            set cmd "docker login "
            foreach {o k} [list -u username -p password -e email] {
                if { [dict exists $reg $k] } {
                    append cmd "$o '[dict get $reg $k]' "
                } else {
                    append cmd "$o '' "
                }
            }
            append cmd [dict get $reg server]
            tooling machine -- -s [storage $vm] ssh $nm $cmd
        }
    }
}


# ::cluster::pull -- Pull one or several images
#
#       Attach to the virtual machine given as a parameter and pull
#       one or several images.  This respect the global -cache option.
#       When caching is on, the images are downloaded to the local
#       host before being snapshotted and transmitted to the virtual
#       machine for loading.  This has two advantages: 1. it minimises
#       download times and thus quickens machine initialisation; 2. It
#       is a security measure as it allows to download from private
#       repositories and use these images in the virtual machine
#       without keeping the credentials in the virtual machine.
#
# Arguments:
#        vm        Virtual machine description
#        images    List of images to pull, empty (default) for the ones from vm
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::pull { vm {images {}} } {
    # Get images, either from parameters (overriding the VM object) or
    # from vm object.
    if { [string length $images] == 0 } {
        if { ![dict exists $vm -images] } {
            return
        }
        set images [dict get $vm -images]
    }
    
    set nm [dict get $vm -name]
    log NOTICE "Pulling images for $nm: $images..."
    foreach img $images {
        # Start by computing caching hint.
        set caching on
        foreach {ptn hint} ${vars::-caching} {
            if { [string match $ptn $img] } {
                set caching $hint
                break
            }
        }
        
        # Check if we have explicitely turned off all caching
        if { ${vars::-cache} eq "-" } {
            set caching off
        }
        
        if { $caching } {
            # When using the cache, we download the image on the
            # localhost (meaning that we should be able to login to
            # remote repositories outside of machinery and use this
            # credentials here!), create a snapshot of the image using
            # docker save, transfer it to the virtual machine with scp
            # and then load it there.
            
            # Decide where to cache (this is for being able to support
            # virtualbox settings)
            if { ${vars::-cache} eq "" } {
                set cache $vars::defaultMachine
            } else {
                set cache ${vars::-cache}
            }
            set origin [expr {$cache eq "" ? "locally" : "via $cache"}]
            log INFO "Pulling $img $origin and transfering to $nm"
            
            # Detach so we can pull locally!
            if { $cache eq "" } {
                Detach
            } else {
                Attach $cache -external
            }
            # Pull image locally
            tooling docker -stderr -- pull $img
            # Get unique identifier for image locally and remotely
            set local_id [tooling docker -return -- images -q --no-trunc $img]
            log TRACE "Identifier for local image is $local_id"
            Attach $vm
            set remote_id [tooling docker -return -- images -q --no-trunc $img]
            log TRACE "Identifier for remote image is $remote_id"
            if { $local_id eq $remote_id } {
                log INFO "Image $img already present on $nm at version $local_id"
            } else {
                # Detach again, we are going to get it locally first!
                if { $cache eq "" } {
                    Detach
                } else {
                    Attach $cache -external
                }
                
                # Save it to the local disk
                set rootname [file rootname [file tail $img]]; # Cheat!...
                set tmp_fpath [Temporary \
                        [file join [TempDir] $rootname]].tar
                log INFO "Using a local snapshot at $tmp_fpath to copy $img\
                        to $nm..."
                tooling docker -stderr -- save -o $tmp_fpath $img
                log DEBUG "Created local snapshot of $img at $tmp_fpath"
                
                # Give the tar to docker on the remote machine
                log DEBUG "Loading $tmp_fpath into $img at $nm..."
                Attach $vm
                tooling docker load -i $tmp_fpath
                
                # Cleanup
                log DEBUG "Cleaning up $tmp_fpath"
                file delete -force -- $tmp_fpath
            }
        } else {
            log INFO "Pulling $img directly in $nm"
            tooling machine -- -s [storage $vm] ssh $nm "docker pull $img"
            # Should we Attach - tooling docker pull $img - Detach instead?
        }
    }
}


# ::cluster::destroy -- Destroy a machine
#
#       This procedure will irrevocably destroy a virtual machine from
#       the cluster.  This will halt the machine before destroying it.
#
# Arguments:
#        vm        Virtual machine description
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::destroy { vm {masters {}}} {
    halt $vm $masters
    set nm [dict get $vm -name]
    if { [dict exists $vm state] } {
        log NOTICE "Removing machine $nm..."
        tooling machine -- -s [storage $vm] rm -y $nm
    } else {
        log INFO "Machine $nm does not exist, nothing to do"
    }
    Discovery [bind $vm]
}


# ::cluster::inspect -- Inspect a machine
#
#       Inspect the low-level details for a virtual machine and return
#       a dictionary containing that description.  This is basically a
#       direct interface to the inspect command of docker-machine,
#       except that the result is easily digested by Tcl commands.
#
# Arguments:
#	vm	Virtuam machine description
#
# Results:
#       Dictionary with low-level details over the machine, see
#       docker-machine documentation for details.
#
# Side Effects:
#       None.
proc ::cluster::inspect { vm } {
    set nm [dict get $vm -name]
    set json ""
    foreach l [tooling machine -return -- -s [storage $vm] inspect $nm] {
        append json $l
        append json " "
    }
    return [::json::parse [string trim $json]]
}


# ::cluster::start -- Bring up a machine
#
#       This procedure will start a virtual machine from the cluster.
#
# Arguments:
#        vm        Virtual machine description
#
# Results:
#       1 on start success, 0 otherwise.
#
# Side Effects:
#       None.
proc ::cluster::start { vm { sync 1 } { sleep 1 } { retries 3 } } {
    set nm [dict get $vm -name]
    if { $retries < 0 } {
        set retries ${vars::-retries}
    }
    while { $retries > 0 } {
        # Check if the machine is already running at once, to avoid
        # unecessary attempts to (re)start.
        set state [Wait $vm [list "running" "timeout" "stopped" "error"]]
        if { $state eq "running" } {
            # Start by putting back all changes that might have
            # occured onto the the VM, if relevant...
            set vm [bind $vm]
            if { [string is true $sync] } {
                sync $vm put
            }
            
            Discovery $vm
            return 1
        }
        log NOTICE "Bringing up machine $nm..."
        tooling machine -- -s [storage $vm] start $nm
        incr retries -1
        if { $retries > 0 } {
            log INFO "Machine $nm could not start, trying again..."
            after [expr {int($sleep*1000)}]
        }
    }
    log WARN "Could never start $nm!"
    return 0
}


# ::cluster::parse -- Parse YAML description
#
#       This procedure will parse a cluster YAML description and
#       return it.  It takes a number of optional dash led arguments
#       followed by their values that can tweak its behaviour these are:
#       -prefix to specify cluster prefix for names (defaults to rootname)
#       -driver to specify default driver to use when not specified.
#
#       Parsing does a number of sanity checks: only one swarm master
#       can be specified, only relevant keys are accepted, etc.  Keys
#       will appear as dash-led in the dictionary representation to
#       mark them as "options".  Parsing does not provide defaults for
#       keys because we want to rely on the defaults that are set in
#       docker-machine for maximum compatibility.
#
# Arguments:
#        fname       Path to YAML description
#        args        List of dash-led options and arguments, see above.
#
# Results:
#       Cluster description, i.e. a list of virtual machine
#       description dictionaries.
#
# Side Effects:
#       None.
proc ::cluster::parse { fname args } {
    getopt args -prefix pfx [file rootname [file tail $fname]]
    getopt args -driver drv "none"
    
    set d [::yaml::yaml2dict -file $fname]
    
    # Get version, default to 1
    set version 1
    if { [dict exists $d version] } {
        set version [vcompare extract [dict get $d version]]
        if { $version eq "" } {
            log ERROR "Version [dict get $d version] does not contain a proper version number!"
            return {}
        }
    }
    
    # Arrange to access to the list of machines, directly under the top of the
    # YAML root in the old version 1.0 format (the default) or under the key
    # called machines in the newer format
    set machines [list]; set networks [list]
    if { [vcompare ge $version 1.0] && [vcompare lt $version 2.0] } {
        # Isolate machines that are not named "version", this introduces a
        # backward compatibility!
        set options {
            -clustering "docker swarm"
        }
        set machines [dict filter $d script {k v} \
                        { expr {![string equal $k "version"]}}]
    } elseif { [vcompare ge $version 2.0] } {
        # Default to new swarm mode with the new version file format!
        set options {
            -clustering "swarm mode"
        }
        # Get list of external networks to create
        if { [dict exists $d networks] } {
            set opts [tooling options [tooling docker -return -- network create --help]]
            dict for {n keys} [dict get $d networks] {
                # Create net "object" with proper name, i.e. using the prefix.
                # We also make sure that we keep a reference to the name of
                # the file that the machine was originally read from.
                if { $pfx eq "" } {
                    set net [dict create -name $n origin $fname]
                } else {
                    set net [dict create -name ${pfx}${vars::-separator}$n origin $fname]
                }
                
                # Set defaults for all networks
                dict for {k v} ${vars::-networks} {
                    dict set net -[string trimleft $k -] $v
                }
                
                # Bring in options from network, as long as they are known
                # options to create
                dict for {k v} $keys {
                    if { [lsearch [dict keys $opts] $k] < 0 } {
                        log WARN "In $n, key $k is not recognised!"
                    } else {
                        dict set net -[string trimleft $k -] $v
                    }
                }
                lappend networks $net
            }
        }

        if { [dict exists $d machines] } {
            set machines [dict get $d machines]
        } else {
            log WARN "No key machines found in YAML description!"
        }
        
        # Get options and initialise to good defaults
        if { [dict exists $d options] } {
            # Initialise options with good defaults
            set opts [dict get $d options]
            foreach {o d} {clustering "swarm mode"} {
                if { [dict exists $opts [string trimleft $o -]] } {
                    dict set options -[string trimleft $o -] \
                        [dict get $opts [string trimleft $o -]]
                } else {
                    dict set options -[string trimleft $o -] $d
                }
            }
        }        
    }

    set vms {}
    set masters [list]
    set clustering [dict get $options -clustering]
    dict for {m keys} $machines {
        # Create vm "object" with proper name, i.e. using the prefix.
        # We also make sure that we keep a reference to the name of
        # the file that the machine was originally read from.
        if { $pfx eq "" } {
            set vm [dict create -name $m origin $fname]
        } else {
            set vm [dict create -name ${pfx}${vars::-separator}$m origin $fname]
        }
        
        # Check validity of keys and insert them as dash-led.  Arrange
        # for one master only in old docker swarm mode and store fully-qualified
        # aliases for the machine.
        dict for {k v} $keys {
            if { [lsearch ${vars::-keys} $k] < 0 } {
                log WARN "In $m, key $k is not recognised!"
            } else {
                dict set vm -[string trimleft $k -] $v
                if { [string trimleft $k -] eq "master" } {
                    if { [dict get $vm -master] } {
                        lappend masters [dict get $vm -name]
                        # Prevent several masters when using old "Docker Swarm",
                        # in swarm mode there might be several master
                        # (managers).
                        if { [string match -nocase "docker*swarm" $clustering] \
                                && [llength $masters] > 0 } {
                            log WARN "There can only be one master,\
                                      keeping [lindex $masters 0] as the master"
                            dict set vm -master 0
                            set masters [lrange $masters 0 0]
                        }
                    }
                }
                
                # Automatically prefix the aliases, maybe should we
                # save the prefix in each VM instead?
                if { $k eq "aliases" && $pfx ne "" } {
                    set aliases {}
                    foreach a [dict get $d $m $k] {
                        lappend aliases ${pfx}${vars::-separator}$a
                    }
                    dict set vm -$k $aliases
                }
            }
        }
        
        # Automatically give a driver to the VM if possible and
        # necessary.
        if { ![dict exists $vm -driver] } {
            log NOTICE "Adding default driver '$drv' to [dict get $vm -name]"
            dict set vm -driver $drv
        }
        
        lappend vms $vm
    }
    
    # Check that there is at least one master in the file that we have
    # parsed.
    if { [llength $masters] == 0 } {
        log WARN "Cluster file at $fname has no master!"
    } else {
        log DEBUG "Masters are: [join $masters ,\ ]"
    }
    
    return [dict create -machines $vms -options $options -networks $networks]
}


# ::cluster::env -- Output cluster environment
#
#       This procedure returns a description of the whole cluster
#       suitable for discovery.  The description will contain
#       environment variables which names start with MACHINERY_ and
#       provide information on the various IP addresses allocated to
#       the machines.
#
# Arguments:
#	cluster	List of cluster VM descriptions
#	force	Force inspection of all VMs (otherwise cache is returned).
#	fd	File descriptor to print out in format suitable for bash
#
# Results:
#       When the file descriptor is empty, this will return a
#       dictionary containing the discovery status.  Otherwise, the
#       result is undefined.
#
# Side Effects:
#       Query all VMs or read from cache on disk.
proc ::cluster::env { cluster {force 0} {fd ""} } {
    set cluster [Machines $cluster]
    # Nothing to do on an empty cluster...
    if { [llength $cluster] == 0 } {
        return
    }
    
    set vm [lindex $cluster 0]
    if { [dict exists $vm origin] } {
        set env_path [environment cache $vm]
    } else {
        # Should not happen
        log WARN "Cannot discover where cluster originates from!"
        return
    }
    
    # Remove the cache file and recreate
    if { [string is true $force] } {
        file delete -force -- $env_path
        foreach vm $cluster {
            Discovery $vm
        }
    }
    
    # Either return content of environment file as a dictionary, or
    # return so it contains exporting variables commands.
    set e [environment read $env_path]
    if { $fd ne "" } {
        environment write $fd $e "export "
    } else {
        return [environment read $env_path]
    }
}


proc ::cluster::candidates { {dir .} } {
    set candidates {}
    foreach fpath [glob -nocomplain -directory $dir -- $vars::lookup] {
        if { [catch {open $fpath} fd] == 0 } {
            log DEBUG "Polling $fpath for leading YAML marker"
            while { ![eof $fd] } {
                set line [string trim [gets $fd]]
                if { $line ne "" } {
                    if { [regexp $vars::marker $line] } {
                        lappend candidates $fpath
                    }
                    break;   # Jump out on first non empty line
                }
            }
            close $fd
        } else {
            log WARN "Cannot consider $fpath as a cluster description file: $fd"
        }
    }
    
    return $candidates
}




####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################

# ::cluster::LogLevel -- Convert log levels
#
#       For convenience, log levels can also be expressed using
#       human-readable strings.  This procedure will convert from this
#       format to the internal integer format.
#
# Arguments:
#        lvl        Log level (integer or string).
#
# Results:
#       Log level in integer format, -1 if it could not be converted.
#
# Side Effects:
#       None.
proc ::cluster::LogLevel { lvl } {
    if { ![string is integer $lvl] } {
        foreach {l str} $vars::verboseTags {
            if { [string match -nocase $str $lvl] } {
                return $l
            }
        }
        return -1
    }
    return $lvl
}


proc ::cluster::Log? { { lvl "" } { intlvl_ ""} } {
    # Convert current module level from string to integer.
    set current [LogLevel ${vars::-verbose}]
    
    # Either return current log level or if we should log.
    if { $lvl eq "" } {
        return $current
    } else {
        if { $intlvl_ ne "" } {
            upvar $intlvl_ intlvl
        }
        # Convert incoming level from string to integer.
        set intlvl [LogLevel $lvl]
        return [expr {$current >= $intlvl}]
    }
    return -1
}


# ::cluster::StorageDir -- Path to machine storage cache
#
#       Return the path to the machine storage cache directory.
#
# Arguments:
#	yaml	Path to YAML description of cluster
#
# Results:
#       Full path to directory for storage
#
# Side Effects:
#       Create the directory if it did not exist prior to this call.
proc ::cluster::StorageDir { yaml } {
    if { ${vars::-storage} eq "" } {
        set dir [CacheFile $yaml ${vars::-ext}]
    } else {
        set dir ${vars::-storage}
    }
    
    if { ![file isdirectory $dir] } {
        log NOTICE "Creating machine storage directory at $dir"
        file mkdir $dir;   # Let it fail since we can't continue otherwise
    }
    
    return [file normalize $dir]
}


# ::cluster::+ -- Implements ANSI colouring codes.
#
#       Output ANSI colouring codes, inspired by wiki code at
#       http://wiki.tcl.tk/1143.
#
# Arguments:
#        args        List of colouring and effects to apply
#
# Results:
#       Return coding escape.
#
# Side Effects:
#       None.
proc ::cluster::+ { args } {
    set map {
        normal 0 bold 1 light 2 blink 5 invert 7
        black 30 red 31 green 32 yellow 33 blue 34 purple 35 cyan 36 white 37
        Black 40 Red 41 Green 42 Yellow 43 Blue 44 Purple 45 Cyan 46 White 47
    }
    set t 0
    foreach i $args {
        set ix [lsearch -exact $map $i]
        if {$ix>-1} {lappend t [lindex $map [incr ix]]}
    }
    return "\033\[[join $t {;}]m"
}


# ::cluster::Create -- Create a VM
#
#       Create a virtual machine using docker-machine.  This will
#       translate the cpu, memory and size options to the relevant
#       options for the driver to use for machine creation.  It will
#       also append the whole list of blind options, if any specified.
#       Once created, we check that it worked properly by ssh'ing a
#       command into the machine.  This is necessary as docker-machine
#       seems to be needing that extra step before getting the
#       machines to work properly.
#
# Arguments:
#        vm        Virtual machine description
#        token     Swarm token for machine, empty for no swarm in machine.
#        swarmmode Swarm Mode (manager, worker or empty for old swarm).
#
# Results:
#       Return the name of the machine, empty string on errors.
#
# Side Effects:
#       None.
proc ::cluster::Create { vm { token "" } {masters {}} } {
    set nm [dict get $vm -name]
    log NOTICE "Creating machine $nm"
    Detach
    set docker_version [tooling version docker]
    
    # Start creating a command that we will be able to call for
    # machine creation: first insert creation command with proper
    # driver.
    set driver [dict get $vm -driver]
    set cmd [list tooling machine -- -s [storage $vm] create -d $driver]
    
    # Now translate the standard memory (in MB), size (in MB) and cpu
    # (in numbers) options into options that are specific to the
    # drivers.
    
    # For kvm, you need the https://github.com/dhiltgen/docker-machine-kvm
    # plugin to docker-machine.
    
    # Memory size is in MB
    if { [dict exists $vm -memory] } {
        array set MOPT {
            softlayer --softlayer-memory
            hyper-v --hyper-v-memory
            virtualbox --virtualbox-memory
            vmwarefusion --vmwarefusion-memory-size
            vmwarevcloudair --vmwarevcloudair-memory-size
            vmwarevsphere --vmwarevsphere-memory-size
            kvm --kvm-memory
        }
        if { [info exist MOPT($driver)] } {
            lappend cmd $MOPT($driver) [Convert [dict get $vm -memory] MiB MiB]
        } else {
            log WARN "Cannot set memory size for driver $driver!"
        }
    }
    # Number of CPUs.
    if { [dict exists $vm -cpu] } {
        array set COPT {
            softlayer --softlayer-cpu
            vmwarevcloudair --vmwarevcloudair-cpu-count
            vmwarevsphere --vmwarevsphere-cpu-count
            kvm --kvm-cpu-count
        }
        # Setting the number of CPUs works with machine >= 0.2
        if { [vcompare ge [tooling version machine] 0.2] } {
            set COPT(virtualbox) --virtualbox-cpu-count
        }
        if { [info exist COPT($driver)] } {
            lappend cmd $COPT($driver) [dict get $vm -cpu]
        } else {
            log WARN "Cannot set number of CPUs for driver $driver!"
        }
    }
    # We understand disk size in MB, and use multipliers to adapt to
    # each drivers specificities
    if { [dict exists $vm -size] } {
        set SOPT {
            amazonec2 --amazonec2-root-size 0.001
            digitalocean --digitalocean-size 1000
            softlayer --softlayer-disk-size 1
            hyper-v --hyper-v-disk-size 1
            virtualbox --virtualbox-disk-size 1
            vmwarefusion --vmwarefusion-disk-size 1
            vmwarevsphere --vmwarevsphere-disk-size 1
            kvm --kvm-disk-size 1
        }
        set found 0
        foreach { p opt mult } $SOPT {
            if { $driver eq $p } {
                lappend cmd $opt \
                        [expr {[Convert [dict get $vm -size] MB MB]*$mult}]
                set found 1
                break
            }
        }
        if {! $found} {
            log WARN "Cannot set disk size for driver $driver!"
        }
    }
    
    # Blindly append driver specific options, if any.  Make sure these
    # are available options, at least!  Also convert these to absolute
    # files so locally stored cached arguments will keep working.
    if { [dict exists $vm -options] } {
        if { [llength $vars::machopts] <= 0 } {
            set vars::machopts [tooling machineOptions $driver]
        }
        dict for {k v} [dict get $vm -options] {
            set k [string trimleft $k "-"]
            if { [dict exists $vars::machopts $k] } {
                if { [lsearch $vars::absPaths $k] >= 0 } {
                    lappend cmd --$k [AbsolutePath $vm $v on]
                } else {
                    lappend cmd --$k $v
                }
            } else {
                log WARN "--$k is not an option supported by 'create'"
            }
        }
    }
    
    # Take care of old Docker Swarm. Turn it on in the first place, and
    # recognise the key master (and request for a swarm master when it is on).
    if { [llength $masters] == 0 } {
        if { $token ne "" } {
            if { ([dict exists $vm -swarm] \
                        && (([string is boolean -strict [dict get $vm -swarm]] \
                                && ![string is false [dict get $vm -swarm]])
                            || ![string is boolean -strict [dict get $vm -swarm]])) \
                    || ![dict exists $vm -swarm] } {
                lappend cmd --swarm --swarm-discovery token://$token
                if { [dict exists $vm -master] \
                            && [string is true [dict get $vm -master]] } {
                    lappend cmd --swarm-master
                }
            } else {
                log NOTICE "Swarm is turned off for this machine"
            }
        } else {
            log NOTICE "Swarm is turned off for this machine"
        }
    }
    
    # Add the tags, if version permits.
    if { [vcompare ge [tooling version machine] 0.4] } {
        if { [dict exists $vm -labels] } {
            foreach {k v} [dict get $vm -labels] {
                lappend cmd --engine-label ${k}=${v};   # Should we quote?
            }
        }
    }
    
    # Finalise command by adding to it the name of the machine that we
    # want to create and run it.
    lappend cmd $nm
    eval $cmd
    
    # Test SSH connection by getting the version of docker using ssh.
    # This seems to be necessary to make docker-machine happy and
    # we'll compare to our local version below for upgrades.
    log DEBUG "Testing SSH connection to $nm"
    WaitSSH $vm
    set rv_line [lindex [tooling machine -return -- -s [storage $vm] ssh $nm "docker --version"] 0]
    set remote_version [vcompare extract $rv_line]
    if { $remote_version eq "" } {
        log FATAL "Cannot log into $nm!"
        return ""
    } else {
        log INFO "Machine $nm running docker v. $remote_version,\
                  running v. [tooling version docker] locally"
        if { [unix release $vm ID] ne "rancheros" } {
            # RancherOS cannot be upgraded through docker machine
            if { [vcompare gt $docker_version $remote_version] } {
                log NOTICE "Local docker version greater than machine,\
                            trying an upgrade"
                tooling machine -- -s [storage $vm] upgrade $nm
            }
        }
    }
    
    if { [llength $masters] } {
        swarmmode join $vm $masters
    }
            
    return [dict get $vm -name]
}


# ::cluster::Attach -- Attach to vm
#
#       Attach to a (running) virtual machine.  This will set the
#       necessary environment variables so that the next call to
#       "docker" will connect to the proper machine.  We perform a
#       simplistic parsing of the output of "docker-machine env" for
#       this purpose. The procedure takes a number of dash-led flags to modify
#       its behaviour, these are:
#       -swarm     Attach to swarm master instead
#       -force     Force attaching even if we were already attached
#       -external  Attach to machine out of cluster under our control
#
# Arguments:
#        vm        Virtual machine description dictionary
#        args      List of dash led flags (see above)
#
# Results:
#       None.
#
# Side Effects:
#       Modify current environment so as to be able to pass it further
#       to docker on next call.
proc ::cluster::Attach { vm args } {
    global env;   # Access program environment.
    
    set swarm [getopt args -swarm]
    set force [getopt args -force]
    set external [getopt args -external]
    
    if { $external } {
        set nm $vm
    } else {
        set nm [dict get $vm -name]
    }
    if { $nm ne [lindex $vars::attached 0] \
                || $swarm != [lindex $vars::attached 1] \
                || $force } {
        log INFO "Attaching to $nm"
        array set DENV {};   # Will hold the set of variables to be set.
        
        set cmd [list tooling machine -return --]
        if { !$external } {
            lappend cmd -s [storage $vm]
        }
        lappend cmd env
        if { $swarm } {
            lappend cmd --swarm
        }
        lappend cmd $nm
        
        set response [eval $cmd]
        if { [llength $response] > 0 } {
            foreach l $response {
                set k [environment line d $l]
                if { $k ne "" } {
                    set DENV($k) [dict get $d $k]
                }
            }
        } else {
            log INFO "Could not request environment through machine, trying a good guess through inspection"
            set cmd [list tooling machine -return --]
            if { !$external } {
                lappend cmd -s [storage $vm]
            }
            lappend cmd inspect $nm
            
            set res [eval $cmd]
            if { $res ne "" } {
                set json [join $res \n]
                set response [::json::parse $json]
                set DENV(DOCKER_TLS_VERIFY) [string is true [dict get $response HostOptions EngineOptions TlsVerify]]
                set DENV(DOCKER_CERT_PATH) [dict get $response HostOptions AuthOptions CertDir]
                set DENV(DOCKER_MACHINE_NAME) [dict get $response Driver MachineName]
                set DENV(DOCKER_HOST) tcp://[dict get $response Driver IPAddress]:2376
            }
        }
        
        if { [llength [array names DENV]] > 0 } {
            array set env [array get DENV]
            set vars::attached [list $nm $swarm]
        } else {
            log ERROR "Could not attach to $nm!"
        }
    }
}


# ::cluster::Detach -- Detach from VM
#
#       Detach from a VM that we might have attached to using the
#       Attach procedure.  This will clear out the set of environment
#       variables that is usually set by docker-machine env.
#
# Arguments:
#       None.
#
# Results:
#       None.
#
# Side Effects:
#       Modify current environment so as to be able to clear out
#       docker context.
proc ::cluster::Detach {} {
    if { [llength $vars::attached] != 0 } {
        log INFO "Detaching from vm..."
        foreach e [list TLS_VERIFY CERT_PATH HOST MACHINE_NAME] {
            if { [info exists ::env(DOCKER_$e)] } {
                unset ::env(DOCKER_$e)
            }
        }
        set vars::attached {}
    }
}


# ::cluster::Ports -- Parse port forwarding specification
#
#       This procedure will parse a port forwarding specification
#       (either integer, list of host guest (and perhaps proto) or
#       host:guest/proto (with optional proto)), verify that the ports
#       are integers and return either an empty list on errors, or a
#       list of exactly three items: the host port, the guest port and
#       the protocol to use for the forwarding.
#
# Arguments:
#        pspec        Port forwarding specification, see above
#
# Results:
#       Return an empty list or the parsed forwarding specification
#
# Side Effects:
#       None.
proc ::cluster::Ports { pspec } {
    # Defaults
    set host -1
    set mchn -1
    set proto tcp
    # Segregate list from string formatting and parse.
    if { [llength $pspec] >= 2 } {
        foreach {host mchn proto} $pspec break
    } else {
        set slash [string first "/" $pspec]
        if { $slash >= 0 } {
            set proto [string range $pspec [expr {$slash+1}] end]
            set pspec [string range $pspec 0 [expr {$slash-1}]]
        }
        set colon [string first ":" $pspec]
        if { $colon >= 0 } {
            foreach {host mchn} [split $pspec ":"] break
        } else {
            set host $pspec
        }
    }
    
    # Arrange for an empty protocol to be tcp
    if { $proto eq "" } {
        set proto "tcp"
    }
    
    # And make sure we only have udp or tcp as a port.
    switch -nocase -- $proto {
        "tcp" {
            set proto "tcp"
        }
        "udp" {
            set proto "udp"
        }
        default {
            log ERROR "Protocol $proto unknown, should be tcp or udp"
            return {}
        }
    }
    
    # Scream whenever ports are not integer and return.
    if { [string is integer -strict $host] \
                && [string is integer -strict $mchn] } {
        if { $mchn < 0 } {
            set mchn $host
        }
        return [list $host $mchn $proto]
    } else {
        log ERROR "One of $host or $mchn ports is not an integer!"
    }
    return {}
}


proc ::cluster::Project { fpath op {substitution 0} {project ""} {options {}}} {
    set composed ""
    
    if { [string toupper $op] ni {START STOP KILL RM UP} } {
        log WARM "Operation should be one of\
                [join {START STOP KILL RM UP} {, }]"
        return $composed
    }
    
    # Change dir to solve relative access to env files.  This is ugly,
    # but there does not seem to be any other solution at this point
    # for compose < 1.2
    if { [vcompare lt [tooling version compose] 1.2] } {
        cd [file dirname $fpath]
    }
    
    # Perform substituion of environment variables if requested from
    # the VM description (and thus the YAML file).
    set temporaries {}
    if { $substitution } {
        # Read content of project file and resolve environment
        # variables to their values in one go.  This supports defaults
        # whenever a variable does not exist,
        # e.g. ${VARNAME:defaultValue}.
        set fd [open $fpath]
        set yaml [environment resolve [read $fd]]
        close $fd
        
        # Parse the YAML project to see if it contains extending
        # services, in which case we need to make sure the extended
        # services are also available to the temporary copy.
        set projects [yaml::yaml2dict -stream $yaml]
        set associated {}
        foreach p $projects {
            if { [dict exists $p extends] && [dict exists $p extends file] } {
                lappend associated [dict get $p extends file]
            }
            if { [dict exists $p env_file] } {
                lappend associated [dict get $p env_file]
            }
        }
        
        # Resolve the associated files, i.e. the one that the YAML
        # extends to a temporary location.
        set included {}
        foreach f [lsort -unique $associated] {
            # find the real location and resolve it out of its
            # environment variables as well...
            set src_path [file normalize [file join [file dirname $fpath] $f]]
            if { [file exists $src_path] } {
                set rootname [file rootname [file tail $f]]
                set ext [file extension $f]
                set tmp_fpath [Temporary \
                        [file join [TempDir] $rootname]]$ext
                log INFO "Copying a resolved version of $src_path to\
                        $tmp_fpath"
                set in_fd [open $src_path]
                set out_fd [open $tmp_fpath w]
                puts -nonewline $out_fd [environment resolve [read $in_fd]]
                close $in_fd
                close $out_fd
                
                lappend temporaries $tmp_fpath
                lappend included $f $tmp_fpath
            } else {
                log WARN "Cannot find location of $f at $src_path!"
            }
        }
        
        # Do some manual query/replace on the source YAML so that
        # mentions of relative extended services are replaced by a
        # reference to the temporary file resolved just above
        set i 0
        foreach {f dst} $included {
            # Replace and count replacements.
            set count 0
            while 1 {
                set i [string first $f $yaml $i]
                if { $i < 0 } {
                    # Nothing left to be found, done!
                    break
                } else {
                    # We've found a occurence of the filename, we
                    # replace if we can find a preceeding file:
                    # otherwise, we just advance.
                    set extender [string last "file:" $yaml $i]
                    if { $extender >= 0 } {
                        set j [expr {$i+[string length $f]-1}]
                        set yaml [string replace $yaml $i $j $dst]
                        # Advance to next possible, account for
                        # length of replacement.
                        incr i [expr {[string length $dst]-1}];
                        incr count 1
                    } else {
                        incr i [expr {[string length $f]-1}]
                    }
                }
            }
            log DEBUG "Replaced $count occurrences of $f in source YAML"
        }
        
        # Copy resolved result to temporary file
        set projdirname [file tail [file dirname $fpath]]
        set projname [file rootname [file tail $fpath]]
        set tmp_fpath [Temporary [file join [TempDir] $projname]].yml
        set fd [open $tmp_fpath w]
        puts -nonewline $fd $yaml
        close $fd
        lappend temporaries $tmp_fpath
        
        log NOTICE "Substituting environment variables in\
                compose project at $fpath via $tmp_fpath"
        if { $project eq "" } {
            set project $projdirname
        }
        
        # Arrange for compose to pick up the temporary
        # file, but still use the proper project name.
        set cmd [list tooling compose -stderr -- \
                --file $tmp_fpath --project-name $project]
        set composed $tmp_fpath
    } else {
        if { $project eq "" } {
            set cmd [list tooling compose -stderr -- --file $fpath]
        } else {
            set cmd [list tooling compose -stderr -- \
                    --file $fpath --project-name $project]
        }
        set composed $fpath
    }
    
    # Finalise command
    lappend cmd [string tolower $op]
    switch -nocase -- $op {
        "UP" {
            lappend cmd -d
            # Blindly add compose options if we had some.
            foreach o $options {
                lappend cmd $o
            }
        }
        "RM" {
            lappend cmd --force
        }
    }
    
    # Run compose command that we have built up and return to the main
    # directory at once for older versions of compose
    eval $cmd
    if { [vcompare lt [tooling version compose] 1.2] } {
        cd $maindir
    }
    
    # Cleanup files in temporaries list.
    if { $substitution < 2 && [llength $temporaries] > 0 } {
        log INFO "Cleaning up [llength $temporaries] temporary file(s)\
                from [TempDir]"
        foreach tmp_fpath $temporaries {
            file delete -force -- $tmp_fpath
        }
    }
    
    return $composed
}


# ::cluster::Mounting -- Return list of mount points and types
#
#       This procedure will either take the list of shares from its
#       arguments or the virtual machine specification and will return
#       a 3-ary list with, in order, the path to the local directory
#       on the host, the path to the directory on the machine and the
#       type of the mounting solution for keeping those directories in
#       sync at all time.  It can restrict itself to some types
#       through a selection pattern.
#
# Arguments:
#       vm        Virtual machine description
#       shares    Overriding list of shares (otherwise, those from machine)
#       types     Pattern for the types we want to restrict to.
#
# Results:
#       Return a 3-ary list of mount points and their types.
#
# Side Effects:
#       None.
proc ::cluster::Mounting { vm {shares {}} {types *}} {
    # Get shares, either from parameters (overriding the VM object) or
    # from vm object.
    if { [string length $shares] == 0 } {
        if { ![dict exists $vm -shares] } {
            return
        }
        set shares [dict get $vm -shares]
    }
    
    # Access origin to be able to resolve path of relative shares.
    set origin ""
    if { [dict exists $vm origin] } {
        set origin [file dirname [dict get $vm origin]]
    }
    
    # Detect default sharing type based on the driver of the virtual
    # machine.
    set sharing ""
    foreach {driver type} ${vars::-sharing} {
        if { [string match $driver [dict get $vm -driver]] } {
            set sharing $type
            break
        }
    }
    
    # Convert xx:yy constructs to pairs of shares, convert single
    # shares to two shares (the same) and append all these pairs to
    # the list called opening.  Arrange for the list to only contain
    # resolved shares as we allow for environment variable resolution
    set opening {}
    foreach spec $shares {
        set spec [Shares $spec $origin $sharing]; # Extraction and syntax check
        if { [llength $spec] > 0 } {
            foreach {host mchn type} $spec break
            if { [string match $types $type] } {
                lappend opening $host $mchn $type
            }
        }
    }
    
    return $opening
}


# ::cluster::Shares -- Parse share mount specification
#
#       This procedure will parse a share mount specification (either
#       a path, a list of host and guest path or host:guest), convert
#       environment variables to their values in the paths, check that
#       the host path exists and return either an empty list on
#       errors, or a list of exactly three items: the host port, the
#       guest port and the protocol to use for the forwarding.
#       Description
#
# Arguments:
#       spec        Share mount specification
#       origin      Relative directory location, if relevant.
#
# Results:
#       Return a pair compose of the host path and the guest path, or
#       an empty list on error.
#
# Side Effects:
#       None.
proc ::cluster::Shares { spec {origin ""} {type ""}} {
    set host ""
    set mchn ""
    set sharing ""
    
    # Segregates list from the string representation of shares.
    if { [llength $spec] >= 2 } {
        foreach {host mchn sharing} $spec break
    } else {
        set colon [string first ":" $spec]
        if { $colon >= 0 } {
            foreach {host mchn sharing} [split $spec ":"] break
        } else {
            set host $spec
        }
    }
    
    # Make sure we have a sharing type if default and segragate away
    # types that are not recognised.
    if { $sharing eq "" } { set sharing $type }
    if { $sharing ne "" && $sharing ni $vars::sharing } {
	log ERROR "Sharing type $sharing is not supported, should be one of\
                [join $vars::sharing ,\ ]"
        return {}
    }
    
    # Resolve (local) environement variables to the values and make
    # sure relative directories are resolved.
    set host [environment resolve $host]
    set mchn [environment resolve $mchn]
    if { $mchn eq "" } {
        set mchn $host
    }
    
    if { $origin ne "" } {
        set host [file normalize [file join $origin $host]]
        set mchn [file normalize [file join $origin $mchn]]
    }
    
    # Scream on errors and return
    if { $host eq "" } {
        log ERROR "No host path specified!"
        return {}
    } else {
        if { [file isdirectory $host] } {
            return [list $host $mchn $sharing]
        } else {
            log ERROR "$host is not a directory"
        }
    }
    return {}
}


proc ::cluster::IsRunning { vm { force 0 } } {
    set nfo [lindex [ls [storage $vm] [dict get $vm -name] $force] 0]
    if { [dict exists $nfo state] } {
        set state [dict get $nfo state]
        if { [lsearch -nocase ${vars::-running} $state] >= 0 } {
            return 1
        }
    }
    return 0
    
    
    if { [dict exists $vm state] } {
        set state [dict get $vm state]
        if { [lsearch -nocase ${vars::-running} $state] >= 0 } {
            return 1
        }
    }
    return 0
}


proc ::cluster::Exec { vm args } {
    set nm [dict get $vm -name]
    
    # Convert dash-led arg-style into YAML internal, just in case...
    foreach {k v} $args {
        dict set exe [string trimleft $k -] $v
    }
    
    if { [dict exists $exe exec] } {
        set substitution 0
        if { [dict exists $exe substitution] } {
            set substitution \
                    [string is true [dict get $exe substitution]]
        }
        
        set cargs [list]
        if { [dict exists $exe args] } {
            set cargs [dict get $exe args]
        }
        
        set remotely [DGet $exe remote 0]
        set copy [DGet $exe copy 1]
        set keep [DGet $exe keep 0]
        set sudo [DGet $exe sudo 0]
        
        # Resolve using initial location of YAML description file
        set cmd ""
        set tmp_fpath ""
        if { $copy } {
            set fpath [AbsolutePath $vm [dict get $exe exec]]
            if { [file exists $fpath] } {
                if { $substitution } {
                    # Read and substitute content of file
                    set fd [open $fpath]
                    set dta [environment resolve [read $fd]]
                    close $fd
                    
                    # Dump to temporary location
                    set rootname [file rootname [file tail $fpath]]
                    set ext [file extension $fpath]
                    set tmp_fpath [Temporary [file join [TempDir] $rootname]]$ext
                    set fd [open $tmp_fpath w]
                    puts -nonewline $fd $dta
                    close $fd
                    
                    set cmd $tmp_fpath
                } else {
                    set cmd $fpath
                }
            } else {
                log WARN "Cannot find external app to execute at: $fpath"
            }
        } else {
            set cmd [dict get $exe exec]
        }
        
        if { $cmd ne "" } {
            if { $remotely } {
                set dst [Temporary [file join /tmp [file tail $fpath]]]
                SCopy $vm $cmd $dst recurse off mode a+x
                log NOTICE "Executing $fpath remotely (args: $cargs)"
                if { $sudo } {
                    ssh $vm sudo $dst {*}$cargs
                } else {
                    ssh $vm $dst {*}$cargs
                }
                if { !$keep } {
                    ssh $vm /bin/rm -f $dst
                }
            } else {
                log NOTICE "Executing $fpath locally (args: $cargs)"
                tooling run -keepblanks -stderr -raw -- $cmd {*}$cargs
            }
            
            # Remove temporary (subsituted) file, if any.
            if { $tmp_fpath ne "" && !$keep } {
                file delete -force -- $tmp_fpath
            }
        }
    }
}


# ::cluster::Discovery -- Poor man's discovery
#
#       Arrange for a cache file to contain all network information
#       for the machine passed as a parameter.  The file is shared
#       amongst all machines of the same cluster, so that it will
#       provide for a snapshot of the current cluster state.  The file
#       declares environment variables.  For a given machine name
#       (e.g. myproj_myvm), all variables will start with the prefix
#       MACHINERY_MYPROJ_MYVM_ (so MACHINERY_ prepended to the name of
#       the maching in uppercase and an underscore).  Then for each
#       interface there will be, for each IP address found NAME_INET
#       and NAME_INET6 appended to the variable (where NAME is the
#       name of the interface in uppercase).  There will also be a IP
#       appened to the prefix, with a variable that contains the main
#       IP address for the machine (as of docker-machine ip).
#
# Arguments:
#        vm        Virtual machine description dictionary
#
# Results:
#       Return current state of the whole cluster as a dictionary.
#
# Side Effects:
#       None.
proc ::cluster::Discovery { vm } {
    set nm [dict get $vm -name]
    set pfx [string trimright ${vars::-prefix} "_"]_; # Force ending _ on prefix
    set prefixes [list $pfx[string map [list - _] [string toupper $nm]]]
    if { [dict exists $vm -aliases] } {
        foreach alias [dict get $vm -aliases] {
            lappend prefixes $pfx[string map [list - _] [string toupper $alias]]
        }
    }
    if { [dict exists $vm origin] } {
        # Get current discovery values for this machine from the cache.
        set env_path [environment cache $vm]
        set environment [environment read $env_path]
        
        # Remove all keys that are associated to this machine's name
        # and aliases, we are going to override (or won't have any if
        # it was stopped!)
        dict for {k v} $environment {
            foreach pfx $prefixes {
                if { [string first $pfx $k] == 0 } {
                    dict unset environment $k
                }
            }
        }
        
        # If the machine is running, go get all information we can
        # about its network interfaces and its (main) IP address.
        if { [IsRunning $vm] } {
            # Get complete network interface description (except the
            # virtual interfaces)
            foreach itf [unix ifs $vm] {
                foreach pfx $prefixes {
                    set k ${pfx}_[string toupper [dict get $itf interface]]
                    if { [dict exists $itf inet] } {
			log DEBUG "inet addr for [dict get $itf interface]\
                                is [dict get $itf inet]"
                        dict set environment ${k}_INET [dict get $itf inet]
                    }
                    if { [dict exists $itf inet6] } {
			log DEBUG "inet6 addr for [dict get $itf interface]\
                                is [dict get $itf inet6]"
                        dict set environment ${k}_INET6 [dict get $itf inet6]
                    }
                }
            }
            # Add the official IP address, as this is what will be
            # usefull most of the time.
            set ip [lindex [tooling machine -return -- -s [storage $vm] ip $nm] 0]
            if { $ip ne "" \
                        && [regexp {((\w|\w[\w\-]{0,61}\w)(\.(\w|\w[\w\-]{0,61}\w))*)|(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})} $ip] } {
                foreach pfx $prefixes {
                    if { [regexp {\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}} $ip] } {
                        dict set environment ${pfx}_IP $ip
                        dict set environment ${pfx}_HOSTNAME $ip
                    }
                    if { [regexp {(\w|\w[\w\-]{0,61}\w)(\.(\w|\w[\w\-]{0,61}\w))*} $ip] } {
                        dict set environment ${pfx}_HOSTNAME $ip
                        dict set environment ${pfx}_IP [::cluster::unix::resolve $ip]
                    }
                }
            }
        }
        
        # Dump the (modified) environment to the cache.
        log INFO "Writing cluster network information ($nm accounted)\
                to $env_path"
        environment write $env_path $environment
        
        return $environment
    }
    return {}
}




# ::cluster::LogTerminal -- Create log line for terminal output
#
#       Pretty print a log message for output on the terminal.  This
#       will use ANSI colour codings to improve readability (and will
#       omit the timestamps).
#
# Arguments:
#        lvl     Log level (an integer)
#        msg     Log message
#
# Results:
#       Line to output on terminal
#
# Side Effects:
#       None.
proc ::cluster::LogTerminal { lvl msg } {
    # Format the tagger so that they all have the same size,
    # i.e. the size of the longest level (in words)
    array set TAGGER $vars::verboseTags
    if { [info exists TAGGER($lvl)] } {
        set lbl [format %.6s "$TAGGER($lvl)        "]
    } else {
        set lbl [format %.6s "$lvl        "]
    }
    # Start by appending a human-readable level, using colors to
    # rank the levels. (see the + procedure below)
    set line "\["
    array set LABELER { 3 yellow 2 red 1 purple 4 blue 6 light }
    if { [info exists LABELER($lvl)] } {
        append line [+ $LABELER($lvl)]$lbl[+ normal]
    } else {
        append line $lbl
    }
    append line "\] "
    # Append the message itself, colorised again
    array set COLORISER { 3 yellow 2 red 1 purple 4 bold 6 light }
    if { [info exists COLORISER($lvl)] } {
        append line [+ $COLORISER($lvl)]$msg[+ normal]
    } else {
        append line $msg
    }
    
    return $line
}


# ::cluster::LogTerminal -- Create log line for file output
#
#       Pretty print a log message for output to a file descriptor.
#       This will add a timestamp to ease future introspection.
#
# Arguments:
#        lvl        Log level (an integer)
#        msg     Log message
#
# Results:
#       Line to output on file
#
# Side Effects:
#       None.
proc ::cluster::LogStandard { lvl msg } {
    array set TAGGER $vars::verboseTags
    if { [info exists TAGGER($lvl)] } {
        set lbl $TAGGER($lvl)
    } else {
        set lbl $lvl
    }
    set dt [clock format [clock seconds] -format ${vars::-date}]
    return "\[$dt\] \[$lbl\] $msg"
}


# ::cluster::Temporary -- Temporary name
#
#       Generate a rather unique temporary name (to be used, for
#       example, when creating temporary files). The procedure only keep
#       worthwhile characters, trying to ensure minimal problems when it comes
#       to file paths.
#
# Arguments:
#        pfx        Prefix before unicity taggers
#
# Results:
#       A string that is made unique through the process identifier
#       and some randomness.
#
# Side Effects:
#       None.
proc ::cluster::Temporary { pfx } {
    set dirname [file dirname $pfx]
    set fname [file tail $pfx]
    
    set nm ""
    set allowed [split $vars::fpathCharacters ""]
    foreach c [split $fname ""] {
        if { [lsearch $allowed $c] >= 0 } {
            append nm $c
        } else {
            append nm "-"
        }
    }
    if { $dirname eq "." || $dirname eq "" } {
        return ${nm}-[pid]-[expr {int(rand()*1000)}]
    } else {
        return [file join $dirname ${nm}-[pid]-[expr {int(rand()*1000)}]]
    }
}


# ::cluster::CacheFile -- Good name for a cache file
#
#       Generates a dotted (therefor hidden) filename to use for
#       caching various values.  The cache file will use the same
#       rootname in the same directory as the original YAML file, but
#       with a different extension.
#
# Arguments:
#        yaml        Original full path to YAML description file.
#        ext        Extension to use.
#
# Results:
#       An hidden file path for caching values.
#
# Side Effects:
#       None.
proc ::cluster::CacheFile { yaml ext } {
    set dirname [file dirname $yaml]
    set rootname [string trimleft [file rootname [file tail $yaml]] .]
    set path [file join [pwd] $dirname \
            ".$rootname.[string trimleft $ext .]"]
    
    return $path
}


# ::cluster::NameCmp -- Match machine names
#
#       This procedure matches if the name of a machine matches a name
#       that would have been entered on the command line.  This is
#       aware of the possible prefix.
#
# Arguments:
#	name	Real name of machine
#	nm	User-entered name
#	op	(Valid!) string comparison operation to use
#
# Results:
#       1 if names compare positively, 0 otherwise
#
# Side Effects:
#       None.
proc ::cluster::NameCmp { name nm {op equal}} {
    # Lookup with proper name
    if { [string $op $nm $name] } {
        return 1
    }
    # Lookup the separator separating the prefix from the machine name
    # and match on the name.
    set sep [string first ${vars::-separator} $name]
    if { $sep >= 0 } {
        incr sep [string length ${vars::-separator}]
        if { [string $op $nm [string range $name $sep end]] } {
            return 1
        }
    }
    
    return 0
}



# ::cluster::Convert -- SI multiples converter
#
#       This procedure will convert sizes (memory or disk) to a target
#       unit.  The incoming size specification is either a floating
#       point (see below for value) or a floating point followed by a
#       unit specifier, e.g. 10k to express 10 kilobytes.  The unit
#       specifier is case independent and the conversion will
#       understand both k, kB or KB.  Recognised are multipliers up to
#       yottabyte, e.g. the leading letters (in order!): b (bytes), k,
#       m, g, t, p, e, z, y.  When the incoming size, its default unit
#       can be specified, in which case this is one of the unit string
#       as described before.  If a returning unit is specified, then it
#       is a unit string as described before and describes the unit of
#       the returned value.
#
# Arguments:
#	spec	Size specification, e.g. 1345, 34k or 20MB.
#	dft	Default Unit of size spec when unspecified, e.g. k, GB, etc.
#	unit	Unit of converted returned value, e.g. k, GB or similar.
#
# Results:
#       The converted value in the requested SI unit, or an error.
#
# Side Effects:
#       None.
proc ::cluster::Convert { spec {dft ""} { unit "" } { precision "%.01f"} } {
    # Extract value and first letter of unit specification from
    # string.
    set len [scan $spec "%f %c" val ustart]
    
    # Convert incoming string to number of bytes in metric format,
    # see: http://en.wikipedia.org/wiki/Gigabyte
    if { $len == 2 } {
        set i [string first [format %c $ustart] $spec]
        set m [Multiplier [string range $spec $i end]]
        set val [expr {$val*$m}]
    } else {
        if { $dft ne "" } {
            set m [Multiplier $dft]
            set val [expr {$val*$m}]
        }
    }
    
    # Now convert back to the requested size
    if { $unit ne "" } {
        set m [Multiplier $unit]
        set val [expr {$val/$m}]
    }
    if { [string match "*.0" $val] } {
        return [expr {int($val)}]
    }
    return [format $precision $val]
}


proc ::cluster::Multiplier { unit } {
    foreach {rx m} $vars::converters {
        if { [regexp -nocase -- $rx $unit] } {
            return $m
        }
    }
    
    return -code error "$unit is not a recognised multiple of bytes"
}


# ::cluster::Wait -- Wait for state
#
#       Wait a finite amount of time until a virtual machine has
#       reached one of the specified states.  State matching occurs
#       case insensitive and the state return is one of those
#       specified in the arguments (as opposed to those returned by
#       docker-machine).  This is to ensure consistency of the code
#       when calling this procedure.
#
# Arguments:
#	vm	Virtual machine description
#	states	List of acceptable states to reach
#	sleep	Number of seconds to wait between poll retries.
#	retries	Maximum number of retries, negative for global default
#
# Results:
#       The reached state, as one of those pointed at by arguments or
#       an empty string on errors.
#
# Side Effects:
#       None.
proc ::cluster::Wait { vm {states {"running"}} { sleep 1 } { retries 5 } } {
    set nm [dict get $vm -name]
    if { $retries < 0 } {
        set retries ${vars::-retries}
    }
    while { $retries > 0 } {
        set machines [ls [storage $vm] $nm 1]
        if { [llength $machines] == 1 } {
            set mchn [lindex $machines 0]
            # If we have a state in the dictionary, match it against
            # the ones that we should stop at and, in that case,
            # return.
            if { [dict exists $mchn state] } {
                foreach s $states {
                    if { [string equal -nocase [dict get $mchn state] $s] } {
                        log INFO "Machine $nm is in state $s"
                        return $s
                    }
                }
            }
        }
        # Go on trying, this accepts floating number of seconds...
        incr retries -1;
        if { $retries > 0 } {
            log INFO "Still waiting for machine $nm to reach proper state..."
            after [expr {int($sleep*1000)}]
        }
    }
    log WARN "Gave up waiting for $nm to be running properly!"
    return ""
}


# ::cluster::Running -- Wait for machine to be running
#
#       This will actively wait for a virtual machine to be in the
#       running state and have a docker daemon that is up and running.
#
# Arguments:
#	vm	Virtual machine description
#	sleep	Number of seconds to sleep between tests
#	retries	Max number of retries.
#
# Results:
#       Return the complete VM description (bound) on success, empty
#       dictionary on errors.
#
# Side Effects:
#       None.
proc ::cluster::Running { vm { sleep 1 } { retries 3 } } {
    set nm [dict get $vm -name]
    if { $retries < 0 } {
        set retries ${vars::-retries}
    }
    while { $retries > 0 } {
        log DEBUG "Waiting for $nm to be running..."
        set state [Wait $vm]
        if { $state eq "running" } {
            set vm [bind $vm]
            if { [dict exists $vm url] && [dict get $vm url] ne "" } {
                return $vm
            } else {
                log INFO "Machine $nm was $state, but docker not yet ready"
            }
        } else {
            log INFO "Machine $nm was not $state"
        }
        after [expr {int($sleep*1000)}]
    }
    log WARN "Gave up waiting for $nm to be fully started!"
    
    return {}
}


# ::cluster::DGet -- get or default from dictionary
#
#       Get the value of a key from a dictionary, returning a default value if
#       the key does not exist in the dictionary.
#
# Arguments:
#       d       Dictionary to get from
#       key     Key in dictionary to query
#       default	Default value to return when key does not exist
#
# Results:
#       Value of key in dictionary, or default value if it does not exist.
#
# Side Effects:
#       Copy the file using scp
proc ::cluster::DGet { d key { default "" } } {
    if { [dict exists $d $key] } {
        return [dict get $d $key]
    }
    return $default
}


# ::cluster::SCopy -- scp to machine
#
#       Copy a local file to a machine using scp.  This procedure is
#       able to circumvent the missing scp command from machine 0.2
#       and under.
#
# Arguments:
#       vm      Virtual machine description
#       s_fname	Path to source file
#       d_fname	Path to destination, empty for same as source.
#
# Results:
#       None.
#
# Side Effects:
#       Copy the file using scp
proc ::cluster::SCopy { vm s_fname d_fname args } {
    set nm [dict get $vm -name]
    if { $d_fname eq "" } {
        set d_fname $s_fname
    }
    
    set elevation ""
    if { [DGet $args sudo off] } {
        set elevation sudo
    }
    
    # Create directory where to receive data.
    if { [file isdirectory $s_fname] } {
        tooling machine -- -s [storage $vm] ssh $nm {*}$elevation mkdir -p $d_fname            
    } else {
        # Use formatting of destination to guess if it is a directory or not...
        if { [string index $d_fname end] eq "/" } {
            tooling machine -- -s [storage $vm] ssh $nm {*}$elevation mkdir -p $d_fname
        } else {
            tooling machine -- -s [storage $vm] ssh $nm {*}$elevation mkdir -p [file dirname $d_fname]
        }
    }

    # Save real destination in a variable and generate a temporary directory
    # to hold the content of the file(s) that we will copy. Create the directory
    # at the remote host!
    if { $elevation eq "sudo" } {        
        set d_real $d_fname
        set d_fname [string trimright [Temporary /tmp/scp] /]/
        log INFO "Performing copy through temporary directory $d_fname"
        tooling machine -- -s [storage $vm] ssh $nm mkdir -p $d_fname
    }

    if { [vcompare ge [tooling version machine] 0.3] } {
        set storage [storage $vm]
        # On windows we need to trick the underlying scp of docker-machine,
        # which really is a relay to the scp command. We force in localhost:
        # at the beginning of the source path and find out the local mount
        # point for absolute source paths.
        if { $::tcl_platform(platform) eq "windows" } {
            # Find windows volume and put it in the volume variable
            set volume ""
            foreach vol [file volumes] {
                if { [string first $vol [string toupper $s_fname]] == 0 } {
                    set volume $vol
                    break
                }
            }
            
            # If we had a volume, the source path is absolute. Replace this by
            # the local mount (this will both recognise cygwin- and mingw- based
            # environments)
            if { $volume ne "" } {
                set volume [string trimright $volume /]
                set lmount [VolumeLocation $volume]
                if { $lmount ne "" } {
                    set src "localhost:"
                    append src $lmount
                    append src [string range $s_fname 2 end]
                }
            } else {
                set src $s_fname
            }
        } else {
            set src $s_fname
        }

        # Construct options to scp command and call it.
        set opts [list]

        # Recursion is auto or a boolean
        set recursion [DGet $args recurse auto]
        if { $recursion eq "auto" } {
            set recursion [file isdirectory $src]
        }
        if { $recursion } {
            lappend opts -r
        }
        
        # Delta for rsync-helped copy
        if { [DGet $args delta off] } {
            lappend opts -d
        }
        
        # Now perform copy
        tooling machine -stderr -- -s $storage scp {*}$opts $src ${nm}:${d_fname}
        
        # And perform past-copy operations in order to be able to operate on
        # ownership of file(s) or access modes.
        set opts [list]
        if { $recursion || $elevation eq "sudo" } {
            set opts [list -R]
        }

        # chmod        
        set mode [DGet $args mode]
        if { $mode ne "" } {
            tooling machine -stderr -- -s $storage ssh $nm chmod {*}$opts $mode $d_fname
        }
        
        # chown
        set owner [DGet $args owner]
        if { $owner ne "" } {
            tooling machine -stderr -- -s $storage ssh $nm chown {*}$opts $owner $d_fname
        }
        
        # chgrp
        set group [DGet $args group]
        if { $group ne "" } {
            tooling machine -stderr -- -s $storage ssh $nm chgrp {*}$opts $group $d_fname
        }
    } else {
        unix defaults -ssh [SCommand $vm]
        unix scp $vm $s_fname $d_fname
    }
    
    if { $elevation eq "sudo" } {
        log INFO "Moving file(s) from $d_fname to $d_real"
        tooling machine -stderr -- -s $storage ssh $nm {*}$elevation \
            mv -f [file join $d_fname [file tail $s_fname]] $d_real && rm -rf $d_fname
    }
}


# ::cluster::SCommand -- SSH Command to machine
#
#       This procedure actively computes the SSH command to execute an
#       SSH to the machine specified as its argument.  It will either
#       use the global ssh command from the variables, in which case
#       any occurence of %port%, %user%, %identity% and %host% will be
#       replaced with, respectively the port number, the username, the
#       path to the identity file and the hostname/IP address of the
#       remote machine. Otherwise, it will use the unix module to
#       guess the SSH command.
#
# Arguments:
#	vm	Virtual machine description
#
# Results:
#       Return the ssh command to the machine as a list, with the
#       hostname as the last argument of the list (no user@host
#       construct left)
#
# Side Effects:
#       None.
proc ::cluster::SCommand { vm } {
    set nm [dict get $vm -name]
    set ssh {}
    if { ${vars::-ssh} ne "" } {
        set nfo [inspect $vm]
        set mapper [list \
                "%port%" [dict get $nfo Driver SSHPort] \
                "%host%" [dict get $nfo Driver IPAddress] \
                "%user%" [dict get $nfo Driver SSHUser]]
        set id_path [file join [dict get $nfo StorePath] id_rsa]
        if { [file exists $id_path] } {
            lappend mapper "%identity%" $id_path
        }
        set ssh [string map $mapper ${vars::-ssh}]
    } else {
        set ssh [unix remote $vm]
    }
    
    # Extract user name and host name from last argument if possible.
    # This follows RFC1123 for the extraction of the hostname (but is
    # probably wrong for non-latin chars?
    set last [lindex $ssh end]
    if { [regexp {(\w+)@((\w|\w[\w\-]{0,61}\w)(\.(\w|\w[\w\-]{0,61}\w))*)} $last x uname hname] } {
        set ssh [lrange $ssh 0 end-1]
        lappend ssh -l $uname $hname
    }
    
    return $ssh
}


proc ::cluster::InstallRSync { vm } {
    set nm [dict get $vm -name]
    
    set installer ""
    set id [OSIdentifier $vm]
    switch -glob -nocase -- $id {
        "debian*" -
        "ubuntu*" {
            # Ubuntu
            set installer "sudo apt-get update; sudo apt-get install -y rsync"
        }
        "*docker" {
            # Boot2docker
            set installer "tce-load -wi rsync"
        }
    }
    
    if { $installer eq "" } {
	log WARN "Cannot install rsync in $nm: OS '$id' in $nm\
                is not (yet?) supported"
    } else {
        log NOTICE "Installing rsync in $nm"
        tooling machine -- -s [storage $vm] ssh $nm $installer
    }
}


proc ::cluster::OSInfo { vm } {
    set nfo {}
    set nm [dict get $vm -name]
    foreach l [tooling machine -return -- -s [storage $vm] ssh $nm "cat /etc/os-release"] {
        set k [environment line nfo $l]
    }
    
    return $nfo
}


proc ::cluster::OSIdentifier { vm } {
    set nfo [OSInfo $vm]
    if { [dict exists $nfo ID] } {
        return [dict get $nfo ID]
    } else {
        return ""
    }
}


proc ::cluster::AbsolutePath { vm fpath { native 0 } } {
    if { [dict exists $vm origin] } {
        set dirname [file dirname [dict get $vm origin]]
        log DEBUG "Joining $dirname and $fpath to get final path"
        set fpath [file join $dirname $fpath]
    }
    set fpath [file normalize $fpath]
    if { [string is true $native] } {
        set fpath [file nativename $fpath]
    }
    
    return $fpath
}


proc ::cluster::TempDir {} {
    if { ${vars::-tmp} ne "" } {
        return ${vars::-tmp}
    }
    
    if { [lsearch [split [::platform::generic] -] win32] >= 0 } {
        set resolutions [list USERPROFILE AppData/Local/Temp \
                windir TEMP \
                SystemRoot TEMP \
                TEMP "" TMP "" \
                "" "C:/TEMP" "" "C:/TMP" "" "C:/"]
    } else {
        set resolutions [list TMP "" "" /tmp]
    }
    
    foreach { var subdir }  $resolutions {
        set dir ""
        if { $var eq "" } {
            set dir $subdir
        } elseif { [info exists ::env($var)] && [set ::env($var)] ne "" } {
            set dir [file join [set ::env($var)] $subdir]
        }
        if { $dir ne "" && [file isdirectory $dir] } {
            log TRACE "Using $dir as a temporary directory"
            return $dir
        }
    }
    
    return [cwd]
}


proc ::cluster::VolumeLocation { vol } {
    set vol [string toupper [string trimright $vol /]]
    if { [dict exists $vars::volMounts $vol] } {
        return [dict get $vars::volMounts $vol]
    } else {
        foreach l [tooling run -return -- mount] {
            set on [string first " on " $l]
            if { $on >= 0 } {
                set type [string first " type " $l $on]
                if { $type >= 0 } {
                    set v [string trim [string range $l 0 [expr {$on-1}]]]
                    if { [string equal -nocase $vol $v] } {
                        set l [string trim [string range $l [expr {$on+3}] [expr {$type-1}]]]
                        log INFO "Discovered local mount for $vol at $l"
                        dict set vars::volMounts $vol $l
                        return $l
                    }
                }
            }
        }
    }
    
    return "";  # Not found!
}


proc ::cluster::DefaultMachine {} {
    set possible ""; # Will hold the name of a possible machine to use as default
    
    # Get docker system-wide information
    set d_info [tooling docker -return -raw -stderr -- info]
    if { [string match -nocase "*error occurred trying to connect*" $d_info] } {
        # If we get an error, and since we know that we are on windows, we are
        # probably running on top of the Docker Toolbox. Then the default
        # machine is a good guess...
        set possible "default"
    } else {
        # We did not get an error, then either we are running with the new
        # Docker for Windows beta or we were attached to something (something
        # else?)
        set info [dict create]; # Dictionary to hold info parsing results
        
        # Parse what was returned by docker info. As it is a tree, using
        # indentation, we represent the different levels by dot-separated keys.
        # (the format is not compatible with what Tcl considers as a dictionary)
        set lvl [list]
        foreach l $d_info {
            set clean [string trimleft $l]
            # Key and value are composed of what is directly before and
            # after the first : sign. This is important since the value can
            # contain : signs.
            set colon [string first ":" $clean]
            if { $colon >= 0 } {
                set k [string trim [string range $clean 0 [expr {$colon-1}]]]
                set v [string trim [string range $clean [expr {$colon+1}] end]]
                
                # Count the number of spaces and compare to the current level
                # (this suppose one space for indentation)
                set lead [expr {[string length $l]-[string length $clean]}]
                if { $lead+1 > [llength $lvl] } {
                    lappend lvl $k
                } elseif { $lead+1 < [llength $lvl] } {
                    set lvl [lrange $lvl 0 end-1]
                } else {
                    set lvl [lreplace $lvl end end $k]
                }
                dict set info [join $lvl .] $v
            }
        }
        
        # If the machine against which we are running is a boot2docker machine,
        # good chance is that we are running against the docker toolbox (and had
        # attached to the default machine).
        if { [dict exists $info "Operating System"] \
                    && [string match -nocase "*Boot2Docker*" [dict get $info "Operating System"]] } {
            # Pick up the machine that we had attached to, or "default" if we
            # can't find one.
            if { [dict exists $info "Name"] } {
                set possible [dict get $info "Name"]
            } else {
                set possible "default"
            }
        }
    }
    
    # When here, the variable possible points at the name of a machine running
    # locally on virtual box, thus as part of the docker toolbox. Check that
    # this really is one of the default known machines and pick it up as the
    # default machine for caching if it was.
    if { $possible ne "" } {
        set state [tooling machine -return -- ls]
        foreach nfo [tooling parser $state] {
            # Add only machines which name matches the incoming pattern.
            if { [dict exists $nfo name] \
                        && [dict get $nfo name] eq "default" } {
                return "default"
            }
        }
    }
    
    return ""
}


proc ::cluster::Machines { cluster } {
    if { [dict exists $cluster -machines] } {
        return [dict get $cluster -machines]
    }
    return $cluster
}


proc ::cluster::WaitSSH { vm { sleep 5 } { retries 5 } } {
    set nm [dict get $vm -name]
    if { $retries < 0 } {
        set retries ${vars::-retries}
    }
    log DEBUG "Waiting for ssh to be ready on $nm"
    while { $retries > 0 } {
        set l [lindex [tooling machine -return -- -s [storage $vm] ssh $nm "echo ready"] 0]
        if { $l eq "ready" } {
            return $retries
        }
        incr retries -1;
        if { $retries > 0 } {
            log INFO "Still waiting for SSH to be ready on $nm..."
            after [expr {int($sleep*1000)}]
        }
    }
    log WARN "Gave up waiting for SSH on $nm!"
    return $retries
}

package provide cluster 0.4


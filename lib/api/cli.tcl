##################
## Module Name     --  cli.tcl
## Original Author --  Emmanuel Frecon - emmanuel@sics.se
## Description:
##
##     This module implements most of the low-level command-line
##     options services for machinery.  It exports a command called
##     cli with which all other operations can be performed.
##
##################

package require cluster::swarm
package require cluster::tooling
package require cluster::utils

namespace eval ::api::cli {
    namespace eval vars {
        # All global options recognised by the main program are
        # described here.  Note that once these options have been
        # parsed, there will be variables populating the vars
        # sub-namespace with the final values of the variables.  The
        # variables will have the same name as the options, including
        # the leading dash.
        variable gopts {
            -help      ""                 "Print this help and exit"
            -verbose   5                  "Verbosity level \[0-6\]"
            -machine   "docker-machine"   "Path to docker-machine"
            -docker    "docker"           "Path to docker"
            -compose   "docker-compose"   "Path to docker-compose"
            -token     ""                 "Override token for cluster"
            -cluster   ""                 "YAML description, empty for cluster.yml"
            -driver    "virtualbox"       "Default driver for VM creation"
            -caching   "*/*/* on * off"   "Image caching hints"
            -cache     ""                 "Name of machine to locally cached docker images, - to turn off, empty for local machine"
            -ssh       ""                 "SSH command to use into host, dynamic replacement of %-surrounded keys will happen, e.g. ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectionAttempts=30 -o LogLevel=quiet -p %port% -i %identity% %user%@%host%.  Empty to guess."
            -config    ""                 "Path to config file, command-line arguments will override configure content"
            -storage   ""                 "Location of machine storage cache, empty for co-located with YAML description"
            -dns       ""                 "IP of nameserver to use for name resolution"
            -mounts    ""                 "List of alternating remote local virtual mounts, empty for auto, - to turn off"
            -tweaks    ""                 "Alternating list of (semi-)internal module configuration"
        }
        # This is the list of recognised commands that will be print
        # when help is requested.
        variable cmds {
            help    "Print out help or command help"
            up      "Create and bring up cluster and/or specific machines"
            halt    "Bring down cluster and/or specific machines"
            token   "Create (new) swarm token, force regeneration with -force"
            destroy "Destroy cluster and/or specific machines"
            restart "Restart whole cluster and/or specific machines"
            env     "Export environment variables for discovery"
            reinit  "Rerun finalisation stages on machine(s), specify via -step"
            swarm   "Lifecycle management of components via swarm"
            stack   "Stack lifecycle for new swarm mode"
            node    "Relays low(er)-level node operations for new swarm mode"
            sync    "One shot synchronisation of rsync shares"
            forall  "Execute docker command on all matching containers"
            search  "Search for matching containers"
            ssh     "Execute command in cluster machine"
            server  "Start a web server to respond to REST calls"
            ps      "List all existing containers in cluster or specific machines"
            ls      "List all machines in the cluster and their state"
            pack    "Pack all cluster info in ZIP for migration"
            version "Print out current version number"
        }
        
        variable appname "";          # Name of main application.
        variable version 0.8-dev;     # GLOBAL Application version!
        variable yaml "";             # The cluster YAML file we ended up using!
        variable justify 80;          # Justification for long text
        variable default "./cluster.yml"
        variable indent "  ";         # Indentification forward
    }
    
    namespace export {[a-z]*};         # Convention: export all lowercase
    namespace path [namespace parent]; # DANGER: Be aware of similar names!
    namespace ensemble create -command ::cli
    namespace import ::cluster::utils::log
}

# ::api::cli::help -- Dump help and exit
#
#       This will dump the help for the program and exit.  Help output
#       will use the list of global options defined as part of the
#       vars sub-namespace.
#
# Arguments:
#	hdr	An optional header string to output at first
#
# Results:
#       None.
#
# Side Effects:
#       COMPLETELY exit the program at once!
proc ::api::cli::help { {hdr ""} {fd stderr} } {
    if { $hdr ne "" } {
        puts $fd ""
        puts $fd $hdr
        puts $fd ""
    }
    puts $fd "NAME:"
    puts $fd "${vars::indent}${vars::appname} -\
            Cluster lifecycle management via docker, machine, compose and swarm"
    puts $fd ""
    puts $fd "USAGE"
    puts $fd "${vars::indent}${vars::appname} \[global options\] command \[command options\] \[arguments...\]"
    puts $fd ""
    puts $fd "VERSION"
    puts $fd "${vars::indent}${vars::version}"
    puts $fd ""
    puts $fd "COMMANDS:"
    Tabulate 2 $vars::cmds $fd "${vars::indent}"
    puts $fd ""
    puts $fd "GLOBAL OPTIONS:"
    # Rewrite option descriptions, tabulate nicely and output
    set optout {}
    foreach { arg val dsc } $vars::gopts {
        lappend optout $arg "$dsc (default: $val)"
    }
    Tabulate 2 $optout $fd "${vars::indent}"
    exit
}


# ::api::cli::chelp -- Dump command help and exit
#
#       Dump command specific help and exit.  The help message will
#       automatically by justified and the option descriptions
#       tabulated.
#
# Arguments:
#	cmd	Command to give help for
#	hlp	Help for command
#	opts	Pairs of options and their descriptions.
#	fd	Where to dump out the help.
#
# Results:
#       None.
#
# Side Effects:
#       Exit the program!
proc ::api::cli::chelp { cmd hlp {opts {}} {fd stderr} } {
    puts $fd ""
    puts $fd [Justify $hlp $vars::justify]
    puts $fd ""
    puts $fd "USAGE"
    if { [llength $opts] > 0 } {
        puts $fd "${vars::indent}${vars::appname} \[global options\] $cmd \[command options\]"
        puts $fd ""
        puts $fd "COMMAND OPTIONS"
        Tabulate 2 $opts $fd "${vars::indent}"
    } else {
        puts $fd "${vars::indent}${vars::appname} \[global options\] $cmd"
    }
    puts $fd ""
    exit
}

# ::api::cli::globals -- Extract global options from args
#
#       Extract the global options from the main arguments and
#       initialise so that global dash-led variables within the
#       sub-namespace vars contain the final options given to the
#       program.  This procedure will arrange to initialise options
#       from any configure files that would be provided with the
#       -config option.  Options (and their values) are ACTIVELY
#       removed from the argument list.
#
# Arguments:
#	appname	Name of application, i.e. generally main script
#	argv_	Pointer to list of program arguments.
#
# Results:
#       None.
#
# Side Effects:
#       Exit on problems or help, read configure files and actively
#       modify incoming list of arguments.
proc ::api::cli::globals { appname argv_ } {
    # Initialise defaults, i.e. take the default value of all global
    # options and for each option create one extra variable in our
    # child namespace.  The variable names will have a dash, that's
    # ok!  We arrange to do this only once, just in case.
    if { [llength [info vars vars::-*]] == 0 } {
        foreach {arg val dsc} $vars::gopts {
            set vars::$arg $val
        }
    }
    
    # Remember application name for later.
    set vars::appname $appname
    
    # Access global arguments.
    upvar $argv_ argv
    
    # Roll forward to look for separating -- or first
    # command. Anything before the -- or command are the global
    # options, anything else is the command.
    set ddash [lsearch $argv --]
    if { $ddash >= 0 } {
        set opts [lrange $argv 0 [expr {$ddash-1}]]
        set argv [lrange $argv [expr {$ddash+1}] end]
    } else {
        # Find the first commands, since arguments to commands could
        # be matching a command name we look for the closest one to
        # the argument start.
        set cmdloc -1
        foreach {cmd hlp} $vars::cmds {
            set i [lsearch $argv $cmd]
            if { $cmdloc < 0 || ($i >= 0 && $i < $cmdloc) } {
                set cmdloc $i
            }
        }
        # We have a command, isolate global options from arguments,
        # otherwise we don't know what to do!
        if { $cmdloc >= 0 } {
            set opts [lrange $argv 0 [expr {$cmdloc-1}]]
            set argv [lrange $argv $cmdloc end]
        } else {
            help "Couldn't find a known command!"
        }
    }
    
    # No Arguments remaining?? dump help and exit since we need a command
    # to know what to really do...
    if { [llength $argv] <= 0 } {
        help "No command specified!"
    }
    
    # Did we request for help? Output and goodbye
    if { [utils getopt opts "-help"] } {
        help
    }
    
    # Do we have a configure file to read, do this at once.
    utils getopt opts -config vars::-config ${vars::-config}
    if { ${vars::-config} ne "" } {
        Config ${vars::-config}
    }
    
    # Eat all program options from the command line, the latest value
    # will be the one as we don't have options that can appear several
    # times.
    for {set eaten ""} {$eaten ne $opts} {} {
        set eaten $opts
        foreach opt [info vars vars::-*] {
            set opt [lindex [split $opt ":"] end]
            utils getopt opts $opt vars::$opt [set vars::$opt]
        }
    }
    
    # Remaining opts? They are unknown!
    if { [llength $opts] > 0 } {
        help "'$opts' contains unknown global options!"
    }
    
    # Pass arguments from the command-line as the defaults for the cluster
    # module.
    foreach k [list -verbose] {
        utils defaults cluster::utils $k [set vars::$k]
    }
    foreach k [list -cache -caching -ssh -storage] {
        cluster defaults $k [set vars::$k]
    }
    foreach k [list -machine -docker -compose] {
        utils defaults cluster::tooling $k [set vars::$k]
    }
    
    if { ${vars::-dns} ne "" } {
        package require dns
        ::dns::configure -nameserver ${vars::-dns}
    }

    set tweaks [list]
    foreach { tweak value } ${vars::-tweaks} {
        foreach {ns var} [split $tweak .] break
        if { $ns ne "" && $var ne "" } {
            set tgt cluster::[string trimleft $ns :]
            if { [catch {utils defaults $tgt $var $value}] == 0 } {
                lappend tweaks $tweak
            } else {
                log WARN "Could not apply tweak $tweak: $res"
            }
        }
    }
    if { [llength $tweaks] } {
        log NOTICE "Applied [llength $tweaks] tweaks to internal configurations"
    }
}

# ::api::cli::defaults -- Set/get default parameters
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
proc ::api::cli::defaults { {args {}}} {
    return [utils defaults [namespace current] {*}$args]
}


# ::api::cli::version -- Program version
#
#       Accessor for the main program version number.
#
# Arguments:
#       None.
#
# Results:
#       Current version number for program.
#
# Side Effects:
#       None.
proc ::api::cli::version {} {
    return $vars::version
}


# ::api::cli::resolve -- Resolve proper YAML for parsing
#
#       Without any cluster file specified, machinery will try loading
#       the default file called cluster.yml from the current
#       directory.  This procedure arranges to return the location of
#       the YAML for the cluster that the program should handle
#       according to this convention.
#
# Arguments:
#	pfx_	Cluster prefix (to be prepended to all machine names!)
#	fname	Force path to file, otherwise take from global options.
#
# Results:
#       Return the path to the YAML description file that we should
#       parse for cluster description.
#
# Side Effects:
#       None.
proc ::api::cli::resolve { pfx_ {fname ""} } {
    # Access prefix in caller's stack
    upvar $pfx_ pfx
    set pfx ""
    
    # Default to value from global options if nothing specified.
    if { $fname eq "" } {
        set fname ${vars::-cluster}
    }
    
    # Set the prefix and filename depending on the filename that we
    # ended up picking.
    if { $fname eq "" } {
        if { [file exists ${vars::default}] } {
            set fname ${vars::default}
            return $fname
        } else {
            set candidates [cluster candidates]
            if { [llength $candidates] > 1 } {
                log WARN "Found [llength $candidates] possible cluster\
                        files, cannot pickup one automatically!"
            } else {
                # Pick the only possible candidate
                set fname [lindex $candidates 0]
                log NOTICE "Automatically picking YAML file at:\
                        $fname"
            }
        }
    }
    
    if { $fname ne "" } {
        set pfx [file rootname [file tail $fname]]
    }
    
    return $fname
}


# ::api::cli::yaml -- Parse YAML content
#
#       This rather badly named procedure (this is to avoid name clash
#       with the command called 'cluster') will parse the content of
#       the YAML file passed as an argument.  Machines that have no
#       drivers will be given the one that was specified as part of
#       the global options.
#
# Arguments:
#	fname	Path to file to read
#	pfx	Prefix to prepend to all machine names.
#
# Results:
#       Return a list of dictionaries describing the cluster.
#
# Side Effects:
#       Dumps help and exit on parsing problems.
proc ::api::cli::yaml { fname {pfx ""} } {
    if { [catch {cluster parse $fname \
                -prefix $pfx -driver ${vars::-driver}} cluster] } {
        help $cluster
    }
    return $cluster
}



# ::api::cli::init -- Initialise cluster description
#
#       This will read the cluster YAML description file as specified
#       from the global options and arrange to complement the VM
#       description dictionaries with the current state of the running
#       machines that are part of that cluster.
#
# Arguments:
#	fname	Path to YAML file to read, empty from global options
#
# Results:
#       A list of VM description dictionaries, including running state
#       information whenever relevant and accessible.
#
# Side Effects:
#       Exit with help information on parsing problems.
proc ::api::cli::init { {fname ""} } {
    set vars::yaml [resolve pfx $fname]
    set cspec [yaml $vars::yaml $pfx]

    cluster vfs $vars::yaml ${vars::-mounts}
    
    # Recap with current state of cluster as seen from docker-machine
    # and arrange for <cluster> to be the list of virtual machine
    # descriptions that represent the whole cluster that we should
    # operate on.
    set cluster [dict create \
            -options [dict get $cspec -options] \
            -networks [dict get $cspec -networks] \
            -applications [dict get $cspec -applications] \
            -machines [list]]
    set state [cluster ls $vars::yaml]
    foreach vm [dict get $cspec -machines] {
        dict lappend cluster \
                -machines [cluster bind $vm $state [dict get $cspec -options]]
    }
    
    return $cluster
}


# ::api::cli::token -- Access/Generate swarm token
#
#       High-level access or generation of the swarm token for a given
#       cluster.
#
# Arguments:
#	force	Set to 1 to force re-generation of token
#	yaml	Path to YAML description of cluster.
#
# Results:
#       The token to use for swarm orchestration.
#
# Side Effects:
#       Token generation will kick-off a local docker component.
proc ::api::cli::token {{force 0} {yaml ""}} {
    if { $yaml eq "" } {
        set yaml $vars::yaml
    }
    
    # Generate token if necessary (or forced through option
    # -force), cache it and print it out.
    if { ${vars::-token} ne "" } {
        set token ${vars::-token}
    } else {
        #set token [cluster token $CRT(-cluster) $force $CRT(-driver)]
        set token [::cluster::swarm::token $yaml $force ""]
    }
    return $token
}


# ::api::cli::machines -- Select machines to operate on
#
#       As machine names can be prefixed by the name of the cluster,
#       this procedure arranges to look for all cluster machines that
#       would match the shortnames, i.e. the names without the prefix,
#       within the cluster.  It returns a list of VM description
#       dictionaries.
#
# Arguments:
#	cluster	    Cluster to select from (i.e. list of VM dicts).
#	shortnames  List of name patterns to select within cluster, empty == all
#
# Results:
#       Return a list of VM dictionaries for the machines whose name
#       match the ones passed as arguments.
#
# Side Effects:
#       None.
proc ::api::cli::machines { cluster {shortnames {}} } {
    if { [llength $shortnames] == 0 } {
        set shortnames [cluster names $cluster]
    }
    
    set machines {}
    foreach nm $shortnames {
        foreach vm [cluster findAll $cluster $nm] {
            # Add only if not yet in the found list of machines, to
            # avoid duplicates.
            if { [cluster find $machines [dict get $vm -name] 1] eq {} } {
                lappend machines $vm
            }
        }
    }
    
    return $machines
}


# ::api::cli::up -- Up or start machine
#
#       This is a helper procedure that will either create or simply
#       start a VM of the cluster, depending on its current state.
#       Whenever a state is present and is not running, the machine
#       will be started.  In all other cases, this will attempt to
#       create the VM.
#
# Arguments:
#	vm	Complete (bound) VM description
#	token	Swarm token to use for VM creation
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::api::cli::up { vm args } {
    if { [dict exists $vm state] } {
        if { ![string equal -nocase [dict get $vm state] "running"] } {
            cluster start $vm
        }
    } else {
        cluster create $vm {*}$args
        return 1
    }
    return 0
}


# ::api::cli::command -- Main program dispatcher
#
#       This procedure implements the main program dispatcher.
#
# Arguments:
#	cmd	Command to execute (case insensitive)
#	args	Additional arguments to command
#
# Results:
#       None, but note that the command called server will block!
#
# Side Effects:
#       A whole lot!
proc ::api::cli::command { cmd args } {
    switch -nocase -- $cmd {
        "version" {
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Print program version on standard output and exit." \
                        { -help "Print this help" }
            }
            puts stdout [version]
        }
        "help" {
            if { [llength $args] == 0 } {
                cli help
            } else {
                command [lindex $args 0] -help
            }
        }
        "token" {
            tooling runtime exit
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Possibly generate and print out the swarm token for this cluster.  Tokens are cached on disk in a hidden file for reuse. Use the -force option to force the generation of a new token if necessary." \
                        {   -help "Print this help"
                            -force "For regeneration of a new token" }
            }
            set cluster [init]
            puts stdout [token [utils getopt args -force]]
        }
        "start" -
        "up" {
            tooling runtime exit
            # Start up one or several machines (or the whole cluster if no
            # arguments), the machines will be created if they did not
            # exists
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Start up one or several machines (or the whole cluster if no arguments is given).  The machines will be created if they do not exist, otherwise they will be started up if they were stopped.  Apart from the command options, all arguments to this command should be machine names, as from the YAML description." \
                        { -help "Print this help" }
            }
            set cluster [init]
            set clustering [dict get $cluster -options -clustering]
            set token "" 
            if { [string match -nocase "docker*swarm" $clustering] } {
                set token [token]
                foreach vm [machines $cluster $args] {
                    up $vm -token $token
                }
                ::cluster::swarm::recapture $cluster
            } else {
                set created [list]
                foreach vm [machines $cluster $args] {
                    if { [up $vm \
                            -steps [cluster steps "worker" [cluster defaults -steps]] \
                            -masters [Masters $cluster] \
                            -networks [dict get $cluster -networks] \
                            -applications [dict get $cluster -applications]] } {
                        lappend created $vm
                    }
                }                
                foreach vm $created {
                    cluster init $vm \
                        -steps [cluster steps "manager" [cluster defaults -steps]] \
                        -masters [Masters $cluster] \
                        -networks [dict get $cluster -networks] \
                        -applications [dict get $cluster -applications]
                }                
            }
        }
        "stack" {
            tooling runtime exit
            
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Bring up/down stacks and status introspection of services for new swarm mode. This brings support for 'extends' in compose v3+ format. All commands are passed further to docker stack at one of the managers." \
                        { -help "Print his help" }
            }
            set masters [Masters [init]]
            if { [llength $masters] } {
                swarmmode stack $masters {*}$args
            } else {
                log WARN "$cmd can only be used with new Swarm Mode"
            }
        }
        "node" {
            tooling runtime exit
            
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Relays low(er)-level node opeations on swarm to one of the managers" \
                        { -help "Print his help" }
            }
            set masters [Masters [init]]
            if { [llength $masters] } {
                swarmmode node $masters {*}$args
            } else {
                log WARN "$cmd can only be used with new Swarm Mode"
            }
        }
        "swarm" {
            tooling runtime exit
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "When called with no arguments, just print out the cluster info.  When called with arguments, these should be YAML file ready for compose, or YAML files containing indirections to YAML project files, as in the main cluster YAML description syntax." \
                        {   -help "Print this help"
                    -stop "Stop the components"
                    -kill "Forcedly kill the components"
                    -rm "Remove the components"
                    -up "(re)create the components (this is the default)"
                    -start "Start the components"
                -options "Takes a comma separated string as argument, each item should look like key=value, where the keys are as of the compose indirection YAML specification, e.g. project, substitution, etc." }
            }
            set cluster [cli init]
            if { [llength $args] == 0 } {
                ::cluster::swarm::info $cluster
            } else {
                set master [::cluster::swarm::master $cluster]
                
                # Get arguments from the command line and convert these to
                # operations that we can give away to swarm command below.
                # The operations are ORDERED so we can write -stop -kill
                # -rm -up for example.
                set operations {}
                if { [utils getopt args -stop] } {
                    lappend operations STOP
                }
                if { [utils getopt args -kill] } {
                    lappend operations KILL
                }
                if { [utils getopt args -rm] } {
                    lappend operations RM
                }
                if { [utils getopt args -up] } {
                    lappend operations UP
                }
                if { [utils getopt args -start] } {
                    lappend operations START
                }
                utils getopt args -options optstr ""
                set copts {}
                foreach odef [split $optstr ","] {
                    foreach {k v} [split $odef "="] {
                        lappend copts [string trim $k] [string trim $v]
                    }
                }
                if { [llength $operations] == 0 } {
                    # Nothing means up!
                    lappend operations UP
                }
                
                foreach fpath $args {
                    foreach op $operations {
                        cluster swarm $master $op $fpath $copts
                    }
                }
            }
        }
        "ps" {
            tooling runtime exit
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "When called with no arguments, this will request the swarm master for a list of components.  When called with arguments, these should be the names of virtual machines and the list of components for each of these machines will be printed out.   Apart from the command options, all arguments to this command should be machine names, as from the YAML description." \
                        {   -help "Print this help" }
            }
            set cluster [init]
            if { [llength $args] == 0 } {
                set master [::cluster::swarm::master $cluster]
                cluster ps $master 1
            } else {
                foreach vm [machines $cluster $args] {
                    cluster ps $vm
                }
            }
        }
        "ls" {
            tooling runtime exit
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "List current machines in cluster and their state" \
                        { -help "Print this help" }
            }
            set cluster [init]
            set state {MACHINE STATE URL MASTER DRIVER MEMORY SIZE}
            set total_memory 0
            set total_size 0
            foreach vm [machines $cluster $args] {
                lappend state [dict get $vm -name]
                if { [dict exists $vm state] } {
                    lappend state [dict get $vm state]
                } else {
                    lappend state Void
                }
                if { [dict exists $vm url] } {
                    lappend state [dict get $vm url]
                } else {
                    lappend state ""
                }
                if { [dict exists $vm -master] && [string is true [dict get $vm -master]] } {
                    lappend state *
                } else {
                    lappend state ""
                }
                lappend state [dict get $vm -driver]
                if { [dict exists $vm -memory] } {
                    set mem [dict get $vm -memory]
                    set mem [utils convert $mem MiB GiB]
                    lappend state ${mem}GiB
                    set total_memory [expr {$total_memory+$mem}]
                } else {
                    lappend state -
                }
                if { [dict exists $vm -size] } {
                    set size [dict get $vm -size]
                    set size [utils convert $size MB GB]
                    lappend state ${size}GB
                    set total_size [expr {$total_size+$size}]
                } else {
                    lappend state -
                }
            }
            if { $total_memory != 0 || $total_size != 0 } {
                lappend state "" "" "" "" "" "======" "======"
                lappend state "" "" "" "" "" \
                        ${total_memory}GiB \
                        ${total_size}GB
            }
            Tabulate 7 $state
        }
        "reinit" {
            tooling runtime exit
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Reinitialise one or several machines (or the whole cluster if no arguments is given).  Apart from the command options, all arguments to this command should be machine names, as from the YAML description." \
                        { -help "Print this help"
                -steps "List of comma separated steps to perform, the steps are named after the YAML description, i.e. registries, compose, images, addendum, etc." }
            }

            # Extract steps to perform, understand both comma-separated lists
            # and clear Tcl-like whitespace lists).
            utils getopt args -steps steps [cluster defaults -steps]
            if { [string first "," $steps] } {
                set steps [split $steps ","]
            }

            set cluster [init]
            set clustering [dict get $cluster -options -clustering]
            foreach vm [machines $cluster $args] {
                if { [string match -nocase "swarm*mode" $clustering] } {
                    cluster init $vm \
                        -steps [cluster steps "worker" $steps] \
                        -masters [Masters $cluster] \
                        -applications [dict get $cluster -applications] \
                        -networks [dict get $cluster -networks]
                } else {
                    cluster init $vm -steps $steps
                }
            }
            if { [string match -nocase "swarm*mode" $clustering] } {
                foreach vm [machines $cluster $args] {
                    cluster init $vm \
                        -steps [cluster steps "manager" $steps] \
                        -masters [Masters $cluster] \
                        -applications [dict get $cluster -applications] \
                        -networks [dict get $cluster -networks]
                }
            }
        }
        "down" -
        "stop" -
        "halt" {
            tooling runtime exit
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Bring down one or several machines (or the whole cluster if no arguments is given).  Apart from the command options, all arguments to this command should be machine names, as from the YAML description." \
                        { -help "Print this help" }
            }
            # Halt one or several machines (or the whole cluster if no
            # arguments)
            set cluster [init]
            set masters [Masters $cluster]
            foreach vm [machines $cluster $args] {
                cluster halt $vm $masters
            }
            ::cluster::swarm::recapture $cluster
        }
        "restart" {
            tooling runtime exit
            # Halt one or several machines (or the whole cluster if no
            # arguments)
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Restart one or several machines (or the whole cluster if no arguments is given).  This is equivalent to calling halt and then start.  Apart from the command options, all arguments to this command should be machine names, as from the YAML description." \
                        { -help "Print this help" }
            }
            set cluster [init]
            set masters [Masters $cluster]
            foreach vm [machines $cluster $args] {
                cluster halt $vm
                cluster start $vm
            }
        }
        "rm" -
        "destroy" {
            tooling runtime exit
            # Destroy one or several machines (or the whole cluster if no
            # arguments).  The machines will be halted before removal.
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Destroy one or several machines (or the whole cluster if no arguments is given).  The machines will be gently halted and before destroyal.  Apart from the command options, all arguments to this command should be machine names, as from the YAML description." \
                        { -help "Print this help" }
            }
            set cluster [init]
            set masters [Masters $cluster]
            foreach vm [machines $cluster $args] {
                cluster destroy $vm $masters
            }
            ::cluster::swarm::recapture $cluster
        }
        "sync" {
            tooling runtime exit
            # Destroy one or several machines (or the whole cluster if no
            # arguments).  The machines will be halted before removal.
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Synchronise rsync-based shared from one or several machines (or the whole cluster if no arguments is given).  Data will move from the machine to the host.  Apart from the command options, all arguments to this command should be machine names, as from the YAML description." \
                        { -help "Print this help"
                -op "Operation to execute: 'get' from VM or 'put' to VM"}
            }
            set cluster [init]
            utils getopt args -op direction "get"
            foreach vm [machines $cluster $args] {
                cluster sync $vm $direction
            }
        }
        "env" {
            tooling runtime exit
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Print out exporting commands to get (discovery) environment of one or several machines (or the whole cluster if no arguments is given).  Apart from the command options, all arguments to this command should be machine names, as from the YAML description." \
                        { -help "Print this help"
                -force "Force recreation of cache" }
            }
            set cluster [init]
            cluster env $cluster [utils getopt args -force] stdout
        }
        "ssh" {
            tooling runtime exit
            # Execute one command in a running virtual machine.  This is
            # mainly an alias to docker-machine ssh.
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "This command takes at least the name of a machine as an argument.  Without any further arguments, it will ssh into the machine, otherwise the remaining of the arguments form a command to execute on the machine.  The name of the machine should be as from the YAML description." \
                        { -help "Print this help" }
            }
            set cluster [init]
            if { [llength $args] == 0 } {
                log ERROR "Need at least the name of a machine"
            }
            set vm [cluster find $cluster [lindex $args 0]]
            set args [lrange $args 1 end]
            if { $vm ne "" } {
                eval [linsert $args 0 cluster ssh $vm]
            }
        }
        "server" {
            tooling runtime exit
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Start a web server providing a REST API to operate on the cluster." \
                        {   -help "Print this help"
                    -port "Port to listen on (default: 8070)"
                    -root "Root directory to serve files from (default: empty==no serving)"
                    -dirlist "Glob-style pattern to allow directories to be listed for content (when serving files)"
                    -logfile "Path to file for logging"
                    -pki "List of paths to two file paths for the public and private keys, will serve using HTTPS when this option exists"
                    -authorization "List of triplets for basic auth protection: glob-style pattern matching directory name at server, realm and list of elements where the username and password of the allowed users are separated by a colon"
                }
            }
            package require api::wapi
            set yaml [resolve pfx]
            # Pass all arguments to the web API service initialisation
            # for maximimum flexibility and so we can benefit from
            # authorisation or HTTPS capabilities.
            wapi server $yaml $pfx {*}$args
            vwait forever;   # Wait forever!
        }
        "search" {
            tooling runtime exit
            # Search for components, arguments are glob-style patterns
            # to match against container names.
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Search for components by their names within the cluster and list them.  This command takes glob-style patterns to match against the component names.  No arguments is the same as providing the pattern *, matching any component name" \
                        { -help "Print this help"
                -restrict "Comma-separated list of patterns for machine subset selection"}
            }
            set cluster [init]
            utils getopt args -restrict subset {}
            set subset [split $subset ","]
            set machines [machines $cluster $subset]
            set locations {}
            if { [llength $args] == 0 } {
                set args [list "*"]
            }
            foreach ptn $args {
                set locations [concat $locations [cluster search $machines $ptn]]
            }
            if { [llength $locations] > 0 } {
                Tabulate 3 [concat MACHINE NAME ID $locations]
            }
        }
        "forall" {
            tooling runtime exit
            # Execute docker commands, first argument is glob-style
            # pattern to match against component name, second is
            # docker command to execute, remaining arguments are
            # options to the docker command.  First argument is
            # optional, so we can run commands that are not bound to
            # components.
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Execute docker command on components in the cluster.  The first argument is a pattern to match against the name of the components within all machines, the second argument is the docker (sub-) command to execute and the remaining arguments are blindly passed to the command at execution time.  The first argument is optional, in which case the docker command and its argument will be executed in all machines as of the -respect option.  For the (rare!) cases where the pattern is also docker command, you can separate the pattern and the command by a double-dash to make these argument types explicit." \
                        { -help "Print this help"
                -restrict "Comma-separated list of patterns for machine subset selection" }
            }
            set cluster [init]
            utils getopt args -restrict subset {}
            set subset [split $subset ","]
            set machines [machines $cluster $subset]
            # When we have a double-dash, it explicitely separates the
            # patterns to match against the component names from the
            # command to execute.  When we don't we peek to see if the
            # first argument is actually the name of a docker command.
            # If it is, then we'll execute that command on no
            # particular components (think commands like pull here).
            set idx [lsearch $args --]
            if { $idx >= 1 } {
                set ptn [lindex $args 0]
                incr idx
                set cmd [lindex $args $idx]
                incr idx
                set cargs [lrange $args $idx end]
            } else {
                if { [lsearch [tooling commands docker] [lindex $args 0]] >= 0 } {
                    set ptn ""
                    set cmd [lindex $args 0]
                    set cargs [lrange $args 1 end]
                } else {
                    foreach {ptn cmd} $args break;  # Extract pattern and command
                    set cargs [lrange $args 2 end]
                }
            }
            cluster forall $machines $ptn $cmd {*}$cargs
        }
        "pack" {
            tooling runtime exit
            # pack to zip file for project transport
            if { [utils getopt args -help] } {
                chelp $cmd \
                        "Pack to zip file for project transport.  Takes the path to a ZIP file as an argument." \
                        { -help "Print this help"
                          -zap "Remove project files once ZIPped. This is irreversible!" }
            }
            set zap [utils getopt args -zap]

            set cluster [init]
            if { [llength $args] } {
                set zipped [cluster pack $cluster [lindex $args 0]]
            } else {
                set zipped [cluster pack $cluster]
            }

            if { $zap } {
                log NOTICE "Removing [llength $zipped] project's related file(s)"
                foreach fpath $zipped {
                    catch { file delete -force -- $fpath }
                }
            }
        }
        default {
            help "$cmd is an unknown command!"
        }
    }
}


####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################


# ::api::cli::Tabulate -- Tabulate list
#
#       Considers the list passed as argument to represent a table of
#       x lines and sz columns and pretty print its content onto a
#       file descriptor by padding all column items with spaces so
#       that the length of the maximum string decides.  The last item
#       in columns is treated slightly differently, as it will be
#       allowed to span several lines (and thus align with the rest)
#       whenever it is too long.
#
# Arguments:
#	sz	Number of columns.
#	lst	Incoming list representing data to tabulate
#	fd	File descriptor to output to
#	pre	String to prepend to each line being output
#	sep	Separator to add between columns.
#
# Results:
#       None.
#
# Side Effects:
#       Output tabulated data.
proc ::api::cli::Tabulate { sz lst { fd stdout } {pre "" } { sep "  "} } {
    # Compute maximum length of each column and put this into list
    # called 'lens' (which will then contain $sz items).
    set lens [lrepeat $sz -1]
    for {set i 0} {$i<[llength $lst]} {incr i $sz} {
        for {set j 0} {$j<$sz} {incr j} {
            set prm [lindex $lst [expr {$i+$j}]]
            set plen [string length $prm]
            set len [lindex $lens $j]
            if { $plen > $len } {
                set lens [lreplace $lens $j $j $plen]
            }
        }
    }
    
    # For each row, append enough spaces to each item and output the
    # whole line one at a time.
    for {set i 0} {$i<[llength $lst]} {incr i $sz} {
        set line $pre
        # Take care of all the first $sz-1 parameters
        if { $sz > 1 } {
            for {set j 0} {$j<$sz-1} {incr j} {
                set prm [lindex $lst [expr {$i+$j}]]
                set len [lindex $lens $j]
                append prm [string repeat " " $len]
                incr len -1;  # Back one to make sure range below works properly
                append line [string range $prm 0 $len]
                append line $sep;
            }
        }
        # Last param
        set indent $pre
        foreach len [lrange $lens 0 end-1] {
            append indent [string repeat " " $len]
            append indent $sep
        }
        set prm [lindex $lst [expr {$i+$sz-1}]]
        set remaining [expr {$vars::justify-[string length $indent]}]
        if { $remaining < 10 } { set remaining $vars::justify }
        if { [string length $prm] > $remaining } {
            set plines [split [Justify $prm $remaining] \n]
            append line [lindex $plines 0]
            puts $fd [string trimright $line]
            foreach l [lrange $plines 1 end] {
                set line $indent
                append line $l
                puts $fd [string trimright $line]
            }
        } else {
            append line $prm
            puts $fd [string trimright $line]
        }
    }
}


# ::api::cli::Config -- Read configuration file
#
#       Read the configuration file passed as an argument and modify
#       the global options stored in the vars sub-namespace to reflect
#       the values read from the file.  In the file, empty lines are
#       ignored, as well as lines starting with a #-sign.  Otherwise
#       they should contain a key and value in tcl-parsable format.
#       The key does not need to be led by a dash, this will be
#       automatically added, so as to increase readability of the
#       file.
#
# Arguments:
#	fname	Path to file
#
# Results:
#       The list of options that were read from the file, dash-led.
#
# Side Effects:
#       None.
proc ::api::cli::Config {fname} {
    set configured {}
    set fd [open $fname];   # Fail with errors on purpose
    while {![eof $fd]} {
        set line [string trim [gets $fd]]
        if { $line ne "" && [string index $line 0] ne "\#" } {
            foreach {opt val} $line break
            set opt [string trimleft $opt -]
            if { [info exists vars::-$opt] } {
                set vars::-$opt $val
                lappend configured -$opt
            } else {
                help "-$opt (from $fname) is not a known option!"
            }
        }
    }
    close $fd
    
    return $configured
}


# ::api::cli::Justify -- Justify text
#
#       Quick and dirty code justification, the code originates from
#       http://wiki.tcl.tk/1774.  This does not check for line breaks
#       in the text, and other corner cases.
#
# Arguments:
#	text	(long) text to justify
#	width	Max width of lines.
#
# Results:
#       Return several lines separated by the line break.
#
# Side Effects:
#       None.
proc ::api::cli::Justify {text {width 72}} {
    for {set result {}} {[string length $text] > $width} {
        set text [string range $text [expr {$brk+1}] end]
    } {
        set brk [string last " " $text $width]
        if { $brk < 0 } {set brk $width}
        append result [string trim [string range $text 0 $brk]] \n
    }
    return $result$text
}


proc ::api::cli::Masters { cluster }  {
    set masters [list]
    if { [string match -nocase "swarm*mode" [dict get $cluster -options -clustering]] } {
        set masters [swarmmode masters $cluster]
    }
    return $masters    
}

package provide api::cli 0.2

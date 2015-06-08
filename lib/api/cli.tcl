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

namespace eval ::api::cli {
    namespace eval vars {
	# All global options recognised by the main program are
	# described here.  Note that once these options have been
	# parsed, there will be variables populating the vars
	# sub-namespace with the final values of the variables.  The
	# variables will have the same name as the options, including
	# the leading dash.
	variable gopts {
	    -help      ""               "Print this help and exit"
	    -verbose   5                "Verbosity level \[0-6\]"
	    -machine   "docker-machine" "Path to docker-machine"
	    -docker    "docker"         "Path to docker"
	    -compose   "docker-compose" "Path to docker-compose"
	    -token     ""               "Override token for cluster"
	    -cluster   ""               "YAML description, empty for cluster.yml"
	    -driver    "virtualbox"     "Default driver for VM creation"
	    -cache     "on"             "Use locally cached docker images?"
	    -ssh       ""               "SSH command to use into host, dynamic replacement of %-surrounded keys will happen, e.g. ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectionAttempts=30 -o LogLevel=quiet -p %port% -i %identity% %user%@%host%.  Empty to guess."
	    -config    ""               "Path to config file, command-line arguments will override configure content"
	}
        # This is the list of recognised commands that will be print
        # when help is requested.
        variable cmds {
            up      "Create and bring up cluster and/or specific machines"
            halt    "Bring down cluster and/or specific machines"
            token   "Create (new) swarm token, force regeneration with -force"
            destroy "Destroy cluster and/or specific machines"
            restart "Restart whole cluster and/or specific machines"
            env     "Export environment variables for discovery"
            reinit  "Rerun finalisation stages on machine(s), specify via -step"
            swarm   "Lifecycle management of components via swarm"
            sync    "One shot synchronisation of rsync shares"
            forall  "Execute docker command on all matching containers"
            search  "Search for matching containers"
        }
	
	variable appname "";          # Name of main application.
	variable version 0.6-dev;     # GLOBAL Application version!
	variable yaml "";             # The cluster YAML file we ended up using!
	variable default "./cluster.yml"
    }
    
    namespace export {[a-z]*};         # Convention: export all lowercase 
    namespace path [namespace parent]; # DANGER: Be aware of similar names!
    namespace ensemble create -command ::cli
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
    puts $fd "\t${vars::appname} -\
          Cluster creation and management via docker, machine, compose and swarm"
    puts $fd ""
    puts $fd "USAGE"
    puts $fd "\t${vars::appname} \[global options\] command \[command options\] \[arguments...\]"
    puts $fd ""
    puts $fd "VERSION"
    puts $fd "\t${vars::version}"
    puts $fd ""
    puts $fd "COMMANDS:"
    Tabulate 2 $vars::cmds $fd "\t"
    puts $fd ""
    puts $fd "GLOBAL OPTIONS:"
    # Rewrite option descriptions, tabulate nicely and output
    set optout {}
    foreach { arg val dsc } $vars::gopts {
        lappend optout $arg "$dsc (default: $val)"
    }
    Tabulate 2 $optout $fd "\t"
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
    # XXX: There might be problems if the options to the commands end
    # up being the same as global options.  One way to ensure proper
    # parsing would be to recognise the -- separator, but as long as
    # options to the commands do not overlap, the following
    # implementation is safe.

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

    # Did we request for help? Output and goodbye
    if { [cluster getopt argv "-help"] } {
	help
    }

    # Do we have a configure file to read, do this at once.
    cluster getopt argv -config vars::-config ${vars::-config}
    if { ${vars::-config} ne "" } {
	Config ${vars::-config}
    }


    # Eat all program options from the command line, the latest value
    # will be the one as we don't have options that can appear several
    # times.
    for {set eaten ""} {$eaten ne $argv} {} {
	set eaten $argv
	foreach opt [info vars vars::-*] {
	    set opt [lindex [split $opt ":"] end]
	    cluster getopt argv $opt vars::$opt [set vars::$opt]
	}
    }

    # Pass arguments from the command-line as the defaults for the cluster
    # module.
    foreach k [list -machine -docker -compose -verbose -cache -ssh] {
	cluster defaults $k [set vars::$k]
    }

    # No Arguments remaining?? dump help and exit since we need a command
    # to know what to really do...
    if { [llength $argv] <= 0 } {
	help "No command specified!"
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
    foreach {k v} $args {
        set k -[string trimleft $k -]
        if { [info exists vars::$k] } {
            set vars::$k $v
        }
    }
    
    set state {}
    foreach v [info vars vars::-*] {
	lappend state [lindex [split $v ":"] end] [set $v]
    }
    return $state
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

    # Default to value from global options if nothing specified.
    if { $fname eq "" } {
	set fname ${vars::-cluster}
    }

    # Set the prefix and filename depending on the filename that we
    # ended up picking.
    if { $fname eq "" } {
	set pfx ""
	set fname ${vars::default}
    } else {
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
		     -prefix $pfx -driver ${vars::-driver}} vms] } {
	help $vms
    }
    return $vms
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
    set vms [yaml $vars::yaml $pfx]

    # Recap with current state of cluster as seen from docker-machine
    # and arrange for <cluster> to be the list of virtual machine
    # descriptions that represent the whole cluster that we should
    # operate on.
    set cluster {}
    set state [cluster ls]
    foreach vm $vms {
	lappend cluster [cluster bind $vm $state]
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
#	cluster		Cluster to select from (i.e. list of VM dicts).
#	shortnames	List of names to select within cluster, empty for all.
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
	set vm [cluster find $cluster $nm]
	if { $vm ne "" } {
	    lappend machines $vm
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
proc ::api::cli::up { vm token } {
    if { [dict exists $vm state] } {
	if { ![string equal -nocase [dict get $vm state] "running"] } {
	    cluster start $vm
	}
    } else {
	cluster create $vm $token
    }
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
	    puts stdout [version]
	}
	"help" {
	    cli help
	}
	"token" {
	    set cluster [init]
	    puts stdout [token [cluster getopt args -force]]
	}
	"start" -
	"up" {
	    # Start up one or several machines (or the whole cluster if no
	    # arguments), the machines will be created if they did not
	    # exists
	    set cluster [init]
	    set token [token]
	    foreach vm [machines $cluster $args] {
		up $vm $token
	    }
	}
	"swarm" {
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
		if { [cluster getopt args -stop] } {
		    lappend operations STOP
		}
		if { [cluster getopt args -kill] } {
		    lappend operations KILL
		}
		if { [cluster getopt args -rm] } {
		    lappend operations RM
		}
		if { [cluster getopt args -up] } {
		    lappend operations UP
		}
		if { [cluster getopt args -start] } {
		    lappend operations START
		}
		cluster getopt args -options optstr ""
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
	"reinit" {
	    set cluster [init]
	    cluster getopt args -steps steps "registries,images,compose"
	    if { [string first "," $steps] } {
		set steps [split $steps ","]
	    }

	    foreach vm [machines $cluster $args] {
		cluster init $vm $steps
	    }
	}
	"down" -
	"stop" -
	"halt" {
	    # Halt one or several machines (or the whole cluster if no
	    # arguments)
	    set cluster [init]
	    foreach vm [machines $cluster $args] {
		cluster halt $vm
	    }
	}
	"restart" {
	    # Halt one or several machines (or the whole cluster if no
	    # arguments)
	    set cluster [init]
	    foreach vm [machines $cluster $args] {
		cluster halt $vm
		cluster start $vm
	    }
	}
	"rm" -
	"destroy" {
	    # Destroy one or several machines (or the whole cluster if no
	    # arguments).  The machines will be halted before removal.
	    set cluster [init]
	    foreach vm [machines $cluster $args] {
		cluster destroy $vm
	    }
	}
	"sync" {
	    # Destroy one or several machines (or the whole cluster if no
	    # arguments).  The machines will be halted before removal.
	    set cluster [init]
	    foreach vm [machines $cluster $args] {
		cluster sync $vm
	    }
	}
	"env" {
	    set cluster [init]
	    cluster env $cluster [cluster getopt args -force] stdout
	}
	"ssh" {
	    # Execute one command in a running virtual machine.  This is
	    # mainly an alias to docker-machine ssh.
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
	    package require api::wapi
	    set yaml [resolve pfx]
	    # Pass all arguments to the web API service initialisation
	    # for maximimum flexibility and so we can benefit from
	    # authorisation or HTTPS capabilities.
	    wapi server $yaml $pfx {*}$args
	    vwait forever;   # Wait forever!
	}
	"search" {
            # Search for components, arguments are glob-style patterns
            # to match against container names.
	    set cluster [init]
	    set locations {}
	    foreach ptn $args {
		set locations [concat $locations [cluster search $cluster $ptn]]
	    }
	    if { [llength $locations] > 0 } {
		Tabulate 3 [concat MACHINE NAME ID $locations]
	    }
	}
	"forall" {
            # Execute docker commands, first argument is glob-style
            # pattern to match against component name, second is
            # docker command to execute, remaining arguments are
            # options to the docker command.
	    set cluster [init]
	    if { [llength $args] >= 2 } {
                foreach {ptn cmd} $args break;  # Extract pattern and command
		cluster forall $cluster $ptn $cmd {*}[lindex $args 2 end]
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
#       that the length of the maximum string decides.
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
proc ::api::cli::Tabulate { sz lst { fd stdout } {pre "" } { sep " "} } {
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
	for {set j 0} {$j<$sz} {incr j} {
	    set prm [lindex $lst [expr {$i+$j}]]
	    set len [lindex $lens $j]
	    incr len -1;  # Back one to make sure range below works properly
	    append prm [string repeat " " $len]
	    append line [string range $prm 0 $len]
	    if { $j<[expr {$sz-1}] } {
		append line $sep;  # Add separator unless last element.
	    }
	}
	puts $fd [string trimright $line]
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


package provide api::cli 0.1

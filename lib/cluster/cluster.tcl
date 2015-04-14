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
package require yaml;   # This is found in tcllib
package require cluster::virtualbox

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
				 ports shares}
	# Path to docker executables
	variable -machine   docker-machine
	variable -docker    docker
	# Current verbosity level
	variable -verbose   NOTICE
	# Location of boot2docker profile
	variable -profile   /var/lib/boot2docker/profile
	# Mapping from integer to string representation of verbosity levels
	variable verboseTags {1 CRITICAL 2 ERROR 3 WARN 4 NOTICE 5 INFO 6 DEBUG}
	# Extension for token storage files
	variable -ext       .tkn
	# File descriptor to dump log messages to
	variable -log       stderr
	# Date log output
	variable -date      "%Y%m%d %H%M%S"
    }
    # Automatically export all procedures starting with lower case and
    # create an ensemble for an easier API.
    namespace export {[a-z]*}
    namespace ensemble create
}


# ::cluster::defaults -- Set default parameters
#
#       This procedure takes an even list of keys and values used to
#       set the values of the options supported by the library.  The
#       list of options is composed of all variables starting with a
#       dash in the vars sub-namespace.  In the list, the dash
#       preceding the key is optional.
#
# Arguments:
#	args	List of key and values to set for module options.
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::defaults { args } {
    foreach {k v} $args {
	set k -[string trimleft $k -]
	if { [info exists vars::$k] } {
	    set vars::$k $v
	}
    }
}

# ::cluster::getopt -- Quick and Dirty Options Parser
#
#       Parses options, code comes from wiki.  Once parsed, an option
#       (and its argument) are removed from the argument list.
#
# Arguments:
#	_argv	List of arguments to parse
#	name	Name of option to look for.
#	_var	Pointer to variable in which to store value
#	dft	Default value if not found
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
#       either be an integer or one of CRITICAL ERROR WARN NOTICE INFO
#       DEBUG, where CRITICAL corresponds to level 1 and DEBUG to
#       level 6.  Level 0 will therefor turn off ALL debugging.
#       Logging happens on the standard error, but this can be changed
#       through the -log option to the module.  Logging is pretty
#       printed using ANSI codes when the destination channel is a
#       terminal.
#
# Arguments:
#	lvl	Logging level of the message
#	msg	String content of the message.
#
# Results:
#       None.
#
# Side Effects:
#       Output message to logging channel whenever at the proper level.
proc ::cluster::log { lvl msg } {
    # Convert incoming level from string to integer.
    set lvl [LogLevel $lvl]
    # Convert module level from string to integer.
    set current [LogLevel ${vars::-verbose}]
    # If we should output (i.e. level of message is below the global
    # module level), pretty print and output.
    if { ${vars::-verbose} >= $lvl } {
	set toTTY [dict exists [fconfigure ${vars::-log}] -mode]
	# Output the whole line.
	if { $toTTY } {	
	    puts ${vars::-log} [LogTerminal $lvl $msg]
	} else {
	    puts ${vars::-log} [LogStandard $lvl $msg]
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
#	machines	glob-style pattern to match on machine names
#
# Results:
#       Return a list of dictionaries, one dictionary for the stat of
#       each machine which name matches the argument.
#
# Side Effects:
#       None.
proc ::cluster::ls { {machines *} } {
    set cluster {};   # The list of dictionaries we will return

    # Get current state of cluster and arrange for cols to be the list
    # of keys (this is the first line of docker-machine ls output,
    # meaning the header).
    set state [Run -return -- ${vars::-machine} ls]
    set cols [lindex $state 0]
    # Arrange for indices to contain the character index at which each
    # column of the output starts (in same order as the list of keys
    # above).
    set indices {}
    foreach c $cols {
	lappend indices [string first $c $cols]
    }

    # Now loop through all lines of the output, i.e. the complete
    # state of the cluster.
    foreach m [lrange $state 1 end] {
	# Isolate the content of each keys, respecting the column
	# alignment found in <indices> and the order of the columns.
	for {set c 0} {$c<[llength $cols]} {incr c} {
	    set k [lindex $cols $c];   # Extract the key
	    # Extract its value, i.e. the characters between where the
	    # key started in the header up to the character before
	    # where the next key started in the header.
	    if { $c < [expr [llength $cols]-1] } {
		set end [lindex $indices [expr {$c+1}]]
		incr end -1
	    } else {
		set end "end"
	    }
	    # The value is inbetween those ranges, trim to get rid of
	    # trailing spaces that had been added for a nice output.
	    set v [string range $m [lindex $indices $c] $end]
	    dict set nfo [string trim [string tolower $k]] [string trim $v]
	}
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
#	cluster	List of machine description dictionaries.
#
# Results:
#       List of names
#
# Side Effects:
#       None.
proc ::cluster::names { cluster } {
    set names {}
    foreach vm $cluster {
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
#	cluster	List of machine description dictionaries.
#	name	Name of machine to look for.
#
# Results:
#       Full dictionary description of machine.
#
# Side Effects:
#       None.
proc ::cluster::find { cluster name } {
    foreach vm $cluster {
	set nm [dict get $vm -name]
	# Lookup with proper name
	if { $name eq $nm } {
	    return $vm
	}
	# Lookup the separator separating the prefix from the machine
	# name and match on the name.
	set sep [string first ${vars::-separator} $nm]
	if { $sep >= 0 } {
	    incr sep [string length ${vars::-separator}]
	    if { [string range $nm $sep end] eq $name } {
		return $vm
	    }
	}
    }
    return {}
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
#	vm	Virtual machine description
#	ls	Live cluster description. If -, will be actualised.
#
# Results:
#       A new virtual machine description dictionary.
#
# Side Effects:
#       None.
proc ::cluster::bind { vm {ls -}} {
    # Get current status of cluster.
    if { $ls eq "-" } {
	set ls [ls]
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
		    if { [dict get $m active] eq "" } {
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

    # Return the new modified dictionary.
    return $vm
}


# ::cluster::create -- Create a machine
#
#       Create, tag (if necessary) and verify a virtual machine.
#
# Arguments:
#	vm	Dictionary description of machine (as of YAML parsing)
#	token	Swarm token to use.
#
# Results:
#       The name of the machine on success, empty string otherwise.
#
# Side Effects:
#       None.
proc ::cluster::create { vm token } {
    # Create machine
    set nm [Create $vm $token]

    if { $nm ne "" } {
	# Tag virtual machine with labels.
	tag $vm

	# Open the ports and creates the shares
	set vm [bind $vm]
	ports $vm
	shares $vm
    
	# Test that machine is properly working by echoing its name
	# using a busybox component and checking we get that name
	# back.
	log DEBUG "Testing that machine $vm has a working docker via busybox"
	Attach $vm
	if { [Run -return -- ${vars::-docker} run --rm busybox \
		  echo $nm] eq "$nm" } {
	    log INFO "Docker setup properly on $nm"
	} else {
	    log ERROR "Cannot test docker for $nm, check manually!"
	}
    }

    return $nm
}


# ::cluster::scp -- Copy local file into machine.
#
#       Copy a local file into a virtual machine.  The scp command is
#       dynamically generated out of the ssh command that is used by
#       docker-machine to enter the VM.  We detect that by putting
#       docker-machine in debug mode and try running a command in the
#       machine using docker-machine ssh.
#
# Arguments:
#	vm	Virtual machine description dictionary
#	src_fn	Full path to source.
#	dst_fn	Full path to destination (empty to same as source)
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::scp { vm src_fname { dst_fname "" } } {
    # Make destination identical to source if necessary.
    if { $dst_fname eq "" } {
	set dst_fname $src_fname
    }

    set nm [dict get $vm -name]
    log NOTICE "Copying local $src_fname to ${nm}:$dst_fname"

    # Guess raw SSH command by running ssh-ing "echo" into the virtual
    # machine.  This assumes docker-machine output the ssh command
    # onto the stderr.
    log DEBUG "Detecting SSH command into $nm"
    set sshinfo [Run -return -stderr -- ${vars::-machine} --debug \
		     ssh $nm echo ""]
    set ssh [string first ssh $sshinfo];  # Lookup the string 'ssh': START
    set echo [string last echo $sshinfo]; # Lookup the string 'echo': END
    set cmd [string trim [string range $sshinfo $ssh [expr {$echo-1}]]]

    # Construct an scp command out of the ssh command!  This converts
    # the arguments between the ssh and scp namespaces, which are not
    # exactly the same.
    set cmd [regsub ^ssh $cmd scp]
    set cmd [regsub -- -p $cmd -P]
    foreach { m k v } [regexp -all -inline -- {-o\s+(\w*)\s+(\w*)} $cmd] {
	set cmd [string map [list $m "-o ${k}=${v}"] $cmd]
    }
    set dst [lindex $cmd end];   # Extract out user@hostname, last in
				 # (ssh)command
    set scp [lrange $cmd 0 end-1]
    log DEBUG "Constructed command $scp, destination: $dst"
    
    # Finalise the scp command by adding file paths information and
    # execute it.
    lappend scp $src_fname ${dst}:$dst_fname
    eval [linsert $scp 0 Run]
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
#	vm	Virtual machine description dictionary
#	lbls	Even long list of keys and values: the labels to set.
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
	    return
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
    # empty lines.  The result is an array.
    log DEBUG "Getting current boot2docker profile"
    foreach l [Run -return -- ${vars::-machine} ssh $nm \
		   cat ${vars::-profile}] {
	set l [string trim $l]
	if { $l ne "" && [string index $l 0] ne "\#" } {
	    set equal [string first "=" $l]
	    set k [string range $l 0 [expr {$equal-1}]]
	    set v [string range $l [expr {$equal+1}] end]
	    set DARGS($k) [string trim $v "'\""]; # Trim away quotes
	}
    }
    
    # Append labels to EXTRA_ARGS index in the array.  Maybe should we
    # parse for their existence before?
    foreach {k v} $lbls {
	append DARGS(EXTRA_ARGS) " --label=${k}=${v}"
    }

    # Create a local temporary file with the new content.  This is far
    # from perfect, but should do as we are only creating one file and
    # will be removing it soon.
    set fname [Temporary /tmp/profile]
    set fd [open $fname w]
    foreach a [array names DARGS] {
	if { [string first " " $DARGS($a)] >= 0 } {
	    puts $fd "$a='$DARGS($a)'"
	} else {
	    puts $fd "$a=$DARGS($a)"
	}
    }
    close $fd

    # Copy new file to same place (assuming /tmp is a good place!) and
    # install it for reboot.
    scp $vm $fname
    Run ${vars::-machine} ssh $nm sudo mv $fname ${vars::-profile}

    # Cleanup and restart machine to make sure the labels get live.
    file delete -force -- $fname;      # Remove local file, not needed anymore
    Run ${vars::-machine} restart $nm; # Restart machine to activate tags
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
#	vm	Virtual machine description dictionary
#	ports	List of port forwardings, empty to use the list from the
#               VM description
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
    set pspec ""
    foreach {host mchn proto} $opening {
	append pspec "${host}->${mchn}/$proto "
    }
    log NOTICE "Port forwarding for $nm as follows: [string trim $pspec]"

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
#       This procedure will arrange for shares to be mounted between
#       the host machine and the guest machine.  This is only
#       implemented on top of the virtualbox driver at present.
#
#       The format of the list of shares is understood as follows.  A
#       single path will be shared at the same location than the host
#       within the guest.  A share specification can also be a pair
#       (i.e. a list itself!)  composed of a host path and a guest
#       path.  Finally, a share specification can also have the form
#       host:guest where host and guest should the path on the local
#       host and where to mount it on the guest.
#
# Arguments:
#	vm	Virtual machine description dictionary
#	shares	List of share mounts, empty to use the list from the
#               VM description
#
# Results:
#       None.
#
# Side Effects:
#       Will use the Virtual box commands to request for port
#       forwarding.
proc ::cluster::shares { vm { shares {}} } {
    # Get shares, either from parameters (overriding the VM object) or
    # from vm object.
    if { [string length $shares] == 0 } {
	if { ![dict exists $vm -shares] } {
	    return
	}
	set shares [dict get $vm -shares]
    }

    # Convert xx:yy constructs to pairs of shares, convert single
    # shares to two shares (the same) and append all these pairs to
    # the list called opening.  Arrange for the list to only contain
    # resolved shares as we allow for environment variable resolution
    set opening {}
    foreach spec $shares {
	set spec [Shares $spec];   # Extraction and syntax check
	if { [llength $spec] > 0 } {
	    foreach {host mchn} $spec break
	    lappend opening $host $mchn
	}
    }
    
    # Some nic'ish ouput of the shares and what we do.
    set nm [dict get $vm -name]
    set spec ""
    foreach {host mchn} $opening {
	append spec "${host}->${mchn} "
    }
    log NOTICE "Mounting shares as follows for $nm: [string trim $spec]"
    
    switch [dict get $vm -driver] {
	"virtualbox" {
	    # Add shares as necessary.  This might halt the virtual
	    # machine if they do not exist yet, so we gather their
	    # names together with host and guest path information in a
	    # new list called sharing.  This allows us to halt the
	    # machine as little as possible.
	    set sharing {}
	    foreach {host mchn} $opening {
		set share [virtualbox::addshare $nm $host]
		if { $share ne "" } {
		    lappend sharing $host $mchn $share
		}
	    }

	    # Now start virtual machine as we will be manipulating the
	    # runtime state of the machine.  This should only starts
	    # the machines if it is not running already.
	    start $vm

	    # And arrange for the destination directories to exist
	    # within the guest and perform the mount.
	    foreach {host mchn share} $sharing {
		Run ${vars::-machine} ssh $nm "sudo mkdir -p $mchn"
		Run ${vars::-machine} ssh $nm \
		    "sudo mount -t vboxsf $share $mchn"
	    }
	}
	default {
	    log WARN "Cannot mount shares with driver [dict get $vm -driver]"
	}
    }
}


# ::cluster::halt -- Halt a virtual machine
#
#       Halt a virtual machine by first trying to stop it gently, and
#       then killing it entirely if the shutdown operation had not
#       worked properly.
#
# Arguments:
#	vm	Virtual machine description
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::halt { vm } {
    set nm [dict get $vm -name]
    log NOTICE "Bringing down machine $nm..."
    # First attempt to be gentle against the machine, i.e. using the
    # stop command of docker-machine.
    if { [dict exists $vm state] \
	     && [string equal -nocase [dict get $vm state] "running"] } {
	log INFO "Attempting graceful shutdown of $nm"
	Run ${vars::-machine} stop $nm
    }
    # Ask state of cluster again and if the machine still isn't
    # stopped, force a kill.
    set state [ls $nm]
    if { [dict exists $state state] \
	     && ![string equal -nocase [dict get $vm state] "stopped"] } {
	log NOTICE "Forcing stop of $nm"
	Run ${vars::-machine} kill $nm
    }
}


# ::cluster::ssh -- Execute command in machine
#
#       This procedure will print out the result of a command executed
#       in the VM on the standard output.
#
# Arguments:
#	vm	Virtual machine description
#	args	Command to execute.
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
	set res [eval [linsert $args 0 Run -return -keepblanks -- \
			   ${vars::-machine} ssh $nm]]
	foreach l [lrange $res 0 end-1] {
	    puts stdout $l
	}
	if { [string trim [lindex $res end]] ne "" } {
	    puts stdout [lindex $res end]
	}
    } else {
	# NYI
    }
}


# ::cluster::destroy -- Destroy a machine
#
#       This procedure will irrevocably destroy a virtual machine from
#       the cluster.  This will halt the machine before destroying it.
#
# Arguments:
#	vm	Virtual machine description
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::destroy { vm } {
    halt $vm
    set nm [dict get $vm -name]
    log NOTICE "Removing machine $nm..."
    Run ${vars::-machine} rm $nm
}


# ::cluster::start -- Bring up a machine
#
#       This procedure will start a virtual machine from the cluster.
#
# Arguments:
#	vm	Virtual machine description
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::start { vm } {
    set nm [dict get $vm -name]
    log NOTICE "Bringing up machine $nm..."
    Run ${vars::-machine} start $nm
}


# ::cluster::master -- Master description
#
#       This procedure looks up the swarm master out of a cluster
#       description and returns its vm description.
#
# Arguments:
#	cluster	List of machine description dictionaries.
#
# Results:
#       Virtual machine description of swarm master, empty if none.
#
# Side Effects:
#       None.
proc ::cluster::master { cluster } {
    foreach vm $cluster {
	if { [dict exists $vm -master] } {
	    if { [string is true [dict get $vm -master]] } {
		return $vm
	    }
	}
    }
    return {}
}


# ::cluster::token -- Generate a token
#
#       This procedure will generate a swarm token cluster if
#       necessary and return it.  The token is stored in a hidden file
#       under the same directory as the YAML description file, and
#       with the .tkn extension.  When the token needs to be
#       generated, this is done through the creation of a temporary
#       virtual machine.
#
# Arguments:
#	yaml	Path to YAML description for cluster
#	force	Force token (re)generation
#	driver	Driver to use for token generation
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::token { yaml { force 0 } { driver virtualbox } } {
    set token ""

    # Generate file name for token caching out of yaml path.
    set rootname [file rootname [file tail $yaml]]
    set dirname [file dirname $yaml]
    set tkn_path [file join $dirname \
		      ".$rootname.[string trimleft ${vars::-ext} .]"]

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
#	fname	Path to YAML description
#	args	List of dash-led options and arguments, see above.
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

    set vms {}
    set master ""
    set d [::yaml::yaml2dict -file $fname]
    foreach m [dict keys $d] {
	# Create vm "object" with proper name, i.e. using the prefix.
	if { $pfx eq "" } {
	    set vm [dict create -name $m]
	} else {
	    set vm [dict create -name ${pfx}${vars::-separator}$m]
	}

	# Check validity of keys and insert them as dash-led.  Arrange
	# for one master only.
	foreach k [dict keys [dict get $d $m]] {
	    if { [lsearch ${vars::-keys} $k] < 0 } {
		log WARN "In $m, key $k is not recognised!"
	    } else {
		dict set vm -$k [dict get $d $m $k]
		if { $k eq "master" } {
		    if { $master eq "" } {
			set master [dict get $vm -name]
		    } else {
			if { [string is true [dict get $vm -master]] } {
			    log WARN "There can only be one master,\
                                      keeping $master as the master"
			    dict set vm -master 0
			}
		    }
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

    return $vms
}



####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################

# ::LogLevel -- Convert log levels
#
#       For convenience, log levels can also be expressed using
#       human-readable strings.  This procedure will convert from this
#       format to the internal integer format.
#
# Arguments:
#	lvl	Log level (integer or string).
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


# ::cluster::+ -- Implements ANSI colouring codes.
#
#       Output ANSI colouring codes, inspired by wiki code at
#       http://wiki.tcl.tk/1143.
#
# Arguments:
#	args	List of colouring and effects to apply
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
#	vm	Virtual machine description
#	token	Swarm token for machine, empty for no swarm in machine.
#
# Results:
#       Return the name of the machine, empty string on errors.
#
# Side Effects:
#       None.
proc ::cluster::Create { vm { token "" } } {
    set nm [dict get $vm -name]
    log NOTICE "Creating machine $nm"

    # Start creating a command that we will be able to call for
    # machine creation: first insert creation command with proper
    # driver.
    set driver [dict get $vm -driver]
    set cmd [list ${vars::-machine} create -d $driver]

    # Now translate the standard memory (in MB), size (in MB) and cpu
    # (in numbers) options into options that are specific to the
    # drivers.

    # Memory size is in MB
    if { [dict exists $vm -memory] } {
	array set MOPT {
	    softlayer --softlayer-memory
	    hyper-v --hyper-v-memory
	    virtualbox --virtualbox-memory
	    vmwarefusion --vmwarefusion-memory-size
	    vmwarevcloudair --vmwarevcloudair-memory-size
	    vmwarevsphere --vmwarevsphere-memory-size
	}
	if { [info exist MOPT($driver)] } {
	    lappend cmd $MOPT($driver) [dict get $vm -memory]
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
	}
	set found 0
	foreach { p opt mult } $SOPT {
	    if { $driver eq $p } {
		lappend cmd $opt [expr {[dict get $vm -size]*$mult}]
		set found 1
		break
	    }
	}
	if {! $found} {
	    log WARN "Cannot set disk size for driver $driver!"
	}
    }
    # Blindly append driver specific options, if any
    if { [dict exists $vm -options] } {
	dict for {k v} [dict get $vm -options] {
	    lappend cmd --[string trimleft $k "-"] $v
	}
    }

    # Take care of swam.  Turn it on in the first place, and recognise
    # the key master (and request for a swarm master when it is on).
    if { $token ne "" } {
	lappend cmd --swarm --swarm-discovery token://$token
    }
    if { [dict exists $vm -master] } {
	if { $token ne "" } {
	    if { [string is true [dict get $vm -master]] } {
		lappend cmd --swarm-master
	    }
	} else {
	    log WARM "Swarm is turned off for this machine,\
                      cannot understand 'master'"
	}
    }

    # Finalise command by adding to it the name of the machine that we
    # want to create and run it.
    lappend cmd $nm
    eval [linsert $cmd 0 Run]

    # Test SSH connection by echoing the name of the machine in the
    # machine using ssh.  This seems to be necessary to make
    # docker-machine happy, but is also a "good thing to check" (TM).
    log DEBUG "Testing SSH connection to $nm"
    if { [Run -return -- ${vars::-machine} ssh $nm echo "$nm"] eq "$nm" } {
	log INFO "SSH to $nm working properly"
    } else {
	log CRITICAL "Cannot log into $nm!"
	return ""
    }

    return [dict get $vm -name]
}


# ::cluster::Run -- Run command
#
#       Run an external (local!) command and possibly capture its
#       output.  The commands is followed of all the arguments placed
#       after --, meaning that all dash-led options before the -- are
#       options to this procedure.  These options are as follows:
#       -return     Return result of command instead: list of (non-empty) lines
#       -keepblanks Keep blank lines (default is to omit them)
#       -stderr     Also capture standard error.
#
#       When output of the command should simply be shown, we do some
#       extra extraction and parsing work on the output of
#       docker-machine and output at the log level INFO (but maybe
#       could we translate between log levels?)
#
# Arguments:
#	args	(Optional dash-led options, followed by --) and command
#               to execute.
#
# Results:
#       Result of command
#
# Side Effects:
#       Run local command and (possibly) show its output.
proc ::cluster::Run { args } {
    set ret {}

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

    # Extract some options and start building the pipe.  As we want to
    # capture output of the command, we will be using the Tcl command
    # "open" with a file path that starts with a "|" sign.
    set keep [getopt opts -keepblanks]
    set back [getopt opts -return]
    set pipe |[concat $args]
    if { [getopt opts -stderr] } {
	append pipe " 2>@1"
    }

    log DEBUG "Running $pipe"
    set fd [open $pipe]
    while {![eof $fd]} {
	set line [gets $fd]
	set outlvl INFO
	# Parse and analyse output of docker-machine. Do some
	# translation of the loglevels between logrus and our internal
	# levels.
	if { [lindex $args 0] eq ${vars::-machine} } {
	    foreach {k v} [string map {"=" " "} $line] {
		if { $k eq "msg" } {
		    set line $v
		    break
		}
		# Translate between loglevels from logrus to internal
		# levels.
		if { $k eq "level" } {
		    foreach { gl lvl } [list info INFO \
					    warn NOTICE \
					    error WARN \
					    fatal ERROR \
					    panic CRITICAL] {
			if { [string equal -nocase $v $gl] } {
			    set outlvl $lvl
			}
		    }
		}
	    }
	}
	# Respect -keepblanks and output or accumulate in result
	if { ( !$keep && [string trim $line] ne "") || $keep } {
	    if { $back } {
		log DEBUG "Appending $line to result"
		lappend ret $line
	    } else {
		log $outlvl "  $line"
	    }
	}
    }
    catch {close $fd}
    return $ret
}


# ::cluster::Attach -- Attach to vm
#
#       Attach to a (running) virtual machine.  This will set the
#       necessary environment variables so that the next call to
#       "docker" will connect to the proper machine.  We perform a
#       simplistic parsing of the output of "docker-machine env" for
#       this purpose.
#
# Arguments:
#	vm	Virtual machine description dictionary
#	swarm	Contact swarm master?
#
# Results:
#       None.
#
# Side Effects:
#       Modify current environment so as to be able to pass it further
#       to docker on next call.
proc ::cluster::Attach { vm { swarm 0 } } {
    set nm [dict get $vm -name]
    log INFO "Attaching to $nm"
    if { $swarm } {
	set cmd [list ${vars::-machine} env --swarm $nm]
    } else {
	set cmd [list ${vars::-machine} env $nm]
    }
    foreach l [eval [linsert $cmd 0 Run -return --]] {
	foreach {k v} [split [string map [list "export " ""] $l] "="] {
	    set ::env($k) $v
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
    log INFO "Detaching from vm..."
    foreach e [list TLS_VERIFY CERT_PATH HOST] {
	if { [info exists ::env(DOCKER_$e)] } {
	    unset ::env(DOCKER_$e)
	}
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
#	pspec	Port forwarding specification, see above
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
	    set proto [string range [expr {$slash+1}] end]
	    set pspec [string range 0 [expr {$slash-1}]]
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
#	arg1	descr
#	arg2	descr
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::Shares { spec } {
    set host ""
    set mchn ""
    # Segragates list from the string representation of shares.
    if { [llength $spec] >= 2 } {
	foreach {host mchn} $spec break
    } else {
	set colon [string first ":" $spec]
	if { $colon >= 0 } {
	    foreach {host mchn} [split $spec ":"] break
	} else {
	    set host $spec
	}
    }

    # Resolve (local) environement variables to the values.
    set host [Resolve $host]
    set mchn [Resolve $mchn]
    if { $mchn eq "" } {
	set mchn $host
    }

    # Scream on errors and return
    if { $host eq "" } {
	log ERROR "No host path specified!"
	return {}
    } else {
	if { [file isdirectory $host] } {
	    return [list $host $mchn]
	} else {
	    log ERROR "$host is not a directory"
	}
    }
    return {}
}


# ::cluster::Resolve -- Environement variable resolution
#
#       This procedure will resolve every occurence of a construct
#       $name where name is the name of an environment variable to the
#       value of that variable, as long as it exists.  It also
#       recognises ${name}.
#
# Arguments:
#	str	Incoming string
#
# Results:
#       String where environment variables have been resolved to their
#       values.
#
# Side Effects:
#       None.
proc ::cluster::Resolve { str } {
    set mapper {}
    foreach e [array names ::env] {
	lappend mapper \$${e} [set ::env($e)]
	lappend mapper \$\{${e}\} [set ::env($e)]
    }
    return [string map $mapper $str]
}


# ::cluster::Token -- Generate token
#
#       Generate a new swarm token through creating a temporary
#       virtual machine in which we will run "docker-machine run swarm
#       create".  The temporary machine is removed once the token has
#       been generated.  When the driver is empty, this will create
#       the swarm token using a local component, thus leaving an extra
#       image on the local machine.
#
# Arguments:
#	driver	Default driver to use for (temporary) VM creation.
#
# Results:
#       Generated token
#
# Side Effects:
#       Create a (temporary) virtual machine and component for swarm
#       token creation.
proc ::cluster::Token { {driver virtualbox} } {
    set token ""
    if { $driver eq "none" || $driver eq "" } {
	Detach;   # Ensure we are running locally...
	log INFO "Creating swarm token..."
	set token [Run -return -- ${vars::-docker} run --rm swarm create]
	log NOTICE "Created cluster token $token"
    } else {
	set nm [Temporary "tokeniser"]
	log NOTICE "Creating machine $nm for token creation"
	set vm [dict create -name $nm -driver $driver]
	if { [Create $vm] ne "" } {
	    Attach $vm
	    log INFO "Creating swarm token..."
	    set token [Run -return -- ${vars::-docker} run --rm swarm create]
	    log NOTICE "Created cluster token $token"
	    Run ${vars::-machine} kill $nm;   # We want to make this quick!
	    Run ${vars::-machine} rm $nm
	}
    }
    return $token
}


# ::cluster::LogTerminal -- Create log line for terminal output
#
#       Pretty print a log message for output on the terminal.  This
#       will use ANSI colour codings to improve readability (and will
#       omit the timestamps).
#
# Arguments:
#	lvl	Log level (an integer)
#	msg     Log message
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
	set lbl [format %.8s "$TAGGER($lvl)        "]
    } else {
	set lbl [format %.8s "$lvl        "]
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
#	lvl	Log level (an integer)
#	msg     Log message
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
#       example, when creating temporary files).
#
# Arguments:
#	pfx	Prefix before unicity taggers
#
# Results:
#       A string that is made unique through the process identifier
#       and some randomness.
#
# Side Effects:
#       None.
proc ::cluster::Temporary { pfx } {
    return ${pfx}-[pid]-[expr {int(rand()*1000)}]

}


package provide cluster 0.2

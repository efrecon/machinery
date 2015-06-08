##################
## Module Name     --  wapi.tcl
## Original Author --  Emmanuel Frecon - emmanuel@sics.se
## Description:
##
##      This module implements a web-server and API for operating on a
##      cluster using a vocabulary that mimics most of the
##      command-line arguments.  The current implementation binds a
##      given cluster YAML description file to a port on which the
##      server will listen.  This is likely to change in the future.
##      The module implements a single command called wapi, a command
##      pushed into the main namespace.
##
##################

package require cluster::swarm
package require minihttpd

namespace eval ::api::wapi {
    namespace eval vars {
	variable version   "0.1";  # Version of this module and API!
	variable clusters  {};     # List of dictionaries, keys are port numbers

	variable -port     8090;   # Default port to listen on
	variable -endpoint "/api/v$version";   # Entry point of the API
    }

    namespace export {[a-z]*}
    namespace path ::cluster;   # Arrange to access log easily, should we rm?
    namespace ensemble create -command ::wapi
}


# ::api::wapi::server -- Start serving commands
#
#       This procedure will bind a YAML description file to a port
#       number and will listen to incoming HTTP connections on that
#       port.  This implements a REST-like vocabulary that mimics the
#       command line options.
#
# Arguments:
#	yaml	Path to YAML file description
#	pfx	Prefix when creating the machines in cluster
#	args	List of dash-led keys and their values: -port should be
#               the port to listen on, -root a directory to serve file
#               from, all other arguments are passed to the HTTPd lib.
#
# Results:
#       The port number on success, a negative number otherwise.
#
# Side Effects:
#       Start serving on the port, with all the risks involved.  Note
#       that the HTTP server used is capable of doing HTTPS and
#       implements basic authorisation, but this hasn't been lift up
#       to the interface (yet?)
proc ::api::wapi::server { yaml pfx args } {
    # Get "our" arguments so we can translate between our API (only
    # based on dash-led options) to the one of the web server (which
    # requires a root directory and a port number).
    cluster getopt args -port port ${vars::-port}
    cluster getopt args -root www ""

    # Create a webserver on the (default?) port, pass all other
    # arguments to the web server.  Of special interest should be
    # -authorization to control access using basic authentication and
    # -pki for HTTPS serving.
    set srv [::minihttpd::new $www $port {*}$args]
    if { $srv < 0 } {
	log ERROR "Cannot start web server on port: $port"
	return $srv
    }

    # Bind API entry points to procedures.  API entry points that end
    # with .json will return a JSON construct, ending with .txt a text
    # (more tcl-like) and nothing will default to the JSON behaviour.
    set api [string trimright ${vars::-endpoint} "/"]
    foreach entries {token names info version up destroy halt restart sync \
			 ps reinit} {
	# Extract entrypoint for API and name of procedure it should
	# map to.  When no procedure is specified, it will be the same
	# as the API entry point, with an uppercase first letter.
	foreach {entry procname} $entries break
	if { $procname eq "" } {
	    set procname [string toupper [string index $entry 0]]
	    append procname [string range $entry 1 end]
	}

	# Empty procname leads a Not-Yet-Implemented result, we might
	# want to do better than this...
	if { $procname eq "" } {
	    set procname NYI
	}

	# Create REST entry points.  Everything which ends with .json
	# or nothing will expect JSON returning results, .txt will
	# lead to results that are more easily munge by Tcl.  The
	# desired output type is automatically passed to the
	# procedures as a first argument, it is up to the
	# implementation to respect the output format.
	::minihttpd::handler $srv $api/$entry \
	    [list [namespace current]::$procname json] "application/json"
	::minihttpd::handler $srv $api/${entry}.json \
	    [list [namespace current]::$procname json] "application/json"
	::minihttpd::handler $srv $api/${entry}.txt \
	    [list [namespace current]::$procname txt] "text/plain"
    }
    
    # Bind the cluster to the server port.  vars::clusters contains a
    # dictionary where the keys are the ports that we are serving as a
    # module (i.e. EACH call to this procedure).  The value of these
    # dictionaries will itself be a dictionary with the following
    # keys: yaml -- Path to YAML description file; prefix -- Prefix
    # for machine name creation; cluster -- List of VM dictionaries
    # describing the machines of the cluster.
    dict set vars::clusters $srv yaml $yaml
    dict set vars::clusters $srv prefix $pfx

    log NOTICE "Listening for web connections on $port,\
                endpoint: ${vars::-endpoint}"
    return $srv
}

####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################

# ::api::wapi::Init -- Conditional cluster reading
#
#       Read the cluster description associated to the web server port
#       number if necessary and return its list of dictionary
#       descriptions.
#
# Arguments:
#	prt	Port number we are listening on.
#
# Results:
#       Return the list of VM description dictionaries, this is
#       cached.
#
# Side Effects:
#       None.
proc ::api::wapi::Init { prt } {
    if { [dict exists $vars::clusters $prt] } {
	if { [dict exists $vars::clusters $prt cluster] } {
	    return [dict get $vars::clusters $prt cluster]
	} else {
	    set yaml [dict get $vars::clusters $prt yaml]
	    set prefix [dict get $vars::clusters $prt prefix]
	    set driver [dict get [cli defaults] -driver]
	    if { [catch {cluster parse $yaml \
			     -prefix $prefix -driver $driver} vms] } {
		log ERROR "Cannot parse $yaml: $vms"
	    } else {
		dict set vars::clusters $prt cluster $vms
		return $vms
	    }
	}
    } else {
	log WARN "No initialisation ever performed for $prt"
    }
    return {}
}


# ::api::wapi::Bind -- Bind cluster to running state
#
#       Bind the cluster associated to the port number passed as an
#       argument to the current running state reported by
#       docker-machine.
#
# Arguments:
#	prt	Port number we are listening on.
#
# Results:
#       Return the list of VM description dictionaries, this is not
#       cached.
#
# Side Effects:
#       None.
proc ::api::wapi::Bind { prt } {
    set cluster {}

    # Initialise if necessary.
    if { ![dict exists $vars::clusters $prt cluster] } {
	Init $prt
    }

    # Get state from docker machine and merge into VM descriptions so
    # as complete the information for each machine.
    if { [dict exists $vars::clusters $prt cluster] } {
	set state [cluster ls]
	foreach vm [dict get $vars::clusters $prt cluster] {
	    lappend cluster [cluster bind $vm $state]
	}
    }

    return $cluster
}


# ::api::wapi::GetToken -- Get swarm token
#
#       Get the token associated to the cluster associated to the port
#       number passed as an argument.
#
# Arguments:
#	prt	Port number we are listening on
#	force	Force re-generation of token
#
# Results:
#       Return the token
#
# Side Effects:
#       None.
proc ::api::wapi::GetToken { prt {force 0}} {
    set token ""
    if { [Init $prt] ne {} } {
	set yaml [dict get $vars::clusters $prt yaml]
	set token [::cluster::swarm::token $yaml $force ""]
    }
    return $token
}


# ::api::wapi::Token -- API implementation for token
#
#       Get or (re)generate swarm token
#
# Arguments:
#	output	Output format (json or txt)
#	prt	Port number we are listening on
#	sock	Socket to client
#	url	Path which was requested
#	qry	key/values from query
#
# Results:
#       Token information in JSON or TXT format.
#
# Side Effects:
#       None.
proc ::api::wapi::Token {output prt sock url qry} {
    set force 0
    if { [dict exists $qry force] } {
	set force [string is true [dict get $qry force]]
    }
    set token [GetToken $prt $force]

    if { $output eq "txt" } {
	return $token
    } else {
	return [::json::stringify [dict create token $token] 0]
    }
}


# ::api::wapi::Names -- API implementation for names
#
#       Get the names of the machines that are declared as part of the
#       cluster.
#
# Arguments:
#	output	Output format (json or txt)
#	prt	Port number we are listening on
#	sock	Socket to client
#	url	Path which was requested
#	qry	key/values from query
#
# Results:
#       Names in JSON or TXT format.
#
# Side Effects:
#       None.
proc ::api::wapi::Names {output prt sock url qry} {
    set names [cluster names [Bind $prt]]
    if { $output eq "txt" } {
	return $names
    } else {
	# Force proper schema
	return [::json::stringify [dict create names $names] 0 \
		    [dict create names array]]
    }
}


# ::api::wapi::Info -- API implementation for info
#
#       Get information of (some of) the machines that are declared as
#       part of the cluster.  Recognise 'machines' as an argument, a
#       comma-separated list of machine names (short names accepted).
#
# Arguments:
#	output	Output format (json or txt)
#	prt	Port number we are listening on
#	sock	Socket to client
#	url	Path which was requested
#	qry	key/values from query
#
# Results:
#       List of machine information, an array of objects in JSON, a
#       tcl-list for TXT.
#
# Side Effects:
#       None.
proc ::api::wapi::Info {output prt sock url qry} {
    # Get list of machines from argument, all machines in cluster if
    # nothing specified.
    if { [dict exists $qry machines] } {
	set machines [split [dict get $qry machines] ,]
    } else {
	set machines {}
    }

    set vms [cli machines [Bind $prt] $machines]
    if { $output eq "txt" } {
	return $vms
    } else {
	set json "\["
	foreach vm $vms {
	    dict unset vm origin;   # Remove internal state
	    append json [::json::stringify $vm 0 \
			     [dict create -ports array \
				  -shares array \
				  -images array \
				  -compose array \
				  swarm string \
				  state string \
				  -registries array]]
	    append json ","
	}
	set json [string trimright $json ","]
	append json "\]"
	return $json
    }
}


# ::api::wapi::Version -- API implementation for version
#
#       Return machinery version
#
# Arguments:
#	output	Output format (json or txt)
#	prt	Port number we are listening on
#	sock	Socket to client
#	url	Path which was requested
#	qry	key/values from query
#
# Results:
#       Version number in JSON or TXT format.
#
# Side Effects:
#       None.
proc ::api::wapi::Version {output prt sock url qry} {
    set cluster [Bind $prt]
    if { $output eq "txt" } {
	return [cli version]
    } else {
	return [::json::stringify [dict create version [cli version]] 0]
    }
}


# ::api::wapi::Up -- API implementation for up
#
#       Create or (re)start machines.  Recognise 'machines' as an
#       argument, a comma-separated list of machine names (short names
#       accepted).  No argument means all machines in cluster.
#
# Arguments:
#	output	Output format (json or txt)
#	prt	Port number we are listening on
#	sock	Socket to client
#	url	Path which was requested
#	qry	key/values from query
#
# Results:
#       List of machine information, an array of objects in JSON, a
#       tcl-list for TXT.
#
# Side Effects:
#       None.
proc ::api::wapi::Up {output prt sock url qry} {
    # Get list of machines from argument, all machines in cluster if
    # nothing specified.
    set token [GetToken $prt]
    if { [dict exists $qry machines] } {
	set machines [split [dict get $qry machines] ,]
    } else {
	set machines {}
    }
    foreach vm [cli machines [Bind $prt] $machines] {
	cli up $vm $token
    }

    # Return information for the machines that we requested to be
    # started up.
    return [Info $output $prt $sock $url $qry]
}


# Implement destroy, see OnEach
proc ::api::wapi::Destroy {output prt sock url qry} {
    return [OnEach $output $prt $sock $url $qry [list destroy]]
}

# Implement halt, see OnEach
proc ::api::wapi::Halt {output prt sock url qry} {
    return [OnEach $output $prt $sock $url $qry [list halt]]
}

# Implement restart, see OnEach
proc ::api::wapi::Restart {output prt sock url qry} {
    return [OnEach $output $prt $sock $url $qry [list halt start]]
}

# Implement sync, see OnEach
proc ::api::wapi::Sync {output prt sock url qry} {
    return [OnEach $output $prt $sock $url $qry [list sync]]
}

# ::api::wapi::Ps -- API implementation for ps
#
#       List the components running on selected machines of the
#       cluster, or as reported by the swarm master.  This is
#       basically an interface to docker ps.  Recognise 'machines' as
#       an argument, a comma-separated list of machine names (short
#       names accepted).  No argument means requesting the cluster
#       master about the list of components running.
#
# Arguments:
#	output	Output format (json or txt)
#	prt	Port number we are listening on
#	sock	Socket to client
#	url	Path which was requested
#	qry	key/values from query
#
# Results:
#       List of component information, an array of objects in JSON, a
#       tcl-list for TXT.  When machines have been pin-pointed, an
#       argument called machine will contain the name of the machine
#       that the component runs on.
#
# Side Effects:
#       None.
proc ::api::wapi::Ps {output prt sock url qry} {
    # Get the list of machines out of the machines query parameter
    if { [dict exists $qry machines] } {
	set machines [split [dict get $qry machines] ,]
    } else {
	set machines {}
    }

    # Get list of components out of the list of machines or from the
    # swarm master.  Add the name of the machine when listing
    # machines to make sure callers can make the difference.
    set out {}
    if { [llength $machines] > 0 } {
	foreach vm [cli machines [Bind $prt] $machines] {
	    foreach c [cluster ps $vm 0 0] {
		if { [dict exists $vm -name] } {
		    dict set c machine [dict get $vm -name]
		}
		lappend out $c
	    }
	}
    } else {
	set master [::cluster::swarm::master [Bind $prt]]
	set out [cluster ps $master 1 0]
    }
    
    # Output the list of components which we've got from the swarm
    # master or from the machines.
    if { $output eq "txt" } {
	return $out
    } else {
	set json "\["
	foreach c $out {
	    # Trim leading quote away from command
	    if { [dict exists $c command] } {
		dict set c command [string trim [dict get $c command] \"]
	    }
	    # Split the list of ports
	    if { [dict exists $c ports] } {
		dict set c ports [split [dict get $c ports] ","]
	    }

	    append json [::json::stringify $c 0 \
			     [dict create \
				  ports array \
				  command string \
				  created string \
				  status string]]
	    append json ","
	}
	set json [string trimright $json ","]
	append json "\]"
	return $json
    }
}


# ::api::wapi::Reinit -- API implementation for reinit
#
#       Reinitialise machines.  Recognise 'machines' as an argument, a
#       comma-separated list of machine names (short names accepted).
#       No argument means all machines in cluster.  Also recognise
#       'steps' as a comma separated list of steps to perform during
#       reinitialisation: registries, images or compose.
#
# Arguments:
#	output	Output format (json or txt)
#	prt	Port number we are listening on
#	sock	Socket to client
#	url	Path which was requested
#	qry	key/values from query
#
# Results:
#       List of machine information, an array of objects in JSON, a
#       tcl-list for TXT.
#
# Side Effects:
#       None.
proc ::api::wapi::Reinit {output prt sock url qry} {
    if { [dict exists $qry steps] } {
	set steps [split [dict get $qry steps] ,]
    } else {
	set steps [list registries images compose]
    }

    return [OnEach $output $prt $sock $url $qry [list [list init $steps]]]
}


proc ::api::wapi::Swarm {output prt sock url qry} {
    # Get list of operations to perform out of query arguments ops
    # (but also accepts operations)
    set ops {}
    if { [dict exists $qry ops] } {
	set ops [split [dict get $qry ops] ,]
	dict unset qry ops
    } elseif { [dict exists $qry operations] } {
	set ops [split [dict get $qry operations] ,]
	dict unset qry operations
    }
    
    # Order the operations to be performed into list called operations
    if { [llength $ops] == 0 } {
	set operations [list UP]
    } else {
	foreach order [list STOP KILL RM UP START] {
	    if { [lsearch -glob -nocase $ops *${order}*] >= 0 } {
		lappend operations $order
	    }
	}
    }

    # Pass all other query parameters as options to swarm
    set compose [string trim [::minihttpd::data $prt $sock]]
    if { $compose ne "" } {
	set master [::cluster::swarm::master [Bind $prt]]

	# Create temporary file with content of POSTed data.
	set tmpfile [cluster tempfile compose .yml]
	set fd [open $tmpfile w]
	puts $fd $compose
	close $fd

	foreach op $operations {
	    cluster swarm $master $op $tmpfile $qry
	}

	# Remove temp file
	file delete -force $tmpfile
    }
}


# ::api::wapi::OnEach -- Execute sequence of ops on machines
#
#       This will execute a sequence of operations on a number of
#       machines in the cluster.  Recognise 'machines' as an argument,
#       a comma-separated list of machine names (short names
#       accepted).  No argument means all machines in cluster.
#
# Arguments:
#	output	Output format (json or txt)
#	prt	Port number we are listening on
#	sock	Socket to client
#	url	Path which was requested
#	qry	key/values from query
#
# Results:
#       List of machine information, an array of objects in JSON, a
#       tcl-list for TXT.
#
# Side Effects:
#       None.
proc ::api::wapi::OnEach {output prt sock url qry ops} {
    if { [dict exists $qry machines] } {
	set machines [split [dict get $qry machines] ,]
    } else {
	set machines {}
    }
    foreach vm [cli machines [Bind $prt] $machines] {
	foreach op $ops {
	    if { [llength $op] > 1 } {
		cluster [lindex $op 0] $vm {*}[lrange $op 1 end]
	    } else {
		cluster $op $vm
	    }
	}
    }

    # Return information for the machines that we requested to be
    # started up.
    return [Info $output $prt $sock $url $qry]
}


# ::api::wapi::NYI -- Not Yet Implemented
#
#       Not yet implemented, return empty!
#
# Arguments:
#	output	Output format (json or txt)
#	prt	Port number we are listening on
#	sock	Socket to client
#	url	Path which was requested
#	qry	key/values from query
#
# Results:
#       Empty string/object.
#
# Side Effects:
#       None.
proc ::api::wapi::NYI {output prt sock url qry} {
    # "Implementation" of NYI
    if {$output eq "txt" } {
	return ""
    } else {
	return "\{\}"
    }
}

package provide api::wapi $::api::wapi::vars::version


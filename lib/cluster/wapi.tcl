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

namespace eval ::cluster::wapi {
    namespace eval vars {
	variable version   "0.1";    # Version of this module and API!
	variable clusters  {};       # List of dictionaries, keys are the port#

	variable -endpoint "/api/v$version";   # Entry point of the API
    }

    namespace export {[a-z]*}
    namespace path [namespace parent]
    namespace ensemble create -command ::wapi
}


# ::cluster::wapi::server -- Start serving commands
#
#       This procedure will bind a YAML description file to a port
#       number and will listen to incoming HTTP connections on that
#       port.  This implements a REST-like vocabulary that mimics the
#       command line options.
#
# Arguments:
#	yaml	Path to YAML file description
#	pfx	Prefix when creating the machines in cluster
#	port	Port to listen for incoming connections on.
#	root	Root path to serve file for
#
# Results:
#       The port number on success, a negative number otherwise.
#
# Side Effects:
#       Start serving on the port, with all the risks involved.  Note
#       that the HTTP server used is capable of doing HTTPS and
#       implements basic authorisation, but this hasn't been lift up
#       to the interface (yet?)
proc ::cluster::wapi::server { yaml {pfx ""} { port 8080 } { root "" } } {
    # Create a webserver
    set srv [::minihttpd::new $root $port]
    if { $srv < 0 } {
	log ERROR "Cannot start web server on port: $port"
	return $srv
    }

    # Bind API entry points to procedures.  API entry points that end
    # with .json will return a JSON construct, ending with .txt a text
    # (more tcl-like) and nothing will default to the JSON behaviour.
    set api [string trimright ${vars::-endpoint} "/"]
    foreach entries {token names info version up destroy halt restart sync} {
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

proc ::cluster::wapi::Init { prt } {
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


proc ::cluster::wapi::Bind { prt } {
    set cluster {}
    if { ![dict exists $vars::clusters $prt cluster] } {
	Init $prt
    }

    if { [dict exists $vars::clusters $prt cluster] } {
	set state [cluster ls]
	foreach vm [dict get $vars::clusters $prt cluster] {
	    lappend cluster [cluster bind $vm $state]
	}
    }

    return $cluster
}


proc ::cluster::wapi::GetToken { prt {force 0}} {
    set token ""
    if { [Init $prt] ne {} } {
	set yaml [dict get $vars::clusters $prt yaml]
	set token [::cluster::swarm::token $yaml $force ""]
    }
    return $token
}


proc ::cluster::wapi::Token {output prt sock url qry} {
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


proc ::cluster::wapi::Names {output prt sock url qry} {
    set names [cluster names [Bind $prt]]
    if { $output eq "txt" } {
	return $names
    } else {
	# Force proper schema
	return [::json::stringify [dict create names $names] 0 \
		    [dict create names array]]
    }
}


proc ::cluster::wapi::Info {output prt sock url qry} {
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
			     [dict create -ports array -shares array]]
	    append json ","
	}
	set json [string trimright $json ","]
	append json "\]"
	return $json
    }
}


proc ::cluster::wapi::Version {output prt sock url qry} {
    set cluster [Bind $prt]
    if { $output eq "txt" } {
	return [cli version]
    } else {
	return [::json::stringify [dict create version [cli version]] 0]
    }
}

proc ::cluster::wapi::Up {output prt sock url qry} {
    set token [GetToken $prt]
    if { [dict exists $qry machines] } {
	set machines [split [dict get $qry machines] ,]
    } else {
	set machines {}
    }
    foreach vm [cli machines [Bind $prt] $machines] {
	cli up $vm $token
    }

    return [Info $output $prt $sock $url $qry]
}


proc ::cluster::wapi::Destroy {output prt sock url qry} {
    return [OnEach $output $prt $sock $url $qry [list destroy]]
}

proc ::cluster::wapi::Halt {output prt sock url qry} {
    return [OnEach $output $prt $sock $url $qry [list halt]]
}

proc ::cluster::wapi::Restart {output prt sock url qry} {
    return [OnEach $output $prt $sock $url $qry [list halt start]]
}

proc ::cluster::wapi::Sync {output prt sock url qry} {
    return [OnEach $output $prt $sock $url $qry [list sync]]
}

proc ::cluster::wapi::OnEach {output prt sock url qry ops} {
    if { [dict exists $qry machines] } {
	set machines [split [dict get $qry machines] ,]
    } else {
	set machines {}
    }
    foreach vm [cli machines [Bind $prt] $machines] {
	foreach op $ops {
	    cluster $op $vm
	}
    }

    return [Info $output $prt $sock $url $qry]
}


proc ::cluster::wapi::NYI {output prt sock url qry} {
    # "Implementation" of NYI
    if {$output eq "txt" } {
	return ""
    } else {
	return "\{\}"
    }
}

package provide cluster::wapi $::cluster::wapi::vars::version


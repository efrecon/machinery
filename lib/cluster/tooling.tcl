package require cluster::vcompare
package require cluster::utils

namespace eval ::cluster::tooling {
    # Encapsulates variables global to this namespace under their own
    # namespace, an idea originating from http://wiki.tcl.tk/1489.
    # Variables which name start with a dash are options and which
    # values can be changed to influence the behaviour of this
    # implementation.
    namespace eval vars {
        # Path to common executables
        variable -machine   docker-machine
        variable -docker    docker
        variable -compose   docker-compose
        variable -rsync     rsync
        # Force attachment via command line options
        variable -sticky    off
        # Object generation identifiers
        variable generator  0
        # CLI commands supported by tools (on demand)
        variable commands   {docker "" compose "" machine ""}
        # version numbers for our tools (on demand)
        variable versions   {docker "" compose "" machine ""}
    }
    # Export all lower case procedure, arrange to be able to access
    # commands from the parent (cluster) namespace from here and
    # create an ensemble command called swarmmode (note the leading :: to make
    # this a top-level command!) to ease API calls.
    namespace export {[a-z]*}
    namespace path [namespace parent]
    namespace ensemble create -command ::tooling
    namespace import [namespace parent]::utils::log
}


# ::cluster::runtime -- Runtime check
#
#   Check for the presence of (and access to) the underlying necessary docker
#   tools and execute a command when they are not available.
#
# Arguments:
#	cmd	Command to execute when one tool is not available
#
# Results:
#	A boolean telling if all runtime configuration is proper (or not)
#
# Side Effects:
#	None
proc ::cluster::tooling::runtime { { cmd {} } } {
    foreach tool [list docker compose machine] {
        if { [auto_execok [set vars::-[string trimleft $tool -]]] eq "" } {
            log FATAL "Cannot access '$tool'!"
            if { [llength $cmd] } {
                eval {*}$cmd
            }
            return 0
        }
    }
    return 1
}


proc ::cluster::tooling::commands { tool } {
    switch -nocase -- $tool {
        compose -
        machine -
        docker {
            if { [dict get $vars::commands $tool] eq "" } {
                dict set vars::commands $tool [CommandsQuery $tool]
                log DEBUG "Current set of commands for $tool is\
                           [join [dict get $vars::commands $tool] ,\ ]"
            }
            return [dict get $vars::commands $tool]
        }
    }
    return {}
}


# ::cluster::tooling::version -- (Cached) version of underlying tools.
#
#       This will return the core version number of one of the
#       underlying tools that we support.  The version number is
#       cached in a global variable so it will only be queried once.
#
# Arguments:
#       tool    Tool to query, a string, one of: docker, machine or compose
#
# Results:
#       Return the version number or an empty string.
#
# Side Effects:
#       None.
proc ::cluster::tooling::version { tool } {
    switch -nocase -- $tool {
        compose -
        machine -
        docker {
            if { [dict get $vars::versions $tool] eq "" } {
                dict set vars::versions $tool [VersionQuery $tool]
                log DEBUG "Current version for $tool is\
                        [dict get $vars::versions $tool]"
            }
            return [dict get $vars::versions $tool]
        }
    }
    return ""
}

# ::cluster::tooling::docker -- Run docker binary
#
#       Run the docker binary registered as part as the global library
#       options under the control of this program.  This wrapper will
#       turn on extra debbuggin in docker itself whenever the
#       verbosity level of the library is greated or equal than DEBUG.
#
# Arguments:
#        args        Arguments to docker command (compatible with Run)
#
# Results:
#       Result of command.
#
# Side Effects:
#       None.
proc ::cluster::tooling::docker { args } {
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
    
    # Put docker in debug mode when we are ourselves at debug level.
    if { [utils outlog] >= 7 } {
        set args [linsert $args 0 --debug]
    }
    if { [string is true ${vars::-sticky}] } {
        if { [info exists ::env(DOCKER_TLS_VERIFY)] } {
            if { [string is true $::env(DOCKER_TLS_VERIFY)] } {
                set args [linsert $args 0 --tls --tlsverify=true]
            }
        }
        if { [info exists ::env(DOCKER_CERT_PATH)] } {
            foreach {opt fname} [list cacert ca.pem cert cert.pem key key.pem] {
                set fpath [file join $::env(DOCKER_CERT_PATH) $fname]
                if { [file exists $fpath] } {
                    set args [linsert $args 0 --tls$opt [file nativename $fpath]]
                }
            }
        }
        if { [info exists ::env(DOCKER_HOST)] } {
            set args [linsert $args 0 -H $::env(DOCKER_HOST)]
        }
        log INFO "Automatically added command line arguments to docker: $args"
    }
    return [eval run $opts -- [auto_execok ${vars::-docker}] $args]
}


# ::cluster::tooling::compose -- Run compose binary
#
#       Run the compose binary registered as part as the global
#       library options under the control of this program.  This
#       wrapper will turn on extra debbuggin in compose itself
#       whenever the verbosity level of the library is greated or
#       equal than DEBUG.
#
# Arguments:
#        args        Arguments to compose command (compatible with Run)
#
# Results:
#       Result of command.
#
# Side Effects:
#       None.
proc ::cluster::tooling::compose { args } {
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
    
    # Put docker in debug mode when we are ourselves at debug level.
    if { [utils outlog] >= 7 } {
        set args [linsert $args 0 --verbose]
    }
    return [eval run $opts -- [auto_execok ${vars::-compose}] $args]
}


# ::cluster::tooling::machine -- Run machine binary
#
#       Run the docker machine binary registered as part as the global
#       library options under the control of this program.  This
#       wrapper will turn on extra debbuggin in machine itself
#       whenever the verbosity level of the library is greated or
#       equal than DEBUG.
#
# Arguments:
#        args        Arguments to machine command (compatible with Run)
#
# Results:
#       Result of command.
#
# Side Effects:
#       None.
proc ::cluster::tooling::machine { args } {
    # Isolate -- that will separate options to procedure from options
    # that would be for command.  Using -- is preferred if you want to
    # specify options to the procedure.
    utils options args opts
    
    # Put docker-machine in debug mode when we are ourselves at debug
    # level.
    if { [utils outlog] >= 7 } {
        set args [linsert $args 0 --debug]
        set opts [linsert $opts 0 -stderr]
    }
    if { 0 && [lsearch [split [::platform::generic] -] "win32"] >= 0 } {
        set args [linsert $args 0 --native-ssh]
    }

    return [eval run $opts -- [auto_execok ${vars::-machine}] $args]
}


proc ::cluster::tooling::relatively { args } {
    utils options args opts
    set chdir [expr {[utils getopt opts -cd] || [utils getopt opts -chdir]}]
    set dir [lindex $args 0]
    set args [lrange $args 1 end]
    
    set modified 0
    set nargs [list]
    foreach a $args {
        if { [file exists $a] } {
            set modified 1
            lappend nargs [utils relative $a $dir]
        } else {
            lappend nargs $a
        }
    }

    if { $modified } {
        log DEBUG "Calling '$nargs' in directory context of $dir"
    }
    set cwd [pwd]
    cd $dir
    set res [uplevel 1 $nargs]
    if { !$chdir} {
        cd $cwd
    }
    return $res
}


# ::cluster::tooling::run -- Run command
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
#        args   (Optional dash-led options, followed by --) and command
#               to execute.
#
# Results:
#       Result of command
#
# Side Effects:
#       Run local command and (possibly) show its output.
proc ::cluster::tooling::run { args } {
    # Isolate -- that will separate options to procedure from options
    # that would be for command.  Using -- is MANDATORY if you want to
    # specify options to the procedure.
    utils options args opts
    
    if { [utils getopt opts -interactive] } {
        log DEBUG "Executing $args interactively"
        foreach fd {stdout stderr stdin} {
            fconfigure $fd -buffering none -translation binary
        }
        if { [catch {exec {*}$args >@ stdout 2>@ stderr <@ stdin} err] } {
            log WARN "Child returned: $err"
        }
    } else {
        # Create an array global to the namespace that we'll use for
        # synchronisation and context storage.
        set c [namespace current]::command[incr ${vars::generator}]
        upvar \#0 $c CMD
        set CMD(id) $c
        set CMD(command) $args
        log DEBUG "Executing $CMD(command) and capturing its output"
        
        # Extract some options and start building the
        # pipe.  As we want to capture output of the command, we will be
        # using the Tcl command "open" with a file path that starts with a
        # "|" sign.
        set CMD(keep) [utils getopt opts -keepblanks]
        set CMD(back) [utils getopt opts -return]
        set CMD(outerr) [utils getopt opts -stderr]
        set CMD(relay) [utils getopt opts -raw]
        set CMD(done) 0
        set CMD(result) {}
        
        # Kick-off the command and wait for its end
        # Kick-off the command and wait for its end
        if { [lsearch [split [::platform::generic] -] win32] >= 0 } {
            set pipe |[concat $args]
            if { $CMD(outerr) } {
                append pipe " 2>@1"
            }
            set CMD(stdin) ""
            set CMD(stderr) ""
            set CMD(stdout) [open $pipe]
            set CMD(pid) [pid $CMD(stdout)]
            fileevent $CMD(stdout) readable [namespace code [list LineRead $c stdout]]
        } else {
            lassign [POpen4 {*}$args] CMD(pid) CMD(stdin) CMD(stdout) CMD(stderr)
            fileevent $CMD(stdout) readable [namespace code [list LineRead $c stdout]]
            fileevent $CMD(stderr) readable [namespace code [list LineRead $c stderr]]
        }
        vwait ${c}(done);   # Wait for command to end
        
        catch {close $CMD(stdin)}
        catch {close $CMD(stdout)}
        catch {close $CMD(stderr)}
        
        set res $CMD(result)
        unset $c
        return $res
    }
}



proc ::cluster::tooling::machineOptions { driver } {
    log INFO "Actively discovering creation options for driver $driver"
    return [options [machine -return -- create --driver $driver]]
}


proc ::cluster::tooling::options { lines } {
    set cmdopts {};  # Empty list of discovered options
    
    foreach l $lines {
        # Only considers indented lines, they contain the option
        # descriptions (there might be a lot!).
        if { [string trim $l] ne "" && [string trimleft $l] ne $l } {
            set l [string trim $l]
            # Now only consider lines that start with a dash.
            if { [string index $l 0] eq "-" } {
                # Get rid of the option textual description behind the
                # first tab.
                set tab [string first "\t" $l]
                if { $tab < 0 } {
                    set tab [string first "  " $l]
                }
                set lead [string trim [string range $l 0 $tab]]
                # Now isolate the real option, starting from the back
                # of the string.  Try capturing the default value if
                # any.
                set def_val {};   # Default value is empty by default
                set back [expr {[string length $lead]-1}];  # End of lead
                # Default value is at end, between quotes.
                if { [string index $lead end] eq "\"" } {
                    set op_quote [string last "\"" $lead end-1]
                    set back [expr {$op_quote-1}];  # Skip default val
                    set def_val [string trim [string range $lead $op_quote end] "\""]
                }
                # Skip multioption specification, which is enclosed by
                # brackets.
                set idx [string last "\]" $lead]
                if { $idx >= 0 } {
                    set back [expr {[string last "\[" $lead $idx]-1}]
                }
                # When we are here, the variable back contains the
                # location within the lead where the options
                # specifications are contained.  Split on coma and
                # pick up the first with a double dash.
                foreach opt [split [string range $lead 0 $back] ","] {
                    set opt [string trim $opt]
                    if { [string range $opt 0 1] eq "--" } {
                        set space [string first " " $opt]
                        if { $space >= 0 } {
                            lappend cmdopts [string range $opt 2 [expr {$space - 1}]] $def_val                        
                        } else {
                            lappend cmdopts [string range $opt 2 end] $def_val
                        }
                        break;   # Done, we have found one!
                    }
                }
            }
        }
    }
    
    return $cmdopts    
}


proc ::cluster::tooling::parser { state { hdrfix {}} } {
    set content {};   # The list of dictionaries we will return
    
    set cols [lindex $state 0]
    if { [llength $hdrfix] > 0 } {
        set cols [string map $hdrfix $cols]
    }
    
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
            # The value is in between those ranges, trim to get rid of
            # trailing spaces that had been added for a nice output.
            set v [string range $m [lindex $indices $c] $end]
            dict set nfo [string trim [string tolower $k]] [string trim $v]
        }
        lappend content $nfo
    }
    
    return $content
}



####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################


# ::cluster::tooling::POpen4 -- Pipe open
#
#       This procedure executes an external command and arranges to
#       redirect locally assiged channel descriptors to its stdin,
#       stdout and stderr.  This makes it possible to send input to
#       the command, but also to properly separate its two forms of
#       outputs.
#
# Arguments:
#	args	Command to execute
#
# Results:
#       A list of four elements.  Respectively: the list of process
#       identifiers for the command(s) that were piped, channel for
#       input to command pipe, for regular output of command pipe and
#       channel for errors of command pipe.
#
# Side Effects:
#       None.
proc ::cluster::tooling::POpen4 { args } {
    foreach chan {In Out Err} {
        set pipe [chan pipe]
        if { [llength $pipe] >= 2 } {
            lassign $pipe read$chan write$chan
        } else {
            log FATAL "Cannot create channel pipes!"
            return [list]
        }
    }
    
    if { [catch {exec {*}$args <@$readIn >@$writeOut 2>@$writeErr &} pid] } {
        foreach chan {In Out Err} {
            chan close write$chan
            chan close read$chan
        }
        log CRITICAL "Cannot execute $args: $pid"
        return [list]
    }
    chan close $writeOut
    chan close $writeErr
    
    foreach chan [list stdout stderr $readOut $readErr $writeIn] {
        chan configure $chan -buffering line -blocking false
    }
    
    return [list $pid $writeIn $readOut $readErr]
}


# ::cluster::tooling::LineRead -- Read line output from started commands
#
#       This reads the output from commands that we have started, line
#       by line and either prints it out or accumulate the result.
#       Properly mark for end of output so the caller will stop
#       waiting for output to happen.  When outputing through the
#       logging facility, the procedure is able to recognise the
#       output of docker-machine commands (which uses the logrus
#       package) and to convert between loglevels.
#
# Arguments:
#	c	Identifier of command being run
#	fd	Which channel to read (refers to index in command)
#
# Results:
#       None.
#
# Side Effects:
#       Read lines, outputs
proc ::cluster::tooling::LineRead { c fd } {
    upvar \#0 $c CMD
    
    set line [gets $CMD($fd)]
    set outlvl [expr {$fd eq "stderr" ? "NOTICE":"INFO"}]
    # Parse and analyse output of docker-machine. Do some translation
    # of the loglevels between logrus and our internal levels.
    set bin [lindex $CMD(command) 0]
    if { [string first ${vars::-machine} $bin] >= 0 } {
        if { [string first "msg=" $line] >= 0 } {
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
                            panic FATAL] {
                        if { [string equal -nocase $v $gl] } {
                            set outlvl $lvl
                        }
                    }
                }
            }
        }
    }
    # Respect -keepblanks and output or accumulate in result
    if { ( !$CMD(keep) && [string trim $line] ne "") || $CMD(keep) } {
        if { $CMD(back) } {
            if { ( $CMD(outerr) && $fd eq "stderr" ) || $fd eq "stdout" } {
                log TRACE "Appending '$line' to result"
                lappend CMD(result) $line
            }
        } elseif { $CMD(relay) } {
            puts $fd $line
        } else {
            # Output even what was captured on stderr, which is
            # probably what we wanted in the first place.
            log $outlvl "  $line"
        }
    }
    
    # On EOF, we stop this very procedure to be triggered.  If there
    # are no more outputs to listen to, then the process has ended and
    # we are done.
    if { [eof $CMD($fd)] } {
        fileevent $CMD($fd) readable {}
        if { ($CMD(stdout) eq "" || [fileevent $CMD(stdout) readable] eq "" ) \
                    && ($CMD(stderr) eq "" || [fileevent $CMD(stderr) readable] eq "" ) } {
            set CMD(done) 1
        }
    }
}



# ::cluster::tooling::VersionQuery -- Version of underlying tools
#
#       Query and return the version number of one of the underlying
#       tools that we support.  This will call the appropriate tool
#       with the proper arguments to get the version number.
#
# Arguments:
#        tool   Tool to query, a string, one of: docker, machine or compose
#
# Results:
#       Return the version number or an empty string.
#
# Side Effects:
#       None.
proc ::cluster::tooling::VersionQuery { tool } {
    set vline ""
    switch -nocase -- $tool {
        docker {
            set vline [lindex [docker -return -- --version] 0]
        }
        machine {
            set vline [lindex [machine -return -- -version] 0]
        }
        compose {
            set vline [lindex [compose -return -- --version] 0]
        }
        default {
            log WARN "$tool isn't a tool that we can query the version for"
        }
    }
    return [vcompare extract $vline];    # Catch all for errors
}


proc ::cluster::tooling::CommandsQuery { tool } {
    set hlp {}
    switch -nocase -- $tool {
        docker {
            set hlp [docker -return -keepblanks -- --help]
        }
        machine {
            set hlp [machine -return -keepblanks -- --help]
        }
        compose {
            set hlp [compose -return -keepblanks -- --help]
        }
        default {
            log WARN "$tool isn't a tool that we can query the commands for"
        }
    }
    
    # Analyse the output of the help for the tool, they are all
    # formatted more or less the same way.  We look for a line that
    # starts with commands and considers that it marks the beginning
    # of the list of commands.
    set commands {}
    set c_group 0
    foreach l $hlp {
        if { $c_group } {
            set l [string trim $l]
            # Empty line marks the end of the command description
            # group, return what we've found.
            if { $l eq "" } {
                return $commands
            }
            # Look for a separator between the command name(s) and
            # its/their description.  We prefer the tab, but accept
            # also a double space.
            set sep [string first "\t" $l]
            if { $sep < 0 } {
                set sep [string first "  " $l]
            }
            # Separate the command name(s) from the description, split
            # on the coma sign in case there were aliases, then add
            # each command in turns.
            if { $sep < 0 } {
                log WARN "Cannot find command leading '$l'"
            } else {
                set spec [string trim [string range $l 0 $sep]]
                foreach c [split $spec ,] {
                    lappend commands [string trim $c]
                }
            }
        } else {
            # We don't do anything until we've found a line that marks
            # the start of the command description group.
            if { [string match -nocase "commands*" $l] } {
                set c_group 1
            }
        }
    }
    return $commands
}



package provide cluster::tooling 0.2
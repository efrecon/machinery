##################
## Module Name     --  proctrace.tcl
## Original Author --  Emmanuel Frecon
## Description:
##
##      This module is meant to be a last resort debugging facility. It will
##      arrange for being able to trace execution either at the entry of
##      procedure, either of all commands within procedures. The defaults are to
##      trace all procedures, except the one from a few packages known to slow
##      execution down. See beginning of library for an explanation of the
##      options.
##
##################

package require Tcl 8.6

namespace eval ::proctrace {
    namespace eval vars {
        # File to trace execution to (if no file is specified, tracing will
        # occur on the standard error)
        variable -file  ""
        # List of pattern to match against the name of current and future
        # procedures. Only the procedures matching the patterns in this list
        # will be considered for tracing.
        variable -allowed {*}
        # List of patterns to match against the name of procedure that should
        # not be considered for tracing. This is a subset of the ones allowed.
        variable -denied {::tcl::* ::aes::* ::logger::*}
        # A boolean, turn it on to trace the execution of each command block
        # within the procedures.
        variable -detailed off

        variable fd stderr;   # File descriptor where to trace
        variable version 0.2; # Current package version.
        variable enabled 1;   # Is tracing enabled
    }

    # Automatically export all procedures starting with lower case and
    # create an ensemble for an easier API.
    namespace export {[a-z]*}
    namespace ensemble create

}

# ::proctrace::init -- Init and start tracing 
#
#       Arrange to trace the execution of code either at the entry of procedure,
#       either of all commands within procedures. This command takes a number of
#       dash led options, these are described a the beginning of the library.
#
# Arguments:
#        args        List of dash-led options and arguments.
#
# Results:
#       None.
#
# Side Effects:
#       Will start tracing, which means a LOT of output!
proc ::proctrace::init { args } {
    # Detect all options available to the procedure, out of the variables that
    # are dash-led.
    set opts [list]
    foreach o [info vars vars::-*] {
        set i [string last "::-" $o]
        lappend opts [string trimleft [string range $o $i end] :]
    }
    
    # "parse" the options, i.e. set the values if they should exist...
    foreach {k v} $args {
        if { $k in $opts } {
            set vars::$k $v
        } else {
            return -code error "$k unknown options, should be [join $opts ,\ ]"
        }
    }
    
    # Open the file for output, if relevant.
    if { ${vars::-file} ne "" } {
        set vars::fd [open ${vars::-file} w]
    }

    # Arrange to reroute procedure declaration through our command so we can
    # automagically install execution traces.
    rename ::proc ::proctrace::RealProc
    interp alias {} ::proc {} ::proctrace::Proc
    
    # Catch up with the current set of existing procedure to make sure we can
    # also capture execution within procedure that would have been created
    # before ::proctrace::init was called.
    foreach p [AllProcs] {
        if { [Tracable $p]} {
            Follow $p 2
        }
    }
}

proc ::proctrace::terminate {} {set ::proctrace::vars::enabled 0}
proc ::proctrace::resume {} {set ::proctrace::vars::enabled 1}


# ::proctrace::AllProcs -- List all declared procedures
#
#       Returns a list of all declared procedures, in all namespaces currently
#       defined in the interpreter. The implementation recursively list all
#       procedures in all sub-namespaces.
#
# Arguments:
#        base        Namespace at which to start.
#
# Results:
#       List of all procedure in current and descendant namespaces.
#
# Side Effects:
#       None.
proc ::proctrace::AllProcs { { base "::" } } {
    # Get list of procedures in current namespace.
    set procs [info procs [string trimright ${base} :]::*]
    # Recurse in children namespaces.
    foreach ns [namespace children $base] {
        set procs [concat $procs [AllProcs $ns]]
    }
    return $procs
}


# ::proctrace::Follow -- Install traces
#
#       Install traces to be able to get notified whenever procedures are
#       entered or commands within procedures are executed.
#
# Arguments:
#        name        Name (fully-qualified) of procedure.
#        lvl        Call stack level at which to execute trace installation
#
# Results:
#       None.
#
# Side Effects:
#       Arrange for Trace procedure to be called
proc ::proctrace::Follow { name {lvl 1}} {
    if { [string is true ${vars::-detailed}] } {
        uplevel $lvl [list trace add execution $name enterstep [list ::proctrace::Trace $name]]
    } else {
        uplevel $lvl [list trace add execution $name enter [list ::proctrace::Trace $name]]
    }
    
}


# ::proctrace::Proc -- Capturing procedure
#
#       This is our re-implementation of the proc command. It calls the original
#       command and also arranges to install traces if appropriate.
#
# Arguments:
#        name        Name of procedure
#        arglist        List of arguments to procedure
#        body        Procedure body.
#
# Results:
#       None.
#
# Side Effects:
#       Creates a new procedure, possibly arrange for tracing its execution.
proc ::proctrace::Proc { name arglist body } {
    uplevel 1 [list ::proctrace::RealProc $name $arglist $body]
    if { [Tracable $name]} {
        Follow $name 2
    }
}


# ::proctrace::Trace -- Perform trace
#
#       Trace procedure/command execution.
#
# Arguments:
#        name        Name of procedure
#        command        Command being executed
#        op        Operation (should be enter or enterstep, not used)
#
# Results:
#       None.
#
# Side Effects:
#       Trace execution on globally allocated file descriptor.
proc ::proctrace::Trace { name command op } {
    if {!$::proctrace::vars::enabled} {return}
    puts $vars::fd "$name >> $command"
    flush $vars::fd
}

# ::proctrace::Tracable -- Should procedure be traced
#
#       Decide if a procedure should be traced according to the -allowed and
#       -denied options that are global to this library.
#
# Arguments:
#        name        Fully-qualified procedure name
#
# Results:
#       1 if the procedure should be traced, 0 otherwise.
#
# Side Effects:
#       None.
proc ::proctrace::Tracable { name } {
    # Traverse -allow(ance) list to allow procedure.
    set allow 0
    foreach ptn ${vars::-allowed} {
        if { [string match $ptn $name] } {
            set allow 1
            break
        }
    }

    # Possibly negate previous allowance through matching the name against the
    # patterns in the -denied list.
    foreach ptn ${vars::-denied} {
        if { [string match $ptn $name] } {
            set allow 0
            break
        }
    }

    # Return final decision.
    return $allow
}

package provide proctrace $::proctrace::vars::version
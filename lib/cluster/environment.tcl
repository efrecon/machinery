package require cluster::utils

namespace eval ::cluster::environment {
    # Encapsulates variables global to this namespace under their own
    # namespace, an idea originating from http://wiki.tcl.tk/1489.
    # Variables which name start with a dash are options and which
    # values can be changed to influence the behaviour of this
    # implementation.
    namespace eval vars {
        # Extension for env storage cache files
        variable -ext         .env
        # Character for shell-compatible quoting
        variable -quote       "\""
        variable -backslashed {"\\\$" "\$" "\\\"" \" "\\'" ' "\\\\" "\\" "\\`" "`"}
    }
    # Export all lower case procedure, arrange to be able to access
    # commands from the parent (cluster) namespace from here and
    # create an ensemble command called swarmmode (note the leading :: to make
    # this a top-level command!) to ease API calls.
    namespace export {[a-z]*}
    namespace path [namespace parent]
    namespace ensemble create -command ::environment
    namespace import [namespace parent]::CacheFile \
                        [namespace parent]::utils::log
}


# ::cluster::environment::set -- Set environement
#
#       Set the (discovery) environment based on the origin of a
#       virtual machine.
#
# Arguments:
#	vm	Virtual machine description
#
# Results:
#       Return the full dictionary of what was set, empty dict on errors.
#
# Side Effects:
#       Changes the ::env global array, which will be passed to sub-processes.
proc ::cluster::environment::set { vm } {
    if { [dict exists $vm origin] } {
        ::set environment [read [cache $vm]]
        dict for {k v} $environment {
            ::set ::env($k) $v
        }
    } else {
        ::set environment {}
    }
    
    return $environment
}


proc ::cluster::environment::cache { vm } {
    return [CacheFile [dict get $vm origin] ${vars::-ext}]
}


# ::cluster::environment::read -- Read an environment file
#
#       Read the content of an environment file, such as the ones used
#       for declaring defaults in /etc (or for our discovery cache).
#       This isn't a perfect parser, but is able to skip comments and
#       blank lines.
#
# Arguments:
#        fpath        Full path to file to read
#
# Results:
#       Content of file as a dictionary
#
# Side Effects:
#       None.
proc ::cluster::environment::read { fpath } {
    ::set d [dict create]
    if { [file exists $fpath] } {
        log DEBUG "Reading environment description file at $fpath"
        ::set fd [open $fpath]
        while {![eof $fd]} {
            line d [gets $fd]
        }
        close $fd
    }
    log DEBUG "Read [join [dict keys $d] {, }] from $fpath"
    
    return $d
}


# ::cluster::environment::line -- Parse lines of environment files
#
#       Parses the line passed as an argument and set the
#       corresponding keys in the dictionary from the arguments.
#
# Arguments:
#	d_	Name of dictionary variable to modify
#	line	Line to parse
#
# Results:
#       Return the key that was extracted from the line, or an empty
#       string on errors, empty lines, comments, etc.
#
# Side Effects:
#       None.
proc ::cluster::environment::line { d_ line } {
    upvar $d_ d;   # Get to the dictionary variable.
    ::set line [string trim $line]
    if { $line ne "" || [string index $line 0] ne "\#" } {
        # Skip leading "export" bash instruction
        if { [string first "export " $line] == 0 } {
            ::set line [string trim \
                    [string range $line [string length "export "] end]]
        }
        ::set eql [string first "=" $line]
        if { $eql >= 0 } {
            ::set k [string trim [string range $line 0 [expr {$eql-1}]]]
            ::set v [string trim [string range $line [expr {$eql+1}] end]]
			::set v [string trim $v "\"'"];  # Remove UNIX outer-quoting
            # Replace backslashed characters
			::set v [string map ${vars::-backslashed} $v]

            dict set d $k $v
            return $k
        }
    }
    return ""
}


# ::cluster::environment::write -- Write an environment file
#
#       Write the content of a dictionary to an environment file.
#
# Arguments:
#        fpath        Full path to file to write to (or file descriptor)
#        enviro       Environment to write
#        lead         String to insert at beginning of each line
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::cluster::environment::write { fpath enviro { lead "" } } {
    log DEBUG "Writing [join [dict keys $enviro] {, }] to\
               description file at $fpath"
    if { [catch {fconfigure $fpath} res] == 0 } {
        ::set fd $fpath
    } else {
        ::set fd [open $fpath "w"]
    }
    dict for {k v} $enviro {
        if { [string first " " $v] < 0 } {
            puts $fd "${lead}${k}=${v}"
        } else {
            puts $fd "${lead}${k}=${vars::-quote}${v}${vars::-quote}"
        }
    }
    if { $fd ne $fpath } {
        close $fd
    }
}


# ::cluster::environment::resolve -- Environement variable resolution
#
#       This procedure will resolve every occurence of a construct
#       $name where name is the name of an environment variable to the
#       value of that variable, as long as it exists.  It also
#       recognises ${name} and ${name:default} (i.e. replace by the
#       content of the variable if it exists, or by the default value
#       if the variable does not exist).
#
# Arguments:
#        str        Incoming string
#
# Results:
#       String where environment variables have been resolved to their
#       values.
#
# Side Effects:
#       None.
proc ::cluster::environment::resolve { str } {
    # Do a quick string mapping for $VARNAME and ${VARNAME} and store
    # result in variable called quick.
    ::set mapper {}
    foreach e [array names ::env] {
        lappend mapper \$${e} [::set ::env($e)]
        lappend mapper \$\{${e}\} [::set ::env($e)]
    }
    ::set quick [string map $mapper $str]
    
    # Iteratively modify quick for replacing occurences of
    # ${name:default} constructs.  We do this until there are no
    # match.
    ::set done 0
    # The regexp below using varnames as bash seems to be considering
    # them.
    ::set exp "\\$\{(\[a-zA-Z_\]+\[a-zA-Z0-9_\]*):(-?)(\[^\}\]*?)\}"
    while { !$done } {
        # Look for the expression and if we have a match, extract the
        # name of the variable.
        ::set rpl [regexp -inline -indices -- $exp $quick]
        if { [llength $rpl] >= 3 } {
            lassign $rpl range var marker dft
            lassign $range range_start range_stop
            lassign $var var_start var_stop
            lassign $marker marker_start marker_stop
            lassign $dft dft_start dft_stop
            ::set var [string range $quick $var_start $var_stop]
            ::set marker [string range $quick $marker_start $marker_stop]
            ::set dft [string range $quick $dft_start $dft_stop]
            # If that variable is declared and exist, replace by its
            # value, otherwise replace with the default value.
            if { [info exists ::env($var)] } {
                if { $marker eq "-" && [::set ::env($var)] eq ""  } {
                    ::set quick \
                        [string replace $quick $range_start $range_stop $dft]
                } else {
                    ::set quick \
                        [string replace $quick $range_start $range_stop \
                            [::set ::env($var)]]
                }
            } else {
                ::set quick \
                    [string replace $quick $range_start $range_stop $dft]
            }
        } else {
            ::set done 1
        }
    }
    
    return $quick
}


proc ::cluster::environment::quote { str } {
    ::set prev ""
    ::set ret ""
    foreach c [split $str ""] {
        if { $c in [list "(" ")" "'" "\"" "\$"] && $prev ne "\\" } {
            append ret "\\" $c
        } else {
            append ret $c
        }
        ::set prev $c
    }
    return $ret
}


package provide cluster::environment 0.2
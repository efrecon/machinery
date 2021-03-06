package require yaml
package require huddle

package require cluster::vcompare

namespace eval ::cluster::extend {
    # Encapsulates variables global to this namespace under their own
    # namespace, an idea originating from http://wiki.tcl.tk/1489.
    # Variables which name start with a dash are options and which
    # values can be changed to influence the behaviour of this
    # implementation.
    namespace eval vars {
        # List of endings to trim away, in order from reconstructed YAML
        variable -trim        {- " \f\v\r\t\n"}
        # Indenting and wordwrapping options
        variable -indent      2
        variable -wordwrap    1024
    }
    # Export all lower case procedure, arrange to be able to access
    # commands from the parent (cluster) namespace from here and
    # create an ensemble command called swarmmode (note the leading :: to make
    # this a top-level command!) to ease API calls.
    namespace export {[a-z]*}
    namespace path [namespace parent]
    namespace ensemble create -command ::extend
}


# ::cluster::extend::linearise -- Linearise away 'extends'
#
#       Linearise YAML so it does not contain 'extends' instructions. Each
#       occurence of 'extends' will be resolved recursively and inserted into
#       the service description.
#
# Arguments:
#       yaml	Textual YAML content, as read from a file, for example
#       dir	    Original directory context where the content is coming from (empty==pwd)
#
# Results:
#       Return the same YAML content, where all references to other services
#       (pointed at by 'extends') have been recursively replaced by their
#       content.
#
# Side Effects:
#       None.
proc ::cluster::extend::linearise { yaml { dir "." } } {
    return [huddle2yaml [linearise2huddle $yaml $dir]]
}


# ::cluster::extend::linearise2huddle -- Linearise away 'extends' to huddle
#
#       Linearise YAML so it does not contain 'extends' instructions. Each
#       occurence of 'extends' will be resolved recursively and inserted into
#       the service description. This procedure returns the internal huddle
#       representation of the linearised result so that it can be process
#       further.
#
# Arguments:
#       yaml	Textual YAML content, as read from a file, for example
#       dir	    Original directory context where the content is coming from (empty==pwd)
#
# Results:
#       Return a huddle tree representation, where all references to other
#       services (pointed at by 'extends') have been recursively replaced by
#       their content.
#
# Side Effects:
#       None.
proc ::cluster::extend::linearise2huddle { yaml { dir "." } } {
    if { $dir eq "" } {
        set dir [pwd]
    }
    
    # Make sure we have "huddle get_stripped". This is to cope with earlier
    # versions of huddle in tcllib.
    if { [llength [info commands ::huddle::_gets]] } {
        proc ::huddle::get_stripped { src args } {
            return [uplevel 1 [linsert $args 0 huddle gets $src]]
        }
    }
    
    set hdl [::yaml::yaml2huddle $yaml]
    if { "services" in [huddle keys $hdl] } {
        foreach k [huddle keys $hdl] {
            if { $k ne "services" } {
                if { [info exists output] } {
                    huddle set output $k [huddle get $hdl $k]
                } else {
                    set output [huddle create $k [huddle get $hdl $k]]
                }
            }
        }
        huddle set output services [Services $dir [huddle get $hdl services]]
    } else {
        set output [Services $dir $hdl]
    }
    
    return $output
}


# ::cluster::extend::huddle2yaml -- Convert back to YAML
#
#       Convert back the huddle representation of a YAML file to YAML content.
#       This performs a number of cleanup and transformations to make docker
#       stack deploy happy with the input.
#
# Arguments:
#       hdl 	Huddle representation of YAML content
#
# Results:
#       Return YAML content ready to be given away to docker stack deploy or
#       docker-compose.
#
# Side Effects:
#       None.
proc ::cluster::extend::huddle2yaml { hdl } {
    # Trim for improved readability of the result
    set yaml [::yaml::huddle2yaml $hdl ${vars::-indent} ${vars::-wordwrap}]
    foreach trim ${vars::-trim} {
        set yaml [string trim $yaml $trim]
    }

    # Performs a number of textual translations on the output. At present, this
    # forces the version number to be represented as a string as docker stack
    # deploy is peaky about that very type, and arranges for values that end
    # with a : (and that could fool YAML parsing) to be enclosed by quotes.
    foreach translation [list \
                            "s/version:\\s*(\[0-9.\]+)/version: \"\\1\"/g" \
                            "s/^(\\s*)(\\w*):\\s*(.*:)$/\\1\\2: \"\\3\"/g" \
                            "s/^(\\s*)-\\s*(.*:)$/\\1- \"\\2\"/g" \
                            "s/^(\\s*)(cpus|memory):\\s*(\[0-9.\]+)$/\\1\\2: \"\\3\"/g"] {
        set yaml [Sed $translation $yaml]
    }
    
    return $yaml
}


# ::cluster::extend::Service -- Look for a service
#
#      Look for the description of a given services within a list of service and
#      return it.
#
# Arguments:
#      services List of services
#      srv      Name of service to look for
#
# Results:
#      Return the service description, or an empty dict
#
# Side Effects:
#      None.
proc ::cluster::extend::Service { services srv } {
    foreach s [huddle keys $services] {
        if { $s eq $srv } {
            return [huddle get $services $s]
        }
    }
    return [dict create]
}


# This is an ugly (and rather unprecise when it comes to version numbers) fix.
# Starting with later updates, the huddle2yaml implementation is broken as it
# does not properly supports its own types. The following fixes it in a rather
# ugly way, until this has made its way into the official implementation in
# tcllib.
if { [vcompare gt [package provide yaml] 0.3.7] } {
    proc ::yaml::_imp_huddle2yaml {data {offset ""}} {
        set nextoff "$offset[string repeat { } $yaml::_dumpIndent]"
        switch -glob -- [huddle type $data] {
            "int*" -
            "str*" {
                set data [huddle get_stripped $data]
                return [_dumpScalar $data $offset]
            }
            "sequence" -
            "list" {
                set inner {}
                set len [huddle llength $data]
                for {set i 0} {$i < $len} {incr i} {
                    set sub [huddle get $data $i]
                    set tsub [huddle type $sub]
                    set sep [expr {[string match "str*" $tsub] || [string match "int*" $tsub] ? " " : "\n"}]
                    lappend inner [join [list $offset - $sep [_imp_huddle2yaml $sub $nextoff]] ""]
                }
                return [join $inner "\n"]
            }
            "mapping" - 
            "dict" {
                set inner {}
                foreach {key} [huddle keys $data] {
                    set sub [huddle get $data $key]
                    set tsub [huddle type $sub]
                    set sep [expr {[string match "str*" $tsub] || [string match "int*" $tsub] ? " " : "\n"}]
                    lappend inner [join [list $offset $key: $sep [_imp_huddle2yaml $sub $nextoff]] ""]
                }
                return [join $inner "\n"]
            }
            default {
                return $data
            }
        }
    }
}


# ::cluster::extend::Combine -- combine together huddle YAML content
#
#      Given a huddle map representation, this procedure will merge onto of its
#      keys the content of another similar map.
#
# Arguments:
#      tgt_     Pointer to huddle map to modify
#      src      Huddle map to copy into map
#      allow    List of key matching patterns to consider when copying
#      deny     List of key matching patterns not to consider when copying
#
# Results:
#      List of keys that were combined
#
# Side Effects:
#      Actively modify the target
proc ::cluster::extend::Combine { tgt_ src {allow {*}} {deny {}} } {
    upvar $tgt_ tgt
    
    set combined [list]
    foreach k [huddle keys $src] {
        
        # Decide if the content of this key should be merged or not
        set allow 0
        foreach ptn $allow {
            if { [string match $ptn $k] } {
                set allow 1; break
            }
        }
        if { $allow } {
            foreach ptn $deny {
                if { [string match $ptn $k] } {
                    set allow 0; break
                }                
            }
        }
        
        if { $allow } {
            set v [huddle get $src $k]
            if { $k in [huddle keys $tgt] } {
                switch [huddle type $v] {
                    "mapping" -
                    "dict" {
                        huddle set tgt \
                            $k [huddle combine [huddle get $tgt $k] $v]
                    }
                    "sequence" -
                    "list" {
                        huddle set tgt \
                            $k [huddle combine [huddle get $tgt $k] $v]
                    }
                    default {
                        huddle set tgt $k $v
                    }
                }
            } else {
                huddle set tgt $k $v
            }
            lappend combined $k
        }
    }
    
    return $combined
}


# ::cluster::extend::Services -- Linarise services
#
#      Given a huddle representation of services (originating from a given
#      directory context), this procedure will replace all occurences of
#      services that contain an 'extends' directive with the description that
#      originates from the service pointed at by extend. This implementation is
#      aware both of extending within files, but also when referencing to
#      external files and will recurse as necessary
#
# Arguments:
#      dir      Context dictionary where the description is coming from
#      hdl      Huddle representation of the list of services.
#
# Results:
#      A linearised list of services.
#
# Side Effects:
#      None.
proc ::cluster::extend::Services { dir hdl } {
    # Access services (do this is in version dependent manner so we can support
    # the old v 1. file format and the new ones.
    if { "services" in [huddle keys $hdl] } {
        set services [huddle get $hdl services]
    } else {
        set services $hdl
    }

    # The YAML implementation relies on specific internal types in addition to
    # the types that are directly supported by huddle, the following copies the
    # incoming map of services and empties it in order to start from something
    # that has the same internal type (as opposed to create).
    set all_services $services
    foreach service [huddle keys $all_services] {
        set all_services [huddle remove $all_services $service]
    }
    
    foreach service [huddle keys $services] {
        set descr [huddle get $services $service]
        if { "extends" in [huddle keys $descr] } {
            # When a key called extends exist in the service description,
            # recursively go a look for the entire description of that service
            # and store this in the variable n_descr.
            set src [huddle get $descr extends]
            if { [string match "str*" [huddle type $src]] } {
                # When the value of what we extend is a string, this is the name
                # of a service that is already in this file, recurse using the
                # services that we already know of. 
                set n_descr [Service $all_services [huddle get_stripped $descr extends]]                
            } else {
                # Otherwise, we need to specify at least the name of a service
                # (in which case this is exactly the same as above), or a
                # service in another (relative) file.
                if { "service" in [huddle keys $src] } {
                    if { "file" in [huddle keys $src] } {
                        # When extending from a service in another file,
                        # recursively find the services in that file, look for
                        # that service use that description
                        set s_file [file join $dir [huddle get_stripped $src file]]
                        set s_dir [file dirname $s_file]
                        set in [open $s_file];        # Let it fail on purpose
                        set n_descr [Service \
                                        [Services $s_dir [::yaml::yaml2huddle [read $in]]] \
                                        [huddle get_stripped $src service]]
                        close $in
                    } else {
                        set n_descr [Service $all_services [huddle get_stripped $src service]]
                    }
                } else {
                    set n_descr {}
                }
            }
            
            
            # Now add the value of all local keys to n_descr, skip extend since
            # we have linearised above. We cannot simply copy into, since that
            # would loose value from the extended object, instead we arrange to
            # combine for composed-objects such as lists or dictionaries.
            Combine n_descr $descr [list *] [list "extends"]
            

            # Add this service to the list of linearised services.
            huddle set all_services $service $n_descr
        } else {
            # Since no extends exists in that service, add it to the list of
            # lineraised services verbatim.
            huddle set all_services $service $descr
        }
    }
    return $all_services
}


# ::cluster::extend::SedLine -- Mini-sed implementation
#
#      This is a minimal sed implementation that has been lifted up from toclbox
#      and also implements use of \1, \2, etc. in subgroups replacements.
#
# Arguments:
#      script   sed-like script. Not all syntax is supported!
#      input    Text to perform sed operations on.
#
# Results:
#      Return the result of the sed-like mini-language operation on the input.
#
# Side Effects:
#      None.
proc ::cluster::extend::SedLine {script input} {
    set sep [string index $script 1]
    foreach {cmd from to flag} [::split $script $sep] break
    switch -- $cmd {
        "s" {
            set cmd regsub
            if {[string first "g" $flag]>=0} {
                lappend cmd -all
            }
            if {[string first "i" [string tolower $flag]]>=0} {
                lappend cmd -nocase
            }
            set idx [regsub -all -- {[a-zA-Z]} $flag ""]
            if { [string is integer -strict $idx] } {
                set cmd [lreplace $cmd 0 0 regexp]
                lappend cmd -inline -indices -all -- $from $input
                set res [eval $cmd]
                if { [llength $res] } {
                    set which [lindex $res $idx]
                    # Create map for replacement of all subgroups, if necessary.
                    for {set i 1} {$i<[llength $res]} { incr i} {
                        foreach {b e} [lindex $res $i] break
                        lappend map "\\$i" [string range $input $b $e]
                    }
                    return [string replace $input [lindex $which 0] [lindex $which 1] [string map $map $to]]
                } else {
                    return $input
                }
            }
            # Most generic case
            lappend cmd -- $from $input $to
            return [eval $cmd]
        }
        "e" {
            set cmd regexp
            if { $to eq "" } { set to 0 }
            if {![string is integer -strict $to]} {
                return -error code "No proper group identifier specified for extraction"
            }
            lappend cmd -inline -- $from $input
            return [lindex [eval $cmd] $to]
        }
        "y" {
            return [string map [list $from $to] $input]
        }
    }
    return -code error "not yet implemented"
}

proc ::cluster::extend::Sed {script input} {
    set input [string map [list "\r\n" "\n" "\r" "\n"] $input]
    set output ""
    foreach line [split $input \n] {
        set res [SedLine $script $line]
        append output ${res}\n
    }
    return [string trimright $output \n]
}


package provide cluster::extend 0.1

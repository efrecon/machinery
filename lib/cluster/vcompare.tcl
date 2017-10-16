##################
## Module Name     --  cluster::vcompare
## Original Author --  Emmanuel Frecon - emmanuel@sics.se
## Description:
##
##      Provides facilities to compare version number.  This supports
##      semantic versioning, but will not handle numbers where the
##      dash sign is used to separate the main version number from a
##      release (alpha, beta, etc.) specification.
##
##################

package require cluster::utils

namespace eval ::cluster::vcompare {
    namespace eval vars {
        # Maximum of version dividers (dots in the number!)
        variable -depth   8
    }
    namespace export {[a-z]*}
    namespace path [namespace parent]
    namespace ensemble create -command ::vcompare
    namespace import [namespace parent]::utils::log
}


proc ::cluster::vcompare::depth { vernum } {
    return [llength [split $vernum .]]
}



proc ::cluster::vcompare::gt { current base } {
    set len [expr {max([depth $current],[depth $base])}]
    set l_current [Equalise $current $len]
    set l_base [Equalise $base $len]

    for {set i 0} {$i < $len} {incr i} {
        if { [lindex $l_current $i] > [lindex $l_base $i] } {
            return 1
        }
        if { [lindex $l_current $i] < [lindex $l_base $i] } {
            return 0
        }
    }
    return 0
}

proc ::cluster::vcompare::lt { current base } {
    return [expr {![ge $current $base]}]
}


proc ::cluster::vcompare::eq { current base } {
    set len [expr {max([depth $current],[depth $base])}]
    set l_current [Equalise $current $len]
    set l_base [Equalise $base $len]

    for {set i 0} {$i < $len} {incr i} {
        if { [lindex $l_current $i] != [lindex $l_base $i] } {
            return 0
        }
    }
    return 1
}

proc ::cluster::vcompare::ge { current base } {
    set len [expr {max([depth $current],[depth $base])}]
    set l_current [Equalise $current $len]
    set l_base [Equalise $base $len]

    for {set i 0} {$i < $len} {incr i} {
        if { [lindex $l_current $i] > [lindex $l_base $i] } {
            return 1
        }
        if { [lindex $l_current $i] < [lindex $l_base $i] } {
            return 0
        }
    }
    return 1
}

proc ::cluster::vcompare::le { current base } {
    return [expr !{gt $current $base}]
}


proc ::cluster::vcompare::extract { vline } {
    if { $vline ne "" } {
        if { [regexp {\d+(\.\d+)*} $vline version] } {
            return $version
        } else {
            log WARN "Cannot extract a version number out of '$vline'!"
        }
    }
    return ""
}



####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################

proc ::cluster::vcompare::Equalise { vernum {depth -1}} {
    if { $depth < 0 } {
        set depth ${vars::-depth}
    }

    set l_vernum [split $vernum .]
    while { [llength $l_vernum] < $depth } {
        lappend l_vernum 0
    }
    return $l_vernum
}

package provide cluster::vcompare 0.1

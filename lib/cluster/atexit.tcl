namespace eval AtExit {
    variable atExitScripts [list]
    variable trapped 0

    proc atExit script {
        variable atExitScripts
        variable trapped

        # Install CTRL+C handler if possible
        if { ! $trapped && [catch {package require Tclx} ver] == 0 } {
            signal trap SIGINT exit
            set trapped 1
        }
        
        lappend atExitScripts \
                [uplevel 1 [list namespace code $script]]
    }

    namespace export atExit
}

rename exit AtExit::ExitOrig
proc exit {{code 0}} {
    variable AtExit::atExitScripts
    set n [llength $atExitScripts]
    while {$n} {
        catch [lindex $atExitScripts [incr n -1]]
    }
    rename exit {}
    rename AtExit::ExitOrig exit
    namespace delete AtExit
    exit $code
}

namespace import AtExit::atExit

package provide atExit 1.0
# ZIP file constructor

package require zlib

namespace eval zipper {
    namespace export initialize
    namespace eval v {}
    catch {namespace ensemble create}
}
    
proc ::zipper::initialize {fd} {
    # Store file specific information in a separate namespace
    namespace eval v::$fd {}
    set v::${fd}::fd $fd
    set v::${fd}::base [tell $fd]
    set v::${fd}::toc [list]
    fconfigure $fd -translation binary -encoding binary
    # Arrange for access to callers, Tk-style
    interp alias {} [namespace current]::v::$fd {} [namespace current]::Dispatch $fd
    return [namespace current]::v::$fd
}

proc ::zipper::Dispatch { fd cmd args } {
    if { [string match {[a-z]*} $cmd] && [llength [info procs [namespace current]::$cmd]] } {
        if { [namespace exists [namespace current]::v::$fd] } {
            return [uplevel 1 [linsert $args 0 [namespace current]::$cmd $fd]]
        } else {
            return -code error "$fd doesn't refer to a zipper context"
        }
    } else {
        return -code error "$cmd is not a known zipper command"
    }
}

proc ::zipper::Emit { fd s} {
    puts -nonewline [set v::${fd}::fd] $s
}

proc ::zipper::DosTime {sec} {
    set f [clock format $sec -format {%Y %m %d %H %M %S} -gmt 1]
    regsub -all { 0(\d)} $f { \1} f
    foreach {Y M D h m s} $f break
    set date [expr {(($Y-1980)<<9) | ($M<<5) | $D}]
    set time [expr {($h<<11) | ($m<<5) | ($s>>1)}]
    return [list $date $time]
}

proc ::zipper::addentry {fd name contents {date ""} {force 0}} {
    if {$date == ""} { set date [clock seconds] }
    foreach {date time} [DosTime $date] break
    set flag 0
    set type 0 ;# stored
    set fsize [string length $contents]
    set csize $fsize
    set fnlen [string length $name]
    
    if {$force > 0 && $force != [string length $contents]} {
        set csize $fsize
        set fsize $force
        set type 8 ;# if we're passing in compressed data, it's deflated
    }
    
    if {[catch { zlib crc32 $contents } crc]} {
        set crc 0
    } elseif {$type == 0} {
        set cdata [zlib deflate $contents]
        if {[string length $cdata] < [string length $contents]} {
            set contents $cdata
            set csize [string length $cdata]
            set type 8 ;# deflate
        }
    }
    
    lappend v::${fd}::toc "[binary format a2c6ssssiiiss4ii PK {1 2 20 0 20 0} \
            $flag $type $time $date $crc $csize $fsize $fnlen \
            {0 0 0 0} 128 [tell [set v::${fd}::fd]]]$name"
    
    Emit $fd [binary format a2c4ssssiiiss PK {3 4 20 0} \
            $flag $type $time $date $crc $csize $fsize $fnlen 0]
    Emit $fd $name
    Emit $fd $contents
}

proc ::zipper::adddirentry {fd name {date ""} {force 0}} {
    if {$date == ""} { set date [clock seconds] }
    # remove trailing slashes and add new one
    set name "[string trimright $name /]/"
    foreach {date time} [DosTime $date] break
    set flag 2
    set type 0
    set crc 0
    set csize 0
    set fsize 0
    set fnlen [string length $name]
    
    lappend v::${fd}::toc "[binary format a2c6ssssiiiss4ii PK {1 2 20 0 20 0} \
            $flag $type $time $date $crc $csize $fsize $fnlen \
            {0 0 0 0} 128 [tell [set v::${fd}::fd]]]$name"
    Emit $fd [binary format a2c4ssssiiiss PK {3 4 20 0} \
            $flag $type $time $date $crc $csize $fsize $fnlen 0]
    Emit $fd $name
}

proc ::zipper::finalize { fd } {
    set pos [tell [set v::${fd}::fd]]
    
    set ntoc [llength [set v::${fd}::toc]]
    foreach x [set v::${fd}::toc] {
        Emit $fd $x
    }
    set v::${fd}::toc {}
    
    set len [expr {[tell [set v::${fd}::fd]] - $pos}]
    incr pos -[set v::${fd}::base]
    
    Emit $fd [binary format a2c2ssssiis PK {5 6} 0 0 $ntoc $ntoc $len $pos 0]
    namespace delete v::$fd
    
    return $fd
}

# test code below runs when this is launched as the main script
if {[info exists argv0] && [string match zipper* [file tail $argv0]]} {
    
    set zip [zipper initialize [open try.zip w]]
    
    set dirs [list .]
    while {[llength $dirs] > 0} {
        set d [lindex $dirs 0]
        set dirs [lrange $dirs 1 end]
        foreach f [lsort [glob -nocomplain [file join $d *]]] {
            if {[file isfile $f]} {
                regsub {^\./} $f {} f
                set fd [open $f]
                fconfigure $fd -translation binary -encoding binary
                $zip addentry $f [read $fd] [file mtime $f]
                close $fd
            } elseif {[file isdir $f]} {
                lappend dirs $f
            }
        }
    }
    
    close [$zip finalize]
    
    puts "size = [file size try.zip]"
    puts [exec unzip -v try.zip]
    
    file delete try.zip
}

package provide zipper 0.12

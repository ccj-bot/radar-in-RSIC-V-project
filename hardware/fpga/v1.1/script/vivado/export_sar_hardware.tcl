# HSI obtains the bitstream from the implementation run directory, including
# after manual write_bitstream on the post-route optimized design.
proc check_v11_bus_skew {export_dir} {
    set skew_text [report_bus_skew -return_string]
    set fh [open [file join $export_dir bus_skew.rpt] w]
    puts -nonewline $fh $skew_text
    close $fh
    if {[regexp {Slack\s+\(VIOLATED\)} $skew_text]} {
        error "v1.1 bus skew timing failed"
    }
}

proc export_v11_hardware {export_dir design_name} {
    set impl_dir [get_property DIRECTORY [get_runs impl_1]]
    set exported_bit [file join $export_dir system.bit]
    if {![file exists $exported_bit]} {error "Missing signed-off bit: $exported_bit"}
    file copy -force $exported_bit [file join $impl_dir [format "%s_wrapper.bit" $design_name]]
    write_hw_platform -fixed -include_bit -force -file [file join $export_dir [format "%s.xsa" $design_name]]
}

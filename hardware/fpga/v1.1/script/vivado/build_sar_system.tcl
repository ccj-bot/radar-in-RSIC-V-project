# -----------------------------------------------------------------------------
# build_sar_system.tcl
#
# Batch build script for the SAR system Vivado project and block design.
# Uses project mode, but is intended to run entirely from CLI.
# -----------------------------------------------------------------------------

proc parse_args {argv_list defaults_list} {
    array set opts $defaults_list

    set argc_local [llength $argv_list]
    set i 0
    while {$i < $argc_local} {
        set key [lindex $argv_list $i]
        incr i

        if {![string match -* $key]} {
            error "Unexpected positional argument: $key"
        }
        if {$i >= $argc_local} {
            error "Missing value for argument: $key"
        }

        set value [lindex $argv_list $i]
        incr i

        set key [string trimleft $key "-"]
        set opts($key) $value
    }

    return [array get opts]
}

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]
source [file join $script_dir export_sar_hardware.tcl]
set default_ps_init_tcl [file normalize [file join $script_dir ps7_2dfft_onboard_ref.tcl]]

array set opts [parse_args $argv {
    part xc7z020clg484-1
    project_name v11
    project_dir {}
    design_name system
    ip_repo_path {}
    export_dir {}
    build_step impl
    ps_init_tcl {}
    fclk_mhz 100
    common_sram_clock 1
    enable_hdmi_preview 1
    range_ifft_mode 0
    pl_iw_q_scale 26564
    jobs 1
}]

if {$opts(project_dir) eq {}} {
    set opts(project_dir) [file normalize [file join $repo_root vivado projects $opts(project_name)]]
} else {
    set opts(project_dir) [file normalize $opts(project_dir)]
}

if {$opts(ip_repo_path) eq {}} {
    set opts(ip_repo_path) [file normalize [file join $repo_root output ip_repo]]
} else {
    set opts(ip_repo_path) [file normalize $opts(ip_repo_path)]
}

if {$opts(export_dir) eq {}} {
    set opts(export_dir) [file normalize [file join $repo_root output export $opts(project_name)]]
} else {
    set opts(export_dir) [file normalize $opts(export_dir)]
}

if {$opts(part) ne "xc7z020clg484-1" || $opts(fclk_mhz) != 100} {
    error "v1.1 requires xc7z020clg484-1 at 100 MHz"
}
set_param general.maxThreads 2
set build_step [string tolower $opts(build_step)]
if {$build_step ni {bd synth impl}} {
    error "Unsupported build_step '$opts(build_step)'. Expected one of: bd, synth, impl."
}

if {$opts(ps_init_tcl) eq {} && [file exists $default_ps_init_tcl]} {
    set opts(ps_init_tcl) $default_ps_init_tcl
}

if {$opts(ps_init_tcl) ne {}} {
    set opts(ps_init_tcl) [file normalize $opts(ps_init_tcl)]
}

set axis_sink_src [file normalize [file join $repo_root rtl system axis_stream_sink.v]]
set create_bd_tcl [file normalize [file join $script_dir create_sar_system_bd.tcl]]
set sram_xdc_file [file normalize [file join $repo_root constraints sram_example sar_imaging_sram_pins.xdc]]

if {![file exists $axis_sink_src]} {
    error "Missing required source file: $axis_sink_src"
}
if {![file exists $create_bd_tcl]} {
    error "Missing BD creation script: $create_bd_tcl"
}
if {![file isdirectory $opts(ip_repo_path)]} {
    error "IP repository directory not found: $opts(ip_repo_path)"
}

puts "INFO: Project name  : $opts(project_name)"
puts "INFO: Project dir   : $opts(project_dir)"
puts "INFO: Part          : $opts(part)"
puts "INFO: Build step    : $build_step"
puts "INFO: FCLK0 MHz     : $opts(fclk_mhz)"
puts "INFO: Common SRAM clock: $opts(common_sram_clock)"
puts "INFO: HDMI preview : $opts(enable_hdmi_preview)"
puts "INFO: Range IFFT mode: $opts(range_ifft_mode)"
puts "INFO: IP repo path  : $opts(ip_repo_path)"
puts "INFO: Export dir    : $opts(export_dir)"
puts "INFO: PS init Tcl   : $opts(ps_init_tcl)"
puts "INFO: Vivado jobs   : $opts(jobs)"

file mkdir [file dirname $opts(project_dir)]
cd [file dirname $opts(project_dir)]

create_project -force $opts(project_name) $opts(project_dir) -part $opts(part)
set_property target_language Verilog [current_project]

add_files -fileset sources_1 -norecurse $axis_sink_src
if {[file exists $sram_xdc_file]} {
    add_files -fileset constrs_1 -norecurse $sram_xdc_file
}
set_property ip_repo_paths [list $opts(ip_repo_path)] [current_project]
update_ip_catalog

source $create_bd_tcl
create_sar_system_bd $opts(design_name) $opts(ps_init_tcl) $opts(fclk_mhz) $opts(common_sram_clock) $opts(enable_hdmi_preview) $opts(range_ifft_mode) $opts(pl_iw_q_scale)

set bd_file [lindex [get_files -quiet ${opts(design_name)}.bd] 0]
if {$bd_file eq {}} {
    error "Unable to locate generated BD file for design $opts(design_name)"
}

validate_bd_design
save_bd_design
generate_target all $bd_file

set wrapper_file [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper_file
update_compile_order -fileset sources_1
set_property top ${opts(design_name)}_wrapper [current_fileset]

if {$build_step eq "bd"} {
    puts "INFO: BD generation completed. Stopping at build_step=bd."
    close_project
    exit
}

if {$opts(jobs) <= 1} {
    set ooc_synth_runs {}
    foreach run_obj [get_runs -quiet *_synth_1] {
        set run_name [get_property NAME $run_obj]
        if {$run_name ne "synth_1"} {
            lappend ooc_synth_runs $run_obj
        }
    }

    foreach run_obj $ooc_synth_runs {
        set run_name [get_property NAME $run_obj]
        if {[get_property PROGRESS $run_obj] ne "100%"} {
            puts "INFO: Launching OOC synth run sequentially: $run_name"
            launch_runs $run_obj -jobs 1
            wait_on_run $run_obj
        }
        if {[get_property PROGRESS $run_obj] ne "100%"} {
            error "OOC synthesis run '$run_name' did not complete successfully."
        }
    }
}

launch_runs synth_1 -jobs $opts(jobs)
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Synthesis did not complete successfully."
}

if {$build_step eq "synth"} {
    puts "INFO: Synthesis completed. Stopping at build_step=synth."
    close_project
    exit
}

launch_runs impl_1 -to_step route_design -jobs $opts(jobs)
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Implementation/bitstream generation did not complete successfully."
}

file mkdir $opts(export_dir)
open_run impl_1
# Optimize the actual routed design; never lower the processing clock.
for {set attempt 0} {$attempt < 3} {incr attempt} {
    phys_opt_design -directive AggressiveExplore
    route_design -directive Explore
    set setup_path [get_timing_paths -delay_type max -max_paths 1]
    set hold_path [get_timing_paths -delay_type min -max_paths 1]
    if {[llength $setup_path] == 0 || [llength $hold_path] == 0} {
        error "Missing constrained timing paths"
    }
    set wns [get_property SLACK $setup_path]
    set whs [get_property SLACK $hold_path]
    puts "INFO: v1.1 post-route attempt $attempt WNS=$wns WHS=$whs"
    if {$wns >= 0 && $whs >= 0} {break}
}
report_timing_summary -delay_type min_max -max_paths 20 -report_unconstrained -file [file join $opts(export_dir) timing_summary.rpt]
check_v11_bus_skew $opts(export_dir)
report_utilization -file [file join $opts(export_dir) utilization.rpt]
report_route_status -file [file join $opts(export_dir) route_status.rpt]
report_drc -file [file join $opts(export_dir) drc.rpt]
write_checkpoint -force [file join $opts(export_dir) system_routed.dcp]
set bad_drc [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {$wns < 0 || $whs < 0 || [llength $bad_drc] > 0} {
    error "v1.1 signoff failed: WNS=$wns WHS=$whs DRC_errors=[llength $bad_drc]"
}
write_bitstream -force [file join $opts(export_dir) system.bit]
export_v11_hardware $opts(export_dir) $opts(design_name)

set ps7_init_candidates [glob -nocomplain -types f \
    [file join $opts(project_dir) "$opts(project_name).gen" sources_1 bd $opts(design_name) ip *processing_system7* ps7_init.tcl]]
if {[llength $ps7_init_candidates] > 0} {
    set exported_ps7_init [file join $opts(export_dir) ps7_init.tcl]
    file copy -force [lindex $ps7_init_candidates 0] $exported_ps7_init
    puts "INFO: Exported PS init Tcl: $exported_ps7_init"
} else {
    puts "WARNING: No generated ps7_init.tcl found under $opts(project_dir)"
}

puts "INFO: Build completed successfully."
puts "INFO: Exported XSA: [file join $opts(export_dir) ${opts(design_name)}.xsa]"

close_project

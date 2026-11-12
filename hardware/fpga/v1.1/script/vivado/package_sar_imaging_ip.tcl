# -----------------------------------------------------------------------------
# package_sar_imaging_ip.tcl
#
# Batch-packages rtl/system/sar_imaging_top.v as a reusable Vivado IP.
#
# Default usage:
#   vivado -mode batch -source script/vivado/package_sar_imaging_ip.tcl
#
# Common overrides:
#   vivado -mode batch -source script/vivado/package_sar_imaging_ip.tcl -- \
#     -part xc7z020clg484-1 \
#     -ip_root E:/tmp/ip_repo/sar_imaging_top
#
# Notes:
# - The script creates a temporary packaging project under vivado/projects/.
# - The packaged IP is emitted under output/ip_repo/sar_imaging_top by default.
# - Simulation-only files and deprecated postproc AXI wrapper files are excluded.
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

proc collect_files_recursive {root extensions exclude_names} {
    set collected {}
    if {![file exists $root]} {
        return $collected
    }

    foreach item [glob -nocomplain -directory $root *] {
        if {[file isdirectory $item]} {
            set nested [collect_files_recursive $item $extensions $exclude_names]
            if {[llength $nested] > 0} {
                set collected [concat $collected $nested]
            }
            continue
        }

        set tail [file tail $item]
        if {[lsearch -exact $exclude_names $tail] >= 0} {
            continue
        }

        if {[lsearch -exact $extensions [file extension $item]] >= 0} {
            lappend collected [file normalize $item]
        }
    }

    return $collected
}

proc ensure_bus_parameter {busif param_name param_value} {
    set existing [ipx::get_bus_parameters $param_name -of_objects $busif]
    if {[llength $existing] == 0} {
        set existing [ipx::add_bus_parameter $param_name $busif]
    }
    set_property value $param_value $existing
}

proc assert_bus_interfaces_exist {core interface_names} {
    foreach if_name $interface_names {
        if {[llength [ipx::get_bus_interfaces $if_name -of_objects $core]] == 0} {
            error "Expected inferred bus interface '$if_name' was not found. Check top-level port naming."
        }
    }
}

proc xml_path_variants {path_value} {
    set normalized [string map {\\ /} [file normalize $path_value]]
    set drive_lower [format "%s%s" [string tolower [string index $normalized 0]] [string range $normalized 1 end]]
    return [list $normalized $drive_lower [string tolower $normalized]]
}

proc ensure_component_files_present {component_xml relative_paths file_type user_file_type} {
    set fh [open $component_xml r]
    set xml_text [read $fh]
    close $fh

    set changed 0
    foreach rel_path $relative_paths {
        if {[string first "<spirit:name>$rel_path</spirit:name>" $xml_text] >= 0} {
            continue
        }

        set insert_block [format {      <spirit:file>
        <spirit:name>%s</spirit:name>
        <spirit:fileType>%s</spirit:fileType>
        <spirit:userFileType>%s</spirit:userFileType>
      </spirit:file>
} $rel_path $file_type $user_file_type]

        set synth_end_tag "    </spirit:fileSet>\n    <spirit:fileSet>\n      <spirit:name>xilinx_anylanguagebehavioralsimulation</spirit:name>"
        set repl "${insert_block}${synth_end_tag}"
        if {[string first $synth_end_tag $xml_text] >= 0} {
            set xml_text [string map [list $synth_end_tag $repl] $xml_text]
            set changed 1
        }

        set sim_end_tag "    </spirit:fileSet>\n    <spirit:fileSet>\n      <spirit:name>xilinx_utilityxitfiles</spirit:name>"
        set repl "${insert_block}${sim_end_tag}"
        if {[string first $sim_end_tag $xml_text] >= 0} {
            set xml_text [string map [list $sim_end_tag $repl] $xml_text]
            set changed 1
        }
    }

    if {$changed} {
        set fh [open $component_xml w]
        puts -nonewline $fh $xml_text
        close $fh
    }
}

proc fix_packaged_raw_includes {repo_root ip_root} {
    set src_dir        [file join $ip_root src]
    set raw_src_dir    [file join $src_dir raw]
    set raw_origin_dir [file join $repo_root rtl 2D_fft fft raw]
    set component_xml  [file join $ip_root component.xml]

    if {![file exists $component_xml]} {
        error "Missing packaged component.xml at $component_xml"
    }

    file mkdir $raw_src_dir

    set raw_files [glob -nocomplain -directory $raw_origin_dir *.txt]
    foreach raw_file $raw_files {
        set raw_tail [file tail $raw_file]
        set raw_root [file rootname $raw_tail]
        file copy -force $raw_file [file join $raw_src_dir $raw_tail]
        file copy -force $raw_file [file join $raw_src_dir ${raw_root}.vh]
    }

    foreach factor_file [glob -nocomplain -directory $src_dir FactorW*.v] {
        set fh [open $factor_file r]
        set factor_text [read $fh]
        close $fh

        foreach raw_file $raw_files {
            set raw_tail [file tail $raw_file]
            set raw_root [file rootname $raw_tail]
            set factor_text [string map [list "./raw/$raw_tail" "./raw/${raw_root}.vh"] $factor_text]
        }

        set fh [open $factor_file w]
        puts -nonewline $fh $factor_text
        close $fh
    }

    set fh [open $component_xml r]
    set xml_text [read $fh]
    close $fh

    foreach raw_file $raw_files {
        set raw_tail [file tail $raw_file]
        set raw_root [file rootname $raw_tail]
        set replacements {}
        foreach raw_abs [xml_path_variants $raw_file] {
            lappend replacements $raw_abs "src/raw/${raw_root}.vh"
        }
        lappend replacements "src/raw/$raw_tail" "src/raw/${raw_root}.vh"
        set xml_text [string map $replacements $xml_text]

        set raw_block_old [format {      <spirit:file>
        <spirit:name>src/raw/%s.vh</spirit:name>
        <spirit:userFileType>text</spirit:userFileType>
        <spirit:isIncludeFile>true</spirit:isIncludeFile>
      </spirit:file>
} $raw_root]
        set raw_block_new [format {      <spirit:file>
        <spirit:name>src/raw/%s.vh</spirit:name>
        <spirit:fileType>verilogSource</spirit:fileType>
        <spirit:userFileType>IMPORTED_FILE</spirit:userFileType>
        <spirit:isIncludeFile>true</spirit:isIncludeFile>
      </spirit:file>
} $raw_root]
        set xml_text [string map [list $raw_block_old $raw_block_new] $xml_text]

        set duplicate_block [format {      <spirit:file>
        <spirit:name>src/%s</spirit:name>
        <spirit:fileType>verilogSource</spirit:fileType>
        <spirit:userFileType>IMPORTED_FILE</spirit:userFileType>
        <spirit:isIncludeFile>true</spirit:isIncludeFile>
      </spirit:file>
} $raw_tail]
        set xml_text [string map [list $duplicate_block ""] $xml_text]

        set flat_copy [file join $src_dir $raw_tail]
        if {[file exists $flat_copy]} {
            file delete -force $flat_copy
        }
    }

    foreach include_dep_path [xml_path_variants [file join $repo_root rtl 2D_fft fft]] {
        set include_dep [format {      <spirit:dependency>%s</spirit:dependency>
} $include_dep_path]
        set xml_text [string map [list $include_dep ""] $xml_text]
    }

    set fh [open $component_xml w]
    puts -nonewline $fh $xml_text
    close $fh
}

proc fix_packaged_reorder_tables {repo_root ip_root} {
    set src_dir           [file join $ip_root src]
    set transform_src_dir [file join $repo_root data scripts_output transform]
    set component_xml     [file join $ip_root component.xml]
    set fft2d_file        [file join $src_dir 2D_fft.v]

    if {![file exists $component_xml]} {
        error "Missing packaged component.xml at $component_xml"
    }
    if {![file exists $fft2d_file]} {
        error "Missing packaged 2D_fft.v at $fft2d_file"
    }

    set reorder_files [list lookup_table.mem lookup_table2.mem]
    foreach reorder_file $reorder_files {
        set origin_file [file join $transform_src_dir $reorder_file]
        if {![file exists $origin_file]} {
            error "Missing reorder table source file at $origin_file"
        }
        file copy -force $origin_file [file join $src_dir $reorder_file]
    }

    set fh [open $fft2d_file r]
    set fft2d_text [read $fh]
    close $fh

    set fft2d_text [string map [list \
        "../../scripts_output/transform/lookup_table.mem"  "lookup_table.mem" \
        "../../scripts_output/transform/lookup_table2.mem" "lookup_table2.mem" \
    ] $fft2d_text]

    set fh [open $fft2d_file w]
    puts -nonewline $fh $fft2d_text
    close $fh

    ensure_component_files_present \
        $component_xml \
        [list "src/lookup_table.mem" "src/lookup_table2.mem"] \
        "memoryInitializationFile" \
        "IMPORTED_FILE"
}

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir .. ..]]

array set opts [parse_args $argv {
    part xc7z020clg484-1
    vendor user.org
    library sar
    taxonomy /UserIP
    version 1.1
    project_dir {}
    ip_root {}
}]

if {$opts(project_dir) eq {}} {
    set opts(project_dir) [file normalize [file join $repo_root vivado projects sar_imaging_ip_pack]]
} else {
    set opts(project_dir) [file normalize $opts(project_dir)]
}

if {$opts(ip_root) eq {}} {
    set opts(ip_root) [file normalize [file join $repo_root output ip_repo sar_imaging_top]]
} else {
    set opts(ip_root) [file normalize $opts(ip_root)]
}

set tmp_proj_dir $opts(project_dir)
set ip_root      $opts(ip_root)

set exclude_names [list \
    ddr_sim_subsystem.v \
    matrix_transpose_ddr_sim.v \
    matrix_transpose_ideal.v \
    AXI4_MT_DDR.v \
    AXI4_MT_DDR_master_full_v1_0_S00_AXI_DDR.v \
    AXI4_MT_LITE.v \
    AXI4_MT_LITE_slave_lite_v1_0_S00_AXI_LITE.v \
    AXI4_MT_Stream.v \
    AXI4_MT_Stream_master_stream_v1_0_M00_AXIS_Stream.v \
]

set rtl_files {}
foreach rtl_dir [list \
    [file join $repo_root rtl system] \
    [file join $repo_root rtl pl_iw] \
    [file join $repo_root rtl 2D_fft] \
    [file join $repo_root rtl common] \
    [file join $repo_root rtl interp2] \
    [file join $repo_root rtl interp2_axi] \
    [file join $repo_root rtl axi] \
    [file join $repo_root rtl common] \
] {
    set rtl_files [concat $rtl_files [collect_files_recursive $rtl_dir {.v .sv} $exclude_names]]
}

set rtl_files [concat $rtl_files \
    [collect_files_recursive [file join $repo_root rtl hdmi_test rgb2dvi] {.vhd} {}]]

lappend rtl_files \
    [file normalize [file join $repo_root data scripts_output transform lookup_table.mem]] \
    [file normalize [file join $repo_root data scripts_output transform lookup_table2.mem]]

lappend rtl_files \
    [file normalize [file join $repo_root rtl postproc sar_postproc_gamma_stream.v]] \
    [file normalize [file join $repo_root rtl postproc pwl_gamma.v]]

set rtl_files [lsort -unique $rtl_files]

puts "INFO: Packaging sar_imaging_top from $repo_root"
puts "INFO: Temporary Vivado project: $tmp_proj_dir"
puts "INFO: IP output root: $ip_root"

catch {close_project}
file mkdir [file dirname $tmp_proj_dir]
if {[file exists $tmp_proj_dir]} {
    file delete -force $tmp_proj_dir
}
cd [file dirname $tmp_proj_dir]
create_project -force sar_imaging_ip_pack $tmp_proj_dir -part $opts(part)
set_property target_language Verilog [current_project]

add_files -fileset sources_1 -norecurse $rtl_files
set_property include_dirs [list [file normalize [file join $repo_root rtl 2D_fft fft]]] [get_filesets sources_1]
set_property top sar_imaging_top [get_filesets sources_1]
update_compile_order -fileset sources_1

if {[file exists $ip_root]} {
    file delete -force $ip_root
}
file mkdir [file dirname $ip_root]

ipx::package_project \
    -root_dir $ip_root \
    -vendor $opts(vendor) \
    -library $opts(library) \
    -taxonomy $opts(taxonomy) \
    -import_files \
    -set_current true

set core [ipx::current_core]
set_property name sar_imaging_top $core
set_property display_name {SAR Imaging v1.1 with PL Descriptor Generator} $core
set_property description {SAR imaging top-level with AXI-Lite control, AXI DDR masters, and AXI-Stream frame I/O.} $core
set_property version $opts(version) $core

assert_bus_interfaces_exist $core {s_axi m_axi_mag m_axi_trans m_axi_hdmi s_axis_echo s_axis_index_weight m_axis_image}

set associated_busifs {}
foreach if_name {s_axi m_axi_mag m_axi_trans m_axi_hdmi s_axis_echo s_axis_index_weight m_axis_image m_axis_interp2} {
    if {[llength [ipx::get_bus_interfaces $if_name -of_objects $core]] > 0} {
        lappend associated_busifs $if_name
    }
}

set clk_busif [lindex [ipx::get_bus_interfaces aclk -of_objects $core] 0]
if {$clk_busif ne {}} {
    ensure_bus_parameter $clk_busif ASSOCIATED_BUSIF [join $associated_busifs ":"]
    ensure_bus_parameter $clk_busif ASSOCIATED_RESET aresetn
}

set rst_busif [lindex [ipx::get_bus_interfaces aresetn -of_objects $core] 0]
if {$rst_busif ne {}} {
    ensure_bus_parameter $rst_busif POLARITY ACTIVE_LOW
}

set irq_busif [lindex [ipx::get_bus_interfaces irq_frame_done -of_objects $core] 0]
if {$irq_busif ne {}} {
    ensure_bus_parameter $irq_busif SENSITIVITY EDGE_RISING
}

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core

close_project
fix_packaged_raw_includes $repo_root $ip_root
fix_packaged_reorder_tables $repo_root $ip_root
puts "INFO: Packaged IP written to $ip_root"

## 32 MHz oscillator and active-low START/STOP buttons
set_property PACKAGE_PIN N15 [get_ports clk32m]
set_property IOSTANDARD LVCMOS33 [get_ports clk32m]
create_clock -period 31.250 -name clk32m_in -waveform {0.000 15.625} [get_ports clk32m]

## SW1=START, SW2=STOP. Both are pulled up and active low.
set_property PACKAGE_PIN C14 [get_ports sw1_n]
set_property PACKAGE_PIN B13 [get_ports sw2_n]
set_property PACKAGE_PIN U13 [get_ports phy_nrst]
set_property IOSTANDARD LVCMOS33 [get_ports sw1_n]
set_property IOSTANDARD LVCMOS33 [get_ports sw2_n]
set_property IOSTANDARD LVCMOS33 [get_ports phy_nrst]

## Active-low system-health and acquisition LEDs
set_property PACKAGE_PIN R10 [get_ports system_status_led_n]
set_property PACKAGE_PIN D14 [get_ports capture_led_n]
set_property IOSTANDARD LVCMOS33 [get_ports {system_status_led_n capture_led_n}]
set_property DRIVE 8 [get_ports {system_status_led_n capture_led_n}]
set_property SLEW SLOW [get_ports {system_status_led_n capture_led_n}]

# Successful 24-channel sample-group monitor. MCU_REV_IO1 must remain an
# input/high-impedance on the MCU side while FPGA drives this net.
set_property PACKAGE_PIN M4 [get_ports sample_monitor]
set_property IOSTANDARD LVCMOS33 [get_ports sample_monitor]
set_property DRIVE 8 [get_ports sample_monitor]
set_property SLEW SLOW [get_ports sample_monitor]
set_property PULLUP true [get_ports sw1_n]
set_property PULLUP true [get_ports sw2_n]

## W25Q128 runtime SPI x1 pins. CCLK/E9 is driven only through STARTUPE2 and
## therefore is intentionally absent from the top-level port list.
set_property PACKAGE_PIN L13 [get_ports flash_cs_n]
set_property PACKAGE_PIN K17 [get_ports {flash_dq[0]}]
set_property PACKAGE_PIN K18 [get_ports {flash_dq[1]}]
set_property PACKAGE_PIN L14 [get_ports {flash_dq[2]}]
set_property PACKAGE_PIN M14 [get_ports {flash_dq[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {flash_cs_n {flash_dq[*]}}]
set_property DRIVE 8 [get_ports {flash_cs_n {flash_dq[0]}}]
set_property SLEW SLOW [get_ports {flash_cs_n {flash_dq[0]}}]
set_property PULLUP true [get_ports flash_cs_n]

## RTL8211FDI-CG RGMII receive pins from schematic page 8
set_property PACKAGE_PIN T11 [get_ports rgmii_rxc]
set_property PACKAGE_PIN U11 [get_ports rgmii_rx_ctl]
set_property PACKAGE_PIN U12 [get_ports {rgmii_rxd[0]}]
set_property PACKAGE_PIN V12 [get_ports {rgmii_rxd[1]}]
set_property PACKAGE_PIN V10 [get_ports {rgmii_rxd[2]}]
set_property PACKAGE_PIN V11 [get_ports {rgmii_rxd[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {rgmii_rxc rgmii_rx_ctl {rgmii_rxd[*]}}]
create_clock -period 8.000 -name rgmii_rxc_clk -waveform {0.000 4.000} [get_ports rgmii_rxc]
create_clock -period 8.000 -name rgmii_rxc_virtual -waveform {0.000 4.000}

## T11 is a regular I/O rather than an MRCC/SRCC pin.  This exception is
## limited to the schematic-mandated RXC net; the adaptive receiver verifies
## the complete frame FCS before accepting a tap/alignment combination.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports rgmii_rxc]]

## PHY RXDLY is strapped low.  IDELAYE2 supplies the required delay.  Constrain
## both DDR edges using conservative package-level source-synchronous skew.
set_input_delay -clock rgmii_rxc_virtual -max 0.500 [get_ports {{rgmii_rxd[*]} rgmii_rx_ctl}]
set_input_delay -clock rgmii_rxc_virtual -min -0.500 [get_ports {{rgmii_rxd[*]} rgmii_rx_ctl}]
set_input_delay -clock rgmii_rxc_virtual -clock_fall -max -add_delay 0.500 [get_ports {{rgmii_rxd[*]} rgmii_rx_ctl}]
set_input_delay -clock rgmii_rxc_virtual -clock_fall -min -add_delay -0.500 [get_ports {{rgmii_rxd[*]} rgmii_rx_ctl}]

## The non-dedicated RXC insertion invalidates only the conventional same-edge
## input hold relationship.  Setup checks remain active and the received FCS
## is the functional integrity check for every accepted frame.
set_false_path -hold -from [get_clocks rgmii_rxc_virtual] -to [get_cells -hier -filter {REF_NAME == IDDR}]

## RGMII transmit pins: identical to the verified 10000-packet UDP baseline
set_property PACKAGE_PIN U17 [get_ports {rgmii_txd[0]}]
set_property PACKAGE_PIN V16 [get_ports {rgmii_txd[1]}]
set_property PACKAGE_PIN V15 [get_ports {rgmii_txd[2]}]
set_property PACKAGE_PIN T16 [get_ports {rgmii_txd[3]}]
set_property PACKAGE_PIN U18 [get_ports rgmii_tx_ctl]
set_property PACKAGE_PIN U16 [get_ports rgmii_txc]
set_property IOSTANDARD LVCMOS33 [get_ports {{rgmii_txd[*]} rgmii_tx_ctl rgmii_txc}]
set_property SLEW FAST [get_ports {{rgmii_txd[*]} rgmii_tx_ctl rgmii_txc}]
set_property DRIVE 8 [get_ports {{rgmii_txd[*]} rgmii_tx_ctl rgmii_txc phy_nrst}]

create_generated_clock -name rgmii_txc_clk -source [get_pins u_clock_reset/u_mmcm/CLKOUT1] -divide_by 1 [get_ports rgmii_txc]
set_output_delay -clock rgmii_txc_clk -max 1.000 [get_ports {{rgmii_txd[*]} rgmii_tx_ctl}]
set_output_delay -clock rgmii_txc_clk -min -1.000 [get_ports {{rgmii_txd[*]} rgmii_tx_ctl}]
set_output_delay -clock rgmii_txc_clk -clock_fall -max -add_delay 1.000 [get_ports {{rgmii_txd[*]} rgmii_tx_ctl}]
set_output_delay -clock rgmii_txc_clk -clock_fall -min -add_delay -1.000 [get_ports {{rgmii_txd[*]} rgmii_tx_ctl}]

## RXC and the local MMCM clocks are unrelated.  Crossings use a dual-port RAM
## plus toggle/ack handshake and explicitly marked synchronizer registers.
set_clock_groups -asynchronous -group [get_clocks {rgmii_rxc_clk rgmii_rxc_virtual}] -group [get_clocks {clk32m_in clk125_mmcm clk125_90_mmcm clk200_mmcm rgmii_txc_clk}]

## Acquisition and Ethernet logic communicate only through explicit two-flop
## synchronizers and the XPM asynchronous FIFO.  Although both clocks originate
## from the same oscillator, their fractional MMCM relationship must not be used
## as a functional sampling relationship for those CDC interfaces.
set_clock_groups -asynchronous -group [get_clocks clk32m_in] -group [get_clocks {clk125_mmcm clk125_90_mmcm clk200_mmcm rgmii_txc_clk}]
set_false_path -from [get_ports {sw1_n sw2_n}]
set_false_path -to [get_ports phy_nrst]

## Reset is asserted from MMCM LOCKED and synchronously released separately in
## the 32, 125, 125-degree-shifted, 200 MHz and RXC domains.  No blanket reset
## false path is used; recovery/removal is contained by reset_sync instances.

## Three independent AD7606C-16 parallel interfaces.
set_property PACKAGE_PIN D10 [get_ports {adc1_os[0]}]
set_property PACKAGE_PIN A9 [get_ports {adc1_os[1]}]
set_property PACKAGE_PIN A10 [get_ports {adc1_os[2]}]
set_property PACKAGE_PIN C10 [get_ports adc1_par_ser_sel]
set_property PACKAGE_PIN C11 [get_ports adc1_nstby]
set_property PACKAGE_PIN A8 [get_ports adc1_range]
set_property PACKAGE_PIN H16 [get_ports adc1_convst]
set_property PACKAGE_PIN B9 [get_ports adc1_nwr]
set_property PACKAGE_PIN C9 [get_ports adc1_rst]
set_property PACKAGE_PIN D9 [get_ports adc1_nrd]
set_property PACKAGE_PIN K16 [get_ports adc1_ncs]
set_property PACKAGE_PIN J15 [get_ports adc1_busy]
set_property PACKAGE_PIN K15 [get_ports adc1_frstdata]
set_property PACKAGE_PIN J18 [get_ports {adc1_db[0]}]
set_property PACKAGE_PIN J17 [get_ports {adc1_db[1]}]
set_property PACKAGE_PIN F18 [get_ports {adc1_db[2]}]
set_property PACKAGE_PIN G18 [get_ports {adc1_db[3]}]
set_property PACKAGE_PIN D18 [get_ports {adc1_db[4]}]
set_property PACKAGE_PIN E18 [get_ports {adc1_db[5]}]
set_property PACKAGE_PIN C17 [get_ports {adc1_db[6]}]
set_property PACKAGE_PIN C16 [get_ports {adc1_db[7]}]
set_property PACKAGE_PIN H15 [get_ports {adc1_db[8]}]
set_property PACKAGE_PIN J14 [get_ports {adc1_db[9]}]
set_property PACKAGE_PIN G17 [get_ports {adc1_db[10]}]
set_property PACKAGE_PIN H17 [get_ports {adc1_db[11]}]
set_property PACKAGE_PIN J13 [get_ports {adc1_db[12]}]
set_property PACKAGE_PIN K13 [get_ports {adc1_db[13]}]
set_property PACKAGE_PIN D17 [get_ports {adc1_db[14]}]
set_property PACKAGE_PIN E17 [get_ports {adc1_db[15]}]

set_property PACKAGE_PIN E16 [get_ports {adc2_os[0]}]
set_property PACKAGE_PIN E15 [get_ports {adc2_os[1]}]
set_property PACKAGE_PIN A18 [get_ports {adc2_os[2]}]
set_property PACKAGE_PIN B18 [get_ports adc2_par_ser_sel]
set_property PACKAGE_PIN A14 [get_ports adc2_nstby]
set_property PACKAGE_PIN A13 [get_ports adc2_range]
set_property PACKAGE_PIN C15 [get_ports adc2_convst]
set_property PACKAGE_PIN A15 [get_ports adc2_nwr]
set_property PACKAGE_PIN B17 [get_ports adc2_rst]
set_property PACKAGE_PIN B16 [get_ports adc2_nrd]
set_property PACKAGE_PIN D13 [get_ports adc2_ncs]
set_property PACKAGE_PIN D12 [get_ports adc2_busy]
set_property PACKAGE_PIN F14 [get_ports adc2_frstdata]
set_property PACKAGE_PIN A1 [get_ports {adc2_db[0]}]
set_property PACKAGE_PIN B1 [get_ports {adc2_db[1]}]
set_property PACKAGE_PIN A3 [get_ports {adc2_db[2]}]
set_property PACKAGE_PIN A4 [get_ports {adc2_db[3]}]
set_property PACKAGE_PIN B4 [get_ports {adc2_db[4]}]
set_property PACKAGE_PIN C4 [get_ports {adc2_db[5]}]
set_property PACKAGE_PIN D7 [get_ports {adc2_db[6]}]
set_property PACKAGE_PIN E7 [get_ports {adc2_db[7]}]
set_property PACKAGE_PIN E5 [get_ports {adc2_db[8]}]
set_property PACKAGE_PIN E6 [get_ports {adc2_db[9]}]
set_property PACKAGE_PIN C7 [get_ports {adc2_db[10]}]
set_property PACKAGE_PIN D8 [get_ports {adc2_db[11]}]
set_property PACKAGE_PIN A5 [get_ports {adc2_db[12]}]
set_property PACKAGE_PIN A6 [get_ports {adc2_db[13]}]
set_property PACKAGE_PIN B6 [get_ports {adc2_db[14]}]
set_property PACKAGE_PIN B7 [get_ports {adc2_db[15]}]

set_property PACKAGE_PIN J5 [get_ports {adc3_os[0]}]
set_property PACKAGE_PIN H5 [get_ports {adc3_os[1]}]
set_property PACKAGE_PIN H6 [get_ports {adc3_os[2]}]
set_property PACKAGE_PIN K1 [get_ports adc3_par_ser_sel]
set_property PACKAGE_PIN K2 [get_ports adc3_nstby]
set_property PACKAGE_PIN J2 [get_ports adc3_range]
set_property PACKAGE_PIN D15 [get_ports adc3_convst]
set_property PACKAGE_PIN H4 [get_ports adc3_nwr]
set_property PACKAGE_PIN J4 [get_ports adc3_rst]
set_property PACKAGE_PIN G3 [get_ports adc3_nrd]
set_property PACKAGE_PIN G4 [get_ports adc3_ncs]
set_property PACKAGE_PIN F6 [get_ports adc3_busy]
set_property PACKAGE_PIN G6 [get_ports adc3_frstdata]
set_property PACKAGE_PIN E1 [get_ports {adc3_db[0]}]
set_property PACKAGE_PIN F1 [get_ports {adc3_db[1]}]
set_property PACKAGE_PIN G1 [get_ports {adc3_db[2]}]
set_property PACKAGE_PIN H1 [get_ports {adc3_db[3]}]
set_property PACKAGE_PIN C1 [get_ports {adc3_db[4]}]
set_property PACKAGE_PIN C2 [get_ports {adc3_db[5]}]
set_property PACKAGE_PIN G2 [get_ports {adc3_db[6]}]
set_property PACKAGE_PIN H2 [get_ports {adc3_db[7]}]
set_property PACKAGE_PIN D2 [get_ports {adc3_db[8]}]
set_property PACKAGE_PIN E2 [get_ports {adc3_db[9]}]
set_property PACKAGE_PIN F3 [get_ports {adc3_db[10]}]
set_property PACKAGE_PIN F4 [get_ports {adc3_db[11]}]
set_property PACKAGE_PIN D3 [get_ports {adc3_db[12]}]
set_property PACKAGE_PIN E3 [get_ports {adc3_db[13]}]
set_property PACKAGE_PIN D4 [get_ports {adc3_db[14]}]
set_property PACKAGE_PIN D5 [get_ports {adc3_db[15]}]

set_property IOSTANDARD LVCMOS33 [get_ports {adc1_* adc2_* adc3_*}]
set_property SLEW SLOW [get_ports {{adc1_os[*]} {adc2_os[*]} {adc3_os[*]} adc1_par_ser_sel adc2_par_ser_sel adc3_par_ser_sel adc1_nstby adc2_nstby adc3_nstby adc1_range adc2_range adc3_range adc1_convst adc2_convst adc3_convst adc1_rst adc2_rst adc3_rst adc1_ncs adc2_ncs adc3_ncs adc1_nwr adc2_nwr adc3_nwr adc1_nrd adc2_nrd adc3_nrd}]

## BUSY is asynchronous and terminates in explicitly marked two-flop chains.
set_false_path -from [get_ports {adc1_busy adc2_busy adc3_busy}] -to [get_cells -hierarchical -filter {NAME =~ *busy_sync1_reg}]

## FRSTDATA updates 30 ns after the RD falling edge. The parallel controller
## checks it with the DB word two 32 MHz clocks after that edge.
set_input_delay -clock clk32m_in -max 30.000 [get_ports {adc1_frstdata adc2_frstdata adc3_frstdata}]
set_input_delay -clock clk32m_in -min 0.000 [get_ports {adc1_frstdata adc2_frstdata adc3_frstdata}]
set_multicycle_path -setup -from [get_ports {adc1_frstdata adc2_frstdata adc3_frstdata}] 2
set_multicycle_path -hold -from [get_ports {adc1_frstdata adc2_frstdata adc3_frstdata}] 1

## DB becomes valid no later than 30 ns after RD falls. The controller samples
## it two 32 MHz cycles later. The setup multicycle describes this qualified
## capture window; hold is paired per the standard N/N-1 rule.
set_input_delay -clock clk32m_in -max 30.000 [get_ports {{adc1_db[*]} {adc2_db[*]} {adc3_db[*]}}]
set_input_delay -clock clk32m_in -min 0.000 [get_ports {{adc1_db[*]} {adc2_db[*]} {adc3_db[*]}}]
set_multicycle_path -setup -from [get_ports {{adc1_db[*]} {adc2_db[*]} {adc3_db[*]}}] 2
set_multicycle_path -hold -from [get_ports {{adc1_db[*]} {adc2_db[*]} {adc3_db[*]}}] 1

set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]


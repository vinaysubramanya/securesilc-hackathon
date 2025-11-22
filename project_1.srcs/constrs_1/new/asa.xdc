## basys3_echo_top.xdc
## Minimal constraints for echo_top.v (Basys-3)
## Save this file into your Vivado project and set top module = echo_top

## 100 MHz onboard clock
set_property PACKAGE_PIN W5 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

## Reset (use center pushbutton BTN_C) - active LOW in top (rstn)
set_property PACKAGE_PIN U18 [get_ports rstn]
set_property IOSTANDARD LVCMOS33 [get_ports rstn]
set_property PULLUP true [get_ports rstn]

## USB-UART (on-board FTDI -> FPGA pins)
## Basys-3: B18 = RsRx (FPGA receives from host), A18 = RsTx (FPGA transmits to host)
set_property PACKAGE_PIN B18 [get_ports uart_rx_pin]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx_pin]

set_property PACKAGE_PIN A18 [get_ports uart_tx_pin]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx_pin]

## (Optional) Add constraints for unused debug LEDs or buttons if you want to probe signals later.
## Example (uncomment and change port names if you expose dbg signals in your top):
## set_property PACKAGE_PIN U16 [get_ports dbg_rx_valid]
## set_property IOSTANDARD LVCMOS33 [get_ports dbg_rx_valid]
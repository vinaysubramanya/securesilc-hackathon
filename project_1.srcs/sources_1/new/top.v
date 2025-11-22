`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// echo_top.v - AES-128 over UART for Basys3 (using 25 MHz system clock)
// UART protocol:
//   'E' (0x45) + 16 bytes plaintext  -> 16 bytes ciphertext
//   'D' (0x44) + 16 bytes ciphertext -> 16 bytes plaintext (decrypt)
//   other commands are ignored
//////////////////////////////////////////////////////////////////////////////////

module echo_top (
    input  wire clk,          // 100 MHz clock from Basys3 (W5)
    input  wire rstn,         // active-LOW reset (BTN0 on U18), pulled up in XDC
    input  wire uart_rx_pin,  // from PC (FTDI RsRx, B18)
    output wire uart_tx_pin   // to PC   (FTDI RsTx, A18)
    // no LEDs here; you can add if desired
);
    localparam BAUD       = 115200;
    localparam integer UART_CLK_FREQ = 25_000_000;  // we will generate 25 MHz

    // -----------------------------
    // 100 MHz -> 25 MHz clock
    // -----------------------------
    wire clk25;

    clock_div_25mhz u_div (
        .clk100(clk),
        .rstn (rstn),
        .clk25(clk25)
    );

    // -----------------------------
    // UART RX / TX (run at 25 MHz)
    // -----------------------------
    wire [7:0] rx_byte;
    wire       rx_valid;
    reg  [7:0] tx_byte;
    reg        tx_start;
    wire       tx_busy;

    uart_rx #(
        .CLOCK_FREQ(UART_CLK_FREQ),
        .BAUD      (BAUD)
    ) u_rx (
        .clk   (clk25),
        .rstn  (rstn),
        .rx    (uart_rx_pin),
        .data  (rx_byte),
        .valid (rx_valid)
    );

    uart_tx #(
        .CLOCK_FREQ(UART_CLK_FREQ),
        .BAUD      (BAUD)
    ) u_tx (
        .clk     (clk25),
        .rstn    (rstn),
        .data_in (tx_byte),
        .start   (tx_start),
        .tx      (uart_tx_pin),
        .busy    (tx_busy)
    );

    // -----------------------------
    // AES Key & Key Expansion
    // -----------------------------
    // Fixed 128-bit key (you can change this):
    // Standard AES test key: 2b7e151628aed2a6abf7158809cf4f3c
    wire [127:0] aes_key = 128'h2b7e151628aed2a6abf7158809cf4f3c;
    wire [1407:0] round_keys;

    key_expand_128 u_kexp (
        .key_in     (aes_key),
        .round_keys (round_keys)
    );

    // -----------------------------
    // AES-128 Encryption Core
    // -----------------------------
    reg         enc_start;
    wire        enc_busy;
    wire        enc_done;
    reg  [127:0] aes_in_block;
    wire [127:0] aes_out_block;

    aes128_encrypt u_enc (
        .clk        (clk25),      // <<< run AES at 25 MHz
        .rstn       (rstn),
        .start      (enc_start),
        .block_in   (aes_in_block),
        .round_keys (round_keys),
        .block_out  (aes_out_block),
        .busy       (enc_busy),
        .done       (enc_done)
    );

    // -----------------------------
    // AES-128 Decryption Core
    // -----------------------------
    reg         dec_start;
    wire        dec_busy;
    wire        dec_done;
    wire [127:0] aes_out_block_dec;

    aes128_decrypt u_dec (
        .clk        (clk25),
        .rstn       (rstn),
        .start      (dec_start),
        .block_in   (aes_in_block),
        .round_keys (round_keys),
        .block_out  (aes_out_block_dec),
        .busy       (dec_busy),
        .done       (dec_done)
    );

    // -----------------------------
    // UART Command + AES FSM (also clk25)
    // -----------------------------
    localparam ST_IDLE   = 2'd0;
    localparam ST_RECV16 = 2'd1;
    localparam ST_WAIT   = 2'd2;
    localparam ST_SEND16 = 2'd3;

    reg [1:0]   state;
    reg [3:0]   byte_cnt;
    reg [127:0] data_buf;
    reg [127:0] out_buf;
    reg [3:0]   send_idx;
    reg [7:0]   cmd; // store 'E' or 'D'

    always @(posedge clk25 or negedge rstn) begin
        if (!rstn) begin
            state        <= ST_IDLE;
            byte_cnt     <= 4'd0;
            data_buf     <= 128'd0;
            aes_in_block <= 128'd0;
            enc_start    <= 1'b0;
            dec_start    <= 1'b0;
            out_buf      <= 128'd0;
            send_idx     <= 4'd0;
            tx_start     <= 1'b0;
            tx_byte      <= 8'd0;
            cmd          <= 8'd0;
        end else begin
            // default deassert one-cycle strobes
            enc_start <= 1'b0;
            dec_start <= 1'b0;
            tx_start  <= 1'b0;

            case (state)
                // Wait for 'E' or 'D' command
                ST_IDLE: begin
                    byte_cnt <= 4'd0;
                    if (rx_valid) begin
                        if (rx_byte == "E" || rx_byte == "e" ||
                            rx_byte == "D" || rx_byte == "d") begin
                            // store command and go receive 16 bytes
                            cmd <= rx_byte;
                            state <= ST_RECV16;
                        end
                        // else ignore other bytes
                    end
                end

                // Receive 16 bytes plaintext (for encrypt) or ciphertext (for decrypt)
                ST_RECV16: begin
                    if (rx_valid) begin
                        data_buf <= {data_buf[119:0], rx_byte};  // shift left, new byte in LSB
                        if (byte_cnt == 4'd15) begin
                            aes_in_block <= {data_buf[119:0], rx_byte};
                            // start appropriate core
                            if (cmd == "E" || cmd == "e")
                                enc_start <= 1'b1;
                            else
                                dec_start <= 1'b1;
                            state        <= ST_WAIT;
                        end else begin
                            byte_cnt <= byte_cnt + 1'b1;
                        end
                    end
                end

                // Wait until AES encryption or decryption done
                ST_WAIT: begin
                    if (enc_done || dec_done) begin
                        if (enc_done)
                            out_buf  <= aes_out_block;
                        else
                            out_buf  <= aes_out_block_dec;
                        send_idx <= 4'd0;
                        state    <= ST_SEND16;
                    end
                end

                // Send 16 bytes out over UART
                ST_SEND16: begin
                    if (!tx_busy) begin
                        tx_byte  <= out_buf[127 - 8*send_idx -: 8];
                        tx_start <= 1'b1;
                        if (send_idx == 4'd15) begin
                            state <= ST_IDLE;
                        end
                        send_idx <= send_idx + 1'b1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule


//=====================================================
// 100 MHz -> 25 MHz Clock Divider (÷4)
//=====================================================
module clock_div_25mhz (
    input  wire clk100,
    input  wire rstn,
    output wire clk25
);
    reg [1:0] cnt;

    always @(posedge clk100 or negedge rstn) begin
        if (!rstn) begin
            cnt <= 2'd0;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end

    assign clk25 = cnt[1]; // divides by 4 -> 25 MHz from 100 MHz
endmodule



//////////////////////////////////////////////////////////////////////////////////
// uart_rx.v - simple byte receiver (1 start,8,N,1) @ CLOCK_FREQ
//////////////////////////////////////////////////////////////////////////////////
module uart_rx #(
    parameter CLOCK_FREQ = 100_000_000,
    parameter BAUD       = 115200
)(
    input  wire clk,
    input  wire rstn,
    input  wire rx,
    output reg  [7:0] data,
    output reg        valid
);
    localparam integer CLKS_PER_BIT = CLOCK_FREQ / BAUD;

    reg [31:0] clk_cnt;
    reg [3:0]  bit_idx;
    reg        receiving;
    reg [7:0]  shift;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            clk_cnt   <= 0;
            bit_idx   <= 0;
            receiving <= 0;
            valid     <= 0;
            shift     <= 0;
            data      <= 8'd0;
        end else begin
            valid <= 0;
            if (!receiving) begin
                if (rx == 1'b0) begin
                    receiving <= 1'b1;
                    clk_cnt   <= CLKS_PER_BIT/2;
                    bit_idx   <= 0;
                end
            end else begin
                if (clk_cnt == CLKS_PER_BIT-1) begin
                    clk_cnt <= 0;
                    if (bit_idx < 4'd8) begin
                        shift[bit_idx] <= rx;
                        bit_idx <= bit_idx + 1'b1;
                    end else begin
                        data      <= shift;
                        valid     <= 1'b1;
                        receiving <= 1'b0;
                    end
                end else begin
                    clk_cnt <= clk_cnt + 1'b1;
                end
            end
        end
    end
endmodule


//////////////////////////////////////////////////////////////////////////////////
// uart_tx.v - simple transmitter (1 start,8,N,1) @ CLOCK_FREQ
//////////////////////////////////////////////////////////////////////////////////
module uart_tx #(
    parameter CLOCK_FREQ = 100_000_000,
    parameter BAUD       = 115200
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire [7:0]  data_in,
    input  wire        start,
    output reg         tx,
    output reg         busy
);
    localparam integer CLKS_PER_BIT = CLOCK_FREQ / BAUD;

    reg [31:0] clk_cnt;
    reg [3:0]  bit_idx;
    reg [9:0]  shift;
    reg        sending;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            tx      <= 1'b1;
            clk_cnt <= 0;
            bit_idx <= 0;
            busy    <= 0;
            shift   <= 10'h3FF;
            sending <= 0;
        end else begin
            if (start && !sending) begin
                // {stop bit, data[7:0], start bit}
                shift   <= {1'b1, data_in, 1'b0};
                sending <= 1'b1;
                busy    <= 1'b1;
                bit_idx <= 0;
                clk_cnt <= 0;
                tx      <= 1'b0;  // start bit
            end else if (sending) begin
                if (clk_cnt == CLKS_PER_BIT-1) begin
                    clk_cnt <= 0;
                    bit_idx <= bit_idx + 1'b1;
                    if (bit_idx < 4'd9) begin
                        tx <= shift[bit_idx];
                    end else begin
                        tx      <= 1'b1;  // back to idle
                        sending <= 1'b0;
                        busy    <= 1'b0;
                    end
                end else begin
                    clk_cnt <= clk_cnt + 1'b1;
                end
            end else begin
                tx   <= 1'b1;
                busy <= 1'b0;
            end
        end
    end
endmodule


//////////////////////////////////////////////////////////////////////////////////
// AES-128 S-box (encrypt)
//////////////////////////////////////////////////////////////////////////////////
module sbox (
    input  wire [7:0]  a,
    output reg  [7:0]  y
);
    always @* begin
        case (a)
            8'h00: y=8'h63; 8'h01: y=8'h7c; 8'h02: y=8'h77; 8'h03: y=8'h7b;
            8'h04: y=8'hf2; 8'h05: y=8'h6b; 8'h06: y=8'h6f; 8'h07: y=8'hc5;
            8'h08: y=8'h30; 8'h09: y=8'h01; 8'h0a: y=8'h67; 8'h0b: y=8'h2b;
            8'h0c: y=8'hfe; 8'h0d: y=8'hd7; 8'h0e: y=8'hab; 8'h0f: y=8'h76;

            8'h10: y=8'hca; 8'h11: y=8'h82; 8'h12: y=8'hc9; 8'h13: y=8'h7d;
            8'h14: y=8'hfa; 8'h15: y=8'h59; 8'h16: y=8'h47; 8'h17: y=8'hf0;
            8'h18: y=8'had; 8'h19: y=8'hd4; 8'h1a: y=8'ha2; 8'h1b: y=8'haf;
            8'h1c: y=8'h9c; 8'h1d: y=8'ha4; 8'h1e: y=8'h72; 8'h1f: y=8'hc0;

            8'h20: y=8'hb7; 8'h21: y=8'hfd; 8'h22: y=8'h93; 8'h23: y=8'h26;
            8'h24: y=8'h36; 8'h25: y=8'h3f; 8'h26: y=8'hf7; 8'h27: y=8'hcc;
            8'h28: y=8'h34; 8'h29: y=8'ha5; 8'h2a: y=8'he5; 8'h2b: y=8'hf1;
            8'h2c: y=8'h71; 8'h2d: y=8'hd8; 8'h2e: y=8'h31; 8'h2f: y=8'h15;

            8'h30: y=8'h04; 8'h31: y=8'hc7; 8'h32: y=8'h23; 8'h33: y=8'hc3;
            8'h34: y=8'h18; 8'h35: y=8'h96; 8'h36: y=8'h05; 8'h37: y=8'h9a;
            8'h38: y=8'h07; 8'h39: y=8'h12; 8'h3a: y=8'h80; 8'h3b: y=8'he2;
            8'h3c: y=8'heb; 8'h3d: y=8'h27; 8'h3e: y=8'hb2; 8'h3f: y=8'h75;

            8'h40: y=8'h09; 8'h41: y=8'h83; 8'h42: y=8'h2c; 8'h43: y=8'h1a;
            8'h44: y=8'h1b; 8'h45: y=8'h6e; 8'h46: y=8'h5a; 8'h47: y=8'ha0;
            8'h48: y=8'h52; 8'h49: y=8'h3b; 8'h4a: y=8'hd6; 8'h4b: y=8'hb3;
            8'h4c: y=8'h29; 8'h4d: y=8'he3; 8'h4e: y=8'h2f; 8'h4f: y=8'h84;

            8'h50: y=8'h53; 8'h51: y=8'hd1; 8'h52: y=8'h00; 8'h53: y=8'hed;
            8'h54: y=8'h20; 8'h55: y=8'hfc; 8'h56: y=8'hb1; 8'h57: y=8'h5b;
            8'h58: y=8'h6a; 8'h59: y=8'hcb; 8'h5a: y=8'hbe; 8'h5b: y=8'h39;
            8'h5c: y=8'h4a; 8'h5d: y=8'h4c; 8'h5e: y=8'h58; 8'h5f: y=8'hcf;

            8'h60: y=8'hd0; 8'h61: y=8'hef; 8'h62: y=8'haa; 8'h63: y=8'hfb;
            8'h64: y=8'h43; 8'h65: y=8'h4d; 8'h66: y=8'h33; 8'h67: y=8'h85;
            8'h68: y=8'h45; 8'h69: y=8'hf9; 8'h6a: y=8'h02; 8'h6b: y=8'h7f;
            8'h6c: y=8'h50; 8'h6d: y=8'h3c; 8'h6e: y=8'h9f; 8'h6f: y=8'ha8;

            8'h70: y=8'h51; 8'h71: y=8'ha3; 8'h72: y=8'h40; 8'h73: y=8'h8f;
            8'h74: y=8'h92; 8'h75: y=8'h9d; 8'h76: y=8'h38; 8'h77: y=8'hf5;
            8'h78: y=8'hbc; 8'h79: y=8'hb6; 8'h7a: y=8'hda; 8'h7b: y=8'h21;
            8'h7c: y=8'h10; 8'h7d: y=8'hff; 8'h7e: y=8'hf3; 8'h7f: y=8'hd2;

            8'h80: y=8'hcd; 8'h81: y=8'h0c; 8'h82: y=8'h13; 8'h83: y=8'hec;
            8'h84: y=8'h5f; 8'h85: y=8'h97; 8'h86: y=8'h44; 8'h87: y=8'h17;
            8'h88: y=8'hc4; 8'h89: y=8'ha7; 8'h8a: y=8'h7e; 8'h8b: y=8'h3d;
            8'h8c: y=8'h64; 8'h8d: y=8'h5d; 8'h8e: y=8'h19; 8'h8f: y=8'h73;

            8'h90: y=8'h60; 8'h91: y=8'h81; 8'h92: y=8'h4f; 8'h93: y=8'hdc;
            8'h94: y=8'h22; 8'h95: y=8'h2a; 8'h96: y=8'h90; 8'h97: y=8'h88;
            8'h98: y=8'h46; 8'h99: y=8'hee; 8'h9a: y=8'hb8; 8'h9b: y=8'h14;
            8'h9c: y=8'hde; 8'h9d: y=8'h5e; 8'h9e: y=8'h0b; 8'h9f: y=8'hdb;

            8'ha0: y=8'he0; 8'ha1: y=8'h32; 8'ha2: y=8'h3a; 8'ha3: y=8'h0a;
            8'ha4: y=8'h49; 8'ha5: y=8'h06; 8'ha6: y=8'h24; 8'ha7: y=8'h5c;
            8'ha8: y=8'hc2; 8'ha9: y=8'hd3; 8'haa: y=8'hac; 8'hab: y=8'h62;
            8'hac: y=8'h91; 8'had: y=8'h95; 8'hae: y=8'he4; 8'haf: y=8'h79;

            8'hb0: y=8'he7; 8'hb1: y=8'hc8; 8'hb2: y=8'h37; 8'hb3: y=8'h6d;
            8'hb4: y=8'h8d; 8'hb5: y=8'hd5; 8'hb6: y=8'h4e; 8'hb7: y=8'ha9;
            8'hb8: y=8'h6c; 8'hb9: y=8'h56; 8'hba: y=8'hf4; 8'hbb: y=8'hea;
            8'hbc: y=8'h65; 8'hbd: y=8'h7a; 8'hbe: y=8'hae; 8'hbf: y=8'h08;

            8'hc0: y=8'hba; 8'hc1: y=8'h78; 8'hc2: y=8'h25; 8'hc3: y=8'h2e;
            8'hc4: y=8'h1c; 8'hc5: y=8'ha6; 8'hc6: y=8'hb4; 8'hc7: y=8'hc6;
            8'hc8: y=8'he8; 8'hc9: y=8'hdd; 8'hca: y=8'h74; 8'hcb: y=8'h1f;
            8'hcc: y=8'h4b; 8'hcd: y=8'hbd; 8'hce: y=8'h8b; 8'hcf: y=8'h8a;

            8'hd0: y=8'h70; 8'hd1: y=8'h3e; 8'hd2: y=8'hb5; 8'hd3: y=8'h66;
            8'hd4: y=8'h48; 8'hd5: y=8'h03; 8'hd6: y=8'hf6; 8'hd7: y=8'h0e;
            8'hd8: y=8'h61; 8'hd9: y=8'h35; 8'hda: y=8'h57; 8'hdb: y=8'hb9;
            8'hdc: y=8'h86; 8'hdd: y=8'hc1; 8'hde: y=8'h1d; 8'hdf: y=8'h9e;

            8'he0: y=8'he1; 8'he1: y=8'hf8; 8'he2: y=8'h98; 8'he3: y=8'h11;
            8'he4: y=8'h69; 8'he5: y=8'hd9; 8'he6: y=8'h8e; 8'he7: y=8'h94;
            8'he8: y=8'h9b; 8'he9: y=8'h1e; 8'hea: y=8'h87; 8'heb: y=8'he9;
            8'hec: y=8'hce; 8'hed: y=8'h55; 8'hee: y=8'h28; 8'hef: y=8'hdf;

            8'hf0: y=8'h8c; 8'hf1: y=8'ha1; 8'hf2: y=8'h89; 8'hf3: y=8'h0d;
            8'hf4: y=8'hbf; 8'hf5: y=8'he6; 8'hf6: y=8'h42; 8'hf7: y=8'h68;
            8'hf8: y=8'h41; 8'hf9: y=8'h99; 8'hfa: y=8'h2d; 8'hfb: y=8'h0f;
            8'hfc: y=8'hb0; 8'hfd: y=8'h54; 8'hfe: y=8'hbb; 8'hff: y=8'h16;
        endcase
    end
endmodule


//////////////////////////////////////////////////////////////////////////////////
// MixColumns (encryption)
//////////////////////////////////////////////////////////////////////////////////
module mixcolumns (
    input  wire [127:0] state_in,
    output wire [127:0] state_out
);
    function [7:0] xtime(input [7:0] b);
        begin
            xtime = {b[6:0],1'b0} ^ (8'h1b & {8{b[7]}});
        end
    endfunction

    function [7:0] gm2(input [7:0] b);
        gm2 = xtime(b);
    endfunction

    function [7:0] gm3(input [7:0] b);
        gm3 = xtime(b) ^ b;
    endfunction

    wire [7:0] s[0:15];
    assign { s[0], s[1], s[2], s[3],
             s[4], s[5], s[6], s[7],
             s[8], s[9], s[10],s[11],
             s[12],s[13],s[14],s[15] } = state_in;

    wire [7:0] r[0:15];

    // column 0: s0,s4,s8,s12
    assign r[0]  = gm2(s[0]) ^ gm3(s[4]) ^ s[8]      ^ s[12];
    assign r[4]  = s[0]      ^ gm2(s[4]) ^ gm3(s[8]) ^ s[12];
    assign r[8]  = s[0]      ^ s[4]      ^ gm2(s[8]) ^ gm3(s[12]);
    assign r[12] = gm3(s[0]) ^ s[4]      ^ s[8]      ^ gm2(s[12]);

    // column 1: s1,s5,s9,s13
    assign r[1]  = gm2(s[1]) ^ gm3(s[5]) ^ s[9]      ^ s[13];
    assign r[5]  = s[1]      ^ gm2(s[5]) ^ gm3(s[9]) ^ s[13];
    assign r[9]  = s[1]      ^ s[5]      ^ gm2(s[9]) ^ gm3(s[13]);
    assign r[13] = gm3(s[1]) ^ s[5]      ^ s[9]      ^ gm2(s[13]);

    // column 2: s2,s6,s10,s14
    assign r[2]  = gm2(s[2]) ^ gm3(s[6]) ^ s[10]     ^ s[14];
    assign r[6]  = s[2]      ^ gm2(s[6]) ^ gm3(s[10])^ s[14];
    assign r[10] = s[2]      ^ s[6]      ^ gm2(s[10])^ gm3(s[14]);
    assign r[14] = gm3(s[2]) ^ s[6]      ^ s[10]     ^ gm2(s[14]);

    // column 3: s3,s7,s11,s15
    assign r[3]  = gm2(s[3]) ^ gm3(s[7]) ^ s[11]     ^ s[15];
    assign r[7]  = s[3]      ^ gm2(s[7]) ^ gm3(s[11])^ s[15];
    assign r[11] = s[3]      ^ s[7]      ^ gm2(s[11])^ gm3(s[15]);
    assign r[15] = gm3(s[3]) ^ s[7]      ^ s[11]     ^ gm2(s[15]);

    assign state_out = { r[0], r[1], r[2], r[3],
                         r[4], r[5], r[6], r[7],
                         r[8], r[9], r[10],r[11],
                         r[12],r[13],r[14],r[15] };
endmodule


//////////////////////////////////////////////////////////////////////////////////
// AES-128 Key Expansion (combinational)
//////////////////////////////////////////////////////////////////////////////////
module key_expand_128 (
    input  wire  [127:0] key_in,
    output reg   [1407:0] round_keys
);
    reg [31:0] w [0:43];
    reg [7:0]  rcon [0:9];
    integer i;

    function [7:0] sbox_fn(input [7:0] a);
        begin
            case (a)
                8'h00: sbox_fn=8'h63; 8'h01: sbox_fn=8'h7c; 8'h02: sbox_fn=8'h77; 8'h03: sbox_fn=8'h7b;
                8'h04: sbox_fn=8'hf2; 8'h05: sbox_fn=8'h6b; 8'h06: sbox_fn=8'h6f; 8'h07: sbox_fn=8'hc5;
                8'h08: sbox_fn=8'h30; 8'h09: sbox_fn=8'h01; 8'h0a: sbox_fn=8'h67; 8'h0b: sbox_fn=8'h2b;
                8'h0c: sbox_fn=8'hfe; 8'h0d: sbox_fn=8'hd7; 8'h0e: sbox_fn=8'hab; 8'h0f: sbox_fn=8'h76;
                8'h10: sbox_fn=8'hca; 8'h11: sbox_fn=8'h82; 8'h12: sbox_fn=8'hc9; 8'h13: sbox_fn=8'h7d;
                8'h14: sbox_fn=8'hfa; 8'h15: sbox_fn=8'h59; 8'h16: sbox_fn=8'h47; 8'h17: sbox_fn=8'hf0;
                8'h18: sbox_fn=8'had; 8'h19: sbox_fn=8'hd4; 8'h1a: sbox_fn=8'ha2; 8'h1b: sbox_fn=8'haf;
                8'h1c: sbox_fn=8'h9c; 8'h1d: sbox_fn=8'ha4; 8'h1e: sbox_fn=8'h72; 8'h1f: sbox_fn=8'hc0;
                8'h20: sbox_fn=8'hb7; 8'h21: sbox_fn=8'hfd; 8'h22: sbox_fn=8'h93; 8'h23: sbox_fn=8'h26;
                8'h24: sbox_fn=8'h36; 8'h25: sbox_fn=8'h3f; 8'h26: sbox_fn=8'hf7; 8'h27: sbox_fn=8'hcc;
                8'h28: sbox_fn=8'h34; 8'h29: sbox_fn=8'ha5; 8'h2a: sbox_fn=8'he5; 8'h2b: sbox_fn=8'hf1;
                8'h2c: sbox_fn=8'h71; 8'h2d: sbox_fn=8'hd8; 8'h2e: sbox_fn=8'h31; 8'h2f: sbox_fn=8'h15;
                8'h30: sbox_fn=8'h04; 8'h31: sbox_fn=8'hc7; 8'h32: sbox_fn=8'h23; 8'h33: sbox_fn=8'hc3;
                8'h34: sbox_fn=8'h18; 8'h35: sbox_fn=8'h96; 8'h36: sbox_fn=8'h05; 8'h37: sbox_fn=8'h9a;
                8'h38: sbox_fn=8'h07; 8'h39: sbox_fn=8'h12; 8'h3a: sbox_fn=8'h80; 8'h3b: sbox_fn=8'he2;
                8'h3c: sbox_fn=8'heb; 8'h3d: sbox_fn=8'h27; 8'h3e: sbox_fn=8'hb2; 8'h3f: sbox_fn=8'h75;
                8'h40: sbox_fn=8'h09; 8'h41: sbox_fn=8'h83; 8'h42: sbox_fn=8'h2c; 8'h43: sbox_fn=8'h1a;
                8'h44: sbox_fn=8'h1b; 8'h45: sbox_fn=8'h6e; 8'h46: sbox_fn=8'h5a; 8'h47: sbox_fn=8'ha0;
                8'h48: sbox_fn=8'h52; 8'h49: sbox_fn=8'h3b; 8'h4a: sbox_fn=8'hd6; 8'h4b: sbox_fn=8'hb3;
                8'h4c: sbox_fn=8'h29; 8'h4d: sbox_fn=8'he3; 8'h4e: sbox_fn=8'h2f; 8'h4f: sbox_fn=8'h84;
                8'h50: sbox_fn=8'h53; 8'h51: sbox_fn=8'hd1; 8'h52: sbox_fn=8'h00; 8'h53: sbox_fn=8'hed;
                8'h54: sbox_fn=8'h20; 8'h55: sbox_fn=8'hfc; 8'h56: sbox_fn=8'hb1; 8'h57: sbox_fn=8'h5b;
                8'h58: sbox_fn=8'h6a; 8'h59: sbox_fn=8'hcb; 8'h5a: sbox_fn=8'hbe; 8'h5b: sbox_fn=8'h39;
                8'h5c: sbox_fn=8'h4a; 8'h5d: sbox_fn=8'h4c; 8'h5e: sbox_fn=8'h58; 8'h5f: sbox_fn=8'hcf;
                8'h60: sbox_fn=8'hd0; 8'h61: sbox_fn=8'hef; 8'h62: sbox_fn=8'haa; 8'h63: sbox_fn=8'hfb;
                8'h64: sbox_fn=8'h43; 8'h65: sbox_fn=8'h4d; 8'h66: sbox_fn=8'h33; 8'h67: sbox_fn=8'h85;
                8'h68: sbox_fn=8'h45; 8'h69: sbox_fn=8'hf9; 8'h6a: sbox_fn=8'h02; 8'h6b: sbox_fn=8'h7f;
                8'h6c: sbox_fn=8'h50; 8'h6d: sbox_fn=8'h3c; 8'h6e: sbox_fn=8'h9f; 8'h6f: sbox_fn=8'ha8;
                8'h70: sbox_fn=8'h51; 8'h71: sbox_fn=8'ha3; 8'h72: sbox_fn=8'h40; 8'h73: sbox_fn=8'h8f;
                8'h74: sbox_fn=8'h92; 8'h75: sbox_fn=8'h9d; 8'h76: sbox_fn=8'h38; 8'h77: sbox_fn=8'hf5;
                8'h78: sbox_fn=8'hbc; 8'h79: sbox_fn=8'hb6; 8'h7a: sbox_fn=8'hda; 8'h7b: sbox_fn=8'h21;
                8'h7c: sbox_fn=8'h10; 8'h7d: sbox_fn=8'hff; 8'h7e: sbox_fn=8'hf3; 8'h7f: sbox_fn=8'hd2;
                8'h80: sbox_fn=8'hcd; 8'h81: sbox_fn=8'h0c; 8'h82: sbox_fn=8'h13; 8'h83: sbox_fn=8'hec;
                8'h84: sbox_fn=8'h5f; 8'h85: sbox_fn=8'h97; 8'h86: sbox_fn=8'h44; 8'h87: sbox_fn=8'h17;
                8'h88: sbox_fn=8'hc4; 8'h89: sbox_fn=8'ha7; 8'h8a: sbox_fn=8'h7e; 8'h8b: sbox_fn=8'h3d;
                8'h8c: sbox_fn=8'h64; 8'h8d: sbox_fn=8'h5d; 8'h8e: sbox_fn=8'h19; 8'h8f: sbox_fn=8'h73;
                8'h90: sbox_fn=8'h60; 8'h91: sbox_fn=8'h81; 8'h92: sbox_fn=8'h4f; 8'h93: sbox_fn=8'hdc;
                8'h94: sbox_fn=8'h22; 8'h95: sbox_fn=8'h2a; 8'h96: sbox_fn=8'h90; 8'h97: sbox_fn=8'h88;
                8'h98: sbox_fn=8'h46; 8'h99: sbox_fn=8'hee; 8'h9a: sbox_fn=8'hb8; 8'h9b: sbox_fn=8'h14;
                8'h9c: sbox_fn=8'hde; 8'h9d: sbox_fn=8'h5e; 8'h9e: sbox_fn=8'h0b; 8'h9f: sbox_fn=8'hdb;
                8'ha0: sbox_fn=8'he0; 8'ha1: sbox_fn=8'h32; 8'ha2: sbox_fn=8'h3a; 8'ha3: sbox_fn=8'h0a;
                8'ha4: sbox_fn=8'h49; 8'ha5: sbox_fn=8'h06; 8'ha6: sbox_fn=8'h24; 8'ha7: sbox_fn=8'h5c;
                8'ha8: sbox_fn=8'hc2; 8'ha9: sbox_fn=8'hd3; 8'haa: sbox_fn=8'hac; 8'hab: sbox_fn=8'h62;
                8'hac: sbox_fn=8'h91; 8'had: sbox_fn=8'h95; 8'hae: sbox_fn=8'he4; 8'haf: sbox_fn=8'h79;
                8'hb0: sbox_fn=8'he7; 8'hb1: sbox_fn=8'hc8; 8'hb2: sbox_fn=8'h37; 8'hb3: sbox_fn=8'h6d;
                8'hb4: sbox_fn=8'h8d; 8'hb5: sbox_fn=8'hd5; 8'hb6: sbox_fn=8'h4e; 8'hb7: sbox_fn=8'ha9;
                8'hb8: sbox_fn=8'h6c; 8'hb9: sbox_fn=8'h56; 8'hba: sbox_fn=8'hf4; 8'hbb: sbox_fn=8'hea;
                8'hbc: sbox_fn=8'h65; 8'hbd: sbox_fn=8'h7a; 8'hbe: sbox_fn=8'hae; 8'hbf: sbox_fn=8'h08;
                8'hc0: sbox_fn=8'hba; 8'hc1: sbox_fn=8'h78; 8'hc2: sbox_fn=8'h25; 8'hc3: sbox_fn=8'h2e;
                8'hc4: sbox_fn=8'h1c; 8'hc5: sbox_fn=8'ha6; 8'hc6: sbox_fn=8'hb4; 8'hc7: sbox_fn=8'hc6;
                8'hc8: sbox_fn=8'he8; 8'hc9: sbox_fn=8'hdd; 8'hca: sbox_fn=8'h74; 8'hcb: sbox_fn=8'h1f;
                8'hcc: sbox_fn=8'h4b; 8'hcd: sbox_fn=8'hbd; 8'hce: sbox_fn=8'h8b; 8'hcf: sbox_fn=8'h8a;
                8'hd0: sbox_fn=8'h70; 8'hd1: sbox_fn=8'h3e; 8'hd2: sbox_fn=8'hb5; 8'hd3: sbox_fn=8'h66;
                8'hd4: sbox_fn=8'h48; 8'hd5: sbox_fn=8'h03; 8'hd6: sbox_fn=8'hf6; 8'hd7: sbox_fn=8'h0e;
                8'hd8: sbox_fn=8'h61; 8'hd9: sbox_fn=8'h35; 8'hda: sbox_fn=8'h57; 8'hdb: sbox_fn=8'hb9;
                8'hdc: sbox_fn=8'h86; 8'hdd: sbox_fn=8'hc1; 8'hde: sbox_fn=8'h1d; 8'hdf: sbox_fn=8'h9e;
                8'he0: sbox_fn=8'he1; 8'he1: sbox_fn=8'hf8; 8'he2: sbox_fn=8'h98; 8'he3: sbox_fn=8'h11;
                8'he4: sbox_fn=8'h69; 8'he5: sbox_fn=8'hd9; 8'he6: sbox_fn=8'h8e; 8'he7: sbox_fn=8'h94;
                8'he8: sbox_fn=8'h9b; 8'he9: sbox_fn=8'h1e; 8'hea: sbox_fn=8'h87; 8'heb: sbox_fn=8'he9;
                8'hec: sbox_fn=8'hce; 8'hed: sbox_fn=8'h55; 8'hee: sbox_fn=8'h28; 8'hef: sbox_fn=8'hdf;
                8'hf0: sbox_fn=8'h8c; 8'hf1: sbox_fn=8'ha1; 8'hf2: sbox_fn=8'h89; 8'hf3: sbox_fn=8'h0d;
                8'hf4: sbox_fn=8'hbf; 8'hf5: sbox_fn=8'he6; 8'hf6: sbox_fn=8'h42; 8'hf7: sbox_fn=8'h68;
                8'hf8: sbox_fn=8'h41; 8'hf9: sbox_fn=8'h99; 8'hfa: sbox_fn=8'h2d; 8'hfb: sbox_fn=8'h0f;
                8'hfc: sbox_fn=8'hb0; 8'hfd: sbox_fn=8'h54; 8'hfe: sbox_fn=8'hbb; 8'hff: sbox_fn=8'h16;
            endcase
        end
    endfunction

    function [31:0] subword(input [31:0] x);
        subword = { sbox_fn(x[31:24]),
                    sbox_fn(x[23:16]),
                    sbox_fn(x[15:8]),
                    sbox_fn(x[7:0]) };
    endfunction

    function [31:0] rotword(input [31:0] x);
        rotword = { x[23:0], x[31:24] };
    endfunction

    always @* begin
        rcon[0]=8'h01; rcon[1]=8'h02; rcon[2]=8'h04; rcon[3]=8'h08;
        rcon[4]=8'h10; rcon[5]=8'h20; rcon[6]=8'h40; rcon[7]=8'h80;
        rcon[8]=8'h1B; rcon[9]=8'h36;

        {w[0],w[1],w[2],w[3]} = key_in;

        for (i=4; i<44; i=i+1) begin
            if (i % 4 == 0)
                w[i] = w[i-4] ^ (subword(rotword(w[i-1])) ^
                                {rcon[(i/4)-1], 24'h0});
            else
                w[i] = w[i-4] ^ w[i-1];
        end

        for (i=0; i<11; i=i+1) begin
            round_keys[1407 - 128*i -: 128] =
                { w[4*i], w[4*i+1], w[4*i+2], w[4*i+3] };
        end
    end

endmodule


//////////////////////////////////////////////////////////////////////////////////
// AES-128 Encryption Core (10 rounds)
//////////////////////////////////////////////////////////////////////////////////
module aes128_encrypt (
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,
    input  wire [127:0]  block_in,
    input  wire [1407:0] round_keys,
    output reg  [127:0]  block_out,
    output reg          busy,
    output reg          done
);
    reg [127:0] state;
    reg [3:0]   round;

    // SubBytes
    wire [127:0] sub_out;
    genvar i;
    generate
        for (i=0; i<16; i=i+1) begin : SBOXES
            wire [7:0] sb_in;
            wire [7:0] sb_out;
            assign sb_in = state[127 - 8*i -: 8];
            sbox u_s (.a(sb_in), .y(sb_out));
            assign sub_out[127 - 8*i -: 8] = sb_out;
        end
    endgenerate

    // ShiftRows
    wire [7:0] b[0:15];
    assign { b[0], b[1], b[2], b[3],
             b[4], b[5], b[6], b[7],
             b[8], b[9], b[10],b[11],
             b[12],b[13],b[14],b[15] } = sub_out;

    wire [7:0] sh[0:15];
    // row 0: unchanged
    assign sh[0] = b[0];
    assign sh[1] = b[1];
    assign sh[2] = b[2];
    assign sh[3] = b[3];
    // row 1: left shift by 1
    assign sh[4] = b[5];
    assign sh[5] = b[6];
    assign sh[6] = b[7];
    assign sh[7] = b[4];
    // row 2: left shift by 2
    assign sh[8]  = b[10];
    assign sh[9]  = b[11];
    assign sh[10] = b[8];
    assign sh[11] = b[9];
    // row 3: left shift by 3
    assign sh[12] = b[15];
    assign sh[13] = b[12];
    assign sh[14] = b[13];
    assign sh[15] = b[14];

    wire [127:0] shift_out = { sh[0], sh[1], sh[2], sh[3],
                               sh[4], sh[5], sh[6], sh[7],
                               sh[8], sh[9], sh[10],sh[11],
                               sh[12],sh[13],sh[14],sh[15] };

    // MixColumns (skipped in final round)
    wire [127:0] mix_out;
    mixcolumns u_mix (
        .state_in (shift_out),
        .state_out(mix_out)
    );

    // Round key accessor
    function [127:0] get_rk(input [3:0] r);
        get_rk = round_keys[1407 - 128*r -: 128];
    endfunction

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state     <= 128'd0;
            round     <= 4'd0;
            block_out <= 128'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                // initial AddRoundKey (round 0)
                state <= block_in ^ get_rk(4'd0);
                round <= 4'd1;
                busy  <= 1'b1;
            end else if (busy) begin
                if (round < 4'd10) begin
                    // rounds 1..9: SubBytes, ShiftRows, MixColumns, AddRoundKey
                    state <= mix_out ^ get_rk(round);
                    round <= round + 1'b1;
                end else begin
                    // final round (10): SubBytes, ShiftRows, AddRoundKey (no MixColumns)
                    state     <= shift_out ^ get_rk(4'd10);
                    block_out <= shift_out ^ get_rk(4'd10);
                    busy      <= 1'b0;
                    done      <= 1'b1;
                end
            end
        end
    end

endmodule


//////////////////////////////////////////////////////////////////////////////////
// AES-128 Decryption Core (10 rounds) - iterative, uses round_keys from key_expand_128
//////////////////////////////////////////////////////////////////////////////////
module aes128_decrypt (
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,
    input  wire [127:0] block_in,
    input  wire [1407:0] round_keys,
    output reg  [127:0] block_out,
    output reg          busy,
    output reg          done
);
    reg [127:0] state;
    reg [3:0]   round;

    // inv sbox
    function [7:0] inv_sbox_fn(input [7:0] a);
        begin
            case (a)
                8'h00: inv_sbox_fn=8'h52; 8'h01: inv_sbox_fn=8'h09; 8'h02: inv_sbox_fn=8'h6A; 8'h03: inv_sbox_fn=8'hD5;
                8'h04: inv_sbox_fn=8'h30; 8'h05: inv_sbox_fn=8'h36; 8'h06: inv_sbox_fn=8'hA5; 8'h07: inv_sbox_fn=8'h38;
                8'h08: inv_sbox_fn=8'hBF; 8'h09: inv_sbox_fn=8'h40; 8'h0a: inv_sbox_fn=8'hA3; 8'h0b: inv_sbox_fn=8'h9E;
                8'h0c: inv_sbox_fn=8'h81; 8'h0d: inv_sbox_fn=8'hF3; 8'h0e: inv_sbox_fn=8'hD7; 8'h0f: inv_sbox_fn=8'hFB;
                8'h10: inv_sbox_fn=8'h7C; 8'h11: inv_sbox_fn=8'hE3; 8'h12: inv_sbox_fn=8'h39; 8'h13: inv_sbox_fn=8'h82;
                8'h14: inv_sbox_fn=8'h9B; 8'h15: inv_sbox_fn=8'h2F; 8'h16: inv_sbox_fn=8'hFF; 8'h17: inv_sbox_fn=8'h87;
                8'h18: inv_sbox_fn=8'h34; 8'h19: inv_sbox_fn=8'h8E; 8'h1a: inv_sbox_fn=8'h43; 8'h1b: inv_sbox_fn=8'h44;
                8'h1c: inv_sbox_fn=8'hC4; 8'h1d: inv_sbox_fn=8'hDE; 8'h1e: inv_sbox_fn=8'hE9; 8'h1f: inv_sbox_fn=8'hCB;
                8'h20: inv_sbox_fn=8'h54; 8'h21: inv_sbox_fn=8'h7B; 8'h22: inv_sbox_fn=8'h94; 8'h23: inv_sbox_fn=8'h32;
                8'h24: inv_sbox_fn=8'hA6; 8'h25: inv_sbox_fn=8'hC2; 8'h26: inv_sbox_fn=8'h23; 8'h27: inv_sbox_fn=8'h3D;
                8'h28: inv_sbox_fn=8'hEE; 8'h29: inv_sbox_fn=8'h4C; 8'h2a: inv_sbox_fn=8'h95; 8'h2b: inv_sbox_fn=8'h0B;
                8'h2c: inv_sbox_fn=8'h42; 8'h2d: inv_sbox_fn=8'hFA; 8'h2e: inv_sbox_fn=8'hC3; 8'h2f: inv_sbox_fn=8'h4E;
                8'h30: inv_sbox_fn=8'h08; 8'h31: inv_sbox_fn=8'h2E; 8'h32: inv_sbox_fn=8'hA1; 8'h33: inv_sbox_fn=8'h66;
                8'h34: inv_sbox_fn=8'h28; 8'h35: inv_sbox_fn=8'hD9; 8'h36: inv_sbox_fn=8'h24; 8'h37: inv_sbox_fn=8'hB2;
                8'h38: inv_sbox_fn=8'h76; 8'h39: inv_sbox_fn=8'h5B; 8'h3a: inv_sbox_fn=8'hA2; 8'h3b: inv_sbox_fn=8'h49;
                8'h3c: inv_sbox_fn=8'h6D; 8'h3d: inv_sbox_fn=8'h8B; 8'h3e: inv_sbox_fn=8'hD1; 8'h3f: inv_sbox_fn=8'h25;
                8'h40: inv_sbox_fn=8'h72; 8'h41: inv_sbox_fn=8'hF8; 8'h42: inv_sbox_fn=8'hF6; 8'h43: inv_sbox_fn=8'h64;
                8'h44: inv_sbox_fn=8'h86; 8'h45: inv_sbox_fn=8'h68; 8'h46: inv_sbox_fn=8'h98; 8'h47: inv_sbox_fn=8'h16;
                8'h48: inv_sbox_fn=8'hD4; 8'h49: inv_sbox_fn=8'hA4; 8'h4a: inv_sbox_fn=8'h5C; 8'h4b: inv_sbox_fn=8'hCC;
                8'h4c: inv_sbox_fn=8'h5D; 8'h4d: inv_sbox_fn=8'h65; 8'h4e: inv_sbox_fn=8'hB6; 8'h4f: inv_sbox_fn=8'h92;
                8'h50: inv_sbox_fn=8'h6C; 8'h51: inv_sbox_fn=8'h70; 8'h52: inv_sbox_fn=8'h48; 8'h53: inv_sbox_fn=8'h50;
                8'h54: inv_sbox_fn=8'hFD; 8'h55: inv_sbox_fn=8'hED; 8'h56: inv_sbox_fn=8'hB9; 8'h57: inv_sbox_fn=8'hDA;
                8'h58: inv_sbox_fn=8'h5E; 8'h59: inv_sbox_fn=8'h15; 8'h5a: inv_sbox_fn=8'h46; 8'h5b: inv_sbox_fn=8'h57;
                8'h5c: inv_sbox_fn=8'hA7; 8'h5d: inv_sbox_fn=8'h8D; 8'h5e: inv_sbox_fn=8'h9D; 8'h5f: inv_sbox_fn=8'h84;
                8'h60: inv_sbox_fn=8'h90; 8'h61: inv_sbox_fn=8'hD8; 8'h62: inv_sbox_fn=8'hAB; 8'h63: inv_sbox_fn=8'h00;
                8'h64: inv_sbox_fn=8'h8C; 8'h65: inv_sbox_fn=8'hBC; 8'h66: inv_sbox_fn=8'hD3; 8'h67: inv_sbox_fn=8'h0A;
                8'h68: inv_sbox_fn=8'hF7; 8'h69: inv_sbox_fn=8'hE4; 8'h6a: inv_sbox_fn=8'h58; 8'h6b: inv_sbox_fn=8'h05;
                8'h6c: inv_sbox_fn=8'hB8; 8'h6d: inv_sbox_fn=8'hB3; 8'h6e: inv_sbox_fn=8'h45; 8'h6f: inv_sbox_fn=8'h06;
                8'h70: inv_sbox_fn=8'hD0; 8'h71: inv_sbox_fn=8'h2C; 8'h72: inv_sbox_fn=8'h1E; 8'h73: inv_sbox_fn=8'h8F;
                8'h74: inv_sbox_fn=8'hCA; 8'h75: inv_sbox_fn=8'h3F; 8'h76: inv_sbox_fn=8'h0F; 8'h77: inv_sbox_fn=8'h02;
                8'h78: inv_sbox_fn=8'hC1; 8'h79: inv_sbox_fn=8'hAF; 8'h7a: inv_sbox_fn=8'hBD; 8'h7b: inv_sbox_fn=8'h03;
                8'h7c: inv_sbox_fn=8'h01; 8'h7d: inv_sbox_fn=8'h13; 8'h7e: inv_sbox_fn=8'h8A; 8'h7f: inv_sbox_fn=8'h6B;
                8'h80: inv_sbox_fn=8'h3A; 8'h81: inv_sbox_fn=8'h91; 8'h82: inv_sbox_fn=8'h11; 8'h83: inv_sbox_fn=8'h41;
                8'h84: inv_sbox_fn=8'h4F; 8'h85: inv_sbox_fn=8'h67; 8'h86: inv_sbox_fn=8'hDC; 8'h87: inv_sbox_fn=8'hEA;
                8'h88: inv_sbox_fn=8'h97; 8'h89: inv_sbox_fn=8'hF2; 8'h8a: inv_sbox_fn=8'hCF; 8'h8b: inv_sbox_fn=8'hCE;
                8'h8c: inv_sbox_fn=8'hF0; 8'h8d: inv_sbox_fn=8'hB4; 8'h8e: inv_sbox_fn=8'hE6; 8'h8f: inv_sbox_fn=8'h73;
                8'h90: inv_sbox_fn=8'h96; 8'h91: inv_sbox_fn=8'hAC; 8'h92: inv_sbox_fn=8'h74; 8'h93: inv_sbox_fn=8'h22;
                8'h94: inv_sbox_fn=8'hE7; 8'h95: inv_sbox_fn=8'hAD; 8'h96: inv_sbox_fn=8'h35; 8'h97: inv_sbox_fn=8'h85;
                8'h98: inv_sbox_fn=8'hE2; 8'h99: inv_sbox_fn=8'hF9; 8'h9a: inv_sbox_fn=8'h37; 8'h9b: inv_sbox_fn=8'hE8;
                8'h9c: inv_sbox_fn=8'h1C; 8'h9d: inv_sbox_fn=8'h75; 8'h9e: inv_sbox_fn=8'hDF; 8'h9f: inv_sbox_fn=8'h6E;
                8'ha0: inv_sbox_fn=8'h47; 8'ha1: inv_sbox_fn=8'hF1; 8'ha2: inv_sbox_fn=8'h1A; 8'ha3: inv_sbox_fn=8'h71;
                8'ha4: inv_sbox_fn=8'h1D; 8'ha5: inv_sbox_fn=8'h29; 8'ha6: inv_sbox_fn=8'hC5; 8'ha7: inv_sbox_fn=8'h89;
                8'ha8: inv_sbox_fn=8'h6F; 8'ha9: inv_sbox_fn=8'hB7; 8'haa: inv_sbox_fn=8'h62; 8'hab: inv_sbox_fn=8'h0E;
                8'hac: inv_sbox_fn=8'hAA; 8'had: inv_sbox_fn=8'h18; 8'hae: inv_sbox_fn=8'hBE; 8'haf: inv_sbox_fn=8'h1B;
                8'hb0: inv_sbox_fn=8'hFC; 8'hb1: inv_sbox_fn=8'h56; 8'hb2: inv_sbox_fn=8'h3E; 8'hb3: inv_sbox_fn=8'h4B;
                8'hb4: inv_sbox_fn=8'hC6; 8'hb5: inv_sbox_fn=8'hD2; 8'hb6: inv_sbox_fn=8'h79; 8'hb7: inv_sbox_fn=8'h20;
                8'hb8: inv_sbox_fn=8'h9A; 8'hb9: inv_sbox_fn=8'hDB; 8'hba: inv_sbox_fn=8'hC0; 8'hbb: inv_sbox_fn=8'hFE;
                8'hbc: inv_sbox_fn=8'h78; 8'hbd: inv_sbox_fn=8'hCD; 8'hbe: inv_sbox_fn=8'h5A; 8'hbf: inv_sbox_fn=8'hF4;
                8'hc0: inv_sbox_fn=8'h1F; 8'hc1: inv_sbox_fn=8'hDD; 8'hc2: inv_sbox_fn=8'hA8; 8'hc3: inv_sbox_fn=8'h33;
                8'hc4: inv_sbox_fn=8'h88; 8'hc5: inv_sbox_fn=8'h07; 8'hc6: inv_sbox_fn=8'hC7; 8'hc7: inv_sbox_fn=8'h31;
                8'hc8: inv_sbox_fn=8'hB1; 8'hc9: inv_sbox_fn=8'h12; 8'hca: inv_sbox_fn=8'h10; 8'hcb: inv_sbox_fn=8'h59;
                8'hcc: inv_sbox_fn=8'h27; 8'hcd: inv_sbox_fn=8'h80; 8'hce: inv_sbox_fn=8'hEC; 8'hcf: inv_sbox_fn=8'h5F;
                8'hd0: inv_sbox_fn=8'h60; 8'hd1: inv_sbox_fn=8'h51; 8'hd2: inv_sbox_fn=8'h7F; 8'hd3: inv_sbox_fn=8'hA9;
                8'hd4: inv_sbox_fn=8'h19; 8'hd5: inv_sbox_fn=8'hB5; 8'hd6: inv_sbox_fn=8'h4A; 8'hd7: inv_sbox_fn=8'h0D;
                8'hd8: inv_sbox_fn=8'h2D; 8'hd9: inv_sbox_fn=8'hE5; 8'hda: inv_sbox_fn=8'h7A; 8'hdb: inv_sbox_fn=8'h9F;
                8'hdc: inv_sbox_fn=8'h93; 8'hdd: inv_sbox_fn=8'hC9; 8'hde: inv_sbox_fn=8'h9C; 8'hdf: inv_sbox_fn=8'hEF;
                8'he0: inv_sbox_fn=8'hA0; 8'he1: inv_sbox_fn=8'hE0; 8'he2: inv_sbox_fn=8'h3B; 8'he3: inv_sbox_fn=8'h4D;
                8'he4: inv_sbox_fn=8'hAE; 8'he5: inv_sbox_fn=8'h2A; 8'he6: inv_sbox_fn=8'hF5; 8'he7: inv_sbox_fn=8'hB0;
                8'he8: inv_sbox_fn=8'hC8; 8'he9: inv_sbox_fn=8'hEB; 8'hea: inv_sbox_fn=8'hBB; 8'heb: inv_sbox_fn=8'h3C;
                8'hec: inv_sbox_fn=8'h83; 8'hed: inv_sbox_fn=8'h53; 8'hee: inv_sbox_fn=8'h99; 8'hef: inv_sbox_fn=8'h61;
                8'hf0: inv_sbox_fn=8'h17; 8'hf1: inv_sbox_fn=8'h2B; 8'hf2: inv_sbox_fn=8'h04; 8'hf3: inv_sbox_fn=8'h7E;
                8'hf4: inv_sbox_fn=8'hBA; 8'hf5: inv_sbox_fn=8'h77; 8'hf6: inv_sbox_fn=8'hD6; 8'hf7: inv_sbox_fn=8'h26;
                8'hf8: inv_sbox_fn=8'hE1; 8'hf9: inv_sbox_fn=8'h69; 8'hfa: inv_sbox_fn=8'h14; 8'hfb: inv_sbox_fn=8'h63;
                8'hfc: inv_sbox_fn=8'h55; 8'hfd: inv_sbox_fn=8'h21; 8'hfe: inv_sbox_fn=8'h0C; 8'hff: inv_sbox_fn=8'h7D;
            endcase
        end
    endfunction

    // InvMixColumns helper functions
    function [7:0] xtime(input [7:0] b);
        begin
            xtime = {b[6:0],1'b0} ^ (8'h1b & {8{b[7]}});
        end
    endfunction

    function [7:0] mul_by_9(input [7:0] b);
        begin
            // 9*x = x*8 + x
            mul_by_9 = xtime(xtime(xtime(b))) ^ b;
        end
    endfunction

    function [7:0] mul_by_11(input [7:0] b);
        begin
            // 11*x = x*8 + x*2 + x
            mul_by_11 = xtime(xtime(xtime(b))) ^ xtime(b) ^ b;
        end
    endfunction

    function [7:0] mul_by_13(input [7:0] b);
        begin
            // 13*x = x*8 + x*4 + x
            mul_by_13 = xtime(xtime(xtime(b))) ^ xtime(xtime(b)) ^ b;
        end
    endfunction

    function [7:0] mul_by_14(input [7:0] b);
        begin
            // 14*x = x*8 + x*4 + x*2
            mul_by_14 = xtime(xtime(xtime(b))) ^ xtime(xtime(b)) ^ xtime(b);
        end
    endfunction

    // InvMixColumns - operate on full 128-bit state
    function [127:0] inv_mixcolumns(input [127:0] state_in);
        reg [7:0] s[0:15];
        reg [7:0] r[0:15];
        integer j;
        begin
            { s[0], s[1], s[2], s[3],
              s[4], s[5], s[6], s[7],
              s[8], s[9], s[10],s[11],
              s[12],s[13],s[14],s[15] } = state_in;

            // column 0
            r[0]  = mul_by_14(s[0]) ^ mul_by_11(s[1]) ^ mul_by_13(s[2]) ^ mul_by_9(s[3]);
            r[1]  = mul_by_9(s[0])  ^ mul_by_14(s[1]) ^ mul_by_11(s[2]) ^ mul_by_13(s[3]);
            r[2]  = mul_by_13(s[0]) ^ mul_by_9(s[1])  ^ mul_by_14(s[2]) ^ mul_by_11(s[3]);
            r[3]  = mul_by_11(s[0]) ^ mul_by_13(s[1]) ^ mul_by_9(s[2])  ^ mul_by_14(s[3]);
            // column 1
            r[4]  = mul_by_14(s[4]) ^ mul_by_11(s[5]) ^ mul_by_13(s[6]) ^ mul_by_9(s[7]);
            r[5]  = mul_by_9(s[4])  ^ mul_by_14(s[5]) ^ mul_by_11(s[6]) ^ mul_by_13(s[7]);
            r[6]  = mul_by_13(s[4]) ^ mul_by_9(s[5])  ^ mul_by_14(s[6]) ^ mul_by_11(s[7]);
            r[7]  = mul_by_11(s[4]) ^ mul_by_13(s[5]) ^ mul_by_9(s[6])  ^ mul_by_14(s[7]);
            // column 2
            r[8]  = mul_by_14(s[8]) ^ mul_by_11(s[9]) ^ mul_by_13(s[10]) ^ mul_by_9(s[11]);
            r[9]  = mul_by_9(s[8])  ^ mul_by_14(s[9]) ^ mul_by_11(s[10]) ^ mul_by_13(s[11]);
            r[10] = mul_by_13(s[8]) ^ mul_by_9(s[9])  ^ mul_by_14(s[10]) ^ mul_by_11(s[11]);
            r[11] = mul_by_11(s[8]) ^ mul_by_13(s[9]) ^ mul_by_9(s[10])  ^ mul_by_14(s[11]);
            // column 3
            r[12] = mul_by_14(s[12]) ^ mul_by_11(s[13]) ^ mul_by_13(s[14]) ^ mul_by_9(s[15]);
            r[13] = mul_by_9(s[12])  ^ mul_by_14(s[13]) ^ mul_by_11(s[14]) ^ mul_by_13(s[15]);
            r[14] = mul_by_13(s[12]) ^ mul_by_9(s[13])  ^ mul_by_14(s[14]) ^ mul_by_11(s[15]);
            r[15] = mul_by_11(s[12]) ^ mul_by_13(s[13]) ^ mul_by_9(s[14])  ^ mul_by_14(s[15]);

            inv_mixcolumns = { r[0], r[1], r[2], r[3],
                               r[4], r[5], r[6], r[7],
                               r[8], r[9], r[10],r[11],
                               r[12],r[13],r[14],r[15] };
        end
    endfunction

    // InvShiftRows + InvSubBytes
    function [127:0] inv_shift_sub(input [127:0] s_in);
        reg [7:0] b[0:15];
        reg [7:0] sh[0:15];
        integer k;
        begin
            { b[0], b[1], b[2], b[3],
              b[4], b[5], b[6], b[7],
              b[8], b[9], b[10],b[11],
              b[12],b[13],b[14],b[15] } = s_in;

            // inv shift rows: right shifts by row index
            sh[0]  = inv_sbox_fn(b[0]);
            sh[1]  = inv_sbox_fn(b[13]);
            sh[2]  = inv_sbox_fn(b[10]);
            sh[3]  = inv_sbox_fn(b[7]);

            sh[4]  = inv_sbox_fn(b[4]);
            sh[5]  = inv_sbox_fn(b[1]);
            sh[6]  = inv_sbox_fn(b[14]);
            sh[7]  = inv_sbox_fn(b[11]);

            sh[8]  = inv_sbox_fn(b[8]);
            sh[9]  = inv_sbox_fn(b[5]);
            sh[10] = inv_sbox_fn(b[2]);
            sh[11] = inv_sbox_fn(b[15]);

            sh[12] = inv_sbox_fn(b[12]);
            sh[13] = inv_sbox_fn(b[9]);
            sh[14] = inv_sbox_fn(b[6]);
            sh[15] = inv_sbox_fn(b[3]);

            inv_shift_sub = { sh[0], sh[1], sh[2], sh[3],
                              sh[4], sh[5], sh[6], sh[7],
                              sh[8], sh[9], sh[10],sh[11],
                              sh[12],sh[13],sh[14],sh[15] };
        end
    endfunction

    // round key accessor same order as encryption (round 0..10)
    function [127:0] get_rk(input [3:0] r);
        get_rk = round_keys[1407 - 128*r -: 128];
    endfunction

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state     <= 128'd0;
            round     <= 4'd0;
            block_out <= 128'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                // initial AddRoundKey with last round key (round 10)
                state <= block_in ^ get_rk(4'd10);
                round <= 4'd9; // next round to perform is 9
                busy  <= 1'b1;
            end else if (busy) begin
                if (round > 4'd0) begin
                    // rounds 9..1: InvShiftRows+InvSubBytes, AddRoundKey, InvMixColumns
                    // apply inv_shift_sub then add round key for this round, then inv_mixcolumns
                    state <= inv_mixcolumns( inv_shift_sub(state) ^ get_rk(round) );
                    round <= round - 1'b1;
                end else begin
                    // final round (round 0): InvShiftRows + InvSubBytes + AddRoundKey(0)
                    state     <= inv_shift_sub(state) ^ get_rk(4'd0);
                    block_out <= inv_shift_sub(state) ^ get_rk(4'd0);
                    busy      <= 1'b0;
                    done      <= 1'b1;
                end
            end
        end
    end

endmodule
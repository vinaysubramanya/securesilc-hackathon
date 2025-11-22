#  SecureSilicon — AES-128 Encryption & Decryption over UART (Basys-3)

SecureSilicon is an FPGA-based **AES-128 hardware crypto engine** that supports **both encryption and decryption** over UART.  
It is fully written in **synthesizable Verilog**, targets the **Digilent Basys-3** FPGA board, and is ideal for hardware security demos, hackathons, and academic projects.

The design exposes a simple UART protocol:
- Send `E` + 16 bytes → FPGA returns **AES-128 encrypted** 16-byte block  
- Send `D` + 16 bytes → FPGA returns **AES-128 decrypted** 16-byte block  

---

## ⚙️ UART Command Protocol

All communication is over UART at **115200 baud, 8-N-1**.

| Command Byte | Meaning         | Following Bytes         | FPGA Output               |
|--------------|-----------------|-------------------------|---------------------------|
| `E` / `e`    | Encrypt block   | 16 bytes plaintext      | 16 bytes ciphertext       |
| `D` / `d`    | Decrypt block   | 16 bytes ciphertext     | 16 bytes recovered plain  |
| Other        | Ignored         | —                       | —                         |

The PC communicates with the Basys-3 over the onboard **FTDI USB-UART** interface.

---

## Top-Level Architecture

High-level data flow:

```text
      PC (Serial Terminal)
                 │
                 ▼
        +----------------+
        |    uart_rx     |   RX bytes
        +----------------+
                 │  (8-bit data, valid)
                 ▼
        +----------------+
        |  echo_top FSM  |  ─────┐
        +----------------+       │
           │   command & 16B     │
           │                     │
     +-----------+         +-----------+
     | aes128_   | 16B blk | aes128_   |
     | encrypt   | ───────▶| decrypt   |
     +-----------+         +-----------+
           │                     │
           └──────────┬──────────┘
                      ▼
                +-----------+
                |  uart_tx  |  TX bytes
                +-----------+
                      │
                      ▼
                PC (serial)
```

The entire design runs at **25 MHz**, generated from the Basys-3 **100 MHz clock** using a simple ÷4 divider.

---

##   GitHub Repository Structure

```text
SecureSilicon-AES-UART/
│
├── src/
│   ├── echo_top.v             # Top-level AES-UART system
│   ├── aes128_encrypt.v       # AES-128 encryption core (10 rounds)
│   ├── aes128_decrypt.v       # AES-128 decryption core (10 rounds)
│   ├── key_expand_128.v       # AES key expansion (11 round keys)
│   ├── sbox.v                 # AES S-box (SubBytes)
│   ├── mixcolumns.v           # MixColumns transformation
│   ├── uart_rx.v              # UART receiver (115200, 8-N-1)
│   ├── uart_tx.v              # UART transmitter (115200, 8-N-1)
│   └── clock_div_25mhz.v      # 100 MHz → 25 MHz clock divider
│
├── constr/
│   └── basys3_constraints.xdc # Pin mapping for Basys-3
│
└── README.md
```



---

##  AES Key

In `echo_top`, a fixed 128-bit AES test key is used (you can modify it):

```verilog
// Standard AES-128 test key:
wire [127:0] aes_key = 128'h2b7e151628aed2a6abf7158809cf4f3c;
```

This key is passed to `key_expand_128`, which generates **11 round keys** for AES-128 (round 0 to round 10).

---

##  Module-by-Module Explanation

###  `echo_top` — AES-UART System Top

**Role:**  
The main control module that connects UART, AES cores, key expansion, and the FSM that handles the protocol.

**Key responsibilities:**
- Divides the **100 MHz** clock down to **25 MHz** using `clock_div_25mhz`
- Instantiates:
  - `uart_rx` and `uart_tx`
  - `key_expand_128`
  - `aes128_encrypt` and `aes128_decrypt`
- Implements a **UART protocol FSM** with states:
  - `ST_IDLE`   — wait for command (`E`/`D`)
  - `ST_RECV16` — receive 16 bytes of data
  - `ST_WAIT`   — wait for AES core to finish
  - `ST_SEND16` — send 16-byte result back over UART

**Data handling:**
- First received byte = `cmd` (`E` or `D`)
- Next **16 bytes** are collected into `data_buf` and then loaded into `aes_in_block`
- Depending on `cmd`, it asserts **`enc_start`** or **`dec_start`**
- When `enc_done` / `dec_done` goes high, stores output into `out_buf`
- Streams 16 bytes of `out_buf` via `uart_tx` using `tx_start`

This module is the **brain** of the system and directly implements the high-level protocol.

---

###  `clock_div_25mhz` — 100 MHz to 25 MHz Divider

**Role:**  
Simple synchronous divider to generate a 25 MHz clock from the 100 MHz Basys-3 input.

**How it works:**
- 2-bit counter `cnt` increments on each 100 MHz clock edge
- Output clock: `clk25 = cnt[1]` → divides by 4

This 25 MHz clock is used for:
- UART RX/TX timing
- AES encryption/decryption cores

---

###  `uart_rx` — UART Receiver

**Role:**  
Receives serial data from the PC and converts it into 8-bit parallel bytes with a strobe `valid`.

**Parameters:**
- `CLOCK_FREQ` — here set to `25_000_000`
- `BAUD`        — set to `115200`

**Implementation:**
- Computes `CLKS_PER_BIT = CLOCK_FREQ / BAUD`
- Waits for **start bit** (`rx == 0`)
- Samples each bit at the middle of the bit period using `clk_cnt`
- Shifts received bits into an 8-bit `shift` register
- After 8 data bits, outputs:
  - `data`  — the received byte
  - `valid` — 1-cycle pulse

The `echo_top` FSM uses `rx_valid` + `rx_byte` from this module.

---

###  `uart_tx` — UART Transmitter

**Role:**  
Takes 8-bit parallel data and sends it out serially over UART with start/stop framing.

**Inputs/Outputs:**
- `data_in`  — byte to send
- `start`    — 1-cycle pulse to begin transmission
- `tx`       — UART TX line
- `busy`     — indicates transmission in progress

**Implementation details:**
- Builds a 10-bit frame: `{stop(1), data[7:0], start(0)}`
- Sends bits one by one every `CLKS_PER_BIT` cycles
- Keeps `tx` high when idle

`echo_top` only asserts `tx_start` when `tx_busy == 0`, ensuring back-to-back, reliable transmission of 16 bytes.

---

###  `sbox` — AES SubBytes Lookup

**Role:**  
Implements the standard AES **S-Box** as a combinational lookup table.

**Behavior:**
- Input:  8-bit byte `a`
- Output: 8-bit substituted byte `y`
- Defined using a `case` statement with all **256 entries**

Used in:
- `aes128_encrypt` (for SubBytes)
- `key_expand_128` (inside `sbox_fn` function)

This is the non-linear heart of AES.

---

###  `mixcolumns` — AES MixColumns (Encryption)

**Role:**  
Implements the **MixColumns** transformation for AES encryption.

**Representation:**
- Treats the 128-bit state as 16 bytes `s[0..15]`
- Each column = 4 bytes, e.g. (s0, s4, s8, s12)

**Math:**
- Implements multiplication by 2 and 3 in GF(2^8) using `xtime` and XOR logic
- Output bytes `r[0..15]` are computed per AES’s standard MixColumns matrix

Used in each **round 1–9** in `aes128_encrypt`.  
Not used in the **final round** (round 10), as per AES spec.

---

###  `key_expand_128` — AES-128 Key Expansion

**Role:**  
Takes a 128-bit AES key and expands it into **44 words (32 bits each)** — total of **11 round keys** (0–10).

**Internals:**
- Stores words in `w[0..43]`
- Uses AES operations:
  - `RotWord` — byte rotate
  - `SubWord` — apply S-Box per byte
  - `Rcon`    — round constants

**Algorithm:**
- Initial 4 words: `{w[0], w[1], w[2], w[3]} = key_in`
- For `i = 4 to 43`:
  - If `i % 4 == 0`:
    ```verilog
    w[i] = w[i-4] ^ (SubWord(RotWord(w[i-1])) ^ {Rcon, 24'h0});
    ```
  - Else:
    ```verilog
    w[i] = w[i-4] ^ w[i-1];
    ```

**Output packing:**
- `round_keys` is 1408 bits: 11 × 128
- For each round `i` (0..10):
  - `round_keys[1407 - 128*i -: 128] = { w[4*i], w[4*i+1], w[4*i+2], w[4*i+3] }`

Both `aes128_encrypt` and `aes128_decrypt` use these round keys via `get_rk(round)`.

---

###  `aes128_encrypt` — AES-128 Encryption Core

**Role:**  
Iterative AES encryption core that performs **10 rounds** plus the initial AddRoundKey.

**Interface:**
- `start` — 1-cycle pulse to begin encryption
- `block_in` — 128-bit plaintext block
- `round_keys` — 11 × 128-bit round keys
- `block_out` — 128-bit ciphertext block
- `busy` / `done` — control/status signals

**Pipeline per block:**
1. On `start` (when not `busy`):
   ```verilog
   state <= block_in ^ get_rk(0); // initial AddRoundKey
   round <= 1;
   busy  <= 1;
   ```
2. For rounds 1–9:
   - SubBytes (via 16 instances of `sbox`)
   - ShiftRows
   - MixColumns
   - AddRoundKey (`get_rk(round)`)
3. Final round (round 10):
   - SubBytes
   - ShiftRows
   - AddRoundKey (`get_rk(10)`) **without MixColumns**
   - Output to `block_out`, assert `done`

The core processes one AES block in **11 clock cycles** plus control overhead at 25 MHz.

---

###  `aes128_decrypt` — AES-128 Decryption Core

**Role:**  
Inverse of `aes128_encrypt`, implementing **AES-128 decryption** using the same `round_keys` (0–10).

**Key points:**
- Initial step:
  ```verilog
  state <= block_in ^ get_rk(10); // last round key
  round <= 9;
  busy  <= 1;
  ```
- For rounds 9..1:
  - Apply `inv_shift_sub(state)`
  - XOR with `get_rk(round)`
  - Apply `inv_mixcolumns(...)`
- Final round (round 0):
  - Apply `inv_shift_sub(state)`
  - XOR with `get_rk(0)`
  - Output `block_out`
  - Assert `done`

**Helper logic inside:**
- `inv_sbox_fn` — full inverse S-Box table
- `inv_shift_sub` — combined InvShiftRows + InvSubBytes
- `inv_mixcolumns` — full inverse MixColumns using GF(2^8) multipliers by 9, 11, 13, 14

Used by `echo_top` when the command byte is `D` / `d`.

---

## 🛠 How to Build & Run on Basys-3

###  Vivado Project Setup
- Create a new **RTL Project**
- Add all `src/*.v` files
- Add the Basys-3 constraint file in `constr/basys3_constraints.xdc`
  - Map:
    - `clk`   → 100 MHz clock pin (W5)
    - `rstn`  → pushbutton (e.g., BTN0 on U18, active-low with pull-up)
    - `uart_rx_pin` → FTDI Rx pin (from PC, B18)
    - `uart_tx_pin` → FTDI Tx pin (to PC, A18)

###  Synthesize & Implement
- Run **Synthesis** and **Implementation**
- Generate **Bitstream**

###  Program the FPGA
- Open **Hardware Manager**
- Auto-connect to the Basys-3 board
- Program device with generated `.bit` file

### Open Serial Terminal on PC
Use any serial monitor (PuTTY, TeraTerm, VS Code, etc.)

Settings:
- Baud rate: **115200**
- Data bits: **8**
- Parity: **None**
- Stop bits: **1**
- Flow control: **None**

### Example Session

**Encrypt:**
1. Send ASCII `E`
2. Send 16 bytes of plaintext (you can send any 16 characters)

FPGA returns 16 bytes of ciphertext (may appear as gibberish characters).

**Decrypt:**
1. Send ASCII `D`
2. Send the 16-byte ciphertext you previously captured

FPGA returns 16 bytes of recovered plaintext.

---



This project demonstrates:

- **Real hardware AES-128** (not just simulation or software)
- **Bidirectional secure communication** via UART
- Complete **encryption + decryption** pipeline in Verilog

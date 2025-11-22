# 🔐 SecureSilicon — AES-UART Secure Communication System

## Overview
SecureSilicon is an FPGA-based **AES-128 Hardware Encryption System** that uses **UART communication** to securely transfer encrypted data in real time.  
This system runs on the **Xilinx Basys-3 FPGA**, written entirely in synthesizable Verilog, and built for a National-Level Hardware Hackathon.

The project encrypts incoming UART plaintext using a hardware AES core and sends the encrypted ciphertext back over UART.

---

## 📁 Project Structure (Actual Vivado Layout)

Your current project structure:

project_1/
│
├── project_1.srcs/ → Vivado auto-generated sources
│
├── constrs_1/
│ └── new/
│ └── asa.xdc → Basys-3 constraint file
│
├── sources_1/
│ └── new/
│ └── top.v → Your top-level Verilog module
│
└── .gitignore → Ignoring Vivado build files

yaml
Copy code

This is the standard **Vivado directory structure** and is perfectly valid.

---

## 🚀 Features

### 🔸 AES-128 Encryption Engine
- Fully synthesizable hardware AES core  
- Implements 10 AES rounds  
- Real-time encryption of UART data  

### 🔸 UART RX & TX Interface
- Receives plaintext bytes  
- Transmits ciphertext bytes  
- Baud rate: **115200**  
- Works with PuTTY / TeraTerm / VS Code Serial Monitor  

### 🔸 Basys-3 FPGA Integration
- 100 MHz main clock  
- USB-UART over the on-board FTDI chip  
- Constraint file (`asa.xdc`) included  

---

## 🔧 Requirements

- **Vivado 2020.2+**
- **Basys-3 FPGA Board**
- USB-UART Serial Terminal  
- UART settings: **115200**, **8-N-1**

---

## 🛠 How to Build & Run

### 1️⃣ Open the Vivado project
File → Open Project → select project_1.xpr

shell
Copy code

### 2️⃣ Synthesize & Generate Bitstream
Flow → Generate Bitstream

shell
Copy code

### 3️⃣ Program Basys-3 FPGA
Hardware Manager → Program Device

yaml
Copy code

### 4️⃣ Open UART Terminal
Configure your serial monitor:
- Baud: **115200**
- Data bits: **8**
- Parity: **None**
- Stop bits: **1**

### 5️⃣ Send Data
Type a character or string.  
The FPGA encrypts it using AES-128 and returns **ciphertext**.

---

## 📡 System Data Flow

+------------+ +-------------+ +-------------+
| UART RX | ---> | AES-128 | ---> | UART TX |
| (Plaintext)| | Encryption | | (Ciphertext)|
+------------+ +-------------+ +-------------+

yaml
Copy code

---

## 🏆 Hackathon Focus

SecureSilicon demonstrates:
- Hardware-level cryptography  
- FPGA-based secure communication  
- Real-time AES encryption  
- Verilog RTL design  
- End-to-end embedded hardware system  

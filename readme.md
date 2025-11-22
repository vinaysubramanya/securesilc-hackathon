# 🔐 SecureSilicon — AES-UART Secure Communication System

SecureSilicon is an FPGA-based **AES-128 Hardware Encryption System** that uses **UART communication** to securely transfer encrypted data in real time.

The system runs on the **Xilinx Basys-3 FPGA**, written entirely in **synthesizable Verilog**, and built for a **National-Level Hardware Hackathon**.

Incoming plaintext data over UART is encrypted using a hardware AES core, and the resulting ciphertext is sent back over UART to the host PC.

---

## 📁 Project Structure

```text
project_1/
│
├── project_1.srcs/         # Vivado auto-generated sources
│
├── constrs_1/
│   └── new/
│       └── asa.xdc         # Basys-3 constraint file
│
├── sources_1/
│   └── new/
│       └── top.v           # Top-level Verilog module
│
└── .gitignore              # Ignore Vivado build / temp files
```

---

## 🚀 Features

### 🔸 AES-128 Encryption Engine
- Fully synthesizable **hardware AES-128 core**
- Implements all **10 AES rounds**
- Real-time encryption of UART data

### 🔸 UART RX & TX Interface
- Receives plaintext from PC
- Returns ciphertext
- Baud: **115200**, Format: **8-N-1**

### 🔸 Basys-3 FPGA Integration
- Uses on‑board **100 MHz** clock
- USB‑UART via FTDI
- Ready constraint file included

---

## 🛠 How to Build & Run

### 1️⃣ Open Project
`File → Open Project → project_1.xpr`

### 2️⃣ Generate Bitstream
`Flow → Generate Bitstream`

### 3️⃣ Program FPGA
`Hardware Manager → Program Device`

### 4️⃣ Open Serial Terminal
Set:
- Baud: 115200  
- Data: 8  
- Parity: None  
- Stop: 1  

### 5️⃣ Send Data
The FPGA:
1. Receives plaintext  
2. Encrypts using AES-128  
3. Sends ciphertext back  

---

## 📡 Data Flow

```text
+-----------+       +-----------+       +-----------+
|  UART RX  |  -->  |  AES-128  |  -->  |  UART TX  |
| Plaintext |       | Encryption|       | Ciphertext|
+-----------+       +-----------+       +-----------+
```

---

## 🏆 Hackathon Highlights
- Hardware cryptography  
- Real-time secure communication  
- Clean Verilog RTL  
- Strong FPGA design architecture  
